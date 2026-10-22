import Foundation
import KumikoCore

// A thin client: every command is answered by the running app, so the CLI stays fast enough to be
// called from a hotkey or a shell loop. Only help and version are answered locally.

let usage = """
	usage: kumiko <command> [arguments]

	commands:
	  ping       check that kumiko is running
	  status     show modules and permissions
	  reload     reread kumiko.toml
	  query windows|focused
	             print windows as JSON
	  version    print the version of the running app

	  --version  print the version of this CLI
	"""

let args = Array(CommandLine.arguments.dropFirst())

func printError(_ message: String) {
	FileHandle.standardError.write(Data((message + "\n").utf8))
}

switch args.first {
case nil, "-h", "--help", "help":
	print(usage)
	exit(args.isEmpty ? 1 : 0)
case "--version":
	print(Kumiko.version)
	exit(0)
default:
	break
}

let paths = Paths.standard()

do {
	let response = try IPCClient.send(Request(args: args), to: paths.socket)

	if response.ok {
		if !response.output.isEmpty { print(response.output) }
		exit(0)
	}

	printError(response.output)
	exit(1)
} catch IPCError.system("connect", _) {
	printError("kumiko is not running (no answer on \(paths.socket.path(percentEncoded: false)))")
	exit(1)
} catch {
	printError("kumiko: \(error)")
	exit(1)
}
