-- quilt: Lua-side bridge to the quiltctl helper. Every private-API operation is delegated to the
-- compiled helper; this module only shells out, caches, and decodes.
local cfg = require("config")

local M = {}
local cache = nil

-- Refreshed on space-changed events (wm.lua's space watcher) and by M.ensure. On failure, keeps
-- the previous cache rather than clearing it, so a transient quiltctl hiccup does not blank out
-- every accessor mid-session.
function M.inventory()
  local output, _, _, rc = hs.execute(cfg.helper .. " spaces", true)
  if rc ~= 0 then
    hs.printf("quilt: quiltctl spaces failed (rc=%s): %s", tostring(rc), tostring(output))
    return nil
  end
  local ok, decoded = pcall(hs.json.decode, output)
  if not ok or decoded == nil then
    hs.printf("quilt: quiltctl spaces returned undecodable output: %s", tostring(output))
    return nil
  end
  cache = decoded
  return cache
end

function M.idForIndex(i)
  if cache == nil then return nil end
  for _, entry in ipairs(cache.spaces or {}) do
    if entry.index == i then return entry.id end
  end
  return nil
end

function M.indexForId(sid)
  if cache == nil then return nil end
  for _, entry in ipairs(cache.spaces or {}) do
    if entry.id == sid then return entry.index end
  end
  return nil
end

function M.currentId()
  if cache ~= nil and cache.current ~= nil then return cache.current end
  return hs.spaces.focusedSpace()
end

-- Returns ok, err — never indexes the CLI output without first checking it decoded and
-- the move actually reported success.
function M.move(wid, index)
  local cmd = string.format("%s move %d %d", cfg.helper, wid, index)
  local output, _, _, rc = hs.execute(cmd, true)
  if rc ~= 0 then return false, output end
  local ok, decoded = pcall(hs.json.decode, output)
  if not ok or decoded == nil then return false, output end
  if decoded.moved ~= true then return false, output end
  return true, nil
end

-- Called once at load. Never aborts config load: exit 2 (unsupported on this build) is a warning,
-- any other non-zero is an error, both are logged and swallowed.
function M.ensure(count)
  local cmd = string.format("%s ensure %d", cfg.helper, count)
  local output, _, _, rc = hs.execute(cmd, true)
  local ok, decoded = pcall(hs.json.decode, output)
  local created = (ok and decoded and decoded.created) or 0
  local total = (ok and decoded and decoded.spaces and #decoded.spaces) or 0
  if rc == 0 then
    hs.printf("quilt: ensure(%d) ok — %d spaces present, %d created", count, total, created)
    if ok then cache = decoded end
  elseif rc == 2 then
    hs.printf("quilt: ensure(%d) unsupported on this build — %d spaces present, continuing", count, total)
  else
    hs.printf("quilt: ensure(%d) failed (rc=%s): %s", count, tostring(rc), tostring(output))
  end
end

return M
