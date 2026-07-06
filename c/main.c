/*
   main.c — Weaver Engine Host entry point.
   Bootstraps GLFW, spins the Lua VM thread, and runs the multi-tenant
   window multiplexer loop.
*/
#include "vx_global_state.h"
#include "vx_glfw_multiplexer.h"
#include "vx_vulkan_core.h"
#include "vx_vulkan_render.h"

#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

/* ── Lua Co-Overlord Thread */

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

/* ── Entry Point */

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

        /* ── Poll if any window is alive */
        bool has_windows = false;
        for (int i = 0; i < MAX_WINDOWS; i++) {
            if (windows[i] != NULL) { has_windows = true; break; }
        }
        if (has_windows) glfwPollEvents();

        /* ── Per-tenant command dispatch */
        for (int id = 0; id < MAX_WINDOWS; id++) {
            // 1. Use atomic_load (L) instead of atomic_exchange (E_A)!
            // Do not wipe the mailbox. Just peek at it.
            int cmd = L(g_engine.mailbox.tenants[id].glfw_cmd);

            if (cmd == CMD_BOOT_WINDOW && windows[id] == NULL) {
                // ... (your existing mid-loop boot code remains here) ...
                // NO GLOBAL FREEZE. We just create the window.
                int w = L_R(g_engine.mailbox.tenants[id].glfw_arg_w);
                int h = L_R(g_engine.mailbox.tenants[id].glfw_arg_h);

                glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API); glfwWindowHint(GLFW_RESIZABLE, GLFW_TRUE);
                windows[id] = glfwCreateWindow(w, h, "Weaver Engine Editor", NULL, NULL);
                glfwSetWindowUserPointer(windows[id], (void*)(intptr_t)id); glfwSetWindowSizeLimits(windows[id],
                640, 360, GLFW_DONT_CARE, GLFW_DONT_CARE); glfwShowWindow(windows[id]);
                glfwSetWindowAttrib(windows[id], GLFW_FLOATING, GLFW_TRUE); glfwFocusWindow(windows[id]);
                glfwSetWindowAttrib(windows[id], GLFW_FLOATING, GLFW_FALSE);
                glfwSetFramebufferSizeCallback(windows[id], glfw_framebuffer_size_callback);
                glfwSetKeyCallback(windows[id], glfw_key_callback); glfwSetCursorPosCallback(windows[id],
                glfw_cursor_callback); glfwSetMouseButtonCallback(windows[id], glfw_mouse_button_callback);

                int fb_w, fb_h;
                glfwGetFramebufferSize(windows[id], &fb_w, &fb_h);
                S(g_engine.mailbox.tenants[id].win_w, fb_w);
                S(g_engine.mailbox.tenants[id].win_h, fb_h);

                void* instance = L(g_engine.mailbox.tenants[id].vk_instance);
                if (instance != NULL) {
                    VkSurfaceKHR surface;
                    if (glfwCreateWindowSurface((VkInstance)instance, windows[id], NULL, &surface) == VK_SUCCESS) {
                        S(g_engine.mailbox.tenants[id].vk_surface, (void*)surface);
                        printf("[C-CORE] Tenant %d: Mid-loop Window & Surface Created!\n", id);
                    }
                }
                // 2. Clear the command ONLY after we successfully process it
                S(g_engine.mailbox.tenants[id].glfw_cmd, CMD_IDLE);
            }
            else if (cmd == CMD_KILL_WINDOW && windows[id] != NULL) {
                S(g_wsi_state[id], 0);
                int timeout = 2000;

                // STRAGGLER FIX: Wait for BOTH threads to yield before destroying the OS window
                while ((L(g_render_busy[id]) || L(g_transfer_busy[id])) && timeout > 0) {
                    SLEEP_MS(1);
                    timeout--;
                }

                glfwDestroyWindow(windows[id]);
                windows[id] = NULL;
                S(g_engine.mailbox.tenants[id].vk_surface, NULL);
                S(g_engine.mailbox.tenants[id].glfw_cmd, CMD_IDLE);
                printf("[C-CORE] Tenant %d OS Window Destroyed Safely.\n", id);
            }

            /* ── Close-request intercept (all tenants) */
            if (windows[id] && glfwWindowShouldClose(windows[id])) {
                S(g_engine.mailbox.tenants[id].last_key_pressed,
                  GLFW_KEY_ESCAPE);

                // Do NOT reset the close flag here.
                // Let C persistently spam the ESCAPE signal to the mailbox.
                // The loop will naturally break when Lua sends CMD_KILL_WINDOW
                // and sets windows[id] = NULL.
            }
        }

        SLEEP_MS(1);
    }

    /* ── Shutdown */
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
