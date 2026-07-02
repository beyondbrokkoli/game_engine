local ffi = require("ffi")
local reg = require("registry_vk")
local vk_struct = reg.vk_struct

local Renderer = {}

function Renderer.InitSync(vk, device, frames_in_flight)
    print("[RENDERER] Forging Synchronization Primitives...")

    -- [ARMOR PATCH]: Force a minimum of 3 primitives to survive the C-Core % 3 hardcode.
    local safe_frames = math.max(3, frames_in_flight)

    local imageAvailable = ffi.new("VkSemaphore[?]", safe_frames)
    local renderFinished = ffi.new("VkSemaphore[?]", safe_frames)
    local inFlight = ffi.new("VkFence[?]", safe_frames)

    local semInfo = ffi.new("VkSemaphoreCreateInfo", { sType = vk_struct.semaphore_create })
    local fenceInfo = ffi.new("VkFenceCreateInfo", {
        sType = vk_struct.fence_create,
        flags = 1 -- VK_FENCE_CREATE_SIGNALED_BIT
    })

    -- Initialize the full padded length
    for i = 0, safe_frames - 1 do
        assert(vk.vkCreateSemaphore(device, semInfo, nil, imageAvailable + i) == 0)
        assert(vk.vkCreateSemaphore(device, semInfo, nil, renderFinished + i) == 0)
        assert(vk.vkCreateFence(device, fenceInfo, nil, inFlight + i) == 0)
    end

    return {
        imageAvailable = imageAvailable,
        renderFinished = renderFinished,
        inFlight = inFlight,
        -- Pass safe_frames back so Destroy() cleans up the padded handles correctly
        safe_frames = safe_frames
    }
end

function Renderer.Destroy(vk, device, sync)
    print("[TEARDOWN] Dismantling Renderer Sync Objects...")

    -- DELETE THIS LINE: vk.vkDeviceWaitIdle(device)
    -- The C-core already idled the device safely on the Render Thread!

    if not sync then return end

    -- Use the padded count for safe teardown
    for i = 0, sync.safe_frames - 1 do
        vk.vkDestroySemaphore(device, sync.imageAvailable[i], nil)
        vk.vkDestroySemaphore(device, sync.renderFinished[i], nil)
        vk.vkDestroyFence(device, sync.inFlight[i], nil)
    end
end

return Renderer
