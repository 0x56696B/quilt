# quilt

quilt is a tiling window manager for macOS. It arranges windows in a binary
space partition (BSP) layout and adds space and window commands you can run
from the command line or bind to a key.

## What it does

- **BSP tiling.** Each connected screen keeps its own tiling tree. One window
  fills the screen. A second window splits it in half. A third window splits
  the focused half again. The split direction follows the screen's aspect
  ratio.
- **Multiple desktop spaces.** quilt checks the number of Mission Control
  spaces at startup and creates more if you need them.
- **Space switching.** Use the native macOS "Switch to Desktop" shortcuts
  (Option+1 through Option+9 by default). quilt does not add its own
  shortcut for this.
- **Move a window to a space.** Run `quilt window --space N` from the
  command line. There is no keyboard shortcut for this yet, and it does not
  work on every macOS build. See Known limitations.
- **Drag to swap.** Drag a tiled window's title bar onto another tiled
  window to swap their positions in the layout. Drop a window on empty
  space and it snaps back into its own tile.

## How it works

quilt has two parts:

- **A Hammerspoon configuration** (Lua). This is the tiling engine. It
  tracks windows, computes the BSP layout, and applies it.
- **`quilt` and `quiltctl`.** `quilt` is a command-line wrapper you call by
  hand or bind to a key. `quiltctl` is a small compiled helper that handles
  space operations Hammerspoon cannot do on its own.

## Requirements

- macOS
- [Hammerspoon](https://www.hammerspoon.org/) 1.1.1 or later
- Xcode Command Line Tools (for `swiftc`)
- [Homebrew](https://brew.sh/) and `jq`

## Install

```
./install.sh
```

The installer is idempotent. Run it again any time. It stops once for a
manual step: grant Hammerspoon Accessibility access in System Settings →
Privacy & Security → Accessibility, then run the script again.

## Verify

```
lua test_bsp.lua      # BSP tree math, unit tests
quilt space --list    # live space state
quilt frames          # compares the computed layout against each window's actual on-screen frame
```

`quilt frames` checks that the layout engine's computed position matches
the window's real on-screen position, not just that the math is right.

## Uninstall

```
./uninstall.sh
```

This removes the LaunchAgent, the Hammerspoon config path override, and the
installed binaries.

## Known limitations

- Moving the focused window to a space with `quilt window --space N` does
  not work on every macOS build. quilt reports the real result
  (`moved: false`) instead of a false success.
- Drag-to-swap works only between windows on the same screen.
- No focus, resize, or rebalance commands, and no per-app window rules
  beyond excluding an app from tiling entirely.
- quilt's own space-focus command (`quilt space --focus N`) has no
  keyboard shortcut. Use the native macOS shortcuts instead.

## Status

This is a proof of concept. Tiling and space management work well day to
day. A few window-move edge cases are still unresolved upstream in macOS
and Hammerspoon.
