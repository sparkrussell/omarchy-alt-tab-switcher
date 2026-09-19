-- Alt-Tab window switcher with live thumbnails.
--
-- This module owns the switcher's key handling and selection state. The
-- thumbnail overlay is a separate Quickshell process
-- (~/.config/quickshell/omarchy-switcher, started from autostart.lua) that only
-- renders what this module publishes, so window switching keeps working even
-- when the overlay is not running.
--
-- Wire protocol (both directions go through Hyprland's own IPC):
--   Lua -> overlay: hl.dsp.event("omarchy-switcher>>" .. json) which the
--                   compositor broadcasts on socket2 as "custom>>...".
--   overlay -> Lua: hyprctl dispatch 'omarchy_switcher.pick("0x...")', i.e. the
--                   global table published at the bottom of this file.
--
-- Rebinds ALT+TAB and ALT+SHIFT+TAB, which Omarchy binds to
-- dispatch cyclenext + bringactivetotop.

-- One name, three roles: custom-event channel, Hyprland submap, and the layer
-- namespace the Quickshell overlay gives its surfaces.
local NAME = "omarchy-switcher"
local IDLE_TIMEOUT_MS = 10000

local state = {
  open = false,
  entries = {},
  sel = 1,
  generation = 0,
  timer = nil,
  -- Address to re-focus once the overlay surface unmaps; see close().
  recommit = nil,
}

-- JSON string literal. Control characters are stripped because socket2 events
-- are newline delimited.
local function jstr(value)
  local text = tostring(value or "")
  if #text > 120 then
    text = text:sub(1, 119) .. "…"
  end
  text = text:gsub("[\\\"]", "\\%0"):gsub("%c", " ")
  return '"' .. text .. '"'
end

local function emit(payload)
  hl.dispatch(hl.dsp.event(NAME .. ">>" .. payload))
end

local function publish()
  if not state.open then
    emit('{"open":false}')
    return
  end

  -- Addresses only: Hyprland truncates socket2 events at 1024 bytes, so titles
  -- and classes would cap the switcher at a handful of windows. The overlay
  -- reads those from its own toplevel list instead.
  local items = {}
  for index, entry in ipairs(state.entries) do
    items[index] = jstr(entry.address)
  end

  emit(table.concat({
    '{"open":true,"sel":',
    tostring(state.sel - 1),
    ',"monitor":',
    jstr(state.monitor),
    ',"entries":[',
    table.concat(items, ","),
    "]}",
  }))
end

-- Most recently used order: focus_history_id 0 is the focused window.
local function collect()
  local windows = {}
  for _, window in ipairs(hl.get_windows()) do
    if window.mapped and not window.hidden then
      windows[#windows + 1] = window
    end
  end

  table.sort(windows, function(a, b)
    return (a.focus_history_id or 0) < (b.focus_history_id or 0)
  end)

  local entries = {}
  for index, window in ipairs(windows) do
    entries[index] = { address = window.address }
  end

  return entries
end

local function wrap(index, count)
  return ((index - 1) % count) + 1
end

local function index_of(address)
  for index, entry in ipairs(state.entries) do
    if entry.address == address then
      return index
    end
  end
end

local function disarm()
  if state.timer then
    -- HL.Timer has no stop(); disabling it is how a oneshot gets cancelled.
    state.timer:set_enabled(false)
    state.timer = nil
  end
end

local function focus(address)
  if not hl.get_window("address:" .. address) then
    return
  end
  hl.dispatch(hl.dsp.focus({ window = "address:" .. address }))
  hl.dispatch(hl.dsp.window.bring_to_top())
end

local function close(commit)
  -- Unconditional and first: whatever else happens, no key path may leave the
  -- compositor parked in the switcher submap.
  hl.dispatch(hl.dsp.submap("reset"))

  if not state.open then
    return
  end

  local target = commit and state.entries[state.sel] or nil

  state.open = false
  state.entries = {}
  state.generation = state.generation + 1
  disarm()
  publish()

  if target then
    focus(target.address)
    -- The overlay held pointer focus, and Hyprland refocuses the monitor's last
    -- window when such a layer unmaps (LayerSurface.cpp onUnmap) - which lands
    -- after this dispatch and would undo the switch. Re-apply once the overlay
    -- surface is really gone.
    state.recommit = target.address
  end
end

-- An unattended switcher gives up on its own rather than holding the submap.
local function arm_timeout()
  local generation = state.generation
  disarm()
  state.timer = hl.timer(function()
    if state.open and state.generation == generation then
      close(false)
    end
  end, { timeout = IDLE_TIMEOUT_MS, type = "oneshot" })
end

local function step(direction)
  if not state.open then
    return
  end
  state.sel = wrap(state.sel + direction, #state.entries)
  publish()
  arm_timeout()
end

local function open(direction)
  if state.open then
    step(direction)
    return
  end

  local entries = collect()
  if #entries < 2 then
    return
  end

  local monitor = hl.get_active_monitor()

  state.recommit = nil
  state.entries = entries
  state.monitor = monitor and monitor.name or ""
  state.open = true
  state.generation = state.generation + 1
  -- A tap of ALT+TAB lands on the previously focused window.
  state.sel = direction > 0 and 2 or #entries

  hl.dispatch(hl.dsp.submap(NAME))
  publish()
  arm_timeout()
end

-- hl.unbind is not submap aware, so Omarchy's ALT+TAB defaults (cyclenext and
-- bringactivetotop) have to go before the submap registers its own ALT+TAB.
hl.unbind("ALT + TAB")
hl.unbind("ALT + SHIFT + TAB")

hl.define_submap(NAME, function()
  -- ALT is still held while the switcher is up, so every bind carries it. The
  -- ALT-less variants cover a modifier state that got out of sync.
  hl.bind("ALT + TAB", function() step(1) end, { repeating = true })
  hl.bind("ALT + SHIFT + TAB", function() step(-1) end, { repeating = true })
  hl.bind("TAB", function() step(1) end, { repeating = true })
  hl.bind("SHIFT + TAB", function() step(-1) end, { repeating = true })

  hl.bind("ALT + RIGHT", function() step(1) end, { repeating = true })
  hl.bind("ALT + LEFT", function() step(-1) end, { repeating = true })
  hl.bind("RIGHT", function() step(1) end, { repeating = true })
  hl.bind("LEFT", function() step(-1) end, { repeating = true })

  hl.bind("ALT + RETURN", function() close(true) end)
  hl.bind("RETURN", function() close(true) end)
  hl.bind("ALT + ESCAPE", function() close(false) end)
  hl.bind("ESCAPE", function() close(false) end)
  hl.bind("ALT + Q", function() close(false) end)
end)

-- Releasing ALT commits, which is what makes hold-to-preview work. Three
-- non-obvious flags, all load bearing (Hyprland 0.56 KeybindManager.cpp):
--   submap_universal: a release bind is matched against the submap that was
--     active when the key went *down* (submapAtPress), and ALT goes down before
--     ALT+TAB enters the submap, so a submap-scoped bind never matches.
--   transparent: triggering ALT+TAB runs shadowKeybinds(), which shadows every
--     bind whose key is still held down - including this one. Only `global` and
--     transparent binds are exempt.
--   non_consuming: otherwise the ALT release never reaches the focused client,
--     leaving applications believing ALT is still held.
for _, key in ipairs({ "ALT + Alt_L", "ALT + Alt_R" }) do
  hl.bind(key, function()
    if state.open then
      close(true)
    end
  end, { release = true, submap_universal = true, transparent = true, non_consuming = true })
end

o.bind("ALT + TAB", "Window switcher", function() open(1) end, { repeating = true })
o.bind("ALT + SHIFT + TAB", "Window switcher (reverse)", function() open(-1) end, { repeating = true })

-- Windows closing behind the switcher would otherwise leave dead thumbnails.
hl.on("window.close", function()
  if not state.open then
    return
  end

  local selected = state.entries[state.sel]
  local entries = collect()
  if #entries < 2 then
    close(false)
    return
  end

  state.entries = entries
  state.sel = (selected and index_of(selected.address)) or wrap(state.sel, #entries)
  publish()
end)

hl.on("layer.closed", function(layer)
  if not state.recommit or not layer or layer.namespace ~= NAME then
    return
  end

  local address = state.recommit
  state.recommit = nil
  focus(address)
end)

-- Public entry points. The overlay dispatches into these
-- (hyprctl dispatch 'omarchy_switcher.pick("0x...")') and they double as the
-- scriptable interface for the switcher.
_G.omarchy_switcher = {
  open = function(direction)
    open(tonumber(direction) or 1)
    return hl.dsp.no_op()
  end,

  step = function(direction)
    step(tonumber(direction) or 1)
    return hl.dsp.no_op()
  end,

  commit = function()
    close(true)
    return hl.dsp.no_op()
  end,

  pick = function(address)
    if state.open then
      local index = index_of(address)
      if index then
        state.sel = index
      end
      close(true)
    end
    return hl.dsp.no_op()
  end,

  hover = function(address)
    if state.open then
      local index = index_of(address)
      if index and index ~= state.sel then
        state.sel = index
        publish()
        arm_timeout()
      end
    end
    return hl.dsp.no_op()
  end,

  cancel = function()
    close(false)
    return hl.dsp.no_op()
  end,

  -- Lets the overlay recover the current state when it (re)starts.
  resync = function()
    publish()
    return hl.dsp.no_op()
  end,
}
