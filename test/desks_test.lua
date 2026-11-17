#!/usr/bin/env lua
-- Regression tests for Unified Desks against Omarchy's per-monitor workspaces.
--
-- Runs the real hypr/unified-desks.lua and, when it is installed, Omarchy's real
-- default/hypr/monitor-workspaces.lua against a small fake of Hyprland's Lua
-- API, so the two modules meet the way they do in a live session -- including
-- the config reload that every theme change performs.
--
--   lua test/desks_test.lua
--
-- Nothing here talks to a live Hyprland or touches ~/.config: Omarchy's state
-- files go to a fresh temp directory, and the plugin's config read is answered
-- by the test instead of the filesystem.

-- The repository root, wherever the test is run from.
local ROOT = (arg[0]:match("^(.*)/[^/]*$") or ".") .. "/.."
local OMARCHY_MODULE = (os.getenv("OMARCHY_PATH") or "/usr/share/omarchy")
  .. "/default/hypr/monitor-workspaces.lua"

local function exists(path)
  local file = io.open(path, "r")
  if file then file:close() end
  return file ~= nil
end

local HAVE_OMARCHY = exists(OMARCHY_MODULE)

-- The plugin reads its desk count from ~/.config; answer that here, and refuse
-- any other ~/.config read outright.
local real_open = io.open
local desk_config = nil
io.open = function(path, mode)
  if path:find("/.config/", 1, true) then
    if desk_config and path:match("unified%-desks%.conf$") then
      return { read = function() return desk_config end, close = function() end }
    end
    return nil
  end
  return real_open(path, mode)
end

-- ---------------------------------------------------------------------------
-- Fake Hyprland
-- ---------------------------------------------------------------------------

local world

local function find_monitor(name)
  for _, monitor in ipairs(world.monitors) do
    if monitor.name == name then return monitor end
  end
end

local monitor_view, workspace_view

workspace_view = function(id)
  id = tonumber(id)
  local workspace = id and world.workspaces[id]
  if not workspace then return nil end

  return setmetatable({ id = id, name = tostring(id), special = false, windows = workspace.windows }, {
    __index = function(_, key)
      if key == "monitor" then return monitor_view(find_monitor(workspace.monitor)) end
    end,
  })
end

local function lowest_free_id()
  local id = 1
  while world.workspaces[id] do id = id + 1 end
  return id
end

-- Hyprland destroys an empty workspace once no monitor shows it.
local function collect(id)
  local workspace = id and world.workspaces[id]
  if not workspace or workspace.windows > 0 then return end
  for _, shown in pairs(world.active) do
    if shown == id then return end
  end
  world.workspaces[id] = nil
end

local function show(monitor_name, id)
  local previous = world.active[monitor_name]
  world.active[monitor_name] = id
  if previous ~= id then collect(previous) end
end

-- A new workspace opens on the monitor a rule names, else the focused one.
local function ensure(id)
  if not world.workspaces[id] then
    world.workspaces[id] = { windows = 0, monitor = world.rules[tostring(id)] or world.focused }
  end
  return world.workspaces[id]
end

local function focus_workspace(id)
  local workspace = ensure(id)
  world.focused = workspace.monitor
  show(workspace.monitor, id)
end

local function move_workspace(id, monitor_name)
  local workspace = world.workspaces[id]
  if not workspace or workspace.monitor == monitor_name then return end

  local from = workspace.monitor
  workspace.monitor = monitor_name

  -- The monitor it left shows another of its own, or a fresh one.
  if world.active[from] == id then
    local other = nil
    for other_id, candidate in pairs(world.workspaces) do
      if candidate.monitor == from and other_id ~= id and (not other or other_id < other) then
        other = other_id
      end
    end
    if not other then
      other = lowest_free_id()
      world.workspaces[other] = { windows = 0, monitor = from }
    end
    world.active[from] = other
  end

  show(monitor_name, id)
end

local function change_id(old, new)
  local workspace = world.workspaces[old]
  if not workspace or world.workspaces[new] then return end

  world.workspaces[new], world.workspaces[old] = workspace, nil
  for name, shown in pairs(world.active) do
    if shown == old then world.active[name] = new end
  end
  table.insert(world.renumbered, old .. "->" .. new)
end

-- The "active window" is one on the focused monitor's visible workspace.
local function move_window(id, follow)
  local from = world.workspaces[world.active[world.focused]]
  if not from or from.windows == 0 then return end

  local target = ensure(id)
  from.windows = from.windows - 1
  target.windows = target.windows + 1
  if follow then focus_workspace(id) end
end

monitor_view = function(monitor)
  if not monitor then return nil end

  return setmetatable({
    id = monitor.id,
    name = monitor.name,
    description = monitor.description,
    position = { x = monitor.x, y = 0 },
    is_mirror = false,
    focused = world.focused == monitor.name,
    set_workspace = function(_, args)
      local id = tonumber(args.workspace)
      if world.workspaces[id] then show(monitor.name, id) end
    end,
  }, {
    __index = function(_, key)
      if key == "active_workspace" then return workspace_view(world.active[monitor.name]) end
    end,
  })
end

local function dispatcher(path)
  return setmetatable({}, {
    __index = function(_, key) return dispatcher(path and (path .. "." .. key) or key) end,
    __call = function(_, args) return { op = path, args = args or {} } end,
  })
end

local function dispatch(action)
  if type(action) == "function" then return action() end

  local op, args = action.op, action.args
  if op == "focus" and args.monitor then
    if find_monitor(args.monitor) then world.focused = args.monitor end
  elseif op == "focus" and args.workspace then
    focus_workspace(tonumber(args.workspace))
  elseif op == "workspace.change_id" then
    change_id(tonumber(args.workspace), tonumber(args.id))
  elseif op == "workspace.move" and args.workspace then
    move_workspace(tonumber(args.workspace), args.monitor)
  elseif op == "window.move" and args.workspace then
    move_window(tonumber(args.workspace), args.follow ~= false)
  else
    error("fake Hyprland has no dispatcher " .. tostring(op))
  end
end

local function install_globals()
  hl = {
    dsp = dispatcher(nil),
    dispatch = dispatch,
    get_monitors = function()
      local out = {}
      for _, monitor in ipairs(world.monitors) do out[#out + 1] = monitor_view(monitor) end
      return out
    end,
    get_monitor = function(name) return monitor_view(find_monitor(name)) end,
    get_active_monitor = function() return monitor_view(find_monitor(world.focused)) end,
    get_workspace = workspace_view,
    get_workspaces = function()
      local ids = {}
      for id in pairs(world.workspaces) do ids[#ids + 1] = id end
      table.sort(ids)
      local out = {}
      for _, id in ipairs(ids) do out[#out + 1] = workspace_view(id) end
      return out
    end,
    get_active_window = function() return nil end,
    get_window = function() return nil end,
    workspace_rule = function(rule)
      world.rules[rule.workspace] = rule.monitor
      if rule.default then world.defaults[rule.monitor] = tonumber(rule.workspace) end
    end,
    on = function(event, fn)
      world.handlers[event] = world.handlers[event] or {}
      table.insert(world.handlers[event], fn)
    end,
    timer = function(fn) fn() end,
    unbind = function(keys) world.binds[keys] = nil end,
  }

  o = {
    bind_expressions = {},
    shell_quote = function(value) return "'" .. (value:gsub("'", "'\\''")) .. "'" end,
    bind = function(keys, _, action)
      world.binds[keys] = world.binds[keys] or {}
      table.insert(world.binds[keys], action)
    end,
  }
end

local function fire(event, ...)
  for _, fn in ipairs(world.handlers[event] or {}) do fn(...) end
end

-- Evaluate the config: Omarchy's defaults first, the plugin last, as
-- hyprland.lua orders them. A reload starts the Lua side over the same way.
local function load_config()
  world.handlers, world.binds, world.rules, world.defaults = {}, {}, {}, {}
  install_globals()
  if world.omarchy then dofile(OMARCHY_MODULE) end
  dofile(ROOT .. "/hypr/unified-desks.lua")
end

local state_dirs = {}

local function new_state_dir(blocks)
  local handle = assert(io.popen("mktemp -d"))
  local dir = handle:read("*l")
  handle:close()
  assert(dir and dir:match("^/"), "mktemp -d failed")
  assert(not dir:find("/.config/", 1, true), "state dir must not be under ~/.config")
  assert(os.execute("mkdir '" .. dir .. "/omarchy'"))
  table.insert(state_dirs, dir)

  if blocks then
    local file = assert(real_open(dir .. "/omarchy/monitor-workspaces", "w"))
    file:write(blocks)
    file:close()
  end

  return dir
end

-- Start a session: monitors come up on their default-rule workspace, or the
-- lowest free number, and Omarchy reconciles once Hyprland has started.
local function start(monitors, options)
  options = options or {}
  world = {
    monitors = monitors,
    workspaces = {},
    active = {},
    focused = monitors[1].name,
    renumbered = {},
    omarchy = options.omarchy ~= false and HAVE_OMARCHY,
  }
  desk_config = options.desks and tostring(options.desks) or nil
  package.loaded["default.hypr.paths"] = { state_home = new_state_dir(options.blocks) }

  load_config()

  for _, monitor in ipairs(world.monitors) do
    local id = world.defaults[monitor.name]
    if not id or world.workspaces[id] then id = lowest_free_id() end
    world.workspaces[id] = { windows = 0, monitor = monitor.name }
    world.active[monitor.name] = id
  end

  fire("hyprland.start")
end

-- What `hyprctl reload` does, and so what every `omarchy theme set` does.
local function reload()
  load_config()
  fire("config.reloaded")
end

local function press(keys)
  local actions = world.binds[keys]
  assert(actions and #actions > 0, "nothing bound to " .. keys)
  for _, action in ipairs(actions) do dispatch(action) end
end

local function open_window_on(monitor_name)
  world.workspaces[world.active[monitor_name]].windows =
    world.workspaces[world.active[monitor_name]].windows + 1
end

-- The slot a workspace id fills in its monitor's block of ten, which is the
-- desk it belongs to.
local function slot_of(id)
  return (id - 1) % 10 + 1
end

local function shown(monitor_name)
  local id = world.active[monitor_name]
  return id, world.workspaces[id]
end

-- Two identical panels side by side that report no serial, so Omarchy can only
-- tell them apart by connector.
local function twin_panels()
  return {
    { id = 0, name = "DP-1", description = "Generic Ultrawide", x = 0 },
    { id = 1, name = "DP-2", description = "Generic Ultrawide", x = 3440 },
  }
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

local failures, ran, skipped = 0, 0, 0

local function test(name, fn, needs_omarchy)
  if needs_omarchy and not HAVE_OMARCHY then
    skipped = skipped + 1
    print("skip  " .. name .. " (no " .. OMARCHY_MODULE .. ")")
    return
  end

  ran = ran + 1
  local ok, err = pcall(fn)
  if ok then
    print("ok    " .. name)
  else
    failures = failures + 1
    print("FAIL  " .. name .. "\n      " .. tostring(err))
  end
end

local function eq(actual, expected, what)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", what, tostring(expected), tostring(actual)), 2)
  end
end

test("a theme-change reload leaves every desk's windows where they were", function()
  start(twin_panels())

  for desk = 1, 3 do
    o.unified_desks.switch_desk(desk)
    open_window_on("DP-1")
    open_window_on("DP-2")
  end

  reload()
  eq(table.concat(world.renumbered, " "), "", "workspaces Omarchy renumbered")

  for desk = 1, 3 do
    o.unified_desks.switch_desk(desk)
    local left_id, left = shown("DP-1")
    local right_id, right = shown("DP-2")
    eq(left and left.windows, 1, "desk " .. desk .. " left (ws " .. left_id .. ") windows")
    eq(right and right.windows, 1, "desk " .. desk .. " right (ws " .. right_id .. ") windows")
  end
end, true)

test("desks use each monitor's own Omarchy block, whichever block that is", function()
  -- The left screen happens to own the second block here.
  start({
    { id = 0, name = "DP-1", description = "Left panel", x = 0 },
    { id = 1, name = "DP-2", description = "Right panel", x = 2560 },
  }, { blocks = "0\tDP-2\tRight panel\n1\tDP-1\tLeft panel\n" })

  o.unified_desks.switch_desk(2)
  eq(shown("DP-1"), 12, "left half of desk 2")
  eq(shown("DP-2"), 2, "right half of desk 2")

  open_window_on("DP-1")
  open_window_on("DP-2")
  reload()
  eq(table.concat(world.renumbered, " "), "", "workspaces Omarchy renumbered")
end, true)

test("SUPER+SHIFT+N keeps a window on its own monitor's half of the desk", function()
  start(twin_panels())
  o.unified_desks.switch_desk(1)
  dispatch(hl.dsp.focus({ monitor = "DP-2" }))
  open_window_on("DP-2")

  press("SUPER + SHIFT + code:11")

  local id, workspace = shown("DP-2")
  eq(workspace.monitor, "DP-2", "monitor the moved window is on")
  eq(workspace.windows, 1, "windows on ws " .. id)
  eq(slot_of(id), 2, "desk the window moved to")

  reload()
  eq(table.concat(world.renumbered, " "), "", "workspaces Omarchy renumbered")
end, true)

test("with one monitor the number keys fall through to Omarchy's own workspaces", function()
  start({ { id = 0, name = "DP-2", description = "Right panel", x = 0 } },
    { blocks = "0\tDP-1\tLeft panel\n1\tDP-2\tRight panel\n" })

  press("SUPER + code:12")
  eq(shown("DP-2"), 13, "workspace SUPER+3 shows on the right panel's block")
end, true)

test("without per-monitor workspaces, desk N is still N on the left and 10 + N on the right", function()
  start(twin_panels(), { omarchy = false })

  o.unified_desks.switch_desk(2)
  eq(shown("DP-1"), 2, "left half of desk 2")
  eq(shown("DP-2"), 12, "right half of desk 2")
  eq(world.rules["12"], "DP-2", "monitor ws 12 is pinned to")
end)

test("the desk count only changes how many desks there are", function()
  start(twin_panels(), { desks = 3 })

  eq(o.unified_desks.desks, 3, "desk count")
  press("SUPER + code:15") -- 6 -> desk 3
  local left = shown("DP-1")
  local right = shown("DP-2")
  eq(slot_of(left), 3, "desk on the left")
  eq(slot_of(right), 3, "desk on the right")
  eq(world.binds["SUPER + code:16"], nil, "SUPER+7 is left to Omarchy at three desks")
end)

-- Omarchy writes at most these two files into a state directory.
for _, dir in ipairs(state_dirs) do
  os.remove(dir .. "/omarchy/monitor-workspaces")
  os.remove(dir .. "/omarchy/monitor-workspaces-merged")
  os.remove(dir .. "/omarchy")
  os.remove(dir)
end

print(string.format("\n%d run, %d failed, %d skipped", ran, failures, skipped))
os.exit(failures == 0 and 0 or 1)
