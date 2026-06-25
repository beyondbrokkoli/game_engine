local ConfigSim = {}

-- Purely game-logic related. If you load 3D Swarm, this file is ignored.
ConfigSim.world = {
    map_width = 256,
    map_height = 256,
    spacing = 20.0,
    grid_cells = 262144
}

ConfigSim.world.offset_x = (ConfigSim.world.map_width * ConfigSim.world.spacing) / 2.0
ConfigSim.world.offset_z = (ConfigSim.world.map_height * ConfigSim.world.spacing) / 2.0

return ConfigSim
