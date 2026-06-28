local ffi = require("ffi")

ffi.cdef[[
// C-Core Multi-Tenant Window & Input API
void vx_sys_publish_instance(int win_id, void* instance);
void vx_sys_set_cmd(int win_id, int cmd, int w, int h);
void* vx_sys_get_surface(int win_id);
int vx_sys_get_resize_state(int win_id);
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

int vx_stream_acquire(int win_id);
void* vx_stream_packet(int idx);
void vx_stream_commit(int win_id, int idx);

void vx_thread_kill();
void vx_stream_init(int win_id, void* wsi);
void vx_thread_start();
void vx_transfer_setup(uint32_t q_family_index);
int vx_transfer_request(int win_id, uint64_t src, uint64_t dst, uint64_t size, uint64_t t_sem, uint64_t sig_val);

// --- NEW VULKAN MULTI-TENANT & VALIDATION API ---
void vx_stream_allocate_tenant(int wid, void* wsi, uint32_t gfx_family, uint32_t transfer_family);
// -- void vx_record_commands(void* cmd, void* p, void* queue, uint32_t count, void* win_wsi);
const char** vx_sys_glfw_extensions(uint32_t* count);
void vx_sys_inject_validation(void* instance_ptr);
void vx_sys_eject_validation(void* instance);

// --- NEW INPUT API ---
int vx_input_get_active_window();

// OS & Time
void Sleep(uint32_t dwMilliseconds);
int usleep(uint32_t usec);
int QueryPerformanceCounter(int64_t *lpPerformanceCount);
int QueryPerformanceFrequency(int64_t *lpFrequency);
typedef struct { long tv_sec; long tv_nsec; } timespec;
int clock_gettime(int clk_id, timespec *tp);

// Math / Structs
typedef struct __attribute__((aligned(16))) { float x, y, z, w; } vec4_t;

typedef struct {
    uint32_t sType;
    void* pNext;
    uint32_t timelineSemaphore;
} VkPhysicalDeviceTimelineSemaphoreFeatures;

]]

return ffi.C
