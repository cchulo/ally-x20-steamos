-- SPDX-License-Identifier: GPL-2.0-only
-- Unit tests for overlay/home/wireplumber/scripts/lib/x20-volume-core.lua
-- (the hardware volume rule). Runs under plain Lua 5.1-5.4 or LuaJIT:
--   lua tests/lua/test_x20_volume_core.lua <repo-root>
-- Exit status 0 when every case passes. Driven by tests/components/audio_dsp.bats.

local root = arg[1] or "."
package.path = root .. "/overlay/home/wireplumber/scripts/lib/?.lua;" .. package.path
local route = require ("x20-route-core")
local vcore = require ("x20-volume-core")

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

local function list (s)
  if s == "-" then
    return {}
  end
  return split (s, "[^,]+")
end

local function set (s)
  if s == "first" then
    return nil
  end
  local t = {}
  if s ~= "none" then
    for _, n in ipairs (list (s)) do
      t[n] = true
    end
  end
  return t
end

local function numbers (s)
  local t = {}
  for _, kv in ipairs (list (s)) do
    local k, v = kv:match ("^([^=]+)=(.+)$")
    assert (k, "bad name=volume: " .. kv)
    t[k] = assert (tonumber (v), "bad volume: " .. kv)
  end
  return t
end

local function format_set (t)
  local keys = {}
  for k in pairs (t) do
    keys[#keys + 1] = k
  end
  if #keys == 0 then
    return "none"
  end
  table.sort (keys)
  return table.concat (keys, ",")
end

local function sorted_list (s)
  if s == "none" then
    return "none"
  end
  local t = list (s)
  table.sort (t)
  return table.concat (t, ",")
end

-- 1. Table-driven decide () cases.
local fh = assert (io.open (root .. "/tests/fixtures/audio_dsp/volume-cases.txt", "r"))
local cases = 0
for line in fh:lines () do
  if line:match ("%S") and not line:match ("^%s*#") then
    local f = split (line, "%S+")
    assert (#f == 8, "bad volume fixture line: " .. line)
    local actions, members = vcore.decide ({
      chain = list (f[2]),
      previous = set (f[3]),
      volumes = numbers (f[4]),
      saved = numbers (f[5]),
      enabled = f[6] == "yes",
    })
    check ("decide/" .. f[1] .. "/actions", vcore.format_actions (actions), f[7])
    check ("decide/" .. f[1] .. "/members", format_set (members), sorted_list (f[8]))
    cases = cases + 1
  end
end
fh:close ()
check ("fixture has cases", cases > 15, true)

-- enabled defaults to on when absent (nil)
check ("decide/enabled-absent", vcore.format_actions ((vcore.decide ({
  chain = { "x20-speakers", "spk" }, volumes = { spk = 0.5 } }))), "save:spk=0.5;set:spk=1")
check ("decide/nil", vcore.format_actions ((vcore.decide (nil))), "none")
-- the raise is a float (WirePlumber hands it to mixer-api as a double)
local acts = vcore.decide ({ chain = { "x20-speakers", "spk" }, volumes = { spk = 0.5 } })
check ("decide/raise-volume", acts[2].op == "set" and acts[2].volume == 1.0, true)

-- 2. Targets: pinned outputs follow target.object, the headphone output the
-- headphone classification (same as the link-target hook).
local SPK = route.X20_SPEAKER_SINK
local JACK = "alsa_output.pci-0000_64_00.5-platform-amd_sdw.HiFi__Headphones__sink"
local function jack (available)
  return { name = JACK, priority = 1000,
    routes = { { name = "[Out] Headphones", direction = "Output", available = available } } }
end
local speaker_sink = { name = SPK, priority = 712,
  routes = { { name = "[Out] Speaker", direction = "Output", available = "unknown" } } }
local outputs = {
  { name = "x20-speakers.output", target = SPK },
  -- synthetic intermediate stage (no such sink ships): keeps chains of more
  -- than one x20 sink covered
  { name = "x20-stage.output", target = "x20-speakers" },
  { name = "x20-headphones.output" },
  { name = "game.output", target = "x" },
}
local t = vcore.targets (outputs, { jack ("yes"), speaker_sink })
check ("targets/speakers", t["x20-speakers"], SPK)
check ("targets/stage", t["x20-stage"], "x20-speakers")
check ("targets/headphones-jack", t["x20-headphones"], JACK)
check ("targets/not-x20", t["game"], nil)
t = vcore.targets (outputs, { jack ("no"), speaker_sink })
check ("targets/headphones-unplugged", t["x20-headphones"], nil)
t = vcore.targets (outputs, { jack ("no"), speaker_sink,
  { name = "bluez_output.aa", priority = 1010, api = "bluez5" } })
check ("targets/headphones-bluetooth", t["x20-headphones"], "bluez_output.aa")
check ("targets/nil", next (vcore.targets (nil, nil)), nil)

-- 3. Chains.
t = vcore.targets (outputs, { jack ("yes"), speaker_sink })
check ("chain/speakers", table.concat (vcore.chain ("x20-speakers", t), ","), "x20-speakers," .. SPK)
check ("chain/stage", table.concat (vcore.chain ("x20-stage", t), ","),
  "x20-stage,x20-speakers," .. SPK)
check ("chain/headphones", table.concat (vcore.chain ("x20-headphones", t), ","), "x20-headphones," .. JACK)
check ("chain/hardware", table.concat (vcore.chain (SPK, t), ","), SPK)
check ("chain/no-headphones", table.concat (vcore.chain ("x20-headphones", {}), ","), "x20-headphones")
check ("chain/nil", #vcore.chain (nil, t), 0)
check ("chain/loop", table.concat (vcore.chain ("x20-a", { ["x20-a"] = "x20-b", ["x20-b"] = "x20-a" }), ","), "x20-a,x20-b")
-- a sink removed from the confs simply has no output and no target: the
-- chain of the remaining sinks is unchanged (removing x20-stage)
local without = vcore.targets ({ outputs[1], outputs[3] }, { jack ("yes"), speaker_sink })
check ("chain/without-stage", table.concat (vcore.chain ("x20-speakers", without), ","), "x20-speakers," .. SPK)
check ("chain/removed-sink-alone", table.concat (vcore.chain ("x20-stage", without), ","), "x20-stage")

io.stdout:write (string.format ("%d checks, %d failures\n", count, failures))
os.exit (failures == 0 and 0 or 1)
