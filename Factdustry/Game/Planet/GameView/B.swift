//
//  B.swift
//  Factdustry
//
//  Created by Bright on 7/24/25.
//

import SwiftUI
import UIKit
import Combine
import SwiftData

// MARK: - Convenience Extensions and Factory Methods

extension TileRequirement {
    /// Factory method for simple ore extraction buildings
    static func requiresOre(oreTypes: [OreType] = [.copper, .graphite]) -> TileRequirement {
        return TileRequirement(
            globalRules: [
                TileRequirementRule(
                    type: .all,
                    conditions: [.anyOreType(oreTypes)],
                    customErrorMessage: "Must be placed on ore deposits",
                    priority: 100
                )
            ],
            name: "Ore Extraction",
            description: "Must be placed entirely on ore deposits"
        )
    }
    
    /// NEW: Factory method for buildings that need ore in front of them (directional)
    static func requiresOreInFront(oreTypes: [OreType] = [.copper, .graphite], frontDistance: Int = 1) -> TileRequirement {
        let floorTypes: [TileType] = [.darkSand, .terrain0, .terrain1, .terrain2]
        
        return TileRequirement(
            globalRules: [
                TileRequirementRule(
                    type: .all,
                    conditions: [.anyTileType(floorTypes)],
                    customErrorMessage: "Must be placed on solid ground",
                    priority: 50
                )
            ],
            name: "Directional Ore Extraction",
            description: "Must face ore deposits and be placed on solid ground",
            customValidation: { blockSize, position, rotation, mapData in
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
                
                let rotatedSize = rotation.applied(to: blockSize)
                
                // Check all tiles in front of the building for ore
                var hasOreInFront = false
                
                // For each tile along the front edge of the building
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
                        if oreTypes.contains(oreType) {
                            hasOreInFront = true
                            break
                        }
                    }
                }
                
                if !hasOreInFront {
                    let directionName: String
                    switch rotation.rawValue {
                    case 0: directionName = "above"
                    case 1: directionName = "to the right"
                    case 2: directionName = "below"
                    case 3: directionName = "to the left"
                    default: directionName = "in front"
                    }
                    
                    return (false, "Must face ore deposits (\(directionName) of building)")
                }
                
                return (true, nil)
            }
        )
    }
    
    /// Factory method for buildings that need vents
    static func requiresVent() -> TileRequirement {
        return TileRequirement(
            globalRules: [
                TileRequirementRule(
                    type: .any,
                    conditions: [.tileType(.vent)],
                    customErrorMessage: "Must be placed on or adjacent to a vent",
                    priority: 100
                )
            ],
            name: "Vent Required",
            description: "Must have at least one tile on a vent"
        )
    }
    
    /// Factory method for buildings that need geysers
    static func requiresGeyser() -> TileRequirement {
        return TileRequirement(
            globalRules: [
                TileRequirementRule(
                    type: .any,
                    conditions: [.tileType(.geyser)],
                    customErrorMessage: "Must be placed on or adjacent to a geyser",
                    priority: 100
                )
            ],
            name: "Geyser Required",
            description: "Must have at least one tile on a geyser"
        )
    }
    
    /// Factory method for buildings that can use either vents or geysers
    static func requiresVentOrGeyser() -> TileRequirement {
        return TileRequirement(
            globalRules: [
                TileRequirementRule(
                    type: .any,
                    conditions: [.anyTileType([.vent, .geyser])],
                    customErrorMessage: "Must be placed on or adjacent to a vent or geyser",
                    priority: 100
                )
            ],
            name: "Vent or Geyser Required",
            description: "Must have at least one tile on a vent or geyser"
        )
    }
    
    /// Factory method for standard floor placement
    static func requiresFloor() -> TileRequirement {
        let floorTypes: [TileType] = [.darkSand, .terrain0, .terrain1, .terrain2, .geyser, .vent]
        return TileRequirement(
            globalRules: [
                TileRequirementRule(
                    type: .all,
                    conditions: [.anyTileType(floorTypes)],
                    customErrorMessage: "Must be placed on solid ground",
                    priority: 50
                ),
            ],
            name: "Floor Required",
            description: "Must be placed on solid ground, not on special terrain"
        )
    }
    
    /// Factory method for buildings that need mixed terrain (some ore, some floor)
    static func requiresMixedTerrain(minOrePercentage: Double = 0.5) -> TileRequirement {
        let floorTypes: [TileType] = [.darkSand, .terrain0, .terrain1, .terrain2]
        return TileRequirement(
            globalRules: [
                TileRequirementRule(
                    type: .percentage(minOrePercentage),
                    conditions: [.anyOre],
                    customErrorMessage: "Requires at least \(Int(minOrePercentage * 100))% ore coverage",
                    priority: 100
                ),
                TileRequirementRule(
                    type: .atLeast(1),
                    conditions: [.anyTileType(floorTypes), .noOre],
                    logicalOperator: .and,
                    customErrorMessage: "Requires at least one solid ground tile without ore",
                    priority: 90
                )
            ],
            name: "Mixed Terrain",
            description: "Requires both ore deposits and solid ground"
        )
    }
    
    /// Factory method for advanced buildings with complex positional requirements
    static func advancedFactoryRequirement() -> TileRequirement {
        let floorTypes: [TileType] = [.darkSand, .terrain0, .terrain1, .terrain2]
        
        return TileRequirement(
            globalRules: [
                TileRequirementRule(
                    type: .atLeast(4),
                    conditions: [.anyTileType(floorTypes)],
                    customErrorMessage: "Requires at least 4 solid ground tiles",
                    priority: 100
                )
            ],
            positionalRequirements: [
                // Center tile must be solid ground with no ore (for foundation)
                PositionalRequirement(x: 1, y: 1, rules: [
                    TileRequirementRule(
                        type: .all,
                        conditions: [.anyTileType(floorTypes), .noOre],
                        logicalOperator: .and,
                        customErrorMessage: "Center must be solid ground without ore (foundation)",
                        priority: 100
                    )
                ]),
                // At least one corner must have access to power (no specific requirement for now)
                PositionalRequirement(x: 0, y: 0, rules: [
                    TileRequirementRule(
                        type: .all,
                        conditions: [.anyTileType(floorTypes)],
                        customErrorMessage: "Corner must be solid ground (power access)",
                        priority: 90
                    )
                ])
            ],
            name: "Advanced Factory",
            description: "Complex factory requiring specific foundation and access requirements"
        )
    }
    
    /// Factory method for water-based buildings
    static func requiresWaterAccess() -> TileRequirement {
        return TileRequirement(
            globalRules: [
                TileRequirementRule(
                    type: .any,
                    conditions: [.tileType(.geyser)], // Assuming geysers provide water access
                    customErrorMessage: "Must have access to water source",
                    priority: 100
                )
            ],
            name: "Water Access Required",
            description: "Must be placed near a water source"
        )
    }
}

extension TileRequirement {
    /// Factory method for buildings that need their CENTER tile on a vent
    static func requiresCenterOnVent() -> TileRequirement {
        return TileRequirement(
            globalRules: [
                // All other tiles must be solid ground
                TileRequirementRule(
                    type: .all,
                    conditions: [.anyTileType([.darkSand, .terrain0, .terrain1, .terrain2, .vent])],
                    customErrorMessage: "Must be placed on solid ground or vents",
                    priority: 50
                )
            ],
            positionalRequirements: [
                // Center tile (1,1 for 3x3 building) must be a vent
                PositionalRequirement(x: 1, y: 1, rules: [
                    TileRequirementRule(
                        type: .all,
                        conditions: [.tileType(.vent)],
                        customErrorMessage: "Center tile must be on a vent",
                        priority: 100
                    )
                ])
            ],
            name: "Center Vent Required",
            description: "Center tile must be placed on a vent"
        )
    }
    
    /// Factory method for buildings that need their CENTER tile on a vent or geyser
    static func requiresCenterOnVentOrGeyser() -> TileRequirement {        
        return TileRequirement(
            globalRules: [
                // All tiles must be either solid ground, vents, or geysers
                TileRequirementRule(
                    type: .all,
                    conditions: [.anyTileType([.darkSand, .terrain0, .terrain1, .terrain2, .vent, .geyser])],
                    customErrorMessage: "Must be placed on solid ground, vents, or geysers",
                    priority: 50
                )
            ],
            positionalRequirements: [
                // Center tile (1,1 for 3x3 building) must be a vent or geyser
                PositionalRequirement(x: 1, y: 1, rules: [
                    TileRequirementRule(
                        type: .all,
                        conditions: [.anyTileType([.vent, .geyser])],
                        customErrorMessage: "Center tile must be on a vent or geyser",
                        priority: 100
                    )
                ])
            ],
            name: "Center Vent or Geyser Required",
            description: "Center tile must be placed on a vent or geyser"
        )
    }
}

// MARK: - Display Name Extensions for Better Error Messages

extension TileType {
    var displayName: String {
        switch self {
        case .darkSand: return "Dark Sand"
        case .terrain0: return "Rocky Terrain"
        case .terrain1: return "Sandy Terrain"
        case .terrain2: return "Hard Ground"
        case .vent: return "Vent"
        case .geyser: return "Geyser"
        case .empty:
            return "empty"
        case .wall0:
            return "wall0"
        case .wall1:
            return "wall1"
        case .wall2:
            return "wall2"
        case .wall3:
            return "wall3"
        case .water:
            return "water"
        case .saltWater:
            return "salt-water"
        case .shrub:
            return "shrub"
        }
    }
}

extension OreType {
    var displayName: String {
        switch self {
        case .none: return "No Ore"
        case .copper: return "Copper"
        case .graphite: return "Graphite"
        case .coal: return "Coal"
        case .sulfur: return "Sulfur"
        }
    }
}

// MARK: - Centralized Block Rotation System

/// Handles all block rotation logic in a centralized, clean way
struct BlockRotation: Equatable {
    let rawValue: Int
    
    init(_ value: Int = 0) {
        self.rawValue = ((value % 4) + 4) % 4  // Ensure always 0-3, handle negative values
    }
    
    /// Rotation angle in degrees
    var degrees: Double {
        return Double(rawValue) * 90.0
    }
    
    /// Rotation angle in radians
    var radians: Double {
        return degrees * .pi / 180.0
    }
    
    /// Rotate clockwise
    func rotatedClockwise() -> BlockRotation {
        return BlockRotation(rawValue + 1)
    }
    
    /// Rotate counter-clockwise
    func rotatedCounterClockwise() -> BlockRotation {
        return BlockRotation(rawValue - 1)
    }
    
    /// Apply rotation to a size (width, height)
    func applied(to size: CGSize) -> CGSize {
        switch rawValue {
        case 0, 2: return size  // 0° and 180° - no size change
        case 1, 3: return CGSize(width: size.height, height: size.width)  // 90° and 270° - swap dimensions
        default: return size
        }
    }
    
    /// Apply rotation to integer dimensions
    func applied(to size: (width: Int, height: Int)) -> (width: Int, height: Int) {
        switch rawValue {
        case 0, 2: return size  // 0° and 180°
        case 1, 3: return (width: size.height, height: size.width)  // 90° and 270°
        default: return size
        }
    }
    
    /// Apply rotation to a point (for texture offsets)
    func applied(to point: CGPoint) -> CGPoint {
        switch rawValue {
        case 0: return point  // 0° - no change
        case 1: return CGPoint(x: -point.y, y: point.x)  // 90° clockwise
        case 2: return CGPoint(x: -point.x, y: -point.y)  // 180°
        case 3: return CGPoint(x: point.y, y: -point.x)  // 270° clockwise
        default: return point
        }
    }
    
    /// Get the rotation direction name for debugging
    var directionName: String {
        switch rawValue {
        case 0: return "North (0°)"
        case 1: return "East (90°)"
        case 2: return "South (180°)"
        case 3: return "West (270°)"
        default: return "Unknown"
        }
    }
}

// MARK: - Rotation Controller

class RotationController: ObservableObject {
    @Published var selectedBlockRotation: BlockRotation = BlockRotation()
    
    private let hapticFeedback = UIImpactFeedbackGenerator(style: .light)
    
    /// Rotate the selected block clockwise
    func rotateClockwise() {
        selectedBlockRotation = selectedBlockRotation.rotatedClockwise()
        hapticFeedback.impactOccurred()
    }
    
    /// Rotate the selected block counter-clockwise
    func rotateCounterClockwise() {
        selectedBlockRotation = selectedBlockRotation.rotatedCounterClockwise()
        hapticFeedback.impactOccurred()
    }
    
    /// Reset rotation when a new block is selected
    func resetRotation() {
        selectedBlockRotation = BlockRotation()
    }
    
    /// Handle scroll input for rotation
    func handleScroll(delta: CGFloat) {
        if delta > 0 {
            rotateClockwise()
        } else if delta < 0 {
            rotateCounterClockwise()
        }
    }
    
    /// Handle keyboard input for rotation
    func handleKeyboard(key: String) {
        switch key.lowercased() {
        case "e":
            rotateClockwise()
        case "q":
            rotateCounterClockwise()
        default:
            break
        }
    }
}

// MARK: - Global Hover Detection

/// ObservableObject that publishes global hover positions and scroll events
final class GlobalHoverObserver: ObservableObject {
    @Published var location: CGPoint = .zero
    @Published var isHovering: Bool = false
    @Published var scrollDelta: CGFloat = 0
    
    private var isInstalled = false
    private var mouseTrackingView: UIView?
    private var lastUpdateTime: CFTimeInterval = 0
    private let updateThrottle: CFTimeInterval = 1.0 / 240.0 // IMPROVED: Increased to 240 FPS for more responsive hover
    
    // Scroll event callback
    var onScrollEvent: ((CGFloat) -> Void)?

    /// Call this once, passing in your app's window
    func install(on window: UIWindow) {
        guard !isInstalled else {
            return
        }
        
        // Add UIHover support for iOS/iPadOS
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        window.addGestureRecognizer(hover)
        
        // Add scroll wheel support
        setupScrollWheelDetection(on: window)
        
        // Add Mac Catalyst keyboard support through UIKit
        #if targetEnvironment(macCatalyst)
        setupMacMouseTracking(in: window)
        #endif
        
        isInstalled = true
    }
    
    private func setupScrollWheelDetection(on window: UIWindow) {
        // Create a custom view to capture scroll events
        let scrollCaptureView = ScrollCaptureView()
        scrollCaptureView.frame = window.bounds
        scrollCaptureView.backgroundColor = UIColor.clear
        scrollCaptureView.isUserInteractionEnabled = true
        scrollCaptureView.onScrollEvent = { [weak self] delta in
            DispatchQueue.main.async {
                self?.onScrollEvent?(delta)
            }
        }
        
        // Add as the topmost view to capture all scroll events
        window.addSubview(scrollCaptureView)
        window.bringSubviewToFront(scrollCaptureView)
        
        // FIXED: Ensure the view stays on top and resizes with the window
        scrollCaptureView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollCaptureView.topAnchor.constraint(equalTo: window.topAnchor),
            scrollCaptureView.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            scrollCaptureView.trailingAnchor.constraint(equalTo: window.trailingAnchor),
            scrollCaptureView.bottomAnchor.constraint(equalTo: window.bottomAnchor)
        ])
    }
    
    @objc
    private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        guard let view = recognizer.view else { return }
        let pt = recognizer.location(in: view)
        updateLocationThrottled(pt, isHovering: recognizer.state == .changed || recognizer.state == .began)
    }
    
    // IMPROVED: More responsive throttling and immediate updates for significant movements
    private func updateLocationThrottled(_ newLocation: CGPoint, isHovering: Bool) {
        let currentTime = CACurrentMediaTime()
        
        // Calculate movement distance since last update
        let distance = sqrt(pow(newLocation.x - location.x, 2) + pow(newLocation.y - location.y, 2))
        
        // IMPROVED: Allow immediate updates for larger movements (tile boundaries)
        // or respect throttle for small movements
        let shouldUpdate = currentTime - lastUpdateTime > updateThrottle || distance > 10
        
        guard shouldUpdate else { return }
        lastUpdateTime = currentTime
        
        DispatchQueue.main.async {
            self.location = newLocation
            self.isHovering = isHovering
        }
    }
    
    #if targetEnvironment(macCatalyst)
    
    private func setupMacMouseTracking(in window: UIWindow) {
    }

    // Called from Mac mouse tracking view
    func updateMouseLocation(_ location: CGPoint, isHovering: Bool) {
        updateLocationThrottled(location, isHovering: isHovering)
    }
    
    #endif
}

// MARK: - FIXED: Improved Scroll Capture View
class ScrollCaptureView: UIView {
    var onScrollEvent: ((CGFloat) -> Void)?
    private var lastScrollTime: CFTimeInterval = 0
    private let scrollThrottle: CFTimeInterval = 1.0 / 240.0 // 240 FPS throttling
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupScrollDetection()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupScrollDetection()
    }
    
    private func setupScrollDetection() {
        // FIXED: Support both discrete and continuous scroll events for trackpads
        #if targetEnvironment(macCatalyst)
        
        // Add continuous scroll support for trackpads
        let continuousScrollGesture = UIPanGestureRecognizer(target: self, action: #selector(handleContinuousScroll(_:)))
        continuousScrollGesture.allowedScrollTypesMask = .continuous
        continuousScrollGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        addGestureRecognizer(continuousScrollGesture)
        
        // Add discrete scroll support for mouse wheels
        let discreteScrollGesture = UIPanGestureRecognizer(target: self, action: #selector(handleDiscreteScroll(_:)))
        discreteScrollGesture.allowedScrollTypesMask = .discrete
        discreteScrollGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        addGestureRecognizer(discreteScrollGesture)
        
        #endif
    }
    
    @objc private func handleContinuousScroll(_ gesture: UIPanGestureRecognizer) {
        // FIXED: Handle trackpad scrolling
        let translation = gesture.translation(in: self)
        let delta = -translation.y // Invert Y for natural scrolling direction
        
        // Throttle scroll events to prevent overwhelming the system
        let currentTime = CACurrentMediaTime()
        guard currentTime - lastScrollTime > scrollThrottle else { return }
        lastScrollTime = currentTime
        
        if abs(delta) > 2 { // Threshold to avoid tiny movements
            onScrollEvent?(delta)
            gesture.setTranslation(.zero, in: self)
        }
    }
    
    @objc private func handleDiscreteScroll(_ gesture: UIPanGestureRecognizer) {
        // FIXED: Handle mouse wheel scrolling
        let translation = gesture.translation(in: self)
        let delta = -translation.y // Invert Y for natural scrolling direction
        
        if abs(delta) > 1 { // Lower threshold for discrete scroll events
            onScrollEvent?(delta)
            gesture.setTranslation(.zero, in: self)
        }
    }
    
    // FIXED: Allow the view to receive events but pass touches through to underlying views
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Check if this is a scroll event (indirect pointer)
        if let touches = event?.allTouches {
            for touch in touches {
                if touch.type == .indirectPointer {
                    // This is a scroll/trackpad event, capture it
                    return self
                }
            }
        }
        
        // For all other events (direct touches), pass through to underlying views
        return nil
    }
    
    // FIXED: Allow the view to become first responder for scroll events
    override var canBecomeFirstResponder: Bool {
        return true
    }
}

#if targetEnvironment(macCatalyst)
protocol MacKeyboardDelegate: AnyObject {
    func handleMacKeyDown(_ key: String)
    func handleMacKeyUp(_ key: String)
}

class MacKeyboardHandler: MacKeyboardDelegate {
    var onKeyDown: ((String) -> Void)?
    var onKeyUp: ((String) -> Void)?
    
    func handleMacKeyDown(_ key: String) {
        onKeyDown?(key)
    }
    
    func handleMacKeyUp(_ key: String) {
        onKeyUp?(key)
    }
}
#endif

// Mac Catalyst mouse tracking view - uses UIKit only
class MacMouseTrackingView: UIView {
    weak var hoverObserver: GlobalHoverObserver?
    
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
    }
}

/// UIViewRepresentable that gives access to the UIWindow
struct WindowAccessor: UIViewRepresentable {
    var callback: (UIWindow) -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        // Once this view is in a window, grab it
        DispatchQueue.main.async {
            if let win = v.window {
                self.callback(win)
            }
        }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Try again in case the window wasn't available the first time
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let win = uiView.window {
                self.callback(win)
            }
        }
    }
}

struct Resource: Identifiable {
    let id = UUID()
    let iconName: String
    let count: Int
}

enum ItemType: Codable, CaseIterable, Hashable {
    case copper
    case graphite
    case silicon
    case iron
    case steel
    case rawAliuminum
    case aliuminum
    case coal
    case sulfur
    
    var displayName: String {
        switch self {
        case .copper: return "Copper"
        case .graphite: return "Graphite"
        case .silicon: return "Silicon"
        case .iron: return "Iron"
        case .steel: return "Steel"
        case .rawAliuminum: return "Raw Aluminum"
        case .aliuminum: return "Aluminum"
        case .coal: return "Coal"
        case .sulfur: return "Sulfur"
        }
    }
    
    var iconName: String {
        switch self {
        case .copper: return "copper"
        case .graphite: return "graphite"
        case .silicon: return "silicon"
        case .iron: return "iron"
        case .steel: return "steel"
        case .rawAliuminum: return "rawAluminum"
        case .aliuminum: return "aluminum"
        case .coal: return "coal"
        case .sulfur: return"sulfur"
        }
    }
}

enum FluidType: Codable, Hashable {
    case water
    case hydrogen
    case oxygen
    
    var displayName: String {
        switch self {
        case .water: return "Water"
        case .hydrogen: return "Hydrogen"
        case .oxygen: return "Oxygen"
        }
    }
}

@Model
final class Process {
    var time: Double
    
    var inputItems: [ItemType:Int]?
    var inputFluids: [FluidType:Int]?
    var inputPower: Int?
    
    var outputItems: [ItemType:Int]?
    var outputFluids: [FluidType:Int]?
    var outputPower: Int?
    
    init(time: Double, inputItems: [ItemType : Int]? = nil, inputFluids: [FluidType : Int]? = nil, inputPower: Int? = nil, outputItems: [ItemType : Int]? = nil, outputFluids: [FluidType : Int]? = nil, outputPower: Int? = nil) {
        self.time = time
        self.inputItems = inputItems
        self.inputFluids = inputFluids
        self.inputPower = inputPower
        self.outputItems = outputItems
        self.outputFluids = outputFluids
        self.outputPower = outputPower
    }
}

// MARK: - Faction System

enum Faction: String, CaseIterable, Codable {
    case lumina = "lumina"      // Player faction (blue)
    case ferox = "ferox"        // Enemy faction (red)
    case malum = "malum"        // Yndora faction (purple)
    case kanir = "kanir"        // Gas planet faction (green)
    case neutral = "neutral"    // Neutral/abandoned (gray)
    
    var displayName: String {
        switch self {
        case .lumina: return "Lumina"
        case .ferox: return "Ferox"
        case .malum: return "Malum"
        case .kanir: return "Kanir"
        case .neutral: return "Neutral"
        }
    }
    
    var primaryColor: Color {
        switch self {
        case .lumina: return .blue
        case .ferox: return .red
        case .malum: return .purple
        case .kanir: return .green
        case .neutral: return .gray
        }
    }
    
    var secondaryColor: Color {
        switch self {
        case .lumina: return .cyan
        case .ferox: return .orange
        case .malum: return .pink
        case .kanir: return .mint
        case .neutral: return .white
        }
    }
    
    var description: String {
        switch self {
        case .lumina: return "The refugee faction seeking a new home"
        case .ferox: return "Militaristic empire expanding their dominance"
        case .malum: return "Mysterious faction from Yndora"
        case .kanir: return "Gas planet colonists"
        case .neutral: return "Abandoned or unclaimed territory"
        }
    }
}

enum FactionRelation: String, Codable {
    case allied = "allied"
    case neutral = "neutral"
    case enemy = "enemy"
    
    var canAttack: Bool {
        return self == .enemy
    }
    
    var canAssist: Bool {
        return self == .allied
    }
    
    var displayName: String {
        switch self {
        case .allied: return "Allied"
        case .neutral: return "Neutral"
        case .enemy: return "Enemy"
        }
    }
    
    var color: Color {
        switch self {
        case .allied: return .green
        case .neutral: return .yellow
        case .enemy: return .red
        }
    }
}

// MARK: - Faction Manager

class FactionManager: ObservableObject {
    static let shared = FactionManager()
    
    @Published var playerFaction: Faction = .lumina
    @Published var factionRelations: [Faction: [Faction: FactionRelation]] = [:]
    @Published var factionStats: [Faction: FactionStats] = [:]
    
    struct FactionStats {
        var blocksOwned: Int = 0
        var unitsOwned: Int = 0
        var resourcesCollected: Int = 0
        var blocksDestroyed: Int = 0
        var unitsDestroyed: Int = 0
    }
    
    private init() {
        setupDefaultRelations()
        initializeFactionStats()
    }
    
    private func setupDefaultRelations() {
        // Initialize all factions with neutral relations
        for faction1 in Faction.allCases {
            factionRelations[faction1] = [:]
            for faction2 in Faction.allCases {
                if faction1 == faction2 {
                    factionRelations[faction1]?[faction2] = .allied // Same faction
                } else {
                    factionRelations[faction1]?[faction2] = .neutral
                }
            }
        }
        
        // Set up story-based relations
        setRelation(from: .lumina, to: .ferox, relation: .enemy)
        setRelation(from: .ferox, to: .lumina, relation: .enemy)
        
        setRelation(from: .lumina, to: .malum, relation: .neutral)
        setRelation(from: .malum, to: .lumina, relation: .neutral)
        
        setRelation(from: .lumina, to: .kanir, relation: .neutral)
        setRelation(from: .kanir, to: .lumina, relation: .neutral)
        
        setRelation(from: .ferox, to: .malum, relation: .enemy)
        setRelation(from: .malum, to: .ferox, relation: .enemy)
        
        setRelation(from: .ferox, to: .kanir, relation: .neutral)
        setRelation(from: .kanir, to: .ferox, relation: .neutral)
        
        setRelation(from: .malum, to: .kanir, relation: .neutral)
        setRelation(from: .kanir, to: .malum, relation: .neutral)
        
        // Neutral faction is neutral to everyone except itself
        for faction in Faction.allCases where faction != .neutral {
            setRelation(from: .neutral, to: faction, relation: .neutral)
            setRelation(from: faction, to: .neutral, relation: .neutral)
        }
    }
    
    private func initializeFactionStats() {
        for faction in Faction.allCases {
            factionStats[faction] = FactionStats()
        }
    }
    
    func setRelation(from faction1: Faction, to faction2: Faction, relation: FactionRelation) {
        factionRelations[faction1]?[faction2] = relation
    }
    
    func getRelation(from faction1: Faction, to faction2: Faction) -> FactionRelation {
        return factionRelations[faction1]?[faction2] ?? .neutral
    }
    
    func areAllied(_ faction1: Faction, _ faction2: Faction) -> Bool {
        return getRelation(from: faction1, to: faction2) == .allied
    }
    
    func areEnemies(_ faction1: Faction, _ faction2: Faction) -> Bool {
        return getRelation(from: faction1, to: faction2) == .enemy
    }
    
    func canAttack(attacker: Faction, target: Faction) -> Bool {
        return getRelation(from: attacker, to: target).canAttack
    }
    
    func canAssist(helper: Faction, target: Faction) -> Bool {
        return getRelation(from: helper, to: target).canAssist
    }
    
    // MARK: - Statistics
    
    func incrementBlocksOwned(for faction: Faction) {
        var s = factionStats[faction] ?? FactionStats()
        s.blocksOwned += 1
        factionStats[faction] = s
        // Trigger @Published update
        self.factionStats = self.factionStats
    }
    
    func decrementBlocksOwned(for faction: Faction) {
        var s = factionStats[faction] ?? FactionStats()
        s.blocksOwned = max(0, s.blocksOwned - 1)
        factionStats[faction] = s
        // Trigger @Published update
        self.factionStats = self.factionStats
    }
    
    func incrementUnitsOwned(for faction: Faction) {
        var s = factionStats[faction] ?? FactionStats()
        s.unitsOwned += 1
        factionStats[faction] = s
        // Trigger @Published update
        self.factionStats = self.factionStats
    }
    
    func decrementUnitsOwned(for faction: Faction) {
        var s = factionStats[faction] ?? FactionStats()
        s.unitsOwned = max(0, s.unitsOwned - 1)
        factionStats[faction] = s
        // Trigger @Published update
        self.factionStats = self.factionStats
    }
    
    func addResourcesCollected(for faction: Faction, amount: Int) {
        var s = factionStats[faction] ?? FactionStats()
        s.resourcesCollected += amount
        factionStats[faction] = s
        // Trigger @Published update
        self.factionStats = self.factionStats
    }
    
    func incrementBlocksDestroyed(for faction: Faction) {
        var s = factionStats[faction] ?? FactionStats()
        s.blocksDestroyed += 1
        factionStats[faction] = s
        // Trigger @Published update
        self.factionStats = self.factionStats
    }
    
    func incrementUnitsDestroyed(for faction: Faction) {
        var s = factionStats[faction] ?? FactionStats()
        s.unitsDestroyed += 1
        factionStats[faction] = s
        // Trigger @Published update
        self.factionStats = self.factionStats
    }
    
    func getStats(for faction: Faction) -> FactionStats {
        return factionStats[faction] ?? FactionStats()
    }
}

// MARK: - Faction UI Components

struct FactionIndicatorView: View {
    let faction: Faction
    let size: CGFloat
    
    var body: some View {
        ZStack {
            // Faction color background
            Circle()
                .fill(faction.primaryColor)
                .frame(width: size, height: size)
            
            // Faction symbol/initial
            Text(String(faction.displayName.prefix(1)))
                .font(.system(size: size * 0.6, weight: .bold))
                .foregroundColor(.white)
        }
        .overlay(
            Circle()
                .stroke(faction.secondaryColor, lineWidth: 2)
        )
    }
}

struct FactionRelationView: View {
    let fromFaction: Faction
    let toFaction: Faction
    
    private var relation: FactionRelation {
        FactionManager.shared.getRelation(from: fromFaction, to: toFaction)
    }
    
    var body: some View {
        HStack(spacing: 8) {
            FactionIndicatorView(faction: fromFaction, size: 24)
            
            Image(systemName: relationIcon)
                .foregroundColor(relation.color)
                .font(.system(size: 16, weight: .bold))
            
            FactionIndicatorView(faction: toFaction, size: 24)
            
            Text(relation.displayName)
                .font(.caption)
                .foregroundColor(relation.color)
        }
        .padding(8)
        .background(Color.black.opacity(0.7))
        .cornerRadius(8)
    }
    
    private var relationIcon: String {
        switch relation {
        case .allied: return "heart.fill"
        case .neutral: return "minus.circle.fill"
        case .enemy: return "xmark.circle.fill"
        }
    }
}

struct FactionStatsView: View {
    @ObservedObject var factionManager = FactionManager.shared
    let faction: Faction
    
    private var stats: FactionManager.FactionStats {
        factionManager.getStats(for: faction)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                FactionIndicatorView(faction: faction, size: 32)
                Text(faction.displayName)
                    .font(.headline)
                    .foregroundColor(.white)
            }
            
            Group {
                statRow(icon: "building.2.fill", label: "Blocks", value: stats.blocksOwned)
                statRow(icon: "person.3.fill", label: "Units", value: stats.unitsOwned)
                statRow(icon: "cube.box.fill", label: "Resources", value: stats.resourcesCollected)
                statRow(icon: "hammer.fill", label: "Destroyed", value: stats.blocksDestroyed)
                statRow(icon: "xmark.circle.fill", label: "Units Lost", value: stats.unitsDestroyed)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(faction.primaryColor.opacity(0.2))
                .stroke(faction.primaryColor, lineWidth: 2)
        )
    }
    
    private func statRow(icon: String, label: String, value: Int) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(faction.secondaryColor)
                .frame(width: 16)
            
            Text(label)
                .foregroundColor(.gray)
                .font(.caption)
            
            Spacer()
            
            Text("\(value)")
                .foregroundColor(.white)
                .font(.caption)
                .fontWeight(.medium)
        }
    }
}

struct FactionOverviewView: View {
    @ObservedObject var factionManager = FactionManager.shared
    @Binding var isShowing: Bool
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.8)
                .ignoresSafeArea()
                .onTapGesture {
                    isShowing = false
                }
            
            ScrollView {
                VStack(spacing: 20) {
                    // Header
                    HStack {
                        Text("Faction Overview")
                            .font(.title)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                        
                        Spacer()
                        
                        Button("Close") {
                            isShowing = false
                        }
                        .foregroundColor(.orange)
                    }
                    .padding()
                    
                    // Player faction stats
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your Faction")
                            .font(.headline)
                            .foregroundColor(.white)
                        
                        FactionStatsView(faction: factionManager.playerFaction)
                    }
                    
                    // Other factions
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Other Factions")
                            .font(.headline)
                            .foregroundColor(.white)
                        
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250))], spacing: 12) {
                            ForEach(Faction.allCases.filter { $0 != factionManager.playerFaction }, id: \.self) { faction in
                                FactionStatsView(faction: faction)
                            }
                        }
                    }
                    
                    // Relations
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Diplomatic Relations")
                            .font(.headline)
                            .foregroundColor(.white)
                        
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200))], spacing: 8) {
                            ForEach(Faction.allCases.filter { $0 != factionManager.playerFaction }, id: \.self) { faction in
                                FactionRelationView(
                                    fromFaction: factionManager.playerFaction,
                                    toFaction: faction
                                )
                            }
                        }
                    }
                }
                .padding()
            }
            .frame(maxWidth: 800, maxHeight: 600)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.black.opacity(0.9))
                    .stroke(Color.orange, lineWidth: 2)
            )
        }
    }
}

// MARK: - Faction-Aware Block Visual Updates

struct FactionBlockIndicator: View {
    let faction: Faction
    let isActive: Bool
    
    var body: some View {
        HStack(spacing: 2) {
            // Faction indicator
            Circle()
                .fill(faction.primaryColor)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .stroke(faction.secondaryColor, lineWidth: 1)
                )
            
            // Status indicator
            if isActive {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(2)
        .background(Color.black.opacity(0.7))
        .cornerRadius(4)
    }
}

// MARK: - Extensions for Turret Targeting

extension TransmissionNetworkManager {
    func findEnemyUnitsInRange(of turretNodeId: UUID, range: CGFloat) -> [UUID] {
        // Placeholder for finding enemy units
        // Would return IDs of enemy units within range
        return []
    }
}

#Preview {
    let mapFileURL = Bundle.main.mapFileURL(named: "Terrain_SG")!
    GameView(fileURL: mapFileURL, onReturnToSectorMap: nil)
        .environmentObject(GlobalHoverObserver())
        .ignoresSafeArea()
}
