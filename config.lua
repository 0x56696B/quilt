-- quilt: single source of tunables, shared by init.lua and wm.lua.
-- Lua locals are file-scoped, so any constant needed by both files must live here.
return {
  padding = 8,
  gap = 8,
  spaceCount = 10,

  -- Bundle IDs excluded from tiling. Mirrors roles/window-manager/files/yabai/yabairc's
  -- manage=off rules for System Settings and Passwords, plus aerospace.toml's Bitwarden float.
  -- OpenWhispr mirrors yabairc's "manage=off sticky=on sub-layer=above" rule: it is a floating
  -- dictation control panel, not a normal document window, and forcing it into a BSP tile fights
  -- the floating position the app sets for itself.
  -- Title-conditional rules (yabairc's "Sweet Home 3D" / title="^Modify") cannot be expressed by
  -- bundle id and are out of scope for this PoC.
  deny = {
    ["com.apple.systempreferences"] = true,
    ["com.apple.Passwords"] = true,
    ["com.bitwarden.desktop"] = true,
    ["com.gizmolabs.openwhispr"] = true,
  },

  reconcileInterval = 2,
  retileDelay = 0.05,

  helper = os.getenv("HOME") .. "/.local/bin/quiltctl",
}
