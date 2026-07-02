-- lua/tenant_registry.lua (Updated for WSI mapping)
local ffi = require("ffi")
local WindowAPI = require("window_api")
local EngineAPI = require("engine_api")
local swapchain = require("swapchain")
local renderer = require("renderer")
local camera_mod = require("camera")

local TenantRegistry = { active = {} }

function TenantRegistry.boot_tenant(vk_rt, win_id, width, height, frame_slots)
    print(string.format("[UI BOOTSTRAP] Booting Tenant %d...", win_id))

    -- 1. Publish Instance to Multiplexer & Boot OS Window
    EngineAPI.publish_instance(win_id, vk_rt.instance)
    WindowAPI.boot(win_id, width, height)

    local surface = nil
    while surface == nil do
        surface = WindowAPI.get_surface(win_id)
        -- sys_sleep(10) is handled in main, but a small yield here is safe
    end

    -- 2. Allocate WSI & Sync Primitives per Tenant
    local sc = swapchain.Init(vk_rt.vk, vk_rt, width, height, nil, surface)

    -- [GOLDEN FIX]: Sync primitive count MUST match the hardware image count!
    local sync = renderer.InitSync(vk_rt.vk, vk_rt.device, sc.imageCount)

    local wsi = ffi.new("RenderThreadInit")
    wsi.device = vk_rt.device
    wsi.queue = vk_rt.queue
    wsi.transfer_queue = vk_rt.transferQueue
    wsi.swapchain = sc.handle

    -- Tell the C-Core to modulo the CPU frames exactly to the hardware capability
    wsi.max_frames_in_flight = sc.imageCount

    for i = 0, sc.imageCount - 1 do
        wsi.swapchain_images[i] = ffi.cast("uint64_t", sc.images[i])
        wsi.swapchain_views[i]  = ffi.cast("uint64_t", sc.imageViews[i])
    end

    -- [ARMOR PATCH]: Map ALL hardware indices across the FFI boundary
    -- so the C-Core never reads a NULL pointer when using img_idx!
    for i = 0, sc.imageCount - 1 do
        wsi.image_available[i] = sync.imageAvailable[i];
        wsi.render_finished[i] = sync.renderFinished[i];
        wsi.in_flight[i]       = sync.inFlight[i];
    end

    -- FIX INJECTED: Populate required Dynamic Rendering and Sync function pointers
    local vk, dev = vk_rt.vk, vk_rt.device
    wsi.vkWaitForFences = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkWaitForFences"))
    wsi.vkAcquireNextImageKHR = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkAcquireNextImageKHR"))
    wsi.vkResetFences = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkResetFences"))
    wsi.vkQueueSubmit = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkQueueSubmit"))
    wsi.vkQueuePresentKHR = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkQueuePresentKHR"))
    wsi.pfnBegin = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkCmdBeginRenderingKHR"))
    wsi.pfnEnd = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkCmdEndRenderingKHR"))
    wsi.pfnSetCullMode = vk.vkGetDeviceProcAddr(dev, "vkCmdSetCullModeEXT")
    wsi.pfnSetFrontFace = vk.vkGetDeviceProcAddr(dev, "vkCmdSetFrontFaceEXT")
    wsi.pfnSetPrimitiveTopology = vk.vkGetDeviceProcAddr(dev, "vkCmdSetPrimitiveTopologyEXT")
    wsi.pfnSetDepthTestEnable = vk.vkGetDeviceProcAddr(dev, "vkCmdSetDepthTestEnableEXT")
    wsi.pfnSetDepthWriteEnable = vk.vkGetDeviceProcAddr(dev, "vkCmdSetDepthWriteEnableEXT")
    wsi.pfnSetDepthCompareOp = vk.vkGetDeviceProcAddr(dev, "vkCmdSetDepthCompareOpEXT")

    EngineAPI.allocate_tenant(win_id, wsi, vk_rt.qIndex, vk_rt.tIndex);
    EngineAPI.init_stream(win_id, wsi);

    -- 4. Construct the Isolated Lua Tenant Struct
    local tenant = {
        win_id = win_id,
        suspended = false,
        width = width,
        height = height,
        sc = sc,
        sync = sync,
        cam = camera_mod.new(),
        pc = ffi.new("PushConstants"),
        inv_vp = ffi.new("mat4_t")
    }

    tenant.pc.aos_current_idx, tenant.pc.aos_prev_idx, tenant.pc.dt = 0, 0, 0.0

    TenantRegistry.active[win_id] = tenant
    return tenant
end

function TenantRegistry.teardown_tenant(win_id, vk_rt)
    local tenant = TenantRegistry.active[win_id]
    if not tenant then
        print(string.format("[UI ERROR] Tenant %d does not exist.", win_id))
        return
    end

    print(string.format("[UI TEARDOWN] Initiating Phase 1 for Tenant %d...", win_id))

    -- CACHE THE SURFACE: We must grab this before C-Core nullifies it!
    local surface_ptr = WindowAPI.get_surface(win_id)
    local vk_surface = nil
    if surface_ptr ~= ffi.NULL then
        vk_surface = ffi.cast("VkSurfaceKHR", surface_ptr)
    end

    -- Phase 1: Signal C-Core to drop the OS window and pools
    WindowAPI.destroy(win_id)

    -- Phase 2: Poll until C-Core confirms detachment
    while WindowAPI.get_surface(win_id) ~= ffi.NULL do
        ffi.C.Sleep(1)
    end

    print(string.format("[UI TEARDOWN] C-Core detached. Initiating Phase 3 for Tenant %d...", win_id))

    -- Phase 3: Safe to destroy Lua-owned Vulkan objects
    local graphics_mod = require("graphics_pipeline")
    local renderer_mod = require("renderer")
    local swapchain_mod = require("swapchain")

    if tenant.gfx then graphics_mod.Destroy(vk_rt.vk, vk_rt, tenant.gfx) end
    renderer_mod.Destroy(vk_rt.vk, vk_rt.device, tenant.sync)
    swapchain_mod.Destroy(vk_rt.vk, vk_rt, tenant.sc)

    -- Destroy the surface using our cached handle
    if vk_surface then
        vk_rt.vk.vkDestroySurfaceKHR(vk_rt.instance, vk_surface, nil)
    end

    -- Purge from registry
    TenantRegistry.active[win_id] = nil
    print(string.format("[UI TEARDOWN] Tenant %d completely purged.", win_id))
end

return TenantRegistry
