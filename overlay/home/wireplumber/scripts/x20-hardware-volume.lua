-- SPDX-License-Identifier: GPL-2.0-only
-- ally-x20-steamos: hold every sink under our default sink at 100 %
-- (WirePlumber 0.5).
--
-- Installed into ~/.local/share/wireplumber/scripts/ and loaded by
-- ~/.config/wireplumber/wireplumber.conf.d/50-x20-route-by-channels.conf.
--
-- Steam's volume slider moves the default sink's volume only. With
-- x20-speakers as the default, the hardware Speaker sink underneath keeps
-- its own volume, and the two multiply (measured on the X20: hardware at
-- 55 %, about -15.6 dB, under x20-speakers at 100 %). While the default is
-- one of our sinks, this script raises every sink between it and the
-- hardware to 100 % and saves the volume it found; when a sink leaves that
-- chain (the default moves to a hardware sink, or back from
-- x20-speakers-surround to x20-speakers) it gets the saved volume back. The
-- default sink's own volume is never raised. The policy is
-- x20-volume-core.decide (unit-tested, tests/lua/); this file is glue.
--
-- Mechanism: WirePlumber applies the default sink by writing
-- "default.audio.sink" into the "default" metadata
-- (default-nodes/apply-default-node) after every select-default-node event:
-- Steam's pick, "Default" (our x20/select-default-sink hook), plug/unplug
-- and start-up. Watching that key sees every change, whoever made it. Sinks
-- coming and going re-run the rule too (at start-up the hardware sink
-- appears after our filter-chain sinks; a headset connecting changes the
-- sink under x20-headphones). The saved volumes live in WirePlumber's state
-- directory (~/.local/state/wireplumber/x20-hardware-volume), so a restart
-- in between does not lose them.
-- Opt out: `ally-x20-steamos audio-dsp hardware-volume off` (setting
-- x20.hardware_volume); turning it off restores what was saved.

local vcore = require ("x20-volume-core")
local route = require ("x20-route-core")
local facts = require ("x20-sink-facts")
local cutils = require ("common-utils")
local log = Log.open_topic ("s-default-nodes.x20")

local state = State ("x20-hardware-volume")
local saved = state:load () or {}

-- Members handled by the last run (nil: none yet, raise what is found).
local previous = nil

local function setting_bool (key, default)
  local ok, value = pcall (Settings.get_boolean, key)
  if ok and value ~= nil then
    return value
  end
  return default
end

local function default_sink_name ()
  local md = cutils.get_default_metadata_object ()
  if not md then
    return nil
  end
  local value = md:find (0, "default.audio.sink")
  if not value then
    return nil
  end
  local ok, parsed = pcall (function () return Json.Raw (value):parse () end)
  if ok and type (parsed) == "table" and type (parsed.name) == "string" then
    return parsed.name
  end
  return nil
end

local function find_node (om, name)
  return om:lookup { Constraint { "node.name", "=", name } }
end

-- volume (mixer, node) : the node's linear volume, nil when unknown.
local function volume_of (mixer, node)
  if not mixer or not node then
    return nil
  end
  local ok, v = pcall (function () return mixer:call ("get-volume", node ["bound-id"]) end)
  if ok and type (v) == "table" then
    return tonumber (v.volume)
  end
  return nil
end

local function evaluate ()
  local default = default_sink_name ()
  if not default then
    -- No default (start-up, nothing selected): wait for the next one
    -- instead of restoring and raising again a moment later.
    return
  end
  local mixer = Plugin.find ("mixer-api")
  if not mixer then
    log:warning ("x20: mixer-api plugin not loaded; hardware volume rule inactive")
    return
  end
  local nodes_om = cutils.get_object_manager ("node")
  local devices_om = cutils.get_object_manager ("device")
  if not nodes_om then
    return
  end

  -- Link targets of our filter outputs, and every audio sink for the
  -- headphone classification (the same facts the link-target hook uses).
  local outputs, sinks = {}, {}
  for node in nodes_om:iterate { type = "node" } do
    local p = node.properties
    local name = p ["node.name"]
    local class = p ["media.class"] or ""
    if name and class:find ("^Audio/Sink") then
      table.insert (sinks, facts.sink (p, devices_om))
    elseif name and route.is_x20_name (name) and name:sub (-7) == ".output" then
      table.insert (outputs, { name = name, target = p ["target.object"] })
    end
  end
  local chain = vcore.chain (default, vcore.targets (outputs, sinks))

  local volumes, ids = {}, {}
  local function probe (name)
    if ids [name] == nil then
      local node = find_node (nodes_om, name)
      ids [name] = node and node ["bound-id"] or false
      volumes [name] = volume_of (mixer, node)
    end
  end
  for _, name in ipairs (chain) do
    probe (name)
  end
  local saved_numbers = {}
  for name, v in pairs (saved) do
    saved_numbers [name] = tonumber (v)
    probe (name)
  end

  local actions, members, reason = vcore.decide {
    chain = chain,
    previous = previous,
    volumes = volumes,
    saved = saved_numbers,
    enabled = setting_bool ("x20.hardware_volume", true),
  }
  previous = members

  if #actions == 0 then
    log:debug (string.format ("x20: hardware volume, default %s: %s", default, reason))
    return
  end
  log:info (string.format ("x20: hardware volume, default %s (%s): %s [%s]", default,
      table.concat (chain, " -> "), reason, vcore.format_actions (actions)))
  local dirty = false
  for _, act in ipairs (actions) do
    if act.op == "save" then
      saved [act.node] = string.format ("%.6f", act.volume)
      dirty = true
    elseif act.op == "forget" then
      saved [act.node] = nil
      dirty = true
    elseif act.op == "set" and ids [act.node] then
      -- + 0.0: mixer-api reads "volume" as a double; a Lua integer would
      -- become an int64 and be ignored.
      mixer:call ("set-volume", ids [act.node], { volume = act.volume + 0.0 })
    end
  end
  if dirty then
    state:save (saved)
  end
end

SimpleEventHook {
  name = "x20/hardware-volume",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "metadata-changed" },
      Constraint { "metadata.name", "=", "default" },
      Constraint { "event.subject.key", "=", "default.audio.sink" },
    },
    EventInterest {
      Constraint { "event.type", "c", "session-item-added", "session-item-removed" },
      Constraint { "event.session-item.interface", "=", "linkable" },
      Constraint { "media.class", "#", "Audio/Sink*" },
    },
    -- our filter outputs carry the link targets the chain follows
    EventInterest {
      Constraint { "event.type", "=", "session-item-added" },
      Constraint { "event.session-item.interface", "=", "linkable" },
      Constraint { "node.name", "#", "x20-*.output" },
    },
  },
  execute = function (event)
    evaluate ()
  end
}:register ()

pcall (Settings.subscribe, "x20.hardware_volume", function ()
  -- On: raise again whatever is under the default. Off: restore.
  previous = nil
  evaluate ()
end)
