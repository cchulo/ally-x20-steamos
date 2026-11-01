-- SPDX-License-Identifier: GPL-2.0-only
-- Unit tests for overlay/home/wireplumber/scripts/lib/x20-route-core.lua.
-- Runs under plain Lua 5.1-5.4 or LuaJIT, no WirePlumber needed:
--   lua tests/lua/test_x20_route_core.lua <repo-root>
-- Exit status 0 when every case passes. Driven by tests/components/audio_dsp.bats.

local root = arg[1] or "."
package.path = root .. "/overlay/home/wireplumber/scripts/lib/?.lua;" .. package.path
local core = require ("x20-route-core")

local failures, count = 0, 0
local function check (name, got, want)
  count = count + 1
  if got ~= want then
    failures = failures + 1
    io.stderr:write (string.format ("FAIL %s: got %s, want %s\n", name, tostring (got), tostring (want)))
  end
end

local function split (s, pattern)
  local t = {}
  for w in s:gmatch (pattern) do
    t[#t + 1] = w
  end
  return t
end

-- Route shorthands used in the fixture file.
local ROUTES = {
  hp = { name = "[Out] Headphones" },
  spk = { name = "[Out] Speaker" },
  acphp = { name = "analog-output-headphones", description = "Headphones" },
  hdmi = { name = "hdmi-output-0", description = "HDMI / DisplayPort" },
}

-- name:priority:form-factor:route:available -> sink table
local function parse_sink (spec)
  local f = split (spec, "[^:]+")
  assert (#f == 5, "bad sink spec: " .. spec)
  local sink = { name = f[1], priority = tonumber (f[2]), routes = {} }
  if f[3] ~= "-" then
    sink.form_factor = f[3]
  end
  if f[4] ~= "-" then
    local r = assert (ROUTES[f[4]], "unknown route shorthand " .. f[4])
    sink.routes[1] = { name = r.name, description = r.description,
      direction = "Output", available = f[5] }
  end
  return sink
end

-- 1. Table-driven decide () cases from the fixture file.
local fixture = root .. "/tests/fixtures/audio_dsp/routing-cases.txt"
local fh = assert (io.open (fixture, "r"))
local cases = 0
for line in fh:lines () do
  if line:match ("%S") and not line:match ("^%s*#") then
    local f = split (line, "%S+")
    assert (#f == 6, "bad fixture line: " .. line)
    local sinks = {}
    if f[5] ~= "-" then
      for spec in f[5]:gmatch ("[^,]+") do
        sinks[#sinks + 1] = parse_sink (spec)
      end
    end
    local got = core.decide (
      { media_class = "Stream/Output/Audio", node_name = f[2], explicit_target = f[3] == "yes" },
      { sinks = sinks, default_name = (f[4] ~= "-") and f[4] or nil })
    if got == core.UNLINKED then
      got = "unlinked"
    end
    check ("decide/" .. f[1], tostring (got), f[6])
    cases = cases + 1
  end
end
fh:close ()
check ("fixture has cases", cases > 10, true)

-- 2. Table-driven decide_default () cases (automatic default sink).
local NAMES = {
  spk = core.X20_SPEAKER_SINK,
  jack = "alsa_output.pci-0000_64_00.5-platform-amd_sdw.HiFi__Headphones__sink",
}
local ALL_X20 = { core.SINK_SPEAKERS, core.SINK_SPEAKERS_SURROUND, core.SINK_HEADPHONES }
fh = assert (io.open (root .. "/tests/fixtures/audio_dsp/default-cases.txt", "r"))
local dcases = 0
for line in fh:lines () do
  if line:match ("%S") and not line:match ("^%s*#") then
    local f = split (line, "%S+")
    assert (#f == 12, "bad default fixture line: " .. line)
    local name = NAMES[f[2]] or f[2]
    local sink = { name = name, routes = {} }
    if f[4] ~= "-" then
      sink.form_factor = f[4]
    end
    if f[5] ~= "-" then
      local r = assert (ROUTES[f[5]], "unknown route shorthand " .. f[5])
      sink.routes[1] = { name = r.name, description = r.description,
        direction = "Output", available = f[6] }
    end
    if f[7] ~= "-" then
      sink.api = f[7]
    end
    local available = { [NAMES.spk] = true, [NAMES.jack] = true, [name] = true }
    local present = (f[11] == "all") and ALL_X20 or split (f[11], "[^,]+")
    for _, n in ipairs (present) do
      available[n] = true
    end
    local got = core.decide_default (
      { name = name, priority = tonumber (f[3]), sink = sink },
      { speakers_precedence = f[8] == "yes", headphones_virtual_surround = f[9] == "yes",
        stereo_surround = f[10] == "yes", available = available })
    check ("default/" .. f[1], tostring (got), f[12])
    dcases = dcases + 1
  end
end
fh:close ()
check ("default fixture has cases", dcases > 10, true)
check ("default/nothing-selected", core.decide_default (nil, nil), nil)
-- precedence and headphone settings default to on when absent (nil)
check ("default/settings-absent-speakers", core.decide_default (
  { name = core.X20_SPEAKER_SINK, priority = 712 },
  { available = { [core.SINK_SPEAKERS] = true } }), core.SINK_SPEAKERS)
check ("default/settings-absent-headphones", core.decide_default (
  { name = "bluez_output.x", priority = 1010, sink = { name = "bluez_output.x", api = "bluez5" } },
  { available = { [core.SINK_HEADPHONES] = true } }), core.SINK_HEADPHONES)

-- 3. Non-playback streams are never touched.
check ("decide/capture", core.decide ({ media_class = "Stream/Input/Audio", node_name = "x20-headphones.output" },
  { sinks = { parse_sink ("jack:1000:-:hp:yes") } }), nil)
check ("decide/empty", core.decide (nil, nil), nil)

-- 4. Headphone and speaker sink classification (jack detection through availability).
check ("hp/ucm-available", core.is_headphone_sink (parse_sink ("j:1:-:hp:yes")), true)
check ("hp/ucm-unavailable", core.is_headphone_sink (parse_sink ("j:1:-:hp:no")), false)
check ("hp/speaker", core.is_headphone_sink (parse_sink ("s:1:-:spk:yes")), false)
check ("hp/hdmi", core.is_headphone_sink (parse_sink ("h:1:-:hdmi:yes")), false)
check ("hp/acp", core.is_headphone_sink (parse_sink ("c:1:-:acphp:yes")), true)
check ("hp/internal-ff", core.is_headphone_sink (parse_sink ("i:1:internal:-:-")), false)
check ("hp/x20-name", core.is_headphone_sink (parse_sink ("x20-speakers:1:headset:hp:yes")), false)
check ("hp/input-route-ignored", core.is_headphone_sink ({ name = "a",
  routes = { { name = "[In] Headset Mic", direction = "Input", available = "yes" } } }), false)
check ("hp/port-type", core.is_headphone_sink ({ name = "a",
  routes = { { name = "out-1", port_type = "headphones", available = "yes" } } }), true)
check ("hp/speaker-and-headphone-words", core.is_headphone_sink ({ name = "a",
  routes = { { name = "Speaker + Headphones", available = "yes" } } }), false)
check ("hp/nil", core.is_headphone_sink (nil), false)
check ("hp/bluez5", core.is_headphone_sink ({ name = "bluez_output.a", api = "bluez5" }), true)
check ("hp/bluez5-speaker", core.is_headphone_sink ({ name = "bluez_output.a", api = "bluez5", form_factor = "speaker" }), false)
check ("spk/x20-speaker-sink", core.is_speaker_sink ({ name = core.X20_SPEAKER_SINK }), true)
check ("spk/route", core.is_speaker_sink (parse_sink ("s:1:-:spk:unknown")), true)
check ("spk/route-unavailable", core.is_speaker_sink (parse_sink ("s:1:-:spk:no")), false)
check ("spk/headphone-route", core.is_speaker_sink (parse_sink ("j:1:-:hp:yes")), false)
check ("spk/x20", core.is_speaker_sink ({ name = "x20-speakers" }), false)
check ("spk/hdmi", core.is_speaker_sink (parse_sink ("h:1:-:hdmi:yes")), false)

-- 5. Helpers.
check ("x20-name", core.is_x20_name ("x20-speakers"), true)
check ("x20-name/other", core.is_x20_name ("alsa_output.x20"), false)
check ("hp-output-name/headphones", core.is_headphone_output_name ("x20-headphones.output"), true)
check ("hp-output-name/old-71", core.is_headphone_output_name ("x20-virtual-surround-71.output"), false)
check ("sink-name", core.SINK_HEADPHONES, "x20-headphones")
check ("hp-output-name/speakers", core.is_headphone_output_name ("x20-speakers.output"), false)
check ("truthy/true-string", core.truthy ("true"), true)
check ("truthy/zero", core.truthy ("0"), false)

io.stdout:write (string.format ("%d checks, %d failures\n", count, failures))
os.exit (failures == 0 and 0 or 1)
