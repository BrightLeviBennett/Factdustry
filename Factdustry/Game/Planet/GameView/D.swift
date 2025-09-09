//
//  D.swift
//  Factdustry
//
//  Created by Bright on 7/24/25.
//

import SwiftUI
import UIKit
import Combine
import SwiftData
import SpriteKit


// MARK: - Enhanced Block Info Display with Connection Information

//struct EnhancedBlockInfoDisplay: View {
//    let selectedBlock: BlockType
//    let selectedBlockRotation: BlockRotation
//    let researchManager: ResearchManager
//    @State private var name = ""
//
//    var body: some View {
//        VStack(alignment: .leading, spacing: 8) {
//            HStack(spacing: 8) {
//                // Standardized block icon in info display
//                StandardizedBlockImageView(
//                    iconName: selectedBlock.iconName,
//                    targetSize: 32,
//                    rotation: selectedBlockRotation
//                )
//
//                VStack(alignment: .leading, spacing: 4) {
//                    Text(name)
//                        .font(.headline)
//                        .fontWeight(.bold)
//                        .foregroundColor(.white)
//
//                    let rotatedSize = selectedBlock.getRotatedSize(rotation: selectedBlockRotation)
//                    Text("Size: \(rotatedSize.width)Ã—\(rotatedSize.height) tiles")
//                        .font(.caption)
//                        .foregroundColor(.gray)
//
//                    if selectedBlock.canRotate {
//                        Text("ðŸ”„ Rotatable")
//                            .font(.caption2)
//                            .foregroundColor(.cyan)
//                    }
//                }
//                Spacer()
//            }
//
//            // Build cost
//            if !selectedBlock.buildCost.isEmpty {
//                VStack(alignment: .leading, spacing: 2) {
//                    Text("Build Cost:")
//                        .font(.caption)
//                        .fontWeight(.semibold)
//                        .foregroundColor(.orange)
//
//                    Text(formatBuildCost(selectedBlock.buildCost))
//                        .font(.caption2)
//                        .foregroundColor(.orange)
//                }
//            }
//
//            // NEW: Connection info with the unified system
//            if !selectedBlock.connections.isEmpty {
//                VStack(alignment: .leading, spacing: 2) {
//                    Text("Connections:")
//                        .font(.caption)
//                        .fontWeight(.semibold)
//                        .foregroundColor(.cyan)
//
//                    ForEach(Array(selectedBlock.connections.enumerated()), id: \.offset) { index, connection in
//                        HStack(spacing: 4) {
//                            // Show all connection types for this direction
//                            let connectionTypesText = connection.connectionTypes.map { type in
//                                connectionTypeDescription(type)
//                            }.joined(separator: ", ")
//
//                            Text("\(connection.direction)".capitalized)
//                                .font(.caption2)
//                                .foregroundColor(.gray)
//
//                            Text(connectionTypesText)
//                                .font(.caption2)
//                                .foregroundColor(.cyan)
//                        }
//                    }
//                }
//            }
//
//            // Enhanced tile requirements display
//            if let requirement = selectedBlock.tileRequirement {
//                VStack(alignment: .leading, spacing: 4) {
//                    Text("Requirements:")
//                        .font(.caption)
//                        .fontWeight(.semibold)
//                        .foregroundColor(.yellow)
//
//                    Text(requirement.name)
//                        .font(.caption2)
//                        .fontWeight(.medium)
//                        .foregroundColor(.yellow)
//
//                    Text(requirement.description)
//                        .font(.caption2)
//                        .foregroundColor(.gray)
//                        .lineLimit(3)
//
//                    // Show detailed rules for complex requirements
//                    if requirement.globalRules.count > 1 || !requirement.positionalRequirements.isEmpty {
//                        ForEach(Array(requirement.globalRules.prefix(2).enumerated()), id: \.offset) { index, rule in
//                            Text("â€¢ \(rule.description)")
//                                .font(.caption2)
//                                .foregroundColor(.gray)
//                        }
//
//                        if requirement.globalRules.count > 2 {
//                            Text("â€¢ +\(requirement.globalRules.count - 2) more rules...")
//                                .font(.caption2)
//                                .foregroundColor(.gray)
//                                .italic()
//                        }
//                    }
//                }
//            }
//
//            // Research status
//            if researchManager.requireResearchForPlacement {
//                let researchInfo = researchManager.getResearchInfo(for: selectedBlock.iconName)
//                HStack(spacing: 4) {
//                    Group {
//                        if researchInfo.isResearched {
//                            Image(systemName: "checkmark.circle.fill")
//                                .foregroundColor(.green)
//                            Text("Researched")
//                                .foregroundColor(.green)
//                        } else if researchInfo.canResearch {
//                            Image(systemName: "exclamationmark.triangle.fill")
//                                .foregroundColor(.yellow)
//                            Text("Research Available")
//                                .foregroundColor(.yellow)
//                        } else {
//                            Image(systemName: "lock.circle.fill")
//                                .foregroundColor(.red)
//                            Text("Research Locked")
//                                .foregroundColor(.red)
//                        }
//                    }
//                    .font(.caption2)
//                }
//            }
//
//            Spacer()
//        }
//        .padding(12)
//        .background(
//            RoundedRectangle(cornerRadius: 8)
//                .fill(Color.black.opacity(0.8))
//                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
//        )
//        .frame(maxWidth: 280)
//        .onAppear {
//            updateDisplayName()
//        }
//        .onChange(of: selectedBlock.iconName) {
//            updateDisplayName()
//        }
//    }
//
//    private func updateDisplayName() {
//        name = selectedBlock.iconName
//            .split(separator: "-")
//            .map { $0.capitalized }
//            .joined(separator: " ")
//            .replacingOccurrences(of: "_", with: " ")
//    }
//
//    private func formatBuildCost(_ buildCost: [ItemType: Int]) -> String {
//        return buildCost.map { "\($0.value) \($0.key.displayName)" }.joined(separator: ", ")
//    }
//
//    // NEW: Helper function for connection type description
//    private func connectionTypeDescription(_ connectionType: UniversalConnection.ConnectionType) -> String {
//        switch connectionType {
//        case .powerInput(let type): return "âš¡In(\(type.displayName))"
//        case .powerOutput(let type): return "âš¡Out(\(type.displayName))"
//        case .itemInput(let types):
//            if let types = types {
//                return "ðŸ“¦In(\(types.map(\.displayName).joined(separator: ", ")))"
//            } else {
//                return "ðŸ“¦In(All)"
//            }
//        case .itemOutput(let types):
//            if let types = types {
//                return "ðŸ“¦Out(\(types.map(\.displayName).joined(separator: ", ")))"
//            } else {
//                return "ðŸ“¦Out(All)"
//            }
//        case .fluidInput(let types):
//            if let types = types {
//                return "ðŸ’§In(\(types.map(\.displayName).joined(separator: ", ")))"
//            } else {
//                return "ðŸ’§In(All)"
//            }
//        case .fluidOutput(let types):
//            if let types = types {
//                return "ðŸ’§Out(\(types.map(\.displayName).joined(separator: ", ")))"
//            } else {
//                return "ðŸ’§Out(All)"
//            }
//        }
//    }
//}

// MARK: - Views

struct ResourceStatusBar: View {
    let resources: [Resource]
    
    var body: some View {
        HStack(spacing: 12) {
            ForEach(resources) { res in
                HStack(spacing: 4) {
                    Image(systemName: res.iconName)
                        .resizable()
                        .frame(width: 20, height: 20)
                    Text("\(res.count)")
                        .font(.footnote).bold()
                }
                .padding(6)
                .background(Color.black.opacity(0.6))
                .cornerRadius(6)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

// MARK: - NEW: SwiftUI Integration Components

struct TransmissionNetworkView: View {
    @ObservedObject var networkManager: TransmissionNetworkManager
    @ObservedObject var blockLoadingManager: BlockLoadingManager  // Add this
    let mapData: MapData
    let tileSize: CGFloat
    
    var body: some View {
        ZStack {
            // Smooth conveyor items with animations
            ConveyorItemsView(
                networkManager: networkManager,
                blockLoadingManager: blockLoadingManager,  // Add this
                tileSize: tileSize
            )
            
            // Node status indicators
            NodeStatusView(
                networkManager: networkManager,
                mapData: mapData,
                tileSize: tileSize
            )
        }
    }
}

// MARK: - Synchronized Animation View (Replace in D.swift)
struct SynchronizedGridItemView: View {
    let item: ConveyorItem
    let node: NetworkNode
    let networkManager: TransmissionNetworkManager
    let isCorner: Bool
    let cornerRotation: Int
    let tileSize: CGFloat
    
    @State private var currentPosition: CGPoint = .zero
    @State private var currentStep: Int = 0
    @State private var gridPath: [CGPoint] = []
    @State private var hasStarted = false
    @State private var animationComplete = false
    
    var body: some View {
        Image(item.itemType.iconName)
            .resizable()
            .frame(width: 20, height: 20)
            .background(
                Circle()
                    .fill(animationComplete ? Color.green.opacity(0.3) : Color.blue.opacity(0.2))
                    .frame(width: 24, height: 24)
            )
            .position(currentPosition)
            .onAppear {
                setupSynchronizedAnimation()
            }
            .onChange(of: item.id) {
                setupSynchronizedAnimation()
            }
    }
    
    private func setupSynchronizedAnimation() {
        hasStarted = false
        currentStep = 0
        animationComplete = false
        
        // Generate path with optimal step count
        generateOptimalPath()
        
        // Set initial position
        if !gridPath.isEmpty {
            if let seamlessStart = item.seamlessStartPosition {
                currentPosition = seamlessStart
                // Adjust first path point to match seamless start
                gridPath[0] = seamlessStart
            } else {
                currentPosition = gridPath[0]
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                startSynchronizedAnimation()
            }
        }
    }
    
    private func generateOptimalPath() {
        let centerX = CGFloat(node.position.x) * tileSize + tileSize / 2
        let centerY = CGFloat(node.position.y) * tileSize + tileSize / 2
        
        // Calculate optimal number of steps based on transfer duration
        // Ensure animation completes slightly before transfer (at ~90% of duration)
        let optimalSteps = /*30*/max(6, min(12, Int(item.transferDuration * 5))) // 5 steps per second
        
        if isCorner {
            generateOptimalCornerPath(centerX: centerX, centerY: centerY, steps: optimalSteps)
        } else {
            generateOptimalStraightPath(centerX: centerX, centerY: centerY, steps: optimalSteps)
        }
    }
    
    private func generateOptimalStraightPath(centerX: CGFloat, centerY: CGFloat, steps: Int) {
        var path: [CGPoint] = []
        
        // Start position
        let startPoint: CGPoint
        if let seamlessStart = item.seamlessStartPosition {
            startPoint = seamlessStart
        } else {
            let inputDirection = getInputDirection()
            let inputOffset = getDirectionOffset(inputDirection)
            startPoint = CGPoint(
                x: centerX + inputOffset.x * tileSize * 0.45,
                y: centerY + inputOffset.y * tileSize * 0.45
            )
        }
        
        // End position (slightly before the edge so transfer can happen smoothly)
        let outputDirection = getOutputDirection()
        let outputOffset = getDirectionOffset(outputDirection)
        let endPoint = CGPoint(
            x: centerX + outputOffset.x * tileSize * 0.45,
            y: centerY + outputOffset.y * tileSize * 0.45
        )
        
        // Generate path with exact number of steps
        for step in 0...steps {
            let progress = Double(step) / Double(steps)
            let x = startPoint.x + (endPoint.x - startPoint.x) * progress
            let y = startPoint.y + (endPoint.y - startPoint.y) * progress
            path.append(CGPoint(x: x, y: y))
        }
        
        gridPath = path
    }
    
    private func generateOptimalCornerPath(centerX: CGFloat, centerY: CGFloat, steps: Int) {
        var path: [CGPoint] = []
        
        let startPoint: CGPoint
        if let seamlessStart = item.seamlessStartPosition {
            startPoint = seamlessStart
        } else {
            let (inputDir, _) = getCornerDirections()
            let inputOffset = getDirectionOffset(inputDir)
            startPoint = CGPoint(
                x: centerX + inputOffset.x * tileSize * 0.45,
                y: centerY + inputOffset.y * tileSize * 0.45
            )
        }
        
        let (_, outputDir) = getCornerDirections()
        let outputOffset = getDirectionOffset(outputDir)
        let endPoint = CGPoint(
            x: centerX + outputOffset.x * tileSize * 0.45,
            y: centerY + outputOffset.y * tileSize * 0.45
        )
        
        // Create smooth curved path
        let controlPoint = CGPoint(x: centerX, y: centerY)
        
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            
            // Quadratic BÃ©zier curve
            let x = pow(1-t, 2) * startPoint.x + 2*(1-t)*t * controlPoint.x + pow(t, 2) * endPoint.x
            let y = pow(1-t, 2) * startPoint.y + 2*(1-t)*t * controlPoint.y + pow(t, 2) * endPoint.y
            
            path.append(CGPoint(x: x, y: y))
        }
        
        gridPath = path
    }
    
    private func startSynchronizedAnimation() {
        guard !hasStarted && !gridPath.isEmpty else { return }
        hasStarted = true
        currentStep = 0
        
        // IMPROVED: Complete animation at 95% to allow for early transfers
        let animationDuration = item.transferDuration * 0.95 // Reduced from 1.0
        let stepDuration = animationDuration / Double(gridPath.count)
        

        
        animateToNextStep(stepDuration: stepDuration)
    }

    private func animateToNextStep(stepDuration: Double) {
        guard currentStep < gridPath.count else {
            // Animation complete - mark it immediately
            animationComplete = true
            markAnimationComplete()
            
            return
        }
        
        let targetPosition = gridPath[currentStep]
        
        // IMPROVED: Use easeOut animation for smoother end transitions
        let animationType: Animation = currentStep >= gridPath.count - 2 ?
            .easeOut(duration: stepDuration) : .linear(duration: stepDuration)
        
        withAnimation(animationType) {
            currentPosition = targetPosition
        }
        
        currentStep += 1
        
        // Schedule next step
        let deadline = DispatchTime.now() + stepDuration
        DispatchQueue.main.asyncAfter(deadline: deadline) {
            // Check if the item still exists before continuing animation
            guard self.node.conveyorItems.contains(where: { $0.id == self.item.id }) else {
                return
            }
            
            self.animateToNextStep(stepDuration: stepDuration)
        }
    }

    private func markAnimationComplete() {
        // IMPROVED: More robust animation completion marking
        DispatchQueue.main.async {
            // Find this item in the node and mark it as animation complete
            if let itemIndex = self.node.conveyorItems.firstIndex(where: { $0.id == self.item.id }) {
                self.node.conveyorItems[itemIndex].isAnimationComplete = true
            }
        }
    }
    
    // MARK: - Helper Methods
    private func getInputDirection() -> Direction {
        switch node.rotation.rawValue {
        case 0: return .south
        case 1: return .west
        case 2: return .north
        case 3: return .east
        default: return .south
        }
    }
    
    private func getOutputDirection() -> Direction {
        switch node.rotation.rawValue {
        case 0: return .north
        case 1: return .east
        case 2: return .south
        case 3: return .west
        default: return .north
        }
    }
    
    private func getDirectionOffset(_ direction: Direction) -> CGPoint {
        switch direction {
        case .north: return CGPoint(x: 0, y: -1)
        case .south: return CGPoint(x: 0, y: 1)
        case .east: return CGPoint(x: 1, y: 0)
        case .west: return CGPoint(x: -1, y: 0)
        }
    }
    
    private func getCornerDirections() -> (input: Direction, output: Direction) {
        switch cornerRotation {
        case 0:  return (input: .south, output: .east)  // Bottomâ†’Right
        case 1:  return (input: .west,  output: .south) // Leftâ†’Bottom
        case 2:  return (input: .north, output: .west)  // Topâ†’Left
        case 3:  return (input: .east,  output: .north) // Rightâ†’Top
        default: return (input: .south, output: .north)
        }
    }
}

// MARK: - Updated ConveyorItemsView
struct ConveyorItemsView: View {
    @ObservedObject var networkManager: TransmissionNetworkManager
    @ObservedObject var blockLoadingManager: BlockLoadingManager
    let tileSize: CGFloat
    
    var body: some View {
        ZStack {
            ForEach(Array(networkManager.nodes.values), id: \.id) { node in
                if node.blockType == "conveyor-belt" || node.blockType.contains("belt") {
                    ForEach(node.conveyorItems) { item in
                        SynchronizedGridItemView(
                            item: item,
                            node: node,
                            networkManager: networkManager,
                            isCorner: blockLoadingManager.conveyorCornerStates[node.id] ?? false,
                            cornerRotation: blockLoadingManager.conveyorCornerRotations[node.id] ?? 0,
                            tileSize: tileSize
                        )
                        .id("\(node.id)-\(item.id)")
                    }
                }
            }
        }
    }
}

struct NodeStatusView: View {
    @ObservedObject var networkManager: TransmissionNetworkManager
    let mapData: MapData
    let tileSize: CGFloat
    
    var body: some View {
        ForEach(Array(networkManager.nodes.values), id: \.id) { node in
            NodeStatusIndicator(node: node, tileSize: tileSize)
        }
    }
}

struct ItemTransferView: View {
    let transfer: Transfer
    let tileSize: CGFloat
    
    var body: some View {
        ZStack {
            Image(transfer.itemType.iconName)
                .resizable()
                .frame(width: 30, height: 30)
        }
        .position(
            x: CGFloat(transfer.currentPosition.x) * tileSize + tileSize / 2,
            y: CGFloat(transfer.currentPosition.y) * tileSize + tileSize / 2
        )
        .zIndex(100) // Ensure items render above other elements
    }
}

struct NodeStatusIndicator: View {
    @ObservedObject var node: NetworkNode
    let tileSize: CGFloat
    
    var body: some View {
        VStack(spacing: 2) {
            // Power indicator
            if node.powerLevel > 0 {
                Circle()
                    .fill(node.isActive ? Color.green : Color.yellow)
                    .frame(width: 6, height: 6)
                    .opacity(0.8)
            }
        }
        .position(
            x: CGFloat(node.position.x) * tileSize + tileSize - 8,
            y: CGFloat(node.position.y) * tileSize + 8
        )
    }
}

// MARK: - Network Statistics Display

struct NetworkStatsView: View {
    @ObservedObject var networkManager: TransmissionNetworkManager
    
    var body: some View {
        let stats = networkManager.getNetworkStats()
        
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "cpu.fill")
                    .foregroundColor(.blue)
                Text("Networks: \(stats.activeNetworks)")
            }
            
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill")
                    .foregroundColor(.yellow)
                Text("Power: \(Int(stats.totalPowerGeneration))")
            }
            
            HStack(spacing: 4) {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundColor(.orange)
                Text("Transfers: \(stats.activeTransfers)")
            }
        }
        .font(.caption)
        .padding(8)
        .background(Color.black.opacity(0.8))
        .cornerRadius(6)
    }
}

// MARK: - Enhanced Camera Controlled Map View with New Transmission System
struct CameraControlledMapView: View {
    let fileURL: URL
    @ObservedObject var cameraController: CameraController
    let placedBlocks: [PlacedBlock]
    let onMapTap: (CGPoint, MapData) -> Void
    let onDragStart: (CGPoint, MapData) -> Void
    let onDragChanged: (CGPoint) -> Void
    let onDragEnd: (MapData) -> Void
    let linePlacementPoints: [(x: Int, y: Int)]
    let linePlacementCollisions: [Bool]
    let selectedBlock: BlockType?
    let selectedBlockRotation: BlockRotation
    let hoverTileCoordinates: (x: Int, y: Int)?
    let isHoverColliding: Bool
    let blockLibrary: [BlockCategory: [BlockType]]
    @ObservedObject var transmissionManager: TransmissionNetworkManager
    @ObservedObject var blockManager: BlockLoadingManager  // Add this line
    @Binding var mapViewFrame: CGRect
    
    var body: some View {
        GeometryReader { geometry in
            // Create a non-scrollable map view
            if let mapData = try? MapData.fromJSONFile(at: fileURL) {
                ZStack(alignment: .topLeading) {
                    // Map layer
                    StaticMapView(mapData: mapData)
                    
                    // NEW: Unified transmission network visualization
                    TransmissionNetworkView(
                        networkManager: transmissionManager,
                        blockLoadingManager: blockManager,  // Add this line
                        mapData: mapData,
                        tileSize: 32
                    )
                    .zIndex(100)
                    
                    // Blocks layer
                    BlocksOverlayLayer(
                        blocks: placedBlocks,
                        mapData: mapData,
                        tileSize: 32,
                        blockLibrary: blockLibrary,
                        transmissionManager: transmissionManager,
                        blockLoadingManager: blockManager  // Add this line
                    )
                    
                    // Hover preview layer with new rotation support
                    if let selectedBlock = selectedBlock,
                       let hoverCoords = hoverTileCoordinates {
                        HoverPreviewLayer(
                            selectedBlock: selectedBlock,
                            selectedBlockRotation: selectedBlockRotation,
                            hoverCoordinates: hoverCoords,
                            mapData: mapData,
                            tileSize: 32,
                            isColliding: isHoverColliding
                        )
                    }
                    
                    if let selectedBlock = selectedBlock, !linePlacementPoints.isEmpty {
                        // Define tile size constant
                        let tileSize: CGFloat = 32
                        
                        ZStack {
                            ForEach(Array(zip(linePlacementPoints.indices, linePlacementPoints)), id: \.0) { index, point in
                                let isColliding = index < linePlacementCollisions.count ? linePlacementCollisions[index] : false
                                
                                let blockX = CGFloat(point.x) * tileSize
                                let blockY = CGFloat(point.y) * tileSize
                                let rotatedSize = selectedBlock.getRotatedSize(rotation: selectedBlockRotation)
                                
                                // Calculate center position
                                let centerX = blockX + (tileSize * CGFloat(rotatedSize.width)) / 2
                                let centerY = blockY + (tileSize * CGFloat(rotatedSize.height)) / 2
                                
                                // Apply rotated texture offset
                                let textureOffset = selectedBlock.getRotatedTextureOffset(rotation: selectedBlockRotation)
                                let finalX = centerX + textureOffset.x
                                let finalY = centerY + textureOffset.y
                                
                                ZStack {
                                    // Background tile highlight
                                    Rectangle()
                                        .fill(isColliding ? Color.red.opacity(0.4) : Color.yellow.opacity(0.3))
                                        .frame(
                                            width: tileSize * CGFloat(rotatedSize.width),
                                            height: tileSize * CGFloat(rotatedSize.height)
                                        )
                                        .position(x: centerX, y: centerY)
                                    
                                    // Block preview
                                    StandardizedBlockImageView(
                                        iconName: selectedBlock.iconName,
                                        targetSize: selectedBlock.size * 0.8,
                                        color: isColliding ? .red : .white,
                                        opacity: isColliding ? 0.6 : 0.7,
                                        rotation: selectedBlockRotation
                                    )
                                    .position(x: finalX, y: finalY)
                                }
                            }
                        }
                        .frame(
                            width: CGFloat(mapData.width) * tileSize,
                            height: CGFloat(mapData.height) * tileSize,
                            alignment: .topLeading
                        )
                    }
                
                    // --- Turret layers ---
                    TurretProjectilesView(transmissionManager: transmissionManager, tileSize: 32)
                        .zIndex(250)
                    TurretControlOverlay(manager: transmissionManager, cameraController: cameraController, tileSize: 32)
                        .zIndex(300)
}
                .scaleEffect(cameraController.zoomScale)
                .offset(x: cameraController.offset.x, y: cameraController.offset.y)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            if gesture.translation == .zero {
                                // This is essentially the start of the drag
                                onDragStart(gesture.location, mapData)
                            } else {
                                // Update hover preview during drag
                                onDragChanged(gesture.location)
                            }
                        }
                        .onEnded { gesture in
                            // Handle drag end
                            onDragEnd(mapData)
                        }
                )
                .gesture(
                    // Zoom gesture
                    MagnificationGesture()
                        .onChanged { value in
                            cameraController.zoom(by: value / cameraController.zoomScale)
                        }
                )
                .background(
                    // Capture the frame of this view for coordinate conversion
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear {
                                mapViewFrame = proxy.frame(in: .global)
                            }
                            .onChange(of: proxy.frame(in: .global)) {
                                mapViewFrame = proxy.frame(in: .global)
                            }
                    }
                )
            } else {
                Text("Failed to load map")
                    .foregroundColor(.red)
            }
        }
        .clipped()
    }
}

struct SelectionRectangleView: View {
    let rect: CGRect
    let selectedBlocks: Set<UUID>
    let placedBlocks: [PlacedBlock]
    let cameraController: CameraController
    let tileSize: CGFloat
    
    var body: some View {
        ZStack {
            // Selection rectangle outline with animated dashed line
            Rectangle()
                .stroke(Color.red, style: StrokeStyle(
                    lineWidth: 2,
                    dash: [10, 5],
                    dashPhase: 0
                ))
                .background(
                    Rectangle()
                        .fill(Color.red.opacity(0.1))
                )
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .animation(.linear(duration: 0.1), value: rect)
            
            // Highlight selected blocks with pulsing effect
            ForEach(placedBlocks.filter { selectedBlocks.contains($0.id) }) { block in
                if let blockType = getBlockType(for: block.iconName) {
                    let rotatedSize = blockType.getRotatedSize(rotation: block.rotation)
                    let blockX = CGFloat(block.x) * tileSize * cameraController.zoomScale + cameraController.offset.x
                    let blockY = CGFloat(block.y) * tileSize * cameraController.zoomScale + cameraController.offset.y
                    let width = CGFloat(rotatedSize.width) * tileSize * cameraController.zoomScale
                    let height = CGFloat(rotatedSize.height) * tileSize * cameraController.zoomScale
                    
                    ZStack {
                        // Red overlay
                        Rectangle()
                            .fill(Color.red.opacity(0.5))
                            .frame(width: width, height: height)
                        
                        // X mark overlay
                        Image(systemName: "xmark")
                            .font(.system(size: min(width, height) * 0.4, weight: .bold))
                            .foregroundColor(.white)
                            .opacity(0.8)
                    }
                    .position(x: blockX + width/2, y: blockY + height/2)
                }
            }
            
            // Show count of selected blocks
            if !selectedBlocks.isEmpty {
                VStack {
                    HStack {
                        Spacer()
                        Text("\(selectedBlocks.count) blocks selected")
                            .font(.caption)
                            .fontWeight(.bold)
                            .padding(8)
                            .background(Color.red)
                            .foregroundColor(.white)
                            .cornerRadius(6)
                            .padding()
                    }
                    Spacer()
                }
            }
        }
    }
    
    private func getBlockType(for iconName: String) -> BlockType? {
        for (_, blocks) in GameView.enhancedBlockLibrary {
            if let block = blocks.first(where: { $0.iconName == iconName }) {
                return block
            }
        }
        return nil
    }
}

struct LinePreviewLayer: View {
    let selectedBlock: BlockType
    let selectedBlockRotation: BlockRotation
    let linePoints: [(x: Int, y: Int)]
    let collisions: [Bool]
    let mapData: MapData
    let tileSize: CGFloat
    
    var body: some View {
        ZStack {
            ForEach(Array(zip(linePoints.indices, linePoints)), id: \.0) { index, point in
                let isColliding = index < collisions.count ? collisions[index] : false
                
                // Reuse the hover preview for each point
                SingleBlockPreview(
                    selectedBlock: selectedBlock,
                    selectedBlockRotation: selectedBlockRotation,
                    position: point,
                    tileSize: tileSize,
                    isColliding: isColliding
                )
            }
        }
        .frame(
            width: CGFloat(mapData.width) * tileSize,
            height: CGFloat(mapData.height) * tileSize,
            alignment: .topLeading
        )
    }
}

struct SingleBlockPreview: View {
    let selectedBlock: BlockType
    let selectedBlockRotation: BlockRotation
    let position: (x: Int, y: Int)
    let tileSize: CGFloat
    let isColliding: Bool
    
    var body: some View {
        let blockX = CGFloat(position.x) * tileSize
        let blockY = CGFloat(position.y) * tileSize
        let rotatedSize = selectedBlock.getRotatedSize(rotation: selectedBlockRotation)
        
        // Calculate center position
        let centerX = blockX + (tileSize * CGFloat(rotatedSize.width)) / 2
        let centerY = blockY + (tileSize * CGFloat(rotatedSize.height)) / 2
        
        // Apply rotated texture offset for preview
        let textureOffset = selectedBlock.getRotatedTextureOffset(rotation: selectedBlockRotation)
        let finalX = centerX + textureOffset.x
        let finalY = centerY + textureOffset.y
        
        ZStack {
            // Background tile highlight
            Rectangle()
                .fill(isColliding ? Color.red.opacity(0.4) : Color.yellow.opacity(0.3))
                .frame(
                    width: tileSize * CGFloat(rotatedSize.width),
                    height: tileSize * CGFloat(rotatedSize.height)
                )
                .position(x: centerX, y: centerY)
            
            // Block preview
            StandardizedBlockImageView(
                iconName: selectedBlock.iconName,
                targetSize: selectedBlock.size * 0.8,
                color: isColliding ? .red : .white,
                opacity: isColliding ? 0.6 : 0.7,
                rotation: selectedBlockRotation
            )
            .position(x: finalX, y: finalY)
        }
    }
}

// MARK: - Enhanced Blocks Overlay Layer with New Transmission System
struct BlocksOverlayLayer: View {
    let blocks: [PlacedBlock]
    let mapData: MapData
    let tileSize: CGFloat
    let blockLibrary: [BlockCategory: [BlockType]]
    @ObservedObject var transmissionManager: TransmissionNetworkManager
    @ObservedObject var blockLoadingManager: BlockLoadingManager
    
    var body: some View {
        ZStack {
            ForEach(Array(blocks), id: \.id) { block in
                SingleBlockViewWithConstruction( // Changed from SingleBlockView
                    block: block,
                    mapData: mapData,
                    tileSize: tileSize,
                    blockLibrary: blockLibrary,
                    transmissionManager: transmissionManager,
                    blockLoadingManager: blockLoadingManager
                )
            }
        }
        .frame(
            width: CGFloat(mapData.width) * tileSize,
            height: CGFloat(mapData.height) * tileSize,
            alignment: .topLeading
        )
    }
}

// MARK: - Updated Single Block View with New Transmission System
struct SingleBlockView: View {
    let block: PlacedBlock
    let mapData: MapData
    let tileSize: CGFloat
    let blockLibrary: [BlockCategory: [BlockType]]
    @ObservedObject var transmissionManager: TransmissionNetworkManager
    @ObservedObject var blockLoadingManager: BlockLoadingManager
    
    // Compute the icon name and rotation
    private var displayIconName: String {
        if block.blockType == "conveyor-belt",
           let isCorner = blockLoadingManager.conveyorCornerStates[block.id],
           isCorner,
           let textureType = blockLoadingManager.conveyorCornerTextures[block.id] {
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
            // Use the corner-specific rotation
            return BlockRotation(cornerRotation)
        } else {
            // Use the block's normal rotation
            return block.rotation
        }
    }
    
    var body: some View {
        let blockX = CGFloat(block.x) * tileSize
        let blockY = CGFloat(block.y) * tileSize
        let blockType = getBlockType(for: block.blockType)
        let rotatedSize = blockType?.getRotatedSize(rotation: block.rotation) ?? (width: 1, height: 1)
        
        let targetDisplaySize = blockType?.size ?? block.size
        let scaledSize = targetDisplaySize * 0.8
        
        let centerX = blockX + (tileSize * CGFloat(rotatedSize.width)) / 2
        let centerY = blockY + (tileSize * CGFloat(rotatedSize.height)) / 2
        
        let textureOffset = blockType?.getRotatedTextureOffset(rotation: block.rotation) ?? .zero
        let finalX = centerX + textureOffset.x
        let finalY = centerY + textureOffset.y
        
        ZStack {
            // Main block image with corner-aware rotation
            StandardizedBlockImageView(
                iconName: displayIconName,
                targetSize: scaledSize,
                rotation: effectiveRotation  // Use the computed rotation
            )
            .position(x: finalX, y: finalY)
            
            // Rest of the view remains the same...
            VStack {
                HStack {
                    Spacer()
                    
                    VStack(spacing: 2) {
                        // Power status
                        if transmissionManager.getNodePowerLevel(id: block.id) > 0 {
                            Image(systemName: transmissionManager.isNodeActive(id: block.id) ? "bolt.fill" : "bolt.slash.fill")
                                .font(.system(size: 8))
                                .foregroundColor(transmissionManager.isNodeActive(id: block.id) ? .green : .red)
                                .background(Color.black.opacity(0.6))
                                .clipShape(Circle())
                        }
                        
                        // Item count and display for conveyors
//                        if block.iconName == "conveyor-belt" {
//                            // Get all items in the conveyor's buffer
//                            let itemsInBuffer = ItemType.allCases.compactMap { itemType -> (type: ItemType, count: Int)? in
//                                let count = transmissionManager.getNodeItemCount(id: block.id, itemType: itemType)
//                                return count > 0 ? (type: itemType, count: count) : nil
//                            }
//
//                            // For this simple approach, just show what's in the buffer
//                            // The flying animation handles the visual transition
//                            if let firstItem = itemsInBuffer.first {
//                                Image(firstItem.type.iconName)
//                                    .resizable()
//                                    .frame(width: 30, height: 30)
//                            }
//                        }
                    }
                }
                Spacer()
            }
            .frame(width: tileSize * CGFloat(rotatedSize.width), height: tileSize * CGFloat(rotatedSize.height))
            .position(x: centerX, y: centerY)
        }
    }
    
    private func getBlockType(for blockTypeName: String) -> BlockType? {
        for (_, blocks) in blockLibrary {
            for block in blocks {
                if block.iconName == blockTypeName {
                    return block
                }
            }
        }
        return nil
    }
}

// MARK: - Enhanced Hover Preview Layer with New Rotation Support
struct HoverPreviewLayer: View {
    let selectedBlock: BlockType
    let selectedBlockRotation: BlockRotation
    let hoverCoordinates: (x: Int, y: Int)
    let mapData: MapData
    let tileSize: CGFloat
    let isColliding: Bool
    
    var body: some View {
        let blockX = CGFloat(hoverCoordinates.x) * tileSize
        let blockY = CGFloat(hoverCoordinates.y) * tileSize
        let rotatedSize = selectedBlock.getRotatedSize(rotation: selectedBlockRotation)
        
        // Calculate center position
        let centerX = blockX + (tileSize * CGFloat(rotatedSize.width)) / 2
        let centerY = blockY + (tileSize * CGFloat(rotatedSize.height)) / 2
        
        // NEW: Apply rotated texture offset for preview
        let textureOffset = selectedBlock.getRotatedTextureOffset(rotation: selectedBlockRotation)
        let finalX = centerX + textureOffset.x
        let finalY = centerY + textureOffset.y
        
        ZStack {
            // Background tile highlight - covers the full rotated block size (no offset applied here)
            Rectangle()
                .fill(isColliding ? Color.red.opacity(0.4) : Color.yellow.opacity(0.3))
                .frame(
                    width: tileSize * CGFloat(rotatedSize.width),
                    height: tileSize * CGFloat(rotatedSize.height)
                )
                .position(x: centerX, y: centerY) // Grid highlight stays at grid position
            
            // NEW: Connection preview
            if !selectedBlock.connections.isEmpty {
                ForEach(Array(selectedBlock.connections.enumerated()), id: \.offset) { index, connection in
                    ConnectionPreview(
                        connection: connection,
                        blockPosition: hoverCoordinates,
                        blockRotation: selectedBlockRotation,
                        tileSize: tileSize,
                        isColliding: isColliding
                    )
                }
            }
            
            // Block preview with standardized sizing, rotation, and texture offset
            StandardizedBlockImageView(
                iconName: selectedBlock.iconName,
                targetSize: selectedBlock.size * 0.8,
                color: isColliding ? .red : .white,
                opacity: isColliding ? 0.6 : 0.7,
                rotation: selectedBlockRotation
            )
            .position(x: finalX, y: finalY) // NEW: Apply texture offset to preview
        }
        .frame(
            width: CGFloat(mapData.width) * tileSize,
            height: CGFloat(mapData.height) * tileSize,
            alignment: .topLeading
        )
        // No animation - instant snap to position
    }
}

// MARK: - NEW: Connection Preview
struct ConnectionPreview: View {
    let connection: UniversalConnection
    let blockPosition: (x: Int, y: Int)
    let blockRotation: BlockRotation
    let tileSize: CGFloat
    let isColliding: Bool
    
    // MARK: - Computed Properties to reduce body complexity
    private var rotatedDirection: Direction {
        connection.direction.rotated(by: blockRotation)
    }
    
    private var connectionPoint: CGPoint {
        let offset = rotatedDirection.offset
        return CGPoint(
            x: CGFloat(blockPosition.x) * tileSize + tileSize / 2 + CGFloat(offset.x) * tileSize / 2,
            y: CGFloat(blockPosition.y) * tileSize + tileSize / 2 + CGFloat(offset.y) * tileSize / 2
        )
    }
    
    private var connectionPointR: CGPoint {
        let offset = rotatedDirection.offset
        // Increase the distance multiplier from 0.5 to 0.8 (or any value you prefer)
        // 0.5 = edge of tile, 0.8 = 80% out from center, 1.0 = full tile away
        let distanceMultiplier: CGFloat = 0.8
        
        return CGPoint(
            x: CGFloat(blockPosition.x) * tileSize + tileSize / 2 + CGFloat(offset.x) * tileSize * distanceMultiplier,
            y: CGFloat(blockPosition.y) * tileSize + tileSize / 2 + CGFloat(offset.y) * tileSize * distanceMultiplier
        )
    }
    
    // Check if this connection handles rotational power
    private var isRotationalPower: Bool {
        connection.connectionTypes.contains { type in
            switch type {
            case .powerInput(.rotational), .powerOutput(.rotational):
                return true
            default:
                return false
            }
        }
    }
    
    private var connectionColor: Color {
        // Color based on connection types
        let hasInput = connection.connectionTypes.contains { type in
            switch type {
            case .powerInput(_), .itemInput(_), .fluidInput(_): return true
            default: return false
            }
        }
        let hasOutput = connection.connectionTypes.contains { type in
            switch type {
            case .powerOutput(_), .itemOutput(_), .fluidOutput(_): return true
            default: return false
            }
        }
        
        if hasInput && hasOutput {
            return .yellow // Bidirectional
        } else if hasOutput {
            return .green // Output
        } else {
            return .blue // Input
        }
    }
    
    private var connectionOpacity: Double {
        isColliding ? 0.4 : 0.8
    }
    
    private var arrowRotation: Double {
        Double(blockRotation.rawValue) * 90 + directionToDegrees(rotatedDirection)
    }
    
    var body: some View {
        ZStack {
            if isRotationalPower {
                // Special visualization for rotational power
                Image(systemName: "arrow.down.left.arrow.up.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .position(connectionPointR)
            } else {
                // Original visualization for other connection types
                Circle()
                    .fill(connectionColor)
                    .frame(width: 8, height: 8)
                    .opacity(connectionOpacity)
                    .position(connectionPoint)
            }
        }
    }
    
    private func directionToDegrees(_ direction: Direction) -> Double {
        switch direction {
        case .north: return 0
        case .east: return 90
        case .south: return 180
        case .west: return 270
        }
    }
}

struct CoreInventoryDisplay: View {
    @ObservedObject var coreInventory = CoreInventoryManager.shared
    
    // Computed property to get items that actually have inventory
    private var inventoryItems: [(item: ItemType, count: Int)] {
        return coreInventory.coreInventory.compactMap { (item, count) in
            count > 0 ? (item: item, count: count) : nil
        }.sorted { $0.item.displayName < $1.item.displayName }
    }
    
    var body: some View {
        let columns = [
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible())
        ]
        
        if !inventoryItems.isEmpty {
            LazyVGrid(columns: columns) {
                ForEach(inventoryItems, id: \.item) { inventoryItem in
                    HStack {
                        Image(inventoryItem.item.iconName)
                            .resizable()
                            .frame(width: 20, height: 20)
                        
                        let count = inventoryItem.count
                        Text(count < 1000
                             ? String(count)
                             : String(format: "%.1fK", Double(count) / 1000.0))
                            .font(.caption2)
                            .foregroundColor(.white)
                    }
                }
            }
            .frame(width: 250, height: 30)
            .padding(8)
            .background(
                Rectangle()
                    .foregroundColor(.black)
                    .opacity(0.7)
                    .frame(width: 250, height: 30)
            )
        }
    }
}

// MARK: - Static Map View (No Scrolling)
struct StaticMapView: View {
    let mapData: MapData
    let tileSize: CGFloat = 32
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            // Base terrain grid (no ScrollView)
            VStack(spacing: 0) {
                ForEach(0..<mapData.height, id: \.self) { y in
                    HStack(spacing: 0) {
                        ForEach(0..<mapData.width, id: \.self) { x in
                            let tileType = mapData.tiles[y][x]
                            let oreType = mapData.ores[y][x]
                            
                            staticTileView(tileType: tileType, oreType: oreType)
                        }
                    }
                }
            }
            
            // Vent/Geyser overlay
            ForEach(0 ..< mapData.width, id: \.self) { x in
                ForEach(0 ..< mapData.height, id: \.self) { y in
                    let tile = mapData.tiles[y][x]
                    if tile == .vent || tile == .geyser {
                        let shouldDraw: Bool = {
                            var neighborCount = 0
                            var all3x3Same = true
                            for oy in -1...1 {
                                for ox in -1...1 {
                                    if ox == 0 && oy == 0 { continue }
                                    let nx = x + ox
                                    let ny = y + oy
                                    if nx >= 0 && ny >= 0 && nx < mapData.width && ny < mapData.height {
                                        if mapData.tiles[ny][nx] == tile {
                                            neighborCount += 1
                                        } else {
                                            all3x3Same = false
                                        }
                                    } else {
                                        all3x3Same = false
                                    }
                                }
                            }
                            let isIsolated = (neighborCount == 0)
                            return isIsolated || all3x3Same
                        }()
                        if shouldDraw {
                            Group {
                                if !tile.imageName.isEmpty {
                                    Image(tile.imageName)
                                        .resizable()
                                        .frame(width: tileSize * 3, height: tileSize * 3)
                                } else {
                                    Circle()
                                        .fill(tile.fallbackColor)
                                        .frame(width: tileSize * 3, height: tileSize * 3)
                                }
                            }
                            .position(
                                x: CGFloat(x) * tileSize + tileSize / 2,
                                y: CGFloat(y) * tileSize + tileSize / 2
                            )
                        }
                    }
                }
            }
        }
        .background(Color.clear)
    }
    
    @ViewBuilder
    private func staticTileView(tileType: TileType, oreType: OreType) -> some View {
        ZStack {
            // Base tile layer
            Group {
                if tileType == .vent || tileType == .geyser {
                    Rectangle()
                        .fill(tileType.fallbackColor.opacity(0.3))
                        .frame(width: tileSize, height: tileSize)
                } else if !tileType.imageName.isEmpty, let uiImage = UIImage(named: tileType.imageName) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: tileSize, height: tileSize)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(tileType.fallbackColor)
                        .frame(width: tileSize, height: tileSize)
                }
            }
            
            // Ore overlay layer
            if oreType != .none {
                Group {
                    if !oreType.imageName.isEmpty {
                        if let oreImage = UIImage(named: oreType.imageName) {
                            Image(uiImage: oreImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: tileSize, height: tileSize)
                                .opacity(0.8)
                                .clipped()
                        } else {
                            Rectangle()
                                .fill(oreType.fallbackColor)
                                .frame(width: tileSize, height: tileSize)
                        }
                    } else {
                        Rectangle()
                            .fill(oreType.fallbackColor)
                            .frame(width: tileSize, height: tileSize)
                    }
                }
            }
        }
    }
}

struct MiningEffectsView: View {
    @ObservedObject var miningManager: OreMiningManager
    let tileSize: CGFloat
    
    var body: some View {
        ZStack {
            // Mining operation indicators
            ForEach(Array(miningManager.activeMiningOperations.values), id: \.id) { operation in
                MiningIndicatorView(operation: operation, tileSize: tileSize)
            }
            
            // Mining visual effects (items flying to core)
            ForEach(miningManager.miningVisualEffects, id: \.id) { effect in
                MiningItemEffect(effect: effect, tileSize: tileSize)
            }
        }
    }
}

struct MiningIndicatorView: View {
    let operation: OreMiningManager.MiningOperation
    let tileSize: CGFloat
    
    @State private var pulseScale: CGFloat = 1.0
    
    var body: some View {
        ZStack {
            // Pulsing circle to indicate active mining
            Circle()
                .stroke(Color.yellow, lineWidth: 3)
                .frame(width: tileSize * 0.8, height: tileSize * 0.8)
                .scaleEffect(pulseScale)
                .opacity(0.8)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                        pulseScale = 1.2
                    }
                }
            
            // Mining pickaxe icon
            Image(systemName: "hammer.fill")
                .font(.system(size: 16))
                .foregroundColor(.yellow)
                .rotationEffect(.degrees(-45))
        }
        .position(
            x: CGFloat(operation.orePosition.x) * tileSize + tileSize / 2,
            y: CGFloat(operation.orePosition.y) * tileSize + tileSize / 2
        )
    }
}

struct MiningItemEffect: View {
    let effect: OreMiningManager.MiningEffect
    let tileSize: CGFloat
    
    @State private var animationProgress: Double = 0.0
    @State private var opacity: Double = 1.0
    
    var body: some View {
        Image(effect.itemType.iconName)
            .resizable()
            .frame(width: 20, height: 20)
            .opacity(opacity)
            .position(currentPosition)
            .onAppear {
                withAnimation(.easeOut(duration: effect.duration)) {
                    animationProgress = 1.0
                    opacity = 0.0
                }
            }
    }
    
    private var currentPosition: CGPoint {
        // Animate from ore position to top of screen (where core inventory is)
        let startPos = effect.position
        let endPos = CGPoint(x: startPos.x, y: -50) // Move upward off screen
        
        return CGPoint(
            x: startPos.x + (endPos.x - startPos.x) * animationProgress,
            y: startPos.y + (endPos.y - startPos.y) * animationProgress
        )
    }
}

#Preview {
    let mapFileURL = Bundle.main.mapFileURL(named: "Terrain_SG")!
    GameView(fileURL: mapFileURL, onReturnToSectorMap: nil)
        .environmentObject(GlobalHoverObserver())
        .ignoresSafeArea()
}



// MARK: - Turret Projectiles Overlay
struct TurretProjectilesView: View {
    @ObservedObject var transmissionManager: TransmissionNetworkManager
    let tileSize: CGFloat

    var body: some View {
        ZStack {
            ForEach(transmissionManager.projectiles) { p in
                Circle()
                    .frame(width: tileSize * 0.18, height: tileSize * 0.18)
                    .opacity(0.9)
                    .position(x: p.position.x * tileSize, y: p.position.y * tileSize)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Turret Control Overlay
struct TurretControlOverlay: View {
    @ObservedObject var manager: TransmissionNetworkManager
    @ObservedObject var cameraController: CameraController
    let tileSize: CGFloat

    private func worldPoint(from local: CGPoint) -> CGPoint {
        let s = cameraController.zoomScale
        let ox = cameraController.offset.x
        let oy = cameraController.offset.y
        // convert from screen-space within map container to world-tile coords
        return CGPoint(
            x: (local.x - ox) / (s * tileSize),
            y: (local.y - oy) / (s * tileSize)
        )
    }

    var body: some View {
        // Only intercept input while a turret is actively controlled
        let active = (manager.controlledTurretID != nil)
        return Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .allowsHitTesting(active)
            #if os(macOS)
            .onContinuousHover { phase in
                guard let id = manager.controlledTurretID else { return }
                if case .active(let loc) = phase {
                    let world = worldPoint(from: loc)
                    manager.aimTurret(id: id, atWorldPoint: world)
                }
            }
            #endif
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard let id = manager.controlledTurretID else { return }
                        let world = worldPoint(from: value.location)
                        manager.aimTurret(id: id, atWorldPoint: world)
                        if !manager.isTriggerHeld(id) {
                            manager.setTriggerHeld(true, for: id)
                            manager.fireOnce(id: id)
                        }
                    }
                    .onEnded { _ in
                        if let id = manager.controlledTurretID {
                            manager.setTriggerHeld(false, for: id)
                        }
                    }
            )
    }
}
