--engine_api.lua
local ffi = require("ffi")
-- Assuming core_abi.lua has already been required by main.lua

local EngineAPI = {}
function EngineAPI.is_running()
    return ffi.C.vx_core_is_running() == 1
end
function EngineAPI.acquire_render_packet()
    return ffi.C.vx_stream_acquire()
end
function EngineAPI.get_render_packet(idx)
    return ffi.cast("RenderPacket*", ffi.C.vx_stream_packet(idx))
end
function EngineAPI.commit_render_packet(idx)
    ffi.C.vx_stream_commit(idx)
end
function EngineAPI.publish_instance(win_id, instance_ptr)
    ffi.C.vx_sys_publish_instance(win_id, instance_ptr)
end
function EngineAPI.shutdown()
    ffi.C.vx_core_shutdown()
end
function EngineAPI.mark_finished()
    ffi.C.vx_core_mark_finished()
end
function EngineAPI.kill_thread()
    ffi.C.vx_thread_kill()
end
function EngineAPI.init_stream(win_id, wsi_ptr)
    ffi.C.vx_stream_init(win_id, wsi_ptr)
end
function EngineAPI.start_thread()
    ffi.C.vx_thread_start()
end
function EngineAPI.setup_transfer(q_family_index)
    ffi.C.vx_transfer_setup(q_family_index)
end
function EngineAPI.request_transfer(src, dst, size, t_sem, sig_val)
    return ffi.C.vx_transfer_request(src, dst, size, t_sem, sig_val)
end
return EngineAPI
