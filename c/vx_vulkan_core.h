#pragma once

/* ═══════════════════════════════════════════════════════════════════
   vx_vulkan_core.h — Vulkan instance-level utilities and
   validation layer injection/ejection.
   ═══════════════════════════════════════════════════════════════════ */

#include "vx_global_state.h"

#ifdef __cplusplus
extern "C" {
#endif

EXPORT void vx_sys_inject_validation(void* instance_ptr);
EXPORT void vx_sys_eject_validation(void* instance);

#ifdef __cplusplus
}
#endif
