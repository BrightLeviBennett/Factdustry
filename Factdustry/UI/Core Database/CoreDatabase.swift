//
//  Core Database.swift
//  Factdustry
//
//  Created by Bright on 7/16/25.
//

import SwiftUI

// NOTE: Planet, Tarkon, and DatabaseItem protocol are now defined in Tarkon.swift
// This file focuses on the UI components for the Core Database

// MARK: - Main Core Database View
struct CoreDatabase: View {
    @State private var searchText = ""
    @State private var selectedItem: (any DatabaseItem)? = nil
    @State private var showingDetail: (any DatabaseItem)? = nil
    @ObservedObject private var researchManager = ResearchManager.shared
    @ObservedObject private var databaseManager = DatabaseManager.shared
    
    let planet: Planet
    
    init(planet: Planet = Tarkon) {
        self.planet = planet
    }
    
    var filteredBlocks: [CDBlock] {
        filterItems(databaseManager.getItemsByType(CDBlock.self))
    }
    
    var filteredUnits: [CDUnit] {
        filterItems(databaseManager.getItemsByType(CDUnit.self))
    }
    
    var filteredFluids: [CDFluid] {
        filterItems(databaseManager.getItemsByType(CDFluid.self))
    }
    
    var filteredGases: [CDGas] {
        filterItems(databaseManager.getItemsByType(CDGas.self))
    }
    
    var filteredResources: [CDResource] {
        filterItems(databaseManager.getItemsByType(CDResource.self))
    }
    
    var filteredStatusEffects: [CDStatusEfect] {
        filterItems(databaseManager.getItemsByType(CDStatusEfect.self))
    }
    
    var filteredSectors: [CDSector] {
        filterItems(databaseManager.getItemsByType(CDSector.self))
    }
    
    private func filterItems<T: DatabaseItem>(_ items: [T]) -> [T] {
        if searchText.isEmpty {
            return items
        } else {
            return items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    // Computed property for sheet presentation binding
    private var isShowingDetailBinding: Binding<Bool> {
        Binding(
            get: { showingDetail != nil },
            set: { newValue in
                if !newValue {
                    showingDetail = nil
                }
            }
        )
    }
    
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                // Main Content
                VStack(spacing: 0) {
                    // Content area
                    contentArea
                    
                    // Bottom bar
                    bottomBar
                }
                .background(Color.black)
            }
        }
        .background(Color.black)
        .sheet(isPresented: isShowingDetailBinding) {
            if let item = showingDetail {
                CDViewer(item: item)
            }
        }
    }
        
    private var contentArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Items Section
                if !filteredResources.isEmpty {
                    DatabaseSection(
                        title: "Items",
                        items: filteredResources,
                        onItemTap: { item in
                            selectedItem = item
                            showingDetail = item
                        }
                    )
                }
                
                // Blocks Section
                if !filteredBlocks.isEmpty {
                    DatabaseSection(
                        title: "Blocks",
                        items: filteredBlocks,
                        onItemTap: { item in
                            selectedItem = item
                            showingDetail = item
                        }
                    )
                }
                
                // Fluids Section
                if !filteredFluids.isEmpty {
                    DatabaseSection(
                        title: "Fluids",
                        items: filteredFluids,
                        onItemTap: { item in
                            selectedItem = item
                            showingDetail = item
                        }
                    )
                }
                
                if !filteredGases.isEmpty {
                    DatabaseSection(
                        title: "Gases",
                        items: filteredGases,
                        onItemTap: { item in
                            selectedItem = item
                            showingDetail = item
                        }
                    )
                }
                
                // Status Effects Section
                if !filteredStatusEffects.isEmpty {
                    DatabaseSection(
                        title: "Status Effects",
                        items: filteredStatusEffects,
                        onItemTap: { item in
                            selectedItem = item
                            showingDetail = item
                        }
                    )
                }
                
                // Units Section
                if !filteredUnits.isEmpty {
                    DatabaseSection(
                        title: "Units",
                        items: filteredUnits,
                        onItemTap: { item in
                            selectedItem = item
                            showingDetail = item
                        }
                    )
                }
                
                // Sectors Section
                if !filteredSectors.isEmpty {
                    DatabaseSection(
                        title: "Sectors",
                        items: filteredSectors,
                        onItemTap: { item in
                            selectedItem = item
                            showingDetail = item
                        }
                    )
                }
                
                Spacer(minLength: 100)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
        }
    }
    
    private var bottomBar: some View {
        HStack {
            Button(action: {
                // Back action
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .medium))
                    
                    Text("Back")
                        .font(.system(size: 16, weight: .medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color(red: 0.2, green: 0.2, blue: 0.2))
                .cornerRadius(8)
            }
        }
        .padding()
        .background(Color(red: 0.05, green: 0.05, blue: 0.05))
    }
}

// MARK: - Supporting Views
struct SidebarButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(isSelected ? .orange : .gray)
                    .frame(width: 20)
                
                Text(title)
                    .font(.system(size: 16))
                    .foregroundColor(isSelected ? .orange : .gray)
                
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(isSelected ? Color(red: 0.2, green: 0.15, blue: 0.05) : Color.clear)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct DatabaseSection<T: DatabaseItem>: View {
    let title: String
    let items: [T]
    let onItemTap: (T) -> Void
    @ObservedObject private var researchManager = ResearchManager.shared
    
    private let columns = Array(repeating: GridItem(.fixed(40), spacing: 4), count: 20)
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header with research count
            HStack {
                Text(title)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.orange)
                
                let researchedCount = items.filter { researchManager.isResearched($0.name) }.count
                if researchedCount > 0 {
                    Text("(\(researchedCount)/\(items.count))")
                        .font(.system(size: 14))
                        .foregroundColor(.green)
                }
                
                Rectangle()
                    .fill(Color.orange)
                    .frame(height: 2)
                    .frame(maxWidth: .infinity)
            }
            
            // Items grid
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    DatabaseItemIcon(item: item) {
                        onItemTap(item)
                    }
                }
            }
        }
    }
}

struct DatabaseItemIcon: View {
    let item: any DatabaseItem
    let onTap: () -> Void
    @ObservedObject private var researchManager = ResearchManager.shared
    
    var isResearched: Bool {
        researchManager.isResearched(item.name)
    }
    
    var body: some View {
        Button(action: onTap) {
            ZStack {
                // Background
                Rectangle()
                    .fill(Color(red: 0.2, green: 0.2, blue: 0.2))
                    .frame(width: 36, height: 36)
                    .cornerRadius(4)
                
                // Item icon
                if isResearched {
                    Image(item.icon)
                        .resizable()
                        .frame(width: 32, height: 32)
                        .scaleEffect(x: item.scaleX, y: item.scaleY)
                        .offset(x: item.offsetX, y: item.offsetY)
                } else {
                    Image(systemName: "lock.fill")
                        .resizable()
                        .frame(width: 16, height: 16)
                        .foregroundColor(.gray)
                        .opacity(0.6)
                }
                
                // Research status overlay
                if isResearched {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption2)
                        }
                        Spacer()
                    }
                    .frame(width: 36, height: 36)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(
                        isResearched ? Color.green.opacity(0.6) : Color.gray.opacity(0.3),
                        lineWidth: isResearched ? 2 : 1
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct MindustryDetailView: View {
    let item: any DatabaseItem
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var researchManager = ResearchManager.shared
    
    var isResearched: Bool {
        researchManager.isResearched(item.name)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack {
                Image(item.icon)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .scaleEffect(x: item.scaleX, y: item.scaleY)
                    .offset(x: item.offsetX, y: item.offsetY)
                    .background(Color(red: 0.2, green: 0.2, blue: 0.2))
                    .cornerRadius(8)
                    .opacity(isResearched ? 1.0 : 0.6)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.orange)
                    
                    HStack {
                        Text(getItemType())
                            .font(.subheadline)
                            .foregroundColor(.gray)
                        
                        if isResearched {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                        } else {
                            Image(systemName: "lock.fill")
                                .foregroundColor(.red)
                                .font(.caption)
                        }
                    }
                }
                
                Spacer()
                
                Button("✕") {
                    dismiss()
                }
                .font(.title2)
                .foregroundColor(.gray)
            }
            .padding()
            
            // Research status
            if !isResearched {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    
                    Text("This item has not been researched yet. Research it in the Tech Tree to unlock its full information.")
                        .font(.caption)
                        .foregroundColor(.yellow)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.yellow.opacity(0.1))
                .cornerRadius(8)
                .padding(.horizontal)
            }
            
            // Description
            Text(isResearched ? item.description : "Research this item to view its description.")
                .font(.body)
                .foregroundColor(isResearched ? .white : .gray)
                .italic(!isResearched)
                .padding(.horizontal)
            
            // Additional details based on type (only if researched)
            if isResearched, let block = item as? CDBlock {
                BlockDetailSection(block: block)
            }
            
            Spacer()
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
    
    private func getItemType() -> String {
        switch item {
        case is CDBlock: return "Block"
        case is CDUnit: return "Unit"
        case is CDFluid: return "Fluid"
        case is CDGas: return "Gas"
        case is CDResource: return "Resource"
        case is CDStatusEfect: return "Status Effect"
        case is CDSector: return "Sector"
        default: return "Unknown"
        }
    }
}

struct BlockDetailSection: View {
    let block: CDBlock
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Properties")
                .font(.headline)
                .foregroundColor(.orange)
                .padding(.horizontal)
            
            VStack(alignment: .leading, spacing: 4) {
                DetailProperty(label: "Size", value: "\(block.size)×\(block.size)")
                DetailProperty(label: "Build Time", value: "\(block.buidTime)s")
                
                if let sp = block.SPs {
                    if let range = sp.range {
                        DetailProperty(label: "Range", value: "\(range)")
                    }
                    if let targetsGround = sp.targetsGround {
                        DetailProperty(label: "Targets Ground", value: targetsGround ? "Yes" : "No")
                    }
                    if let targetsAir = sp.targetsAir {
                        DetailProperty(label: "Targets Air", value: targetsAir ? "Yes" : "No")
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}

struct DetailProperty: View {
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

// MARK: - Preview
#Preview {
    CoreDatabase()
}
