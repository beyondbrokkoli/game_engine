local ffi = require("ffi")
local cfg_net = require("config_net")

local M = {}

-- 1. UNIFIED TYPE SIZE REGISTRY
M.type_sizes = {
    float = 4, uint32_t = 4, int32_t = 4,
    uint64_t = 8, int64_t = 8,
    uint16_t = 2, int16_t = 2,
    uint8_t = 1, int8_t = 1
}

function M.get_base_size(type_str)
    if M.type_sizes[type_str] then return M.type_sizes[type_str] end
    if string.find(type_str, "*") or string.find(type_str, "64") then return 8 end
    if string.find(type_str, "32") or type_str == "float" then return 4 end
    if string.find(type_str, "16") then return 2 end
    if string.find(type_str, "8") then return 1 end
    if string.sub(type_str, 1, 2) == "Vk" or string.sub(type_str, 1, 4) == "PFN_" then return 8 end
    error("[FATAL INVARIANT] Unknown type size requested in SSoT Compiler: " .. tostring(type_str))
end

M.specs = {
    {
        name = "VulkanDeviceContext",
        c_only = true, vk_shield = true, wire_format = false, force_align = false, glsl_std430 = false,
        members = {
            { type = "VkDevice", name = "device" },
            { type = "VkQueue", name = "queue" },
            { type = "VkQueue", name = "transfer_queue" },
            { type = "uint32_t", name = "max_frames_in_flight" },
            { type = "void*", name = "vkWaitForFences" },
            { type = "void*", name = "vkAcquireNextImageKHR" },
            { type = "void*", name = "vkResetFences" },
            { type = "void*", name = "vkQueueSubmit" },
            { type = "void*", name = "vkQueuePresentKHR" },
            { type = "void*", name = "pfnBegin" },
            { type = "void*", name = "pfnEnd" },
            { type = "void*", name = "pfnSetCullMode" },
            { type = "void*", name = "pfnSetFrontFace" },
            { type = "void*", name = "pfnSetPrimitiveTopology" },
            { type = "void*", name = "pfnSetDepthTestEnable" },
            { type = "void*", name = "pfnSetDepthWriteEnable" },
            { type = "void*", name = "pfnSetDepthCompareOp" }
        }
    },
    {
        name = "VulkanSwapchainContext",
        c_only = true, vk_shield = true, wire_format = false, force_align = false, glsl_std430 = false,
        members = {
            { type = "VkSwapchainKHR", name = "swapchain" },
            { type = "uint32_t", name = "status" }, -- 0 = INACTIVE, 1 = ACTIVE, 2 = RETIRING
            { type = "uint64_t", name = "swapchain_images", count = 10 },
            { type = "uint64_t", name = "swapchain_views", count = 10 },
            { type = "VkSemaphore", name = "image_available", count = 3 },
            { type = "VkSemaphore", name = "render_finished", count = 3 },
            { type = "VkFence", name = "in_flight", count = 3 },
            { type = "VkFence", name = "images_in_flight_fences", count = 10 }
        }
    },
    {
        name = "mat4_t", align = 16,
        c_only = false, vk_shield = false, wire_format = false, force_align = false, glsl_std430 = true,
        members = { { type = "float", name = "m", count = 16 } }
    },
    {
        name = "RtsTileInstance", align = 16,
        c_only = false, vk_shield = false, wire_format = false, force_align = false, glsl_std430 = true,
        members = {
            { type = "float", name = "px" },
            { type = "float", name = "py" },
            { type = "float", name = "pz" },
            { type = "uint32_t", name = "tile_data" }
        }
    },
    {
        name = "PushConstants", align = 16,
        c_only = false, vk_shield = false, wire_format = false, force_align = false, glsl_std430 = true,
        members = {
            { type = "mat4_t", name = "viewProj" },
            { type = "uint32_t", name = "aos_current_idx" },
            { type = "uint32_t", name = "aos_prev_idx" },
            { type = "float", name = "dt" },
            { type = "float", name = "total_time" },
            { type = "uint32_t", name = "target_state" },
            { type = "uint32_t", name = "hover_idx" },
            { type = "uint32_t", name = "flags" }
        }
    },
    {
        name = "DrawCommand", align = 8,
        c_only = true, vk_shield = false, wire_format = false, force_align = false, glsl_std430 = false,
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
        name = "RenderPacket", align = 64,
        c_only = true, vk_shield = false, wire_format = false, force_align = true, glsl_std430 = false,
        members = {
            { type = "DrawCommand*", name = "draw_queue" },
            { type = "uint32_t", name = "draw_count" },
            { type = "uint32_t", name = "target_window_id" },
            { type = "uint64_t", name = "gfx_layout" },
            { type = "uint64_t", name = "vertex_buffer" },
            { type = "uint64_t", name = "index_buffer" },
            { type = "uint64_t", name = "depth_image" },
            { type = "uint64_t", name = "depth_view" },
            { type = "uint32_t", name = "width" },
            { type = "uint32_t", name = "height" },
            { type = "uint32_t", name = "swapchain_generation" }
        }
    },
    {
        name = "PlayerCommand", align = 4,
        c_only = true, vk_shield = false, wire_format = true, force_align = true, glsl_std430 = false,
        members = {
            { type = "uint8_t", name = "opcode" },
            { type = "uint8_t", name = "flags" },
            { type = "uint16_t", name = "target_id" },
            { type = "uint32_t", name = "target_pos" }
        }
    },
    {
        name = "LockstepPacket", align = 1,
        c_only = true, vk_shield = false, wire_format = true, force_align = true, glsl_std430 = false,
        members = {
            { type = "uint64_t", name = "session_token" },
            { type = "uint32_t", name = "frame_tick" },
            { type = "uint32_t", name = "checksum_tick" },
            { type = "uint32_t", name = "state_checksum" },
            { type = "uint32_t", name = "base_tick" },
            { type = "uint8_t", name = "player_id" },
            { type = "uint8_t", name = "history_count" },
            { type = "uint16_t", name = "_align_pad" },
            { type = "uint32_t", name = "peer_acks", count = cfg_net.MAX_PLAYERS },
            { type = "PlayerCommand", name = "commands", count = { cfg_net.HISTORY_LEN, 2 } }
        }
    },
    {
        name = "NetworkFrame", align = 4,
        c_only = true, vk_shield = false, wire_format = false, force_align = true, glsl_std430 = false,
        members = {
            { type = "uint32_t", name = "tick" },
            { type = "uint8_t", name = "state" },
            { type = "uint32_t", name = "state_checksum" },
            { type = "uint32_t", name = "remote_checksum" },
            { type = "uint8_t", name = "remote_peer_id" },
            { type = "PlayerCommand", name = "commands", count = { cfg_net.MAX_PLAYERS, 2 } }
        }
    },
    {
        name = "RollbackBuffer", align = 64,
        c_only = true, vk_shield = false, wire_format = false, force_align = true, glsl_std430 = false,
        members = {
            { type = "uint32_t", name = "head_tick" },
            { type = "uint32_t", name = "confirmed_tick" },
            { type = "uint8_t", name = "is_rollback_active" },
            { type = "uint32_t", name = "rollback_target" },
            { type = "NetworkFrame", name = "frames", count = cfg_net.RING_SIZE }
        }
    },
    {
        name = "RxPacket", align = 2,
        c_only = true, vk_shield = false, wire_format = false, force_align = false, glsl_std430 = false,
        members = {
            { type = "uint16_t", name = "len" },
            { type = "uint8_t", name = "data", count = 4096 }
        }
    },
    {
        name = "IcePunchPacket", align = 1,
        c_only = true, vk_shield = false, wire_format = true, force_align = true, glsl_std430 = false,
        members = {
            { type = "uint64_t", name = "session_token" },
            { type = "uint32_t", name = "frame_tick" },
            { type = "uint32_t", name = "checksum_tick" },
            { type = "uint32_t", name = "state_checksum" },
            { type = "uint32_t", name = "base_tick" },
            { type = "uint8_t", name = "player_id" },
            { type = "uint8_t", name = "is_ping" },
            { type = "uint16_t", name = "_align_pad" },
            { type = "uint32_t", name = "padding", count = 3 }
        }
    }
}

-- 2. THE LAYOUT COMPILER & INVARIANT ENFORCER
local function compile_layouts()
    local cdef_builder = ""

    for _, struct in ipairs(M.specs) do
        -- A. STRICT FLAG ENFORCEMENT (Weaponizing Nil)
        assert(struct.c_only ~= nil, "[FATAL] " .. struct.name .. " MUST define 'c_only' (true/false)")
        assert(struct.vk_shield ~= nil, "[FATAL] " .. struct.name .. " MUST define 'vk_shield' (true/false)")
        assert(struct.wire_format ~= nil, "[FATAL] " .. struct.name .. " MUST define 'wire_format' (true/false)")
        assert(struct.force_align ~= nil, "[FATAL] " .. struct.name .. " MUST define 'force_align' (true/false)")
        assert(struct.glsl_std430 ~= nil, "[FATAL] " .. struct.name .. " MUST define 'glsl_std430' (true/false)") -- [NEW]

        -- B. COMPUTE PADDING AND INJECT EXPLICIT FIELDS
        local safe_align = struct.align or 8
        if struct.glsl_std430 then
            safe_align = math.max(safe_align, 16)
        end

        local attr = ""
        if struct.wire_format then
            attr = "__attribute__((packed))"
        elseif struct.force_align then
            attr = string.format("__attribute__((aligned(%d)))", safe_align)
        end

        cdef_builder = cdef_builder .. string.format("typedef struct %s {\n", attr)

        local offset = 0
        local pad_id = 0
        local compiled_members = {}

        for _, m in ipairs(struct.members) do
            local m_size = M.get_base_size(m.type)
            local m_align = m_size

            -- Apply std430 alignment rules
            if struct.glsl_std430 then
                if m.type == "mat4_t" then m_align = 16 end
                if m_align > 16 then m_align = 16 end -- Caps standard base alignment at vec4 boundaries
            end

            if not struct.wire_format then
                local rem = offset % m_align -- [CHANGED: offset % m_align instead of m_size]
                if rem ~= 0 then
                    local pad_bytes = m_align - rem
                    -- INJECT PADDING DIRECTLY INTO THE AST
                    table.insert(compiled_members, { type = "uint8_t", name = "_pad_auto_" .. pad_id, count = pad_bytes, is_pad = true })

                    cdef_builder = cdef_builder .. string.format("    uint8_t _pad_auto_%d[%d];\n", pad_id, pad_bytes)
                    offset = offset + pad_bytes
                    pad_id = pad_id + 1
                end
            end

            -- Keep the original member
            table.insert(compiled_members, m)
            -- Compute size for next offset
            local element_count = 1
            local arr_str = ""
            if type(m.count) == "table" then
                for _, dim in ipairs(m.count) do
                    arr_str = arr_str .. string.format("[%d]", dim)
                    element_count = element_count * dim
                end
            elseif m.count then
                arr_str = string.format("[%d]", m.count)
                element_count = m.count
            end

            local ffi_type = m.type
            if string.sub(ffi_type, 1, 2) == "Vk" or string.sub(ffi_type, 1, 4) == "PFN_" then ffi_type = "void*" end
            cdef_builder = cdef_builder .. string.format("    %s %s%s;\n", ffi_type, m.name, arr_str)

            offset = offset + (M.type_sizes[m.type] and M.type_sizes[m.type] * element_count or m_size * element_count)
        end

        -- C. TAIL PADDING INJECTION
        if not struct.wire_format then
            local tail_rem = offset % safe_align
            if tail_rem ~= 0 then
                local tail_pad = safe_align - tail_rem
                table.insert(compiled_members, { type = "uint8_t", name = "_pad_tail", count = tail_pad, is_pad = true })
                cdef_builder = cdef_builder .. string.format("    uint8_t _pad_tail[%d];\n", tail_pad)
                offset = offset + tail_pad
            end
        end

        -- D. OVERWRITE AST & REGISTER SIZE
        struct.members = compiled_members
        cdef_builder = cdef_builder .. "} " .. struct.name .. ";\n\n"
        M.type_sizes[struct.name] = offset
    end

    ffi.cdef(cdef_builder)
end

-- Run the compiler immediately upon require
compile_layouts()

return M
