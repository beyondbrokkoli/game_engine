#pragma once

/*
   vx_glfw_multiplexer.h — Window management and input domain.
*/

#include "vx_global_state.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ── GLFW Callbacks (set via function pointer) */
void glfw_cursor_callback(GLFWwindow* window, double xpos, double ypos);
void glfw_mouse_button_callback(GLFWwindow* window, int button,
                                int action, int mods);
void glfw_key_callback(GLFWwindow* window, int key, int scancode,
                       int action, int mods);
void glfw_framebuffer_size_callback(GLFWwindow* window, int width,
                                    int height);

/* ── Input Queries (EXPORT for Lua FFI) */
EXPORT int        vx_input_last_key(int win_id);
EXPORT int        vx_input_get_active_window(void);
EXPORT int        vx_input_mouse_btn(int win_id, int btn);
EXPORT float      vx_input_mouse_x(int win_id);
EXPORT float      vx_input_mouse_y(int win_id);
EXPORT float      vx_input_click_x(int win_id);
EXPORT float      vx_input_click_y(int win_id);
EXPORT int        vx_input_is_captured(int win_id);
EXPORT uint32_t   vx_input_wasd(int win_id);
EXPORT float      vx_input_mouse_dx(int win_id);
EXPORT float      vx_input_mouse_dy(int win_id);
EXPORT int        vx_input_spacebar(int win_id);
EXPORT int        vx_sys_get_resize_state(int win_id);

/* ── Window System Helpers (EXPORT for Lua FFI) */
EXPORT const char** vx_sys_glfw_extensions(uint32_t* count);
EXPORT void         vx_sys_publish_instance(int win_id, void* instance);
EXPORT void* vx_sys_get_surface(int win_id);
EXPORT void         vx_sys_set_cmd(int win_id, int cmd, int w, int h);
EXPORT void         vx_sys_window_size(int win_id, int* w, int* h);

#ifdef __cplusplus
}
#endif
