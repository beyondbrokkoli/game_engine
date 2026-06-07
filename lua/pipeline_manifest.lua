return {
    graphics = {
        geom = {
            vert = "bin/render_vert.spv",
            frag = "bin/render_frag.spv",
            topology = 3, cull_mode = 1, depth_test = 1, depth_write = 1, depth_compare_op = 3, blend_enable = 0
        },
        points = {
            vert = "bin/render_vert.spv",
            frag = "bin/render_frag.spv",
            topology = 0, cull_mode = 0, depth_test = 1, depth_write = 0, depth_compare_op = 3, blend_enable = 1
        }
    },
    compute = {
        -- We will hook the physics dummy shader in here later!
        -- { name = "entity_physics", file = "bin/physics.comp.spv" }
    }
}
