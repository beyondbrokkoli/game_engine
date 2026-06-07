#ifndef SHARED_GLSL
#define SHARED_GLSL

#extension GL_GOOGLE_include_directive : require
#include "registry.glsl"

layout(push_constant) uniform PushBlock {
    PushConstants pc;
};

layout(std430, binding = 0) readonly buffer MasterGpuArena {
    RtsTileInstance tiles[];
} master_grid;

layout(std430, binding = 1) readonly buffer PaletteHaven {
    vec4 colors[];
} palette;

#endif
