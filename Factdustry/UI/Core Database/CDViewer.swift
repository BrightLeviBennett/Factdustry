//
//  BRFViewer.swift
//  Factdustry
//
//  Created by Bright on 7/16/25.
//

import SwiftUI

struct BFrag {
    let damage: Int
    let inflictedEffect: CDStatusEfect?
}

struct TAT: Identifiable { // turret ammo type
    let id = UUID()
    
    let item: ItemType?
    let frags: [BFrag]
    let damage: Int
    let inflictedEffect: CDStatusEfect?
}

struct CDBSP { // UIBlock Specical properties
    let targetsGround: Bool?
    let targetsAir: Bool?
    let TATs: [TAT]?
    let range: Int?
    
    let proceses: [Process]
}

struct CDBlock: Identifiable {
    let id = UUID()
    
    let name: String
    let description: String
    let icon: String
    let scaleX: Double
    let scaleY: Double
    let offsetX: Double
    let offsetY: Double
    let size: Int
    let buidTime: Int
    let SPs: CDBSP?
    
    init(name: String, description: String, icon: String, scaleX: Double = 1.0, scaleY: Double = 1.0, offsetX: Double = 0.0, offsetY: Double = 0.0, size: Int, buidTime: Int, SPs: CDBSP? = nil) {
        self.name = name
        self.description = description
        self.icon = icon
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.size = size
        self.buidTime = buidTime
        self.SPs = SPs
    }
}

struct CDUnit: Identifiable {
    let id = UUID()
    
    let name: String
    let description: String
    let icon: String
    let scaleX: Double
    let scaleY: Double
    let offsetX: Double
    let offsetY: Double
    let SPs: CDBSP?
    
    init(name: String, description: String, icon: String, scaleX: Double = 1.0, scaleY: Double = 1.0, offsetX: Double = 0.0, offsetY: Double = 0.0, SPs: CDBSP? = nil) {
        self.name = name
        self.description = description
        self.icon = icon
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.SPs = SPs
    }
}

struct CDFluid: Identifiable {
    let id = UUID()
    
    let name: String
    let description: String
    let icon: String
    let scaleX: Double
    let scaleY: Double
    let offsetX: Double
    let offsetY: Double
    
    init(name: String, description: String, icon: String, scaleX: Double = 1.0, scaleY: Double = 1.0, offsetX: Double = 0.0, offsetY: Double = 0.0) {
        self.name = name
        self.description = description
        self.icon = icon
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.offsetX = offsetX
        self.offsetY = offsetY
    }
}

struct CDGas: Identifiable {
    let id = UUID()
    
    let name: String
    let description: String
    let icon: String
    let scaleX: Double
    let scaleY: Double
    let offsetX: Double
    let offsetY: Double
    
    init(name: String, description: String, icon: String, scaleX: Double = 1.0, scaleY: Double = 1.0, offsetX: Double = 0.0, offsetY: Double = 0.0) {
        self.name = name
        self.description = description
        self.icon = icon
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.offsetX = offsetX
        self.offsetY = offsetY
    }
}

struct CDSector: Identifiable {
    let id = UUID()
    
    let name: String
    let description: String
    let icon: String
    let scaleX: Double
    let scaleY: Double
    let offsetX: Double
    let offsetY: Double
    
    init(name: String, description: String, icon: String, scaleX: Double = 1.0, scaleY: Double = 1.0, offsetX: Double = 0.0, offsetY: Double = 0.0) {
        self.name = name
        self.description = description
        self.icon = icon
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.offsetX = offsetX
        self.offsetY = offsetY
    }
}

struct CDResource: Identifiable {
    let id = UUID()
    
    let name: String
    let description: String
    let icon: String
    let scaleX: Double
    let scaleY: Double
    let offsetX: Double
    let offsetY: Double
    
    init(name: String, description: String, icon: String, scaleX: Double = 1.0, scaleY: Double = 1.0, offsetX: Double = 0.0, offsetY: Double = 0.0) {
        self.name = name
        self.description = description
        self.icon = icon
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.offsetX = offsetX
        self.offsetY = offsetY
    }
}

enum CDVMode {
    case block
    case resurce
    case fluid
    case sector
    case unit
    case statusEfect
}

struct CDStatusEfect: Identifiable {
    let id = UUID()
    
    var name: String
    var description: String
    var icon: String
    let scaleX: Double
    let scaleY: Double
    let offsetX: Double
    let offsetY: Double
    
    init(name: String, description: String, icon: String, scaleX: Double = 1.0, scaleY: Double = 1.0, offsetX: Double = 0.0, offsetY: Double = 0.0) {
        self.name = name
        self.description = description
        self.icon = icon
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.offsetX = offsetX
        self.offsetY = offsetY
    }
}

struct CDViewer: View { // Core Database Viewer
    let item: any DatabaseItem
    @Environment(\.dismiss) private var dismiss
    
    // Computed properties to determine mode and cast input
    private var mode: CDVMode {
        switch item {
        case is CDBlock: return .block
        case is CDUnit: return .unit
        case is CDFluid: return .fluid
        case is CDGas: return .fluid // Using fluid mode for gas as well
        case is CDResource: return .resurce
        case is CDStatusEfect: return .statusEfect
        case is CDSector: return .sector
        default: return .block
        }
    }
    
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            
            VStack {
                // Header with close button
                HStack {
                    Text(item.name)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.orange)
                    
                    Spacer()
                    
                    Button("✕") {
                        dismiss()
                    }
                    .font(.title2)
                    .foregroundColor(.gray)
                }
                .padding()
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Main content based on item type
                        switch mode {
                        case .block:
                            if let block = item as? CDBlock {
                                BlockDetailView(block: block)
                            }
                        case .unit:
                            if let unit = item as? CDUnit {
                                UnitDetailView(unit: unit)
                            }
                        case .fluid:
                            FluidDetailView(item: item)
                        case .resurce:
                            if let resource = item as? CDResource {
                                ResourceDetailView(resource: resource)
                            }
                        case .statusEfect:
                            if let statusEffect = item as? CDStatusEfect {
                                StatusEffectDetailView(statusEffect: statusEffect)
                            }
                        case .sector:
                            if let sector = item as? CDSector {
                                SectorDetailView(sector: sector)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Detail Views for Each Type

struct BlockDetailView: View {
    let block: CDBlock
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with icon and basic info
            HStack {
                Image(block.icon)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .scaleEffect(x: block.scaleX, y: block.scaleY)
                    .offset(x: block.offsetX, y: block.offsetY)
                    .background(Color(red: 0.2, green: 0.2, blue: 0.2))
                    .cornerRadius(8)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Block")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                    
                    Text("Size: \(block.size)×\(block.size)")
                        .foregroundColor(.white)
                    
                    Text("Build time: \(block.buidTime)s")
                        .foregroundColor(.white)
                }
                
                Spacer()
            }
            
            // Description
            Text(block.description)
                .foregroundColor(.white)
                .padding()
                .background(Color(red: 0.15, green: 0.15, blue: 0.15))
                .cornerRadius(8)
            
            // Special properties
            if let sps = block.SPs {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Combat Properties")
                        .font(.headline)
                        .foregroundColor(.orange)
                    
                    if let targetsGround = sps.targetsGround {
                        PropertyRow(label: "Targets Ground", value: targetsGround ? "Yes" : "No")
                    }
                    
                    if let targetsAir = sps.targetsAir {
                        PropertyRow(label: "Targets Air", value: targetsAir ? "Yes" : "No")
                    }
                    
                    if let range = sps.range {
                        PropertyRow(label: "Range", value: "\(range)")
                    }
                }
                .padding()
                .background(Color(red: 0.12, green: 0.12, blue: 0.12))
                .cornerRadius(8)
                
                // Ammo types
                if let tats = sps.TATs, !tats.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Ammunition Types")
                            .font(.headline)
                            .foregroundColor(.orange)
                        
                        ForEach(tats) { tat in
                            AmmoTypeView(tat: tat)
                        }
                    }
                }
            }
        }
    }
}

struct UnitDetailView: View {
    let unit: CDUnit
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(unit.icon)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .scaleEffect(x: unit.scaleX, y: unit.scaleY)
                    .offset(x: unit.offsetX, y: unit.offsetY)
                    .background(Color(red: 0.2, green: 0.2, blue: 0.2))
                    .cornerRadius(8)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Unit")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                
                Spacer()
            }
            
            Text(unit.description)
                .foregroundColor(.white)
                .padding()
                .background(Color(red: 0.15, green: 0.15, blue: 0.15))
                .cornerRadius(8)
            
            // Unit special properties if available
            if let sps = unit.SPs {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Unit Properties")
                        .font(.headline)
                        .foregroundColor(.orange)
                    
                    if let range = sps.range {
                        PropertyRow(label: "Range", value: "\(range)")
                    }
                }
                .padding()
                .background(Color(red: 0.12, green: 0.12, blue: 0.12))
                .cornerRadius(8)
            }
        }
    }
}

struct FluidDetailView: View {
    let item: any DatabaseItem
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Group {
                    if let fluid = item as? CDFluid {
                        Image(fluid.icon)
                            .resizable()
                            .frame(width: 64, height: 64)
                            .scaleEffect(x: fluid.scaleX, y: fluid.scaleY)
                            .offset(x: fluid.offsetX, y: fluid.offsetY)
                    } else if let gas = item as? CDGas {
                        Image(gas.icon)
                            .resizable()
                            .frame(width: 64, height: 64)
                            .scaleEffect(x: gas.scaleX, y: gas.scaleY)
                            .offset(x: gas.offsetX, y: gas.offsetY)
                    } else {
                        Image(item.icon)
                            .resizable()
                            .frame(width: 64, height: 64)
                    }
                }
                .background(Color(red: 0.2, green: 0.2, blue: 0.2))
                .cornerRadius(8)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(item is CDFluid ? "Fluid" : "Gas")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                
                Spacer()
            }
            
            Text(item.description)
                .foregroundColor(.white)
                .padding()
                .background(Color(red: 0.15, green: 0.15, blue: 0.15))
                .cornerRadius(8)
        }
    }
}

struct ResourceDetailView: View {
    let resource: CDResource
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(resource.icon)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .scaleEffect(x: resource.scaleX, y: resource.scaleY)
                    .offset(x: resource.offsetX, y: resource.offsetY)
                    .background(Color(red: 0.2, green: 0.2, blue: 0.2))
                    .cornerRadius(8)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Resource")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                
                Spacer()
            }
            
            Text(resource.description)
                .foregroundColor(.white)
                .padding()
                .background(Color(red: 0.15, green: 0.15, blue: 0.15))
                .cornerRadius(8)
        }
    }
}

struct StatusEffectDetailView: View {
    let statusEffect: CDStatusEfect
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(statusEffect.icon)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .scaleEffect(x: statusEffect.scaleX, y: statusEffect.scaleY)
                    .offset(x: statusEffect.offsetX, y: statusEffect.offsetY)
                    .background(Color(red: 0.2, green: 0.2, blue: 0.2))
                    .cornerRadius(8)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Status Effect")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                
                Spacer()
            }
            
            Text(statusEffect.description)
                .foregroundColor(.white)
                .padding()
                .background(Color(red: 0.15, green: 0.15, blue: 0.15))
                .cornerRadius(8)
        }
    }
}

struct SectorDetailView: View {
    let sector: CDSector
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(sector.icon)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .scaleEffect(x: sector.scaleX, y: sector.scaleY)
                    .offset(x: sector.offsetX, y: sector.offsetY)
                    .background(Color(red: 0.2, green: 0.2, blue: 0.2))
                    .cornerRadius(8)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sector")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                
                Spacer()
            }
            
            Text(sector.description)
                .foregroundColor(.white)
                .padding()
                .background(Color(red: 0.15, green: 0.15, blue: 0.15))
                .cornerRadius(8)
        }
    }
}

// MARK: - Helper Views

struct PropertyRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label + ":")
                .foregroundColor(.gray)
            
            Text(value)
                .foregroundColor(.white)
                .fontWeight(.medium)
            
            Spacer()
        }
        .font(.system(size: 14))
    }
}

struct AmmoTypeView: View {
    let tat: TAT
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Rectangle()
                    .frame(height: 120)
                    .foregroundColor(Color(white: 0.12))
                    .cornerRadius(8)
                
                VStack(alignment: .leading, spacing: 8) {
                    // Header with item icon and name
                    HStack {
                        if let item = tat.item {
                            Image(item.iconName)
                                .resizable()
                                .frame(width: 32, height: 32)
//                                .scaleEffect(x: item.scaleX ?? 1.0, y: item.scaleY ?? 1.0)
//                                .offset(x: item.offsetX ?? 0.0, y: item.offsetY ?? 0.0)
                        }
                        
                        if let item = tat.item {
                            Text(item.displayName)
                                .foregroundColor(.white)
                                .bold()
                        }
                        
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    
                    // Stats
                    VStack(alignment: .leading, spacing: 4) {
                        if !tat.frags.isEmpty {
                            Text("\(tat.frags.count) Fragments")
                                .foregroundColor(.yellow)
                                .font(.system(size: 12))
                        }
                        
                        Text("\(tat.damage) Damage")
                            .foregroundColor(.yellow)
                            .font(.system(size: 12))
                        
                        if let effect = tat.inflictedEffect {
                            HStack {
                                Image(effect.icon)
                                    .resizable()
                                    .frame(width: 16, height: 16)
                                    .scaleEffect(x: effect.scaleX, y: effect.scaleY)
                                    .offset(x: effect.offsetX, y: effect.offsetY)
                                
                                Text(effect.name)
                                    .foregroundColor(.yellow)
                                    .font(.system(size: 12))
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
            }
        }
    }
}

#Preview {
    let testInput = CDBlock(name: "Main-screen view", description: "yeah uy yeah description", icon: "Main_Screen_Background", scaleX: 1.2, scaleY: 0.8, offsetX: 5, offsetY: -3, size: 2, buidTime: 5, SPs: CDBSP(targetsGround: true, targetsAir: false, TATs: [TAT(item: .copper, frags: [], damage: 50, inflictedEffect: CDStatusEfect(name: "hoooooolyy woooowwwwwoow", description: "", icon: "_terrain1"))], range: 27, proceses: [] ))
    CDViewer(item: testInput)
}
