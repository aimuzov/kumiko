import CryptoKit
import Foundation
import KumikoCore

/// `kumiko sa …`, answered here rather than by the running app: installing and loading need root,
/// and the app never runs as root.
func scriptingAdditionCommand(_ args: [String]) -> Int32 {
	let command = args.first ?? "status"

	switch command {
	case "status":
		let loaded = ScriptingAddition.handshake().map { "loaded, version \($0)" } ?? "not loaded"
		let installed = ScriptingAddition.Installer.isInstalled ? "installed" : "not installed"
		print("\(installed), \(loaded)")
		return 0
	case "sudoers":
		return printSudoers()
	case "install", "load", "uninstall":
		break
	default:
		printError("usage: kumiko sa status|install|load|uninstall|sudoers")
		return 1
	}

	guard getuid() == 0 else {
		printError("kumiko sa \(command) needs root: sudo kumiko sa \(command)")
		return 1
	}

	do {
		switch command {
		case "uninstall":
			try ScriptingAddition.Installer.uninstall()
			print("removed; a payload already in Dock stays until Dock restarts")
		default:
			guard let resources = bundledPayload() else {
				printError("no scripting addition next to this binary; run the kumiko inside Kumiko.app")
				return 1
			}
			try ScriptingAddition.Installer.install(from: resources)
			if command == "load" {
				try ScriptingAddition.Installer.load()
				print("loaded, version \(ScriptingAddition.version)")
			} else {
				print("installed")
			}
		}
		return 0
	} catch {
		printError("kumiko sa \(command): \(error)")
		return 1
	}
}

/// `Kumiko.app/Contents/Resources/osax`, where `scripts/bundle.sh` puts the payload, found from this
/// binary in `Contents/MacOS` even when it is reached through a symlink on the PATH.
private func bundledPayload() -> URL? {
	guard let binary = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
	let resources = binary.deletingLastPathComponent().deletingLastPathComponent().appending(path: "Resources/osax")
	let payload = resources.appending(path: "payload").path(percentEncoded: false)
	return FileManager.default.fileExists(atPath: payload) ? resources : nil
}

/// A sudoers line that lets the app load the payload without a password after Dock restarts. It is
/// pinned to this binary's hash, so it has to be written again after every rebuild.
private func printSudoers() -> Int32 {
	guard
		let binary = Bundle.main.executableURL?.resolvingSymlinksInPath(),
		let data = try? Data(contentsOf: binary)
	else {
		printError("cannot read this binary")
		return 1
	}

	let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
	let user = ProcessInfo.processInfo.environment["SUDO_USER"] ?? NSUserName()
	print("\(user) ALL=(root) NOPASSWD: sha256:\(hash) \(binary.path(percentEncoded: false)) sa load")
	return 0
}
