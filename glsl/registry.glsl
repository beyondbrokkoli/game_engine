// AUTO-GENERATED SSoT - DO NOT MODIFY
#ifndef REGISTRY_GLSL
#define REGISTRY_GLSL

// --- CONSTANTS ---
const uint MODE_DUAL = 0U;
const uint MODE_GEOM = 1U;
const uint MODE_POINT_CLOUD_PASS = 88U;
const uint MODE_POINTS = 2U;
const uint WORLD_GRID_CELLS = 262144U;
const uint WORLD_MAP_HEIGHT = 256U;
const uint WORLD_MAP_WIDTH = 256U;
const uint WORLD_OFFSET_X = 2560U;
const uint WORLD_OFFSET_Z = 2560U;
const uint WORLD_SPACING = 20U;

// --- std430 SSBO DEFINITIONS ---
struct mat4_t {
    float m[16];
};

struct RtsTileInstance {
    float px;
    float py;
    float pz;
    uint tile_data;
};

struct PushConstants {
    mat4 viewProj;
    uint aos_current_idx;
    uint aos_prev_idx;
    float dt;
    float total_time;
    uint target_state;
    uint hover_idx;
    uint flags;
    // Engine injected pad: uint8_t[4]
};

#endif // REGISTRY_GLSL
