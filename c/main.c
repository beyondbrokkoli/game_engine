// main.c
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdalign.h>

#define GLFW_INCLUDE_VULKAN
#include <GLFW/glfw3.h>

// Activate the Vulkan structs for the main thread
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
static vmath_thread_t vmath_thread_start(void* (*func)(void*), void* arg) {
    pthread_t thread;
    pthread_create(&thread, NULL, func, arg);
    return thread;
}

static void vmath_thread_join(vmath_thread_t thread) {
    pthread_join(thread, NULL);
}

#define CMD_IDLE 0
#define CMD_BOOT_WINDOW 1
#define CMD_KILL_WINDOW 2
#define MAX_WINDOWS 4

static bool s_is_fullscreen[MAX_WINDOWS] = {false};
static int s_win_x[MAX_WINDOWS] = {0}, s_win_y[MAX_WINDOWS] = {0};
static int s_win_w[MAX_WINDOWS] = {1280}, s_win_h[MAX_WINDOWS] = {720};

typedef struct {
    alignas(64) _Atomic int ready_index;
    _Atomic int is_running;
    _Atomic int lua_finished;
    _Atomic int active_window;

    // --- MULTI-TENANT STATE (Arrays) ---
    _Atomic(void*) vk_instance[MAX_WINDOWS];
    _Atomic(void*) vk_surface[MAX_WINDOWS];
    _Atomic int glfw_cmd[MAX_WINDOWS];
    _Atomic int glfw_arg_w[MAX_WINDOWS];
    _Atomic int glfw_arg_h[MAX_WINDOWS];
    _Atomic int last_key_pressed[MAX_WINDOWS];
    _Atomic uint32_t wasd_mask[MAX_WINDOWS];
    _Atomic float mouse_dx[MAX_WINDOWS];
    _Atomic float mouse_dy[MAX_WINDOWS];
    _Atomic float mouse_x[MAX_WINDOWS];
    _Atomic float mouse_y[MAX_WINDOWS];
    _Atomic int mouse_captured[MAX_WINDOWS];
    _Atomic int window_resized[MAX_WINDOWS];
    _Atomic int win_w[MAX_WINDOWS];
    _Atomic int win_h[MAX_WINDOWS];

    // --- PATCH: MISSING INPUT ARRAYS ---
    _Atomic float click_x[MAX_WINDOWS];
    _Atomic float click_y[MAX_WINDOWS];
    _Atomic int mouse_left[MAX_WINDOWS];
    _Atomic int mouse_right[MAX_WINDOWS];
    _Atomic int key_space[MAX_WINDOWS];
} IPC_Mailbox;

typedef struct {
    IPC_Mailbox mailbox;
    int render_index;
    int write_index;
} EngineState;

static EngineState g_engine;

EXPORT int vx_core_is_running() { return atomic_load_explicit(&g_engine.mailbox.is_running, memory_order_relaxed); }
EXPORT void vx_core_shutdown() { atomic_store_explicit(&g_engine.mailbox.is_running, 0, memory_order_release); }
EXPORT void vx_core_mark_finished() { atomic_store_explicit(&g_engine.mailbox.lua_finished, 1, memory_order_release); }
EXPORT const char** vx_sys_glfw_extensions(uint32_t* count) { return glfwGetRequiredInstanceExtensions(count); }
EXPORT void vx_sys_publish_instance(int win_id, void* instance) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return;
    atomic_store_explicit(&g_engine.mailbox.vk_instance[win_id], instance, memory_order_release);
}

EXPORT void* vx_sys_get_surface(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return NULL;
    return atomic_load_explicit(&g_engine.mailbox.vk_surface[win_id], memory_order_acquire);
}

EXPORT void vx_sys_set_cmd(int win_id, int cmd, int w, int h) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return;
    atomic_store_explicit(&g_engine.mailbox.glfw_arg_w[win_id], w, memory_order_relaxed);
    atomic_store_explicit(&g_engine.mailbox.glfw_arg_h[win_id], h, memory_order_relaxed);
    atomic_store_explicit(&g_engine.mailbox.glfw_cmd[win_id], cmd, memory_order_release);
}

EXPORT int vx_input_last_key(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return 0;
    return atomic_exchange_explicit(&g_engine.mailbox.last_key_pressed[win_id], 0, memory_order_acquire);
}

EXPORT int vx_input_get_active_window() {
    return atomic_load_explicit(&g_engine.mailbox.active_window, memory_order_acquire);
}

double last_mx[MAX_WINDOWS] = {0.0};
double last_my[MAX_WINDOWS] = {0.0};
bool first_mouse[MAX_WINDOWS] = {true, true, true, true};
static atomic_flag s_mouse_lock = ATOMIC_FLAG_INIT;

void glfw_cursor_callback(GLFWwindow* window, double xpos, double ypos) {
    int id = (int)(intptr_t)glfwGetWindowUserPointer(window);
    if (id < 0 || id >= MAX_WINDOWS) return;

    atomic_store_explicit(&g_engine.mailbox.mouse_x[id], (float)xpos, memory_order_release);
    atomic_store_explicit(&g_engine.mailbox.mouse_y[id], (float)ypos, memory_order_release);

    if (first_mouse[id]) {
        last_mx[id] = xpos;
        last_my[id] = ypos;
        first_mouse[id] = false;
    }

    float dx = (float)(xpos - last_mx[id]);
    float dy = (float)(ypos - last_my[id]);
    last_mx[id] = xpos;
    last_my[id] = ypos;

    // MULTI-TENANT SPINLOCK ACCUMULATION
    while (atomic_flag_test_and_set_explicit(&s_mouse_lock, memory_order_acquire));

    float current_dx = atomic_load_explicit(&g_engine.mailbox.mouse_dx[id], memory_order_relaxed);
    atomic_store_explicit(&g_engine.mailbox.mouse_dx[id], current_dx + dx, memory_order_relaxed);

    float current_dy = atomic_load_explicit(&g_engine.mailbox.mouse_dy[id], memory_order_relaxed);
    atomic_store_explicit(&g_engine.mailbox.mouse_dy[id], current_dy + dy, memory_order_relaxed);

    atomic_flag_clear_explicit(&s_mouse_lock, memory_order_release);
}

void glfw_mouse_button_callback(GLFWwindow* window, int button, int action, int mods) {
    int id = (int)(intptr_t)glfwGetWindowUserPointer(window);
    if (id < 0 || id >= MAX_WINDOWS) return;

    // Track the active window on any mouse interaction
    if (action == GLFW_PRESS) {
        atomic_store_explicit(&g_engine.mailbox.active_window, id, memory_order_release);
    }

    if (button == GLFW_MOUSE_BUTTON_LEFT) {
        if (action == GLFW_PRESS) {
            double cx, cy;
            glfwGetCursorPos(window, &cx, &cy); // Get exact coordinate of the event
            atomic_store_explicit(&g_engine.mailbox.click_x[id], (float)cx, memory_order_release);
            atomic_store_explicit(&g_engine.mailbox.click_y[id], (float)cy, memory_order_release);
            atomic_store_explicit(&g_engine.mailbox.mouse_left[id], 1, memory_order_release);
        } else {
            atomic_store_explicit(&g_engine.mailbox.mouse_left[id], 0, memory_order_release);
        }
    } else if (button == GLFW_MOUSE_BUTTON_RIGHT) {
        // DO NOT LOSE THIS!
        atomic_store_explicit(&g_engine.mailbox.mouse_right[id], (action == GLFW_PRESS) ? 1 : 0, memory_order_release);
    }
}

EXPORT int vx_input_mouse_btn(int win_id, int btn) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return 0;
    if (btn == 0) return atomic_load_explicit(&g_engine.mailbox.mouse_left[win_id], memory_order_acquire);
    if (btn == 1) return atomic_load_explicit(&g_engine.mailbox.mouse_right[win_id], memory_order_acquire);
    return 0;
}

EXPORT float vx_input_mouse_x(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return 0.0f;
    return atomic_load_explicit(&g_engine.mailbox.mouse_x[win_id], memory_order_acquire);
}

EXPORT float vx_input_mouse_y(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return 0.0f;
    return atomic_load_explicit(&g_engine.mailbox.mouse_y[win_id], memory_order_acquire);
}

EXPORT float vx_input_click_x(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return -1.0f;
    return atomic_load_explicit(&g_engine.mailbox.click_x[win_id], memory_order_acquire);
}

EXPORT float vx_input_click_y(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return -1.0f;
    return atomic_load_explicit(&g_engine.mailbox.click_y[win_id], memory_order_acquire);
}

EXPORT int vx_input_is_captured(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return 0;
    return atomic_load_explicit(&g_engine.mailbox.mouse_captured[win_id], memory_order_acquire);
}

void glfw_key_callback(GLFWwindow* window, int key, int scancode, int action, int mods) {
    int id = (int)(intptr_t)glfwGetWindowUserPointer(window);
    if (id < 0 || id >= MAX_WINDOWS) return;

    // Ensure this window is marked active if the user is typing in it
    atomic_store_explicit(&g_engine.mailbox.active_window, id, memory_order_release);

    if (action == GLFW_PRESS || action == GLFW_RELEASE) {
        uint32_t bit = 0;
        if (key == GLFW_KEY_W) bit = 1; else if (key == GLFW_KEY_S) bit = 2;
        else if (key == GLFW_KEY_A) bit = 4; else if (key == GLFW_KEY_D) bit = 8;
        else if (key == GLFW_KEY_E) bit = 16; else if (key == GLFW_KEY_Q) bit = 32;
        if (bit) {
            uint32_t mask = atomic_load_explicit(&g_engine.mailbox.wasd_mask[id], memory_order_acquire);
            uint32_t new_mask;
            do {
                new_mask = (action == GLFW_PRESS) ? (mask | bit) : (mask & ~bit);
            } while(!atomic_compare_exchange_weak_explicit(&g_engine.mailbox.wasd_mask[id], &mask, new_mask, memory_order_release, memory_order_relaxed));
        }
    }

    if (key == GLFW_KEY_ESCAPE && action == GLFW_PRESS) {
        // Instantly trigger shutdown
        atomic_store_explicit(&g_engine.mailbox.last_key_pressed[id], GLFW_KEY_ESCAPE, memory_order_release);
    }

    if (key == GLFW_KEY_SPACE) {
        // 1 means pressed or held, 0 means released
        atomic_store_explicit(&g_engine.mailbox.key_space[id], (action != GLFW_RELEASE) ? 1 : 0, memory_order_release);
    }

    // === F11 NATIVE FULLSCREEN TOGGLE ===
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

    // THE MOUSE RELAY TOGGLE
    if (key == GLFW_KEY_F10 && action == GLFW_PRESS) {
        int is_cap = atomic_load_explicit(&g_engine.mailbox.mouse_captured[id], memory_order_acquire);
        is_cap = !is_cap; // Flip the state
        atomic_store_explicit(&g_engine.mailbox.mouse_captured[id], is_cap, memory_order_release);

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
            atomic_store_explicit(&g_engine.mailbox.last_key_pressed[id], key, memory_order_release);
        }
    }
}

VkDebugUtilsMessengerEXT g_debugMessenger = VK_NULL_HANDLE;

static VKAPI_ATTR VkBool32 VKAPI_CALL vulkan_debug_callback(
    VkDebugUtilsMessageSeverityFlagBitsEXT messageSeverity,
    VkDebugUtilsMessageTypeFlagsEXT messageType,
    const VkDebugUtilsMessengerCallbackDataEXT* pCallbackData,
    void* pUserData) {

    if (messageSeverity < VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) {
        return VK_FALSE;
    }
    printf("\n[VULKAN LAYER ENFORCER]\nSEVERITY: %d\nMESSAGE: %s\n\n",
           messageSeverity, pCallbackData->pMessage);
    fflush(stdout);
    return VK_FALSE;
}

EXPORT void vx_sys_inject_validation(void* instance_ptr) {
    VkInstance instance = (VkInstance)instance_ptr;
    VkDebugUtilsMessengerCreateInfoEXT createInfo = {0};
    createInfo.sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT;
    createInfo.messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT |
                                 VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                                 VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
    createInfo.messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                             VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                             VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
    createInfo.pfnUserCallback = vulkan_debug_callback;

    PFN_vkCreateDebugUtilsMessengerEXT func = (PFN_vkCreateDebugUtilsMessengerEXT)
        glfwGetInstanceProcAddress(instance, "vkCreateDebugUtilsMessengerEXT");

    if (func != NULL) {
        func(instance, &createInfo, NULL, &g_debugMessenger);
        printf("[C-CORE] Validation Layer Enforcer Injected Successfully!\n");
    } else {
        printf("[C-FATAL] Failed to setup debug messenger (VK_EXT_debug_utils not found).\n");
    }
}

EXPORT void vx_sys_eject_validation(void* instance) {
    PFN_vkDestroyDebugUtilsMessengerEXT destroyFn =
        (PFN_vkDestroyDebugUtilsMessengerEXT)vkGetInstanceProcAddr(
            (VkInstance)instance,
            "vkDestroyDebugUtilsMessengerEXT"
        );

    if (destroyFn != NULL) {
        destroyFn((VkInstance)instance, g_debugMessenger, NULL);
    }
}

EXPORT uint32_t vx_input_wasd(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return 0;
    return atomic_load_explicit(&g_engine.mailbox.wasd_mask[win_id], memory_order_acquire);
}
EXPORT float vx_input_mouse_dx(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return 0.0f;

    while (atomic_flag_test_and_set_explicit(&s_mouse_lock, memory_order_acquire));
    float val = atomic_exchange_explicit(&g_engine.mailbox.mouse_dx[win_id], 0.0f, memory_order_relaxed);
    atomic_flag_clear_explicit(&s_mouse_lock, memory_order_release);

    return val;
}

EXPORT float vx_input_mouse_dy(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return 0.0f;

    while (atomic_flag_test_and_set_explicit(&s_mouse_lock, memory_order_acquire));
    float val = atomic_exchange_explicit(&g_engine.mailbox.mouse_dy[win_id], 0.0f, memory_order_relaxed);
    atomic_flag_clear_explicit(&s_mouse_lock, memory_order_release);

    return val;
}
EXPORT int vx_sys_resize_flag(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return 0;
    return atomic_exchange_explicit(&g_engine.mailbox.window_resized[win_id], 0, memory_order_acquire);
}

EXPORT void vx_sys_window_size(int win_id, int* w, int* h) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) {
        *w = 0; *h = 0;
        return;
    }
    *w = atomic_load_explicit(&g_engine.mailbox.win_w[win_id], memory_order_acquire);
    *h = atomic_load_explicit(&g_engine.mailbox.win_h[win_id], memory_order_acquire);
}

void glfw_framebuffer_size_callback(GLFWwindow* window, int width, int height) {
    if (width == 0 || height == 0) return;

    // Extract the target tenant
    int id = (int)(intptr_t)glfwGetWindowUserPointer(window);
    if (id < 0 || id >= MAX_WINDOWS) return;

    atomic_store_explicit(&g_engine.mailbox.win_w[id], width, memory_order_release);
    atomic_store_explicit(&g_engine.mailbox.win_h[id], height, memory_order_release);

    // Flag the render thread / Lua that this specific WSI needs a rebuild
    atomic_store_explicit(&g_engine.mailbox.window_resized[id], 1, memory_order_release);
}
EXPORT int vx_input_spacebar(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return 0;
    return atomic_load_explicit(&g_engine.mailbox.key_space[win_id], memory_order_acquire);
}


#define RING_SIZE 4
#define LOAD(var) atomic_load_explicit(&(var), memory_order_acquire)
#define STORE(var, val) atomic_store_explicit(&(var), (val), memory_order_release)

// FFI-CONTRACT: RenderPacket mapping
typedef struct {
    alignas(64) RenderPacket packets[RING_SIZE];
    alignas(64) _Atomic int ready_idx;
    alignas(64) _Atomic uint32_t locked_mask; // REPLACES read_idx
} RenderRing;

// INSTANTIATE WITH MASK
static RenderRing g_ring = { .ready_idx = -1, .locked_mask = 0 };

#define MAX_WINDOWS 4

static RenderThreadInit g_window_wsi[MAX_WINDOWS];
static atomic_int g_wsi_state[MAX_WINDOWS] = {0, 0, 0, 0};
static atomic_int g_render_busy[MAX_WINDOWS] = {0, 0, 0, 0};

EXPORT void vx_stream_register_window(int win_id, RenderThreadInit* wsi) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return;
    atomic_store_explicit(&g_wsi_state[win_id], 0, memory_order_release);
    while (atomic_load_explicit(&g_render_busy[win_id], memory_order_acquire)) { SLEEP_MS(1); }
    g_window_wsi[win_id] = *wsi;
    atomic_store_explicit(&g_wsi_state[win_id], 1, memory_order_release);
}

static vmath_thread_t g_render_thread;
static atomic_int g_render_thread_active = 0;

// [NEW] Global Command Pool Tracking
static VkCommandPool g_render_cmd_pool = VK_NULL_HANDLE;
static VkCommandPool g_transfer_cmd_pool = VK_NULL_HANDLE;

// DIRECTIVE ZETA: ASYNC TRANSFER OVERLORD
typedef struct {
    uint64_t src_buffer;
    uint64_t dst_buffer;
    uint64_t size;
    uint64_t timeline_sem;
    uint64_t signal_val;
    alignas(64) _Atomic int status; // 0 = FREE, 1 = PENDING, 2 = COMPLETE
} TransferJob;

#define TRANSFER_RING_SIZE 4
static TransferJob g_transfer_ring[TRANSFER_RING_SIZE];
static uint32_t g_transfer_family_idx = 0;
static vmath_thread_t g_transfer_thread;
static atomic_int g_transfer_thread_active = 0;

EXPORT void vx_transfer_setup(uint32_t q_family_index) {
    g_transfer_family_idx = q_family_index;
    for(int i = 0; i < TRANSFER_RING_SIZE; i++) {
        atomic_init(&g_transfer_ring[i].status, 0);
    }
}

EXPORT int vx_transfer_request(uint64_t src, uint64_t dst, uint64_t size, uint64_t t_sem, uint64_t sig_val) {
    for(int i = 0; i < TRANSFER_RING_SIZE; i++) {
        int expected = 0; // FREE
        if (atomic_compare_exchange_strong_explicit(&g_transfer_ring[i].status, &expected, 1, memory_order_acquire, memory_order_relaxed)) {
            g_transfer_ring[i].src_buffer = src;
            g_transfer_ring[i].dst_buffer = dst;
            g_transfer_ring[i].size = size;
            g_transfer_ring[i].timeline_sem = t_sem;
            g_transfer_ring[i].signal_val = sig_val;

            // Mark as PENDING for the transfer thread to pick up
            atomic_store_explicit(&g_transfer_ring[i].status, 2, memory_order_release);
            return 1;
        }
    }
    return 0; // Mailbox full, Lua must yield
}

THREAD_FUNC transfer_thread_loop(void* arg) {
    printf("[C-CORE] Async Transfer Overlord Online.\n");

    // [SAFETY] Wait for the primary device to be initialized before creating pools
    // Prevents a race condition if the transfer thread boots before Window 0 is created.
    while (g_window_wsi[0].device == NULL && atomic_load_explicit(&g_engine.mailbox.is_running, memory_order_acquire)) {
        SLEEP_MS(1);
    }
    if (!atomic_load_explicit(&g_engine.mailbox.is_running, memory_order_acquire)) return NULL;

    VkCommandPool cmd_pool;
    VkCommandPoolCreateInfo pool_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = g_transfer_family_idx // Strict Domain Isolation
    };
    vkCreateCommandPool(g_window_wsi[0].device, &pool_info, NULL, &g_transfer_cmd_pool);

    VkCommandBuffer cmd;
    VkCommandBufferAllocateInfo alloc_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = g_transfer_cmd_pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1
    };
    vkAllocateCommandBuffers(g_window_wsi[0].device, &alloc_info, &cmd);

    PFN_vkQueueSubmit pfnSubmit = (PFN_vkQueueSubmit)g_window_wsi[0].vkQueueSubmit;

    VkFence transfer_fence;
    VkFenceCreateInfo fence_info = {
        .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .flags = 1 // VK_FENCE_CREATE_SIGNALED_BIT
    };
    vkCreateFence(g_window_wsi[0].device, &fence_info, NULL, &transfer_fence);

    PFN_vkWaitForFences pfnWait = (PFN_vkWaitForFences)g_window_wsi[0].vkWaitForFences;
    PFN_vkResetFences pfnReset = (PFN_vkResetFences)g_window_wsi[0].vkResetFences;

    while (atomic_load_explicit(&g_transfer_thread_active, memory_order_acquire) &&
           atomic_load_explicit(&g_engine.mailbox.is_running, memory_order_acquire)) {

        bool worked = false;
        for(int i = 0; i < TRANSFER_RING_SIZE; i++) {
            if (atomic_load_explicit(&g_transfer_ring[i].status, memory_order_acquire) == 2) {
                TransferJob* job = &g_transfer_ring[i];

                pfnWait(g_window_wsi[0].device, 1, &transfer_fence, VK_TRUE, UINT64_MAX);
                pfnReset(g_window_wsi[0].device, 1, &transfer_fence);

                vkResetCommandBuffer(cmd, 0);
                VkCommandBufferBeginInfo beginInfo = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
                vkBeginCommandBuffer(cmd, &beginInfo);

                VkBufferCopy copyRegion = { .srcOffset = 0, .dstOffset = 0, .size = job->size };
                vkCmdCopyBuffer(cmd, (VkBuffer)job->src_buffer, (VkBuffer)job->dst_buffer, 1, &copyRegion);

                vkEndCommandBuffer(cmd);

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
                    .pSignalSemaphores = (VkSemaphore*)&job->timeline_sem
                };

                printf("[C-CORE] Submitting DMA Transfer. Timeline Signal Value: %llu\n", (unsigned long long)job->signal_val);
                pfnSubmit(g_window_wsi[0].transfer_queue, 1, &submitInfo, transfer_fence);

                atomic_store_explicit(&job->status, 0, memory_order_release);
                worked = true;
            }
        }
        if (!worked) SLEEP_MS(1);
    }

    vkDestroyFence(g_window_wsi[0].device, transfer_fence, NULL);
    printf("[C-CORE] Async Transfer Thread gracefully terminated.\n");
    return NULL;
}

EXPORT void vx_stream_init(int win_id, RenderThreadInit* wsi) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return;

    atomic_store_explicit(&g_wsi_state[win_id], 0, memory_order_release);
    while (atomic_load_explicit(&g_render_busy[win_id], memory_order_acquire)) {
        SLEEP_MS(1);
    }

    g_window_wsi[win_id] = *wsi;

    // [PATCH] Remove the localized ring reset block from here.
    // It is now safely centralized in vx_thread_kill().

    atomic_store_explicit(&g_wsi_state[win_id], 1, memory_order_release);
}

EXPORT RenderPacket* vx_stream_packet(int idx) {
    // [PATCH] Guard against -1 index requests from leaked locks
    if (idx < 0 || idx >= RING_SIZE) {
        printf("[FATAL] -1 index requests");
        return NULL;
    }
    return &g_ring.packets[idx];
}

EXPORT int vx_stream_acquire() {
    uint32_t mask = LOAD(g_ring.locked_mask);
    int ready = LOAD(g_ring.ready_idx);

    for (int i = 1; i <= RING_SIZE; i++) {
        int idx = (ready + i) % RING_SIZE;
        if ((mask & (1 << idx)) == 0) {
            // LUA NOW LOCKS THE SLOT IMMEDIATELY
            atomic_fetch_or_explicit(&g_ring.locked_mask, (1 << idx), memory_order_release);
            return idx;
        }
    }
    return -1;
}

EXPORT void vx_stream_commit(int idx) {
    // FORCE HARDWARE MEMORY FLUSH:
    // Guarantees all previous ffi.copy and pointer assignments from Lua
    // are visible in RAM before the C-Core is allowed to read this slot.
    atomic_thread_fence(memory_order_release);
    STORE(g_ring.ready_idx, idx);
}

EXPORT void vx_record_commands(VkCommandBuffer cmd, RenderPacket* p, DrawCommand* queue, uint32_t count, RenderThreadInit* win_wsi) {
    VkCommandBufferBeginInfo beginInfo = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    vkBeginCommandBuffer(cmd, &beginInfo);

    // 2. Setup Render Pass Barriers (Cleansed of ID Buffer logic)
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

    // Standard Fast-Path Barrier: Wait on TOP_OF_PIPE
    vkCmdPipelineBarrier(cmd,
        VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
        0, 0, NULL, 0, NULL, 2, preBarriers);

    // --- THE FIX: Cast the opaque FFI pointers to callable Vulkan function pointers ---
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

    // Now call the local function pointer!
    pfnBegin(cmd, &renderInfo);

    // 3. Global Graphics State Setup
    VkViewport viewport = {0.0f, 0.0f, (float)p->width, (float)p->height, 0.0f, 1.0f};
    VkRect2D scissor = {{0, 0}, {p->width, p->height}};
    vkCmdSetViewport(cmd, 0, 1, &viewport);
    vkCmdSetScissor(cmd, 0, 1, &scissor);

    VkDeviceSize offset = 0;
    VkBuffer vbo = (VkBuffer)p->vertex_buffer;
    vkCmdBindVertexBuffers(cmd, 0, 1, &vbo, &offset);

    // --- BIND THE INDEX BUFFER ---
    VkBuffer ibo = (VkBuffer)p->index_buffer;
    vkCmdBindIndexBuffer(cmd, ibo, 0, VK_INDEX_TYPE_UINT32);

    PFN_vkCmdSetCullModeEXT vkCmdSetCullModeEXT = (PFN_vkCmdSetCullModeEXT)win_wsi->pfnSetCullMode;
    PFN_vkCmdSetFrontFaceEXT vkCmdSetFrontFaceEXT = (PFN_vkCmdSetFrontFaceEXT)win_wsi->pfnSetFrontFace;
    PFN_vkCmdSetPrimitiveTopologyEXT vkCmdSetPrimitiveTopologyEXT = (PFN_vkCmdSetPrimitiveTopologyEXT)win_wsi->pfnSetPrimitiveTopology;
    PFN_vkCmdSetDepthTestEnableEXT vkCmdSetDepthTestEnableEXT = (PFN_vkCmdSetDepthTestEnableEXT)win_wsi->pfnSetDepthTestEnable;
    PFN_vkCmdSetDepthWriteEnableEXT vkCmdSetDepthWriteEnableEXT = (PFN_vkCmdSetDepthWriteEnableEXT)win_wsi->pfnSetDepthWriteEnable;
    PFN_vkCmdSetDepthCompareOpEXT vkCmdSetDepthCompareOpEXT = (PFN_vkCmdSetDepthCompareOpEXT)win_wsi->pfnSetDepthCompareOp;

    // 4. Data-Oriented Queue Execution
    uint64_t current_pipeline = 0;
    uint64_t current_descriptor = 0;

    for (uint32_t i = 0; i < count; i++) {
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

        VkRect2D scissor = {
            .offset = { (int32_t)draw->scissor_x, (int32_t)draw->scissor_y },
            .extent = { (uint32_t)draw->scissor_w, (uint32_t)draw->scissor_h }
        };

        vkCmdSetScissor(cmd, 0, 1, &scissor);
        vkCmdSetCullModeEXT(cmd, draw->cull_mode);
        vkCmdSetFrontFaceEXT(cmd, draw->front_face);
        vkCmdSetPrimitiveTopologyEXT(cmd, draw->topology);
        vkCmdSetDepthTestEnableEXT(cmd, draw->depth_test);
        vkCmdSetDepthWriteEnableEXT(cmd, draw->depth_write);
        vkCmdSetDepthCompareOpEXT(cmd, draw->depth_compare_op);

        vkCmdPushConstants(
            cmd, (VkPipelineLayout)p->gfx_layout,
            VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
            draw->pc_offset, draw->pc_size, draw->push_constants + draw->pc_offset
        );

        vkCmdDrawIndexed(cmd,
            draw->index_count,
            draw->instance_count,
            draw->first_index,
            draw->vertex_offset,
            draw->first_instance
        );
    }

    // Call the end function pointer!
    pfnEnd(cmd);

    // 5. Present Barrier
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

    // 1. Shared Command Pool Setup (Assuming a shared logical device)
    // We use WSI index 0's device. For true multi-device support, pool creation must be per-device.
    VkCommandPool cmd_pool;
    VkCommandPoolCreateInfo pool_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = 0
    };
    vkCreateCommandPool(g_window_wsi[0].device, &pool_info, NULL, &g_render_cmd_pool);

    // 2. AVOID THE LAZY ALLOCATION TRAP: Pre-allocate the 2D Command Buffer Array!
    VkCommandBuffer cmd_buffers[MAX_WINDOWS][3];
    uint32_t t_frame[MAX_WINDOWS] = {0};             // current_frame per tenant
    int active_ring_slots[MAX_WINDOWS][3];           // IPC tracking per tenant

    for (int wid = 0; wid < MAX_WINDOWS; wid++) {
        for (int f = 0; f < 3; f++) active_ring_slots[wid][f] = -1;

        VkCommandBufferAllocateInfo alloc_info = {
            .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = g_render_cmd_pool,
            .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 3
        };
        // Safe pre-allocation at thread boot
        vkAllocateCommandBuffers(g_window_wsi[0].device, &alloc_info, cmd_buffers[wid]);
    }

    int local_read = -1;

    while (atomic_load_explicit(&g_render_thread_active, memory_order_acquire) &&
           atomic_load_explicit(&g_engine.mailbox.is_running, memory_order_acquire)) {

        // 1. Grab the latest frame from Lua
        int ready = atomic_load_explicit(&g_ring.ready_idx, memory_order_acquire);
        if (ready == -1 || ready == local_read) {
            SLEEP_MS(1);
            continue;
        }

        local_read = ready;
        RenderPacket* p = &g_ring.packets[local_read];
        int wid = p->target_window_id; // Added to shared_structs.h Phase 1

        // 2. THE HEADLESS DROP CHECK (Crucial for deterministic networking)
        if (wid < 0 || wid >= MAX_WINDOWS || atomic_load_explicit(&g_wsi_state[wid], memory_order_acquire) == 0) {
            // Window is dead or resizing. Unlock the slot IMMEDIATELY so Lua doesn't starve!
            atomic_fetch_and_explicit(&g_ring.locked_mask, ~(1 << local_read), memory_order_release);
            continue;
        }

        // 3. ENTER VULKAN EXECUTION BLOCK (The Double-Gate Lock)
        atomic_store_explicit(&g_render_busy[wid], 1, memory_order_release);

        // Sanity check: Did Lua invalidate the window while we were locking?
        if (atomic_load_explicit(&g_wsi_state[wid], memory_order_acquire) == 0) {
            atomic_store_explicit(&g_render_busy[wid], 0, memory_order_release); // Release Seal
            atomic_fetch_and_explicit(&g_ring.locked_mask, ~(1 << local_read), memory_order_release); // Release IPC
            continue;
        }

        // --- SAFE VULKAN EXECUTION ZONE ---

        // Multiplex Pointers
        RenderThreadInit* win_wsi = &g_window_wsi[wid];
        uint32_t current_frame = t_frame[wid];
        VkCommandBuffer cmd = cmd_buffers[wid][current_frame];

        // Safely sleep on the specific tenant's GPU Fence
        PFN_vkWaitForFences pfnWait = (PFN_vkWaitForFences)win_wsi->vkWaitForFences;
        pfnWait(win_wsi->device, 1, &win_wsi->in_flight[current_frame], VK_TRUE, UINT64_MAX);

        // IPC Unlock: GPU finished the oldest frame for THIS window
        int finished_slot = active_ring_slots[wid][current_frame];
        if (finished_slot != -1 && finished_slot != local_read) {
            atomic_fetch_and_explicit(&g_ring.locked_mask, ~(1 << finished_slot), memory_order_release);
        }
        active_ring_slots[wid][current_frame] = local_read;

        // Acquire Image
        PFN_vkAcquireNextImageKHR pfnAcquire = (PFN_vkAcquireNextImageKHR)win_wsi->vkAcquireNextImageKHR;
        uint32_t img_idx;

        // 5ms timeout. If it times out, drop the lock and yield to the OS/Main Thread.
        VkResult res = pfnAcquire(win_wsi->device, win_wsi->swapchain, 5000000, win_wsi->image_available[current_frame], VK_NULL_HANDLE, &img_idx);

        if (res == VK_TIMEOUT || res == VK_NOT_READY) {
            atomic_store_explicit(&g_render_busy[wid], 0, memory_order_release);
            SLEEP_MS(1); // Crucial: Give the Main Thread's glfwCreateWindow time to execute
            continue;
        }

        if (res == VK_ERROR_OUT_OF_DATE_KHR) {
            atomic_store_explicit(&g_engine.mailbox.window_resized[wid], 1, memory_order_release);

            // CRITICAL RELEASE: Drop the lock before backing out!
            atomic_store_explicit(&g_render_busy[wid], 0, memory_order_release);
            SLEEP_MS(10);
            continue;
        }

        // Record Commands
        PFN_vkResetFences pfnReset = (PFN_vkResetFences)win_wsi->vkResetFences;
        pfnReset(win_wsi->device, 1, &win_wsi->in_flight[current_frame]);

        p->swapchain_image = win_wsi->swapchain_images[img_idx];
        p->swapchain_view = win_wsi->swapchain_views[img_idx];

        vkResetCommandBuffer(cmd, 0);
        vx_record_commands(cmd, p, p->draw_queue, p->draw_count, win_wsi);

        // Submit
        VkPipelineStageFlags waitStage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        VkSubmitInfo submitInfo = {
            .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &win_wsi->image_available[current_frame],
            .pWaitDstStageMask = &waitStage,
            .commandBufferCount = 1,
            .pCommandBuffers = &cmd,
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &win_wsi->render_finished[img_idx]
        };

        PFN_vkQueueSubmit pfnSubmit = (PFN_vkQueueSubmit)win_wsi->vkQueueSubmit;
        pfnSubmit(win_wsi->queue, 1, &submitInfo, win_wsi->in_flight[current_frame]);

        // Present
        VkPresentInfoKHR presentInfo = {
            .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &win_wsi->render_finished[img_idx],
            .swapchainCount = 1,
            .pSwapchains = &win_wsi->swapchain,
            .pImageIndices = &img_idx
        };

        PFN_vkQueuePresentKHR pfnPresent = (PFN_vkQueuePresentKHR)win_wsi->vkQueuePresentKHR;
        pfnPresent(win_wsi->queue, &presentInfo);

        // EXIT VULKAN EXECUTION BLOCK
        atomic_store_explicit(&g_render_busy[wid], 0, memory_order_release);

        // Advance this tenant's frame clock
        t_frame[wid] = (current_frame + 1) % 3;
    }

    printf("[C-CORE] Async Render Multiplexer gracefully terminated.\n");
    return NULL;
}

EXPORT void vx_thread_start() {
    atomic_store_explicit(&g_render_thread_active, 1, memory_order_release);
    atomic_store_explicit(&g_transfer_thread_active, 1, memory_order_release);
    g_render_thread = vmath_thread_start(render_thread_loop, NULL);
    g_transfer_thread = vmath_thread_start(transfer_thread_loop, NULL);
}

EXPORT void vx_thread_kill() {
    atomic_store_explicit(&g_render_thread_active, 0, memory_order_release);
    atomic_store_explicit(&g_transfer_thread_active, 0, memory_order_release);
    vmath_thread_join(g_render_thread);
    vmath_thread_join(g_transfer_thread);

    // [PATCH] Purge the Ring Buffer! Toxic packets and leaked locks die here.
    atomic_store_explicit(&g_ring.ready_idx, -1, memory_order_release);
    atomic_store_explicit(&g_ring.locked_mask, 0, memory_order_release);

    for (int i = 0; i < MAX_WINDOWS; i++) {
        if (g_window_wsi[i].device) {
            vkDeviceWaitIdle(g_window_wsi[i].device);
        }
    }

    if (g_render_cmd_pool) {
        vkDestroyCommandPool(g_window_wsi[0].device, g_render_cmd_pool, NULL);
        g_render_cmd_pool = VK_NULL_HANDLE;
    }
    if (g_transfer_cmd_pool) {
        vkDestroyCommandPool(g_window_wsi[0].device, g_transfer_cmd_pool, NULL);
        g_transfer_cmd_pool = VK_NULL_HANDLE;
    }
    printf("[C-CORE] Async Threads joined, Device idled, Ring Purged, and Pools destroyed.\n");
}

void vx_init_mailbox() {
    atomic_init(&g_engine.mailbox.ready_index, 0);
    atomic_init(&g_engine.mailbox.is_running, 1);
    atomic_init(&g_engine.mailbox.lua_finished, 0);
    atomic_init(&g_engine.mailbox.active_window, 0);

    for (int i = 0; i < MAX_WINDOWS; i++) {
        atomic_init(&g_engine.mailbox.vk_instance[i], NULL);
        atomic_init(&g_engine.mailbox.vk_surface[i], NULL);
        atomic_init(&g_engine.mailbox.glfw_cmd[i], CMD_IDLE);
        atomic_init(&g_engine.mailbox.glfw_arg_w[i], 0);
        atomic_init(&g_engine.mailbox.glfw_arg_h[i], 0);
        atomic_init(&g_engine.mailbox.last_key_pressed[i], 0);
        atomic_init(&g_engine.mailbox.wasd_mask[i], 0);
        atomic_init(&g_engine.mailbox.mouse_dx[i], 0.0f);
        atomic_init(&g_engine.mailbox.mouse_dy[i], 0.0f);
        atomic_init(&g_engine.mailbox.mouse_x[i], 0.0f);
        atomic_init(&g_engine.mailbox.mouse_y[i], 0.0f);
        atomic_init(&g_engine.mailbox.click_x[i], -1.0f);
        atomic_init(&g_engine.mailbox.click_y[i], -1.0f);
        atomic_init(&g_engine.mailbox.mouse_left[i], 0);
        atomic_init(&g_engine.mailbox.mouse_right[i], 0);
        atomic_init(&g_engine.mailbox.mouse_captured[i], 0);
        atomic_init(&g_engine.mailbox.window_resized[i], 0);
        atomic_init(&g_engine.mailbox.win_w[i], 1280);
        atomic_init(&g_engine.mailbox.win_h[i], 720);
        atomic_init(&g_engine.mailbox.key_space[i], 0);
    }
}

// --- THE CONSENSUS LUA OVERLORD THREAD ---
// Reverted to the original, pure, zero-overhead boot sequence.
THREAD_FUNC lua_co_overlord_loop(void* arg) {
    printf("[LUA-OS-THREAD] Booting Lua VM...\n");
    lua_State* L = luaL_newstate();
    luaL_openlibs(L);

    // Engine executes the root main.lua - Lua handles its own package.paths
    if (luaL_dofile(L, "main.lua") != LUA_OK) {
        printf("\n[LUA FATAL ERROR] %s\n", lua_tostring(L, -1));
    }

    lua_close(L);
    printf("[LUA-OS-THREAD] VM Destroyed.\n");
    return THREAD_RETURN_VAL;
}

// === DOMAIN: MAIN EXECUTION ===

// ... [lua_co_overlord_loop unchanged] ...

int main(int argc, char** argv) {
    printf("[C-CORE] Booting Weaver Engine Host...\n");
    if (!glfwInit()) {
        printf("[C-FATAL] GLFW failed to initialize. Display Server missing?\n");
        return -1;
    }

    vx_init_mailbox();

    vmath_thread_t lua_thread = vmath_thread_start(lua_co_overlord_loop, NULL);

    // CRITICAL: The OS Thread must track an array of windows
    GLFWwindow* windows[MAX_WINDOWS] = {NULL};

    while (vx_core_is_running()) {
        // Poll events once per tick if ANY window is alive
        bool has_windows = false;
        for (int i = 0; i < MAX_WINDOWS; i++) {
            if (windows[i] != NULL) {
                has_windows = true;
                break;
            }
        }
        if (has_windows) glfwPollEvents();

        // Loop over every tenant slot to process commands and lifecycle events
        for (int id = 0; id < MAX_WINDOWS; id++) {
            int cmd = atomic_exchange_explicit(&g_engine.mailbox.glfw_cmd[id], CMD_IDLE, memory_order_acquire);

            if (cmd == CMD_BOOT_WINDOW && windows[id] == NULL) {
                // [PATCH] 1. Global WSI Barrier: Suspend all rendering to release OS Display locks
                for (int i = 0; i < MAX_WINDOWS; i++) {
                    if (atomic_load_explicit(&g_wsi_state[i], memory_order_acquire) == 1) {
                        atomic_store_explicit(&g_wsi_state[i], 0, memory_order_release);
                        // Wait for the Render Thread to hit our new VK_TIMEOUT and drop the busy flag
                        while (atomic_load_explicit(&g_render_busy[i], memory_order_acquire)) {
                            SLEEP_MS(1);
                        }
                    }
                }

                int w = atomic_load_explicit(&g_engine.mailbox.glfw_arg_w[id], memory_order_relaxed);
                int h = atomic_load_explicit(&g_engine.mailbox.glfw_arg_h[id], memory_order_relaxed);

                glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
                glfwWindowHint(GLFW_RESIZABLE, GLFW_TRUE);
                windows[id] = glfwCreateWindow(w, h, "Weaver Engine Editor", NULL, NULL);

                // CRITICAL FIX: Bind the tenant ID to the GLFW window for callbacks
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
                atomic_store_explicit(&g_engine.mailbox.win_w[id], fb_w, memory_order_release);
                atomic_store_explicit(&g_engine.mailbox.win_h[id], fb_h, memory_order_release);

                // [PATCH] 2. Fallback to primary instance if Lua hasn't mapped the tenant instance yet
                void* instance = atomic_load_explicit(&g_engine.mailbox.vk_instance[id], memory_order_acquire);
                if (instance == NULL) {
                    instance = atomic_load_explicit(&g_engine.mailbox.vk_instance[0], memory_order_acquire);
                }

                if (instance != NULL) {
                    VkSurfaceKHR surface;
                    if (glfwCreateWindowSurface((VkInstance)instance, windows[id], NULL, &surface) == VK_SUCCESS) {
                        atomic_store_explicit(&g_engine.mailbox.vk_surface[id], (void*)surface, memory_order_release);
                        printf("[C-CORE] Tenant %d: Window & Surface Created safely!\n", id);
                    }
                }

                // [PATCH] 3. Resume rendering ONLY for previously active windows.
                // Do NOT resume the new window (id); Lua's vx_stream_init() handles that atomic handoff securely.
                for (int i = 0; i < MAX_WINDOWS; i++) {
                    if (windows[i] != NULL && i != id) {
                        atomic_store_explicit(&g_wsi_state[i], 1, memory_order_release);
                    }
                }
            }
            else if (cmd == CMD_KILL_WINDOW && windows[id] != NULL) {
                // === TEARDOWN SYNCHRONIZATION ===
                atomic_store_explicit(&g_wsi_state[id], 0, memory_order_release);

                while (atomic_load_explicit(&g_render_busy[id], memory_order_acquire)) {
                    SLEEP_MS(1);
                }

                if (g_window_wsi[id].device) {
                    vkDeviceWaitIdle(g_window_wsi[id].device);
                }

                glfwDestroyWindow(windows[id]);
                windows[id] = NULL;
                atomic_store_explicit(&g_engine.mailbox.vk_surface[id], NULL, memory_order_release);
                printf("[C-CORE] Tenant %d Window Destroyed Safely. Render Thread isolated.\n", id);
            }

            if (windows[id] && glfwWindowShouldClose(windows[id])) {
                atomic_store_explicit(&g_engine.mailbox.last_key_pressed[id], GLFW_KEY_ESCAPE, memory_order_release);
                glfwSetWindowShouldClose(windows[id], GLFW_FALSE);
            }
        }

        SLEEP_MS(1);
    }

    printf("\n[C-CORE] Shutdown triggered. Waiting for Lua VM...\n");
    while (atomic_load_explicit(&g_engine.mailbox.lua_finished, memory_order_acquire) == 0) {
        SLEEP_MS(1);
    }
    vmath_thread_join(lua_thread);

    // Safely cleanup any remaining open windows during a hard shutdown
    for (int i = 0; i < MAX_WINDOWS; i++) {
        if (windows[i]) glfwDestroyWindow(windows[i]);
    }

    glfwTerminate();
    printf("[C-CORE] Clean Exit.\n");
    return 0;
}
