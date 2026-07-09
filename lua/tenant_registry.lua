-- lua/tenant_registry.lua
local ffi = require("ffi")
local WindowAPI = require("window_api")
local EngineAPI = require("engine_api")
local swapchain = require("swapchain")
local renderer = require("renderer")
local camera_mod = require("camera")

-- 1. DUPLICATE THE OS TIMERS HERE
-- ADDING THIS DIDNT HELP THE ISSUE THAT WAS MY MISTAKE I LEFT IT HERE TO STAY HONEST
local function sys_sleep(ms)
    if jit.os == "Windows" then
        ffi.C.Sleep(ms)
    else
        ffi.C.usleep(ms * 1000)
    end
end

local TenantRegistry = { active = {} }

function TenantRegistry.boot_tenant(vk_rt, win_id, width, height, frame_slots)
    print(string.format("[UI BOOTSTRAP] Booting Tenant %d...", win_id))

    -- 1. Publish Instance to Multiplexer & Boot OS Window
    EngineAPI.publish_instance(win_id, vk_rt.instance)
    WindowAPI.boot(win_id, width, height)

    local surface = nil
    while surface == nil do
        surface = WindowAPI.get_surface(win_id)
        sys_sleep(1) -- Use your cross-platform sleep
    end

    -- 2. Allocate WSI & Sync Primitives per Tenant
    local sc = swapchain.Init(vk_rt.vk, vk_rt, width, height, nil, surface)

    -- [GOLDEN FIX]: Sync primitive count MUST match the hardware image count!
    local sync = renderer.InitSync(vk_rt.vk, vk_rt.device, sc.imageCount)

    -- 3. Populate the IMMUTABLE Device Context
    local dev_ctx = ffi.new("VulkanDeviceContext")
    dev_ctx.device = vk_rt.device
    dev_ctx.queue = vk_rt.queue
    dev_ctx.transfer_queue = vk_rt.transferQueue
    dev_ctx.max_frames_in_flight = sc.imageCount

    local vk, dev = vk_rt.vk, vk_rt.device
    dev_ctx.vkWaitForFences = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkWaitForFences"))
    dev_ctx.vkAcquireNextImageKHR = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkAcquireNextImageKHR"))
    dev_ctx.vkResetFences = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkResetFences"))
    dev_ctx.vkQueueSubmit = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkQueueSubmit"))
    dev_ctx.vkQueuePresentKHR = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkQueuePresentKHR"))
    dev_ctx.pfnBegin = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkCmdBeginRenderingKHR"))
    dev_ctx.pfnEnd = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkCmdEndRenderingKHR"))
    dev_ctx.pfnSetCullMode = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkCmdSetCullModeEXT"))
    dev_ctx.pfnSetFrontFace = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkCmdSetFrontFaceEXT"))
    dev_ctx.pfnSetPrimitiveTopology = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkCmdSetPrimitiveTopologyEXT"))
    dev_ctx.pfnSetDepthTestEnable = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkCmdSetDepthTestEnableEXT"))
    dev_ctx.pfnSetDepthWriteEnable = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkCmdSetDepthWriteEnableEXT"))
    dev_ctx.pfnSetDepthCompareOp = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkCmdSetDepthCompareOpEXT"))

    -- Tell C-Core to allocate the tenant boundaries and cache the device context
    EngineAPI.allocate_tenant(win_id, dev_ctx, vk_rt.qIndex, vk_rt.tIndex)

    -- 4. Populate the VOLATILE Swapchain Context (Zombie Protocol Boot Sequence)
    WindowAPI.prepare_new_wsi(win_id, width, height)

    -- [THE LOCK-FREE HANDSHAKE]: Wait for C-Core to zero the slot and set CMD back to 0!
    while WindowAPI.get_cmd_state(win_id) ~= 0 do
        sys_sleep(1)
    end

    local inactive_wsi_ptr = ffi.C.vx_sys_get_inactive_wsi_slot(win_id)
    local dormant_wsi = ffi.cast("VulkanSwapchainContext*", inactive_wsi_ptr)

    local current_gen = ffi.C.vx_sys_get_wsi_generation(win_id)
    local next_gen = current_gen + 1

    dormant_wsi.swapchain = sc.handle
    dormant_wsi.status = 1 -- 1 = ACTIVE

    for i = 0, sc.imageCount - 1 do
        dormant_wsi.swapchain_images[i] = ffi.cast("uint64_t", sc.images[i])
        dormant_wsi.swapchain_views[i]  = ffi.cast("uint64_t", sc.imageViews[i])
        dormant_wsi.image_available[i]  = sync.imageAvailable[i]
        dormant_wsi.render_finished[i]  = sync.renderFinished[i]
        dormant_wsi.in_flight[i]        = sync.inFlight[i]
    end

    -- Pivot the WSI Generation Slot!
    WindowAPI.flip_wsi(win_id)
    print(string.format("[UI BOOTSTRAP] Tenant %d WSI populated. Boot Generation: %d", win_id, next_gen))

    -- 5. Open the render command stream for this tenant
    EngineAPI.init_stream(win_id, dev_ctx)

    -- 6. Construct the Isolated Lua Tenant Struct
    local tenant = {
        win_id = win_id,
        suspended = false,
        width = width,
        height = height,
        sc = sc,
        sync = sync,
        cam = camera_mod.new(),
        pc = ffi.new("PushConstants"),
        inv_vp = ffi.new("mat4_t"),
        generation = next_gen,
        zombies = {},    -- Initialize the Lua-side Trash Collector
        wsi_state = 0    -- [NEW]: Boot directly into IDLE state for main.lua!
    }

    tenant.pc.aos_current_idx, tenant.pc.aos_prev_idx, tenant.pc.dt = 0, 0, 0.0

    TenantRegistry.active[win_id] = tenant
    return tenant
end

return TenantRegistry
