////
////  MapEditor.swift
////  Factdustry
////
////  Created by Bright on 6/3/25.
////
//
//import SwiftUI
//
//struct Tile2: Identifiable, Codable {
//    var id = UUID()
//    var type: TileType
//    var x: Int
//    var y: Int
//}
//
//enum TileType: String, CaseIterable, Codable {
//    case empty = " "
//    case darkSand = "A"
//    case terrain0 = "B"
//    case terrain1 = "C"
//    case terrain2 = "D"
//    
//    // New terrain (tile-type)
//    case water = "W"
//    case saltWater = "Z"
//    
//    // Wall types
//    case wall0 = "E"
//    case wall1 = "F"
//    case wall2 = "G"
//    case wall3 = "H"
//    // New wall (wall-type)
//    case shrub = "S"
//    
//    // 3x3 structures
//    case vent = "V"
//    case geyser = "Y"
//    
//    var imageName: String {
//        switch self {
//        case .empty: return ""
//        case .darkSand: return "terrain3"
//        case .terrain0: return "terrain0"
//        case .terrain1: return "terrain1"
//        case .terrain2: return "terrain2"
//        case .wall0: return "wall0"
//        case .wall1: return "wall1"
//        case .wall2: return "wall2"
//        case .wall3: return "wall3"
//        case .vent: return "vent"
//        case .geyser: return "geyser"
//        case .water: return "water-t"
//        case .saltWater: return "salt-water"
//        case .shrub: return "shrub"
//        }
//    }
//    
//    var fallbackColor: Color {
//        switch self {
//        case .empty: return Color.purple
//        case .darkSand: return Color.brown
//        case .terrain0: return Color.gray
//        case .terrain1: return Color.orange
//        case .terrain2: return Color.green
//        case .wall0: return Color.gray.opacity(0.8)
//        case .wall1: return Color.gray.opacity(0.6)
//        case .wall2: return Color.gray.opacity(0.4)
//        case .wall3: return Color.gray.opacity(0.2)
//        case .vent: return Color.cyan
//        case .geyser: return Color.blue
//        case .water: return Color.blue.opacity(0.6)
//        case .saltWater: return Color.cyan.opacity(0.6)
//        case .shrub: return Color.green.opacity(0.7)
//        }
//    }
//    
//    var name: String {
//        switch self {
//        case .empty: return "Empty"
//        case .darkSand: return "Dark Sand"
//        case .terrain0: return "Terrain 0"
//        case .terrain1: return "Terrain 1"
//        case .terrain2: return "Terrain 2"
//        case .wall0: return "Wall 0"
//        case .wall1: return "Wall 1"
//        case .wall2: return "Wall 2"
//        case .wall3: return "Wall 3"
//        case .vent: return "Vent"
//        case .geyser: return "Geyser"
//        case .water: return "Water"
//        case .saltWater: return "Salt Water"
//        case .shrub: return "Shrub"
//        }
//    }
//        
//    var category: TileCategory {
//        switch self {
//        case .empty, .darkSand, .terrain0, .terrain1, .terrain2, .water, .saltWater:
//            return .terrain
//        case .wall0, .wall1, .wall2, .wall3, .shrub:
//            return .walls
//        case .vent, .geyser:
//            return .structures
//        }
//    }
//    
//    var size: TileSize {
//        switch self {
//        case .vent, .geyser:
//            return .large // 9x9 like TerrainGenerator
//        default:
//            return .single // 1x1
//        }
//    }
//    
//    var canPlaceOreOn: Bool {
//        switch self {
//        case .wall0, .wall1, .wall2, .wall3:
//            return true
//        default:
//            return false
//        }
//    }
//    
//    var validOreTypes: [OreType] {
//        switch self {
//        case .wall3:
//            return [.graphite]
//        case .wall0, .wall1, .wall2:
//            return [.copper]
//        default:
//            return []
//        }
//    }
//}
//
//enum TileCategory: String, CaseIterable {
//    case terrain = "Terrain"
//    case walls = "Walls"
//    case structures = "Structures"
//    
//    var icon: String {
//        switch self {
//        case .terrain: return "square.grid.3x1.below.line.grid.1x2"
//        case .walls: return "square.stack.3d.up"
//        case .structures: return "building.2"
//        }
//    }
//}
//
//enum TileSize {
//    case single // 1x1
//    case large  // 9x9 like TerrainGenerator
//}
//
//struct MapData: Codable {
//    var width: Int
//    var height: Int
//    var tiles: [[TileType]]
//    var ores: [[OreType]] // Separate ore layer for overlays
//    var metadata: MapMetadata
//    var coreLoadout: [String: Int]?
//    
//    init(width: Int, height: Int) {
//        self.width = width
//        self.height = height
//        self.tiles = Array(repeating: Array(repeating: .empty, count: width), count: height)
//        self.ores = Array(repeating: Array(repeating: .none, count: width), count: height)
//        self.metadata = MapMetadata()
//        self.coreLoadout = nil
//    }
//    
//    static func fromJSON(_ jsonString: String) throws -> MapData {
//        guard let data = jsonString.data(using: .utf8),
//              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
//            throw MapDataError.invalidJSON
//        }
//        
//        guard let metadata = json["metadata"] as? [String: Any],
//              let width = metadata["width"] as? Int,
//              let height = metadata["height"] as? Int else {
//            throw MapDataError.missingMetadata
//        }
//        
//        guard let tileTranslations = json["tileTranslations"] as? [String: String] else {
//            throw MapDataError.missingTileTranslations
//        }
//        
//        let oreTranslations = json["oreTranslations"] as? [String: String] ?? [:]
//        
//        guard let tileStrings = json["tiles"] as? [String] else {
//            throw MapDataError.missingTiles
//        }
//        
//        let oreStrings = json["ores"] as? [String] ?? []
//        let coreLoadout = json["coreLoadout"] as? [String: Int]
//        
//        var mapData = MapData(width: width, height: height)
//        mapData.coreLoadout = coreLoadout
//        
//        if let name = metadata["name"] as? String {
//            mapData.metadata.name = name
//        }
//        
//        // Convert tile strings to TileType array
//        for (y, row) in tileStrings.enumerated() {
//            guard y < height else { break }
//            for (x, char) in row.enumerated() {
//                guard x < width else { break }
//                let charString = String(char)
//                
//                if let translatedType = tileTranslations[charString] {
//                    switch translatedType {
//                    case "Dark_Sand": mapData.tiles[y][x] = .darkSand
//                    case "terrain0": mapData.tiles[y][x] = .terrain0
//                    case "terrain1": mapData.tiles[y][x] = .terrain1
//                    case "terrain2": mapData.tiles[y][x] = .terrain2
//                    case "wall0": mapData.tiles[y][x] = .wall0
//                    case "wall1": mapData.tiles[y][x] = .wall1
//                    case "wall2": mapData.tiles[y][x] = .wall2
//                    case "wall3": mapData.tiles[y][x] = .wall3
//                    case "vent": mapData.tiles[y][x] = .vent
//                    case "geyser": mapData.tiles[y][x] = .geyser
//                    case "blank": mapData.tiles[y][x] = .empty
//                    case "water": mapData.tiles[y][x] = .water
//                    case "salt-water": mapData.tiles[y][x] = .saltWater
//                    case "shrub": mapData.tiles[y][x] = .shrub
//                    default: mapData.tiles[y][x] = .empty
//                    }
//                } else {
//                    mapData.tiles[y][x] = .empty
//                }
//            }
//        }
//        
//        // Convert ore strings to OreType array
//        for (y, row) in oreStrings.enumerated() {
//            guard y < height else { break }
//            for (x, char) in row.enumerated() {
//                guard x < width else { break }
//                let charString = String(char)
//                
//                if let translatedOre = oreTranslations[charString] {
//                    switch translatedOre {
//                    case "ore_copper": mapData.ores[y][x] = .copper
//                    case "ore_graphite": mapData.ores[y][x] = .graphite
//                    case "none": mapData.ores[y][x] = .none
//                    default: mapData.ores[y][x] = .none
//                    }
//                } else {
//                    mapData.ores[y][x] = .none
//                }
//            }
//        }
//        
//        return mapData
//    }
//    
//    static func fromJSONFile(at url: URL) throws -> MapData {
//        let data = try Data(contentsOf: url)
//        let jsonString = String(data: data, encoding: .utf8) ?? ""
//        return try fromJSON(jsonString)
//    }
//    
//    // Helper method to convert core loadout to ItemTypes format
//    func getCoreLoadoutAsItemTypes() -> [ItemType: Int] {
//        guard let loadout = coreLoadout else { return [:] }
//        
//        var itemLoadout: [ItemType: Int] = [:]
//        
//        for (itemName, count) in loadout {
//            // Convert string names to ItemType enum
//            switch itemName.lowercased() {
//            case "copper":
//                itemLoadout[.copper] = count
//            case "graphite":
//                itemLoadout[.graphite] = count
//            case "silicon":
//                itemLoadout[.silicon] = count
//            case "iron":
//                itemLoadout[.iron] = count
//            case "steel":
//                itemLoadout[.steel] = count
//            case "rawaluminum", "raw_aluminum":
//                itemLoadout[.rawAliuminum] = count
//            case "aluminum", "aluminium":
//                itemLoadout[.aliuminum] = count
//            case "coal":
//                itemLoadout[.coal] = count
//            default:
//                // Handle unknown item names gracefully
//                break
//            }
//        }
//        
//        return itemLoadout
//    }
//}
//
//enum MapDataError: Error {
//    case invalidJSON
//    case missingMetadata
//    case missingTileTranslations
//    case missingTiles
//}
//
//enum OreType: String, CaseIterable, Codable {
//    case none = " "
//    case copper = "J"
//    case graphite = "I"
//    
//    var imageName: String {
//        switch self {
//        case .none: return ""
//        case .copper: return "ore_copper"
//        case .graphite: return "ore_graphite"
//        }
//    }
//    
//    var fallbackColor: Color {
//        switch self {
//        case .none: return .clear
//        case .copper: return Color(red: 0.9, green: 0.4, blue: 0.0).opacity(0.8)
//        case .graphite: return Color(red: 0.35, green: 0.35, blue: 0.35).opacity(0.8)
//        }
//    }
//    
//    var name: String {
//        switch self {
//        case .none: return "No Ore"
//        case .copper: return "Copper Ore"
//        case .graphite: return "Graphite Ore"
//        }
//    }
//}
//
//struct MapMetadata: Codable {
//    var name: String = "Untitled Map"
//    var author: String = ""
//    var description: String = ""
//    var version: String = "1.0"
//}
//
//enum BrushType: CaseIterable {
//    case paint, fill
//    
//    var name: String {
//        switch self {
//        case .paint: return "Paint"
//        case .fill: return "Fill"
//        }
//    }
//    
//    var icon: String {
//        switch self {
//        case .paint: return "paintbrush.fill"
//        case .fill: return "paintbucket.fill"
//        }
//    }
//}
//
//// MARK: - Editor State
//class MapEditorState: ObservableObject {
//    @Published var mapData: MapData
//    @Published var selectedTile: TileType = .darkSand
//    @Published var selectedOre: OreType = .none
//    @Published var editMode: EditMode = .tile
//    @Published var brushType: BrushType = .paint
//    @Published var brushSize: Int = 1
//    @Published var isDrawing: Bool = false
//    @Published var zoomScale: CGFloat = 1.0
//    @Published var baseZoomScale: CGFloat = 1.0
//    @Published var offset: CGPoint = CGPoint(x: 100, y: 50)
//    @Published var hoverPreview: (x: Int, y: Int)?
//    
//    // WASD movement constants
//    private let baseMovementSpeed: CGFloat = 400.0
//    private let tileSize: CGFloat = 32
//    
//    // Camera bounds - made consistent
//    var viewportSize: CGSize = .zero
//    private let sidebarWidth: CGFloat = 340
//    private let headerHeight: CGFloat = 60
//    
//    // Undo/Redo system
//    private var undoStack: [MapData] = []
//    private var redoStack: [MapData] = []
//    private let maxUndoSteps = 50
//    
//    var canUndo: Bool { !undoStack.isEmpty }
//    var canRedo: Bool { !redoStack.isEmpty }
//    
//    init(width: Int = 30, height: Int = 30) {
//        self.mapData = MapData(width: width, height: height)
//    }
//    
//    deinit {
//        stopMoving()
//    }
//    
//    enum EditMode {
//        case tile
//        case ore
//    }
//    
//    // MARK: - Camera bounds calculation helper
//    private func getCanvasDimensions() -> (width: CGFloat, height: CGFloat) {
//        let canvasWidth = max(100, viewportSize.width - sidebarWidth)
//        let canvasHeight = max(100, viewportSize.height - headerHeight)
//        return (canvasWidth, canvasHeight)
//    }
//    
//    // MARK: - WASD Camera Movement Functions
//    private var moveTimer: Timer?
//    private var currentDirection: MoveDirection?
//    private var lastMoveTime = Date()
//    
//    func startMoving(direction: MoveDirection) {
//        if currentDirection != direction || moveTimer == nil {
//            stopMoving()
//            currentDirection = direction
//            lastMoveTime = Date()
//            
//            performMove(direction: direction)
//            
//            moveTimer = Timer.scheduledTimer(withTimeInterval: 1/60.0, repeats: true) { _ in
//                self.performMove(direction: direction)
//            }
//        }
//    }
//    
//    private func performMove(direction: MoveDirection) {
//        let currentTime = Date()
//        let deltaTime = currentTime.timeIntervalSince(lastMoveTime)
//        lastMoveTime = currentTime
//        
//        let moveDistance = baseMovementSpeed * CGFloat(deltaTime) / zoomScale
//        
//        var newOffset = offset
//        switch direction {
//        case .up:    newOffset.y += moveDistance
//        case .down:  newOffset.y -= moveDistance
//        case .left:  newOffset.x += moveDistance
//        case .right: newOffset.x -= moveDistance
//        }
//        
//        newOffset = applyBounds(to: newOffset)
//        
//        DispatchQueue.main.async {
//            self.offset = newOffset
//        }
//    }
//    
//    func applyBounds(to proposedOffset: CGPoint) -> CGPoint {
//        guard viewportSize.width > 0 && viewportSize.height > 0 else {
//            return proposedOffset
//        }
//        
//        let (canvasWidth, canvasHeight) = getCanvasDimensions()
//        
//        // Calculate map size in pixels
//        let mapWidth = CGFloat(mapData.width) * tileSize * zoomScale
//        let mapHeight = CGFloat(mapData.height) * tileSize * zoomScale
//        
//        // Calculate bounds with margin
//        let margin: CGFloat = 50 * zoomScale
//        
//        // FIXED: Improved bounds calculation
//        let maxOffsetX = margin
//        let minOffsetX = canvasWidth - mapWidth - margin
//        let maxOffsetY = margin
//        let minOffsetY = canvasHeight - mapHeight - margin
//        
//        // Ensure we can always see part of the map
//        let clampedX = min(maxOffsetX, max(minOffsetX, proposedOffset.x))
//        let clampedY = min(maxOffsetY, max(minOffsetY, proposedOffset.y))
//        
//        return CGPoint(x: clampedX, y: clampedY)
//    }
//    
//    func updateViewportSize(_ size: CGSize) {
//        viewportSize = size
//        offset = applyBounds(to: offset)
//    }
//    
//    func stopMoving() {
//        moveTimer?.invalidate()
//        moveTimer = nil
//        currentDirection = nil
//    }
//    
//    func resetCamera() {
//        zoomScale = 1.0
//        baseZoomScale = 1.0
//        
//        let (canvasWidth, canvasHeight) = getCanvasDimensions()
//        let mapWidth = CGFloat(mapData.width) * tileSize
//        let mapHeight = CGFloat(mapData.height) * tileSize
//        
//        let centerX = (canvasWidth - mapWidth) / 2
//        let centerY = (canvasHeight - mapHeight) / 2
//        
//        offset = CGPoint(x: centerX, y: centerY)
//        offset = applyBounds(to: offset)
//    }
//    
//    enum MoveDirection {
//        case up, down, left, right
//    }
//    
//    // MARK: - FIXED: Correct screen-to-tile coordinate conversion for center-anchored scaling
//    func screenToTileCoordinates(screenPoint: CGPoint, canvasSize: CGSize) -> (x: Int, y: Int) {
//        // Calculate the map's natural size
//        let mapWidth = CGFloat(mapData.width) * tileSize
//        let mapHeight = CGFloat(mapData.height) * tileSize
//        
//        // After offset + center-anchored scale, calculate where the top-left corner actually is
//        let centerX = offset.x + mapWidth / 2
//        let centerY = offset.y + mapHeight / 2
//        
//        // After scaling, the top-left corner moves
//        let scaledWidth = mapWidth * zoomScale
//        let scaledHeight = mapHeight * zoomScale
//        let actualTopLeftX = centerX - scaledWidth / 2
//        let actualTopLeftY = centerY - scaledHeight / 2
//        
//        // Convert screen point to map coordinates
//        let mapX = (screenPoint.x - actualTopLeftX) / zoomScale
//        let mapY = (screenPoint.y - actualTopLeftY) / zoomScale
//        
//        // Convert to tile coordinates
//        let tileX = Int(floor(mapX / tileSize))
//        let tileY = Int(floor(mapY / tileSize))
//        
//        // Clamp to map bounds
//        let clampedX = max(0, min(mapData.width - 1, tileX))
//        let clampedY = max(0, min(mapData.height - 1, tileY))
//        
//        return (x: clampedX, y: clampedY)
//    }
//    
//    func handleTileInteraction(x: Int, y: Int) {
//        guard x >= 0 && x < mapData.width && y >= 0 && y < mapData.height else {
//            return
//        }
//        
//        if editMode == .ore {
//            switch brushType {
//            case .paint:
//                if brushSize == 1 {
//                    setOre(x: x, y: y, ore: selectedOre)
//                } else {
//                    paintArea(centerX: x, centerY: y, ore: selectedOre)
//                }
//            case .fill:
//                floodFillOre(startX: x, startY: y, newOre: selectedOre)
//            }
//            return
//        }
//        
//        if let (centerX, centerY) = find9x9StructureCenter(at: x, y: y) {
//            let centerTile = mapData.tiles[centerY][centerX]
//            if selectedTile.size == .large && centerTile == selectedTile {
//                return
//            }
//            
//            if selectedTile != .empty {
//                remove9x9Tile(centerX: centerX, centerY: centerY)
//                
//                if selectedTile.size == .large {
//                    place9x9Tile(centerX: centerX, centerY: centerY, type: selectedTile)
//                    return
//                }
//            } else {
//                remove9x9Tile(centerX: centerX, centerY: centerY)
//                return
//            }
//        }
//        
//        switch brushType {
//        case .paint:
//            if selectedTile.size == .large {
//                place9x9Tile(centerX: x, centerY: y, type: selectedTile)
//            } else if brushSize == 1 {
//                setTile(x: x, y: y, type: selectedTile)
//            } else {
//                paintArea(centerX: x, centerY: y, type: selectedTile)
//            }
//        case .fill:
//            if selectedTile.size == .single {
//                floodFill(startX: x, startY: y, newType: selectedTile)
//            }
//        }
//    }
//    
//    func setTile(x: Int, y: Int, type: TileType) {
//        guard x >= 0 && x < mapData.width && y >= 0 && y < mapData.height else {
//            return
//        }
//        
//        if mapData.tiles[y][x] != type {
//            if !isDrawing {
//                saveToUndoStack()
//            }
//            mapData.tiles[y][x] = type
//            
//            if !type.canPlaceOreOn {
//                mapData.ores[y][x] = .none
//            }
//        }
//    }
//    
//    func setOre(x: Int, y: Int, ore: OreType) {
//        guard x >= 0 && x < mapData.width && y >= 0 && y < mapData.height else {
//            return
//        }
//        
//        let currentTile = mapData.tiles[y][x]
//        
//        if ore != .none && !currentTile.validOreTypes.contains(ore) {
//            return
//        }
//        
//        if mapData.ores[y][x] != ore {
//            if !isDrawing {
//                saveToUndoStack()
//            }
//            mapData.ores[y][x] = ore
//        }
//    }
//    
//    func canPlace9x9Tile(centerX: Int, centerY: Int, type: TileType) -> Bool {
//        guard type.size == .large else { return true }
//        
//        guard centerX >= 0 && centerX < mapData.width &&
//              centerY >= 0 && centerY < mapData.height else {
//            return false
//        }
//        
//        return true
//    }
//    
//    func place9x9Tile(centerX: Int, centerY: Int, type: TileType) {
//        guard type.size == .large else { return }
//        
//        guard centerX >= 0 && centerX < mapData.width &&
//              centerY >= 0 && centerY < mapData.height else { return }
//        
//        saveToUndoStack()
//        
//        mapData.tiles[centerY][centerX] = type
//    }
//    
//    func remove9x9Tile(centerX: Int, centerY: Int) {
//        saveToUndoStack()
//        mapData.tiles[centerY][centerX] = .empty
//    }
//    
//    func find9x9StructureCenter(at x: Int, y: Int) -> (Int, Int)? {
//        guard x >= 0 && x < mapData.width && y >= 0 && y < mapData.height else {
//            return nil
//        }
//        
//        let currentTile = mapData.tiles[y][x]
//        
//        if currentTile.size == .large {
//            return (x, y)
//        }
//        
//        return nil
//    }
//    
//    func paintArea(centerX: Int, centerY: Int, type: TileType? = nil, ore: OreType? = nil) {
//        saveToUndoStack()
//        
//        let halfSize = brushSize / 2
//        
//        for dy in -halfSize...halfSize {
//            for dx in -halfSize...halfSize {
//                let x = centerX + dx
//                let y = centerY + dy
//                
//                if x >= 0 && x < mapData.width && y >= 0 && y < mapData.height {
//                    if let tileType = type {
//                        mapData.tiles[y][x] = tileType
//                        if !tileType.canPlaceOreOn {
//                            mapData.ores[y][x] = .none
//                        }
//                    }
//                    
//                    if let oreType = ore {
//                        let currentTile = mapData.tiles[y][x]
//                        if oreType == .none || currentTile.validOreTypes.contains(oreType) {
//                            mapData.ores[y][x] = oreType
//                        }
//                    }
//                }
//            }
//        }
//    }
//    
//    func floodFill(startX: Int, startY: Int, newType: TileType) {
//        guard startX >= 0 && startX < mapData.width && startY >= 0 && startY < mapData.height else {
//            return
//        }
//        
//        let originalType = mapData.tiles[startY][startX]
//        guard originalType != newType else { return }
//        
//        saveToUndoStack()
//        
//        var stack = [(startX, startY)]
//        
//        while !stack.isEmpty {
//            let (x, y) = stack.removeLast()
//            
//            guard x >= 0 && x < mapData.width && y >= 0 && y < mapData.height else {
//                continue
//            }
//            
//            guard mapData.tiles[y][x] == originalType else { continue }
//            
//            mapData.tiles[y][x] = newType
//            
//            if !newType.canPlaceOreOn {
//                mapData.ores[y][x] = .none
//            }
//            
//            stack.append((x + 1, y))
//            stack.append((x - 1, y))
//            stack.append((x, y + 1))
//            stack.append((x, y - 1))
//        }
//    }
//    
//    func floodFillOre(startX: Int, startY: Int, newOre: OreType) {
//        guard startX >= 0 && startX < mapData.width && startY >= 0 && startY < mapData.height else {
//            return
//        }
//        
//        let originalOre = mapData.ores[startY][startX]
//        guard originalOre != newOre else { return }
//        
//        saveToUndoStack()
//        
//        var stack = [(startX, startY)]
//        
//        while !stack.isEmpty {
//            let (x, y) = stack.removeLast()
//            
//            guard x >= 0 && x < mapData.width && y >= 0 && y < mapData.height else {
//                continue
//            }
//            
//            guard mapData.ores[y][x] == originalOre else { continue }
//            
//            let currentTile = mapData.tiles[y][x]
//            if newOre == .none || currentTile.validOreTypes.contains(newOre) {
//                mapData.ores[y][x] = newOre
//            }
//            
//            stack.append((x + 1, y))
//            stack.append((x - 1, y))
//            stack.append((x, y + 1))
//            stack.append((x, y - 1))
//        }
//    }
//    
//    func resizeMap(newWidth: Int, newHeight: Int) {
//        saveToUndoStack()
//        
//        var newTiles = Array(repeating: Array(repeating: TileType.empty, count: newWidth), count: newHeight)
//        var newOres = Array(repeating: Array(repeating: OreType.none, count: newWidth), count: newHeight)
//        
//        let copyWidth = min(mapData.width, newWidth)
//        let copyHeight = min(mapData.height, newHeight)
//        
//        for y in 0..<copyHeight {
//            for x in 0..<copyWidth {
//                newTiles[y][x] = mapData.tiles[y][x]
//                newOres[y][x] = mapData.ores[y][x]
//            }
//        }
//        
//        mapData.width = newWidth
//        mapData.height = newHeight
//        mapData.tiles = newTiles
//        mapData.ores = newOres
//    }
//    
//    func undo() {
//        guard !undoStack.isEmpty else { return }
//        redoStack.append(mapData)
//        mapData = undoStack.removeLast()
//    }
//    
//    func redo() {
//        guard !redoStack.isEmpty else { return }
//        undoStack.append(mapData)
//        mapData = redoStack.removeLast()
//    }
//    
//    private func saveToUndoStack() {
//        undoStack.append(mapData)
//        redoStack.removeAll()
//        
//        if undoStack.count > maxUndoSteps {
//            undoStack.removeFirst()
//        }
//    }
//    
//    func exportToJSON() -> String {
//        let tileStrings = mapData.tiles.map { row in
//            row.map { $0.rawValue }.joined()
//        }
//        
//        let oreStrings = mapData.ores.map { row in
//            row.map { $0.rawValue }.joined()
//        }
//        
//        let export = [
//            "metadata": [
//                "width": mapData.width,
//                "height": mapData.height,
//                "name": mapData.metadata.name
//            ],
//            "tileTranslations": [
//                "A": "Dark_Sand",
//                "B": "terrain0",
//                "C": "terrain1",
//                "D": "terrain2",
//                "E": "wall0",
//                "F": "wall1",
//                "G": "wall2",
//                "H": "wall3",
//                "V": "vent",
//                "Y": "geyser",
//                "W": "water",
//                "Z": "salt-water",
//                "S": "shrub",
//                " ": "blank"
//            ],
//            "oreTranslations": [
//                "I": "ore_graphite",
//                "J": "ore_copper",
//                " ": "none"
//            ],
//            "tiles": tileStrings,
//            "ores": oreStrings,
//            "coreLoadout": (mapData.coreLoadout ?? [:])
//        ] as [String: Any]
//        
//        if let data = try? JSONSerialization.data(withJSONObject: export, options: .prettyPrinted),
//           let string = String(data: data, encoding: .utf8) {
//            return string
//        }
//        return ""
//    }
//
//    func exportToJSONWith(coreLoadout: [String: Int]?) -> String {
//        let tileStrings = mapData.tiles.map { row in
//            row.map { $0.rawValue }.joined()
//        }
//        let oreStrings = mapData.ores.map { row in
//            row.map { $0.rawValue }.joined()
//        }
//        let export: [String: Any] = [
//            "metadata": [
//                "width": mapData.width,
//                "height": mapData.height,
//                "name": mapData.metadata.name
//            ],
//            "tileTranslations": [
//                "A": "Dark_Sand",
//                "B": "terrain0",
//                "C": "terrain1",
//                "D": "terrain2",
//                "E": "wall0",
//                "F": "wall1",
//                "G": "wall2",
//                "H": "wall3",
//                "V": "vent",
//                "Y": "geyser",
//                "W": "water",
//                "Z": "salt-water",
//                "S": "shrub",
//                " ": "blank"
//            ],
//            "oreTranslations": [
//                "I": "ore_graphite",
//                "J": "ore_copper",
//                " ": "none"
//            ],
//            "tiles": tileStrings,
//            "ores": oreStrings,
//            "coreLoadout": coreLoadout ?? (mapData.coreLoadout ?? [:])
//        ]
//        if let data = try? JSONSerialization.data(withJSONObject: export, options: .prettyPrinted),
//           let string = String(data: data, encoding: .utf8) {
//            return string
//        }
//        return ""
//    }
//
//    
//    func loadMapFromJSON(_ jsonString: String) throws {
//        let loadedMapData = try MapData.fromJSON(jsonString)
//        undoStack.removeAll()
//        redoStack.removeAll()
//        self.mapData = loadedMapData
//    }
//}
//
//// MARK: - Main Editor View
//struct MapEditorView: View {
//    @StateObject private var editorState = MapEditorState()
//    @State private var showingExport = false
//    @State private var showingImport = false
//    @State private var exportedJSON = ""
//    @State private var exportedCoreLoadout: [String: Int] = [:]
//    @State private var includeCoreLoadout = true
//    @State private var importText = ""
//    @State private var importError: String?
//    
//    @State private var viewportSize: CGSize = .zero
//    @State private var lastZoomUpdate: Date = Date()
//    private let zoomThrottleInterval: TimeInterval = 0.0
//    
//    @State private var pressedKeys: Set<String> = []
//    
//    var body: some View {
//        GeometryReader { geometry in
//            ZStack {
//                Color(UIColor.systemGroupedBackground)
//                    .ignoresSafeArea()
//                
//                VStack(spacing: 0) {
//                    toolbarView
//                    
//                    HStack(spacing: 0) {
//                        VStack(spacing: 20) {
//                            mapPropertiesView
//                            tilePaletteView
//                            Spacer()
//                        }
//                        .frame(width: 300)
//                        .padding(20)
//                        .background(Color(UIColor.systemBackground))
//                        
//                        VStack(spacing: 0) {
//                            canvasHeaderView
//                                .padding(.horizontal, 20)
//                                .padding(.vertical, 12)
//                                .background(Color(UIColor.systemBackground))
//                            
//                            // FIXED: Map canvas with proper coordinate handling
//                            optimizedMapCanvas
//                                .background(Color.black)
//                                .onAppear {
//                                    viewportSize = geometry.size
//                                    editorState.updateViewportSize(geometry.size)
//                                }
//                                .onChange(of: geometry.size) { _, newSize in
//                                    viewportSize = newSize
//                                    editorState.updateViewportSize(newSize)
//                                }
//                        }
//                    }
//                }
//            }
//        }
//        .overlay(
//            KeyboardHandler(
//                onKeyDown: { key in
//                    handleKeyDown(key)
//                },
//                onKeyUp: { key in
//                    handleKeyUp(key)
//                }
//            )
//            .frame(width: 0, height: 0)
//            .opacity(0)
//        )
//        .sheet(isPresented: $showingExport) {
//            ExportView(
//                jsonString: $exportedJSON,
//                coreLoadout: $exportedCoreLoadout,
//                includeCoreLoadout: $includeCoreLoadout,
//                onExport: {
//                    if includeCoreLoadout {
//                        exportedJSON = editorState.exportToJSONWith(coreLoadout: exportedCoreLoadout.isEmpty ? nil : exportedCoreLoadout)
//                    } else {
//                        exportedJSON = editorState.exportToJSON()
//                    }
//                }
//            )
//        }
//        .sheet(isPresented: $showingImport) {
//            ImportView(
//                importText: $importText,
//                importError: $importError,
//                onImport: {
//                    do {
//                        try editorState.loadMapFromJSON(importText)
//                        showingImport = false
//                        importError = nil
//                    } catch {
//                        importError = error.localizedDescription
//                    }
//                }
//            )
//        }
//    }
//    
//    // MARK: - FIXED: Map Canvas with Proper Coordinate System
//    private var optimizedMapCanvas: some View {
//        GeometryReader { geometry in
//            let canvasWidth = max(100, geometry.size.width)
//            let canvasHeight = max(100, geometry.size.height)
//            
//            ZStack {
//                // FIXED: Interactive canvas with proper gesture handling
//                Rectangle()
//                    .fill(Color.clear)
//                    .frame(width: canvasWidth, height: canvasHeight)
//                    .contentShape(Rectangle())
//                    .gesture(
//                        // FIXED: Tile placement gesture with corrected coordinates
//                        DragGesture(minimumDistance: 0)
//                            .onChanged { gesture in
//                                let tileCoords = editorState.screenToTileCoordinates(
//                                    screenPoint: gesture.location,
//                                    canvasSize: CGSize(width: canvasWidth, height: canvasHeight)
//                                )
//                                editorState.handleTileInteraction(x: tileCoords.x, y: tileCoords.y)
//                            }
//                    )
//                    .simultaneousGesture(
//                        // FIXED: Zoom gesture with proper anchor handling
//                        MagnificationGesture()
//                            .onChanged { value in
//                                let now = Date()
//                                if now.timeIntervalSince(lastZoomUpdate) > zoomThrottleInterval {
//                                    let newScale = min(3.0, max(0.25, editorState.baseZoomScale * value))
//                                    editorState.zoomScale = newScale
//                                    editorState.offset = editorState.applyBounds(to: editorState.offset)
//                                    lastZoomUpdate = now
//                                }
//                            }
//                            .onEnded { _ in
//                                editorState.baseZoomScale = editorState.zoomScale
//                            }
//                    )
//                
//                // FIXED: Map content with natural center-anchored scaling
//                performantMapGridView(in: CGSize(width: canvasWidth, height: canvasHeight))
//                    .scaleEffect(editorState.zoomScale) // Removed anchor parameter for natural zoom
//                    .offset(x: editorState.offset.x, y: editorState.offset.y)
//                    .allowsHitTesting(false)
//            }
//            .frame(width: canvasWidth, height: canvasHeight)
//            .clipped()
//        }
//    }
//    
//    // MARK: - Performance-focused tile rendering
//    private func performantMapGridView(in viewSize: CGSize) -> some View {
//        let visibleRange = calculateOptimizedVisibleRange(viewSize: viewSize)
//        
//        let shouldRenderDetails = editorState.zoomScale > 0.3 &&
//                                  (visibleRange.xRange.count * visibleRange.yRange.count) < 2000
//        
//        return ZStack {
//            LazyVStack(spacing: 0) {
//                ForEach(visibleRange.yRange, id: \.self) { y in
//                    LazyHStack(spacing: 0) {
//                        ForEach(visibleRange.xRange, id: \.self) { x in
//                            if y >= 0 && y < editorState.mapData.height &&
//                                x >= 0 && x < editorState.mapData.width {
//                                
//                                highPerformanceTileView(
//                                    tileType: editorState.mapData.tiles[y][x],
//                                    oreType: editorState.mapData.ores[y][x],
//                                    x: x,
//                                    y: y,
//                                    zoomLevel: editorState.zoomScale
//                                )
//                            } else {
//                                Rectangle()
//                                    .fill(Color.black)
//                                    .frame(width: tileSize, height: tileSize)
//                            }
//                        }
//                    }
//                }
//            }
//            
//            ForEach(visibleRange.yRange, id: \.self) { y in
//                ForEach(visibleRange.xRange, id: \.self) { x in
//                    if y >= 0 && y < editorState.mapData.height &&
//                        x >= 0 && x < editorState.mapData.width {
//                        
//                        let tileType = editorState.mapData.tiles[y][x]
//                        if tileType.size == .large {
//                            optimizedLargeStructureOverlay(
//                                tileType: tileType,
//                                x: x,
//                                y: y
//                            )
//                        }
//                    }
//                }
//            }
//        }
//        .frame(
//            width: CGFloat(editorState.mapData.width) * tileSize,
//            height: CGFloat(editorState.mapData.height) * tileSize,
//            alignment: .topLeading
//        )
//    }
//    
//    // MARK: - Visible range calculation
//    private func calculateOptimizedVisibleRange(viewSize: CGSize) -> (xRange: Range<Int>, yRange: Range<Int>) {
//        let canvasWidth = viewSize.width
//        let canvasHeight = viewSize.height
//        
//        let scaledTileSize = tileSize * editorState.zoomScale
//        
//        let viewLeft = -editorState.offset.x
//        let viewTop = -editorState.offset.y
//        let viewRight = viewLeft + canvasWidth
//        let viewBottom = viewTop + canvasHeight
//        
//        let padding = editorState.zoomScale > 0.5 ? 3 : 1
//        let startX = max(0, Int(floor(viewLeft / scaledTileSize)) - padding)
//        let endX = min(editorState.mapData.width, Int(ceil(viewRight / scaledTileSize)) + padding)
//        let startY = max(0, Int(floor(viewTop / scaledTileSize)) - padding)
//        let endY = min(editorState.mapData.height, Int(ceil(viewBottom / scaledTileSize)) + padding)
//        
//        return (xRange: startX..<endX, yRange: startY..<endY)
//    }
//    
//    // MARK: - High-performance tile rendering
//    private func highPerformanceTileView(tileType: TileType, oreType: OreType, x: Int, y: Int, zoomLevel: CGFloat) -> some View {
//        Group {
//            if tileType.size == .large {
//                Rectangle()
//                    .fill(tileType.fallbackColor.opacity(0.3))
//                    .frame(width: tileSize, height: tileSize)
//                    .overlay(
//                        zoomLevel > 1.0 ?
//                        Rectangle().stroke(Color.white.opacity(0.1), lineWidth: 0.5) : nil
//                    )
//            } else {
//                TileView(
//                    tileType: tileType,
//                    oreType: oreType,
//                    size: tileSize
//                )
//                .overlay(
//                    zoomLevel > 1.0 ?
//                    Rectangle().stroke(Color.white.opacity(0.1), lineWidth: 0.5) : nil
//                )
//            }
//        }
//    }
//    
//    private func optimizedLargeStructureOverlay(tileType: TileType, x: Int, y: Int) -> some View {
//        let structure9x9Size = tileSize * 9
//        
//        return Group {
//            if !tileType.imageName.isEmpty {
//                if let uiImage = UIImage(named: tileType.imageName) {
//                    Image(uiImage: uiImage)
//                        .resizable()
//                        .aspectRatio(contentMode: .fill)
//                        .frame(width: structure9x9Size, height: structure9x9Size)
//                        .position(
//                            x: CGFloat(x) * tileSize + structure9x9Size/2,
//                            y: CGFloat(y) * tileSize + structure9x9Size/2
//                        )
//                        .clipped()
//                        .allowsHitTesting(false)
//                } else {
//                    Rectangle()
//                        .fill(tileType.fallbackColor)
//                        .frame(width: structure9x9Size, height: structure9x9Size)
//                        .position(
//                            x: CGFloat(x) * tileSize + structure9x9Size/2,
//                            y: CGFloat(y) * tileSize + structure9x9Size/2
//                        )
//                        .allowsHitTesting(false)
//                }
//            }
//        }
//    }
//    
//    private let tileSize: CGFloat = 32
//    
//    private func throttledZoomUpdate(newScale: CGFloat) {
//        let now = Date()
//        if now.timeIntervalSince(lastZoomUpdate) > zoomThrottleInterval {
//            editorState.zoomScale = newScale
//            editorState.baseZoomScale = newScale
//            editorState.offset = editorState.applyBounds(to: editorState.offset)
//            lastZoomUpdate = now
//        }
//    }
//    
//    private var toolbarView: some View {
//        HStack {
//            HStack(spacing: 8) {
//                Button(action: editorState.undo) {
//                    Image(systemName: "arrow.uturn.backward")
//                        .foregroundColor(editorState.canUndo ? .primary : .secondary)
//                }
//                .disabled(!editorState.canUndo)
//                
//                Button(action: editorState.redo) {
//                    Image(systemName: "arrow.uturn.forward")
//                        .foregroundColor(editorState.canRedo ? .primary : .secondary)
//                }
//                .disabled(!editorState.canRedo)
//            }
//            .padding(.horizontal, 8)
//            .padding(.vertical, 6)
//            .background(Color(UIColor.tertiarySystemFill))
//            .cornerRadius(8)
//            
//            Button(action: { editorState.resetCamera() }) {
//                Image(systemName: "location.circle.fill")
//                    .foregroundColor(.blue)
//            }
//            .padding(.horizontal, 8)
//            .padding(.vertical, 6)
//            .background(Color(UIColor.tertiarySystemFill))
//            .cornerRadius(8)
//            
//            Spacer()
//            
//            HStack(spacing: 8) {
//                Button("-") {
//                    throttledZoomUpdate(newScale: max(0.25, editorState.zoomScale - 0.25))
//                }
//                .font(.system(size: 16, weight: .medium))
//                .foregroundColor(.blue)
//                
//                Text("\(Int(editorState.zoomScale * 100))%")
//                    .font(.system(size: 14, weight: .medium))
//                    .frame(width: 50)
//                    .foregroundColor(.secondary)
//                
//                Button("+") {
//                    throttledZoomUpdate(newScale: min(3.0, editorState.zoomScale + 0.25))
//                }
//                .font(.system(size: 16, weight: .medium))
//                .foregroundColor(.blue)
//            }
//            .padding(.horizontal, 12)
//            .padding(.vertical, 8)
//            .background(Color(UIColor.tertiarySystemFill))
//            .cornerRadius(8)
//        }
//        .padding(.horizontal, 20)
//        .padding(.vertical, 12)
//        .background(Color(UIColor.systemGroupedBackground))
//    }
//    
//    private var canvasHeaderView: some View {
//        VStack(spacing: 8) {
//            HStack {
//                HStack(spacing: 12) {
//                    Picker("Edit Mode", selection: $editorState.editMode) {
//                        Text("Tiles").tag(MapEditorState.EditMode.tile)
//                        Text("Ores").tag(MapEditorState.EditMode.ore)
//                    }
//                    .pickerStyle(.segmented)
//                    .frame(width: 120)
//                    
//                    Picker("Brush", selection: $editorState.brushType) {
//                        ForEach(BrushType.allCases, id: \.self) { brushType in
//                            Label(brushType.name, systemImage: brushType.icon)
//                                .tag(brushType)
//                        }
//                    }
//                    .pickerStyle(.segmented)
//                    .frame(width: 150)
//                    .disabled(editorState.editMode == .tile && editorState.selectedTile.size == .large && editorState.brushType == .fill)
//                    .onChange(of: editorState.selectedTile) { _, _ in
//                        if editorState.selectedTile.size == .large && editorState.brushType == .fill {
//                            editorState.brushType = .paint
//                        }
//                    }
//                    
//                    if editorState.brushType == .paint &&
//                       ((editorState.editMode == .tile && editorState.selectedTile.size == .single) ||
//                        editorState.editMode == .ore) {
//                        HStack(spacing: 8) {
//                            Text("Size:")
//                                .font(.system(size: 14, weight: .medium))
//                                .foregroundColor(.secondary)
//                            
//                            HStack(spacing: 4) {
//                                Button("-") {
//                                    editorState.brushSize = max(1, editorState.brushSize - 1)
//                                }
//                                .font(.system(size: 12, weight: .medium))
//                                .disabled(editorState.brushSize <= 1)
//                                
//                                Text("\(editorState.brushSize)")
//                                    .font(.system(size: 14, weight: .medium))
//                                    .frame(width: 30)
//                                
//                                Button("+") {
//                                    editorState.brushSize = min(10, editorState.brushSize + 1)
//                                }
//                                .font(.system(size: 12, weight: .medium))
//                                .disabled(editorState.brushSize >= 10)
//                            }
//                            .padding(.horizontal, 8)
//                            .padding(.vertical, 4)
//                            .background(Color(UIColor.tertiarySystemFill))
//                            .cornerRadius(6)
//                        }
//                    }
//                }
//                
//                Spacer()
//            }
//        }
//    }
//    
//    private var mapPropertiesView: some View {
//        VStack(spacing: 16) {
//            HStack {
//                Label("Map Properties", systemImage: "map")
//                    .font(.headline)
//                    .foregroundColor(.primary)
//                
//                Spacer()
//            }
//            
//            VStack(alignment: .leading, spacing: 8) {
//                Text("Map Name")
//                    .font(.subheadline)
//                    .fontWeight(.medium)
//                    .foregroundColor(.secondary)
//                
//                TextField("Enter map name", text: $editorState.mapData.metadata.name)
//                    .textFieldStyle(.roundedBorder)
//            }
//            
//            VStack(alignment: .leading, spacing: 8) {
//                Text("Current Size")
//                    .font(.subheadline)
//                    .fontWeight(.medium)
//                    .foregroundColor(.secondary)
//                
//                HStack {
//                    Text("\(editorState.mapData.width) × \(editorState.mapData.height)")
//                        .font(.title3)
//                        .fontWeight(.semibold)
//                    
//                    Spacer()
//                    
//                    Button("Export") {
//                        exportedCoreLoadout = editorState.mapData.coreLoadout ?? exportedCoreLoadout
//                        exportedJSON = editorState.exportToJSONWith(coreLoadout: includeCoreLoadout ? exportedCoreLoadout : nil)
//                        showingExport = true
//                    }
//                    .buttonStyle(.borderedProminent)
//                    .controlSize(.small)
//                    
//                    Button("Import") {
//                        showingImport = true
//                    }
//                    .buttonStyle(.bordered)
//                    .controlSize(.small)
//                }
//            }
//            
//            VStack(spacing: 12) {
//                HStack {
//                    Text("Resize Map")
//                        .font(.subheadline)
//                        .fontWeight(.medium)
//                        .foregroundColor(.secondary)
//                    Spacer()
//                }
//                
//                HStack(spacing: 8) {
//                    Text("Width:")
//                        .font(.system(size: 14, weight: .medium))
//                        .frame(width: 50, alignment: .leading)
//                    
//                    HStack(spacing: 8) {
//                        Button("-") {
//                            if editorState.mapData.width > 10 {
//                                editorState.resizeMap(newWidth: editorState.mapData.width - 1, newHeight: editorState.mapData.height)
//                            }
//                        }
//                        .font(.system(size: 14, weight: .medium))
//                        .foregroundColor(editorState.mapData.width > 10 ? .blue : .secondary)
//                        .disabled(editorState.mapData.width <= 10)
//                        
//                        Text("\(editorState.mapData.width)")
//                            .font(.system(size: 14, weight: .medium))
//                            .frame(width: 40)
//                        
//                        Button("+") {
//                            if editorState.mapData.width < 100 {
//                                editorState.resizeMap(newWidth: editorState.mapData.width + 1, newHeight: editorState.mapData.height)
//                            }
//                        }
//                        .font(.system(size: 14, weight: .medium))
//                        .foregroundColor(editorState.mapData.width < 100 ? .blue : .secondary)
//                        .disabled(editorState.mapData.width >= 100)
//                    }
//                }
//                
//                HStack(spacing: 8) {
//                    Text("Height:")
//                        .font(.system(size: 14, weight: .medium))
//                        .frame(width: 50, alignment: .leading)
//                    
//                    HStack(spacing: 8) {
//                        Button("-") {
//                            if editorState.mapData.height > 10 {
//                                editorState.resizeMap(newWidth: editorState.mapData.width, newHeight: editorState.mapData.height - 1)
//                            }
//                        }
//                        .font(.system(size: 14, weight: .medium))
//                        .foregroundColor(editorState.mapData.height > 10 ? .blue : .secondary)
//                        .disabled(editorState.mapData.height <= 10)
//                        
//                        Text("\(editorState.mapData.height)")
//                            .font(.system(size: 14, weight: .medium))
//                            .frame(width: 40)
//                        
//                        Button("+") {
//                            if editorState.mapData.height < 100 {
//                                editorState.resizeMap(newWidth: editorState.mapData.width, newHeight: editorState.mapData.height + 1)
//                            }
//                        }
//                        .font(.system(size: 14, weight: .medium))
//                        .foregroundColor(editorState.mapData.height < 100 ? .blue : .secondary)
//                        .disabled(editorState.mapData.height >= 100)
//                    }
//                }
//            }
//            
//            VStack(spacing: 12) {
//                HStack {
//                    Text("Quick Presets")
//                        .font(.subheadline)
//                        .fontWeight(.medium)
//                        .foregroundColor(.secondary)
//                    Spacer()
//                }
//                
//                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
//                    PresetButton(title: "Small", subtitle: "20×20") {
//                        editorState.resizeMap(newWidth: 20, newHeight: 20)
//                    }
//                    
//                    PresetButton(title: "Medium", subtitle: "40×40") {
//                        editorState.resizeMap(newWidth: 40, newHeight: 40)
//                    }
//                    
//                    PresetButton(title: "Large", subtitle: "60×60") {
//                        editorState.resizeMap(newWidth: 60, newHeight: 60)
//                    }
//                    
//                    PresetButton(title: "Custom", subtitle: "Current") {
//                        // Could open a custom size dialog
//                    }
//                }
//            }
//        }
//        .padding(20)
//        .background(Color(UIColor.systemBackground))
//        .cornerRadius(12)
//        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
//    }
//    
//    func handleKeyDown(_ key: String) {
//        switch key.lowercased() {
//        case "w":
//            if !pressedKeys.contains(key) {
//                pressedKeys.insert(key)
//                editorState.startMoving(direction: .up)
//            }
//        case "s":
//            if !pressedKeys.contains(key) {
//                pressedKeys.insert(key)
//                editorState.startMoving(direction: .down)
//            }
//        case "a":
//            if !pressedKeys.contains(key) {
//                pressedKeys.insert(key)
//                editorState.startMoving(direction: .left)
//            }
//        case "d":
//            if !pressedKeys.contains(key) {
//                pressedKeys.insert(key)
//                editorState.startMoving(direction: .right)
//            }
//        case "r":
//            editorState.resetCamera()
//        default:
//            break
//        }
//    }
//    
//    func handleKeyUp(_ key: String) {
//        pressedKeys.remove(key)
//        
//        switch key.lowercased() {
//        case "w", "s", "a", "d":
//            editorState.stopMoving()
//            
//            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
//                if self.pressedKeys.contains("w") {
//                    self.editorState.startMoving(direction: .up)
//                } else if self.pressedKeys.contains("s") {
//                    self.editorState.startMoving(direction: .down)
//                } else if self.pressedKeys.contains("a") {
//                    self.editorState.startMoving(direction: .left)
//                } else if self.pressedKeys.contains("d") {
//                    self.editorState.startMoving(direction: .right)
//                }
//            }
//        default:
//            break
//        }
//    }
//    
//    private var tilePaletteView: some View {
//        VStack(spacing: 16) {
//            HStack {
//                Label(editorState.editMode == .tile ? "Tile Palette" : "Ore Palette",
//                      systemImage: editorState.editMode == .tile ? "paintpalette.fill" : "gem")
//                    .font(.headline)
//                    .foregroundColor(.primary)
//                
//                Spacer()
//            }
//            
//            ScrollView {
//                if editorState.editMode == .tile {
//                    LazyVStack(spacing: 16) {
//                        ForEach(TileCategory.allCases, id: \.self) { category in
//                            TileCategorySection(
//                                category: category,
//                                selectedTile: $editorState.selectedTile
//                            )
//                        }
//                    }
//                } else {
//                    VStack(spacing: 16) {
//                        HStack {
//                            Label("Ores", systemImage: "gem")
//                                .font(.subheadline)
//                                .fontWeight(.semibold)
//                                .foregroundColor(.secondary)
//                            
//                            Spacer()
//                        }
//                        
//                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 12) {
//                            ForEach(OreType.allCases, id: \.self) { oreType in
//                                OrePaletteItem(
//                                    oreType: oreType,
//                                    isSelected: editorState.selectedOre == oreType
//                                ) {
//                                    editorState.selectedOre = oreType
//                                }
//                            }
//                        }
//                    }
//                }
//            }
//            .frame(maxHeight: 400)
//        }
//        .padding(20)
//        .background(Color(UIColor.systemBackground))
//        .cornerRadius(12)
//        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
//    }
//}
//
//// MARK: - Helper Views
//struct PresetButton: View {
//    let title: String
//    let subtitle: String
//    let action: () -> Void
//    
//    var body: some View {
//        Button(action: action) {
//            VStack(spacing: 4) {
//                Text(title)
//                    .font(.system(size: 14, weight: .semibold))
//                    .foregroundColor(.primary)
//                
//                Text(subtitle)
//                    .font(.system(size: 12))
//                    .foregroundColor(.secondary)
//            }
//            .frame(maxWidth: .infinity)
//            .padding(.vertical, 8)
//            .background(Color(UIColor.tertiarySystemFill))
//            .cornerRadius(8)
//        }
//        .buttonStyle(.plain)
//    }
//}
//
//struct TileView: View {
//    let tileType: TileType
//    let oreType: OreType
//    let size: CGFloat
//    let showSizeIndicator: Bool
//    
//    init(tileType: TileType, oreType: OreType = .none, size: CGFloat, showSizeIndicator: Bool = false) {
//        self.tileType = tileType
//        self.oreType = oreType
//        self.size = size
//        self.showSizeIndicator = showSizeIndicator
//    }
//    
//    var body: some View {
//        ZStack {
//            Group {
//                if !tileType.imageName.isEmpty {
//                    if let uiImage = UIImage(named: tileType.imageName) {
//                        Image(uiImage: uiImage)
//                            .resizable()
//                            .aspectRatio(contentMode: .fill)
//                    } else {
//                        Rectangle()
//                            .fill(tileType.fallbackColor)
//                    }
//                } else {
//                    Rectangle()
//                        .fill(tileType.fallbackColor)
//                }
//            }
//            
//            if oreType != .none {
//                Group {
//                    if !oreType.imageName.isEmpty {
//                        if let oreImage = UIImage(named: oreType.imageName) {
//                            Image(uiImage: oreImage)
//                                .resizable()
//                                .aspectRatio(contentMode: .fill)
//                                .opacity(0.8)
//                        } else {
//                            Rectangle()
//                                .fill(oreType.fallbackColor)
//                        }
//                    } else {
//                        Rectangle()
//                            .fill(oreType.fallbackColor)
//                    }
//                }
//            }
//        }
//        .frame(width: size, height: size)
//        .clipped()
//        .overlay(
//            (tileType.size == .large && showSizeIndicator) ?
//            VStack {
//                HStack {
//                    Spacer()
//                    Text("9×9")
//                        .font(.system(size: max(6, size * 0.15), weight: .bold))
//                        .foregroundColor(.white)
//                        .padding(1)
//                        .background(Color.black.opacity(0.7))
//                        .cornerRadius(2)
//                }
//                Spacer()
//            }
//            .padding(2)
//            : nil
//        )
//    }
//}
//
//struct TileCategorySection: View {
//    let category: TileCategory
//    @Binding var selectedTile: TileType
//    
//    private var tilesInCategory: [TileType] {
//        TileType.allCases.filter { $0.category == category }
//    }
//    
//    var body: some View {
//        VStack(spacing: 12) {
//            HStack {
//                Label(category.rawValue, systemImage: category.icon)
//                    .font(.subheadline)
//                    .fontWeight(.semibold)
//                    .foregroundColor(.secondary)
//                
//                Spacer()
//            }
//            
//            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 12) {
//                ForEach(tilesInCategory, id: \.self) { tileType in
//                    TilePaletteItem(
//                        tileType: tileType,
//                        isSelected: selectedTile == tileType
//                    ) {
//                        selectedTile = tileType
//                    }
//                }
//            }
//        }
//    }
//}
//
//struct TilePaletteItem: View {
//    let tileType: TileType
//    let isSelected: Bool
//    let action: () -> Void
//    
//    var body: some View {
//        Button(action: action) {
//            VStack(spacing: 8) {
//                TileView(
//                    tileType: tileType,
//                    size: 50,
//                    showSizeIndicator: true
//                )
//                .cornerRadius(8)
//                .overlay(
//                    RoundedRectangle(cornerRadius: 8)
//                        .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 3)
//                )
//                .overlay(
//                    RoundedRectangle(cornerRadius: 8)
//                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
//                )
//                
//                Text(tileType.name)
//                    .font(.system(size: 12, weight: .medium))
//                    .foregroundColor(isSelected ? .blue : .primary)
//                    .lineLimit(1)
//            }
//        }
//        .scaleEffect(isSelected ? 1.05 : 1.0)
//        .animation(.easeInOut(duration: 0.15), value: isSelected)
//    }
//}
//
//struct OrePaletteItem: View {
//    let oreType: OreType
//    let isSelected: Bool
//    let action: () -> Void
//    
//    var body: some View {
//        Button(action: action) {
//            VStack(spacing: 8) {
//                ZStack {
//                    Rectangle()
//                        .fill(Color.gray.opacity(0.6))
//                        .frame(width: 50, height: 50)
//                    
//                    if oreType != .none {
//                        if !oreType.imageName.isEmpty {
//                            if let oreImage = UIImage(named: oreType.imageName) {
//                                Image(uiImage: oreImage)
//                                    .resizable()
//                                    .frame(width: 50, height: 50)
//                                    .opacity(0.8)
//                            } else {
//                                Rectangle()
//                                    .fill(oreType.fallbackColor)
//                                    .frame(width: 50, height: 50)
//                            }
//                        }
//                    }
//                }
//                .cornerRadius(8)
//                .overlay(
//                    RoundedRectangle(cornerRadius: 8)
//                        .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 3)
//                )
//                .overlay(
//                    RoundedRectangle(cornerRadius: 8)
//                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
//                )
//                
//                Text(oreType.name)
//                    .font(.system(size: 12, weight: .medium))
//                    .foregroundColor(isSelected ? .blue : .primary)
//                    .lineLimit(1)
//            }
//        }
//        .scaleEffect(isSelected ? 1.05 : 1.0)
//        .animation(.easeInOut(duration: 0.15), value: isSelected)
//    }
//}
//
//// MARK: - Export/Import Views
//struct ExportView: View {
//    @Binding var jsonString: String
//    @Binding var coreLoadout: [String: Int]
//    @Binding var includeCoreLoadout: Bool
//    let onExport: () -> Void
//    @Environment(\.dismiss) private var dismiss
//    
//    var body: some View {
//        NavigationView {
//            VStack(spacing: 20) {
//                VStack(alignment: .leading, spacing: 12) {
//                    Toggle("Include Core Loadout", isOn: $includeCoreLoadout)
//                        .padding()
//                        .background(Color(UIColor.secondarySystemBackground))
//                        .cornerRadius(8)
//                    
//                    if includeCoreLoadout {
//                        Text("Configure core loadout or leave empty for default")
//                            .font(.caption)
//                            .foregroundColor(.secondary)
//                    }
//                }
//                
//                ScrollView {
//                    Text(jsonString)
//                        .font(.system(.body, design: .monospaced))
//                        .frame(maxWidth: .infinity, alignment: .leading)
//                        .padding()
//                        .background(Color(UIColor.secondarySystemBackground))
//                        .cornerRadius(8)
//                }
//                
//                HStack(spacing: 16) {
//                    Button("Copy to Clipboard") {
//                        UIPasteboard.general.string = jsonString
//                    }
//                    .buttonStyle(.bordered)
//                    .frame(maxWidth: .infinity)
//                    
//                    Button("Share") {
//                        let activityVC = UIActivityViewController(activityItems: [jsonString], applicationActivities: nil)
//                        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
//                           let window = windowScene.windows.first {
//                            window.rootViewController?.present(activityVC, animated: true)
//                        }
//                    }
//                    .buttonStyle(.borderedProminent)
//                    .frame(maxWidth: .infinity)
//                }
//                .padding()
//            }
//            .navigationTitle("Export Map")
//            .navigationBarTitleDisplayMode(.inline)
//            .toolbar {
//                ToolbarItem(placement: .navigationBarTrailing) {
//                    Button("Done") {
//                        dismiss()
//                    }
//                }
//            }
//            .onAppear {
//                onExport()
//            }
//        }
//    }
//}
//
//struct ImportView: View {
//    @Binding var importText: String
//    @Binding var importError: String?
//    let onImport: () -> Void
//    @Environment(\.dismiss) private var dismiss
//    
//    var body: some View {
//        NavigationView {
//            VStack(spacing: 20) {
//                Text("Paste your map JSON data below:")
//                    .frame(maxWidth: .infinity, alignment: .leading)
//                
//                ScrollView {
//                    TextEditor(text: $importText)
//                        .font(.system(.body, design: .monospaced))
//                        .frame(minHeight: 200)
//                }
//                .background(Color(UIColor.secondarySystemBackground))
//                .cornerRadius(8)
//                
//                if let error = importError {
//                    Text(error)
//                        .foregroundColor(.red)
//                        .frame(maxWidth: .infinity, alignment: .leading)
//                }
//                
//                Spacer()
//                
//                Button("Import Map") {
//                    onImport()
//                }
//                .buttonStyle(.borderedProminent)
//                .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
//                .padding()
//            }
//            .navigationTitle("Import Map")
//            .navigationBarTitleDisplayMode(.inline)
//            .toolbar {
//                ToolbarItem(placement: .navigationBarTrailing) {
//                    Button("Cancel") {
//                        dismiss()
//                        importText = ""
//                        importError = nil
//                    }
//                }
//                ToolbarItem(placement: .navigationBarLeading) {
//                    Button("Paste") {
//                        if let clipboardString = UIPasteboard.general.string {
//                            importText = clipboardString
//                            importError = nil
//                        }
//                    }
//                }
//            }
//        }
//    }
//}
//
//// MARK: - Preview
//struct MapEditorView_Previews: PreviewProvider {
//    static var previews: some View {
//        MapEditorView()
//    }
//}
