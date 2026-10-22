import Foundation
import KumikoCore
import Testing

struct IPCTests {
	/// Short path under /tmp: sockaddr_un only holds about a hundred bytes, and the per-user
	/// temporary directory is already most of that.
	private func socketURL() -> URL {
		URL(filePath: "/tmp/kumiko-test-\(UUID().uuidString.prefix(8)).sock")
	}

	@Test func roundTrip() async throws {
		let url = socketURL()
		let server = IPCServer(socket: url) { args in .success(args.joined(separator: " ")) }
		try server.start()
		defer { server.stop() }

		let response = try await Task.detached {
			try IPCClient.send(Request(args: ["echo", "hello"]), to: url)
		}.value

		#expect(response == .success("echo hello"))
	}

	@Test func detectsRunningServer() async throws {
		let url = socketURL()
		#expect(await Task.detached { IPCServer.isRunning(at: url) }.value == false)

		let server = IPCServer(socket: url) { _ in .success("pong") }
		try server.start()
		defer { server.stop() }

		#expect(await Task.detached { IPCServer.isRunning(at: url) }.value)
	}

	@Test func staleSocketFileIsReplaced() async throws {
		let url = socketURL()
		FileManager.default.createFile(atPath: url.path, contents: Data())

		let server = IPCServer(socket: url) { _ in .success("ok") }
		try server.start()
		defer { server.stop() }

		let response = try await Task.detached { try IPCClient.send(Request(args: []), to: url) }.value
		#expect(response.ok)
	}

	@Test func noServerIsAConnectError() {
		#expect(throws: IPCError.self) { try IPCClient.send(Request(args: ["ping"]), to: socketURL()) }
	}
}
