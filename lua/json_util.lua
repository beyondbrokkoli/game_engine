-- lua/json_util.lua
local libJson = require("dkjson")

local M = {}

-- JSON Core Wrappers

-- Safely decodes a JSON string and returns the table, or throws a hard error
function M.decode(content)
    local data, pos, err = libJson.decode(content)
    if err or not data then
        error(string.format("[FATAL]: JSON error at position %s: %s\nRaw Content: %s", tostring(pos), tostring(err), tostring(content)))
    end
    return data
end

-- Encodes a Lua table back into a JSON string
function M.encode(tbl)
    return libJson.encode(tbl, { indent = true })
end

-- Visual Debugging (Tree Dumper)

local printJsonObject -- Forward declaration

local function printJsonArray(j, depth)
    depth = depth or 0
    for i, v in ipairs(j) do
        io.write(string.rep("  ", depth))
        if type(v) == "table" then
            print("[" .. i .. "]:")
            if next(v) == 1 then printJsonArray(v, depth + 1)
            else printJsonObject(v, depth + 1) end
        else print("[" .. i .. "]: " .. tostring(v)) end
    end
end

printJsonObject = function(j, depth)
    depth = depth or 0
    for k, v in pairs(j) do
        io.write(string.rep("  ", depth))
        if type(v) == "table" then
            print(k .. ":")
            if next(v) == 1 then printJsonArray(v, depth + 1)
            else printJsonObject(v, depth + 1) end
        else print(k .. ": " .. tostring(v)) end
    end
end

-- Dumps any Lua table (JSON decoded or otherwise) to the terminal
function M.dump(tbl)
    if not tbl then return end
    print("--- JSON DUMP ---")
    if type(tbl) == "table" then
        if next(tbl) == 1 then printJsonArray(tbl)
        else printJsonObject(tbl) end
    else
        print(tostring(tbl))
    end
    print("-----------------")
end

-- Extended State & Table Functionality

function M.deep_copy(obj)
    if type(obj) ~= "table" then return obj end
    local res = {}
    for k, v in pairs(obj) do res[M.deep_copy(k)] = M.deep_copy(v) end
    return res
end

function M.deep_compare(t1, t2)
    if type(t1) ~= type(t2) then return false end
    if type(t1) ~= "table" then return t1 == t2 end
    for k, v in pairs(t1) do
        if not M.deep_compare(v, t2[k]) then return false end
    end
    for k in pairs(t2) do
        if t1[k] == nil then return false end
    end
    return true
end

function M.deep_merge(base, overlay)
    if not overlay then return M.deep_copy(base) end
    local res = M.deep_copy(base)
    for k, v in pairs(overlay) do
        if type(v) == "table" and type(res[k]) == "table" then
            res[k] = M.deep_merge(res[k], v)
        else
            if res[k] ~= nil and res[k] ~= v then
                print(string.format("[AUDIT]: Key '%s' override: %s -> %s", k, tostring(res[k]), tostring(v)))
            end
            res[k] = M.deep_copy(v)
        end
    end
    return res
end

function M.walk(data, f, depth)
    depth = depth or 0
    local isArray = next(data) == 1
    for k, v in (isArray and ipairs or pairs)(data) do
        if type(v) == "table" then
            f(k, nil, depth, true, isArray)
            M.walk(v, f, depth + 1)
        else
            f(k, v, depth, false, isArray)
        end
    end
end

return M
