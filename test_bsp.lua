-- quilt: pure-Lua behaviour lock for bsp.lua. Run with: lua test_bsp.lua
-- Proves the requested geometry: 1 window fullscreen, 2 windows 50/50, 3rd window splits the
-- focused pane into two quarters, and that the split axis follows aspect ratio (not hardcoded).

local bsp = require("bsp")

local failures = {}
local total = 0

local function almostEqualRect(a, b)
  return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h
end

local function rectStr(r)
  return string.format("{x=%s,y=%s,w=%s,h=%s}", tostring(r.x), tostring(r.y), tostring(r.w), tostring(r.h))
end

local function check(caseName, node, rect, gap, expected)
  total = total + 1
  local entries = bsp.layout(node, rect, gap)
  local byWin = {}
  for _, e in ipairs(entries) do
    byWin[e.win] = e.rect
  end
  for win, wantRect in pairs(expected) do
    local gotRect = byWin[win]
    if gotRect == nil then
      failures[#failures + 1] = string.format("%s: window %s missing from layout", caseName, tostring(win))
    elseif not almostEqualRect(gotRect, wantRect) then
      failures[#failures + 1] = string.format(
        "%s: window %s expected %s got %s", caseName, tostring(win), rectStr(wantRect), rectStr(gotRect))
    end
  end
end

-- ===== Case A: 1600x1000 screen inset by padding 8 -> inner rect 1584x984, gap 8 =====
local rectA = { x = 8, y = 8, w = 1584, h = 984 }
local gap = 8

local t1 = bsp.insert(nil, nil, 1, rectA, gap)
check("A.1window", t1, rectA, gap, { [1] = { x = 8, y = 8, w = 1584, h = 984 } })

local t2 = bsp.insert(t1, 1, 2, rectA, gap)
check("A.2windows", t2, rectA, gap, {
  [1] = { x = 8, y = 8, w = 788, h = 984 },
  [2] = { x = 804, y = 8, w = 788, h = 984 },
})

local t3 = bsp.insert(t2, 2, 3, rectA, gap)
check("A.3windows", t3, rectA, gap, {
  [1] = { x = 8, y = 8, w = 788, h = 984 },
  [2] = { x = 804, y = 8, w = 788, h = 488 },
  [3] = { x = 804, y = 504, w = 788, h = 488 },
})

local t4 = bsp.insert(t3, 3, 4, rectA, gap)
check("A.4windows", t4, rectA, gap, {
  [3] = { x = 804, y = 504, w = 390, h = 488 },
  [4] = { x = 1202, y = 504, w = 390, h = 488 },
})

-- bsp.remove of window 3 from the 3-window tree restores the exact 2-window layout.
total = total + 1
local restored = bsp.remove(t3, 3)
local restoredEntries = bsp.layout(restored, rectA, gap)
local expectRestored = { [1] = { x = 8, y = 8, w = 788, h = 984 }, [2] = { x = 804, y = 8, w = 788, h = 984 } }
if #restoredEntries ~= 2 then
  failures[#failures + 1] = string.format("A.remove: expected 2 windows after removing 3, got %d", #restoredEntries)
else
  for _, e in ipairs(restoredEntries) do
    local want = expectRestored[e.win]
    if want == nil or not almostEqualRect(e.rect, want) then
      failures[#failures + 1] = string.format("A.remove: window %s rect mismatch, got %s", tostring(e.win), rectStr(e.rect))
    end
  end
end

-- bsp.insert with a target absent from the tree appends against the last leaf without error.
total = total + 1
local ok, tAbsentTarget = pcall(bsp.insert, t2, 999, 3, rectA, gap)
if not ok then
  failures[#failures + 1] = "A.insert_absent_target: bsp.insert raised an error: " .. tostring(tAbsentTarget)
elseif not bsp.contains(tAbsentTarget, 3) then
  failures[#failures + 1] = "A.insert_absent_target: window 3 not present after insert with unknown target"
end

-- bsp.insert of an id already in the tree is a no-op (tree identical, #windows unchanged).
total = total + 1
local beforeCount = #bsp.windows(t2)
local tDup = bsp.insert(t2, 1, 2, rectA, gap)
local afterCount = #bsp.windows(tDup)
if afterCount ~= beforeCount then
  failures[#failures + 1] = string.format(
    "A.insert_duplicate: window count changed from %d to %d on duplicate insert", beforeCount, afterCount)
end
if not almostEqualRect(bsp.layout(tDup, rectA, gap)[1].rect, bsp.layout(t2, rectA, gap)[1].rect) then
  failures[#failures + 1] = "A.insert_duplicate: tree changed shape on duplicate insert"
end

-- bsp.swap exchanges two leaves in place: the rects stay put, only the window ids move.
total = total + 1
local tSwapped = bsp.swap(t4, 3, 4)
check("A.swap", tSwapped, rectA, gap, {
  [1] = { x = 8, y = 8, w = 788, h = 984 },
  [2] = { x = 804, y = 8, w = 788, h = 488 },
  [4] = { x = 804, y = 504, w = 390, h = 488 },
  [3] = { x = 1202, y = 504, w = 390, h = 488 },
})

-- bsp.swap with an id absent from the tree is a no-op.
total = total + 1
local tSwapAbsent = bsp.swap(t4, 3, 999)
check("A.swap_absent_id", tSwapAbsent, rectA, gap, {
  [3] = { x = 804, y = 504, w = 390, h = 488 },
})

-- bsp.swap of a window with itself is a no-op.
total = total + 1
local tSwapSelf = bsp.swap(t4, 3, 3)
check("A.swap_self", tSwapSelf, rectA, gap, {
  [3] = { x = 804, y = 504, w = 390, h = 488 },
  [4] = { x = 1202, y = 504, w = 390, h = 488 },
})

-- ===== Case B: 21:9 screen, documents that the split axis follows aspect ratio =====
-- rect = {x=8,y=8,w=3432,h=1424}, gap=8. Values below are derived from bsp.lua's own formula
-- (half = floor((rect.w - gap) / 2)), not assumed: top split halves the width to 1712/1712;
-- inserting the 3rd window at the focused right half (w=1712 > h=1424) again splits left/right,
-- halving 1712 to 852/852.
local rectB = { x = 8, y = 8, w = 3432, h = 1424 }
local b1 = bsp.insert(nil, nil, 1, rectB, gap)
local b2 = bsp.insert(b1, 1, 2, rectB, gap)
check("B.2windows", b2, rectB, gap, {
  [1] = { x = 8, y = 8, w = 1712, h = 1424 },
  [2] = { x = 1728, y = 8, w = 1712, h = 1424 },
})
local b3 = bsp.insert(b2, 2, 3, rectB, gap)
check("B.3windows_left_right_split", b3, rectB, gap, {
  [2] = { x = 1728, y = 8, w = 852, h = 1424 },
  [3] = { x = 2588, y = 8, w = 852, h = 1424 },
})

if #failures > 0 then
  for _, f in ipairs(failures) do
    print(f)
  end
  print(string.format("FAILED %d/%d", total - #failures, total))
  os.exit(1)
end

print(string.format("ok %d/%d", total, total))
os.exit(0)
