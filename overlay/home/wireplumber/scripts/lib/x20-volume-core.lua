-- SPDX-License-Identifier: GPL-2.0-only
-- ally-x20-steamos: decision core for x20-hardware-volume.lua (WirePlumber 0.5).
--
-- Pure Lua, no WirePlumber API (tests/lua/test_x20_volume_core.lua runs it
-- under plain Lua 5.1-5.4 or LuaJIT); loaded with require ("x20-volume-core")
-- from ~/.local/share/wireplumber/scripts/lib/.
--
-- The problem: every sink has its own volume and Steam's slider only moves
-- the default sink's. With one of our sinks as the default, the sinks under
-- it multiply in: x20-speakers at 100 % on a hardware Speaker sink left at
-- 55 % (cubic, about -15.6 dB) is 15.6 dB quieter than the raw speakers.
--
-- The rule: while the default sink is one of ours, every sink between it and
-- the hardware (the "chain") is held at 100 %, so the default's own slider is
-- an absolute fraction of the hardware's full range:
--   x20-speakers           -> hardware speaker sink
--   x20-headphones         -> the headphone sink its output is linked to
-- A stage below 100 % that enters the chain is saved and raised to 100 %. A
-- saved stage that is no longer in the chain gets its saved volume back. The
-- default sink itself is never raised (it is the user's slider), and a stage
-- that stays in the chain is never touched again (a manual change sticks).
-- Nothing here knows the sink names: the chain comes from each x20 sink's
-- link target, so a chain of any length works (an x20 sink feeding another
-- x20 sink, as the speaker virtual surround did until 2026-10, is covered by
-- the tests), and removing a sink is a deletion in its conf, not code.

local route = require ("x20-route-core")

local M = {}

-- Volumes at or above this count as 100 % (linear; float noise).
M.FULL = 1.0
M.FULL_EPSILON = 0.999

-- Longest chain followed (loop guard).
M.MAX_CHAIN = 8

-- targets (outputs, sinks) -> { [x20 sink name] = name of the sink it feeds }
--   outputs = { { name = "<x20 sink>.output", target = target.object or nil }, ... }
--   sinks   = sink tables for route.pick_headphone_sink (headphone
--             classification, the same as the link-target hook)
-- A pinned output (target.object) feeds its target. The headphone output has
-- no target.object; it feeds the headphone sink the route hook links it to,
-- or nothing when no headphones are available.
function M.targets (outputs, sinks)
  local t = {}
  for _, o in ipairs (outputs or {}) do
    local name = o.name
    if type (name) == "string" and name:sub (-7) == ".output" then
      local sink = name:sub (1, -8)
      if route.is_x20_name (sink) then
        if type (o.target) == "string" and o.target ~= "" then
          t[sink] = o.target
        elseif route.is_headphone_output_name (name) then
          t[sink] = route.pick_headphone_sink (sinks, nil)
        end
      end
    end
  end
  return t
end

-- chain (default, targets) -> { default, stage, ..., hardware }
-- Follows the targets from the default sink while the current sink is an
-- x20 sink. A hardware default gives { default }. An x20 sink without a
-- known target ends the chain early (e.g. x20-headphones with no headphones).
function M.chain (default, targets)
  local chain, seen = {}, {}
  local name = default
  targets = targets or {}
  while type (name) == "string" and name ~= "" and not seen[name]
      and #chain < M.MAX_CHAIN do
    chain[#chain + 1] = name
    seen[name] = true
    if not route.is_x20_name (name) then
      break
    end
    name = targets[name]
  end
  return chain
end

local function sorted_keys (t)
  local keys = {}
  for k in pairs (t or {}) do
    keys[#keys + 1] = k
  end
  table.sort (keys)
  return keys
end

-- decide (a) -> actions, members, reason
--   a = { chain    = M.chain () result (chain[1] is the default sink),
--         previous = { [name] = true }: the members returned by the last
--                    call, nil on the first call (start-up, setting changed),
--         volumes  = { [name] = linear volume }: nil = node not present,
--         saved    = { [name] = linear volume saved before raising it },
--         enabled  = false to only restore (x20.hardware_volume off) }
--   actions = list of { op = "save" | "set" | "forget", node =, volume = }
--             in the order to apply them: restores first, then raises.
--   members = { [name] = true }: the stages handled; pass them back as
--             previous next time. A stage whose node is not present yet is
--             left out, so it is raised once it appears.
function M.decide (a)
  a = a or {}
  local chain = a.chain or {}
  local volumes = a.volumes or {}
  local saved = a.saved or {}
  local actions, members, notes = {}, {}, {}

  local stages = {}
  if a.enabled ~= false then
    for i = 2, #chain do
      stages[chain[i]] = true
    end
  end

  -- 1. Restore every saved sink that is not a stage any more (the default
  -- included: a hardware default gets its own volume back). Only while its
  -- node exists; otherwise keep the entry for later.
  for _, name in ipairs (sorted_keys (saved)) do
    local v = tonumber (saved[name])
    if not stages[name] and v ~= nil and volumes[name] ~= nil then
      actions[#actions + 1] = { op = "set", node = name, volume = v }
      actions[#actions + 1] = { op = "forget", node = name }
      notes[#notes + 1] = "restore " .. name
    end
  end

  -- 2. Raise the stages that entered the chain.
  if a.enabled ~= false then
    for i = 2, #chain do
      local name = chain[i]
      if a.previous and a.previous[name] then
        members[name] = true
      else
        local v = tonumber (volumes[name])
        if v ~= nil then
          members[name] = true
          if v < M.FULL_EPSILON then
            if saved[name] == nil then
              actions[#actions + 1] = { op = "save", node = name, volume = v }
            end
            actions[#actions + 1] = { op = "set", node = name, volume = M.FULL }
            notes[#notes + 1] = "raise " .. name
          end
        else
          notes[#notes + 1] = name .. " not present yet"
        end
      end
    end
  end

  local reason
  if #notes == 0 then
    reason = "nothing to do"
  else
    reason = table.concat (notes, ", ")
  end
  return actions, members, reason
end

-- format_actions (actions) -> "save:spk=0.55;set:spk=1" or "none" (tests, logs)
function M.format_actions (actions)
  local out = {}
  for _, act in ipairs (actions or {}) do
    if act.op == "forget" then
      out[#out + 1] = "forget:" .. act.node
    else
      out[#out + 1] = string.format ("%s:%s=%g", act.op, act.node, act.volume)
    end
  end
  if #out == 0 then
    return "none"
  end
  return table.concat (out, ";")
end

return M
