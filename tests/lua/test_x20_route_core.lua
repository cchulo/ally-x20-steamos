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

-- 1. Table-driven decide() cases from the fixture file.
local function split (s)
  local t = {}
  for w in s:gmatch ("%S+") do
    t[#t + 1] = w
  end
  return t
end
local fixture = root .. "/tests/fixtures/audio_dsp/routing-cases.txt"
local fh = assert (io.open (fixture, "r"))
for line in fh:lines () do
  if line:match ("%S") and not line:match ("^%s*#") then
    local f = split (line)
    assert (#f == 11, "bad fixture line: " .. line)
    local available = {}
    for n in f[10]:gmatch ("[^,]+") do
      available[n] = true
    end
    local stream = {
      media_class = f[2],
      node_name = f[3],
      channels = (f[4] ~= "-") and f[4] or nil,
      explicit_target = f[5] == "yes",
      link_group = (f[6] ~= "-") and f[6] or nil,
    }
    local env = {
      enabled = true,
      output = f[7],
      stereo_hrtf = f[8] == "yes",
      default_is_x20 = f[9] == "yes",
      hardware_sink = "alsa_output.hw",
      available = available,
    }
    local got = core.decide (stream, env)
    check ("decide/" .. f[1], tostring (got), f[11])
  end
end
fh:close ()

-- 2. Disabled and encoded streams are never touched.
check ("decide/disabled", core.decide ({ media_class = "Stream/Output/Audio", channels = 8 },
  { enabled = false, output = "headphones", available = { [core.SINK_71] = true } }), nil)
check ("decide/encoded", core.decide ({ media_class = "Stream/Output/Audio", channels = 2, encoded = true },
  { enabled = true, output = "speakers", available = { [core.SINK_SPEAKERS] = true } }), nil)
check ("decide/no-hardware-known", core.decide ({ media_class = "Stream/Output/Audio", channels = 2 },
  { enabled = true, output = "headphones", available = {} }), nil)

-- 3. Channel count normalisation (property strings and parsed SPA pods).
check ("channels/string", core.channel_count ("6"), 6)
check ("channels/number", core.channel_count (8), 8)
check ("channels/choice", core.channel_count ({ 2, 1, 64 }), 2)
check ("channels/choice-default", core.channel_count ({ default = 6 }), 6)
check ("channels/zero", core.channel_count (0), nil)
check ("channels/nil", core.channel_count (nil), nil)
check ("channels/garbage", core.channel_count ("x"), nil)

-- 4. Output classification (jack detection through route availability).
local hp = { name = "[Out] Headphones", direction = "Output", available = "yes" }
local hp_unplugged = { name = "[Out] Headphones", direction = "Output", available = "no" }
local spk = { name = "[Out] Speaker", direction = "Output", available = "unknown" }
local acp_hp = { name = "analog-output-headphones", description = "Headphones", direction = "Output", available = "yes" }
local hdmi = { name = "hdmi-output-0", description = "HDMI / DisplayPort", direction = "Output", available = "yes" }
check ("classify/ucm-headphones", core.classify_output ({}, { hp }), "headphones")
check ("classify/acp-headphones", core.classify_output ({}, { acp_hp }), "headphones")
check ("classify/unplugged-then-speaker", core.classify_output ({}, { hp_unplugged, spk }), "speakers")
check ("classify/speaker-only", core.classify_output ({}, { spk }), "speakers")
check ("classify/hdmi", core.classify_output ({}, { hdmi }), "other")
check ("classify/bt-headset", core.classify_output ({ form_factor = "headset" }, {}), "headphones")
check ("classify/usb-headphone", core.classify_output ({ form_factor = "headphone" }, { hdmi }), "headphones")
check ("classify/internal-no-routes", core.classify_output ({ form_factor = "internal" }, {}), "speakers")
check ("classify/nothing", core.classify_output (nil, nil), "other")
check ("classify/input-route-ignored", core.classify_output ({}, { { name = "[In] Headset Mic", direction = "Input", available = "yes" } }), "other")
check ("classify/port-type", core.classify_output ({}, { { name = "out-1", port_type = "headphones", available = "yes" } }), "headphones")

-- 5. Hardware sink selection.
local sinks = {
  { name = "x20-virtual-surround-71", priority = 50 },
  { name = "alsa_output.hdmi", priority = 600 },
  { name = "alsa_output.internal", priority = 1000 },
}
check ("hw/default-hardware", core.pick_hardware_sink (sinks, "alsa_output.hdmi"), "alsa_output.hdmi")
check ("hw/default-is-x20", core.pick_hardware_sink (sinks, "x20-speakers"), "alsa_output.internal")
check ("hw/no-default", core.pick_hardware_sink (sinks, nil), "alsa_output.internal")
check ("hw/only-x20", core.pick_hardware_sink ({ { name = "x20-speakers" } }, nil), nil)

-- 6. Helpers.
check ("x20-name", core.is_x20_name ("x20-speakers"), true)
check ("x20-name/other", core.is_x20_name ("alsa_output.x20"), false)
check ("truthy/true-string", core.truthy ("true"), true)
check ("truthy/zero", core.truthy ("0"), false)

io.stdout:write (string.format ("%d checks, %d failures\n", count, failures))
os.exit (failures == 0 and 0 or 1)
