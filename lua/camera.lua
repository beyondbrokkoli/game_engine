local ffi = require("ffi")
local math = require("math")
local bit = require("bit")
local vmath = require("vmath")

local Camera = {}

function Camera.new()
    return {
        ortho_zoom = 250.0,
        yaw = 0.785398,
        pitch = 0.615472,
        pos = { x = 0.0, y = 0.0, z = 0.0 },
        move_speed = 850.0,
        proj = ffi.new("mat4_t"),
        view = ffi.new("mat4_t")
    }
end

function Camera.update(cam, frame_time, mouse_x, mouse_y, width, height)
    local EDGE_THRESHOLD = 40.0
    local pan_x, pan_z = 0.0, 0.0

    if ffi.C.vx_input_is_captured() == 1 then
        if mouse_x < EDGE_THRESHOLD then pan_x = -1.0
        elseif mouse_x > width - EDGE_THRESHOLD then pan_x = 1.0 end

        if mouse_y < EDGE_THRESHOLD then pan_z = -1.0
        elseif mouse_y > height - EDGE_THRESHOLD then pan_z = 1.0 end
    end

    local fwd_x = math.sin(cam.yaw)
    local fwd_z = math.cos(cam.yaw)
    local right_x = math.cos(cam.yaw)
    local right_z = -math.sin(cam.yaw)

    local frame_speed = cam.move_speed * frame_time
    cam.pos.x = cam.pos.x + (right_x * pan_x + fwd_x * -pan_z) * frame_speed
    cam.pos.z = cam.pos.z + (right_z * pan_x + fwd_z * -pan_z) * frame_speed

    local wasd = ffi.C.vx_input_wasd()
    local zoom_dir = 0
    if bit.band(wasd, 16) ~= 0 then zoom_dir = -1 end
    if bit.band(wasd, 32) ~= 0 then zoom_dir = 1 end

    if zoom_dir ~= 0 then
        cam.ortho_zoom = cam.ortho_zoom * math.exp(zoom_dir * frame_time * 3.0)
        cam.ortho_zoom = math.max(200.0, math.min(25000.0, cam.ortho_zoom))
    end
end

function Camera.get_matrices(cam, width, height, out_viewProj, out_invViewProj)
    local aspect = width / math.max(1, height)
    vmath.ortho_vk(-cam.ortho_zoom * aspect, cam.ortho_zoom * aspect, -cam.ortho_zoom, cam.ortho_zoom, -10000.0, 10000.0, cam.proj)

    local look_x = math.sin(cam.yaw) * math.cos(cam.pitch)
    local look_y = -math.sin(cam.pitch)
    local look_z = math.cos(cam.yaw) * math.cos(cam.pitch)

    vmath.lookAt(cam.pos.x, cam.pos.y, cam.pos.z, cam.pos.x + look_x, cam.pos.y + look_y, cam.pos.z + look_z, cam.view)

    vmath.multiply_mat4(cam.proj, cam.view, out_viewProj)
    vmath.inverse_mat4(out_viewProj, out_invViewProj)
end

return Camera
