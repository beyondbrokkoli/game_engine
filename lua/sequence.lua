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

    -- FIX: TRANSFER_DST (2) | STORAGE_BUFFER (32) | VERTEX_BUFFER (128) = 162
    memory.CreateHostVisibleBuffer("MASTER_GPU_BLOCK", "uint8_t", gpu_bytes, 162, ctx.vk_runtime)

    -- FIX: TRANSFER_DST (2) | INDEX_BUFFER (64) = 66
    memory.CreateHostVisibleBuffer("MASTER_INDEX_BLOCK", "uint32_t", map_grid_cells * 6, 66, ctx.vk_runtime)

    -- TRANSFER_SRC (1) remains correct
    memory.CreateHostVisibleBuffer("PALETTE_STAGING", "float", 4096, 1, ctx.vk_runtime)

    -- FIX: TRANSFER_DST (2) | STORAGE_BUFFER (32) = 34
    memory.CreateBufferHaven("PALETTE_HAVEN", 16384, 34, ctx.vk_runtime)

    print("[WEAVER] Strict VRAM Mapping Complete.")
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


-- lua/sequence.lua (The New Sequence Table)
local seq_boot = {
    { name = "Vulkan Instance", action = step_1_instance },
    { name = "Vulkan Logical Device", action = step_3_logical_device },
    { name = "Memory Arenas Allocation", action = step_4_memory_arenas },
    { name = "Descriptors Matrix", action = step_6_descriptors },
    { name = "Compute Graph Pipelines", action = step_7_compute }
}

-- You can also completely delete seq_resize from this file.
-- The WSI rebuilder handles it now!
local seq_resize = {}

local SequenceModule = {}

-- 3. BLANK CLOSURE FACTORY
function SequenceModule.init(app_ctx_ignored)
    return {
        boot = seq_boot,
        resize = seq_resize
    }
end

return SequenceModule
