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
-- Omarchy gives every monitor its own block of ten workspace ids -- 1-10 on
-- one, 11-20 on the next -- and on every config reload, which every theme
-- change performs, it renumbers any workspace it finds on a monitor outside
-- that monitor's block. So desk N is workspace N *of each monitor's block*:
--
--   SUPER + 1  ->  left = ws 1   right = ws 11
--   SUPER + 2  ->  left = ws 2   right = ws 12
--   ...
--   SUPER + 5  ->  left = ws 5   right = ws 15
--
-- Which monitor owns which block is Omarchy's call, so the ids are always asked
-- of it rather than assumed. An Omarchy without per-monitor workspaces gets the
-- same layout: left 1-10, right 11-20.
--
-- The desk count is configurable in ~/.config/omarchy/unified-desks.conf --
-- a single number from 1 to 10.
--
-- TWO MONITORS ONLY. With any other count this module disables itself and
-- leaves Omarchy's stock workspace bindings untouched.

local M = {}

local DEFAULT_DESKS = 5
local MAX_DESKS = 10
local NUMBER_KEYS = 10 -- SUPER+1..0 is all the keyboard gives us
local REQUIRED_MONITORS = 2
local SLOTS = 10 -- workspace ids in each monitor's block

-- Omarchy's per-monitor workspaces (default/hypr/monitor-workspaces.lua), which
-- Omarchy loads before this file. Nil on an Omarchy that predates them.
local omarchy = o.workspaces
if type(omarchy) ~= "table" or type(omarchy.workspace_id) ~= "function"
  or type(omarchy.focus) ~= "function" or type(omarchy.move_window) ~= "function" then
  omarchy = nil
end

-- Desk count is read from an optional one-line config file. Absent, unreadable
-- or out of range all fall back to the default, so a bad edit degrades to
-- working defaults rather than a broken keymap.
local CONFIG_PATH = (os.getenv("HOME") or "") .. "/.config/omarchy/unified-desks.conf"

local function read_desk_count()
  local file = io.open(CONFIG_PATH, "r")
  if not file then return DEFAULT_DESKS end

  local line = file:read("*l")
  file:close()

  local count = tonumber(line and line:match("^%s*(%d+)"))
  if not count or count < 1 or count > MAX_DESKS then return DEFAULT_DESKS end
  return count
end

local DESKS = read_desk_count() -- desks; also the offset between a desk's halves

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

-- The workspace id of a desk on one monitor of the pair: side 1 is the left
-- monitor, side 2 the right. A desk must sit inside each monitor's own block,
-- or Omarchy's next reload renumbers it out from under the desk.
function M.workspace_on(monitors, side, desk)
  if omarchy then
    return omarchy.workspace_id(monitors[side], desk)
  end
  return (side - 1) * SLOTS + desk
end

-- Desk N's two workspaces, left then right.
function M.workspaces_for(desk, monitors)
  monitors = monitors or M.ordered_monitors()
  return M.workspace_on(monitors, 1, desk), M.workspace_on(monitors, 2, desk)
end

-- The desk a number key (1 to 10) switches to, or nil when the key is left to
-- Omarchy. Keys past the desk count wrap round once, so with five desks
-- SUPER+6..0 reach desks 1..5 as well.
function M.desk_for_key(key_number)
  if key_number < 1 or key_number > DESKS * REQUIRED_MONITORS then return nil end
  if key_number > DESKS then return key_number - DESKS end
  return key_number
end

-- Pin each half of a desk to its monitor. Without this a workspace can be
-- created on the wrong screen, and switching to it drags focus across.
function M.apply_workspace_rules()
  if not M.active() then return end

  local monitors = M.ordered_monitors()
  local left, right = monitors[1].name, monitors[2].name

  for desk = 1, DESKS do
    local left_ws, right_ws = M.workspaces_for(desk, monitors)
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
  local left_ws, right_ws = M.workspaces_for(desk, monitors)

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
  local focused = hl.get_active_monitor()
  local side = 1
  if focused and focused.name == monitors[2].name then
    side = 2
  end

  local target = M.workspace_on(monitors, side, desk)
  hl.dispatch(hl.dsp.window.move({ workspace = tostring(target), follow = follow ~= false }))
end

-- ---------------------------------------------------------------------------
-- Key handlers
--
-- These always fall back to stock behaviour when the desk model is unavailable
-- (monitor unplugged, docked, wrong count). The stock workspace binds are
-- replaced at load, so without this fallback losing a monitor would leave the
-- machine with no working workspace keys at all.
--
-- Stock means Omarchy's own number-key actions: with per-monitor workspaces,
-- SUPER+3 is the third workspace of the focused monitor's block, not workspace
-- 3. They are built once, here, because every call to o.workspaces.focus()
-- registers another action with Omarchy's keybindings menu.
-- ---------------------------------------------------------------------------

local stock = {}
if omarchy then
  for number = 1, NUMBER_KEYS do
    stock[number] = {
      focus = omarchy.focus(number),
      move = omarchy.move_window(number),
      move_silently = omarchy.move_window(number, false),
    }
  end
end

function M.focus_workspace(number)
  if M.active() then
    local desk = M.desk_for_key(number)
    if desk then
      M.switch_desk(desk)
      return
    end
  end

  if stock[number] then
    stock[number].focus()
    return
  end

  hl.dispatch(hl.dsp.focus({ workspace = tostring(number) }))
end

function M.move_window(number, follow)
  if M.active() then
    local desk = M.desk_for_key(number)
    if desk then
      M.move_to_desk(desk, follow)
      return
    end
  end

  if stock[number] then
    if follow == false then
      stock[number].move_silently()
    else
      stock[number].move()
    end
    return
  end

  hl.dispatch(hl.dsp.window.move({
    workspace = tostring(number),
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

-- Iterate the ten number keys, which are the only keys Omarchy binds to
-- workspaces (SUPER + code:10..19). Deriving keycodes from desk or workspace
-- numbers instead would run past the number row onto `-`, `=`, backspace, tab.
--
-- A key is claimed only when it maps to a desk. Any key beyond 2 x DESKS keeps
-- Omarchy's stock binding, so a smaller desk count simply leaves the spare
-- number keys alone.
--
-- Binding regardless of monitor count is deliberate: the handlers fall back to
-- stock behaviour when the desk model is unavailable, so unplugging a monitor
-- degrades gracefully instead of leaving the machine with no workspace keys.
--
-- Hyprland fires *every* bind registered on a chord, so stock binds are removed
-- before ours are added.
for key_number = 1, NUMBER_KEYS do
  local desk = M.desk_for_key(key_number)

  if desk then
    local key = "code:" .. tostring(key_number + 9)
    local label = "Switch both monitors to desk " .. desk

    hl.unbind("SUPER + " .. key)
    o.bind("SUPER + " .. key, label, function() M.focus_workspace(key_number) end)

    hl.unbind("SUPER + SHIFT + " .. key)
    o.bind("SUPER + SHIFT + " .. key, "Move window to desk " .. desk,
      function() M.move_window(key_number, true) end)

    hl.unbind("SUPER + SHIFT + ALT + " .. key)
    o.bind("SUPER + SHIFT + ALT + " .. key, "Move window silently to desk " .. desk,
      function() M.move_window(key_number, false) end)
  end
end

-- Re-pin workspaces when displays change. Switching itself resolves monitors
-- at press time, so only the rules need refreshing.
hl.on("monitor.added", function() M.apply_workspace_rules() end)
hl.on("monitor.removed", function() M.apply_workspace_rules() end)
hl.on("monitor.layout_changed", function() M.apply_workspace_rules() end)

return M
