local ffi = require("ffi")
local bit = require("bit")
local cfg = require("config_engine")

local ArenaManager = {}

-- Consolidates all Host-Visible and Device-Local Buffer Haven allocations
function ArenaManager.AllocateArenas(vk_runtime)
    local memory = require("memory")

    -- Initialize async transfer timeline
    memory.InitTransferSubsystem(vk_runtime)

    -- Allocate standard configured arenas (MASTER_GPU_BLOCK, MASTER_INDEX_BLOCK)
    for _, arena in ipairs(cfg.memory_arenas) do
        memory.CreateHostVisibleBuffer(arena.name, arena.cdef_type, arena.count, arena.usage, vk_runtime)
    end

    -- Allocate Palette Arenas
    local palette_bytes = 16384
    local usage_staging = 1
    local usage_haven = bit.bor(2, 128)

    memory.CreateHostVisibleBuffer("PALETTE_STAGING", "uint8_t", palette_bytes, usage_staging, vk_runtime)
    memory.CreateBufferHaven("PALETTE_HAVEN", palette_bytes, usage_haven, vk_runtime)
end

-- Allocates the CPU-side Indirect Draw Command ring buffer
function ArenaManager.AllocateRenderQueues()
    local MAX_DRAW_COMMANDS = 1024
    return ffi.new("DrawCommand[?]", MAX_DRAW_COMMANDS * cfg.cfg.frame_slots)
end

return ArenaManager
