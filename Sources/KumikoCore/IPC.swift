import Foundation

/// What the CLI sends: its arguments, as typed.
public struct Request: Codable, Sendable, Equatable {
	public var args: [String]

	public init(args: [String]) {
		self.args = args
	}
}

/// What comes back. `output` goes to stdout on success and to stderr otherwise.
public struct Response: Codable, Sendable, Equatable {
	public var ok: Bool
	public var output: String

	public init(ok: Bool, output: String) {
		self.ok = ok
		self.output = output
	}

	public static func success(_ output: String = "") -> Response { Response(ok: true, output: output) }
	public static func failure(_ output: String) -> Response { Response(ok: false, output: output) }
}

public enum IPCError: Error, CustomStringConvertible {
	case system(String, Int32)
	case pathTooLong(String)
	case malformed

	public var description: String {
		switch self {
		case let .system(call, code): "\(call): \(String(cString: strerror(code)))"
		case let .pathTooLong(path): "socket path is too long: \(path)"
		case .malformed: "malformed message"
		}
	}
}

// One connection carries one exchange: the client writes a JSON request and shuts down its write
// side, the server answers with a JSON response and closes. No framing beyond EOF is needed.

/// Sends one request to a running kumiko and waits for the answer.
public enum IPCClient {
	public static func send(_ request: Request, to socket: URL, timeout: TimeInterval = 5) throws -> Response {
		let fd = try connectedSocket(socket)
		defer { close(fd) }

		setTimeout(fd, timeout)

		try writeAll(fd, JSONEncoder().encode(request))
		shutdown(fd, SHUT_WR)

		guard let response = try? JSONDecoder().decode(Response.self, from: readAll(fd)) else {
			throw IPCError.malformed
		}

		return response
	}

	static func connectedSocket(_ url: URL) throws -> Int32 {
		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		guard fd >= 0 else { throw IPCError.system("socket", errno) }

		var address = try socketAddress(url)
		let result = withUnsafePointer(to: &address) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
			}
		}

		guard result == 0 else {
			let code = errno
			close(fd)
			throw IPCError.system("connect", code)
		}

		return fd
	}
}

/// Accepts connections on the socket and answers each request through `handler`.
///
/// Reading and writing happen on a private queue; only the handler runs on the main actor, where
/// the rest of kumiko lives.
public final class IPCServer: @unchecked Sendable {
	public typealias Handler = @MainActor ([String]) -> Response

	private let url: URL
	private let handler: Handler
	private let queue = DispatchQueue(label: "\(Kumiko.bundleIdentifier).ipc")
	private var source: (any DispatchSourceRead)?

	public init(socket url: URL, handler: @escaping Handler) {
		self.url = url
		self.handler = handler
	}

	/// Takes over the socket path. A file left there by a crashed instance is removed; a live
	/// instance is the caller's business to detect (see `isRunning`) before calling this.
	public func start() throws {
		let path = url.path(percentEncoded: false)
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		unlink(path)

		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		guard fd >= 0 else { throw IPCError.system("socket", errno) }

		var address = try socketAddress(url)
		let bound = withUnsafePointer(to: &address) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
			}
		}

		guard bound == 0, listen(fd, 16) == 0 else {
			let code = errno
			close(fd)
			throw IPCError.system("bind", code)
		}

		// Only this user may talk to the window manager.
		chmod(path, 0o600)

		let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
		source.setEventHandler { [weak self] in self?.accept(on: fd) }
		source.setCancelHandler { close(fd) }
		source.resume()

		self.source = source
	}

	public func stop() {
		source?.cancel()
		source = nil
		unlink(url.path(percentEncoded: false))
	}

	/// True when another kumiko answers on the socket.
	public static func isRunning(at url: URL) -> Bool {
		(try? IPCClient.send(Request(args: ["ping"]), to: url, timeout: 1))?.ok == true
	}

	private func accept(on listener: Int32) {
		let fd = Darwin.accept(listener, nil, nil)
		guard fd >= 0 else { return }

		// A client that connects and never sends would otherwise hold the queue forever.
		setTimeout(fd, 1)

		guard let data = try? readAll(fd), let request = try? JSONDecoder().decode(Request.self, from: data) else {
			reply(.failure(IPCError.malformed.description), on: fd)
			return
		}

		let handler = handler
		Task { @MainActor in
			let response = handler(request.args)
			self.queue.async { self.reply(response, on: fd) }
		}
	}

	private func reply(_ response: Response, on fd: Int32) {
		if let data = try? JSONEncoder().encode(response) {
			try? writeAll(fd, data)
		}
		close(fd)
	}
}

// MARK: - Socket helpers

func socketAddress(_ url: URL) throws -> sockaddr_un {
	let path = url.path(percentEncoded: false)
	var address = sockaddr_un()
	address.sun_family = sa_family_t(AF_UNIX)

	let capacity = MemoryLayout.size(ofValue: address.sun_path)
	guard path.utf8.count < capacity else { throw IPCError.pathTooLong(path) }

	withUnsafeMutableBytes(of: &address.sun_path) { buffer in
		buffer.copyBytes(from: path.utf8)
		buffer[path.utf8.count] = 0
	}

	return address
}

func setTimeout(_ fd: Int32, _ seconds: TimeInterval) {
	var value = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
	// A client gone before the reply must not take the whole app down with SIGPIPE.
	var on: Int32 = 1
	setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
}

func writeAll(_ fd: Int32, _ data: Data) throws {
	try data.withUnsafeBytes { buffer in
		var offset = 0
		while offset < buffer.count {
			let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
			guard written > 0 else { throw IPCError.system("write", errno) }
			offset += written
		}
	}
}

func readAll(_ fd: Int32) throws -> Data {
	var data = Data()
	var buffer = [UInt8](repeating: 0, count: 4096)

	while true {
		let count = read(fd, &buffer, buffer.count)
		if count == 0 { return data }
		guard count > 0 else { throw IPCError.system("read", errno) }
		data.append(buffer, count: count)
	}
}
