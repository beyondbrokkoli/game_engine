-- lua/window_api.lua
local ffi = require("ffi")
-- Assuming core_abi.lua has already been required by main.lua

local WindowAPI = {}
function WindowAPI.boot(win_id, w, h)
    ffi.C.vx_sys_set_cmd(win_id, 1, w, h)
end
function WindowAPI.is_mouse_down(win_id, button)
    return ffi.C.vx_input_mouse_btn(win_id, button) == 1
end
function WindowAPI.get_mouse_pos(win_id)
    return ffi.C.vx_input_mouse_x(win_id), ffi.C.vx_input_mouse_y(win_id)
end
function WindowAPI.is_key_down(win_id, keycode)
    return ffi.C.vx_input_last_key(win_id) == keycode
end
function WindowAPI.get_surface(win_id)
    return ffi.C.vx_sys_get_surface(win_id)
end
function WindowAPI.destroy(win_id)
    ffi.C.vx_sys_set_cmd(win_id, 2, 0, 0)
end
-- Replace WindowAPI.was_resized with:
function WindowAPI.get_resize_state(win_id)
    return ffi.C.vx_sys_get_resize_state(win_id) == 1
end

-- Add this new helper to trigger Phase 2 rebuild
function WindowAPI.trigger_wsi_rebuild(win_id)
    ffi.C.vx_sys_set_cmd(win_id, 3, 0, 0) -- 3 = CMD_REBUILD_WSI
end
local _w_ptr = ffi.new("int[1]")
local _h_ptr = ffi.new("int[1]")
function WindowAPI.get_window_size(win_id)
    ffi.C.vx_sys_window_size(win_id, _w_ptr, _h_ptr)
    return _w_ptr[0], _h_ptr[0]
end
function WindowAPI.get_click_pos(win_id)
    return ffi.C.vx_input_click_x(win_id), ffi.C.vx_input_click_y(win_id)
end
function WindowAPI.get_mouse_delta(win_id)
    return ffi.C.vx_input_mouse_dx(win_id), ffi.C.vx_input_mouse_dy(win_id)
end
function WindowAPI.get_wasd_mask(win_id)
    return ffi.C.vx_input_wasd(win_id)
end
function WindowAPI.get_last_key(win_id)
    return ffi.C.vx_input_last_key(win_id)
end
function WindowAPI.is_captured(win_id)
    return ffi.C.vx_input_is_captured(win_id) == 1
end
function WindowAPI.is_spacebar_down(win_id)
    return ffi.C.vx_input_spacebar(win_id) == 1
end
return WindowAPI
