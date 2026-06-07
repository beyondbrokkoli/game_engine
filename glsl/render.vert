#version 460
#extension GL_GOOGLE_include_directive : require

#include "shared.glsl"

layout(set = 0, binding = 0) readonly buffer MasterBuffer { 
    uint data[]; 
} vram;

layout(location = 0) out vec4 v_color;
layout(location = 1) out vec3 v_worldPos;
layout(location = 2) flat out uint v_shapeID;

// The base geometry spans from -1.0 to 1.0 (a total width of 2.0)
const vec3 SHAPE_LIBRARY[14] = vec3[](
    vec3(0.0, 1.5, 0.0),   
    vec3(0.0, -0.5, 0.0),  
    vec3(-1.0, 0.0, 1.0),  
    vec3( 1.0, 0.0, 1.0),  
    vec3( 1.0, 0.0, -1.0), 
    vec3(-1.0, 0.0, -1.0), 
    vec3(-1.0, -1.0, 1.0), 
    vec3( 1.0, -1.0, 1.0), 
    vec3( 1.0, 1.0, 1.0),  
    vec3(-1.0, 1.0, 1.0),  
    vec3(-1.0, -1.0, -1.0),
    vec3( 1.0, -1.0, -1.0),
    vec3( 1.0, 1.0, -1.0), 
    vec3(-1.0, 1.0, -1.0)  
);

void main() {
    uint base_idx = pc.aos_current_idx + (gl_InstanceIndex * 4);
    
    vec3 tile_pos = vec3(
        uintBitsToFloat(vram.data[base_idx + 0]),
        uintBitsToFloat(vram.data[base_idx + 1]),
        uintBitsToFloat(vram.data[base_idx + 2])
    );
    
    uint tile_data = vram.data[base_idx + 3];
    uint terrain_id = (tile_data >> 24) & 0xFF;

    vec3 local_pos = SHAPE_LIBRARY[gl_VertexIndex];

    // --- THE DIMENSIONAL SYNC ---
    // Multiply by WORLD_SPACING * 0.5 to make the 2.0-width base 
    // exactly span the full WORLD_SPACING grid cell.
    float visual_radius = WORLD_SPACING * 0.5;
    float visual_height = WORLD_SPACING * 0.25; // Keeps the isometric proportion
    
    local_pos *= vec3(visual_radius, visual_height, visual_radius);

    vec3 final_pos = tile_pos + local_pos;

    gl_Position = pc.viewProj * vec4(final_pos, 1.0);
    
    v_worldPos = final_pos;
    v_shapeID = pc.target_state;
    v_color = palette.colors[terrain_id];
    
    // Scale up the points in Point Cloud mode so they aren't microscopic
    gl_PointSize = clamp(WORLD_SPACING * 0.25, 1.0, 64.0); 
}
