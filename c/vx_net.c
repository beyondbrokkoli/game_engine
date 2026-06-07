/* c/vx_net.c - Non-blocking UDP bridge for Deterministic Lockstep */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <stdatomic.h>

#include "shared_structs.h" // Brings in all the CFG_ and FRAME_STATE_ defines

// Quick macro to turn the size into a bitmask (128 -> 127)
#define NET_RING_MASK (CFG_ROLLBACK_BUFFER_SIZE - 1)

#if defined(_WIN32)
    #define EXPORT __declspec(dllexport)
    #include <winsock2.h>
    #include <ws2tcpip.h>
    #pragma comment(lib, "ws2_32.lib")
    typedef int socklen_t;
    typedef SSIZE_T ssize_t;
    typedef SOCKET vx_socket_t; /* [NEW] Native Windows socket type */
    static int net_wsa_initialized = 0;
    #define NET_CLOSE closesocket
    #define NET_ERROR SOCKET_ERROR
    #define NET_INVALID INVALID_SOCKET
    #define NET_WOULDBLOCK WSAEWOULDBLOCK
    #define NET_LASTERR WSAGetLastError()
#else
    #define EXPORT __attribute__((visibility("default")))
    #include <sys/socket.h>
    #include <netinet/in.h>
    #include <arpa/inet.h>
    #include <netdb.h>
    #include <fcntl.h>
    #include <unistd.h>
    #include <errno.h>
    typedef int vx_socket_t; /* [NEW] Native POSIX socket type */
    #define NET_CLOSE close
    #define NET_ERROR -1
    #define NET_INVALID -1
    #define NET_WOULDBLOCK EWOULDBLOCK
    #define NET_LASTERR errno
#endif


static struct {
    vx_socket_t sock;
    int is_bound;
    int is_connected;
    struct sockaddr_in remote_addr;
    socklen_t remote_addr_len;
    _Atomic(int) last_error;

    // Hardening variables
    uint64_t current_session_token;
    int is_address_pinned;
} g_net = {
    .sock = NET_INVALID,
    .is_bound = 0,
    .is_connected = 0,
    .remote_addr_len = sizeof(struct sockaddr_in),
    .current_session_token = 0,
    .is_address_pinned = 0
};

// Platform Abstraction: Non-blocking socket setup
static inline int net_set_nonblocking(int sock) {
#if defined(_WIN32)
    u_long mode = 1;
    return ioctlsocket(sock, FIONBIO, &mode) == 0 ? 0 : -1;
#else
    int flags = fcntl(sock, F_GETFL, 0);
    return (flags < 0) ? -1 : fcntl(sock, F_SETFL, flags | O_NONBLOCK);
#endif
}

static inline void net_cleanup_platform(void) {
#if defined(_WIN32)
    if (net_wsa_initialized) {
        WSACleanup();
        net_wsa_initialized = 0;
    }
#endif
}

static inline int net_init_platform(void) {
#if defined(_WIN32)
    if (!net_wsa_initialized) {
        WSADATA wsa;
        if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return -1;
        net_wsa_initialized = 1;
    }
#endif
    return 0;
}

/**
 * vx_net_host(int port)
 * Bind a UDP socket to port for receiving/sending.
 * Returns: 0 on success, -1 on failure.
 */

#if defined(_WIN32)
    #include <mstcpip.h>

    // [MINGW FIX] If the compiler headers are missing the Microsoft IOCTL, manually define it.
    #ifndef SIO_UDP_CONNRESET
        #define SIO_UDP_CONNRESET _WSAIOW(IOC_VENDOR, 12)
    #endif
#endif

EXPORT int vx_net_host(int port) {
    if (g_net.sock != NET_INVALID) {
        NET_CLOSE(g_net.sock);
        g_net.sock = NET_INVALID;
        g_net.is_bound = 0;
        g_net.is_connected = 0;
    }

    if (net_init_platform() < 0) {
        atomic_store_explicit(&g_net.last_error, -100, memory_order_release);
        return -1;
    }

    /* [FIXED] Use the cross-platform type instead of int */
    vx_socket_t sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);

    if (sock == NET_INVALID) {
        atomic_store_explicit(&g_net.last_error, NET_LASTERR, memory_order_release);
        return -1;
    }

    /* SO_REUSEADDR for rapid restarts */
    int opt = 1;
#if defined(_WIN32)
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, (const char*)&opt, sizeof(opt));
#else
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
#endif

    if (net_set_nonblocking(sock) < 0) {
        NET_CLOSE(sock);
        atomic_store_explicit(&g_net.last_error, NET_LASTERR, memory_order_release);
        return -1;
    }

    struct sockaddr_in local = {0};
    local.sin_family = AF_INET;
    local.sin_addr.s_addr = htonl(INADDR_ANY);
    local.sin_port = htons((uint16_t)port);

    if (bind(sock, (struct sockaddr*)&local, sizeof(local)) == NET_ERROR) {
        NET_CLOSE(sock);
        atomic_store_explicit(&g_net.last_error, NET_LASTERR, memory_order_release);
        return -1;
    }

#if defined(_WIN32)
    // [CRITICAL WINDOWS FIX] Disable WSAECONNRESET for UDP Hole Punching
    DWORD dwBytesReturned = 0;
    BOOL bNewBehavior = FALSE;
    WSAIoctl(sock, SIO_UDP_CONNRESET, &bNewBehavior, sizeof(bNewBehavior), NULL, 0, &dwBytesReturned, NULL, NULL);
#endif

    g_net.sock = sock;
    g_net.is_bound = 1;
    g_net.is_connected = 0;
    atomic_store_explicit(&g_net.last_error, 0, memory_order_release);

    fprintf(stderr, "[NET] UDP socket bound to port %d (fd=%d)\n", port, sock);
    return 0;
}

/**
 * vx_net_connect(const char* ip, int port)
 * Set remote destination for send_command(). Does NOT establish TCP-like connection.
 * Returns: 0 on success, -1 on failure.
 */
EXPORT int vx_net_connect(const char* ip, int port) {
    if (g_net.sock == NET_INVALID) {
        atomic_store_explicit(&g_net.last_error, -101, memory_order_release);
        return -1;
    }
    if (!ip || port < 1 || port > 65535) {
        atomic_store_explicit(&g_net.last_error, -102, memory_order_release);
        return -1;
    }

    g_net.remote_addr.sin_family = AF_INET;
    g_net.remote_addr.sin_port = htons((uint16_t)port);

    if (inet_pton(AF_INET, ip, &g_net.remote_addr.sin_addr) <= 0) {
        /* Fallback: try as hostname */
        struct hostent* he = gethostbyname(ip);
        if (!he || he->h_addrtype != AF_INET) {
            atomic_store_explicit(&g_net.last_error, NET_LASTERR, memory_order_release);
            return -1;
        }
        memcpy(&g_net.remote_addr.sin_addr, he->h_addr_list[0], he->h_length);
    }

    g_net.is_connected = 1;
    atomic_store_explicit(&g_net.last_error, 0, memory_order_release);

    fprintf(stderr, "[NET] Remote target set: %s:%d\n", ip, port);
    return 0;
}

// Send exactly 'len' bytes from the pointer
EXPORT void vx_net_send(const void* payload, size_t len) {
    if (g_net.sock == NET_INVALID || !payload) return;
    if (!g_net.is_connected) return;

    sendto(g_net.sock, (const char*)payload, len, 0,
           (struct sockaddr*)&g_net.remote_addr, g_net.remote_addr_len);
}

// Exported initialization called right after matchmaker handoff
EXPORT void vx_net_set_session(uint64_t token) {
    g_net.current_session_token = token;
    g_net.is_address_pinned = 0; // Reset tracking for new match
}

EXPORT int vx_net_poll(void* out_buffer, size_t expected_len) {
    if (g_net.sock == NET_INVALID || !out_buffer) return 0;

    struct sockaddr_in from;
    socklen_t from_len = sizeof(from);
    char temp_buf[2048];

    // Process up to 100 packets in queue per frame execution
    for (int i = 0; i < 100; i++) {
        ssize_t recvd = recvfrom(g_net.sock, temp_buf, sizeof(temp_buf), 0, (struct sockaddr*)&from, &from_len);
        if (recvd < 0) {
            return 0; // Queue empty for this frame
        }

        if (recvd == expected_len) {
            LockstepPacket* incoming = (LockstepPacket*)temp_buf;

            // CRITICAL SECURITY CHECK 1: Validate Matchmaker Session Token
            if (incoming->session_token != g_net.current_session_token) {
                // Silently drop unauthorized packets (prevents port scanning leaks)
                continue;
            }

            // CRITICAL SECURITY CHECK 2: Validate Pinned Address
            if (g_net.is_address_pinned) {
                if (from.sin_addr.s_addr != g_net.remote_addr.sin_addr.s_addr ||
                    from.sin_port != g_net.remote_addr.sin_port) {
                    // Hijack attempt caught! Someone with a leaked token or an old packet is spoofing.
                    continue;
                }
            } else {
                // First valid packet encountered! Pin the connection securely.
                g_net.is_connected = 1;
                g_net.remote_addr = from;
                g_net.remote_addr_len = from_len;
                g_net.is_address_pinned = 1;
                fprintf(stderr, "[SECURITY] Session locked securely to peer source: %s:%d\n",
                        inet_ntoa(from.sin_addr), ntohs(from.sin_port));
            }

            // Validation checks passed successfully. Extract the packet payload.
            memcpy(out_buffer, temp_buf, expected_len);
            return 1;
        }
    }
    return 0;
}

/**
 * vx_net_get_last_error(void)
 * Retrieve last socket error code for debugging.
 * Returns platform-specific error code or 0 if none.
 */
EXPORT int vx_net_get_last_error(void) {
    return atomic_load_explicit(&g_net.last_error, memory_order_acquire);
}

// The SSoT Rollback Arena
static RollbackBuffer g_rollback_arena = {0};

EXPORT RollbackBuffer* vx_net_get_arena(void) {
    return &g_rollback_arena;
}

EXPORT void vx_net_pump(void) {
    // 1. Grab the current tick that Lua just wrote into the shared arena
    uint32_t tick = g_rollback_arena.head_tick;
    uint32_t idx = tick & NET_RING_MASK;
    RollbackFrame* current_frame = &g_rollback_arena.frames[idx];

    // 2. Broadcast local reality over UDP (With Redundant History)
    LockstepPacket out_pkt;

    // [THE FIX] Inject the crypto token into the packet header!
    out_pkt.session_token = g_net.current_session_token;

    out_pkt.frame_tick = tick;
    out_pkt.player_input = current_frame->local_input;
    out_pkt.click_grid_idx = current_frame->local_click;

    for (int i = 1; i <= 7; i++) {
        uint32_t p_tick = tick - i;
        out_pkt.past_inputs[i-1] = g_rollback_arena.frames[p_tick & NET_RING_MASK].local_input;
        out_pkt.past_clicks[i-1] = g_rollback_arena.frames[p_tick & NET_RING_MASK].local_click;
    }

    vx_net_send(&out_pkt, sizeof(LockstepPacket));

    // 3. Process Incoming Network Reality
    LockstepPacket in_pkt;
    while (vx_net_poll(&in_pkt, sizeof(LockstepPacket))) {

        // REDUNDANT HISTORY RECOVERY (Process oldest to newest)
        for (int i = 7; i >= 1; i--) {
            uint32_t h_tick = in_pkt.frame_tick - i;
            uint32_t h_idx = h_tick & NET_RING_MASK;
            RollbackFrame* h_frame = &g_rollback_arena.frames[h_idx];

            if (h_frame->state == FRAME_STATE_PREDICTED && h_frame->tick == h_tick) {
                uint32_t h_input = in_pkt.past_inputs[i-1];
                int32_t h_click = in_pkt.past_clicks[i-1];

                if (h_frame->remote_input != h_input || h_frame->remote_click != h_click) {
                    if (!g_rollback_arena.is_rollback_active || h_tick < g_rollback_arena.rollback_target) {
                        g_rollback_arena.is_rollback_active = 1;
                        g_rollback_arena.rollback_target = h_tick;
                    }
                }
                h_frame->remote_input = h_input;
                h_frame->remote_click = h_click;
                h_frame->state = FRAME_STATE_CONFIRMED;
            }
        }

        uint32_t r_idx = in_pkt.frame_tick & NET_RING_MASK;
        RollbackFrame* r_frame = &g_rollback_arena.frames[r_idx];

        // THE GHOST SHIELD: Exorcise ancient delayed packets
        if ((int32_t)(in_pkt.frame_tick - r_frame->tick) < 0 && r_frame->tick != 0) {
            printf("[NET] 🚨 EXORCISM: Dropped ancient packet %u! Slot already claimed by %u.\n",
                   in_pkt.frame_tick, r_frame->tick);
            continue;
        }

        // Temporal Fracture Check
        if (r_frame->state == FRAME_STATE_PREDICTED && r_frame->tick == in_pkt.frame_tick) {
            if (r_frame->remote_input != in_pkt.player_input || r_frame->remote_click != in_pkt.click_grid_idx) {
                if (!g_rollback_arena.is_rollback_active || in_pkt.frame_tick < g_rollback_arena.rollback_target) {
                    g_rollback_arena.is_rollback_active = 1;
                    g_rollback_arena.rollback_target = in_pkt.frame_tick;
                }
            }
        }

        // Overwrite with confirmed reality
        r_frame->tick = in_pkt.frame_tick;
        r_frame->remote_input = in_pkt.player_input;
        r_frame->remote_click = in_pkt.click_grid_idx;
        r_frame->state = FRAME_STATE_CONFIRMED;

        if (in_pkt.frame_tick > g_rollback_arena.confirmed_tick) {
            g_rollback_arena.confirmed_tick = in_pkt.frame_tick;
        }
    }

    // 4. Predict the future if we didn't get a confirmation
    if (current_frame->state != FRAME_STATE_CONFIRMED) {
        uint32_t prev_idx = (tick - 1) & NET_RING_MASK;
        current_frame->remote_input = g_rollback_arena.frames[prev_idx].remote_input;
        current_frame->remote_click = -1;
        current_frame->state = FRAME_STATE_PREDICTED;
    }
}

/**
 * vx_net_stun_punch(ip, port, out_ip, out_port)
 * Fires a STUN Binding Request using the already-bound g_net.sock.
 * Extracts the NAT-translated Public IP and Port.
 */
EXPORT int vx_net_stun_punch(const char* stun_server_ip, int stun_port, char* out_ip, int* out_port) {
    if (g_net.sock == NET_INVALID) return 0;

    struct sockaddr_in stun_addr = {0};
    stun_addr.sin_family = AF_INET;
    stun_addr.sin_port = htons((uint16_t)stun_port);
    inet_pton(AF_INET, stun_server_ip, &stun_addr.sin_addr);

    // Construct a raw STUN Binding Request
    uint8_t req[20] = {0};
    req[0] = 0x00; req[1] = 0x01; // Type: Binding Request
    req[4] = 0x21; req[5] = 0x12; req[6] = 0xA4; req[7] = 0x42; // Magic Cookie
    for(int i = 8; i < 20; i++) req[i] = i; // Dummy Transaction ID

    sendto(g_net.sock, (const char*)req, 20, 0, (struct sockaddr*)&stun_addr, sizeof(stun_addr));

    uint8_t resp[1024];
    struct sockaddr_in from;
    socklen_t from_len = sizeof(from);

    // Timeout loop (Socket is non-blocking)
    for (int wait = 0; wait < 50; wait++) {
        ssize_t recvd = recvfrom(g_net.sock, (char*)resp, sizeof(resp), 0, (struct sockaddr*)&from, &from_len);

        if (recvd >= 20) {
            uint16_t msg_len = (resp[2] << 8) | resp[3];
            int offset = 20;

            // Parse STUN Attributes looking for XOR-MAPPED-ADDRESS (0x0020)
            while (offset < 20 + msg_len && offset + 4 <= recvd) {
                uint16_t attr_type = (resp[offset] << 8) | resp[offset+1];
                uint16_t attr_len = (resp[offset+2] << 8) | resp[offset+3];

                if (attr_type == 0x0020) {
                    uint16_t xport = (resp[offset+6] << 8) | resp[offset+7];
                    uint32_t xip = (resp[offset+8] << 24) | (resp[offset+9] << 16) | (resp[offset+10] << 8) | resp[offset+11];

                    // Un-XOR against the Magic Cookie
                    *out_port = xport ^ 0x2112;
                    uint32_t real_ip = xip ^ 0x2112A442;

                    snprintf(out_ip, 16, "%d.%d.%d.%d",
                        (real_ip >> 24) & 0xFF, (real_ip >> 16) & 0xFF,
                        (real_ip >> 8) & 0xFF, real_ip & 0xFF);

                    return 1; // STUN Hole Punch Success!
                }

                // Enforce RFC 5389 4-byte padding alignment!
                int padded_len = (attr_len + 3) & ~3;
                offset += 4 + padded_len;
            }
        }

#if defined(_WIN32)
        Sleep(10);
#else
        usleep(10000);
#endif
    }
    return 0; // STUN timeout
}

EXPORT void vx_net_shutdown(void) {
    if (g_net.sock != NET_INVALID) {
        NET_CLOSE(g_net.sock);
        g_net.sock = NET_INVALID;
    }
    g_net.is_bound = 0;
    g_net.is_connected = 0;
    net_cleanup_platform();
    fprintf(stderr, "[NET] Socket shutdown complete.\n");
}
