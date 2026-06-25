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

local function get_sorted_files(base_dir, entry_module)
    local sorted = {}
    local visited = {}
    local visiting = {} -- Tracks current stack to catch circular requires

    local function visit(module_name)
        -- Convert Lua module syntax "folder.file" to "folder/file.lua"
        local relative_path = module_name:gsub("%.", "/")
        local file_path = base_dir .. "/" .. relative_path .. ".lua"

        -- Skip if already processed
        if visited[file_path] then return end

        -- Guard against circular dependencies locking up the minifier
        if visiting[file_path] then
            print("[!] WARNING: Circular dependency detected in: " .. module_name)
            return
        end

        visiting[file_path] = true

        local f = io.open(file_path, "r")
        if f then
            local content = f:read("*all")
            f:close()

            -- Regex matches both require("x") and require 'x'
            for dep_match in content:gmatch('require%s*%(?%s*["\'](.-)["\']%s*%)?') do
                visit(dep_match)
            end
        else
            print("[!] WARNING: Could not open required module: " .. file_path)
        end

        visiting[file_path] = false
        visited[file_path] = true

        -- Insert post-order: Dependencies are added BEFORE the files that require them
        table.insert(sorted, file_path)
    end

    visit(entry_module)
    return sorted
end

print("--- AI SNAPSHOT ---")

-- 1. Dynamically resolve all Lua dependencies starting from main
local order = get_sorted_files("lua", "main")

-- 2. Append non-Lua files (C-core, shaders) that 'require()' won't catch
local external_assets = {
    "c/shared_structs.h",
    "c/vx_net.c",
    "c/main.c",
    "glsl/registry.glsl",
    "glsl/shared.glsl",
    "glsl/render.vert",
    "glsl/render.frag"
}

for _, asset in ipairs(external_assets) do
    table.insert(order, asset)
end

-- 3. Execute minification loop
for _, src in ipairs(order) do
    local f = io.open(src, "r")
    if f then
        local content = f:read("*all")
        local minified_content = ""

        -- Route GLSL, Compute, and C files to the C minifier
        if src:match("%.c$") or src:match("%.h$") or src:match("%.glsl$") or src:match("%.comp$") or src:match("%.vert$") or src:match("%.frag$") then
            minified_content = minify_c(content)
        else
            minified_content = minify_lua(content)
        end

        print("@@@ FILE: " .. src .. " @@@\n" ..  minified_content)
        f:close()
    else
        print("@@@ FILE: " .. src .. " @@@\n-- [FILE NOT FOUND OR UNREADABLE] --")
    end
end
