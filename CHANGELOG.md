# Changelog

## [0.4.0](https://github.com/aimuzov/kumiko/compare/v0.3.0...v0.4.0) (2026-10-27)


### Features

* apply recommended settings from the General page ([c0c71a4](https://github.com/aimuzov/kumiko/commit/c0c71a4faf27a84516a679138a583c74dcf73a67))
* apply recommended settings from the General page ([93c880c](https://github.com/aimuzov/kumiko/commit/93c880caa7a2ff8bc23e9680df9ab059a2ce96ab)), closes [#86](https://github.com/aimuzov/kumiko/issues/86)
* edit the borders' exceptions in settings ([69de11c](https://github.com/aimuzov/kumiko/commit/69de11cf3becf0dac3211c5d28722b8b455ce4f6))
* edit the borders' exceptions in settings ([ba63edb](https://github.com/aimuzov/kumiko/commit/ba63edbadc3da9a6d5c6e200da0b996135e73cc1)), closes [#81](https://github.com/aimuzov/kumiko/issues/81)
* follow the reviewed preset: two modes, own frame colour, no rare apps ([576c10a](https://github.com/aimuzov/kumiko/commit/576c10aeecb980b0b2c319f383f6f6a62f979727))
* leave a forgotten hotkey mode on a timeout, a click or another app ([4f4c29d](https://github.com/aimuzov/kumiko/commit/4f4c29d955e7998d72ce48b3cae0c8e0d2e02a70))
* send crash reports to Sentry ([2810fb7](https://github.com/aimuzov/kumiko/commit/2810fb77a7f1b3a58b31dd4031b531fc80948f88))
* send crash reports to Sentry, off with [telemetry] crash_reports = false ([2077c5f](https://github.com/aimuzov/kumiko/commit/2077c5f5d235dc6642d6bbb879be51abcfefc5ca))
* switch the system appearance from the menu and the CLI ([f07fee6](https://github.com/aimuzov/kumiko/commit/f07fee67e681a3fa63fd9b8d06c930a5431020a3))
* switch the system appearance from the menu and the CLI ([cdd994b](https://github.com/aimuzov/kumiko/commit/cdd994bfb8c69f661955852fd21503e65c9a1128))


### Bug Fixes

* drop the hotkey mode line from the status bar menu ([5764b74](https://github.com/aimuzov/kumiko/commit/5764b74de0d2d9c899aeb1820121f9c79b0cecdf))
* drop the hotkey mode line from the status bar menu ([4b57fe6](https://github.com/aimuzov/kumiko/commit/4b57fe6043c9299fe3e0ba6568cfde24ab052c3c)), closes [#87](https://github.com/aimuzov/kumiko/issues/87)
* give a square window a square frame ([062f87a](https://github.com/aimuzov/kumiko/commit/062f87a1a52fd835fd56ef59d0a6d5718668dee3))
* hide a helper's windows along with the app that owns them ([9a7e75e](https://github.com/aimuzov/kumiko/commit/9a7e75eba7fbab729ebed2c8f9fa057bcbbfb896))
* keep an app shown while its helper has a window on a shown workspace ([4dd4f47](https://github.com/aimuzov/kumiko/commit/4dd4f47538dd45b30a749070a17709c080294609))
* keep earlier backups when the preset is applied again ([e7ff79a](https://github.com/aimuzov/kumiko/commit/e7ff79ae3aedadbcf09c920d3d107695aa6be4a3))
* show one bar icon for an app and its helper ([9cce076](https://github.com/aimuzov/kumiko/commit/9cce0767c12e4d9dcc0f0f26d07ee5dc7e462bcf))
* show the settings' workspace when cmd-tab brings kumiko forward ([14d0502](https://github.com/aimuzov/kumiko/commit/14d0502ea076c455e75b5c9c0ccec7fcddced84f))
* show the settings' workspace when cmd-tab brings kumiko forward ([565f26a](https://github.com/aimuzov/kumiko/commit/565f26a06d6f9fec41d225fd6eae5c8c934f38c0)), closes [#83](https://github.com/aimuzov/kumiko/issues/83)
* tile windows that an app draws in a helper process, like Steam's ([35ffebb](https://github.com/aimuzov/kumiko/commit/35ffebb5823ae6a2c5bede3b9554908c737a4478))
* tile windows that an app draws in a helper process, like Steam's ([920f1c1](https://github.com/aimuzov/kumiko/commit/920f1c1bf92eec9c1d68cc00f9cc349ed75a13da)), closes [#79](https://github.com/aimuzov/kumiko/issues/79)

## [0.3.0](https://github.com/aimuzov/kumiko/compare/v0.2.0...v0.3.0) (2026-10-27)


### Features

* keep floating windows on screen after a drag ([5813d75](https://github.com/aimuzov/kumiko/commit/5813d7522a740b7bf311d3fbd69e97e40ca6a134))


### Bug Fixes

* leave a window alone if its workspace was hidden during the drag ([1936c6a](https://github.com/aimuzov/kumiko/commit/1936c6ab94a70be481001bf9ac852c9c3b6fb257))

## 0.2.0 (2026-10-26)

The first release: kumiko tiles windows into workspaces, draws a bar and a frame, takes hotkeys and
Vim modes, and edits all of its config from a settings window.

### Windows and workspaces

* Windows split the screen, sit in one stack or float, chosen per workspace.
* A workspace lives on a display: `main`, `external`, `builtin` or a screen's name, and `main` is
  the one System Settings calls main.
* Apps open on their workspace in the order the file lists them, each with a size of its own.
* Window rules pick windows by app, title or window ID. Settings windows and windows that cannot be
  resized float on their own.
* A group of native tabs takes one place in the layout instead of one per tab.
* Floating windows stay above the tiled ones and window shadows can go, with the scripting addition
  in Dock.
* Pressing a window's edge resizes it instead of clicking the desktop.

### Settings window

* Every section of the config is edited here, and only the lines that change are written.
* Workspaces sit in islands per display and move by dragging; each has its layout and app sizes.
* Window rules take exceptions picked from open windows by title or ID.
* Hotkeys are recorded by pressing them, actions come from a list, and modes come and go.
* The Vim page sets the apps it stays out of, its start commands and the Russian layout in Normal
  mode.
* Menu bar items move between shown and hidden by dragging.
* Cmd-W closes the window, a rule can tile it, and it looks right in full screen.

### Bar

* Built in, in place of sketchybar, looking like the macOS menu bar, with a scale.
* A click on a workspace shows it, on an app's icon focuses its window, on the time opens Calendar
  on its workspace, on the battery shows its percentage, on the input source switches it.
* A plus after the workspaces adds one, and icons grow under the pointer like the Dock's.
* Labels over the items and a highlight under the pointer.
* The icons and numbers of hidden workspaces are easier to see.
* Caffeinate stays on across restarts.

### Also

* A frame around the focused window, in the accent colour unless one is picked.
* Hotkeys with modes and key remaps, and Vim modes in any text field.
* Menu bar items hide the way Ice hides them.
* The menu bar icon shows the workspaces and the hotkey mode, and can pause kumiko.
* kumiko has an icon of its own.
