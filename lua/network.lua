-- lua/network.lua
local ffi = require("ffi")

ffi.cdef[[
    int vx_net_host(int port);
    int vx_net_connect(uint8_t peer_id, const char* ip, int port);
    void vx_net_set_session(uint64_t token);
    void vx_net_set_player_id(uint8_t id);
    int vx_net_recv_all(void* out_buffer, int max_count);
    void vx_net_send_to(void* data, size_t len, uint8_t target_peer);
    void vx_net_set_relay_ip(const char* ip);
    uint32_t vx_net_hash_state(const void* data, size_t length, uint32_t initial_hash);
    int vx_net_stun_punch(const char* stun_server_ip, int stun_port, char* out_ip, int* out_port);
    void vx_net_shutdown(void);
]]

-- Dynamically load the binary depending on the host OS
local lib_path = jit.os == "Windows" and "bin/vx_net.dll" or "./bin/libvx_net.so"
local net_lib = ffi.load(lib_path)

local Network = {}

function Network.Host(port)
    return net_lib.vx_net_host(port) == 0
end

function Network.Connect(peer_id, ip, port)
    return net_lib.vx_net_connect(peer_id, ip, port) == 0
end

function Network.SetSession(token)
    net_lib.vx_net_set_session(token)
end

function Network.SetPlayerId(id)
    net_lib.vx_net_set_player_id(id)
end

function Network.SendTo(pkt, len, peer_id)
    net_lib.vx_net_send_to(pkt, len, peer_id)
end

function Network.RecvAll(out_buffer, max_count)
    return net_lib.vx_net_recv_all(out_buffer, max_count)
end

function Network.StunPunch(stun_ip, stun_port)
    local out_ip = ffi.new("char[16]")
    local out_port = ffi.new("int[1]")
    local success = net_lib.vx_net_stun_punch(stun_ip, stun_port, out_ip, out_port) == 1
    if success then
        return true, ffi.string(out_ip), out_port[0]
    end
    return false, "0.0.0.0", 0
end

function Network.SetRelayIP(ip)
    net_lib.vx_net_set_relay_ip(ip)
end

function Network.HashState(data_ptr, length, initial_hash)
    return net_lib.vx_net_hash_state(data_ptr, length, initial_hash)
end

function Network.Shutdown()
    net_lib.vx_net_shutdown()
end

return Network
