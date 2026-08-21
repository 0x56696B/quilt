#!/usr/bin/env bash
# quilt: idempotent installer. Keybindings for space-switching are the native macOS "Switch to
# Desktop 1..9" shortcuts (unchanged by this PoC). Moving the focused window to a space has no
# keyboard shortcut — run `quilt window --space N` by hand.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HS="/opt/homebrew/bin/hs"

case "${1:-}" in
  "") ;;
  *) echo "usage: install.sh" >&2; exit 64 ;;
esac

echo "==> 1/8 prerequisites"
[[ "$(uname -s)" == "Darwin" ]] || { echo "install.sh: requires macOS" >&2; exit 1; }
[[ -x /usr/bin/swiftc ]] || { echo "install.sh: /usr/bin/swiftc not found (install Command Line Tools)" >&2; exit 1; }
command -v brew >/dev/null 2>&1 || { echo "install.sh: brew not found" >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "install.sh: jq not found" >&2; exit 1; }

echo "==> 2/8 Hammerspoon"
if [[ ! -d /Applications/Hammerspoon.app ]]; then
  brew install --cask hammerspoon
fi
ver="$(defaults read /Applications/Hammerspoon.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo 0)"
if [[ "$(printf '%s\n' 1.1.1 "$ver" | sort -V | head -1)" != "1.1.1" ]]; then
  echo "install.sh: Hammerspoon $ver < 1.1.1 required (1.1.0 had a Gatekeeper defect); run: brew upgrade --cask hammerspoon" >&2
  exit 1
fi

echo "==> 3/8 build quiltctl, link quilt"
mkdir -p "$HOME/.local/bin" "$HOME/.local/state/quilt"
/usr/bin/swiftc -O -o "$HOME/.local/bin/quiltctl" "$DIR/quiltctl.swift"
ln -sf "$DIR/quilt" "$HOME/.local/bin/quilt"

echo "==> 4/8 point Hammerspoon at this config"
defaults write org.hammerspoon.Hammerspoon MJConfigFile "$DIR/init.lua"

echo "==> 5/8 launch Hammerspoon, wait for its CLI"
open -g -a /Applications/Hammerspoon.app
found_hs=0
for _ in $(seq 1 15); do
  if [[ -x "$HS" ]]; then found_hs=1; break; fi
  sleep 1
done
if [[ "$found_hs" -ne 1 ]]; then
  echo "install.sh: Hammerspoon did not install the hs CLI — open its console and check init.lua for errors" >&2
  exit 1
fi

echo "==> 6/8 Hammerspoon Accessibility gate"
hs_trusted="$("$HS" -c "hs.accessibilityState()" 2>/dev/null || true)"
if [[ "$hs_trusted" != "true" ]]; then
  echo "grant Hammerspoon Accessibility: System Settings > Privacy & Security > Accessibility, then re-run this script" >&2
  exit 3
fi

echo "==> 7/8 LaunchAgent for login start"
mkdir -p "$HOME/Library/LaunchAgents"
AGENT_PLIST="$HOME/Library/LaunchAgents/org.hammerspoon.quilt.plist"
cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>org.hammerspoon.quilt</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-a</string>
    <string>/Applications/Hammerspoon.app</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
launchctl bootout "gui/$(id -u)/org.hammerspoon.quilt" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null || {
  sleep 1
  launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null || true
}
launchctl print "gui/$(id -u)/org.hammerspoon.quilt" >/dev/null 2>&1 || {
  echo "install.sh: failed to bootstrap the quilt LaunchAgent" >&2
  exit 1
}

echo "==> 8/8 reload Hammerspoon so any rebuilt helper/edited config takes effect"
if pgrep -x Hammerspoon >/dev/null; then
  "$HS" -c "hs.reload()" >/dev/null 2>&1 || { killall Hammerspoon; sleep 1; open -g -a /Applications/Hammerspoon.app; }
fi
for _ in $(seq 1 15); do
  pgrep -x Hammerspoon >/dev/null && break
  sleep 1
done
pgrep -x Hammerspoon >/dev/null || { echo "install.sh: Hammerspoon is not running after reload" >&2; exit 1; }

echo "install.sh: done. Space-switching uses the native macOS Option+1..9 shortcuts (unchanged)."
echo "install.sh: to move the focused window to a space, run: quilt window --space N (no keyboard shortcut; see Known limitations in README.md)."
