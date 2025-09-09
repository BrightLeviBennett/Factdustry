//
//  SKBridge.swift
//  Factdustry
//
//  Corrected by ChatGPT
//

import SwiftUI
import SpriteKit
import Combine

// MARK: - Texture helpers
private enum SKArt {
    static func tex(_ name: String) -> SKTexture? {
        let t = SKTexture(imageNamed: name)
        return t.size().width > 0 ? t : nil
    }
    static func any(_ names: [String]) -> SKTexture? {
        for n in names { if let t = tex(n) { return t } }
        return nil
    }
}

// MARK: - Units and Effects Scene (Overlay only)
final class SKUnitsScene: SKScene {
    private var blockLibrary: [BlockCategory: [BlockType]] = [:]
    private var tileSize: CGFloat = 32
    private var mapData: MapData?

    private let unitLayer = SKNode()
    private let projectileLayer = SKNode()
    private let effectsLayer = SKNode()
    private let worldNode = SKNode()
    private let cameraNode = SKCameraNode()

    struct Unit {
        enum Kind { case shardling, ant }
        let id = UUID()
        var kind: Kind
        var faction: Faction // NEW: Add faction to units
        var position: CGPoint
        var displayOffset: CGVector = CGVector.zero
        var speed: CGFloat
        var sprite: SKSpriteNode?
        var targetPosition: CGPoint?
        var isMoving: Bool = false
        var health: Int = 100
        var maxHealth: Int = 100
    }
    private var units: [UUID: Unit] = [:]
    private var hasSpawnedShardling = false
    private var projectileNodes: [UUID: SKNode] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var currentCameraVelocity: CGVector = CGVector.zero // NEW: Track camera velocity
    private var unitProductionSubscription: AnyCancellable? // NEW: Unit production subscription
    
    // References to external managers
    private weak var cameraController: CameraController?
    private weak var transmissionManager: TransmissionNetworkManager?
    private weak var blockManager: BlockLoadingManager?
    
    private var isInReturnMode: Bool = false
    private var lastSignificantMovementTime: TimeInterval = 0
    private var returnDelay: TimeInterval = 0.3 // Shorter delay for faster catch-up
    private var lastCameraPosition: CGPoint = CGPoint.zero
    private var targetShardlingLag: CGVector = CGVector.zero
    private var lastVelocityDirection: CGVector = CGVector.zero
    private var wasHighVelocityLastFrame: Bool = false

    override func didMove(to view: SKView) {
        backgroundColor = .clear // Transparent background for overlay
        
        addChild(worldNode)
        worldNode.addChild(unitLayer)
        worldNode.addChild(effectsLayer)
        worldNode.addChild(projectileLayer)
        // Camera setup
        self.camera = cameraNode
        addChild(cameraNode)

        unitLayer.zPosition = 100
        effectsLayer.zPosition = 150
        projectileLayer.zPosition = 200
        
        // Start unit AI update loop
        startUnitUpdates()
        
        wasHighVelocityLastFrame = false
    }

    func configure(mapData: MapData,
                   blockLibrary: [BlockCategory: [BlockType]],
                   tileSize: CGFloat,
                   cameraController: CameraController,
                   transmissionManager: TransmissionNetworkManager?,
                   blockManager: BlockLoadingManager?) {
        self.mapData = mapData
        self.blockLibrary = blockLibrary
        self.tileSize = tileSize
        self.cameraController = cameraController
        self.transmissionManager = transmissionManager
        self.blockManager = blockManager

        hookCamera(cameraController)
        hookProjectiles(transmissionManager)
        hookBlocks(blockManager)
        hookUnitProduction(transmissionManager) // NEW: Hook unit production
        
        // Force an initial check for existing blocks
        if let mgr = blockManager {
            syncBlocks(mgr.placedBlocks)
        }
    }

    func syncBlocks(_ placed: [PlacedBlock]) {
        // Spawn shardling on core
        ensureShardling(onTopOf: placed)
    }

    
    
    // Convert CameraController's offset/zoom to SKCameraNode transform.
    // - offset is a screen-space translation applied before scaling in SwiftUI.
    // - zoomScale magnifies content (1.0 = 1:1). In SpriteKit, camera.xScale < 1 zooms in.
    private func updateCameraFromController(offset: CGPoint, zoomScale: CGFloat) {
        let viewSize = self.view?.bounds.size ?? CGSize(width: 800, height: 600)
        let center = CGPoint(x: viewSize.width / 2.0, y: viewSize.height / 2.0)
        // worldCenter = (screenCenter - offset) / zoom
        let worldCenterX = (center.x - offset.x) / max(zoomScale, 0.0001)
        let worldCenterY = (center.y - offset.y) / max(zoomScale, 0.0001)
        cameraNode.position = CGPoint(x: worldCenterX, y: worldCenterY)
        // In SpriteKit, smaller camera scale zooms IN; mirror SwiftUI zoom by inverting.
        let inv = 1.0 / max(zoomScale, 0.0001)
        cameraNode.xScale = inv
        cameraNode.yScale = inv
    }
    
    private func hookCamera(_ cc: CameraController) {
        self.cameraController = cc
        
        // Position and scale the scene to match the SwiftUI map
        cc.$offset
            .receive(on: DispatchQueue.main)
            .sink { [weak self] offset in
                guard let self = self else { return }
                self.updateCameraFromController(offset: offset, zoomScale: cc.zoomScale)
            }
            .store(in: &cancellables)
            
        cc.$zoomScale
            .receive(on: DispatchQueue.main)
            .sink { [weak self] scale in
                guard let self = self else { return }
                self.updateCameraFromController(offset: cc.offset, zoomScale: scale)
            }
            .store(in: &cancellables)
            
        // NEW: Track camera velocity for drift effect
        cc.$velocity
            .receive(on: DispatchQueue.main)
            .sink { [weak self] velocity in
                self?.currentCameraVelocity = velocity
                self?.updateShardlingDrift()
            }
            .store(in: &cancellables)
    }

    // NEW: Update shardling drift based on camera movement
    private func updateShardlingDrift() {
        guard let cameraController = cameraController else { return }
        
        let currentTime = CACurrentMediaTime()
        let currentCameraPosition = CGPoint(x: -cameraController.offset.x, y: -cameraController.offset.y)
        
        // Calculate camera movement since last frame
        let cameraMovement = CGPoint(
            x: currentCameraPosition.x - lastCameraPosition.x,
            y: currentCameraPosition.y - lastCameraPosition.y
        )
        let movementMagnitude = sqrt(cameraMovement.x * cameraMovement.x + cameraMovement.y * cameraMovement.y)
        
        // Check camera velocity magnitude
        let velocityMagnitude = sqrt(currentCameraVelocity.dx * currentCameraVelocity.dx + currentCameraVelocity.dy * currentCameraVelocity.dy)
        
        // Calculate current velocity direction (normalized)
        let currentVelocityDirection: CGVector
        if velocityMagnitude > 10.0 {
            currentVelocityDirection = CGVector(
                dx: currentCameraVelocity.dx / velocityMagnitude,
                dy: currentCameraVelocity.dy / velocityMagnitude
            )
        } else {
            currentVelocityDirection = CGVector.zero
        }
        
        // Detect direction changes (dot product approach)
        let dotProduct = lastVelocityDirection.dx * currentVelocityDirection.dx +
                        lastVelocityDirection.dy * currentVelocityDirection.dy
        let isDirectionChange = velocityMagnitude > 100.0 &&
                               sqrt(lastVelocityDirection.dx * lastVelocityDirection.dx + lastVelocityDirection.dy * lastVelocityDirection.dy) > 0.5 &&
                               dotProduct < 0.7 // Angle > ~45 degrees
        
        if isDirectionChange {
            print("🔄 DIRECTION CHANGE DETECTED!")
            print("   - Last direction: (\(String(format: "%.2f", lastVelocityDirection.dx)), \(String(format: "%.2f", lastVelocityDirection.dy)))")
            print("   - Current direction: (\(String(format: "%.2f", currentVelocityDirection.dx)), \(String(format: "%.2f", currentVelocityDirection.dy)))")
            print("   - Dot product: \(String(format: "%.2f", dotProduct))")
        }
        
        // Hysteresis thresholds
        let highVelocityThreshold: CGFloat = 100.0  // Must be above this to START lagging
        let lowVelocityThreshold: CGFloat = 20.0    // Must be below this to START catching up
        
        // Track state changes for debug
        let wasInReturnMode = isInReturnMode
        
        // State machine with hysteresis
        if !isInReturnMode && velocityMagnitude > highVelocityThreshold {
            // Start lag mode (high velocity detected)
            lastSignificantMovementTime = currentTime
            isInReturnMode = false
            if wasInReturnMode {
                print("🏃 STATE CHANGE: Catch-up -> Lag mode (velocity: \(String(format: "%.1f", velocityMagnitude)))")
            }
        } else if !isInReturnMode && velocityMagnitude <= lowVelocityThreshold {
            // Camera is slow enough, check if enough time has passed
            let timeSinceMovement = currentTime - lastSignificantMovementTime
            print("⏰ Checking catch-up: velocity=\(String(format: "%.1f", velocityMagnitude)), timeSince=\(String(format: "%.2f", timeSinceMovement)), delay=\(returnDelay)")
            if timeSinceMovement > returnDelay {
                isInReturnMode = true
                print("🎯 STATE CHANGE: Lag -> Catch-up mode (velocity: \(String(format: "%.1f", velocityMagnitude)))")
            }
        } else if isInReturnMode && velocityMagnitude > highVelocityThreshold {
            // High velocity detected while catching up - go back to lag
            lastSignificantMovementTime = currentTime
            isInReturnMode = false
            print("🏃 STATE CHANGE: Catch-up -> Lag mode (interrupted by velocity: \(String(format: "%.1f", velocityMagnitude)))")
        }
        
        // Debug current state
        if Int(currentTime * 2) % 10 == 0 { // Every 5 seconds
            print("📊 STATE: \(isInReturnMode ? "CATCH-UP" : "LAG"), velocity=\(String(format: "%.1f", velocityMagnitude))")
        }
        
        // Update movement time for mid-range velocities
        if velocityMagnitude > lowVelocityThreshold {
            lastSignificantMovementTime = currentTime
        }
        
        for (id, var unit) in units {
            if unit.kind == .shardling {
                if isInReturnMode {
                    // CATCH-UP MODE: Instantly snap to center (like Mindustry)
                    let offsetMagnitude = sqrt(unit.displayOffset.dx * unit.displayOffset.dx + unit.displayOffset.dy * unit.displayOffset.dy)
                    
                    if offsetMagnitude > 0.1 {
                        print("🎯 CATCH-UP MODE:")
                        print("   - Current lag: (\(String(format: "%.2f", unit.displayOffset.dx)), \(String(format: "%.2f", unit.displayOffset.dy)))")
                        print("   - Lag magnitude: \(String(format: "%.2f", offsetMagnitude))")
                        
                        // INSTANT snap to center (like Mindustry)
                        unit.displayOffset = CGVector.zero
                        print("   - ✅ INSTANTLY SNAPPED TO CENTER!")
                    } else {
                        print("🎯 CATCH-UP MODE: Already at center")
                    }
                    
                } else {
                    // LAG MODE: Shardling lags behind camera movement
                    if movementMagnitude > 1.0 { // Only log when there's significant movement
                        print("🏃 LAG MODE:")
                        print("   - Camera movement: (\(String(format: "%.1f", cameraMovement.x)), \(String(format: "%.1f", cameraMovement.y)))")
                        print("   - Current lag: (\(String(format: "%.2f", unit.displayOffset.dx)), \(String(format: "%.2f", unit.displayOffset.dy)))")
                    }
                    
                    // Create lag by moving shardling slower than camera
                    let lagMultiplier: CGFloat = 0.7 // Shardling moves 70% as fast as camera
                    let maxLag: CGFloat = tileSize * 2.0 // Maximum lag distance
                    
                    // Add camera movement to current lag (but reduced)
                    let newLagDelta = CGVector(
                        dx: -cameraMovement.x * (1.0 - lagMultiplier) / cameraController.zoomScale,
                        dy: -cameraMovement.y * (1.0 - lagMultiplier) / cameraController.zoomScale
                    )
                    
                    unit.displayOffset.dx += newLagDelta.dx
                    unit.displayOffset.dy += newLagDelta.dy
                    
                    // Clamp lag to maximum distance
                    let lagMagnitude = sqrt(unit.displayOffset.dx * unit.displayOffset.dx + unit.displayOffset.dy * unit.displayOffset.dy)
                    if lagMagnitude > maxLag {
                        let scale = maxLag / lagMagnitude
                        unit.displayOffset.dx *= scale
                        unit.displayOffset.dy *= scale
                    }
                }
                
                // Update sprite position
                if let sprite = unit.sprite {
                    let baseWorldPos = CGPoint(x: unit.position.x * tileSize, y: unit.position.y * tileSize)
                    let laggedPos = CGPoint(
                        x: baseWorldPos.x + unit.displayOffset.dx,
                        y: baseWorldPos.y + unit.displayOffset.dy
                    )
                    sprite.position = laggedPos
                }
                
                units[id] = unit
            }
        }
        
        // Update last camera position for next frame
        lastCameraPosition = currentCameraPosition
        
        // Update last velocity direction
        lastVelocityDirection = currentVelocityDirection
    }

    private func hookProjectiles(_ mgr: TransmissionNetworkManager?) {
        mgr?.$projectiles
            .receive(on: DispatchQueue.main)
            .sink { [weak self] projectiles in self?.syncProjectiles(projectiles) }
            .store(in: &cancellables)
    }
    
    // NEW: Hook unit production
    private func hookUnitProduction(_ mgr: TransmissionNetworkManager?) {
        mgr?.$completedUnits
            .receive(on: DispatchQueue.main)
            .sink { [weak self] completedUnits in
                for unit in completedUnits {
                    self?.spawnUnit(
                        type: unit.unitType,
                        at: unit.spawnPosition,
                        facing: unit.direction,
                        faction: unit.faction
                    )
                }
                // Clear completed units after spawning
                mgr?.completedUnits.removeAll()
            }
            .store(in: &cancellables)
    }
    
    private func hookBlocks(_ mgr: BlockLoadingManager?) {
        guard let mgr = mgr else {
            print("❌ No block manager provided to hookBlocks")
            return
        }
        
        print("🔗 Hooking up block manager...")
        mgr.$placedBlocks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] blocks in
                print("📦 Block update received: \(blocks.count) blocks")
                self?.syncBlocks(blocks)
            }
            .store(in: &cancellables)
        print("✅ Block manager hooked up")
    }

    private func syncProjectiles(_ ps: [TurretProjectile]) {
        let idsNow = Set(ps.map { $0.id })
        
        // Remove old projectiles
        for (id, node) in projectileNodes where !idsNow.contains(id) {
            node.removeFromParent()
            projectileNodes.removeValue(forKey: id)
        }
        
        // Update existing and create new projectiles
        for p in ps {
            let worldPos = CGPoint(x: p.position.x * tileSize, y: p.position.y * tileSize)
            
            if let n = projectileNodes[p.id] {
                n.position = worldPos
            } else {
                let n = makeProjectileNode(for: p)
                n.position = worldPos
                projectileLayer.addChild(n)
                projectileNodes[p.id] = n
            }
        }
    }

    private func makeProjectileNode(for p: TurretProjectile) -> SKNode {
        let r = max(2.0, tileSize * 0.16)
        let n = SKShapeNode(circleOfRadius: r)
        n.fillColor = .white
        n.strokeColor = .clear
        n.zPosition = 200
        
        // Add a glow effect
        n.glowWidth = 2.0
        
        return n
    }

    private func ensureShardling(onTopOf placed: [PlacedBlock]) {
        // More robust core detection
        let coreBlocks = placed.filter { block in
            let iconName = block.iconName.lowercased()
            let blockType = block.blockType.lowercased()
            return iconName.contains("core") || blockType.contains("core") ||
                   iconName.contains("shard") || blockType.contains("shard")
        }
        
        guard let core = coreBlocks.first else {
            print("⚠️ No core found to spawn shardling on")
            return
        }
        
        // Calculate core center position
        var w: CGFloat = 1, h: CGFloat = 1
        if let coreDef = blockLibrary[.core]?.first(where: { $0.iconName == core.iconName }) {
            w = CGFloat(coreDef.sizeX)
            h = CGFloat(coreDef.sizeY)
        }
        
        let center = CGPoint(x: CGFloat(core.x) + w/2.0,
                             y: CGFloat(core.y) + h/2.0)
        
        if !hasSpawnedShardling {
            spawnShardling(at: center)
            hasSpawnedShardling = true
            print("📍 Shardling spawned at core position: \(center)")
            
            // Auto-center camera on core
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let camera = self.cameraController {
                    let worldPos = CGPoint(x: center.x * self.tileSize, y: center.y * self.tileSize)
                    camera.centerOnPosition(worldPosition: worldPos, viewSize: CGSize(width: 800, height: 600))
                    print("📷 Camera centered on core at world position: \(worldPos)")
                }
            }
        } else {
            // Update existing shardling position if core moved
            updateShardlingPosition(onTopOf: placed)
        }
    }
    
    private func updateShardlingPosition(onTopOf placed: [PlacedBlock]) {
        guard let core = placed.first(where: { $0.iconName.contains("core") }) else { return }
        guard let shardlingId = units.keys.first else { return }
        
        var w: CGFloat = 1, h: CGFloat = 1
        if let coreDef = blockLibrary[.core]?.first(where: { $0.iconName == core.iconName }) {
            w = CGFloat(coreDef.sizeX)
            h = CGFloat(coreDef.sizeY)
        }
        
        let newCenter = CGPoint(x: CGFloat(core.x) + w/2.0,
                                y: CGFloat(core.y) + h/2.0)
        
        // Move shardling to new core position if it's different
        if var unit = units[shardlingId] {
            let distance = sqrt(pow(newCenter.x - unit.position.x, 2) + pow(newCenter.y - unit.position.y, 2))
            if distance > 0.5 { // Only move if significant distance
                unit.targetPosition = newCenter
                unit.isMoving = true
                units[shardlingId] = unit
            }
        }
    }

    private func spawnShardling(at tilePos: CGPoint) {
        var u = Unit(kind: .shardling, faction: .lumina, position: tilePos, speed: 2.0, sprite: nil)
        
        let spriteNameCandidates = ["Shardling", "shardling", "shardling-0"]
        var tex: SKTexture? = nil
        
        // Try to find texture
        for candidate in spriteNameCandidates {
            if let foundTex = SKArt.tex(candidate) {
                tex = foundTex
                break
            }
        }
        
        // Fallback to creating texture from image name
        if tex == nil {
            tex = SKTexture(imageNamed: "Shardling")
            
            // If still no texture, create a simple colored rectangle
            if tex?.size().width == 0 || tex == nil {
                let fallbackNode = SKSpriteNode(color: .systemBlue, size: CGSize(width: tileSize * 2.5, height: tileSize * 2.5))
                fallbackNode.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                
                // Convert tile position to world position
                let worldPos = CGPoint(x: tilePos.x * tileSize, y: tilePos.y * tileSize)
                fallbackNode.position = worldPos
                fallbackNode.zPosition = 100
                fallbackNode.alpha = 1.0
                fallbackNode.isHidden = false
                
                // Add a border to make it more visible
                let border = SKShapeNode(rect: CGRect(x: -tileSize * 1.25, y: -tileSize * 1.25, width: tileSize * 2.5, height: tileSize * 2.5))
                border.strokeColor = .white
                border.fillColor = .clear
                border.lineWidth = 2.0
                fallbackNode.addChild(border)
                
                unitLayer.addChild(fallbackNode)
                u.sprite = fallbackNode
                units[u.id] = u
                
                // NEW: Set camera to follow this shardling
                if let camera = cameraController {
                    camera.setFollowTarget(worldPos, viewSize: CGSize(width: 800, height: 600))
                    print("📷 Camera now following shardling at: \(worldPos)")
                }
                
                print("Fallback shardling created at tile position: \(tilePos)")
                return
            }
        }
        
        let node = SKSpriteNode(texture: tex)
        node.size = CGSize(width: tileSize * 2.5, height: tileSize * 2.5)
        node.anchorPoint = CGPoint(x: 1, y: 1)
        
        // Convert tile position to world position
        let worldPos = CGPoint(x: tilePos.x * tileSize, y: tilePos.y * tileSize)
        node.position = worldPos
        node.zPosition = 100
        
        // Make sure it's visible
        node.alpha = 1.0
        node.isHidden = false
        
        unitLayer.addChild(node)
        u.sprite = node
        units[u.id] = u
        
        // NEW: Set camera to follow this shardling
        if let camera = cameraController {
            camera.setFollowTarget(worldPos, viewSize: CGSize(width: 800, height: 600))
            print("📷 Camera now following shardling at: \(worldPos)")
        }
        
        print("Shardling spawned successfully at tile position: \(tilePos)")
    }
    
    // NEW: Spawn unit method for fabricated units
    private func spawnUnit(type: UnitType, at worldPosition: CGPoint, facing direction: Direction, faction: Faction) {
        let tilePos = CGPoint(x: worldPosition.x / tileSize, y: worldPosition.y / tileSize)
        
        var u = Unit(kind: .ant, faction: faction, position: tilePos, speed: 3.0, sprite: nil)
        
        // Try to find ant texture
        let spriteNameCandidates = ["Ant", "ant", "ant-unit"]
        var tex: SKTexture? = nil
        
        for candidate in spriteNameCandidates {
            if let foundTex = SKArt.tex(candidate) {
                tex = foundTex
                break
            }
        }
        
        // Create sprite
        let node: SKSpriteNode
        if let tex = tex, tex.size().width > 0 {
            node = SKSpriteNode(texture: tex)
            node.size = CGSize(width: tileSize * 1.5, height: tileSize * 1.5)
        } else {
            // Fallback with faction color - make it triangular for ants
            let size = CGSize(width: tileSize * 1.5, height: tileSize * 1.5)
            node = SKSpriteNode(color: faction.primaryColor.uiColor, size: size)
            
            // Add triangular shape to indicate it's an ant
            let triangle = SKShapeNode()
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: size.height/2))
            path.addLine(to: CGPoint(x: -size.width/2, y: -size.height/2))
            path.addLine(to: CGPoint(x: size.width/2, y: -size.height/2))
            path.closeSubpath()
            triangle.path = path
            triangle.fillColor = faction.secondaryColor.uiColor
            triangle.strokeColor = .white
            triangle.lineWidth = 1.0
            node.addChild(triangle)
        }
        
        node.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        node.position = worldPosition
        node.zPosition = 90 // Below shardling but above other elements
        
        // Apply faction color tint
        if tex != nil {
            node.colorBlendFactor = 0.4
            node.color = faction.primaryColor.uiColor
        }
        
        // Set initial rotation based on spawn direction
        let rotation: CGFloat
        switch direction {
        case .north: rotation = 0
        case .east: rotation = CGFloat.pi / 2
        case .south: rotation = CGFloat.pi
        case .west: rotation = -CGFloat.pi / 2
        }
        node.zRotation = rotation
        
        node.alpha = 1.0
        node.isHidden = false
        
        unitLayer.addChild(node)
        u.sprite = node
        units[u.id] = u
        
        // Update faction stats
        FactionManager.shared.incrementUnitsOwned(for: faction)
        
        print("🐜 \(faction.displayName) ant spawned at \(worldPosition) facing \(direction)")
        
        // Add a spawn effect
        addSpawnEffect(at: worldPosition)
    }
    
    // NEW: Add spawn effect for visual feedback
    private func addSpawnEffect(at position: CGPoint) {
        let effect = SKShapeNode(circleOfRadius: tileSize)
        effect.strokeColor = .yellow
        effect.fillColor = .yellow.withAlphaComponent(0.3)
        effect.lineWidth = 2.0
        effect.position = position
        effect.zPosition = 80
        
        effectsLayer.addChild(effect)
        
        // Animate the effect
        let expand = SKAction.scale(to: 1.5, duration: 0.3)
        let fade = SKAction.fadeOut(withDuration: 0.3)
        let remove = SKAction.removeFromParent()
        let sequence = SKAction.sequence([
            SKAction.group([expand, fade]),
            remove
        ])
        
        effect.run(sequence)
    }
    
    private func startUnitUpdates() {
        let updateAction = SKAction.repeatForever(
            SKAction.sequence([
                SKAction.run { [weak self] in self?.updateUnits() },
                SKAction.wait(forDuration: 1.0/30.0) // 30 FPS unit updates
            ])
        )
        run(updateAction)
    }
    
    private func updateUnits() {
        for (id, var unit) in units {
            guard let sprite = unit.sprite else { continue }
            
            // Handle movement
            if unit.isMoving, let target = unit.targetPosition {
                let currentPos = unit.position
                let dx = target.x - currentPos.x
                let dy = target.y - currentPos.y
                let distance = sqrt(dx * dx + dy * dy)
                
                if distance < 0.1 {
                    // Arrived at target
                    unit.position = target
                    unit.targetPosition = nil
                    unit.isMoving = false
                    
                    // Update sprite position with current drift
                    let baseWorldPos = CGPoint(x: target.x * tileSize, y: target.y * tileSize)
                    let driftedPos = CGPoint(
                        x: baseWorldPos.x + unit.displayOffset.dx,
                        y: baseWorldPos.y + unit.displayOffset.dy
                    )
                    sprite.position = driftedPos
                } else {
                    // Move towards target
                    let speed = unit.speed / 30.0 // Adjust for 30 FPS updates
                    let moveX = (dx / distance) * speed
                    let moveY = -(dy / distance) * speed
                    
                    unit.position.x += moveX
                    unit.position.y += moveY
                    
                    // Update sprite position with current drift
                    let baseWorldPos = CGPoint(x: unit.position.x * tileSize, y: unit.position.y * tileSize)
                    let driftedPos = CGPoint(
                        x: baseWorldPos.x + unit.displayOffset.dx,
                        y: baseWorldPos.y + unit.displayOffset.dy
                    )
                    sprite.position = driftedPos
                }
                
                units[id] = unit
            }
        }
    }
    
    func respawnShardling() {
        guard let blockManager = blockManager else {
            print("⚠️ No block manager available for respawn")
            return
        }
        
        // Remove existing shardling
        for (id, unit) in units {
            if unit.kind == .shardling {
                unit.sprite?.removeFromParent()
                units.removeValue(forKey: id)
                print("🗑️ Removed existing shardling")
            }
        }
        
        // Reset spawn flag
        hasSpawnedShardling = false
        
        // Respawn on current blocks
        syncBlocks(blockManager.placedBlocks)
        
        print("🔄 Shardling respawned!")
    }
}

extension SKUnitsScene {
    // Update spawnShardling to include faction
    private func spawnShardling(at tilePos: CGPoint, faction: Faction = .lumina) {
        var u = Unit(kind: .shardling, faction: faction, position: tilePos, speed: 2.0, sprite: nil)
        
        let spriteNameCandidates = ["Shardling", "shardling", "shardling-0"]
        var tex: SKTexture? = nil
        
        // Try to find texture
        for candidate in spriteNameCandidates {
            if let foundTex = SKArt.tex(candidate) {
                tex = foundTex
                break
            }
        }
        
        // Create sprite with faction colors
        let node: SKSpriteNode
        if let tex = tex, tex.size().width > 0 {
            node = SKSpriteNode(texture: tex)
            node.size = CGSize(width: tileSize * 2.5, height: tileSize * 2.5)
        } else {
            // Fallback with faction color
            node = SKSpriteNode(color: faction.primaryColor.uiColor, size: CGSize(width: tileSize * 2.5, height: tileSize * 2.5))
            
            // Add faction indicator
            let border = SKShapeNode(rect: CGRect(x: -tileSize * 1.25, y: -tileSize * 1.25, width: tileSize * 2.5, height: tileSize * 2.5))
            border.strokeColor = faction.secondaryColor.uiColor
            border.fillColor = .clear
            border.lineWidth = 2.0
            node.addChild(border)
        }
        
        node.anchorPoint = CGPoint(x: 1, y: 1)
        
        // Convert tile position to world position
        let worldPos = CGPoint(x: tilePos.x * tileSize, y: tilePos.y * tileSize)
        node.position = worldPos
        node.zPosition = 100
        
        // Apply faction color tint if not already colored
        if tex != nil {
            node.colorBlendFactor = 0.3
            node.color = faction.primaryColor.uiColor
        }
        
        node.alpha = 1.0
        node.isHidden = false
        
        unitLayer.addChild(node)
        u.sprite = node
        units[u.id] = u
        
        // Update faction stats
        FactionManager.shared.incrementUnitsOwned(for: faction)
        
        // Only follow player faction units
        if faction == FactionManager.shared.playerFaction {
            if let camera = cameraController {
                camera.setFollowTarget(worldPos, viewSize: CGSize(width: 800, height: 600))
                print("📷 Camera now following \(faction.displayName) shardling at: \(worldPos)")
            }
        }
        
        print("\(faction.displayName) shardling spawned successfully at tile position: \(tilePos)")
    }
}

// Extension to convert SwiftUI Color to UIColor
extension Color {
    var uiColor: UIColor {
        if #available(iOS 14.0, *) {
            return UIColor(self)
        } else {
            // Fallback for older iOS versions
            let components = self.cgColor?.components ?? [0, 0, 0, 1]
            return UIColor(red: components[0], green: components[1], blue: components[2], alpha: components[3])
        }
    }
}

// MARK: - UIViewRepresentable for units overlay
private struct SKUnitsOverlay: UIViewRepresentable {
    let mapData: MapData
    let blockLibrary: [BlockCategory: [BlockType]]
    let tileSize: CGFloat
    @ObservedObject var cameraController: CameraController
    weak var transmissionManager: TransmissionNetworkManager?
    weak var blockManager: BlockLoadingManager?
    let placedBlocks: [PlacedBlock]
    
    // Add this binding
    @Binding var respawnTrigger: Bool

    func makeUIView(context: Context) -> SKView {
        print("🗂️ Creating SKView for units overlay...")
        let v = SKView()
        v.ignoresSiblingOrder = true
        v.preferredFramesPerSecond = 60
        v.showsFPS = false
        v.showsNodeCount = false
        v.backgroundColor = .clear
        v.allowsTransparency = true

        // Use the map-based size with correct scale mode
        let sceneSize = CGSize(width: CGFloat(mapData.width * 32), height: CGFloat(mapData.height * 32))
        print("📏 Creating scene with size: \(sceneSize)")
        
        let scene = SKUnitsScene(size: sceneSize)
        scene.scaleMode = .aspectFill  // Use .aspectFill to prevent clipping
        
        print("🎬 Configuring scene with mapData size: \(mapData.width)x\(mapData.height)")
        scene.configure(mapData: mapData,
                        blockLibrary: blockLibrary,
                        tileSize: tileSize,
                        cameraController: cameraController,
                        transmissionManager: transmissionManager,
                        blockManager: blockManager)
        
        context.coordinator.scene = scene
        v.presentScene(scene)
        print("✅ SKView created and scene presented")
        return v
    }

    func updateUIView(_ uiView: SKView, context: Context) {
        // Handle respawn trigger
        if respawnTrigger {
            context.coordinator.respawnShardling()
            // Reset trigger - this will be handled by the parent view
        }
    }

    func makeCoordinator() -> Coord { Coord() }
    final class Coord {
        weak var scene: SKUnitsScene?
        
        func respawnShardling() {
            scene?.respawnShardling()
        }
    }
}

// MARK: - Enhanced map view with SpriteKit units overlay
struct SKEnhancedMapView: View {
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
    @ObservedObject var blockManager: BlockLoadingManager
    @Binding var mapViewFrame: CGRect
    
    // Add this binding
    @Binding var respawnTrigger: Bool

    var body: some View {
        GeometryReader { geometry in
            if let mapData = try? MapData.fromJSONFile(at: fileURL) {
                ZStack(alignment: .topLeading) {
                    // Original SwiftUI-based map rendering (keep this working!)
                    CameraControlledMapView(
                        fileURL: fileURL,
                        cameraController: cameraController,
                        placedBlocks: placedBlocks,
                        onMapTap: onMapTap,
                        onDragStart: onDragStart,
                        onDragChanged: onDragChanged,
                        onDragEnd: onDragEnd,
                        linePlacementPoints: linePlacementPoints,
                        linePlacementCollisions: linePlacementCollisions,
                        selectedBlock: selectedBlock,
                        selectedBlockRotation: selectedBlockRotation,
                        hoverTileCoordinates: hoverTileCoordinates,
                        isHoverColliding: isHoverColliding,
                        blockLibrary: blockLibrary,
                        transmissionManager: transmissionManager,
                        blockManager: blockManager,
                        mapViewFrame: $mapViewFrame
                    )
                    
                    // SpriteKit overlay for units and projectiles only
                    SKUnitsOverlay(
                        mapData: mapData,
                        blockLibrary: blockLibrary,
                        tileSize: 32,
                        cameraController: cameraController,
                        transmissionManager: transmissionManager,
                        blockManager: blockManager,
                        placedBlocks: placedBlocks,
                        respawnTrigger: $respawnTrigger
                    )
                    .allowsHitTesting(false) // Let touches pass through to underlying map
                }
                .background(
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
