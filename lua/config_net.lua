local ConfigNet = {}

-- Engine Memory Bounds (STRICT OVERPROVISIONING)
ConfigNet.MAX_PLAYERS = 8      -- Hardcoded to 8 for FFI C structs. Python matchmaker handles 2-8 logic.
ConfigNet.RING_SIZE = 512      -- 512 > (120 + 60 + 60) -> Zero Memory Collisions
ConfigNet.RING_MASK = ConfigNet.RING_SIZE - 1

-- Temporal Logic & Rollback
ConfigNet.TICK_RATE = 60
ConfigNet.LOOKAHEAD_CAP = 60
ConfigNet.HISTORY_LEN = 120    -- 2 Seconds of payload.
ConfigNet.HISTORY_HORIZON = ConfigNet.HISTORY_LEN - 1
ConfigNet.DESYNC_SWEEP = 60

-- Infrastructure Routing
ConfigNet.MATCHMAKER_URL = "http://138.199.152.240:80"
ConfigNet.STUN_SERVER = "138.199.152.240"
ConfigNet.STUN_PORT = 3478
ConfigNet.RELAY_IP = "138.199.152.240"
ConfigNet.RELAY_PORT = 49152

-- I/O Limits
ConfigNet.MAX_BURST_PACKETS = 256

-- Lockstep state flags for C-header export
ConfigNet.net_state = {
    empty = 0,
    predicted = 1,
    confirmed = 2
}

return ConfigNet
