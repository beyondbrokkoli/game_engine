local bit = require("bit")

local KB = 1024
local MB = 1024 * KB

local config = {
    sys = { idle = 0, boot = 1, kill = 2 },
    win = { w = 1280, h = 720, min_w = 640, min_h = 360 },
    move  = { fwd = 1, back = 2, left = 4, right = 8, up = 16, down = 32 },
    mouse = { left = 0, right = 1 },
    key   = { space = 32, num1 = 49, num2 = 50, num3 = 51, num4 = 52, esc = 256, f11 = 290, f5 = 294 },

    cfg = {
        use_validation = 0,
        vk_api_version = 4206592,
        pcount = 1000000,
        grid_cells = 262144,
        pc_size = 96, -- [UPDATED] Dropped to 96 bytes to match struct
        frame_slots = 10,
        swap_slots = 10,
        swarm_states = 7,
        rollback_buffer_size = 128
    },

    mode = { dual = 0, geom = 1, points = 2, point_cloud_pass = 88 },

    -- [NEW] Dimensional Manifesto SSoT
    world = {
        map_width = 256,
        map_height = 256,
        spacing = 20.0,
    },

    net_state = { empty = 0, predicted = 1, confirmed = 2 },

    memory_arenas = {
        { name = "MASTER_INDEX_BLOCK", cdef_type = "uint32_t", count = 256, usage = bit.bor(64, 256) },
        { name = "MASTER_GPU_BLOCK",   cdef_type = "uint8_t",  count = 12 * MB, usage = bit.bor(32, 128, 256) }
    }
}

-- Compute Universal Offsets once at boot
config.world.offset_x = (config.world.map_width * config.world.spacing) / 2.0
config.world.offset_z = (config.world.map_height * config.world.spacing) / 2.0

return config
