-- quilt: window tracking, BSP application, and event/reconciliation. All private-API work is
-- delegated to quiltctl via spaces.lua; this module only touches public Hammerspoon APIs.
local cfg = require("config")
local bsp = require("bsp")
local spaces = require("spaces")

local M = {}

-- All state lives on M so nothing is garbage-collected and everything is stoppable.
M.trees = {}       -- [spaceId][screenId] = bsp node
M.lastFocus = {}   -- [spaceId][screenId] = window id
M.wf = nil
M.watcher = nil
M.reconciler = nil
M.retiler = nil
M.cfg = nil
M.dragTap = nil    -- hs.eventtap watching for drag-to-swap gestures
M.drag = nil       -- { sid, id, frame } for the window picked up by the current gesture, if any

-- The only space-id accessor. hs.spaces.watcher's callback argument is a legacy workspace number
-- in a different namespace and must be discarded in favour of this.
local function currentSpaceId()
  return hs.spaces.focusedSpace()
end

local function tileable(w)
  if w == nil or w:id() == nil then return false end
  if not w:isStandard() then return false end
  if not w:isVisible() then return false end
  if w:isMinimized() then return false end
  if w:isFullScreen() then return false end
  if w:screen() == nil then return false end -- frame overlaps no connected display (e.g. a
    -- position restored from a now-disconnected monitor); every caller assumes w:screen():id()
    -- succeeds, so this must be rejected here rather than left to blow up downstream.
  local app = w:application()
  local bid = app and app:bundleID()
  if bid and M.cfg.deny[bid] then return false end
  return true
end

-- Each connected screen tiles independently: every (space, screen) pair keeps its own BSP tree,
-- so a window's own screen decides which tree and which rect it belongs to.
local function innerRect(screen)
  local f = screen:frame()
  local p = M.cfg.padding
  return { x = f.x + p, y = f.y + p, w = f.w - 2 * p, h = f.h - 2 * p }
end

-- AX position/size sets are cross-process calls, and calling one on a window already at the
-- target rect is pure overhead with a real cost: apply() fires unconditionally on every Mission
-- Control space switch (M.watcher below) and on every reconcile() diff, not only when a window's
-- own geometry actually needs to change. So switching spaces and clicking into a window on the
-- landing space can race an AX setFrame against that same window's click-driven focus transition.
-- For a frameless/custom-titlebar window (no native chrome for the OS to repaint on its own,
-- e.g. a GPU-composited app drawing its own "focused" chrome) that race can leave the window
-- rendering its unfocused/inactive appearance until a later event forces a repaint. A half-point
-- epsilon absorbs float rounding from AX round-trips without masking a real, intentional move.
local EPS = 0.5
local function frameMatches(f, rect)
  return math.abs(f.x - rect.x) < EPS and math.abs(f.y - rect.y) < EPS
    and math.abs(f.w - rect.w) < EPS and math.abs(f.h - rect.h) < EPS
end

-- Called only for the currently active space: AX cannot size windows on a non-active space.
-- Never indexes hs.window.get() directly — it returns nil for closed or off-space windows, and a
-- thrown error inside a timer callback would abandon the remaining windows.
local function apply(spaceId)
  local screenTrees = M.trees[spaceId]
  if screenTrees == nil then return end
  for screenId, tree in pairs(screenTrees) do
    local screen = hs.screen.find(screenId)
    if screen ~= nil then
      local entries = bsp.layout(tree, innerRect(screen), M.cfg.gap)
      for _, entry in ipairs(entries) do
        local w = hs.window.get(entry.win)
        if w then
          if not frameMatches(w:frame(), entry.rect) then
            w:setFrame(entry.rect, 0)
          end
        else
          screenTrees[screenId] = bsp.remove(screenTrees[screenId], entry.win)
        end
      end
    end
  end
end

local function retile()
  M.retiler:start()
end

-- Drag-to-swap: dropping a dragged window onto a tiled window swaps their positions in the BSP
-- tree; quilt has no warp/insert-at-edge primitive yet (see README "Known limitations"). Watched
-- via raw mouse events rather than AX move notifications, which are unreliable on this Tahoe
-- build (see reconcile() below) — a leftMouseDown/leftMouseUp pair brackets every drag reliably
-- regardless.
--
-- A gesture only counts as a move if the watched window's frame actually changed between down
-- and up: this is what tells a real title-bar drag apart from a click, or an in-app drag (text
-- selection, a draggable divider) that never touches the window's own frame.
local function frameContains(f, pt)
  return pt.x >= f.x and pt.x <= f.x + f.w and pt.y >= f.y and pt.y <= f.y + f.h
end

-- Frontmost tiled window (present in any of `screenTrees`, excluding `excludeId`) whose frame
-- contains pt. Excluding the dragged window itself matters at drop time: it now sits wherever the
-- cursor is, so without the exclusion it would always match itself instead of the window
-- underneath. Searches every screen's tree in the space, not just the one under the cursor, so a
-- drag that crosses monitors still finds its drop target.
local function inAnyTree(screenTrees, id)
  for _, tree in pairs(screenTrees) do
    if bsp.contains(tree, id) then return true end
  end
  return false
end

local function topTiledWindowAt(screenTrees, pt, excludeId)
  for _, w in ipairs(hs.window.orderedWindows()) do
    if w:id() ~= excludeId and inAnyTree(screenTrees, w:id()) and frameContains(w:frame(), pt) then
      return w
    end
  end
  return nil
end

local function dragEventHandler(e)
  local etype = e:getType()
  local pt = e:location()

  if etype == hs.eventtap.event.types.leftMouseDown then
    M.drag = nil
    local sid = currentSpaceId()
    local screenTrees = M.trees[sid]
    local w = screenTrees and topTiledWindowAt(screenTrees, pt, nil)
    if w then
      M.drag = { sid = sid, screen = w:screen():id(), id = w:id(), frame = w:frame() }
    end
    return false
  end

  if etype == hs.eventtap.event.types.leftMouseUp then
    local drag = M.drag
    M.drag = nil
    if drag == nil then return false end

    local w = hs.window.get(drag.id)
    if w == nil then return false end

    local nowFrame = w:frame()
    local moved = nowFrame.x ~= drag.frame.x or nowFrame.y ~= drag.frame.y
    if not moved then return false end

    local screenTrees = M.trees[drag.sid]
    if screenTrees ~= nil then
      -- The swap primitive only rearranges leaves within one tree, so a drop onto a tiled window
      -- on a different screen is treated the same as a drop onto empty space: snap back.
      local target = topTiledWindowAt(screenTrees, pt, drag.id)
      if target and target:screen():id() == drag.screen then
        hs.printf("quilt: drag-swap %d <-> %d (space %d, screen %d)", drag.id, target:id(), drag.sid, drag.screen)
        screenTrees[drag.screen] = bsp.swap(screenTrees[drag.screen], drag.id, target:id())
      else
        hs.printf("quilt: drag-swap %d dropped on no same-screen tiled window (space %d), snapping back", drag.id, drag.sid)
      end
      if drag.sid == currentSpaceId() then apply(drag.sid) end
    end
    return false
  end

  return false
end

-- Builds a space's trees from its existing windows, back-most first per screen, so a space
-- visited for the first time adopts what is already there instead of showing only a newly
-- moved-in window. Each connected screen gets its own independent BSP tree.
local function bootstrapSpace(sid)
  local ordered = hs.window.orderedWindows()
  local idsByScreen = {}   -- [screenId] = { ids... }, back-most first
  local screenObjs = {}    -- [screenId] = hs.screen
  for i = #ordered, 1, -1 do
    local w = ordered[i]
    if tileable(w) then
      local screen = w:screen()
      local sc = screen:id()
      screenObjs[sc] = screen
      idsByScreen[sc] = idsByScreen[sc] or {}
      idsByScreen[sc][#idsByScreen[sc] + 1] = w:id()
    end
  end
  local trees, lastFocus = {}, {}
  for sc, ids in pairs(idsByScreen) do
    local tree, lastId = nil, nil
    for _, id in ipairs(ids) do
      tree = bsp.insert(tree, lastId, id, innerRect(screenObjs[sc]), M.cfg.gap)
      lastId = id
    end
    trees[sc] = tree
    lastFocus[sc] = lastId
  end
  M.trees[sid] = trees
  M.lastFocus[sid] = lastFocus
end

local function removeFromAllTrees(id)
  for sid, screenTrees in pairs(M.trees) do
    for sc, tree in pairs(screenTrees) do
      if bsp.contains(tree, id) then
        screenTrees[sc] = bsp.remove(tree, id)
      end
    end
    local lf = M.lastFocus[sid]
    if lf ~= nil then
      for sc, fid in pairs(lf) do
        if fid == id then lf[sc] = nil end
      end
    end
  end
end

-- Shared by windowCreated / windowUnminimized / windowUnfullscreened. A window can be created on
-- a space other than the active one, and filing it into the wrong tree is unrecoverable, so the
-- target tree is resolved from hs.spaces.windowSpaces(w), never assumed to be the current space.
local function handleCreatedOrRestored(w)
  if not tileable(w) then return end
  local ws = hs.spaces.windowSpaces(w)
  local target = ws and ws[1]
  if target == nil then return end
  if spaces.indexForId(target) == nil then return end
  local sc = w:screen():id()
  M.trees[target] = M.trees[target] or {}
  M.lastFocus[target] = M.lastFocus[target] or {}
  if bsp.contains(M.trees[target][sc], w:id()) then return end -- reconciliation may have inserted it first
  M.trees[target][sc] = bsp.insert(M.trees[target][sc], M.lastFocus[target][sc], w:id(), innerRect(w:screen()), M.cfg.gap)
  M.lastFocus[target][sc] = w:id()
  if target == currentSpaceId() then retile() end
end

local function reconcile()
  local sid = currentSpaceId()
  local changed = false
  M.trees[sid] = M.trees[sid] or {}
  M.lastFocus[sid] = M.lastFocus[sid] or {}

  -- Every currently tileable window's screen, as of right now: this is what each window's tree
  -- membership is checked against, so a window dragged to a different monitor gets relocated
  -- rather than stranded in its old screen's tree.
  local idToScreen, screenObjs = {}, {}
  for _, w in ipairs(hs.window.allWindows()) do
    if tileable(w) then
      local screen = w:screen()
      idToScreen[w:id()] = screen:id()
      screenObjs[screen:id()] = screen
    end
  end

  -- A minimised, fullscreened, closed, or moved-to-another-screen window fails this membership
  -- check (tileable(w), or tileable at its old screen), so an existence check alone would leave a
  -- permanent hole or a stale cross-screen entry.
  for sc, tree in pairs(M.trees[sid]) do
    for _, id in ipairs(bsp.windows(tree)) do
      if idToScreen[id] ~= sc then
        M.trees[sid][sc] = bsp.remove(M.trees[sid][sc], id)
        changed = true
      end
    end
  end

  local ids = {}
  for id in pairs(idToScreen) do ids[#ids + 1] = id end
  table.sort(ids) -- deterministic geometry, independent of hs.window.allWindows() ordering

  for _, id in ipairs(ids) do
    local sc = idToScreen[id]
    if not bsp.contains(M.trees[sid][sc], id) then
      M.trees[sid][sc] = bsp.insert(M.trees[sid][sc], M.lastFocus[sid][sc], id, innerRect(screenObjs[sc]), M.cfg.gap)
      M.lastFocus[sid][sc] = id
      changed = true
    end
  end

  if changed then retile() end
end

function M.start()
  M.cfg = cfg
  hs.window.animationDuration = 0

  bootstrapSpace(currentSpaceId())

  M.retiler = hs.timer.delayed.new(M.cfg.retileDelay, function() apply(currentSpaceId()) end)

  M.wf = hs.window.filter.new(tileable)
  M.wf:subscribe(hs.window.filter.windowCreated, handleCreatedOrRestored)
  M.wf:subscribe(hs.window.filter.windowUnminimized, handleCreatedOrRestored)
  M.wf:subscribe(hs.window.filter.windowUnfullscreened, handleCreatedOrRestored)
  M.wf:subscribe(hs.window.filter.windowUnhidden, handleCreatedOrRestored)
  M.wf:subscribe(hs.window.filter.windowDestroyed, function(w) removeFromAllTrees(w:id()); retile() end)
  M.wf:subscribe(hs.window.filter.windowMinimized, function(w) removeFromAllTrees(w:id()); retile() end)
  M.wf:subscribe(hs.window.filter.windowFullscreened, function(w) removeFromAllTrees(w:id()); retile() end)
  -- Focus is the one event common to every "surface an existing window" gesture (dock click on a
  -- hidden app that doesn't fire windowUnhidden reliably, Mission Control drag-then-click, a
  -- Window-menu pick, Cmd-Tab): running handleCreatedOrRestored here catches the window the
  -- instant it's focused instead of waiting up to reconcileInterval for the polling fallback.
  -- handleCreatedOrRestored bails out early once the window is already tracked, touching neither
  -- lastFocus nor the layout, so both still run unconditionally below: lastFocus must track every
  -- focus regardless, and the unconditional retile (cheap — apply() no-ops per window whose frame
  -- already matches) is what repairs a window that's tracked at the right tree position but the
  -- wrong on-screen frame, e.g. one that arrived via a cross-space move reconcile() already
  -- recorded without ever resizing (reconcile only diffs tree membership, never frame). This
  -- mirrors M.watcher below, which applies unconditionally on every space switch for the same
  -- reason.
  M.wf:subscribe(hs.window.filter.windowFocused, function(w)
    handleCreatedOrRestored(w)
    local sid = currentSpaceId()
    M.lastFocus[sid] = M.lastFocus[sid] or {}
    M.lastFocus[sid][w:screen():id()] = w:id()
    retile()
  end)

  M.dragTap = hs.eventtap.new(
    { hs.eventtap.event.types.leftMouseDown, hs.eventtap.event.types.leftMouseUp },
    dragEventHandler
  )
  M.dragTap:start()

  -- Always applies (not only when something is marked dirty): cheap and self-correcting, and the
  -- authoritative defence against Tahoe's unreliable AX notifications together with reconcile().
  M.watcher = hs.spaces.watcher.new(function()
    spaces.inventory()
    local sid = currentSpaceId()
    if M.trees[sid] == nil then bootstrapSpace(sid) end
    apply(sid)
  end)
  M.watcher:start()

  M.reconciler = hs.timer.doEvery(M.cfg.reconcileInterval, reconcile)

  apply(currentSpaceId())
end

-- Called from quilt.cli, never bound to a hotkey directly — quilt binds no keyboard shortcuts.
function M.moveFocusedToSpace(index)
  local w = hs.window.focusedWindow()
  if w == nil or not tileable(w) then
    return false, "window not tileable"
  end
  local src = currentSpaceId()
  local dst = spaces.idForIndex(index)
  if dst == nil then return false, "no space inventory" end
  if dst == src then return true, nil end

  local sc = w:screen():id()
  M.trees[src] = M.trees[src] or {}
  M.lastFocus[src] = M.lastFocus[src] or {}

  local fallbackTarget = M.lastFocus[src][sc]
  M.trees[src][sc] = bsp.remove(M.trees[src][sc], w:id())
  if M.lastFocus[src][sc] == w:id() then M.lastFocus[src][sc] = nil end
  apply(src)

  local ok, err = spaces.move(w:id(), index)
  if not ok then
    M.trees[src][sc] = bsp.insert(M.trees[src][sc], fallbackTarget, w:id(), innerRect(w:screen()), M.cfg.gap)
    apply(src)
    return false, err
  end

  -- Do not set frames on the destination now: AX cannot size windows on a non-active space. When
  -- the destination has no tree yet, leave it nil — the space watcher bootstraps it (picking up
  -- the moved window along with what was already there) the next time that space becomes active.
  if M.trees[dst] ~= nil then
    M.lastFocus[dst] = M.lastFocus[dst] or {}
    M.trees[dst][sc] = bsp.insert(M.trees[dst][sc], M.lastFocus[dst][sc], w:id(), innerRect(w:screen()), M.cfg.gap)
    M.lastFocus[dst][sc] = w:id()
  end
  return true, nil
end

function M.retileNow()
  apply(currentSpaceId())
end

return M
