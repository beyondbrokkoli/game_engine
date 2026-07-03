local function minify_c(content)
    content = content:gsub("/%*.-%*/", "")
    local minified_string = ""
    local in_multiline_macro = false

    for line in content:gmatch("[^\r\n]+") do
        local clean_line = line
        local s = clean_line:find("//", 1, true)
        if s then
            local prefix = clean_line:sub(1, s - 1)
            local _, quote_count = prefix:gsub('"', '"')
            if quote_count % 2 == 0 then clean_line = prefix end
        end

        clean_line = clean_line:gsub("[ \t]+", " ")
        clean_line = clean_line:match("^%s*(.-)%s*$")

        if clean_line ~= "" then
            if clean_line:sub(1, 1) == "#" or in_multiline_macro then
                minified_string = minified_string .. clean_line .. "\n"
                in_multiline_macro = (clean_line:sub(-1) == "\\")
            else
                minified_string = minified_string .. clean_line .. " "
            end
        end
    end
    if minified_string == "" then return "/* [EMPTY] */" end
    return minified_string
end

local function minify_lua(content)
    local lines = {}
    local d = "\45" .. "\45"
    for line in content:gmatch("[^\r\n]+") do
        local s = line:find(d, 1, true)
        local clean_line = line
        if s then
            local prefix = line:sub(1, s - 1)
            local _, quote_count = prefix:gsub('"', '"')
            if quote_count % 2 == 0 then clean_line = prefix end
        end
        clean_line = clean_line:gsub("[ \t]+", " ")
        clean_line = clean_line:match("^%s*(.-)%s*$")
        if clean_line ~= "" then table.insert(lines, clean_line) end
    end
    if #lines == 0 then return "-- [EMPTY] --" end
    return table.concat(lines, "; ")
end

local function get_sorted_files()
    local sorted = {}
    local visited = {}

    local function visit(file)
        if visited[file] then return end
        visited[file] = true

        local f = io.open(file, "r")
        if f then
            local content = f:read("*all")
            f:close()
            for dep_match in content:gmatch('require%s*%(?%s*["\'](.-)["\']%s*%)?') do
                local dep_name = dep_match:gsub("%.", "/")
                if not dep_name:find("%.lua$") then dep_name = dep_name .. ".lua" end
                visit(dep_name)
            end
        end
        table.insert(sorted, file)
    end

    -- Automatically trace dependencies starting from main.lua
    visit("main.lua")
    return sorted
end

-- EXECUTION & MANUAL FILE SELECTION MATRIX
-- Comment out (--) any file you DO NOT want included in the snapshot.

print("--- AI SNAPSHOT ---")

local order = {
    -- 1. C-CORE & HEADERS (Absolute Foundation)
--     "c/shared_structs.h",
--     "c/vx_global_state.h",
--     "c/vx_vulkan_core.h",
--     "c/vx_vulkan_render.h",
--     "c/vx_glfw_multiplexer.h",
--     "c/vx_global_state.c",
--     "c/vx_vulkan_core.c",
--     "c/vx_glfw_multiplexer.c",
--     "c/vx_vulkan_render.c",
--     "c/vx_net.c",
--     "c/main.c",

    -- 2. GLSL SHADERS & SSOT
    -- "glsl/shared.glsl",
    -- "glsl/registry.glsl",
    -- "glsl/render.vert",
    -- "glsl/render.frag",

--    -- 3. LUA LEAVES (Level 0: Zero Internal Dependencies)
--    "lua/config_engine.lua",
    "lua/config_gfx.lua",
--    "lua/config_net.lua",
--    "lua/config_sim.lua",
--    "lua/core_abi.lua",
--    "lua/dkjson.lua",
--    "lua/engine_api.lua",
--    "lua/fixed_math.lua",
--    "lua/network.lua",
    "lua/pipeline_manifest.lua",
--    "lua/vmath.lua",
--    "lua/vulkan_headers.lua",
--    "lua/window_api.lua",

--    -- 4. LUA LEVEL 1 (Depends strictly on Level 0)
--    "lua/camera.lua",          -- Needs vmath, window_api, config_gfx
--    "lua/fsm_core.lua",        -- Needs network
--    "lua/game_state.lua",      -- Needs network, fixed_math
--    "lua/input_core.lua",      -- Needs config_net
--    "lua/json_util.lua",       -- Needs dkjson
--    "lua/net_pump.lua",        -- Needs network
--    "lua/raycast.lua",         -- Needs vmath, fixed_math, config_sim
    "lua/registry_vk.lua",     -- Needs vulkan_headers
--    "lua/render_queue.lua",    -- Needs pipeline_manifest, fixed_math, engine_api, config_gfx
    "lua/structs.lua",         -- Needs config_net

--    -- 5. LUA LEVEL 2 (Depends on Level 1)
--    "lua/compute_pipeline.lua",  -- Needs registry_vk
--    "lua/descriptors.lua",       -- Needs registry_vk
--    "lua/graphics_pipeline.lua", -- Needs registry_vk
--    "lua/memory.lua",            -- Needs registry_vk
--    "lua/net_utils.lua",         -- Needs json_util, config_net, network
--    "lua/registry_export.lua",   -- Needs structs, config_gfx, config_sim, config_net
    "lua/renderer.lua",          -- Needs registry_vk, pipeline_manifest
    "lua/swapchain.lua",         -- Needs registry_vk
--    "lua/vulkan_core.lua",       -- Needs registry_vk, vulkan_headers, engine_api

--    -- 6. LUA LEVEL 3 (Orchestration - Depends on Level 2)
    "lua/sequence.lua",          -- Needs memory, swapchain, descriptors, etc.
    "lua/tenant_registry.lua",   -- Needs swapchain, renderer, camera, etc.

--    -- 7. ENTRY POINTS (Masters)
--    "build.lua",
--    "main.lua",
}


for _, src in ipairs(order) do local f = io.open(src, "r") if f then
        local content = f:read("*all")
        local minified_content = ""

        -- Route GLSL and Compute shaders through the C minifier!
        if src:match("%.c$") or src:match("%.h$") or src:match("%.glsl$") or src:match("%.comp$") or src:match("%.vert$") or src:match("%.frag$") then
            minified_content = minify_c(content)
        else
            minified_content = minify_lua(content)
        end

        print("@@@ FILE: " .. src .. " @@@\n" .. minified_content)
        f:close()
    else
        print("@@@ FILE: " .. src .. " @@@\n-- [FILE NOT FOUND OR UNREADABLE] --")
    end
end
