// AUTO-GENERATED SSoT - DO NOT MODIFY
#pragma once
#include <stdint.h>

// --- ENGINE CONSTANTS ---
#define MODE_DUAL 0
#define MODE_GEOM 1
#define MODE_POINT_CLOUD_PASS 88
#define MODE_POINTS 2
#define CFG_FRAME_SLOTS 10
#define CFG_GRID_CELLS 262144
#define CFG_PC_SIZE 96
#define CFG_PCOUNT 1000000
#define CFG_ROLLBACK_BUFFER_SIZE 128
#define CFG_SWAP_SLOTS 10
#define CFG_SWARM_STATES 7
#define CFG_USE_VALIDATION 0
#define CFG_VK_API_VERSION 4206592
#define FRAME_STATE_CONFIRMED 2
#define FRAME_STATE_EMPTY 0
#define FRAME_STATE_PREDICTED 1
#define WORLD_MAP_HEIGHT 256
#define WORLD_MAP_WIDTH 256
#define WORLD_OFFSET_X 2560
#define WORLD_OFFSET_Z 2560
#define WORLD_SPACING 20
typedef struct __attribute__((packed)) {
    float m[16];
} mat4_t;

typedef struct __attribute__((packed)) {
    float px;
    float py;
    float pz;
    uint32_t tile_data;
} RtsTileInstance;

typedef struct __attribute__((packed)) {
    mat4_t viewProj;
    uint32_t aos_current_idx;
    uint32_t aos_prev_idx;
    float dt;
    float total_time;
    uint32_t target_state;
    uint32_t hover_idx;
    uint32_t flags;
    uint8_t _pad_tail[4];
} PushConstants;

typedef struct __attribute__((packed)) {
    uint64_t pipeline_id;
    uint64_t descriptor_set;
    uint32_t index_count;
    uint32_t instance_count;
    uint32_t first_index;
    int32_t vertex_offset;
    uint32_t first_instance;
    uint16_t pc_offset;
    uint16_t pc_size;
    uint8_t push_constants[128];
    int16_t scissor_x;
    int16_t scissor_y;
    uint16_t scissor_w;
    uint16_t scissor_h;
    uint8_t cull_mode;
    uint8_t depth_test;
    uint8_t depth_write;
    uint8_t depth_compare_op;
    uint8_t front_face;
    uint8_t topology;
    uint8_t _pad_tail[2];
} DrawCommand;

typedef struct __attribute__((packed, aligned(64))) {
    DrawCommand* draw_queue;
    uint32_t draw_count;
    uint8_t _pad_auto_0[4];
    uint64_t gfx_layout;
    uint64_t vertex_buffer;
    uint64_t index_buffer;
    uint64_t swapchain_image;
    uint64_t swapchain_view;
    uint64_t depth_image;
    uint64_t depth_view;
    uint32_t width;
    uint32_t height;
    uint8_t _pad_tail[48];
} RenderPacket;

typedef struct __attribute__((packed, aligned(8))) {
    uint64_t session_token;
    uint32_t frame_tick;
    uint32_t player_input;
    int32_t click_grid_idx;
    uint32_t past_inputs[7];
    int32_t past_clicks[7];
    uint8_t _pad_tail[4];
} LockstepPacket;

typedef struct __attribute__((packed, aligned(4))) {
    uint32_t tick;
    uint32_t local_input;
    uint32_t remote_input;
    int32_t local_click;
    int32_t remote_click;
    uint8_t state;
    uint8_t _pad_tail[3];
} RollbackFrame;

typedef struct __attribute__((packed, aligned(64))) {
    RollbackFrame frames[128];
    uint32_t head_tick;
    uint32_t confirmed_tick;
    uint32_t rollback_target;
    uint32_t is_rollback_active;
    uint8_t _pad_tail[48];
} RollbackBuffer;

#ifdef VX_ENABLE_VULKAN_STRUCTS
        typedef struct {
            VkDevice device; VkQueue queue; VkQueue transfer_queue; VkSwapchainKHR swapchain;
            uint64_t swapchain_images[10]; uint64_t swapchain_views[10];
            VkSemaphore image_available[10]; VkSemaphore render_finished[10];
            VkFence in_flight[10]; void* vkWaitForFences; void* vkAcquireNextImageKHR;
            void* vkResetFences; void* vkQueueSubmit; void* vkQueuePresentKHR;
            void* pfnBegin; void* pfnEnd; void* pfnSetCullMode; void* pfnSetFrontFace;
            void* pfnSetPrimitiveTopology; void* pfnSetDepthTestEnable;
            void* pfnSetDepthWriteEnable; void* pfnSetDepthCompareOp;
        } RenderThreadInit;
    
#endif // VX_ENABLE_VULKAN_STRUCTS
