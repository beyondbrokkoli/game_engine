// AUTO-GENERATED SSoT - DO NOT MODIFY
#pragma once
#include <stdint.h>

// --- ENGINE CONSTANTS ---
#define MODE_DUAL 0
#define MODE_GEOM 1
#define MODE_POINT_CLOUD_PASS 88
#define MODE_POINTS 2
#define FRAME_STATE_CONFIRMED 2
#define FRAME_STATE_EMPTY 0
#define FRAME_STATE_PREDICTED 1
#define WORLD_GRID_CELLS 262144
#define WORLD_MAP_HEIGHT 256
#define WORLD_MAP_WIDTH 256
#define WORLD_OFFSET_X 2560
#define WORLD_OFFSET_Z 2560
#define WORLD_SPACING 20

// --- ENGINE MEMORY STRUCTURES ---
#ifdef VX_ENABLE_VULKAN_STRUCTS
typedef struct  {
    VkDevice device;
    VkQueue queue;
    VkQueue transfer_queue;
    uint32_t max_frames_in_flight;
    uint8_t _pad_auto_0[4];
    void* vkWaitForFences;
    void* vkAcquireNextImageKHR;
    void* vkResetFences;
    void* vkQueueSubmit;
    void* vkQueuePresentKHR;
    void* pfnBegin;
    void* pfnEnd;
    void* pfnSetCullMode;
    void* pfnSetFrontFace;
    void* pfnSetPrimitiveTopology;
    void* pfnSetDepthTestEnable;
    void* pfnSetDepthWriteEnable;
    void* pfnSetDepthCompareOp;
} VulkanDeviceContext;

#endif // VX_ENABLE_VULKAN_STRUCTS

#ifdef VX_ENABLE_VULKAN_STRUCTS
typedef struct  {
    VkSwapchainKHR swapchain;
    uint32_t status;
    uint8_t _pad_auto_0[4];
    uint64_t swapchain_images[10];
    uint64_t swapchain_views[10];
    VkSemaphore image_available[3];
    VkSemaphore render_finished[3];
    VkFence in_flight[3];
    VkFence images_in_flight_fences[10];
} VulkanSwapchainContext;

#endif // VX_ENABLE_VULKAN_STRUCTS

typedef struct  {
    float m[16];
} mat4_t;

typedef struct  {
    float px;
    float py;
    float pz;
    uint32_t tile_data;
} RtsTileInstance;

typedef struct  {
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

typedef struct  {
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

typedef struct __attribute__((aligned(64))) {
    DrawCommand* draw_queue;
    uint32_t draw_count;
    uint32_t target_window_id;
    uint64_t gfx_layout;
    uint64_t vertex_buffer;
    uint64_t index_buffer;
    uint64_t depth_image;
    uint64_t depth_view;
    uint32_t width;
    uint32_t height;
    uint32_t swapchain_generation;
    uint8_t _pad_tail[60];
} RenderPacket;

#pragma pack(push, 1)
typedef struct {
    uint8_t opcode;
    uint8_t flags;
    uint16_t target_id;
    uint32_t target_pos;
} PlayerCommand;
#pragma pack(pop)

#pragma pack(push, 1)
typedef struct {
    uint64_t session_token;
    uint32_t frame_tick;
    uint32_t checksum_tick;
    uint32_t state_checksum;
    uint32_t base_tick;
    uint8_t player_id;
    uint8_t history_count;
    uint16_t _align_pad;
    uint32_t peer_acks[8];
    PlayerCommand commands[120][2];
} LockstepPacket;
#pragma pack(pop)

typedef struct __attribute__((aligned(4))) {
    uint32_t tick;
    uint8_t state;
    uint8_t _pad_auto_0[3];
    uint32_t state_checksum;
    uint32_t remote_checksum;
    uint8_t remote_peer_id;
    uint8_t _pad_auto_1[7];
    PlayerCommand commands[8][2];
} NetworkFrame;

typedef struct __attribute__((aligned(64))) {
    uint32_t head_tick;
    uint32_t confirmed_tick;
    uint8_t is_rollback_active;
    uint8_t _pad_auto_0[3];
    uint32_t rollback_target;
    uint8_t _pad_auto_1[136];
    NetworkFrame frames[512];
    uint8_t _pad_tail[40];
} RollbackBuffer;

typedef struct  {
    uint16_t len;
    uint8_t data[4096];
} RxPacket;

#pragma pack(push, 1)
typedef struct {
    uint64_t session_token;
    uint32_t frame_tick;
    uint32_t checksum_tick;
    uint32_t state_checksum;
    uint32_t base_tick;
    uint8_t player_id;
    uint8_t is_ping;
    uint16_t _align_pad;
    uint32_t padding[3];
} IcePunchPacket;
#pragma pack(pop)

