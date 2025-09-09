//
//  MapViewer.swift
//  Factdustry
//
//  Created by Bright on 6/3/25.
//

import SwiftUI

// MARK: - JSON Import Support (if not already available)
#if !MAPDATA_JSON_SUPPORT
struct ImportedMapData: Codable {
    let metadata: ImportedMetadata
    let tileTranslations: [String: String]
    let oreTranslations: [String: String]?
    let tiles: [String]
    let ores: [String]?
}

struct ImportedMetadata: Codable {
    let width: Int
    let height: Int
    let name: String
}

enum MapImportError: Error, LocalizedError {
    case invalidJSON
    case missingRequiredFields
    case invalidDimensions
    case tileDataMismatch
    case oreDataMismatch
    case unsupportedTileType(String)
    case unsupportedOreType(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "The file contains invalid JSON data"
        case .missingRequiredFields:
            return "Required fields are missing from the map data"
        case .invalidDimensions:
            return "Map dimensions are invalid or don't match tile data"
        case .tileDataMismatch:
            return "Tile data doesn't match the specified dimensions"
        case .oreDataMismatch:
            return "Ore data doesn't match the specified dimensions"
        case .unsupportedTileType(let type):
            return "Unsupported tile type: \(type)"
        case .unsupportedOreType(let type):
            return "Unsupported ore type: \(type)"
        }
    }
}

// Update MapData to include ore layer
extension MapData {
    /// Import MapData from JSON Data
    static func fromJSONData(_ jsonData: Data) throws -> MapData {
        let decoder = JSONDecoder()
        
        do {
            let importedData = try decoder.decode(ImportedMapData.self, from: jsonData)
            return try convertImportedData(importedData)
        } catch {
            throw MapImportError.invalidJSON
        }
    }
    
    /// Convert imported JSON structure to MapData
    private static func convertImportedData(_ importedData: ImportedMapData) throws -> MapData {
        let metadata = importedData.metadata
        
        // Validate dimensions
        guard metadata.width > 0 && metadata.height > 0 &&
              metadata.width <= 200 && metadata.height <= 200 else {
            throw MapImportError.invalidDimensions
        }
        
        // Validate tile data dimensions
        guard importedData.tiles.count == metadata.height else {
            throw MapImportError.tileDataMismatch
        }
        
        // Convert tile strings to TileType array
        var tiles: [[TileType]] = []
        
        for rowString in importedData.tiles {
            guard rowString.count == metadata.width else {
                throw MapImportError.tileDataMismatch
            }
            
            var row: [TileType] = []
            for char in rowString {
                let tileChar = String(char)
                
                guard let tileType = TileType(rawValue: tileChar) else {
                    throw MapImportError.unsupportedTileType(tileChar)
                }
                
                row.append(tileType)
            }
            tiles.append(row)
        }
        
        // Convert ore strings to OreType array (if present)
        var ores: [[OreType]] = Array(repeating: Array(repeating: .none, count: metadata.width), count: metadata.height)
        
        if let oreData = importedData.ores {
            guard oreData.count == metadata.height else {
                throw MapImportError.oreDataMismatch
            }
            
            for (rowIndex, rowString) in oreData.enumerated() {
                guard rowString.count == metadata.width else {
                    throw MapImportError.oreDataMismatch
                }
                
                var row: [OreType] = []
                for char in rowString {
                    let oreChar = String(char)
                    
                    guard let oreType = OreType(rawValue: oreChar) else {
                        throw MapImportError.unsupportedOreType(oreChar)
                    }
                    
                    row.append(oreType)
                }
                ores[rowIndex] = row
            }
        }
        
        // Create MapData
        var mapData = MapData(width: metadata.width, height: metadata.height)
        mapData.tiles = tiles
        mapData.ores = ores
        mapData.metadata.name = metadata.name
        
        return mapData
    }
}
#endif

// MARK: - Map Display Configuration
struct MapDisplayConfig {
    var tileSize: CGFloat = 32
    var showGrid: Bool = false
    var gridColor: Color = Color.white.opacity(0.2)
    var gridLineWidth: CGFloat = 0.5
    var cornerRadius: CGFloat = 0
    var enableInteraction: Bool = false
    var backgroundColor: Color = Color.clear
    
    // Preset configurations
    static let game = MapDisplayConfig(
        tileSize: 32,
        showGrid: false,
        cornerRadius: 8,
        enableInteraction: true
    )
    
    static let preview = MapDisplayConfig(
        tileSize: 16,
        showGrid: true,
        cornerRadius: 4
    )
    
    static let editor = MapDisplayConfig(
        tileSize: 24,
        showGrid: true,
        gridColor: Color.black.opacity(0.1),
        cornerRadius: 2
    )
    
    static let minimap = MapDisplayConfig(
        tileSize: 8,
        showGrid: false
    )
}

// MARK: - Map Display View
struct MapDisplayView: View {
    let mapData: MapData
    let config: MapDisplayConfig
    
    // Optional interaction callbacks
    var onTileTap: ((Int, Int, TileType, OreType) -> Void)?
    var onTileLongPress: ((Int, Int, TileType, OreType) -> Void)?
    
    init(
        mapData: MapData,
        config: MapDisplayConfig = .game,
        onTileTap: ((Int, Int, TileType, OreType) -> Void)? = nil,
        onTileLongPress: ((Int, Int, TileType, OreType) -> Void)? = nil
    ) {
        self.mapData = mapData
        self.config = config
        self.onTileTap = onTileTap
        self.onTileLongPress = onTileLongPress
    }
    
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                // Base terrain grid (excluding vents/geysers)
                LazyVStack(spacing: config.showGrid ? 0 : 0) {
                    ForEach(0..<mapData.height, id: \.self) { y in
                        LazyHStack(spacing: config.showGrid ? 0 : 0) {
                            ForEach(0..<mapData.width, id: \.self) { x in
                                let tileType = mapData.tiles[y][x]
                                let oreType = mapData.ores[y][x]
                                
                                baseTileDisplayView(
                                    tileType: tileType,
                                    oreType: oreType,
                                    size: config.tileSize,
                                    showGrid: config.showGrid,
                                    gridColor: config.gridColor,
                                    gridLineWidth: config.gridLineWidth
                                )
                                .onTapGesture {
                                    if config.enableInteraction {
                                        onTileTap?(x, y, tileType, oreType)
                                    }
                                }
                                .onLongPressGesture {
                                    if config.enableInteraction {
                                        onTileLongPress?(x, y, tileType, oreType)
                                    }
                                }
                            }
                        }
                    }
                }
                
                // Vent/Geyser overlay (like TerrainGenerator)
                ventGeyserOverlay(tileSize: config.tileSize)
                    .allowsHitTesting(false)
            }
            .background(config.backgroundColor)
            .cornerRadius(config.cornerRadius)
        }
    }
    
    /// Render all vents and geysers as an overlay on top of the base terrain (like TerrainGenerator)
    @ViewBuilder
    private func ventGeyserOverlay(tileSize: CGFloat) -> some View {
        ForEach(0 ..< mapData.width, id: \.self) { x in
            ForEach(0 ..< mapData.height, id: \.self) { y in
                let tile = mapData.tiles[y][x]
                let ore = mapData.ores[y][x]
                
                if tile == .vent || tile == .geyser {
                    Group {
                        if !tile.imageName.isEmpty {
                            Image(tile.imageName)
                                .resizable()
                                .frame(width: tileSize * 3, height: tileSize * 3)
                        } else {
                            // Fallback: draw a colored circle if no asset
                            Circle()
                                .fill(tile.fallbackColor)
                                .frame(width: tileSize * 3, height: tileSize * 3)
                        }
                    }
                    .position(
                        x: CGFloat(x) * tileSize + tileSize / 2,
                        y: CGFloat(y) * tileSize + tileSize / 2
                    )
                    .onTapGesture {
                        if config.enableInteraction {
                            onTileTap?(x, y, tile, ore)
                        }
                    }
                    .onLongPressGesture {
                        if config.enableInteraction {
                            onTileLongPress?(x, y, tile, ore)
                        }
                    }
                }
            }
        }
        .frame(
            width: CGFloat(mapData.width) * tileSize,
            height: CGFloat(mapData.height) * tileSize,
            alignment: .topLeading
        )
    }
}

// MARK: - Camera-Controlled Map Display View
struct CameraControlledMapDisplayView: View {
    let mapData: MapData
    let config: MapDisplayConfig
    @ObservedObject var cameraController: CameraController
    
    // Optional interaction callbacks
    var onTileTap: ((Int, Int, TileType, OreType) -> Void)?
    var onTileLongPress: ((Int, Int, TileType, OreType) -> Void)?
    
    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    // Base terrain grid
                    LazyVStack(spacing: config.showGrid ? 1 : 0) {
                        ForEach(0..<mapData.height, id: \.self) { y in
                            LazyHStack(spacing: config.showGrid ? 1 : 0) {
                                ForEach(0..<mapData.width, id: \.self) { x in
                                    let tileType = mapData.tiles[y][x]
                                    let oreType = mapData.ores[y][x]
                                    
                                    baseTileDisplayView(
                                        tileType: tileType,
                                        oreType: oreType,
                                        size: config.tileSize * cameraController.zoomScale,
                                        showGrid: config.showGrid,
                                        gridColor: config.gridColor,
                                        gridLineWidth: config.gridLineWidth
                                    )
                                    .onTapGesture {
                                        if config.enableInteraction {
                                            onTileTap?(x, y, tileType, oreType)
                                        }
                                    }
                                    .onLongPressGesture {
                                        if config.enableInteraction {
                                            onTileLongPress?(x, y, tileType, oreType)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    
                    // Vent/Geyser overlay
                    ventGeyserOverlay(tileSize: config.tileSize * cameraController.zoomScale)
                        .allowsHitTesting(false)
                }
                .background(config.backgroundColor)
                .cornerRadius(config.cornerRadius)
                .offset(x: cameraController.offset.x, y: cameraController.offset.y)
            }
            .scrollDisabled(true) // Disable scroll gestures since we're using WASD
            .gesture(
                // Keep magnification gesture for zoom
                MagnificationGesture()
                    .onChanged { value in
                        cameraController.zoom(by: value / cameraController.zoomScale)
                    }
            )
        }
        .clipped()
    }
    
    /// Render all vents and geysers as an overlay
    @ViewBuilder
    private func ventGeyserOverlay(tileSize: CGFloat) -> some View {
        ForEach(0 ..< mapData.width, id: \.self) { x in
            ForEach(0 ..< mapData.height, id: \.self) { y in
                let tile = mapData.tiles[y][x]
                let ore = mapData.ores[y][x]
                
                if tile == .vent || tile == .geyser {
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
                    .onTapGesture {
                        if config.enableInteraction {
                            onTileTap?(x, y, tile, ore)
                        }
                    }
                    .onLongPressGesture {
                        if config.enableInteraction {
                            onTileLongPress?(x, y, tile, ore)
                        }
                    }
                }
            }
        }
        .frame(
            width: CGFloat(mapData.width) * tileSize,
            height: CGFloat(mapData.height) * tileSize,
            alignment: .topLeading
        )
    }
}

// MARK: - Base Tile Display View (Optimized for Performance, excludes vents/geysers, includes ore overlays)
@ViewBuilder
private func baseTileDisplayView(
    tileType: TileType,
    oreType: OreType,
    size: CGFloat,
    showGrid: Bool,
    gridColor: Color,
    gridLineWidth: CGFloat
) -> some View {
    ZStack {
        // Base tile layer
        Group {
            if tileType == .vent || tileType == .geyser {
                // For vents/geysers, render as transparent placeholder in base grid
                Rectangle()
                    .fill(tileType.fallbackColor.opacity(0.3))
                    .frame(width: size, height: size)
            } else if !tileType.imageName.isEmpty, let uiImage = UIImage(named: tileType.imageName) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                // Fallback to color if image doesn't exist or imageName is empty
                Rectangle()
                    .fill(tileType.fallbackColor)
                    .frame(width: size, height: size)
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
                            .frame(width: size, height: size)
                            .opacity(0.8) // Slightly transparent so wall shows through
                            .clipped()
                    } else {
                        // Fallback to colored overlay
                        Rectangle()
                            .fill(oreType.fallbackColor)
                            .frame(width: size, height: size)
                    }
                } else {
                    // Fallback to colored overlay
                    Rectangle()
                        .fill(oreType.fallbackColor)
                        .frame(width: size, height: size)
                }
            }
        }
    }
    .overlay(
        showGrid ?
        Rectangle()
            .stroke(gridColor, lineWidth: gridLineWidth)
        : nil
    )
}

// MARK: - Convenience Initializers
extension MapDisplayView {
    
    /// Create from JSON string
    init?(
        jsonString: String,
        config: MapDisplayConfig = .game,
        onTileTap: ((Int, Int, TileType, OreType) -> Void)? = nil,
        onTileLongPress: ((Int, Int, TileType, OreType) -> Void)? = nil
    ) {
        do {
            let mapData = try MapData.fromJSON(jsonString)
            self.init(
                mapData: mapData,
                config: config,
                onTileTap: onTileTap,
                onTileLongPress: onTileLongPress
            )
        } catch {
            return nil
        }
    }
    
    /// Create from JSON Data
    init?(
        jsonData: Data,
        config: MapDisplayConfig = .game,
        onTileTap: ((Int, Int, TileType, OreType) -> Void)? = nil,
        onTileLongPress: ((Int, Int, TileType, OreType) -> Void)? = nil
    ) {
        do {
            let mapData = try MapData.fromJSONData(jsonData)
            self.init(
                mapData: mapData,
                config: config,
                onTileTap: onTileTap,
                onTileLongPress: onTileLongPress
            )
        } catch {
            return nil
        }
    }
    
    /// Create from file URL
    init?(
        fileURL: URL,
        config: MapDisplayConfig = .game,
        onTileTap: ((Int, Int, TileType, OreType) -> Void)? = nil,
        onTileLongPress: ((Int, Int, TileType, OreType) -> Void)? = nil
    ) {
        do {
            let mapData = try MapData.fromJSONFile(at: fileURL)
            self.init(
                mapData: mapData,
                config: config,
                onTileTap: onTileTap,
                onTileLongPress: onTileLongPress
            )
        } catch {
            return nil
        }
    }
}

// MARK: - Camera-Controlled Map Extensions
extension CameraControlledMapDisplayView {
    
    /// Create from file URL with camera controls
    init?(
        fileURL: URL,
        cameraController: CameraController,
        config: MapDisplayConfig = .game,
        onTileTap: ((Int, Int, TileType, OreType) -> Void)? = nil,
        onTileLongPress: ((Int, Int, TileType, OreType) -> Void)? = nil
    ) {
        do {
            let mapData = try MapData.fromJSONFile(at: fileURL)
            self.mapData = mapData
            self.config = config
            self.cameraController = cameraController
            self.onTileTap = onTileTap
            self.onTileLongPress = onTileLongPress
        } catch {
            return nil
        }
    }
}

// MARK: - Map Preview Component
struct MapPreviewCard: View {
    let mapData: MapData
    let onSelect: (() -> Void)?
    
    init(mapData: MapData, onSelect: (() -> Void)? = nil) {
        self.mapData = mapData
        self.onSelect = onSelect
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Map preview
            MapDisplayView(mapData: mapData, config: .preview)
                .frame(height: 120)
                .clipped()
            
            // Map info
            VStack(alignment: .leading, spacing: 4) {
                Text(mapData.metadata.name)
                    .font(.headline)
                    .lineLimit(1)
                
                Text("\(mapData.width) × \(mapData.height)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .background(Color(UIColor.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
        .onTapGesture {
            onSelect?()
        }
    }
}

// MARK: - Interactive Game Map View
struct GameMapView: View {
    let mapData: MapData
    @State private var selectedTile: (x: Int, y: Int, type: TileType, ore: OreType)?
    @StateObject private var cameraController = CameraController()
    
    var body: some View {
        VStack(spacing: 0) {
            // Map info header
            HStack {
                VStack(alignment: .leading) {
                    Text(mapData.metadata.name)
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text("\(mapData.width) × \(mapData.height)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Zoom controls
                HStack {
                    Button("-") {
                        cameraController.zoom(by: 0.75)
                    }
                    
                    Text("\(Int(cameraController.zoomScale * 100))%")
                        .frame(width: 50)
                    
                    Button("+") {
                        cameraController.zoom(by: 1.25)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(UIColor.tertiarySystemFill))
                .cornerRadius(8)
            }
            .padding()
            .background(Color(UIColor.systemBackground))
            
            // Camera-controlled map display
            CameraControlledMapDisplayView(
                mapData: mapData,
                config: MapDisplayConfig(
                    tileSize: 32,
                    showGrid: cameraController.zoomScale > 1.0,
                    enableInteraction: true
                ),
                cameraController: cameraController,
                onTileTap: { x, y, tileType, oreType in
                    selectedTile = (x: x, y: y, type: tileType, ore: oreType)
                }
            )
            
            // Selected tile info
            if let selected = selectedTile {
                VStack(spacing: 8) {
                    HStack {
                        TileView(tileType: selected.type, oreType: selected.ore, size: 32)
                            .cornerRadius(4)
                        
                        VStack(alignment: .leading) {
                            Text(selected.type.name)
                                .font(.headline)
                            if selected.ore != .none {
                                Text("+ \(selected.ore.name)")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            Text("Position: \(selected.x), \(selected.y)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Button("Clear") {
                            selectedTile = nil
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding()
                .background(Color(UIColor.secondarySystemBackground))
            }
        }
    }
}
 
extension Bundle {
    /// Get URL for a map file included in your app bundle
    func mapFileURL(named fileName: String) -> URL? {
        // For files like "level1.json" in your app bundle
        return url(forResource: fileName, withExtension: "json")
    }
    
    /// Get all map files from app bundle
    func allMapFileURLs() -> [URL] {
        guard let resourcePath = Bundle.main.resourcePath else { return [] }
        let resourceURL = URL(fileURLWithPath: resourcePath)
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: resourceURL,
                includingPropertiesForKeys: nil
            )
            return contents.filter { $0.pathExtension == "json" }
        } catch {
            print("Error reading bundle contents: \(error)")
            return []
        }
    }
    
    func coreScemFileURL(named name: String) -> URL? {
        return self.url(forResource: "CoreScem_\(name)", withExtension: "json")
    }
}

let mapFileURL = Bundle.main.mapFileURL(named: "Terrain_SG")!

#Preview {
    if let mapView = MapDisplayView(fileURL: mapFileURL) {
        mapView
    }
}
