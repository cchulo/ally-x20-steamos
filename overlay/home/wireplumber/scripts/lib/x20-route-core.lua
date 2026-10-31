-- SPDX-License-Identifier: GPL-2.0-only
-- ally-x20-steamos: routing decision core for x20-route-by-channels.lua.
--
-- Pure Lua, no WirePlumber API: every function takes plain tables and
-- returns plain values, so the decision logic runs under any Lua 5.1-5.4 or
-- LuaJIT (tests/lua/test_x20_route_core.lua) as well as inside WirePlumber,
-- which loads it with require ("x20-route-core") from
-- ~/.local/share/wireplumber/scripts/lib/.
--
-- Policy (X20-STEAMOS-PLAN.md section 1.5, item 3):
--   headphones  7..8 channels -> x20-virtual-surround-71
--               3..6 channels -> x20-virtual-surround-51
--               1..2 channels -> hardware sink, untouched (bit-exact), or
--                                x20-virtual-surround-71 when the
--                                x20.stereo_hrtf setting is true
--   speakers    3..8 channels -> x20-speakers-surround (binaural render +
--                                crosstalk cancellation) when the
--                                x20.speaker_surround setting is true
--                                (default), otherwise x20-speakers
--               1..2 channels -> x20-speakers (downmix/width/EQ), or
--                                x20-speakers-surround when the
--                                x20.stereo_surround setting is true
--               x20-speakers-surround missing -> x20-speakers
--   other       everything    -> hardware sink (HDMI, line out, USB DAC:
--                                a receiver decodes surround itself)
-- Never touched: streams with an explicit target (set by the application or
-- moved by the user), encoded passthrough, capture streams, other filters.

local M = {}

M.SINK_71 = "x20-virtual-surround-71"
M.SINK_51 = "x20-virtual-surround-51"
M.SINK_SPEAKERS = "x20-speakers"
M.SINK_SPEAKERS_SURROUND = "x20-speakers-surround"

-- is_x20_name (name) : true for nodes created by our filter chains
-- ("x20-..." sinks and their "x20-....output" playback streams).
function M.is_x20_name (name)
  return type (name) == "string" and name:sub (1, 4) == "x20-"
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

-- channel_count (v) : normalise a channel count from a property string, a
-- number or a parsed SPA pod. EnumFormat params of flexible streams carry a
-- Choice (e.g. { 2, 1, 64 } = default 2, range 1..64); the default (first
-- value) is what the client asked for. Returns nil when unknown.
function M.channel_count (v)
  if type (v) == "number" then
    if v > 0 then
      return math.floor (v)
    end
    return nil
  end
  if type (v) == "string" then
    return M.channel_count (tonumber (v))
  end
  if type (v) == "table" then
    if v.default ~= nil then
      return M.channel_count (v.default)
    end
    return M.channel_count (v[1])
  end
  return nil
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

-- classify_output (sink, routes) : "headphones" | "speakers" | "other"
--   sink   = { form_factor = "headphone"|"headset"|"internal"|..., bus = ...,
--              name = node.name }
--   routes = list of the device's active output routes for this sink:
--            { name = "analog-output-headphones" | "[Out] Headphones" | ...,
--              description = ..., port_type = ..., available = "yes"|"no"|
--              "unknown", direction = "Output" }
-- Bluetooth/USB headsets announce themselves through device.form-factor.
-- The internal card exposes the jack as a route: ALSA jack detection flips
-- route.available to "no" when the plug is out, and WirePlumber then
-- switches the active route to the speaker. TODO(hw): the X20's UCM route
-- names (expected "[Out] Headphones" / "[Out] Speaker").
function M.classify_output (sink, routes)
  sink = sink or {}
  local ff = lower (sink.form_factor)
  if ff == "headphone" or ff == "headset" or ff == "hands-free" then
    return "headphones"
  end
  local saw_speaker = false
  for _, r in ipairs (routes or {}) do
    local dir = lower (r.direction)
    if dir == "" or dir == "output" then
      if lower (r.available) ~= "no" then
        if mentions (r, "headphone") or mentions (r, "headset") then
          return "headphones"
        end
        if mentions (r, "speaker") then
          saw_speaker = true
        end
      end
    end
  end
  if saw_speaker then
    return "speakers"
  end
  if ff == "speaker" or ff == "internal" then
    -- No route information but the device says it is built in.
    return "speakers"
  end
  return "other"
end

-- pick_hardware_sink (sinks, default_name) : the sink that represents "the
-- hardware". The default sink when it is not one of ours, otherwise the
-- non-x20 sink with the highest priority.session. sinks is a list of
-- { name = node.name, priority = number }. Returns a name or nil.
function M.pick_hardware_sink (sinks, default_name)
  if default_name and not M.is_x20_name (default_name) then
    return default_name
  end
  local best, best_prio = nil, nil
  for _, s in ipairs (sinks or {}) do
    if s.name and not M.is_x20_name (s.name) then
      local p = tonumber (s.priority) or 0
      if best == nil or p > best_prio then
        best, best_prio = s.name, p
      end
    end
  end
  return best
end

-- decide (stream, env) -> sink-name|nil, reason
--   stream = { media_class, node_name, channels, explicit_target (bool),
--              link_group (string|nil), encoded (bool) }
--   env    = { enabled (bool), stereo_hrtf (bool),
--              speaker_surround (bool, nil = true), stereo_surround (bool),
--              output = "headphones"|"speakers"|"other",
--              hardware_sink = name|nil, default_is_x20 (bool),
--              available = { [sink-name] = true, ... } }
-- nil means "do not interfere": WirePlumber's remaining hooks decide.
function M.decide (stream, env)
  stream = stream or {}
  env = env or {}
  local available = env.available or {}

  if env.enabled == false then
    return nil, "audio-dsp disabled"
  end
  if stream.media_class ~= "Stream/Output/Audio" then
    return nil, "not an audio playback stream"
  end
  if stream.explicit_target then
    return nil, "explicit target set by the application or user"
  end
  if stream.encoded then
    return nil, "encoded passthrough stream"
  end

  local function hardware (why)
    if env.hardware_sink then
      return env.hardware_sink, why
    end
    return nil, why .. " (no hardware sink known; default linking)"
  end

  if M.is_x20_name (stream.node_name) then
    -- Our own filter output: it must reach the hardware. Only intervene
    -- when the default sink is one of ours (that would loop or double-
    -- process); otherwise default linking already does the right thing.
    if env.default_is_x20 then
      return hardware ("x20 filter output, default sink is virtual")
    end
    return nil, "x20 filter output follows the default sink"
  end
  if stream.link_group then
    return nil, "filter node (node.link-group), not ours"
  end

  local ch = M.channel_count (stream.channels) or 2
  local want, why
  if env.output == "headphones" then
    if ch >= 7 then
      want, why = M.SINK_71, ch .. " channels on headphones"
    elseif ch >= 3 then
      want, why = M.SINK_51, ch .. " channels on headphones"
    elseif env.stereo_hrtf then
      want, why = M.SINK_71, ch .. " channels on headphones, stereo_hrtf on"
    else
      return hardware (ch .. " channels on headphones: bit-exact passthrough")
    end
  elseif env.output == "speakers" then
    local surround = env.speaker_surround ~= false
    if ch >= 3 and surround then
      want, why = M.SINK_SPEAKERS_SURROUND, ch .. " channels on speakers, speaker_surround on"
    elseif ch <= 2 and env.stereo_surround then
      want, why = M.SINK_SPEAKERS_SURROUND, ch .. " channels on speakers, stereo_surround on"
    else
      want, why = M.SINK_SPEAKERS, ch .. " channels on speakers"
    end
    if want == M.SINK_SPEAKERS_SURROUND and not available[want] then
      -- No HRTF or no sofa plugin: the plain speaker chain is still better
      -- than the raw hardware sink.
      want, why = M.SINK_SPEAKERS, why .. ", but " .. M.SINK_SPEAKERS_SURROUND .. " is not loaded"
    end
  else
    return hardware ("output is neither headphones nor speakers")
  end

  if not available[want] then
    return hardware (why .. ", but " .. want .. " is not loaded")
  end
  return want, why
end

return M
