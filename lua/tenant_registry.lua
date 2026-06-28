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
    local sync = renderer.InitSync(vk_rt.vk, vk_rt.device, frame_slots)

    local wsi = ffi.new("RenderThreadInit")
    wsi.device = vk_rt.device
    wsi.queue = vk_rt.queue
    wsi.transfer_queue = vk_rt.transferQueue
    wsi.swapchain = sc.handle

    -- Tell the C-Core exactly how many padded sync frames it is allowed to modulo against
    wsi.max_frames_in_flight = sync.safe_frames or frame_slots

    for i = 0, sc.imageCount - 1 do
        wsi.swapchain_images[i] = ffi.cast("uint64_t", sc.images[i])
        wsi.swapchain_views[i]  = ffi.cast("uint64_t", sc.imageViews[i])
    end

    -- [ARMOR PATCH]: Map all padded handles (safe_frames) across the FFI boundary
    -- so the C-Core % 3 hardcode doesn't read a NULL pointer on frame index 2.
    local safe_slots = sync.safe_frames or frame_slots;
    for i = 0, safe_slots - 1 do
        wsi.image_available[i] = sync.imageAvailable[i];
        wsi.render_finished[i] = sync.renderFinished[i];
        wsi.in_flight[i] = sync.inFlight[i];
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

return TenantRegistry
