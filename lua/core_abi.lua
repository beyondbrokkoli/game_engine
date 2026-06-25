-- lua/core_abi.lua
local ffi = require("ffi")

ffi.cdef[[
// C-Core Multi-Tenant Window & Input API

void vx_sys_publish_instance(int win_id, void* instance);
void vx_sys_set_cmd(int win_id, int cmd, int w, int h);
void* vx_sys_get_surface(int win_id);
int vx_sys_resize_flag(int win_id);
void vx_sys_window_size(int win_id, int* w, int* h);

int vx_input_last_key(int win_id);
uint32_t vx_input_wasd(int win_id);
float vx_input_mouse_dx(int win_id);
float vx_input_mouse_dy(int win_id);
float vx_input_mouse_x(int win_id);
float vx_input_mouse_y(int win_id);
float vx_input_click_x(int win_id);
float vx_input_click_y(int win_id);
int vx_input_is_captured(int win_id);
int vx_input_mouse_btn(int win_id, int btn);
int vx_input_spacebar(int win_id);

// C-Core Engine & Stream API
int vx_core_is_running();
void vx_core_shutdown();
void vx_core_mark_finished();
int vx_stream_acquire();
void* vx_stream_packet(int idx);
void vx_stream_commit(int idx);
void vx_thread_kill();
void vx_stream_init(int win_id, void* wsi);
void vx_thread_start();
void vx_transfer_setup(uint32_t q_family_index);
int vx_transfer_request(uint64_t src, uint64_t dst, uint64_t size, uint64_t t_sem, uint64_t sig_val);

// OS & Time
void Sleep(uint32_t dwMilliseconds);
int usleep(uint32_t usec);
int QueryPerformanceCounter(int64_t *lpPerformanceCount);
int QueryPerformanceFrequency(int64_t *lpFrequency);
typedef struct { long tv_sec; long tv_nsec; } timespec;
int clock_gettime(int clk_id, timespec *tp);

// Math / Structs
typedef struct __attribute__((aligned(16))) { float x, y, z, w; } vec4_t;
]]

return ffi.C
