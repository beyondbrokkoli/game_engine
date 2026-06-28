local ffi = require("ffi")
local reg = require("registry_vk")
local manifest = require("pipeline_manifest")
local WindowAPI = require("window_api")
local EngineAPI = require("engine_api")
local cfg_gfx = require("config_gfx")
local cfg_sim = require("config_sim")

-- 1. STATIC BOOT SEQUENCE ACTIONS
-- Completely decoupled from init(). No upvalues captured.
local function step_1_instance(ctx)
    local vulkan = require("vulkan_core")
    ctx.vk_runtime = vulkan.create_instance(reg.vk_reqs.instance_ext, cfg_gfx.cfg)
    EngineAPI.publish_instance(ctx.win_id, ctx.vk_runtime.instance)
end

local function step_2_window(ctx)
    print("[WEAVER] Ordering C-Core to Boot GLFW Window...")
    WindowAPI.boot(ctx.win_id, cfg_gfx.win.w, cfg_gfx.win.h)
    return "AWAIT_SURFACE"
end

local function step_3_logical_device(ctx)
    local vulkan = require("vulkan_core")
    local surface_ptr = WindowAPI.get_surface(ctx.win_id)
    vulkan.finalize_device_and_swapchain(ctx.vk_runtime, surface_ptr, reg.vk_reqs.device_ext)
end

local function step_4_memory_arenas(ctx)
    local memory = require("memory")
    print("[WEAVER] Booting DMA Engine & VRAM Allocator...")
    memory.InitTransferSubsystem(ctx.vk_runtime)

    local map_grid_cells = cfg_sim.world.grid_cells
    local grid_bytes = map_grid_cells * 16
    local gpu_bytes = math.floor(grid_bytes * 8 * 1.1)

    memory.CreateHostVisibleBuffer("MASTER_GPU_BLOCK", "uint8_t", gpu_bytes, 416, ctx.vk_runtime)
    memory.CreateHostVisibleBuffer("MASTER_INDEX_BLOCK", "uint32_t", map_grid_cells * 6, 320, ctx.vk_runtime)
    memory.CreateHostVisibleBuffer("PALETTE_STAGING", "float", 4096, 1, ctx.vk_runtime)
    memory.CreateBufferHaven("PALETTE_HAVEN", 16384, 384, ctx.vk_runtime)

    print("[WEAVER] Strict VRAM Mapping Complete.")
end

local function step_5_swapchain(ctx)
    local swapchain = require("swapchain")
    local surface_ptr = WindowAPI.get_surface(ctx.win_id)
    ctx.sc_state = swapchain.Init(ctx.vk_runtime.vk, ctx.vk_runtime, cfg_gfx.win.w, cfg_gfx.win.h, ctx.old_swapchain, surface_ptr)
end

local function step_6_descriptors(ctx)
    local descriptors = require("descriptors")
    local memory = require("memory")
    local master_gpu_buffer = memory.Buffers["MASTER_GPU_BLOCK"]
    local palette_haven_buffer = memory.Buffers["PALETTE_HAVEN"]
    ctx.desc_state = descriptors.Init(ctx.vk_runtime.vk, ctx.vk_runtime.device, master_gpu_buffer, palette_haven_buffer, cfg_gfx.cfg)
end

local function step_7_compute(ctx)
    local compute = require("compute_pipeline")
    local layout = ctx.desc_state.pipelineLayout
    ctx.comp_state = compute.Init(ctx.vk_runtime.vk, ctx.vk_runtime.device, layout, manifest.compute)
end

local function step_8_graphics(ctx)
    local graphics = require("graphics_pipeline")
    local layout = ctx.desc_state.pipelineLayout
    local colorFormat = ctx.sc_state.format
    ctx.gfx_state = graphics.Init(ctx.vk_runtime.vk, ctx.vk_runtime, cfg_gfx.win.w, cfg_gfx.win.h, layout, colorFormat, manifest.graphics)
end

local function step_9_sync(ctx)
    local renderer = require("renderer")
    ctx.sync_state = renderer.InitSync(ctx.vk_runtime.vk, ctx.vk_runtime.device, cfg_gfx.cfg.frame_slots)
end

local function step_10_overlord_handoff(ctx)
    print("[WEAVER] Packing C-Core Mailbox and firing Render Thread...")
    local vk, dev = ctx.vk_runtime.vk, ctx.vk_runtime.device
    local sc, sync = ctx.sc_state, ctx.sync_state

    local wsi = ffi.new("RenderThreadInit")
    wsi.device = dev
    wsi.queue = ctx.vk_runtime.queue
    wsi.transfer_queue = ctx.vk_runtime.transferQueue
    wsi.swapchain = sc.handle

    for i = 0, sc.imageCount - 1 do
        wsi.swapchain_images[i] = ffi.cast("uint64_t", sc.images[i])
        wsi.swapchain_views[i]  = ffi.cast("uint64_t", sc.imageViews[i])
    end

    for i = 0, cfg_gfx.cfg.frame_slots - 1 do
        wsi.image_available[i] = sync.imageAvailable[i]
        wsi.render_finished[i] = sync.renderFinished[i]
        wsi.in_flight[i]       = sync.inFlight[i]
    end

    wsi.vkWaitForFences         = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkWaitForFences"))
    wsi.vkAcquireNextImageKHR   = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkAcquireNextImageKHR"))
    wsi.vkResetFences           = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkResetFences"))
    wsi.vkQueueSubmit           = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkQueueSubmit"))
    wsi.vkQueuePresentKHR       = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkQueuePresentKHR"))
    wsi.pfnBegin                = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkCmdBeginRenderingKHR"))
    wsi.pfnEnd                  = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkCmdEndRenderingKHR"))
    wsi.pfnSetCullMode          = vk.vkGetDeviceProcAddr(dev, "vkCmdSetCullModeEXT")
    wsi.pfnSetFrontFace         = vk.vkGetDeviceProcAddr(dev, "vkCmdSetFrontFaceEXT")
    wsi.pfnSetPrimitiveTopology = vk.vkGetDeviceProcAddr(dev, "vkCmdSetPrimitiveTopologyEXT")
    wsi.pfnSetDepthTestEnable   = vk.vkGetDeviceProcAddr(dev, "vkCmdSetDepthTestEnableEXT")
    wsi.pfnSetDepthWriteEnable  = vk.vkGetDeviceProcAddr(dev, "vkCmdSetDepthWriteEnableEXT")
    wsi.pfnSetDepthCompareOp    = vk.vkGetDeviceProcAddr(dev, "vkCmdSetDepthCompareOpEXT")

    EngineAPI.setup_transfer(ctx.vk_runtime.tIndex)
    EngineAPI.init_stream(ctx.win_id, wsi)
    EngineAPI.start_thread()
    print("[WEAVER] Engine Initialization Complete. Async Overlord is LIVE.")
end

-- 2. THE STATIC SEQUENCE TABLE
local seq_boot = {
    { name = "Vulkan Instance", action = step_1_instance },
    { name = "GLFW Window Boot", action = step_2_window },
    { name = "Vulkan Logical Device", action = step_3_logical_device },
    { name = "Memory Arenas Allocation", action = step_4_memory_arenas },
    { name = "Swapchain Initialization", action = step_5_swapchain },
    { name = "Descriptors Matrix", action = step_6_descriptors },
    { name = "Compute Graph Pipelines", action = step_7_compute },
    { name = "Graphics Pipelines & Depth Buffer", action = step_8_graphics },
    { name = "Renderer Synchronization", action = step_9_sync },
    { name = "Async Overlord Handoff", action = step_10_overlord_handoff }
}

local seq_resize = { seq_boot[5], seq_boot[8], seq_boot[9] }

local SequenceModule = {}

-- 3. BLANK CLOSURE FACTORY
function SequenceModule.init(app_ctx_ignored)
    return {
        boot = seq_boot,
        resize = seq_resize
    }
end

return SequenceModule
