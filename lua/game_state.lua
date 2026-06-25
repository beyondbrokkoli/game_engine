-- lua/game_state.lua
local ffi = require("ffi")
local bit = require("bit")
local net = require("network")
local Fixed = require("fixed_math")

local Game = {}

function Game.init(app_ctx)
    -- 1. UPVALUES
    local map_width = app_ctx.cfg_sim.world.map_width
    local map_height = app_ctx.cfg_sim.world.map_height
    local total_tiles = map_width * map_height
    local MAX_PLAYERS = app_ctx.cfg_net.MAX_PLAYERS

    -- 2. DYNAMIC FFI CDEF (Protected against double-loading)
    if not pcall(ffi.sizeof, "GameState") then
        ffi.cdef(string.format([[
            typedef struct {
                uint16_t terrain[8][%d];
                int32_t elevation[8][%d];
                uint32_t rng_state[1];
            } GameState;
        ]], total_tiles, total_tiles))
    end

    -- 3. THE EXECUTABLE CLOSURE
    return {
        GetStateName = function() return "GameState" end,
        GetStateSize = function() return ffi.sizeof("GameState") end,

        InitState = function(session_token)
            local state = ffi.new("GameState")

            -- 1. Deterministic RNG Seed
            local ptr = ffi.cast("uint32_t*", ffi.new("uint64_t[1]", session_token or 0))
            state.rng_state[0] = bit.bxor(ptr[0], ptr[1])
            if state.rng_state[0] == 0 then state.rng_state[0] = 0x811C9DC5 end

            -- 2. Initial World State Painting (ISOLATED TO LAYER 0 & ELEVATED)
            local cx = math.floor(map_width / 2)
            local cz = math.floor(map_height / 2)
            local w = map_width

            local elev_val = Fixed.from_float(15.0)

            -- Center (White)
            state.terrain[0][cz * w + cx] = 10
            state.elevation[0][cz * w + cx] = elev_val

            -- Arms (Red / Blue)
            for x = cx + 1, cx + 5 do
                state.terrain[0][cz * w + x] = 11
                state.elevation[0][cz * w + x] = elev_val
            end
            for z = cz + 1, cz + 5 do
                state.terrain[0][z * w + cx] = 12
                state.elevation[0][z * w + cx] = elev_val
            end

            -- Corners (Red)
            local corners = {
                (cz - 5) * w + (cx - 5),
                (cz - 5) * w + (cx + 5),
                (cz + 5) * w + (cx - 5),
                (cz + 5) * w + (cx + 5)
            }

            for _, idx in ipairs(corners) do
                state.terrain[0][idx] = 13
                state.elevation[0][idx] = elev_val
            end

            return state
        end,

        SimulateTick = function(state, commands_array, tick)
            for p = 0, MAX_PLAYERS - 1 do
                for c = 0, 1 do
                    local cmd = commands_array[p][c]

                    if cmd.opcode == 1 then
                        local idx = cmd.target_pos
                        if idx < total_tiles then
                            state.terrain[p][idx] = p
                            state.elevation[p][idx] = Fixed.from_float(15.0)
                        end
                    elseif cmd.opcode == 2 then
                        local idx = cmd.target_pos
                        if idx < total_tiles then
                            for target_p = 0, MAX_PLAYERS - 1 do
                                state.terrain[target_p][idx] = 0
                                state.elevation[target_p][idx] = Fixed.from_float(0.0)
                            end
                        end
                    end
                end
            end
        end,

        HashState = function(state)
            local h1 = net.HashState(state.terrain, ffi.sizeof(state.terrain), 0)
            local h2 = net.HashState(state.elevation, ffi.sizeof(state.elevation), h1)
            return net.HashState(state.rng_state, 4, h2)
        end
    }
end

return Game
