#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdalign.h>

#define GLFW_INCLUDE_VULKAN
#include <GLFW/glfw3.h>

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

// --- DEFINES ---
#define CMD_IDLE 0
#define CMD_BOOT_WINDOW 1
#define CMD_KILL_WINDOW 2
#define MAX_WINDOWS 4
#define RING_SIZE 4
#define TRANSFER_RING_SIZE 4

#define LOAD(var) atomic_load_explicit(&(var), memory_order_acquire)
#define STORE(var, val) atomic_store_explicit(&(var), (val), memory_order_release)

// --- GLOBAL STATE ---
static bool s_is_fullscreen[MAX_WINDOWS] = {false};
static int s_win_x[MAX_WINDOWS] = {0}, s_win_y[MAX_WINDOWS] = {0};
static int s_win_w[MAX_WINDOWS] = {1280}, s_win_h[MAX_WINDOWS] = {720};

static EngineState g_engine;

double last_mx[MAX_WINDOWS] = {0.0};
double last_my[MAX_WINDOWS] = {0.0};
bool first_mouse[MAX_WINDOWS] = {true, true, true, true};
static atomic_flag s_mouse_lock = ATOMIC_FLAG_INIT;

VkDebugUtilsMessengerEXT g_debugMessenger = VK_NULL_HANDLE;

static RenderRing g_ring = { .ready_idx = -1, .locked_mask = 0 };

static RenderThreadInit g_window_wsi[MAX_WINDOWS];
static atomic_int g_wsi_state[MAX_WINDOWS] = {0, 0, 0, 0};
static atomic_int g_render_busy[MAX_WINDOWS] = {0, 0, 0, 0};

static vmath_thread_t g_render_thread;
static atomic_int g_render_thread_active = 0;

static TransferJob g_transfer_ring[TRANSFER_RING_SIZE];
static uint32_t g_transfer_family_idx = 0;
static vmath_thread_t g_transfer_thread;
static atomic_int g_transfer_thread_active = 0;

// Explicit Command Pools (From Master Patch)
static VkCommandPool g_render_cmd_pools[MAX_WINDOWS] = {VK_NULL_HANDLE};
static VkCommandPool g_transfer_cmd_pools[MAX_WINDOWS] = {VK_NULL_HANDLE};

// Explicit Command Buffers & Fences (From Master Patch)
static VkCommandBuffer g_render_cmd_buffers[MAX_WINDOWS][3]; 
static VkCommandBuffer g_transfer_cmd_buffers[MAX_WINDOWS];
static VkFence g_transfer_fences[MAX_WINDOWS] = {VK_NULL_HANDLE};

// --- IPC & MAILBOX UTILITY ---
// [TRUNCATED: vmath_thread_start]
// [TRUNCATED: vmath_thread_join]
// [TRUNCATED: vx_core_is_running]
// [TRUNCATED: vx_core_shutdown]
// [TRUNCATED: vx_core_mark_finished]
// [TRUNCATED: vx_sys_glfw_extensions]
// [TRUNCATED: vx_sys_publish_instance]
// [TRUNCATED: vx_sys_get_surface]
// [TRUNCATED: vx_sys_set_cmd]
// [TRUNCATED: vx_init_mailbox]

// --- INPUT & GLFW CALLBACKS ---
// [TRUNCATED: vx_input_last_key]
// [TRUNCATED: vx_input_get_active_window]
// [TRUNCATED: glfw_cursor_callback]
// [TRUNCATED: glfw_mouse_button_callback]
// [TRUNCATED: vx_input_mouse_btn]
// [TRUNCATED: vx_input_mouse_x]
// [TRUNCATED: vx_input_mouse_y]
// [TRUNCATED: vx_input_click_x]
// [TRUNCATED: vx_input_click_y]
// [TRUNCATED: vx_input_is_captured]
// [TRUNCATED: glfw_key_callback]
// [TRUNCATED: vx_input_wasd]
// [TRUNCATED: vx_input_mouse_dx]
// [TRUNCATED: vx_input_mouse_dy]
// [TRUNCATED: vx_sys_resize_flag]
// [TRUNCATED: vx_sys_window_size]
// [TRUNCATED: glfw_framebuffer_size_callback]
// [TRUNCATED: vx_input_spacebar]

// --- VULKAN WSI & INITIALIZATION ---
// [TRUNCATED: vulkan_debug_callback]
// [TRUNCATED: vx_sys_inject_validation]
// [TRUNCATED: vx_sys_eject_validation]
// [TRUNCATED: vx_stream_register_window]
// [TRUNCATED: vx_stream_init]
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

EXPORT void vx_stream_allocate_tenant(int wid, RenderThreadInit* wsi, uint32_t gfx_family, uint32_t transfer_family) {
    if (wid < 0 || wid >= MAX_WINDOWS || !wsi || !wsi->device) {
        printf("[C-ERROR] Failed to allocate tenant %d: Invalid WSI or Device.\n", wid);
        return;
    }

    // 1. Allocate Render Pool & Buffers Upfront
    if (g_render_cmd_pools[wid] == VK_NULL_HANDLE) {
        VkCommandPoolCreateInfo r_pool_info = {
            .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = gfx_family
        };
        vkCreateCommandPool(wsi->device, &r_pool_info, NULL, &g_render_cmd_pools[wid]);

        VkCommandBufferAllocateInfo r_alloc_info = {
            .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = g_render_cmd_pools[wid],
            .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 3
        };
        vkAllocateCommandBuffers(wsi->device, &r_alloc_info, g_render_cmd_buffers[wid]);
        printf("[C-CORE] Tenant %d: Render pool and 3x command buffers explicitly allocated.\n", wid);
    }

    // 2. Allocate Transfer Pool, Buffer, and Fence Upfront
    if (g_transfer_cmd_pools[wid] == VK_NULL_HANDLE) {
        VkCommandPoolCreateInfo t_pool_info = {
            .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = transfer_family
        };
        vkCreateCommandPool(wsi->device, &t_pool_info, NULL, &g_transfer_cmd_pools[wid]);

        VkCommandBufferAllocateInfo t_alloc_info = {
            .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = g_transfer_cmd_pools[wid],
            .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1
        };
        vkAllocateCommandBuffers(wsi->device, &t_alloc_info, &g_transfer_cmd_buffers[wid]);

        VkFenceCreateInfo fence_info = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, .flags = 1 }; // Signaled initially
        vkCreateFence(wsi->device, &fence_info, NULL, &g_transfer_fences[wid]);
        printf("[C-CORE] Tenant %d: Transfer pool, buffer, and fence explicitly allocated.\n", wid);
    }
}

// --- ASYNC THREADS & BACKGROUND LOOPS ---
// [TRUNCATED: vx_transfer_setup]
EXPORT void vx_transfer_setup(uint32_t q_family_index) {
    g_transfer_family_idx = q_family_index;
    for(int i = 0; i < TRANSFER_RING_SIZE; i++) {
        atomic_init(&g_transfer_ring[i].status, 0);
    }
}

// [TRUNCATED: vx_transfer_request]
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

    while (atomic_load_explicit(&g_transfer_thread_active, memory_order_acquire) &&
           atomic_load_explicit(&g_engine.mailbox.is_running, memory_order_acquire)) {

        bool worked = false;
        for(int i = 0; i < TRANSFER_RING_SIZE; i++) {
            if (atomic_load_explicit(&g_transfer_ring[i].status, memory_order_acquire) == 2) {
                TransferJob* job = &g_transfer_ring[i];

                int wid = -1;
                for (int w = 0; w < MAX_WINDOWS; w++) {
                    if (atomic_load_explicit(&g_wsi_state[w], memory_order_acquire) && g_window_wsi[w].device) {
                        // Ensure this window has actually had its pools allocated
                        if (g_transfer_cmd_pools[w] != VK_NULL_HANDLE) {
                            wid = w;
                            break;
                        }
                    }
                }

                if (wid == -1) {
                    SLEEP_MS(1);
                    continue;
                }

                RenderThreadInit* wsi = &g_window_wsi[wid];

                // Pull pre-allocated buffer and fence
                VkCommandBuffer cmd = g_transfer_cmd_buffers[wid];
                VkFence fence = g_transfer_fences[wid];

                PFN_vkWaitForFences pfnWait = (PFN_vkWaitForFences)wsi->vkWaitForFences;
                PFN_vkResetFences pfnReset = (PFN_vkResetFences)wsi->vkResetFences;
                PFN_vkQueueSubmit pfnSubmit = (PFN_vkQueueSubmit)wsi->vkQueueSubmit;

                pfnWait(wsi->device, 1, &fence, VK_TRUE, UINT64_MAX);
                pfnReset(wsi->device, 1, &fence);

                vkResetCommandBuffer(cmd, 0);
                VkCommandBufferBeginInfo beginInfo = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
                vkBeginCommandBuffer(cmd, &beginInfo);

                VkBufferCopy copyRegion = { .srcOffset = 0, .dstOffset = 0, .size = job->size };
                vkCmdCopyBuffer(cmd, (VkBuffer)job->src_buffer, (VkBuffer)job->dst_buffer, 1, &copyRegion);
                vkEndCommandBuffer(cmd);

                VkTimelineSemaphoreSubmitInfo timelineInfo = {
                    .sType = 1000207003,
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

                pfnSubmit(wsi->transfer_queue, 1, &submitInfo, fence);
                atomic_store_explicit(&job->status, 0, memory_order_release);
                worked = true;
            }
        }
        if (!worked) SLEEP_MS(1);
    }

    printf("[C-CORE] Async Transfer Thread gracefully terminated.\n");
    return NULL;
}

// [TRUNCATED: vx_stream_packet]
EXPORT RenderPacket* vx_stream_packet(int idx) {
    // [PATCH] Guard against -1 index requests from leaked locks
    if (idx < 0 || idx >= RING_SIZE) {
        printf("[FATAL] -1 index requests");
        return NULL;
    }
    return &g_ring.packets[idx];
}

// [TRUNCATED: vx_stream_acquire]
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

// [TRUNCATED: vx_stream_commit]
EXPORT void vx_stream_commit(int idx) {
    // FORCE HARDWARE MEMORY FLUSH:
    // Guarantees all previous ffi.copy and pointer assignments from Lua
    // are visible in RAM before the C-Core is allowed to read this slot.
    atomic_thread_fence(memory_order_release);
    STORE(g_ring.ready_idx, idx);
}

// [TRUNCATED: vx_record_commands]
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

    uint32_t t_frame[MAX_WINDOWS] = {0};
    int active_ring_slots[MAX_WINDOWS][3];

    for (int wid = 0; wid < MAX_WINDOWS; wid++) {
        for (int f = 0; f < 3; f++) active_ring_slots[wid][f] = -1;
    }

    int local_read = -1;
    while (atomic_load_explicit(&g_render_thread_active, memory_order_acquire) &&
           atomic_load_explicit(&g_engine.mailbox.is_running, memory_order_acquire)) {

        int ready = atomic_load_explicit(&g_ring.ready_idx, memory_order_acquire);
        if (ready == -1 || ready == local_read) {
            SLEEP_MS(1);
            continue;
        }

        local_read = ready;
        RenderPacket* p = &g_ring.packets[local_read];
        int wid = p->target_window_id;

        // Strict validity checks
        if (wid < 0 || wid >= MAX_WINDOWS || atomic_load_explicit(&g_wsi_state[wid], memory_order_acquire) == 0) {
            atomic_fetch_and_explicit(&g_ring.locked_mask, ~(1 << local_read), memory_order_release);
            continue;
        }

        atomic_store_explicit(&g_render_busy[wid], 1, memory_order_release);
        RenderThreadInit* win_wsi = &g_window_wsi[wid];

        uint32_t current_frame = t_frame[wid];

        // Pull the pre-allocated command buffer cleanly
        VkCommandBuffer cmd = g_render_cmd_buffers[wid][current_frame];

        PFN_vkWaitForFences pfnWait = (PFN_vkWaitForFences)win_wsi->vkWaitForFences;
        pfnWait(win_wsi->device, 1, &win_wsi->in_flight[current_frame], VK_TRUE, UINT64_MAX);

        int finished_slot = active_ring_slots[wid][current_frame];
        if (finished_slot != -1 && finished_slot != local_read) {
            atomic_fetch_and_explicit(&g_ring.locked_mask, ~(1 << finished_slot), memory_order_release);
        }
        active_ring_slots[wid][current_frame] = local_read;

        PFN_vkAcquireNextImageKHR pfnAcquire = (PFN_vkAcquireNextImageKHR)win_wsi->vkAcquireNextImageKHR;
        uint32_t img_idx;
        VkResult res = pfnAcquire(win_wsi->device, win_wsi->swapchain, 5000000, win_wsi->image_available[current_frame], VK_NULL_HANDLE, &img_idx);

        if (res == VK_TIMEOUT || res == VK_NOT_READY) {
            atomic_store_explicit(&g_render_busy[wid], 0, memory_order_release);
            SLEEP_MS(1);
            continue;
        }
        if (res == VK_ERROR_OUT_OF_DATE_KHR) {
            atomic_store_explicit(&g_engine.mailbox.window_resized[wid], 1, memory_order_release);
            atomic_store_explicit(&g_render_busy[wid], 0, memory_order_release);
            SLEEP_MS(10);
            continue;
        }

        PFN_vkResetFences pfnReset = (PFN_vkResetFences)win_wsi->vkResetFences;
        pfnReset(win_wsi->device, 1, &win_wsi->in_flight[current_frame]);

        p->swapchain_image = win_wsi->swapchain_images[img_idx];
        p->swapchain_view = win_wsi->swapchain_views[img_idx];

        vkResetCommandBuffer(cmd, 0);
        vx_record_commands(cmd, p, p->draw_queue, p->draw_count, win_wsi);

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

        atomic_store_explicit(&g_render_busy[wid], 0, memory_order_release);
        t_frame[wid] = (current_frame + 1) % 3;
    }

    printf("[C-CORE] Async Render Multiplexer gracefully terminated.\n");
    return NULL;
}

// [TRUNCATED: vx_thread_start]
EXPORT void vx_thread_start() {
    atomic_store_explicit(&g_render_thread_active, 1, memory_order_release);
    atomic_store_explicit(&g_transfer_thread_active, 1, memory_order_release);
    g_render_thread = vmath_thread_start(render_thread_loop, NULL);
    g_transfer_thread = vmath_thread_start(transfer_thread_loop, NULL);
}

// --- ENGINE LIFECYCLE & TEARDOWN ---
// [TRUNCATED: lua_co_overlord_loop]
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

EXPORT void vx_thread_kill() {
    atomic_store_explicit(&g_render_thread_active, 0, memory_order_release);
    atomic_store_explicit(&g_transfer_thread_active, 0, memory_order_release);

    vmath_thread_join(g_render_thread);
    vmath_thread_join(g_transfer_thread);

    atomic_store_explicit(&g_ring.ready_idx, -1, memory_order_release);
    atomic_store_explicit(&g_ring.locked_mask, 0, memory_order_release);

    for (int i = 0; i < MAX_WINDOWS; i++) {
        if (g_window_wsi[i].device) {
            vkDeviceWaitIdle(g_window_wsi[i].device);
        }
        if (g_render_cmd_pools[i]) {
            vkDestroyCommandPool(g_window_wsi[i].device, g_render_cmd_pools[i], NULL);
            g_render_cmd_pools[i] = VK_NULL_HANDLE;
        }
        if (g_transfer_cmd_pools[i]) {
            vkDestroyCommandPool(g_window_wsi[i].device, g_transfer_cmd_pools[i], NULL);
            g_transfer_cmd_pools[i] = VK_NULL_HANDLE;
        }
        if (g_transfer_fences[i]) {
            vkDestroyFence(g_window_wsi[i].device, g_transfer_fences[i], NULL);
            g_transfer_fences[i] = VK_NULL_HANDLE;
        }
    }
    printf("[C-CORE] Async Threads joined, Devices idled, Ring Purged, and Pools/Fences destroyed.\n");
}

int main(int argc, char** argv) {
    printf("[C-CORE] Booting Weaver Engine Host...\n");
    if (!glfwInit()) {
        printf("[C-FATAL] GLFW failed to initialize. Display Server missing?\n");
        return -1;
    }

    vx_init_mailbox();

    vmath_thread_t lua_thread = vmath_thread_start(lua_co_overlord_loop, NULL);

    GLFWwindow* windows[MAX_WINDOWS] = {NULL};

    while (vx_core_is_running()) {
        bool has_windows = false;
        for (int i = 0; i < MAX_WINDOWS; i++) {
            if (windows[i] != NULL) {
                has_windows = true;
                break;
            }
        }

        if (has_windows) glfwPollEvents();

        for (int id = 0; id < MAX_WINDOWS; id++) {
            int cmd = atomic_exchange_explicit(&g_engine.mailbox.glfw_cmd[id], CMD_IDLE, memory_order_acquire);

            if (cmd == CMD_BOOT_WINDOW && windows[id] == NULL) {
                for (int i = 0; i < MAX_WINDOWS; i++) {
                    if (atomic_load_explicit(&g_wsi_state[i], memory_order_acquire) == 1) {
                        atomic_store_explicit(&g_wsi_state[i], 0, memory_order_release);
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

                void* instance = atomic_load_explicit(&g_engine.mailbox.vk_instance[id], memory_order_acquire);

                // Enforce strict tenancy: No fallback to instance[0]
                if (instance != NULL) {
                    VkSurfaceKHR surface;
                    if (glfwCreateWindowSurface((VkInstance)instance, windows[id], NULL, &surface) == VK_SUCCESS) {
                        atomic_store_explicit(&g_engine.mailbox.vk_surface[id], (void*)surface, memory_order_release);
                        printf("[C-CORE] Tenant %d: Window & Surface Created safely!\n", id);
                    }
                } else {
                    printf("[C-ERROR] Tenant %d missing Vulkan instance! Window surface creation aborted.\n", id);
                }

                for (int i = 0; i < MAX_WINDOWS; i++) {
                    if (windows[i] != NULL && i != id) {
                        atomic_store_explicit(&g_wsi_state[i], 1, memory_order_release);
                    }
                }
            }
            else if (cmd == CMD_KILL_WINDOW && windows[id] != NULL) {
                atomic_store_explicit(&g_wsi_state[id], 0, memory_order_release);

                while (atomic_load_explicit(&g_render_busy[id], memory_order_acquire)) {
                    SLEEP_MS(1);
                }

                if (g_window_wsi[id].device) {
                    vkDeviceWaitIdle(g_window_wsi[id].device);

                    // NEW: Purge explicit tenant allocations
                    if (g_render_cmd_pools[id]) {
                        vkDestroyCommandPool(g_window_wsi[id].device, g_render_cmd_pools[id], NULL);
                        g_render_cmd_pools[id] = VK_NULL_HANDLE;
                    }
                    if (g_transfer_cmd_pools[id]) {
                        vkDestroyCommandPool(g_window_wsi[id].device, g_transfer_cmd_pools[id], NULL);
                        g_transfer_cmd_pools[id] = VK_NULL_HANDLE;
                    }
                    if (g_transfer_fences[id]) {
                        vkDestroyFence(g_window_wsi[id].device, g_transfer_fences[id], NULL);
                        g_transfer_fences[id] = VK_NULL_HANDLE;
                    }
                }

                glfwDestroyWindow(windows[id]);
                windows[id] = NULL;
                atomic_store_explicit(&g_engine.mailbox.vk_surface[id], NULL, memory_order_release);
                printf("[C-CORE] Tenant %d Window & Explicit Allocations Destroyed Safely.\n", id);
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

    for (int i = 0; i < MAX_WINDOWS; i++) {
        if (windows[i]) glfwDestroyWindow(windows[i]);
    }

    glfwTerminate();
    printf("[C-CORE] Clean Exit.\n");
    return 0;
}
