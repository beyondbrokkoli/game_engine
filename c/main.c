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

        glfwPollEvents();
        vx_pump_zombie_gc(); // Non-blocking async GC check for dead swapchains

        /* ── Per-tenant command dispatch */
        for (int id = 0; id < MAX_WINDOWS; id++) {
            // Do not wipe the mailbox. Just peek at it.
            int cmd = L(g_engine.mailbox.tenants[id].glfw_cmd);

            if (cmd == CMD_BOOT_WINDOW && windows[id] == NULL) {
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
                S(g_engine.mailbox.tenants[id].glfw_cmd, CMD_IDLE);
            }
            else if (cmd == CMD_KILL_WINDOW && windows[id] != NULL) {
                S(g_wsi_state[id], 0);
                int timeout = 2000;
                int spin_count = 0;

                while ((L(g_render_busy[id]) || L(g_transfer_busy[id])) && timeout > 0) {
                    if (spin_count >= 2000) { timeout--; }
                    vx_spin_wait(&spin_count);
                }

                glfwDestroyWindow(windows[id]);
                windows[id] = NULL;
                S(g_engine.mailbox.tenants[id].vk_surface, NULL);
                S(g_engine.mailbox.tenants[id].glfw_cmd, CMD_IDLE);
                printf("[C-CORE] Tenant %d OS Window Destroyed Safely.\n", id);
            }
            else if (cmd == CMD_PREPARE_NEW_WSI) {
                uint32_t active_gen = L(g_wsi_generation[id]);
                uint32_t active_idx = active_gen % 2;
                uint32_t inactive_idx = (active_gen + 1) % 2;

                VulkanSwapchainContext* new_wsi = &g_wsi_ctx[id][inactive_idx];
                VulkanSwapchainContext* old_wsi = &g_wsi_ctx[id][active_idx]; // We need the old one

                uint32_t slot_status = atomic_load_explicit((_Atomic uint32_t*)&new_wsi->status, memory_order_acquire);
                if (slot_status != 0) {
                    continue;
                }

                // --- THE FIX: Mark the active WSI as 'Retiring' BEFORE Lua calls vkCreateSwapchainKHR ---
                // '999' acts as a barrier so the Render Thread stops calling vkAcquireNextImageKHR.
                // It will be safely overwritten to 120 (Zombie) when Lua fires CMD_FLIP_WSI.
                atomic_store_explicit((_Atomic uint32_t*)&old_wsi->status, 999, memory_order_release);

                // Purge memory so Lua inherits a pristine environment
                memset(new_wsi, 0, sizeof(VulkanSwapchainContext));

                // Architecture Fix: Yield directly to Lua's FFI for WSI creation.
                S(g_engine.mailbox.tenants[id].glfw_cmd, CMD_IDLE);
                printf("[C-CORE] Tenant %d: Slot %d cleared. Yielding WSI build to Lua.\n", id, inactive_idx);
            }
            else if (cmd == CMD_FLIP_WSI) {
                uint32_t active_gen = L(g_wsi_generation[id]);
                uint32_t active_idx = active_gen % 2;
                uint32_t inactive_idx = (active_gen + 1) % 2;

                // Explicit casts to bypass Lua SSoT constraints on the uint32_t status field

                // Set zombie countdown to 120 frames (roughly 2 seconds of safety buffer)
                atomic_store_explicit((_Atomic uint32_t*)&g_wsi_ctx[id][active_idx].status, 120, memory_order_release);

                atomic_store_explicit((_Atomic uint32_t*)&g_wsi_ctx[id][inactive_idx].status, 1, memory_order_release);

                // THE HOLY GRAIL FLIP
                S(g_wsi_generation[id], active_gen + 1);

                S(g_engine.mailbox.tenants[id].glfw_cmd, CMD_IDLE);
                printf("[C-CORE] Tenant %d: Asynchronous WSI Flip Executed! (New Gen: %d)\n", id, active_gen + 1);
            }

            /* ── Close-request intercept (all tenants) */
            if (windows[id] && glfwWindowShouldClose(windows[id])) {
                S(g_engine.mailbox.tenants[id].last_key_pressed,
                  GLFW_KEY_ESCAPE);
            }
        }

        SLEEP_MS(1);
    }

    /* ── Shutdown */
    printf("\n[C-CORE] Shutdown triggered. Waiting for Lua VM...\n");

    int spin_count = 0;
    while (L(g_engine.mailbox.lua_finished) == 0) {
        vx_spin_wait(&spin_count);
    }

    vmath_thread_join(lua_thread);

    for (int i = 0; i < MAX_WINDOWS; i++) {
        if (windows[i]) glfwDestroyWindow(windows[i]);
    }

    glfwTerminate();
    printf("[C-CORE] Clean Exit.\n");
    return 0;
}
