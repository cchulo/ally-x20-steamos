-- SPDX-License-Identifier: GPL-2.0-only
-- ally-x20-steamos: per-stream routing by channel count (WirePlumber 0.5).
--
-- Installed into ~/.local/share/wireplumber/scripts/ (WirePlumber 0.5 looks
-- for scripts under $XDG_DATA_HOME/wireplumber/scripts, not ~/.config) and
-- loaded by ~/.config/wireplumber/wireplumber.conf.d/50-x20-route-by-channels.conf.
--
-- This file is thin glue: it collects facts from the graph and hands them to
-- the pure decision function in lib/x20-route-core.lua (unit-tested without
-- WirePlumber, see tests/lua/).
--
-- Mechanism: WirePlumber 0.5 picks a link target for every stream through a
-- chain of hooks on the "select-target" event (linking/find-*-target.lua).
-- Each hook returns early when an earlier one already chose a target. This
-- hook runs after the hooks that honour explicit targets (target.object /
-- node.target properties and the "default" metadata used by pavucontrol,
-- Steam and `wpctl`), smart filters and role-based policy, and before the
-- default-sink fallback. It therefore never overrides a user or application
-- choice. Re-routing on headphone plug/unplug needs no code here: the
-- standard linking/rescan-trigger hook rescans on device Route changes, which
-- re-runs select-target for every stream.

local core = require ("x20-route-core")
local lutils = require ("linking-utils")
local cutils = require ("common-utils")
local log = Log.open_topic ("s-linking.x20")

local function setting_bool (key, default)
  local ok, value = pcall (Settings.get_boolean, key)
  if ok and value ~= nil then
    return value
  end
  return default
end

-- Channel count of a stream: the audio.channels property when present
-- (rare for clients), otherwise the widest raw EnumFormat the client offers,
-- the same rule si-audio-adapter uses to configure the stream.
local function stream_channels (si, si_props)
  local n = core.channel_count (si_props ["audio.channels"])
  if n then
    return n
  end
  local node = si:get_associated_proxy ("node")
  if not node then
    return nil
  end
  local best = nil
  pcall (function ()
    for p in node:iterate_params ("EnumFormat") do
      local parsed = p:parse ()
      local props = parsed and parsed.properties
      if props and props.mediaType == "audio" and props.mediaSubtype == "raw" then
        local c = core.channel_count (props.channels)
        if c and (best == nil or c > best) then
          best = c
        end
      end
    end
  end)
  return best
end

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

-- All audio sinks known to the session, plus the default sink's name.
local function sinks_and_default (om, si_props)
  local sinks = {}
  local by_id = {}
  local available = {}
  for item in om:iterate {
    type = "SiLinkable",
    Constraint { "media.class", "=", "Audio/Sink" },
  } do
    local p = item.properties
    local name = p ["node.name"]
    if name then
      table.insert (sinks, { name = name, priority = tonumber (p ["priority.session"]) or 0 })
      by_id [tostring (p ["node.id"])] = item
      available [name] = true
    end
  end
  local default_name = nil
  local ok, def_id = pcall (cutils.getDefaultNode, si_props, "input")
  if ok and def_id and by_id [tostring (def_id)] then
    default_name = by_id [tostring (def_id)].properties ["node.name"]
  end
  return sinks, available, default_name
end

-- Active output routes of the device behind a sink node.
local function active_routes (target)
  local routes = {}
  local p = target.properties
  local device_id = p ["device.id"]
  if not device_id then
    return routes
  end
  local device = cutils.get_object_manager ("device"):lookup {
    Constraint { "bound-id", "=", device_id, type = "gobject" },
  }
  if not device then
    return routes
  end
  local card_dev = tonumber (p ["card.profile.device"])
  for param in device:iterate_params ("Route") do
    local r = cutils.parseParam (param, "Route")
    if r and (card_dev == nil or r.device == nil or r.device == card_dev) then
      local port_type = nil
      if type (r.info) == "table" then
        -- info is a flat key/value list: { n, k1, v1, k2, v2, ... }
        for i = 1, #r.info - 1 do
          if r.info [i] == "port.type" then
            port_type = r.info [i + 1]
          end
        end
      end
      table.insert (routes, {
        name = r.name,
        description = r.description,
        available = r.available,
        direction = r.direction,
        port_type = port_type,
      })
    end
  end
  return routes
end

local function lookup_sink (om, name)
  if not name then
    return nil
  end
  return om:lookup {
    type = "SiLinkable",
    Constraint { "node.name", "=", name },
    Constraint { "media.class", "=", "Audio/Sink" },
  }
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

    local sinks, available, default_name = sinks_and_default (om, si_props)
    local hardware_name = core.pick_hardware_sink (sinks, default_name)
    local hardware = lookup_sink (om, hardware_name)

    local output = "other"
    if hardware then
      local hp = hardware.properties
      output = core.classify_output ({
        form_factor = hp ["device.form-factor"],
        bus = hp ["device.bus"],
        name = hp ["node.name"],
      }, active_routes (hardware))
    end

    local stream = {
      media_class = si_props ["media.class"],
      node_name = si_props ["node.name"],
      channels = nil,
      explicit_target = has_explicit_target (si_props),
      link_group = si_props ["node.link-group"],
      encoded = cutils.parseBool (si_props ["item.node.encoded-only"]),
    }
    if stream.media_class == "Stream/Output/Audio" then
      stream.channels = stream_channels (si, si_props)
    end

    local name, reason = core.decide (stream, {
      enabled = true,
      stereo_hrtf = setting_bool ("x20.stereo_hrtf", false),
      output = output,
      hardware_sink = hardware_name,
      default_is_x20 = core.is_x20_name (default_name),
      available = available,
    })

    if not name then
      log:debug (si, string.format ("x20: leaving %s alone: %s",
          tostring (si_props ["node.name"]), reason))
      return
    end

    local t = lookup_sink (om, name)
    if not t or not lutils.canLink (si_props, t) then
      log:info (si, string.format ("x20: cannot link %s to %s",
          tostring (si_props ["node.name"]), name))
      return
    end
    local compatible, can_passthrough = lutils.checkPassthroughCompatibility (si, t)
    if not compatible then
      return
    end

    log:info (si, string.format ("x20: %s -> %s (%s)",
        tostring (si_props ["node.name"]), name, reason))
    si_flags.can_passthrough = can_passthrough
    event:set_data ("target", t)
  end
}:register ()

-- Re-evaluate every stream when the stereo HRTF toggle changes at runtime
-- (`wpctl settings x20.stereo_hrtf true`).
pcall (Settings.subscribe, "x20.stereo_hrtf", function ()
  local source = Plugin.find ("standard-event-source")
  if source then
    source:call ("schedule-rescan", "linking")
  end
end)
