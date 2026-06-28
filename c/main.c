#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <immintrin.h>
#include <stdalign.h>

#undef LOAD
#undef STORE
#define L_R(v) atomic_load_explicit(&(v), memory_order_relaxed)
#define L(v) atomic_load_explicit(&(v), memory_order_acquire)
#define S_R(v, x) atomic_store_explicit(&(v), (x), memory_order_relaxed)
#define S(v, x) atomic_store_explicit(&(v), (x), memory_order_release)
#define E_R(v, x) atomic_exchange_explicit(&(v), (x), memory_order_relaxed)
#define E_A(v, x) atomic_exchange_explicit(&(v), (x), memory_order_acquire)
#define FO(v, x) atomic_fetch_or_explicit(&(v), (x), memory_order_release)
#define FA(v, x) atomic_fetch_and_explicit(&(v), (x), memory_order_release)
#define CWX(v, e, d) atomic_compare_exchange_weak_explicit(&(v), &(e), (d), memory_order_release, memory_order_relaxed)
#define CXS(v, e, d) atomic_compare_exchange_strong_explicit(&(v), &(e), (d), memory_order_acquire, memory_order_relaxed)
#define TAS(v) atomic_flag_test_and_set_explicit(&(v), memory_order_acquire)
#define CLR(v) atomic_flag_clear_explicit(&(v), memory_order_release)

#define GLFW_INCLUDE_VULKAN
#include <GLFW/glfw3.h>

#define VX_ENABLE_VULKAN_STRUCTS
#include "shared_structs.h"

#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#if defined(_WIN32)
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((visibility("default")))
#endif

#include <pthread.h>
#include <unistd.h>

#define SLEEP_MS(ms) usleep((ms) * 1000)

typedef pthread_t vmath_thread_t;
#define THREAD_FUNC void*
#define THREAD_RETURN_VAL NULL

#if defined(_WIN32) || defined(_WIN64)
#include <windows.h>
#include <timeapi.h>
#pragma comment(lib, "winmm.lib")
#endif

#define CMD_IDLE 0
#define CMD_BOOT_WINDOW 1
#define CMD_KILL_WINDOW 2
#define CMD_REBUILD_WSI 3

#define MAX_WINDOWS 4
#define RING_SIZE 16          // EXPANDED: 16 total slots
#define TRANSFER_RING_SIZE 16 // EXPANDED: 16 total slots

// 1. Array of Structures (AoS) Tenant Layout
typedef struct {
    _Atomic(void*) vk_instance;
    _Atomic(void*) vk_surface;
    _Atomic int glfw_cmd;
    _Atomic int glfw_arg_w;
    _Atomic int glfw_arg_h;
    _Atomic int last_key_pressed;
    _Atomic uint32_t wasd_mask;
    _Atomic float mouse_dx;
    _Atomic float mouse_dy;
    _Atomic float mouse_x;
    _Atomic float mouse_y;
    _Atomic int mouse_captured;
    _Atomic int window_resized;
    _Atomic int win_w;
    _Atomic int win_h;
    _Atomic float click_x;
    _Atomic float click_y;
    _Atomic int mouse_left;
    _Atomic int mouse_right;
    _Atomic int key_space;
    uint8_t _pad[40]; // Pads struct to exactly 128 bytes (2 cache lines)
} TenantMailbox;

_Static_assert(sizeof(TenantMailbox) == 128, "TenantMailbox must prevent false sharing");

typedef struct {
    alignas(64) _Atomic int ready_index;
    _Atomic int is_running;
    _Atomic int lua_finished;
    _Atomic int active_window;
    alignas(64) TenantMailbox tenants[MAX_WINDOWS]; // Isolated memory per window
} IPC_Mailbox;

typedef struct {
    IPC_Mailbox mailbox;
    int render_index;
    int write_index;
} EngineState;

typedef struct {
    alignas(64) RenderPacket packets[RING_SIZE];
    alignas(64) _Atomic int ready_idx[MAX_WINDOWS];
    alignas(64) _Atomic int local_read[MAX_WINDOWS];
    alignas(64) int active_ring_slots[MAX_WINDOWS][10]; // NEW: PROMOTED FROM LOCAL
    alignas(64) _Atomic uint32_t locked_mask;
} RenderRing;

typedef struct {
    uint64_t src_buffer;
    uint64_t dst_buffer;
    uint64_t size;
    uint64_t timeline_sem;
    uint64_t signal_val;
    int target_window_id;
    uint32_t _pad;
    alignas(64) _Atomic int status;
} TransferJob;

static bool s_is_fullscreen[MAX_WINDOWS] = {false};
static int s_win_x[MAX_WINDOWS] = {0}, s_win_y[MAX_WINDOWS] = {0};
static int s_win_w[MAX_WINDOWS] = {1280}, s_win_h[MAX_WINDOWS] = {720};

static EngineState g_engine;
double last_mx[MAX_WINDOWS] = {0.0};
double last_my[MAX_WINDOWS] = {0.0};
bool first_mouse[MAX_WINDOWS] = {true, true, true, true};
static atomic_flag s_mouse_lock = ATOMIC_FLAG_INIT;
VkDebugUtilsMessengerEXT g_debugMessenger = VK_NULL_HANDLE;

// FIX INJECTED: Initialize all pointers and caches
static RenderRing g_ring = {
    .ready_idx = {-1, -1, -1, -1},
    .local_read = {-1, -1, -1, -1},
    .active_ring_slots = {
        {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
        {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
        {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
        {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1}
    },
    .locked_mask = 0
};

static RenderThreadInit g_window_wsi[MAX_WINDOWS];
static atomic_int g_wsi_state[MAX_WINDOWS] = {0, 0, 0, 0};
static atomic_int g_render_busy[MAX_WINDOWS] = {0, 0, 0, 0};
static vmath_thread_t g_render_thread;
static atomic_int g_render_thread_active = 0;
static TransferJob g_transfer_ring[TRANSFER_RING_SIZE];
static uint32_t g_transfer_family_idx = 0;
static vmath_thread_t g_transfer_thread;
static atomic_int g_transfer_thread_active = 0;
static VkCommandPool g_render_cmd_pools[MAX_WINDOWS] = {VK_NULL_HANDLE};
static VkCommandPool g_transfer_cmd_pools[MAX_WINDOWS] = {VK_NULL_HANDLE};
static VkCommandBuffer g_render_cmd_buffers[MAX_WINDOWS][3];
static VkCommandBuffer g_transfer_cmd_buffers[MAX_WINDOWS];
static VkFence g_transfer_fences[MAX_WINDOWS] = {VK_NULL_HANDLE};

static vmath_thread_t vmath_thread_start(void* (*func)(void*), void* arg) {
    pthread_t thread;
    pthread_create(&thread, NULL, func, arg);
    return thread;
}

static void vmath_thread_join(vmath_thread_t thread) {
    pthread_join(thread, NULL);
}

EXPORT int vx_core_is_running() {
    return L_R(g_engine.mailbox.is_running);
}

EXPORT void vx_core_shutdown() {
    S(g_engine.mailbox.is_running, 0);
}

EXPORT void vx_core_mark_finished() {
    S(g_engine.mailbox.lua_finished, 1);
}

EXPORT const char** vx_sys_glfw_extensions(uint32_t* count) {
    return glfwGetRequiredInstanceExtensions(count);
}

EXPORT void vx_sys_publish_instance(int win_id, void* instance) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return;
    // FIXED: Routed through the 'tenants' array
    S(g_engine.mailbox.tenants[win_id].vk_instance, instance);
}

EXPORT void* vx_sys_get_surface(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return NULL;
    // FIXED: Routed through the 'tenants' array
    return L(g_engine.mailbox.tenants[win_id].vk_surface);
}

EXPORT void vx_sys_set_cmd(int win_id, int cmd, int w, int h) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return;
    // FIXED: Routed through the 'tenants' array
    S_R(g_engine.mailbox.tenants[win_id].glfw_arg_w, w);
    S_R(g_engine.mailbox.tenants[win_id].glfw_arg_h, h);
    S(g_engine.mailbox.tenants[win_id].glfw_cmd, cmd);
}

EXPORT void vx_sys_window_size(int win_id, int* w, int* h) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) {
        *w = 0; *h = 0;
        return;
    }
    // FIXED: Routed through the 'tenants' array
    *w = L(g_engine.mailbox.tenants[win_id].win_w);
    *h = L(g_engine.mailbox.tenants[win_id].win_h);
}

// 2. Update Initialization
void vx_init_mailbox() {
    atomic_init(&g_engine.mailbox.ready_index, 0);
    atomic_init(&g_engine.mailbox.is_running, 1);
    atomic_init(&g_engine.mailbox.lua_finished, 0);
    atomic_init(&g_engine.mailbox.active_window, 0);
    for (int i = 0; i < MAX_WINDOWS; i++) {
        atomic_init(&g_engine.mailbox.tenants[i].vk_instance, NULL);
        atomic_init(&g_engine.mailbox.tenants[i].vk_surface, NULL);
        atomic_init(&g_engine.mailbox.tenants[i].glfw_cmd, CMD_IDLE);
        atomic_init(&g_engine.mailbox.tenants[i].glfw_arg_w, 0);
        atomic_init(&g_engine.mailbox.tenants[i].glfw_arg_h, 0);
        atomic_init(&g_engine.mailbox.tenants[i].last_key_pressed, 0);
        atomic_init(&g_engine.mailbox.tenants[i].wasd_mask, 0);
        atomic_init(&g_engine.mailbox.tenants[i].mouse_dx, 0.0f);
        atomic_init(&g_engine.mailbox.tenants[i].mouse_dy, 0.0f);
        atomic_init(&g_engine.mailbox.tenants[i].mouse_x, 0.0f);
        atomic_init(&g_engine.mailbox.tenants[i].mouse_y, 0.0f);
        atomic_init(&g_engine.mailbox.tenants[i].click_x, -1.0f);
        atomic_init(&g_engine.mailbox.tenants[i].click_y, -1.0f);
        atomic_init(&g_engine.mailbox.tenants[i].mouse_left, 0);
        atomic_init(&g_engine.mailbox.tenants[i].mouse_right, 0);
        atomic_init(&g_engine.mailbox.tenants[i].mouse_captured, 0);
        atomic_init(&g_engine.mailbox.tenants[i].window_resized, 0);
        atomic_init(&g_engine.mailbox.tenants[i].win_w, 1280);
        atomic_init(&g_engine.mailbox.tenants[i].win_h, 720);
        atomic_init(&g_engine.mailbox.tenants[i].key_space, 0);
    }
}

EXPORT int vx_input_last_key(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return 0;
    return E_A(g_engine.mailbox.tenants[win_id].last_key_pressed, 0);
}

EXPORT int vx_input_get_active_window() {
    // active_window remains global across all tenants
    return L(g_engine.mailbox.active_window);
}

void glfw_cursor_callback(GLFWwindow* window, double xpos, double ypos) {
    int id = (int)(intptr_t)glfwGetWindowUserPointer(window);
    if (id < 0 || id >= MAX_WINDOWS) return;

    S(g_engine.mailbox.tenants[id].mouse_x, (float)xpos);
    S(g_engine.mailbox.tenants[id].mouse_y, (float)ypos);

    if (first_mouse[id]) {
        last_mx[id] = xpos;
        last_my[id] = ypos;
        first_mouse[id] = false;
    }

    float dx = (float)(xpos - last_mx[id]);
    float dy = (float)(ypos - last_my[id]);
    last_mx[id] = xpos;
    last_my[id] = ypos;

    while (TAS(s_mouse_lock)) { _mm_pause(); }
    float current_dx = L_R(g_engine.mailbox.tenants[id].mouse_dx);
    S_R(g_engine.mailbox.tenants[id].mouse_dx, current_dx + dx);
    float current_dy = L_R(g_engine.mailbox.tenants[id].mouse_dy);
    S_R(g_engine.mailbox.tenants[id].mouse_dy, current_dy + dy);
    CLR(s_mouse_lock);
}

void glfw_mouse_button_callback(GLFWwindow* window, int button, int action, int mods) {
    int id = (int)(intptr_t)glfwGetWindowUserPointer(window);
    if (id < 0 || id >= MAX_WINDOWS) return;

    if (action == GLFW_PRESS) {
        S(g_engine.mailbox.active_window, id);
    }

    if (button == GLFW_MOUSE_BUTTON_LEFT) {
        if (action == GLFW_PRESS) {
            double cx, cy;
            glfwGetCursorPos(window, &cx, &cy);
            S(g_engine.mailbox.tenants[id].click_x, (float)cx);
            S(g_engine.mailbox.tenants[id].click_y, (float)cy);
            S(g_engine.mailbox.tenants[id].mouse_left, 1);
        } else {
            S(g_engine.mailbox.tenants[id].mouse_left, 0);
        }
    } else if (button == GLFW_MOUSE_BUTTON_RIGHT) {
        S(g_engine.mailbox.tenants[id].mouse_right, (action == GLFW_PRESS) ? 1 : 0);
    }
}

EXPORT int vx_input_mouse_btn(int win_id, int btn) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return 0;
    if (btn == 0) return L(g_engine.mailbox.tenants[win_id].mouse_left);
    if (btn == 1) return L(g_engine.mailbox.tenants[win_id].mouse_right);
    return 0;
}

EXPORT float vx_input_mouse_x(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return 0.0f;
    return L(g_engine.mailbox.tenants[win_id].mouse_x);
}

EXPORT float vx_input_mouse_y(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return 0.0f;
    return L(g_engine.mailbox.tenants[win_id].mouse_y);
}

EXPORT float vx_input_click_x(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return -1.0f;
    return L(g_engine.mailbox.tenants[win_id].click_x);
}

EXPORT float vx_input_click_y(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return -1.0f;
    return L(g_engine.mailbox.tenants[win_id].click_y);
}

EXPORT int vx_input_is_captured(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return 0;
    return L(g_engine.mailbox.tenants[win_id].mouse_captured);
}

void glfw_key_callback(GLFWwindow* window, int key, int scancode, int action, int mods) {
    int id = (int)(intptr_t)glfwGetWindowUserPointer(window);
    if (id < 0 || id >= MAX_WINDOWS) return;

    S(g_engine.mailbox.active_window, id);

    if (action == GLFW_PRESS || action == GLFW_RELEASE) {
        uint32_t bit = 0;
        if (key == GLFW_KEY_W) bit = 1;
        else if (key == GLFW_KEY_S) bit = 2;
        else if (key == GLFW_KEY_A) bit = 4;
        else if (key == GLFW_KEY_D) bit = 8;
        else if (key == GLFW_KEY_E) bit = 16;
        else if (key == GLFW_KEY_Q) bit = 32;

        if (bit) {
            uint32_t mask = L(g_engine.mailbox.tenants[id].wasd_mask);
            uint32_t new_mask;
            do {
                new_mask = (action == GLFW_PRESS) ? (mask | bit) : (mask & ~bit);
            } while(!CWX(g_engine.mailbox.tenants[id].wasd_mask, mask, new_mask));
        }
    }

    if (key == GLFW_KEY_ESCAPE && action == GLFW_PRESS) {
        S(g_engine.mailbox.tenants[id].last_key_pressed, GLFW_KEY_ESCAPE);
    }

    if (key == GLFW_KEY_SPACE) {
        S(g_engine.mailbox.tenants[id].key_space, (action != GLFW_RELEASE) ? 1 : 0);
    }

    if (key == GLFW_KEY_F11 && action == GLFW_PRESS) {
        if (!s_is_fullscreen[id]) {
            glfwGetWindowPos(window, &s_win_x[id], &s_win_y[id]);
            glfwGetWindowSize(window, &s_win_w[id], &s_win_h[id]);
            GLFWmonitor* monitor = glfwGetPrimaryMonitor();
            const GLFWvidmode* mode = glfwGetVideoMode(monitor);
            glfwSetWindowMonitor(window, monitor, 0, 0, mode->width, mode->height, mode->refreshRate);
            s_is_fullscreen[id] = true;
            printf("[C-CORE] Tenant %d: Native Fullscreen Engaged (%dx%d @ %dHz)\n", id, mode->width, mode->height, mode->refreshRate);
        } else {
            glfwSetWindowMonitor(window, NULL, s_win_x[id], s_win_y[id], s_win_w[id], s_win_h[id], 0);
            s_is_fullscreen[id] = false;
            printf("[C-CORE] Tenant %d: Windowed Mode Restored\n", id);
        }
    }

    if (key == GLFW_KEY_F10 && action == GLFW_PRESS) {
        int is_cap = L(g_engine.mailbox.tenants[id].mouse_captured);
        is_cap = !is_cap;
        S(g_engine.mailbox.tenants[id].mouse_captured, is_cap);
        if (is_cap) {
            glfwSetInputMode(window, GLFW_CURSOR, GLFW_CURSOR_CAPTURED);
            printf("[C-CORE] Tenant %d: Mouse Clamped to Window (F10)\n", id);
        } else {
            glfwSetInputMode(window, GLFW_CURSOR, GLFW_CURSOR_NORMAL);
            printf("[C-CORE] Tenant %d: Mouse Freed (F10)\n", id);
        }
    }

    if (action == GLFW_PRESS) {
        if (key == GLFW_KEY_1 || key == GLFW_KEY_2 || key == GLFW_KEY_3 || key == GLFW_KEY_4 || key == GLFW_KEY_F5 || key == GLFW_KEY_ENTER || key == GLFW_KEY_KP_ENTER) {
            S(g_engine.mailbox.tenants[id].last_key_pressed, key);
        }
    }
}

EXPORT uint32_t vx_input_wasd(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return 0;
    return L(g_engine.mailbox.tenants[win_id].wasd_mask);
}

EXPORT float vx_input_mouse_dx(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return 0.0f;
    while (TAS(s_mouse_lock)) { _mm_pause(); }
    float val = E_R(g_engine.mailbox.tenants[win_id].mouse_dx, 0.0f);
    CLR(s_mouse_lock);
    return val;
}

EXPORT float vx_input_mouse_dy(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return 0.0f;
    while (TAS(s_mouse_lock)) { _mm_pause(); }
    float val = E_R(g_engine.mailbox.tenants[win_id].mouse_dy, 0.0f);
    CLR(s_mouse_lock);
    return val;
}

EXPORT int vx_input_spacebar(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return 0;
    return L(g_engine.mailbox.tenants[win_id].key_space);
}
// PROPER NEW ADDITION
EXPORT int vx_sys_get_resize_state(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return 0;
    return atomic_load_explicit(&g_engine.mailbox.tenants[win_id].window_resized, memory_order_acquire);
}

void glfw_framebuffer_size_callback(GLFWwindow* window, int width, int height) {
    if (width == 0 || height == 0) return;
    int id = (int)(intptr_t)glfwGetWindowUserPointer(window);
    if (id < 0 || id >= MAX_WINDOWS) return;

    // FIXED: Routed through the 'tenants' array
    S(g_engine.mailbox.tenants[id].win_w, width);
    S(g_engine.mailbox.tenants[id].win_h, height);
    S(g_engine.mailbox.tenants[id].window_resized, 1);
}

static VKAPI_ATTR VkBool32 VKAPI_CALL vulkan_debug_callback(
    VkDebugUtilsMessageSeverityFlagBitsEXT messageSeverity,
    VkDebugUtilsMessageTypeFlagsEXT messageType,
    const VkDebugUtilsMessengerCallbackDataEXT* pCallbackData,
    void* pUserData) {
    if (messageSeverity < VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) {
        return VK_FALSE;
    }
    printf("\n[VULKAN LAYER ENFORCER]\nSEVERITY: %d\nMESSAGE: %s\n\n", messageSeverity, pCallbackData->pMessage);
    fflush(stdout);
    return VK_FALSE;
}

EXPORT void vx_sys_inject_validation(void* instance_ptr) {
    VkInstance instance = (VkInstance)instance_ptr;
    VkDebugUtilsMessengerCreateInfoEXT createInfo = {0};
    createInfo.sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT;
    createInfo.messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
    createInfo.messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
    createInfo.pfnUserCallback = vulkan_debug_callback;
    PFN_vkCreateDebugUtilsMessengerEXT func = (PFN_vkCreateDebugUtilsMessengerEXT) glfwGetInstanceProcAddress(instance, "vkCreateDebugUtilsMessengerEXT");
    if (func != NULL) {
        func(instance, &createInfo, NULL, &g_debugMessenger);
        printf("[C-CORE] Validation Layer Enforcer Injected Successfully!\n");
    } else {
        printf("[C-FATAL] Failed to setup debug messenger (VK_EXT_debug_utils not found).\n");
    }
}

EXPORT void vx_sys_eject_validation(void* instance) {
    PFN_vkDestroyDebugUtilsMessengerEXT destroyFn = (PFN_vkDestroyDebugUtilsMessengerEXT)vkGetInstanceProcAddr(
        (VkInstance)instance, "vkDestroyDebugUtilsMessengerEXT"
    );
    if (destroyFn != NULL) {
        destroyFn((VkInstance)instance, g_debugMessenger, NULL);
    }
}

EXPORT void vx_stream_init(int win_id, RenderThreadInit* wsi) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return;
    S(g_wsi_state[win_id], 0);

    int timeout = 2000;
    while (L(g_render_busy[win_id])) {
        SLEEP_MS(1);
        timeout--;
        if (timeout <= 0) {
            printf("[C-FATAL] Render thread failed to release busy flag for Tenant %d. Force overriding.\n", win_id);
            break;
        }
    }

    g_window_wsi[win_id] = *wsi;

    // --- CRITICAL FIX: Reset Ring Buffer State for Resumed Tenant ---
    int offset = win_id * 4;
    uint32_t tenant_mask = 0xFu << offset;

    // 1. Force-unlock all 4 slots for this tenant to prevent deadlock
    FA(g_ring.locked_mask, ~tenant_mask);

    // 2. Reset write pointer so Lua's vx_stream_acquire starts fresh
    S(g_ring.ready_idx[win_id], -1);

    // 3. Reset read pointer so C-Core doesn't process stale pre-resize packets
    S(g_ring.local_read[win_id], -1);

    // 4. Wipe the global active slot cache for this tenant
    for (int f = 0; f < 10; f++) {
        g_ring.active_ring_slots[win_id][f] = -1;
    }

    S(g_wsi_state[win_id], 1);
}

EXPORT void vx_stream_allocate_tenant(int wid, RenderThreadInit* wsi, uint32_t gfx_family, uint32_t transfer_family) {
    // FIX INJECTED: Aggressive absolute bounds checking pre-evaluation
    if (wid < 0 || wid >= MAX_WINDOWS) {
        printf("[C-ERROR] Blocked out-of-bounds tenant allocation: %d\n", wid);
        return;
    }
    if (!wsi || !wsi->device) {
        printf("[C-ERROR] Failed to allocate tenant %d: Invalid WSI or Device.\n", wid);
        return;
    }

    if (g_render_cmd_pools[wid] == VK_NULL_HANDLE) {
        VkCommandPoolCreateInfo r_pool_info = {
            .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = gfx_family
        };
        vkCreateCommandPool(wsi->device, &r_pool_info, NULL, &g_render_cmd_pools[wid]);

        VkCommandBufferAllocateInfo r_alloc_info = {
            .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = g_render_cmd_pools[wid],
            .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 3
        };
        vkAllocateCommandBuffers(wsi->device, &r_alloc_info, g_render_cmd_buffers[wid]);
        printf("[C-CORE] Tenant %d: Render pool and 3x command buffers explicitly allocated.\n", wid);
    }

    if (g_transfer_cmd_pools[wid] == VK_NULL_HANDLE) {
        VkCommandPoolCreateInfo t_pool_info = {
            .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = transfer_family
        };
        vkCreateCommandPool(wsi->device, &t_pool_info, NULL, &g_transfer_cmd_pools[wid]);

        VkCommandBufferAllocateInfo t_alloc_info = {
            .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = g_transfer_cmd_pools[wid],
            .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1
        };
        vkAllocateCommandBuffers(wsi->device, &t_alloc_info, &g_transfer_cmd_buffers[wid]);

        VkFenceCreateInfo fence_info = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, .flags = 1 };
        vkCreateFence(wsi->device, &fence_info, NULL, &g_transfer_fences[wid]);
        printf("[C-CORE] Tenant %d: Transfer pool, buffer, and fence explicitly allocated.\n", wid);
    }
}

EXPORT void vx_transfer_setup(uint32_t q_family_index) {
    g_transfer_family_idx = q_family_index;
    for(int i = 0; i < TRANSFER_RING_SIZE; i++) {
        atomic_init(&g_transfer_ring[i].status, 0);
    }
}

// UPDATED SIGNATURE: Now requires win_id
EXPORT int vx_transfer_request(int win_id, uint64_t src, uint64_t dst, uint64_t size, uint64_t t_sem, uint64_t sig_val) {
    // Zero-Trust Multiplexing Bounds Guard
    if (win_id < 0 || win_id >= MAX_WINDOWS) return 0;

    for(int i = 0; i < TRANSFER_RING_SIZE; i++) {
        int expected = 0;
        if (CXS(g_transfer_ring[i].status, expected, 1)) {
            g_transfer_ring[i].src_buffer = src;
            g_transfer_ring[i].dst_buffer = dst;
            g_transfer_ring[i].size = size;
            g_transfer_ring[i].timeline_sem = t_sem;
            g_transfer_ring[i].signal_val = sig_val;
            g_transfer_ring[i].target_window_id = win_id; // Bind the tenant!
            S(g_transfer_ring[i].status, 2);
            return 1;
        }
    }
    return 0;
}

THREAD_FUNC transfer_thread_loop(void* arg) {
    printf("[C-CORE] Async Transfer Overlord Online.\n");
    while (L(g_transfer_thread_active) && L(g_engine.mailbox.is_running)) {
        bool worked = false;
        for(int i = 0; i < TRANSFER_RING_SIZE; i++) {
            if (L(g_transfer_ring[i].status) == 2) {
                TransferJob* job = &g_transfer_ring[i];
                int wid = job->target_window_id;

                // FIX INJECTED: Transfer Loop Bound Guarding
                if (wid < 0 || wid >= MAX_WINDOWS || L(g_wsi_state[wid]) == 0) {
                    S(job->status, 0);
                    continue;
                }

                RenderThreadInit* wsi = &g_window_wsi[wid];
                if (!wsi->device || g_transfer_cmd_pools[wid] == VK_NULL_HANDLE) {
                    S(job->status, 0);
                    continue;
                }

                VkCommandBuffer cmd = g_transfer_cmd_buffers[wid];
                VkFence fence = g_transfer_fences[wid];
                PFN_vkWaitForFences pfnWait = (PFN_vkWaitForFences)wsi->vkWaitForFences;
                PFN_vkResetFences pfnReset = (PFN_vkResetFences)wsi->vkResetFences;
                PFN_vkQueueSubmit pfnSubmit = (PFN_vkQueueSubmit)wsi->vkQueueSubmit;

                VkResult res = pfnWait(wsi->device, 1, &fence, VK_TRUE, 2000000000);
                if (res == VK_TIMEOUT) {
                    printf("[C-FATAL] Tenant %d: GPU Transfer Hang detected!\n", wid);
                    S(job->status, 0);
                    break;
                }

                pfnReset(wsi->device, 1, &fence);
                vkResetCommandBuffer(cmd, 0);

                VkCommandBufferBeginInfo beginInfo = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
                vkBeginCommandBuffer(cmd, &beginInfo);

                VkBufferCopy copyRegion = { .srcOffset = 0, .dstOffset = 0, .size = job->size };
                vkCmdCopyBuffer(cmd, (VkBuffer)job->src_buffer, (VkBuffer)job->dst_buffer, 1, &copyRegion);
                vkEndCommandBuffer(cmd);

                // FIX INJECTED: Stack-allocated VkSemaphore mapping prevents 64-bit address aliasing segfaults
                VkSemaphore safe_timeline_semaphore = (VkSemaphore)(uintptr_t)job->timeline_sem;

                VkTimelineSemaphoreSubmitInfo timelineInfo = {
                    .sType = 1000207003, // VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO
                    .signalSemaphoreValueCount = 1,
                    .pSignalSemaphoreValues = &job->signal_val
                };

                VkSubmitInfo submitInfo = {
                    .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
                    .pNext = &timelineInfo,
                    .commandBufferCount = 1,
                    .pCommandBuffers = &cmd,
                    .signalSemaphoreCount = 1,
                    .pSignalSemaphores = &safe_timeline_semaphore // Safely mapped stack address
                };

                pfnSubmit(wsi->transfer_queue, 1, &submitInfo, fence);

                // FIX 4: Block the internal transfer thread until the DMA finishes.
                // DO NOT release the job slot back to Lua until the GPU is done reading.
                pfnWait(wsi->device, 1, &fence, VK_TRUE, 2000000000);

                S(job->status, 0);
                worked = true;
            }
        }
        if (!worked) SLEEP_MS(1);
    }
    printf("[C-CORE] Async Transfer Thread gracefully terminated.\n");
    return NULL;
}

EXPORT RenderPacket* vx_stream_packet(int idx) {
    if (idx < 0 || idx >= RING_SIZE) {
        printf("[FATAL] -1 index requests");
        return NULL;
    }
    return &g_ring.packets[idx];
}

// FIX INJECTED: Tenant-Specific Acquisition
EXPORT int vx_stream_acquire(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return -1;

    uint32_t mask = L(g_ring.locked_mask);
    int ready = L(g_ring.ready_idx[win_id]);

    // The mathematical cage: strictly bounds indexing to the tenant's 4-slot chunk
    int offset = win_id * 4;

    for (int i = 1; i <= 4; i++) {
        int local_curr = (ready == -1) ? -1 : (ready - offset);
        int next_local = (local_curr + i) % 4;
        int global_idx = offset + next_local;

        if ((mask & (1u << global_idx)) == 0) {
            FO(g_ring.locked_mask, (1u << global_idx));
            return global_idx;
        }
    }
    return -1; // Tenant's specific 4-slot ring is full
}

// FIX INJECTED: Tenant-Specific Commit
EXPORT void vx_stream_commit(int win_id, int idx) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return;
    atomic_thread_fence(memory_order_release);
    S(g_ring.ready_idx[win_id], idx);
}

EXPORT void vx_record_commands(VkCommandBuffer cmd, RenderPacket* p, DrawCommand* queue, uint32_t count, RenderThreadInit* win_wsi) {
    if (p->width == 0 || p->height == 0) {
        return;
    }

    VkCommandBufferBeginInfo beginInfo = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    vkBeginCommandBuffer(cmd, &beginInfo);

    VkImageMemoryBarrier preBarriers[2] = {0};
    preBarriers[0].sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    preBarriers[0].oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    preBarriers[0].newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    preBarriers[0].image = (VkImage)p->swapchain_image;
    preBarriers[0].subresourceRange = (VkImageSubresourceRange){VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    preBarriers[0].dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;

    preBarriers[1].sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    preBarriers[1].oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    preBarriers[1].newLayout = VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL;
    preBarriers[1].image = (VkImage)p->depth_image;
    preBarriers[1].subresourceRange = (VkImageSubresourceRange){VK_IMAGE_ASPECT_DEPTH_BIT, 0, 1, 0, 1};
    preBarriers[1].dstAccessMask = VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;

    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT, 0, 0, NULL, 0, NULL, 2, preBarriers);

    PFN_vkCmdBeginRenderingKHR pfnBegin = (PFN_vkCmdBeginRenderingKHR)win_wsi->pfnBegin;
    PFN_vkCmdEndRenderingKHR pfnEnd = (PFN_vkCmdEndRenderingKHR)win_wsi->pfnEnd;

    VkRenderingAttachmentInfoKHR colorAttachment = {0};
    colorAttachment.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO_KHR;
    colorAttachment.imageView = (VkImageView)p->swapchain_view;
    colorAttachment.imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    colorAttachment.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    colorAttachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    colorAttachment.clearValue.color.float32[0] = 0.01f;
    colorAttachment.clearValue.color.float32[1] = 0.01f;
    colorAttachment.clearValue.color.float32[2] = 0.02f;
    colorAttachment.clearValue.color.float32[3] = 1.0f;

    VkRenderingAttachmentInfoKHR depthAttachment = {
        .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO_KHR,
        .imageView = (VkImageView)p->depth_view,
        .imageLayout = VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL,
        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
        .clearValue.depthStencil = {1.0f, 0}
    };

    VkRenderingInfoKHR renderInfo = {
        .sType = VK_STRUCTURE_TYPE_RENDERING_INFO_KHR,
        .renderArea.extent = {p->width, p->height},
        .layerCount = 1,
        .colorAttachmentCount = 1,
        .pColorAttachments = &colorAttachment,
        .pDepthAttachment = &depthAttachment
    };

    pfnBegin(cmd, &renderInfo);

    VkViewport viewport = {0.0f, 0.0f, (float)p->width, (float)p->height, 0.0f, 1.0f};
    VkRect2D scissor = {{0, 0}, {p->width, p->height}};
    vkCmdSetViewport(cmd, 0, 1, &viewport);
    vkCmdSetScissor(cmd, 0, 1, &scissor);

    // FIX INJECTED: Strict Buffer Verification & Zero-Draw Guard
    if (count > 0 && p->vertex_buffer != 0 && p->index_buffer != 0) {
        VkDeviceSize offset = 0;
        VkBuffer vbo = (VkBuffer)p->vertex_buffer;
        vkCmdBindVertexBuffers(cmd, 0, 1, &vbo, &offset);

        VkBuffer ibo = (VkBuffer)p->index_buffer;
        vkCmdBindIndexBuffer(cmd, ibo, 0, VK_INDEX_TYPE_UINT32);

        PFN_vkCmdSetCullModeEXT vkCmdSetCullModeEXT = (PFN_vkCmdSetCullModeEXT)win_wsi->pfnSetCullMode;
        PFN_vkCmdSetFrontFaceEXT vkCmdSetFrontFaceEXT = (PFN_vkCmdSetFrontFaceEXT)win_wsi->pfnSetFrontFace;
        PFN_vkCmdSetPrimitiveTopologyEXT vkCmdSetPrimitiveTopologyEXT = (PFN_vkCmdSetPrimitiveTopologyEXT)win_wsi->pfnSetPrimitiveTopology;
        PFN_vkCmdSetDepthTestEnableEXT vkCmdSetDepthTestEnableEXT = (PFN_vkCmdSetDepthTestEnableEXT)win_wsi->pfnSetDepthTestEnable;
        PFN_vkCmdSetDepthWriteEnableEXT vkCmdSetDepthWriteEnableEXT = (PFN_vkCmdSetDepthWriteEnableEXT)win_wsi->pfnSetDepthWriteEnable;
        PFN_vkCmdSetDepthCompareOpEXT vkCmdSetDepthCompareOpEXT = (PFN_vkCmdSetDepthCompareOpEXT)win_wsi->pfnSetDepthCompareOp;

        uint64_t current_pipeline = 0;
        uint64_t current_descriptor = 0;

        // FIX 2: Strict bounds constraint to armor against network state spike overruns
        #define MAX_DRAW_COMMANDS 1024
        uint32_t safe_count = count > MAX_DRAW_COMMANDS ? MAX_DRAW_COMMANDS : count;

        for (uint32_t i = 0; i < safe_count; i++) {
            DrawCommand* draw = &queue[i];

            if (draw->pipeline_id != current_pipeline) {
                vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, (VkPipeline)draw->pipeline_id);
                current_pipeline = draw->pipeline_id;
            }

            if (draw->descriptor_set != current_descriptor) {
                VkDescriptorSet dset = (VkDescriptorSet)draw->descriptor_set;
                vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, (VkPipelineLayout)p->gfx_layout, 0, 1, &dset, 0, NULL);
                current_descriptor = draw->descriptor_set;
            }

            VkRect2D dyn_scissor = {
                .offset = { (int32_t)draw->scissor_x, (int32_t)draw->scissor_y },
                .extent = { (uint32_t)draw->scissor_w, (uint32_t)draw->scissor_h }
            };
            vkCmdSetScissor(cmd, 0, 1, &dyn_scissor);
            vkCmdSetCullModeEXT(cmd, draw->cull_mode);
            vkCmdSetFrontFaceEXT(cmd, draw->front_face);
            vkCmdSetPrimitiveTopologyEXT(cmd, draw->topology);
            vkCmdSetDepthTestEnableEXT(cmd, draw->depth_test);
            vkCmdSetDepthWriteEnableEXT(cmd, draw->depth_write);
            vkCmdSetDepthCompareOpEXT(cmd, draw->depth_compare_op);

            vkCmdPushConstants(
                cmd,
                (VkPipelineLayout)p->gfx_layout,
                VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                draw->pc_offset,
                draw->pc_size,
                draw->push_constants + draw->pc_offset
            );

            vkCmdDrawIndexed(cmd, draw->index_count, draw->instance_count, draw->first_index, draw->vertex_offset, draw->first_instance);
        }
    }

    pfnEnd(cmd);

    VkImageMemoryBarrier presentBarrier = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        .image = (VkImage)p->swapchain_image,
        .subresourceRange = (VkImageSubresourceRange){VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
        .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        .dstAccessMask = 0
    };

    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, NULL, 0, NULL, 1, &presentBarrier);
    vkEndCommandBuffer(cmd);
}


THREAD_FUNC render_thread_loop(void* arg) {
    printf("[C-CORE] Async Render Multiplexer Online.\n");
    uint32_t t_frame[MAX_WINDOWS] = {0};

    while (L(g_render_thread_active) && L(g_engine.mailbox.is_running)) {

        // 1. Process Window OS Commands
        for (int w = 0; w < MAX_WINDOWS; w++) {
            int cmd = atomic_load_explicit(&g_engine.mailbox.tenants[w].glfw_cmd, memory_order_acquire);

            if (cmd == CMD_REBUILD_WSI) {
                RenderThreadInit* wsi = &g_window_wsi[w];
                if (wsi->device) {
                    vkDeviceWaitIdle(wsi->device);
                }

                // Suspend the tenant stream to allow safe Lua teardown
                S(g_wsi_state[w], 0);

                atomic_store_explicit(&g_engine.mailbox.tenants[w].window_resized, 0, memory_order_release);
                atomic_store_explicit(&g_engine.mailbox.tenants[w].glfw_cmd, CMD_IDLE, memory_order_release);
            }
        }

        // 2. Iterate through all active tenants and multiplex their designated chunks
        for (int wid = 0; wid < MAX_WINDOWS; wid++) {
            int ready = L(g_ring.ready_idx[wid]);
            int local_read_val = L(g_ring.local_read[wid]); // READ GLOBAL ATOMIC

            // Skip if no new frames have been committed for this tenant
            if (ready == -1 || ready == local_read_val) {
                continue;
            }

            int offset = wid * 4;

            // Advance sequentially strictly within this tenant's 4-slot boundary
            int new_local_read;
            if (local_read_val == -1) {
                new_local_read = ready;
            } else {
                int curr_local = local_read_val - offset;
                new_local_read = offset + ((curr_local + 1) % 4);
            }

            S(g_ring.local_read[wid], new_local_read); // WRITE GLOBAL ATOMIC

            int read_idx = new_local_read;
            RenderPacket* p = &g_ring.packets[read_idx];

            // Safe-Guard: If WSI is suspended or viewport is dead, drop the packet
            if (L(g_wsi_state[wid]) == 0 || p->width == 0 || p->height == 0) {
                FA(g_ring.locked_mask, ~(1u << read_idx));
                continue;
            }

            S(g_render_busy[wid], 1);
            RenderThreadInit* win_wsi = &g_window_wsi[wid];

            // Clamp frame sync to static bounds
            uint32_t frame_slots = win_wsi->max_frames_in_flight > 0 ? win_wsi->max_frames_in_flight : 3;
            if (frame_slots > 3) frame_slots = 3;

            uint32_t current_frame = t_frame[wid] % frame_slots;
            VkCommandBuffer cmd = g_render_cmd_buffers[wid][current_frame];

            PFN_vkWaitForFences pfnWait = (PFN_vkWaitForFences)win_wsi->vkWaitForFences;
            VkResult wait_res = pfnWait(win_wsi->device, 1, &win_wsi->in_flight[current_frame], VK_TRUE, 2000000000);

            if (wait_res == VK_TIMEOUT) {
                printf("[C-FATAL] Tenant %d: GPU Hang detected!\n", wid);
                S(g_render_busy[wid], 0);
                break;
            }

            // --- USE GLOBAL CACHE INSTEAD OF LOCAL ---
            int finished_slot = g_ring.active_ring_slots[wid][current_frame];
            if (finished_slot != -1 && finished_slot != read_idx) {
                FA(g_ring.locked_mask, ~(1u << finished_slot));
            }
            g_ring.active_ring_slots[wid][current_frame] = read_idx;

            PFN_vkAcquireNextImageKHR pfnAcquire = (PFN_vkAcquireNextImageKHR)win_wsi->vkAcquireNextImageKHR;
            uint32_t img_idx;
            VkResult res = pfnAcquire(win_wsi->device, win_wsi->swapchain, 5000000, win_wsi->image_available[current_frame], VK_NULL_HANDLE, &img_idx);

            if (res == VK_TIMEOUT || res == VK_NOT_READY) {
                S(g_render_busy[wid], 0);
                continue;
            }

            if (res == VK_ERROR_OUT_OF_DATE_KHR) {
                S(g_engine.mailbox.tenants[wid].window_resized, 1);
                S(g_render_busy[wid], 0);
                SLEEP_MS(10);
                continue;
            }

            PFN_vkResetFences pfnReset = (PFN_vkResetFences)win_wsi->vkResetFences;
            pfnReset(win_wsi->device, 1, &win_wsi->in_flight[current_frame]);

            p->swapchain_image = win_wsi->swapchain_images[img_idx];
            p->swapchain_view = win_wsi->swapchain_views[img_idx];

            vkResetCommandBuffer(cmd, 0);
            vx_record_commands(cmd, p, p->draw_queue, p->draw_count, win_wsi);

            VkPipelineStageFlags waitStage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
            VkSubmitInfo submitInfo = {
                .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
                .waitSemaphoreCount = 1,
                .pWaitSemaphores = &win_wsi->image_available[current_frame],
                .pWaitDstStageMask = &waitStage,
                .commandBufferCount = 1,
                .pCommandBuffers = &cmd,
                .signalSemaphoreCount = 1,
                // FIX: Sync to the CPU frame, not the GPU image index
                // .pSignalSemaphores = &win_wsi->render_finished[current_frame]
                .pSignalSemaphores = &win_wsi->render_finished[img_idx]
            };

            PFN_vkQueueSubmit pfnSubmit = (PFN_vkQueueSubmit)win_wsi->vkQueueSubmit;
            pfnSubmit(win_wsi->queue, 1, &submitInfo, win_wsi->in_flight[current_frame]);

            VkPresentInfoKHR presentInfo = {
                .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
                .waitSemaphoreCount = 1,
                // FIX: Sync to the CPU frame, not the GPU image index
                .pWaitSemaphores = &win_wsi->render_finished[img_idx],
                .swapchainCount = 1,
                .pSwapchains = &win_wsi->swapchain,
                .pImageIndices = &img_idx // (This remains img_idx, as required by presentation)
            };

            PFN_vkQueuePresentKHR pfnPresent = (PFN_vkQueuePresentKHR)win_wsi->vkQueuePresentKHR;
            pfnPresent(win_wsi->queue, &presentInfo);

            S(g_render_busy[wid], 0);
            t_frame[wid] = (current_frame + 1) % frame_slots;
        }

        // Single sleep cycle after all active tenants have been checked/processed
        SLEEP_MS(1);
    }
    printf("[C-CORE] Async Render Multiplexer gracefully terminated.\n");
    return NULL;
}

EXPORT void vx_thread_start() {
    S(g_render_thread_active, 1);
    S(g_transfer_thread_active, 1);
    g_render_thread = vmath_thread_start(render_thread_loop, NULL);
    g_transfer_thread = vmath_thread_start(transfer_thread_loop, NULL);
}

THREAD_FUNC lua_co_overlord_loop(void* arg) {
    printf("[LUA-OS-THREAD] Booting Lua VM...\n");
    lua_State* L = luaL_newstate();
    luaL_openlibs(L);
    if (luaL_dofile(L, "main.lua") != LUA_OK) {
        printf("\n[LUA FATAL ERROR] %s\n", lua_tostring(L, -1));
        vx_core_shutdown();
    }
    lua_close(L);
    printf("[LUA-OS-THREAD] VM Destroyed.\n");
    return THREAD_RETURN_VAL;
}

EXPORT void vx_thread_kill() {
    S(g_render_thread_active, 0);
    S(g_transfer_thread_active, 0);

    vmath_thread_join(g_render_thread);
    vmath_thread_join(g_transfer_thread);

    // FIX INJECTED: Iterate through the AoS array to reset all tenant read pointers
    for (int i = 0; i < MAX_WINDOWS; i++) {
        S(g_ring.ready_idx[i], -1);
    }

    S(g_ring.locked_mask, 0);

    for (int i = 0; i < MAX_WINDOWS; i++) {
        if (g_window_wsi[i].device) {
            vkDeviceWaitIdle(g_window_wsi[i].device);
        }
        if (g_render_cmd_pools[i]) {
            vkDestroyCommandPool(g_window_wsi[i].device, g_render_cmd_pools[i], NULL);
            g_render_cmd_pools[i] = VK_NULL_HANDLE;
        }
        if (g_transfer_cmd_pools[i]) {
            vkDestroyCommandPool(g_window_wsi[i].device, g_transfer_cmd_pools[i], NULL);
            g_transfer_cmd_pools[i] = VK_NULL_HANDLE;
        }
        if (g_transfer_fences[i]) {
            vkDestroyFence(g_window_wsi[i].device, g_transfer_fences[i], NULL);
            g_transfer_fences[i] = VK_NULL_HANDLE;
        }
    }
    printf("[C-CORE] Async Threads joined, Devices idled, Ring Purged, and Pools/Fences destroyed.\n");
}

int main(int argc, char** argv) {
    printf("[C-CORE] Booting Weaver Engine Host...\n");
    if (!glfwInit()) {
        printf("[C-FATAL] GLFW failed to initialize. Display Server missing?\n");
        return -1;
    }
    vx_init_mailbox();
    vmath_thread_t lua_thread = vmath_thread_start(lua_co_overlord_loop, NULL);
    GLFWwindow* windows[MAX_WINDOWS] = {NULL};

    while (vx_core_is_running()) {
        bool has_windows = false;
        for (int i = 0; i < MAX_WINDOWS; i++) {
            if (windows[i] != NULL) {
                has_windows = true;
                break;
            }
        }
        if (has_windows) glfwPollEvents();
        for (int id = 0; id < MAX_WINDOWS; id++) {

            // FIXED: Route through .tenants[id]
            int cmd = E_A(g_engine.mailbox.tenants[id].glfw_cmd, CMD_IDLE);

            if (cmd == CMD_BOOT_WINDOW && windows[id] == NULL) {
                for (int i = 0; i < MAX_WINDOWS; i++) {
                    if (L(g_wsi_state[i]) == 1) {
                        S(g_wsi_state[i], 0);
                        while (L(g_render_busy[i])) {
                            SLEEP_MS(1);
                        }
                    }
                }

                // FIXED: Route through .tenants[id]
                int w = L_R(g_engine.mailbox.tenants[id].glfw_arg_w);
                int h = L_R(g_engine.mailbox.tenants[id].glfw_arg_h);

                glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
                glfwWindowHint(GLFW_RESIZABLE, GLFW_TRUE);
                windows[id] = glfwCreateWindow(w, h, "Weaver Engine Editor", NULL, NULL);
                glfwSetWindowUserPointer(windows[id], (void*)(intptr_t)id);
                glfwSetWindowSizeLimits(windows[id], 640, 360, GLFW_DONT_CARE, GLFW_DONT_CARE);
                glfwShowWindow(windows[id]);
                glfwSetWindowAttrib(windows[id], GLFW_FLOATING, GLFW_TRUE);
                glfwFocusWindow(windows[id]);
                glfwSetWindowAttrib(windows[id], GLFW_FLOATING, GLFW_FALSE);
                glfwSetFramebufferSizeCallback(windows[id], glfw_framebuffer_size_callback);
                glfwSetKeyCallback(windows[id], glfw_key_callback);
                glfwSetCursorPosCallback(windows[id], glfw_cursor_callback);
                glfwSetMouseButtonCallback(windows[id], glfw_mouse_button_callback);

                int fb_w, fb_h;
                glfwGetFramebufferSize(windows[id], &fb_w, &fb_h);

                // FIXED: Route through .tenants[id]
                S(g_engine.mailbox.tenants[id].win_w, fb_w);
                S(g_engine.mailbox.tenants[id].win_h, fb_h);

                // FIXED: Route through .tenants[id]
                void* instance = L(g_engine.mailbox.tenants[id].vk_instance);

                if (instance != NULL) {
                    VkSurfaceKHR surface;
                    if (glfwCreateWindowSurface((VkInstance)instance, windows[id], NULL, &surface) == VK_SUCCESS) {
                        // FIXED: Route through .tenants[id]
                        S(g_engine.mailbox.tenants[id].vk_surface, (void*)surface);
                        printf("[C-CORE] Tenant %d: Window & Surface Created safely!\n", id);
                    }
                } else {
                    printf("[C-ERROR] Tenant %d missing Vulkan instance! Window surface creation aborted.\n", id);
                }
                for (int i = 0; i < MAX_WINDOWS; i++) {
                    if (windows[i] != NULL && i != id) {
                        S(g_wsi_state[i], 1);
                    }
                }
            } else if (cmd == CMD_KILL_WINDOW && windows[id] != NULL) {
                S(g_wsi_state[id], 0);

                int timeout = 2000;
                while (L(g_render_busy[id])) {
                    SLEEP_MS(1);
                    timeout--;
                    if (timeout <= 0) {
                        printf("[C-FATAL] Render thread failed to release busy flag for Tenant %d. Force overriding.\n", id);
                        break;
                    }
                }

                if (g_window_wsi[id].device) {
                    vkDeviceWaitIdle(g_window_wsi[id].device);
                    if (g_render_cmd_pools[id]) {
                        vkDestroyCommandPool(g_window_wsi[id].device, g_render_cmd_pools[id], NULL);
                        g_render_cmd_pools[id] = VK_NULL_HANDLE;
                    }
                    if (g_transfer_cmd_pools[id]) {
                        vkDestroyCommandPool(g_window_wsi[id].device, g_transfer_cmd_pools[id], NULL);
                        g_transfer_cmd_pools[id] = VK_NULL_HANDLE;
                    }
                    if (g_transfer_fences[id]) {
                        vkDestroyFence(g_window_wsi[id].device, g_transfer_fences[id], NULL);
                        g_transfer_fences[id] = VK_NULL_HANDLE;
                    }
                }
                glfwDestroyWindow(windows[id]);
                windows[id] = NULL;

                // FIXED: Route through .tenants[id]
                S(g_engine.mailbox.tenants[id].vk_surface, NULL);
                printf("[C-CORE] Tenant %d Window & Explicit Allocations Destroyed Safely.\n", id);
            }
            if (windows[id] && glfwWindowShouldClose(windows[id])) {
                // FIXED: Route through .tenants[id]
                S(g_engine.mailbox.tenants[id].last_key_pressed, GLFW_KEY_ESCAPE);
                glfwSetWindowShouldClose(windows[id], GLFW_FALSE);
            }
        }
        SLEEP_MS(1);
    }
    printf("\n[C-CORE] Shutdown triggered. Waiting for Lua VM...\n");

    // NOTE: lua_finished remains global. This is correct!
    while (L(g_engine.mailbox.lua_finished) == 0) {
        SLEEP_MS(1);
    }
    vmath_thread_join(lua_thread);
    for (int i = 0; i < MAX_WINDOWS; i++) {
        if (windows[i]) glfwDestroyWindow(windows[i]);
    }
    glfwTerminate();
    printf("[C-CORE] Clean Exit.\n");
    return 0;
}
