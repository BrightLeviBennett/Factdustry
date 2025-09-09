//
//  Tarkon.swift
//  Factdustry
//
//  Created by Bright on 7/19/25.
//

import SwiftUI

// MARK: - Planet and Database Item Definitions
struct Planet: Identifiable {
    let id = UUID()
    
    var name: String
    var blocks:        [CDBlock]
    var units:         [CDUnit]
    var fluids:        [CDFluid]
    var gases:         [CDGas]
    var sectors:       [CDSector]
    var statusEffects: [CDStatusEfect]
    var resources:     [CDResource]
}

// MARK: - Database Item Protocol
protocol DatabaseItem {
    var id: UUID { get }
    var name: String { get }
    var description: String { get }
    var icon: String { get }
    var scaleX: Double { get }
    var scaleY: Double { get }
    var offsetX: Double { get }
    var offsetY: Double { get }
}

extension CDBlock: DatabaseItem {}
extension CDUnit: DatabaseItem {}
extension CDFluid: DatabaseItem {}
extension CDGas: DatabaseItem {}
extension CDResource: DatabaseItem {}
extension CDStatusEfect: DatabaseItem {}
extension CDSector: DatabaseItem {}

let Tarkon = Planet(name: "Tarkon",
    blocks: [
        // === CORE BLOCKS ===
        CDBlock(name: "Core: Shard", description: "Basic core structure. Stores items and provides initial technology access.", icon: "core:-shard", size: 3, buidTime: 0, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Core: Fragment", description: "Improved core with increased storage capacity.", icon: "core-fragment", size: 4, buidTime: 300, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Core: Remnant", description: "Advanced core with enhanced processing capabilities.", icon: "core-remnant", size: 5, buidTime: 600, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Core: Bastion", description: "Heavily fortified core structure.", icon: "core-bastion", size: 6, buidTime: 1200, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Core: Crucible", description: "High-capacity manufacturing core.", icon: "core-crucible", size: 7, buidTime: 2400, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Core: Interplanetary", description: "Specialized core for interplanetary operations.", icon: "core-interplanetary", size: 7, buidTime: 3000, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Core: Aegis", description: "Ultimate defensive core structure.", icon: "core-aegis", size: 8, buidTime: 4800, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Core: Singularity", description: "The most advanced core technology available.", icon: "core-singularity", size: 9, buidTime: 7200, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        
        // === PRODUCTION BLOCKS ===
        CDBlock(name: "Silicon Mixer", description: "Produces silicon from raw materials.", icon: "silicon-mixer", size: 2, buidTime: 45, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [Process(time: 2.0, inputItems: [.graphite: 2], outputItems: [.silicon: 1])])),
        CDBlock(name: "Graphite Electrolyzer", description: "Processes graphite for advanced materials.", icon: "graphite-electrolyzer", size: 2, buidTime: 60, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [Process(time: 1.5, inputItems: [.coal: 2], outputItems: [.graphite: 1])])),
        CDBlock(name: "Steel Furnace", description: "Smelts iron into steel.", icon: "steel-furnace", size: 3, buidTime: 120, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [Process(time: 3.0, inputItems: [.iron: 2, .coal: 1], outputItems: [.steel: 1])])),
        CDBlock(name: "Circuit Printer", description: "Manufactures advanced circuits.", icon: "circuit-printer", size: 3, buidTime: 180, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [Process(time: 4.0, inputItems: [.silicon: 2, .copper: 3], outputItems: [.steel: 1])])),
        CDBlock(name: "Carbon-Dioxide Concentrator", description: "Concentrates carbon dioxide from atmosphere.", icon: "carbon-dioxide-concentrator", size: 2, buidTime: 90, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [Process(time: 2.5, inputPower: 100, outputItems: [.coal: 1])])),
        CDBlock(name: "Petroleum Refinery", description: "Refines petroleum into various fuel products.", icon: "petroleum-refinery", size: 4, buidTime: 300, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [Process(time: 5.0, inputItems: [.coal: 3], outputItems: [.steel: 2])])),
        
        // === DRILL BLOCKS ===
        CDBlock(name: "Mechanical Drill", description: "Basic drilling equipment for resource extraction.", icon: "mechanical-drill", size: 2, buidTime: 30, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [Process(time: 2.0, inputPower: 50, outputItems: [.copper: 1])])),
        CDBlock(name: "Plasma Bore", description: "Advanced drilling with plasma technology.", icon: "plasma-bore", size: 3, buidTime: 120, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [Process(time: 1.5, inputPower: 150, outputItems: [.iron: 1])])),
        CDBlock(name: "Advanced Plasma Bore", description: "High-efficiency plasma drilling system.", icon: "advanced-plasma-bore", size: 3, buidTime: 240, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [Process(time: 1.0, inputPower: 250, outputItems: [.steel: 1])])),
        CDBlock(name: "Mineral Extractor", description: "Specialized extractor for rare minerals.", icon: "mineral-extractor", size: 4, buidTime: 480, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [Process(time: 3.0, inputPower: 400, outputItems: [.rawAliuminum: 1])])),
        CDBlock(name: "Petroleum Drill", description: "Specialized drill for petroleum extraction.", icon: "petroleum-drill", size: 3, buidTime: 360, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [Process(time: 2.5, inputPower: 200, outputItems: [.coal: 2])])),
        
        // === POWER BLOCKS ===
        CDBlock(name: "Steam Engine", description: "Generates power from steam.", icon: "steam-engine", size: 2, buidTime: 60, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [Process(time: 1.0, inputFluids: [.water: 1], outputPower: 100)])),
        CDBlock(name: "Combustion Engine", description: "Burns fuel to generate power.", icon: "combustion-engine", size: 2, buidTime: 90, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [Process(time: 1.0, inputItems: [.coal: 1], outputPower: 200)])),
        CDBlock(name: "Combustion Generator", description: "Large-scale power generation from combustion.", icon: "combustion-generator", size: 3, buidTime: 180, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [Process(time: 1.0, inputItems: [.coal: 2], outputPower: 500)])),
        CDBlock(name: "Vent Turbine", description: "Harnesses geothermal energy from vents.", icon: "vent-turbine", size: 2, buidTime: 120, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [Process(time: 1.0, outputPower: 300)])),
        CDBlock(name: "Beam Node", description: "Transmits power via energy beams.", icon: "beam-node", size: 1, buidTime: 45, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Beam Tower", description: "Long-range power transmission tower.", icon: "beam-tower", size: 2, buidTime: 90, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Shaft", description: "Mechanical power transmission via rotating shaft.", icon: "shaft", size: 1, buidTime: 30, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Gearbox", description: "Converts and distributes mechanical power.", icon: "gearbox", size: 2, buidTime: 60, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        
        // === WEAPON BLOCKS ===
        CDBlock(name: "Single Barrel", description: "Basic single-barrel turret.", icon: "single-barrel", size: 1, buidTime: 30, SPs: CDBSP(targetsGround: true, targetsAir: true, TATs: [TAT(item: .copper, frags: [], damage: 25, inflictedEffect: nil)], range: 120, proceses: [])),
        CDBlock(name: "Diffuse", description: "Spreads damage over a wide area.", icon: "diffuse", size: 2, buidTime: 60, SPs: CDBSP(targetsGround: true, targetsAir: true, TATs: [TAT(item: .graphite, frags: [BFrag(damage: 15, inflictedEffect: nil)], damage: 35, inflictedEffect: nil)], range: 100, proceses: [])),
        CDBlock(name: "Double Barrel", description: "Dual-barrel turret for increased firepower.", icon: "double-barrel", size: 2, buidTime: 90, SPs: CDBSP(targetsGround: true, targetsAir: true, TATs: [TAT(item: .iron, frags: [], damage: 45, inflictedEffect: nil)], range: 140, proceses: [])),
        CDBlock(name: "Destroy", description: "High-damage destructive turret.", icon: "destroy-weapon", size: 2, buidTime: 120, SPs: CDBSP(targetsGround: true, targetsAir: false, TATs: [TAT(item: .steel, frags: [], damage: 80, inflictedEffect: nil)], range: 160, proceses: [])),
        CDBlock(name: "Disarm", description: "Disables enemy units temporarily.", icon: "disarm", size: 3, buidTime: 180, SPs: CDBSP(targetsGround: true, targetsAir: true, TATs: [TAT(item: .silicon, frags: [], damage: 20, inflictedEffect: CDStatusEfect(name: "Disarmed", description: "", icon: "disarm-effect"))], range: 180, proceses: [])),
        CDBlock(name: "Annihilate", description: "Devastating high-damage turret.", icon: "annihilate", size: 3, buidTime: 300, SPs: CDBSP(targetsGround: true, targetsAir: true, TATs: [TAT(item: .steel, frags: [], damage: 150, inflictedEffect: nil)], range: 200, proceses: [])),
        CDBlock(name: "EMP Diffuse", description: "Electromagnetic pulse area-effect weapon.", icon: "emp-diffuse", size: 2, buidTime: 150, SPs: CDBSP(targetsGround: true, targetsAir: true, TATs: [TAT(item: .silicon, frags: [BFrag(damage: 10, inflictedEffect: CDStatusEfect(name: "EMP", description: "", icon: "emp-effect"))], damage: 30, inflictedEffect: CDStatusEfect(name: "EMP", description: "", icon: "emp-effect"))], range: 120, proceses: [])),
        CDBlock(name: "Homing Diffuse", description: "Seeking projectiles with area damage.", icon: "homing-diffuse", size: 3, buidTime: 240, SPs: CDBSP(targetsGround: true, targetsAir: true, TATs: [TAT(item: .steel, frags: [BFrag(damage: 25, inflictedEffect: nil)], damage: 60, inflictedEffect: nil)], range: 220, proceses: [])),
        CDBlock(name: "Aegis Arc", description: "Advanced energy weapon system.", icon: "aegis-arc", size: 4, buidTime: 480, SPs: CDBSP(targetsGround: true, targetsAir: true, TATs: [TAT(item: .aliuminum, frags: [], damage: 200, inflictedEffect: CDStatusEfect(name: "Energy Burn", description: "", icon: "energy-burn"))], range: 280, proceses: [])),
        CDBlock(name: "Gauss Launcher", description: "Electromagnetic projectile launcher.", icon: "gauss-launcher", size: 3, buidTime: 360, SPs: CDBSP(targetsGround: true, targetsAir: true, TATs: [TAT(item: .steel, frags: [], damage: 120, inflictedEffect: nil)], range: 300, proceses: [])),
        CDBlock(name: "Eclipse", description: "Ultimate weapon system.", icon: "eclipse", size: 5, buidTime: 1200, SPs: CDBSP(targetsGround: true, targetsAir: true, TATs: [TAT(item: .aliuminum, frags: [], damage: 500, inflictedEffect: nil)], range: 400, proceses: [])),
        CDBlock(name: "Missile Launcher", description: "Long-range guided missile system.", icon: "missile-launcher", size: 3, buidTime: 420, SPs: CDBSP(targetsGround: true, targetsAir: true, TATs: [TAT(item: .steel, frags: [BFrag(damage: 80, inflictedEffect: nil)], damage: 180, inflictedEffect: nil)], range: 350, proceses: [])),
        CDBlock(name: "Quad Barrel", description: "Four-barrel rapid-fire turret.", icon: "quad-barrel", size: 3, buidTime: 180, SPs: CDBSP(targetsGround: true, targetsAir: true, TATs: [TAT(item: .iron, frags: [], damage: 80, inflictedEffect: nil)], range: 160, proceses: [])),
        CDBlock(name: "Octo Barrel", description: "Eight-barrel devastating turret.", icon: "octo-barrel", size: 4, buidTime: 360, SPs: CDBSP(targetsGround: true, targetsAir: true, TATs: [TAT(item: .steel, frags: [], damage: 160, inflictedEffect: nil)], range: 180, proceses: [])),
        CDBlock(name: "Duodec", description: "Twelve-barrel ultimate firepower.", icon: "duodec", size: 5, buidTime: 720, SPs: CDBSP(targetsGround: true, targetsAir: true, TATs: [TAT(item: .aliuminum, frags: [], damage: 320, inflictedEffect: nil)], range: 200, proceses: [])),
        CDBlock(name: "Quaddec", description: "Advanced multi-barrel system.", icon: "quaddec", size: 6, buidTime: 1440, SPs: CDBSP(targetsGround: true, targetsAir: true, TATs: [TAT(item: .aliuminum, frags: [], damage: 640, inflictedEffect: nil)], range: 220, proceses: [])),
        CDBlock(name: "Shardstorm", description: "Projectile storm weapon.", icon: "shardstorm", size: 3, buidTime: 300, SPs: CDBSP(targetsGround: true, targetsAir: true, TATs: [TAT(item: .graphite, frags: [BFrag(damage: 20, inflictedEffect: nil), BFrag(damage: 20, inflictedEffect: nil), BFrag(damage: 20, inflictedEffect: nil)], damage: 90, inflictedEffect: nil)], range: 190, proceses: [])),
        CDBlock(name: "Thunderburst", description: "Explosive thunder weapon.", icon: "thunderburst", size: 4, buidTime: 600, SPs: CDBSP(targetsGround: true, targetsAir: true, TATs: [TAT(item: .steel, frags: [BFrag(damage: 40, inflictedEffect: nil), BFrag(damage: 40, inflictedEffect: nil)], damage: 200, inflictedEffect: CDStatusEfect(name: "Stunned", description: "", icon: "stun-effect"))], range: 220, proceses: [])),
        
        // === TRANSPORTATION BLOCKS ===
        CDBlock(name: "Conveyor Belt", description: "Transports items across the factory.", icon: "conveyor-belt", size: 1, buidTime: 5, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Belt Junction", description: "Connects multiple conveyor belts.", icon: "belt-junction", size: 1, buidTime: 10, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Belt Router", description: "Routes items to different paths.", icon: "belt-router", size: 1, buidTime: 15, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Belt Bridge", description: "Allows belts to cross over each other.", icon: "belt-bridge", size: 1, buidTime: 20, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Belt Sorter", description: "Sorts items by type.", icon: "belt-sorter", size: 1, buidTime: 25, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Inverted Belt Sorter", description: "Reverse sorting mechanism.", icon: "inverted-belt-sorter", size: 1, buidTime: 30, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Overflow Belt", description: "Handles overflow from main belt.", icon: "overflow-belt", size: 1, buidTime: 35, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Underflow Belt", description: "Secondary belt for underflow.", icon: "underflow-belt", size: 1, buidTime: 35, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Cargo Mass Driver", description: "Long-range item transportation.", icon: "cargo-mass-driver", size: 3, buidTime: 180, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        
        // === PAYLOAD TRANSPORTATION ===
        CDBlock(name: "Payload Conveyor", description: "Transports large payloads.", icon: "payload-conveyor", size: 3, buidTime: 60, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Payload Router", description: "Routes payload containers.", icon: "payload-router", size: 3, buidTime: 90, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Payload Junction", description: "Junction for payload systems.", icon: "payload-junction", size: 3, buidTime: 120, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Payload Bridge", description: "Bridge for payload transportation.", icon: "payload-bridge", size: 3, buidTime: 150, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Payload Rail", description: "Rail system for heavy payloads.", icon: "payload-rail", size: 3, buidTime: 180, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Payload Loader", description: "Loads items into payload containers.", icon: "payload-loader", size: 3, buidTime: 120, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Payload Unloader", description: "Unloads items from payload containers.", icon: "payload-unloader", size: 3, buidTime: 120, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Payload Mass Driver", description: "Mass driver for payload systems.", icon: "payload-mass-driver", size: 4, buidTime: 300, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        
        // === FREIGHT TRANSPORTATION ===
        CDBlock(name: "Freight Conveyer", description: "Heavy-duty freight transportation.", icon: "freight-conveyer", size: 4, buidTime: 120, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Freight Router", description: "Routes freight containers.", icon: "freight-router", size: 4, buidTime: 180, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Freight Junction", description: "Junction for freight systems.", icon: "freight-junction", size: 4, buidTime: 240, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Freight Bridge", description: "Bridge for freight lines.", icon: "freight-bridge", size: 4, buidTime: 300, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Freight Rail", description: "Heavy rail for freight transport.", icon: "freight-rail", size: 4, buidTime: 360, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Freight Loader", description: "Loads heavy freight containers.", icon: "freight-loader", size: 4, buidTime: 240, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Freight Unloader", description: "Unloads heavy freight containers.", icon: "freight-unloader", size: 4, buidTime: 240, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Freight Mass Driver", description: "Mass driver for freight systems.", icon: "freight-mass-driver", size: 5, buidTime: 480, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        
        // === RAIL SYSTEMS ===
        CDBlock(name: "Rail Router", description: "Routes rail traffic.", icon: "rail-router", size: 2, buidTime: 90, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Rail Junction", description: "Junction for rail lines.", icon: "rail-junction", size: 2, buidTime: 120, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Rail Bridge", description: "Bridge for rail crossings.", icon: "rail-bridge", size: 2, buidTime: 150, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Freight Rail Router", description: "Heavy-duty rail router.", icon: "freight-rail-router", size: 3, buidTime: 180, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Freight Rail Junction", description: "Heavy-duty rail junction.", icon: "freight-rail-junction", size: 3, buidTime: 240, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Freight Rail Bridge", description: "Heavy-duty rail bridge.", icon: "freight-rail-bridge", size: 3, buidTime: 300, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        
        // === FLUID TRANSPORTATION ===
        CDBlock(name: "Fluid Conduit", description: "Transports fluids through the factory.", icon: "fluid-conduit", size: 1, buidTime: 8, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Conduit Router", description: "Routes fluids to different paths.", icon: "conduit-router", size: 1, buidTime: 15, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Conduit Bridge", description: "Allows conduits to cross over each other.", icon: "conduit-bridge", size: 1, buidTime: 25, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Conduit Sorter", description: "Sorts fluids by type.", icon: "conduit-sorter", size: 1, buidTime: 30, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Conduit Junction", description: "Junction for fluid conduits.", icon: "conduit-junction", size: 1, buidTime: 20, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Overflow Conduit", description: "Handles fluid overflow.", icon: "overflow-conduit", size: 1, buidTime: 35, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Underflow Conduit", description: "Secondary conduit for underflow.", icon: "underflow-conduit", size: 1, buidTime: 35, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Sealed Cargo Mass Driver", description: "Long-range sealed fluid transportation.", icon: "sealed-cargo-mass-driver", size: 3, buidTime: 240, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        
        // === DUCT SYSTEMS ===
        CDBlock(name: "Duct", description: "Transports gases and small items.", icon: "duct", size: 1, buidTime: 10, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Duct Junction", description: "Junction for duct systems.", icon: "duct-junction", size: 1, buidTime: 15, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Duct Router", description: "Routes materials through ducts.", icon: "duct-router", size: 1, buidTime: 20, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Duct Bridge", description: "Bridge for duct crossings.", icon: "duct-bridge", size: 1, buidTime: 25, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Duct Sorter", description: "Sorts materials in ducts.", icon: "duct-sorter", size: 1, buidTime: 30, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Overflow Duct", description: "Handles duct overflow.", icon: "overflow-duct", size: 1, buidTime: 35, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Underflow Duct", description: "Secondary duct for underflow.", icon: "underflow-duct", size: 1, buidTime: 35, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        CDBlock(name: "Inverted Duct Sorter", description: "Reverse duct sorting mechanism.", icon: "inverted-duct-sorter", size: 1, buidTime: 40, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [])),
        
        // === PUMPS AND CONDENSERS ===
        CDBlock(name: "Fluid Pump", description: "Pumps fluids from beneath it.", icon: "fluid-pump", size: 2, buidTime: 45, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [Process(time: 1.0, inputPower: 50, outputFluids: [.water: 1])])),
        CDBlock(name: "Vent Condenser", description: "Condenses water from vents.", icon: "vent-condenser", size: 2, buidTime: 60, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [Process(time: 2.0, inputPower: 100, outputFluids: [.water: 2])])),
        CDBlock(name: "Geyser Condenser", description: "Condenses water from geysers.", icon: "geyser-condenser", size: 3, buidTime: 120, SPs: CDBSP(targetsGround: nil, targetsAir: nil, TATs: nil, range: nil, proceses: [Process(time: 1.5, inputPower: 200, outputFluids: [.water: 3])])),
        
        // === CONSTRUCTION BLOCKS ===
        CDBlock(name: "Picker", description: "Picks up items and resources.", icon: "picker", size: 2, buidTime: 60, SPs: CDBSP(targetsGround: false, targetsAir: false, TATs: [], range: 0, proceses: [])),
        CDBlock(name: "Placer", description: "Places blocks and structures.", icon: "placer", size: 2, buidTime: 90, SPs: CDBSP(targetsGround: false, targetsAir: false, TATs: [], range: 0, proceses: [])),
        CDBlock(name: "Constructor", description: "Builds structures and facilities.", icon: "constructor", size: 3, buidTime: 120, SPs: CDBSP(targetsGround: false, targetsAir: false, TATs: [], range: 0, proceses: [])),
        CDBlock(name: "Deconstructor", description: "Deconstructs buildings and structures.", icon: "deconstructor", size: 3, buidTime: 120, SPs: CDBSP(targetsGround: false, targetsAir: false, TATs: [], range: 0, proceses: [])),
        CDBlock(name: "Large Constructor", description: "Heavy construction unit for large projects.", icon: "large-constructor", size: 4, buidTime: 240, SPs: CDBSP(targetsGround: false, targetsAir: false, TATs: [], range: 0, proceses: [])),
        CDBlock(name: "Large Deconstructor", description: "Heavy deconstruction unit.", icon: "large-deconstructor", size: 4, buidTime: 240, SPs: CDBSP(targetsGround: false, targetsAir: false, TATs: [], range: 0, proceses: [])),
        
        // === FABRICATOR BLOCKS ===
        CDBlock(name: "Tank Fabricator", description: "Produces ground combat units.", icon: "tank-fabricator", size: 4, buidTime: 300, SPs: CDBSP(targetsGround: false, targetsAir: false, TATs: [], range: 0, proceses: [])),
        CDBlock(name: "Ship Fabricator", description: "Produces naval and flying units.", icon: "ship-fabricator", size: 4, buidTime: 360, SPs: CDBSP(targetsGround: false, targetsAir: false, TATs: [], range: 0, proceses: [])),
        CDBlock(name: "Hover Fabricator", description: "Produces hover units.", icon: "hover-fabricator", size: 3, buidTime: 240, SPs: CDBSP(targetsGround: false, targetsAir: false, TATs: [], range: 0, proceses: [])),
        CDBlock(name: "Support Hover Fabricator", description: "Produces support hover units.", icon: "support-hover-fabricator", size: 3, buidTime: 270, SPs: CDBSP(targetsGround: false, targetsAir: false, TATs: [], range: 0, proceses: [])),
        CDBlock(name: "Crawler Fabricator", description: "Produces crawler-type units.", icon: "crawler-fabricator", size: 3, buidTime: 210, SPs: CDBSP(targetsGround: false, targetsAir: false, TATs: [], range: 0, proceses: [])),
        CDBlock(name: "Unit Assembler", description: "Assembles complex units from components.", icon: "unit-assembler", size: 5, buidTime: 480, SPs: CDBSP(targetsGround: false, targetsAir: false, TATs: [], range: 0, proceses: [])),
        CDBlock(name: "Unit Reassembler", description: "Reassembles and upgrades existing units.", icon: "unit-reassembler", size: 5, buidTime: 540, SPs: CDBSP(targetsGround: false, targetsAir: false, TATs: [], range: 0, proceses: [])),
        CDBlock(name: "Unit Upgrader", description: "Upgrades units with enhanced capabilities.", icon: "unit-upgrader", size: 4, buidTime: 420, SPs: CDBSP(targetsGround: false, targetsAir: false, TATs: [], range: 0, proceses: [])),
        CDBlock(name: "Unit Refabricator", description: "Refabricates units with new specifications.", icon: "unit-refabricator", size: 6, buidTime: 720, SPs: CDBSP(targetsGround: false, targetsAir: false, TATs: [], range: 0, proceses: []))
    ],
    
    units: [
        // === CREATURE UNITS ===
        CDUnit(name: "Ant", description: "Basic ground unit with light armor.", icon: "ant", SPs: CDBSP(targetsGround: true, targetsAir: false, TATs: [TAT(item: nil, frags: [], damage: 15, inflictedEffect: nil)], range: 30, proceses: [])),
        CDUnit(name: "Beetle", description: "Armored ground unit with defensive capabilities.", icon: "beetle", SPs: CDBSP(targetsGround: true, targetsAir: false, TATs: [TAT(item: nil, frags: [], damage: 20, inflictedEffect: nil)], range: 35, proceses: [])),
        CDUnit(name: "Geckeo", description: "Fast reconnaissance unit.", icon: "geckeo", SPs: CDBSP(targetsGround: true, targetsAir: false, TATs: [TAT(item: nil, frags: [], damage: 25, inflictedEffect: nil)], range: 40, proceses: [])),
        CDUnit(name: "Termite", description: "Heavy assault unit with strong armor.", icon: "termite", SPs: CDBSP(targetsGround: true, targetsAir: false, TATs: [TAT(item: nil, frags: [], damage: 35, inflictedEffect: nil)], range: 45, proceses: [])),
        CDUnit(name: "Lizard", description: "Agile combat unit with improved weapons.", icon: "lizard", SPs: CDBSP(targetsGround: true, targetsAir: false, TATs: [TAT(item: nil, frags: [], damage: 40, inflictedEffect: nil)], range: 50, proceses: [])),
        CDUnit(name: "Armadillo", description: "Heavily armored defensive unit.", icon: "armadillo", SPs: CDBSP(targetsGround: true, targetsAir: false, TATs: [TAT(item: nil, frags: [], damage: 50, inflictedEffect: nil)], range: 55, proceses: [])),
        CDUnit(name: "Iguana", description: "Advanced ground unit with enhanced systems.", icon: "iguana", SPs: CDBSP(targetsGround: true, targetsAir: false, TATs: [TAT(item: nil, frags: [], damage: 60, inflictedEffect: nil)], range: 60, proceses: [])),
        CDUnit(name: "Turtle", description: "Ultimate ground defensive unit.", icon: "turtle", SPs: CDBSP(targetsGround: true, targetsAir: false, TATs: [TAT(item: nil, frags: [], damage: 80, inflictedEffect: nil)], range: 70, proceses: [])),
        CDUnit(name: "Chameleon", description: "Stealth combat unit with cloaking.", icon: "chameleon", SPs: CDBSP(targetsGround: true, targetsAir: false, TATs: [TAT(item: nil, frags: [], damage: 70, inflictedEffect: nil)], range: 65, proceses: [])),
        CDUnit(name: "Monitor", description: "Elite reconnaissance and combat unit.", icon: "monitor", SPs: CDBSP(targetsGround: true, targetsAir: true, TATs: [TAT(item: nil, frags: [], damage: 90, inflictedEffect: nil)], range: 80, proceses: [])),
        
        // === FLYING UNITS ===
        CDUnit(name: "Fly", description: "Basic flying scout unit.", icon: "fly", SPs: CDBSP(targetsGround: true, targetsAir: true, TATs: [TAT(item: nil, frags: [], damage: 12, inflictedEffect: nil)], range: 60, proceses: [])),
        CDUnit(name: "Moth", description: "Light flying combat unit.", icon: "moth", SPs: CDBSP(targetsGround: true, targetsAir: true, TATs: [TAT(item: nil, frags: [], damage: 20, inflictedEffect: nil)], range: 70, proceses: [])),
        CDUnit(name: "Kestrel", description: "Fast attack flying unit.", icon: "kestrel", SPs: CDBSP(targetsGround: true, targetsAir: true, TATs: [TAT(item: nil, frags: [], damage: 35, inflictedEffect: nil)], range: 80, proceses: [])),
        CDUnit(name: "Hawk", description: "Advanced aerial combat unit.", icon: "hawk", SPs: CDBSP(targetsGround: true, targetsAir: true, TATs: [TAT(item: nil, frags: [], damage: 50, inflictedEffect: nil)], range: 90, proceses: [])),
        CDUnit(name: "Eagle", description: "Elite air superiority fighter.", icon: "eagle", SPs: CDBSP(targetsGround: true, targetsAir: true, TATs: [TAT(item: nil, frags: [], damage: 75, inflictedEffect: nil)], range: 100, proceses: [])),
        
        // === HOVER UNITS ===
        CDUnit(name: "Hoverboard", description: "Basic hover transport unit.", icon: "hoverboard", SPs: CDBSP(targetsGround: false, targetsAir: false, TATs: [], range: 0, proceses: [])),
        CDUnit(name: "Hover-transport", description: "Cargo hover unit for transportation.", icon: "hover-transport", SPs: CDBSP(targetsGround: false, targetsAir: false, TATs: [], range: 0, proceses: [])),
        CDUnit(name: "Hoverlift", description: "Heavy-duty hover transport.", icon: "hoverlift", SPs: CDBSP(targetsGround: false, targetsAir: false, TATs: [], range: 0, proceses: [])),
        CDUnit(name: "Hovercraft", description: "Armed hover unit with combat capabilities.", icon: "hovercraft", SPs: CDBSP(targetsGround: true, targetsAir: false, TATs: [TAT(item: nil, frags: [], damage: 30, inflictedEffect: nil)], range: 50, proceses: [])),
        CDUnit(name: "Hovership", description: "Advanced hover combat vessel.", icon: "hovership", SPs: CDBSP(targetsGround: true, targetsAir: true, TATs: [TAT(item: nil, frags: [], damage: 45, inflictedEffect: nil)], range: 70, proceses: [])),
        
        // === SUPPORT UNITS ===
        CDUnit(name: "Destroy ", description: "Unit demolition specialist.", icon: "destroy", SPs: CDBSP(targetsGround: false, targetsAir: false, TATs: [], range: 0, proceses: [])),
        CDUnit(name: "Rebuild", description: "Reconstruction and repair unit.", icon: "rebuild", SPs: CDBSP(targetsGround: false, targetsAir: false, TATs: [], range: 0, proceses: [])),
        CDUnit(name: "Assist", description: "Support unit for assisting construction.", icon: "assist", SPs: CDBSP(targetsGround: false, targetsAir: false, TATs: [], range: 0, proceses: [])),
        CDUnit(name: "Support", description: "Advanced support and logistics unit.", icon: "support", SPs: CDBSP(targetsGround: false, targetsAir: false, TATs: [], range: 0, proceses: [])),
        CDUnit(name: "Protect", description: "Defensive support unit with shields.", icon: "protect", SPs: CDBSP(targetsGround: false, targetsAir: false, TATs: [], range: 0, proceses: []))
    ],
    
    fluids: [
        CDFluid(name: "Water", description:     "Essential fluid for many processes.", icon: "water"),
        CDFluid(name: "Petroleum", description: "Raw petroleum for refining.", icon: "petroleum")
    ],
    
    gases: [
        CDGas(name: "Hydrogen", description: "Lightweight gas used for advanced processes.", icon: "hydrogen"),
        CDGas(name: "Oxygen", description:   "Reactive gas essential for combustion.", icon: "oxygen"),
        CDGas(name: "Ethane", description:   "Hydrocarbon gas derived from petroleum.", icon: "ethane"),
        CDGas(name: "Methane", description:  "Simple hydrocarbon gas.", icon: "methane"),
        CDGas(name: "Butane", description:   "Heavier hydrocarbon gas.", icon: "butane"),
        CDGas(name: "Propane", description:  "Compressed hydrocarbon gas.", icon: "propane")
    ],
    
    sectors: [
        CDSector(name: "Starting Grounds", description: "A sector with minimal enemy presense, perfect for begining the journey of conquering Tarkon.", icon: "Starting-Grounds"),
        CDSector(name: "Ferrum Ridge", description: "This sector has many gysers, making it ideal for iron extraction and refinment into steel.", icon: "Ferrum-Ridge"),
        CDSector(name: "Crevice", description: "A small crevice with a large river seperating your and the enemy's base. hover and flying units will be the only viable options.", icon: "Crevice"),
        CDSector(name: "Nightfall Depths", description: "Because very few asteroids landed on this side of the planet, there aren't many vents and gysers; so you'll need to find other sources of energy. Aquire coal, and research the 'Combustion Engine' and 'Combustion Generator' to utilize the large deposits of coal on this sector.", icon: "Nightfall-Depths"),
        CDSector(name: "Aluminum Mountains", description: "Due to the mountainous terrain of this sector, flying and cralwer units will be the only possible options. Aquire aluminum, and research how to refine it, and utilize it for upgrading your units and turrets.", icon: "Aluminum-Mountains"),
        CDSector(name: "Dark Valley", description: "A valley filled with coal, sulfur, and some new gases. This sector will also allow for many new research opportunities, as well as many enemy bases.", icon: "Dark-Valley"),
        CDSector(name: "Ruins", description: "This secctor is filled with old technolgy lost to time. Salvage what you can, and move on.", icon: "Ruins")
    ],
    
    statusEffects: [
        CDStatusEfect(name: "Burning", description: "", icon: "burning"),
        CDStatusEfect(name: "Freezing", description: "", icon: "freezing"),
        CDStatusEfect(name: "Shocked", description: "", icon: "shocked"),
        CDStatusEfect(name: "EMP-1", description: "", icon: "EMP-1"),
        CDStatusEfect(name: "EMP-2", description: "", icon: "EMP-2"),
        CDStatusEfect(name: "EMP-3", description: "", icon: "EMP-3"),
        CDStatusEfect(name: "Disarmed", description: "", icon: "disarmed"),
        CDStatusEfect(name: "Energy Burn", description: "", icon: "energy-burn"),
        CDStatusEfect(name: "Stunned", description: "", icon: "stunned")
    ],
    
    resources: [
        CDResource(name: "Copper", description: "Basic metallic resource for early construction.", icon: "copper"),
        CDResource(name: "Graphite", description: "Carbon-based material for advanced components.", icon: "graphite"),
        CDResource(name: "Silicon", description: "Semiconductor material for electronics.", icon: "silicon"),
        CDResource(name: "Iron", description: "Strong metal for construction and tools.", icon: "iron"),
        CDResource(name: "Steel", description: "Refined metal alloy with superior properties.", icon: "steel"),
        CDResource(name: "Raw Aluminum", description: "Unprocessed aluminum ore.", icon: "rawAluminum"),
        CDResource(name: "Aluminum", description: "Lightweight metal for advanced construction.", icon: "aluminum"),
        CDResource(name: "Coal", description: "Combustible material for power generation.", icon: "coal"),
        CDResource(name: "Sulfur", description: "", icon: "sulfur")
    ]
)


#Preview {
    CoreDatabase()
}
