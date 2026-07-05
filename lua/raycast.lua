local ffi = require("ffi")
local vmath = require("vmath")
local Fixed = require("fixed_math")
local cfg_sim = require("config_sim")

local Raycast = {}

-- [FIX APPLIED] Removed root-level temp_vec_near and temp_vec_far

function Raycast.matrix_raycast_terrain(mouse_x, mouse_y, screen_w, screen_h, viewProj_inv, grid, net_identity)
    -- [FIX APPLIED] Local allocation. LuaJIT sinks these to registers.
    local temp_vec_near = ffi.new("vec4_t")
    local temp_vec_far = ffi.new("vec4_t")

    local nx = (mouse_x / screen_w) * 2.0 - 1.0
    local ny = (mouse_y / screen_h) * 2.0 - 1.0

    vmath.multiply_mat4_vec4(viewProj_inv, nx, ny, 0.0, 1.0, temp_vec_near)
    vmath.multiply_mat4_vec4(viewProj_inv, nx, ny, 1.0, 1.0, temp_vec_far)

    local near_w = 1.0 / temp_vec_near.w
    local ox, oy, oz = temp_vec_near.x * near_w, temp_vec_near.y * near_w, temp_vec_near.z * near_w

    local far_w = 1.0 / temp_vec_far.w
    local fx, fy, fz = temp_vec_far.x * far_w, temp_vec_far.y * far_w, temp_vec_far.z * far_w

    local dx, dy, dz = fx - ox, fy - oy, fz - oz
    local inv_mag = 1.0 / math.sqrt(dx^2 + dy^2 + dz^2)
    dx, dy, dz = dx * inv_mag, dy * inv_mag, dz * inv_mag

    local t = 0.0
    if dy < 0.0 then
        local dist_to_ceiling = (10.0 - oy) / dy
        if dist_to_ceiling > 0.0 then t = dist_to_ceiling end
    end

    for _ = 1, 100 do
        local px = ox + dx * t
        local py = oy + dy * t
        local pz = oz + dz * t

        local grid_x = math.floor((px + cfg_sim.world.offset_x) / cfg_sim.world.spacing + 0.5)
        local grid_z = math.floor((pz + cfg_sim.world.offset_z) / cfg_sim.world.spacing + 0.5)

        if grid_x >= 0 and grid_x < cfg_sim.world.map_width and grid_z >= 0 and grid_z < cfg_sim.world.map_height then
            local idx = grid_z * cfg_sim.world.map_width + grid_x

            local max_elevation = 0
            for peer = 0, 7 do
                local peer_elev = grid.elevation[peer][idx]
                if peer_elev > max_elevation then
                    max_elevation = peer_elev
                end
            end

            local float_elevation = Fixed.to_float(max_elevation)
            if py <= float_elevation + 0.1 then return idx end
        end
        t = t + (cfg_sim.world.spacing * 0.1)
    end
    return 65535
end

return Raycast
