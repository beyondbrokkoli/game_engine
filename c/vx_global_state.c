/*
   vx_global_state.c — Definitions for all shared global variables
   and implementations of ring/mailbox/lifecycle functions.
*/
#include "vx_global_state.h"

/* ── Global Variable Definitions */

EngineState g_engine;

/* Rely on BSS for structural zeroing; atomics strictly initialized in vx_init_mailbox */
RenderRing g_ring;

RenderThreadInit g_window_wsi[MAX_WINDOWS];
atomic_int       g_wsi_state[MAX_WINDOWS];
atomic_int       g_render_busy[MAX_WINDOWS];
atomic_int       g_transfer_busy[MAX_WINDOWS]; // ADD THIS

vmath_thread_t   g_render_thread;
atomic_int       g_render_thread_active;

TransferJob      g_transfer_ring[TRANSFER_RING_SIZE];

vmath_thread_t   g_transfer_thread;
atomic_int       g_transfer_thread_active;

VkCommandPool    g_render_cmd_pools[MAX_WINDOWS];
VkCommandPool    g_transfer_cmd_pools[MAX_WINDOWS];
VkCommandBuffer  g_render_cmd_buffers[MAX_WINDOWS][3];
VkCommandBuffer  g_transfer_cmd_buffers[MAX_WINDOWS];
VkFence          g_transfer_fences[MAX_WINDOWS];

/* ── Threading Helpers */

vmath_thread_t vmath_thread_start(void* (*func)(void*), void* arg) {
    pthread_t thread;
    pthread_create(&thread, NULL, func, arg);
    return thread;
}

void vmath_thread_join(vmath_thread_t thread) {
    pthread_join(thread, NULL);
}

/* ── Mailbox Bootstrap */

EXPORT void vx_init_mailbox(void) {
    atomic_init(&g_engine.mailbox.ready_index,  0);
    atomic_init(&g_engine.mailbox.is_running,   1);
    atomic_init(&g_engine.mailbox.lua_finished,  0);
    atomic_init(&g_engine.mailbox.active_window, 0);

    for (int i = 0; i < MAX_WINDOWS; i++) {
        atomic_init(&g_engine.mailbox.tenants[i].vk_instance,    NULL);
        atomic_init(&g_engine.mailbox.tenants[i].vk_surface,     NULL);
        atomic_init(&g_engine.mailbox.tenants[i].glfw_cmd,       CMD_IDLE);
        atomic_init(&g_engine.mailbox.tenants[i].glfw_arg_w,     0);
        atomic_init(&g_engine.mailbox.tenants[i].glfw_arg_h,     0);
        atomic_init(&g_engine.mailbox.tenants[i].last_key_pressed, 0);
        atomic_init(&g_engine.mailbox.tenants[i].wasd_mask,      0);
        atomic_init(&g_engine.mailbox.tenants[i].mouse_dx,       0.0f);
        atomic_init(&g_engine.mailbox.tenants[i].mouse_dy,       0.0f);
        atomic_init(&g_engine.mailbox.tenants[i].mouse_x,        0.0f);
        atomic_init(&g_engine.mailbox.tenants[i].mouse_y,        0.0f);
        atomic_init(&g_engine.mailbox.tenants[i].click_x,        -1.0f);
        atomic_init(&g_engine.mailbox.tenants[i].click_y,        -1.0f);
        atomic_init(&g_engine.mailbox.tenants[i].mouse_left,     0);
        atomic_init(&g_engine.mailbox.tenants[i].mouse_right,    0);
        atomic_init(&g_engine.mailbox.tenants[i].mouse_captured, 0);
        atomic_init(&g_engine.mailbox.tenants[i].window_resized, 0);
        atomic_init(&g_engine.mailbox.tenants[i].win_w,          1280);
        atomic_init(&g_engine.mailbox.tenants[i].win_h,          720);
        atomic_init(&g_engine.mailbox.tenants[i].key_space,      0);
    }

    /* Strict C11 Atomic Initializations */
    atomic_init(&g_ring.locked_mask, 0);
    for (int i = 0; i < MAX_WINDOWS; i++) {
        atomic_init(&g_wsi_state[i], 0);
        atomic_init(&g_render_busy[i], 0);
        atomic_init(&g_transfer_busy[i], 0);
        atomic_init(&g_ring.ready_idx[i], -1);
        atomic_init(&g_ring.local_read[i], -1);
        for (int f = 0; f < 10; f++) {
            g_ring.active_ring_slots[i][f] = -1;
        }
    }
}

/* ── Lifecycle */

EXPORT int vx_core_is_running(void) {
    return L_R(g_engine.mailbox.is_running);
}

EXPORT void vx_core_shutdown(void) {
    S(g_engine.mailbox.is_running, 0);
}

EXPORT void vx_core_mark_finished(void) {
    S(g_engine.mailbox.lua_finished, 1);
}

/* ── Diagnostic */

EXPORT void vx_sys_dump_ring_state(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return;

    uint32_t mask   = L_R(g_ring.locked_mask);
    int      ready  = L_R(g_ring.ready_idx[win_id]);
    int      local  = L_R(g_ring.local_read[win_id]);
    int      wsi    = L_R(g_wsi_state[win_id]);
    int      offset = win_id * 4;
    uint32_t tenant_mask = (mask >> offset) & 0xF;

    printf("\n--- FREEZE AUTOPSY (Tenant %d) ---\n", win_id);
    printf("WSI State  : %d\n", wsi);
    printf("Ready Idx  : %d\n", ready);
    printf("Local Read : %d\n", local);
    printf("Slot Locks : [ %d | %d | %d | %d ]\n",
           (tenant_mask & 1) != 0, (tenant_mask & 2) != 0,
           (tenant_mask & 4) != 0, (tenant_mask & 8) != 0);
    printf("----------------------------------\n");
    fflush(stdout);
}

/* ── Render Ring Stream API */

EXPORT RenderPacket* vx_stream_packet(int idx) {
    if (idx < 0 || idx >= RING_SIZE) {
        printf("[FATAL] -1 index requests");
        return NULL;
    }
    return &g_ring.packets[idx];
}

EXPORT int vx_stream_acquire(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return -1;

    int ready  = L(g_ring.ready_idx[win_id]);
    int offset = win_id * 4;

    for (int i = 1; i <= 4; i++) {
        int local_curr = (ready == -1) ? -1 : (ready - offset);
        int next_local = (local_curr + i) % 4;
        int global_idx = offset + next_local;
        uint32_t bit   = (1u << global_idx);

        // Fresh read of the volatile state per slot attempt
        uint32_t expected = L(g_ring.locked_mask);

        // Loop purely to secure THIS specific slot
        while ((expected & bit) == 0) {
            if (CWX(g_ring.locked_mask, expected, expected | bit)) {
                return global_idx; // Secured.
            }
            // If CWX fails, 'expected' is automatically updated with the latest mask.
            // The while-condition immediately re-evaluates if our target bit is still free.
        }
    }
    return -1;
}

EXPORT void vx_stream_commit(int win_id, int idx) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return;
    atomic_thread_fence(memory_order_release);
    S(g_ring.ready_idx[win_id], idx);
}

EXPORT void vx_stream_init(int win_id, RenderThreadInit* wsi) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return;

    S(g_wsi_state[win_id], 0);
    int timeout = 2000;

    // Update this loop to wait on BOTH threads
    while (L(g_render_busy[win_id]) || L(g_transfer_busy[win_id])) {
        SLEEP_MS(1);
        timeout--;
        if (timeout <= 0) {
            printf("[C-FATAL] Threads failed to release busy flags "
                   "for Tenant %d. Aborting init to prevent corruption.\n", win_id);
            return;
        }
    }

    g_window_wsi[win_id] = *wsi;

    int      offset      = win_id * 4;
    uint32_t tenant_mask = 0xFu << offset;
    FA(g_ring.locked_mask, ~tenant_mask);

    S(g_ring.ready_idx[win_id],  -1);
    S(g_ring.local_read[win_id], -1);

    for (int f = 0; f < 10; f++) {
        g_ring.active_ring_slots[win_id][f] = -1;
    }

    S(g_wsi_state[win_id], 1);
}
