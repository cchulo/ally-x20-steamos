-- SPDX-License-Identifier: GPL-2.0-only
-- ally-x20-steamos: routing decision core for x20-route-by-channels.lua.
--
-- Pure Lua, no WirePlumber API: every function takes plain tables and
-- returns plain values, so the decision logic runs under any Lua 5.1-5.4 or
-- LuaJIT (tests/lua/test_x20_route_core.lua) as well as inside WirePlumber,
-- which loads it with require ("x20-route-core") from
-- ~/.local/share/wireplumber/scripts/lib/.
--
-- Policy. The user picks the output (the default sink) by hand in Steam:
-- the hardware speakers or headphones, "X20 Speakers", the speaker virtual
-- surround or one of the headphone surround sinks. Application streams are
-- never routed here; they follow that choice. Only the outputs of our own
-- filter chains need a target, because their sink is the hardware behind
-- the virtual one:
--   x20-virtual-surround-71.output, x20-virtual-surround-51.output
--       (binaural audio, only correct on headphones)
--       -> the best headphone-class hardware sink: not an x20 sink, and
--          either its active ALSA route is a headphone/headset route that
--          is not "available = no" (UCM "[Out] Headphones", ACP
--          "analog-output-headphones"), or the device says it is a
--          headphone/headset (device.form-factor, USB and Bluetooth).
--          The default sink when it qualifies, otherwise the one with the
--          highest priority.session.
--       -> nothing qualifies: stay unlinked (M.UNLINKED). Never the speaker
--          sink, never an x20 sink, never a jack whose route is
--          unavailable, never a blind fallback to the default sink.
--   x20-speakers.output, x20-speakers-surround.output
--       pinned in their PipeWire confs (target.object: the hardware speaker
--       sink, x20-speakers); WirePlumber's find-defined-target hook links
--       them before this hook runs. Left alone here.
-- Never touched: streams with an explicit target (set by the application or
-- moved by the user), capture streams, other filters, application streams.
--
-- History: the earlier version also routed every application stream by its
-- channel count and sent our filter outputs to "the non-x20 sink with the
-- highest priority.session" whenever the default was one of ours. On the X20
-- that is the headphone jack sink (priority.session 1000 against 712 for
-- the speaker sink) even with nothing plugged in (route "not available"),
-- so x20-speakers played into an unplugged jack: silence.

local M = {}

M.SINK_71 = "x20-virtual-surround-71"
M.SINK_51 = "x20-virtual-surround-51"
M.SINK_SPEAKERS = "x20-speakers"
M.SINK_SPEAKERS_SURROUND = "x20-speakers-surround"

-- Returned by decide () when the stream must stay unlinked: the glue stops
-- the select-target event so the default-sink hooks do not link it either.
M.UNLINKED = "<unlinked>"

-- is_x20_name (name) : true for nodes created by our filter chains
-- ("x20-..." sinks and their "x20-....output" playback streams).
function M.is_x20_name (name)
  return type (name) == "string" and name:sub (1, 4) == "x20-"
end

-- is_headphone_output_name (name) : the playback stream of one of the
-- headphone surround sinks.
function M.is_headphone_output_name (name)
  return name == M.SINK_71 .. ".output" or name == M.SINK_51 .. ".output"
end

-- truthy (v) : WirePlumber property values are strings ("true", "1").
function M.truthy (v)
  if v == true then
    return true
  end
  if type (v) == "number" then
    return v ~= 0
  end
  if type (v) == "string" then
    local s = v:lower ()
    return s == "true" or s == "1" or s == "yes" or s == "on"
  end
  return false
end

local function lower (s)
  if type (s) ~= "string" then
    return ""
  end
  return s:lower ()
end

local function mentions (route, word)
  return lower (route.name):find (word, 1, true) ~= nil
      or lower (route.description):find (word, 1, true) ~= nil
      or lower (route.port_type):find (word, 1, true) ~= nil
end

-- is_headphone_sink (sink) : true when the sink is a hardware headphone
-- output that can play right now.
--   sink = { name = node.name,
--            form_factor = device.form-factor ("headphone", "headset",
--                          "hands-free", "internal", ...),
--            routes = the device's active output routes for this sink:
--                     { name = "[Out] Headphones" | "analog-output-..." ...,
--                       description = ..., port_type = ...,
--                       available = "yes" | "no" | "unknown",
--                       direction = "Output" } }
-- ALSA jack detection sets route.available to "no" while the plug is out;
-- the jack sink node itself stays, which is why availability matters.
function M.is_headphone_sink (sink)
  if type (sink) ~= "table" or M.is_x20_name (sink.name) then
    return false
  end
  local ff = lower (sink.form_factor)
  if ff == "headphone" or ff == "headset" or ff == "hands-free" then
    return true
  end
  for _, r in ipairs (sink.routes or {}) do
    local dir = lower (r.direction)
    if (dir == "" or dir == "output") and lower (r.available) ~= "no"
        and not mentions (r, "speaker")
        and (mentions (r, "headphone") or mentions (r, "headset")) then
      return true
    end
  end
  return false
end

-- pick_headphone_sink (sinks, default_name) : name of the best headphone
-- sink, or nil. sinks is a list of is_headphone_sink () tables plus
-- priority = priority.session. The default sink wins when it qualifies
-- (the user's own choice), then the highest priority, then list order.
function M.pick_headphone_sink (sinks, default_name)
  local best, best_prio = nil, nil
  for _, s in ipairs (sinks or {}) do
    if M.is_headphone_sink (s) then
      if default_name ~= nil and s.name == default_name then
        return s.name
      end
      local p = tonumber (s.priority) or 0
      if best == nil or p > best_prio then
        best, best_prio = s.name, p
      end
    end
  end
  return best
end

-- decide (stream, env) -> sink-name | M.UNLINKED | nil, reason
--   stream = { media_class, node_name, explicit_target (bool) }
--   env    = { sinks = { sink tables, see pick_headphone_sink },
--              default_name = default sink node.name or nil }
-- nil means "do not interfere": WirePlumber's remaining hooks decide (for
-- an application stream: the default sink).
function M.decide (stream, env)
  stream = stream or {}
  env = env or {}

  if stream.media_class ~= "Stream/Output/Audio" then
    return nil, "not an audio playback stream"
  end
  if stream.explicit_target then
    return nil, "explicit target (conf, application or user)"
  end
  if not M.is_x20_name (stream.node_name) then
    return nil, "application stream follows the default sink"
  end
  if not M.is_headphone_output_name (stream.node_name) then
    return nil, "x20 filter output without a rule (pinned in its conf)"
  end

  local name = M.pick_headphone_sink (env.sinks, env.default_name)
  if name then
    return name, "headphone surround output to the headphone sink"
  end
  return M.UNLINKED, "headphone surround output, but no headphones are available"
end

return M
