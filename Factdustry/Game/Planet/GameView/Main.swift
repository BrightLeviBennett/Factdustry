//
//  Main.swift
//  Factdustry
//
//  Created by Bright on 6/13/25.
//

import SwiftUI
import UIKit
import Combine
import SwiftData

class RightClickGestureView: UIView {
    var onLeftDragStart: ((CGPoint) -> Void)?
    var onLeftDragChanged: ((CGPoint) -> Void)?
    var onLeftDragEnd: (() -> Void)?
    var onRightDragStart: ((CGPoint) -> Void)?
    var onRightDragChanged: ((CGPoint) -> Void)?
    var onRightDragEnd: (() -> Void)?
    var onLeftTap: ((CGPoint) -> Void)?
    var onRightTap: ((CGPoint) -> Void)?
    
    var isLeftDragging = false
    var isRightDragging = false
    var dragStartPoint: CGPoint?
    var currentTouches: Set<UITouch> = []
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupGestures()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupGestures()
    }
    
    func setupGestures() {
        // Enable multiple touch for two-finger gestures
        self.isMultipleTouchEnabled = true
        
        // Long press gesture for right-click simulation on touch devices
        let longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPressGesture.minimumPressDuration = 0.5
        addGestureRecognizer(longPressGesture)
    }
    
    // Handle touches directly for better control
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        currentTouches = touches
        
        guard let touch = touches.first else { return }
        let location = touch.location(in: self)
        
        #if targetEnvironment(macCatalyst)
        // On Mac, check for right mouse button
        if touch.type == .indirectPointer {
            // Check if it's a secondary click (right-click)
            if event?.buttonMask.contains(.secondary) == true {
                isRightDragging = true
                onRightDragStart?(location)
            } else {
                isLeftDragging = true
                onLeftDragStart?(location)
            }
        } else {
            // Direct touch on Mac with touchscreen
            handleTouchDevice(touches: touches, location: location, isStart: true)
        }
        #else
        // iOS/iPadOS
        handleTouchDevice(touches: touches, location: location, isStart: true)
        #endif
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        
        guard let touch = touches.first else { return }
        let location = touch.location(in: self)
        
        if isRightDragging {
            onRightDragChanged?(location)
        } else if isLeftDragging {
            onLeftDragChanged?(location)
        }
    }
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        
        guard let touch = touches.first else { return }
        let location = touch.location(in: self)
        
        // Check if it was a tap (not a drag)
        if !isLeftDragging && !isRightDragging {
            #if targetEnvironment(macCatalyst)
            if touch.type == .indirectPointer && event?.buttonMask.contains(.secondary) == true {
                onRightTap?(location)
            } else {
                onLeftTap?(location)
            }
            #else
            // On iOS, single tap is left click
            if touches.count == 1 {
                onLeftTap?(location)
            }
            #endif
        }
        
        // End any active drags
        if isRightDragging {
            onRightDragEnd?()
            isRightDragging = false
        } else if isLeftDragging {
            onLeftDragEnd?()
            isLeftDragging = false
        }
        
        currentTouches.removeAll()
    }
    
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        
        if isRightDragging {
            onRightDragEnd?()
            isRightDragging = false
        } else if isLeftDragging {
            onLeftDragEnd?()
            isLeftDragging = false
        }
        
        currentTouches.removeAll()
    }
    
    // Handle touch devices (iOS/iPadOS or Mac with touchscreen)
    func handleTouchDevice(touches: Set<UITouch>, location: CGPoint, isStart: Bool) {
        if touches.count >= 2 {
            // Two-finger touch acts as right-click
            if isStart {
                isRightDragging = true
                onRightDragStart?(location)
            }
        } else {
            // Single finger is left-click
            if isStart {
                isLeftDragging = true
                onLeftDragStart?(location)
            }
        }
    }
    
    // Long press for right-click on touch devices
    @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        let location = gesture.location(in: self)
        
        switch gesture.state {
        case .began:
            // Cancel any left drag that might be in progress
            if isLeftDragging {
                onLeftDragEnd?()
                isLeftDragging = false
            }
            
            // Start right drag
            isRightDragging = true
            onRightDragStart?(location)
            
        case .changed:
            if isRightDragging {
                onRightDragChanged?(location)
            }
            
        case .ended, .cancelled:
            if isRightDragging {
                onRightDragEnd?()
                isRightDragging = false
            }
            
        default:
            break
        }
    }
}

extension RightClickGestureView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}

struct GameView: View {
    @EnvironmentObject var hoverObserver: GlobalHoverObserver
    @ObservedObject var researchManager = ResearchManager.shared
    @StateObject var rotationController = RotationController()
    @StateObject var blockManager: BlockLoadingManager
    @StateObject var cameraController = CameraController()
    @StateObject var miningManager = OreMiningManager()
    @State var selectedCategory: BlockCategory = .core
    @State var selectedBlock: BlockType? = nil
    @State var pressedKeys: Set<String> = []
    @State var hoverTileCoordinates: (x: Int, y: Int)? = nil
    @State var isHoverColliding: Bool = false
    @State var hoverCollisionReason: String? = nil
    @State var mapViewFrame: CGRect = .zero
    @State var cachedMapData: MapData? = nil
    @State var windowSetupComplete = false
    @State var showResearchUI = false
    @State var isDragging = false
    @State var dragStartCoordinates: (x: Int, y: Int)? = nil
    @State var linePlacementPoints: [(x: Int, y: Int)] = []
    @State var linePlacementCollisions: [Bool] = []
    @State var isSelectionDragging = false
    @State var selectionStartPoint: CGPoint = .zero
    @State var selectionEndPoint: CGPoint = .zero
    @State var selectionRectangle: CGRect = .zero
    @State var selectedBlocksForDeletion: Set<UUID> = []
    @State var isShiftPressed = false  // Track shift key state
    @State var respawnShardling = false
    
    var fileURL: URL
    let onReturnToSectorMap: (() -> Void)? // ADD THIS LINE
    
    var fileIdentifier: String {
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        if fileName.hasPrefix("Terrain_") {
            return String(fileName.dropFirst("Terrain_".count))
        }
        return ""
    }
        
    var normalizedSelectionRect: CGRect {
        let minX = min(selectionStartPoint.x, selectionEndPoint.x)
        let minY = min(selectionStartPoint.y, selectionEndPoint.y)
        let width = abs(selectionEndPoint.x - selectionStartPoint.x)
        let height = abs(selectionEndPoint.y - selectionStartPoint.y)
        return CGRect(x: minX, y: minY, width: width, height: height)
    }
    
    static let enhancedBlockLibrary: [BlockCategory: [BlockType]] = [
        .core: [
            BlockType(
                iconName: "core-shard",
                size: 100,
                sizeX: 2,
                sizeY: 2,
                buildCost: [(.copper, 500), (.graphite, 500), (.silicon, 300)],
                buildTime: 10.0,
                tileRequirement: .requiresFloor(),
                canRotate: false,
                connections: [
                    UniversalConnection(
                        direction: .north,
                        connectionTypes: [.itemInput(nil)],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 200,
                            priority: 10,
                            bufferSize: 0
                        )
                    ),
                    UniversalConnection(
                        direction: .west,
                        connectionTypes: [.itemInput(nil)],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 200,
                            priority: 10,
                            bufferSize: 0
                        )
                    ),
                    UniversalConnection(
                        direction: .east,
                        connectionTypes: [.itemInput(nil)],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 200,
                            priority: 10,
                            bufferSize: 0
                        )
                    ),
                    UniversalConnection(
                        direction: .south,
                        connectionTypes: [.itemInput(nil)],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 200,
                            priority: 10,
                            bufferSize: 0
                        )
                    ),
                ]
            )
        ],
        .production: [
            BlockType(
                iconName: "mechanical-drill",
                size: 135,
                sizeX: 2,
                sizeY: 2,
                buildCost: [(.copper, 10)],
                buildTime: 10.0,
                processes: [
                    Process(time: 2.0, inputPower: 20, outputItems: [.copper: 1])
                ],
                tileRequirement: .requiresOreInFront(),
                canRotate: true,
                textureOffset: CGPoint(x: -2, y: -8),
                connections: [
                    UniversalConnection(
                        direction: .south,
                        connectionTypes: [.powerInput(.rotational), .itemOutput([.copper])],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 30,
                            priority: 5,
                            bufferSize: 0
                        )
                    ),
                    UniversalConnection(
                        direction: .east,
                        connectionTypes: [.powerInput(.rotational), .itemOutput([.copper])],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 30,
                            priority: 5,
                            bufferSize: 0
                        )
                    ),
                    UniversalConnection(
                        direction: .west,
                        connectionTypes: [.powerInput(.rotational), .itemOutput([.copper])],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 30,
                            priority: 5,
                            bufferSize: 0
                        )
                    ),
                    UniversalConnection(
                        direction: .north,
                        connectionTypes: [.powerInput(.rotational), .itemOutput([.copper])],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 10,
                            priority: 8,
                            bufferSize: 5
                        )
                    )
                ]
            ),
            BlockType(
                iconName: "plasma-bore",
                size: 80,
                sizeX: 2,
                sizeY: 2,
                buildCost: [(.silicon, 50), (.graphite, 40)],
                buildTime: 8.0,
                processes: [
                    Process(time: 1.5, inputPower: 35, outputItems: [.copper: 1, .graphite: 1])
                ],
                tileRequirement: .requiresOreInFront(oreTypes: [.copper, .graphite]),
                canRotate: true,
                connections: [
                    UniversalConnection(
                        direction: .south,
                        connectionTypes: [.powerInput(.rotational)],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 50,
                            priority: 5,
                            bufferSize: 0
                        )
                    ),
                    UniversalConnection(
                        direction: .north,
                        connectionTypes: [.itemOutput([.copper, .graphite])],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 15,
                            priority: 8,
                            bufferSize: 10
                        )
                    )
                ]
            ),
            BlockType(
                iconName: "advanced-plasma-bore",
                size: 120,
                sizeX: 3,
                sizeY: 3,
                buildCost: [(.silicon, 100), (.steel, 80), (.graphite, 60)],
                buildTime: 15.0,
                processes: [
                    Process(time: 1.0, inputPower: 50, outputItems: [.copper: 2, .graphite: 2])
                ],
                tileRequirement: .requiresOreInFront(oreTypes: [.copper, .graphite]),
                canRotate: true,
                connections: [
                    UniversalConnection(
                        direction: .south,
                        connectionTypes: [.powerInput(.rotational)],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 75,
                            priority: 5,
                            bufferSize: 0
                        )
                    ),
                    UniversalConnection(
                        direction: .north,
                        connectionTypes: [.itemOutput([.copper, .graphite])],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 20,
                            priority: 8,
                            bufferSize: 15
                        )
                    )
                ]
            ),
            BlockType(
                iconName: "mineral-extractor",
                size: 120,
                sizeX: 3,
                sizeY: 3,
                buildCost: [(.copper, 120), (.silicon, 80), (.graphite, 100)],
                buildTime: 20.0,
                tileRequirement: .requiresCenterOnVentOrGeyser(),
                canRotate: false
            )
        ],
        .distribution: [
            BlockType(
                iconName: "conveyor-belt",
                size: 40,
                buildCost: [(.copper, 1)],
                buildTime: 0.5,
                tileRequirement: .requiresFloor(),
                canRotate: true,
                connections: [
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
                    ),
                ],
                capacity: 1
            ),
            
            BlockType(
                iconName: "belt-bridge",
                size: 80,
                buildCost: [(.copper, 10)],
                buildTime: 1.0,
                tileRequirement: .requiresFloor(),
                canRotate: true,
                textureOffset: CGPoint(x: 0, y: -12),
                connections: [
                    UniversalConnection(
                        direction: .south,
                        connectionTypes: [.itemInput(nil)],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 25,
                            priority: 5,
                            bufferSize: 5
                        )
                    ),
                    UniversalConnection(
                        direction: .north,
                        connectionTypes: [.itemOutput(nil)],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 25,
                            priority: 5,
                            bufferSize: 0
                        )
                    )
                ]
            ),
            BlockType(
                iconName: "belt-router",
                size: 40,
                buildCost: [(.copper, 5)],
                buildTime: 0.8,
                tileRequirement: .requiresFloor(),
                canRotate: true,
                connections: [
                    UniversalConnection(
                        direction: .south,
                        connectionTypes: [.itemInput(nil)],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 30,
                            priority: 5,
                            bufferSize: 5
                        )
                    ),
                    UniversalConnection(
                        direction: .north,
                        connectionTypes: [.itemOutput(nil)],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 30,
                            priority: 8,
                            bufferSize: 0
                        )
                    ),
                    UniversalConnection(
                        direction: .east,
                        connectionTypes: [.itemOutput(nil)],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 30,
                            priority: 6,
                            bufferSize: 0
                        )
                    ),
                    UniversalConnection(
                        direction: .west,
                        connectionTypes: [.itemOutput(nil)],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 30,
                            priority: 6,
                            bufferSize: 0
                        )
                    )
                ]
            ),
            BlockType(
                iconName: "belt-junction",
                size: 40,
                buildCost: [(.copper, 5)],
                buildTime: 0.6,
                tileRequirement: .requiresFloor(),
                canRotate: true,
                connections: [
                    UniversalConnection(
                        direction: .north,
                        connectionTypes: [.itemInput(nil), .itemOutput(nil)],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 40,
                            priority: 5,
                            bufferSize: 3
                        )
                    ),
                    UniversalConnection(
                        direction: .south,
                        connectionTypes: [.itemInput(nil), .itemOutput(nil)],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 40,
                            priority: 5,
                            bufferSize: 3
                        )
                    ),
                    UniversalConnection(
                        direction: .east,
                        connectionTypes: [.itemInput(nil), .itemOutput(nil)],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 40,
                            priority: 5,
                            bufferSize: 3
                        )
                    ),
                    UniversalConnection(
                        direction: .west,
                        connectionTypes: [.itemInput(nil), .itemOutput(nil)],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 40,
                            priority: 5,
                            bufferSize: 3
                        )
                    )
                ]
            )
        ],
        .defense: [
            BlockType(
                iconName: "shield.fill",
                size: 26,
                buildCost: [(.copper, 5)],
                buildTime: 2.0,
                tileRequirement: .requiresFloor(),
                canRotate: false
            ),
            BlockType(
                iconName: "lock.shield.fill",
                size: 24,
                buildCost: [(.steel, 15), (.silicon, 8)],
                buildTime: 4.0,
                tileRequirement: .requiresFloor(),
                canRotate: false
            )
        ],
        .turets: [
            BlockType(
                iconName: "single-barrel",
                size: 80,
                sizeX: 2,
                sizeY: 2,
                buildCost: [(.copper, 30), (.graphite, 30), (.silicon, 15)],
                buildTime: 5.0,
                tileRequirement: .requiresFloor(),
                canRotate: true,
                connections: [
                    UniversalConnection(
                        direction: .south,
                        connectionTypes: [.itemInput([.copper, .graphite])],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 5,
                            priority: 7,
                            bufferSize: 10
                        )
                    )
                ]
            ),
            BlockType(
                iconName: "double-barrel",
                size: 80,
                sizeX: 2,
                sizeY: 2,
                buildCost: [(.copper, 40), (.graphite, 45), (.silicon, 25), (.iron, 10)],
                buildTime: 8.0,
                tileRequirement: .requiresFloor(),
                canRotate: true,
                connections: [
                    UniversalConnection(
                        direction: .south,
                        connectionTypes: [.itemInput([.copper, .graphite, .iron])],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 8,
                            priority: 7,
                            bufferSize: 15
                        )
                    )
                ]
            )
        ],
        .power: [
            BlockType(
                iconName: "steam-engine",
                size: 170,
                sizeX: 3,
                sizeY: 3,
                buildCost: [(.copper, 50)],
                buildTime: 12.0,
                processes: [
                    Process(time: 1.0, outputPower: 100)
                ],
                tileRequirement: .requiresCenterOnVent(),
                canRotate: true,
                connections: [
                    UniversalConnection(
                        direction: .north,
                        connectionTypes: [.powerOutput(.rotational)],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 100,
                            priority: 10,
                            bufferSize: 0
                        )
                    ),
                    UniversalConnection(
                        direction: .south,
                        connectionTypes: [.powerOutput(.rotational)],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 100,
                            priority: 10,
                            bufferSize: 0
                        )
                    ),
                    UniversalConnection(
                        direction: .east,
                        connectionTypes: [.powerOutput(.rotational)],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 100,
                            priority: 10,
                            bufferSize: 0
                        )
                    ),
                    UniversalConnection(
                        direction: .west,
                        connectionTypes: [.powerOutput(.rotational)],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 100,
                            priority: 10,
                            bufferSize: 0
                        )
                    )
                ]
            ),
            BlockType(
                iconName: "shaft",
                size: 55,
                buildCost: [(.copper, 5)],
                buildTime: 1.0,
                tileRequirement: .requiresFloor(),
                canRotate: true,
                connections: [
                    UniversalConnection(
                        direction: .west,
                        connectionTypes: [.powerOutput(.rotational), .powerInput(.rotational)],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 200,
                            priority: 5,
                            bufferSize: 0
                        )
                    ),
                    UniversalConnection(
                        direction: .east,
                        connectionTypes: [.powerOutput(.rotational), .powerInput(.rotational)],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 200,
                            priority: 5,
                            bufferSize: 0
                        )
                    )
                ]
            ),
            BlockType(
                iconName: "gearbox",
                size: 40,
                buildCost: [(.copper, 14)],
                buildTime: 2.0,
                tileRequirement: .requiresFloor(),
                canRotate: false,
                connections: [
                    UniversalConnection(
                        direction: .north,
                        connectionTypes: [.powerInput(.rotational), .powerOutput(.rotational)],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 150,
                            priority: 5,
                            bufferSize: 0
                        )
                    ),
                    UniversalConnection(
                        direction: .south,
                        connectionTypes: [.powerInput(.rotational), .powerOutput(.rotational)],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 150,
                            priority: 5,
                            bufferSize: 0
                        )
                    ),
                    UniversalConnection(
                        direction: .east,
                        connectionTypes: [.powerInput(.rotational), .powerOutput(.rotational)],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 150,
                            priority: 5,
                            bufferSize: 0
                        )
                    ),
                    UniversalConnection(
                        direction: .west,
                        connectionTypes: [.powerInput(.rotational), .powerOutput(.rotational)],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 150,
                            priority: 5,
                            bufferSize: 0
                        )
                    )
                ]
            )
        ],
        .factory: [
            BlockType(
                iconName: "silicon-mixer",
                size: 120,
                sizeX: 3,
                sizeY: 3,
                buildCost: [(.copper, 40), (.graphite, 30)],
                buildTime: 10.0,
                processes: [
                    Process(time: 2.0, inputItems: [.copper: 2, .graphite: 1], inputPower: 25, outputItems: [.silicon: 1])
                ],
                tileRequirement: .advancedFactoryRequirement(),
                canRotate: true,
                connections: [
                    UniversalConnection(
                        direction: .west,
                        connectionTypes: [.powerInput(.rotational)],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 30,
                            priority: 5,
                            bufferSize: 0
                        )
                    ),
                    UniversalConnection(
                        direction: .south,
                        connectionTypes: [.itemInput([.copper])],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 10,
                            priority: 7,
                            bufferSize: 20
                        )
                    ),
                    UniversalConnection(
                        direction: .east,
                        connectionTypes: [.itemInput([.graphite])],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 10,
                            priority: 7,
                            bufferSize: 20
                        )
                    ),
                    UniversalConnection(
                        direction: .north,
                        connectionTypes: [.itemOutput([.silicon])],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 5,
                            priority: 8,
                            bufferSize: 10
                        )
                    )
                ]
            )
        ],
        .fluids: [],
        .units: [
            BlockType(
                iconName: "tank-fabricator",
                size: 120,
                sizeX: 3,
                sizeY: 3,
                buildCost: [(.copper, 50), (.graphite, 40), (.silicon, 25)],
                buildTime: 8.0,
                processes: [
                    Process(time: 3.0, inputItems: [.copper: 10], outputItems: [:]) // Custom unit production
                ],
                tileRequirement: .requiresFloor(),
                canRotate: true,
                connections: [
                    UniversalConnection(
                        direction: .south,
                        connectionTypes: [.itemInput([.copper]), .powerInput(.rotational)],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 10,
                            priority: 7,
                            bufferSize: 50
                        )
                    ),
                    UniversalConnection(
                        direction: .east,
                        connectionTypes: [.itemInput([.copper]), .powerInput(.rotational)],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 10,
                            priority: 7,
                            bufferSize: 50
                        )
                    ),
                    UniversalConnection(
                        direction: .west,
                        connectionTypes: [.itemInput([.copper]), .powerInput(.rotational)],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 10,
                            priority: 7,
                            bufferSize: 50
                        )
                    ),
                    UniversalConnection(
                        direction: .north,
                        connectionTypes: [.itemInput([.copper]), .powerInput(.rotational)],
                        constraints: UniversalConnection.ConnectionConstraints(
                            maxThroughput: 10,
                            priority: 7,
                            bufferSize: 50
                        )
                    )
                ],
                capacity: 100
            ),
        ],
        .payloads: []
    ]
    
    init(fileURL: URL, onReturnToSectorMap: (() -> Void)? = nil) {
        self.fileURL = fileURL
        self.onReturnToSectorMap = onReturnToSectorMap // ADD THIS LINE
        self._blockManager = StateObject(wrappedValue: BlockLoadingManager(blockLibrary: GameView.enhancedBlockLibrary))
    }
    var body: some View {
        AnyView(mainBody)
    }
    
    @State var showFactionOverview = false
    
    @ViewBuilder
    private var mainBody: some View {
        ZStack {
            ZStack {
                WindowAccessor { window in
                    if !windowSetupComplete {
                        setupWindowAndKeyboard(window: window)
                        windowSetupComplete = true
                    }
                }
                .frame(width: 0, height: 0)
                .opacity(0)
                
                // UPDATED: Use enhanced map view with SpriteKit overlay for units
                SKEnhancedMapView(
                    fileURL: fileURL,
                    cameraController: cameraController,
                    placedBlocks: blockManager.placedBlocks,
                    onMapTap: handleMapTap,
                    onDragStart: { location, mapData in
                        // Check if shift is pressed for selection mode
                        if isShiftPressed {
                            handleSelectionDragStart(at: location)
                        } else {
                            handleDragStart(at: location, mapData)
                        }
                    },
                    onDragChanged: { location in
                        if isSelectionDragging {
                            if let mapData = cachedMapData {
                                handleSelectionDragChanged(at: location, mapData: mapData)
                            }
                        } else {
                            updateHoverPreview(at: location)
                        }
                    },
                    onDragEnd: { mapData in
                        if isSelectionDragging {
                            handleSelectionDragEnd(mapData: mapData)
                        } else {
                            handleDragEnd(mapData)
                        }
                    },
                    linePlacementPoints: linePlacementPoints,
                        linePlacementCollisions: linePlacementCollisions,
                        selectedBlock: selectedBlock,
                        selectedBlockRotation: rotationController.selectedBlockRotation,
                        hoverTileCoordinates: hoverTileCoordinates,
                        isHoverColliding: isHoverColliding,
                        blockLibrary: GameView.enhancedBlockLibrary,
                        transmissionManager: blockManager.networkManager,
                        blockManager: blockManager,
                        mapViewFrame: $mapViewFrame,
                        respawnTrigger: $respawnShardling
                    )
                .onChange(of: respawnShardling) {
                    if respawnShardling {
                        // Reset the trigger after a short delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            respawnShardling = false
                        }
                    }
                }
                .overlay(
                    // Selection rectangle overlay
                    Group {
                        if isSelectionDragging {
                            SelectionRectangleView(
                                rect: normalizedSelectionRect,
                                selectedBlocks: selectedBlocksForDeletion,
                                placedBlocks: blockManager.placedBlocks,
                                cameraController: cameraController,
                                tileSize: 32
                            )
                        }
                    }
                )
                
                // Mining effects overlay (keep this for mining visual feedback)
                MiningEffectsView(miningManager: miningManager, tileSize: 32)
                    .allowsHitTesting(false)
                
                if blockManager.isLoading {
                    VStack {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .orange))
                        Text("Loading blocks...")
                            .foregroundColor(.orange)
                            .font(.caption)
                    }
                    .padding()
                    .background(Color.black.opacity(0.8))
                    .cornerRadius(8)
                }
                
                if let error = blockManager.loadingError {
                    VStack {
                        Text("Block Loading Error")
                            .foregroundColor(.red)
                            .font(.headline)
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .background(Color.black.opacity(0.8))
                    .cornerRadius(8)
                }
                
                CoreInventoryDisplay()
                    .offset(x: 0, y: -450)
                
                VStack {
                    HStack {
                        Spacer()
                        VStack(alignment: .trailing, spacing: 8) {
                            NetworkStatsView(networkManager: blockManager.networkManager)
                            
                            // Mining operations display
                            VStack(alignment: .trailing, spacing: 4) {
                                HStack(spacing: 4) {
                                    Image(systemName: "hammer.fill")
                                        .foregroundColor(.yellow)
                                    Text("Mining: \(miningManager.activeMiningOperations.count)")
                                        .font(.caption)
                                        .foregroundColor(.white)
                                }
                                
                                ForEach(Array(miningManager.activeMiningOperations.values.prefix(3)), id: \.id) { operation in
                                    HStack(spacing: 4) {
                                        Text("\(operation.oreType.displayName):")
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                        Text("\(operation.totalMined)")
                                            .font(.caption2)
                                            .foregroundColor(.yellow)
                                    }
                                }
                                
                                if miningManager.activeMiningOperations.count > 3 {
                                    Text("+ \(miningManager.activeMiningOperations.count - 3) more")
                                        .font(.caption2)
                                        .foregroundColor(.gray)
                                        .italic()
                                }
                            }
                            .padding(8)
                            .background(Color.black.opacity(0.8))
                            .cornerRadius(6)
                        }
                    }
                    Spacer()
                }
                
                VStack {
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            Button(action: {
                                researchManager.toggleResearchRequirement()
                            }) {
                                HStack(spacing: 8) {
                                    Image(systemName: researchManager.requireResearchForPlacement ? "checkmark.square.fill" : "square")
                                        .foregroundColor(researchManager.requireResearchForPlacement ? .green : .gray)
                                    Text("Require Research for Placement")
                                        .foregroundColor(.white)
                                        .font(.caption)
                                }
                                .padding(8)
                                .background(Color.black.opacity(0.8))
                                .cornerRadius(6)
                            }
                        }
                        
                        // NEW: Faction overview button
                        Button(action: {
                            showFactionOverview.toggle()
                        }) {
                            HStack(spacing: 8) {
                                FactionIndicatorView(faction: FactionManager.shared.playerFaction, size: 24)
                                Text("Faction Overview")
                                    .foregroundColor(.white)
                                    .font(.caption)
                            }
                            .padding(8)
                            .background(Color.black.opacity(0.8))
                            .cornerRadius(6)
                        }
                        
                        Spacer()
                    }
                    .padding(.leading, 20)
                    .padding(.top, 80)
                    Spacer()
                }
                
                if showFactionOverview {
                    FactionOverviewView(isShowing: $showFactionOverview)
                }
                
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        UpdatedEnhancedBlockSelectionPanel(
                            selectedCategory: $selectedCategory,
                            selectedBlock: $selectedBlock,
                            blockLibrary: GameView.enhancedBlockLibrary,
                            researchManager: researchManager,
                            showResearchUI: $showResearchUI,
                            onReturnToSectorMap: onReturnToSectorMap
                        )
                    }
                }
                
                KeyboardHandler(
                    onKeyDown: { key in
                        handleKeyDown(key)
                    },
                    onKeyUp: { key in
                        handleKeyUp(key)
                    }
                )
                .frame(width: 0, height: 0)
                .opacity(0)
            }
            .onAppear {
                blockManager.loadBlocksFromCoreSchema(fileIdentifier: fileIdentifier)
                cachedMapData = try? MapData.fromJSONFile(at: fileURL)
            }
            .onChange(of: fileURL) {
                blockManager.loadBlocksFromCoreSchema(fileIdentifier: fileIdentifier)
                cachedMapData = try? MapData.fromJSONFile(at: fileURL)
            }
            .onChange(of: selectedBlock) {
                if selectedBlock != nil {
                    rotationController.resetRotation()
                } else {
                    hoverTileCoordinates = nil
                    isHoverColliding = false
                    hoverCollisionReason = nil
                    rotationController.resetRotation()
                }
            }
            .onChange(of: hoverObserver.location) {
                updateHoverPreview(at: hoverObserver.location)
            }
            .onChange(of: hoverObserver.isHovering) {
                if !hoverObserver.isHovering {
                    hoverTileCoordinates = nil
                    isHoverColliding = false
                    hoverCollisionReason = nil
                }
            }
            .onChange(of: rotationController.selectedBlockRotation) {
                if hoverObserver.isHovering {
                    updateHoverPreview(at: hoverObserver.location)
                }
            }
            .onAppear {
                loadSector()
            }
            .onChange(of: fileURL) {
                loadSector()
            }
            
            if showResearchUI {
                MindustryTechTreeView(
                    viewModel: researchManager.techTreeViewModel,
                    isShowingTechTree: $showResearchUI
                )
            }
            
            // REMOVED: Static Shardling image - now handled by SpriteKit scene
            // The shardling will automatically spawn on top of the core via the SpriteKit overlay
        }
    }

    
    func loadSector() {
        blockManager.loadBlocksFromCoreSchema(fileIdentifier: fileIdentifier)
        
        // Load map data and apply core loadout if this is a fresh sector
        if let mapData = try? MapData.fromJSONFile(at: fileURL) {
            cachedMapData = mapData
            
            // Apply initial core loadout if this is a fresh sector
            if CoreInventoryManager.shared.isFreshSector {
                let loadout = mapData.getCoreLoadoutAsItemTypes()
                if !loadout.isEmpty {
                    CoreInventoryManager.shared.setInitialLoadout(loadout)
                }
            }
            
            // Auto-center camera on core after loading
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let corePosition = blockManager.findCorePosition() {
                    cameraController.centerOnPosition(
                        worldPosition: corePosition,
                        viewSize: CGSize(width: mapViewFrame.width, height: mapViewFrame.height)
                    )
                    print("📷 Auto-centered camera on core")
                }
            }
        } else {
            cachedMapData = try? MapData.fromJSONFile(at: fileURL)
        }
    }
    
    func handleSelectionDragStart(at location: CGPoint) {
        isSelectionDragging = true
        selectionStartPoint = location
        selectionEndPoint = location
        selectedBlocksForDeletion.removeAll()
    }

    func handleSelectionDragChanged(at location: CGPoint, mapData: MapData) {
        guard isSelectionDragging else { return }
        
        selectionEndPoint = location
        updateSelectedBlocks(mapData: mapData)
    }

    func handleSelectionDragEnd(mapData: MapData) {
        guard isSelectionDragging else { return }
        
        // Remove all selected blocks
        for blockId in selectedBlocksForDeletion {
            if let block = blockManager.placedBlocks.first(where: { $0.id == blockId }) {
                blockManager.startDestruction(at: (x: block.x, y: block.y))
            }
        }
        
        // Reset selection state
        isSelectionDragging = false
        selectionStartPoint = .zero
        selectionEndPoint = .zero
        selectedBlocksForDeletion.removeAll()
    }

    func updateSelectedBlocks(mapData: MapData) {
        selectedBlocksForDeletion.removeAll()
        
        let rect = normalizedSelectionRect
        
        // Convert screen rectangle to tile coordinates
        let topLeft = cameraController.screenToTileCoordinates(
            screenPoint: CGPoint(x: rect.minX, y: rect.minY),
            mapSize: CGSize(width: mapData.width, height: mapData.height),
            tileSize: 32
        )
        
        let bottomRight = cameraController.screenToTileCoordinates(
            screenPoint: CGPoint(x: rect.maxX, y: rect.maxY),
            mapSize: CGSize(width: mapData.width, height: mapData.height),
            tileSize: 32
        )
        
        // Check each placed block
        for block in blockManager.placedBlocks {
            if let blockType = getBlockType(for: block.iconName) {
                let rotatedSize = blockType.getRotatedSize(rotation: block.rotation)
                
                // Check if any part of the block is within the selection
                let blockMinX = block.x
                let blockMaxX = block.x + rotatedSize.width - 1
                let blockMinY = block.y
                let blockMaxY = block.y + rotatedSize.height - 1
                
                // Check for overlap
                if blockMaxX >= topLeft.x && blockMinX <= bottomRight.x &&
                   blockMaxY >= topLeft.y && blockMinY <= bottomRight.y {
                    selectedBlocksForDeletion.insert(block.id)
                }
            }
        }
    }

    func getBlockType(for iconName: String) -> BlockType? {
        for (_, blocks) in GameView.enhancedBlockLibrary {
            if let block = blocks.first(where: { $0.iconName == iconName }) {
                return block
            }
        }
        return nil
    }
    
    func handleDragStart(at screenPoint: CGPoint, _ mapData: MapData) {
        // Don't start block placement drag if we're in selection mode
        guard !isShiftPressed else {
            handleSelectionDragStart(at: screenPoint)
            return
        }
        
        guard selectedBlock != nil else { return }
        
        let tileCoordinates = cameraController.screenToTileCoordinates(
            screenPoint: screenPoint,
            mapSize: CGSize(width: mapData.width, height: mapData.height),
            tileSize: 32
        )
        
        guard tileCoordinates.x >= 0 && tileCoordinates.x < mapData.width &&
              tileCoordinates.y >= 0 && tileCoordinates.y < mapData.height else {
            return
        }
        
        isDragging = true
        dragStartCoordinates = tileCoordinates
        
        // Initial preview
        updateHoverPreview(at: CGPoint(
            x: screenPoint.x + mapViewFrame.origin.x,
            y: screenPoint.y + mapViewFrame.origin.y
        ))
    }

    func handleDragEnd(_ mapData: MapData) {
        // Handle selection drag end if in selection mode
        if isSelectionDragging {
            handleSelectionDragEnd(mapData: mapData)
            return
        }
        
        defer {
            isDragging = false
            dragStartCoordinates = nil
            linePlacementPoints = []
            linePlacementCollisions = []
        }
        
        guard let selectedBlock = selectedBlock, !linePlacementPoints.isEmpty else { return }
        
        // Use the current rotation from the rotation controller
        let currentRotation = rotationController.selectedBlockRotation
        
        // Place blocks at all valid positions
        for (index, point) in linePlacementPoints.enumerated() {
            if index < linePlacementCollisions.count && linePlacementCollisions[index] {
                continue
            }
            
            blockManager.placeBlockWithResearchCheckAndConstruction(
                selectedBlock,
                at: point,
                rotation: currentRotation,
                mapData: mapData,
                researchManager: researchManager
            )
        }
    }

    
    func generateLine(from start: (x: Int, y: Int), to end: (x: Int, y: Int)) -> (points: [(x: Int, y: Int)], direction: Direction?) {
        // Determine if we should make a horizontal or vertical line
        let dx = abs(end.x - start.x)
        let dy = abs(end.y - start.y)
        
        // Detect dominant direction for auto-rotation
        var direction: Direction? = nil
        if dx > 0 || dy > 0 {
            if dx > dy {
                // Horizontal is dominant
                direction = end.x > start.x ? .east : .west
            } else {
                // Vertical is dominant
                direction = end.y > start.y ? .south : .north
            }
        }
        
        // Generate points for either horizontal or vertical line based on dominant axis
        var points: [(x: Int, y: Int)] = []
        
        if dx > dy {
            // Horizontal line
            let sx = start.x < end.x ? 1 : -1
            var x = start.x
            while true {
                points.append((x: x, y: start.y))
                if x == end.x {
                    break
                }
                x += sx
            }
        } else {
            // Vertical line
            let sy = start.y < end.y ? 1 : -1
            var y = start.y
            while true {
                points.append((x: start.x, y: y))
                if y == end.y {
                    break
                }
                y += sy
            }
        }
        
        return (points, direction)
    }
    
    func tileDistance(from pos1: (x: Int, y: Int), to pos2: (x: Int, y: Int)) -> Double {
        let dx = Double(pos2.x - pos1.x)
        let dy = Double(pos2.y - pos1.y)
        return sqrt(dx * dx + dy * dy)
    }

    /// Get the center of the screen in tile coordinates
    func getScreenCenterInTileCoordinates() -> (x: Int, y: Int) {
        guard let mapData = cachedMapData else { return (0, 0) }
        
        // Get the center of the screen in screen coordinates
        let screenCenter = CGPoint(x: mapViewFrame.width / 2, y: mapViewFrame.height / 2)
        
        // Convert to tile coordinates
        let tileCoords = cameraController.screenToTileCoordinates(
            screenPoint: screenCenter,
            mapSize: CGSize(width: mapData.width, height: mapData.height),
            tileSize: 32
        )
        
        return tileCoords
    }
        
    private func handleMapTap(at screenPoint: CGPoint, _ mapData: MapData) {
        // Convert screen point to tile coordinates
        let tileCoordinates = cameraController.screenToTileCoordinates(
            screenPoint: screenPoint,
            mapSize: CGSize(width: mapData.width, height: mapData.height),
            tileSize: 32
        )
        
        // Debug output
        print("🖱️ Clicked at screen: (\(Int(screenPoint.x)), \(Int(screenPoint.y))) -> tile: (\(tileCoordinates.x), \(tileCoordinates.y))")
        
        guard tileCoordinates.x >= 0 && tileCoordinates.x < mapData.width &&
              tileCoordinates.y >= 0 && tileCoordinates.y < mapData.height else {
            print("❌ Click outside map bounds")
            return
        }
        
        // Get the ore type at the clicked position
        let oreType = mapData.ores[tileCoordinates.y][tileCoordinates.x]
        print("🪨 Ore at clicked position: \(oreType.displayName)")
        
        // Check if clicking on ore for mining
        if oreType != .none {
            let screenCenter = getScreenCenterInTileCoordinates()
            let distance = tileDistance(from: screenCenter, to: tileCoordinates)
            
            print("📏 Distance from screen center (\(screenCenter.x), \(screenCenter.y)) to ore: \(String(format: "%.1f", distance)) tiles")
            
            // Toggle mining at this position
            if miningManager.isMining(at: tileCoordinates) {
                print("🛑 Stopping mining at (\(tileCoordinates.x), \(tileCoordinates.y))")
                miningManager.stopMining(at: tileCoordinates)
            } else {
                print("⛏️ Starting mining at (\(tileCoordinates.x), \(tileCoordinates.y))")
                miningManager.startMining(oreType: oreType, at: tileCoordinates)
            }
            return
        }
        
        // If shift is pressed, handle block deletion
        if isShiftPressed {
            if blockManager.getBlock(at: tileCoordinates) != nil {
                blockManager.removeBlock(at: tileCoordinates)
                print("🗑️ Removed block at (\(tileCoordinates.x), \(tileCoordinates.y))")
            }
            return
        }
        
        // Normal block placement with construction
        if let selectedBlock = selectedBlock {
            print("🏗️ Attempting to place \(selectedBlock.iconName) at (\(tileCoordinates.x), \(tileCoordinates.y))")
            let placementResult = blockManager.placeBlockWithResearchCheckAndConstruction( // Changed method name
                selectedBlock,
                at: tileCoordinates,
                rotation: rotationController.selectedBlockRotation,
                mapData: mapData,
                researchManager: researchManager
            )
            
            if !placementResult.success {
                print("❌ Block placement failed: \(placementResult.reason ?? "Unknown reason")")
            } else {
                print("✅ Construction started successfully")
            }
        } else {
            print("ℹ️ No block selected and no ore to mine")
        }
    }
    
    func updateHoverPreview(at globalLocation: CGPoint) {
        guard let selectedBlock = selectedBlock else {
            hoverTileCoordinates = nil
            isHoverColliding = false
            hoverCollisionReason = nil
            linePlacementPoints = []
            linePlacementCollisions = []
            return
        }
        
        guard hoverObserver.isHovering else {
            if !isDragging {
                hoverTileCoordinates = nil
                isHoverColliding = false
                hoverCollisionReason = nil
                linePlacementPoints = []
                linePlacementCollisions = []
            }
            return
        }
        
        guard let mapData = cachedMapData else {
            guard let mapData = try? MapData.fromJSONFile(at: fileURL) else { return }
            cachedMapData = mapData
            return
        }
        
        guard mapViewFrame.contains(globalLocation) else {
            if !isDragging {
                hoverTileCoordinates = nil
                isHoverColliding = false
                hoverCollisionReason = nil
                linePlacementPoints = []
                linePlacementCollisions = []
            }
            return
        }
        
        let mapLocalPoint = CGPoint(
            x: globalLocation.x - mapViewFrame.origin.x,
            y: globalLocation.y - mapViewFrame.origin.y
        )
        
        // Handle selection drag preview
        if isSelectionDragging {
            handleSelectionDragChanged(at: mapLocalPoint, mapData: mapData)
            return
        }
        
        let tileCoordinates = cameraController.screenToTileCoordinates(
            screenPoint: mapLocalPoint,
            mapSize: CGSize(width: mapData.width, height: mapData.height),
            tileSize: 32
        )
        
        guard tileCoordinates.x >= 0 && tileCoordinates.x < mapData.width &&
              tileCoordinates.y >= 0 && tileCoordinates.y < mapData.height else {
            if !isDragging {
                hoverTileCoordinates = nil
                isHoverColliding = false
                hoverCollisionReason = nil
                linePlacementPoints = []
                linePlacementCollisions = []
            }
            return
        }
        
        hoverTileCoordinates = tileCoordinates
        
        // Handle single point or line based on drag state
        if isDragging, let startCoordinates = dragStartCoordinates {
            // Generate all points in the line
            let lineResult = generateLine(from: startCoordinates, to: tileCoordinates)
            let linePoints = lineResult.points
            
            // Check collision for each point
            var collisions: [Bool] = []
            
            for point in linePoints {
                let placementInfo = blockManager.getPlacementInfo(
                    for: selectedBlock,
                    at: point,
                    rotation: rotationController.selectedBlockRotation,
                    mapData: mapData,
                    researchManager: researchManager
                )
                
                collisions.append(!placementInfo.canPlace)
            }
            
            linePlacementPoints = linePoints
            linePlacementCollisions = collisions
            
            // Set the hover collision state based on the current hover point
            let placementInfo = blockManager.getPlacementInfo(
                for: selectedBlock,
                at: tileCoordinates,
                rotation: rotationController.selectedBlockRotation,
                mapData: mapData,
                researchManager: researchManager
            )
            
            isHoverColliding = !placementInfo.canPlace
            hoverCollisionReason = placementInfo.reason
            
            if selectedBlock.canRotate, let direction = lineResult.direction {
                // Map direction to rotation (0=north, 1=east, 2=south, 3=west)
                var newRotation: BlockRotation? = nil
                
                if selectedBlock.iconName != "shaft" {
                    switch direction {
                    case .north:
                        newRotation = BlockRotation(0)
                    case .east:
                        newRotation = BlockRotation(1)
                    case .south:
                        newRotation = BlockRotation(2)
                    case .west:
                        newRotation = BlockRotation(3)
                    }
                } else {
                    switch direction {
                    case .north:
                        newRotation = BlockRotation(3)
                    case .east:
                        newRotation = BlockRotation(2)
                    case .south:
                        newRotation = BlockRotation(1)
                    case .west:
                        newRotation = BlockRotation(0)
                    }
                }
                
                // Update the rotation controller
                if rotationController.selectedBlockRotation.rawValue != newRotation?.rawValue {
                    rotationController.selectedBlockRotation = newRotation!
                }
            }
        } else {
            // Just handle single point preview
            let placementInfo = blockManager.getPlacementInfo(
                for: selectedBlock,
                at: tileCoordinates,
                rotation: rotationController.selectedBlockRotation,
                mapData: mapData,
                researchManager: researchManager
            )
            
            isHoverColliding = !placementInfo.canPlace
            hoverCollisionReason = placementInfo.reason
            
            // Clear line placement data
            linePlacementPoints = []
            linePlacementCollisions = []
        }
    }
    
    func setupWindowAndKeyboard(window: UIWindow) {
        hoverObserver.install(on: window)
        
        hoverObserver.onScrollEvent = { delta in
            if let selectedBlock = self.selectedBlock, selectedBlock.canRotate {
                self.rotationController.handleScroll(delta: delta)
            }
        }
    }
    
    func formatBuildCost(_ buildCost: [ItemType: Int]) -> String {
        return buildCost.map { "\($0.value) \($0.key.displayName)" }.joined(separator: ", ")
    }
    
    func handleKeyDown(_ key: String) {
    switch key.lowercased() {
    case "w", "a", "s", "d":
        if !pressedKeys.contains(key.lowercased()) {
            pressedKeys.insert(key.lowercased())
        }
        updateMovementFromPressedKeys()
    case "r":
        // Respawn shardling
        respawnShardling = true
        print("🔄 Respawning shardling...")
    case "x":
        selectedBlock = nil
        rotationController.resetRotation()
    case " ": // Space bar
        break
    case "q", "e": // Rotation keys
        if let selectedBlock = selectedBlock, selectedBlock.canRotate {
            rotationController.handleKeyboard(key: key)
        }
    case "shift":
        isShiftPressed = true
    default:
        break
    }
}

    
    func handleKeyUp(_ key: String) {
    pressedKeys.remove(key.lowercased())

    switch key.lowercased() {
    case "w", "a", "s", "d":
        updateMovementFromPressedKeys()
    case " ": // Space bar
        break
    case "shift":
        isShiftPressed = false
    default:
        break
    }
}

/// Recomputes camera movement from currently pressed WASD keys.
private func updateMovementFromPressedKeys() {
    let up = pressedKeys.contains("w")
    let down = pressedKeys.contains("s")
    let left = pressedKeys.contains("a")
    let right = pressedKeys.contains("d")

    // Resolve vertical and horizontal intents (opposites cancel out)
    let v = (up ? 1 : 0) - (down ? 1 : 0)
    let h = (left ? 1 : 0) - (right ? 1 : 0)

    if v == 0 && h == 0 {
        cameraController.stopMoving()
        return
    }

    if v > 0 && h > 0 {
        cameraController.startMoving(direction: .upLeft)
    } else if v > 0 && h < 0 {
        cameraController.startMoving(direction: .upRight)
    } else if v < 0 && h > 0 {
        cameraController.startMoving(direction: .downLeft)
    } else if v < 0 && h < 0 {
        cameraController.startMoving(direction: .downRight)
    } else if v > 0 {
        cameraController.startMoving(direction: .up)
    } else if v < 0 {
        cameraController.startMoving(direction: .down)
    } else if h > 0 {
        cameraController.startMoving(direction: .left)
    } else if h < 0 {
        cameraController.startMoving(direction: .right)
    }
}

}

#Preview {
    let mapFileURL = Bundle.main.mapFileURL(named: "Terrain_SG")!
    GameView(fileURL: mapFileURL, onReturnToSectorMap: nil)
        .environmentObject(GlobalHoverObserver())
        .ignoresSafeArea()
}





//import UIKit
//import Combine
//
///// 1) An ObservableObject that will publish global hover positions.
//final class GlobalHoverObserver: ObservableObject {
//    @Published var location: CGPoint = .zero
//
//    /// Call this once, passing in your app's window.
//    func install(on window: UIWindow) {
//        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
//        window.addGestureRecognizer(hover)
//    }
//
//    @objc
//    func handleHover(_ recognizer: UIHoverGestureRecognizer) {
//        guard recognizer.state == .changed,
//              let view = recognizer.view else { return }
//        let pt = recognizer.location(in: view)
//        DispatchQueue.main.async {
//            self.location = pt
//        }
//    }
//}
//
///// 2) A tiny UIViewRepresentable that gives you the UIWindow as soon as it's in the hierarchy.
//struct WindowAccessor: UIViewRepresentable {
//    var callback: (UIWindow) -> Void
//
//    func makeUIView(context: Context) -> UIView {
//        let v = UIView()
//        // once this view is in a window, grab it:
//        DispatchQueue.main.async {
//            if let win = v.window {
//                self.callback(win)
//            }
//        }
//        return v
//    }
//
//    func updateUIView(_ uiView: UIView, context: Context) { }
//}
//
///// 4) Your SwiftUI UI can now read hover positions from the environment object
//struct ContentView: View {
//    @EnvironmentObject var hoverObs: GlobalHoverObserver
//
//    var body: some View {
//        ZStack {
//            Color(.systemBackground)
//                .ignoresSafeArea()
//
//            VStack {
//                Text("Hover at x: \(Int(hoverObs.location.x)), y: \(Int(hoverObs.location.y))")
//                    .padding(8)
//                    .background(Color.black.opacity(0.7))
//                    .foregroundColor(.white)
//                    .cornerRadius(6)
//                Spacer()
//            }
//            .padding()
//        }
//    }
//}

// enemy faction name: Ferox

// player faction name: Lumina

// yndora faction name: Malum

// gas planet faction name: Kanir

// story: Lumina’s original homeworld was destroyed by a cosmic catastrophe. Tarkon is their chosen refuge, but Ferox has already established dominance, using the planet to expand their militaristic empire. Lumina must fight for their very survival.
