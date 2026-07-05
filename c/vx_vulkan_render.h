#pragma once

/*
   vx_vulkan_render.h — Execution loops, command recording,
   transfer ring, and thread lifecycle.
*/

#include "vx_global_state.h"

#ifdef __cplusplus
extern "C" {
#endif

EXPORT void vx_stream_allocate_tenant(int wid, RenderThreadInit* wsi,
                                      uint32_t gfx_family,
                                      uint32_t transfer_family);
EXPORT void vx_transfer_setup(uint32_t q_family_index);
EXPORT int  vx_transfer_request(int win_id, uint64_t src, uint64_t dst,
                                uint64_t size, uint64_t t_sem,
                                uint64_t sig_val);
EXPORT void vx_record_commands(VkCommandBuffer cmd, RenderPacket* p,
                               DrawCommand* queue, uint32_t count,
                               RenderThreadInit* win_wsi);
EXPORT void vx_thread_start(void);
EXPORT void vx_thread_kill(void);

#ifdef __cplusplus
}
#endif
