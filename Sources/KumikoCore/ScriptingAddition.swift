import Foundation

/// kumiko's payload in Dock, from `Sources/KumikoOSAX`. Dock's connection to the window server may
/// change any app's windows, which kumiko's own may not; the payload takes requests on a socket and
/// carries them out as Dock.
public enum ScriptingAddition {
	/// The payload version this build talks to, `SA_VERSION` in `common.h`.
	public static let version = "2"

	public struct Failure: Error, CustomStringConvertible {
		public let description: String

		init(_ description: String) {
			self.description = description
		}
	}

	private enum Opcode: UInt8 {
		case handshake = 0x01
		case windowShadow = 0x02
		case windowAbove = 0x03
	}

	/// The payload listens in the name of the user Dock runs as. Under sudo that is the user who
	/// ran sudo, not root.
	static var socket: URL {
		let user = ProcessInfo.processInfo.environment["SUDO_USER"] ?? NSUserName()
		return URL(filePath: "/tmp/kumiko-sa_\(user).socket")
	}

	/// Whether System Integrity Protection lets the payload into Dock: it needs filesystem protections
	/// and debugging restrictions off, the way yabai's wiki has them. `csr_check` answers 0 for what
	/// SIP allows.
	public static var isAllowedBySIP: Bool {
		typealias Check = @convention(c) (UInt32) -> Int32
		guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csr_check") else { return false }
		let check = unsafeBitCast(symbol, to: Check.self)
		let unrestrictedFilesystem: UInt32 = 1 << 1
		let taskForPID: UInt32 = 1 << 2
		return check(unrestrictedFilesystem) == 0 && check(taskForPID) == 0
	}

	/// The version of the payload loaded in Dock, nil when none answers.
	public static func handshake() -> String? {
		guard let reply = try? exchange([Opcode.handshake.rawValue], answered: true) else { return nil }
		let version = String(decoding: reply, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
		return version.isEmpty ? nil : version
	}

	/// Gives a window its shadow back or takes it away. False when the payload did not take the
	/// request.
	@discardableResult
	public static func setShadow(_ window: UInt32, _ on: Bool) -> Bool {
		var body = [Opcode.windowShadow.rawValue]
		withUnsafeBytes(of: window.littleEndian) { body += $0 }
		body.append(on ? 1 : 0)
		return (try? exchange(body, answered: false)) != nil
	}

	/// Keeps a window above the windows of the normal level, or puts it back among them. False when
	/// the payload did not take the request; one older than version 2 takes it and does nothing.
	@discardableResult
	public static func setAbove(_ window: UInt32, _ above: Bool) -> Bool {
		var body = [Opcode.windowAbove.rawValue]
		withUnsafeBytes(of: window.littleEndian) { body += $0 }
		body.append(above ? 1 : 0)
		return (try? exchange(body, answered: false)) != nil
	}

	/// One request per connection, framed as `common.h` describes: an int16 length, then the body.
	private static func exchange(_ body: [UInt8], answered: Bool) throws -> Data {
		let fd = try IPCClient.connectedSocket(socket)
		defer { close(fd) }
		setTimeout(fd, 1)

		var message = Data()
		withUnsafeBytes(of: Int16(body.count).littleEndian) { message.append(contentsOf: $0) }
		message.append(contentsOf: body)
		try writeAll(fd, message)

		return answered ? try readAll(fd) : Data()
	}

	/// Puts the payload where Dock can load it and loads it. Everything here needs root.
	public enum Installer {
		public static let directory = URL(filePath: "/Library/ScriptingAdditions/kumiko.osax")

		private static var binaries: URL { directory.appending(path: "Contents/MacOS") }

		public static var isInstalled: Bool {
			FileManager.default.fileExists(atPath: binaries.appending(path: "payload").path(percentEncoded: false))
		}

		/// Copies the loader and the payload built by `scripts/osax.sh` from `resources` and signs
		/// them ad hoc, as Dock will not load an unsigned library.
		public static func install(from resources: URL) throws {
			let files = FileManager.default
			try? files.removeItem(at: directory)
			try files.createDirectory(at: binaries, withIntermediateDirectories: true)

			for name in ["loader", "payload"] {
				let target = binaries.appending(path: name)
				try files.copyItem(at: resources.appending(path: name), to: target)
				try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path(percentEncoded: false))
				try run("/usr/bin/codesign", "--force", "--sign", "-", target.path(percentEncoded: false))
			}
		}

		/// Injects the payload into Dock and waits for it to answer. A payload already there is
		/// left alone when it is this version; another version stays until Dock restarts, since
		/// Dock does not load the same library twice.
		public static func load() throws {
			switch handshake() {
			case version?:
				return
			case let other?:
				throw Failure("Dock runs payload version \(other), this kumiko needs \(version): restart Dock with `killall Dock`, then load again")
			case nil:
				break
			}

			try run(binaries.appending(path: "loader").path(percentEncoded: false))

			for _ in 0..<20 where handshake() == nil {
				Thread.sleep(forTimeInterval: 0.05)
			}

			guard handshake() == version else {
				throw Failure("the payload did not answer after loading; see `log show --predicate 'process == \"Dock\"' --last 1m`")
			}
		}

		/// Removes the files. A payload already in Dock keeps running until Dock restarts.
		public static func uninstall() throws {
			guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return }
			try FileManager.default.removeItem(at: directory)
		}

		private static func run(_ executable: String, _ arguments: String...) throws {
			let process = Process()
			process.executableURL = URL(filePath: executable)
			process.arguments = arguments
			let output = Pipe()
			process.standardOutput = output
			process.standardError = output

			try process.run()
			process.waitUntilExit()

			guard process.terminationStatus == 0 else {
				let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
				let name = URL(filePath: executable).lastPathComponent
				throw Failure("\(name) failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
			}
		}
	}
}
