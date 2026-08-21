#!/usr/bin/env bash
# quilt: full revert. Every step tolerates an already-clean system, so this is safely re-runnable.
set -euo pipefail

echo "==> 1/4 remove the Hammerspoon LaunchAgent"
launchctl bootout "gui/$(id -u)/org.hammerspoon.quilt" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/org.hammerspoon.quilt.plist"

echo "==> 2/4 unset Hammerspoon's config path override"
defaults delete org.hammerspoon.Hammerspoon MJConfigFile 2>/dev/null || true

echo "==> 3/4 remove the quilt CLI and helper"
rm -f "$HOME/.local/bin/quilt" "$HOME/.local/bin/quiltctl"

echo "==> 4/4 done. Nothing else to revert: quilt never modified any other keybindings."
