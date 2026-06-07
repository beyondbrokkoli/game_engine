local ffi = require("ffi")

local reg = require("registry_vk")
local vk_struct, vk_shader = reg.vk_struct, reg.vk_shader_stage

local ComputePipeline = {}

local function ReadShaderFile(filename)
    local file = io.open(filename, "rb")
    assert(file, "FATAL: Failed to open shader file: " .. filename)
    local content = file:read("*a")
    file:close()
    return content
end

local function CreateShaderModule(vk, device, filename)
    local compCode = ReadShaderFile(filename)
    local compInfo = ffi.new("VkShaderModuleCreateInfo", {
        sType = vk_struct.shader_module_create,
        codeSize = string.len(compCode),
        pCode = ffi.cast("const uint32_t*", compCode)
    })
    local pMod = ffi.new("VkShaderModule[1]")
    assert(vk.vkCreateShaderModule(device, compInfo, nil, pMod) == 0, "Failed to load: " .. filename)
    return pMod[0]
end

function ComputePipeline.Init(vk, device, pipelineLayout, configs)
    local count = #configs
    print(string.format("[COMPUTE] Forging %d-Pass Compute Shaders...", count))

    if count == 0 then
        return { pipelineLayout = pipelineLayout, pipelines = {}, modules = {} }
    end

    local pipelineInfos = ffi.new("VkComputePipelineCreateInfo[?]", count)
    local modules = {}

    for i, cfg in ipairs(configs) do
        local mod = CreateShaderModule(vk, device, cfg.file)
        modules[i] = mod
        pipelineInfos[i-1].sType = vk_struct.compute_pipeline_create
        pipelineInfos[i-1].layout = pipelineLayout
        pipelineInfos[i-1].stage.sType = vk_struct.pipeline_shader_stage_create
        pipelineInfos[i-1].stage.stage = vk_shader.comp
        pipelineInfos[i-1].stage.module = mod
        pipelineInfos[i-1].stage.pName = "main"
    end

    local pPipelines = ffi.new("VkPipeline[?]", count)
    assert(vk.vkCreateComputePipelines(device, nil, count, pipelineInfos, nil, pPipelines) == 0)

    local state = { pipelineLayout = pipelineLayout, pipelines = {}, modules = {} }
    for i, cfg in ipairs(configs) do
        state.pipelines[cfg.name] = pPipelines[i-1]
        state.modules[cfg.name] = modules[i]
    end

    return state
end

function ComputePipeline.Destroy(vk, core_state, comp_state)
    print("[TEARDOWN] Dismantling Compute Graph Pipelines...")
    if not comp_state or not core_state then return end
    local device = core_state.device
    for _, pipe in pairs(comp_state.pipelines) do vk.vkDestroyPipeline(device, pipe, nil) end
    for _, mod in pairs(comp_state.modules) do vk.vkDestroyShaderModule(device, mod, nil) end
end

return ComputePipeline
