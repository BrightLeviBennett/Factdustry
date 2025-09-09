//
//  TechTree.swift
//  Factdustry
//
//  Created by Bright on 6/6/25.
//

import SwiftUI
import Combine

struct ResourceCost: Identifiable {
    let id = UUID()
    let resourceName: String
    let amount: Int
}

// Research-specific data that doesn't duplicate database info
struct TechResearchData {
    let databaseItemName: String
    let gridPosition: GridPosition
    let dependencies: [String] // Required for research unlocking (uses databaseItemName)
    let visualConnections: [String] // Visual lines only, separate from dependencies
    let researchCosts: [ResourceCost]
}

struct TechNode: Identifiable, Equatable {
    let id = UUID()
    let databaseItemName: String // References item in database
    var gridPosition: GridPosition // Grid-based positioning
    let dependencies: [String] // Required for research unlocking (uses databaseItemName)
    let visualConnections: [String] // Visual lines only, separate from dependencies
    let researchCosts: [ResourceCost]
    var isUnlocked: Bool = false
    var isResearched: Bool = false
    
    // Computed properties that fetch from database
    var name: String {
        if let item = DatabaseManager.shared.findItem(named: databaseItemName) {
            return item.name
        }
        return databaseItemName
    }
    
    var iconName: String {
        if let item = DatabaseManager.shared.findItem(named: databaseItemName) {
            return item.icon
        }
        return "questionmark"
    }
    
    var description: String {
        if let item = DatabaseManager.shared.findItem(named: databaseItemName) {
            return item.description
        }
        return ""
    }
    
    // Initialize from research data
    init(from researchData: TechResearchData) {
        self.databaseItemName = researchData.databaseItemName
        self.gridPosition = researchData.gridPosition
        self.dependencies = researchData.dependencies
        self.visualConnections = researchData.visualConnections
        self.researchCosts = researchData.researchCosts
    }
    
    static func == (lhs: TechNode, rhs: TechNode) -> Bool {
        lhs.id == rhs.id
    }
}

struct GridPosition: Hashable {
    let x: Int
    var y: Int
    
    func toCGPoint(gridSize: CGFloat) -> CGPoint {
        return CGPoint(x: CGFloat(x) * gridSize, y: CGFloat(y) * gridSize)
    }
}

struct ResourceItem: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    var quantity: Int
}

class TechTreeViewModel: ObservableObject {
    @Published var nodes: [TechNode] = []
    @Published var resources: [ResourceItem] = []
    @Published var selectedNode: TechNode?
    @Published var zoomScale: CGFloat = 0.6
    @Published var useSmartRouting: Bool = true
    
    let minZoom: CGFloat = 0.3
    let maxZoom: CGFloat = 3.0
    let gridSize: CGFloat = 80
    
    // MARK: - Resource & Sector Helpers
    
    private func normalizeResourceName(_ s: String) -> String {
        let lower = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.hasPrefix("raw ") { return String(lower.dropFirst(4)) }
        return lower
    }
    
    func isResourceNode(_ node: TechNode) -> Bool {
        let nodeName = normalizeResourceName(node.databaseItemName)
        return resources.contains { normalizeResourceName($0.name) == nodeName }
    }
    
    func isSectorNode(_ node: TechNode) -> Bool {
        if isSectorName(node.databaseItemName) { return true }
        let deps = effectiveDependencies(for: node)
        if deps.contains(where: { $0.lowercased().hasPrefix("sector:") }) { return true }
        let n = node.databaseItemName.lowercased()
        return n.hasPrefix("sector ") || n.hasPrefix("sector:")
    }
    
    func autoResearchResources() {
        var changed = false
        var qty: [String:Int] = [:]
        for r in resources { qty[normalizeResourceName(r.name)] = r.quantity }
        for (idx, node) in nodes.enumerated() where !node.isResearched && isResourceNode(node) {
            let key = normalizeResourceName(node.databaseItemName)
            if let q = qty[key], q > 0 {
                var depsMet = true
                for dep in effectiveDependencies(for: node) { if !isDependencyMet(dep) { depsMet = false; break } }
                if depsMet {
                    var u = node; u.isResearched = true; u.isUnlocked = true; nodes[idx] = u
                    changed = true
                }
            }
        }
        if changed { unlockNodes() }
    }
    
    private var resourcesCancellable: AnyCancellable?
    
    
    
    // Optional resolver for sector status by name, so tech dependencies can target sector states.
    // Provide a closure via `setSectorStatusResolver` that returns the current SectorStatus for a given sector name.
    var sectorStatusResolver: ((String) -> SectorStatus)? = nil
    var isSectorNameResolver: ((String) -> Bool)? = nil
    init() {
        resourcesCancellable = $resources.sink { [weak self] _ in self?.autoResearchResources() }
        setupResources()
        setupTechTreeFromDatabase()
        layoutUnifiedTechTree()
        resolveOverlaps()
        unlockNodes()
    }
    
    private func setupResources() {
        resources = [
            ResourceItem(name: "Copper", icon: "copper",     quantity: 0),
            ResourceItem(name: "Graphite", icon: "graphite", quantity: 0),
            ResourceItem(name: "Steel", icon: "steel",       quantity: 0),
            ResourceItem(name: "Silicon", icon: "silicon",   quantity: 0),
            ResourceItem(name: "Hydrogen", icon: "hydrogen", quantity: 0),
            ResourceItem(name: "Oxygen", icon: "oxygen",     quantity: 0),
            ResourceItem(name: "Water", icon: "water",       quantity: 0),
            ResourceItem(name: "Iron", icon: "iron",         quantity: 0),
            ResourceItem(name: "Circuit", icon: "●",         quantity: 0),
            ResourceItem(name: "Carbon Dioxide", icon: "●",  quantity: 0),
            ResourceItem(name: "Petroleum", icon: "●",       quantity: 0),
            ResourceItem(name: "Coal", icon: "coal",         quantity: 0),
            ResourceItem(name: "Ethane", icon: "●",          quantity: 0),
            ResourceItem(name: "Methane", icon: "●",         quantity: 0),
            ResourceItem(name: "Butane", icon: "●",          quantity: 0),
            ResourceItem(name: "Propane", icon: "●",         quantity: 0),
            ResourceItem(name: "Raw Aluminum", icon: "rawAluminum", quantity: 0),
            ResourceItem(name: "Aluminum", icon: "aluminum", quantity: 0),
        ]
    }
    
    private func setupTechTreeFromDatabase() {
        // Define only research-specific data, all display info comes from database
        let researchData: [TechResearchData] = [
            // === UNITS: creatures ===
            TechResearchData(databaseItemName: "Ant", gridPosition: GridPosition(x:0,y:0), dependencies: ["Tank Fabricator"], visualConnections: ["Tank Fabricator"], researchCosts: [ResourceCost(resourceName: "Copper", amount: 50)]),
            TechResearchData(databaseItemName: "Crawler Fabricator", gridPosition: GridPosition(x:0,y:0), dependencies: ["Ant"], visualConnections: ["Ant"], researchCosts: [ResourceCost(resourceName: "Copper", amount: 100), ResourceCost(resourceName: "Graphite", amount: 75)]),
            TechResearchData(databaseItemName: "Geckeo", gridPosition: GridPosition(x:0,y:0), dependencies: ["Crawler Fabricator"], visualConnections: ["Crawler Fabricator"], researchCosts: [ResourceCost(resourceName: "Graphite", amount: 150), ResourceCost(resourceName: "Iron", amount: 100)]),
            TechResearchData(databaseItemName: "Lizard", gridPosition: GridPosition(x:0,y:0), dependencies: ["Geckeo"], visualConnections: ["Geckeo"], researchCosts: [ResourceCost(resourceName: "Iron", amount: 200), ResourceCost(resourceName: "Steel", amount: 150)]),
            TechResearchData(databaseItemName: "Iguana", gridPosition: GridPosition(x:0,y:0), dependencies: ["Lizard"], visualConnections: ["Lizard"], researchCosts: [ResourceCost(resourceName: "Steel", amount: 250), ResourceCost(resourceName: "Silicon", amount: 200)]),
            TechResearchData(databaseItemName: "Chameleon", gridPosition: GridPosition(x:0,y:0), dependencies: ["Iguana"], visualConnections: ["Iguana"], researchCosts: [ResourceCost(resourceName: "Silicon", amount: 300), ResourceCost(resourceName: "Circuit", amount: 100)]),
            TechResearchData(databaseItemName: "Monitor", gridPosition: GridPosition(x:0,y:0), dependencies: ["Chameleon"], visualConnections: ["Chameleon"], researchCosts: [ResourceCost(resourceName: "Circuit", amount: 200), ResourceCost(resourceName: "Hydrogen", amount: 150)]),
            
            // === UNITS: insects ===
            TechResearchData(databaseItemName: "Beetle", gridPosition: GridPosition(x:0,y:0), dependencies: ["Ant"], visualConnections: ["Ant"], researchCosts: [ResourceCost(resourceName: "Copper", amount: 75), ResourceCost(resourceName: "Graphite", amount: 50)]),
            TechResearchData(databaseItemName: "Termite", gridPosition: GridPosition(x:0,y:0), dependencies: ["Beetle"], visualConnections: ["Beetle"], researchCosts: [ResourceCost(resourceName: "Graphite", amount: 125), ResourceCost(resourceName: "Iron", amount: 100)]),
            TechResearchData(databaseItemName: "Armadillo", gridPosition: GridPosition(x:0,y:0), dependencies: ["Termite"], visualConnections: ["Termite"], researchCosts: [ResourceCost(resourceName: "Iron", amount: 200), ResourceCost(resourceName: "Steel", amount: 100)]),
            TechResearchData(databaseItemName: "Turtle", gridPosition: GridPosition(x:0,y:0), dependencies: ["Armadillo"], visualConnections: ["Armadillo"], researchCosts: [ResourceCost(resourceName: "Steel", amount: 300), ResourceCost(resourceName: "Silicon", amount: 150)]),
            
            TechResearchData(databaseItemName: "Destroy ", gridPosition: GridPosition(x:0,y:0), dependencies: ["Support Hover Fabricator"], visualConnections: ["Support Hover Fabricator"], researchCosts: [ResourceCost(resourceName: "Steel", amount: 200), ResourceCost(resourceName: "Circuit", amount: 50)]),
            TechResearchData(databaseItemName: "Rebuild", gridPosition: GridPosition(x:0,y:0), dependencies: ["Destroy "], visualConnections: ["Destroy "], researchCosts: [ResourceCost(resourceName: "Steel", amount: 250), ResourceCost(resourceName: "Circuit", amount: 75)]),
            TechResearchData(databaseItemName: "Assist", gridPosition: GridPosition(x:0,y:0), dependencies: ["Rebuild"], visualConnections: ["Rebuild"], researchCosts: [ResourceCost(resourceName: "Circuit", amount: 100), ResourceCost(resourceName: "Silicon", amount: 200)]),
            TechResearchData(databaseItemName: "Support", gridPosition: GridPosition(x:0,y:0), dependencies: ["Assist"], visualConnections: ["Assist"], researchCosts: [ResourceCost(resourceName: "Circuit", amount: 150), ResourceCost(resourceName: "Hydrogen", amount: 100)]),
            TechResearchData(databaseItemName: "Protect", gridPosition: GridPosition(x:0,y:0), dependencies: ["Support"], visualConnections: ["Support"], researchCosts: [ResourceCost(resourceName: "Circuit", amount: 200), ResourceCost(resourceName: "Hydrogen", amount: 200)]),
            
            // === UNITS: specialized fabricators & flyers ===
            TechResearchData(databaseItemName: "Tank Fabricator", gridPosition: GridPosition(x:0,y:0), dependencies: ["Core: Shard"], visualConnections: ["Core: Shard"], researchCosts: [ResourceCost(resourceName: "Copper", amount: 150), ResourceCost(resourceName: "Graphite", amount: 100)]),
            TechResearchData(databaseItemName: "Ship Fabricator", gridPosition: GridPosition(x:0,y:0), dependencies: ["Tank Fabricator"], visualConnections: ["Tank Fabricator"], researchCosts: [ResourceCost(resourceName: "Iron", amount: 250), ResourceCost(resourceName: "Steel", amount: 200)]),
            TechResearchData(databaseItemName: "Hover Fabricator", gridPosition: GridPosition(x:0,y:0), dependencies: ["Tank Fabricator"], visualConnections: ["Tank Fabricator"], researchCosts: [ResourceCost(resourceName: "Steel", amount: 300), ResourceCost(resourceName: "Silicon", amount: 150)]),
            TechResearchData(databaseItemName: "Support Hover Fabricator", gridPosition: GridPosition(x:0,y:0), dependencies: ["Hover Fabricator"], visualConnections: ["Hover Fabricator"], researchCosts: [ResourceCost(resourceName: "Silicon", amount: 250), ResourceCost(resourceName: "Circuit", amount: 100)]),
            TechResearchData(databaseItemName: "Unit Reassembler", gridPosition: GridPosition(x:0,y:0), dependencies: ["Unit Assembler"], visualConnections: ["Unit Assembler"], researchCosts: [ResourceCost(resourceName: "Circuit", amount: 300), ResourceCost(resourceName: "Hydrogen", amount: 200)]),
            TechResearchData(databaseItemName: "Unit Assembler", gridPosition: GridPosition(x:0,y:0), dependencies: ["Unit Upgrader"], visualConnections: ["Unit Upgrader"], researchCosts: [ResourceCost(resourceName: "Circuit", amount: 200), ResourceCost(resourceName: "Silicon", amount: 300)]),
            TechResearchData(databaseItemName: "Unit Upgrader", gridPosition: GridPosition(x:0,y:0), dependencies: ["Unit Refabricator"], visualConnections: ["Unit Refabricator"], researchCosts: [ResourceCost(resourceName: "Steel", amount: 400), ResourceCost(resourceName: "Circuit", amount: 150)]),
            TechResearchData(databaseItemName: "Unit Refabricator", gridPosition: GridPosition(x:0,y:0), dependencies: ["Tank Fabricator"], visualConnections: ["Tank Fabricator"], researchCosts: [ResourceCost(resourceName: "Steel", amount: 300), ResourceCost(resourceName: "Silicon", amount: 200)]),
            
            TechResearchData(databaseItemName: "Hoverboard", gridPosition: GridPosition(x:0,y:0), dependencies: ["Hover Fabricator"], visualConnections: ["Hover Fabricator"], researchCosts: [ResourceCost(resourceName: "Steel", amount: 100), ResourceCost(resourceName: "Silicon", amount: 75)]),
            TechResearchData(databaseItemName: "Hover-transport", gridPosition: GridPosition(x:0,y:0), dependencies: ["Hoverboard"], visualConnections: ["Hoverboard"], researchCosts: [ResourceCost(resourceName: "Silicon", amount: 150), ResourceCost(resourceName: "Circuit", amount: 50)]),
            TechResearchData(databaseItemName: "Hoverlift", gridPosition: GridPosition(x:0,y:0), dependencies: ["Hover-transport"], visualConnections: ["Hover-transport"], researchCosts: [ResourceCost(resourceName: "Circuit", amount: 100), ResourceCost(resourceName: "Hydrogen", amount: 75)]),
            TechResearchData(databaseItemName: "Hovercraft", gridPosition: GridPosition(x:0,y:0), dependencies: ["Hoverlift"], visualConnections: ["Hoverlift"], researchCosts: [ResourceCost(resourceName: "Circuit", amount: 150), ResourceCost(resourceName: "Hydrogen", amount: 100)]),
            TechResearchData(databaseItemName: "Hovership", gridPosition: GridPosition(x:0,y:0), dependencies: ["Hovercraft"], visualConnections: ["Hovercraft"], researchCosts: [ResourceCost(resourceName: "Circuit", amount: 200), ResourceCost(resourceName: "Hydrogen", amount: 150)]),
            
            TechResearchData(databaseItemName: "Fly", gridPosition: GridPosition(x:0,y:0), dependencies: ["Ship Fabricator"], visualConnections: ["Ship Fabricator"], researchCosts: [ResourceCost(resourceName: "Iron", amount: 100), ResourceCost(resourceName: "Steel", amount: 75)]),
            TechResearchData(databaseItemName: "Moth", gridPosition: GridPosition(x:0,y:0), dependencies: ["Fly"], visualConnections: ["Fly"], researchCosts: [ResourceCost(resourceName: "Steel", amount: 150), ResourceCost(resourceName: "Silicon", amount: 100)]),
            TechResearchData(databaseItemName: "Kestrel", gridPosition: GridPosition(x:0,y:0), dependencies: ["Moth"], visualConnections: ["Moth"], researchCosts: [ResourceCost(resourceName: "Silicon", amount: 200), ResourceCost(resourceName: "Circuit", amount: 75)]),
            TechResearchData(databaseItemName: "Hawk", gridPosition: GridPosition(x:0,y:0), dependencies: ["Kestrel"], visualConnections: ["Kestrel"], researchCosts: [ResourceCost(resourceName: "Circuit", amount: 150), ResourceCost(resourceName: "Hydrogen", amount: 100)]),
            TechResearchData(databaseItemName: "Eagle", gridPosition: GridPosition(x:0,y:0), dependencies: ["Hawk"], visualConnections: ["Hawk"], researchCosts: [ResourceCost(resourceName: "Circuit", amount: 250), ResourceCost(resourceName: "Hydrogen", amount: 200)]),
            
            // === CONSTRUCTION BLOCKS ===
            TechResearchData(databaseItemName: "Picker", gridPosition: GridPosition(x:0,y:0), dependencies: ["Tank Fabricator"], visualConnections: ["Tank Fabricator"], researchCosts: [ResourceCost(resourceName: "Copper", amount: 100), ResourceCost(resourceName: "Graphite", amount: 50)]),
            TechResearchData(databaseItemName: "Placer", gridPosition: GridPosition(x:0,y:0), dependencies: ["Picker"], visualConnections: ["Picker"], researchCosts: [ResourceCost(resourceName: "Graphite", amount: 100), ResourceCost(resourceName: "Iron", amount: 75)]),
            TechResearchData(databaseItemName: "Constructor", gridPosition: GridPosition(x:0,y:0), dependencies: ["Placer"], visualConnections: ["Placer"], researchCosts: [ResourceCost(resourceName: "Iron", amount: 150), ResourceCost(resourceName: "Steel", amount: 100)]),
            TechResearchData(databaseItemName: "Deconstructor", gridPosition: GridPosition(x:0,y:0), dependencies: ["Constructor"], visualConnections: ["Constructor"], researchCosts: [ResourceCost(resourceName: "Steel", amount: 150), ResourceCost(resourceName: "Silicon", amount: 100)]),
            TechResearchData(databaseItemName: "Large Constructor", gridPosition: GridPosition(x:0,y:0), dependencies: ["Constructor"], visualConnections: ["Constructor"], researchCosts: [ResourceCost(resourceName: "Steel", amount: 200), ResourceCost(resourceName: "Silicon", amount: 150)]),
            TechResearchData(databaseItemName: "Large Deconstructor", gridPosition: GridPosition(x:0,y:0), dependencies: ["Deconstructor"], visualConnections: ["Deconstructor"], researchCosts: [ResourceCost(resourceName: "Silicon", amount: 200), ResourceCost(resourceName: "Circuit", amount: 100)]),
            
            // === CORE ===
            TechResearchData(databaseItemName: "Core: Shard", gridPosition: GridPosition(x:0,y:0), dependencies: [], visualConnections: [], researchCosts: []),
            TechResearchData(databaseItemName: "Core: Fragment", gridPosition: GridPosition(x:0,y:0), dependencies: ["Core: Shard"], visualConnections: ["Core: Shard"], researchCosts: []),
            TechResearchData(databaseItemName: "Core: Remnant", gridPosition: GridPosition(x:0,y:0), dependencies: ["Core: Fragment"], visualConnections: ["Core: Fragment"], researchCosts: [ResourceCost(resourceName: "Graphite", amount: 200)]),
            TechResearchData(databaseItemName: "Core: Bastion", gridPosition: GridPosition(x:0,y:0), dependencies: ["Core: Remnant"], visualConnections: ["Core: Remnant"], researchCosts: [ResourceCost(resourceName: "Silicon", amount: 400)]),
            TechResearchData(databaseItemName: "Core: Crucible", gridPosition: GridPosition(x:0,y:0), dependencies: ["Core: Bastion"], visualConnections: ["Core: Bastion"], researchCosts: [ResourceCost(resourceName: "Silicon", amount: 600)]),
            TechResearchData(databaseItemName: "Core: Interplanetary", gridPosition: GridPosition(x:0,y:0), dependencies: ["Core: Bastion"], visualConnections: ["Core: Bastion"], researchCosts: [ResourceCost(resourceName: "Hydrogen", amount: 800)]),
            TechResearchData(databaseItemName: "Core: Aegis", gridPosition: GridPosition(x:0,y:0), dependencies: ["Core: Crucible"], visualConnections: ["Core: Crucible"], researchCosts: [ResourceCost(resourceName: "Hydrogen", amount: 1500)]),
            TechResearchData(databaseItemName: "Core: Singularity", gridPosition: GridPosition(x:0,y:0), dependencies: ["Core: Aegis"], visualConnections: ["Core: Aegis"], researchCosts: [ResourceCost(resourceName: "Hydrogen", amount: 3000)]),
            
            // === PRODUCTION ===
            TechResearchData(databaseItemName: "Copper", gridPosition: GridPosition(x:0,y:0), dependencies: ["Core: Shard"], visualConnections: ["Core: Shard"], researchCosts: []),
            TechResearchData(databaseItemName: "Graphite", gridPosition: GridPosition(x:0,y:0), dependencies: ["Copper"], visualConnections: ["Copper"], researchCosts: [ResourceCost(resourceName: "Copper", amount: 100)]),
            TechResearchData(databaseItemName: "Water", gridPosition: GridPosition(x:0,y:0), dependencies: ["Copper"], visualConnections: ["Copper"], researchCosts: [ResourceCost(resourceName: "Copper", amount: 150)]),
            TechResearchData(databaseItemName: "Silicon", gridPosition: GridPosition(x:0,y:0), dependencies: ["Graphite"], visualConnections: ["Graphite"], researchCosts: [ResourceCost(resourceName: "Graphite", amount: 150)]),
            TechResearchData(databaseItemName: "Iron", gridPosition: GridPosition(x:0,y:0), dependencies: ["Water", "Graphite"], visualConnections: [], researchCosts: [ResourceCost(resourceName: "Water", amount: 200), ResourceCost(resourceName: "Graphite", amount: 200)]),
            TechResearchData(databaseItemName: "Steel", gridPosition: GridPosition(x:0,y:0), dependencies: ["Iron"], visualConnections: ["Iron"], researchCosts: [ResourceCost(resourceName: "Iron", amount: 300)]),
            TechResearchData(databaseItemName: "Hydrogen", gridPosition: GridPosition(x:0,y:0), dependencies: ["Water"], visualConnections: ["Water"], researchCosts: [ResourceCost(resourceName: "Water", amount: 500)]),
            TechResearchData(databaseItemName: "Oxygen", gridPosition: GridPosition(x:0,y:0), dependencies: ["Water"], visualConnections: ["Water"], researchCosts: [ResourceCost(resourceName: "Water", amount: 400)]),
            TechResearchData(databaseItemName: "Coal", gridPosition: GridPosition(x:0,y:0), dependencies: [], visualConnections: [], researchCosts: []),
            
            // === FLUIDS ===
            TechResearchData(databaseItemName: "Petroleum", gridPosition: GridPosition(x:0,y:0), dependencies: ["Petroleum Drill"], visualConnections: ["Petroleum Drill"], researchCosts: [ResourceCost(resourceName: "Steel", amount: 300), ResourceCost(resourceName: "Silicon", amount: 200)]),
            
            // === GASES ===
            TechResearchData(databaseItemName: "Ethane", gridPosition: GridPosition(x:0,y:0), dependencies: ["Petroleum"], visualConnections: ["Petroleum"], researchCosts: [ResourceCost(resourceName: "Steel", amount: 200), ResourceCost(resourceName: "Circuit", amount: 100)]),
            TechResearchData(databaseItemName: "Methane", gridPosition: GridPosition(x:0,y:0), dependencies: ["Ethane"], visualConnections: ["Ethane"], researchCosts: [ResourceCost(resourceName: "Circuit", amount: 150), ResourceCost(resourceName: "Hydrogen", amount: 100)]),
            TechResearchData(databaseItemName: "Butane", gridPosition: GridPosition(x:0,y:0), dependencies: ["Methane"], visualConnections: ["Methane"], researchCosts: [ResourceCost(resourceName: "Circuit", amount: 200), ResourceCost(resourceName: "Hydrogen", amount: 150)]),
            TechResearchData(databaseItemName: "Propane", gridPosition: GridPosition(x:0,y:0), dependencies: ["Butane"], visualConnections: ["Butane"], researchCosts: [ResourceCost(resourceName: "Circuit", amount: 250), ResourceCost(resourceName: "Hydrogen", amount: 200)]),
            
            // === ADVANCED RESOURCES ===
            TechResearchData(databaseItemName: "Raw Aluminum", gridPosition: GridPosition(x:0,y:0), dependencies: ["Mineral Extractor"], visualConnections: ["Mineral Extractor"], researchCosts: [ResourceCost(resourceName: "Silicon", amount: 400), ResourceCost(resourceName: "Circuit", amount: 200)]),
            TechResearchData(databaseItemName: "Aluminum", gridPosition: GridPosition(x:0,y:0), dependencies: ["Raw Aluminum"], visualConnections: ["Raw Aluminum"], researchCosts: [ResourceCost(resourceName: "Circuit", amount: 300), ResourceCost(resourceName: "Hydrogen", amount: 250)]),
            
            // Production buildings
            TechResearchData(databaseItemName: "Steel Furnace", gridPosition: GridPosition(x:0,y:0), dependencies: ["Iron"], visualConnections: ["Silicon Mixer"], researchCosts: [ResourceCost(resourceName: "Steel", amount: 500)]),
            TechResearchData(databaseItemName: "Silicon Mixer", gridPosition: GridPosition(x:0,y:0), dependencies: ["Core: Shard"], visualConnections: ["Core: Shard"], researchCosts: []),
            TechResearchData(databaseItemName: "Graphite Electrolyzer", gridPosition: GridPosition(x:0,y:0), dependencies: ["Graphite"], visualConnections: ["Silicon Mixer"], researchCosts: []),
            TechResearchData(databaseItemName: "Circuit Printer", gridPosition: GridPosition(x:0,y:0), dependencies: ["Silicon Mixer", "Graphite Electrolyzer"], visualConnections: ["Silicon Mixer"], researchCosts: []),
            TechResearchData(databaseItemName: "Carbon-Dioxide Concentrator", gridPosition: GridPosition(x:0,y:0), dependencies: ["Steel Furnace"], visualConnections: ["Steel Furnace"], researchCosts: []),
            TechResearchData(databaseItemName: "Petroleum Refinery", gridPosition: GridPosition(x:0,y:0), dependencies: ["Carbon-Dioxide Concentrator"], visualConnections: ["Carbon-Dioxide Concentrator"], researchCosts: []),
            
            // === DRILLS ===
            TechResearchData(databaseItemName: "Mechanical Drill", gridPosition: GridPosition(x:0,y:0), dependencies: ["Core: Shard"], visualConnections: ["Core: Shard"], researchCosts: []),
            TechResearchData(databaseItemName: "Plasma Bore", gridPosition: GridPosition(x:0,y:0), dependencies: ["Mechanical Drill"], visualConnections: ["Mechanical Drill"], researchCosts: []),
            TechResearchData(databaseItemName: "Advanced Plasma Bore", gridPosition: GridPosition(x:0,y:0), dependencies: ["Plasma Bore"], visualConnections: ["Plasma Bore"], researchCosts: []),
            TechResearchData(databaseItemName: "Mineral Extractor", gridPosition: GridPosition(x:0,y:0), dependencies: ["Advanced Plasma Bore"], visualConnections: ["Advanced Plasma Bore"], researchCosts: []),
            TechResearchData(databaseItemName: "Petroleum Drill", gridPosition: GridPosition(x:0,y:0), dependencies: ["Advanced Plasma Bore"], visualConnections: ["Advanced Plasma Bore"], researchCosts: []),
            
            // === POWER ===
            TechResearchData(databaseItemName: "Steam Engine", gridPosition: GridPosition(x:0,y:0), dependencies: ["Core: Shard"], visualConnections: ["Core: Shard"], researchCosts: []),
            TechResearchData(databaseItemName: "Combustion Engine", gridPosition: GridPosition(x:0,y:0), dependencies: ["Steam Engine"], visualConnections: ["Steam Engine"], researchCosts: []),
            TechResearchData(databaseItemName: "Combustion Generator", gridPosition: GridPosition(x:0,y:0), dependencies: ["Vent Turbine"], visualConnections: ["Vent Turbine"], researchCosts: []),
            TechResearchData(databaseItemName: "Vent Turbine", gridPosition: GridPosition(x:0,y:0), dependencies: ["Steam Engine"], visualConnections: ["Steam Engine"], researchCosts: []),
            TechResearchData(databaseItemName: "Beam Node", gridPosition: GridPosition(x:0,y:0), dependencies: ["Vent Turbine"], visualConnections: ["Vent Turbine"], researchCosts: []),
            TechResearchData(databaseItemName: "Beam Tower", gridPosition: GridPosition(x:0,y:0), dependencies: ["Beam Node"], visualConnections: ["Beam Node"], researchCosts: []),
            TechResearchData(databaseItemName: "Shaft", gridPosition: GridPosition(x:0,y:0), dependencies: ["Steam Engine"], visualConnections: ["Steam Engine"], researchCosts: []),
            TechResearchData(databaseItemName: "Gearbox", gridPosition: GridPosition(x:0,y:0), dependencies: ["Shaft"], visualConnections: ["Shaft"], researchCosts: []),
            
            // === SECTORS ===
            TechResearchData(databaseItemName: "Starting Grounds", gridPosition: GridPosition(x:0,y:0), dependencies: ["Core: Shard"], visualConnections: ["Core: Shard"], researchCosts: []),
            TechResearchData(databaseItemName: "Ferrum Ridge", gridPosition: GridPosition(x:0,y:0), dependencies: ["Starting Grounds"], visualConnections: ["Starting Grounds"], researchCosts: []),
            TechResearchData(databaseItemName: "Crevice", gridPosition: GridPosition(x:0,y:0), dependencies: ["Ferrum Ridge"], visualConnections: ["Ferrum Ridge"], researchCosts: []),
            TechResearchData(databaseItemName: "Nightfall Depths", gridPosition: GridPosition(x:0,y:0), dependencies: ["Crevice"], visualConnections: ["Crevice"], researchCosts: []),
            TechResearchData(databaseItemName: "Aluminum Mountains", gridPosition: GridPosition(x:0,y:0), dependencies: ["Nightfall Depths"], visualConnections: ["Nightfall Depths"], researchCosts: []),
            TechResearchData(databaseItemName: "Dark Valley", gridPosition: GridPosition(x:0,y:0), dependencies: ["Aluminum Mountains"], visualConnections: ["Aluminum Mountains"], researchCosts: []),
            TechResearchData(databaseItemName: "Ruins", gridPosition: GridPosition(x:0,y:0), dependencies: ["Dark Valley"], visualConnections: ["Dark Valley"], researchCosts: []),
            
            // === WEAPONS ===
            TechResearchData(databaseItemName: "Single Barrel", gridPosition: GridPosition(x:0,y:0), dependencies: ["Core: Shard"], visualConnections: ["Core: Shard"], researchCosts: []),
            TechResearchData(databaseItemName: "Diffuse", gridPosition: GridPosition(x:0,y:0), dependencies: ["Single Barrel"], visualConnections: ["Single Barrel"], researchCosts: []),
            TechResearchData(databaseItemName: "Double Barrel", gridPosition: GridPosition(x:0,y:0), dependencies: ["Single Barrel"], visualConnections: ["Single Barrel"], researchCosts: []),
            TechResearchData(databaseItemName: "Destroy", gridPosition: GridPosition(x:0,y:0), dependencies: ["Single Barrel"], visualConnections: ["Single Barrel"], researchCosts: []),
            TechResearchData(databaseItemName: "EMP Diffuse", gridPosition: GridPosition(x:0,y:0), dependencies: ["Homing Diffuse"], visualConnections: ["Homing Diffuse"], researchCosts: []),
            TechResearchData(databaseItemName: "Disarm", gridPosition: GridPosition(x:0,y:0), dependencies: ["Destroy"], visualConnections: ["Destroy"], researchCosts: []),
            TechResearchData(databaseItemName: "Annihilate", gridPosition: GridPosition(x:0,y:0), dependencies: ["Destroy"], visualConnections: ["Destroy"], researchCosts: []),
            TechResearchData(databaseItemName: "Homing Diffuse", gridPosition: GridPosition(x:0,y:0), dependencies: ["Diffuse"], visualConnections: ["Diffuse"], researchCosts: []),
            TechResearchData(databaseItemName: "Aegis Arc", gridPosition: GridPosition(x:0,y:0), dependencies: ["EMP Diffuse"], visualConnections: ["EMP Diffuse"], researchCosts: []),
            TechResearchData(databaseItemName: "Gauss Launcher", gridPosition: GridPosition(x:0,y:0), dependencies: ["Disarm"], visualConnections: ["Disarm"], researchCosts: []),
            TechResearchData(databaseItemName: "Eclipse", gridPosition: GridPosition(x:0,y:0), dependencies: ["Annihilate"], visualConnections: ["Annihilate"], researchCosts: [ResourceCost(resourceName: "Hydrogen", amount: 800)]),
            TechResearchData(databaseItemName: "Missile Launcher", gridPosition: GridPosition(x:0,y:0), dependencies: ["Annihilate"], visualConnections: ["Annihilate"], researchCosts: []),
            TechResearchData(databaseItemName: "Quad Barrel", gridPosition: GridPosition(x:0,y:0), dependencies: ["Double Barrel"], visualConnections: ["Double Barrel"], researchCosts: []),
            TechResearchData(databaseItemName: "Octo Barrel", gridPosition: GridPosition(x:0,y:0), dependencies: ["Quad Barrel"], visualConnections: ["Quad Barrel"], researchCosts: []),
            TechResearchData(databaseItemName: "Duodec", gridPosition: GridPosition(x:0,y:0), dependencies: ["Octo Barrel"], visualConnections: ["Octo Barrel"], researchCosts: []),
            TechResearchData(databaseItemName: "Quaddec", gridPosition: GridPosition(x:0,y:0), dependencies: ["Duodec"], visualConnections: ["Duodec"], researchCosts: []),
            TechResearchData(databaseItemName: "Shardstorm", gridPosition: GridPosition(x:0,y:0), dependencies: ["Double Barrel", "Homing Diffuse"], visualConnections: ["Homing Diffuse", "Double Barrel"], researchCosts: []),
            TechResearchData(databaseItemName: "Thunderburst", gridPosition: GridPosition(x:0,y:0), dependencies: ["Shardstorm"], visualConnections: ["Shardstorm"], researchCosts: []),
            
            // === TRANSPORTATION ===
            TechResearchData(databaseItemName: "Conveyor Belt", gridPosition: GridPosition(x:0,y:0), dependencies: ["Core: Shard"], visualConnections: ["Core: Shard"], researchCosts: [ResourceCost(resourceName: "Copper", amount: 50)]),
            TechResearchData(databaseItemName: "Belt Junction", gridPosition: GridPosition(x:0,y:0), dependencies: ["Conveyor Belt"], visualConnections: ["Conveyor Belt"], researchCosts: [ResourceCost(resourceName: "Copper", amount: 100)]),
            TechResearchData(databaseItemName: "Belt Router", gridPosition: GridPosition(x:0,y:0), dependencies: ["Conveyor Belt"], visualConnections: ["Conveyor Belt"], researchCosts: [ResourceCost(resourceName: "Copper", amount: 125)]),
            TechResearchData(databaseItemName: "Belt Bridge", gridPosition: GridPosition(x:0,y:0), dependencies: ["Conveyor Belt"], visualConnections: ["Conveyor Belt"], researchCosts: [ResourceCost(resourceName: "Copper", amount: 150)]),
            TechResearchData(databaseItemName: "Belt Sorter", gridPosition: GridPosition(x:0,y:0), dependencies: ["Conveyor Belt"], visualConnections: ["Conveyor Belt"], researchCosts: [ResourceCost(resourceName: "Copper", amount: 100)]),
            TechResearchData(databaseItemName: "Inverted Belt Sorter", gridPosition: GridPosition(x:0,y:0), dependencies: ["Belt Sorter"], visualConnections: ["Belt Sorter"], researchCosts: []),
            TechResearchData(databaseItemName: "Underflow Belt", gridPosition: GridPosition(x:0,y:0), dependencies: ["Overflow Belt"], visualConnections: ["Overflow Belt"], researchCosts: []),
            TechResearchData(databaseItemName: "Overflow Belt", gridPosition: GridPosition(x:0,y:0), dependencies: ["Conveyor Belt"], visualConnections: ["Conveyor Belt"], researchCosts: [ResourceCost(resourceName: "Copper", amount: 200)]),
            TechResearchData(databaseItemName: "Cargo Mass Driver", gridPosition: GridPosition(x:0,y:0), dependencies: ["Belt Bridge"], visualConnections: ["Belt Bridge"], researchCosts: []),
            
            // === PAYLOAD TRANSPORTATION ===
            TechResearchData(databaseItemName: "Payload Conveyor", gridPosition: GridPosition(x:0,y:0), dependencies: ["Conveyor Belt"], visualConnections: ["Conveyor Belt"], researchCosts: [ResourceCost(resourceName: "Iron", amount: 200), ResourceCost(resourceName: "Steel", amount: 100)]),
            TechResearchData(databaseItemName: "Payload Router", gridPosition: GridPosition(x:0,y:0), dependencies: ["Payload Conveyor"], visualConnections: ["Payload Conveyor"], researchCosts: [ResourceCost(resourceName: "Steel", amount: 150)]),
            TechResearchData(databaseItemName: "Payload Junction", gridPosition: GridPosition(x:0,y:0), dependencies: ["Payload Conveyor"], visualConnections: ["Payload Conveyor"], researchCosts: [ResourceCost(resourceName: "Steel", amount: 100)]),
            TechResearchData(databaseItemName: "Payload Bridge", gridPosition: GridPosition(x:0,y:0), dependencies: ["Payload Conveyor"], visualConnections: ["Payload Conveyor"], researchCosts: [ResourceCost(resourceName: "Steel", amount: 125)]),
            TechResearchData(databaseItemName: "Payload Rail", gridPosition: GridPosition(x:0,y:0), dependencies: ["Payload Router"], visualConnections: ["Payload Router"], researchCosts: [ResourceCost(resourceName: "Steel", amount: 200), ResourceCost(resourceName: "Silicon", amount: 100)]),
            TechResearchData(databaseItemName: "Payload Loader", gridPosition: GridPosition(x:0,y:0), dependencies: ["Payload Junction"], visualConnections: ["Payload Junction"], researchCosts: [ResourceCost(resourceName: "Steel", amount: 150), ResourceCost(resourceName: "Silicon", amount: 75)]),
            TechResearchData(databaseItemName: "Payload Unloader", gridPosition: GridPosition(x:0,y:0), dependencies: ["Payload Loader"], visualConnections: ["Payload Loader"], researchCosts: [ResourceCost(resourceName: "Steel", amount: 150), ResourceCost(resourceName: "Silicon", amount: 75)]),
            TechResearchData(databaseItemName: "Payload Mass Driver", gridPosition: GridPosition(x:0,y:0), dependencies: ["Payload Rail"], visualConnections: ["Payload Rail"], researchCosts: [ResourceCost(resourceName: "Silicon", amount: 300), ResourceCost(resourceName: "Circuit", amount: 150)]),
            
            // === FREIGHT TRANSPORTATION ===
            TechResearchData(databaseItemName: "Freight Conveyer", gridPosition: GridPosition(x:0,y:0), dependencies: ["Payload Conveyor"], visualConnections: ["Payload Conveyor"], researchCosts: [ResourceCost(resourceName: "Steel", amount: 300), ResourceCost(resourceName: "Silicon", amount: 200)]),
            TechResearchData(databaseItemName: "Freight Router", gridPosition: GridPosition(x:0,y:0), dependencies: ["Freight Conveyer"], visualConnections: ["Freight Conveyer"], researchCosts: [ResourceCost(resourceName: "Silicon", amount: 250)]),
            TechResearchData(databaseItemName: "Freight Junction", gridPosition: GridPosition(x:0,y:0), dependencies: ["Freight Conveyer"], visualConnections: ["Freight Conveyer"], researchCosts: [ResourceCost(resourceName: "Silicon", amount: 200)]),
            TechResearchData(databaseItemName: "Freight Bridge", gridPosition: GridPosition(x:0,y:0), dependencies: ["Freight Conveyer"], visualConnections: ["Freight Conveyer"], researchCosts: [ResourceCost(resourceName: "Silicon", amount: 225)]),
            TechResearchData(databaseItemName: "Freight Rail", gridPosition: GridPosition(x:0,y:0), dependencies: ["Freight Router"], visualConnections: ["Freight Router"], researchCosts: [ResourceCost(resourceName: "Silicon", amount: 300), ResourceCost(resourceName: "Circuit", amount: 150)]),
            TechResearchData(databaseItemName: "Freight Loader", gridPosition: GridPosition(x:0,y:0), dependencies: ["Freight Junction"], visualConnections: ["Freight Junction"], researchCosts: [ResourceCost(resourceName: "Silicon", amount: 250), ResourceCost(resourceName: "Circuit", amount: 100)]),
            TechResearchData(databaseItemName: "Freight Unloader", gridPosition: GridPosition(x:0,y:0), dependencies: ["Freight Loader"], visualConnections: ["Freight Loader"], researchCosts: [ResourceCost(resourceName: "Silicon", amount: 250), ResourceCost(resourceName: "Circuit", amount: 100)]),
            TechResearchData(databaseItemName: "Freight Mass Driver", gridPosition: GridPosition(x:0,y:0), dependencies: ["Freight Rail"], visualConnections: ["Freight Rail"], researchCosts: [ResourceCost(resourceName: "Circuit", amount: 400), ResourceCost(resourceName: "Hydrogen", amount: 200)]),
            
            // === RAIL SYSTEMS ===
            TechResearchData(databaseItemName: "Rail Router", gridPosition: GridPosition(x:0,y:0), dependencies: ["Payload Rail"], visualConnections: ["Payload Rail"], researchCosts: [ResourceCost(resourceName: "Steel", amount: 150), ResourceCost(resourceName: "Silicon", amount: 100)]),
            TechResearchData(databaseItemName: "Rail Junction", gridPosition: GridPosition(x:0,y:0), dependencies: ["Rail Router"], visualConnections: ["Rail Router"], researchCosts: [ResourceCost(resourceName: "Silicon", amount: 150)]),
            TechResearchData(databaseItemName: "Rail Bridge", gridPosition: GridPosition(x:0,y:0), dependencies: ["Rail Junction"], visualConnections: ["Rail Junction"], researchCosts: [ResourceCost(resourceName: "Silicon", amount: 175)]),
            TechResearchData(databaseItemName: "Freight Rail Router", gridPosition: GridPosition(x:0,y:0), dependencies: ["Freight Rail"], visualConnections: ["Freight Rail"], researchCosts: [ResourceCost(resourceName: "Silicon", amount: 200), ResourceCost(resourceName: "Circuit", amount: 100)]),
            TechResearchData(databaseItemName: "Freight Rail Junction", gridPosition: GridPosition(x:0,y:0), dependencies: ["Freight Rail Router"], visualConnections: ["Freight Rail Router"], researchCosts: [ResourceCost(resourceName: "Circuit", amount: 150)]),
            TechResearchData(databaseItemName: "Freight Rail Bridge", gridPosition: GridPosition(x:0,y:0), dependencies: ["Freight Rail Junction"], visualConnections: ["Freight Rail Junction"], researchCosts: [ResourceCost(resourceName: "Circuit", amount: 175)]),
            
            // Ducts
            TechResearchData(databaseItemName: "Duct", gridPosition: GridPosition(x:0,y:0), dependencies: ["Conveyor Belt"], visualConnections: ["Conveyor Belt"], researchCosts: []),
            TechResearchData(databaseItemName: "Duct Junction", gridPosition: GridPosition(x:0,y:0), dependencies: ["Duct"], visualConnections: ["Duct"], researchCosts: []),
            TechResearchData(databaseItemName: "Duct Router", gridPosition: GridPosition(x:0,y:0), dependencies: ["Duct"], visualConnections: ["Duct"], researchCosts: []),
            TechResearchData(databaseItemName: "Duct Bridge", gridPosition: GridPosition(x:0,y:0), dependencies: ["Duct"], visualConnections: ["Duct"], researchCosts: []),
            TechResearchData(databaseItemName: "Duct Sorter", gridPosition: GridPosition(x:0,y:0), dependencies: ["Duct"], visualConnections: ["Duct"], researchCosts: []),
            TechResearchData(databaseItemName: "Overflow Duct", gridPosition: GridPosition(x:0,y:0), dependencies: ["Duct"], visualConnections: ["Duct"], researchCosts: []),
            TechResearchData(databaseItemName: "Underflow Duct", gridPosition: GridPosition(x:0,y:0), dependencies: ["Overflow Duct"], visualConnections: ["Overflow Duct"], researchCosts: []),
            TechResearchData(databaseItemName: "Inverted Duct Sorter", gridPosition: GridPosition(x:0,y:0), dependencies: ["Duct Sorter"], visualConnections: ["Duct Sorter"], researchCosts: []),
            
            // === FLUID SYSTEMS ===
            TechResearchData(databaseItemName: "Fluid Conduit", gridPosition: GridPosition(x:0,y:0), dependencies: ["Core: Shard"], visualConnections: ["Core: Shard"], researchCosts: [ResourceCost(resourceName: "Copper", amount: 75)]),
            TechResearchData(databaseItemName: "Conduit Router", gridPosition: GridPosition(x:0,y:0), dependencies: ["Fluid Conduit"], visualConnections: ["Fluid Conduit"], researchCosts: [ResourceCost(resourceName: "Copper", amount: 150)]),
            TechResearchData(databaseItemName: "Conduit Bridge", gridPosition: GridPosition(x:0,y:0), dependencies: ["Fluid Conduit"], visualConnections: ["Fluid Conduit"], researchCosts: [ResourceCost(resourceName: "Copper", amount: 175)]),
            TechResearchData(databaseItemName: "Conduit Sorter", gridPosition: GridPosition(x:0,y:0), dependencies: ["Fluid Conduit"], visualConnections: ["Fluid Conduit"], researchCosts: []),
            TechResearchData(databaseItemName: "Underflow Conduit", gridPosition: GridPosition(x:0,y:0), dependencies: ["Overflow Conduit"], visualConnections: ["Overflow Conduit"], researchCosts: []),
            TechResearchData(databaseItemName: "Overflow Conduit", gridPosition: GridPosition(x:0,y:0), dependencies: ["Fluid Conduit"], visualConnections: ["Fluid Conduit"], researchCosts: []),
            TechResearchData(databaseItemName: "Sealed Cargo Mass Driver", gridPosition: GridPosition(x:0,y:0), dependencies: ["Conduit Bridge"], visualConnections: ["Conduit Bridge"], researchCosts: []),
            TechResearchData(databaseItemName: "Fluid Pump", gridPosition: GridPosition(x:0,y:0), dependencies: ["Fluid Conduit"], visualConnections: ["Fluid Conduit"], researchCosts: [ResourceCost(resourceName: "Graphite", amount: 150)]),
            TechResearchData(databaseItemName: "Vent Condenser", gridPosition: GridPosition(x:0,y:0), dependencies: ["Fluid Conduit"], visualConnections: ["Fluid Conduit"], researchCosts: []),
            TechResearchData(databaseItemName: "Geyser Condenser", gridPosition: GridPosition(x:0,y:0), dependencies: ["Vent Condenser"], visualConnections: ["Vent Condenser"], researchCosts: []),
            TechResearchData(databaseItemName: "Conduit Junction", gridPosition: GridPosition(x:0,y:0), dependencies: ["Fluid Conduit"], visualConnections: ["Fluid Conduit"], researchCosts: []),
        ]
        
        // Convert research data to tech nodes
        nodes = researchData.compactMap { data in
            // Verify the item exists in the database
            guard DatabaseManager.shared.findItem(named: data.databaseItemName) != nil else {
                print("Warning: Could not find database item named '\(data.databaseItemName)'")
                return nil
            }
            return TechNode(from: data)
        }
        
        // Mark starting nodes as researched
        markInitialResearchedNodes()
    }
    
    private func markInitialResearchedNodes() {
        let initialResearchedItems = ["Copper", "Coal", "Core: Shard", "Starting Grounds"]
        
        for itemName in initialResearchedItems {
            if let index = nodes.firstIndex(where: { $0.databaseItemName == itemName }) {
                nodes[index].isResearched = true
                nodes[index].isUnlocked = true
            }
        }
    }
    
    private func layoutUnifiedTechTree() {
        // Layout following the exact column order: Units | Turrets | Factories | Cores | Conveyers & Ducts | Fluids | Resource Extractors | Resources
        var positionMap: [String: GridPosition] = [:]
        
        // === COLUMN 1: UNITS (0-4) ===
        // Tank Fabricator as root at bottom
        positionMap["Tank Fabricator"   ] = GridPosition(x: -24, y: -1)
        
        // Ant chain (leftmost)
        positionMap["Ant"               ] = GridPosition(x: -27, y: -2)
        positionMap["Crawler Fabricator"] = GridPosition(x: -28, y: -3)
        positionMap["Geckeo"            ] = GridPosition(x: -28, y: -4)
        positionMap["Lizard"            ] = GridPosition(x: -28, y: -5)
        positionMap["Iguana"            ] = GridPosition(x: -28, y: -6)
        positionMap["Chameleon"         ] = GridPosition(x: -28, y: -7)
        positionMap["Monitor"           ] = GridPosition(x: -28, y: -8)
        
        // Beetle branch
        positionMap["Beetle"   ] = GridPosition(x: -27, y: -3)
        positionMap["Termite"  ] = GridPosition(x: -27, y: -4)
        positionMap["Armadillo"] = GridPosition(x: -27, y: -5)
        positionMap["Turtle"   ] = GridPosition(x: -27, y: -6)
        
        // support branch
        positionMap["Destroy "  ] = GridPosition(x: -26, y: -4)
        positionMap["Rebuild"  ] = GridPosition(x: -26, y: -5)
        positionMap["Assist"   ] = GridPosition(x: -26, y: -6)
        positionMap["Support"  ] = GridPosition(x: -26, y: -7)
        positionMap["Protect"  ] = GridPosition(x: -26, y: -8)
        
        // Hover units
        positionMap["Hoverboard"     ] = GridPosition(x: -25, y: -3)
        positionMap["Hover-transport"] = GridPosition(x: -25, y: -4)
        positionMap["Hoverlift"      ] = GridPosition(x: -25, y: -5)
        positionMap["Hovercraft"     ] = GridPosition(x: -25, y: -6)
        positionMap["Hovership"      ] = GridPosition(x: -25, y: -7)
        
        // Flying units
        positionMap["Fly"    ] = GridPosition(x: -24, y: -3)
        positionMap["Moth"   ] = GridPosition(x: -24, y: -4)
        positionMap["Kestrel"] = GridPosition(x: -24, y: -5)
        positionMap["Hawk"   ] = GridPosition(x: -24, y: -6)
        positionMap["Eagle"  ] = GridPosition(x: -24, y: -7)
        
        // Fabricators
        positionMap["Ship Fabricator"  ] = GridPosition(x: -24, y: -2)
        positionMap["Hover Fabricator" ] = GridPosition(x: -25, y: -2)
        positionMap["Support Hover Fabricator" ] = GridPosition(x: -26, y: -3)
        positionMap["Unit Assembler"   ] = GridPosition(x: -23, y: -5)
        positionMap["Unit Reassembler" ] = GridPosition(x: -23, y: -4)
        positionMap["Unit Upgrader"    ] = GridPosition(x: -23, y: -3)
        positionMap["Unit Refabricator"] = GridPosition(x: -23, y: -2)
        
        // Construction blocks
        positionMap["Picker"             ] = GridPosition(x: -22, y: -2)
        positionMap["Placer"             ] = GridPosition(x: -22, y: -3)
        positionMap["Constructor"        ] = GridPosition(x: -22, y: -4)
        positionMap["Deconstructor"      ] = GridPosition(x: -22, y: -5)
        positionMap["Large Constructor"  ] = GridPosition(x: -21, y: -4)
        positionMap["Large Deconstructor"] = GridPosition(x: -21, y: -5)
        
        // === COLUMN 2: TURRETS/WEAPONS (Updated to match diagram) ===
        positionMap["Single Barrel"   ] = GridPosition(x: -9, y: -1)
        positionMap["Diffuse"         ] = GridPosition(x: -9, y: -2)
        positionMap["Double Barrel"   ] = GridPosition(x: -8, y: -2)
        positionMap["Destroy"         ] = GridPosition(x: -10, y: -2)
        positionMap["EMP Diffuse"     ] = GridPosition(x: -9, y: -4)
        positionMap["Disarm"          ] = GridPosition(x: -11, y: -2)
        positionMap["Annihilate"      ] = GridPosition(x: -10, y: -3)
        positionMap["Homing Diffuse"  ] = GridPosition(x: -9, y: -3)
        positionMap["Aegis Arc"       ] = GridPosition(x: -9, y: -5)
        positionMap["Gauss Launcher"  ] = GridPosition(x: -12, y: -2)
        positionMap["Missile Launcher"] = GridPosition(x: -11, y: -4)
        positionMap["Eclipse"         ] = GridPosition(x: -10, y: -4)
        positionMap["Quad Barrel"     ] = GridPosition(x: -7, y: -2)
        positionMap["Octo Barrel"     ] = GridPosition(x: -7, y: -3)
        positionMap["Duodec"          ] = GridPosition(x: -7, y: -4)
        positionMap["Quaddec"         ] = GridPosition(x: -7, y: -5)
        positionMap["Shardstorm"      ] = GridPosition(x: -8, y: -3)
        positionMap["Thunderburst"    ] = GridPosition(x: -8, y: -4)
        
        // === COLUMN 3: FACTORIES/PRODUCTION (10-12) ===
        positionMap["Silicon Mixer"              ] = GridPosition(x: -4, y: -1)
        positionMap["Graphite Electrolyzer"      ] = GridPosition(x: -4, y: -2)
        positionMap["Circuit Printer"            ] = GridPosition(x: -3, y: -2)
        positionMap["Steel Furnace"              ] = GridPosition(x: -5, y: -2)
        positionMap["Carbon-Dioxide Concentrator"] = GridPosition(x: -5, y: -3)
        positionMap["Petroleum Refinery"         ] = GridPosition(x: -5, y: -4)
        
        // === COLUMN 4: CORES (14) ===
        positionMap["Core: Shard"         ] = GridPosition(x: 0,  y: 0)
        positionMap["Core: Fragment"      ] = GridPosition(x: -2, y: -1)
        positionMap["Core: Remnant"       ] = GridPosition(x: -2, y: -2)
        positionMap["Core: Bastion"       ] = GridPosition(x: -2, y: -3)
        positionMap["Core: Crucible"      ] = GridPosition(x: -2, y: -4)
        positionMap["Core: Interplanetary"] = GridPosition(x: -3, y: -4)
        positionMap["Core: Aegis"         ] = GridPosition(x: -2, y: -5)
        positionMap["Core: Singularity"   ] = GridPosition(x: -2, y: -6)
        
        // === COLUMN 5: CONVEYERS & DUCTS (16-18) ===
        // Belt system
        positionMap["Conveyor Belt"       ] = GridPosition(x: 5, y: -1)
        positionMap["Belt Junction"       ] = GridPosition(x: 3, y: -2)
        positionMap["Belt Router"         ] = GridPosition(x: 4, y: -2)
        positionMap["Belt Bridge"         ] = GridPosition(x: 5, y: -2)
        positionMap["Belt Sorter"         ] = GridPosition(x: 6, y: -2)
        positionMap["Inverted Belt Sorter"] = GridPosition(x: 6, y: -3)
        positionMap["Underflow Belt"      ] = GridPosition(x: 7, y: -3)
        positionMap["Overflow Belt"       ] = GridPosition(x: 7, y: -2)
        positionMap["Cargo Mass Driver"   ] = GridPosition(x: 5, y: -3)
        
        // Duct system
        positionMap["Duct"                ] = GridPosition(x: 11, y: -2)
        positionMap["Duct Junction"       ] = GridPosition(x: 9,  y: -3)
        positionMap["Duct Router"         ] = GridPosition(x: 10, y: -3)
        positionMap["Duct Bridge"         ] = GridPosition(x: 11, y: -3)
        positionMap["Duct Sorter"         ] = GridPosition(x: 12, y: -3)
        positionMap["Overflow Duct"       ] = GridPosition(x: 13, y: -3)
        positionMap["Underflow Duct"      ] = GridPosition(x: 13, y: -4)
        positionMap["Inverted Duct Sorter"] = GridPosition(x: 12, y: -4)
        
        // === PAYLOAD TRANSPORTATION (14-16) ===
        positionMap["Payload Conveyor"   ] = GridPosition(x: 14, y: -2)
        positionMap["Payload Router"     ] = GridPosition(x: 14, y: -3)
        positionMap["Payload Junction"   ] = GridPosition(x: 15, y: -3)
        positionMap["Payload Bridge"     ] = GridPosition(x: 16, y: -3)
        positionMap["Payload Rail"       ] = GridPosition(x: 14, y: -4)
        positionMap["Payload Loader"     ] = GridPosition(x: 15, y: -4)
        positionMap["Payload Unloader"   ] = GridPosition(x: 16, y: -4)
        positionMap["Payload Mass Driver"] = GridPosition(x: 14, y: -5)
        
        // === FREIGHT TRANSPORTATION (17-19) ===
        positionMap["Freight Conveyer"   ] = GridPosition(x: 17, y: -3)
        positionMap["Freight Router"     ] = GridPosition(x: 17, y: -4)
        positionMap["Freight Junction"   ] = GridPosition(x: 18, y: -4)
        positionMap["Freight Bridge"     ] = GridPosition(x: 19, y: -4)
        positionMap["Freight Rail"       ] = GridPosition(x: 17, y: -5)
        positionMap["Freight Loader"     ] = GridPosition(x: 18, y: -5)
        positionMap["Freight Unloader"   ] = GridPosition(x: 19, y: -5)
        positionMap["Freight Mass Driver"] = GridPosition(x: 17, y: -6)
        
        // === RAIL SYSTEMS ===
        positionMap["Rail Router"          ] = GridPosition(x: 15, y: -5)
        positionMap["Rail Junction"        ] = GridPosition(x: 16, y: -5)
        positionMap["Rail Bridge"          ] = GridPosition(x: 17, y: -5)
        positionMap["Freight Rail Router"  ] = GridPosition(x: 18, y: -6)
        positionMap["Freight Rail Junction"] = GridPosition(x: 19, y: -6)
        positionMap["Freight Rail Bridge"  ] = GridPosition(x: 20, y: -6)
        
        // === COLUMN 6: FLUIDS (20-22) ===
        positionMap["Fluid Conduit"           ] = GridPosition(x: 22, y: -1)
        positionMap["Conduit Router"          ] = GridPosition(x: 21, y: -2)
        positionMap["Conduit Bridge"          ] = GridPosition(x: 22, y: -2)
        positionMap["Conduit Sorter"          ] = GridPosition(x: 23, y: -2)
        positionMap["Underflow Conduit"       ] = GridPosition(x: 24, y: -3)
        positionMap["Overflow Conduit"        ] = GridPosition(x: 24, y: -2)
        positionMap["Sealed Cargo Mass Driver"] = GridPosition(x: 22, y: -3)
        positionMap["Conduit Junction"        ] = GridPosition(x: 20, y: -2)
        // Pumps and condensers
        positionMap["Fluid Pump"              ] = GridPosition(x: 20, y: -3)
        positionMap["Vent Condenser"          ] = GridPosition(x: 21, y: -3)
        positionMap["Geyser Condenser"        ] = GridPosition(x: 21, y: -4)
        
        // === FLUIDS ===
        positionMap["Petroleum"               ] = GridPosition(x: 26, y: -5)
        
        // === GASES (25) ===
        positionMap["Ethane"                  ] = GridPosition(x: 25, y: -6)
        positionMap["Methane"                 ] = GridPosition(x: 25, y: -7)
        positionMap["Butane"                  ] = GridPosition(x: 26, y: -7)
        positionMap["Propane"                 ] = GridPosition(x: 27, y: -7)
        
        // === COLUMN 7: RESOURCE EXTRACTORS (27) ===
        positionMap["Mechanical Drill"    ] = GridPosition(x: 27, y: -1)
        positionMap["Plasma Bore"         ] = GridPosition(x: 27, y: -2)
        positionMap["Advanced Plasma Bore"] = GridPosition(x: 27, y: -3)
        positionMap["Mineral Extractor"   ] = GridPosition(x: 26, y: -4)
        positionMap["Petroleum Drill"     ] = GridPosition(x: 28, y: -4)
        
        // === COLUMN 8: RESOURCES (29-35) ===
        // Basic resources (following the diagram layout)
        positionMap["Copper"        ] = GridPosition(x: 31, y: -1)  // Bottom
        positionMap["Graphite"      ] = GridPosition(x: 31, y: -2)  // Above copper
        positionMap["Water"         ] = GridPosition(x: 30, y: -3)  // Side of graphite
        positionMap["Silicon"       ] = GridPosition(x: 31, y: -3)  // Above water
        positionMap["Iron"          ] = GridPosition(x: 32, y: -2)  // Right of silicon
        positionMap["Steel"         ] = GridPosition(x: 32, y: -3)  // Above iron
        positionMap["Hydrogen"      ] = GridPosition(x: 29, y: -4)  // Left side, above graphite
        positionMap["Oxygen"        ] = GridPosition(x: 31, y: -4)  // Above silicon
        positionMap["Coal"          ] = GridPosition(x: 36, y: -5)  // Independent, right of petroleum
        
        // Advanced resources
        positionMap["Raw Aluminum"  ] = GridPosition(x: 33, y: -4)  // Right of oxygen
        positionMap["Aluminum"      ] = GridPosition(x: 33, y: -5)  // Above raw aluminum
        
        // Power (fits in between cores and conveyers)
        positionMap["Steam Engine"        ] = GridPosition(x: 0,  y: -1)
        positionMap["Combustion Engine"   ] = GridPosition(x: 1,  y: -1)
        positionMap["Combustion Generator"] = GridPosition(x: 1,  y: -2)
        positionMap["Vent Turbine"        ] = GridPosition(x: 0,  y: -2)
        positionMap["Beam Node"           ] = GridPosition(x: 0,  y: -3)
        positionMap["Beam Tower"          ] = GridPosition(x: 0,  y: -4)
        positionMap["Shaft"               ] = GridPosition(x: -1, y: -1)
        positionMap["Gearbox"             ] = GridPosition(x: -1, y: -2)
        
        // Sectors
        positionMap["Starting Grounds"  ] = GridPosition(x: 2, y: -1)
        positionMap["Ferrum Ridge"      ] = GridPosition(x: 2, y: -2)
        positionMap["Crevice"           ] = GridPosition(x: 2, y: -3)
        positionMap["Nightfall Depths"  ] = GridPosition(x: 2, y: -4)
        positionMap["Aluminum Mountains"] = GridPosition(x: 2, y: -5)
        positionMap["Dark Valley"       ] = GridPosition(x: 2, y: -6)
        positionMap["Ruins"             ] = GridPosition(x: 2, y: -7)
        
        // Apply positions to nodes
        for index in nodes.indices {
            if let position = positionMap[nodes[index].databaseItemName] {
                nodes[index].gridPosition = position
            }
        }
    }
    
    private func resolveOverlaps() {
        var occupied = Set<GridPosition>()
        for index in nodes.indices {
            var pos = nodes[index].gridPosition
            while occupied.contains(pos) {
                pos.y += 1
            }
            nodes[index].gridPosition = pos
            occupied.insert(pos)
        }
    }
    
    // Unlock nodes whose dependencies are fully researched
    func unlockNodes() {
        for i in nodes.indices {
            let node = nodes[i]
            if !node.isUnlocked && effectiveDependencies(for: node).allSatisfy({ dep in isDependencyMet(dep) }) {
                nodes[i].isUnlocked = true
            }
        }
        
        autoResearchResources()
    }
    
    
    
    
    // MARK: - Sector dependency helpers
    func setSectorStatusResolver(_ resolver: @escaping (String) -> SectorStatus) {
        self.sectorStatusResolver = resolver
    }
    
    func setIsSectorNameResolver(_ resolver: @escaping (String) -> Bool) {
        self.isSectorNameResolver = resolver
    }
    
    private func isSectorName(_ name: String) -> Bool {
        return isSectorNameResolver?(name) ?? false
    }
    
    private func isSectorConditionMet(sectorName: String, condition: String) -> Bool {
        guard let resolver = sectorStatusResolver else { return false }
        let status = resolver(sectorName)
        switch condition.lowercased() {
        case "captured":
            return status == .completed
        case "landed":
            return status == .inProgress || status == .completed || status == .available
        default:
            return false
        }
    }
    
    // Combine explicit dependencies with implicit sector chain dependency:
    // If both this node and one of its visualConnections are sector names,
    // we require the connected sector to be captured.
    private func effectiveDependencies(for node: TechNode) -> [String] {
        var deps = node.dependencies
        if isSectorName(node.databaseItemName) {
            if let prev = node.visualConnections.first(where: { isSectorName($0) }) {
                let implied = "sector:\(prev):captured"
                if !deps.contains(implied) {
                    deps.append(implied)
                }
            }
        }
        return deps
    }
    
    private func isDependencyMet(_ dependency: String) -> Bool {
        let lower = dependency.lowercased()
        if lower.hasPrefix("sector:") {
            let parts = dependency.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            if parts.count == 3 {
                return isSectorConditionMet(sectorName: parts[1], condition: parts[2])
            } else {
                return false
            }
        } else {
            return nodes.contains(where: { $0.databaseItemName == dependency && $0.isResearched })
        }
    }
    
    func canResearch(_ node: TechNode) -> Bool {
        if isResourceNode(node) || isSectorNode(node) { return false }
        guard !node.isResearched else { return false }
        
        // Check if all dependencies are researched
        for dependency in effectiveDependencies(for: node) {
            if !isDependencyMet(dependency) {
                return false
            }
        }
        
        // Check if we have enough resources
        for cost in node.researchCosts {
            if let resource = resources.first(where: { $0.name == cost.resourceName }) {
                if resource.quantity < cost.amount {
                    return false
                }
            } else {
                return false
            }
        }
        
        return true
    }
    
    func researchNode(_ node: TechNode) {
        guard canResearch(node) else { return }
        
        // Deduct resources
        for cost in node.researchCosts {
            if let index = resources.firstIndex(where: { $0.name == cost.resourceName }) {
                resources[index].quantity -= cost.amount
            }
        }
        
        // Mark as researched
        if let index = nodes.firstIndex(where: { $0.id == node.id }) {
            nodes[index].isResearched = true
            nodes[index].isUnlocked = true
        }
        
        // Update unlocked status for other nodes
        unlockNodes()
    }
    
    func getNodeState(_ node: TechNode) -> NodeState {
        if node.isResearched {
            return .researched
        } else if canResearch(node) {
            return .available
        } else {
            return .locked
        }
    }
    
    func zoomIn() {
        withAnimation(.easeInOut(duration: 0.2)) {
            zoomScale = min(maxZoom, zoomScale * 1.3)
        }
    }
    
    func zoomOut() {
        withAnimation(.easeInOut(duration: 0.2)) {
            zoomScale = max(minZoom, zoomScale / 1.3)
        }
    }
    
    func resetZoom() {
        withAnimation(.easeInOut(duration: 0.3)) {
            zoomScale = 0.6 // Reset to overview level
        }
    }
}

enum NodeState {
    case locked, available, researched
}

// MARK: - Views

struct MindustryTechTreeView: View {
    @ObservedObject var viewModel: TechTreeViewModel
    @Binding var isShowingTechTree: Bool
    
    @State private var magnification: CGFloat = 1.0
    @State private var dragOffset: CGSize = CGSize(width: 0, height: 0)
    @State private var lastDragTranslation: CGSize = CGSize(width: 0, height: 0)
    @State private var isSidebarExpanded: Bool = true
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Black background
                Color.black.ignoresSafeArea()
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                dragOffset = CGSize(
                                    width: lastDragTranslation.width + value.translation.width,
                                    height: lastDragTranslation.height + value.translation.height
                                )
                            }
                            .onEnded { _ in
                                lastDragTranslation = dragOffset
                            }
                    )
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                let newScale = viewModel.zoomScale * value / magnification
                                viewModel.zoomScale = max(viewModel.minZoom,
                                                          min(viewModel.maxZoom, newScale))
                                magnification = value
                            }
                            .onEnded { _ in
                                magnification = 1.0
                            }
                    )
                
                // Main content area - tech tree with sidebar
                HStack(spacing: 0) {
                    // Left sidebar
                    ResourceSidebar(resources: viewModel.resources, isExpanded: $isSidebarExpanded)
                        .frame(width: 280)
                        .frame(height: isSidebarExpanded ? 600 : 20)
                        .background(Color.gray.opacity(0.9))
                        .clipped()
                        .offset(x: 60, y: isSidebarExpanded ? -700 : -975)
                        .animation(.easeInOut(duration: 0.2), value: isSidebarExpanded)
                        .zIndex(100)
                    
                    // Main tech tree area
                    ZStack {
                        ZStack {
                            // Grid background
                            GridBackground(gridSize: viewModel.gridSize)
                            
                            // Connection lines
                            ForEach(viewModel.nodes) { node in
                                ForEach(node.visualConnections, id: \.self) { connectionTarget in
                                    if let targetNode = viewModel.nodes.first(where: { $0.databaseItemName == connectionTarget }) {
                                        GridBasedConnectionLine(
                                            from: targetNode.gridPosition,
                                            to: node.gridPosition,
                                            gridSize: viewModel.gridSize,
                                            isActive: targetNode.isResearched,
                                            allNodes: viewModel.nodes,
                                            useSmartRouting: viewModel.useSmartRouting
                                        )
                                    }
                                }
                            }
                            
                            // Tech nodes
                            ForEach(viewModel.nodes) { node in
                                MindustryTechNode(
                                    node: node,
                                    state: viewModel.getNodeState(node)
                                ) {
                                    viewModel.selectedNode = node
                                } onResearch: {
                                    viewModel.researchNode(node)
                                }
                                .position(node.gridPosition.toCGPoint(gridSize: viewModel.gridSize))
                            }
                        }
                        .frame(width: 3200, height: 2400)
                        .scaleEffect(viewModel.zoomScale)
                    }
                    .scrollIndicators(.hidden)
                    .offset(dragOffset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                
                // Back button - positioned absolutely
                VStack {
                    HStack {
                        Spacer()
                        
                        Button {
                            isShowingTechTree = false
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.left")
                                    .foregroundColor(.white)
                                    .font(.system(size: 14))
                                
                                Text("Back")
                                    .foregroundColor(.white)
                                    .font(.system(size: 14, weight: .medium))
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )
                        }
//                        .padding(.top, 60)
//                        .padding(.trailing, 40)
                        .position(x: 900, y: 1100)
                    }
                    
                    Spacer()
                }
                
                // Node detail overlay - positioned in the center
                if let selected = viewModel.selectedNode {
                    NodeDetailOverlay(
                        node: selected,
                        canResearch: viewModel.canResearch(selected),
                        resources: viewModel.resources
                    ) {
                        viewModel.researchNode(selected)
                        viewModel.selectedNode = nil
                    } onClose: {
                        viewModel.selectedNode = nil
                    }
                    .offset(x: -700, y: -600)
                }
            }
        }
        .ignoresSafeArea(.all, edges: .all)
    }
}

struct GridBackground: View {
    let gridSize: CGFloat
    
    var body: some View {
        Path { path in
            // Vertical lines
            for i in 0...40 {
                let x = CGFloat(i) * gridSize
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: 2400))
            }
            
            // Horizontal lines
            for i in 0...30 {
                let y = CGFloat(i) * gridSize
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: 3200, y: y))
            }
        }
        .stroke(Color.gray.opacity(0.1), lineWidth: 0.5)
    }
}

struct GridBasedConnectionLine: View {
    let from: GridPosition
    let to: GridPosition
    let gridSize: CGFloat
    let isActive: Bool
    let allNodes: [TechNode] // Add this to check for obstacles
    let useSmartRouting: Bool // Toggle for pathfinding
    
    var body: some View {
        Path { path in
            let startPoint = from.toCGPoint(gridSize: gridSize)
            let endPoint = to.toCGPoint(gridSize: gridSize)
            
            if useSmartRouting {
                // Get optimal path avoiding other nodes
                let waypoints = calculatePath(from: from, to: to, avoiding: allNodes)
                
                if waypoints.isEmpty {
                    // Fallback to simple L-shaped path
                    createSimplePath(path: &path, start: startPoint, end: endPoint)
                } else {
                    // Draw path through waypoints
                    path.move(to: startPoint)
                    for waypoint in waypoints {
                        path.addLine(to: waypoint.toCGPoint(gridSize: gridSize))
                    }
                    path.addLine(to: endPoint)
                }
            } else {
                // Use simple L-shaped routing
                createSimplePath(path: &path, start: startPoint, end: endPoint)
            }
        }
        .stroke(
            isActive ? Color.white.opacity(0.6) : Color.gray.opacity(0.2),
            style: StrokeStyle(lineWidth: 2, lineCap: .round)
        )
    }
    
    private func createSimplePath(path: inout Path, start: CGPoint, end: CGPoint) {
        path.move(to: start)
        
        if from.x != to.x && from.y != to.y {
            let intermediatePoint: CGPoint
            
            if to.y < from.y { // Going up
                intermediatePoint = CGPoint(x: start.x, y: end.y)
            } else { // Going down
                intermediatePoint = CGPoint(x: end.x, y: start.y)
            }
            
            path.addLine(to: intermediatePoint)
            path.addLine(to: end)
        } else {
            path.addLine(to: end)
        }
    }
    
    private func calculatePath(from start: GridPosition, to end: GridPosition, avoiding obstacles: [TechNode]) -> [GridPosition] {
        // Convert obstacles to grid positions for easier checking
        let obstaclePositions = Set(obstacles.map { $0.gridPosition })
        
        // Try simple L-shaped path first
        let simplePath = getSimpleLPath(from: start, to: end)
        if !pathIntersectsObstacles(path: simplePath, obstacles: obstaclePositions, excluding: [start, end]) {
            return simplePath
        }
        
        // Try alternative L-shaped path
        let alternatePath = getAlternateLPath(from: start, to: end)
        if !pathIntersectsObstacles(path: alternatePath, obstacles: obstaclePositions, excluding: [start, end]) {
            return alternatePath
        }
        
        // Try routing around obstacles
        return findPathAroundObstacles(from: start, to: end, obstacles: obstaclePositions)
    }
    
    private func getSimpleLPath(from start: GridPosition, to end: GridPosition) -> [GridPosition] {
        if start.x == end.x || start.y == end.y {
            return [] // Direct line, no waypoints needed
        }
        
        // Standard L-path: horizontal first, then vertical
        return [GridPosition(x: end.x, y: start.y)]
    }
    
    private func getAlternateLPath(from start: GridPosition, to end: GridPosition) -> [GridPosition] {
        if start.x == end.x || start.y == end.y {
            return [] // Direct line, no waypoints needed
        }
        
        // Alternate L-path: vertical first, then horizontal
        return [GridPosition(x: start.x, y: end.y)]
    }
    
    private func pathIntersectsObstacles(path: [GridPosition], obstacles: Set<GridPosition>, excluding: [GridPosition]) -> Bool {
        let excludeSet = Set(excluding)
        
        for position in path {
            if obstacles.contains(position) && !excludeSet.contains(position) {
                return true
            }
        }
        return false
    }
    
    private func findPathAroundObstacles(from start: GridPosition, to end: GridPosition, obstacles: Set<GridPosition>) -> [GridPosition] {
        // Simple A* pathfinding on grid
        var openSet = [start]
        var cameFrom: [GridPosition: GridPosition] = [:]
        var gScore: [GridPosition: Int] = [start: 0]
        var fScore: [GridPosition: Int] = [start: manhattanDistance(start, end)]
        
        while !openSet.isEmpty {
            // Find node with lowest fScore
            let current = openSet.min { pos1, pos2 in
                (fScore[pos1] ?? Int.max) < (fScore[pos2] ?? Int.max)
            }!
            
            if current == end {
                // Reconstruct path
                var path: [GridPosition] = []
                var node = current
                while let parent = cameFrom[node] {
                    path.insert(node, at: 0)
                    node = parent
                }
                // Remove start and end from path (they're already known)
                return Array(path.dropFirst().dropLast())
            }
            
            openSet.removeAll { $0 == current }
            
            // Check neighbors (4-directional movement)
            let neighbors = [
                GridPosition(x: current.x + 1, y: current.y),
                GridPosition(x: current.x - 1, y: current.y),
                GridPosition(x: current.x, y: current.y + 1),
                GridPosition(x: current.x, y: current.y - 1)
            ]
            
            for neighbor in neighbors {
                // Skip if out of reasonable bounds or is obstacle
                if neighbor.x < 0 || neighbor.x > 50 || neighbor.y < 0 || neighbor.y > 30 {
                    continue
                }
                if obstacles.contains(neighbor) && neighbor != end {
                    continue
                }
                
                let tentativeGScore = (gScore[current] ?? Int.max) + 1
                
                if tentativeGScore < (gScore[neighbor] ?? Int.max) {
                    cameFrom[neighbor] = current
                    gScore[neighbor] = tentativeGScore
                    fScore[neighbor] = tentativeGScore + manhattanDistance(neighbor, end)
                    
                    if !openSet.contains(neighbor) {
                        openSet.append(neighbor)
                    }
                }
            }
            
            // Prevent infinite loops
            if openSet.count > 100 {
                break
            }
        }
        
        // No path found, fall back to simple routing
        return getSimpleAvoidancePath(from: start, to: end)
    }
    
    private func manhattanDistance(_ a: GridPosition, _ b: GridPosition) -> Int {
        return abs(a.x - b.x) + abs(a.y - b.y)
    }
    
    private func getSimpleAvoidancePath(from start: GridPosition, to end: GridPosition) -> [GridPosition] {
        // Simple obstacle avoidance: try going around by adding intermediate points
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        
        // Try going around the obstacle field
        if abs(deltaX) > abs(deltaY) {
            // Primarily horizontal movement - try going above/below obstacle area
            let midX = start.x + deltaX / 2
            
            // Try going above
            return [
                GridPosition(x: midX, y: start.y - 2),
                GridPosition(x: midX, y: end.y - 2),
                GridPosition(x: end.x, y: end.y - 2)
            ]
        } else {
            // Primarily vertical movement - try going left/right of obstacle area
            let midY = start.y + deltaY / 2
            
            // Try going left
            return [
                GridPosition(x: start.x - 2, y: midY),
                GridPosition(x: end.x - 2, y: midY),
                GridPosition(x: end.x - 2, y: end.y)
            ]
        }
    }
}

struct ZoomControls: View {
    @ObservedObject var viewModel: TechTreeViewModel
    
    var body: some View {
        VStack(spacing: 4) {
            Button(action: viewModel.zoomIn) {
                Image(systemName: "plus")
                    .foregroundColor(.white)
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 32, height: 32)
                    .background(Color.black.opacity(0.8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
            }
            
            Button(action: viewModel.resetZoom) {
                Text("\(Int(viewModel.zoomScale * 100))%")
                    .foregroundColor(.white)
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 32, height: 24)
                    .background(Color.black.opacity(0.8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
            }
            
            Button(action: viewModel.zoomOut) {
                Image(systemName: "minus")
                    .foregroundColor(.white)
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 32, height: 32)
                    .background(Color.black.opacity(0.8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
            }
        }
    }
}

struct ResourceSidebar: View {
    let resources: [ResourceItem]
    @Binding var isExpanded: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header - now clickable
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack {
                    Image(systemName: "chevron.down")
                        .foregroundColor(.white)
                        .font(.caption)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .animation(.easeInOut(duration: 0.2), value: isExpanded)
                    
                    Text("Planet Items")
                        .foregroundColor(.orange)
                        .font(.system(size: 16, weight: .medium))
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.9))
                .contentShape(Rectangle()) // Makes entire header area clickable
            }
            .buttonStyle(PlainButtonStyle())
            
            // Resource list - conditionally shown
            if isExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(resources) { resource in
                            HStack(spacing: 8) {
                                Text("\(resource.quantity)")
                                    .foregroundColor(.white)
                                    .font(.system(size: 14, weight: .medium))
                                    .frame(width: 40, alignment: .trailing)
                                
                                // Use SF Symbol for missing icons
                                if resource.icon == "●" {
                                    Image(systemName: "circle.fill")
                                        .resizable()
                                        .frame(width: 20, height: 20)
                                        .foregroundColor(.gray)
                                } else {
                                    Image(resource.icon)
                                        .resizable()
                                        .frame(width: 20, height: 20)
                                }
                                
                                Text(resource.name)
                                    .foregroundColor(.white)
                                    .font(.system(size: 14))
                                
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.top, 8)
                }
                .background(Color.black.opacity(0.8))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            
            Spacer()
        }
        .background(Color.black.opacity(0.9))
        .overlay(
            Rectangle()
                .frame(width: 1)
                .foregroundColor(.gray.opacity(0.3)),
            alignment: .trailing
        )
    }
}

struct TopNavigationBar: View {
    var body: some View {
        HStack {
            
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .foregroundColor(.white)
                    .font(.system(size: 16))
                
                Text("Erekir")
                    .foregroundColor(.white)
                    .font(.system(size: 16, weight: .medium))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.8))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )
            
            Spacer()
            
            HStack(spacing: 16) {
                Button("Sectors") {}
                    .foregroundColor(.gray)
                    .font(.system(size: 14))
                
                Text("Tech Tree")
                    .foregroundColor(.white)
                    .font(.system(size: 14, weight: .medium))
            }
            .padding(.trailing, 20)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.top, 12)
        .background(Color.clear)
    }
}

struct BottomNavigationBar: View {
    @Binding var isShowingTechTree: Bool
    
    var body: some View {
        HStack {
            Button {
                isShowingTechTree = false
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left")
                        .foregroundColor(.white)
                        .font(.system(size: 14))
                    
                    Text("Back")
                        .foregroundColor(.white)
                        .font(.system(size: 14, weight: .medium))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.8))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
            }
            
            Spacer()
            
            Button(action: {}) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .foregroundColor(.white)
                        .font(.system(size: 14))
                    
                    Text("Core Database")
                        .foregroundColor(.white)
                        .font(.system(size: 14, weight: .medium))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.8))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .background(Color.clear)
    }
}

struct MindustryTechNode: View {
    let node: TechNode
    let state: NodeState
    let onTap: () -> Void
    let onResearch: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            ZStack {
                // Dark background box
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.black)
                    .frame(width: 40, height: 40)
                
                // Your icon
                if state != .locked {
                    Image(node.iconName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                        .opacity(state == .locked ? 0.4 : 1.0)
                        .colorMultiply(.white)
                } else {
                    Image(systemName: "lock.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                        .opacity(state == .locked ? 0.4 : 1.0)
                        .colorMultiply(.white)
                        .foregroundColor(.gray)
                }
                
            }
            // Gold outline for researched/available, red for locked
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(
                        state == .locked ? Color.red.opacity(0.4) : state == .researched ? Color.yellow : Color.gray,
                        lineWidth: state == .researched ? 3 : 2
                    )
            )
        }
        .scaleEffect(state == .available ? 1.05 : 1.0)
        .animation(.easeInOut, value: state)
    }
}

struct NodeDetailOverlay: View {
    let node: TechNode
    let canResearch: Bool
    let resources: [ResourceItem]
    let onResearch: () -> Void
    let onClose: () -> Void
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture {
                    onClose()
                }
            
            VStack(alignment: .leading, spacing: 16) {
                // Header with icon, name, and close button
                HStack {
                    // Node icon
                    Image(node.iconName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 32, height: 32)
                        .foregroundColor(.white)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.name)
                            .foregroundColor(.white)
                            .font(.system(size: 18, weight: .bold))
                        
                        // Status indicator
                        Text(node.isResearched ? "Researched" : canResearch ? "Available" : "Locked")
                            .foregroundColor(node.isResearched ? .green : canResearch ? .yellow : .red)
                            .font(.system(size: 12, weight: .medium))
                    }
                    
                    Spacer()
                    
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .foregroundColor(.gray)
                            .font(.system(size: 16, weight: .medium))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                
                // Description section (only show if not empty)
                if !node.description.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Description")
                            .foregroundColor(.gray)
                            .font(.system(size: 14, weight: .medium))
                        
                        Text(node.description)
                            .foregroundColor(.white)
                            .font(.system(size: 14))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                
                // Research costs section (if any)
                if !node.researchCosts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Research Cost")
                            .foregroundColor(.gray)
                            .font(.system(size: 14, weight: .medium))
                        
                        ForEach(node.researchCosts) { cost in
                            HStack(spacing: 8) {
                                if let resource = resources.first(where: { $0.name == cost.resourceName }) {
                                    if resource.icon == "●" {
                                        Image(systemName: "circle.fill")
                                            .resizable()
                                            .frame(width: 16, height: 16)
                                            .foregroundColor(.gray)
                                    } else {
                                        Image(resource.icon)
                                            .resizable()
                                            .frame(width: 16, height: 16)
                                    }
                                    
                                    Text("\(cost.amount)")
                                        .foregroundColor(.white)
                                        .font(.system(size: 14, weight: .medium))
                                    
                                    Text(cost.resourceName)
                                        .foregroundColor(.white)
                                        .font(.system(size: 14))
                                    
                                    Spacer()
                                    
                                    Text("(\(resource.quantity))")
                                        .foregroundColor(resource.quantity >= cost.amount ? .green : .red)
                                        .font(.system(size: 12))
                                } else {
                                    Text("\(cost.amount) \(cost.resourceName)")
                                        .foregroundColor(.white)
                                        .font(.system(size: 14))
                                    
                                    Spacer()
                                    
                                    Text("(Resource not found)")
                                        .foregroundColor(.red)
                                        .font(.system(size: 12))
                                }
                            }
                        }
                    }
                }
                
                // Action buttons
                HStack {
                    if canResearch {
                        Button(action: onResearch) {
                            HStack(spacing: 6) {
                                Text("Research")
                                    .foregroundColor(.white)
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.blue)
                            .cornerRadius(4)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
            .background(Color.black.opacity(0.95))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.4), lineWidth: 1)
            )
            .cornerRadius(8)
            .frame(maxWidth: 400)
            .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
        }
    }
}
