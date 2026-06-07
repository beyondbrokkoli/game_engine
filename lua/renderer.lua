local ffi = require("ffi")
local reg = require("registry_vk")
local vk_struct = reg.vk_struct

local Renderer = {}

-- LOBOTOMY: Pure mechanism, 'frames_in_flight' is injected by the Weaver
function Renderer.InitSync(vk, device, frames_in_flight)
    print("[RENDERER] Forging Synchronization Primitives...")

    local imageAvailable = ffi.new("VkSemaphore[?]", frames_in_flight)
    local renderFinished = ffi.new("VkSemaphore[?]", frames_in_flight)
    local inFlight = ffi.new("VkFence[?]", frames_in_flight)

    local semInfo = ffi.new("VkSemaphoreCreateInfo", { sType = vk_struct.semaphore_create })
    local fenceInfo = ffi.new("VkFenceCreateInfo", {
        sType = vk_struct.fence_create,
        flags = 1 -- VK_FENCE_CREATE_SIGNALED_BIT
    })

    for i = 0, frames_in_flight - 1 do
        assert(vk.vkCreateSemaphore(device, semInfo, nil, imageAvailable + i) == 0)
        assert(vk.vkCreateSemaphore(device, semInfo, nil, renderFinished + i) == 0)
        assert(vk.vkCreateFence(device, fenceInfo, nil, inFlight + i) == 0)
    end

    return {
        imageAvailable = imageAvailable,
        renderFinished = renderFinished,
        inFlight = inFlight
    }
end

function Renderer.Destroy(vk, device, sync, frames_in_flight)
    print("[TEARDOWN] Dismantling Renderer Sync Objects...")
    vk.vkDeviceWaitIdle(device)
    if not sync then return end

    for i = 0, frames_in_flight - 1 do
        vk.vkDestroySemaphore(device, sync.imageAvailable[i], nil)
        vk.vkDestroySemaphore(device, sync.renderFinished[i], nil)
        vk.vkDestroyFence(device, sync.inFlight[i], nil)
    end
end

return Renderer
