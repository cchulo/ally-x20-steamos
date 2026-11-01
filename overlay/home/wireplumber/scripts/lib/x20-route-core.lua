-- SPDX-License-Identifier: GPL-2.0-only
-- ally-x20-steamos: routing decision core for x20-route-by-channels.lua.
--
-- Pure Lua, no WirePlumber API: every function takes plain tables and
-- returns plain values, so the decision logic runs under any Lua 5.1-5.4 or
-- LuaJIT (tests/lua/test_x20_route_core.lua) as well as inside WirePlumber,
-- which loads it with require ("x20-route-core") from
-- ~/.local/share/wireplumber/scripts/lib/.
--
-- Two decisions live here, sharing one device classification so they always
-- agree: decide () (link target of our filter outputs, below) and
-- decide_default () (the automatic default sink, see its comment).
--
-- Policy. The user picks the output (the default sink) by hand in Steam:
-- the hardware speakers or headphones, "X20 Speakers", the speaker virtual
-- surround or the headphone virtual surround ("X20 Headphones"). Application streams are
-- never routed here; they follow that choice. Only the outputs of our own
-- filter chains need a target, because their sink is the hardware behind
-- the virtual one:
--   x20-headphones.output
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

M.SINK_HEADPHONES = "x20-headphones"
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

-- is_headphone_output_name (name) : the playback stream of the headphone
-- surround sink.
function M.is_headphone_output_name (name)
  return name == M.SINK_HEADPHONES .. ".output"
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

-- The X20 internal speaker sink (UCM HiFi verb, Speaker device, on the ACP
-- at PCI 0000:64:00.5), measured on SteamOS 3.9.5.
M.X20_SPEAKER_SINK = "alsa_output.pci-0000_64_00.5-platform-amd_sdw.HiFi__Speaker__sink"

-- priority above which a default was chosen by the user: WirePlumber ranks
-- the configured default (Steam's manual pick) at 30000 + priority and the
-- stored history of configured defaults at 19xxx-20000; the automatic choice
-- (find-best-default-node) is the plain priority.session.
M.MANUAL_PRIORITY = 15000

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
--            api = device.api ("alsa", "bluez5", ...),
--            routes = the device's active output routes for this sink:
--                     { name = "[Out] Headphones" | "analog-output-..." ...,
--                       description = ..., port_type = ...,
--                       available = "yes" | "no" | "unknown",
--                       direction = "Output" } }
-- ALSA jack detection sets route.available to "no" while the plug is out;
-- the jack sink node itself stays, which is why availability matters.
-- Bluetooth sinks (device.api "bluez5") count as headphones unless they
-- say they are a speaker: headsets and earbuds are the common case, and a
-- Bluetooth output always receives a plain stereo stream, so binaural audio
-- works there.
function M.is_headphone_sink (sink)
  if type (sink) ~= "table" or M.is_x20_name (sink.name) then
    return false
  end
  local ff = lower (sink.form_factor)
  if ff == "headphone" or ff == "headset" or ff == "hands-free" then
    return true
  end
  if lower (sink.api) == "bluez5" and ff ~= "speaker" then
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

-- is_speaker_sink (sink) : a hardware built-in speaker output: the X20
-- speaker sink by name, or an output route that names a speaker and is not
-- "available = no" (and no headphone route).
function M.is_speaker_sink (sink)
  if type (sink) ~= "table" or M.is_x20_name (sink.name) then
    return false
  end
  if M.is_headphone_sink (sink) then
    return false
  end
  if sink.name == M.X20_SPEAKER_SINK then
    return true
  end
  for _, r in ipairs (sink.routes or {}) do
    local dir = lower (r.direction)
    if (dir == "" or dir == "output") and lower (r.available) ~= "no"
        and mentions (r, "speaker") then
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

-- decide_default (selected, env) -> sink-name | nil, reason
-- Runs after WirePlumber chose the default sink (select-default-node, before
-- it is applied). nil keeps WirePlumber's choice.
--   selected = { name = node.name, priority = selected-node-priority,
--                sink = is_headphone_sink () table of that node }
--   env = { speakers_precedence (bool, nil = true),
--           headphones_virtual_surround (bool, nil = true),
--           stereo_surround (bool, nil = true),
--           available = { [node.name] = true } (the selectable sinks) }
-- Policy, automatic choices only (a manual pick always wins):
--   built-in speakers, or one of our speaker sinks, chosen automatically
--       -> x20-speakers-surround (x20-speakers with stereo_surround
--          false), when speakers_precedence; the other speaker sink when the preferred
--          one is not loaded (no sofa plugin or HRTF data)
--   headphones (jack with its route available, USB, Bluetooth)
--       -> x20-headphones, when headphones_virtual_surround
--   anything else (HDMI/DP, line out, x20-headphones itself) -> unchanged
function M.decide_default (selected, env)
  selected = selected or {}
  env = env or {}
  local available = env.available or {}
  local name = selected.name
  if type (name) ~= "string" then
    return nil, "no default selected"
  end
  if (tonumber (selected.priority) or 0) > M.MANUAL_PRIORITY then
    return nil, "chosen by the user"
  end

  local function speakers ()
    if env.speakers_precedence == false then
      return nil, "speakers, speakers-precedence off"
    end
    local want, other = M.SINK_SPEAKERS, M.SINK_SPEAKERS_SURROUND
    if env.stereo_surround ~= false then
      want, other = other, want
    end
    if available[want] then
      if want == name then
        return nil, "already the preferred speaker sink"
      end
      return want, "speakers: preferred speaker sink"
    end
    if want == M.SINK_SPEAKERS_SURROUND and available[other] then
      if other == name then
        return nil, "already the speaker chain (surround sink not loaded)"
      end
      return other, "speakers: " .. want .. " not loaded"
    end
    return nil, "speakers, but " .. want .. " is not loaded"
  end

  if name == M.SINK_SPEAKERS or name == M.SINK_SPEAKERS_SURROUND then
    return speakers ()
  end
  if M.is_x20_name (name) then
    return nil, "our headphone sink"
  end
  local sink = selected.sink or { name = name }
  if M.is_headphone_sink (sink) then
    if env.headphones_virtual_surround == false then
      return nil, "headphones, headphones-virtual-surround off"
    end
    if not available[M.SINK_HEADPHONES] then
      return nil, "headphones, but " .. M.SINK_HEADPHONES .. " is not loaded"
    end
    return M.SINK_HEADPHONES, "headphones: virtual surround"
  end
  if M.is_speaker_sink (sink) then
    return speakers ()
  end
  return nil, "neither speakers nor headphones"
end

return M
