local structs_mod = require("structs")
local cfg_gfx = nil; pcall(function() cfg_gfx = require("config_gfx") end)
local cfg_sim = nil; pcall(function() cfg_sim = require("config_sim") end)
local cfg_net = nil; pcall(function() cfg_net = require("config_net") end)

local function enforce_strict_invariants(specs)
    print(" |- [HARNESS] Running Invariant Asserts...")
    local found_structs = {}
    for _, struct in ipairs(specs) do found_structs[struct.name] = struct end

    -- --- NEW: Device Context Check ---
    local dev_ctx = found_structs["VulkanDeviceContext"]
    assert(dev_ctx, "[FATAL] Gremlin removed VulkanDeviceContext!")

    -- --- NEW: Volatile WSI Context Check ---
    local wsi_ctx = found_structs["VulkanSwapchainContext"]
    assert(wsi_ctx, "[FATAL] Gremlin removed VulkanSwapchainContext!")

    local wsi_found, swapchain_arr_found = false, false
    for _, m in ipairs(wsi_ctx.members) do
        if m.name == "swapchain" and m.type == "VkSwapchainKHR" then wsi_found = true end
        if m.name == "swapchain_images" and m.count == 10 then swapchain_arr_found = true end
    end
    assert(wsi_found, "[FATAL INVARIANT] VulkanSwapchainContext missing VkSwapchainKHR. Mux broken!")
    assert(swapchain_arr_found, "[FATAL INVARIANT] VulkanSwapchainContext swapchain_images missing/altered!")

    -- --- Keep RenderPacket Check ---
    local r_packet = found_structs["RenderPacket"]
    assert(r_packet, "[FATAL] Gremlin removed RenderPacket!")
    local target_win_found = false
    for _, m in ipairs(r_packet.members) do
        if m.name == "target_window_id" and m.type == "uint32_t" then target_win_found = true end
    end
    assert(target_win_found, "[FATAL INVARIANT] RenderPacket missing 'target_window_id'.")
    assert(r_packet.force_align and r_packet.align == 64, "[FATAL INVARIANT] RenderPacket not 64-byte aligned!")

    -- --- Keep Lockstep Check ---
    local lockstep = found_structs["LockstepPacket"]
    assert(lockstep, "[FATAL] Gremlin removed LockstepPacket!")
    assert(lockstep.wire_format == true, "[FATAL INVARIANT] LockstepPacket not wire_format!")
    assert(lockstep.align == 1, "[FATAL INVARIANT] LockstepPacket not 1-byte aligned!")

    print(" |- [HARNESS] All system-critical invariants passed.")
end

local function get_sorted_keys(t)
    local keys = {}
    for k in pairs(t) do table.insert(keys, k) end
    table.sort(keys)
    return keys
end

local function map_glsl_type(type_str)
    if type_str == "float" then return "float" end
    if string.find(type_str, "mat4") then return "mat4" end
    return "uint"
end

local function generate_ssot(glsl_path, c_header_path)
    enforce_strict_invariants(structs_mod.specs)

    local glsl = io.open(glsl_path, "w")
    local c_hdr = io.open(c_header_path, "w")

    glsl:write("// AUTO-GENERATED SSoT - DO NOT MODIFY\n")
    glsl:write("#ifndef REGISTRY_GLSL\n#define REGISTRY_GLSL\n\n")
    c_hdr:write("// AUTO-GENERATED SSoT - DO NOT MODIFY\n")
    c_hdr:write("#pragma once\n#include <stdint.h>\n\n")

    glsl:write("// --- CONSTANTS ---\n")
    c_hdr:write("// --- ENGINE CONSTANTS ---\n")

    if cfg_gfx and cfg_gfx.mode then
        for _, k in ipairs(get_sorted_keys(cfg_gfx.mode)) do
            glsl:write(string.format("const uint MODE_%s = %dU;\n", string.upper(k), cfg_gfx.mode[k]))
            c_hdr:write(string.format("#define MODE_%s %d\n", string.upper(k), cfg_gfx.mode[k]))
        end
    end
    if cfg_net and cfg_net.net_state then
        for _, k in ipairs(get_sorted_keys(cfg_net.net_state)) do
            c_hdr:write(string.format("#define FRAME_STATE_%s %d\n", string.upper(k), cfg_net.net_state[k]))
        end
    end
    if cfg_sim and cfg_sim.world then
        for _, k in ipairs(get_sorted_keys(cfg_sim.world)) do
            local val = cfg_sim.world[k]
            if type(val) == "number" then
                if math.floor(val) == val then
                    glsl:write(string.format("const uint WORLD_%s = %dU;\n", string.upper(k), val))
                    c_hdr:write(string.format("#define WORLD_%s %d\n", string.upper(k), val))
                else
                    glsl:write(string.format("const float WORLD_%s = %.1f;\n", string.upper(k), val))
                    c_hdr:write(string.format("#define WORLD_%s %.1ff\n", string.upper(k), val))
                end
            end
        end
    end

    c_hdr:write("\n// --- ENGINE MEMORY STRUCTURES ---\n")
    glsl:write("\n// --- std430 SSBO DEFINITIONS ---\n")

    for _, struct in ipairs(structs_mod.specs) do
        local is_glsl = not struct.c_only and not struct.wire_format
        if struct.vk_shield then c_hdr:write("#ifdef VX_ENABLE_VULKAN_STRUCTS\n") end

        if struct.wire_format then
            c_hdr:write("#pragma pack(push, 1)\n")
            c_hdr:write(string.format("typedef struct {\n"))
        else
            local attr = struct.force_align and string.format("__attribute__((aligned(%d)))", struct.align or 8) or ""
            c_hdr:write(string.format("typedef struct %s {\n", attr))
        end

        if is_glsl then glsl:write(string.format("struct %s {\n", struct.name)) end

        for _, m in ipairs(struct.members) do
            local arr_str = ""
            if type(m.count) == "table" then
                for _, dim in ipairs(m.count) do arr_str = arr_str .. string.format("[%d]", dim) end
            elseif m.count then
                arr_str = string.format("[%d]", m.count)
            end

            c_hdr:write(string.format("    %s %s%s;\n", m.type, m.name, arr_str))

            if is_glsl then
                if m.is_pad then
                    glsl:write(string.format("    // Engine injected pad: %s[%s]\n", m.type, tostring(m.count)))
                else
                    local glsl_type = map_glsl_type(m.type)
                    glsl:write(string.format("    %s %s%s;\n", glsl_type, m.name, arr_str))
                end
            end
        end

        if struct.wire_format then
            c_hdr:write("} " .. struct.name .. ";\n#pragma pack(pop)\n\n")
        else
            c_hdr:write("} " .. struct.name .. ";\n\n")
        end

        if struct.vk_shield then c_hdr:write("#endif // VX_ENABLE_VULKAN_STRUCTS\n\n") end
        if is_glsl then glsl:write("};\n\n") end
    end

    glsl:write("#endif // REGISTRY_GLSL\n")
    glsl:close()
    c_hdr:close()
    print("[LUA SSOT] Dual-Domain Architecture SSoT Generated successfully.")
end

return { generate = generate_ssot }
