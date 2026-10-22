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

`KUMIKO_SIGN_IDENTITY="Developer ID Application: …" scripts/bundle.sh` signs for real. Without it
the bundle is signed ad hoc, and macOS asks for permissions again after every rebuild.

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

## License

MIT
