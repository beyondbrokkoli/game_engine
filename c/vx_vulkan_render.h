#pragma once
#include "vx_global_state.h"

#ifdef __cplusplus
extern "C" {
#endif

// UPDATED
EXPORT void vx_stream_allocate_tenant(int wid, VulkanDeviceContext* dev_ctx,
                                      uint32_t gfx_family,
                                      uint32_t transfer_family);
EXPORT void vx_transfer_setup(void);
EXPORT int  vx_transfer_request(int win_id, uint64_t src, uint64_t dst,
                                uint64_t size, uint64_t t_sem,
                                uint64_t sig_val);
// UPDATED
EXPORT void vx_record_commands(VkCommandBuffer cmd, RenderPacket* p,
                               DrawCommand* queue, uint32_t count,
                               VulkanDeviceContext* dev_ctx,
                               uint64_t target_image, uint64_t target_view);
EXPORT void vx_thread_start(void);
EXPORT void vx_thread_kill(void);

#ifdef __cplusplus
}
#endif
