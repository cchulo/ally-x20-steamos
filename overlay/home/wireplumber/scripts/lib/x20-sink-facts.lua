-- SPDX-License-Identifier: GPL-2.0-only
-- ally-x20-steamos: graph facts about a sink node for x20-route-core.lua,
-- shared by x20-route-by-channels.lua (link target of the headphone surround
-- outputs) and x20-select-default-sink.lua (automatic default sink), so both
-- classify a device the same way.
--
-- WirePlumber 0.5 glue (needs the WirePlumber Lua API); loaded with
-- require ("x20-sink-facts") from ~/.local/share/wireplumber/scripts/lib/.

local cutils = require ("common-utils")

local M = {}

-- active_routes (props, devices_om) : the active output routes of the
-- device behind a sink node: the device's "Route" params for the node's
-- card.profile.device, the same lookup linking-utils.haveAvailableRoutes
-- does. Empty for nodes without a device (virtual sinks, most Bluetooth).
function M.active_routes (props, devices_om)
  local routes = {}
  local device_id = props ["device.id"]
  if not device_id then
    return routes
  end
  devices_om = devices_om or cutils.get_object_manager ("device")
  local device = devices_om:lookup {
    Constraint { "bound-id", "=", device_id, type = "gobject" },
  }
  if not device then
    return routes
  end
  local card_dev = tonumber (props ["card.profile.device"])
  for param in device:iterate_params ("Route") do
    local r = cutils.parseParam (param, "Route")
    if r and (card_dev == nil or r.device == card_dev) then
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

-- sink (props, devices_om) : the plain table x20-route-core expects for a
-- sink node, from its properties.
function M.sink (props, devices_om)
  local name = props ["node.name"]
  local routes = {}
  if name and name:sub (1, 4) ~= "x20-" then
    routes = M.active_routes (props, devices_om)
  end
  return {
    name = name,
    priority = tonumber (props ["priority.session"]) or 0,
    form_factor = props ["device.form-factor"],
    api = props ["device.api"],
    routes = routes,
  }
end

return M
