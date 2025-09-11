//
//  C.swift
//  Factdustry
//
//  Created by Bright on 7/24/25.
//

import SwiftUI
import UIKit
import Combine
import SwiftData

enum ConstructionState: Equatable {
    case underConstruction(progress: Double) // 0.0 ... 1.0
    case underDestruction(progress: Double)  // 0.0 ... 1.0
    case completed

    var isCompleted: Bool {
        switch self {
        case .completed: return true
        case .underConstruction, .underDestruction: return false
        }
    }

    var progress: Double {
        switch self {
        case .completed: return 1.0
        case .underConstruction(let p), .underDestruction(let p): return p
        }
    }

    var isDestruction: Bool {
        if case .underDestruction = self { return true }
        return false
    }
}

// MARK: - Enhanced BlockLoadingManager (Add these properties and methods to existing BlockLoadingManager in C.swift)

extension BlockLoadingManager {
    // FIXED: Add this method to start the construction timer with proper debugging
    func startConstructionTimer() {
        constructionTimer?.invalidate() // Make sure we don't have multiple timers
        
        constructionTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            self?.updateConstruction()
        }
    }
    
    // Add this method to stop the construction timer
    func stopConstructionTimer() {
        constructionTimer?.invalidate()
        constructionTimer = nil
    }
    
    // FIXED: Add this method to update construction progress with debugging
    private func updateConstruction() {
        guard !constructionProgress.isEmpty else { return }

        var completedBuilds: [UUID] = []
        var completedDestructions: [UUID] = []

        for (id, var prog) in constructionProgress {
            let wasDestruction = prog.state.isDestruction
            prog.updateProgress()
            constructionProgress[id] = prog

            if prog.state.isCompleted {
                if wasDestruction { completedDestructions.append(id) }
                else { completedBuilds.append(id) }
            }
        }

        for id in completedBuilds { completeConstruction(id: id) }
        for id in completedDestructions { completeDestruction(id: id) }
    }
    
    // FIXED: Add this method to complete construction with better ID handling
    private func completeConstruction(id: UUID) {
        guard let construction = constructionProgress[id] else {
            return
        }
        
        // Find and update the existing placeholder block
        if let existingIndex = placedBlocks.firstIndex(where: { block in
            block.x == construction.position.x && block.y == construction.position.y
        }) {
            // Update the existing block to mark it as completed
            let existingBlock = placedBlocks[existingIndex]
            let completedBlock = PlacedBlock(
                blockType: construction.blockType.iconName,
                x: construction.position.x,
                y: construction.position.y,
                iconName: construction.blockType.iconName,
                size: construction.blockType.size,
                rotation: construction.rotation,
                faction: existingBlock.faction // preserve whoever placed it
            )
            
            placedBlocks[existingIndex] = completedBlock
            
            // Create network node for the completed block
            let networkNode = NetworkNode(
                id: completedBlock.id,
                position: SIMD2<Int>(construction.position.x, construction.position.y),
                blockType: construction.blockType.iconName,
                connections: construction.blockType.connections,
                rotation: construction.rotation,
                blockSize: (width: construction.blockType.sizeX, height: construction.blockType.sizeY),
                capacity: construction.blockType.capacity
            )
            
            // Update ore types facing for drills if needed
            if let mapData = cachedMapData,
               (construction.blockType.iconName.contains("drill") || construction.blockType.iconName.contains("bore")) {
                networkNode.updateOreTypesFacing(mapData: mapData)
            }
            
            transmissionManager.addNode(networkNode)
        }
        
        // Remove from construction tracking
        constructionProgress.removeValue(forKey: id)
    }
    
    // FIXED: Add this method to start construction of a block with better debugging
    func startConstruction(blockType: BlockType, at position: (x: Int, y: Int), rotation: BlockRotation) -> UUID {
        let constructionId = UUID()
        let construction = ConstructionProgress(
            id: constructionId,
            blockType: blockType,
            position: position,
            rotation: rotation
        )
        
        // Create a placeholder placed block for visual purposes
        let placeholderBlock = PlacedBlock(
            blockType: blockType.iconName,
            x: position.x,
            y: position.y,
            iconName: blockType.iconName,
            size: blockType.size,
            rotation: rotation
        )
        
        placedBlocks.append(placeholderBlock)
        constructionProgress[constructionId] = construction
                
        // Make sure timer is running
        if constructionTimer == nil {
            startConstructionTimer()
        }
        
        return constructionId
    }
    
    // FIXED: Enhanced placement method with debugging
    func placeBlockWithResearchCheckAndConstruction(_ blockType: BlockType, at position: (x: Int, y: Int), rotation: BlockRotation, mapData: MapData? = nil, researchManager: ResearchManager) -> (success: Bool, reason: String?) {
        
        // Check research requirement first
        if researchManager.requireResearchForPlacement {
            let researchInfo = researchManager.getResearchInfo(for: blockType.iconName)
            
            if !researchInfo.isResearched {
                let reason: String
                if let techNodeName = researchInfo.techNodeName {
                    if researchInfo.canResearch {
                        reason = "Research '\(techNodeName)' first (available for research)"
                    } else {
                        reason = "Research '\(techNodeName)' first (prerequisites not met)"
                    }
                } else {
                    reason = "Research required (no tech mapping found)"
                }
                return (false, reason)
            }
        }
        
        // Check resource requirements
        if !blockType.buildCost.isEmpty {
            let hasResources = CoreInventoryManager.shared.hasEnoughResources(for: blockType.buildCost)
            
            if !hasResources {
                return (false, "Insufficient resources")
            }
        }
        
        // Check for collision and tile requirements
        let collisionCheck = wouldCollide(blockType: blockType, at: position, rotation: rotation, mapData: mapData)
        if collisionCheck.hasCollision {
            let reason = collisionCheck.reason ?? "Unknown collision"
            return (false, reason)
        }
        
        // All checks passed - consume resources and start construction
        if !blockType.buildCost.isEmpty {
            let resourcesConsumed = CoreInventoryManager.shared.consumeResources(for: blockType.buildCost)
            if !resourcesConsumed {
                return (false, "Failed to consume resources")
            }
        }
        
        // Store map data for later use
        self.cachedMapData = mapData
        
        // Start construction instead of instant placement
        let constructionId = startConstruction(blockType: blockType, at: position, rotation: rotation)
        
        return (true, nil)
    }
}

// FIXED: Enhanced ConstructionProgress with better debugging
struct ConstructionProgress: Identifiable {
    let id: UUID
    let blockType: BlockType
    let position: (x: Int, y: Int)
    let rotation: BlockRotation
    var state: ConstructionState
    let startTime: Date
    let buildTime: Double
    
    init(id: UUID, blockType: BlockType, position: (x: Int, y: Int), rotation: BlockRotation) {
        self.id = id
        self.blockType = blockType
        self.position = position
        self.rotation = rotation
        self.state = .underConstruction(progress: 0.0)
        self.startTime = Date()
        self.buildTime = blockType.buildTime
        
    }
    
    mutating func updateProgress() {
        let elapsed = Date().timeIntervalSince(startTime)
        let p = min(1.0, elapsed / buildTime)

        switch state {
        case .underConstruction:
            if p >= 1.0 {
                state = .completed
            } else {
                state = .underConstruction(progress: p)
            }
        case .underDestruction:
            if p >= 1.0 {
                state = .completed
            } else {
                state = .underDestruction(progress: p)
            }
        case .completed:
            break
        }
    }
}

// MARK: - Updated SingleBlockView with Construction Progress (Replace the existing SingleBlockView in D.swift)

struct SingleBlockViewWithConstruction: View {
    let block: PlacedBlock
    let mapData: MapData
    let tileSize: CGFloat
    let blockLibrary: [BlockCategory: [BlockType]]
    @ObservedObject var transmissionManager: TransmissionNetworkManager
    @ObservedObject var blockLoadingManager: BlockLoadingManager
    
    // Lookup
    private var construction: ConstructionProgress? {
        blockLoadingManager.constructionProgress.values.first {
            $0.position.x == block.x && $0.position.y == block.y
        }
    }
    
    // Separate progress by mode
    private var buildProgress: Double? {
        guard let c = construction else { return nil }
        if case .underConstruction(let p) = c.state { return max(0, min(1, p)) }
        return nil
    }
    private var destroyProgress: Double? {
        guard let c = construction else { return nil }
        if case .underDestruction(let p) = c.state { return max(0, min(1, p)) }
        return nil
    }
    private var isCompleted: Bool {
        guard let c = construction else { return true }
        return c.state.isCompleted
    }
    
    // UPDATED: Smart texture selection for corners
    private var displayIconName: String {
        if block.blockType == "conveyor-belt",
           let isCorner = blockLoadingManager.conveyorCornerStates[block.id],
           isCorner {
            let textureType = blockLoadingManager.conveyorCornerTextures[block.id] ?? "C"
            return "conveyor-belt-\(textureType)"
        } else {
            return block.iconName
        }
    }
    
    private var effectiveRotation: BlockRotation {
        if block.blockType == "conveyor-belt",
           let isCorner = blockLoadingManager.conveyorCornerStates[block.id],
           isCorner,
           let cornerRotation = blockLoadingManager.conveyorCornerRotations[block.id] {
            return BlockRotation(cornerRotation)
        }
        return block.rotation
    }
    
    private func getBlockType(for name: String) -> BlockType? {
        for (_, blocks) in blockLibrary {
            if let b = blocks.first(where: { $0.iconName == name }) { return b }
        }
        return nil
    }
    
    var body: some View {
        let blockType = getBlockType(for: block.blockType)
        let rotatedSize = blockType?.getRotatedSize(rotation: block.rotation) ?? (width: 1, height: 1)
        let targetDisplaySize = blockType?.size ?? block.size
        let scaledSize = targetDisplaySize * 0.8
        
        // Footprint
        let containerW = tileSize * CGFloat(rotatedSize.width)
        let containerH = tileSize * CGFloat(rotatedSize.height)
        
        // Map placement
        let blockX = CGFloat(block.x) * tileSize
        let blockY = CGFloat(block.y) * tileSize
        
        // Texture offset
        let textureOffset = blockType?.getRotatedTextureOffset(rotation: block.rotation) ?? .zero
        
        // Image with faction-aware tinting for non-player blocks
        
        // World rendering view for this block: for coreShardComplete, layer base + faction overlay; otherwise default standardized image
        let blockImage: AnyView = {
            let isCoreShard = (block.blockType == "coreShardComplete" || block.iconName == "coreShardComplete")
            if isCoreShard {
                let overlayName = (block.faction == .ferox) ? "coreShardOverlay-ferox" : "coreShardOverlay-lumina"
                let layered = ZStack {
                    Image("coreShardBase")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: scaledSize, height: scaledSize)
                    Image(overlayName)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: scaledSize, height: scaledSize)
                }
                .offset(x: textureOffset.x, y: textureOffset.y)
                return AnyView(layered)
            } else {
                let v = StandardizedBlockImageView(
                    iconName: displayIconName,
                    targetSize: scaledSize,
                    rotation: effectiveRotation
                )
                .compositingGroup()
                // Apply faction tint for enemy/other faction blocks
                .colorMultiply(block.faction == FactionManager.shared.playerFaction ? .white : block.faction.primaryColor.opacity(0.7))
                .offset(x: textureOffset.x, y: textureOffset.y)
                return AnyView(v)
            }
        }()
        
        ZStack {
            Group {
                if let p = buildProgress {
                    blockImage
                        .mask(
                            ZStack(alignment: .leading) {
                                Color.clear
                                Rectangle()
                                    .frame(width: containerW * CGFloat(p), height: containerH)
                            }
                                .frame(width: containerW, height: containerH)
                        )
                    
                } else if let d = destroyProgress {
                    let remaining = max(0.0, 1.0 - d)
                    blockImage
                        .mask(
                            ZStack(alignment: .leading) {
                                Color.clear
                                Rectangle()
                                    .frame(width: containerW * CGFloat(remaining), height: containerH)
                            }
                                .frame(width: containerW, height: containerH)
                        )
                    
                } else if isCompleted {
                    blockImage
                }
            }
            
            // NEW: Faction and status indicators
            HStack {
                Spacer()
                VStack(spacing: 2) {
                    // Power/active indicator
                    if transmissionManager.getNodePowerLevel(id: block.id) > 0 {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8))
                            .foregroundColor(transmissionManager.isNodeActive(id: block.id) ? .green : .red)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    
                    // NEW: Enemy targeting indicator for turrets
                    if block.blockType.contains("barrel") && block.faction != FactionManager.shared.playerFaction {
                        Image(systemName: "target")
                            .font(.system(size: 8))
                            .foregroundColor(.red)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                }
            }
            .padding(2)
        }
        .frame(width: containerW, height: containerH, alignment: .center)
        .position(x: blockX + containerW / 2, y: blockY + containerH / 2)
        .animation(.linear(duration: 0.08), value: buildProgress ?? -1)
        .animation(.linear(duration: 0.08), value: destroyProgress ?? -1)
        .allowsHitTesting(false)
    }
}

// MARK: - Enhanced BlockType with New Unified Connection System
struct BlockType: Identifiable, Equatable {
    let id = UUID()
    let iconName: String
    let size: CGFloat  // Display size for UI
    
    // Enhanced block properties
    var sizeX: Int
    var sizeY: Int
    var buildCost: [(ItemType, Int)]
    var buildTime: Double
    var processes: [Process]?
    var tileRequirement: TileRequirement?
    var canRotate: Bool
    var textureOffset: CGPoint
    var connections: [UniversalConnection] // NEW: Unified connection system
    var capacity: Int
    
    init(iconName: String,
         size: CGFloat = 20,
         sizeX: Int = 1,
         sizeY: Int = 1,
         buildCost: [(ItemType, Int)] = [],
         buildTime: Double = 1.0,
         processes: [Process]? = nil,
         tileRequirement: TileRequirement? = nil,
         canRotate: Bool = false,
         textureOffset: CGPoint = .zero,
         connections: [UniversalConnection] = [],
         capacity: Int = 100) {  // Default capacity of 100 for most blocks
        self.iconName = iconName
        self.size = size
        self.sizeX = sizeX
        self.sizeY = sizeY
        self.buildCost = buildCost
        self.buildTime = buildTime
        self.processes = processes
        self.tileRequirement = tileRequirement
        self.canRotate = canRotate
        self.textureOffset = textureOffset
        self.connections = connections
        self.capacity = capacity
    }
    
    /// Convert to BlockRotation-compatible dimensions
    var dimensions: CGSize {
        return CGSize(width: sizeX, height: sizeY)
    }
    
    // Helper method to get rotated dimensions using new rotation system
    func getRotatedSize(rotation: BlockRotation) -> (width: Int, height: Int) {
        let rotatedDimensions = rotation.applied(to: (width: sizeX, height: sizeY))
        return rotatedDimensions
    }
    
    // Helper method to get rotated texture offset using new rotation system
    func getRotatedTextureOffset(rotation: BlockRotation) -> CGPoint {
        return rotation.applied(to: textureOffset)
    }
    
    static func == (lhs: BlockType, rhs: BlockType) -> Bool {
        lhs.id == rhs.id
    }
}

enum BlockCategory: String, CaseIterable, Identifiable {
    var id: String { rawValue }
    
    case core
    case production
    case distribution
    case fluids
    case defense
    case turets
    case power
    case factory
    case units
    case payloads
    
    var iconName: String {
        switch self {
        case .core         : return "inset.filled.square"
        case .production   : return "gearshape"
        case .distribution : return "arrow.up.arrow.down"
        case .fluids       : return "pipe.and.drop"
        case .defense      : return "shield"
        case .turets       : return "dot.scope"
        case .power        : return "bolt"
        case .factory      : return "building.2"
        case .units        : return "person.2"
        case .payloads     : return "arrowtriangle.right.fill"
        }
    }
}

// MARK: - Core Schema Data Models

struct CoreSchemaMetadata: Codable {
    let width: Int
    let height: Int
    let name: String
}

struct FactionData: Codable {
    let tileTranslations: [String: String]
    let tiles: [String]
}

struct CoreSchemaData: Codable {
    let metadata: CoreSchemaMetadata
    let factions: [String: FactionData]
    
    // Legacy support for old format
    let tileTranslations: [String: String]?
    let tiles: [String]?
    
    // Helper to check if this is the new faction format
    var isNewFormat: Bool {
        return !factions.isEmpty
    }
    
    // Helper to get all factions
    var availableFactions: [String] {
        return Array(factions.keys)
    }
}

// MARK: - Enhanced PlacedBlock with New Rotation System
struct PlacedBlock: Identifiable, Equatable {
    let id = UUID()
    let blockType: String
    let x: Int
    let y: Int
    let iconName: String
    let size: CGFloat
    let rotation: BlockRotation
    let faction: Faction // NEW: Add faction to PlacedBlock
    
    init(blockType: String, x: Int, y: Int, iconName: String, size: CGFloat, rotation: BlockRotation = BlockRotation(), faction: Faction = .lumina) {
        self.blockType = blockType
        self.x = x
        self.y = y
        self.iconName = iconName
        self.size = size
        self.rotation = rotation
        self.faction = faction
    }
    
    // Helper method to get rotation angle in degrees
    var rotationDegrees: Double {
        return rotation.degrees
    }
    
    // MARK: - Equatable Implementation
    static func == (lhs: PlacedBlock, rhs: PlacedBlock) -> Bool {
        return lhs.id == rhs.id
    }
}

extension BlockLoadingManager {
    func loadBlocksFromCoreSchema(fileIdentifier: String, mapData: MapData? = nil) {
        isLoading = true
        loadingError = nil
        placedBlocks.removeAll()
        
        guard !fileIdentifier.isEmpty else {
            isLoading = false
            return
        }
        
        let fileName = "CoreScem_\(fileIdentifier)"
        
        guard let fileURL = Bundle.main.url(forResource: fileName, withExtension: "json") else {
            print("❌ Could not find file: \(fileName).json")
            isLoading = false
            return
        }
        
        do {
            let data = try Data(contentsOf: fileURL)
            let coreSchema = try JSONDecoder().decode(CoreSchemaData.self, from: data)
            
            print("📄 Loaded schema with \(coreSchema.factions.count) factions")
            
            if coreSchema.isNewFormat {
                print("🆕 Using new faction-based format")
                // New faction-based format
                parseAndPlaceBlocksFromFactions(from: coreSchema, mapData: mapData)
            } else {
                print("🔄 Using legacy format")
                // Legacy format compatibility
                parseAndPlaceBlocksLegacy(from: coreSchema, mapData: mapData)
            }
            
        } catch {
            let errorMessage = "Failed to load CoreScem file: \(error.localizedDescription)"
            print("❌ \(errorMessage)")
            loadingError = errorMessage
        }
        
        isLoading = false
    }
    
    // New method to handle faction-based format (Add this method)
    private func parseAndPlaceBlocksFromFactions(from schema: CoreSchemaData, mapData: MapData? = nil) {
        var newBlocks: [PlacedBlock] = []
        var processedPositions: Set<String> = []
        
        print("🏭 Processing \(schema.factions.count) factions...")
        
        // Process each faction
        for (factionName, factionData) in schema.factions {
            print("🔍 Processing faction: \(factionName)")
            print("  - Tile translations: \(factionData.tileTranslations)")
            print("  - Tiles count: \(factionData.tiles.count)")
            
            // Process tiles for this faction
            for (y, row) in factionData.tiles.enumerated() {
                for (x, char) in row.enumerated() {
                    let charString = String(char)
                    let positionKey = "\(x),\(y)"
                    
                    // Skip if already processed or blank
                    if processedPositions.contains(positionKey) {
                        continue
                    }
                    
                    if charString == " " || factionData.tileTranslations[charString] == "blank" {
                        continue
                    }
                    
                    // Look up block type from faction's tile translations
                    if let schemaBlockType = factionData.tileTranslations[charString] {
                        print("  - Found tile '\(charString)' at (\(x),\(y)) -> \(schemaBlockType)")
                        
                        if let blockType = findBlockTypeFromSchema(schemaBlockType: schemaBlockType) {
                            print("    ✅ Mapped to block type: \(blockType.iconName)")
                            
                            let gridX = x
                            let gridY = y
                            
                            // Mark occupied positions
                            for blockX in gridX..<(gridX + blockType.sizeX) {
                                for blockY in gridY..<(gridY + blockType.sizeY) {
                                    processedPositions.insert("\(blockX),\(blockY)")
                                }
                            }
                            
                            // Check if PlacedBlock supports faction parameter
                            let block: PlacedBlock
                            if factionName.lowercased() == "lumina" {
                                // Player faction blocks - no special faction parameter needed
                                block = PlacedBlock(
                                    blockType: blockType.iconName,
                                    x: gridX,
                                    y: gridY,
                                    iconName: blockType.iconName,
                                    size: blockType.size,
                                    rotation: BlockRotation()
                                )
                            } else {
                                // Try to create with faction if supported, otherwise use default
                                let factionEnum = Faction(rawValue: factionName.lowercased()) ?? .neutral

                                block = PlacedBlock(
                                    blockType: blockType.iconName,
                                    x: gridX,
                                    y: gridY,
                                    iconName: blockType.iconName,
                                    size: blockType.size,
                                    rotation: BlockRotation(),
                                    faction: factionEnum
                                )
                            }
                            
                            newBlocks.append(block)
                            print("    📦 Created block at (\(gridX), \(gridY))")
                            
                            // Create network node
                            let networkNode = NetworkNode(
                                id: block.id,
                                position: SIMD2<Int>(gridX, gridY),
                                blockType: blockType.iconName,
                                connections: blockType.connections,
                                rotation: BlockRotation(),
                                blockSize: (width: blockType.sizeX, height: blockType.sizeY),
                                capacity: blockType.capacity
                            )
                            
                            // Set faction if supported
                            // networkNode.faction = faction  // Uncomment if NetworkNode supports faction
                            
                            // Update ore types for drills
                            if let mapData = mapData, (blockType.iconName.contains("drill") || blockType.iconName.contains("bore")) {
                                networkNode.updateOreTypesFacing(mapData: mapData)
                            }
                            
                            transmissionManager.addNode(networkNode)
                            print("    🔗 Added network node")
                            
                        } else {
                            print("    ❌ Could not find block type for: \(schemaBlockType)")
                        }
                    }
                }
            }
        }
        
        print("📦 Created \(newBlocks.count) total blocks")
        
        DispatchQueue.main.async {
            self.placedBlocks = newBlocks
            print("✅ Updated placedBlocks with \(newBlocks.count) blocks")
        }
    }
    
    // Legacy method for old format (Add this method)
    private func parseAndPlaceBlocksLegacy(from schema: CoreSchemaData, mapData: MapData? = nil) {
        guard let tiles = schema.tiles, let tileTranslations = schema.tileTranslations else {
            print("❌ Legacy format missing tiles or tileTranslations")
            return
        }
        
        print("🔄 Processing legacy format with \(tiles.count) tile rows")
        
        var newBlocks: [PlacedBlock] = []
        var processedPositions: Set<String> = []
        
        for (y, row) in tiles.enumerated() {
            for (x, char) in row.enumerated() {
                let charString = String(char)
                let positionKey = "\(x),\(y)"
                
                if processedPositions.contains(positionKey) {
                    continue
                }
                
                if charString == " " || tileTranslations[charString] == "blank" {
                    continue
                }
                
                if let schemaBlockType = tileTranslations[charString] {
                    print("  - Found tile '\(charString)' at (\(x),\(y)) -> \(schemaBlockType)")
                    
                    if let blockType = findBlockTypeFromSchema(schemaBlockType: schemaBlockType) {
                        print("    ✅ Mapped to block type: \(blockType.iconName)")
                        
                        let gridX = x
                        let gridY = y
                        
                        for blockX in gridX..<(gridX + blockType.sizeX) {
                            for blockY in gridY..<(gridY + blockType.sizeY) {
                                processedPositions.insert("\(blockX),\(blockY)")
                            }
                        }
                        
                        let block = PlacedBlock(
                            blockType: blockType.iconName,
                            x: gridX,
                            y: gridY,
                            iconName: blockType.iconName,
                            size: blockType.size,
                            rotation: BlockRotation()
                        )
                        
                        newBlocks.append(block)
                        print("    📦 Created block at (\(gridX), \(gridY))")
                        
                        let networkNode = NetworkNode(
                            id: block.id,
                            position: SIMD2<Int>(gridX, gridY),
                            blockType: blockType.iconName,
                            connections: blockType.connections,
                            rotation: BlockRotation(),
                            blockSize: (width: blockType.sizeX, height: blockType.sizeY),
                            capacity: blockType.capacity
                        )
                        
                        if let mapData = mapData, (blockType.iconName.contains("drill") || blockType.iconName.contains("bore")) {
                            networkNode.updateOreTypesFacing(mapData: mapData)
                        }
                        
                        transmissionManager.addNode(networkNode)
                        print("    🔗 Added network node")
                        
                    } else {
                        print("    ❌ Could not find block type for: \(schemaBlockType)")
                    }
                }
            }
        }
        
        print("📦 Created \(newBlocks.count) total blocks")
        
        DispatchQueue.main.async {
            self.placedBlocks = newBlocks
            print("✅ Updated placedBlocks with \(newBlocks.count) blocks")
        }
    }
}

extension BlockLoadingManager {
    func placeBlockWithFaction(_ blockType: BlockType, at position: (x: Int, y: Int), rotation: BlockRotation, faction: Faction = .lumina, mapData: MapData? = nil, researchManager: ResearchManager) -> (success: Bool, reason: String?) {
        
        // Check research requirement first
        if researchManager.requireResearchForPlacement {
            let researchInfo = researchManager.getResearchInfo(for: blockType.iconName)
            
            if !researchInfo.isResearched {
                let reason: String
                if let techNodeName = researchInfo.techNodeName {
                    if researchInfo.canResearch {
                        reason = "Research '\(techNodeName)' first (available for research)"
                    } else {
                        reason = "Research '\(techNodeName)' first (prerequisites not met)"
                    }
                } else {
                    reason = "Research required (no tech mapping found)"
                }
                return (false, reason)
            }
        }
        
        // Only check resources for player faction
        if faction == FactionManager.shared.playerFaction && !blockType.buildCost.isEmpty {
            let hasResources = CoreInventoryManager.shared.hasEnoughResources(for: blockType.buildCost)
            
            if !hasResources {
                return (false, "Insufficient resources")
            }
        }
        
        // Check for collision and tile requirements
        let collisionCheck = wouldCollide(blockType: blockType, at: position, rotation: rotation, mapData: mapData)
        if collisionCheck.hasCollision {
            let reason = collisionCheck.reason ?? "Unknown collision"
            return (false, reason)
        }
        
        // All checks passed - consume resources and place the block
        if faction == FactionManager.shared.playerFaction && !blockType.buildCost.isEmpty {
            let resourcesConsumed = CoreInventoryManager.shared.consumeResources(for: blockType.buildCost)
            if !resourcesConsumed {
                return (false, "Failed to consume resources")
            }
        }
        
        // Place the block with faction
        placeBlockWithFaction(blockType, at: position, rotation: rotation, faction: faction, mapData: mapData)
        
        // Update faction stats
        FactionManager.shared.incrementBlocksOwned(for: faction)
        
        return (true, nil)
    }
    
    private func placeBlockWithFaction(_ blockType: BlockType, at position: (x: Int, y: Int), rotation: BlockRotation, faction: Faction, mapData: MapData? = nil) {
        // Check for collision and tile requirements before placing
        let collisionCheck = wouldCollide(blockType: blockType, at: position, rotation: rotation, mapData: mapData)
        if collisionCheck.hasCollision {
            return
        }
        
        // Create new block with faction
        let newBlock = PlacedBlock(
            blockType: blockType.iconName,
            x: position.x,
            y: position.y,
            iconName: blockType.iconName,
            size: blockType.size,
            rotation: rotation,
            faction: faction
        )
        
        // Add or replace block
        if let existingIndex = placedBlocks.firstIndex(where: { $0.x == position.x && $0.y == position.y }) {
            let oldBlock = placedBlocks[existingIndex]
            placedBlocks[existingIndex] = newBlock
            transmissionManager.removeNode(id: oldBlock.id)
            FactionManager.shared.decrementBlocksOwned(for: oldBlock.faction)
        } else {
            placedBlocks.append(newBlock)
        }
        
        // Create network node with faction
        let networkNode = NetworkNode(
            id: newBlock.id,
            position: SIMD2<Int>(position.x, position.y),
            blockType: blockType.iconName,
            connections: blockType.connections,
            rotation: rotation,
            blockSize: (width: blockType.sizeX, height: blockType.sizeY),
            capacity: blockType.capacity
        )
        
        // Set faction for the node
        networkNode.faction = faction
        
        // Update ore types facing for drills
        if let mapData = mapData, (blockType.iconName.contains("drill") || blockType.iconName.contains("bore")) {
            networkNode.updateOreTypesFacing(mapData: mapData)
        }
        
        transmissionManager.addNode(networkNode)
    }
}

// MARK: - Camera Controller
class CameraController: ObservableObject {
    @Published var offset = CGPoint(x: 190, y: 115)
    @Published var zoomScale: CGFloat = 1.0
    @Published var velocity = CGVector.zero
    
    // NEW: Follow target properties
    @Published var followTarget: CGPoint? = nil
    @Published var isFollowing: Bool = false
    private var followViewSize: CGSize = CGSize(width: 800, height: 600)
    
    let moveSpeed: CGFloat = 400
    let maxZoom: CGFloat = 3.0
    let minZoom: CGFloat = 0.5
    
    private var moveTimer: Timer?
    private var lastMoveTime = Date()
    private var currentDirection: MoveDirection?
    private var lastOffset = CGPoint(x: 190, y: 115)
    
    // NEW: Set follow target and enable following
    func setFollowTarget(_ worldPosition: CGPoint, viewSize: CGSize) {
        followTarget = worldPosition
        followViewSize = viewSize
        isFollowing = true
        
        // Immediately center on target
        updateCameraForFollow()
    }
    
    // NEW: Stop following
    func stopFollowing() {
        isFollowing = false
        followTarget = nil
    }
    
    // NEW: Update camera position to follow target
    private func updateCameraForFollow() {
        guard isFollowing, let target = followTarget else { return }
        
        let centerX = followViewSize.width / 2
        let centerY = followViewSize.height / 2
        
        // Calculate offset to center the target on screen
        let newOffsetX = centerX - (target.x * zoomScale)
        let newOffsetY = centerY - (target.y * zoomScale)
        
        // Smooth camera movement
        withAnimation(.easeOut(duration: 0.1)) {
            offset = CGPoint(x: newOffsetX, y: newOffsetY)
        }
    }
    
    // NEW: Update follow target position (called when shardling moves)
    func updateFollowTarget(_ worldPosition: CGPoint) {
        guard isFollowing else { return }
        followTarget = worldPosition
        updateCameraForFollow()
    }
    
    func startMoving(direction: MoveDirection) {
        // Disable following when user manually moves camera
        if isFollowing {
            stopFollowing()
        }
        
        if currentDirection != direction || moveTimer == nil {
            stopMoving()
            currentDirection = direction
            lastMoveTime = Date()
            lastOffset = offset
            
            performMove(direction: direction)
            
            moveTimer = Timer.scheduledTimer(withTimeInterval: 1/60.0, repeats: true) { _ in
                self.performMove(direction: direction)
            }
        }
    }
    
    private func performMove(direction: MoveDirection) {
        let currentTime = Date()
        let deltaTime = currentTime.timeIntervalSince(lastMoveTime)
        lastMoveTime = currentTime
        
        let moveDistance = moveSpeed * CGFloat(deltaTime) / zoomScale
        let previousOffset = offset
        
        DispatchQueue.main.async {
            switch direction {
case .up:
    self.offset.y += moveDistance
case .down:
    self.offset.y -= moveDistance
case .left:
    self.offset.x += moveDistance
case .right:
    self.offset.x -= moveDistance
case .upLeft:
    let d = moveDistance / CGFloat(2).squareRoot()
    self.offset.y += d
    self.offset.x += d
case .upRight:
    let d = moveDistance / CGFloat(2).squareRoot()
    self.offset.y += d
    self.offset.x -= d
case .downLeft:
    let d = moveDistance / CGFloat(2).squareRoot()
    self.offset.y -= d
    self.offset.x += d
case .downRight:
    let d = moveDistance / CGFloat(2).squareRoot()
    self.offset.y -= d
    self.offset.x -= d
}
            
            // Calculate velocity for shardling drift effect
            let deltaOffset = CGPoint(x: self.offset.x - previousOffset.x, y: self.offset.y - previousOffset.y)
            self.velocity = CGVector(dx: deltaOffset.x / CGFloat(deltaTime), dy: deltaOffset.y / CGFloat(deltaTime))
        }
    }
    
    func stopMoving() {
        moveTimer?.invalidate()
        moveTimer = nil
        currentDirection = nil
        
        // Gradually reduce velocity when stopping
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.3)) {
                self.velocity = CGVector.zero
            }
        }
    }
    
    func zoom(by factor: CGFloat) {
        zoomScale = min(max(zoomScale * factor, minZoom), maxZoom)
        
        // Update follow camera position when zooming
        if isFollowing {
            updateCameraForFollow()
        }
    }
    
    func resetCamera() {
        offset = CGPoint(x: 190, y: 115)
        velocity = CGVector.zero
        stopFollowing()
    }
    
    func centerOnPosition(worldPosition: CGPoint, viewSize: CGSize) {
        let centerX = viewSize.width / 2
        let centerY = viewSize.height / 2
        
        // Calculate offset to center the world position on screen
        let newOffsetX = centerX - (worldPosition.x * zoomScale)
        let newOffsetY = centerY - (worldPosition.y * zoomScale)
        
        withAnimation(.easeInOut(duration: 1.0)) {
            offset = CGPoint(x: newOffsetX, y: newOffsetY)
        }
    }
    
    func screenToTileCoordinates(screenPoint: CGPoint, mapSize: CGSize, tileSize: CGFloat) -> (x: Int, y: Int) {
        // Account for camera transformations
        let worldX = (screenPoint.x - offset.x) / zoomScale
        let worldY = (screenPoint.y - offset.y) / zoomScale
        
        // Use floor() instead of Int() for more predictable behavior
        let tileX = Int(floor(worldX / tileSize))
        let tileY = Int(floor(worldY / tileSize))
        
        return (x: tileX, y: tileY)
    }
}

enum MoveDirection {
    case up, down, left, right
    case upLeft, upRight, downLeft, downRight
}

// MARK: - Keyboard Handler
struct KeyboardHandler: UIViewRepresentable {
    let onKeyDown: (String) -> Void
    let onKeyUp: (String) -> Void
    
    func makeUIView(context: Context) -> UIView {
        let view = KeyboardCapturingView()
        view.onKeyDown = onKeyDown
        view.onKeyUp = onKeyUp
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {}
}

class KeyboardCapturingView: UIView {
    var onKeyDown: ((String) -> Void)?
    var onKeyUp: ((String) -> Void)?
    
    override var canBecomeFirstResponder: Bool { true }
    
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        DispatchQueue.main.async {
            _ = self.becomeFirstResponder()
        }
    }
    
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            
            // Check for shift keys specifically
            if key.keyCode == .keyboardLeftShift || key.keyCode == .keyboardRightShift {
                onKeyDown?("shift")
                handled = true
            }
            if key.keyCode == .keyboardLeftControl || key.keyCode == .keyboardRightControl {
                onKeyDown?("ctrl")
                handled = true
            }
            
            // Handle regular keys
            let character = key.charactersIgnoringModifiers.lowercased()
            if !character.isEmpty && ["w", "a", "s", "d", "r", "x", " ", "q", "e"].contains(character) {
                onKeyDown?(character)
                handled = true
            }
        }
        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }
    
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            
            // Check for shift keys specifically - FIXED: proper parentheses grouping
            if key.keyCode == .keyboardLeftShift || key.keyCode == .keyboardRightShift {
                onKeyUp?("shift")
                handled = true
            }
            if key.keyCode == .keyboardLeftControl || key.keyCode == .keyboardRightControl {
                onKeyUp?("ctrl")
                handled = true
            }
            
            // Handle regular keys
            let character = key.charactersIgnoringModifiers.lowercased()
            if !character.isEmpty && ["w", "a", "s", "d", "r", "x", " ", "q", "e"].contains(character) {
                onKeyUp?(character)
                handled = true
            }
        }
        if !handled {
            super.pressesEnded(presses, with: event)
        }
    }
    
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Handle cancelled presses (like when shift is released)
        for press in presses {
            if press.key?.keyCode == .keyboardLeftShift || press.key?.keyCode == .keyboardRightShift {
                onKeyUp?("shift")
            }
            if press.key?.keyCode == .keyboardLeftControl || press.key?.keyCode == .keyboardRightControl {
                onKeyUp?("ctrl")
            }
        }
        super.pressesCancelled(presses, with: event)
    }
}

// MARK: - Enhanced Block Loading Manager with New Transmission System

class BlockLoadingManager: ObservableObject {
    @Published var placedBlocks: [PlacedBlock] = []
    @Published var isLoading = false
    @Published var loadingError: String?
    @Published var conveyorCornerStates: [UUID: Bool] = [:]
    @Published var conveyorCornerRotations: [UUID: Int] = [:]
    @Published var conveyorCornerTextures: [UUID: String] = [:] // NEW: Store texture type ("C" or "CA")
    
    // NEW: Single transmission manager handles everything
    private let transmissionManager = TransmissionNetworkManager()
    private let blockLibrary: [BlockCategory: [BlockType]]
    
    @Published var constructionProgress: [UUID: ConstructionProgress] = [:]
    private var constructionTimer: Timer? = nil
    private var cachedMapData: MapData? = nil
    
    init(blockLibrary: [BlockCategory: [BlockType]]) {
        self.blockLibrary = blockLibrary
        setupConveyorCornerObserver()
        transmissionManager.blockManager = self
        transmissionManager.blockLoadingManager = self // ADDED: Set the reference
        startConstructionTimer() // Add this line
    }
    
    deinit {
        stopConstructionTimer()
    }
    
    func setupConveyorCornerObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConveyorCornerUpdate),
            name: .conveyorBeltCornerUpdate,
            object: nil
        )
    }

    // UPDATED: Enhanced corner update handler with texture support
    @objc private func handleConveyorCornerUpdate(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let nodeId = userInfo["nodeId"] as? UUID,
              let isCorner = userInfo["isCorner"] as? Bool else { return }
        
        DispatchQueue.main.async {
            self.conveyorCornerStates[nodeId] = isCorner
            
            if isCorner {
                // Store texture type and rotation if provided
                if let textureType = userInfo["textureType"] as? String {
                    self.conveyorCornerTextures[nodeId] = textureType
                }
                if let rotation = userInfo["rotation"] as? Int {
                    self.conveyorCornerRotations[nodeId] = rotation
                }
            } else {
                // Clear corner data
                self.conveyorCornerTextures.removeValue(forKey: nodeId)
                self.conveyorCornerRotations.removeValue(forKey: nodeId)
            }
        }
        
    }
    
    var networkManager: TransmissionNetworkManager {
        return transmissionManager
    }
    
    func findCorePosition() -> CGPoint? {
        // Find any core block
        guard let coreBlock = placedBlocks.first(where: { block in
            let iconName = block.iconName.lowercased()
            let blockType = block.blockType.lowercased()
            return iconName.contains("core") || blockType.contains("core") ||
                   iconName.contains("shard") || blockType.contains("shard")
        }) else {
            return nil
        }
        
        // Get the block type to determine size
        var width: CGFloat = 1, height: CGFloat = 1
        for (_, blocks) in blockLibrary {
            if let blockType = blocks.first(where: { $0.iconName == coreBlock.iconName }) {
                width = CGFloat(blockType.sizeX)
                height = CGFloat(blockType.sizeY)
                break
            }
        }
        
        // Return center position in world coordinates (tiles)
        let centerX = CGFloat(coreBlock.x) + width / 2.0
        let centerY = CGFloat(coreBlock.y) + height / 2.0
        return CGPoint(x: centerX * 32, y: centerY * 32) // Convert to pixels
    }
    
    // Begin destruction animation at a position
    func startDestruction(at position: (x: Int, y: Int)) {
        guard let block = getBlock(at: position),
              let blockType = getBlockType(for: block.iconName) else { return }

        let id = UUID()
        var progress = ConstructionProgress(
            id: id,
            blockType: blockType,
            position: position,
            rotation: block.rotation
        )
        progress.state = .underDestruction(progress: 0.0)
        constructionProgress[id] = progress

        // Ensure timer is running
        if constructionTimer == nil { startConstructionTimer() }
    }

    // Finish destruction: remove the block + network node
    private func completeDestruction(id: UUID) {
        guard let progress = constructionProgress[id] else { return }

        // Remove placed block at that position
        if let idx = placedBlocks.firstIndex(where: { $0.x == progress.position.x && $0.y == progress.position.y }) {
            let removed = placedBlocks.remove(at: idx)
            transmissionManager.removeNode(id: removed.id)
        }

        constructionProgress.removeValue(forKey: id)
    }
    
    // MARK: - Enhanced Collision Detection with New Tile Requirement System
    func wouldCollide(blockType: BlockType, at position: (x: Int, y: Int), rotation: BlockRotation, mapData: MapData? = nil) -> (hasCollision: Bool, reason: String?) {
        let rotatedSize = blockType.getRotatedSize(rotation: rotation)
        
        // Check physical collision with other blocks first
        for blockX in position.x..<(position.x + rotatedSize.width) {
            for blockY in position.y..<(position.y + rotatedSize.height) {
                // Check if any existing block occupies this tile
                for existingBlock in placedBlocks {
                    // Get the block type for the existing block to determine its size
                    if let existingBlockType = getBlockType(for: existingBlock.iconName) {
                        let existingRotatedSize = existingBlockType.getRotatedSize(rotation: existingBlock.rotation)
                        let existingEndX = existingBlock.x + existingRotatedSize.width
                        let existingEndY = existingBlock.y + existingRotatedSize.height
                        
                        if blockX >= existingBlock.x && blockX < existingEndX &&
                           blockY >= existingBlock.y && blockY < existingEndY {
                            return (true, "Space occupied by \(existingBlock.iconName)")
                        }
                    } else {
                        // Fallback: assume 1x1 size for unknown blocks
                        if blockX == existingBlock.x && blockY == existingBlock.y {
                            return (true, "Space occupied")
                        }
                    }
                }
            }
        }
        
        // Check map boundaries
        if position.x < 0 || position.y < 0 {
            return (true, "Cannot place outside map boundaries")
        }
        
        if let mapData = mapData {
            let endX = position.x + rotatedSize.width
            let endY = position.y + rotatedSize.height
            
            if endX > mapData.width || endY > mapData.height {
                return (true, "Block extends outside map boundaries")
            }
            
            // Check tile requirements using the new system
            if let requirement = blockType.tileRequirement {
                let validation = requirement.validate(
                    blockSize: (width: blockType.sizeX, height: blockType.sizeY),
                    at: position,
                    rotation: rotation,
                    mapData: mapData
                )
                
                if !validation.isValid {
                    return (true, validation.failureReason ?? "Tile requirement not met")
                }
            }
        }
        
        return (false, nil) // No collision
    }
    
    // MARK: - Enhanced Placement Methods with Better Error Reporting and Network Updates
    
    /// Enhanced placement method that provides detailed feedback
    func placeBlockWithResearchCheck(_ blockType: BlockType, at position: (x: Int, y: Int), rotation: BlockRotation, mapData: MapData? = nil, researchManager: ResearchManager) -> (success: Bool, reason: String?) {
        
        // Check research requirement first
        if researchManager.requireResearchForPlacement {
            let researchInfo = researchManager.getResearchInfo(for: blockType.iconName)
            
            if !researchInfo.isResearched {
                let reason: String
                if let techNodeName = researchInfo.techNodeName {
                    if researchInfo.canResearch {
                        reason = "Research '\(techNodeName)' first (available for research)"
                    } else {
                        reason = "Research '\(techNodeName)' first (prerequisites not met)"
                    }
                } else {
                    reason = "Research required (no tech mapping found)"
                }
                return (false, reason)
            }
        }
        
        // NEW: Check resource requirements
        if !blockType.buildCost.isEmpty {
            let hasResources = CoreInventoryManager.shared.hasEnoughResources(for: blockType.buildCost)
            
            if !hasResources {
                return (false, "Insufficient resources")
            }
        }
        
        // Check for collision and tile requirements
        let collisionCheck = wouldCollide(blockType: blockType, at: position, rotation: rotation, mapData: mapData)
        if collisionCheck.hasCollision {
            let reason = collisionCheck.reason ?? "Unknown collision"
            return (false, reason)
        }
        
        // All checks passed - consume resources and place the block
        if !blockType.buildCost.isEmpty {
            let resourcesConsumed = CoreInventoryManager.shared.consumeResources(for: blockType.buildCost)
            if !resourcesConsumed {
                return (false, "Failed to consume resources")
            }
        }
        
        // Place the block (now with ore detection)
        placeBlock(blockType, at: position, rotation: rotation, mapData: mapData)
        return (true, nil)
    }

    
    /// Updated placement method with network updates
    func placeBlock(_ blockType: BlockType, at position: (x: Int, y: Int), rotation: BlockRotation, mapData: MapData? = nil) {
        // Check for collision and tile requirements before placing
        let collisionCheck = wouldCollide(blockType: blockType, at: position, rotation: rotation, mapData: mapData)
        if collisionCheck.hasCollision {
            return
        }
        
        // Create new block
        let newBlock = PlacedBlock(
            blockType: blockType.iconName,
            x: position.x,
            y: position.y,
            iconName: blockType.iconName,
            size: blockType.size,
            rotation: rotation
        )
        
        // Add or replace block
        if let existingIndex = placedBlocks.firstIndex(where: { $0.x == position.x && $0.y == position.y }) {
            let oldBlock = placedBlocks[existingIndex]
            placedBlocks[existingIndex] = newBlock
            transmissionManager.removeNode(id: oldBlock.id)
        } else {
            placedBlocks.append(newBlock)
        }
        
        // Create network node for the new transmission system with block size
        let networkNode = NetworkNode(
            id: newBlock.id,
            position: SIMD2<Int>(position.x, position.y),
            blockType: blockType.iconName,
            connections: blockType.connections,
            rotation: rotation,
            blockSize: (width: blockType.sizeX, height: blockType.sizeY),
            capacity: blockType.capacity
        )
        
        // NEW: Update ore types facing for drills
        if let mapData = mapData, (blockType.iconName.contains("drill") || blockType.iconName.contains("bore")) {
            networkNode.updateOreTypesFacing(mapData: mapData)
        }
        
        transmissionManager.addNode(networkNode)
    }

    
    /// Get detailed placement info for UI feedback
    func getPlacementInfo(for blockType: BlockType, at position: (x: Int, y: Int), rotation: BlockRotation, mapData: MapData?, researchManager: ResearchManager) -> (canPlace: Bool, reason: String?, requirement: String?, resourceStatus: String?) {
        
        // Check research first
        if researchManager.requireResearchForPlacement {
            let researchInfo = researchManager.getResearchInfo(for: blockType.iconName)
            if !researchInfo.isResearched {
                let reason = researchInfo.techNodeName.map { "Research '\($0)' required" } ?? "Research required"
                return (false, reason, nil, nil)
            }
        }
        
        // Check resources
        var resourceStatus: String? = nil
        var canAfford = true
        
        if !blockType.buildCost.isEmpty {
            canAfford = CoreInventoryManager.shared.hasEnoughResources(for: blockType.buildCost)
            resourceStatus = CoreInventoryManager.shared.formatBuildCostWithAvailability(for: blockType.buildCost)
            
            if !canAfford {
                return (false, "Insufficient resources", blockType.tileRequirement?.description, resourceStatus)
            }
        }
        
        // Check collision
        let collisionCheck = wouldCollide(blockType: blockType, at: position, rotation: rotation, mapData: mapData)
        if collisionCheck.hasCollision {
            return (false, collisionCheck.reason, blockType.tileRequirement?.description, resourceStatus)
        }
        
        // Get requirement description for UI
        let requirementDesc = blockType.tileRequirement?.description
        return (true, nil, requirementDesc, resourceStatus)
    }
    
    func removeBlock(at position: (x: Int, y: Int)) {
        if let blockIndex = placedBlocks.firstIndex(where: { $0.x == position.x && $0.y == position.y }) {
            let block = placedBlocks[blockIndex]
            placedBlocks.remove(at: blockIndex)
            transmissionManager.removeNode(id: block.id)
        }
    }
    
    func getBlock(at position: (x: Int, y: Int)) -> PlacedBlock? {
        return placedBlocks.first { $0.x == position.x && $0.y == position.y }
    }
    
    private func getBlockType(for iconName: String) -> BlockType? {
        // Search through the block library to find the block type by icon name
        for (_, blocks) in blockLibrary {
            for block in blocks {
                if block.iconName == iconName {
                    return block
                }
            }
        }
        return nil
    }
    
    private func parseAndPlaceBlocks(from schema: CoreSchemaData, mapData: MapData? = nil) {
        var newBlocks: [PlacedBlock] = []
        var processedPositions: Set<String> = [] // Track positions to avoid duplicates for multi-tile blocks
        
        // Iterate through each row of tiles
        for (y, row) in schema.tiles!.enumerated() {
            // Iterate through each character in the row
            for (x, char) in row.enumerated() {
                let charString = String(char)
                let positionKey = "\(x),\(y)"
                
                // Skip if we've already processed this position (for multi-tile blocks)
                if processedPositions.contains(positionKey) {
                    continue
                }
                
                // Skip blank tiles
                if charString == " " || schema.tileTranslations![charString] == "blank" {
                    continue
                }
                
                // Look up the block type from tile translations
                if let schemaBlockType = schema.tileTranslations![charString] {
                    
                    // Map schema block types to our block library
                    if let blockType = findBlockTypeFromSchema(schemaBlockType: schemaBlockType) {
                        
                        // Calculate proper grid alignment - blocks should be placed at their top-left corner
                        let gridX = x
                        let gridY = y
                        
                        // Mark all positions this block will occupy to avoid duplicates
                        for blockX in gridX..<(gridX + blockType.sizeX) {
                            for blockY in gridY..<(gridY + blockType.sizeY) {
                                processedPositions.insert("\(blockX),\(blockY)")
                            }
                        }
                        
                        let block = PlacedBlock(
                            blockType: blockType.iconName,
                            x: gridX,
                            y: gridY,
                            iconName: blockType.iconName,
                            size: blockType.size,
                            rotation: BlockRotation()
                        )
                        
                        newBlocks.append(block)
                        
                        // Create network node for loaded blocks
                        let networkNode = NetworkNode(
                            id: block.id,
                            position: SIMD2<Int>(gridX, gridY),
                            blockType: blockType.iconName,
                            connections: blockType.connections,
                            rotation: BlockRotation(),
                            blockSize: (width: blockType.sizeX, height: blockType.sizeY),
                            capacity: blockType.capacity
                        )
                        
                        // NEW: Update ore types facing for loaded drills
                        if let mapData = mapData, (blockType.iconName.contains("drill") || blockType.iconName.contains("bore")) {
                            networkNode.updateOreTypesFacing(mapData: mapData)
                        }
                        
                        transmissionManager.addNode(networkNode)
                    }
                }
            }
        }
        
        DispatchQueue.main.async {
            self.placedBlocks = newBlocks
        }
    }
    
    // FIXED: Enhanced mapping function that properly finds BlockType from schema names
    private func findBlockTypeFromSchema(schemaBlockType: String) -> BlockType? {
        
        // Enhanced mapping from schema block names to block library icon names
        let blockTypeMapping: [String: String] = [
            // Core blocks
            "Core_Shard": "coreShardComplete",
            "core_shard": "coreShardComplete",
            "Core_Fragment": "core-fragment",
            "core_fragment": "core-fragment",
            "Core_Remnant": "core-remnant",
            "core_remnant": "core-remnant",
            
            // Production blocks
            "Mechanical_Drill": "mechanical-drill",
            "mechanical_drill": "mechanical-drill",
            "Plasma_Bore": "plasma-bore",
            "plasma_bore": "plasma-bore",
            "Advanced_Plasma_Bore": "advanced-plasma-bore",
            "advanced_plasma_bore": "advanced-plasma-bore",
            "Mineral_Extractor": "mineral-extractor",
            "mineral_extractor": "mineral-extractor",
            
            // Transportation
            "Conveyor_Belt": "conveyor-belt",
            "conveyor_belt": "conveyor-belt",
            "Belt_Bridge": "belt-bridge",
            "belt_bridge": "belt-bridge",
            "Belt_Router": "belt-router",
            "belt_router": "belt-router",
            "Belt_Junction": "belt-junction",
            "belt_junction": "belt-junction",
            
            // Power
            "Steam_Engine": "steam-engine",
            "steam_engine": "steam-engine",
            "Shaft": "shaft",
            "shaft": "shaft",
            "Gearbox": "gearbox",
            "gearbox": "gearbox",
            
            // Factory
            "Silicon_Mixer": "silicon-mixer",
            "silicon_mixer": "silicon-mixer",
            
            // Turrets
            "Single_Barrel": "single-barrel",
            "single_barrel": "single-barrel",
            "Double_Barrel": "double-barrel",
            "double_barrel": "double-barrel"
        ]
        
        // First, try direct mapping
        if let mappedIconName = blockTypeMapping[schemaBlockType] {
            // Find the actual BlockType in our library
            for (_, blocks) in blockLibrary {
                for block in blocks {
                    if block.iconName == mappedIconName {
                        return block
                    }
                }
            }
        }
        
        // Fallback: try fuzzy matching with the schema block type name
        let normalizedSchemaName = schemaBlockType.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        
        for (_, blocks) in blockLibrary {
            for block in blocks {
                let normalizedBlockName = block.iconName.lowercased()
                
                // Try exact match with normalized names
                if normalizedBlockName == normalizedSchemaName {
                    return block
                }
                
                // Try partial match
                if normalizedBlockName.contains(normalizedSchemaName) ||
                   normalizedSchemaName.contains(normalizedBlockName) {
                    return block
                }
            }
        }
        
        return nil
    }
}

// MARK: - Standardized Block Image View Component
struct StandardizedBlockImageView: View {
    let iconName: String
    let targetSize: CGFloat
    let color: Color
    let opacity: Double
    let rotation: BlockRotation
    
    init(iconName: String,
         targetSize: CGFloat,
         color: Color = .white,
         opacity: Double = 1.0,
         rotation: BlockRotation = BlockRotation()) {
        self.iconName = iconName
        self.targetSize = targetSize
        self.color = color
        self.opacity = opacity
        self.rotation = rotation
    }
    
    var body: some View {
        Group {
            if iconName.contains(".") || iconName == "cube.fill" {
                // SF Symbol handling
                Image(systemName: iconName)
                    .font(.system(size: targetSize * 0.8))
                    .foregroundColor(color)
            } else if iconName.isEmpty {
                // Empty placeholder
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: targetSize, height: targetSize)
                    .overlay(
                        Text("?")
                            .foregroundColor(.gray)
                            .font(.system(size: targetSize * 0.4))
                    )
            } else {
                // Custom asset from catalog - standardized sizing
                Image(iconName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: targetSize, height: targetSize)
                    .clipped() // Ensures image stays within bounds
                    .foregroundColor(color)
            }
        }
        .opacity(opacity)
        .rotationEffect(.degrees(rotation.degrees))
    }
}

// MARK: - Enhanced Block Button for Selection Panel with Connection Indicators
struct EnhancedBlockButton: View {
    let block: BlockType
    let isSelected: Bool
    let researchManager: ResearchManager
    let onTap: () -> Void
    
    var body: some View {
        let researchInfo = researchManager.getResearchInfo(for: block.iconName)
        let isResearched = researchInfo.isResearched
        let requiresResearch = researchManager.requireResearchForPlacement
        
        Button(action: onTap) {
            ZStack {
                StandardizedBlockImageView(
                    iconName: block.iconName,
                    targetSize: 40,
                    color: .white,
                    opacity: 1.0
                )
            }
            .frame(width: 40, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isSelected ? Color.orange.opacity(0.3) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(
                        isSelected ? Color.yellow : Color.clear,
                        lineWidth: isSelected ? 3 : 0
                    )
            )
            .scaleEffect(isSelected ? 1.1 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: isSelected)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(block.iconName.isEmpty || (requiresResearch && !isResearched))
    }
}

// MARK: - Updated Enhanced Block Selection Panel
struct UpdatedEnhancedBlockSelectionPanel: View {
    @Binding var selectedCategory: BlockCategory
    @Binding var selectedBlock: BlockType?
    let blockLibrary: [BlockCategory: [BlockType]]
    @ObservedObject var researchManager: ResearchManager
    @Binding var showResearchUI: Bool
    let onReturnToSectorMap: (() -> Void)? // ADD THIS LINE
    
    var filteredBlocks: [BlockType] {
        blockLibrary[selectedCategory] ?? []
    }
    
    private var categories: [BlockCategory] {
        Array(BlockCategory.allCases)
    }

    private var splitIndex: Int {
        (categories.count + 1) / 2
    }
    
    @State private var name = ""
    
    var body: some View {
        ZStack {
            ZStack {
                // Block grid
                ZStack {
                    Rectangle()
                        .foregroundColor(Color.black.opacity(0.7))
                        .frame(width: 380, height: 390)
                        .cornerRadius(15)
                    
                    let columns = [
                        GridItem(.adaptive(minimum: 40), spacing: 8)
                    ]
                    
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(filteredBlocks) { block in
                                let researchInfo = researchManager.getResearchInfo(for: block.iconName)
                                let isResearched = researchInfo.isResearched
                                if !researchManager.requireResearchForPlacement || isResearched {
                                    EnhancedBlockButton(
                                        block: block,
                                        isSelected: selectedBlock?.id == block.id,
                                        researchManager: researchManager
                                    ) {
                                        if selectedBlock?.id == block.id {
                                            selectedBlock = nil
                                        } else {
                                            selectedBlock = block
                                        }
                                    }
                                }
                            }
                        }
                        .frame(width: 360)
                        .padding(8)
                        .offset(y: 20)
                    }
                    .frame(height: 300)
                    .cornerRadius(8)
                    .offset(y: 50)
                }
                
                // Category toolbar
                HStack(spacing: 12) {
                    VStack(spacing: 12) {
                        ForEach(categories[..<splitIndex], id: \.self) { cat in
                            categoryButton(cat)
                        }
                    }
                    
                    VStack(spacing: 12) {
                        ForEach(categories[splitIndex...], id: \.self) { cat in
                            categoryButton(cat)
                        }
                    }
                }
                .padding(4)
                .background(Color.black.opacity(0.7))
                .cornerRadius(8)
                .offset(x: 130, y: 60)
                
                if selectedBlock != nil {
                    if let selectedBlock = selectedBlock {
                        VStack {
                            HStack {
                                Image(selectedBlock.iconName)
                                    .resizable()
                                    .frame(width: 40, height: 40)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(name)
                                        .font(.headline)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                    
                                    Text("Size: \(selectedBlock.sizeX)×\(selectedBlock.sizeY) tiles")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                            
                            VStack(alignment: .leading, spacing: 3) {
                                // Fixed ForEach for build costs
                                ForEach(Array(selectedBlock.buildCost.enumerated()), id: \.offset) { index, cost in
                                    let itemType = cost.0
                                    let requiredAmount = cost.1
                                    let availableAmount = CoreInventoryManager.shared.getItemCount(for: itemType)
                                    let hasEnough = availableAmount >= requiredAmount
                                    
                                    HStack(spacing: 0) {
                                        Image(itemType.iconName)
                                            .resizable()
                                            .frame(width: 20, height: 20)
                                        
                                        Text(itemType.displayName)
                                            .foregroundColor(.gray)
                                            .font(.caption)
                                        
                                        Text("\(availableAmount)")
                                            .foregroundColor(hasEnough ? .white : .red)
                                            .font(.caption)
                                            .fontWeight(.medium)
                                        
                                        Text("/\(requiredAmount)")
                                            .foregroundColor(.white)
                                            .font(.caption)
                                    }
                                }
                            }
                        }
                        .offset(x: -110, y: -150)
                    }
                }
            }
            .padding(12)
            
            HStack {
                Button {
                    showResearchUI = true
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .frame(width: 40, height: 40)
                            .foregroundColor(Color.white.opacity(0.3))
                        
                        Image(systemName: "lightbulb.fill")
                            .resizable()
                            .frame(width: 15, height: 20)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
                
                Button {
                    onReturnToSectorMap?() // CHANGED THIS LINE
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .frame(width: 40, height: 40)
                            .foregroundColor(Color.white.opacity(0.3))
                        
                        Image(systemName: "map.fill")
                            .resizable()
                            .frame(width: 20, height: 20)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
                
                Button {
                    
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .frame(width: 40, height: 40)
                            .foregroundColor(Color.white.opacity(0.3))
                        
                        Image(systemName: "map.circle.fill")
                            .resizable()
                            .frame(width: 20, height: 20)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
            }
            .offset(y: 165)
        }
        .onChange(of: selectedBlock) {
            if selectedBlock != nil {
                updateDisplayName()
            }
        }
    }
    
    @ViewBuilder
    private func categoryButton(_ cat: BlockCategory) -> some View {
        Button {
            selectedCategory = cat
            selectedBlock = nil
        } label: {
            Image(systemName: cat.iconName)
                .resizable()
                .frame(width: 24, height: 24)
                .padding(8)
                .foregroundColor(.white.opacity(0.9))
                .cornerRadius(6)
        }
    }
    
    private func updateDisplayName() {
        name = selectedBlock!.iconName
            .split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")
            .replacingOccurrences(of: "_", with: " ")
    }
}

#Preview {
    let mapFileURL = Bundle.main.mapFileURL(named: "Terrain_SG")!
    GameView(fileURL: mapFileURL, onReturnToSectorMap: nil)
        .environmentObject(GlobalHoverObserver())
        .ignoresSafeArea()
}
