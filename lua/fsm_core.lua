-- lua/fsm_core.lua
local net = require("network")
local bit = require("bit")
local ffi = require("ffi")

local FSM = {}

-- Note the new 'domain_module' parameter
function FSM.init(app_ctx, domain_module)
    -- 1. CACHE LUAJIT UPVALUES
    local MAX_PLAYERS     = app_ctx.cfg_net.MAX_PLAYERS
    local LOOKAHEAD_CAP   = app_ctx.cfg_net.LOOKAHEAD_CAP
    local RING_MASK       = app_ctx.cfg_net.RING_MASK
    local HISTORY_HORIZON = app_ctx.cfg_net.HISTORY_HORIZON
    local DESYNC_SWEEP    = app_ctx.cfg_net.DESYNC_SWEEP

    -- Cache the domain functions for max speed in the hot loop
    local GetStateSize = domain_module.GetStateSize
    local SimulateTick = domain_module.SimulateTick
    local HashState    = domain_module.HashState

    -- 2. THE EXECUTABLE CLOSURE
    return {
        tick_playing_state = function(ctx, FIXED_DT)
            local true_consensus = 0xFFFFFFFF
            local min_ack_of_me = 0xFFFFFFFF

            for p = 0, MAX_PLAYERS - 1 do
                if p ~= ctx.net_identity and ctx.peer_active[p] then
                    if ctx.peer_highest_tick[p] < true_consensus then
                        true_consensus = ctx.peer_highest_tick[p]
                    end
                    if ctx.peer_ack_of_me[p] < min_ack_of_me then
                        min_ack_of_me = ctx.peer_ack_of_me[p]
                    end
                end
            end

            local local_max_valid_tick = math.max(0, ctx.sim_tick_count - 1)
            if true_consensus > local_max_valid_tick then
                true_consensus = local_max_valid_tick
            end
            if true_consensus ~= 0xFFFFFFFF and true_consensus > ctx.rollback_arena.confirmed_tick then
                ctx.rollback_arena.confirmed_tick = true_consensus
            end

            if min_ack_of_me == 0xFFFFFFFF then
                min_ack_of_me = ctx.rollback_arena.confirmed_tick
            end

            local remote_highest = ctx.rollback_arena.confirmed_tick
            local safe_horizon = math.min(remote_highest, min_ack_of_me)

            if remote_highest > ctx.sim_tick_count + 2 then
                ctx.accumulator = ctx.accumulator + ((remote_highest - ctx.sim_tick_count) * FIXED_DT)
            end

            if ctx.sim_tick_count > safe_horizon + LOOKAHEAD_CAP then
                ctx.accumulator = 0
            end

            while ctx.accumulator >= FIXED_DT do
                local c_idx = bit.band(ctx.sim_tick_count, RING_MASK)
                local frame = ctx.rollback_arena.frames[c_idx]

                if frame.tick ~= ctx.sim_tick_count then
                    for p = 0, MAX_PLAYERS - 1 do
                        frame.commands[p][0].opcode = 0
                        frame.commands[p][1].opcode = 0
                    end
                    frame.state_checksum = 0
                    frame.remote_checksum = 0
                    frame.state = 0
                    frame.remote_peer_id = 0
                end
                frame.tick = ctx.sim_tick_count

                ctx.rollback_arena.head_tick = ctx.sim_tick_count

                if ctx.rollback_arena.is_rollback_active == 1 then
                    local t_tgt = ctx.rollback_arena.rollback_target

                    if (ctx.sim_tick_count - t_tgt) > HISTORY_HORIZON then
                        print(string.format("[FATAL] Rollback horizon exceeded memory limit! Target: %d | Head: %d", t_tgt, ctx.sim_tick_count))
                        os.exit(1)
                    end

                    local r_idx = bit.band(t_tgt - 1, RING_MASK)
                    local state_size = GetStateSize()

                    ffi.copy(ctx.rts_grid, ctx.snapshot_ring[r_idx], state_size)

                    for t = t_tgt, ctx.sim_tick_count - 1 do
                        local f_idx = bit.band(t, RING_MASK)
                        local f = ctx.rollback_arena.frames[f_idx]

                        SimulateTick(ctx.rts_grid, f.commands, t)
                        f.state_checksum = HashState(ctx.rts_grid)
                        ffi.copy(ctx.snapshot_ring[f_idx], ctx.rts_grid, state_size)
                    end
                    ctx.rollback_arena.is_rollback_active = 0
                end

                if ctx.sim_tick_count <= remote_highest + LOOKAHEAD_CAP then
                    SimulateTick(ctx.rts_grid, frame.commands, ctx.sim_tick_count)
                    frame.state_checksum = HashState(ctx.rts_grid)

                    ffi.copy(ctx.snapshot_ring[c_idx], ctx.rts_grid, GetStateSize())

                    ctx.sim_tick_count = ctx.sim_tick_count + 1

                    local conf_tick = ctx.rollback_arena.confirmed_tick
                    local sweep_start = math.max(0, conf_tick - DESYNC_SWEEP)

                    for v_tick = sweep_start, conf_tick do
                        local v_idx = bit.band(v_tick, RING_MASK)
                        local v_frame = ctx.rollback_arena.frames[v_idx]

                        if v_frame.tick == v_tick and v_frame.state_checksum ~= 0 and v_frame.remote_checksum ~= 0 then
                            if v_frame.state_checksum ~= v_frame.remote_checksum then
                                print(string.format("[FATAL DESYNC] Tick: %d | Local: 0x%08X | Remote: 0x%08X", v_tick, v_frame.state_checksum, v_frame.remote_checksum))
                                os.exit(1)
                            end
                        end
                    end
                end
                ctx.accumulator = ctx.accumulator - FIXED_DT
            end
        end
    }
end

return FSM
