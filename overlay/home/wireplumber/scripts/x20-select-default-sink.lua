-- SPDX-License-Identifier: GPL-2.0-only
-- ally-x20-steamos: automatic default sink (WirePlumber 0.5).
--
-- Installed into ~/.local/share/wireplumber/scripts/ and loaded by
-- ~/.config/wireplumber/wireplumber.conf.d/50-x20-route-by-channels.conf.
--
-- With Steam's output on "Default" (automatic), WirePlumber picks the
-- available sink with the highest priority.session
-- (default-nodes/find-best-default-node). This hook runs right after that
-- choice and before it is applied (default-nodes/apply-default-node), and
-- swaps a hardware choice for its processed counterpart:
--   built-in speakers       -> x20-speakers-surround (x20-speakers with
--                              `audio-dsp stereo-surround off`)
--   headphones: jack, USB,  -> x20-headphones, whose output the
--   Bluetooth                  route-by-channels hook links to those same
--                              headphones (one shared classification)
--   anything else           -> unchanged
-- A default the user picked (Steam's manual choice: WirePlumber ranks it
-- above 15000) is never touched; choosing "Default" in Steam clears it.
-- The policy is x20-route-core.decide_default (unit-tested, tests/lua/).
--
-- Re-evaluation: default-nodes/rescan-trigger schedules a new
-- select-default-node event when sinks come and go and on device Route
-- changes (jack detection), so plugging and unplugging switch the default.
-- Settings changes (`wpctl settings x20.headphones_virtual_surround false`,
-- what `audio-dsp headphones-virtual-surround off` does) schedule one too.

local core = require ("x20-route-core")
local facts = require ("x20-sink-facts")
local log = Log.open_topic ("s-default-nodes.x20")

local function setting_bool (key, default)
  local ok, value = pcall (Settings.get_boolean, key)
  if ok and value ~= nil then
    return value
  end
  return default
end

SimpleEventHook {
  name = "x20/select-default-sink",
  after = { "default-nodes/find-best-default-node",
            "default-nodes/find-selected-default-node",
            "default-nodes/find-stored-default-node" },
  before = "default-nodes/apply-default-node",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "select-default-node" },
      Constraint { "default-node.type", "=", "audio.sink" },
    },
  },
  execute = function (event)
    local selected = event:get_data ("selected-node")
    if not selected then
      return
    end
    local priority = event:get_data ("selected-node-priority") or 0
    if priority > core.MANUAL_PRIORITY then
      return
    end

    local nodes = event:get_data ("available-nodes")
    nodes = nodes and nodes:parse ()
    if not nodes then
      return
    end
    local available = {}
    local selected_props = nil
    for _, props in ipairs (nodes) do
      local name = props ["node.name"]
      if name then
        available [name] = true
        if name == selected then
          selected_props = props
        end
      end
    end

    local sink = nil
    if selected_props then
      local devices_om = event:get_source ():call ("get-object-manager", "device")
      sink = facts.sink (selected_props, devices_om)
    end

    local name, reason = core.decide_default (
      { name = selected, priority = priority, sink = sink },
      {
        speakers_precedence = setting_bool ("x20.speakers_precedence", true),
        headphones_virtual_surround = setting_bool ("x20.headphones_virtual_surround", true),
        stereo_surround = setting_bool ("x20.stereo_surround", true),
        available = available,
      })

    if not name then
      log:debug (string.format ("x20: default sink %s kept: %s", selected, reason))
      return
    end
    log:info (string.format ("x20: default sink %s -> %s (%s)", selected, name, reason))
    event:set_data ("selected-node", name)
  end
}:register ()

local function rescan ()
  local source = Plugin.find ("standard-event-source")
  if source then
    source:call ("schedule-rescan", "default-nodes")
  end
end
for _, key in ipairs ({ "x20.speakers_precedence", "x20.headphones_virtual_surround",
                        "x20.stereo_surround" }) do
  pcall (Settings.subscribe, key, rescan)
end
