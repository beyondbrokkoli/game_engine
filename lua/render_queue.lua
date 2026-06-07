local ffi = require("ffi")
local cfg = require("config_engine")
local manifest = require("pipeline_manifest")
local bit = require("bit")

local RenderQueue = {}

-- Hoisted to the module level. Created ONCE. Zero allocations per frame.
local function pack_pass(current_queue_ptr, pass_idx, pass_name, gfx, desc, total_tiles, pc, sc)
    local cmd = current_queue_ptr[pass_idx]
    local pass_cfg = manifest.graphics[pass_name]

    cmd.pipeline_id = ffi.cast("uint64_t", gfx.pipelines[pass_name])
    cmd.descriptor_set = ffi.cast("uint64_t", desc.set0)
    cmd.index_count = (pass_name == "geom") and 36 or 1
    cmd.first_index = 0
    cmd.vertex_offset = 0
    cmd.instance_count = total_tiles
    cmd.first_instance = 0
    cmd.pc_offset = 0
    cmd.pc_size = cfg.cfg.pc_size

    ffi.copy(cmd.push_constants, pc, cfg.cfg.pc_size)
    if pass_name == "points" then
        local pc_ptr = ffi.cast("PushConstants*", cmd.push_constants)
        pc_ptr.target_state = cfg.mode.point_cloud_pass
    end

    cmd.scissor_w = sc.extent.width
    cmd.scissor_h = sc.extent.height
    cmd.cull_mode = pass_cfg.cull_mode
    cmd.front_face = 0
    cmd.topology = pass_cfg.topology
    cmd.depth_test = pass_cfg.depth_test
    cmd.depth_write = pass_cfg.depth_write
    cmd.depth_compare_op = pass_cfg.depth_compare_op

    return pass_idx + 1
end

function RenderQueue.PackFrame(write_idx, pc, rts_grid, vram_template, render_queues, active_render_mode, master_ptr, memory, gfx, desc, sc, total_tiles)
    local FRAME_BYTES = total_tiles * ffi.sizeof("RtsTileInstance")
    local current_frame_offset = write_idx * FRAME_BYTES
    pc.aos_current_idx = current_frame_offset / 4

    local gpu_ptr = ffi.cast("RtsTileInstance*", master_ptr + (current_frame_offset / 4))
    for i = 0, total_tiles - 1 do
        gpu_ptr[i].px = vram_template[i].px
        gpu_ptr[i].pz = vram_template[i].pz
        gpu_ptr[i].py = rts_grid.elevation[i]
        gpu_ptr[i].tile_data = bit.lshift(rts_grid.terrain[i], 24)
    end

    local packet = ffi.C.vx_stream_packet(write_idx)
    local MAX_DRAW_COMMANDS = 1024
    local current_queue_ptr = render_queues + (write_idx * MAX_DRAW_COMMANDS)

    packet.gfx_layout = ffi.cast("uint64_t", gfx.pipelineLayout)
    packet.vertex_buffer = ffi.cast("uint64_t", memory.Buffers["MASTER_GPU_BLOCK"])
    packet.index_buffer = ffi.cast("uint64_t", memory.Buffers["MASTER_INDEX_BLOCK"])
    packet.depth_image = ffi.cast("uint64_t", gfx.depthImage)
    packet.depth_view = ffi.cast("uint64_t", gfx.depthImageView)
    packet.width = sc.extent.width
    packet.height = sc.extent.height

    local draw_count = 0

    if active_render_mode == cfg.mode.dual then
        draw_count = pack_pass(current_queue_ptr, 0, "geom", gfx, desc, total_tiles, pc, sc)
        draw_count = pack_pass(current_queue_ptr, draw_count, "points", gfx, desc, total_tiles, pc, sc)
    elseif active_render_mode == cfg.mode.geom then
        draw_count = pack_pass(current_queue_ptr, 0, "geom", gfx, desc, total_tiles, pc, sc)
    elseif active_render_mode == cfg.mode.points then
        draw_count = pack_pass(current_queue_ptr, 0, "points", gfx, desc, total_tiles, pc, sc)
    end

    packet.draw_queue = current_queue_ptr
    packet.draw_count = draw_count
end

return RenderQueue
