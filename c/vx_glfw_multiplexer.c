/* ═══════════════════════════════════════════════════════════════════
   vx_glfw_multiplexer.c — GLFW window lifecycle, input callbacks,
   multi-tenant window tracking, and input query exports.
   ═══════════════════════════════════════════════════════════════════ */
#include "vx_glfw_multiplexer.h"

/* ── File-Local State ───────────────────────────────────────────── */
static bool    s_is_fullscreen[MAX_WINDOWS] = {false};
static int     s_win_x[MAX_WINDOWS] = {0};
static int     s_win_y[MAX_WINDOWS] = {0};
static int     s_win_w[MAX_WINDOWS] = {1280};
static int     s_win_h[MAX_WINDOWS] = {720};

static double  last_mx[MAX_WINDOWS] = {0.0};
static double  last_my[MAX_WINDOWS] = {0.0};
static bool    first_mouse[MAX_WINDOWS] = {true, true, true, true};

static atomic_flag s_mouse_lock = ATOMIC_FLAG_INIT;

/* ══════════════════════════════════════════════════════════════════
   GLFW Callbacks
   ══════════════════════════════════════════════════════════════════ */

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

    float current_dx = L_R(g_engine.mailbox.tenants[id].mouse_dx);
    float new_dx;
    do { new_dx = current_dx + dx; }
    while (!CWX(g_engine.mailbox.tenants[id].mouse_dx, current_dx, new_dx));

    float current_dy = L_R(g_engine.mailbox.tenants[id].mouse_dy);
    float new_dy;
    do { new_dy = current_dy + dy; }
    while (!CWX(g_engine.mailbox.tenants[id].mouse_dy, current_dy, new_dy));
}

void glfw_mouse_button_callback(GLFWwindow* window, int button,
                                int action, int mods) {
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
        S(g_engine.mailbox.tenants[id].mouse_right,
          (action == GLFW_PRESS) ? 1 : 0);
    }
}

void glfw_key_callback(GLFWwindow* window, int key, int scancode,
                       int action, int mods) {
    int id = (int)(intptr_t)glfwGetWindowUserPointer(window);
    if (id < 0 || id >= MAX_WINDOWS) return;

    S(g_engine.mailbox.active_window, id);

    if (action == GLFW_PRESS || action == GLFW_RELEASE) {
        uint32_t bit = 0;
        if      (key == GLFW_KEY_W) bit = 1;
        else if (key == GLFW_KEY_S) bit = 2;
        else if (key == GLFW_KEY_A) bit = 4;
        else if (key == GLFW_KEY_D) bit = 8;
        else if (key == GLFW_KEY_E) bit = 16;
        else if (key == GLFW_KEY_Q) bit = 32;

        if (bit) {
            uint32_t mask = L(g_engine.mailbox.tenants[id].wasd_mask);
            uint32_t new_mask;
            do {
                new_mask = (action == GLFW_PRESS) ? (mask | bit)
                                                  : (mask & ~bit);
            } while (!CWX(g_engine.mailbox.tenants[id].wasd_mask,
                          mask, new_mask));
        }
    }

    if (key == GLFW_KEY_ESCAPE && action == GLFW_PRESS) {
        S(g_engine.mailbox.tenants[id].last_key_pressed, GLFW_KEY_ESCAPE);
    }

    if (key == GLFW_KEY_SPACE) {
        S(g_engine.mailbox.tenants[id].key_space,
          (action != GLFW_RELEASE) ? 1 : 0);
    }

    if (key == GLFW_KEY_F11 && action == GLFW_PRESS) {
        if (!s_is_fullscreen[id]) {
            glfwGetWindowPos(window, &s_win_x[id], &s_win_y[id]);
            glfwGetWindowSize(window, &s_win_w[id], &s_win_h[id]);
            GLFWmonitor* monitor = glfwGetPrimaryMonitor();
            const GLFWvidmode* mode = glfwGetVideoMode(monitor);
            glfwSetWindowMonitor(window, monitor, 0, 0,
                                 mode->width, mode->height,
                                 mode->refreshRate);
            s_is_fullscreen[id] = true;
            printf("[C-CORE] Tenant %d: Native Fullscreen Engaged "
                   "(%dx%d @ %dHz)\n",
                   id, mode->width, mode->height, mode->refreshRate);
        } else {
            glfwSetWindowMonitor(window, NULL,
                                 s_win_x[id], s_win_y[id],
                                 s_win_w[id], s_win_h[id], 0);
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
        if (key == GLFW_KEY_1 || key == GLFW_KEY_2 ||
            key == GLFW_KEY_3 || key == GLFW_KEY_4 ||
            key == GLFW_KEY_F5 || key == GLFW_KEY_ENTER ||
            key == GLFW_KEY_KP_ENTER) {
            S(g_engine.mailbox.tenants[id].last_key_pressed, key);
        }
    }

    if (key == GLFW_KEY_F5 && action == GLFW_PRESS) {
        printf("\n>>> NATIVE OS KEY INTERCEPT: F5 <<<\n");
        for (int i = 0; i < MAX_WINDOWS; i++) {
            vx_sys_dump_ring_state(i);
        }
        fflush(stdout);
    }
}

void glfw_framebuffer_size_callback(GLFWwindow* window, int width,
                                    int height) {
    if (width == 0 || height == 0) return;

    int id = (int)(intptr_t)glfwGetWindowUserPointer(window);
    if (id < 0 || id >= MAX_WINDOWS) return;

    S(g_engine.mailbox.tenants[id].win_w, width);
    S(g_engine.mailbox.tenants[id].win_h, height);
    S(g_engine.mailbox.tenants[id].window_resized, 1);
}

/* ══════════════════════════════════════════════════════════════════
   Input Query Exports
   ══════════════════════════════════════════════════════════════════ */

EXPORT int vx_input_last_key(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return 0;
    return E_A(g_engine.mailbox.tenants[win_id].last_key_pressed, 0);
}

EXPORT int vx_input_get_active_window(void) {
    return L(g_engine.mailbox.active_window);
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

EXPORT uint32_t vx_input_wasd(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return 0;
    return L(g_engine.mailbox.tenants[win_id].wasd_mask);
}

EXPORT float vx_input_mouse_dx(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return 0.0f;
    return E_R(g_engine.mailbox.tenants[win_id].mouse_dx, 0.0f);
}

EXPORT float vx_input_mouse_dy(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return 0.0f;
    return E_R(g_engine.mailbox.tenants[win_id].mouse_dy, 0.0f);
}

EXPORT int vx_input_spacebar(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return 0;
    return L(g_engine.mailbox.tenants[win_id].key_space);
}

EXPORT int vx_sys_close_requested(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return 0;
    // Reads the flag and immediately resets it to 0
    return E_A(g_engine.mailbox.tenants[win_id].close_requested, 0);
}

EXPORT int vx_sys_get_resize_state(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return 0;
    return atomic_load_explicit(
        &g_engine.mailbox.tenants[win_id].window_resized,
        memory_order_acquire);
}

/* ══════════════════════════════════════════════════════════════════
   Window System Helpers
   ══════════════════════════════════════════════════════════════════ */

EXPORT const char** vx_sys_glfw_extensions(uint32_t* count) {
    return glfwGetRequiredInstanceExtensions(count);
}

EXPORT void vx_sys_publish_instance(int win_id, void* instance) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return;
    S(g_engine.mailbox.tenants[win_id].vk_instance, instance);
}

EXPORT void* vx_sys_get_surface(int win_id) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return NULL;
    return L(g_engine.mailbox.tenants[win_id].vk_surface);
}

EXPORT void vx_sys_set_cmd(int win_id, int cmd, int w, int h) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return;
    S_R(g_engine.mailbox.tenants[win_id].glfw_arg_w, w);
    S_R(g_engine.mailbox.tenants[win_id].glfw_arg_h, h);
    S(g_engine.mailbox.tenants[win_id].glfw_cmd, cmd);
}

EXPORT void vx_sys_window_size(int win_id, int* w, int* h) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) {
        *w = 0; *h = 0;
        return;
    }
    *w = L(g_engine.mailbox.tenants[win_id].win_w);
    *h = L(g_engine.mailbox.tenants[win_id].win_h);
}
