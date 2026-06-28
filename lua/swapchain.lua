local ffi = require("ffi")
local reg = require("registry_vk")
local vk_struct, vk_format, vk_image = reg.vk_struct, reg.vk_format, reg.vk_image
local vk_swapchain, vk_result = reg.vk_swapchain, reg.vk_result

local Swapchain = {}

function Swapchain.Init(vk, core_state, width, height, old_swapchain, explicit_surface)
    print("[SWAPCHAIN] Building the display chain...")
    -- [TRIFORCE PATCH]: Route to the specific tenant's surface
    local surface = explicit_surface or core_state.surface

    local surfaceCaps = ffi.new("VkSurfaceCapabilitiesKHR")
    vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(core_state.physicalDevice, surface, surfaceCaps)

    if surfaceCaps.maxImageExtent.width == 0 or surfaceCaps.maxImageExtent.height == 0 then
        print("[SWAPCHAIN WARNING] Surface extent is 0x0 (Minimized/Transitioning). Aborting rebuild.")
        return nil
    end

    local actualExtent = surfaceCaps.currentExtent
    if actualExtent.width ~= 4294967295 then
        width = math.max(1, tonumber(actualExtent.width))
        height = math.max(1, tonumber(actualExtent.height))
    else
        width = math.max(1, math.max(tonumber(surfaceCaps.minImageExtent.width), math.min(tonumber(surfaceCaps.maxImageExtent.width), width)))
        height = math.max(1, math.max(tonumber(surfaceCaps.minImageExtent.height), math.min(tonumber(surfaceCaps.maxImageExtent.height), height)))
    end

    local swapchainInfo = ffi.new("VkSwapchainCreateInfoKHR")
    ffi.fill(swapchainInfo, ffi.sizeof(swapchainInfo))
    swapchainInfo.sType = vk_struct.swapchain_create
    swapchainInfo.surface = surface
    swapchainInfo.oldSwapchain = old_swapchain or ffi.cast("VkSwapchainKHR", 0)
    swapchainInfo.minImageCount = surfaceCaps.minImageCount + 1
    swapchainInfo.imageFormat = vk_format.b8g8r8a8_srgb
    swapchainInfo.imageColorSpace = vk_swapchain.color_space_srgb_nonlinear
    swapchainInfo.imageExtent.width = width
    swapchainInfo.imageExtent.height = height
    swapchainInfo.imageArrayLayers = 1
    swapchainInfo.imageUsage = vk_image.usage_color_attachment
    swapchainInfo.preTransform = surfaceCaps.currentTransform
    swapchainInfo.compositeAlpha = vk_swapchain.composite_alpha_opaque
    swapchainInfo.presentMode = vk_swapchain.present_mode_fifo
    swapchainInfo.clipped = 1

    local pSwapchain = ffi.new("VkSwapchainKHR[1]")
    local res = vk.vkCreateSwapchainKHR(core_state.device, swapchainInfo, nil, pSwapchain)

    if res == vk_result.error_out_of_date then
        print("[SWAPCHAIN WARNING] Surface volatile. Retrying next frame...")
        return nil
    end
    assert(res == vk_result.success, "FATAL: Failed to create Swapchain! Error: " .. tonumber(res))
    local swapchain = pSwapchain[0]

    local pImageCount = ffi.new("uint32_t[1]")
    vk.vkGetSwapchainImagesKHR(core_state.device, swapchain, pImageCount, nil)
    local imageCount = pImageCount[0]

    local images = ffi.new("VkImage[?]", imageCount)
    vk.vkGetSwapchainImagesKHR(core_state.device, swapchain, pImageCount, images)

    local imageViews = ffi.new("VkImageView[?]", imageCount)

    for i = 0, imageCount - 1 do
        local viewInfo = ffi.new("VkImageViewCreateInfo")
        ffi.fill(viewInfo, ffi.sizeof(viewInfo))

        viewInfo.sType = vk_struct.image_view_create
        viewInfo.image = images[i]
        viewInfo.viewType = vk_image.view_type_2d
        viewInfo.format = vk_format.b8g8r8a8_srgb
        viewInfo.subresourceRange.aspectMask = vk_image.aspect_color
        viewInfo.subresourceRange.levelCount = 1
        viewInfo.subresourceRange.layerCount = 1

        assert(vk.vkCreateImageView(core_state.device, viewInfo, nil, imageViews + i) == vk_result.success)
    end

    print("[SWAPCHAIN] Created successfully with " .. tonumber(imageCount) .. " images!")

    return {
        handle = swapchain,
        images = images,
        imageViews = imageViews,
        imageCount = imageCount,
        format = vk_format.b8g8r8a8_srgb,
        extent = { width = width, height = height }
    }
end

function Swapchain.Destroy(vk, core_state, sc_state)
    print("[TEARDOWN] Destroying Swapchain & Image Views...")
    if not sc_state then return end

    for i = 0, sc_state.imageCount - 1 do
        if sc_state.imageViews[i] ~= nil then
            vk.vkDestroyImageView(core_state.device, sc_state.imageViews[i], nil)
        end
    end

    if sc_state.handle ~= nil then
        vk.vkDestroySwapchainKHR(core_state.device, sc_state.handle, nil)
    end
end

return Swapchain
