local ffi = require("ffi")
local bit = require("bit")
local net = require("network")

local Pump = {}

-- The module only initializes when main.lua injects the Application Context
function Pump.init(app_ctx)
    -- 1. CACHE LUAJIT UPVALUES (Zero-cost lookups in hot loops)
    local RING_MASK       = app_ctx.cfg_net.RING_MASK
    local HISTORY_HORIZON = app_ctx.cfg_net.HISTORY_HORIZON
    local HISTORY_LEN     = app_ctx.cfg_net.HISTORY_LEN
    local MAX_PLAYERS     = app_ctx.cfg_net.MAX_PLAYERS
    local DESYNC_SWEEP    = app_ctx.cfg_net.DESYNC_SWEEP

    -- The Domain Boundary: Safely grabbing the flag from the active domain
    local STATE_EMPTY     = app_ctx.cfg_net.net_state.empty

    local CHAOS_PACKET_LOSS = 0.0

    -- 2. PERSISTENT BUFFERS (Safely scoped to this engine instance)
    -- Note: This requires 'structs.lua' to be loaded in main.lua prior to init.
    local max_packet_size = 4096 -- [!] PATCHED: Expanded from 2048 to prevent RLE heap overflow
    local tx_buffer = ffi.new("uint8_t[?]", max_packet_size)
    local header_size = ffi.offsetof("LockstepPacket", "commands")

    local global_out_pkt = ffi.new("LockstepPacket")
    local scratch_in_pkt = ffi.new("LockstepPacket") -- Decompression target

    local MAX_BURST_PACKETS = app_ctx.cfg_net.MAX_BURST_PACKETS
    local global_in_buffer = ffi.new("RxPacket[?]", MAX_BURST_PACKETS)

    -- 3. THE EXECUTABLE CLOSURE
    return {
        send_dynamic_history = function(ctx)
            local current_tick = ctx.rollback_arena.head_tick
            local conf_tick = ctx.rollback_arena.confirmed_tick

            ffi.fill(global_out_pkt, ffi.sizeof("LockstepPacket"), 0)
            local pkt = global_out_pkt

            pkt.session_token = ctx.session_token
            pkt.player_id = ctx.net_identity
            pkt.frame_tick = current_tick

            if conf_tick > 0 and ctx.rollback_arena.is_rollback_active == 0 then
                local conf_idx = bit.band(conf_tick, RING_MASK)
                pkt.state_checksum = ctx.rollback_arena.frames[conf_idx].state_checksum
                pkt.checksum_tick = conf_tick
            end

            local needed_base = math.max(1, current_tick - HISTORY_HORIZON)
            local history_len = current_tick - needed_base + 1

            if history_len > HISTORY_LEN then
                history_len = HISTORY_LEN
            end

            pkt.base_tick = needed_base
            pkt.history_count = history_len

            for p = 0, MAX_PLAYERS - 1 do
                if p ~= ctx.net_identity and ctx.peer_active[p] then
                    pkt.peer_acks[p] = ctx.peer_highest_tick[p]
                end
            end

            -- 1. Populate the raw structs as usual
            for i = 0, history_len - 1 do
                local h_tick = needed_base + i
                local h_idx = bit.band(h_tick, RING_MASK)
                local frame = ctx.rollback_arena.frames[h_idx]

                local src_ptr = ffi.cast("uint64_t*", frame.commands[ctx.net_identity])
                local dst_ptr = ffi.cast("uint64_t*", pkt.commands[i])
                dst_ptr[0] = src_ptr[0]
                dst_ptr[1] = src_ptr[1]
            end

            -- RLE COMPRESSION PASS
            ffi.copy(tx_buffer, pkt, header_size)
            local offset = header_size
            local current_run_count = 0
            local current_cmd_ptr = nil

            for i = 0, history_len - 1 do
                local cmd_ptr = ffi.cast("uint64_t*", pkt.commands[i])

                if current_run_count == 0 then
                    current_cmd_ptr = cmd_ptr
                    current_run_count = 1
                elseif current_cmd_ptr[0] == cmd_ptr[0] and current_cmd_ptr[1] == cmd_ptr[1] then
                    current_run_count = current_run_count + 1
                    if current_run_count == 255 then
                        tx_buffer[offset] = current_run_count
                        if (offset + 17) > max_packet_size then
                            print("[WARNING] RLE Compressor hit MTU threshold. Truncating history.")
                            break
                        end
                        ffi.copy(tx_buffer + offset + 1, current_cmd_ptr, 16)
                        offset = offset + 17
                        current_run_count = 0
                    end
                else
                    tx_buffer[offset] = current_run_count
                    ffi.copy(tx_buffer + offset + 1, current_cmd_ptr, 16)
                    offset = offset + 17

                    current_cmd_ptr = cmd_ptr
                    current_run_count = 1
                end
            end

            if current_run_count > 0 then
                tx_buffer[offset] = current_run_count
                ffi.copy(tx_buffer + offset + 1, current_cmd_ptr, 16)
                offset = offset + 17
            end

            local needs_relay = false
            for p = 0, MAX_PLAYERS - 1 do
                if p ~= ctx.net_identity and ctx.peer_active[p] then
                    if ctx.p2p_established and ctx.p2p_established[p] then
                        net.SendTo(tx_buffer, offset, p) -- Sending compressed buffer + length
                    else
                        needs_relay = true
                    end
                end
            end

            if needs_relay then
                net.SendTo(tx_buffer, offset, MAX_PLAYERS)
            end
        end,

        intercept_network = function(ctx, current_tick)
            local count = net.RecvAll(global_in_buffer, MAX_BURST_PACKETS)
            for i = 0, count - 1 do
                local rx_pkt = global_in_buffer[i]
                local pkt = scratch_in_pkt

                if rx_pkt.len < header_size then
                    goto continue_inbox
                end

                -- Read header metadata
                ffi.copy(pkt, rx_pkt.data, header_size)

                if pkt.history_count > HISTORY_LEN then
                    goto continue_inbox
                end

                local rx_offset = header_size
                local decompressed_count = 0

                -- RLE Decompression Loop
                while (rx_offset + 17) <= rx_pkt.len and decompressed_count < pkt.history_count do
                    local run_count = rx_pkt.data[rx_offset]
                    local cmd_data = rx_pkt.data + rx_offset + 1

                    for r = 0, run_count - 1 do
                        if decompressed_count < pkt.history_count then
                            ffi.copy(pkt.commands[decompressed_count], cmd_data, 16)
                            decompressed_count = decompressed_count + 1
                        end
                    end
                    rx_offset = rx_offset + 17
                end

                -- [!] CRITICAL DETERMINISM CHECK:
                -- If the bytes on the wire didn't match the history claim, the packet was truncated.
                -- Do NOT apply partial or zeroed data. Drop it and wait for the next frame's history recovery.
                if decompressed_count < pkt.history_count then
                    goto continue_inbox
                end

                local pid = pkt.player_id
                if pid == ctx.net_identity then
                    goto continue_inbox
                end

                if pkt.frame_tick < ctx.rollback_arena.confirmed_tick then
                    goto continue_inbox
                end

                if pid < MAX_PLAYERS and pkt.frame_tick >= 0 and ctx.peer_active[pid] then
                    local relevant_ack = pkt.peer_acks[ctx.net_identity]
                    if relevant_ack > ctx.peer_ack_of_me[pid] then
                        ctx.peer_ack_of_me[pid] = relevant_ack
                    end

                    local window_start = math.max(0, current_tick - HISTORY_HORIZON)
                    local window_end = math.min(current_tick + RING_MASK, ctx.rollback_arena.confirmed_tick + RING_MASK)

                    for h = 0, pkt.history_count - 1 do
                        local h_tick = pkt.base_tick + h
                        if h_tick > ctx.rollback_arena.confirmed_tick and h_tick >= window_start and h_tick <= window_end then
                            local h_idx = bit.band(h_tick, RING_MASK)
                            local h_frame = ctx.rollback_arena.frames[h_idx]

                            if h_frame.tick ~= h_tick then
                                h_frame.tick = h_tick
                                h_frame.state = STATE_EMPTY
                                for p_scan = 0, MAX_PLAYERS - 1 do
                                    -- Flushes the full 16-byte block (both slots) to zero
                                    ffi.fill(h_frame.commands[p_scan], 16)
                                end
                                h_frame.state_checksum = 0
                                h_frame.remote_checksum = 0
                            end

                            local inc_ptr = ffi.cast("uint64_t*", pkt.commands[h])
                            local h_ptr = ffi.cast("uint64_t*", h_frame.commands[pid])

                            if h_ptr[0] ~= inc_ptr[0] or h_ptr[1] ~= inc_ptr[1] then
                                if h_tick < current_tick then
                                    if ctx.rollback_arena.is_rollback_active == 0 or h_tick < ctx.rollback_arena.rollback_target then
                                        ctx.rollback_arena.is_rollback_active = 1
                                        ctx.rollback_arena.rollback_target = h_tick
                                    end
                                end
                                h_ptr[0] = inc_ptr[0]
                                h_ptr[1] = inc_ptr[1]
                            end
                        end
                    end

                    local payload_highest_tick = pkt.base_tick + pkt.history_count - 1
                    if pkt.base_tick <= ctx.peer_highest_tick[pid] + 1 then
                        if payload_highest_tick > ctx.peer_highest_tick[pid] then
                            ctx.peer_highest_tick[pid] = payload_highest_tick
                        end
                    end

                    if pkt.checksum_tick > 0 and pkt.checksum_tick >= math.max(0, ctx.rollback_arena.confirmed_tick - DESYNC_SWEEP) and pkt.checksum_tick <= current_tick then
                        local c_idx = bit.band(pkt.checksum_tick, RING_MASK)
                        local c_frame = ctx.rollback_arena.frames[c_idx]
                        if c_frame.tick == pkt.checksum_tick then
                            c_frame.remote_checksum = pkt.state_checksum
                        end
                    end
                end
                ::continue_inbox::
            end
        end
    }
end

return Pump
