-- quilt: pure binary-space-partition tree. No Hammerspoon dependency; testable with plain Lua.
--
-- Node shapes:
--   leaf  = { win = <integer window id> }
--   split = { axis = "v" | "h", a = <node>, b = <node> }   -- "v" = vertical divider => left|right
--
-- Equal splits only; there is no ratio field and no resize command in this PoC. The split axis
-- follows the pane's aspect ratio (longer dimension), so the requested "third window fills the
-- lower-right quarter" shape holds while the right half is taller than wide, and flips to a
-- left/right split on a wide-enough pane (see test_bsp.lua Case B).

local M = {}

-- bsp.layout(node, rect, gap) -> { {win=<id>, rect={x=,y=,w=,h=}}, ... }  (depth-first)
function M.layout(node, rect, gap)
  if node == nil then
    return {}
  end
  if node.win ~= nil then
    return { { win = node.win, rect = { x = rect.x, y = rect.y, w = rect.w, h = rect.h } } }
  end

  local aRect, bRect
  if node.axis == "v" then
    local half = math.floor((rect.w - gap) / 2)
    aRect = { x = rect.x, y = rect.y, w = half, h = rect.h }
    bRect = { x = rect.x + half + gap, y = rect.y, w = rect.w - half - gap, h = rect.h }
  else -- "h"
    local half = math.floor((rect.h - gap) / 2)
    aRect = { x = rect.x, y = rect.y, w = rect.w, h = half }
    bRect = { x = rect.x, y = rect.y + half + gap, w = rect.w, h = rect.h - half - gap }
  end

  local out = M.layout(node.a, aRect, gap)
  local bOut = M.layout(node.b, bRect, gap)
  for _, entry in ipairs(bOut) do
    out[#out + 1] = entry
  end
  return out
end

-- bsp.contains(node, win) -> boolean
function M.contains(node, win)
  if node == nil then
    return false
  end
  if node.win ~= nil then
    return node.win == win
  end
  return M.contains(node.a, win) or M.contains(node.b, win)
end

-- bsp.windows(node) -> {ids...}  (depth-first)
function M.windows(node)
  if node == nil then
    return {}
  end
  if node.win ~= nil then
    return { node.win }
  end
  local out = M.windows(node.a)
  local bOut = M.windows(node.b)
  for _, id in ipairs(bOut) do
    out[#out + 1] = id
  end
  return out
end

-- bsp.insert(node, targetWin, newWin, rect, gap) -> node
-- Insert is idempotent: inserting an id already present returns the tree unchanged.
-- When node is empty, the new window becomes the sole leaf. Otherwise the leaf matching
-- targetWin (or, when targetWin is nil/absent, the LAST leaf in depth-first order) is replaced
-- by a split whose first child is the old leaf and whose second child is the new window. The
-- split axis is chosen from the leaf's own rect: "v" (left/right) when wider than tall, else "h".
function M.insert(node, targetWin, newWin, rect, gap)
  if M.contains(node, newWin) then
    return node
  end
  if node == nil then
    return { win = newWin }
  end

  local entries = M.layout(node, rect, gap)
  local chosen = entries[#entries]
  for _, entry in ipairs(entries) do
    if entry.win == targetWin then
      chosen = entry
      break
    end
  end

  local axis = (chosen.rect.w > chosen.rect.h) and "v" or "h"
  local newLeaf = { win = newWin }

  local function replace(n)
    if n.win ~= nil then
      if n.win == chosen.win then
        return { axis = axis, a = { win = n.win }, b = newLeaf }
      end
      return n
    end
    return { axis = n.axis, a = replace(n.a), b = replace(n.b) }
  end

  return replace(node)
end

-- bsp.remove(node, win) -> node|nil
-- Removing the only leaf returns nil. An unknown win returns the tree unchanged. Removing one
-- leaf of a split promotes the surviving sibling subtree in place of the split.
function M.remove(node, win)
  if node == nil then
    return nil
  end
  if node.win ~= nil then
    if node.win == win then
      return nil
    end
    return node
  end

  if M.contains(node.a, win) then
    if node.a.win == win then
      return node.b
    end
    return { axis = node.axis, a = M.remove(node.a, win), b = node.b }
  elseif M.contains(node.b, win) then
    if node.b.win == win then
      return node.a
    end
    return { axis = node.axis, a = node.a, b = M.remove(node.b, win) }
  end
  return node
end

-- bsp.swap(node, winA, winB) -> node
-- Exchanges the leaves holding winA and winB, keeping every split and gap untouched. A missing
-- id, or winA == winB, leaves the tree unchanged — this is the primitive drag-to-swap in wm.lua
-- uses when a drag ends on top of another tiled window.
local function swapLeaves(node, winA, winB)
  if node.win ~= nil then
    if node.win == winA then return { win = winB } end
    if node.win == winB then return { win = winA } end
    return node
  end
  return { axis = node.axis, a = swapLeaves(node.a, winA, winB), b = swapLeaves(node.b, winA, winB) }
end

function M.swap(node, winA, winB)
  if node == nil or winA == winB then
    return node
  end
  if not (M.contains(node, winA) and M.contains(node, winB)) then
    return node
  end
  return swapLeaves(node, winA, winB)
end

return M
