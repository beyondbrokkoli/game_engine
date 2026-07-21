/*
   vx_vulkan_render.c — Render-thread multiplexer, async transfer
   overlord, command recording, and thread lifecycle management.
*/
#include "vx_vulkan_render.h"

/* 
   Tenant Allocation
*/

EXPORT void vx_stream_allocate_tenant(int wid, RenderThreadInit* wsi,
                                      uint32_t gfx_family,
                                      uint32_t transfer_family) {
    if (wid < 0 || wid >= MAX_WINDOWS) {
        printf("[C-ERROR] Blocked out-of-bounds tenant allocation: %d\n", wid);
        return;
    }
    if (!wsi || !wsi->device) {
        printf("[C-ERROR] Failed to allocate tenant %d: "
               "Invalid WSI or Device.\n", wid);
        return;
    }

    /* ── Render command pool + 3× command buffers */
    if (g_render_cmd_pools[wid] == VK_NULL_HANDLE) {
        VkCommandPoolCreateInfo r_pool_info = {
            .sType            = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags            = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = gfx_family
        };
        vkCreateCommandPool(wsi->device, &r_pool_info, NULL,
                            &g_render_cmd_pools[wid]);

        VkCommandBufferAllocateInfo r_alloc_info = {
            .sType              = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool        = g_render_cmd_pools[wid],
            .level              = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 3
        };
        vkAllocateCommandBuffers(wsi->device, &r_alloc_info,
                                 g_render_cmd_buffers[wid]);
        printf("[C-CORE] Tenant %d: Render pool and 3x command buffers "
               "explicitly allocated.\n", wid);
    }

    /* ── Transfer command pool + buffer + fence */
    if (g_transfer_cmd_pools[wid] == VK_NULL_HANDLE) {
        VkCommandPoolCreateInfo t_pool_info = {
            .sType            = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags            = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = transfer_family
        };
        vkCreateCommandPool(wsi->device, &t_pool_info, NULL,
                            &g_transfer_cmd_pools[wid]);

        VkCommandBufferAllocateInfo t_alloc_info = {
            .sType              = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool        = g_transfer_cmd_pools[wid],
            .level              = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1
        };
        vkAllocateCommandBuffers(wsi->device, &t_alloc_info,
                                 &g_transfer_cmd_buffers[wid]);

        VkFenceCreateInfo fence_info = {
            .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .flags = 1
        };
        vkCreateFence(wsi->device, &fence_info, NULL,
                      &g_transfer_fences[wid]);

        printf("[C-CORE] Tenant %d: Transfer pool, buffer, and fence "
               "explicitly allocated.\n", wid);
    }
}

/*
   Transfer Ring
*/

EXPORT void vx_transfer_setup(void) {
    // g_transfer_family_idx = q_family_index; // <-- DELETED

    for (int i = 0; i < TRANSFER_RING_SIZE; i++) {
        atomic_init(&g_transfer_ring[i].status, 0);
    }
}

EXPORT int vx_transfer_request(int win_id, uint64_t src, uint64_t dst,
                               uint64_t size, uint64_t t_sem,
                               uint64_t sig_val) {
    if (win_id < 0 || win_id >= MAX_WINDOWS) return 0;

    for (int i = 0; i < TRANSFER_RING_SIZE; i++) {
        int expected = 0;
        if (CXS(g_transfer_ring[i].status, expected, 1)) {
            g_transfer_ring[i].src_buffer       = src;
            g_transfer_ring[i].dst_buffer       = dst;
            g_transfer_ring[i].size             = size;
            g_transfer_ring[i].timeline_sem     = t_sem;
            g_transfer_ring[i].signal_val       = sig_val;
            g_transfer_ring[i].target_window_id = win_id;
            S(g_transfer_ring[i].status, 2);
            return 1;
        }
    }
    return 0;
}

/*
   Transfer Thread
*/

static THREAD_FUNC transfer_thread_loop(void* arg) {
    printf("[C-CORE] Async Transfer Overlord Online.\n");

    while (L(g_transfer_thread_active) && L(g_engine.mailbox.is_running)) {
        bool worked = false;

        for (int i = 0; i < TRANSFER_RING_SIZE; i++) {
            if (L(g_transfer_ring[i].status) == 2) {
                TransferJob* job = &g_transfer_ring[i];
                int wid = job->target_window_id;

                // 1. Lock the transfer state FIRST
                S(g_transfer_busy[wid], 1);

                // 2. Mid-job check: Validate tenant state hasn't collapsed
                if (wid < 0 || wid >= MAX_WINDOWS || L(g_wsi_state[wid]) == 0) {
                    S(job->status, 0);
                    S(g_transfer_busy[wid], 0); // Safely unlock and abort
                    continue;
                }

                RenderThreadInit* wsi = &g_window_wsi[wid];
                if (!wsi->device || g_transfer_cmd_pools[wid] == VK_NULL_HANDLE) {
                    S(job->status, 0);
                    S(g_transfer_busy[wid], 0); // Safely unlock and abort
                    continue;
                }

                VkCommandBuffer cmd   = g_transfer_cmd_buffers[wid];
                VkFence         fence = g_transfer_fences[wid];

                PFN_vkWaitForFences pfnWait   =
                    (PFN_vkWaitForFences)wsi->vkWaitForFences;
                PFN_vkResetFences   pfnReset  =
                    (PFN_vkResetFences)wsi->vkResetFences;
                PFN_vkQueueSubmit   pfnSubmit =
                    (PFN_vkQueueSubmit)wsi->vkQueueSubmit;

                VkResult res = pfnWait(wsi->device, 1, &fence, VK_TRUE, 2000000000);
                if (res == VK_TIMEOUT) {
                    printf("[C-FATAL] Tenant %d: GPU Transfer Hang detected!\n", wid);
                    S(job->status, 0);
                    S(g_wsi_state[wid], 0);
                    S(g_transfer_busy[wid], 0); // ALWAYS unlock before breaking!
                    break;
                }

                pfnReset(wsi->device, 1, &fence);
                vkResetCommandBuffer(cmd, 0);

                VkCommandBufferBeginInfo beginInfo = {
                    .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
                };
                vkBeginCommandBuffer(cmd, &beginInfo);

                VkBufferCopy copyRegion = {
                    .srcOffset = 0, .dstOffset = 0, .size = job->size
                };
                vkCmdCopyBuffer(cmd, (VkBuffer)job->src_buffer,
                                (VkBuffer)job->dst_buffer, 1, &copyRegion);
                vkEndCommandBuffer(cmd);

                VkSemaphore safe_timeline_semaphore =
                    (VkSemaphore)(uintptr_t)job->timeline_sem;

                VkTimelineSemaphoreSubmitInfo timelineInfo = {
                    .sType                  = 1000207003,
                    .signalSemaphoreValueCount = 1,
                    .pSignalSemaphoreValues = &job->signal_val
                };

                VkSubmitInfo submitInfo = {
                    .sType                = VK_STRUCTURE_TYPE_SUBMIT_INFO,
                    .pNext                = &timelineInfo,
                    .commandBufferCount   = 1,
                    .pCommandBuffers      = &cmd,
                    .signalSemaphoreCount = 1,
                    .pSignalSemaphores    = &safe_timeline_semaphore
                };

                pfnSubmit(wsi->transfer_queue, 1, &submitInfo, fence);
                pfnWait(wsi->device, 1, &fence, VK_TRUE, 2000000000);

                S(job->status, 0);
                S(g_transfer_busy[wid], 0); // 3. Clean exit unlock
                worked = true;
            }
        }

        if (!worked) SLEEP_MS(1);
    }

    printf("[C-CORE] Async Transfer Thread gracefully terminated.\n");
    return NULL;
}

/*
   Command Recording
*/

EXPORT void vx_record_commands(VkCommandBuffer cmd, RenderPacket* p,
                               DrawCommand* queue, uint32_t count,
                               RenderThreadInit* win_wsi) {
    if (p->width == 0 || p->height == 0) {
        return;
    }

    VkCommandBufferBeginInfo beginInfo = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
    };
    vkBeginCommandBuffer(cmd, &beginInfo);

    /* ── Pre-pass barriers */
    VkImageMemoryBarrier preBarriers[2] = {0};

    preBarriers[0].sType            = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    preBarriers[0].oldLayout        = VK_IMAGE_LAYOUT_UNDEFINED;
    preBarriers[0].newLayout        = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    preBarriers[0].image            = (VkImage)p->swapchain_image;
    preBarriers[0].subresourceRange = (VkImageSubresourceRange){
        VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    preBarriers[0].dstAccessMask    = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;

    preBarriers[1].sType            = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    preBarriers[1].oldLayout        = VK_IMAGE_LAYOUT_UNDEFINED;
    preBarriers[1].newLayout        = VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL;
    preBarriers[1].image            = (VkImage)p->depth_image;
    preBarriers[1].subresourceRange = (VkImageSubresourceRange){
        VK_IMAGE_ASPECT_DEPTH_BIT, 0, 1, 0, 1};
    preBarriers[1].dstAccessMask    = VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;

    vkCmdPipelineBarrier(cmd,
        VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT |
        VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
        0, 0, NULL, 0, NULL, 2, preBarriers);

    /* ── Dynamic Rendering Begin */
    PFN_vkCmdBeginRenderingKHR pfnBegin =
        (PFN_vkCmdBeginRenderingKHR)win_wsi->pfnBegin;
    PFN_vkCmdEndRenderingKHR pfnEnd =
        (PFN_vkCmdEndRenderingKHR)win_wsi->pfnEnd;

    VkRenderingAttachmentInfoKHR colorAttachment = {0};
    colorAttachment.sType       = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO_KHR;
    colorAttachment.imageView   = (VkImageView)p->swapchain_view;
    colorAttachment.imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    colorAttachment.loadOp      = VK_ATTACHMENT_LOAD_OP_CLEAR;
    colorAttachment.storeOp     = VK_ATTACHMENT_STORE_OP_STORE;
    colorAttachment.clearValue.color.float32[0] = 0.01f;
    colorAttachment.clearValue.color.float32[1] = 0.01f;
    colorAttachment.clearValue.color.float32[2] = 0.02f;
    colorAttachment.clearValue.color.float32[3] = 1.0f;

    VkRenderingAttachmentInfoKHR depthAttachment = {
        .sType       = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO_KHR,
        .imageView   = (VkImageView)p->depth_view,
        .imageLayout = VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL,
        .loadOp      = VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp     = VK_ATTACHMENT_STORE_OP_STORE,
        .clearValue.depthStencil = {1.0f, 0}
    };

    VkRenderingInfoKHR renderInfo = {
        .sType                = VK_STRUCTURE_TYPE_RENDERING_INFO_KHR,
        .renderArea.extent    = {p->width, p->height},
        .layerCount           = 1,
        .colorAttachmentCount = 1,
        .pColorAttachments    = &colorAttachment,
        .pDepthAttachment     = &depthAttachment
    };

    pfnBegin(cmd, &renderInfo);

    /* ── Viewport / Scissor */
    VkViewport viewport = {0.0f, 0.0f, (float)p->width, (float)p->height,
                           0.0f, 1.0f};
    VkRect2D   scissor  = {{0, 0}, {p->width, p->height}};
    vkCmdSetViewport(cmd, 0, 1, &viewport);
    vkCmdSetScissor(cmd, 0, 1, &scissor);

    /* ── Draw Calls */
    if (count > 0 && p->vertex_buffer != 0 && p->index_buffer != 0) {
        VkDeviceSize offset = 0;
        VkBuffer vbo = (VkBuffer)p->vertex_buffer;
        vkCmdBindVertexBuffers(cmd, 0, 1, &vbo, &offset);

        VkBuffer ibo = (VkBuffer)p->index_buffer;
        vkCmdBindIndexBuffer(cmd, ibo, 0, VK_INDEX_TYPE_UINT32);

        PFN_vkCmdSetCullModeEXT vkCmdSetCullModeEXT =
            (PFN_vkCmdSetCullModeEXT)win_wsi->pfnSetCullMode;
        PFN_vkCmdSetFrontFaceEXT vkCmdSetFrontFaceEXT =
            (PFN_vkCmdSetFrontFaceEXT)win_wsi->pfnSetFrontFace;
        PFN_vkCmdSetPrimitiveTopologyEXT vkCmdSetPrimitiveTopologyEXT =
            (PFN_vkCmdSetPrimitiveTopologyEXT)win_wsi->pfnSetPrimitiveTopology;
        PFN_vkCmdSetDepthTestEnableEXT vkCmdSetDepthTestEnableEXT =
            (PFN_vkCmdSetDepthTestEnableEXT)win_wsi->pfnSetDepthTestEnable;
        PFN_vkCmdSetDepthWriteEnableEXT vkCmdSetDepthWriteEnableEXT =
            (PFN_vkCmdSetDepthWriteEnableEXT)win_wsi->pfnSetDepthWriteEnable;
        PFN_vkCmdSetDepthCompareOpEXT vkCmdSetDepthCompareOpEXT =
            (PFN_vkCmdSetDepthCompareOpEXT)win_wsi->pfnSetDepthCompareOp;

        uint64_t current_pipeline   = 0;
        uint64_t current_descriptor = 0;

        #define MAX_DRAW_COMMANDS 1024
        uint32_t safe_count = count > MAX_DRAW_COMMANDS
                              ? MAX_DRAW_COMMANDS : count;

        for (uint32_t i = 0; i < safe_count; i++) {
            DrawCommand* draw = &queue[i];

            if (draw->pipeline_id != current_pipeline) {
                vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS,
                                  (VkPipeline)draw->pipeline_id);
                current_pipeline = draw->pipeline_id;
            }

            if (draw->descriptor_set != current_descriptor) {
                VkDescriptorSet dset = (VkDescriptorSet)draw->descriptor_set;
                vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS,
                    (VkPipelineLayout)p->gfx_layout,
                    0, 1, &dset, 0, NULL);
                current_descriptor = draw->descriptor_set;
            }

            VkRect2D dyn_scissor = {
                .offset = {(int32_t)draw->scissor_x,
                           (int32_t)draw->scissor_y},
                .extent = {(uint32_t)draw->scissor_w,
                           (uint32_t)draw->scissor_h}
            };
            vkCmdSetScissor(cmd, 0, 1, &dyn_scissor);

            vkCmdSetCullModeEXT(cmd,           draw->cull_mode);
            vkCmdSetFrontFaceEXT(cmd,          draw->front_face);
            vkCmdSetPrimitiveTopologyEXT(cmd,  draw->topology);
            vkCmdSetDepthTestEnableEXT(cmd,    draw->depth_test);
            vkCmdSetDepthWriteEnableEXT(cmd,   draw->depth_write);
            vkCmdSetDepthCompareOpEXT(cmd,     draw->depth_compare_op);

            vkCmdPushConstants(cmd,
                (VkPipelineLayout)p->gfx_layout,
                VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                draw->pc_offset, draw->pc_size,
                draw->push_constants + draw->pc_offset);

            vkCmdDrawIndexed(cmd, draw->index_count, draw->instance_count,
                             draw->first_index, draw->vertex_offset,
                             draw->first_instance);
        }
    }

    pfnEnd(cmd);

    /* ── Present barrier */
    VkImageMemoryBarrier presentBarrier = {
        .sType            = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .oldLayout        = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .newLayout        = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        .image            = (VkImage)p->swapchain_image,
        .subresourceRange = (VkImageSubresourceRange){
            VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
        .srcAccessMask    = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        .dstAccessMask    = 0
    };
    vkCmdPipelineBarrier(cmd,
        VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
        0, 0, NULL, 0, NULL, 1, &presentBarrier);

    vkEndCommandBuffer(cmd);
}

/*
   Render Thread Multiplexer
*/

static THREAD_FUNC render_thread_loop(void* arg) {
    printf("[C-CORE] Async Render Multiplexer Online.\n");

    uint32_t t_frame[MAX_WINDOWS] = {0};

    while (L(g_render_thread_active) && L(g_engine.mailbox.is_running)) {

        /* ── Handle pending WSI rebuilds */
        for (int w = 0; w < MAX_WINDOWS; w++) {
            int cmd = atomic_load_explicit(
                &g_engine.mailbox.tenants[w].glfw_cmd,
                memory_order_acquire);

            if (cmd == CMD_REBUILD_WSI) {
                // 1. Phase-Gate Spinlock: Wait for transfer thread to yield this tenant
                int timeout = 2000;
                int spin_count = 0;
                while (L(g_transfer_busy[w]) && timeout > 0) {
                    if (spin_count >= 2000) { timeout--; } // Only decrement on Tier 3
                    vx_spin_wait(&spin_count);
                }

                RenderThreadInit* wsi = &g_window_wsi[w];
                if (wsi->device) {
                    // THE SCALPEL: Drain only the queues bound to this specific tenant
                    if (wsi->queue) {
                        vkQueueWaitIdle(wsi->queue);
                    }
                    if (wsi->transfer_queue) {
                        vkQueueWaitIdle(wsi->transfer_queue);
                    }

                    if (g_render_cmd_pools[w]) {
                       vkResetCommandPool(wsi->device, g_render_cmd_pools[w], 0);
                    }

                    if (g_transfer_cmd_pools[w]) {
                        vkResetCommandPool(wsi->device, g_transfer_cmd_pools[w], 0);
                    }
                }
                S(g_wsi_state[w], 0);
                atomic_store_explicit(
                    &g_engine.mailbox.tenants[w].window_resized, 0,
                    memory_order_release);
                atomic_store_explicit(
                    &g_engine.mailbox.tenants[w].glfw_cmd, CMD_IDLE,
                    memory_order_release);
            }
        }

        /* ── Per-tenant frame submission */
        for (int wid = 0; wid < MAX_WINDOWS; wid++) {
            int ready          = L(g_ring.ready_idx[wid]);
            int local_read_val = L(g_ring.local_read[wid]);

            if (ready == -1 || ready == local_read_val) {
                continue;
            }

            int offset = wid * 4;
            int new_local_read;

            if (local_read_val == -1) {
                new_local_read = offset + 0;
            } else {
                int curr_local = local_read_val - offset;
                new_local_read = offset + ((curr_local + 1) % 4);
            }

            S(g_ring.local_read[wid], new_local_read);
            int read_idx = new_local_read;

            RenderPacket*     p       = &g_ring.packets[read_idx];
            S(g_render_busy[wid], 1);

            RenderThreadInit* win_wsi = &g_window_wsi[wid];
            uint32_t frame_slots = win_wsi->max_frames_in_flight > 0
                                   ? win_wsi->max_frames_in_flight : 3;
            if (frame_slots > 3) frame_slots = 3;

            uint32_t current_frame  = t_frame[wid] % frame_slots;
            int      finished_slot  = g_ring.active_ring_slots[wid][current_frame];

            if (finished_slot != -1 && finished_slot != read_idx) {
                FA(g_ring.locked_mask, ~(1u << finished_slot));
            }
            g_ring.active_ring_slots[wid][current_frame] = read_idx;

            if (L(g_wsi_state[wid]) == 0 ||
                p->width == 0 || p->height == 0) {
                goto frame_done;
            }

            VkCommandBuffer cmd_buf = g_render_cmd_buffers[wid][current_frame];

            PFN_vkWaitForFences pfnWait =
                (PFN_vkWaitForFences)win_wsi->vkWaitForFences;
            VkResult wait_res = pfnWait(win_wsi->device, 1,
                &win_wsi->in_flight[current_frame], VK_TRUE, 2000000000);

            if (wait_res == VK_TIMEOUT) {
                printf("[C-WARN] Tenant %d: GPU Fence Timeout "
                       "(CPU Starvation). Dropping frame to maintain "
                       "lock parity.\n", wid);
                goto frame_done;
            }

            PFN_vkAcquireNextImageKHR pfnAcquire =
                (PFN_vkAcquireNextImageKHR)win_wsi->vkAcquireNextImageKHR;
            uint32_t img_idx;
            VkResult res = pfnAcquire(win_wsi->device, win_wsi->swapchain,
                5000000, win_wsi->image_available[current_frame],
                VK_NULL_HANDLE, &img_idx);

            if (res == VK_TIMEOUT || res == VK_NOT_READY) {
                goto frame_done;
            }
            if (res == VK_ERROR_OUT_OF_DATE_KHR) {
                S(g_engine.mailbox.tenants[wid].window_resized, 1);
                SLEEP_MS(10);
                goto frame_done;
            }

            PFN_vkResetFences pfnReset =
                (PFN_vkResetFences)win_wsi->vkResetFences;
            pfnReset(win_wsi->device, 1,
                     &win_wsi->in_flight[current_frame]);

            p->swapchain_image = win_wsi->swapchain_images[img_idx];
            p->swapchain_view  = win_wsi->swapchain_views[img_idx];

            vkResetCommandBuffer(cmd_buf, 0);

            vx_record_commands(cmd_buf, p, p->draw_queue,
                               p->draw_count, win_wsi);

            VkPipelineStageFlags waitStage =
                VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;

            VkSubmitInfo submitInfo = {
                .sType                = VK_STRUCTURE_TYPE_SUBMIT_INFO,
                .waitSemaphoreCount   = 1,
                .pWaitSemaphores      = &win_wsi->image_available[current_frame],
                .pWaitDstStageMask    = &waitStage,
                .commandBufferCount   = 1,
                .pCommandBuffers      = &cmd_buf,
                .signalSemaphoreCount = 1,
                .pSignalSemaphores    = &win_wsi->render_finished[img_idx]
            };

            PFN_vkQueueSubmit pfnSubmit =
                (PFN_vkQueueSubmit)win_wsi->vkQueueSubmit;
            pfnSubmit(win_wsi->queue, 1, &submitInfo,
                      win_wsi->in_flight[current_frame]);

            VkPresentInfoKHR presentInfo = {
                .sType              = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
                .waitSemaphoreCount = 1,
                .pWaitSemaphores    = &win_wsi->render_finished[img_idx],
                .swapchainCount     = 1,
                .pSwapchains        = &win_wsi->swapchain,
                .pImageIndices      = &img_idx
            };

            PFN_vkQueuePresentKHR pfnPresent =
                (PFN_vkQueuePresentKHR)win_wsi->vkQueuePresentKHR;
            pfnPresent(win_wsi->queue, &presentInfo);

        frame_done:
            S(g_render_busy[wid], 0);
            t_frame[wid] = (current_frame + 1) % frame_slots;
        }

        SLEEP_MS(1);
    }

    printf("[C-CORE] Async Render Multiplexer gracefully terminated.\n");
    return NULL;
}

/*
   Thread Lifecycle
*/

EXPORT void vx_thread_start(void) {
    S(g_render_thread_active,   1);
    S(g_transfer_thread_active, 1);
    g_render_thread   = vmath_thread_start(render_thread_loop,   NULL);
    g_transfer_thread = vmath_thread_start(transfer_thread_loop, NULL);
}

EXPORT void vx_thread_kill(void) {
    S(g_render_thread_active,   0);
    S(g_transfer_thread_active, 0);

    vmath_thread_join(g_render_thread);
    vmath_thread_join(g_transfer_thread);

    for (int i = 0; i < MAX_WINDOWS; i++) {
        S(g_ring.ready_idx[i], -1);
    }
    S(g_ring.locked_mask, 0);

    for (int i = 0; i < MAX_WINDOWS; i++) {
        if (g_window_wsi[i].device) {
            vkDeviceWaitIdle(g_window_wsi[i].device);
        }
        if (g_render_cmd_pools[i]) {
            vkDestroyCommandPool(g_window_wsi[i].device,
                                 g_render_cmd_pools[i], NULL);
            g_render_cmd_pools[i] = VK_NULL_HANDLE;
        }
        if (g_transfer_cmd_pools[i]) {
            vkDestroyCommandPool(g_window_wsi[i].device,
                                 g_transfer_cmd_pools[i], NULL);
            g_transfer_cmd_pools[i] = VK_NULL_HANDLE;
        }
        if (g_transfer_fences[i]) {
            vkDestroyFence(g_window_wsi[i].device,
                           g_transfer_fences[i], NULL);
            g_transfer_fences[i] = VK_NULL_HANDLE;
        }
    }

    printf("[C-CORE] Async Threads joined, Devices idled, Ring Purged, "
           "and Pools/Fences destroyed.\n");
}
