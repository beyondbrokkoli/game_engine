/* ═══════════════════════════════════════════════════════════════════
   main.c — Weaver Engine Host entry point.
   Bootstraps GLFW, spins the Lua VM thread, and runs the multi-tenant
   window multiplexer loop.
   ═══════════════════════════════════════════════════════════════════ */
#include "vx_global_state.h"
#include "vx_glfw_multiplexer.h"
#include "vx_vulkan_core.h"
#include "vx_vulkan_render.h"

#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

/* ── Lua Co-Overlord Thread ─────────────────────────────────────── */

static THREAD_FUNC lua_co_overlord_loop(void* arg) {
    printf("[LUA-OS-THREAD] Booting Lua VM...\n");

    lua_State* Ls = luaL_newstate();
    luaL_openlibs(Ls);

    if (luaL_dofile(Ls, "main.lua") != LUA_OK) {
        printf("\n[LUA FATAL ERROR] %s\n", lua_tostring(Ls, -1));
        vx_core_shutdown();
    }

    lua_close(Ls);
    printf("[LUA-OS-THREAD] VM Destroyed.\n");
    return THREAD_RETURN_VAL;
}

/* ── Entry Point ────────────────────────────────────────────────── */

int main(int argc, char** argv) {
    printf("[C-CORE] Booting Weaver Engine Host...\n");

    if (!glfwInit()) {
        printf("[C-FATAL] GLFW failed to initialize. "
               "Display Server missing?\n");
        return -1;
    }

    vx_init_mailbox();

    vmath_thread_t lua_thread =
        vmath_thread_start(lua_co_overlord_loop, NULL);

    GLFWwindow* windows[MAX_WINDOWS] = {NULL};

    while (vx_core_is_running()) {

        /* ── Poll if any window is alive ────────────────────────── */
        bool has_windows = false;
        for (int i = 0; i < MAX_WINDOWS; i++) {
            if (windows[i] != NULL) { has_windows = true; break; }
        }
        if (has_windows) glfwPollEvents();

        /* ── Per-tenant command dispatch ────────────────────────── */
        for (int id = 0; id < MAX_WINDOWS; id++) {
            int cmd = E_A(g_engine.mailbox.tenants[id].glfw_cmd, CMD_IDLE);

            /* ── BOOT ───────────────────────────────────────────── */
            if (cmd == CMD_BOOT_WINDOW && windows[id] == NULL) {

                for (int i = 0; i < MAX_WINDOWS; i++) {
                    if (L(g_wsi_state[i]) == 1) {
                        S(g_wsi_state[i], 0);
                        while (L(g_render_busy[i])) { SLEEP_MS(1); }
                    }
                }

                int w = L_R(g_engine.mailbox.tenants[id].glfw_arg_w);
                int h = L_R(g_engine.mailbox.tenants[id].glfw_arg_h);

                glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
                glfwWindowHint(GLFW_RESIZABLE,  GLFW_TRUE);

                windows[id] = glfwCreateWindow(
                    w, h, "Weaver Engine Editor", NULL, NULL);

                glfwSetWindowUserPointer(windows[id],
                                         (void*)(intptr_t)id);
                glfwSetWindowSizeLimits(windows[id],
                    640, 360, GLFW_DONT_CARE, GLFW_DONT_CARE);
                glfwShowWindow(windows[id]);

                glfwSetWindowAttrib(windows[id], GLFW_FLOATING, GLFW_TRUE);
                glfwFocusWindow(windows[id]);
                glfwSetWindowAttrib(windows[id], GLFW_FLOATING, GLFW_FALSE);

                glfwSetFramebufferSizeCallback(windows[id],
                    glfw_framebuffer_size_callback);
                glfwSetKeyCallback(windows[id],
                    glfw_key_callback);
                glfwSetCursorPosCallback(windows[id],
                    glfw_cursor_callback);
                glfwSetMouseButtonCallback(windows[id],
                    glfw_mouse_button_callback);

                int fb_w, fb_h;
                glfwGetFramebufferSize(windows[id], &fb_w, &fb_h);
                S(g_engine.mailbox.tenants[id].win_w, fb_w);
                S(g_engine.mailbox.tenants[id].win_h, fb_h);

                void* instance =
                    L(g_engine.mailbox.tenants[id].vk_instance);
                if (instance != NULL) {
                    VkSurfaceKHR surface;
                    if (glfwCreateWindowSurface(
                            (VkInstance)instance, windows[id],
                            NULL, &surface) == VK_SUCCESS) {
                        S(g_engine.mailbox.tenants[id].vk_surface,
                          (void*)surface);
                        printf("[C-CORE] Tenant %d: Window & Surface "
                               "Created safely!\n", id);
                    }
                } else {
                    printf("[C-ERROR] Tenant %d missing Vulkan instance! "
                           "Window surface creation aborted.\n", id);
                }

                for (int i = 0; i < MAX_WINDOWS; i++) {
                    if (windows[i] != NULL && i != id) {
                        S(g_wsi_state[i], 1);
                    }
                }

            /* ── KILL ───────────────────────────────────────────── */
            } else if (cmd == CMD_KILL_WINDOW && windows[id] != NULL) {

                S(g_wsi_state[id], 0);

                int timeout = 2000;
                while (L(g_render_busy[id])) {
                    SLEEP_MS(1);
                    timeout--;
                    if (timeout <= 0) {
                        printf("[C-FATAL] Render thread failed to release "
                               "busy flag for Tenant %d. "
                               "Force overriding.\n", id);
                        break;
                    }
                }

                if (g_window_wsi[id].device) {
                    // [RESTORED] Surgical Teardown: Wait ONLY for this tenant's frames
                    // Do NOT use vkDeviceWaitIdle here! It will crash the shared VkQueue.
                    PFN_vkWaitForFences pfnWait = (PFN_vkWaitForFences)g_window_wsi[id].vkWaitForFences;
                    if (pfnWait) {
                        for (uint32_t f = 0; f < g_window_wsi[id].max_frames_in_flight; f++) {
                            if (g_window_wsi[id].in_flight[f]) {
                                pfnWait(g_window_wsi[id].device, 1, &g_window_wsi[id].in_flight[f], VK_TRUE, 2000000000);
                            }
                        }
                    }

                    if (g_render_cmd_pools[id]) {
                        vkDestroyCommandPool(g_window_wsi[id].device,
                            g_render_cmd_pools[id], NULL);
                        g_render_cmd_pools[id] = VK_NULL_HANDLE;
                    }
                    if (g_transfer_cmd_pools[id]) {
                        vkDestroyCommandPool(g_window_wsi[id].device,
                            g_transfer_cmd_pools[id], NULL);
                        g_transfer_cmd_pools[id] = VK_NULL_HANDLE;
                    }
                    if (g_transfer_fences[id]) {
                        vkDestroyFence(g_window_wsi[id].device,
                            g_transfer_fences[id], NULL);
                        g_transfer_fences[id] = VK_NULL_HANDLE;
                    }
                }

                glfwDestroyWindow(windows[id]);
                windows[id] = NULL;
                S(g_engine.mailbox.tenants[id].vk_surface, NULL);

                printf("[C-CORE] Tenant %d Window & Explicit Allocations "
                       "Destroyed Safely.\n", id);
            }

            /* ── Close-request intercept (all tenants) ──────────── */
            if (windows[id] && glfwWindowShouldClose(windows[id])) {
                // Signal Lua that this tenant wants to die
                S(g_engine.mailbox.tenants[id].close_requested, 1);

                // Veto the OS close request. Lua and the Multiplexer will tear it down natively later.
                glfwSetWindowShouldClose(windows[id], GLFW_FALSE);
            }
        }

        SLEEP_MS(1);
    }

    /* ── Shutdown ───────────────────────────────────────────────── */
    printf("\n[C-CORE] Shutdown triggered. Waiting for Lua VM...\n");

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
