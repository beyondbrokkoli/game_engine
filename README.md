### 🌐 **Next-Gen Multiplayer Architecture**

The crown jewel of the new build is the `vx_net` C-backend and the Lua-driven matchmaker, enabling seamless competitive play without dedicated simulation servers.

* **Deterministic Rollback (Quantum Fractures):** The engine maintains a 128-tick ring buffer (`RollbackBuffer`). If a remote input desyncs from a local prediction, the engine triggers a "Quantum Fracture," instantly rewinding to the target tick, swapping in the historical AVX state arrays (`terrain_id`, `elevation`), and fast-forwarding the simulation back to the present.
* **Hybrid WAN/LAN Matchmaking:** The engine pings a remote VPS matchmaker but intelligently upgrades connections. It automatically detects ICE hairpins—if two clients share a public IP, it bypasses the external router and hot-swaps the crosshairs to local LAN coordinates.
* **STUN Hole-Punching:** Built-in NAT traversal via Coturn means no port forwarding is required for peer-to-peer WAN play.

---

### ⚙️ **Engine Core & Philosophy**

Weaver is designed to distill the components that power individual pipelines, strictly negating object-oriented impulses. Data is flat, contiguous, and ready for the GPU.

#### **1. The Async Overlord**

Vulkan rendering and memory transfers are isolated from the Lua VM. The C-Core manages an asynchronous render thread and a DMA transfer thread. Lua simply builds `PushConstants` and data packets, submits them to a lock-free ring buffer (`vx_stream_commit`), and moves on.

#### **2. Zero-Friction Shader Hotswapping**

Press `F5` to trigger a lock-free shader hotswap. Weaver will recompile GLSL to SPIR-V, dynamically rebuild the Vulkan pipelines, and seamlessly hot-reload them into the active render pass without dropping the simulation tick rate.

#### **3. SSoT (Single Source of Truth) Generation**

There is no desync between C structs, Lua FFI definitions, and GLSL uniform blocks. Weaver uses `registry_export.lua` to automatically parse a single Lua config and generate strictly aligned `std430` C-headers and GLSL variables during the build process.

#### **4. Pure SoA Memory**

The terrain grid is entirely data-driven. Instead of bloated `Tile` objects, Weaver allocates highly optimized parallel arrays directly into mapped memory blocks:

```lua
-- Forging the Data-Driven World
local total_tiles = cfg.world.map_width * cfg.world.map_height
memory.AllocateSoA("uint16_t", total_tiles, {"terrain_id", "elevation", "entity_id"})

```

---

### 🛠️ **Build & Deployment (The Laboratory)**

Weaver features a completely custom, zero-dependency build script written in Lua. It generates headers, compiles SPIR-V shaders, links the networking DLL/SO, and outputs the final headless boot executable.

**Requirements:**

* LuaJIT 2.1
* Vulkan SDK (1.4+)
* GCC / MinGW64

**Compilation:**

```bash
# Full Windows Build (Engine + Shaders + Netcode)
luajit scripts/build.lua win

# Full Linux Build
luajit scripts/build.lua linux

# Lightning-fast shader-only recompilation
luajit scripts/build.lua win shaders

```

**Execution:**

```bash
# Boot the C-Core worker
./bin/boot

```

*Upon boot, Weaver will connect to the STUN server, allocate VRAM arenas, and drop you into the Matchmaking terminal.*
