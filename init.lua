-- quilt: Hammerspoon entry point. Wires the tiler and exposes the quilt.cli API that the `quilt`
-- bash CLI drives over `hs -c`. No hs.hotkey call anywhere — skhd owns every keybinding.
local cfg = require("config")

hs.window.animationDuration = 0

require("hs.ipc")
hs.ipc.cliInstall("/opt/homebrew") -- puts `hs` at /opt/homebrew/bin/hs; /usr/local/bin doesn't exist here

local spaces = require("spaces")
local wm = require("wm")
local bsp = require("bsp")

spaces.ensure(cfg.spaceCount)
wm.start()

-- Single API entry point, driven over `hs -c 'quilt.cli(...)'`. Prints exactly one JSON object to
-- stdout for every verb; never calls os.exit, which would terminate Hammerspoon itself. Failure is
-- signalled by an "error" key, which `quilt`'s run_hs() branches on (hs -c always exits 0).
quilt = {}

function quilt.cli(verb, arg)
  if verb == "move-window" then
    local ok, err = wm.moveFocusedToSpace(tonumber(arg))
    print(hs.json.encode({ moved = ok, index = tonumber(arg), error = err }))
  elseif verb == "retile" then
    wm.retileNow()
    print(hs.json.encode({ retiled = true }))
  elseif verb == "state" then
    local sid = hs.spaces.focusedSpace()
    local windows = {}
    for _, tree in pairs(wm.trees[sid] or {}) do
      for _, id in ipairs(bsp.windows(tree)) do windows[#windows + 1] = id end
    end
    -- lastFocus is {[screenId]=windowId}: a sparse integer-keyed table that hs.json.encode
    -- cannot serialise directly unless it happens to start at key 1, so it's flattened into an
    -- array of {screen=,id=} pairs, which is always a valid JSON array regardless of screen ids.
    local lastFocus = {}
    for screenId, id in pairs(wm.lastFocus[sid] or {}) do
      lastFocus[#lastFocus + 1] = { screen = screenId, id = id }
    end
    print(hs.json.encode({
      space = sid,
      index = spaces.indexForId(sid),
      windows = windows,
      lastFocus = lastFocus,
    }))
  elseif verb == "frames" then
    local sid = hs.spaces.focusedSpace()
    local out = {}
    for screenId, tree in pairs(wm.trees[sid] or {}) do
      local screen = hs.screen.find(screenId)
      if screen then
        local f = screen:frame()
        local rect = {
          x = f.x + cfg.padding, y = f.y + cfg.padding,
          w = f.w - 2 * cfg.padding, h = f.h - 2 * cfg.padding,
        }
        local entries = bsp.layout(tree, rect, cfg.gap)
        for _, entry in ipairs(entries) do
          local w = hs.window.get(entry.win)
          local app = w and w:application()
          local got = w and w:frame()
          -- want-versus-got is the point: proves the AX resize actually landed, not just that the
          -- maths is right. 1-point tolerance absorbs AX rounding.
          local ok = got ~= nil
            and math.abs(got.x - entry.rect.x) <= 1
            and math.abs(got.y - entry.rect.y) <= 1
            and math.abs(got.w - entry.rect.w) <= 1
            and math.abs(got.h - entry.rect.h) <= 1
          out[#out + 1] = {
            app = app and app:name() or nil,
            id = entry.win,
            screen = screen:name(),
            want = entry.rect,
            got = got and { x = got.x, y = got.y, w = got.w, h = got.h } or nil,
            ok = ok,
          }
        end
      end
    end
    print(hs.json.encode(out))
  else
    print(hs.json.encode({ error = "unknown verb" }))
  end
end

hs.alert.show("quilt loaded")
