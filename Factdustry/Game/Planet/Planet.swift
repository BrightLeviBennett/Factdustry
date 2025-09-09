//
//  Planet.swift
//  Factdustry
//
//  Created by Bright on 6/1/25.
//

import SwiftUI
import SceneKit
import GameplayKit
import simd

extension SCNVector3 {
    var length: Float {
        return sqrtf(x * x + y * y + z * z)
    }
    
    func normalized() -> SCNVector3 {
        let len = length
        if len == 0 {
            return SCNVector3Zero
        }
        return SCNVector3(x / len, y / len, z / len)
    }
    
    static func * (vector: SCNVector3, scalar: Float) -> SCNVector3 {
        return SCNVector3(vector.x * scalar, vector.y * scalar, vector.z * scalar)
    }
    
    static func + (left: SCNVector3, right: SCNVector3) -> SCNVector3 {
        return SCNVector3(left.x + right.x, left.y + right.y, left.z + right.z)
    }
    
    static func - (left: SCNVector3, right: SCNVector3) -> SCNVector3 {
        return SCNVector3(left.x - right.x, left.y - right.y, left.z - right.z)
    }
}

// MARK: - Hexagonal Grid System

// Hexagonal grid coordinates (axial coordinates)
struct HexCoordinate {
    let q: Int  // Column (diagonal left-right)
    let r: Int  // Row (vertical)
    
    // Convert to cube coordinates for easier math
    var cube: CubeCoordinate {
        return CubeCoordinate(x: q, y: -q - r, z: r)
    }
    
    // Distance between two hex coordinates
    func distance(to other: HexCoordinate) -> Int {
        let cube1 = self.cube
        let cube2 = other.cube
        return max(abs(cube1.x - cube2.x), abs(cube1.y - cube2.y), abs(cube1.z - cube2.z))
    }
}

struct CubeCoordinate {
    let x: Int
    let y: Int
    let z: Int
    
    var axial: HexCoordinate {
        return HexCoordinate(q: x, r: z)
    }
}

// MARK: - Hexagonal Grid Mapper

class HexGridMapper {
    // Hex grid parameters
    static let hexSize: Float = 1.0        // Size of each hex on the grid
    static let gridRadius: Float = 2.8     // Radius of the sphere to map onto
    static let gridScale: Float = 0.0405      // Scale factor for the grid spacing
    
    // Convert hex coordinate to 2D plane position
    static func hexToPlane(hex: HexCoordinate) -> CGPoint {
        // Standard hex grid math (pointy-top hexagons)
        // Break down complex expressions for Swift compiler
        let qFloat = Float(hex.q)
        let rFloat = Float(hex.r)
        
        // Calculate X coordinate
        let xComponent = 3.0 / 2.0 * qFloat
        let x = hexSize * xComponent * gridScale
        
        // Calculate Y coordinate (break into parts)
        let sqrt3: Float = sqrtf(3.0)  // Use Float version of sqrt
        let yComponent1 = sqrt3 / 2.0 * qFloat
        let yComponent2 = sqrt3 * rFloat
        let yComponent = yComponent1 + yComponent2
        let y = hexSize * yComponent * gridScale
        
        return CGPoint(x: CGFloat(x), y: CGFloat(y))
    }
    
    // Convert 2D plane position to 3D sphere position
    static func planeToSphere(plane: CGPoint) -> SCNVector3 {
        // Map the 2D hex grid onto the sphere surface
        let x = Float(plane.x)
        let y = Float(plane.y)
        
        // Project onto sphere using stereographic projection
        // This maps a 2D plane onto a sphere nicely
        let r2 = x * x + y * y
        let scale = 2.0 / (1.0 + r2)
        
        let sphereX = scale * x
        let sphereY = scale * y
        let sphereZ = (r2 - 1.0) / (1.0 + r2)
        
        // Normalize and scale to planet radius
        let length = sqrtf(sphereX * sphereX + sphereY * sphereY + sphereZ * sphereZ)
        let normalized = SCNVector3(sphereX / length, sphereY / length, sphereZ / length)
        
        return SCNVector3(normalized.x * gridRadius, normalized.y * gridRadius, normalized.z * gridRadius)
    }
    
    // Direct conversion from hex to sphere
    static func hexToSphere(hex: HexCoordinate) -> SCNVector3 {
        let plane = hexToPlane(hex: hex)
        return planeToSphere(plane: plane)
    }
    
    // Get all neighbors of a hex coordinate
    static func getNeighbors(of hex: HexCoordinate) -> [HexCoordinate] {
        let directions = [
            HexCoordinate(q: 1, r: 0),   // East
            HexCoordinate(q: 1, r: -1),  // Northeast
            HexCoordinate(q: 0, r: -1),  // Northwest
            HexCoordinate(q: -1, r: 0),  // West
            HexCoordinate(q: -1, r: 1),  // Southwest
            HexCoordinate(q: 0, r: 1)    // Southeast
        ]
        
        return directions.map { HexCoordinate(q: hex.q + $0.q, r: hex.r + $0.r) }
    }
    
    // Generate hex coordinates in a spiral pattern (like Mindustry)
    static func spiralCoordinates(rings: Int) -> [HexCoordinate] {
        var coordinates: [HexCoordinate] = []
        
        // Start with center
        coordinates.append(HexCoordinate(q: 0, r: 0))
        
        // Add rings around center
        for ring in 1...rings {
            // Start at the "3 o'clock" position of the ring
            var current = HexCoordinate(q: ring, r: -ring)
            
            // Walk around the ring in 6 directions
            let directions = [
                HexCoordinate(q: 0, r: 1),   // Southeast
                HexCoordinate(q: -1, r: 1),  // Southwest
                HexCoordinate(q: -1, r: 0),  // West
                HexCoordinate(q: 0, r: -1),  // Northwest
                HexCoordinate(q: 1, r: -1),  // Northeast
                HexCoordinate(q: 1, r: 0)    // East
            ]
            
            for direction in directions {
                for _ in 0..<ring {
                    coordinates.append(current)
                    current = HexCoordinate(q: current.q + direction.q, r: current.r + direction.r)
                }
            }
        }
        
        return coordinates
    }
}

// MARK: - Sector Data Models

enum SectorStatus {
    case locked
    case available
    case completed
    case inProgress
    
    var color: Color {
        switch self {
        case .locked: return Color.gray.opacity(0.3)
        case .available: return Color.orange
        case .completed: return Color.green
        case .inProgress: return Color.blue
        }
    }
    
    var scnColor: SCNVector3 {
        switch self {
        case .locked: return SCNVector3(0.2, 0.2, 0.2)
        case .available: return SCNVector3(1.0, 0.6, 0.0)
        case .completed: return SCNVector3(0.0, 0.8, 0.0)
        case .inProgress: return SCNVector3(0.0, 0.5, 1.0)
        }
    }
}

enum SectorDifficulty: Int, CaseIterable {
    case easy = 1
    case normal = 2
    case hard = 3
    case insane = 4
    case eradication = 5
    
    var color: Color {
        switch self {
        case .easy: return Color.green
        case .normal: return Color.yellow
        case .hard: return Color.orange
        case .insane: return Color.red
        case .eradication: return Color.purple
        }
    }
}

struct SectorResources: Equatable {
    let copper: Bool
    let graphite: Bool
    let coal: Bool
    let aluminum: Bool
    
    static let none = SectorResources(copper: false, graphite: false, coal: false, aluminum: false)
}

// Updated Sector struct with hex coordinates
struct Sector {
    let id: Int
    let name: String
    let hexCoordinate: HexCoordinate  // New: hex grid coordinate
    var status: SectorStatus  // Made mutable for research updates
    let difficulty: SectorDifficulty
    let resources: SectorResources
    let connectedSectors: [Int]
    let description: String
    let fileIdentifier: String
    
    // Computed property: convert hex coordinate to 3D sphere position
    var sphereCoordinates: SCNVector3 {
        return HexGridMapper.hexToSphere(hex: hexCoordinate)
    }
}

// MARK: - Planet System (NEW)

// Planet configuration struct
struct PlanetConfig {
    let id: String
    let name: String
    let icon: String
    let description: String
    let position: SCNVector3
    let textureGenerator: (Int, Int) -> UIImage
    let sectorsGenerator: (ResearchManager) -> [Sector]
    
    static let allPlanets: [PlanetConfig] = [
        PlanetConfig(
            id: "tarkon",
            name: "Tarkon",
            icon: "🔥",
            description: "A lush green world",
            position: SCNVector3(0, 0, 0), // Center
            textureGenerator: { size, seed in PlanetTextureGenerator.createTarkonTexture(size: size, seed: seed) },
            sectorsGenerator: { researchManager in SectorData.createTarkonSectors(researchManager: researchManager) }
        ),
        PlanetConfig(
            id: "yndora",
            name: "Yndora",
            icon: "🌊",
            description: "A pure water world",
            position: SCNVector3(20, 0, 0), // To the right
            textureGenerator: { size, seed in PlanetTextureGenerator.createYndoraTexture(size: size, seed: seed) },
            sectorsGenerator: { researchManager in SectorData.createYndoraSectors(researchManager: researchManager) }
        ),
        PlanetConfig(
            id: "xerion",
            name: "Xerion",
            icon: "⚡",
            description: "An electric storm world",
            position: SCNVector3(-20, 0, 0), // To the left
            textureGenerator: { size, seed in PlanetTextureGenerator.createXerionTexture(size: size, seed: seed) },
            sectorsGenerator: { researchManager in SectorData.createXerionSectors(researchManager: researchManager) }
        )
    ]
}

// Individual planet instance
class WorldPlanet {
    let config: PlanetConfig
    let planetNode: SCNNode
    let sectorsParentNode: SCNNode
    let planetGroupNode: SCNNode
    var sectors: [Sector] = []
    
    private var sectorNodes: [Int: SCNNode] = [:]
    private var selectionNodes: [Int: SCNNode] = [:]
    private var hitAreaNodes: [Int: SCNNode] = [:]
    
    init(config: PlanetConfig, researchManager: ResearchManager) {
        self.config = config
        self.planetNode = SCNNode()
        self.sectorsParentNode = SCNNode()
        self.planetGroupNode = SCNNode()
        
        setupPlanetNode()
        updateSectors(researchManager: researchManager)
        
        // Position the entire planet group
        planetGroupNode.position = config.position
        planetGroupNode.addChildNode(planetNode)
        planetGroupNode.addChildNode(sectorsParentNode)
    }
    
    private func setupPlanetNode() {
        // Create sphere geometry
        let sphere = SCNSphere(radius: 3.0)
        
        // Create planet material with this planet's texture
        let material = SCNMaterial()
        let planetImage = config.textureGenerator(512, 42)
        
        material.diffuse.contents = planetImage
        material.lightingModel = .phong
        material.emission.contents = nil
        material.isDoubleSided = false
        material.writesToDepthBuffer = true
        material.roughness.contents = nil
        material.metalness.contents = nil
        material.normal.contents = nil
        material.transparency = 1.0
        
        sphere.materials = [material]
        planetNode.geometry = sphere
        planetNode.name = "planet_\(config.id)"
    }
    
    func updateSectors(researchManager: ResearchManager) {
        sectors = config.sectorsGenerator(researchManager)
        createSectorNodes()
    }
    
    private func createSectorNodes() {
        // Clear existing sector nodes
        sectorsParentNode.childNodes.forEach { $0.removeFromParentNode() }
        sectorNodes.removeAll()
        selectionNodes.removeAll()
        hitAreaNodes.removeAll()
        
        for sector in sectors {
            let sectorNode = createSectorNode(for: sector)
            
            // Use hex grid position (computed from hexCoordinate)
            let position = sector.sphereCoordinates.normalized() * 3
            sectorNode.position = position
            
            // FIXED: Orient the sector to be flat against the planet surface
            // The sector should have its normal pointing outward from planet center
            let normal = position.normalized()
            
            // Calculate rotation to align Z-axis with the outward normal
            let defaultNormal = SCNVector3(0, 0, 1)
            
            // FIXED: Handle the special case where vectors are antiparallel (opposite)
            let dotProd = dotProduct(defaultNormal, normal)
            
            if dotProd < -0.999999 {
                // Vectors are antiparallel (pointing in opposite directions)
                // Need a 180-degree rotation around any perpendicular axis
                // Use X-axis for the 180-degree flip
                sectorNode.rotation = SCNVector4(1, 0, 0, Float.pi)
            } else if dotProd > 0.999999 {
                // Vectors are already aligned, no rotation needed
                sectorNode.rotation = SCNVector4(0, 0, 0, 0)
            } else {
                // Normal case: calculate rotation axis and angle
                let rotationAxis = crossProduct(defaultNormal, normal)
                let rotationAngle = acosf(max(-1, min(1, dotProd)))
                
                if rotationAxis.length > 0.001 {
                    let normalizedAxis = rotationAxis.normalized()
                    sectorNode.rotation = SCNVector4(normalizedAxis.x, normalizedAxis.y, normalizedAxis.z, rotationAngle)
                }
            }
            
            sectorsParentNode.addChildNode(sectorNode)
            sectorNodes[sector.id] = sectorNode
            
            // Create selection highlight node (initially hidden)
            let selectionNode = createSelectionHighlight(for: sector)
            selectionNode.position = position
            selectionNode.rotation = sectorNode.rotation
            selectionNode.isHidden = true
            sectorsParentNode.addChildNode(selectionNode)
            selectionNodes[sector.id] = selectionNode
            
            // Create IMPROVED hit area for better selection
            let hitAreaNode = createImprovedHitArea(for: sector, at: position, with: sectorNode.rotation)
            sectorsParentNode.addChildNode(hitAreaNode)
            hitAreaNodes[sector.id] = hitAreaNode
        }
    }
    
    // Helper function for cross product
    private func crossProduct(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
        return SCNVector3(
            a.y * b.z - a.z * b.y,
            a.z * b.x - a.x * b.z,
            a.x * b.y - a.y * b.x
        )
    }
    
    // Helper function for dot product
    private func dotProduct(_ a: SCNVector3, _ b: SCNVector3) -> Float {
        return a.x * b.x + a.y * b.y + a.z * b.z
    }
    
    // IMPROVED: Much better hit areas that are easier to hit
    private func createImprovedHitArea(for sector: Sector, at position: SCNVector3, with rotation: SCNVector4) -> SCNNode {
        // Make hit areas MUCH larger and more reliable
        let hitAreaSize: Float = 1.4
        let hitArea = createHexagonGeometry(scale: hitAreaSize)
        
        // Completely invisible but solid material
        let hitMaterial = SCNMaterial()
        hitMaterial.diffuse.contents = UIColor.clear
        hitMaterial.transparency = 1.0  // Fully transparent
        hitMaterial.isDoubleSided = true  // Hit from both sides
        hitMaterial.colorBufferWriteMask = []  // Don't write to color buffer
        hitMaterial.writesToDepthBuffer = false  // Prevent hidden occlusion
        
        hitArea.materials = [hitMaterial]
        
        let hitNode = SCNNode(geometry: hitArea)
        
        hitNode.position = position
        hitNode.rotation = rotation
        
        // CRITICAL: Proper naming and identification
        hitNode.name = "hit_area_\(sector.id)_\(config.id)"
        hitNode.setValue(sector.id, forKey: "sectorId")
        hitNode.setValue(config.id, forKey: "planetId")
        hitNode.setValue(true, forKey: "isHitArea")
        
        // HIGHEST rendering order to ensure hit priority
        hitNode.renderingOrder = 1000
        
        return hitNode
    }
    
    private func createSectorNode(for sector: Sector) -> SCNNode {
        let node = SCNNode()
        
        // Simple hexagon like Mindustry (not too complex)
        let hexSize: Float = 1.4
        
        // Create the main sector hexagon (semi-transparent with subtle tint)
        let hexagon = createHexagonGeometry(scale: hexSize)
        
        // SEMI-TRANSPARENT sector fill - visible but subtle
        let material = SCNMaterial()
        
        // Very subtle tint based on status, mostly transparent
        let statusColor = sector.status.scnColor
        material.diffuse.contents = UIColor(red: CGFloat(statusColor.x * 0.2),
                                            green: CGFloat(statusColor.y * 0.2),
                                            blue: CGFloat(statusColor.z * 0.2),
                                            alpha: sector.status == .locked ? 0.15 : 0.25)
        
        // Minimal emission for the fill
        material.emission.contents = UIColor(red: CGFloat(statusColor.x * 0.8),
                                             green: CGFloat(statusColor.y * 0.8),
                                             blue: CGFloat(statusColor.z * 0.8),
                                             alpha: 0.1)
        
        material.isDoubleSided = true
        
        hexagon.materials = [material]
        node.geometry = hexagon
        node.renderingOrder = 100
        
        if sector.status != .locked {
            // FIXED: PROMINENT colored outline
            let outlineHex = createHexagonGeometry(scale: hexSize * 1.15, hollow: true)
            let outlineMaterial = SCNMaterial()
            
            // Different outline colors based on sector status
            let outlineColor: UIColor
            let outlineIntensity: CGFloat
            
            switch sector.status {
            case .locked:
                outlineColor = UIColor(red: 0, green: 0, blue: 0, alpha: 0)
                outlineIntensity = 1
            case .available:
                outlineColor = UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
                outlineIntensity = 1.0
            case .completed:
                outlineColor = UIColor(red: 0.95, green: 0.72, blue: 0.25, alpha: 1.0)
                outlineIntensity = 1.0
            case .inProgress:
                outlineColor = UIColor(red: 0.95, green: 0.72, blue: 0.25, alpha: 1.0)
                outlineIntensity = 1.0
            }
            
            outlineMaterial.emission.contents = outlineColor.withAlphaComponent(outlineIntensity)
            outlineMaterial.isDoubleSided = true
            
            outlineHex.materials = [outlineMaterial]
            
            let outlineNode = SCNNode(geometry: outlineHex)
            outlineNode.name = "sector_outline_\(sector.id)_\(config.id)"
            outlineNode.renderingOrder = 200
            node.addChildNode(outlineNode)
            
            // Enhanced pulsing for available sectors
            if sector.status == .available {
                let pulseAction = SCNAction.sequence([
                    SCNAction.fadeOpacity(to: 0.1, duration: 1.0),
                    SCNAction.fadeOpacity(to: 1.0, duration: 1.0)
                ])
                let repeatAction = SCNAction.repeatForever(pulseAction)
                outlineNode.runAction(repeatAction, forKey: "pulse")
            }
        }
        
        // IMPORTANT: Set the name for identification
        node.name = "sector_visual_\(sector.id)_\(config.id)"
        
        // Store sector data in the node for easy access
        node.setValue(sector.id, forKey: "sectorId")
        node.setValue(config.id, forKey: "planetId")
        node.setValue(false, forKey: "isHitArea")
        
        return node
    }
    
    private func createSelectionHighlight(for sector: Sector) -> SCNNode {
        let node = SCNNode()
        let baseSize: Float = 1.4
        
        // Enhanced selection highlight that's always visible
        
        // Outer white selection ring with strong emission
        let outerRing = createHexagonGeometry(scale: baseSize * 1.4, hollow: true, thickness: 0.08)
        let outerMaterial = SCNMaterial()
        outerMaterial.diffuse.contents = UIColor.clear
        outerMaterial.emission.contents = UIColor.white
        outerMaterial.transparency = 0.8
        outerRing.materials = [outerMaterial]
        
        let outerNode = SCNNode(geometry: outerRing)
        outerNode.position = SCNVector3(0, 0, 0.01)
        outerNode.name = "selection_ring"
        node.addChildNode(outerNode)
        
        // Add inner glow ring for extra visibility
        let innerRing = createHexagonGeometry(scale: baseSize * 1.2, hollow: true, thickness: 0.04)
        let innerMaterial = SCNMaterial()
        innerMaterial.diffuse.contents = UIColor.clear
        innerMaterial.emission.contents = UIColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0)
        innerRing.materials = [innerMaterial]
        
        let innerNode = SCNNode(geometry: innerRing)
        innerNode.position = SCNVector3(0, 0, 0.008)
        innerNode.name = "selection_inner_ring"
        node.addChildNode(innerNode)
        
        // Enhanced pulsing animation
        let pulseAction = SCNAction.sequence([
            SCNAction.fadeOpacity(to: 0.6, duration: 0.8),
            SCNAction.fadeOpacity(to: 1.0, duration: 0.8)
        ])
        let repeatAction = SCNAction.repeatForever(pulseAction)
        node.runAction(repeatAction)
        
        return node
    }
    
    private func createHexagonGeometry(scale: Float = 1.0, hollow: Bool = false, thickness: Float = 0.02) -> SCNGeometry {
        let hexSize = 0.15 * scale
        var vertices: [SCNVector3] = []
        var indices: [UInt16] = []
        
        if hollow {
            // Create hollow hexagon (ring)
            let outerSize = hexSize
            let innerSize = hexSize - thickness
            
            // Outer hexagon vertices
            for i in 0..<6 {
                let angle = Float(i) * Float.pi / 3.0
                let x = cosf(angle) * outerSize
                let y = sinf(angle) * outerSize
                vertices.append(SCNVector3(x, y, 0))
            }
            
            // Inner hexagon vertices
            for i in 0..<6 {
                let angle = Float(i) * Float.pi / 3.0
                let x = cosf(angle) * innerSize
                let y = sinf(angle) * innerSize
                vertices.append(SCNVector3(x, y, 0))
            }
            
            // Create ring faces
            for i in 0..<6 {
                let nextI = (i + 1) % 6
                
                // First triangle
                indices.append(UInt16(i))
                indices.append(UInt16(i + 6))
                indices.append(UInt16(nextI))
                
                // Second triangle
                indices.append(UInt16(nextI))
                indices.append(UInt16(i + 6))
                indices.append(UInt16(nextI + 6))
            }
        } else {
            // Create filled hexagon
            vertices.append(SCNVector3(0, 0, 0)) // Center vertex
            
            // Hexagon vertices
            for i in 0..<6 {
                let angle = Float(i) * Float.pi / 3.0
                let x = cosf(angle) * hexSize
                let y = sinf(angle) * hexSize
                vertices.append(SCNVector3(x, y, 0))
            }
            
            // Create triangular faces
            for i in 0..<6 {
                indices.append(0) // Center
                indices.append(UInt16(i + 1))
                indices.append(UInt16((i + 1) % 6 + 1))
            }
        }
        
        let source = SCNGeometrySource(vertices: vertices)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        
        return SCNGeometry(sources: [source], elements: [element])
    }
    
    func updateSelectionHighlight(selectedSectorId: Int?) {
        // Hide all selection highlights
        for (_, selectionNode) in selectionNodes {
            selectionNode.isHidden = true
        }
        
        // Show selection highlight for selected sector
        if let selectedId = selectedSectorId,
           let selectionNode = selectionNodes[selectedId] {
            selectionNode.isHidden = false
        }
    }
}

// MARK: - Planet Texture Generator (NEW)

struct PlanetTextureGenerator {
    @inline(__always) private static func fade(_ t: Float) -> Float {
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    @inline(__always) private static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        return a + (b - a) * t
    }

    @inline(__always) private static func hash2(_ ix: Int32, _ iy: Int32, _ seed: UInt32) -> Float {
        var v = UInt32(bitPattern: ix) &* 0x27d4_eb2d
        v &+= UInt32(bitPattern: iy) &* 0x1656_67b1
        v &+= seed &* 0x9e37_79b9
        v = (v ^ 61) ^ (v >> 16)
        v = v &* 9
        v ^= (v >> 4)
        v = v &* 0x27d4_eb2d
        v ^= (v >> 15)
        return Float(v) / 4294967295.0
    }

    private static func valueNoise2D(x: Float, y: Float, seed: Int) -> Float {
        let s = UInt32(truncatingIfNeeded: seed)
        let xi = floorf(x)
        let yi = floorf(y)
        let xf = x - xi
        let yf = y - yi
        let ix = Int32(xi)
        let iy = Int32(yi)

        let v00 = hash2(ix,     iy,     s)
        let v10 = hash2(ix + 1, iy,     s)
        let v01 = hash2(ix,     iy + 1, s)
        let v11 = hash2(ix + 1, iy + 1, s)

        let u = fade(xf)
        let v = fade(yf)

        let a = lerp(v00, v10, u)
        let b = lerp(v01, v11, u)
        let n = lerp(a, b, v)

        return n * 2.0 - 1.0
    }

    private static func fbmValue2D(x: Float, y: Float, seed: Int, octaves: Int = 3, lacunarity: Float = 2.0, gain: Float = 0.5) -> Float {
        var sum: Float = 0
        var amp: Float = 0.5
        var fx = x
        var fy = y
        var s = seed

        for _ in 0..<octaves {
            sum += amp * valueNoise2D(x: fx, y: fy, seed: s)
            fx *= lacunarity
            fy *= lacunarity
            amp *= gain
            s &+= 1337
        }
        return sum * 0.5 + 0.5
    }

    private static func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float {
        return max(lo, min(hi, v))
    }

    private static func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        return a + (b - a) * t
    }

    // Tarkon texture (green planet)
    static func createTarkonTexture(size: Int = 512, seed: Int = 42) -> UIImage {
        let width = size, height = size
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        )

        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo.rawValue
        ), let buf = ctx.data else {
            return UIImage()
        }

        let pixels = buf.bindMemory(to: UInt8.self, capacity: width * height * bytesPerPixel)

        let r: Float = Float(min(width, height)) * 0.48
        let cx: Float = Float(width) * 0.5
        let cy: Float = Float(height) * 0.5
        let invR: Float = 1.0 / r

        // Vibrant green land-based colors for Tarkon
        let darkGreen = SIMD3<Float>(0.1, 0.6, 0.1)    // Dark forest areas
        let lightGreen = SIMD3<Float>(0.2, 0.8, 0.2)   // Lighter grassland areas
        let mountains = SIMD3<Float>(0.15, 0.7, 0.15)  // Green mountain ranges
        let ice = SIMD3<Float>(0.9, 0.9, 1.0)          // Ice caps

        for y in 0..<height {
            let yy = Float(y)
            for x in 0..<width {
                let xx = Float(x)
                let dx = xx - cx
                let dy = yy - cy
                let dist = sqrtf(dx*dx + dy*dy)
                let idx = (y * width + x) * bytesPerPixel

                if dist > r {
                    pixels[idx+0] = 0
                    pixels[idx+1] = 0
                    pixels[idx+2] = 0
                    pixels[idx+3] = 255
                    continue
                }

                let e1 = fbmValue2D(x: xx * 0.005, y: yy * 0.005, seed: seed, octaves: 4)
                let e2 = fbmValue2D(x: xx * 0.015, y: yy * 0.015, seed: seed + 100, octaves: 3)
                let e3 = fbmValue2D(x: xx * 0.03, y: yy * 0.03, seed: seed + 200, octaves: 2)
                
                let elevation = e1 * 0.6 + e2 * 0.3 + e3 * 0.1
                
                var base: SIMD3<Float>
                
                if elevation < 0.3 {
                    base = darkGreen
                } else if elevation < 0.6 {
                    base = mix(darkGreen, lightGreen, (elevation - 0.3) / 0.3)
                } else if elevation < 0.8 {
                    base = mix(lightGreen, mountains, (elevation - 0.6) / 0.2)
                } else {
                    base = mountains
                }

                let lat = abs(dy * invR)
                if lat > 0.8 {
                    base = mix(base, ice, (lat - 0.8) / 0.2)
                }

                let edge = clamp(1.0 - (dist / r), 0, 1)
                let a = powf(edge, 0.8)

                pixels[idx+0] = UInt8(clamp(base.z * a, 0, 1) * 255)
                pixels[idx+1] = UInt8(clamp(base.y * a, 0, 1) * 255)
                pixels[idx+2] = UInt8(clamp(base.x * a, 0, 1) * 255)
                pixels[idx+3] = 255
            }
        }

        guard let cg = ctx.makeImage() else { return UIImage() }
        return UIImage(cgImage: cg, scale: UIScreen.main.scale, orientation: .up)
    }
    
    // Yndora texture (pure water world)
    static func createYndoraTexture(size: Int = 512, seed: Int = 123) -> UIImage {
        let width = size, height = size
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        )

        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo.rawValue
        ), let buf = ctx.data else {
            return UIImage()
        }

        let pixels = buf.bindMemory(to: UInt8.self, capacity: width * height * bytesPerPixel)

        let r: Float = Float(min(width, height)) * 0.48
        let cx: Float = Float(width) * 0.5
        let cy: Float = Float(height) * 0.5
        let invR: Float = 1.0 / r

        // Pure water colors for Yndora
        let deepOcean = SIMD3<Float>(0.05, 0.15, 0.4)   // Deep blue water
        let midOcean = SIMD3<Float>(0.1, 0.25, 0.5)     // Medium depth water
        let shallowOcean = SIMD3<Float>(0.15, 0.35, 0.6) // Lighter blue water
        let ice = SIMD3<Float>(0.9, 0.9, 1.0)           // Ice caps

        for y in 0..<height {
            let yy = Float(y)
            for x in 0..<width {
                let xx = Float(x)
                let dx = xx - cx
                let dy = yy - cy
                let dist = sqrtf(dx*dx + dy*dy)
                let idx = (y * width + x) * bytesPerPixel

                if dist > r {
                    pixels[idx+0] = 0
                    pixels[idx+1] = 0
                    pixels[idx+2] = 0
                    pixels[idx+3] = 255
                    continue
                }

                let depthNoise1 = fbmValue2D(x: xx * 0.006, y: yy * 0.006, seed: seed, octaves: 3)
                let depthNoise2 = fbmValue2D(x: xx * 0.015, y: yy * 0.015, seed: seed + 50, octaves: 2)
                
                let depth = depthNoise1 * 0.7 + depthNoise2 * 0.3
                
                var base: SIMD3<Float>
                
                if depth < 0.3 {
                    base = deepOcean
                } else if depth < 0.6 {
                    base = mix(deepOcean, midOcean, (depth - 0.3) / 0.3)
                } else {
                    base = mix(midOcean, shallowOcean, (depth - 0.6) / 0.4)
                }

                let lat = abs(dy * invR)
                if lat > 0.9 {
                    base = mix(base, ice, (lat - 0.9) / 0.1)
                }

                let edge = clamp(1.0 - (dist / r), 0, 1)
                let a = powf(edge, 0.8)

                pixels[idx+0] = UInt8(clamp(base.z * a, 0, 1) * 255)
                pixels[idx+1] = UInt8(clamp(base.y * a, 0, 1) * 255)
                pixels[idx+2] = UInt8(clamp(base.x * a, 0, 1) * 255)
                pixels[idx+3] = 255
            }
        }

        guard let cg = ctx.makeImage() else { return UIImage() }
        return UIImage(cgImage: cg, scale: UIScreen.main.scale, orientation: .up)
    }
    
    // NEW: Xerion texture (electric storm world)
    static func createXerionTexture(size: Int = 512, seed: Int = 456) -> UIImage {
        let width = size, height = size
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        )

        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo.rawValue
        ), let buf = ctx.data else {
            return UIImage()
        }

        let pixels = buf.bindMemory(to: UInt8.self, capacity: width * height * bytesPerPixel)

        let r: Float = Float(min(width, height)) * 0.48
        let cx: Float = Float(width) * 0.5
        let cy: Float = Float(height) * 0.5
        let invR: Float = 1.0 / r

        // Electric storm colors for Xerion
        let darkStorm = SIMD3<Float>(0.2, 0.1, 0.4)     // Dark purple storm areas
        let lightStorm = SIMD3<Float>(0.4, 0.2, 0.6)    // Lighter purple areas
        let electric = SIMD3<Float>(0.8, 0.6, 1.0)      // Electric purple highlights
        let ice = SIMD3<Float>(0.9, 0.9, 1.0)           // Ice caps

        for y in 0..<height {
            let yy = Float(y)
            for x in 0..<width {
                let xx = Float(x)
                let dx = xx - cx
                let dy = yy - cy
                let dist = sqrtf(dx*dx + dy*dy)
                let idx = (y * width + x) * bytesPerPixel

                if dist > r {
                    pixels[idx+0] = 0
                    pixels[idx+1] = 0
                    pixels[idx+2] = 0
                    pixels[idx+3] = 255
                    continue
                }

                let storm1 = fbmValue2D(x: xx * 0.008, y: yy * 0.008, seed: seed, octaves: 4)
                let storm2 = fbmValue2D(x: xx * 0.02, y: yy * 0.02, seed: seed + 100, octaves: 3)
                let lightning = fbmValue2D(x: xx * 0.05, y: yy * 0.05, seed: seed + 200, octaves: 2)
                
                let intensity = storm1 * 0.5 + storm2 * 0.3 + lightning * 0.2
                
                var base: SIMD3<Float>
                
                if intensity < 0.3 {
                    base = darkStorm
                } else if intensity < 0.7 {
                    base = mix(darkStorm, lightStorm, (intensity - 0.3) / 0.4)
                } else {
                    base = mix(lightStorm, electric, (intensity - 0.7) / 0.3)
                }

                let lat = abs(dy * invR)
                if lat > 0.85 {
                    base = mix(base, ice, (lat - 0.85) / 0.15)
                }

                let edge = clamp(1.0 - (dist / r), 0, 1)
                let a = powf(edge, 0.8)

                pixels[idx+0] = UInt8(clamp(base.z * a, 0, 1) * 255)
                pixels[idx+1] = UInt8(clamp(base.y * a, 0, 1) * 255)
                pixels[idx+2] = UInt8(clamp(base.x * a, 0, 1) * 255)
                pixels[idx+3] = 255
            }
        }

        guard let cg = ctx.makeImage() else { return UIImage() }
        return UIImage(cgImage: cg, scale: UIScreen.main.scale, orientation: .up)
    }
}

// MARK: - SceneKit Scene Coordinator (Updated)

final class PlanetSceneCoordinator: NSObject, ObservableObject, SCNSceneRendererDelegate {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    let worldNode = SCNNode()
    
    @Published var selectedSectorId: Int?
    @Published var hoveredSectorId: Int?
    @Published var currentPlanetId: String = "tarkon" {
        didSet {
            if currentPlanetId != oldValue && planets.count > 0 {
                transitionToPlanet(currentPlanetId)
            }
        }
    }
    
    // Planet management
    private var planets: [String: WorldPlanet] = [:]
    private var currentPlanet: WorldPlanet?
    
    // Camera system for planet transitions
    private var cameraDistance: Float = 8.0
    private var planetRotationY: Float = 0.0
    private var planetTiltX: Float = 0.0
    private let minDistance: Float = 5.0
    private let maxDistance: Float = 15.0
    private let maxTiltX: Float = Float.pi / 2.5
    
    // Inertia properties
    private var rotationVelocityY: Float = 0.0
    private var tiltVelocityX: Float = 0.0
    private var isDecelerating = false
    private var decelerationTimer: Timer?
    
    // Transition properties
    private var isTransitioning = false
    
    override init() {
        super.init()
        setupScene()
    }
    
    func setupScene() {
        // Set scene background
        scene.background.contents = UIColor(red: 0.02, green: 0.02, blue: 0.08, alpha: 1.0)
        
        // Create camera
        let camera = SCNCamera()
        camera.fieldOfView = 60
        camera.automaticallyAdjustsZRange = true
        cameraNode.camera = camera
        setupFixedCamera()
        scene.rootNode.addChildNode(cameraNode)
        
        // Add world container
        scene.rootNode.addChildNode(worldNode)
        
        // Create lighting
        setupLighting()
        
        // Create starfield and sun
        createStarfield()
        createDistantSun()
    }
    
    private func setupLighting() {
        // Main light
        let lightNode = SCNNode()
        let light = SCNLight()
        light.type = .directional
        light.color = UIColor(red: 1.0, green: 0.9, blue: 0.7, alpha: 1.0)
        light.intensity = 1200
        lightNode.light = light
        lightNode.position = SCNVector3(3, 3, 5)
        lightNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(lightNode)
        
        // Opposite light
        let oppositeLightNode = SCNNode()
        let oppositeLight = SCNLight()
        oppositeLight.type = .directional
        oppositeLight.color = UIColor(red: 0.8, green: 0.8, blue: 1.0, alpha: 1.0)
        oppositeLight.intensity = 800
        oppositeLightNode.light = oppositeLight
        oppositeLightNode.position = SCNVector3(-4, -2, -6)
        oppositeLightNode.look(at: SCNVector3Zero)
        worldNode.addChildNode(oppositeLightNode)
        
        // Ambient light
        let ambientNode = SCNNode()
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.color = UIColor(red: 0.2, green: 0.2, blue: 0.4, alpha: 1.0)
        ambientLight.intensity = 800
        ambientNode.light = ambientLight
        scene.rootNode.addChildNode(ambientNode)
    }
    
    private func setupFixedCamera() {
        cameraNode.position = SCNVector3(0, 0, cameraDistance)
        cameraNode.look(at: SCNVector3Zero)
    }
    
    private func updatePlanetRotation() {
        guard let currentPlanet = currentPlanet else {
            // Fallback to origin rotation if no current planet
            let horizontalRotation = SCNMatrix4MakeRotation(planetRotationY, 0, 1, 0)
            let verticalTilt = SCNMatrix4MakeRotation(planetTiltX, 1, 0, 0)
            let combinedTransform = SCNMatrix4Mult(horizontalRotation, verticalTilt)
            worldNode.transform = combinedTransform
            return
        }
        
        let planetPos = currentPlanet.config.position
        
        // Create rotation matrices
        let horizontalRotation = SCNMatrix4MakeRotation(planetRotationY, 0, 1, 0)
        let verticalTilt = SCNMatrix4MakeRotation(planetTiltX, 1, 0, 0)
        let combinedRotation = SCNMatrix4Mult(horizontalRotation, verticalTilt)
        
        // Create transformation: translate to origin, rotate, translate back
        // This makes rotation happen around the planet center, not world origin
        let translateToOrigin = SCNMatrix4MakeTranslation(-planetPos.x, -planetPos.y, -planetPos.z)
        let translateBack = SCNMatrix4MakeTranslation(planetPos.x, planetPos.y, planetPos.z)
        
        // Apply transformations: translateBack * rotation * translateToOrigin
        let temp = SCNMatrix4Mult(combinedRotation, translateToOrigin)
        let finalTransform = SCNMatrix4Mult(translateBack, temp)
        
        worldNode.transform = finalTransform
    }
    
    func initializePlanets(researchManager: ResearchManager) {
        // Create all planets
        for config in PlanetConfig.allPlanets {
            let planet = WorldPlanet(config: config, researchManager: researchManager)
            planets[config.id] = planet
            worldNode.addChildNode(planet.planetGroupNode)
        }
        
        // Set initial planet
        currentPlanet = planets[currentPlanetId]
        transitionToPlanet(currentPlanetId)
    }
    
    func updatePlanetsResearch(researchManager: ResearchManager) {
        for planet in planets.values {
            planet.updateSectors(researchManager: researchManager)
        }
    }
    
    private func transitionToPlanet(_ planetId: String) {
        guard let targetPlanet = planets[planetId],
              !isTransitioning else { return }
        
        isTransitioning = true
        let previousPlanet = currentPlanet
        currentPlanet = targetPlanet
        
        // Store starting rotation state
        let startRotationY = planetRotationY
        let startTiltX = planetTiltX
        
        // Reset rotations for clean transition to new planet
        let targetRotationY: Float = 0
        let targetTiltX: Float = 0
        
        // Smooth transition animation
        let transitionAction = SCNAction.customAction(duration: 1.5) { [weak self] _, elapsedTime in
            guard let self = self else { return }
            let progress = elapsedTime / 1.5
            let easedProgress = self.easeInOut(Float(progress))
            
            // Interpolate rotation values
            self.planetRotationY = startRotationY + (targetRotationY - startRotationY) * easedProgress
            self.planetTiltX = startTiltX + (targetTiltX - startTiltX) * easedProgress
            
            self.updatePlanetRotation()
        }
        
        let sequence = SCNAction.sequence([
            transitionAction,
            SCNAction.run { [weak self] _ in
                guard let self = self else { return }
                self.planetRotationY = targetRotationY
                self.planetTiltX = targetTiltX
                self.updatePlanetRotation()
                self.isTransitioning = false
            }
        ])
        
        worldNode.runAction(sequence)
    }
    
    // Add easing function for smooth transitions
    private func easeInOut(_ t: Float) -> Float {
        return t * t * (3.0 - 2.0 * t)
    }
    
    // Existing methods adapted for multi-planet system
    func rotatePlanetBy(deltaX: Float, deltaY: Float) {
        guard !isTransitioning else { return }
        
        planetRotationY += deltaX
        planetTiltX += deltaY
        planetTiltX = max(-maxTiltX, min(maxTiltX, planetTiltX))
        
        rotationVelocityY = deltaX
        tiltVelocityX = deltaY
        
        updatePlanetRotation()
    }
    
    func zoomCameraBy(_ delta: Float) {
        guard !isTransitioning else { return }
        
        cameraDistance += delta
        cameraDistance = max(minDistance, min(maxDistance, cameraDistance))
        
        cameraNode.position = SCNVector3(0, 0, cameraDistance)
    }
    
    func startPlanetInertia() {
        guard !isDecelerating else { return }
        isDecelerating = true
        
        decelerationTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            
            let deceleration: Float = 0.95
            
            if abs(self.rotationVelocityY) > 0.001 || abs(self.tiltVelocityX) > 0.001 {
                self.planetRotationY += self.rotationVelocityY * 0.4
                self.planetTiltX += self.tiltVelocityX * 0.4
                self.planetTiltX = max(-self.maxTiltX, min(self.maxTiltX, self.planetTiltX))
                
                self.rotationVelocityY *= deceleration
                self.tiltVelocityX *= deceleration
                
                self.updatePlanetRotation()
            } else {
                self.stopPlanetInertia()
            }
        }
    }
    
    func stopPlanetInertia() {
        decelerationTimer?.invalidate()
        decelerationTimer = nil
        isDecelerating = false
        rotationVelocityY = 0.0
        tiltVelocityX = 0.0
    }
    
    private func createStarfield() {
        let starCount = 200
        
        for _ in 0..<starCount {
            let phi = Float.random(in: 0...(2 * Float.pi))
            let theta = Float.random(in: 0...Float.pi)
            let radius: Float = 100 // Further away to account for multiple planets
            
            let x = radius * sinf(theta) * cosf(phi)
            let y = radius * sinf(theta) * sinf(phi)
            let z = radius * cosf(theta)
            
            let starSize = Float.random(in: 0.02...0.1)
            let star = SCNSphere(radius: CGFloat(starSize))
            
            let material = SCNMaterial()
            let brightness = Float.random(in: 0.3...1.0)
            material.diffuse.contents = UIColor.white
            material.emission.contents = UIColor(white: CGFloat(brightness), alpha: 1.0)
            star.materials = [material]
            
            let starNode = SCNNode(geometry: star)
            starNode.position = SCNVector3(x, y, z)
            starNode.name = "star"
            worldNode.addChildNode(starNode)
        }
    }
    
    private func createDistantSun() {
        let sun = SCNSphere(radius: 2.0)
        
        let sunMaterial = SCNMaterial()
        sunMaterial.diffuse.contents = UIColor(red: 1.0, green: 0.9, blue: 0.7, alpha: 1.0)
        sunMaterial.emission.contents = UIColor(red: 1.0, green: 0.8, blue: 0.4, alpha: 1.0)
        sun.materials = [sunMaterial]
        
        let sunNode = SCNNode(geometry: sun)
        sunNode.position = SCNVector3(50, 30, -60) // Further away
        sunNode.name = "sun"
        worldNode.addChildNode(sunNode)
    }
    
    // Get current planet's sectors
    var currentSectors: [Sector] {
        return currentPlanet?.sectors ?? []
    }
    
    // Updated sector detection for multi-planet system
    func getSectorFromNode(_ node: SCNNode) -> (sectorId: Int, planetId: String)? {
        // Check for both sector ID and planet ID
        if let sectorId = node.value(forKey: "sectorId") as? Int,
           let planetId = node.value(forKey: "planetId") as? String {
            return (sectorId, planetId)
        }
        
        // Check node name patterns
        if let nodeName = node.name {
            let patterns = ["hit_area_", "sector_visual_", "sector_outline_"]
            
            for pattern in patterns {
                if nodeName.hasPrefix(pattern) {
                    let components = nodeName.components(separatedBy: "_")
                    if components.count >= 3,
                       let sectorId = Int(components[2]),
                       components.count >= 4 {
                        let planetId = components[3]
                        return (sectorId, planetId)
                    }
                }
            }
        }
        
        // Check parent nodes
        var currentNode = node.parent
        var depth = 0
        while currentNode != nil && depth < 3 {
            if let sectorId = currentNode?.value(forKey: "sectorId") as? Int,
               let planetId = currentNode?.value(forKey: "planetId") as? String {
                return (sectorId, planetId)
            }
            currentNode = currentNode?.parent
            depth += 1
        }
        
        return nil
    }
    
    func updateSelectionHighlight() {
        // Update selection for current planet only
        currentPlanet?.updateSelectionHighlight(selectedSectorId: selectedSectorId)
    }
}

// MARK: - Updated Sector Data

struct SectorData {
    // Tarkon sectors (original Erekin sectors)
    static func createTarkonSectors(researchManager: ResearchManager) -> [Sector] {
        return [
            Sector(
                id: 1,
                name: "Starting Grounds",
                hexCoordinate: HexCoordinate(q: 0, r: 0),
                status: researchManager.getSectorStatus("Starting Grounds"),
                difficulty: .easy,
                resources: SectorResources(copper: true, graphite: true, coal: false, aluminum: false),
                connectedSectors: [2, 3, 4],
                description: "A sector with minimal enemy presence, perfect for beginning the journey of conquering Tarkon.",
                fileIdentifier: "SG"
            ),
            Sector(
                id: 2,
                name: "Ferrum Ridge",
                hexCoordinate: HexCoordinate(q: 1, r: 0),
                status: researchManager.getSectorStatus("Ferrum Ridge"),
                difficulty: .normal,
                resources: SectorResources(copper: true, graphite: true, coal: false, aluminum: false),
                connectedSectors: [1, 5],
                description: "This sector has many geysers, making it ideal for iron extraction and refinement into steel.",
                fileIdentifier: "FR"
            ),
            Sector(
                id: 3,
                name: "Crevice",
                hexCoordinate: HexCoordinate(q: 0, r: 1),
                status: researchManager.getSectorStatus("Crevice"),
                difficulty: .normal,
                resources: SectorResources(copper: true, graphite: true, coal: true, aluminum: false),
                connectedSectors: [1, 6],
                description: "A small crevice with a large river separating your and the enemy's base.",
                fileIdentifier: "CV"
            ),
            Sector(
                id: 4,
                name: "Nightfall Depths",
                hexCoordinate: HexCoordinate(q: -1, r: 1),
                status: researchManager.getSectorStatus("Nightfall Depths"),
                difficulty: .easy,
                resources: SectorResources(copper: true, graphite: true, coal: false, aluminum: true),
                connectedSectors: [1, 7],
                description: "Few asteroids landed here, requiring alternative energy sources.",
                fileIdentifier: "ND"
            )
        ]
    }
    
    // NEW: Yndora sectors (water-based challenges)
    static func createYndoraSectors(researchManager: ResearchManager) -> [Sector] {
        return [
            Sector(
                id: 101,
                name: "Tidal Base",
                hexCoordinate: HexCoordinate(q: 0, r: 0),
                status: .available, // Always available for now
                difficulty: .easy,
                resources: SectorResources(copper: false, graphite: false, coal: false, aluminum: false),
                connectedSectors: [102, 103],
                description: "A floating platform in the endless ocean. Perfect for learning naval operations.",
                fileIdentifier: "TB"
            ),
            Sector(
                id: 102,
                name: "Coral Reef",
                hexCoordinate: HexCoordinate(q: 1, r: 0),
                status: .locked,
                difficulty: .normal,
                resources: SectorResources(copper: false, graphite: false, coal: false, aluminum: false),
                connectedSectors: [101],
                description: "A vibrant underwater ecosystem hiding valuable resources.",
                fileIdentifier: "CR"
            ),
            Sector(
                id: 103,
                name: "Deep Trench",
                hexCoordinate: HexCoordinate(q: 0, r: 1),
                status: .locked,
                difficulty: .hard,
                resources: SectorResources(copper: false, graphite: false, coal: false, aluminum: false),
                connectedSectors: [101],
                description: "The deepest part of Yndora's ocean, filled with ancient secrets.",
                fileIdentifier: "DT"
            )
        ]
    }
    
    // NEW: Xerion sectors (electric storm challenges)
    static func createXerionSectors(researchManager: ResearchManager) -> [Sector] {
        return [
            Sector(
                id: 201,
                name: "Storm Eye",
                hexCoordinate: HexCoordinate(q: 0, r: 0),
                status: .locked, // Locked for now
                difficulty: .normal,
                resources: SectorResources(copper: false, graphite: false, coal: false, aluminum: false),
                connectedSectors: [202, 203],
                description: "The calm center of Xerion's eternal storm. Energy crackles in the air.",
                fileIdentifier: "SE"
            ),
            Sector(
                id: 202,
                name: "Lightning Fields",
                hexCoordinate: HexCoordinate(q: 1, r: 0),
                status: .locked,
                difficulty: .insane,
                resources: SectorResources(copper: false, graphite: false, coal: false, aluminum: false),
                connectedSectors: [201],
                description: "Constant electrical storms make conventional units useless here.",
                fileIdentifier: "LF"
            ),
            Sector(
                id: 203,
                name: "Thunder Peaks",
                hexCoordinate: HexCoordinate(q: 0, r: 1),
                status: .locked,
                difficulty: .eradication,
                resources: SectorResources(copper: false, graphite: false, coal: false, aluminum: false),
                connectedSectors: [201],
                description: "The highest peaks of Xerion, where lightning strikes continuously.",
                fileIdentifier: "TP"
            )
        ]
    }
}

// MARK: - SceneKit View Wrapper (Updated)

struct SceneKitPlanetView: UIViewRepresentable {
    @ObservedObject var coordinator: PlanetSceneCoordinator
    let onSectorTap: (Int, String) -> Void // Now includes planet ID
    
    func makeUIView(context: Context) -> SCNView {
        let sceneView = SCNView()
        sceneView.scene = coordinator.scene
        sceneView.backgroundColor = UIColor(red: 0.02, green: 0.02, blue: 0.08, alpha: 1.0)
        sceneView.allowsCameraControl = false
        sceneView.showsStatistics = false
        sceneView.antialiasingMode = .multisampling4X
        
        context.coordinator.sceneView = sceneView
        
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(context.coordinator.handleTap(_:)))
        sceneView.addGestureRecognizer(tapGesture)
        
        let panGesture = UIPanGestureRecognizer(target: context.coordinator, action: #selector(context.coordinator.handlePan(_:)))
        sceneView.addGestureRecognizer(panGesture)
        
        let pinchGesture = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(context.coordinator.handlePinch(_:)))
        sceneView.addGestureRecognizer(pinchGesture)
        
        return sceneView
    }
    
    func updateUIView(_ uiView: SCNView, context: Context) {
        // Update if needed
    }
    
    func makeCoordinator() -> TapCoordinator {
        TapCoordinator(sceneCoordinator: coordinator, onSectorTap: onSectorTap)
    }
    
    class TapCoordinator: NSObject {
        let sceneCoordinator: PlanetSceneCoordinator
        let onSectorTap: (Int, String) -> Void
        var sceneView: SCNView?
        
        init(sceneCoordinator: PlanetSceneCoordinator, onSectorTap: @escaping (Int, String) -> Void) {
            self.sceneCoordinator = sceneCoordinator
            self.onSectorTap = onSectorTap
        }
        
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let sceneView = gesture.view as? SCNView else { return }
            
            let point = gesture.location(in: sceneView)
            let hitResults = sceneView.hitTest(point, options: [
                SCNHitTestOption.backFaceCulling: false,
                SCNHitTestOption.boundingBoxOnly: false,
                SCNHitTestOption.ignoreChildNodes: false,
                SCNHitTestOption.ignoreHiddenNodes: true,
                SCNHitTestOption.sortResults: true,
                SCNHitTestOption.firstFoundOnly: false
            ])
            
            var bestSectorInfo: (sectorId: Int, planetId: String)? = nil
            var bestDistance: Float = Float.greatestFiniteMagnitude
            
            for result in hitResults {
                // Skip non-interactive elements
                if let nodeName = result.node.name {
                    if nodeName.contains("star") || nodeName.contains("sun") ||
                       nodeName.contains("planet") || nodeName.contains("atmosphere") {
                        continue
                    }
                }
                
                // Try to get sector and planet ID from the hit node
                if let sectorInfo = sceneCoordinator.getSectorFromNode(result.node) {
                    // Only consider sectors on current planet
                    if sectorInfo.planetId == sceneCoordinator.currentPlanetId {
                        // Check if sector is clickable
                        if let sector = sceneCoordinator.currentSectors.first(where: { $0.id == sectorInfo.sectorId }) {
                            if sector.status != .locked {
                                let distance = result.worldCoordinates.length
                                if distance < bestDistance {
                                    bestDistance = distance
                                    bestSectorInfo = sectorInfo
                                }
                            }
                        }
                    }
                }
            }
            
            // Select the best sector found
            if let sectorInfo = bestSectorInfo {
                sceneCoordinator.selectedSectorId = sectorInfo.sectorId
                onSectorTap(sectorInfo.sectorId, sectorInfo.planetId)
            } else {
                sceneCoordinator.selectedSectorId = nil
            }
        }
        
        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let sceneView = gesture.view as? SCNView else { return }
            
            switch gesture.state {
            case .began:
                sceneCoordinator.stopPlanetInertia()
                
            case .changed:
                let translation = gesture.translation(in: sceneView)
                let screenWidth = Float(sceneView.bounds.width)
                let screenHeight = Float(sceneView.bounds.height)
                
                let horizontalSensitivity: Float = 2.5
                let verticalSensitivity: Float = 2.5
                
                // Invert deltaX to fix rotation direction
                let deltaX = -Float(translation.x) / screenWidth * horizontalSensitivity
                let deltaY = Float(translation.y) / screenHeight * verticalSensitivity
                
                sceneCoordinator.rotatePlanetBy(deltaX: deltaX, deltaY: deltaY)
                gesture.setTranslation(.zero, in: sceneView)
                
            case .ended, .cancelled:
                sceneCoordinator.startPlanetInertia()
                
            default:
                break
            }
        }
        
        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            let scale = Float(gesture.scale)
            let zoomDelta = (1.0 - scale) * 2.0
            
            sceneCoordinator.zoomCameraBy(zoomDelta)
            gesture.scale = 1.0
        }
    }
}

// MARK: - Main Mindustry View (Updated)

struct MindustrySectorView: View {
    @StateObject private var sceneCoordinator = PlanetSceneCoordinator()
    @State private var selectedSector: Sector?
    @State private var showSectorInfo = false
    @State private var showingDeploymentOptions = false
    @State private var isShowingTechTree: Bool = false
    @Binding var isShowingCampaign: Bool
    @State var currentSectorId: String?
    
    @ObservedObject private var researchManager = ResearchManager.shared
    
    @State var isShowingSectorInfo: String? = nil
    
    var body: some View {
        if let sectorId = currentSectorId, !sectorId.isEmpty {
            GameView(fileURL: mapFileURL) {
                currentSectorId = nil
            }
            .ignoresSafeArea()
        } else {
            ZStack {
                ZStack {
                    // SceneKit planet view with updated callback
                    SceneKitPlanetView(coordinator: sceneCoordinator) { sectorId, planetId in
                        // Find sector from current planet
                        if let sector = sceneCoordinator.currentSectors.first(where: { $0.id == sectorId }) {
                            selectedSector = sector
                            withAnimation(.easeInOut(duration: 0.3)) {
                                showingDeploymentOptions = true
                            }
                        }
                    }
                    .ignoresSafeArea()
                    
                    // Enhanced sector overlay
                    if isShowingSectorInfo == nil {
                        if let selectedId = sceneCoordinator.selectedSectorId,
                           let sector = sceneCoordinator.currentSectors.first(where: { $0.id == selectedId }) {
                            EnhancedSectorOverlay(
                                sector: sector,
                                isVisible: showingDeploymentOptions,
                                onDeploy: {
                                    showSectorInfo = true
                                    showingDeploymentOptions = false
                                },
                                onDismiss: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showingDeploymentOptions = false
                                        sceneCoordinator.selectedSectorId = nil
                                    }
                                },
                                currentSectorId: $currentSectorId,
                                isShowingSectorInfo: $isShowingSectorInfo
                            )
                            .offset(x: -700, y: 70)
                        }
                    }
                    
                    // UI Overlay with updated planet tabs
                    VStack {
                        // Top UI
                        HStack {
                            // Planet selection - now uses all available planets
                            VStack(spacing: 4) {
                                ForEach(PlanetConfig.allPlanets, id: \.id) { planetConfig in
                                    PlanetTab(
                                        name: planetConfig.name,
                                        isSelected: sceneCoordinator.currentPlanetId == planetConfig.id,
                                        icon: planetConfig.icon
                                    )
                                    .onTapGesture {
                                        sceneCoordinator.currentPlanetId = planetConfig.id
                                    }
                                }
                            }
                            
                            Spacer()
                            
                            // Current planet name
                            if let currentPlanet = PlanetConfig.allPlanets.first(where: { $0.id == sceneCoordinator.currentPlanetId }) {
                                VStack(alignment: .trailing) {
                                    Text(currentPlanet.name)
                                        .font(.system(.title2, design: .monospaced))
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                    Text(currentPlanet.description)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.gray)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        
                        Spacer()
                        
                        // Bottom UI
                        HStack {
                            MindustryButton(text: "Back", icon: "chevron.left") {
                                isShowingCampaign = false
                            }
                            
                            Spacer()
                            
                            MindustryButton(text: "Tech Tree", icon: "brain") {
                                isShowingTechTree = true
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    }
                }
                .preferredColorScheme(.dark)
                .onAppear {
                    sceneCoordinator.initializePlanets(researchManager: researchManager)
                }
                .onReceive(researchManager.techTreeViewModel.$nodes) { _ in
                    sceneCoordinator.updatePlanetsResearch(researchManager: researchManager)
                }
                .sheet(isPresented: $showSectorInfo) {
                    if let sector = selectedSector {
                        SectorInfoSheet(sector: sector) {
                            showSectorInfo = false
                        }
                    }
                }
                
                // Tech tree overlay
                if isShowingTechTree {
                    MindustryTechTreeView(
                        viewModel: researchManager.techTreeViewModel,
                        isShowingTechTree: $isShowingTechTree
                    )
                }
                
                if isShowingSectorInfo != nil {
                    ZStack {
                        Rectangle()
                            .foregroundColor(.black)
                            .opacity(0.7)
                        
                        VStack {
                            HStack {
                                HStack {
                                    Image("copper")
                                        .resizable()
                                        .frame(width: 30, height: 30)
                                    Text("500")
                                }
                                
                                HStack {
                                    Image("graphite")
                                        .resizable()
                                        .frame(width: 30, height: 30)
                                    Text("500")
                                }
                                
                                HStack {
                                    Image("silicon")
                                        .resizable()
                                        .frame(width: 30, height: 30)
                                    Text("300")
                                }
                            }
                            
                            HStack {
                                Button {
                                    isShowingSectorInfo = nil
                                } label: {
                                    ZStack {
                                        Rectangle()
                                            .frame(width: 150, height: 50)
                                            .foregroundColor(.gray)
                                        
                                        HStack {
                                            Image(systemName: "chevron.left")
                                                .resizable()
                                                .frame(width: 20, height: 30)
                                                .foregroundColor(.black)
                                            
                                            Text("Back")
                                                .foregroundColor(.black)
                                                .bold()
                                                .font(.system(size: 16))
                                        }
                                    }
                                }
                                
                                Button {
                                    currentSectorId = isShowingSectorInfo
                                } label: {
                                    ZStack {
                                        Rectangle()
                                            .frame(width: 150, height: 50)
                                            .foregroundColor(.gray)
                                        
                                        HStack {
                                            Image(systemName: "checkmark")
                                                .resizable()
                                                .frame(width: 30, height: 30)
                                                .foregroundColor(.black)
                                            
                                            Text("Launch")
                                                .foregroundColor(.black)
                                                .bold()
                                                .font(.system(size: 16))
                                        }
                                    }
                                }
                            }
                            .offset(y: 150)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Enhanced UI Components (Same as before)

struct EnhancedSectorOverlay: View {
    let sector: Sector
    let isVisible: Bool
    let onDeploy: () -> Void
    let onDismiss: () -> Void
    @Binding var currentSectorId: String?
    @Binding var isShowingSectorInfo: String?
    
    var body: some View {
        if isVisible {
            VStack {
                Spacer()
                
                HStack {
                    Spacer()
                    
                    VStack(spacing: 16) {
                        // Header with sector name and status
                        Text(sector.name)
                            .font(.system(.title2, design: .monospaced))
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                        
                        Divider()
                            .background(Color.orange.opacity(0.3))
                        
                        // Difficulty and type info
                        HStack {
                            VStack(spacing: 8) {
                                HStack {
                                    Text("Difficulty:")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.gray)
                                    
                                    HStack(spacing: 3) {
                                        ForEach(0..<5, id: \.self) { i in
                                            Circle()
                                                .fill(i < sector.difficulty.rawValue ? sector.difficulty.color : Color.gray.opacity(0.3))
                                                .frame(width: 10, height: 10)
                                                .overlay(
                                                    Circle()
                                                        .stroke(i < sector.difficulty.rawValue ? sector.difficulty.color : Color.clear, lineWidth: 1)
                                                        .scaleEffect(1.3)
                                                        .opacity(0.5)
                                                )
                                        }
                                    }
                                }
                                
                                if sector.resources != SectorResources.none {
                                    Text("Resources:")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.gray)
                                }
                            }
                        }
                        
                        // Enhanced resource display
                        if sector.resources != SectorResources.none {
                            HStack(spacing: 8) {
                                if sector.resources.copper == true {
                                    Image("copper")
                                        .resizable()
                                        .frame(width: 30, height: 30)
                                }
                                if sector.resources.graphite == true {
                                    Image("graphite")
                                        .resizable()
                                        .frame(width: 30, height: 30)
                                }
                                if sector.resources.coal == true {
                                    Image("coal")
                                        .resizable()
                                        .frame(width: 30, height: 30)
                                }
                                if sector.resources.aluminum == true {
                                    Image("aluminum")
                                        .resizable()
                                        .frame(width: 30, height: 30)
                                }
                            }
                        }
                        
                        Divider()
                            .background(Color.orange.opacity(0.3))
                        
                        if sector.status != .locked {
                            Button(actionText(for: sector.status)) {
                                if sector.status == .available {
                                    isShowingSectorInfo = sector.fileIdentifier
                                } else {
                                    currentSectorId = sector.fileIdentifier
                                }
                            }
                            .buttonStyle(MindustryPrimaryButtonStyle())
                        }
                    }
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.black.opacity(0.9))
                            .stroke(
                                LinearGradient(
                                    colors: [Color.orange.opacity(0.8), Color.orange.opacity(0.3)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2
                            )
                            .shadow(color: .orange.opacity(0.3), radius: 10, x: 0, y: 0)
                    )
                    .frame(maxWidth: 320)
                }
                .padding(.trailing, 20)
                .padding(.bottom, 100)
            }
            .onTapGesture {
                onDismiss()
            }
        }
    }
    
    private func actionText(for status: SectorStatus) -> String {
        switch status {
        case .available: return "Launch"
        case .completed: return "Go"
        case .inProgress: return "Continue"
        case .locked: return "Locked"
        }
    }
}

struct MindustryPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .monospaced))
            .fontWeight(.semibold)
            .foregroundColor(.black)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        LinearGradient(
                            colors: [Color.orange, Color.orange.opacity(0.8)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.orange.opacity(0.5), lineWidth: 1)
            )
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct PlanetTab: View {
    let name: String
    let isSelected: Bool
    let icon: String
    
    var body: some View {
        HStack(spacing: 8) {
            Text(icon)
                .font(.title3)
            Text(name)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)
        }
        .foregroundColor(isSelected ? .orange : .white.opacity(0.7))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.orange.opacity(0.2) : Color.black.opacity(0.4))
                .stroke(isSelected ? Color.orange : Color.gray.opacity(0.3), lineWidth: 1)
        )
    }
}

struct MindustryButton: View {
    let text: String
    let icon: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.black.opacity(0.4))
                    .stroke(Color.gray.opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct SectorInfoSheet: View {
    let sector: Sector
    let onDismiss: () -> Void
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(sector.name)
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                        
                        Text("Sector \(sector.id)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    Divider().background(Color.gray.opacity(0.3))
                    
                    Text(sector.description)
                        .foregroundColor(.white.opacity(0.9))
                        .lineSpacing(4)
                    
                    Spacer()
                    
                    HStack(spacing: 16) {
                        Button("Cancel") { onDismiss() }
                            .buttonStyle(.bordered)
                            .tint(.gray)
                        
                        if sector.status != .locked {
                            Button("Deploy") {
                                onDismiss()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                        }
                    }
                }
                .padding()
            }
            .navigationBarHidden(true)
        }
    }
}

// MARK: - Renderer Update Loop
extension PlanetSceneCoordinator {
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let yRot = SCNMatrix4MakeRotation(planetRotationY, 0, 1, 0)
        let xRot = SCNMatrix4MakeRotation(planetTiltX, 1, 0, 0)
        worldNode.transform = SCNMatrix4Mult(yRot, xRot)
    }
}
