-- Unified Desks -- two-monitor paired workspaces for Hyprland / Omarchy.
--
-- Managed by the io.github.azcoov.unified-desks Omarchy plugin. Edits here are replaced
-- on plugin update; change settings through the plugin instead.
--
-- Hyprland binds each workspace to exactly one monitor, so a single workspace
-- can never span two screens. This treats a *pair* of workspaces as one "desk"
-- and moves both monitors together, so a two-monitor rig behaves like one
-- desktop rather than two independent screens.
--
--   SUPER + 1  ->  left = ws 1   right = ws 6
--   SUPER + 2  ->  left = ws 2   right = ws 7
--   ...
--   SUPER + 5  ->  left = ws 5   right = ws 10
--
-- TWO MONITORS ONLY. With any other count this module disables itself and
-- leaves Omarchy's stock workspace bindings untouched.

local M = {}

local DESKS = 5 -- desks; also the offset between a desk's two halves
local REQUIRED_MONITORS = 2

-- Hyprland reports position as either a table or a packed value depending on
-- version, so normalise before sorting monitors left-to-right.
local function monitor_x(monitor)
  local position = monitor.position
  if type(position) == "table" then
    return tonumber(position.x or position[1]) or 0
  end
  return tonumber(position) or 0
end

-- Connected, non-mirrored monitors ordered left to right by X position.
-- Resolved on every call so a hotplug needs no rebinding.
--
-- hl.get_monitors() returns only enabled outputs and HL.Monitor exposes no
-- `disabled` field today (it reads as nil), but the guard is kept so a future
-- Hyprland that does surface one cannot silently break the monitor count.
function M.ordered_monitors()
  local ordered = {}
  for _, monitor in ipairs(hl.get_monitors() or {}) do
    if not monitor.disabled and not monitor.is_mirror then
      table.insert(ordered, monitor)
    end
  end

  table.sort(ordered, function(a, b) return monitor_x(a) < monitor_x(b) end)
  return ordered
end

function M.active()
  return #M.ordered_monitors() == REQUIRED_MONITORS
end

-- Desk N occupies workspace N on the left monitor and N + DESKS on the right.
function M.workspaces_for(desk)
  return desk, desk + DESKS
end

-- Which desk a workspace id belongs to, or nil if it is outside the range.
function M.desk_of(workspace_id)
  if workspace_id < 1 or workspace_id > DESKS * REQUIRED_MONITORS then return nil end
  if workspace_id > DESKS then return workspace_id - DESKS end
  return workspace_id
end

-- Pin each half of a desk to its monitor. Without this a workspace can be
-- created on the wrong screen, and switching to it drags focus across.
function M.apply_workspace_rules()
  if not M.active() then return end

  local monitors = M.ordered_monitors()
  local left, right = monitors[1].name, monitors[2].name

  for desk = 1, DESKS do
    local left_ws, right_ws = M.workspaces_for(desk)
    hl.workspace_rule({ workspace = tostring(left_ws), monitor = left, default = (desk == 1) })
    hl.workspace_rule({ workspace = tostring(right_ws), monitor = right, default = (desk == 1) })
  end
end

-- Switching a monitor that is not focused silently no-ops in Hyprland 0.56
-- (monitor:set_workspace returns success but does nothing), so each half is
-- driven by focusing that monitor first, then switching it.
function M.switch_desk(desk)
  if not M.active() then return end
  if desk < 1 or desk > DESKS then return end

  local monitors = M.ordered_monitors()
  local left, right = monitors[1].name, monitors[2].name
  local left_ws, right_ws = M.workspaces_for(desk)

  local focused = hl.get_active_monitor()
  local return_to = focused and focused.name or left

  hl.dispatch(hl.dsp.focus({ monitor = right }))
  hl.dispatch(hl.dsp.focus({ workspace = tostring(right_ws) }))
  hl.dispatch(hl.dsp.focus({ monitor = left }))
  hl.dispatch(hl.dsp.focus({ workspace = tostring(left_ws) }))

  -- Leave focus where it was, so switching desks does not teleport the
  -- keyboard to the left screen every time.
  if return_to ~= left then
    hl.dispatch(hl.dsp.focus({ monitor = return_to }))
  end
end

-- Move the focused window to this desk's half on the monitor it already lives
-- on. Stock SUPER+SHIFT+N always targets ws N, which on the right monitor would
-- fling the window to the left screen.
function M.move_to_desk(desk, follow)
  if not M.active() then return end
  if desk < 1 or desk > DESKS then return end

  local monitors = M.ordered_monitors()
  local left_ws, right_ws = M.workspaces_for(desk)

  local focused = hl.get_active_monitor()
  local target = left_ws
  if focused and focused.name == monitors[2].name then
    target = right_ws
  end

  hl.dispatch(hl.dsp.window.move({ workspace = tostring(target), follow = follow ~= false }))
end

-- ---------------------------------------------------------------------------
-- Key handlers
--
-- These always fall back to plain per-workspace behaviour when the desk model
-- is unavailable (monitor unplugged, docked, wrong count). The stock workspace
-- binds are replaced at load, so without this fallback losing a monitor would
-- leave the machine with no working workspace keys at all.
-- ---------------------------------------------------------------------------

function M.focus_workspace(workspace_id)
  if M.active() then
    local desk = M.desk_of(workspace_id)
    if desk then
      M.switch_desk(desk)
      return
    end
  end

  hl.dispatch(hl.dsp.focus({ workspace = tostring(workspace_id) }))
end

function M.move_window(workspace_id, follow)
  if M.active() then
    local desk = M.desk_of(workspace_id)
    if desk then
      M.move_to_desk(desk, follow)
      return
    end
  end

  hl.dispatch(hl.dsp.window.move({
    workspace = tostring(workspace_id),
    follow = follow ~= false,
  }))
end


-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

M.desks = DESKS

-- Exported so the bar widget and any user script can drive a desk:
--   hyprctl eval 'o.unified_desks.switch_desk(3)'
o.unified_desks = M

M.apply_workspace_rules()

-- Every workspace key is rebound, including 6..0 -- those are the right-hand
-- halves of a desk, so pressing one takes you to the desk that contains it
-- rather than desynchronising the pair or sitting there dead.
--
-- Binding unconditionally (rather than only when two monitors are present)
-- is deliberate: the handlers fall back to stock behaviour when the desk model
-- is unavailable, so unplugging a monitor degrades gracefully instead of
-- leaving the machine with no workspace keys.
--
-- Omarchy binds SUPER + code:10..19 to workspaces 1..10. Hyprland fires *every*
-- bind registered on a chord, so stock binds must be removed first.
for ws = 1, DESKS * REQUIRED_MONITORS do
  local key = "code:" .. tostring(ws + 9)
  local desk = M.desk_of(ws)
  local left_ws, right_ws = M.workspaces_for(desk)
  local label = "Desk " .. desk .. " (ws " .. left_ws .. " + ws " .. right_ws .. ")"

  hl.unbind("SUPER + " .. key)
  o.bind("SUPER + " .. key, label, function() M.focus_workspace(ws) end)

  hl.unbind("SUPER + SHIFT + " .. key)
  o.bind("SUPER + SHIFT + " .. key, "Move window to desk " .. desk,
    function() M.move_window(ws, true) end)

  hl.unbind("SUPER + SHIFT + ALT + " .. key)
  o.bind("SUPER + SHIFT + ALT + " .. key, "Move window silently to desk " .. desk,
    function() M.move_window(ws, false) end)
end

-- Re-pin workspaces when displays change. Switching itself resolves monitors
-- at press time, so only the rules need refreshing.
hl.on("monitor.added", function() M.apply_workspace_rules() end)
hl.on("monitor.removed", function() M.apply_workspace_rules() end)
hl.on("monitor.layout_changed", function() M.apply_workspace_rules() end)

return M
