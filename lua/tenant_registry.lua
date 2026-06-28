-- lua/tenant_registry.lua
local ffi = require("ffi")
local WindowAPI = require("window_api")
local camera_mod = require("camera")

local TenantRegistry = {
    active = {}
}

function TenantRegistry.spawn(win_id)
    local w, h = WindowAPI.get_window_size(win_id)

    local tenant = {
        win_id = win_id,
        suspended = false,
        width = w,
        height = h,

        -- Tenant-isolated matrices to prevent cross-contamination
        cam = camera_mod.new(),
        viewProj = ffi.new("mat4_t"),
        inv_vp = ffi.new("mat4_t"),

        -- Push constants specifically bound to this tenant's viewport
        pc = ffi.new("PushConstants")
    }

    TenantRegistry.active[win_id] = tenant
    return tenant
end

function TenantRegistry.remove(win_id)
    TenantRegistry.active[win_id] = nil
end

return TenantRegistry
