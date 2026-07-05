/*
   vx_vulkan_core.c — Debug messenger lifecycle and validation
   layer enforcement.
*/
#include "vx_vulkan_core.h"

/* ── File-Local State */
static VkDebugUtilsMessengerEXT g_debugMessenger = VK_NULL_HANDLE;

/* ── Debug Callback */

static VKAPI_ATTR VkBool32 VKAPI_CALL vulkan_debug_callback(
    VkDebugUtilsMessageSeverityFlagBitsEXT      messageSeverity,
    VkDebugUtilsMessageTypeFlagsEXT             messageType,
    const VkDebugUtilsMessengerCallbackDataEXT* pCallbackData,
    void*                                       pUserData)
{
    if (messageSeverity < VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) {
        return VK_FALSE;
    }
    printf("\n[VULKAN LAYER ENFORCER]\nSEVERITY: %d\nMESSAGE: %s\n\n",
           messageSeverity, pCallbackData->pMessage);
    fflush(stdout);
    return VK_FALSE;
}

/* ── Exports */

EXPORT void vx_sys_inject_validation(void* instance_ptr) {
    VkInstance instance = (VkInstance)instance_ptr;

    VkDebugUtilsMessengerCreateInfoEXT createInfo = {0};
    createInfo.sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT;
    createInfo.messageSeverity =
        VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT  |
        VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT  |
        VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
    createInfo.messageType =
        VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT      |
        VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT   |
        VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
    createInfo.pfnUserCallback = vulkan_debug_callback;

    PFN_vkCreateDebugUtilsMessengerEXT func =
        (PFN_vkCreateDebugUtilsMessengerEXT)
            glfwGetInstanceProcAddress(instance,
                                       "vkCreateDebugUtilsMessengerEXT");

    if (func != NULL) {
        func(instance, &createInfo, NULL, &g_debugMessenger);
        printf("[C-CORE] Validation Layer Enforcer Injected Successfully!\n");
    } else {
        printf("[C-FATAL] Failed to setup debug messenger "
               "(VK_EXT_debug_utils not found).\n");
    }
}

EXPORT void vx_sys_eject_validation(void* instance) {
    PFN_vkDestroyDebugUtilsMessengerEXT destroyFn =
        (PFN_vkDestroyDebugUtilsMessengerEXT)
            vkGetInstanceProcAddr((VkInstance)instance,
                                  "vkDestroyDebugUtilsMessengerEXT");
    if (destroyFn != NULL) {
        destroyFn((VkInstance)instance, g_debugMessenger, NULL);
    }
}
