import Foundation
import KumikoCore

// A thin client: every command is answered by the running app, so the CLI stays fast enough to be
// called from a hotkey or a shell loop. Only help, version and the scripting addition are answered
// locally.

let usage = """
	usage: kumiko <command> [arguments]

	commands:
	  ping       check that kumiko is running
	  status     show modules and permissions
	  reload     reread kumiko.toml
	  settings [general|advanced|about|windows|workspaces|rules|hotkeys|bar|borders|menubar|vim]
	             open the settings window
	  query windows|focused|workspaces|displays
	             print state as JSON

	  window focus west|east|north|south|first|last|recent|stack-next|stack-prev
	  window warp west|east|north|south|first|last
	  window move <workspace>|<n>|next|prev [--focus]
	  window resize left|right|top|bottom <points>
	  window ratio <0…1>
	  window float [--grid rows:cols:x:y:width:height]
	  window zoom fullscreen|parent
	  window stack west|east|north|south
	  window unstack
	  window close

	  workspace focus <name>|<n>|next|prev|recent
	  workspace balance
	  workspace rotate 90|180|270
	  workspace mirror horizontal|vertical
	  workspace layout bsp|stack|float [<name>]
	             written to kumiko.toml; without a name, the focused workspace's

	  menubar show|hide|toggle
	             show or hide the status items left of the divider

	  sa status|install|load|uninstall|sudoers
	             the scripting addition in Dock, for window shadows;
	             install, load and uninstall need sudo
	  version    print the version of the running app
	  quit       quit the app, putting hidden windows back on screen

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
case "sa":
	exit(scriptingAdditionCommand(Array(args.dropFirst())))
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
