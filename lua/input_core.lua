local bit = require("bit")
local cfg_net = require("config_net")

local InputCore = {}

function InputCore.SubmitCommand(ctx, opcode, flags, target_id, target_pos)
    local c_idx = bit.band(ctx.sim_tick_count, cfg_net.RING_MASK)
    local pending_frame = ctx.rollback_arena.frames[c_idx]

    if pending_frame.tick ~= ctx.sim_tick_count then
        pending_frame.tick = ctx.sim_tick_count
        for p = 0, cfg_net.MAX_PLAYERS - 1 do
            pending_frame.commands[p][0].opcode = 0
            pending_frame.commands[p][1].opcode = 0
        end
        pending_frame.state_checksum = 0
        pending_frame.remote_checksum = 0
        pending_frame.state = 0
        pending_frame.remote_peer_id = 0
    end

    local cmds = pending_frame.commands[ctx.net_identity]

    if cmds[0].opcode == 0 then
        cmds[0].opcode = opcode; cmds[0].flags = flags
        cmds[0].target_id = target_id; cmds[0].target_pos = target_pos
    elseif cmds[1].opcode == 0 then
        cmds[1].opcode = opcode; cmds[1].flags = flags
        cmds[1].target_id = target_id; cmds[1].target_pos = target_pos
    else
        print("[WARNING] Engine Command Buffer saturated for tick " .. ctx.sim_tick_count)
    end
end

return InputCore
