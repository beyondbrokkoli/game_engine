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
    -- [ ENTRY POINTS ]
    "main.lua",
--    "build.lua",

    -- [ C-CORE ]
--    "c/main.c",
    "c/vx_net.c",
--    "c/shared_structs.h",

    -- [ LUA ENGINE MODULES ]
--    "lua/registry_vk.lua",
--    "lua/sequence.lua",
--    "lua/pipeline_manifest.lua",
--    "lua/vulkan_core.lua",
--    "lua/swapchain.lua",
--    "lua/descriptors.lua",
--    "lua/graphics_pipeline.lua",
--    "lua/compute_pipeline.lua",
--    "lua/renderer.lua",
--    "lua/renderer.lua",
--    "lua/memory.lua",
--    "lua/vmath.lua",
--    "lua/structs.lua",
--    "lua/config_engine.lua",
--    "lua/registry_export.lua",
--    "lua/network.lua",
--    "lua/camera.lua",
--    "lua/json_util.lua",

    -- [ GLSL SHADERS & SSOT ]
--    "glsl/registry.glsl",
--    "glsl/shared.glsl",
--    "glsl/render.vert",
--    "glsl/render.frag",
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
