# kumiko

A tiling window manager for macOS that comes as one app: windows, hotkeys, a status bar and window
borders, sharing one process and one config file. No SIP changes needed.

> Early days. Stage 1 is the skeleton: the app, its config, the CLI and permission onboarding.
> Window management arrives next.

## Build

```sh
scripts/bundle.sh          # dist/Kumiko.app, release build
scripts/test.sh            # unit tests
```

`KUMIKO_SIGN_IDENTITY="Developer ID Application: …" scripts/bundle.sh` signs for real. For local
builds run `scripts/dev-certificate.sh` once: it puts a self-signed certificate into the login
keychain, `bundle.sh` signs with it, and permissions survive rebuilds. Without either the bundle is
signed ad hoc, and macOS asks for permissions again after every rebuild.

## Run

Open `dist/Kumiko.app`. It lives in the status bar; on first launch it asks for Accessibility (to
arrange windows) and Input Monitoring (for hotkeys).

The CLI is inside the bundle:

```sh
ln -s "$PWD/dist/Kumiko.app/Contents/MacOS/kumiko" ~/.local/bin/kumiko
kumiko status
```

| Command | Does |
| --- | --- |
| `kumiko ping` | checks that the app is running |
| `kumiko status` | modules, permissions, config path and the last config error |
| `kumiko reload` | rereads the config; also happens by itself when the file changes |
| `kumiko version` | version of the running app (`--version` for the CLI itself) |

## Config

`~/.config/kumiko/kumiko.toml` (`$XDG_CONFIG_HOME` is respected). Every key is optional; no file at
all is a valid config. A broken file keeps the previous config in force and shows the error in the
status menu and in `kumiko status`.

```toml
[wm]
enabled = true

[hotkeys]
enabled = true

[bar]
enabled = false

[borders]
enabled = true
```

`[menubar]` hides status items of the macOS menu bar, the way Ice does, and is off by default. It
adds a chevron and an invisible divider to the menu bar; items left of the divider hide. Cmd-drag
an item across the divider to choose. The first time, both take the places of Ice's own.

```toml
[menubar]
enabled = true
show_on_click = true   # a click on the empty menu bar shows or hides the items
show_on_scroll = true  # scrolling over the menu bar: up shows, down hides
rehide = 0             # seconds before shown items hide again, 0 for never
```

`kumiko menubar show|hide|toggle` does the same from a script or a hotkey.

## License

MIT
