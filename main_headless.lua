io.stdout:setvbuf("no")
package.path = "./lua/?.lua;" .. package.path

-- [CRITICAL]: Intercept and mock C-Core dependencies immediately
require("headless_api")

-- Now we can safely pull in the bedrock
local ffi = require("ffi")
local structs = require("structs")
local cfg_sim = require("config_sim")
local cfg_net = require("config_net")

-- Master App Context (Stripped of gfx)
local app_ctx = {
    cfg_sim = cfg_sim,
    cfg_net = cfg_net
}

-- 2. DECOUPLED MODULE FACTORIES (Headless)
local math = require("math")
local net = require("network")
local NetUtils = require("net_utils")

local Game = require("game_state").init(app_ctx)
local Pump = require("net_pump").init(app_ctx)
local FSM = require("fsm_core").init(app_ctx, Game)
local InputCore = require("input_core")

-- 3. TIMING SUBSYSTEM
local function sys_sleep(ms)
    if jit.os == "Windows" then ffi.C.Sleep(ms) else ffi.C.usleep(ms * 1000) end
end

local get_time_hires
if jit.os == "Windows" then
    local freq = ffi.new("int64_t[1]")
    ffi.C.QueryPerformanceFrequency(freq)
    local inv_freq = 1.0 / tonumber(freq[0])
    get_time_hires = function()
        local count = ffi.new("int64_t[1]")
        ffi.C.QueryPerformanceCounter(count)
        return tonumber(count[0]) * inv_freq
    end
else
    local CLOCK_MONOTONIC = 1
    get_time_hires = function()
        local ts = ffi.new("timespec")
        ffi.C.clock_gettime(CLOCK_MONOTONIC, ts)
        return tonumber(ts.tv_sec) + (tonumber(ts.tv_nsec) * 1e-9)
    end
end

-- 4. THE DESYNC TRAP
local function execute_heartbeat_diagnostic(ctx)
    local RING_MASK = cfg_net.RING_MASK
    local MAX_PLAYERS = cfg_net.MAX_PLAYERS

    -- Scan the unconfirmed horizon for discrepancies
    local start_tick = ctx.rollback_arena.confirmed_tick + 1
    local end_tick = ctx.rollback_arena.head_tick

    for t = start_tick, end_tick do
        local idx = bit.band(t, RING_MASK)
        local frame = ctx.rollback_arena.frames[idx]

        if frame.tick == t and frame.remote_checksum ~= 0 and frame.state_checksum ~= 0 then
            if frame.state_checksum ~= frame.remote_checksum then
                print("\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!")
                print(string.format("[CRITICAL DESYNC DETECTED] Tick: %d | Slot: %d", t, idx))
                print(string.format("  Local Hash:  0x%08X", frame.state_checksum))
                print(string.format("  Remote Hash: 0x%08X (Verified by Peer ID: %d)", frame.remote_checksum, frame.remote_peer_id))
                print("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!")
                print("DUMPING TIMELINE INPUT MATRIX FOR CORRUPTED TICK:")

                for p = 0, MAX_PLAYERS - 1 do
                    print(string.format("  Player [%d]:", p))
                    for c = 0, 1 do
                        local cmd = frame.commands[p][c]
                        print(string.format("    Command [%d] -> Opcode: %d | Flags: %d | TargetPos: %d",
                            c, cmd.opcode, cmd.flags, cmd.target_pos))
                    end
                end
                print("--------------------------------------------------------------")
                print("[FATAL INVARIANT] Halting engine loop to preserve memory state.")
                error("[DESYNC] Memory boundary desynchronized across target environments.")
            end
        end
    end
end

-- 5. HEADLESS ORCHESTRATOR
local function main()
    print("Enter Node ID (0-7) OR Preferred Local Port (e.g., 50000): ")
    io.write("> ")
    local local_port = tonumber(io.read("*l")) or 50000
    if local_port < 1000 then local_port = 50000 + local_port end

    assert(net.Host(local_port), "FATAL: Failed to bind local socket port " .. local_port)

    local my_local_ip = NetUtils.get_local_ip()
    local session_token, local_id, p2p_established, active_peers, status_data = NetUtils.BootstrapNetworkTopology(local_port, my_local_ip)

    local ctx = {
        session_token = session_token,
        net_identity = local_id,
        sim_tick_count = 1,
        accumulator = 0.0,
        net_accumulator = 0.0,
        total_tiles = cfg_sim.world.map_width * cfg_sim.world.map_height,
        p2p_established = p2p_established,
        peer_active = ffi.new(string.format("bool[%d]", cfg_net.MAX_PLAYERS)),
        peer_highest_tick = ffi.new(string.format("uint32_t[%d]", cfg_net.MAX_PLAYERS)),
        peer_ack_of_me = ffi.new(string.format("uint32_t[%d]", cfg_net.MAX_PLAYERS)),
        rts_grid = Game.InitState(session_token),
        rollback_arena = ffi.new("RollbackBuffer"),
        snapshot_ring = ffi.new(string.format("%s[%d]", Game.GetStateName(), cfg_net.RING_SIZE))
    }

    ffi.copy(ctx.snapshot_ring[0], ctx.rts_grid, Game.GetStateSize())

    for p = 0, cfg_net.MAX_PLAYERS - 1 do
        ctx.peer_active[p] = (p < #status_data.players)
    end

    print("[LUA IO] Booting Headless Weaver (WAN SERVER MODE)...")
    -- Give the Lua math library a unique starting seed per node
    math.randomseed(os.time() + ctx.net_identity)
    print("[NET] Simulation primed. Awaiting Timeline Synchronization...")

    local last_time = get_time_hires()
    local last_heartbeat = get_time_hires()
    local TICK_RATE = cfg_net.TICK_RATE
    local FIXED_DT = 1.0 / TICK_RATE

    -- Mocking EngineAPI.is_running()
    local is_running = true

    while is_running do
        local current_time = get_time_hires()
        local frame_time = math.max(0.001, math.min(current_time - last_time, 0.25))
        last_time = current_time

        -- A. DETERMINISTIC SIMULATION PHASE
        ctx.accumulator = ctx.accumulator + frame_time
        ctx.net_accumulator = ctx.net_accumulator + frame_time

        Pump.intercept_network(ctx, ctx.sim_tick_count)
        FSM.tick_playing_state(ctx, FIXED_DT)

        execute_heartbeat_diagnostic(ctx)

        if ctx.net_accumulator >= FIXED_DT then

            -- ==============================================================
            -- [SURGICAL PATCH: DOUBLE-BARREL BRUTEFORCE]
            -- Emulating a chaotic human with high APM (Actions Per Minute)
            -- ==============================================================
            -- 15% chance to initiate an action this tick
            if math.random(1, 100) <= 15 then

                -- COMMAND 1: Fire the first action
                local random_tile_1 = math.random(0, ctx.total_tiles - 1)
                InputCore.HandleTerrainClick(ctx, random_tile_1)
                print(string.format("[BRUTEFORCE] Peer %d clicked tile %d at tick %d (Slot 0)", 
                    ctx.net_identity, random_tile_1, ctx.sim_tick_count))

                -- COMMAND 2: 30% chance to immediately double-click somewhere else
                if math.random(1, 100) <= 30 then
                    local random_tile_2 = math.random(0, ctx.total_tiles - 1)
                    InputCore.HandleTerrainClick(ctx, random_tile_2)
                    print(string.format("[BRUTEFORCE] -> Peer %d combo-clicked tile %d at tick %d (Slot 1)", 
                        ctx.net_identity, random_tile_2, ctx.sim_tick_count))
                end
            end

            Pump.send_dynamic_history(ctx)
            ctx.net_accumulator = ctx.net_accumulator % FIXED_DT
        end

        if current_time - last_heartbeat >= 1.0 then
            last_heartbeat = current_time
            print(string.format("\n[HEARTBEAT] Sim Tick: %d | Confirmed: %d | Accum: %.4f",
                ctx.sim_tick_count, ctx.rollback_arena.confirmed_tick, ctx.accumulator))

            for p = 0, cfg_net.MAX_PLAYERS - 1 do
                if ctx.peer_active[p] then
                    print(string.format("  -> [DIAGNOSTIC] Peer %d | Highest Tick: %d | AckOfMe: %d",
                        p, ctx.peer_highest_tick[p], ctx.peer_ack_of_me[p]))
                end
            end
        end

        -- CPU Saver: Yield 1ms to avoid pegging the core at 100% in a tight headless loop
        sys_sleep(1)
    end

    print("\n[LUA IO] Simulation Loop Terminated. Commencing Teardown...")
    net.Shutdown()
    print("[LUA IO] Headless Teardown Complete. Safe Exit.")
end

main()
