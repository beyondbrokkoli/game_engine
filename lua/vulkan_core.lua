local ffi = require("ffi")
local bit = require("bit")
require("vulkan_headers")

local reg = require("registry_vk")
local EngineAPI = require("engine_api")
local vk_struct = reg.vk_struct
local vk_queue = reg.vk_queue

local vk
local success, lib = pcall(ffi.load, "vulkan-1")
if not success then success, lib = pcall(ffi.load, "vulkan") end
if not success then success, lib = pcall(ffi.load, "libvulkan.so.1") end
assert(success, "FATAL: Could not load Vulkan!")
vk = lib

local core = {}

function core.create_instance(req_extensions, gfx_cfg)
    print("[LUA] Initializing Vulkan Core (Instance Generation)...")
    local pCount = ffi.new("uint32_t[1]")
    local glfwExtensions = EngineAPI.get_glfw_extensions(pCount)
    local exts_count = pCount[0]
    local total_exts = exts_count + #req_extensions

    if gfx_cfg.use_validation == 1 then total_exts = total_exts + 1 end

    local instanceExtensions = ffi.new("const char*[?]", total_exts)
    for i = 0, exts_count - 1 do instanceExtensions[i] = glfwExtensions[i] end

    local ext_idx = exts_count
    for _, ext in ipairs(req_extensions) do
        instanceExtensions[ext_idx] = ext
        ext_idx = ext_idx + 1
    end

    local validationLayers = nil
    local layerCount = 0
    if gfx_cfg.use_validation == 1 then
        instanceExtensions[ext_idx] = "VK_EXT_debug_utils"
        validationLayers = ffi.new("const char*[1]", {"VK_LAYER_KHRONOS_validation"})
        layerCount = 1
        print("[LUA] Validation Layers ENABLED.")
    else
        print("[LUA] Validation Layers DISABLED. Running raw.")
    end

    local appInfo = ffi.new("VkApplicationInfo", {
        sType = vk_struct.app_info,
        pApplicationName = "VX Engine Runtime",
        apiVersion = gfx_cfg.vk_api_version
    })

    local createInfo = ffi.new("VkInstanceCreateInfo", {
        sType = vk_struct.instance_create,
        pApplicationInfo = appInfo,
        enabledExtensionCount = total_exts,
        ppEnabledExtensionNames = instanceExtensions,
        enabledLayerCount = layerCount,
        ppEnabledLayerNames = validationLayers
    })

    local pInstance = ffi.new("VkInstance[1]")
    assert(vk.vkCreateInstance(createInfo, nil, pInstance) == 0, "FATAL: vkCreateInstance failed!")

    local instance = pInstance[0]
    if gfx_cfg.use_validation == 1 then EngineAPI.inject_validation(instance) end

    return { vk = vk, instance = instance }
end

function core.finalize_device_and_swapchain(vk_state, surface_ptr, req_extensions)
    print("[LUA] Resuming Vulkan Setup. Finalizing Logical Device...")
    local vk = vk_state.vk
    local instance = vk_state.instance

    local pDeviceCount = ffi.new("uint32_t[1]")
    vk.vkEnumeratePhysicalDevices(instance, pDeviceCount, nil)
    local pDevices = ffi.new("VkPhysicalDevice[?]", pDeviceCount[0])
    vk.vkEnumeratePhysicalDevices(instance, pDeviceCount, pDevices)
    local physicalDevice = pDevices[0]
    vk_state.physicalDevice = physicalDevice

    local pQueueFamilyCount = ffi.new("uint32_t[1]")
    vk.vkGetPhysicalDeviceQueueFamilyProperties(physicalDevice, pQueueFamilyCount, nil)
    local queueFamilies = ffi.new("VkQueueFamilyProperties[?]", pQueueFamilyCount[0])
    vk.vkGetPhysicalDeviceQueueFamilyProperties(physicalDevice, pQueueFamilyCount, queueFamilies)

    local qIndex = -1
    local tIndex = -1

    for i = 0, pQueueFamilyCount[0] - 1 do
        local flags = queueFamilies[i].queueFlags
        if bit.band(flags, vk_queue.graphics) ~= 0 and qIndex == -1 then
            qIndex = i
        end
        if bit.band(flags, vk_queue.transfer) ~= 0 and bit.band(flags, vk_queue.graphics) == 0 then
            tIndex = i
        end
    end

    if tIndex == -1 then
        print("[LUA] No dedicated Transfer queue found. Sharing Graphics queue.")
        tIndex = qIndex
    else
        print("[LUA] Dedicated Transfer queue located at index: " .. tIndex)
    end

    vk_state.qIndex = qIndex
    vk_state.tIndex = tIndex

    local queuePriority = ffi.new("float[1]", 1.0)
    local queueCount = (qIndex == tIndex) and 1 or 2
    local queueCreateInfos = ffi.new("VkDeviceQueueCreateInfo[2]")

    queueCreateInfos[0].sType = vk_struct.device_queue_create
    queueCreateInfos[0].queueFamilyIndex = qIndex
    queueCreateInfos[0].queueCount = 1
    queueCreateInfos[0].pQueuePriorities = queuePriority

    if queueCount == 2 then
        queueCreateInfos[1].sType = vk_struct.device_queue_create
        queueCreateInfos[1].queueFamilyIndex = tIndex
        queueCreateInfos[1].queueCount = 1
        queueCreateInfos[1].pQueuePriorities = queuePriority
    end

    local ext_count = #req_extensions
    local deviceExtensions = ffi.new("const char*[?]", ext_count)
    for i, ext in ipairs(req_extensions) do deviceExtensions[i-1] = ext end

    local dynamicRendering = ffi.new("VkPhysicalDeviceDynamicRenderingFeatures")
    ffi.fill(dynamicRendering, ffi.sizeof(dynamicRendering))
    dynamicRendering.sType = vk_struct.dynamic_rendering_features
    dynamicRendering.dynamicRendering = 1

    local extDynamicState = ffi.new("VkPhysicalDeviceExtendedDynamicStateFeaturesEXT")
    ffi.fill(extDynamicState, ffi.sizeof(extDynamicState))
    extDynamicState.sType = vk_struct.extended_dynamic_state_features
    extDynamicState.pNext = dynamicRendering
    extDynamicState.extendedDynamicState = 1

    local extDynamicState2 = ffi.new("VkPhysicalDeviceExtendedDynamicState2FeaturesEXT")
    ffi.fill(extDynamicState2, ffi.sizeof(extDynamicState2))
    extDynamicState2.sType = vk_struct.extended_dynamic_state2_features
    extDynamicState2.pNext = extDynamicState
    extDynamicState2.extendedDynamicState2 = 1

    local timelineFeat = ffi.new("VkPhysicalDeviceTimelineSemaphoreFeatures")
    ffi.fill(timelineFeat, ffi.sizeof(timelineFeat))
    timelineFeat.sType = 1000207000 
    timelineFeat.timelineSemaphore = 1
    timelineFeat.pNext = extDynamicState2

    local deviceFeatures = ffi.new("VkPhysicalDeviceFeatures")
    ffi.fill(deviceFeatures, ffi.sizeof(deviceFeatures))
    deviceFeatures.largePoints = 1
    deviceFeatures.independentBlend = 1

    local deviceCreateInfo = ffi.new("VkDeviceCreateInfo")
    ffi.fill(deviceCreateInfo, ffi.sizeof(deviceCreateInfo))
    deviceCreateInfo.sType = vk_struct.device_create
    deviceCreateInfo.pNext = timelineFeat

    deviceCreateInfo.queueCreateInfoCount = queueCount;
    deviceCreateInfo.pQueueCreateInfos = queueCreateInfos;
    deviceCreateInfo.enabledExtensionCount = ext_count;

    deviceCreateInfo.ppEnabledExtensionNames = deviceExtensions
    deviceCreateInfo.pEnabledFeatures = deviceFeatures

    local pDevice = ffi.new("VkDevice[1]")
    assert(vk.vkCreateDevice(physicalDevice, deviceCreateInfo, nil, pDevice) == 0, "FATAL: vkCreateDevice failed!")

    vk_state.device = pDevice[0]
    print("[LUA] Logical Device Created!")

    local pQueue = ffi.new("VkQueue[1]")
    vk.vkGetDeviceQueue(vk_state.device, qIndex, 0, pQueue)
    vk_state.queue = pQueue[0]

    local pTransferQueue = ffi.new("VkQueue[1]")
    vk.vkGetDeviceQueue(vk_state.device, tIndex, 0, pTransferQueue)
    vk_state.transferQueue = pTransferQueue[0]

    return vk_state
end

function core.Destroy(vk_state, gfx_cfg)
    print("[TEARDOWN] Shutting down Vulkan Core...")
    local vk = vk_state.vk
    if vk_state.device ~= nil then vk.vkDestroyDevice(vk_state.device, nil) end
    -- [DELETED]: The legacy surface destroy is gone.
    if vk_state.instance ~= nil then
        if gfx_cfg.use_validation == 1 then EngineAPI.eject_validation(vk_state.instance) end
        vk.vkDestroyInstance(vk_state.instance, nil)
    end
end

return core
