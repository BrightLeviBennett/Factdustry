//
//  ResearchManeger.swift
//  Factdustry
//
//  Created by Bright on 8/10/25.
//

import SwiftUI
import Combine

class ResearchManager: ObservableObject {
    @Published var requireResearchForPlacement: Bool = true // Toggle for research requirement
    
    // FIXED: Use a single shared instance that persists
    static let shared = ResearchManager()
    
    // The tech tree view model that persists across view openings/closings
    let techTreeViewModel: TechTreeViewModel
    
    // Mapping between block icon names and tech node names
    private let blockToTechMapping: [String: String] = [
        // Core buildings
        "core-shard": "Core: Shard",
        "core-fragment": "Core: Fragment",
        "core-remnant": "Core: Remnant",
        "core-bastion": "Core: Bastion",
        "core-crucible": "Core: Crucible",
        "core-interplanetary": "Core: Interplanetary",
        "core-aegis": "Core: Aegis",
        "core-singularity": "Core: Singularity",
        
        // Production/Drills
        "mechanical-drill": "Mechanical Drill",
        "plasma-bore": "Plasma Bore",
        "advanced-plasma-bore": "Advanced Plasma Bore",
        "mineral-extractor": "Mineral Extractor",
        "petroleum-drill": "Petroleum Drill",
        
        // Production buildings
        "steel-furnace": "Steel Furnace",
        "silicon-mixer": "Silicon Mixer",
        "graphite-electrolyzer": "Graphite Electrolyzer",
        "circuit-printer": "Circuit Printer",
        "carbon-dioxide-concentrator": "Carbon-Dioxide Concentrator",
        "petroleum-refinery": "Petroleum Refinery",
        
        // Transportation
        "conveyor-belt": "Conveyor Belt",
        "belt-junction": "Belt Junction",
        "belt-router": "Belt Router",
        "belt-bridge": "Belt Bridge",
        "belt-sorter": "Belt Sorter",
        "inverted-belt-sorter": "Inverted Belt Sorter",
        "underflow-belt": "Underflow Belt",
        "overflow-belt": "Overflow Belt",
        "cargo-mass-driver": "Cargo Mass Driver",
        
        // Ducts
        "duct": "Duct",
        "duct-junction": "Duct Junction",
        "duct-router": "Duct Router",
        "duct-bridge": "Duct Bridge",
        "duct-sorter": "Duct Sorter",
        "overflow-duct": "Overflow Duct",
        "underflow-duct": "Underflow Duct",
        "inverted-duct-sorter": "Inverted Duct Sorter",
        
        // Rails and loaders
        "payload-conveyor": "Payload Conveyor",
        "payload-router": "Payload Router",
        "payload-junction": "Payload Junction",
        "payload-bridge": "Payload Bridge",
        "payload-rail": "Payload Rail",
        "freight-conveyer": "Freight Conveyer",
        "freight-router": "Freight Router",
        "freight-junction": "Freight Junction",
        "freight-bridge": "Freight Bridge",
        "rail-router": "Rail Router",
        "rail-junction": "Rail Junction",
        "rail-bridge": "Rail Bridge",
        "freight-rail": "Freight Rail",
        "freight-rail-router": "Freight Rail Router",
        "freight-rail-junction": "Freight Rail Junction",
        "freight-rail-bridge": "Freight Rail Bridge",
        "payload-loader": "Payload Loader",
        "freight-loader": "Freight Loader",
        "payload-unloader": "Payload Unloader",
        "freight-unloader": "Freight Unloader",
        "payload-mass-driver": "Payload Mass Driver",
        "freight-mass-driver": "Freight Mass Driver",
        
        // Fluids
        "fluid-conduit": "Fluid Conduit",
        "conduit-router": "Conduit Router",
        "conduit-bridge": "Conduit Bridge",
        "conduit-sorter": "Conduit Sorter",
        "underflow-conduit": "Underflow Conduit",
        "overflow-conduit": "Overflow Conduit",
        "sealed-cargo-mass-driver": "Sealed Cargo Mass Driver",
        "conduit-junction": "Conduit Junction",
        "fluid-pump": "Fluid Pump",
        "vent-condenser": "Vent Condenser",
        "geyser-condenser": "Geyser Condenser",
        
        // Power
        "steam-engine": "Steam Engine",
        "combustion-engine": "Combustion Engine",
        "combustion-generator": "Combustion Generator",
        "vent-turbine": "Vent Turbine",
        "beam-node": "Beam Node",
        "beam-tower": "Beam Tower",
        "shaft": "Shaft",
        "gearbox": "Gearbox",
        
        // Weapons/Turrets
        "single-barrel": "Single Barrel",
        "diffuse": "Diffuse",
        "double-barrel": "Double Barrel",
        "destroy": "Destroy",
        "emp-diffuse": "EMP Diffuse",
        "disarm": "Disarm",
        "annihilate": "Annihilate",
        "homing-diffuse": "Homing Diffuse",
        "aegis-arc": "Aegis Arc",
        "gauss-launcher": "Gauss Launcher",
        "eclipse": "Eclipse",
        "missile-launcher": "Missile Launcher",
        "quad-barrel": "Quad Barrel",
        "octo-barrel": "Octo Barrel",
        "duodec": "Duodec",
        "quaddec": "Quaddec",
        "shardstorm": "Shardstorm",
        "thunderburst": "Thunderburst"
    ]
    
    

    // Optional default sector-name heuristic if no external resolver is bound.
    private func defaultIsSectorName(_ s: String) -> Bool {
        let n = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return n.hasPrefix("sector ") || n.hasPrefix("sector:")
    }
private init() {
        self.techTreeViewModel = TechTreeViewModel()
        
        // FIXED: Set up observation to trigger UI updates when research changes
        setupResearchObservation()
        // Provide a fallback sector name resolver unless the app binds a custom one later
        techTreeViewModel.setIsSectorNameResolver(defaultIsSectorName)
    }

    /// Notify the research system that a resource has entered (or changed within) the core.
    /// This updates the tech tree's resource list; the view model will auto-research as needed.
    func notifyResourceAddedToCore(name: String, newTotalQuantity: Int) {
        if let idx = techTreeViewModel.resources.firstIndex(where: { $0.name == name }) {
            techTreeViewModel.resources[idx].quantity = newTotalQuantity
        } else {
            techTreeViewModel.resources.append(ResourceItem(name: name, icon: name, quantity: newTotalQuantity))
        }
        // No manual trigger needed; TechTreeViewModel observes $resources.
    }

    
    // FIXED: Set up proper observation of tech tree changes
    private func setupResearchObservation() {
        // Listen for changes in the tech tree and trigger our own updates
        techTreeViewModel.$nodes
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.objectWillChange.send()
                }
            }
            .store(in: &cancellables)
    }
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Database Integration Methods
    
    // Check if any item is researched (used by database)
    func isResearched(_ itemName: String) -> Bool {
        return techTreeViewModel.nodes.first { $0.databaseItemName == itemName }?.isResearched ?? false
    }
    
    // Get all researched items for database filtering
    var researchedItems: Set<String> {
        return Set(techTreeViewModel.nodes.filter { $0.isResearched }.map { $0.databaseItemName })
    }
    
    // Get resources from tech tree
    var resources: [ResourceItem] {
        return techTreeViewModel.resources
    }
    
    // MARK: - Block Research Methods (Existing functionality)
    
    // Check if a block is researched
    func isBlockResearched(_ blockIconName: String) -> Bool {
        // If research requirement is disabled, all blocks are "researched"
        guard requireResearchForPlacement else { return true }
        
        // Get the corresponding tech node name
        guard let techNodeName = blockToTechMapping[blockIconName] else {
            return false // If no mapping found, block is not researched
        }
        
        // Check if the tech node is researched
        return techTreeViewModel.nodes.first { $0.databaseItemName == techNodeName }?.isResearched ?? false
    }
    
    // Get research status info for UI feedback
    func getResearchInfo(for blockIconName: String) -> (isResearched: Bool, techNodeName: String?, canResearch: Bool) {
        guard let techNodeName = blockToTechMapping[blockIconName] else {
            return (false, nil, false)
        }
        
        guard let techNode = techTreeViewModel.nodes.first(where: { $0.databaseItemName == techNodeName }) else {
            return (false, techNodeName, false)
        }
        
        let isResearched = techNode.isResearched
        let canResearch = techTreeViewModel.canResearch(techNode)
        
        return (isResearched, techNodeName, canResearch)
    }
    
    // Toggle research requirement
    func toggleResearchRequirement() {
        requireResearchForPlacement.toggle()
    }
    
    // MARK: - Sector Research Methods
    
    // Check if a sector is unlocked based on research
    func isSectorUnlocked(_ sectorName: String) -> Bool {
        // Find the tech node for this sector
        guard let sectorNode = techTreeViewModel.nodes.first(where: { $0.databaseItemName == sectorName }) else {
            // If sector not found in tech tree, default to available
            return true
        }
        
        return sectorNode.isResearched
    }
    
    // Get sector status based on research state
    func getSectorStatus(_ sectorName: String) -> SectorStatus {
        guard let sectorNode = techTreeViewModel.nodes.first(where: { $0.databaseItemName == sectorName }) else {
            // If sector not found in tech tree, default to available
            return .available
        }
        
        if sectorNode.isResearched {
            return .available
        } else {
            return .locked
        }
    }
    
    // Check if sector can be unlocked (dependencies met)
    func canUnlockSector(_ sectorName: String) -> Bool {
        guard let sectorNode = techTreeViewModel.nodes.first(where: { $0.databaseItemName == sectorName }) else {
            return true
        }
        
        // Check if all dependencies are researched
        for dependency in sectorNode.dependencies {
            if !techTreeViewModel.nodes.contains(where: { $0.databaseItemName == dependency && $0.isResearched }) {
                return false
            }
        }
        
        return true
    }


    // MARK: - Sector Status Binding for Tech Dependencies
    /// Allows wiring a sector status provider so tech node dependencies can depend on sector states.
    /// Usage: ResearchManager.shared.bindSectorStatusResolver { sectorName in
    ///    // return current SectorStatus (.locked, .available, .inProgress, .completed) for `sectorName`
    /// }
    

    // MARK: - Sector resolver bindings
    /// Bind a resolver that tells the tech tree whether a string corresponds to a sector name.
    func bindIsSectorNameResolver(_ resolver: @escaping (String) -> Bool) {
        techTreeViewModel.setIsSectorNameResolver(resolver)
        objectWillChange.send()
    }
    
    /// Bind the status resolver (existing) and force a refresh of unlocks.
    func bindSectorStatusResolver(_ resolver: @escaping (String) -> SectorStatus) {
        techTreeViewModel.setSectorStatusResolver(resolver)
        techTreeViewModel.unlockNodes()
        objectWillChange.send()
    }
    
    /// Call this whenever a sector's status changes to re-evaluate tech unlocks.
    func notifySectorStatusChanged() {
        techTreeViewModel.unlockNodes()
        objectWillChange.send()
    }
}
