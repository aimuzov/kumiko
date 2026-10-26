# Changelog

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
