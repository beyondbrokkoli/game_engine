-- lua/net_utils.lua
local ffi = require("ffi")
local json_util = require("json_util")
local cfg_net = require("config_net")
local net = require("network")
local NetUtils = {}

-- 1. DUPLICATE THE OS TIMERS HERE
local function sys_sleep(ms)
    if jit.os == "Windows" then
        ffi.C.Sleep(ms)
    else
        ffi.C.usleep(ms * 1000)
    end
end

local get_time_hires
if jit.os == "Windows" then
    local kernel32 = ffi.load("kernel32")
    local freq = ffi.new("int64_t[1]")
    kernel32.QueryPerformanceFrequency(freq)
    local inv_freq = 1.0 / tonumber(freq[0])
    get_time_hires = function()
        local count = ffi.new("int64_t[1]")
        kernel32.QueryPerformanceCounter(count)
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

local function http_post(url, json_payload)
    local payload_path = "matchmaker_payload.json"
    local f = assert(io.open(payload_path, "w"), "Failed to open temp file")
    f:write(json_payload)
    f:close()
    local cmd = string.format('curl -s -X POST -H "Content-Type: application/json" -d "@%s" %s', payload_path, url)
    local pf = io.popen(cmd)
    local res = pf:read("*a")
    pf:close()
    os.remove(payload_path)
    return res
end

local function http_get(url)
    local cmd = string.format('curl -s "%s"', url)
    local f = io.popen(cmd)
    if not f then return "" end
    local res = f:read("*a")
    f:close()
    return res
end

function NetUtils.get_local_ip()
    local cmd = ""
    if jit.os == "Windows" then
        cmd = 'powershell -Command "(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike \'127.*\' -and $_.IPAddress -notlike \'169.254.*\' } | Select-Object -First 1).IPAddress"'
    else
        cmd = "ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i==\"src\") print $(i+1)}'"
    end
    local f = io.popen(cmd)
    if not f then return "127.0.0.1" end
    local res = f:read("*a")
    f:close()
    res = res:gsub("%s+", "")
    if not res:match("^%d+%.%d+%.%d+%.%d+$") then return "127.0.0.1" end
    return res
end

local function extract_true_64bit_token(json_string)
    local token_digits = json_string:match('"session_token"%s*:%s*(%d+)')
    assert(token_digits, "FATAL: Could not locate session_token digits in JSON payload")
    local val = ffi.cast("uint64_t", 0)
    for i = 1, #token_digits do
        local byte = string.byte(token_digits, i)
        if byte >= 48 and byte <= 57 then
            val = (val * 10) + (byte - 48)
        else
            break
        end
    end
    return val
end

-- 3. THE EXPORTED MODULE
function NetUtils.BootstrapNetworkTopology(local_port, my_local_ip)
    print(string.format("[STUN] Querying external NAT edges at %s:%d...", cfg_net.STUN_SERVER, cfg_net.STUN_PORT))
    local stun_ok, my_pub_ip, my_pub_port = net.StunPunch(cfg_net.STUN_SERVER, cfg_net.STUN_PORT)

    if not stun_ok then
        print("[WARNING] STUN negotiation failed. Operating via local loopbacks.")
        my_pub_ip = my_local_ip
        my_pub_port = local_port
    else
        print(string.format("[STUN] Discovery successful. External mapped endpoint: %s:%d", my_pub_ip, my_pub_port))
    end

    print("\n[MATCHMAKING] Select Mode: (H)ost New Game or (J)oin Existing Lobby")
    io.write("> ")
    local mode_input = io.read("*l"):upper()

    local lobby_id = ""
    local session_token = nil
    local initial_payload = json_util.encode({
        public_ip = my_pub_ip, public_port = my_pub_port,
        local_ip = my_local_ip, local_port = local_port
    })

    if mode_input == "H" then
        print("Enter Target Lobby Size (2-8):")
        io.write("> ")
        local target_size = tonumber(io.read("*l")) or 2
        target_size = math.max(2, math.min(8, target_size))

        local host_payload = json_util.encode({
            public_ip = my_pub_ip, public_port = my_pub_port,
            local_ip = my_local_ip, local_port = local_port,
            target_size = target_size
        })

        print(string.format("[MATCHMAKER] Requesting new lobby for %d players...", target_size))
        local response = http_post(cfg_net.MATCHMAKER_URL .. "/host", host_payload)
        session_token = extract_true_64bit_token(response)
        lobby_id = json_util.decode(response).lobby_id
        print("[MATCHMAKER] Hosted Lobby, holding room: " .. lobby_id)
    else
        if mode_input == "J" then
            print("Enter Target 4-Character Lobby ID:")
            io.write("> ")
            lobby_id = io.read("*l"):upper()
        else
            lobby_id = mode_input:upper()
        end
        print("[MATCHMAKER] Joining Lobby: " .. lobby_id)
        local response = http_post(cfg_net.MATCHMAKER_URL .. "/join/" .. lobby_id, initial_payload)
        session_token = extract_true_64bit_token(response)
    end

    print("[MATCHMAKER] Polling quorum status. Waiting for 'locked'...")
    local status_data = nil
    while true do
        local raw_res = http_get(cfg_net.MATCHMAKER_URL .. "/status/" .. lobby_id)
        if raw_res and raw_res ~= "" then
            status_data = json_util.decode(raw_res)
            if status_data.status == "locked" then
                print(string.format("[MATCHMAKER] Quorum reached (%d/%d). Lobby is LOCKED.", status_data.player_count, cfg_net.MAX_PLAYERS))
                break
            end
        end
        sys_sleep(500)
    end

    local local_id = 0
    for i, p in ipairs(status_data.players) do
        if p.ip == my_pub_ip and tonumber(p.port) == my_pub_port and p.local_ip == my_local_ip and p.local_port == local_port then
            local_id = i - 1; break
        end
    end

    net.SetPlayerId(local_id)
    net.SetSession(session_token)
    print(string.format("[SYSTEM] Assigning Identity: Node %d. Meshing topology...", local_id))

    local p2p_established = {}
    local active_peers = {}

    for i, p in ipairs(status_data.players) do
        local peer_id = i - 1
        if peer_id ~= local_id then
            active_peers[peer_id] = true
            if p.ip == my_pub_ip or p.ip == "127.0.0.1" or my_pub_ip == "127.0.0.1" then
                local target_ip = (p.local_ip == my_local_ip) and "127.0.0.1" or p.local_ip
                net.Connect(peer_id, target_ip, tonumber(p.local_port))
                p2p_established[peer_id] = true
                print(string.format("[ROUTING] Node %d clamped to LAN (%s:%d). Hairpin bypassed.", peer_id, target_ip, p.local_port))
            else
                net.Connect(peer_id, p.ip, tonumber(p.port))
                print(string.format("[ROUTING] Node %d is WAN. Staging for ICE...", peer_id))
            end
        end
    end

    local real_time_remaining = status_data.start_time - status_data.server_time
    local sync_start_time = get_time_hires()

    if real_time_remaining > 0 then
        print(string.format("[ICE] Quorum locked. Initiating Mutual Handshake for %.2f seconds...", real_time_remaining))

        -- [!] The Consensus: Using our lightweight 40-byte Trojan struct
        local ice_packet_size = ffi.sizeof("IcePunchPacket")
        local handshake_buffer = ffi.new("RxPacket[32]")
        local scratch_ice = ffi.new("IcePunchPacket")
        local p2p_heard = {}

        while (get_time_hires() - sync_start_time) < real_time_remaining do
            for peer_id, active in pairs(active_peers) do
                if active and not p2p_established[peer_id] then
                    local ping_pkt = ffi.new("IcePunchPacket")
                    ping_pkt.session_token = session_token
                    ping_pkt.player_id = local_id
                    ping_pkt.is_ping = p2p_heard[peer_id] and 1 or 0

                    net.SendTo(ping_pkt, ice_packet_size, peer_id)
                end
            end

            local count = net.RecvAll(handshake_buffer, 32)
            for i = 0, count - 1 do
                local rx_pkt = handshake_buffer[i]

                -- Ensure it's big enough before copying to avoid FFI boundary violations
                if rx_pkt.len >= ice_packet_size then
                    ffi.copy(scratch_ice, rx_pkt.data, ice_packet_size)

                    if scratch_ice.session_token == session_token then
                        local sender = scratch_ice.player_id
                        p2p_heard[sender] = true

                        if scratch_ice.is_ping >= 1 and not p2p_established[sender] then
                            p2p_established[sender] = true
                            print(string.format("[ICE] Mutual P2P Punch-Through SUCCESS for Node %d!", sender))
                        end
                    end
                end
            end
            sys_sleep(50)
        end
    end

    print("[ICE] Sync window closed. Evaluating routing topologies...")
    for peer_id, active in pairs(active_peers) do
        if active then
            if p2p_established[peer_id] then
                print(string.format("[ROUTING] Node %d -> P2P [DIRECT RESIDENTIAL]", peer_id))
            else
                print(string.format("[ROUTING] Node %d -> P2P [FAILED]. Tagged for Omnibus Relay.", peer_id))
            end
        end
    end

    net.SetRelayIP(cfg_net.RELAY_IP)
    net.Connect(cfg_net.MAX_PLAYERS, cfg_net.RELAY_IP, cfg_net.RELAY_PORT)

    local reg_pkt = ffi.new("IcePunchPacket")
    reg_pkt.session_token = session_token
    reg_pkt.player_id = local_id
    reg_pkt.is_ping = 0

    local ice_packet_size = ffi.sizeof("IcePunchPacket")
    net.SendTo(reg_pkt, ice_packet_size, cfg_net.MAX_PLAYERS)

    print("[SYSTEM] All routes bound. Drop-in complete.")
    return session_token, local_id, p2p_established, active_peers, status_data
end

return NetUtils
