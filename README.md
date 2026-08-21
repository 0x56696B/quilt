# quilt — a BSP tiling window manager PoC

`quilt` is a proof-of-concept tiling window manager for macOS built from two parts:

- **`quilt` + `quiltctl`** — `quilt` is the bash façade you call by hand or from a script;
  `quiltctl` is a small compiled Swift helper that is the *only* component touching macOS private
  APIs.
- **Hammerspoon** (`init.lua`, `wm.lua`, `bsp.lua`, `spaces.lua`, `config.lua`) is the tiling
  engine: it tracks windows, applies the BSP layout, and reconciles state against Tahoe's
  unreliable AX notifications.

Space-switching uses the **native macOS "Switch to Desktop 1..9" shortcuts** (Option+1…9 on this
machine), unchanged. quilt does not use skhd and does not touch those shortcuts. This was a
deliberate choice: quilt's `quiltctl space-focus` gesture-based switcher works (see below), but
there is no reason to replace an already-working native mechanism with a synthetic one.

`quilt` does **not** replace yabai in the deployed Ansible role — `roles/window-manager/tasks/`
still installs yabai by default. This is a side-by-side PoC you install and test manually.

## What it does

1. **BSP tiling** on the active space, independently per connected screen: each screen keeps its
   own tree, so 1 window on a screen fills it; a 2nd window on that screen splits it 50/50; a 3rd
   splits the focused pane into two quarters (the split axis follows the pane's aspect ratio, so
   this is a 21:9-vs-16:10 difference, not a bug — see `test_bsp.lua` Case B). A window that opens
   on a non-primary screen (e.g. an app restoring its last position) tiles there instead of being
   ignored. **Verified live** with real windows: opening a 2nd and 3rd Ghostty window produced
   exactly this layout, confirmed with `quilt frames` (`want` == `got` on every window).
2. **10 Mission Control spaces**, checked and topped up at Hammerspoon startup
   (`quiltctl ensure 10`).
3. **Space-switching** uses the native macOS shortcuts. Nothing to install for this.
4. **Moving the focused window to a space** — `quilt window --space N` — has no keyboard shortcut.
   Confirmed **not achievable** as a pure userland operation on this exact build (see below); run
   it manually and expect `moved:false` until that changes.
5. **Drag-to-swap.** Dropping a tiled window's title-bar drag onto another tiled window swaps the
   two in the BSP tree — pick up the window on the right, drop it near the one on the left, and
   they trade places once you release the mouse. Detected via a raw `hs.eventtap` watching
   `leftMouseDown`/`leftMouseUp` (not AX move notifications, unreliable on Tahoe — see `wm.lua`);
   a gesture only counts if the window's frame actually moved between the two events, which is
   what tells a real drag apart from a click or an in-app drag that never touches the window
   frame. This is `mouse_drop_action swap` from yabai's own drop-zone model, without its
   edge-warp case: `bsp.lua` has no insert-at-edge primitive yet, so dropping on empty space (no
   tiled window under the cursor) just snaps the dragged window back into its assigned tile.
   **Unit-tested** (`bsp.swap`, see `test_bsp.lua`) and confirmed live via `hs -c` that the tap
   installs and runs (`require('wm').dragTap:isEnabled() == true`). **Not verified end to end
   with a real drag**: Hammerspoon cannot observe mouse events it posts to itself (a documented
   upstream limitation, not specific to quilt), so a synthetic-mouse test cannot exercise this
   path — try one real drag to confirm.

## Status of move-to-space (requirement 4)

Blocked on this exact macOS build (26.5.2), confirmed three independent ways:

- from a plain, unentitled shell;
- from `quiltctl` spawned by a fully Accessibility-trusted Hammerspoon process (an unsigned child
  binary does not inherit its parent's TCC grant — it would need its own explicit entry in System
  Settings; untested whether that alone would fix it);
- via Hammerspoon's own in-process `hs.spaces.moveWindowToSpace` (claims success, does not move the
  window — matches Hammerspoon issue #3698 exactly).

`yabai -m window --space N` still works on this machine, but only because yabai's scripting
addition is already injected into Dock. That is the SIP-adjacent dependency this PoC set out to
avoid, so quilt does not adopt it. `quiltctl move` still reports its result honestly
(`"tier":3` on the compat-ID fallback succeeding, `moved:false` with exit 1 on real failure) —
tiling and space switching are unaffected either way.

## Private APIs quiltctl depends on, and why

- **`SLSCopyManagedDisplaySpaces` / `SLSGetActiveSpace` / `SLSSpaceGetType`** — read the live space
  list. Exported, callable from any unentitled process.
- **The bridged move operation** (`SLSBridgedMoveWindowsToManagedSpaceOperation`, driven through a
  *file-local* C++ symbol resolved by walking SkyLight's Mach-O symbol table, since `dlsym` cannot
  see file-local symbols) plus the pre-14.5 compat-ID fallback (`SLSSpaceSetCompatID` +
  `SLSSetWindowListWorkspace`) — both are exercised by `quiltctl move`; both currently fail on this
  build (see above).
- **The Dock-swipe gesture** (`CGEventSetIntegerValueField`/`CGEventSetDoubleValueField`, undocumented
  field numbers 55/110/123/124/129/132) — this is yabai's own no-injection fallback for switching
  spaces, also used by jurplel/InstantSpaceSwitcher and joshuarli/iss. `quiltctl space-focus`
  implements it and self-calibrates the swipe direction (macOS 26 reports it reversed versus
  earlier releases), persisting the sign to `~/.local/state/quilt/swipe-sign`. Not wired to a
  keybinding — the native shortcuts already switch spaces — but callable directly:
  `quilt space --focus N`.
- **The bridged create/destroy operations** — best-effort space self-healing. Space *destroy* is
  reported broken on Tahoe; a failed `quilt space --destroy` is expected-ish, and the documented
  fallback is removing the space by hand in Mission Control.

None of this requires disabling SIP further than this machine's current configuration (Filesystem
Protections, Debugging Restrictions and NVRAM Protections already disabled).

## Install

```
roles/window-manager/files/quilt/install.sh
```

The installer is idempotent and safe to re-run. It stops once for a genuinely manual step — there
is no supported programmatic way to grant Accessibility on macOS: grant **Hammerspoon**
Accessibility (System Settings → Privacy & Security → Accessibility), then re-run.

Before installing, stop yabai so the two tilers don't fight over the same windows:
`yabai --stop-service` (this machine's yabai LaunchAgent needed
`launchctl bootout gui/$(id -u)/com.koekeishiya.yabai` instead — `--stop-service` and
`brew services stop yabai` both reported success without actually stopping it). Restart with
`yabai --start-service`, or the same `launchctl bootstrap` form if that also doesn't take effect.

## Verify

```
(cd roles/window-manager/files/quilt && /opt/homebrew/bin/lua test_bsp.lua)   # BSP tree maths
quilt space --list                                                            # live space state
quilt frames                                                                  # want vs. got, per window
```

`quilt frames` is the load-bearing debug command: each entry's `ok` field compares the layout
engine's *computed* rect against the window's *actual* on-screen frame, so it proves the AX resize
landed, not just that the arithmetic is right.

## Revert

```
roles/window-manager/files/quilt/uninstall.sh
```

Removes the LaunchAgent, the `MJConfigFile` override, and the installed binaries. Nothing else to
revert: quilt never modifies skhd or the native macOS hotkeys.

## Known limitations

- **`quiltctl` resolves the main display via `CGMainDisplayID()`** (`CGDisplayCreateUUIDFromDisplayID`
  is absent on this build, so it falls back to the first display entry — correct for a
  single-display machine). This only affects `quiltctl`'s own space bookkeeping; the Hammerspoon
  tiler (`wm.lua`) tiles every connected screen independently, each with its own BSP tree per
  space.
- **Drag-to-swap is same-screen only.** Dropping a dragged window onto a tiled window on a
  different screen snaps it back instead of swapping, since the swap primitive only rearranges
  leaves within one screen's tree.
- **No focus/resize/rebalance commands**, no title-conditional window rules (e.g. yabai's Sweet
  Home 3D rule), and no ratio-adjustable splits — out of scope for this PoC. Drag-to-swap (see
  "What it does" above) covers the swap case only — there is no edge-warp equivalent to insert a
  dropped window into a new split.
- **Move-to-space has no keyboard shortcut and does not currently work** — see Status above.
