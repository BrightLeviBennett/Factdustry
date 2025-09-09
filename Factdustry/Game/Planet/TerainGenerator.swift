////
////  TerainGenerator.swift
////  Factdustry
////
////  Created by Bright on 5/23/25.
////
//
///*import SwiftUI
//import GameplayKit
//
//enum ErekirTerrain: Int, CaseIterable {
//    case redStone = 0
//    case darkSand = 1
//    case metalFloor = 2
//    case crystalFloor = 3
//    case roughRhyolite = 4
//    case redIce = 5
//    case berylliumWall = 6
//    case carbonWall = 7
//    case regolith = 8
//    case void = 9  // Add void terrain for areas outside the map
//    
//    var baseColor: Color {
//        switch self {
//        case .redStone: return Color(red: 0.7, green: 0.35, blue: 0.25)
//        case .darkSand: return Color(red: 0.6, green: 0.4, blue: 0.3)
//        case .metalFloor: return Color(red: 0.5, green: 0.45, blue: 0.4)
//        case .crystalFloor: return Color(red: 0.6, green: 0.5, blue: 0.7)
//        case .roughRhyolite: return Color(red: 0.8, green: 0.5, blue: 0.35)
//        case .redIce: return Color(red: 0.6, green: 0.4, blue: 0.5)
//        case .berylliumWall: return Color(red: 0.45, green: 0.4, blue: 0.35)
//        case .carbonWall: return Color(red: 0.3, green: 0.25, blue: 0.2)
//        case .regolith: return Color(red: 0.9, green: 0.6, blue: 0.4)
//        case .void: return Color.black
//        }
//    }
//    
//    var shadowColor: Color {
//        switch self {
//        case .redStone: return Color(red: 0.5, green: 0.25, blue: 0.15)
//        case .darkSand: return Color(red: 0.4, green: 0.25, blue: 0.15)
//        case .metalFloor: return Color(red: 0.3, green: 0.25, blue: 0.2)
//        case .crystalFloor: return Color(red: 0.4, green: 0.3, blue: 0.5)
//        case .roughRhyolite: return Color(red: 0.6, green: 0.3, blue: 0.2)
//        case .redIce: return Color(red: 0.4, green: 0.2, blue: 0.3)
//        case .berylliumWall: return Color(red: 0.25, green: 0.2, blue: 0.15)
//        case .carbonWall: return Color(red: 0.15, green: 0.1, blue: 0.05)
//        case .regolith: return Color(red: 0.7, green: 0.4, blue: 0.25)
//        case .void: return Color.black
//        }
//    }
//    
//    var highlightColor: Color {
//        switch self {
//        case .redStone: return Color(red: 0.85, green: 0.45, blue: 0.35)
//        case .darkSand: return Color(red: 0.75, green: 0.5, blue: 0.4)
//        case .metalFloor: return Color(red: 0.65, green: 0.55, blue: 0.5)
//        case .crystalFloor: return Color(red: 0.75, green: 0.65, blue: 0.85)
//        case .roughRhyolite: return Color(red: 0.95, green: 0.65, blue: 0.45)
//        case .redIce: return Color(red: 0.75, green: 0.5, blue: 0.65)
//        case .berylliumWall: return Color(red: 0.6, green: 0.55, blue: 0.5)
//        case .carbonWall: return Color(red: 0.5, green: 0.4, blue: 0.35)
//        case .regolith: return Color(red: 1.0, green: 0.75, blue: 0.55)
//        case .void: return Color.black
//        }
//    }
//    
//    var isWall: Bool {
//        return self == .berylliumWall || self == .carbonWall
//    }
//    
//    var isVoid: Bool {
//        return self == .void
//    }
//    
//    var imageName: String {
//        switch self {
//        case .redStone: return "Tile_RedStone"
//        case .darkSand: return "Tile_DarkSand"
//        case .metalFloor: return "Tile_MetalFloor"
//        case .crystalFloor: return "Tile_CrystalFloor"
//        case .roughRhyolite: return "Tile_RoughRhyolite"
//        case .redIce: return "Tile_RedIce"
//        case .berylliumWall: return "Tile_BerylliumWall"
//        case .carbonWall: return "Tile_CarbonWall"
//        case .regolith: return "Tile_Regolith"
//        case .void: return "Tile_Void"
//        }
//    }
//}
//
//// MARK: - Biome Definition
//struct TerrainBiome {
//    let primaryTerrain: ErekirTerrain
//    let secondaryTerrains: [ErekirTerrain]
//    let wallDensity: Double
//    let resourceTypes: [ErekirResource]
//    let featureTypes: [ErekirFeature]
//}
//
//// MARK: - Erekir Resources and Features
//enum ErekirResource: CaseIterable {
//    case beryllium
//    case tungsten
//    case thorium
//    case oxide
//    
//    var baseColor: Color {
//        switch self {
//        case .beryllium: return Color(red: 0.4, green: 0.6, blue: 0.4)
//        case .tungsten: return Color(red: 0.5, green: 0.5, blue: 0.6)
//        case .thorium: return Color(red: 0.6, green: 0.3, blue: 0.6)
//        case .oxide: return Color(red: 0.7, green: 0.4, blue: 0.2)
//        }
//    }
//    
//    var shadowColor: Color {
//        switch self {
//        case .beryllium: return Color(red: 0.2, green: 0.4, blue: 0.2)
//        case .tungsten: return Color(red: 0.3, green: 0.3, blue: 0.4)
//        case .thorium: return Color(red: 0.4, green: 0.15, blue: 0.4)
//        case .oxide: return Color(red: 0.5, green: 0.2, blue: 0.1)
//        }
//    }
//    
//    var spawnChance: Double {
//        switch self {
//        case .beryllium: return 0.08
//        case .tungsten: return 0.06
//        case .thorium: return 0.04
//        case .oxide: return 0.05
//        }
//    }
//    
//    var imageName: String {
//        switch self {
//        case .beryllium: return "Resource_Beryllium"
//        case .tungsten: return "Resource_Tungsten"
//        case .thorium: return "Resource_Thorium"
//        case .oxide: return "Resource_Oxide"
//        }
//    }
//}
//
//enum ErekirFeature: CaseIterable {
//    case vent
//    case geyser
//    
//    var spawnChance: Double {
//        switch self {
//        case .vent: return 0.015
//        case .geyser: return 0.025
//        }
//    }
//    
//    var imageName: String {
//        switch self {
//        case .vent: return "Tile_Vent"
//        case .geyser: return "Tile_Geyser"
//        }
//    }
//}
//
//// MARK: - Tile Data
//struct ErekirTile {
//    let terrain: ErekirTerrain
//    var resource: ErekirResource?
//    var feature: ErekirFeature?
//    let variant: Int
//    let x: Int
//    let y: Int
//    var biomeMask: Double = 0.0  // For smooth biome transitions
//    var elevation: Double = 0.0  // Store elevation for easier access
//}
//
//// MARK: - Enhanced Terrain Generator
//class ErekirTerrainGenerator: ObservableObject {
//    @Published var tiles: [[ErekirTile]] = []
//    @Published var isGenerating = false
//    
//    // Multiple noise layers for different features
//    private let continentalNoise: GKNoise      // Large-scale landmasses
//    private let erosionNoise: GKNoise          // Erosion patterns
//    private let peaksValleysNoise: GKNoise     // Mountain/valley features
//    private let temperatureNoise: GKNoise      // Temperature zones
//    private let moistureNoise: GKNoise         // Moisture/humidity
//    private let caveNoise: GKNoise             // Cave/wall generation
//    private let resourceNoise: GKNoise         // Resource vein generation
//    private let detailNoise: GKNoise           // Fine detail variation
//    private let shorelineNoise: GKNoise        // For organic coastlines
//    
//    // Biome definitions
//    private let biomes: [TerrainBiome]
//    
//    // Terrain generation parameters - Cellular Automata approach
//    private let landProbability: Double = 0.45  // Base chance for land vs void
//    private let islandSeeds: Int = 4            // Number of island centers
//    private let cellularIterations: Int = 3     // Iterations to smooth coastlines
//    
//    init() {
//        // Initialize noise with higher frequencies for more varied, smaller features
//        let continentalSource = GKPerlinNoiseSource(frequency: 0.012, octaveCount: 4, persistence: 0.6, lacunarity: 2.0, seed: 1)
//        let erosionSource = GKPerlinNoiseSource(frequency: 0.025, octaveCount: 2, persistence: 0.4, lacunarity: 2.0, seed: 2)
//        let peaksSource = GKPerlinNoiseSource(frequency: 0.035, octaveCount: 3, persistence: 0.6, lacunarity: 2.0, seed: 3)
//        let tempSource = GKPerlinNoiseSource(frequency: 0.02, octaveCount: 2, persistence: 0.5, lacunarity: 2.0, seed: 4)
//        let moistSource = GKPerlinNoiseSource(frequency: 0.03, octaveCount: 3, persistence: 0.4, lacunarity: 2.0, seed: 5)
//        let caveSource = GKPerlinNoiseSource(frequency: 0.045, octaveCount: 2, persistence: 0.3, lacunarity: 2.0, seed: 6)
//        let resourceSource = GKPerlinNoiseSource(frequency: 0.04, octaveCount: 2, persistence: 0.3, lacunarity: 2.0, seed: 7)
//        let detailSource = GKPerlinNoiseSource(frequency: 0.2, octaveCount: 1, persistence: 0.2, lacunarity: 2.0, seed: 8)
//        let shorelineSource = GKPerlinNoiseSource(frequency: 0.06, octaveCount: 3, persistence: 0.5, lacunarity: 2.0, seed: 9)
//        
//        self.continentalNoise = GKNoise(continentalSource)
//        self.erosionNoise = GKNoise(erosionSource)
//        self.peaksValleysNoise = GKNoise(peaksSource)
//        self.temperatureNoise = GKNoise(tempSource)
//        self.moistureNoise = GKNoise(moistSource)
//        self.caveNoise = GKNoise(caveSource)
//        self.resourceNoise = GKNoise(resourceSource)
//        self.detailNoise = GKNoise(detailSource)
//        self.shorelineNoise = GKNoise(shorelineSource)
//        
//        // Define biomes like Mindustry
//        self.biomes = [
//            TerrainBiome(
//                primaryTerrain: .redStone,
//                secondaryTerrains: [.roughRhyolite, .regolith],
//                wallDensity: 0.15,
//                resourceTypes: [.thorium, .oxide],
//                featureTypes: [.vent]
//            ),
//            TerrainBiome(
//                primaryTerrain: .crystalFloor,
//                secondaryTerrains: [.metalFloor, .redIce],
//                wallDensity: 0.1,
//                resourceTypes: [.beryllium, .tungsten],
//                featureTypes: [.geyser]
//            ),
//            TerrainBiome(
//                primaryTerrain: .darkSand,
//                secondaryTerrains: [.regolith, .metalFloor],
//                wallDensity: 0.2,
//                resourceTypes: [.beryllium, .oxide],
//                featureTypes: [.vent, .geyser]
//            ),
//            TerrainBiome(
//                primaryTerrain: .metalFloor,
//                secondaryTerrains: [.crystalFloor, .darkSand],
//                wallDensity: 0.08,
//                resourceTypes: [.beryllium, .tungsten],
//                featureTypes: [.geyser]
//            )
//        ]
//    }
//    
//    func generateTerrain(size: Int) {
//        isGenerating = true
//        
//        DispatchQueue.global(qos: .userInitiated).async {
//            var newTiles: [[ErekirTile]] = []
//            
//            // Step 1: Generate initial land/void map using island seeds
//            var landMap = self.generateLandMap(size: size)
//            
//            // Step 2: Apply cellular automata to create jagged coastlines
//            landMap = self.applyCellularAutomataToLand(landMap: landMap, iterations: self.cellularIterations)
//            
//            // Step 3: Generate terrain types and elevation
//            let biomeMap = self.generateBiomeMap(size: size)
//            
//            // Debug: Count void vs terrain tiles
//            var voidCount = 0
//            var terrainCount = 0
//            
//            for x in 0..<size {
//                var column: [ErekirTile] = []
//                for y in 0..<size {
//                    let isLand = landMap[x][y]
//                    let terrain: ErekirTerrain
//                    
//                    if isLand {
//                        terrain = self.generateTerrainForLand(x: x, y: y, size: size, biomeMap: biomeMap)
//                        terrainCount += 1
//                    } else {
//                        terrain = .void
//                        voidCount += 1
//                    }
//                    
//                    let variant = self.generateVariant(x: x, y: y)
//                    var tile = ErekirTile(terrain: terrain, resource: nil, feature: nil, variant: variant, x: x, y: y)
//                    tile.biomeMask = biomeMap[x][y]
//                    tile.elevation = isLand ? 0.5 : -1.0 // Simple elevation for now
//                    column.append(tile)
//                }
//                newTiles.append(column)
//            }
//            
//            print("Generated terrain: \(terrainCount) terrain tiles, \(voidCount) void tiles")
//            
//            // Step 4: Generate natural walls at land/void boundaries
//            newTiles = self.generateNaturalWallsFromLandMap(tiles: newTiles, landMap: landMap)
//            
//            // Step 5: Apply light cave generation only in solid areas
//            newTiles = self.applyCellularAutomata(tiles: newTiles, iterations: 2)
//            
//            // Step 6: Generate resources and features
//            newTiles = self.generateResourcesAndFeatures(tiles: newTiles)
//            
//            DispatchQueue.main.async {
//                self.tiles = newTiles
//                self.isGenerating = false
//            }
//        }
//    }
//    
//    private func generateLandMap(size: Int) -> [[Bool]] {
//        var landMap: [[Bool]] = []
//        
//        // Generate random island seed points
//        var islandCenters: [(x: Double, y: Double, strength: Double)] = []
//        for _ in 0..<islandSeeds {
//            let x = Double.random(in: 0.2...0.8) // Keep away from edges
//            let y = Double.random(in: 0.2...0.8)
//            let strength = Double.random(in: 0.3...0.8) // Vary island influence
//            islandCenters.append((x: x, y: y, strength: strength))
//        }
//        
//        for x in 0..<size {
//            var column: [Bool] = []
//            for y in 0..<size {
//                let nx = Double(x) / Double(size)
//                let ny = Double(y) / Double(size)
//                
//                // Calculate influence from nearest island centers
//                var maxInfluence: Double = 0
//                for center in islandCenters {
//                    let distance = sqrt(pow(nx - center.x, 2) + pow(ny - center.y, 2))
//                    let influence = center.strength * max(0, 1.0 - (distance / 0.4))
//                    maxInfluence = max(maxInfluence, influence)
//                }
//                
//                // Add noise variation for irregular edges
//                let noiseValue = Double(continentalNoise.value(atPosition: vector2(Float(nx * 8), Float(ny * 8))))
//                let detailNoiseValue = Double(detailNoise.value(atPosition: vector2(Float(nx * 16), Float(ny * 16)))) * 0.3
//                
//                // Combine influence with noise
//                let finalValue = maxInfluence + noiseValue * 0.4 + detailNoiseValue
//                
//                // Force void near edges
//                let edgeDistance = min(min(nx, 1.0 - nx), min(ny, 1.0 - ny))
//                let edgeFalloff = smoothstep(0.0, 0.1, edgeDistance)
//                
//                let isLand = (finalValue * edgeFalloff) > (1.0 - landProbability)
//                column.append(isLand)
//            }
//            landMap.append(column)
//        }
//        
//        return landMap
//    }
//    
//    private func applyCellularAutomataToLand(landMap: [[Bool]], iterations: Int) -> [[Bool]] {
//        var workingMap = landMap
//        let size = landMap.count
//        
//        for iteration in 0..<iterations {
//            var newMap = workingMap
//            
//            for x in 1..<size-1 {
//                for y in 1..<size-1 {
//                    // Count land neighbors in 3x3 area
//                    var landNeighbors = 0
//                    var totalNeighbors = 0
//                    
//                    for dx in -1...1 {
//                        for dy in -1...1 {
//                            let nx = x + dx
//                            let ny = y + dy
//                            if nx >= 0 && nx < size && ny >= 0 && ny < size {
//                                totalNeighbors += 1
//                                if workingMap[nx][ny] {
//                                    landNeighbors += 1
//                                }
//                            }
//                        }
//                    }
//                    
//                    // Cellular automata rules for natural coastlines
//                    let landDensity = Double(landNeighbors) / Double(totalNeighbors)
//                    
//                    if iteration < 2 {
//                        // First iterations: smooth and connect land
//                        newMap[x][y] = landDensity >= 0.5
//                    } else {
//                        // Later iterations: create more jagged edges
//                        newMap[x][y] = landDensity >= 0.4
//                    }
//                }
//            }
//            
//            workingMap = newMap
//        }
//        
//        return workingMap
//    }
//    
//    private func generateTerrainForLand(x: Int, y: Int, size: Int, biomeMap: [[Double]]) -> ErekirTerrain {
//        let nx = Double(x) / Double(size)
//        let ny = Double(y) / Double(size)
//        
//        // Get noise values for terrain variation
//        let temperature = Double(temperatureNoise.value(atPosition: vector2(Float(nx * 1.4), Float(ny * 1.4))))
//        let moisture = Double(moistureNoise.value(atPosition: vector2(Float(nx * 1.7), Float(ny * 1.7))))
//        let erosion = Double(erosionNoise.value(atPosition: vector2(Float(nx * 1.6), Float(ny * 1.6))))
//        let elevation = Double(peaksValleysNoise.value(atPosition: vector2(Float(nx * 2.0), Float(ny * 2.0))))
//        
//        // Generate varied terrain based on multiple factors
//        if elevation > 0.4 {
//            // High elevation areas
//            if temperature > 0.2 {
//                return .roughRhyolite
//            } else if moisture < -0.2 {
//                return .redStone
//            } else {
//                return .regolith
//            }
//        } else if elevation > 0.0 {
//            // Medium elevation
//            if moisture > 0.3 {
//                return .crystalFloor
//            } else if temperature < -0.2 && moisture > 0.0 {
//                return .redIce
//            } else if erosion > 0.2 {
//                return .darkSand
//            } else if temperature > 0.3 {
//                return .redStone
//            } else {
//                return .metalFloor
//            }
//        } else {
//            // Lower areas
//            if moisture > 0.2 && temperature < 0.0 {
//                return .redIce
//            } else if erosion > 0.1 {
//                return .darkSand
//            } else {
//                return .regolith
//            }
//        }
//    }
//    
//    private func generateNaturalWallsFromLandMap(tiles: [[ErekirTile]], landMap: [[Bool]]) -> [[ErekirTile]] {
//        var newTiles = tiles
//        let size = tiles.count
//        
//        for x in 0..<size {
//            for y in 0..<size {
//                let currentTile = tiles[x][y]
//                
//                // Only process land tiles
//                if currentTile.terrain.isVoid { continue }
//                
//                // Check if this land tile should become a wall (adjacent to void)
//                var hasVoidNeighbor = false
//                
//                for dx in -1...1 {
//                    for dy in -1...1 {
//                        if dx == 0 && dy == 0 { continue }
//                        
//                        let nx = x + dx
//                        let ny = y + dy
//                        
//                        if nx >= 0 && nx < size && ny >= 0 && ny < size {
//                            if !landMap[nx][ny] { // Neighbor is void
//                                hasVoidNeighbor = true
//                                break
//                            }
//                        } else {
//                            // Outside map bounds - treat as void
//                            hasVoidNeighbor = true
//                            break
//                        }
//                    }
//                    if hasVoidNeighbor { break }
//                }
//                
//                // Generate walls at the boundary between land and void
//                if hasVoidNeighbor && !currentTile.terrain.isWall {
//                    let wallType: ErekirTerrain = Double.random(in: 0...1) > 0.7 ? .carbonWall : .berylliumWall
//                    
//                    newTiles[x][y] = ErekirTile(
//                        terrain: wallType,
//                        resource: nil,
//                        feature: nil,
//                        variant: currentTile.variant,
//                        x: x, y: y,
//                        biomeMask: currentTile.biomeMask,
//                        elevation: currentTile.elevation
//                    )
//                }
//            }
//        }
//        
//        return newTiles
//    }
//    
//    private func generateBiomeMap(size: Int) -> [[Double]] {
//        var biomeMap: [[Double]] = []
//        
//        for x in 0..<size {
//            var column: [Double] = []
//            for y in 0..<size {
//                let nx = Double(x) / Double(size)
//                let ny = Double(y) / Double(size)
//                
//                let tempValue = Double(temperatureNoise.value(atPosition: vector2(Float(nx), Float(ny))))
//                let moistValue = Double(moistureNoise.value(atPosition: vector2(Float(nx * 1.1), Float(ny * 1.1))))
//                
//                let biomeNoise = (tempValue + moistValue) / 2.0
//                let biomeFloat = ((biomeNoise + 1.0) / 2.0) * Double(biomes.count - 1)
//                column.append(biomeFloat)
//            }
//            biomeMap.append(column)
//        }
//        
//        return biomeMap
//    }
//    
//    private func applyCellularAutomata(tiles: [[ErekirTile]], iterations: Int) -> [[ErekirTile]] {
//        var workingTiles = tiles
//        let size = tiles.count
//        
//        // Light cave generation only in solid terrain areas
//        for iteration in 0..<iterations {
//            var newTiles = workingTiles
//            
//            for x in 1..<size-1 {
//                for y in 1..<size-1 {
//                    let currentTile = workingTiles[x][y]
//                    
//                    // Skip voids and existing walls
//                    if currentTile.terrain.isVoid || currentTile.terrain.isWall { continue }
//                    
//                    let nx = Double(x) / Double(size)
//                    let ny = Double(y) / Double(size)
//                    let caveValue = Double(caveNoise.value(atPosition: vector2(Float(nx * 1.5), Float(ny * 1.5))))
//                    
//                    // Count wall neighbors
//                    var wallNeighbors = 0
//                    var totalNeighbors = 0
//                    for dx in -1...1 {
//                        for dy in -1...1 {
//                            if dx == 0 && dy == 0 { continue }
//                            let nx = x + dx
//                            let ny = y + dy
//                            if nx >= 0 && nx < size && ny >= 0 && ny < size {
//                                totalNeighbors += 1
//                                if workingTiles[nx][ny].terrain.isWall {
//                                    wallNeighbors += 1
//                                }
//                            }
//                        }
//                    }
//                    
//                    let wallDensity = Double(wallNeighbors) / Double(totalNeighbors)
//                    let shouldBeWall = caveValue > 0.6 && (wallDensity > 0.3 || caveValue > 0.8)
//                    
//                    if shouldBeWall {
//                        let wallType: ErekirTerrain = Double.random(in: 0...1) > 0.6 ? .carbonWall : .berylliumWall
//                        newTiles[x][y] = ErekirTile(
//                            terrain: wallType,
//                            resource: nil,
//                            feature: nil,
//                            variant: currentTile.variant,
//                            x: x, y: y,
//                            biomeMask: currentTile.biomeMask,
//                            elevation: currentTile.elevation
//                        )
//                    }
//                }
//            }
//            
//            workingTiles = newTiles
//        }
//        
//        return workingTiles
//    }
//    
//    private func generateResourcesAndFeatures(tiles: [[ErekirTile]]) -> [[ErekirTile]] {
//        var newTiles = tiles
//        let size = tiles.count
//        
//        for x in 0..<size {
//            for y in 0..<size {
//                var tile = newTiles[x][y]
//                
//                // Skip walls and void
//                if tile.terrain.isWall || tile.terrain.isVoid { continue }
//                
//                let nx = Double(x) / Double(size)
//                let ny = Double(y) / Double(size)
//                let resourceValue = Double(resourceNoise.value(atPosition: vector2(Float(nx * 6), Float(ny * 6))))
//                
//                let biomeIndex = Int(tile.biomeMask) % biomes.count
//                let biome = biomes[biomeIndex]
//                
//                // Resource generation
//                if resourceValue > 0.3 {
//                    for resource in biome.resourceTypes {
//                        let veinStrength = (resourceValue - 0.3) / 0.7
//                        let spawnChance = resource.spawnChance * veinStrength * 2.0
//                        
//                        if Double.random(in: 0...1) < spawnChance {
//                            tile.resource = resource
//                            break
//                        }
//                    }
//                }
//                
//                // Feature generation
//                if tile.resource == nil {
//                    for feature in biome.featureTypes {
//                        let featureNoise = Double(detailNoise.value(atPosition: vector2(Float(nx * 8), Float(ny * 8))))
//                        let adjustedChance = feature.spawnChance * (1.0 + featureNoise * 0.5)
//                        
//                        if Double.random(in: 0...1) < adjustedChance {
//                            tile.feature = feature
//                            break
//                        }
//                    }
//                }
//                
//                newTiles[x][y] = tile
//            }
//        }
//        
//        return newTiles
//    }
//    
//    private func generateVariant(x: Int, y: Int) -> Int {
//        let detailValue = detailNoise.value(atPosition: vector2(Float(x) * 0.1, Float(y) * 0.1))
//        return Int((detailValue + 1) * 2) % 4 // 0-3 variants
//    }
//    
//    // Helper function for smooth transitions
//    private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
//        let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
//        return t * t * (3 - 2 * t)
//    }
//}
//
//// MARK: - Enhanced Canvas Rendering
//struct ErekirTerrainCanvas: View {
//    let tiles: [[ErekirTile]]
//    let tileSize: CGFloat
//    let viewportOffset: CGPoint
//    let viewportSize: CGSize
//    
//    var body: some View {
//        Canvas { context, size in
//            guard !tiles.isEmpty else { return }
//            
//            let tilesPerRow = tiles.count
//            let tilesPerColumn = tiles[0].count
//            
//            let startX = max(0, Int(viewportOffset.x / tileSize) - 2)
//            let endX = min(tilesPerRow, Int((viewportOffset.x + viewportSize.width) / tileSize) + 4)
//            let startY = max(0, Int(viewportOffset.y / tileSize) - 2)
//            let endY = min(tilesPerColumn, Int((viewportOffset.y + viewportSize.height) / tileSize) + 4)
//            
//            // Draw terrain
//            for x in startX..<endX {
//                for y in startY..<endY {
//                    let tile = tiles[x][y]
//                    let rect = CGRect(
//                        x: CGFloat(x) * tileSize,
//                        y: CGFloat(y) * tileSize,
//                        width: tileSize,
//                        height: tileSize
//                    )
//                    
//                    drawDetailedTile(context: context, tile: tile, rect: rect)
//                }
//            }
//            
//            // Draw resources and features
//            for x in startX..<endX {
//                for y in startY..<endY {
//                    let tile = tiles[x][y]
//                    let rect = CGRect(
//                        x: CGFloat(x) * tileSize,
//                        y: CGFloat(y) * tileSize,
//                        width: tileSize,
//                        height: tileSize
//                    )
//                    
//                    // Draw resources and features (but not on void)
//                    if !tile.terrain.isVoid {
//                        if let feature = tile.feature {
//                            drawFeature(context: context, feature: feature, rect: rect)
//                        } else if let resource = tile.resource {
//                            drawResource(context: context, resource: resource, rect: rect)
//                        }
//                    }
//                }
//            }
//        }
//        .frame(
//            width: CGFloat(tiles.count) * tileSize,
//            height: tiles.isEmpty ? 0 : CGFloat(tiles[0].count) * tileSize
//        )
//    }
//    
//    private func drawDetailedTile(context: GraphicsContext, tile: ErekirTile, rect: CGRect) {
//        // Handle void tiles specially
//        if tile.terrain.isVoid {
//            context.fill(Path(rect), with: .color(tile.terrain.baseColor))
//            // Add subtle star field effect for void
//            drawVoidPattern(context: context, rect: rect, variant: tile.variant)
//            return
//        }
//        
//        // Try to load terrain image first
//        if let terrainImage = UIImage(named: tile.terrain.imageName) {
//            context.draw(Image(uiImage: terrainImage), in: rect)
//        } else {
//            // Fallback to drawing if image not available
//            context.fill(Path(rect), with: .color(tile.terrain.baseColor))
//            
//            // Add texture patterns based on terrain type and variant
//            drawTerrainPattern(context: context, terrain: tile.terrain, variant: tile.variant, rect: rect)
//            
//            // Add subtle gradient for depth
//            drawGradientEffect(context: context, tile: tile, rect: rect)
//            
//            // Draw walls with special treatment
//            if tile.terrain.isWall {
//                drawWallPattern(context: context, terrain: tile.terrain, rect: rect)
//            }
//        }
//    }
//    
//    private func drawVoidPattern(context: GraphicsContext, rect: CGRect, variant: Int) {
//        // Add small "star" points for void areas
//        for i in 0..<3 {
//            let x = rect.minX + CGFloat((i * 47 + variant * 23) % Int(rect.width))
//            let y = rect.minY + CGFloat((i * 31 + variant * 17) % Int(rect.height))
//            
//            let starSize: CGFloat = 1
//            let starRect = CGRect(x: x - starSize/2, y: y - starSize/2, width: starSize, height: starSize)
//            context.fill(Path(ellipseIn: starRect), with: .color(.white.opacity(0.1)))
//        }
//    }
//    
//    private func drawTerrainPattern(context: GraphicsContext, terrain: ErekirTerrain, variant: Int, rect: CGRect) {
//        switch terrain {
//        case .redStone:
//            drawFlowingPattern(context: context, rect: rect, baseColor: terrain.baseColor, shadowColor: terrain.shadowColor, variant: variant)
//        case .regolith:
//            drawFlowingPattern(context: context, rect: rect, baseColor: terrain.baseColor, shadowColor: terrain.shadowColor, variant: variant, intensity: 0.6)
//        case .darkSand:
//            drawScatteredOvals(context: context, rect: rect, baseColor: terrain.highlightColor, shadowColor: terrain.shadowColor, variant: variant)
//        case .roughRhyolite:
//            drawDiagonalStripes(context: context, rect: rect, baseColor: terrain.shadowColor, variant: variant)
//        case .crystalFloor:
//            drawScatteredDiamonds(context: context, rect: rect, baseColor: terrain.highlightColor, shadowColor: terrain.shadowColor, variant: variant)
//        case .metalFloor:
//            drawMetalGrid(context: context, rect: rect, baseColor: terrain.shadowColor)
//        case .redIce:
//            drawIcePattern(context: context, rect: rect, baseColor: terrain.highlightColor, shadowColor: terrain.shadowColor, variant: variant)
//        default:
//            break
//        }
//    }
//    
//    private func drawFlowingPattern(context: GraphicsContext, rect: CGRect, baseColor: Color, shadowColor: Color, variant: Int, intensity: Double = 1.0) {
//        for i in 0..<6 {
//            let angle = Double(i + variant) * .pi / 3
//            let flowLength = rect.width * 0.8 * intensity
//            let flowWidth = rect.height * 0.15 * intensity
//            
//            let startX = rect.midX + cos(angle) * rect.width * 0.2
//            let startY = rect.midY + sin(angle) * rect.height * 0.2
//            let endX = startX + cos(angle + 0.3) * flowLength
//            let endY = startY + sin(angle + 0.3) * flowLength
//            
//            let flowPath = Path { path in
//                path.move(to: CGPoint(x: startX, y: startY))
//                path.addCurve(
//                    to: CGPoint(x: endX, y: endY),
//                    control1: CGPoint(x: startX + cos(angle + 0.5) * flowLength * 0.3, y: startY + sin(angle + 0.5) * flowLength * 0.3),
//                    control2: CGPoint(x: endX - cos(angle - 0.5) * flowLength * 0.3, y: endY - sin(angle - 0.5) * flowLength * 0.3)
//                )
//            }
//            
//            context.stroke(flowPath, with: .color(shadowColor.opacity(0.6)), lineWidth: flowWidth)
//        }
//    }
//    
//    private func drawScatteredOvals(context: GraphicsContext, rect: CGRect, baseColor: Color, shadowColor: Color, variant: Int) {
//        for i in 0..<12 {
//            let x = rect.minX + CGFloat((i * 17 + variant * 23) % Int(rect.width))
//            let y = rect.minY + CGFloat((i * 19 + variant * 29) % Int(rect.height))
//            
//            let ovalWidth = rect.width * 0.08 + CGFloat(i % 3) * 2
//            let ovalHeight = rect.height * 0.05 + CGFloat(i % 2) * 2
//            
//            let ovalRect = CGRect(x: x - ovalWidth/2, y: y - ovalHeight/2, width: ovalWidth, height: ovalHeight)
//            context.fill(Path(ellipseIn: ovalRect), with: .color(shadowColor.opacity(0.5)))
//        }
//    }
//    
//    private func drawDiagonalStripes(context: GraphicsContext, rect: CGRect, baseColor: Color, variant: Int) {
//        let stripeSpacing = rect.width / 8
//        let stripeWidth: CGFloat = 2
//        
//        for i in stride(from: -rect.width, to: rect.width * 2, by: stripeSpacing) {
//            let path = Path { path in
//                path.move(to: CGPoint(x: rect.minX + i, y: rect.minY))
//                path.addLine(to: CGPoint(x: rect.minX + i + rect.height, y: rect.maxY))
//            }
//            context.stroke(path, with: .color(baseColor.opacity(0.3)), lineWidth: stripeWidth)
//        }
//    }
//    
//    private func drawScatteredDiamonds(context: GraphicsContext, rect: CGRect, baseColor: Color, shadowColor: Color, variant: Int) {
//        for i in 0..<8 {
//            let x = rect.minX + CGFloat((i * 31 + variant * 37) % Int(rect.width))
//            let y = rect.minY + CGFloat((i * 41 + variant * 43) % Int(rect.height))
//            
//            let size = rect.width * 0.06 + CGFloat(i % 2) * 2
//            let rotation = Double(i + variant) * .pi / 4
//            
//            let diamondPath = Path { path in
//                let centerX = x
//                let centerY = y
//                path.move(to: CGPoint(x: centerX + cos(rotation) * size, y: centerY + sin(rotation) * size))
//                path.addLine(to: CGPoint(x: centerX + cos(rotation + .pi/2) * size, y: centerY + sin(rotation + .pi/2) * size))
//                path.addLine(to: CGPoint(x: centerX + cos(rotation + .pi) * size, y: centerY + sin(rotation + .pi) * size))
//                path.addLine(to: CGPoint(x: centerX + cos(rotation + 3 * .pi / 2) * size, y: centerY + sin(rotation + 3 * .pi / 2) * size))
//                path.closeSubpath()
//            }
//            
//            context.fill(diamondPath, with: .color(baseColor.opacity(0.6)))
//            context.stroke(diamondPath, with: .color(shadowColor.opacity(0.4)), lineWidth: 1)
//        }
//    }
//    
//    private func drawMetalGrid(context: GraphicsContext, rect: CGRect, baseColor: Color) {
//        let lineWidth: CGFloat = 1
//        let spacing = rect.width / 6
//        
//        for i in 0..<7 {
//            let pos = rect.minX + CGFloat(i) * spacing
//            // Vertical lines
//            context.stroke(
//                Path { path in
//                    path.move(to: CGPoint(x: pos, y: rect.minY))
//                    path.addLine(to: CGPoint(x: pos, y: rect.maxY))
//                },
//                with: .color(baseColor.opacity(0.4)),
//                lineWidth: lineWidth
//            )
//            // Horizontal lines
//            let hPos = rect.minY + CGFloat(i) * spacing
//            context.stroke(
//                Path { path in
//                    path.move(to: CGPoint(x: rect.minX, y: hPos))
//                    path.addLine(to: CGPoint(x: rect.maxX, y: hPos))
//                },
//                with: .color(baseColor.opacity(0.4)),
//                lineWidth: lineWidth
//            )
//        }
//    }
//    
//    private func drawIcePattern(context: GraphicsContext, rect: CGRect, baseColor: Color, shadowColor: Color, variant: Int) {
//        for i in 0..<4 {
//            let centerX = rect.minX + CGFloat(i % 2) * rect.width / 2 + rect.width / 4
//            let centerY = rect.minY + CGFloat(i / 2) * rect.height / 2 + rect.height / 4
//            let size = rect.width * 0.1
//            
//            // Draw crystal star
//            for j in 0..<6 {
//                let angle = Double(j) * .pi / 3 + Double(variant) * 0.1
//                let endX = centerX + cos(angle) * size
//                let endY = centerY + sin(angle) * size
//                
//                context.stroke(
//                    Path { path in
//                        path.move(to: CGPoint(x: centerX, y: centerY))
//                        path.addLine(to: CGPoint(x: endX, y: endY))
//                    },
//                    with: .color(baseColor.opacity(0.6)),
//                    lineWidth: 1
//                )
//            }
//        }
//    }
//    
//    private func drawGradientEffect(context: GraphicsContext, tile: ErekirTile, rect: CGRect) {
//        // Add subtle top-left highlight and bottom-right shadow
//        let highlightRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width * 0.6, height: rect.height * 0.6)
//        context.fill(Path(highlightRect), with: .color(tile.terrain.highlightColor.opacity(0.15)))
//        
//        let shadowRect = CGRect(x: rect.maxX - rect.width * 0.6, y: rect.maxY - rect.height * 0.6, width: rect.width * 0.6, height: rect.height * 0.6)
//        context.fill(Path(shadowRect), with: .color(tile.terrain.shadowColor.opacity(0.2)))
//    }
//    
//    private func drawWallPattern(context: GraphicsContext, terrain: ErekirTerrain, rect: CGRect) {
//        if terrain == .carbonWall {
//            let borderWidth: CGFloat = 1.5
//            let borderRect = rect.insetBy(dx: borderWidth/2, dy: borderWidth/2)
//            context.stroke(Path(borderRect), with: .color(.black.opacity(0.8)), lineWidth: borderWidth)
//            
//            // Cross pattern
//            let crossSize = rect.width * 0.6
//            let centerX = rect.midX
//            let centerY = rect.midY
//            
//            context.stroke(
//                Path { path in
//                    path.move(to: CGPoint(x: centerX - crossSize/2, y: centerY))
//                    path.addLine(to: CGPoint(x: centerX + crossSize/2, y: centerY))
//                },
//                with: .color(terrain.shadowColor),
//                lineWidth: 2
//            )
//            
//            context.stroke(
//                Path { path in
//                    path.move(to: CGPoint(x: centerX, y: centerY - crossSize/2))
//                    path.addLine(to: CGPoint(x: centerX, y: centerY + crossSize/2))
//                },
//                with: .color(terrain.shadowColor),
//                lineWidth: 2
//            )
//            
//        } else if terrain == .berylliumWall {
//            let borderWidth: CGFloat = 1.5
//            let borderRect = rect.insetBy(dx: borderWidth/2, dy: borderWidth/2)
//            context.stroke(Path(borderRect), with: .color(terrain.shadowColor), lineWidth: borderWidth)
//            
//            let diamondSize = rect.width * 0.4
//            let centerX = rect.midX
//            let centerY = rect.midY
//            
//            let diamondPath = Path { path in
//                path.move(to: CGPoint(x: centerX, y: centerY - diamondSize/2))
//                path.addLine(to: CGPoint(x: centerX + diamondSize/2, y: centerY))
//                path.addLine(to: CGPoint(x: centerX, y: centerY + diamondSize/2))
//                path.addLine(to: CGPoint(x: centerX - diamondSize/2, y: centerY))
//                path.closeSubpath()
//            }
//            
//            context.fill(diamondPath, with: .color(terrain.highlightColor.opacity(0.5)))
//            context.stroke(diamondPath, with: .color(terrain.shadowColor), lineWidth: 1)
//        }
//        
//        let innerRect = rect.insetBy(dx: 3, dy: 3)
//        context.fill(Path(innerRect), with: .color(.black.opacity(0.15)))
//    }
//    
//    private func drawFeature(context: GraphicsContext, feature: ErekirFeature, rect: CGRect) {
//        if let featureImage = UIImage(named: feature.imageName) {
//            let featureSize = rect.width * 0.9 * 3
//            let featureRect = CGRect(
//                x: rect.midX - featureSize / 2,
//                y: rect.midY - featureSize / 2,
//                width: featureSize,
//                height: featureSize
//            )
//            context.draw(Image(uiImage: featureImage), in: featureRect)
//        } else {
//            switch feature {
//            case .vent:
//                drawVentFallback(context: context, rect: rect)
//            case .geyser:
//                drawGeyserFallback(context: context, rect: rect)
//            }
//        }
//    }
//    
//    private func drawVentFallback(context: GraphicsContext, rect: CGRect) {
//        let ventSize = rect.width * 0.7
//        let ventRect = CGRect(
//            x: rect.midX - ventSize / 2,
//            y: rect.midY - ventSize / 2,
//            width: ventSize,
//            height: ventSize
//        )
//        
//        context.fill(Path(ellipseIn: ventRect), with: .color(Color(red: 0.2, green: 0.1, blue: 0.05)))
//        
//        let coreSize = ventSize * 0.5
//        let coreRect = CGRect(
//            x: rect.midX - coreSize / 2,
//            y: rect.midY - coreSize / 2,
//            width: coreSize,
//            height: coreSize
//        )
//        context.fill(Path(ellipseIn: coreRect), with: .color(Color(red: 0.1, green: 0.05, blue: 0.02)))
//        
//        for i in 0..<8 {
//            let angle = Double(i) * .pi / 4
//            let startRadius = ventSize * 0.35
//            let endRadius = ventSize * 0.6
//            
//            let startX = rect.midX + cos(angle) * startRadius
//            let startY = rect.midY + sin(angle) * startRadius
//            let endX = rect.midX + cos(angle) * endRadius
//            let endY = rect.midY + sin(angle) * endRadius
//            
//            context.stroke(
//                Path { path in
//                    path.move(to: CGPoint(x: startX, y: startY))
//                    path.addLine(to: CGPoint(x: endX, y: endY))
//                },
//                with: .color(Color(red: 0.3, green: 0.15, blue: 0.1).opacity(0.8)),
//                lineWidth: 2
//            )
//        }
//        
//        context.stroke(
//            Path(ellipseIn: ventRect),
//            with: .color(Color(red: 0.4, green: 0.25, blue: 0.15).opacity(0.6)),
//            lineWidth: 1.5
//        )
//    }
//    
//    private func drawGeyserFallback(context: GraphicsContext, rect: CGRect) {
//        let geyserSize = rect.width * 0.6
//        let geyserRect = CGRect(
//            x: rect.midX - geyserSize / 2,
//            y: rect.midY - geyserSize / 2,
//            width: geyserSize,
//            height: geyserSize
//        )
//        
//        context.fill(Path(ellipseIn: geyserRect), with: .color(Color(red: 0.4, green: 0.5, blue: 0.7)))
//        
//        for i in 0..<6 {
//            let angle = Double(i) * .pi / 3
//            let spikeLength = geyserSize * 0.3
//            
//            let endX = rect.midX + cos(angle) * spikeLength
//            let endY = rect.midY + sin(angle) * spikeLength
//            
//            let spikePath = Path { path in
//                path.move(to: CGPoint(x: rect.midX, y: rect.midY))
//                path.addLine(to: CGPoint(x: endX, y: endY))
//                path.addLine(to: CGPoint(x: rect.midX + cos(angle + 0.3) * spikeLength * 0.7, y: rect.midY + sin(angle + 0.3) * spikeLength * 0.7))
//                path.closeSubpath()
//            }
//            
//            context.fill(spikePath, with: .color(Color(red: 0.6, green: 0.7, blue: 0.9).opacity(0.8)))
//        }
//        
//        let centerSize = geyserSize * 0.2
//        let centerRect = CGRect(
//            x: rect.midX - centerSize / 2,
//            y: rect.midY - centerSize / 2,
//            width: centerSize,
//            height: centerSize
//        )
//        context.fill(Path(ellipseIn: centerRect), with: .color(.white.opacity(0.8)))
//    }
//    
//    private func drawResource(context: GraphicsContext, resource: ErekirResource, rect: CGRect) {
//        if let resourceImage = UIImage(named: resource.imageName) {
//            let resourceSize = rect.width * 0.7
//            let resourceRect = CGRect(
//                x: rect.midX - resourceSize / 2,
//                y: rect.midY - resourceSize / 2,
//                width: resourceSize,
//                height: resourceSize
//            )
//            context.draw(Image(uiImage: resourceImage), in: resourceRect)
//        } else {
//            let resourceSize = rect.width * 0.5
//            let resourceRect = CGRect(
//                x: rect.midX - resourceSize / 2,
//                y: rect.midY - resourceSize / 2,
//                width: resourceSize,
//                height: resourceSize
//            )
//            
//            context.fill(Path(ellipseIn: resourceRect), with: .color(resource.baseColor))
//            
//            let highlightRect = CGRect(
//                x: resourceRect.minX + resourceSize * 0.2,
//                y: resourceRect.minY + resourceSize * 0.2,
//                width: resourceSize * 0.4,
//                height: resourceSize * 0.4
//            )
//            context.fill(Path(ellipseIn: highlightRect), with: .color(.white.opacity(0.3)))
//            
//            context.stroke(Path(ellipseIn: resourceRect), with: .color(resource.shadowColor), lineWidth: 1.5)
//        }
//    }
//}
//
//// MARK: - Scrollable Terrain View
//struct ErekirTerrainView: View {
//    let tiles: [[ErekirTile]]
//    let tileSize: CGFloat
//    @State private var scrollPosition = CGPoint.zero
//    
//    var body: some View {
//        GeometryReader { geometry in
//            ScrollView([.horizontal, .vertical]) {
//                ErekirTerrainCanvas(
//                    tiles: tiles,
//                    tileSize: tileSize,
//                    viewportOffset: scrollPosition,
//                    viewportSize: geometry.size
//                )
//            }
//            .background(Color.black) // Make void areas very obvious
//            .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
//                scrollPosition = value
//            }
//            .overlay(
//                ScrollView([.horizontal, .vertical]) {
//                    Color.clear
//                        .frame(
//                            width: tiles.isEmpty ? 0 : CGFloat(tiles.count) * tileSize,
//                            height: tiles.isEmpty ? 0 : CGFloat(tiles[0].count) * tileSize
//                        )
//                        .background(GeometryReader { proxy in
//                            Color.clear
//                                .preference(key: ScrollOffsetPreferenceKey.self, value: CGPoint(
//                                    x: -proxy.frame(in: .named("scroll")).origin.x,
//                                    y: -proxy.frame(in: .named("scroll")).origin.y
//                                ))
//                        })
//                }
//                .coordinateSpace(name: "scroll")
//                .allowsHitTesting(false)
//            )
//        }
//    }
//}
//
//struct ScrollOffsetPreferenceKey: PreferenceKey {
//    static var defaultValue: CGPoint = .zero
//    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) {}
//}
//
//// MARK: - Main View
//struct MainWorld: View {
//    @StateObject private var terrainGenerator = ErekirTerrainGenerator()
//    @State private var terrainSize = 100
//    @State private var tileSize: CGFloat = 16
//    
//    var body: some View {
//        VStack(spacing: 0) {
//            // Controls
//            VStack {
//                HStack {
//                    Text("Terrain Size: \(terrainSize)")
//                        .foregroundColor(.white)
//                    Slider(value: Binding(
//                        get: { Double(terrainSize) },
//                        set: { terrainSize = Int($0) }
//                    ), in: 60...250, step: 10)
//                }
//                
//                HStack {
//                    Text("Tile Size: \(Int(tileSize))")
//                        .foregroundColor(.white)
//                    Slider(value: $tileSize, in: 12...24, step: 1)
//                }
//                
//                Button(action: {
//                    terrainGenerator.generateTerrain(size: terrainSize)
//                }) {
//                    if terrainGenerator.isGenerating {
//                        HStack {
//                            ProgressView()
//                                .scaleEffect(0.8)
//                            Text("Generating Erekir...")
//                        }
//                    } else {
//                        Text("Generate Erekir Terrain")
//                    }
//                }
//                .buttonStyle(.borderedProminent)
//                .disabled(terrainGenerator.isGenerating)
//            }
//            .padding()
//            .background(Color(red: 0.2, green: 0.15, blue: 0.1))
//            
//            // Terrain Display
//            if !terrainGenerator.tiles.isEmpty {
//                ErekirTerrainView(tiles: terrainGenerator.tiles, tileSize: tileSize)
//            } else {
//                VStack {
//                    Text("Erekir Awaits")
//                        .font(.title)
//                        .foregroundColor(.orange)
//                    Text("Generate terrain to explore the industrial wasteland")
//                        .foregroundColor(.secondary)
//                }
//                .frame(maxWidth: .infinity, maxHeight: .infinity)
//                .background(Color.black)
//            }
//        }
//        .background(Color.black)
//        .onAppear {
//            if terrainGenerator.tiles.isEmpty {
//                terrainGenerator.generateTerrain(size: terrainSize)
//            }
//        }
//    }
//}
//
//#Preview {
//    MainWorld()
//}*/
//
//import Foundation
//import GameplayKit    // for Perlin noise
//import SwiftUI        // for Color (used in overlays)
//import simd           // for vector_double2
//
//// ----------------------------------------------------------------------------
//// MARK: — Tile / Enum Definitions
//// ----------------------------------------------------------------------------
//
//struct Tile {
//    // 0,1,2 → which terrain image ("terrain0", "terrain1", or "terrain2")
//    var floorVariant: Int = 0
//
//    // .stoneWall indicates a wall tile; .none = floor; .cliff is unused here but left for future.
//    var block: BlockType = .none
//
//    // Only walls get ore; floor (block==.none) never gets an ore.
//    var ore: OreType = .copper
//
//    // Only floor tiles (block==.none) can get a vent/geyser.
//    var decor: DecorType = .none
//}
//
//enum BlockType: CaseIterable {
//    case none
//    case stoneWall   // a solid wall on the border
//    case cliff       // (unused in this minimal version)
//
//    // We will draw a matching wall image (wall0/1/2) instead of a flat color.
//    var displayColor: Color? {
//        switch self {
//        case .none:
//            return nil
//        case .stoneWall:
//            return Color(red: 0.2, green: 0.2, blue: 0.2).opacity(1.0)
//        case .cliff:
//            return Color(red: 0.25, green: 0.25, blue: 0.25).opacity(1.0)
//        }
//    }
//}
//
//enum OreType: CaseIterable {
//    case none
//    case copper
//    case graphite
//    case titanium
//
//    // Image names for ore textures
//    var imageName: String? {
//        switch self {
//        case .none:
//            return nil
//        case .copper:
//            return "ore_copper"
//        case .graphite:
//            return "ore_graphite"  // Using graphite texture for lead
//        case .titanium:
//            return "ore_graphite"  // Using graphite texture for titanium (you can change this)
//        }
//    }
//
//    // Fallback color if image is not available
//    var fallbackColor: Color {
//        switch self {
//        case .none:
//            return .clear
//        case .copper:
//            return Color(red: 0.9, green: 0.4, blue: 0.0)
//        case .graphite:
//            return Color(red: 0.35, green: 0.35, blue: 0.35)
//        case .titanium:
//            return Color(red: 0.6, green: 0.6, blue: 0.8)
//        }
//    }
//
//    // Keep the old displayColor for backwards compatibility, but mark as deprecated
//    @available(*, deprecated, message: "Use imageName instead")
//    var displayColor: Color? {
//        return fallbackColor
//    }
//}
//
//enum DecorType: CaseIterable {
//    case none
//    case vent
//    case geyser
//
//    // If you have actual PNGs named "vent" and "geyser" in Assets.xcassets, they'll be used.
//    // Otherwise, we'll draw a colored circle as a placeholder.
//    var displayImageName: String? {
//        switch self {
//        case .none:
//            return nil
//        case .vent:
//            return "vent"      // make sure you imported asset "vent"
//        case .geyser:
//            return "geyser"    // make sure you imported asset "geyser"
//        }
//    }
//
//    // Fallback color if no image exists
//    var placeholderColor: Color {
//        switch self {
//        case .none:
//            return .clear
//        case .vent:
//            return Color(red: 1.0, green: 0.2, blue: 0.1).opacity(0.8)   // red‐orange
//        case .geyser:
//            return Color(red: 0.8, green: 0.8, blue: 1.0).opacity(0.8)   // pale blue
//        }
//    }
//}
//
//struct IntGrid {
//    let width: Int
//    let height: Int
//    var data: [Int]
//
//    init(width: Int, height: Int, defaultValue: Int = 0) {
//        self.width = width
//        self.height = height
//        self.data = Array(repeating: defaultValue, count: width * height)
//    }
//
//    subscript(x: Int, y: Int) -> Int {
//        get {
//            guard x >= 0 && x < width && y >= 0 && y < height else { return 0 }
//            return data[y * width + x]
//        }
//        set {
//            guard x >= 0 && x < width && y >= 0 && y < height else { return }
//            data[y * width + x] = newValue
//        }
//    }
//}
//
//// ----------------------------------------------------------------------------
//// MARK: — TerrainGenerator Class
//// ----------------------------------------------------------------------------
//
//class TerrainGenerator {
//    let width: Int
//    let height: Int
//    let seed: UInt64
//
//    // Final output grid
//    private(set) var tiles: [[Tile]]
//
//    // For smoothing floorVariant (no walls here)
//    private let noiseSource: GKPerlinNoiseSource
//    private let noise: GKNoise
//    private let noiseMap: GKNoiseMap
//
//    private var coreX: Int { width / 2 }
//    private var coreY: Int { height / 2 }
//
//    init(width: Int, height: Int, seed: UInt64) {
//        self.width = width
//        self.height = height
//        self.seed = seed
//
//        // Initialize a blank grid of Tiles
//        self.tiles = Array(
//            repeating: Array(repeating: Tile(), count: height),
//            count: width
//        )
//
//        // Perlin‐noise setup for smooth floorVariant
//        self.noiseSource = GKPerlinNoiseSource(
//            frequency: 0.3,    // Lower frequency → larger blobs
//            octaveCount: 3,
//            persistence: 0.5,
//            lacunarity: 2.0,
//            seed: Int32(truncatingIfNeeded: seed)
//        )
//        self.noise = GKNoise(noiseSource)
//
//        // Build a noiseMap large enough to cover width×height
//        self.noiseMap = GKNoiseMap(
//            noise,
//            size: vector_double2(Double(width) / 16.0, Double(height) / 16.0),
//            origin: vector_double2(0, 0),
//            sampleCount: vector_int2(Int32(width), Int32(height)),
//            seamless: false
//        )
//    }
//
//    /// Call this *once* to fill `tiles` with floorVariant, then walls on edges, then ores in walls, then vents/geysers.
//    func generateAll() {
//        generateBaseFloorVariant()
//        generateBorderWallsOnly()
//        placeOresInWalls()
//        placeVentsAndGeysers()
//    }
//
//    // MARK: — 1) Generate a smooth floorVariant (0..2) using Perlin + smoothing
//
//    private func generateBaseFloorVariant() {
//            // A) Initial "banding" by noise: each tile → raw noise ∈ [–1,1], normalize to [0,1]
//            for x in 0 ..< width {
//                for y in 0 ..< height {
//                    let raw = noiseMap.value(at: vector_int2(Int32(x), Int32(y)))
//                    let normalized = (raw + 1.0) / 2.0   // now ∈ [0,1]
//
//                    // Map [0,1] → 0,1,2,3 by splitting into four equal bands
//                    let band = Int(min(max(floor(normalized * 4.0), 0.0), 3.0))
//                    tiles[x][y].floorVariant = band
//                }
//            }
//
//            // B) One quick majority‐filter pass to remove tiny speckles
//            var variantGrid = IntGrid(width: width, height: height, defaultValue: 0)
//            for x in 0 ..< width {
//                for y in 0 ..< height {
//                    var counts = [0, 0, 0, 0]  // Updated to handle 4 variants
//                    for dy in -1 ... 1 {
//                        for dx in -1 ... 1 {
//                            let nx = x + dx, ny = y + dy
//                            if nx < 0 || nx >= width || ny < 0 || ny >= height { continue }
//                            let v = tiles[nx][ny].floorVariant
//                            if v >= 0 && v < 4 {  // Safety check for valid variant range
//                                counts[v] += 1
//                            }
//                        }
//                    }
//                    let majority = counts.enumerated().max(by: { $0.element < $1.element })!.offset
//                    variantGrid[x, y] = majority
//                }
//            }
//            // Copy the smoothed values back
//            for x in 0 ..< width {
//                for y in 0 ..< height {
//                    tiles[x][y].floorVariant = variantGrid[x, y]
//                }
//            }
//        }
//    // MARK: — 2) Generate walls ONLY on the outermost border
//
//    private func generateBorderWallsOnly() {
//        for x in 0 ..< width {
//            for y in 0 ..< height {
//                if x == 0 || x == width - 1 || y == 0 || y == height - 1 {
//                    tiles[x][y].block = .stoneWall
//                } else {
//                    tiles[x][y].block = .none
//                }
//                // Clear any ore/decor we might have set earlier
//                tiles[x][y].ore = .none
//                tiles[x][y].decor = .none
//            }
//        }
//    }
//
//    // MARK: — 3) Place ore ONLY inside those border walls
//
//    private func placeOresInWalls() {
//        // Build a small Perlin noise map for ore distribution
//        let oreNoiseSource = GKPerlinNoiseSource(
//            frequency: 0.8,
//            octaveCount: 3,
//            persistence: 0.5,
//            lacunarity: 2.0,
//            seed: Int32(bitPattern: UInt32(truncatingIfNeeded: seed ^ 0xC0FFEE))
//        )
//        let oreNoise = GKNoise(oreNoiseSource)
//        let oreNoiseMap = GKNoiseMap(
//            oreNoise,
//            size: vector_double2(Double(width) / 20.0, Double(height) / 20.0),
//            origin: vector_double2(0, 0),
//            sampleCount: vector_int2(Int32(width), Int32(height)),
//            seamless: false
//        )
//
//        for x in 0 ..< width {
//            for y in 0 ..< height {
//                // Only generate ore where there is a stoneWall
//                guard tiles[x][y].block == .stoneWall else {
//                    tiles[x][y].ore = .none
//                    continue
//                }
//                
//                let val = oreNoiseMap.value(at: vector_int2(Int32(x), Int32(y)))
//                let norm = (val + 1.0) / 2.0
//                let wallVariant = tiles[x][y].floorVariant
//                
//                // Clear ore first
//                tiles[x][y].ore = .none
//                
//                // Variant-specific ore spawning logic:
//                switch wallVariant {
//                case 0, 1, 2:
//                    // Wall variants 0, 1, 2 can have copper and titanium, but NO graphite
//                    if norm > 0.5 {
//                        tiles[x][y].ore = .copper
//                    }
//                    // Titanium is rarer and can spawn on walls 0,1,2
//                    if norm > 0.85 {
//                        tiles[x][y].ore = .titanium
//                    }
//                    
//                case 3:
//                    // Wall variant 3 can ONLY have graphite (no copper or titanium)
//                    if norm > 0.4 {  // Graphite is more common on variant 3 walls
//                        tiles[x][y].ore = .graphite
//                    }
//                    
//                default:
//                    // Safety case for any unexpected variants
//                    tiles[x][y].ore = .none
//                }
//            }
//        }
//    }
//
//    // MARK: — 4) Place vents & geysers on floor tiles (not on walls)
//
//    private func placeVentsAndGeysers() {
//        let rng = GKMersenneTwisterRandomSource(seed: seed ^ 0xDEADBEEF)
//        let minDistance = 3 // Minimum distance between any decorations
//        
//        // First, ensure all decor is cleared
//        for x in 0 ..< width {
//            for y in 0 ..< height {
//                tiles[x][y].decor = .none
//            }
//        }
//
//        for x in 1 ..< (width - 1) {
//            for y in 1 ..< (height - 1) {
//                // Skip if this tile is a wall
//                guard tiles[x][y].block == .none else {
//                    continue
//                }
//
//                // Check if there's already a decoration within minimum distance
//                if hasDecorationInRadius(x: x, y: y, radius: minDistance) {
//                    continue
//                }
//
//                // Check if this tile is adjacent to any wall - if so, skip it
//                var adjacentToWall = false
//                for dy in -1 ... 1 {
//                    for dx in -1 ... 1 {
//                        if dx == 0 && dy == 0 { continue }
//                        let nx = x + dx, ny = y + dy
//                        if nx >= 0 && nx < width && ny >= 0 && ny < height {
//                            if tiles[nx][ny].block == .stoneWall {
//                                adjacentToWall = true
//                                break
//                            }
//                        }
//                    }
//                    if adjacentToWall { break }
//                }
//                
//                // Skip this tile if it's adjacent to a wall
//                if adjacentToWall {
//                    continue
//                }
//
//                // A) 2% chance of a vent on floor tiles away from walls
//                if rng.nextUniform() < 0.002 {
//                    tiles[x][y].decor = .vent
//                    continue
//                }
//
//                // B) 2% chance of a geyser on floor tiles away from walls
//                if rng.nextUniform() < 0.003 {
//                    tiles[x][y].decor = .geyser
//                    continue
//                }
//            }
//        }
//
//        // Make sure border tiles remain decor‐free (safety check)
//        for x in 0 ..< width {
//            tiles[x][0].decor = .none
//            tiles[x][height - 1].decor = .none
//        }
//        for y in 0 ..< height {
//            tiles[0][y].decor = .none
//            tiles[width - 1][y].decor = .none
//        }
//    }
//
//    /// Helper method to check if there's any decoration within the specified radius
//    private func hasDecorationInRadius(x: Int, y: Int, radius: Int) -> Bool {
//        for dy in -radius...radius {
//            for dx in -radius...radius {
//                let nx = x + dx
//                let ny = y + dy
//                
//                // Skip out of bounds
//                if nx < 0 || nx >= width || ny < 0 || ny >= height {
//                    continue
//                }
//                
//                // Check if this tile has any decoration
//                if tiles[nx][ny].decor != .none {
//                    return true
//                }
//            }
//        }
//        return false
//    }
//}
//
//// MARK: — Small Extension for SwiftUI Color
//
//extension Color {
//    /// For convenience, create a Color from RGB easily.
//    init(r: Double, g: Double, b: Double) {
//        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
//    }
//}
//
//struct ContentView: View {
//    @State private var terrain: [[Tile]] = []
//    private let mapWidth  = 50
//    private let mapHeight = 50
//
//    var body: some View {
//        GeometryReader { geo in
//            if terrain.isEmpty {
//                // Show a spinner while generating
//                VStack {
//                    ProgressView("Generating Map…")
//                        .progressViewStyle(CircularProgressViewStyle())
//                        .padding()
//                }
//                .frame(maxWidth: .infinity, maxHeight: .infinity)
//                .onAppear {
//                    DispatchQueue.global(qos: .userInitiated).async {
//                        let generator = TerrainGenerator(
//                            width: mapWidth,
//                            height: mapHeight,
//                            seed: UInt64(Date().timeIntervalSince1970)
//                        )
//                        generator.generateAll()
//                        DispatchQueue.main.async {
//                            self.terrain = generator.tiles
//                        }
//                    }
//                }
//            } else {
//                // Calculate tile size
//                let tileSize = min(
//                    geo.size.width  / CGFloat(mapWidth),
//                    geo.size.height / CGFloat(mapHeight)
//                )
//
//                ScrollView([.vertical, .horizontal], showsIndicators: false) {
//                    ZStack(alignment: .topLeading) {
//                        // LAYER 1: Base terrain grid
//                        LazyVGrid(
//                            columns: Array(
//                                repeating: GridItem(.fixed(tileSize), spacing: 0),
//                                count: mapWidth
//                            ),
//                            spacing: 0
//                        ) {
//                            ForEach(0 ..< (mapWidth * mapHeight), id: \.self) { index in
//                                let x = index % mapWidth
//                                let y = index / mapWidth
//                                let tile = terrain[x][y]
//                                
//                                baseTileView(for: tile)
//                                    .frame(width: tileSize, height: tileSize)
//                                    .clipped()
//                                    .border(Color.black.opacity(0.05), width: 0.2)
//                            }
//                        }
//                        
//                        // LAYER 2: Vents and Geysers overlay (larger, positioned above everything)
//                        ventGeyserOverlay(tileSize: tileSize)
//                        
//                        // LAYER 3: Ore overlay (positioned exactly on top of grid)
//                        oreOverlay(tileSize: tileSize)
//                            .zIndex(1000)
//                    }
//                }
//            }
//        }
//        .edgesIgnoringSafeArea(.all)
//    }
//
//    /// Draw base tile without vents/geysers (these are rendered separately)
//    @ViewBuilder
//    private func baseTileView(for tile: Tile) -> some View {
//        ZStack {
//            // 1) FLOOR IMAGE (base layer)
//            let floorImage = "terrain\(tile.floorVariant)"
//            Image(floorImage)
//                .resizable()
//                .scaledToFill()
//
//            // 2) WALL IMAGE (if any) - overlaid on top
//            if tile.block == .stoneWall {
//                let wallImage = "wall\(tile.floorVariant)"
//                Image(wallImage)
//                    .resizable()
//                    .scaledToFill()
//            }
//
//            // 3) ORE TEXTURE OVERLAY (updated to use images)
////            if tile.ore != .none {
////                if let oreImageName = tile.ore.imageName {
////                    // Try to load the ore texture image
////                    Image("ore_copper")
////                        .resizable()
//////                        .scaledToFill()
//////                        .opacity(0.8)  // Slightly transparent so wall texture shows through
////                        //.scaleEffect(1)
////                        .onAppear {
////                            print("image")
////                        }
////                        .zIndex(100)
////                } else {
////                    // Fallback to colored rectangle if image not available
////                    Rectangle()
////                        .fill(tile.ore.fallbackColor)
////                        .opacity(0.7)
////                        .padding(2)
////                        .onAppear {
////                            print("fallback")
////                        }
////                }
////            }
//            
//            // Note: No vents/geysers here - they're rendered in the overlay
//        }
//    }
//    
//    /// Render all vents and geysers as an overlay on top of the base terrain
//    @ViewBuilder
//    private func ventGeyserOverlay(tileSize: CGFloat) -> some View {
//        // Create a view that positions vents/geysers at their exact coordinates
//        ForEach(0 ..< mapWidth, id: \.self) { x in
//            ForEach(0 ..< mapHeight, id: \.self) { y in
//                let tile = terrain[x][y]
//                
//                if tile.decor != .none {
//                    Group {
//                        switch tile.decor {
//                        case .vent:
//                            if let imgName = tile.decor.displayImageName {
//                                Image(imgName)
//                                    .resizable()
//                                    .frame(width: tileSize * 9, height: tileSize * 9)
//                            } else {
//                                // Fallback: draw a red circle if no asset
//                                Circle()
//                                    .fill(tile.decor.placeholderColor)
//                                    .frame(width: tileSize * 9, height: tileSize * 9)
//                            }
//                        case .geyser:
//                            if let imgName = tile.decor.displayImageName {
//                                Image(imgName)
//                                    .resizable()
//                                    .frame(width: tileSize * 9, height: tileSize * 9)
//                            } else {
//                                // Fallback: draw a pale‐blue circle if no asset
//                                Circle()
//                                    .fill(tile.decor.placeholderColor)
//                                    .frame(width: tileSize * 9, height: tileSize * 9)
//                            }
//                        default:
//                            EmptyView()
//                        }
//                    }
//                    .position(
//                        x: CGFloat(x) * tileSize + tileSize / 2,
//                        y: CGFloat(y) * tileSize + tileSize / 2
//                    )
//                    .allowsHitTesting(false)
//                }
//            }
//        }
//        .frame(
//            width: CGFloat(mapWidth) * tileSize,
//            height: CGFloat(mapHeight) * tileSize,
//            alignment: .topLeading
//        )
//    }
//    
//    @ViewBuilder
//    private func oreOverlay(tileSize: CGFloat) -> some View {
//        // Create a view that positions ore textures at their exact coordinates
//        ForEach(0 ..< mapWidth, id: \.self) { x in
//            ForEach(0 ..< mapHeight, id: \.self) { y in
//                let tile = terrain[x][y]
//                
//                if tile.ore != .none {
//                    Group {
//                        if let oreImageName = tile.ore.imageName {
//                            // Try to load the ore texture image
//                            Image(oreImageName)
//                                .resizable()
//                                .scaledToFill()
//                                .frame(width: tileSize, height: tileSize)
//                        } else {
//                            // Fallback to colored rectangle if image not available
//                            Rectangle()
//                                .fill(tile.ore.fallbackColor)
//                                .opacity(0.7)
//                                .frame(width: tileSize, height: tileSize)
//                                .padding(2)
//                        }
//                    }
//                    .position(
//                        x: CGFloat(x) * tileSize + tileSize / 2,
//                        y: CGFloat(y) * tileSize + tileSize / 2
//                    )
//                    .allowsHitTesting(false)
//                }
//            }
//        }
//        .frame(
//            width: CGFloat(mapWidth) * tileSize,
//            height: CGFloat(mapHeight) * tileSize,
//            alignment: .topLeading
//        )
//    }
//}
//
//struct ContentView_Previews: PreviewProvider {
//    static var previews: some View {
//        ContentView()
//    }
//}
