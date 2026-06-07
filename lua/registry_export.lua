local cfg = require("config_engine")
local reg = require("registry_vk")
local structs_mod = require("structs") -- Pulling from the new SSOT

local function get_sorted_keys(t)
    local keys = {}
    for k in pairs(t) do table.insert(keys, k) end
    table.sort(keys)
    return keys
end

local function map_glsl_type(type_str)
    if type_str == "float" then return "float" end
    if string.find(type_str, "mat4") then return "mat4" end
    return "uint" -- Default primitive integer mapping for our GLSL pipeline
end

local function generate_ssot(glsl_path, c_header_path)
    local glsl = io.open(glsl_path, "w")
    local c_hdr = io.open(c_header_path, "w")

    -- 1. HEADER SETUP
    glsl:write("// AUTO-GENERATED SSoT - DO NOT MODIFY\n")
    glsl:write("#ifndef REGISTRY_GLSL\n#define REGISTRY_GLSL\n\n")
    c_hdr:write("// AUTO-GENERATED SSoT - DO NOT MODIFY\n")
    c_hdr:write("#pragma once\n#include <stdint.h>\n\n")

    -- 2. ENUMS & CONSTANTS
    glsl:write("// --- CONSTANTS ---\n")
    c_hdr:write("// --- ENGINE CONSTANTS ---\n")

    local mode_keys = get_sorted_keys(cfg.mode)
    for _, k in ipairs(mode_keys) do
        glsl:write(string.format("const uint MODE_%s = %dU;\n", string.upper(k), cfg.mode[k]))
        c_hdr:write(string.format("#define MODE_%s %d\n", string.upper(k), cfg.mode[k]))
    end

    local cfg_keys = get_sorted_keys(cfg.cfg)
    for _, k in ipairs(cfg_keys) do
        glsl:write(string.format("const uint CFG_%s = %dU;\n", string.upper(k), cfg.cfg[k]))
        c_hdr:write(string.format("#define CFG_%s %d\n", string.upper(k), cfg.cfg[k]))
    end

    -- [NEW] Export Network States to C-Core
    local net_keys = get_sorted_keys(cfg.net_state)
    for _, k in ipairs(net_keys) do
        c_hdr:write(string.format("#define FRAME_STATE_%s %d\n", string.upper(k), cfg.net_state[k]))
    end

    -- [NEW] Injecting the Dimensional Manifesto
    local world_keys = get_sorted_keys(cfg.world)
    for _, k in ipairs(world_keys) do
        local val = cfg.world[k]
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

    -- 3. INTERLOCKING ALIGNMENT REGISTRY
    -- Seed known base primitives into local dictionary for type scanning
    local dynamic_sizes = {
        float = 4, uint32_t = 4, int32_t = 4,
        uint64_t = 8, int64_t = 8,
        uint16_t = 2, int16_t = 2,
        uint8_t = 1, int8_t = 1
    }

    local function resolve_member_size(type_str)
        if dynamic_sizes[type_str] then return dynamic_sizes[type_str] end
        if string.find(type_str, "*") then return 8 end
        if string.find(type_str, "64") then return 8 end
        if string.find(type_str, "32") or type_str == "float" then return 4 end
        if string.find(type_str, "16") then return 2 end
        if string.find(type_str, "8") then return 1 end
        return 64 -- Fallback for opaque layout elements
    end

    glsl:write("\n// --- std430 SSBO DEFINITIONS ---\n")

    -- Iterate over the specs table from structs.lua
    for _, struct in ipairs(structs_mod.specs) do
        -- C-Side Generation
        local attr = struct.force_align and "__attribute__((packed, aligned("..struct.align..")))" or "__attribute__((packed))"
        c_hdr:write(string.format("typedef struct %s {\n", attr))

        -- GLSL-Side Generation
        if not struct.c_only then
            glsl:write(string.format("struct %s {\n", struct.name))
        end

        local offset = 0
        local pad_id = 0

        for _, m in ipairs(struct.members) do
            local m_size = resolve_member_size(m.type)

            -- Detect Alignment Fracture & Force Padding Injection
            local rem = offset % m_size
            if rem ~= 0 then
                local pad_bytes = m_size - rem
                c_hdr:write(string.format("    uint8_t _pad_auto_%d[%d];\n", pad_id, pad_bytes))
                if not struct.c_only then
                    glsl:write(string.format("    // Engine injected %d pad bytes for std430\n", pad_bytes))
                end
                offset = offset + pad_bytes
                pad_id = pad_id + 1
            end

            -- Write Out Core Member Layouts
            local c_arr = m.count and string.format("[%d]", m.count) or ""
            c_hdr:write(string.format("    %s %s%s;\n", m.type, m.name, c_arr))

            if not struct.c_only then
                local glsl_type = map_glsl_type(m.type)
                local glsl_arr = m.count and string.format("[%d]", m.count) or ""
                glsl:write(string.format("    %s %s%s;\n", glsl_type, m.name, glsl_arr))
            end

            offset = offset + (m_size * (m.count or 1))
        end

        -- Tail Padding Enforcement to Clean Structure Boundaries
        local tail_rem = offset % struct.align
        if tail_rem ~= 0 then
            local tail_pad = struct.align - tail_rem
            c_hdr:write(string.format("    uint8_t _pad_tail[%d];\n", tail_pad))
            if not struct.c_only then
                glsl:write(string.format("    // Tail padded by %d bytes\n", tail_pad))
            end
            offset = offset + tail_pad
        end

        c_hdr:write("} " .. struct.name .. ";\n\n")
        if not struct.c_only then
            glsl:write("};\n\n")
        end

        -- Register calculated size block so child arrays evaluate with perfect dimension scale
        dynamic_sizes[struct.name] = offset
    end

    -- 4. VULKAN HOST INTERFACES INJECTION
    c_hdr:write("#ifdef VX_ENABLE_VULKAN_STRUCTS\n")
    c_hdr:write(reg.c_vk_structs)
    c_hdr:write("\n#endif // VX_ENABLE_VULKAN_STRUCTS\n")

    glsl:write("#endif // REGISTRY_GLSL\n")
    glsl:close()
    c_hdr:close()

    print("[LUA SSOT] Alignment Manifesto Enforced. Header and GLSL Generated.")
end

return { generate = generate_ssot }
