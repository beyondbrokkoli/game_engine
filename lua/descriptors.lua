local ffi = require("ffi")
local bit = require("bit")
local reg = require("registry_vk")
local config = require("config_engine")
local vk_desc, vk_struct, vk_shader = reg.vk_desc, reg.vk_struct, reg.vk_shader_stage

local Descriptors = {}

function Descriptors.Init(vk, device, master_gpu_buffer, palette_haven_buffer)
    print("[DESCRIPTORS] Wiring Master VRAM Arena & Palette Haven...")

    local STAGE_ALL = bit.bor(vk_shader.vert, vk_shader.frag)

    -- We now have 2 bindings
    local ssboBindings = ffi.new("VkDescriptorSetLayoutBinding[2]")

    -- Binding 0: The Lockstep Grid (ReBAR)
    ssboBindings[0].binding = 0
    ssboBindings[0].descriptorType = vk_desc.ssbo
    ssboBindings[0].descriptorCount = 1
    ssboBindings[0].stageFlags = STAGE_ALL
    ssboBindings[0].pImmutableSamplers = nil

    -- Binding 1: The Color Palette (Device Local Haven)
    ssboBindings[1].binding = 1
    ssboBindings[1].descriptorType = vk_desc.ssbo
    ssboBindings[1].descriptorCount = 1
    ssboBindings[1].stageFlags = STAGE_ALL
    ssboBindings[1].pImmutableSamplers = nil

    local layoutInfo = ffi.new("VkDescriptorSetLayoutCreateInfo")
    ffi.fill(layoutInfo, ffi.sizeof(layoutInfo))
    layoutInfo.sType = vk_struct.desc_set_layout_create
    layoutInfo.bindingCount = 2
    layoutInfo.pBindings = ssboBindings

    local pLayout = ffi.new("VkDescriptorSetLayout[1]")
    assert(vk.vkCreateDescriptorSetLayout(device, layoutInfo, nil, pLayout) == 0, "FATAL: Layout Creation Failed")
    local unifiedSetLayout = pLayout[0]

    -- 2. Push Constant Range (128-Byte Router)
    local pushRange = ffi.new("VkPushConstantRange[1]")
    pushRange[0].stageFlags = STAGE_ALL
    pushRange[0].offset = 0
    pushRange[0].size = config.cfg.pc_size

    -- 3. Pipeline Layout (Unified Router)
    local pipeLayoutInfo = ffi.new("VkPipelineLayoutCreateInfo")
    ffi.fill(pipeLayoutInfo, ffi.sizeof(pipeLayoutInfo))
    pipeLayoutInfo.sType = vk_struct.pipeline_layout_create
    pipeLayoutInfo.setLayoutCount = 1
    pipeLayoutInfo.pSetLayouts = ffi.new("VkDescriptorSetLayout[1]", {unifiedSetLayout})
    pipeLayoutInfo.pushConstantRangeCount = 1
    pipeLayoutInfo.pPushConstantRanges = pushRange

    local pPipeLayout = ffi.new("VkPipelineLayout[1]")
    assert(vk.vkCreatePipelineLayout(device, pipeLayoutInfo, nil, pPipeLayout) == 0, "FATAL: Pipeline Layout Failed")
    local unifiedPipelineLayout = pPipeLayout[0]

    -- 4. Descriptor Pool
    local poolSize = ffi.new("VkDescriptorPoolSize[1]")
    poolSize[0].type = vk_desc.ssbo
    poolSize[0].descriptorCount = 2 -- Update pool size

    local poolInfo = ffi.new("VkDescriptorPoolCreateInfo")
    ffi.fill(poolInfo, ffi.sizeof(poolInfo))
    poolInfo.sType = vk_struct.desc_pool_create
    poolInfo.maxSets = 1
    poolInfo.poolSizeCount = 1
    poolInfo.pPoolSizes = poolSize

    local pPool = ffi.new("VkDescriptorPool[1]")
    assert(vk.vkCreateDescriptorPool(device, poolInfo, nil, pPool) == 0)
    local descriptorPool = pPool[0]

    -- 5. Allocate and Update Descriptor Set
    local allocInfo = ffi.new("VkDescriptorSetAllocateInfo")
    ffi.fill(allocInfo, ffi.sizeof(allocInfo))
    allocInfo.sType = vk_struct.desc_set_alloc
    allocInfo.descriptorPool = descriptorPool
    allocInfo.descriptorSetCount = 1
    allocInfo.pSetLayouts = ffi.new("VkDescriptorSetLayout[1]", {unifiedSetLayout})

    local pSet = ffi.new("VkDescriptorSet[1]")
    assert(vk.vkAllocateDescriptorSets(device, allocInfo, pSet) == 0)

    local VK_WHOLE_SIZE = ffi.cast("uint64_t", -1)

    local bufInfos = ffi.new("VkDescriptorBufferInfo[2]")
    bufInfos[0].buffer = master_gpu_buffer
    bufInfos[0].offset = 0
    bufInfos[0].range = VK_WHOLE_SIZE

    bufInfos[1].buffer = palette_haven_buffer
    bufInfos[1].offset = 0
    bufInfos[1].range = VK_WHOLE_SIZE

    local writes = ffi.new("VkWriteDescriptorSet[2]")
    ffi.fill(writes, ffi.sizeof(writes))

    writes[0].sType = vk_struct.write_desc_set
    writes[0].dstSet = pSet[0]
    writes[0].dstBinding = 0
    writes[0].descriptorCount = 1
    writes[0].descriptorType = vk_desc.ssbo
    writes[0].pBufferInfo = bufInfos + 0

    writes[1].sType = vk_struct.write_desc_set
    writes[1].dstSet = pSet[0]
    writes[1].dstBinding = 1
    writes[1].descriptorCount = 1
    writes[1].descriptorType = vk_desc.ssbo
    writes[1].pBufferInfo = bufInfos + 1

    vk.vkUpdateDescriptorSets(device, 2, writes, 0, nil)

    print("[DESCRIPTORS] Unified Memory Matrix successfully bound!")
    return {
        setLayout = unifiedSetLayout,
        pipelineLayout = unifiedPipelineLayout,
        pool = descriptorPool,
        set0 = pSet[0]
    }
end

function Descriptors.Destroy(vk, device, desc_state)
    print("[TEARDOWN] Deconstructing Descriptors...")
    if not desc_state then return end
    if desc_state.pool then vk.vkDestroyDescriptorPool(device, desc_state.pool, nil) end
    if desc_state.setLayout then vk.vkDestroyDescriptorSetLayout(device, desc_state.setLayout, nil) end
    if desc_state.pipelineLayout then vk.vkDestroyPipelineLayout(device, desc_state.pipelineLayout, nil) end
end

return Descriptors
