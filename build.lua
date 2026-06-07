local VULKAN_SDK_PATH = "C:/VulkanSDK/1.4.341.1"

-- Dictionary of all shaders required by the Weaver
local shaders = {
    { src = "glsl/render.vert",       dst = "bin/render_vert.spv" },
    { src = "glsl/render.frag",       dst = "bin/render_frag.spv" },
}

local function copy_file(source, destination)
    local infile = io.open(source, "rb")
    if not infile then
        print("  [ERROR] Could not find: " .. source)
        return false
    end
    local content = infile:read("*all")
    infile:close()

    local outfile = io.open(destination, "wb")
    if not outfile then
        print("  [ERROR] Could not write to: " .. destination)
        return false
    end
    outfile:write(content)
    outfile:close()
    return true
end

local function run_cmd(cmd)
    local res = os.execute(cmd)
    return (res == true or res == 0)
end

local function compile_engine(platform, build_target)
    print("   WEAVER LABORATORY BUILD AUTOMATION")
    print("   Target Platform: " .. string.upper(platform))

    if build_target == "shaders" then
        print("   Mode: SHADERS ONLY")
    else
        print("   Mode: FULL BUILD")
    end

    -- [1/4] Generate the Single Source of Truth
    print("\n[1/4] Generating C Header SSoT from Boilerplate...")
    local gen_cmd = [[luajit -e "package.path='./lua/?.lua;'..package.path; require('registry_export').generate('glsl/registry.glsl', 'c/shared_structs.h')"]]
    if not run_cmd(gen_cmd) then
        print("ERROR: Failed to generate SSoT files!")
        os.exit(1)
    end

    -- [2/4] Compile GLSL Shaders to SPIR-V
    print("\n[2/4] Compiling GLSL Shaders to SPIR-V...")
    -- On Windows, explicitly point to the Vulkan SDK. On Linux, rely on PATH.
    local glslc = (platform == "win") and (VULKAN_SDK_PATH .. "/Bin/glslc.exe") or "glslc"

    for _, sh in ipairs(shaders) do
        local cmd = string.format('%s %s -o %s', glslc, sh.src, sh.dst)
        if run_cmd(cmd) then
            print("  |- Compiled: " .. sh.dst)
        else
            print("  [ERROR] Failed to compile " .. sh.src)
            os.exit(1)
        end
    end

    -- EARLY EXIT: If we only want shaders, stop here to avoid locking OS binaries.
    if build_target == "shaders" then
        print("\n[SUCCESS] Shader build complete! Ready for hot-reload.\n")
        return
    end

    -- [3/4] Compile Networking Backend (vx_net.c)
    print("\n[3/4] Compiling Networking Backend (vx_net.c)...")
    local net_cmd = ""
    if platform == "linux" then
        -- Native CachyOS/Linux Shared Object
        net_cmd = "gcc -shared -fPIC -O3 -march=x86-64-v3 c/vx_net.c -o bin/libvx_net.so"
    elseif platform == "win" then
        -- Windows DLL (Requires linking ws2_32)
        net_cmd = "gcc -shared -O3 -march=x86-64-v3 c/vx_net.c -lws2_32 -o bin/vx_net.dll"
    end

    if not run_cmd(net_cmd) then
        print("ERROR: vx_net compilation failed!")
        os.exit(1)
    end
    print("  |- Successfully compiled Networking Library.")

    -- [4/4] Compile Host C-Core
    print("\n[4/4] Compiling Laboratory Host (main.c) ...")
    if platform == "linux" then
        local linux_build_main = "gcc c/main.c -O3 -march=x86-64-v3 -Wl,-E -I/usr/include/luajit-2.1 -lglfw -lvulkan -lluajit-5.1 -lm -lpthread -o bin/boot"
        if not run_cmd(linux_build_main) then
            print("ERROR: c/main.c compilation failed!")
            os.exit(1)
        end

    elseif platform == "win" then
        local LUA_INC = "C:/msys64/mingw64/include/luajit-2.1"
        local win_build_main = string.format(
            'gcc c/main.c -O3 -march=x86-64-v3 -I"%s" -I"%s/Include" -L"%s/Lib" -lws2_32 -lglfw3 -lvulkan-1 -lluajit-5.1 -lm -o bin/boot.exe',
            LUA_INC, VULKAN_SDK_PATH, VULKAN_SDK_PATH
        )
        if not run_cmd(win_build_main) then
            print("ERROR: boot.exe compilation failed!")
            os.exit(1)
        end

        print("\n[Packing Windows Dependencies (DLLs)...]")
        copy_file("C:/msys64/mingw64/bin/glfw3.dll", "bin/glfw3.dll")
        copy_file("C:/msys64/mingw64/bin/lua51.dll", "bin/lua51.dll")
        copy_file("C:/msys64/mingw64/bin/libwinpthread-1.dll", "bin/libwinpthread-1.dll") -- Add this
        print("  |- DLLs copied successfully.")
    else
        print("ERROR: Unknown platform. Use 'linux' or 'win'.")
        os.exit(1)
    end

    print("\n[SUCCESS] Laboratory build complete!\n")
end

-- EXECUTION
local target_platform = arg[1]
local build_target = arg[2]

if target_platform ~= "linux" and target_platform ~= "win" then
    print("  [FATAL] Missing or invalid target platform!")
    print("  Usage:   luajit build.lua <linux|win> [shaders]")
    print("  Example: luajit build.lua win")
    print("  Example: luajit build.lua win shaders")
    os.exit(1)
end

compile_engine(target_platform, build_target)
