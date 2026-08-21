-- quilt: single source of tunables, shared by init.lua and wm.lua.
-- Lua locals are file-scoped, so any constant needed by both files must live here.
return {
  padding = 8,
  gap = 8,
  spaceCount = 10,

  -- Bundle IDs excluded from tiling: System Settings, the macOS Passwords app, Bitwarden's
  -- floating window, and OpenWhispr's dictation control panel. Each is a floating utility
  -- window, not a normal document window, and forcing it into a BSP tile fights the floating
  -- position the app sets for itself.
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
