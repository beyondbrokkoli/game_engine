local ffi = require("ffi")

local M = {}

-- Sizing registry to handle primitive and custom structures dynamically
local struct_sizes = {
    float = 4, uint32_t = 4, int32_t = 4,
    uint64_t = 8, int64_t = 8,
    uint16_t = 2, int16_t = 2,
    uint8_t = 1, int8_t = 1
}

local function get_base_size(type_str)
    if struct_sizes[type_str] then return struct_sizes[type_str] end
    if string.find(type_str, "*") then return 8 end
    if string.find(type_str, "64") then return 8 end
    if string.find(type_str, "32") or type_str == "float" then return 4 end
    if string.find(type_str, "16") then return 2 end
    if string.find(type_str, "8") then return 1 end
    return 64 -- Fallback for unparsed raw blocks (e.g. mat4_t)
end

M.specs = {
    {
        name = "mat4_t", glsl = "mat4", align = 16,
        members = { { type = "float", name = "m", count = 16 } }
    },
    {
        name = "RtsTileInstance", glsl = "RtsTileInstance", align = 16,
        members = {
            { type = "float", name = "px" },
            { type = "float", name = "py" },
            { type = "float", name = "pz" },
            { type = "uint32_t", name = "tile_data" }
        }
    },
    {
        name = "PushConstants", glsl = "PushConstants", align = 16,
        members = {
            { type = "mat4_t",   name = "viewProj" },
            { type = "uint32_t", name = "aos_current_idx" },
            { type = "uint32_t", name = "aos_prev_idx" },
            { type = "float",    name = "dt" },
            { type = "float",    name = "total_time" },
            { type = "uint32_t", name = "target_state" },
            { type = "uint32_t", name = "hover_idx" },
            { type = "uint32_t", name = "flags" }
        }
    },
    {
        name = "DrawCommand", c_only = true, align = 8,
        members = {
            { type = "uint64_t", name = "pipeline_id" },
            { type = "uint64_t", name = "descriptor_set" },
            { type = "uint32_t", name = "index_count" },
            { type = "uint32_t", name = "instance_count" },
            { type = "uint32_t", name = "first_index" },
            { type = "int32_t", name = "vertex_offset" },
            { type = "uint32_t", name = "first_instance" },
            { type = "uint16_t", name = "pc_offset" },
            { type = "uint16_t", name = "pc_size" },
            { type = "uint8_t", name = "push_constants", count = 128 },
            { type = "int16_t", name = "scissor_x" },
            { type = "int16_t", name = "scissor_y" },
            { type = "uint16_t", name = "scissor_w" },
            { type = "uint16_t", name = "scissor_h" },
            { type = "uint8_t", name = "cull_mode" },
            { type = "uint8_t", name = "depth_test" },
            { type = "uint8_t", name = "depth_write" },
            { type = "uint8_t", name = "depth_compare_op" },
            { type = "uint8_t", name = "front_face" },
            { type = "uint8_t", name = "topology" }
        }
    },
    {
        name = "RenderPacket", c_only = true, align = 64, force_align = true,
        members = {
            { type = "DrawCommand*", name = "draw_queue" },
            { type = "uint32_t", name = "draw_count" },
            { type = "uint64_t", name = "gfx_layout" },
            { type = "uint64_t", name = "vertex_buffer" },
            { type = "uint64_t", name = "index_buffer" },
            { type = "uint64_t", name = "swapchain_image" },
            { type = "uint64_t", name = "swapchain_view" },
            { type = "uint64_t", name = "depth_image" },
            { type = "uint64_t", name = "depth_view" },
            { type = "uint32_t", name = "width" },
            { type = "uint32_t", name = "height" }
        }
    },
    {
        name = "LockstepPacket", c_only = true, align = 8, force_align = true,
        members = {
            { type = "uint64_t", name = "session_token" }, -- The crypto handshake key
            { type = "uint32_t", name = "frame_tick" },
            { type = "uint32_t", name = "player_input" },
            { type = "int32_t", name = "click_grid_idx" },
            { type = "uint32_t", name = "past_inputs", count = 7 },
            { type = "int32_t", name = "past_clicks", count = 7 }
        }
    },
    -- [NEW] Rollback Network Engine Core Containment Types
    {
        name = "RollbackFrame", c_only = true, align = 4, force_align = true,
        members = {
            { type = "uint32_t", name = "tick" },
            { type = "uint32_t", name = "local_input" },
            { type = "uint32_t", name = "remote_input" },
            { type = "int32_t", name = "local_click" },  -- [RENAMED]
            { type = "int32_t", name = "remote_click" }, -- [NEW] The missing variable
            { type = "uint8_t", name = "state" }
        }
    },
    {
        name = "RollbackBuffer", c_only = true, align = 64, force_align = true,
        members = {
            { type = "RollbackFrame", name = "frames", count = 128 },
            { type = "uint32_t", name = "head_tick" },
            { type = "uint32_t", name = "confirmed_tick" },
            { type = "uint32_t", name = "rollback_target" },
            { type = "uint32_t", name = "is_rollback_active" }
        }
    }
}

-- Code Generation and FFI Binding Setup
local cdef_builder = ""
for _, struct in ipairs(M.specs) do
    local attr = struct.force_align and "__attribute__((packed, aligned("..struct.align..")))" or "__attribute__((packed))"
    cdef_builder = cdef_builder .. string.format("typedef struct %s {\n", attr)

    local offset = 0
    local pad_id = 0
    for _, m in ipairs(struct.members) do
        local m_size = get_base_size(m.type)

        -- Memory Alignment Offset Check
        local rem = offset % m_size
        if rem ~= 0 then
            local pad_bytes = m_size - rem
            cdef_builder = cdef_builder .. string.format("    uint8_t _pad_%d[%d];\n", pad_id, pad_bytes)
            offset = offset + pad_bytes
            pad_id = pad_id + 1
        end

        local arr = m.count and string.format("[%d]", m.count) or ""
        cdef_builder = cdef_builder .. string.format("    %s %s%s;\n", m.type, m.name, arr)
        offset = offset + (m_size * (m.count or 1))
    end

    -- Structure Boundary Alignment Check
    local tail_rem = offset % struct.align
    if tail_rem ~= 0 then
        local tail_pad = struct.align - tail_rem
        cdef_builder = cdef_builder .. string.format("    uint8_t _pad_tail[%d];\n", tail_pad)
        offset = offset + tail_pad
    end

    cdef_builder = cdef_builder .. "} " .. struct.name .. ";\n\n"
    struct_sizes[struct.name] = offset -- Feed structural footprint back into registry
end

ffi.cdef(cdef_builder)

return M
