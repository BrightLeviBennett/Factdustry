//
//  A.swift
//  Factdustry
//
//  Created by Bright on 7/24/25.
//

import SwiftUI
import UIKit
import Combine
import SwiftData

// MARK: - Unit Production System
enum UnitType: String, CaseIterable {
    case ant
    case tank
    case drone
    
    var displayName: String {
        switch self {
        case .ant: return "Ant"
        case .tank: return "Tank"
        case .drone: return "Drone"
        }
    }
    
    var productionTime: Double {
        switch self {
        case .ant: return 3.0      // 3 seconds to build an ant
        case .tank: return 8.0     // 8 seconds to build a tank
        case .drone: return 5.0    // 5 seconds to build a drone
        }
    }
}

struct UnitProductionOrder {
    let id = UUID()
    let unitType: UnitType
    let startTime: TimeInterval
    let fabricatorId: UUID
    let spawnDirection: Direction
    let faction: Faction
    
    var isComplete: Bool {
        let elapsed = CACurrentMediaTime() - startTime
        return elapsed >= unitType.productionTime
    }
    
    var progress: Double {
        let elapsed = CACurrentMediaTime() - startTime
        return min(1.0, elapsed / unitType.productionTime)
    }
}

// MARK: - Turret Projectile (tile-space)
struct TurretProjectile: Identifiable {
    let id = UUID()
    var position: CGPoint      // world in tiles
    var velocity: CGVector     // tiles per second
    var age: TimeInterval = 0
    var lifetime: TimeInterval // seconds
}

class CoreInventoryManager: ObservableObject {
    static let shared = CoreInventoryManager()
    
    @Published var coreInventory: [ItemType: Int] = [:]
    @Published var totalItemsCollected: Int = 0
    @Published var recentItems: [(itemType: ItemType, amount: Int, timestamp: Date)] = []
    
    private let maxRecentItems = 10
    
    private init() {
        // Initialize with empty inventory
    }
    
    func addItems(_ items: [ItemType: Int]) {
        for (itemType, amount) in items {
            let currentAmount = coreInventory[itemType] ?? 0
            coreInventory[itemType] = currentAmount + amount
            totalItemsCollected += amount
            // Notify research system about updated resource total
            ResearchManager.shared.notifyResourceAddedToCore(name: itemType.displayName, newTotalQuantity: coreInventory[itemType] ?? 0)
            
            // Track recent items for UI feedback
            recentItems.append((itemType: itemType, amount: amount, timestamp: Date()))
            
            // Keep only the most recent items
            if recentItems.count > maxRecentItems {
                recentItems.removeFirst(recentItems.count - maxRecentItems)
            }
        }
    }
    
    func getItemCount(for itemType: ItemType) -> Int {
        return coreInventory[itemType] ?? 0
    }
    
    func getAllItems() -> [(itemType: ItemType, count: Int)] {
        return coreInventory.map { (itemType: $0.key, count: $0.value) }
            .sorted { $0.itemType.displayName < $1.itemType.displayName }
    }
}

extension CoreInventoryManager {
    /// Check if the player has enough resources for a given build cost
    func hasEnoughResources(for buildCost: [(ItemType, Int)]) -> Bool {
        for (itemType, requiredAmount) in buildCost {
            let availableAmount = coreInventory[itemType] ?? 0
            if availableAmount < requiredAmount {
                return false
            }
        }
        return true
    }
    
    /// Check what resources are missing for a build cost
    func getMissingResources(for buildCost: [(ItemType, Int)]) -> [(ItemType, Int)] {
        var missingResources: [(ItemType, Int)] = []
        
        for (itemType, requiredAmount) in buildCost {
            let availableAmount = coreInventory[itemType] ?? 0
            let missingAmount = requiredAmount - availableAmount
            if missingAmount > 0 {
                missingResources.append((itemType, missingAmount))
            }
        }
        
        return missingResources
    }
    
    /// Consume resources for building (only call after checking hasEnoughResources)
    func consumeResources(for buildCost: [(ItemType, Int)]) -> Bool {
        // Double-check we have enough resources
        guard hasEnoughResources(for: buildCost) else {
            return false
        }
        
        // Deduct the resources
        for (itemType, requiredAmount) in buildCost {
            let currentAmount = coreInventory[itemType] ?? 0
            coreInventory[itemType] = currentAmount - requiredAmount
            
            // Remove items with 0 count for cleaner inventory display
            if coreInventory[itemType] == 0 {
                coreInventory.removeValue(forKey: itemType)
            }
        }
        
        return true
    }
    
    /// Format build cost as a readable string with availability indicators
    func formatBuildCostWithAvailability(for buildCost: [(ItemType, Int)]) -> String {
        return buildCost.map { (itemType, requiredAmount) in
            let availableAmount = coreInventory[itemType] ?? 0
            let hasEnough = availableAmount >= requiredAmount
            let indicator = hasEnough ? "✅" : "❌"
            return "\(indicator) \(requiredAmount) \(itemType.displayName) (\(availableAmount) available)"
        }.joined(separator: "\n")
    }
}

extension CoreInventoryManager {
    /// Set the initial core loadout, typically called when loading a new sector
    func setInitialLoadout(_ loadout: [ItemType: Int]) {
        // Clear existing inventory first
        coreInventory.removeAll()
        totalItemsCollected = 0
        recentItems.removeAll()
        
        // Set the new loadout
        for (itemType, amount) in loadout {
            coreInventory[itemType] = amount
            totalItemsCollected += amount
            // Notify research system for initial loadout
            ResearchManager.shared.notifyResourceAddedToCore(name: itemType.displayName, newTotalQuantity: amount)
        }
        
    }
    
    /// Check if this is a fresh sector (no items in core inventory)
    var isFreshSector: Bool {
        return totalItemsCollected == 0
    }
}

class OreMiningManager: ObservableObject {
    @Published var activeMiningOperations: [String: MiningOperation] = [:]
    @Published var miningVisualEffects: [MiningEffect] = []
    
    private var miningTimers: [String: Timer] = [:]
    
    struct MiningOperation {
        let id = UUID()
        let orePosition: (x: Int, y: Int)
        let oreType: OreType
        let startTime: Date
        var totalMined: Int = 0
        
        var positionKey: String {
            return "\(orePosition.x),\(orePosition.y)"
        }
    }
    
    struct MiningEffect {
        let id = UUID()
        let position: CGPoint
        let itemType: ItemType
        let startTime: Date
        let duration: Double = 1.5
    }
    
    func startMining(oreType: OreType, at position: (x: Int, y: Int)) {
        let positionKey = "\(position.x),\(position.y)"
        
        // Stop any existing mining at this position
        stopMining(at: position)
        
        guard oreType != .none else {
            return
        }
        
        let operation = MiningOperation(
            orePosition: position,
            oreType: oreType,
            startTime: Date()
        )
        
        activeMiningOperations[positionKey] = operation
        
        // Start mining timer
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.performMining(positionKey: positionKey)
        }
        
        miningTimers[positionKey] = timer
        
    }
    
    func stopMining(at position: (x: Int, y: Int)) {
        let positionKey = "\(position.x),\(position.y)"
        stopMining(positionKey: positionKey)
    }
    
    private func stopMining(positionKey: String) {
        miningTimers[positionKey]?.invalidate()
        miningTimers.removeValue(forKey: positionKey)
    }
    
    func stopAllMining() {
        for positionKey in activeMiningOperations.keys {
            stopMining(positionKey: positionKey)
        }
    }
    
    private func performMining(positionKey: String) {
        guard var operation = activeMiningOperations[positionKey] else { return }
        
        // Convert ore type to item type
        guard let itemType = oreTypeToItemType(operation.oreType) else { return }
        
        // Add item to core inventory
        CoreInventoryManager.shared.addItems([itemType: 1])
        
        // Update operation
        operation.totalMined += 1
        activeMiningOperations[positionKey] = operation
        
        // Create visual effect
        let effect = MiningEffect(
            position: CGPoint(x: operation.orePosition.x * 32 + 16, y: operation.orePosition.y * 32 + 16),
            itemType: itemType,
            startTime: Date()
        )
        
        DispatchQueue.main.async {
            self.miningVisualEffects.append(effect)
            
            // Remove effect after duration
            DispatchQueue.main.asyncAfter(deadline: .now() + effect.duration) {
                self.miningVisualEffects.removeAll { $0.id == effect.id }
            }
        }
        
    }
    
    private func oreTypeToItemType(_ oreType: OreType) -> ItemType? {
        switch oreType {
        case .copper: return .copper
        case .graphite: return .graphite
        case .none: return nil
        case .coal: return .coal
        case .sulfur: return .sulfur
        }
    }
    
    func isMining(at position: (x: Int, y: Int)) -> Bool {
        let positionKey = "\(position.x),\(position.y)"
        return activeMiningOperations[positionKey] != nil
    }
}

// MARK: - NEW: Unified Transmission System

/// Universal connection point that can handle both power and items
struct UniversalConnection: Hashable {
    let direction: Direction
    let connectionTypes: Set<ConnectionType>
    let constraints: ConnectionConstraints
    
    enum ConnectionType: Hashable {
        case powerInput(PowerType)
        case powerOutput(PowerType)
        case itemInput([ItemType]?) // nil = accepts all items
        case itemOutput([ItemType]?) // nil = outputs all items
        case fluidInput([FluidType]?)
        case fluidOutput([FluidType]?)
        
        // MARK: - Hashable Conformance
        func hash(into hasher: inout Hasher) {
            switch self {
            case .powerInput(let powerType):
                hasher.combine("powerInput")
                hasher.combine(powerType)
            case .powerOutput(let powerType):
                hasher.combine("powerOutput")
                hasher.combine(powerType)
            case .itemInput(let itemTypes):
                hasher.combine("itemInput")
                hasher.combine(itemTypes)
            case .itemOutput(let itemTypes):
                hasher.combine("itemOutput")
                hasher.combine(itemTypes)
            case .fluidInput(let fluidTypes):
                hasher.combine("fluidInput")
                hasher.combine(fluidTypes)
            case .fluidOutput(let fluidTypes):
                hasher.combine("fluidOutput")
                hasher.combine(fluidTypes)
            }
        }
        
        static func == (lhs: ConnectionType, rhs: ConnectionType) -> Bool {
            switch (lhs, rhs) {
            case (.powerInput(let lhsType), .powerInput(let rhsType)):
                return lhsType == rhsType
            case (.powerOutput(let lhsType), .powerOutput(let rhsType)):
                return lhsType == rhsType
            case (.itemInput(let lhsTypes), .itemInput(let rhsTypes)):
                return lhsTypes == rhsTypes
            case (.itemOutput(let lhsTypes), .itemOutput(let rhsTypes)):
                return lhsTypes == rhsTypes
            case (.fluidInput(let lhsTypes), .fluidInput(let rhsTypes)):
                return lhsTypes == rhsTypes
            case (.fluidOutput(let lhsTypes), .fluidOutput(let rhsTypes)):
                return lhsTypes == rhsTypes
            default:
                return false
            }
        }
    }
    
    struct ConnectionConstraints: Hashable {
        let maxThroughput: Double // items/second or power/second
        let priority: Int // Higher priority connections get processed first
        let bufferSize: Int // How many items can be buffered
    }
}

/// Represents a node in the transmission network
class NetworkNode: ObservableObject, Identifiable {
    let id: UUID
    let position: SIMD2<Int>
    let blockType: String
    var connections: [UniversalConnection]
    var rotation: BlockRotation
    var blockSize: (width: Int, height: Int) = (1, 1) // NEW: Store the block size
    var capacity: Int = 100
    var oreTypesFacing: [OreType] = [] // NEW: Store what ore types this drill is facing
    
    // Node state
    @Published var powerLevel: Double = 0
    @Published var itemBuffer: [ItemType: Int] = [:]
    @Published var fluidBuffer: [FluidType: Double] = [:]
    @Published var isActive: Bool = false
    @Published var conveyorItems: [ConveyorItem] = []
    // Turret head state (for rotatable turret heads)
    @Published var headAngleDegrees: CGFloat = 0
    @Published var targetHeadAngleDegrees: CGFloat? = nil

    
    // Performance metrics
    var lastUpdateTime: TimeInterval = 0
    var processingLoad: Double = 0
    
    init(id: UUID, position: SIMD2<Int>, blockType: String, connections: [UniversalConnection], rotation: BlockRotation = BlockRotation(), blockSize: (width: Int, height: Int) = (1, 1), capacity: Int = 100) {
        self.id = id
        self.position = position
        self.blockType = blockType
        self.connections = connections
        self.rotation = rotation
        self.blockSize = blockSize
        self.capacity = capacity
    
        // Default the head angle to the building's base facing for single-barrel turrets
        if self.blockType == "single-barrel" {
            self.headAngleDegrees = CGFloat((self.rotation.rawValue % 4) * 90)
        }
}
    
    func getTotalItemCount() -> Int {
        return itemBuffer.reduce(0) { total, item in total + item.value }
    }

    func hasCapacityFor(amount: Int) -> Bool {
        let currentTotal = getTotalItemCount()
        return currentTotal + amount <= capacity
    }
    
    func getRotatedConnections() -> [UniversalConnection] {
        return connections.map { connection in
            UniversalConnection(
                direction: connection.direction.rotated(by: rotation),
                connectionTypes: connection.connectionTypes,
                constraints: connection.constraints
            )
        }
    }
    
    func updateOreTypesFacing(mapData: MapData) {
        guard blockType.contains("drill") || blockType.contains("bore") else {
            oreTypesFacing = []
            return
        }
        
        let frontDistance = 1
        var facingOres: Set<OreType> = []
        
        // Calculate the direction the building is facing based on rotation
        let (frontDeltaX, frontDeltaY): (Int, Int)
        switch rotation.rawValue {
        case 0:  // North (0°) - front is up (negative Y)
            (frontDeltaX, frontDeltaY) = (0, -frontDistance)
        case 1:  // East (90°) - front is right (positive X)
            (frontDeltaX, frontDeltaY) = (frontDistance, 0)
        case 2:  // South (180°) - front is down (positive Y)
            (frontDeltaX, frontDeltaY) = (0, frontDistance)
        case 3:  // West (270°) - front is left (negative X)
            (frontDeltaX, frontDeltaY) = (-frontDistance, 0)
        default:
            (frontDeltaX, frontDeltaY) = (0, -frontDistance) // Default to North
        }
        
        let rotatedSize = getRotatedSize()
        
        // Check all tiles in front of the building for ore
        for i in 0..<max(rotatedSize.width, rotatedSize.height) {
            let (checkX, checkY): (Int, Int)
            
            // Calculate which tiles to check based on building orientation
            switch rotation.rawValue {
            case 0:  // North - check tiles above the top edge
                checkX = position.x + min(i, rotatedSize.width - 1)
                checkY = position.y + frontDeltaY
            case 1:  // East - check tiles to the right of the right edge
                checkX = position.x + rotatedSize.width + frontDeltaX - 1
                checkY = position.y + min(i, rotatedSize.height - 1)
            case 2:  // South - check tiles below the bottom edge
                checkX = position.x + min(i, rotatedSize.width - 1)
                checkY = position.y + rotatedSize.height + frontDeltaY - 1
            case 3:  // West - check tiles to the left of the left edge
                checkX = position.x + frontDeltaX
                checkY = position.y + min(i, rotatedSize.height - 1)
            default:
                checkX = position.x + min(i, rotatedSize.width - 1)
                checkY = position.y + frontDeltaY
            }
            
            // Check if the tile is within map bounds
            if checkX >= 0 && checkX < mapData.width &&
               checkY >= 0 && checkY < mapData.height {
                let oreType = mapData.ores[checkY][checkX]
                if oreType != .none {
                    facingOres.insert(oreType)
                }
            }
        }
        
        oreTypesFacing = Array(facingOres)
    }
    
    // NEW: Get the rotated block size
    func getRotatedSize() -> (width: Int, height: Int) {
        return rotation.applied(to: blockSize)
    }
    
    // NEW: Get all edge positions for a given direction
    func getEdgePositions(for direction: Direction) -> [SIMD2<Int>] {
        let rotatedSize = getRotatedSize()
        var positions: [SIMD2<Int>] = []
        
        switch direction {
        case .north:
            // Top edge - positions above the block
            for x in 0..<rotatedSize.width {
                positions.append(SIMD2<Int>(position.x + x, position.y - 1))
            }
        case .south:
            // Bottom edge - positions below the block
            for x in 0..<rotatedSize.width {
                positions.append(SIMD2<Int>(position.x + x, position.y + rotatedSize.height))
            }
        case .east:
            // Right edge - positions to the right of the block
            for y in 0..<rotatedSize.height {
                positions.append(SIMD2<Int>(position.x + rotatedSize.width, position.y + y))
            }
        case .west:
            // Left edge - positions to the left of the block
            for y in 0..<rotatedSize.height {
                positions.append(SIMD2<Int>(position.x - 1, position.y + y))
            }
        }
        
        return positions
    }
    
    /// Get the primary flow direction for this conveyor
    func getConveyorFlowDirection() -> (input: Direction, output: Direction)? {
        guard blockType == "conveyor-belt" || blockType.contains("belt") else { return nil }
        
        let connections = getRotatedConnections()
        
        var inputDir: Direction? = nil
        var outputDir: Direction? = nil
        
        for connection in connections {
            let hasInput = connection.connectionTypes.contains { type in
                if case .itemInput(_) = type { return true }
                return false
            }
            let hasOutput = connection.connectionTypes.contains { type in
                if case .itemOutput(_) = type { return true }
                return false
            }
            
            if hasInput && inputDir == nil {
                inputDir = connection.direction
            }
            if hasOutput && outputDir == nil {
                outputDir = connection.direction
            }
        }
        
        if let input = inputDir, let output = outputDir {
            return (input: input, output: output)
        }
        
        // Fallback: use rotation to determine flow
        switch rotation.rawValue {
        case 0: return (input: .south, output: .north)
        case 1: return (input: .west, output: .east)
        case 2: return (input: .north, output: .south)
        case 3: return (input: .east, output: .west)
        default: return (input: .south, output: .north)
        }
    }
}

// MARK: - Transmission Network Manager

extension Notification.Name {
    static let conveyorBeltCornerUpdate = Notification.Name("conveyorBeltCornerUpdate")
}

private struct ConveyorFlow {
    var inputDirection: Direction?
    let outputDirection: Direction?
}

struct ConveyorItem: Identifiable, Equatable {
    let id = UUID()
    let itemType: ItemType
    let startTime: TimeInterval
    let transferDuration: Double
    var seamlessStartPosition: CGPoint?
    var animationSteps: Int = 30
    var isAnimationComplete: Bool = false
    var transferAttempts: Int = 0
    var lastTransferAttempt: TimeInterval = 0
    var isStuck: Bool = false
    var animationCompletionTime: TimeInterval? = nil  // NEW: Track when animation completed
    
    static func == (lhs: ConveyorItem, rhs: ConveyorItem) -> Bool {
        lhs.id == rhs.id
    }
    
    // NEW: Helper to check if item is ready for transfer with proper timing
    func isReadyForTransfer(currentTime: TimeInterval) -> Bool {
        // Must have completed animation
        guard isAnimationComplete else { return false }
        
        // If we have completion time, ensure a small buffer has passed
        if let completionTime = animationCompletionTime {
            return currentTime - completionTime > 0.1 // 100ms buffer
        }
        
        // Fallback: check age
        let age = currentTime - startTime
        return age >= transferDuration * 0.95
    }
}

extension ConveyorItem {
    // NEW: Helper to check if item is ready for early transfer (85% completion)
    func isReadyForEarlyTransfer(currentTime: TimeInterval) -> Bool {
        let age = currentTime - startTime
        return age >= transferDuration * 0.85
    }
    
    // NEW: Get current animation progress (0.0 to 1.0)
    func getAnimationProgress(currentTime: TimeInterval) -> Double {
        let age = currentTime - startTime
        return min(1.0, age / transferDuration)
    }
}

extension TransmissionNetworkManager {
    
    private func processItemTransport(for node: NetworkNode, in network: TransmissionNetwork) {
        let currentTime = CACurrentMediaTime()
        
        // First, try to transfer items that are ready
        if node.blockType == "conveyor-belt" || node.blockType.contains("belt") {
            // Process transfers BEFORE removing old items
            let connections = node.getRotatedConnections()
            let outputConnections = connections.filter { connection in
                connection.connectionTypes.contains { type in
                    if case .itemOutput(_) = type { return true }
                    return false
                }
            }
            
            for connection in outputConnections {
                let edgePositions = node.getEdgePositions(for: connection.direction)
                
                for edgePosition in edgePositions {
                    // Find any node at this edge position
                    for (_, targetNode) in nodes {
                        if targetNode.id == node.id { continue }
                        
                        let targetSize = targetNode.getRotatedSize()
                        if edgePosition.x >= targetNode.position.x &&
                           edgePosition.x < targetNode.position.x + targetSize.width &&
                           edgePosition.y >= targetNode.position.y &&
                           edgePosition.y < targetNode.position.y + targetSize.height {
                            
                            // Check if we can connect to this target
                            if canConnect(from: node, connection: connection, to: targetNode) {
                                transferItemsAnimated(
                                    from: node,
                                    to: targetNode,
                                    via: connection,
                                    currentTime: currentTime
                                )
                            }
                        }
                    }
                }
            }
            
            // IMPROVED: More intelligent item cleanup
            node.conveyorItems.removeAll { item in
                let age = currentTime - item.startTime
                let maxNormalAge = item.transferDuration * 2.0  // Reduced from 3.0
                
                // Only remove items that are genuinely stuck
                if age > maxNormalAge {
                    // Check if item has been trying to transfer but failing
                    let timeSinceLastAttempt = currentTime - item.lastTransferAttempt
                    let hasRecentAttempts = item.transferAttempts > 3 && timeSinceLastAttempt < 2.0
                    
                    if hasRecentAttempts || item.isStuck {
                        return true
                    }
                }
                
                return false
            }
        } else {
            // Handle non-conveyor sources (drills, etc.)
            transferFromNonConveyor(from: node, in: network, currentTime: currentTime)
        }
    }
    
    private func transferItemsAnimated(from source: NetworkNode, to target: NetworkNode, via connection: UniversalConnection, currentTime: TimeInterval) {
        if source.blockType == "conveyor-belt" || source.blockType.contains("belt") {
            // Process items oldest first for conveyors
            let sortedItems = source.conveyorItems.sorted { $0.startTime < $1.startTime }
            
            for (_, var item) in sortedItems.enumerated() {
                let itemAge = currentTime - item.startTime
                
                // IMPROVED: Start transfer at 75% completion for seamless transition (especially corners)
                let transferThreshold = item.transferDuration * 0.75
                let isReadyForTransfer = itemAge >= transferThreshold
                
                if isReadyForTransfer {
                    // Check if target can accept this item type
                    if canAcceptItem(node: target, itemType: item.itemType, from: connection.direction.opposite) {
                        
                        if target.blockType == "conveyor-belt" || target.blockType.contains("belt") {
                            // Enhanced spacing check for corner conveyors
                            let isCornerTransfer = (blockLoadingManager?.conveyorCornerStates[source.id] == true) ||
                                                  (blockLoadingManager?.conveyorCornerStates[target.id] == true)
                            
                            let spacingThreshold = isCornerTransfer ? 0.05 : 0.1 // Tighter spacing for corners
                            
                            let canAcceptNewItem = target.conveyorItems.count < target.capacity &&
                                (target.conveyorItems.isEmpty ||
                                 target.conveyorItems.allSatisfy { targetItem in
                                     let targetAge = currentTime - targetItem.startTime
                                     return targetAge > spacingThreshold
                                 })
                            
                            if canAcceptNewItem {
                                // IMPROVED: Calculate seamless start position based on current animation progress
                                let animationProgress = min(1.0, itemAge / item.transferDuration)
                                let seamlessStartPos = calculateSeamlessTransferPosition(
                                    from: source,
                                    to: target,
                                    connection: connection,
                                    sourceProgress: animationProgress
                                )
                                
                                // Create new item with reduced transfer duration to compensate for early transfer
                                let remainingTime = max(0.1, item.transferDuration - itemAge)
                                let baseDuration = target.transferDuration
                                let adjustedDuration = isCornerTransfer ? baseDuration * 0.8 : baseDuration
                                
                                let newItem = ConveyorItem(
                                    itemType: item.itemType,
                                    startTime: currentTime,
                                    transferDuration: adjustedDuration,
                                    seamlessStartPosition: seamlessStartPos,
                                    animationSteps: calculateOptimalSteps(for: adjustedDuration),
                                    isAnimationComplete: false
                                )
                                
                                // Perform the synchronized transfer
                                DispatchQueue.main.async {
                                    target.conveyorItems.append(newItem)
                                    source.conveyorItems.removeAll { $0.id == item.id }
                                }
                                
                                return // Only transfer one item per update cycle
                            } else {
                                // Target is full - mark item with transfer attempt
                                item.transferAttempts += 1
                                item.lastTransferAttempt = currentTime
                                
                                // Update the item in the source
                                if let itemIndex = source.conveyorItems.firstIndex(where: { $0.id == item.id }) {
                                    source.conveyorItems[itemIndex] = item
                                }
                                
                                // More aggressive stuck detection for corners
                                let isSourceCorner = blockLoadingManager?.conveyorCornerStates[source.id] == true
                                let stuckThreshold = isSourceCorner ? 4 : 6
                                let stuckTimeThreshold = isSourceCorner ? 2.0 : 2.5
                                
                                if item.transferAttempts > stuckThreshold && itemAge > item.transferDuration * stuckTimeThreshold {
                                    DispatchQueue.main.async {
                                        source.conveyorItems.removeAll { $0.id == item.id }
                                    }
                                }
                            }
                        } else {
                            // Transfer to non-conveyor (like core or turret) - keep original timing
                            if item.isAnimationComplete {
                                if target.hasCapacityFor(amount: 1) {
                                    DispatchQueue.main.async {
                                        let currentAmount = target.itemBuffer[item.itemType] ?? 0
                                        target.itemBuffer[item.itemType] = currentAmount + 1
                                        source.conveyorItems.removeAll { $0.id == item.id }
                                        
                                    }
                                    
                                    return
                                } else {
                                    // Target buffer is full - mark transfer attempt
                                    item.transferAttempts += 1
                                    item.lastTransferAttempt = currentTime
                                    
                                    if let itemIndex = source.conveyorItems.firstIndex(where: { $0.id == item.id }) {
                                        source.conveyorItems[itemIndex] = item
                                    }
                                }
                            }
                        }
                    } else {
                        // Target can't accept this item type - remove stuck item
                        DispatchQueue.main.async {
                            source.conveyorItems.removeAll { $0.id == item.id }
                        }
                    }
                }
            }
        }
    }
}

extension TransmissionNetworkManager {
    /// Enhanced corner detection that updates network connections
    func updateConveyorCorners() {
        var networkNeedsRebuild = false
        
        for (nodeId, node) in nodes {
            guard node.blockType == "conveyor-belt" else { continue }
            
            // Check if this conveyor has perpendicular input/output (making it a corner)
            if let cornerRotation = detectSimpleCorner(for: node) {
                // Update to corner
                updateNodeToCorner(nodeId: nodeId, cornerRotation: cornerRotation)
                networkNeedsRebuild = true
            } else {
                // Revert to normal conveyor
                updateNodeToNormal(nodeId: nodeId)
                networkNeedsRebuild = true
            }
        }
        
        // Rebuild network if any corners changed
        if networkNeedsRebuild {
            needsNetworkRebuild = true
        }
    }

    // FIXED: Simple, working corner detection
    private func detectSimpleCorner(for node: NetworkNode) -> Int? {
        var connectedDirections: Set<Direction> = []
        
        // Check all four directions for actual conveyor connections
        for direction in Direction.allCases {
            let edgePositions = node.getEdgePositions(for: direction)
            
            for edgePos in edgePositions {
                // Find nodes at this edge position
                for (_, neighbor) in nodes {
                    if neighbor.id == node.id { continue }
                    
                    // Check if neighbor is a conveyor and overlaps with this edge position
                    if (neighbor.blockType == "conveyor-belt" || neighbor.blockType.contains("belt")) {
                        let neighborSize = neighbor.getRotatedSize()
                        if edgePos.x >= neighbor.position.x &&
                           edgePos.x < neighbor.position.x + neighborSize.width &&
                           edgePos.y >= neighbor.position.y &&
                           edgePos.y < neighbor.position.y + neighborSize.height {
                            
                            // We found a connected conveyor neighbor in this direction
                            connectedDirections.insert(direction)
                            break
                        }
                    }
                }
            }
        }
        
        // Corner detection: exactly 2 connected directions that are perpendicular
        guard connectedDirections.count == 2 else { return nil }
        
        let directions = Array(connectedDirections)
        let dir1 = directions[0]
        let dir2 = directions[1]
        
        // Check if directions are perpendicular (not opposite)
        guard dir1.opposite != dir2 else { return nil }
        
        // Simple mapping - just use one flow direction per connection pair
        // We'll determine texture type later based on the corner rotation
        switch (dir1, dir2) {
        case (.south, .east), (.east, .south):  return 0
        case (.west, .south), (.south, .west):  return 1
        case (.north, .west), (.west, .north):  return 2
        case (.east, .north), (.north, .east):  return 3
        default: return nil
        }
    }
    
    /// Update a node to corner configuration with proper network connections
    private func updateNodeToCorner(nodeId: UUID, cornerRotation: Int) {
        guard let node = nodes[nodeId] else { return }
        
        // Update visual state
        updateNodeVisualToCorner(nodeId: nodeId, cornerRotation: cornerRotation)
        
        // Get the input and output directions for this corner rotation
        let (inputDir, outputDir) = getCornerFlowDirections(cornerRotation: cornerRotation)
        
        // Create new connections for corner flow
        let newConnections = [
            UniversalConnection(
                direction: inputDir,
                connectionTypes: [.itemInput(nil)],
                constraints: UniversalConnection.ConnectionConstraints(
                    maxThroughput: 20,
                    priority: 5,
                    bufferSize: 1
                )
            ),
            UniversalConnection(
                direction: outputDir,
                connectionTypes: [.itemOutput(nil)],
                constraints: UniversalConnection.ConnectionConstraints(
                    maxThroughput: 20,
                    priority: 5,
                    bufferSize: 1
                )
            )
        ]
        
        // Update the node's connections
        node.connections = newConnections
        
    }
    
    /// Revert a node back to normal conveyor configuration
    private func updateNodeToNormal(nodeId: UUID) {
        guard let node = nodes[nodeId] else { return }
        
        // Update visual state
        updateNodeVisualToNormal(nodeId: nodeId)
        
        // Restore original conveyor connections (straight through)
        let originalConnections = [
            UniversalConnection(
                direction: .north,
                connectionTypes: [.itemOutput(nil)],
                constraints: UniversalConnection.ConnectionConstraints(
                    maxThroughput: 20,
                    priority: 5,
                    bufferSize: 1
                )
            ),
            UniversalConnection(
                direction: .south,
                connectionTypes: [.itemInput(nil)],
                constraints: UniversalConnection.ConnectionConstraints(
                    maxThroughput: 20,
                    priority: 5,
                    bufferSize: 1
                )
            )
        ]
        
        // Update the node's connections
        node.connections = originalConnections
    }
    
    // Helper function to get the flow direction of a conveyor
    private func getConveyorFlowDirection(for conveyor: NetworkNode) -> (input: Direction, output: Direction) {
        // For non-corner conveyors, flow is determined by rotation
        switch conveyor.rotation.rawValue {
        case 0: return (input: .south, output: .north) // North-facing: South->North
        case 1: return (input: .west, output: .east)   // East-facing: West->East
        case 2: return (input: .north, output: .south) // South-facing: North->South
        case 3: return (input: .east, output: .west)   // West-facing: East->West
        default: return (input: .south, output: .north) // Default
        }
    }

    // SIMPLE: Flow directions for the 4 basic corner types
    private func getCornerFlowDirections(cornerRotation: Int) -> (input: Direction, output: Direction) {
        switch cornerRotation {
        case 0:  return (input: .south, output: .east)  // Bottom→Right
        case 1:  return (input: .west,  output: .south) // Left→Bottom
        case 2:  return (input: .north, output: .west)  // Top→Left
        case 3:  return (input: .east,  output: .north) // Right→Top
        default: return (input: .south, output: .north) // fallback
        }
    }

    /// Update node visual to corner texture with smart texture selection
    private func updateNodeVisualToCorner(nodeId: UUID, cornerRotation: Int) {
        let (textureType, textureRotation) = getCornerTextureInfo(cornerRotation: cornerRotation)
        
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .conveyorBeltCornerUpdate,
                object: nil,
                userInfo: [
                    "nodeId": nodeId,
                    "isCorner": true,
                    "textureType": textureType,
                    "rotation": textureRotation
                ]
            )
        }
        
    }
    
    /// Determine which corner texture to use and how to rotate it
    private func getCornerTextureInfo(cornerRotation: Int) -> (textureType: String, textureRotation: Int) {
            let (inputDir, outputDir) = getCornerFlowDirections(cornerRotation: cornerRotation)
                        
            // Check if this matches the "left to down" pattern (West→South) or its rotations
            let isLeftToDownFamily = isLeftToDownPattern(input: inputDir, output: outputDir)
            
            if isLeftToDownFamily {
                // Use CA texture
                let rotation = getCARotationFor(input: inputDir, output: outputDir)
                return ("CA", rotation)
            } else {
                // Use C texture for "up to right" pattern and others
                let rotation = getCRotationFor(input: inputDir, output: outputDir)
                return ("C", rotation)
            }
        }
        
        /// Check if the flow pattern matches "left to down" family
        private func isLeftToDownPattern(input: Direction, output: Direction) -> Bool {
            // "Left to down" (West→South) and its rotations:
            switch (input, output) {
            case (.west, .south):   // Left→Down (base)
                return true
            case (.south, .east):   // Down→Right (90° rotation)
                return true
            case (.east, .north):   // Right→Up (180° rotation)
                return true
            case (.north, .west):   // Up→Left (270° rotation)
                return true
            default:
                return false
            }
        }
        
        /// Get rotation for CA texture based on flow direction
        private func getCARotationFor(input: Direction, output: Direction) -> Int {
            switch (input, output) {
            case (.west, .south):   return 1  // Base CA orientation
            case (.south, .east):   return 0  // 90° rotation
            case (.east, .north):   return 3  // 180° rotation
            case (.north, .west):   return 2  // 270° rotation
            default:                return 0
            }
        }
        
        /// Get rotation for C texture based on flow direction
        private func getCRotationFor(input: Direction, output: Direction) -> Int {
            // For "up to right" pattern (North→East) and its rotations
            // But our detection might not give us North→East directly
            // So let's map whatever we do detect to appropriate C rotations
            switch (input, output) {
            case (.north, .east):   return 3  // Up→Right (ideal C base)
            case (.east, .south):   return 0  // Right→Down (90° rotation)
            case (.south, .west):   return 1  // Down→Left (180° rotation)
            case (.west, .north):   return 2  // Left→Up (270° rotation)
            default:
                // Fallback mapping for any other patterns
                return 0
            }
        }

    /// Update node visual back to normal
    private func updateNodeVisualToNormal(nodeId: UUID) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .conveyorBeltCornerUpdate,
                object: nil,
                userInfo: ["nodeId": nodeId, "isCorner": false]
            )
        }
    }
}

extension NetworkNode {
    var conveyorSpeed: Double {
        // Speed in tiles per second
        switch blockType {
        case "conveyor-belt": return 50.0
        case "duct": return 3.0
        default: return 1.0
        }
    }
    
    var transferDuration: Double {
        // Time to cross one tile at this speed
        return 1.0 / conveyorSpeed
    }
}

extension TransmissionNetworkManager {
    func canTurretAttack(turretNodeId: UUID, targetPosition: CGPoint) -> Bool {
        guard let turretNode = nodes[turretNodeId] else { return false }
        
        // Check if there are any enemy units at the target position
        // For now, this is a placeholder until we have proper unit targeting
        return true
    }
    
    func findNearestEnemyTarget(for turretNodeId: UUID, range: CGFloat) -> UUID? {
        guard let turretNode = nodes[turretNodeId] else { return nil }
        
        var nearestEnemyId: UUID? = nil
        var nearestDistance: CGFloat = range + 1
        
        // Check for enemy blocks in range (other faction turrets, important buildings, etc.)
        for (nodeId, node) in nodes {
            guard nodeId != turretNodeId else { continue }
            guard FactionManager.shared.canAttack(attacker: turretNode.faction, target: node.faction) else { continue }
            
            let dx = CGFloat(node.position.x - turretNode.position.x)
            let dy = CGFloat(node.position.y - turretNode.position.y)
            let distance = sqrt(dx * dx + dy * dy)
            
            if distance <= range && distance < nearestDistance {
                nearestDistance = distance
                nearestEnemyId = nodeId
            }
        }
        
        return nearestEnemyId
    }
    
    // NEW: Auto-targeting for enemy faction turrets
    private func updateAutoTargeting() {
        for (nodeId, node) in nodes {
            guard node.blockType.contains("barrel") else { continue }
            guard node.faction != FactionManager.shared.playerFaction else { continue } // Only auto-target for AI
            
            let range = turretRangesTiles["single-barrel"] ?? 6.0
            
            if let targetId = findNearestEnemyTarget(for: nodeId, range: range) {
                if let targetNode = nodes[targetId] {
                    let targetWorldPos = CGPoint(
                        x: CGFloat(targetNode.position.x),
                        y: CGFloat(targetNode.position.y)
                    )
                    aimTurret(id: nodeId, atWorldPoint: targetWorldPos)
                    
                    // Auto-fire if enemy faction has ammo
                    let ammo = node.itemBuffer[.copper] ?? 0
                    if ammo > 0 {
                        fireOnce(id: nodeId)
                    }
                }
            }
        }
    }
}

extension NetworkNode {
    private static var factionStorage: [UUID: Faction] = [:]
    
    var faction: Faction {
        get {
            return NetworkNode.factionStorage[self.id] ?? .lumina
        }
        set {
            NetworkNode.factionStorage[self.id] = newValue
        }
    }
    
    func canInteractWith(_ other: NetworkNode) -> Bool {
        let relation = FactionManager.shared.getRelation(from: self.faction, to: other.faction)
        return relation == .allied || (relation == .neutral && blockType != "single-barrel" && blockType != "double-barrel")
    }
    
    func canAttack(_ target: NetworkNode) -> Bool {
        return FactionManager.shared.canAttack(attacker: self.faction, target: target.faction)
    }
}

class TransmissionNetworkManager: ObservableObject {
    @Published var nodes: [UUID: NetworkNode] = [:]
    @Published var networks: [TransmissionNetwork] = []
    @Published var activeTransfers: [Transfer] = []
    @Published var itemAnimations: [UUID: (from: CGPoint, to: CGPoint, startTime: TimeInterval)] = [:]
    
    // Unit production system
    @Published var activeUnitProduction: [UUID: UnitProductionOrder] = [:]
    @Published var completedUnits: [(unitType: UnitType, spawnPosition: CGPoint, direction: Direction, faction: Faction)] = []
    
    private var updateTimer: Timer?
    private let updateInterval: TimeInterval = 0.2 // 10 FPS updates
    private var needsNetworkRebuild = true
    private var conveyorTopologyDirty: Bool = true // only recompute conveyor corners when dirty
    private var lastTransferTimes: [String: TimeInterval] = [:] // Track last transfer time between nodes
    private let minTransferInterval: TimeInterval = 0.5 // Minimum time between visual transfers
    
    weak var blockManager: BlockLoadingManager?
    


    // MARK: - Turret control & projectiles
    @Published var projectiles: [TurretProjectile] = []
    @Published var controlledTurretID: UUID?
    private var triggerHeld: Set<UUID> = []

    // Fire timing + tick timing
    private var lastTurretFire: [UUID: CFTimeInterval] = [:]
    private var lastTickTime: CFTimeInterval = CACurrentMediaTime()

    // Tunables
    private let headTurnRateDegPerSec: CGFloat = 240
    private let bulletSpeedTilesPerSec: CGFloat = 12.0
    private let turretCooldowns: [String: TimeInterval] = ["single-barrel": 0.60]
    private let turretRangesTiles: [String: CGFloat]   = ["single-barrel": 6.0]

    var blockLoadingManager: BlockLoadingManager? // ADDED: Reference to block loading manager
    
    init() {
        startUpdateLoop()
    }
    
    deinit {
        updateTimer?.invalidate()
    }


    
    // Explicitly mark that conveyor corner topology changed
    func markConveyorTopologyDirty() { conveyorTopologyDirty = true }

// MARK: - Turret head rotation helpers

    private func shortestAngularDelta(from: CGFloat, to: CGFloat) -> CGFloat {
        var d = (to - from).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    private func unitVector(forDegrees deg: CGFloat) -> CGVector {
        // Our convention: 0° = North (up), 90° = East
        let theta = (deg - 90) * .pi / 180
        return CGVector(dx: cos(theta), dy: sin(theta))
    }

    private func updateTurretHeads(dt: CFTimeInterval) {
        guard dt > 0 else { return }
        for (_, node) in nodes where node.blockType == "single-barrel" {
            let baseFacingDeg = CGFloat((node.rotation.rawValue % 4) * 90)
            let target = node.targetHeadAngleDegrees ?? baseFacingDeg
            let delta = shortestAngularDelta(from: node.headAngleDegrees, to: target)
            let maxStep = headTurnRateDegPerSec * CGFloat(dt)
            let step = max(-maxStep, min(maxStep, delta))
            node.headAngleDegrees = (node.headAngleDegrees + step).truncatingRemainder(dividingBy: 360)
        }
    }

    // Public: aim head to a world (tile-space) point
    func aimTurret(id: UUID, atWorldPoint p: CGPoint) {
        guard let node = nodes[id], node.blockType == "single-barrel" else { return }
        let size = node.getRotatedSize()
        let center = CGPoint(
            x: CGFloat(node.position.x) + CGFloat(size.width) / 2.0,
            y: CGFloat(node.position.y) + CGFloat(size.height) / 2.0
        )
        let dx = p.x - center.x
        let dy = p.y - center.y
        let mathDeg = atan2(dy, dx) * 180 / .pi  // 0=E, 90=S, -90=N
        let gameDeg = CGFloat(mathDeg) + 90      // 0=N, 90=E, 180=S, 270=W
        nodes[id]?.targetHeadAngleDegrees = gameDeg
    }

    // MARK: - Control helpers

    func beginControllingTurret(_ id: UUID) {
        controlledTurretID = id
        if let node = nodes[id] {
            nodes[id]?.targetHeadAngleDegrees = node.headAngleDegrees
        }
    }

    func releaseControl() {
        if let id = controlledTurretID { triggerHeld.remove(id) }
        controlledTurretID = nil
    }

    func setTriggerHeld(_ held: Bool, for id: UUID) {
        if held { triggerHeld.insert(id) } else { triggerHeld.remove(id) }
    }

    func isTriggerHeld(_ id: UUID) -> Bool { triggerHeld.contains(id) }

    // Find a single-barrel at a world (tile) point
    func findSingleBarrel(atWorldPoint p: CGPoint) -> UUID? {
        for (_, node) in nodes where node.blockType == "single-barrel" {
            let sz = node.getRotatedSize()
            let rect = CGRect(x: CGFloat(node.position.x), y: CGFloat(node.position.y),
                              width: CGFloat(sz.width), height: CGFloat(sz.height))
            if rect.contains(p) { return node.id }
        }
        return nil
    }

    // MARK: - Firing

    func fireOnce(id: UUID) {
        let now = CACurrentMediaTime()
        guard let node = nodes[id], node.blockType == "single-barrel" else { return }
        let copper = node.itemBuffer[.copper] ?? 0
        guard copper > 0 else { return }
        let cd = turretCooldowns["single-barrel"] ?? 0.6
        let last = lastTurretFire[id] ?? 0
        guard now - last >= cd else { return }

        nodes[id]?.itemBuffer[.copper] = max(0, copper - 1)
        lastTurretFire[id] = now
        spawnProjectile(from: node)
    }

    private func spawnProjectile(from node: NetworkNode) {
        let size = node.getRotatedSize()
        let center = CGPoint(
            x: CGFloat(node.position.x) + CGFloat(size.width) / 2.0,
            y: CGFloat(node.position.y) + CGFloat(size.height) / 2.0
        )

        let dir = unitVector(forDegrees: node.headAngleDegrees)
        let halfExtent = CGFloat(max(size.width, size.height)) / 2.0
        let muzzleOffsetTiles: CGFloat = halfExtent * 0.8
        let origin = CGPoint(x: center.x + dir.dx * muzzleOffsetTiles,
                             y: center.y + dir.dy * muzzleOffsetTiles)

        let speed = bulletSpeedTilesPerSec
        let rangeTiles = turretRangesTiles["single-barrel"] ?? 6.0
        let lifetime = TimeInterval(rangeTiles / speed)

        projectiles.append(
            TurretProjectile(
                position: origin,
                velocity: CGVector(dx: dir.dx * speed, dy: dir.dy * speed),
                age: 0,
                lifetime: lifetime
            )
        )
    }

    private func updateProjectiles(dt: CFTimeInterval) {
        guard dt > 0 else { return }
        for i in projectiles.indices {
            projectiles[i].position.x += projectiles[i].velocity.dx * CGFloat(dt)
            projectiles[i].position.y += projectiles[i].velocity.dy * CGFloat(dt)
            projectiles[i].age += dt
        }
        projectiles.removeAll { $0.age >= $0.lifetime }
    }

    private func updateTurrets(now: CFTimeInterval) {
        for (_, node) in nodes where node.blockType == "single-barrel" {
            // If controlled, only fire while trigger held
            if let controlled = controlledTurretID, node.id == controlled {
                guard triggerHeld.contains(node.id) else { continue }
            } else {
                // Not controlled: do nothing (no auto-fire)
                continue
            }

            let copper = node.itemBuffer[.copper] ?? 0
            guard copper > 0 else { continue }

            let last = lastTurretFire[node.id] ?? 0
            let cd = turretCooldowns["single-barrel"] ?? 0.6
            guard now - last >= cd else { continue }

            nodes[node.id]?.itemBuffer[.copper] = max(0, copper - 1)
            lastTurretFire[node.id] = now
            spawnProjectile(from: node)
        }
    }
    
    // MARK: - Unit Production
    
    private func processUnitProduction(for node: NetworkNode) {
        // Only process unit fabricators
        guard node.blockType == "tank-fabricator" else { return }
        guard node.isActive else { return } // Must be powered
        
        let currentTime = CACurrentMediaTime()
        
        // Check if we can start a new production
        if activeUnitProduction[node.id] == nil {
            // Check if we have enough copper (10 copper per ant)
            let copperCount = node.itemBuffer[.copper] ?? 0
            if copperCount >= 10 {
                // Consume copper and start production
                node.itemBuffer[.copper] = copperCount - 10
                
                // Calculate spawn direction based on fabricator rotation
                let spawnDirection: Direction
                switch node.rotation.rawValue {
                case 0: spawnDirection = .north
                case 1: spawnDirection = .east
                case 2: spawnDirection = .south
                case 3: spawnDirection = .west
                default: spawnDirection = .north
                }
                
                let order = UnitProductionOrder(
                    unitType: .ant,
                    startTime: currentTime,
                    fabricatorId: node.id,
                    spawnDirection: spawnDirection,
                    faction: node.faction
                )
                
                activeUnitProduction[node.id] = order
                print("🏭 Started ant production at fabricator \(node.id)")
            }
        }
        
        // Check if current production is complete
        if let order = activeUnitProduction[node.id], order.isComplete {
            // Calculate spawn position (front of fabricator)
            let fabricatorSize = node.getRotatedSize()
            let spawnOffset = order.spawnDirection.offset
            
            let spawnTileX = node.position.x + fabricatorSize.width/2 + spawnOffset.x * 2
            let spawnTileY = node.position.y + fabricatorSize.height/2 + spawnOffset.y * 2
            
            let spawnWorldPos = CGPoint(
                x: CGFloat(spawnTileX) * 32, // Convert to world coordinates
                y: CGFloat(spawnTileY) * 32
            )
            
            // Add completed unit to spawn queue
            completedUnits.append((
                unitType: order.unitType,
                spawnPosition: spawnWorldPos,
                direction: order.spawnDirection,
                faction: order.faction
            ))
            
            // Remove completed order
            activeUnitProduction.removeValue(forKey: node.id)
            
            print("🐜 Ant production completed! Spawning at \(spawnWorldPos)")
        }
    }
    
    // MARK: - Node Management
    
    func addNode(_ node: NetworkNode) {
        nodes[node.id] = node
        needsNetworkRebuild = true
        conveyorTopologyDirty = true
    }
    
    func removeNode(id: UUID) {
        // Mark dirty if removing a conveyor affects corner topology
        if let n = nodes[id], n.blockType.contains("conveyor") { conveyorTopologyDirty = true }
        nodes.removeValue(forKey: id)
        needsNetworkRebuild = true
    }
    
    func updateNode(id: UUID, rotation: BlockRotation) {
        if let n = nodes[id], n.blockType.contains("conveyor") { conveyorTopologyDirty = true }
        nodes[id]?.rotation = rotation
        needsNetworkRebuild = true
    }

    // NEW: Check if a node has item input/output connections
    private func hasItemConnections(_ node: NetworkNode) -> Bool {
        let connections = node.getRotatedConnections()
        return connections.contains { conn in
            conn.connectionTypes.contains { type in
                switch type {
                case .itemInput(_), .itemOutput(_):
                    return true
                default:
                    return false
                }
            }
        }
    }

    // NEW: Check if a node is likely an input source
    private func isLikelyInputSource(_ node: NetworkNode, toDirection: Direction) -> Bool {
        // Item producers are always input sources
        if node.blockType.contains("drill") || node.blockType.contains("bore") {
            return true
        }
        
        // Check if node has output connections in our direction
        let connections = node.getRotatedConnections()
        return connections.contains { conn in
            conn.direction == toDirection &&
            conn.connectionTypes.contains { type in
                if case .itemOutput(_) = type { return true }
                return false
            }
        }
    }

    // NEW: Check if a node is likely an output target
    private func isLikelyOutputTarget(_ node: NetworkNode, fromDirection: Direction) -> Bool {
        // Item consumers are always output targets
        if node.blockType.contains("turret") || node.blockType.contains("factory") ||
           node.blockType == "core-shard" || node.blockType.contains("mixer") {
            return true
        }
        
        // Check if node has input connections from our direction
        let connections = node.getRotatedConnections()
        return connections.contains { conn in
            conn.direction == fromDirection &&
            conn.connectionTypes.contains { type in
                if case .itemInput(_) = type { return true }
                return false
            }
        }
    }
    
    private func getCornerRotation(flow: ConveyorFlow) -> Int? {
        guard let input = flow.inputDirection,
              let output = flow.outputDirection else { return nil }
        
        // Check if input and output are perpendicular (not opposite)
        guard input.opposite != output else { return nil }
        
        // Determine corner rotation based on input-output configuration
        // The corner texture should rotate so items flow from input to output
        switch (input, output) {
        case (.south, .east), (.west, .north):  // Bottom-left to top-right flow
            return 0
        case (.west, .south), (.north, .east):  // Top-left to bottom-right flow
            return 1
        case (.north, .west), (.east, .south):  // Top-right to bottom-left flow
            return 2
        case (.east, .north), (.south, .west):  // Bottom-right to top-left flow
            return 3
        default:
            return nil
        }
    }
    
    private func getConveyorFlow(for nodeId: UUID) -> ConveyorFlow {
        guard let node = nodes[nodeId] else { return ConveyorFlow(inputDirection: nil, outputDirection: nil) }
        
        var inputDirection: Direction? = nil
        var outputDirection: Direction? = nil
        
        // Check all four directions for actual connections
        for direction in Direction.allCases {
            // Get all edge positions for this direction
            let edgePositions = node.getEdgePositions(for: direction)
            
            // Check if any edge position has a connected conveyor
            for edgePos in edgePositions {
                // Find nodes at this edge position
                for (_, neighbor) in nodes {
                    if neighbor.id == node.id { continue }
                    
                    let neighborSize = neighbor.getRotatedSize()
                    if edgePos.x >= neighbor.position.x &&
                       edgePos.x < neighbor.position.x + neighborSize.width &&
                       edgePos.y >= neighbor.position.y &&
                       edgePos.y < neighbor.position.y + neighborSize.height &&
                       (neighbor.blockType == "conveyor-belt" || neighbor.blockType.contains("belt")) {
                        
                        // Check if this neighbor can connect to us
                        let neighborConnections = neighbor.getRotatedConnections()
                        for neighborConn in neighborConnections {
                            if neighborConn.direction == direction.opposite {
                                // Check if neighbor outputs items
                                let hasOutput = neighborConn.connectionTypes.contains { type in
                                    if case .itemOutput(_) = type { return true }
                                    return false
                                }
                                if hasOutput {
                                    inputDirection = direction
                                }
                            }
                        }
                        
                        // Check if we output to neighbor
                        let ourConnections = node.getRotatedConnections()
                        for ourConn in ourConnections {
                            if ourConn.direction == direction {
                                let hasOutput = ourConn.connectionTypes.contains { type in
                                    if case .itemOutput(_) = type { return true }
                                    return false
                                }
                                if hasOutput {
                                    outputDirection = direction
                                }
                            }
                        }
                    }
                }
            }
        }
        
        return ConveyorFlow(inputDirection: inputDirection, outputDirection: outputDirection)
    }
    
    // MARK: - Network Analysis
    
    private func rebuildNetworks() {
        networks.removeAll()
        var visited: Set<UUID> = []
        
        // Find all connected components
        for (nodeId, _) in nodes {
            if !visited.contains(nodeId) {
                let network = buildNetwork(startingFrom: nodeId, visited: &visited)
                if !network.nodes.isEmpty {
                    networks.append(network)
                }
            }
        }
        
        needsNetworkRebuild = false
    }
    
    private func buildNetwork(startingFrom nodeId: UUID, visited: inout Set<UUID>) -> TransmissionNetwork {
        var network = TransmissionNetwork()
        var queue: [UUID] = [nodeId]
        
        while !queue.isEmpty {
            let currentId = queue.removeFirst()
            
            if visited.contains(currentId) { continue }
            visited.insert(currentId)
            
            guard let currentNode = nodes[currentId] else { continue }
            network.addNode(currentNode)
            
            // Find connected nodes
            let connections = currentNode.getRotatedConnections()
            for connection in connections {
                // Check all edge positions for this connection direction
                let edgePositions = currentNode.getEdgePositions(for: connection.direction)
                
                // Check all edge positions - don't stop after finding one connection
                for edgePosition in edgePositions {
                    // Find any node that overlaps with this edge position
                    for (_, targetNode) in nodes {
                        if targetNode.id == currentNode.id { continue }
                        
                        // Check if this edge position is within the target node's bounds
                        let targetSize = targetNode.getRotatedSize()
                        if edgePosition.x >= targetNode.position.x &&
                           edgePosition.x < targetNode.position.x + targetSize.width &&
                           edgePosition.y >= targetNode.position.y &&
                           edgePosition.y < targetNode.position.y + targetSize.height {
                            
                            // Check if nodes can actually connect
                            if canConnect(from: currentNode, connection: connection, to: targetNode) {
                                // Add to queue if not visited
                                if !visited.contains(targetNode.id) {
                                    queue.append(targetNode.id)
                                }
                                // Always add the connection (even if targetNode was already visited)
                                network.addConnection(from: currentId, to: targetNode.id, via: connection)
                            }
                        }
                    }
                }
            }
        }
        
        return network
    }
    

    
    private func canConnect(from source: NetworkNode, connection: UniversalConnection, to target: NetworkNode) -> Bool {
        // The required direction is the opposite of the source's connection direction
        let requiredDirection = connection.direction.opposite
        let targetConnections = target.getRotatedConnections()
        
        // Check if target has a connection in the opposite direction with compatible types
        return targetConnections.contains { targetConnection in
            targetConnection.direction == requiredDirection &&
            hasCompatibleConnectionTypes(source: connection.connectionTypes, target: targetConnection.connectionTypes)
        }
    }
    
    private func hasCompatibleConnectionTypes(source: Set<UniversalConnection.ConnectionType>, target: Set<UniversalConnection.ConnectionType>) -> Bool {
        for sourceType in source {
            for targetType in target {
                if areCompatible(sourceType, targetType) {
                    return true
                }
            }
        }
        return false
    }
    
    private func areCompatible(_ type1: UniversalConnection.ConnectionType, _ type2: UniversalConnection.ConnectionType) -> Bool {
        switch (type1, type2) {
        case (.powerOutput(let p1), .powerInput(let p2)):
            return p1 == p2
        case (.powerInput(let p1), .powerOutput(let p2)):
            return p1 == p2
        case (.itemOutput(_), .itemInput(_)):
            return true
        case (.itemInput(_), .itemOutput(_)):
            return true
        case (.fluidOutput(_), .fluidInput(_)):
            return true
        case (.fluidInput(_), .fluidOutput(_)):
            return true
        default:
            return false
        }
    }
    
    // MARK: - Update Loop
    
    private func startUpdateLoop() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            self?.updateNetworks()
        }
    }
    
    private func updateNetworks() {
        if needsNetworkRebuild {
            rebuildNetworks()
        }
        
        // Update each network
        for network in networks {
            updateNetwork(network)
        }
        
        // Update active transfers
        updateTransfers()
        
        // Notify UI of changes
        
        // --- Turret head/firing/projectiles ---
        let now = CACurrentMediaTime()
        let dt  = now - lastTickTime
        lastTickTime = now
        updateTurretHeads(dt: dt)
        updateTurrets(now: now)
        updateProjectiles(dt: dt)
DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }
    
    private func updateNetwork(_ network: TransmissionNetwork) {
        // Update power flow
        updatePowerFlow(in: network)
        
        // Update item flow - make sure this is called for ALL nodes
        updateItemFlow(in: network)
        
        // Update fluid flow
        updateFluidFlow(in: network)
        
        // Update conveyor corners (event-driven)
        if conveyorTopologyDirty {
            updateConveyorCorners()
            conveyorTopologyDirty = false
        }
    }
    
    // MARK: - Power Flow Simulation
    
    private func updatePowerFlow(in network: TransmissionNetwork) {
        var generators: [NetworkNode] = []
        var consumers: [NetworkNode] = []
        var powerConductors: [NetworkNode] = [] // NEW: Track nodes that can conduct power
        
        // Categorize nodes
        for nodeId in network.nodes {
            guard let node = nodes[nodeId] else { continue }
            
            let connections = node.getRotatedConnections()
            let hasPowerOutput = connections.contains { connection in
                connection.connectionTypes.contains { type in
                    if case .powerOutput(_) = type { return true }
                    return false
                }
            }
            let hasPowerInput = connections.contains { connection in
                connection.connectionTypes.contains { type in
                    if case .powerInput(_) = type { return true }
                    return false
                }
            }
            
            // Only consider nodes that have ANY power connection
            if hasPowerOutput || hasPowerInput {
                if hasPowerOutput && !hasPowerInput {
                    generators.append(node)
                } else if hasPowerInput && !hasPowerOutput {
                    consumers.append(node)
                } else if hasPowerInput && hasPowerOutput {
                    // Nodes that can both input and output power (like shafts)
                    powerConductors.append(node)
                }
            }
        }
        
        // Calculate total generation and consumption
        let totalGeneration = generators.reduce(0) { total, generator in
            total + getPowerGeneration(for: generator)
        }
        
        let totalConsumption = consumers.reduce(0) { total, consumer in
            total + getPowerConsumption(for: consumer)
        }
        
        // Distribute power
        let efficiency = min(1.0, totalGeneration / max(totalConsumption, 1.0))
        
        // Update node power levels - ONLY for nodes that actually handle power
        for nodeId in network.nodes {
            guard let node = nodes[nodeId] else { continue }
            
            if generators.contains(where: { $0.id == nodeId }) {
                // Power generators
                node.powerLevel = getPowerGeneration(for: node)
                node.isActive = true
            } else if consumers.contains(where: { $0.id == nodeId }) {
                // Power consumers
                node.powerLevel = getPowerConsumption(for: node) * efficiency
                node.isActive = efficiency > 0.5 // Node is active if it gets enough power
            } else if powerConductors.contains(where: { $0.id == nodeId }) {
                // Power conductors (like shafts)
                node.powerLevel = totalGeneration * efficiency
                node.isActive = efficiency > 0.1
            } else {
                // Nodes with no power connections (like conveyor belts) - NO POWER!
                node.powerLevel = 0
                node.isActive = false
            }
        }
    }
    
    // MARK: - Item Flow Simulation
    
    private func updateItemFlow(in network: TransmissionNetwork) {
        var producers: [NetworkNode] = []
        var consumers: [NetworkNode] = []
        var transporters: [NetworkNode] = []
        
        // Categorize nodes by their item handling capabilities
        for nodeId in network.nodes {
            guard let node = nodes[nodeId] else { continue }
            
            let connections = node.getRotatedConnections()
            var hasItemInput = false
            var hasItemOutput = false
            
            for connection in connections {
                for connectionType in connection.connectionTypes {
                    switch connectionType {
                    case .itemInput(_):
                        hasItemInput = true
                    case .itemOutput(_):
                        hasItemOutput = true
                    default:
                        break
                    }
                }
            }
            
            if hasItemOutput && !hasItemInput {
                producers.append(node)
            } else if hasItemInput && !hasItemOutput {
                consumers.append(node)
            } else if hasItemInput && hasItemOutput {
                transporters.append(node)
            }
        }
        
        // Process item production
        for producer in producers {
            if producer.isActive { // Only produce if powered
                processItemProduction(for: producer)
            }
        }
        
        // Process item transport from producers
        for producer in producers {
            processItemTransport(for: producer, in: network)
        }
        
        // Process item transport from transporters
        for transporter in transporters {
            processItemTransport(for: transporter, in: network)
        }
        
        // Process item consumption - FIXED: Handle core blocks specially
        for consumer in consumers {
            // Core blocks should always consume items, regardless of power state
            if consumer.blockType.hasPrefix("core") {
                processItemConsumption(for: consumer)
            } else if consumer.isActive { // Other consumers only consume if powered
                processItemConsumption(for: consumer)
            }
        }
        
        // Process unit production for fabricators
        for nodeId in network.nodes {
            guard let node = nodes[nodeId] else { continue }
            processUnitProduction(for: node)
        }
    }
    
    private func processItemProduction(for node: NetworkNode) {
        // Only produce if the node is active (powered)
        guard node.isActive else { return }
        
        // Get base production rate based on block type
        guard let baseProductionInfo = getProductionInfo(for: node.blockType) else { return }
        
        let currentTime = CACurrentMediaTime()
        let timeSinceLastUpdate = currentTime - node.lastUpdateTime
        
        // Only produce if enough time has passed
        if timeSinceLastUpdate >= 1.0 / baseProductionInfo.rate {
            // For drills, determine output based on what ore they're facing
            let outputItems: [ItemType: Int]
            
            if node.blockType.contains("drill") || node.blockType.contains("bore") {
                outputItems = getDrillOutput(for: node.blockType, facingOres: node.oreTypesFacing)
            } else {
                outputItems = baseProductionInfo.outputs
            }
            
            // Produce items
            for (itemType, count) in outputItems {
                let currentCount = node.itemBuffer[itemType] ?? 0
                // Limit buffer size to prevent infinite accumulation
                let maxBuffer = 50
                if currentCount < maxBuffer {
                    node.itemBuffer[itemType] = currentCount + count
                }
            }
            node.lastUpdateTime = currentTime
        }
    }

    // Add this new method to TransmissionNetworkManager (A.swift):

    /// Determine what items a drill should output based on the ore it's facing
    private func getDrillOutput(for blockType: String, facingOres: [OreType]) -> [ItemType: Int] {
        // Convert ore types to item types
        var outputs: [ItemType: Int] = [:]
        
        let baseRate: Int
        switch blockType {
        case "mechanical-drill":
            baseRate = 1
        case "plasma-bore":
            baseRate = 1
        case "advanced-plasma-bore":
            baseRate = 2
        default:
            baseRate = 1
        }
        
        // Convert facing ores to corresponding items
        if facingOres.isEmpty {
            // If no ore is detected, default to copper for backwards compatibility
            outputs[.copper] = baseRate
        } else {
            for oreType in facingOres {
                switch oreType {
                case .copper:
                    outputs[.copper] = baseRate
                case .graphite:
                    outputs[.graphite] = baseRate
                case .none:
                    break
                case .coal:
                    outputs[.coal] = baseRate
                case .sulfur:
                    outputs[.sulfur] = baseRate
                }
            }
            
            // Ensure we always output something (fallback to copper if no valid ore mapping found)
            if outputs.isEmpty {
                outputs[.copper] = baseRate
            }
        }
        
        return outputs
    }
    
    private func calculateSeamlessTransferPosition(from source: NetworkNode, to target: NetworkNode, connection: UniversalConnection, sourceProgress: Double = 0.0) -> CGPoint {
        let tileSize: CGFloat = 32
        
        let targetCenterX = CGFloat(target.position.x) * tileSize + tileSize / 2
        let targetCenterY = CGFloat(target.position.y) * tileSize + tileSize / 2
        
        // Determine which edge of the target the item is entering from
        let sourceDirection = connection.direction.opposite
        
        // Calculate the exact edge position where the item should start
        // Make it slightly more inward for smoother visual transition
        let edgeOffset: CGFloat = tileSize * 0.35 // Reduced from 0.45 for smoother entry
        
        // IMPROVED: Account for source animation progress to create seamless transition
        let progressOffset: CGFloat = tileSize * 0.1 * CGFloat(sourceProgress) // Small adjustment based on source progress
        
        switch sourceDirection {
        case .north:
            return CGPoint(x: targetCenterX, y: targetCenterY - edgeOffset - progressOffset)
        case .south:
            return CGPoint(x: targetCenterX, y: targetCenterY + edgeOffset + progressOffset)
        case .east:
            return CGPoint(x: targetCenterX + edgeOffset + progressOffset, y: targetCenterY)
        case .west:
            return CGPoint(x: targetCenterX - edgeOffset - progressOffset, y: targetCenterY)
        }
    }

    // MARK: - Helper function to calculate optimal steps
    private func calculateOptimalSteps(for duration: Double) -> Int {
        // Increase steps per second for smoother animation during transitions
        let stepsPerSecond = 8.0 // Increased from 6.0
        let optimalSteps = Int(duration * stepsPerSecond)
        
        // Tighter bounds for more consistent animation
        return max(4, min(12, optimalSteps)) // Reduced max from 15 to 12
    }

    // MARK: - Updated transfer from non-conveyor with synchronized items
    private func transferFromNonConveyor(from source: NetworkNode, in network: TransmissionNetwork, currentTime: TimeInterval) {
        let connections = source.getRotatedConnections()
        let outputConnections = connections.filter { connection in
            connection.connectionTypes.contains { type in
                if case .itemOutput(_) = type { return true }
                return false
            }
        }
        
        for connection in outputConnections {
            let edgePositions = source.getEdgePositions(for: connection.direction)
            
            for edgePosition in edgePositions {
                for (_, targetNode) in nodes {
                    if targetNode.id == source.id { continue }
                    
                    let targetSize = targetNode.getRotatedSize()
                    if edgePosition.x >= targetNode.position.x &&
                       edgePosition.x < targetNode.position.x + targetSize.width &&
                       edgePosition.y >= targetNode.position.y &&
                       edgePosition.y < targetNode.position.y + targetSize.height {
                        
                        if canConnect(from: source, connection: connection, to: targetNode) {
                            for (itemType, count) in source.itemBuffer where count > 0 {
                                if canAcceptItem(node: targetNode, itemType: itemType, from: connection.direction.opposite) {
                                    
                                    if targetNode.blockType == "conveyor-belt" || targetNode.blockType.contains("belt") {
                                        let canAccept = targetNode.conveyorItems.count < targetNode.capacity &&
                                            (targetNode.conveyorItems.isEmpty ||
                                             targetNode.conveyorItems.allSatisfy { item in
                                                 currentTime - item.startTime > 0.5
                                             })
                                        
                                        if canAccept {
                                            // Calculate seamless start position
                                            let seamlessStartPos = calculateSeamlessTransferPosition(
                                                from: source,
                                                to: targetNode,
                                                connection: connection
                                            )
                                            
                                            // Create item with synchronized properties
                                            let newItem = ConveyorItem(
                                                itemType: itemType,
                                                startTime: currentTime,
                                                transferDuration: targetNode.transferDuration,
                                                seamlessStartPosition: seamlessStartPos,
                                                animationSteps: calculateOptimalSteps(for: targetNode.transferDuration),
                                                isAnimationComplete: false
                                            )
                                            
                                            DispatchQueue.main.async {
                                                source.itemBuffer[itemType] = count - 1
                                                targetNode.conveyorItems.append(newItem)
                                            }
                                            
                                            return
                                        }
                                    } else {
                                        // Transfer to non-conveyor
                                        if targetNode.hasCapacityFor(amount: 1) {
                                            let targetAmount = targetNode.itemBuffer[itemType] ?? 0
                                            
                                            DispatchQueue.main.async {
                                                source.itemBuffer[itemType] = count - 1
                                                targetNode.itemBuffer[itemType] = targetAmount + 1
                                            }
                                            
                                            return
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func transferItems(from source: NetworkNode, to target: NetworkNode, via connection: UniversalConnection) {
        let throughput = connection.constraints.maxThroughput * updateInterval
        var totalTransferred = false
        
        for (itemType, sourceCount) in source.itemBuffer {
            if sourceCount > 0 && !totalTransferred {
                // Calculate how much we can transfer based on throughput
                let maxTransferAmount = min(sourceCount, Int(throughput))
                
                // Check if target can accept this item type from the opposite direction
                if canAcceptItem(node: target, itemType: itemType, from: connection.direction.opposite) {
                    // Check target's capacity
                    let targetCurrentTotal = target.getTotalItemCount()
                    let targetRemainingCapacity = target.capacity - targetCurrentTotal
                    
                    // Only transfer what the target can hold
                    let transferAmount = min(maxTransferAmount, targetRemainingCapacity)
                    
                    if transferAmount > 0 {
                        // NEW: Don't modify buffers immediately - let the transfer handle it
                        // Create visual transfer with node IDs
                        createTransfer(
                            from: source.position,
                            to: target.position,
                            sourceNodeId: source.id,
                            targetNodeId: target.id,
                            itemType: itemType,
                            amount: transferAmount
                        )
                        totalTransferred = true
                    }
                }
                
                break // Only transfer one item type per update for balance
            }
        }
    }
    
    private func canAcceptItem(node: NetworkNode, itemType: ItemType, from direction: Direction) -> Bool {
        let connections = node.getRotatedConnections()
        
        return connections.contains { connection in
            connection.direction == direction &&
            connection.connectionTypes.contains { type in
                if case .itemInput(let acceptedTypes) = type {
                    return acceptedTypes?.contains(itemType) ?? true
                }
                return false
            }
        }
    }
    
    private func processItemConsumption(for node: NetworkNode) {
        // Special handling for Core blocks
        if node.blockType.hasPrefix("core") {
            // Core blocks consume all items in their buffer
            var itemsToConsume: [ItemType: Int] = [:]
            
            for (itemType, amount) in node.itemBuffer {
                if amount > 0 {
                    itemsToConsume[itemType] = amount
                    node.itemBuffer[itemType] = 0
                }
            }
            
            // Add to core inventory
            if !itemsToConsume.isEmpty {
                CoreInventoryManager.shared.addItems(itemsToConsume)
            }
            
            return
        }
        
        // Regular consumption logic for other buildings
        guard let consumptionInfo = getConsumptionInfo(for: node.blockType) else { return }
        
        let timeSinceLastUpdate = CACurrentMediaTime() - node.lastUpdateTime
        let consumptionRate = consumptionInfo.rate * timeSinceLastUpdate
        
        for (itemType, requiredAmount) in consumptionInfo.inputs {
            let currentAmount = node.itemBuffer[itemType] ?? 0
            let consumeAmount = min(currentAmount, Int(Double(requiredAmount) * consumptionRate))
            
            if consumeAmount > 0 {
                node.itemBuffer[itemType] = currentAmount - consumeAmount
            }
        }
        
        node.lastUpdateTime = CACurrentMediaTime()
    }
    
    // MARK: - Fluid Flow Simulation
    
    private func updateFluidFlow(in network: TransmissionNetwork) {
        // Similar to item flow but for fluids
        // Implementing pressure-based flow simulation
        
        for nodeId in network.nodes {
            guard let node = nodes[nodeId] else { continue }
            
            let connections = node.getRotatedConnections()
            let fluidConnections = connections.filter { connection in
                connection.connectionTypes.contains { type in
                    switch type {
                    case .fluidInput(_), .fluidOutput(_):
                        return true
                    default:
                        return false
                    }
                }
            }
            
            // Process fluid flow based on pressure differences
            for connection in fluidConnections {
                processFluidFlow(from: node, via: connection, in: network)
            }
        }
    }
    
    private func processFluidFlow(from source: NetworkNode, via connection: UniversalConnection, in network: TransmissionNetwork) {
        // Implement fluid dynamics here
        // This is a simplified version - real fluid simulation would be more complex
    }
    
    // MARK: - Transfer Management
    
    private func hasActiveTransfer(from sourcePos: SIMD2<Int>, to targetPos: SIMD2<Int>) -> Bool {
        return activeTransfers.contains { transfer in
            transfer.sourcePosition == sourcePos && transfer.targetPosition == targetPos
        }
    }
    
    private func createTransfer(from sourcePos: SIMD2<Int>, to targetPos: SIMD2<Int>,
                              sourceNodeId: UUID, targetNodeId: UUID,
                              itemType: ItemType, amount: Int) {
        let transferKey = "\(sourcePos.x),\(sourcePos.y)->\(targetPos.x),\(targetPos.y)"
        let currentTime = CACurrentMediaTime()
        
        // Check if enough time has passed since last transfer on this route
        if let lastTime = lastTransferTimes[transferKey] {
            guard currentTime - lastTime >= minTransferInterval else { return }
        }
        
        // Don't create multiple transfers on the same route
        let hasExisting = activeTransfers.contains { transfer in
            transfer.sourcePosition == sourcePos && transfer.targetPosition == targetPos
        }
        guard !hasExisting else { return }
        
        let transfer = Transfer(
            id: UUID(),
            sourcePosition: sourcePos,
            targetPosition: targetPos,
            sourceNodeId: sourceNodeId,
            targetNodeId: targetNodeId,
            itemType: itemType,
            amount: amount,
            startTime: currentTime,
            duration: 0.5
        )
        activeTransfers.append(transfer)
        lastTransferTimes[transferKey] = currentTime
    }
    
    private func updateTransfers() {
        // Update transfer states and handle item movement
        for index in activeTransfers.indices.reversed() {
            var transfer = activeTransfers[index]
            
            // SIMPLE FIX: Only move items at 90% completion
            if transfer.progress >= 0.9 && !transfer.hasRemovedFromSource {
                if let sourceNode = nodes[transfer.sourceNodeId],
                   let targetNode = nodes[transfer.targetNodeId] {
                    
                    let sourceAmount = sourceNode.itemBuffer[transfer.itemType] ?? 0
                    if sourceAmount >= transfer.amount {
                        // Check target capacity
                        let targetCurrentTotal = targetNode.getTotalItemCount()
                        let targetRemainingCapacity = targetNode.capacity - targetCurrentTotal
                        
                        if targetRemainingCapacity >= transfer.amount {
                            // Remove from source
                            sourceNode.itemBuffer[transfer.itemType] = sourceAmount - transfer.amount
                            
                            // Add to target immediately
                            let targetAmount = targetNode.itemBuffer[transfer.itemType] ?? 0
                            targetNode.itemBuffer[transfer.itemType] = targetAmount + transfer.amount
                            
                            transfer.hasRemovedFromSource = true
                            transfer.hasAddedToTarget = true
                            activeTransfers[index] = transfer
                        }
                    }
                }
            }
            
            // Remove completed transfers
            if transfer.progress >= 1.0 {
                activeTransfers.remove(at: index)
            }
        }
    }
    
    // MARK: - Helper Functions
    
    private func getPowerGeneration(for node: NetworkNode) -> Double {
        switch node.blockType {
        case "steam-engine":
            return 100.0
        case "combustion-engine":
            return 150.0
        default:
            return 0.0
        }
    }
    
    private func getPowerConsumption(for node: NetworkNode) -> Double {
        switch node.blockType {
        case "mechanical-drill":
            return 20.0
        case "plasma-bore":
            return 35.0
        case "advanced-plasma-bore":
            return 50.0
        case "tank-fabricator":
            return 25.0
        default:
            return 0.0
        }
    }
    
    private func getProductionInfo(for blockType: String) -> (rate: Double, outputs: [ItemType: Int])? {
        switch blockType {
        case "mechanical-drill":
            return (rate: 0.5, outputs: [.copper: 1]) // 0.5 items per second
        case "plasma-bore":
            return (rate: 0.67, outputs: [.copper: 1, .graphite: 1])
        case "advanced-plasma-bore":
            return (rate: 1.0, outputs: [.copper: 2, .graphite: 2])
        default:
            return nil
        }
    }
    
    private func getConsumptionInfo(for blockType: String) -> (rate: Double, inputs: [ItemType: Int])? {
        switch blockType {
        case "silicon-mixer":
            return (rate: 0.5, inputs: [.copper: 2, .graphite: 1])
        default:
            return nil
        }
    }
    
    // MARK: - Public Interface
    
    func getNodePowerLevel(id: UUID) -> Double {
        return nodes[id]?.powerLevel ?? 0
    }
    
    func getNodeItemCount(id: UUID, itemType: ItemType) -> Int {
        return nodes[id]?.itemBuffer[itemType] ?? 0
    }
    
    func isNodeActive(id: UUID) -> Bool {
        return nodes[id]?.isActive ?? false
    }
    
    func getActiveTransfers() -> [Transfer] {
        return activeTransfers
    }
    
    func getNetworkStats() -> NetworkStats {
        return NetworkStats(
            totalNodes: nodes.count,
            activeNetworks: networks.count,
            activeTransfers: activeTransfers.count,
            totalPowerGeneration: networks.reduce(0) { total, network in
                total + network.nodes.compactMap { nodes[$0] }.reduce(0) { nodeTotal, node in
                    nodeTotal + getPowerGeneration(for: node)
                }
            }
        )
    }
}

// MARK: - Supporting Data Structures

struct TransmissionNetwork {
    var id = UUID()
    var nodes: Set<UUID> = []
    var connections: [(from: UUID, to: UUID, connection: UniversalConnection)] = []
    
    mutating func addNode(_ node: NetworkNode) {
        nodes.insert(node.id)
    }
    
    mutating func addConnection(from sourceId: UUID, to targetId: UUID, via connection: UniversalConnection) {
        connections.append((from: sourceId, to: targetId, connection: connection))
    }
}

struct Transfer: Identifiable {
    let id: UUID
    let sourcePosition: SIMD2<Int>
    let targetPosition: SIMD2<Int>
    let sourceNodeId: UUID
    let targetNodeId: UUID
    let itemType: ItemType
    let amount: Int
    let startTime: TimeInterval
    let duration: TimeInterval
    
    // NEW: Track transfer state
    var hasRemovedFromSource: Bool = false
    var hasAddedToTarget: Bool = false
    
    var progress: Double {
        let elapsed = CACurrentMediaTime() - startTime
        return min(1.0, elapsed / duration)
    }
    
    var currentPosition: SIMD2<Double> {
        let start = SIMD2<Double>(Double(sourcePosition.x), Double(sourcePosition.y))
        let end = SIMD2<Double>(Double(targetPosition.x), Double(targetPosition.y))
        return start + (end - start) * progress
    }
}

struct NetworkStats {
    let totalNodes: Int
    let activeNetworks: Int
    let activeTransfers: Int
    let totalPowerGeneration: Double
}

/// Represents different types of power transmission
enum PowerType: Codable, Hashable {
    case rotational  // Mechanical rotational power (shafts, gears)
    case electrical  // Electrical power (cables, batteries)
    
    var displayName: String {
        switch self {
        case .rotational: return "Rotational"
        case .electrical: return "Electrical"
        }
    }
}

/// Cardinal directions for connections
enum Direction: CaseIterable, Hashable {
    case north, south, east, west
    
    var offset: (x: Int, y: Int) {
        switch self {
        case .north: return (0, -1)
        case .south: return (0, 1)
        case .east: return (1, 0)
        case .west: return (-1, 0)
        }
    }
    
    var opposite: Direction {
        switch self {
        case .north: return .south
        case .south: return .north
        case .east: return .west
        case .west: return .east
        }
    }
    
    /// Get the direction after rotating by a certain number of 90-degree steps
    func rotated(by rotation: BlockRotation) -> Direction {
        let allDirections: [Direction] = [.north, .east, .south, .west]
        guard let currentIndex = allDirections.firstIndex(of: self) else { return self }
        let newIndex = (currentIndex + rotation.rawValue) % 4
        return allDirections[newIndex]
    }
    
    var description: String {
        switch self {
        case .north: return "North"
        case .south: return "South"
        case .east: return "East"
        case .west: return "West"
        }
    }
}

// MARK: - Enhanced Tile Requirement System (unchanged)

/// Defines how many tiles must meet a requirement
enum TileRequirementType: Equatable {
    case all                    // All tiles must meet this requirement
    case any                    // At least one tile must meet this requirement
    case none                   // No tiles can meet this requirement (exclusion)
    case exactly(Int)           // Exactly N tiles must meet this requirement
    case atLeast(Int)           // At least N tiles must meet this requirement
    case atMost(Int)            // At most N tiles must meet this requirement
    case percentage(Double)     // Percentage of tiles must meet this requirement (0.0 to 1.0)
    
    var description: String {
        switch self {
        case .all: return "all tiles"
        case .any: return "at least one tile"
        case .none: return "no tiles"
        case .exactly(let count): return "exactly \(count) tile(s)"
        case .atLeast(let count): return "at least \(count) tile(s)"
        case .atMost(let count): return "at most \(count) tile(s)"
        case .percentage(let pct): return "\(Int(pct * 100))% of tiles"
        }
    }
}

/// Individual conditions that can be checked against a tile
enum TileCondition: Equatable {
    case tileType(TileType)
    case oreType(OreType)
    case anyTileType([TileType])    // Tile must be one of these types
    case anyOreType([OreType])      // Tile must have one of these ore types
    case noOre                      // Tile must have no ore
    case anyOre                     // Tile must have any ore (not .none)
    case notTileType(TileType)      // Tile must NOT be this type
    case notOreType(OreType)        // Tile must NOT have this ore type
    
    var description: String {
        switch self {
        case .tileType(let type): return "be \(type.displayName)"
        case .oreType(let type): return "have \(type.displayName) ore"
        case .anyTileType(let types): return "be one of: \(types.map(\.displayName).joined(separator: ", "))"
        case .anyOreType(let types): return "have ore of: \(types.map(\.displayName).joined(separator: ", "))"
        case .noOre: return "have no ore"
        case .anyOre: return "have any ore"
        case .notTileType(let type): return "not be \(type.displayName)"
        case .notOreType(let type): return "not have \(type.displayName) ore"
        }
    }
    
    /// Check if a tile meets this condition
    func evaluate(tileType: TileType, oreType: OreType) -> Bool {
        switch self {
        case .tileType(let required):
            return tileType == required
        case .oreType(let required):
            return oreType == required
        case .anyTileType(let types):
            return types.contains(tileType)
        case .anyOreType(let types):
            return types.contains(oreType)
        case .noOre:
            return oreType == .none
        case .anyOre:
            return oreType != .none
        case .notTileType(let forbidden):
            return tileType != forbidden
        case .notOreType(let forbidden):
            return oreType != forbidden
        }
    }
}

/// How to combine multiple conditions
enum LogicalOperator: Equatable {
    case and    // All conditions must be true
    case or     // At least one condition must be true
    
    var description: String {
        switch self {
        case .and: return "and"
        case .or: return "or"
        }
    }
}

/// A single requirement rule that can be applied to tiles
struct TileRequirementRule: Equatable {
    let type: TileRequirementType
    let conditions: [TileCondition]
    let logicalOperator: LogicalOperator
    let customErrorMessage: String?
    let priority: Int // Higher priority rules are checked first
    
    init(type: TileRequirementType,
         conditions: [TileCondition],
         logicalOperator: LogicalOperator = .and,
         customErrorMessage: String? = nil,
         priority: Int = 0) {
        self.type = type
        self.conditions = conditions
        self.logicalOperator = logicalOperator
        self.customErrorMessage = customErrorMessage
        self.priority = priority
    }
    
    /// Generate a human-readable description of this rule
    var description: String {
        if let customMessage = customErrorMessage {
            return customMessage
        }
        
        let conditionDesc = conditions.map(\.description).joined(separator: " \(logicalOperator.description) ")
        return "\(type.description) must \(conditionDesc)"
    }
    
    /// Check if this rule is satisfied by the given tiles
    func evaluate(tiles: [(tileType: TileType, oreType: OreType)]) -> (satisfied: Bool, failureReason: String?) {
        var satisfiedCount = 0
        
        for tile in tiles {
            let conditionResults = conditions.map { $0.evaluate(tileType: tile.tileType, oreType: tile.oreType) }
            
            let tilePassesRule: Bool
            switch logicalOperator {
            case .and:
                tilePassesRule = conditionResults.allSatisfy { $0 }
            case .or:
                tilePassesRule = conditionResults.contains(true)
            }
            
            if tilePassesRule {
                satisfiedCount += 1
            }
        }
        
        let totalTiles = tiles.count
        let satisfied: Bool
        
        switch type {
        case .all:
            satisfied = satisfiedCount == totalTiles
        case .any:
            satisfied = satisfiedCount > 0
        case .none:
            satisfied = satisfiedCount == 0
        case .exactly(let count):
            satisfied = satisfiedCount == count
        case .atLeast(let count):
            satisfied = satisfiedCount >= count
        case .atMost(let count):
            satisfied = satisfiedCount <= count
        case .percentage(let pct):
            let required = Int(ceil(Double(totalTiles) * pct))
            satisfied = satisfiedCount >= required
        }
        
        if satisfied {
            return (true, nil)
        } else {
            let reason = customErrorMessage ?? description
            return (false, reason)
        }
    }
}

/// Position-specific requirement for multi-tile buildings
struct PositionalRequirement: Equatable {
    let relativePosition: CGPoint  // Relative to top-left corner
    let rules: [TileRequirementRule]
    
    init(x: Int, y: Int, rules: [TileRequirementRule]) {
        self.relativePosition = CGPoint(x: x, y: y)
        self.rules = rules
    }
}

/// Custom validation function type for complex requirements
typealias CustomValidationFunction = (
    _ blockSize: (width: Int, height: Int),
    _ position: (x: Int, y: Int),
    _ rotation: BlockRotation,
    _ mapData: MapData
) -> (isValid: Bool, failureReason: String?)

/// The main tile requirement structure - supports both global and per-tile requirements
struct TileRequirement: Equatable {
    let globalRules: [TileRequirementRule]           // Rules that apply to all tiles
    let positionalRequirements: [PositionalRequirement]  // Rules for specific positions
    let name: String                                 // Human-readable name
    let description: String                          // Detailed description
    let customValidation: CustomValidationFunction?  // NEW: Custom validation for complex cases
    
    init(globalRules: [TileRequirementRule] = [],
         positionalRequirements: [PositionalRequirement] = [],
         name: String,
         description: String,
         customValidation: CustomValidationFunction? = nil) {
        // Sort rules by priority (higher first)
        self.globalRules = globalRules.sorted { $0.priority > $1.priority }
        self.positionalRequirements = positionalRequirements
        self.name = name
        self.description = description
        self.customValidation = customValidation
    }
    
    // MARK: - Equatable Implementation (Updated for Custom Validation)
    static func == (lhs: TileRequirement, rhs: TileRequirement) -> Bool {
        return lhs.globalRules == rhs.globalRules &&
               lhs.positionalRequirements == rhs.positionalRequirements &&
               lhs.name == rhs.name &&
               lhs.description == rhs.description
        // Note: customValidation functions can't be compared directly, so we exclude them from equality
    }
    
    /// Validate if a block can be placed at the given position
    func validate(blockSize: (width: Int, height: Int),
                  at position: (x: Int, y: Int),
                  rotation: BlockRotation,
                  mapData: MapData) -> (isValid: Bool, failureReason: String?) {
        
        // NEW: Check custom validation first if it exists
        if let customValidation = customValidation {
            let customResult = customValidation(blockSize, position, rotation, mapData)
            if !customResult.isValid {
                return customResult
            }
        }
        
        let rotatedSize = rotation.applied(to: blockSize)
        
        // Collect all tiles that would be occupied
        var allTiles: [(tileType: TileType, oreType: OreType)] = []
        var tilePositions: [(x: Int, y: Int)] = []
        
        for blockX in position.x..<(position.x + rotatedSize.width) {
            for blockY in position.y..<(position.y + rotatedSize.height) {
                // Check bounds
                guard blockX >= 0 && blockX < mapData.width &&
                      blockY >= 0 && blockY < mapData.height else {
                    return (false, "Block extends outside map boundaries")
                }
                
                let tileType = mapData.tiles[blockY][blockX]
                let oreType = mapData.ores[blockY][blockX]
                allTiles.append((tileType: tileType, oreType: oreType))
                tilePositions.append((x: blockX, y: blockY))
            }
        }
        
        // Check global rules first
        for rule in globalRules {
            let result = rule.evaluate(tiles: allTiles)
            if !result.satisfied {
                return (false, result.failureReason)
            }
        }
        
        // Check positional requirements
        for posReq in positionalRequirements {
            // Calculate actual position considering rotation
            let rotatedOffset = rotation.applied(to: posReq.relativePosition)
            let actualX = position.x + Int(rotatedOffset.x)
            let actualY = position.y + Int(rotatedOffset.y)
            
            // Check bounds for this specific position
            guard actualX >= 0 && actualX < mapData.width &&
                  actualY >= 0 && actualY < mapData.height else {
                return (false, "Required position (\(actualX), \(actualY)) is outside map boundaries")
            }
            
            let tileType = mapData.tiles[actualY][actualX]
            let oreType = mapData.ores[actualY][actualX]
            let singleTile = [(tileType: tileType, oreType: oreType)]
            
            for rule in posReq.rules {
                let result = rule.evaluate(tiles: singleTile)
                if !result.satisfied {
                    return (false, "Position (\(Int(posReq.relativePosition.x)), \(Int(posReq.relativePosition.y))): \(result.failureReason ?? rule.description)")
                }
            }
        }
        
        return (true, nil)
    }
}

#Preview {
    let mapFileURL = Bundle.main.mapFileURL(named: "Terrain_SG")!
    GameView(fileURL: mapFileURL, onReturnToSectorMap: nil)
        .environmentObject(GlobalHoverObserver())
        .ignoresSafeArea()
}
