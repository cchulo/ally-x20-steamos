-- SPDX-License-Identifier: GPL-2.0-only
-- ally-x20-steamos: link target for the headphone surround output
-- (WirePlumber 0.5).
--
-- Installed into ~/.local/share/wireplumber/scripts/ (WirePlumber 0.5 looks
-- for scripts under $XDG_DATA_HOME/wireplumber/scripts, not ~/.config) and
-- loaded by ~/.config/wireplumber/wireplumber.conf.d/50-x20-route-by-channels.conf.
-- The file name is historical: the script no longer routes application
-- streams by channel count. They follow the default sink the user picks in
-- Steam.
--
-- This file is thin glue: it collects facts from the graph and hands them to
-- the pure decision function in lib/x20-route-core.lua (unit-tested without
-- WirePlumber, see tests/lua/), which has the policy.
--
-- Mechanism: WirePlumber 0.5 picks a link target for every stream through a
-- chain of hooks on the "select-target" event (linking/find-*-target.lua).
-- Each hook returns early when an earlier one already chose a target. This
-- hook runs after the hooks that honour explicit targets (target.object in
-- our confs, the "default" metadata used by pavucontrol, Steam and `wpctl`),
-- smart filters and role-based policy, and before the default-sink and
-- best-sink fallbacks. Re-evaluation on headphone plug/unplug needs no code
-- here: the standard linking/rescan-trigger hook rescans on device Route
-- changes and on nodes being added or removed, which re-runs select-target
-- for every stream.

local core = require ("x20-route-core")
local facts = require ("x20-sink-facts")
local lutils = require ("linking-utils")
local cutils = require ("common-utils")
local log = Log.open_topic ("s-linking.x20")

local function has_explicit_target (si_props)
  if si_props ["target.object"] ~= nil or si_props ["node.target"] ~= nil then
    return true
  end
  local md = cutils.get_default_metadata_object ()
  local id = si_props ["node.id"]
  if md and id then
    if md:find (id, "target.object") ~= nil or md:find (id, "target.node") ~= nil then
      return true
    end
  end
  return false
end

-- Sink media classes we consider. Every x20 sink is a plain Audio/Sink
-- (WirePlumber 0.5 cannot link streams into Audio/Sink/Internal).
local SINK_CLASSES = "Audio/Sink*"

-- Every audio sink as a plain table for the core, the linkable items by
-- name, and the default sink's name.
local function collect_sinks (om, si_props)
  local sinks, by_name, by_id = {}, {}, {}
  for item in om:iterate {
    type = "SiLinkable",
    Constraint { "media.class", "#", SINK_CLASSES },
  } do
    local p = item.properties
    local name = p ["node.name"]
    if name then
      table.insert (sinks, facts.sink (p))
      by_name [name] = item
      by_id [tostring (p ["node.id"])] = item
    end
  end
  local default_name = nil
  local ok, def_id = pcall (cutils.getDefaultNode, si_props, "input")
  if ok and def_id and by_id [tostring (def_id)] then
    default_name = by_id [tostring (def_id)].properties ["node.name"]
  end
  return sinks, by_name, default_name
end

SimpleEventHook {
  name = "x20/route-by-channels",
  after = { "linking/find-defined-target",
            "linking/find-filter-target",
            "linking/find-media-role-target",
            "linking/find-audio-group-target" },
  before = { "linking/find-default-target",
             "linking/find-best-target",
             "linking/prepare-link" },
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "select-target" },
    },
  },
  execute = function (event)
    local source, om, si, si_props, si_flags, target =
        lutils:unwrap_select_target_event (event)

    -- An earlier hook (explicit target, smart filter, role policy) won.
    if target then
      return
    end

    local stream = {
      media_class = si_props ["media.class"],
      node_name = si_props ["node.name"],
      explicit_target = has_explicit_target (si_props),
    }
    -- Cheap exit for everything that is not one of our filter outputs.
    if not core.is_x20_name (stream.node_name) then
      return
    end

    local sinks, by_name, default_name = collect_sinks (om, si_props)
    local name, reason = core.decide (stream, {
      sinks = sinks,
      default_name = default_name,
    })

    if not name then
      log:debug (si, string.format ("x20: leaving %s alone: %s",
          tostring (si_props ["node.name"]), reason))
      return
    end

    if name == core.UNLINKED then
      -- Like node.dont-fallback with linger: wait unlinked instead of
      -- letting find-default-target/find-best-target pick a sink. The next
      -- rescan (headphones plugged in, a headset connecting) links it.
      log:info (si, string.format ("x20: %s stays unlinked: %s",
          tostring (si_props ["node.name"]), reason))
      event:stop_processing ()
      return
    end

    local t = by_name [name]
    if not t or not lutils.canLink (si_props, t) then
      log:info (si, string.format ("x20: cannot link %s to %s; staying unlinked",
          tostring (si_props ["node.name"]), name))
      event:stop_processing ()
      return
    end
    local compatible, can_passthrough = lutils.checkPassthroughCompatibility (si, t)
    if not compatible then
      event:stop_processing ()
      return
    end

    log:info (si, string.format ("x20: %s -> %s (%s)",
        tostring (si_props ["node.name"]), name, reason))
    si_flags.can_passthrough = can_passthrough
    event:set_data ("target", t)
  end
}:register ()
