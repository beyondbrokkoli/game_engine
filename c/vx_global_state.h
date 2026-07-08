#pragma once

/*
   vx_global_state.h — Central repository for shared memory structures,
   ring buffer definitions, lock-free atomics, and global thread state.
   This is the shared contract between all domains.
*/

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdalign.h>

#if defined(__x86_64__) || defined(_M_X64)
#include <immintrin.h>
#endif

#undef LOAD
#undef STORE

/* ── Atomic Convenience Macros */
#define L_R(v, ...)   atomic_load_explicit(&(v), memory_order_relaxed)
#define L(v)          atomic_load_explicit(&(v), memory_order_acquire)
#define S_R(v, x)     atomic_store_explicit(&(v), (x), memory_order_relaxed)
#define S(v, x)       atomic_store_explicit(&(v), (x), memory_order_release)
#define E_R(v, x)     atomic_exchange_explicit(&(v), (x), memory_order_relaxed)
#define E_A(v, x)     atomic_exchange_explicit(&(v), (x), memory_order_acquire)
#define FO(v, x)      atomic_fetch_or_explicit(&(v), (x), memory_order_release)
#define FA(v, x)      atomic_fetch_and_explicit(&(v), (x), memory_order_release)
#define CWX(v, e, d)  atomic_compare_exchange_weak_explicit(&(v), &(e), (d), \
                          memory_order_release, memory_order_relaxed)
#define CXS(v, e, d)  atomic_compare_exchange_strong_explicit(&(v), &(e), (d), \
                          memory_order_acquire, memory_order_relaxed)
#define TAS(v)        atomic_flag_test_and_set_explicit(&(v), memory_order_acquire)
#define CLR(v)        atomic_flag_clear_explicit(&(v), memory_order_release)

/* ── Platform / Threading */
#include <pthread.h>
#include <unistd.h>
#include <sched.h> /* Required for sched_yield() */
#define SLEEP_MS(ms) usleep((ms) * 1000)

/* ── Tiered Backoff Spinlock Wait */
static inline void vx_spin_wait(int* spin_count) {
    if (*spin_count < 1000) {
        // Tier 1: Pause CPU pipeline to save power (Nanoseconds)
        _mm_pause();
    } else if (*spin_count < 2000) {
        // Tier 2: Yield to OS scheduler (Microseconds)
        #if defined(_WIN32)
            SwitchToThread();
        #else
            sched_yield();
        #endif
    } else {
        // Tier 3: Hard yield (Milliseconds)
        SLEEP_MS(1);
    }
    (*spin_count)++;
}

typedef pthread_t vmath_thread_t;
#define THREAD_FUNC        void*
#define THREAD_RETURN_VAL NULL

#if defined(_WIN32) || defined(_WIN64)
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <timeapi.h>
#pragma comment(lib, "winmm.lib")
#endif

#if defined(_WIN32)
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((visibility("default")))
#endif

/* ── Vulkan + GLFW */
#define GLFW_INCLUDE_VULKAN
#include <GLFW/glfw3.h>

#define VX_ENABLE_VULKAN_STRUCTS
#include "shared_structs.h"

/* ── Engine Constants */
#define CMD_IDLE           0
#define CMD_BOOT_WINDOW    1
#define CMD_KILL_WINDOW    2
#define CMD_REBUILD_WSI    3
#define MAX_WINDOWS        4
#define RING_SIZE          16
#define TRANSFER_RING_SIZE 16

/* ── Core Data Types */

typedef struct {
    _Atomic(void*)  vk_instance;
    _Atomic(void*)  vk_surface;
    _Atomic int     glfw_cmd;
    _Atomic int     glfw_arg_w;
    _Atomic int     glfw_arg_h;
    _Atomic int     last_key_pressed;
    _Atomic uint32_t wasd_mask;
    _Atomic float   mouse_dx;
    _Atomic float   mouse_dy;
    _Atomic float   mouse_x;
    _Atomic float   mouse_y;
    _Atomic int     mouse_captured;
    _Atomic int     window_resized;
    _Atomic int     win_w;
    _Atomic int     win_h;
    _Atomic float   click_x;
    _Atomic float   click_y;
    _Atomic int     mouse_left;
    _Atomic int     mouse_right;
    _Atomic int     key_space;
    uint8_t         _pad[40];
} TenantMailbox;

_Static_assert(sizeof(TenantMailbox) == 128,
               "TenantMailbox must prevent false sharing");

typedef struct {
    alignas(64) _Atomic int ready_index;
    _Atomic int is_running;
    _Atomic int lua_finished;
    _Atomic int active_window;
    alignas(64) TenantMailbox tenants[MAX_WINDOWS];
} IPC_Mailbox;

typedef struct {
    IPC_Mailbox mailbox;
    int render_index;
    int write_index;
} EngineState;

typedef struct {
    alignas(64) RenderPacket packets[RING_SIZE];
    alignas(64) _Atomic int  ready_idx[MAX_WINDOWS];
    alignas(64) _Atomic int  local_read[MAX_WINDOWS];
    alignas(64) int          active_ring_slots[MAX_WINDOWS][10];
    alignas(64) _Atomic uint32_t locked_mask;
} RenderRing;

typedef struct {
    uint64_t src_buffer;
    uint64_t dst_buffer;
    uint64_t size;
    uint64_t timeline_sem;
    uint64_t signal_val;
    int      target_window_id;
    uint32_t _pad;
    alignas(64) _Atomic int status;
} TransferJob;

/* ── Extern Global State */
#ifdef __cplusplus
extern "C" {
#endif

extern EngineState       g_engine;
extern RenderRing        g_ring;

// NEW: Double-Buffered Decoupled Contexts
extern VulkanDeviceContext    g_device_ctx[MAX_WINDOWS];
extern VulkanSwapchainContext g_wsi_ctx[MAX_WINDOWS][2];
extern _Atomic uint32_t       g_wsi_generation[MAX_WINDOWS];

extern atomic_int        g_wsi_state[MAX_WINDOWS];
extern atomic_int g_render_busy[MAX_WINDOWS];
extern atomic_int g_transfer_busy[MAX_WINDOWS]; // ADD THIS

extern vmath_thread_t    g_render_thread;
extern atomic_int        g_render_thread_active;

extern TransferJob       g_transfer_ring[TRANSFER_RING_SIZE];

extern vmath_thread_t    g_transfer_thread;
extern atomic_int        g_transfer_thread_active;

extern VkCommandPool     g_render_cmd_pools[MAX_WINDOWS];
extern VkCommandPool     g_transfer_cmd_pools[MAX_WINDOWS];
extern VkCommandBuffer   g_render_cmd_buffers[MAX_WINDOWS][3];
extern VkCommandBuffer   g_transfer_cmd_buffers[MAX_WINDOWS];
extern VkFence           g_transfer_fences[MAX_WINDOWS];

/* ── Global-State Function Prototypes */
vmath_thread_t  vmath_thread_start(void* (*func)(void*), void* arg);
void            vmath_thread_join(vmath_thread_t thread);

EXPORT void     vx_init_mailbox(void);
EXPORT int      vx_core_is_running(void);
EXPORT void     vx_core_shutdown(void);
EXPORT void     vx_core_mark_finished(void);
EXPORT void     vx_sys_dump_ring_state(int win_id);

EXPORT RenderPacket* vx_stream_packet(int idx);
EXPORT int           vx_stream_acquire(int win_id);
EXPORT void          vx_stream_commit(int win_id, int idx);
// UPDATED SIGNATURE:
EXPORT void          vx_stream_init(int win_id, VulkanDeviceContext* dev_ctx);

#ifdef __cplusplus
}
#endif
