//
//  DatabaseManeger.swift
//  Factdustry
//
//  Created by Bright on 8/10/25.
//

import SwiftUI

class DatabaseManager: ObservableObject {
    static let shared = DatabaseManager()
    
    @Published var allItems: [any DatabaseItem] = []
    private var itemLookup: [String: any DatabaseItem] = [:]
    
    private init() {
        setupDatabase()
        buildLookup()
    }
    
    private func setupDatabase() {
        // Use the existing Tarkon planet data
        let tarkon = Tarkon
        
        // Combine all items from the existing Tarkon planet
        allItems = []
        allItems.append(contentsOf: tarkon.blocks)
        allItems.append(contentsOf: tarkon.units)
        allItems.append(contentsOf: tarkon.fluids)
        allItems.append(contentsOf: tarkon.gases)
        allItems.append(contentsOf: tarkon.sectors)
        allItems.append(contentsOf: tarkon.statusEffects)
        allItems.append(contentsOf: tarkon.resources)
    }
    
    private func buildLookup() {
        itemLookup.removeAll()
        for item in allItems {
            itemLookup[item.name] = item
        }
    }
    
    func findItem(named name: String) -> (any DatabaseItem)? {
        return itemLookup[name]
    }
    
    func getAllItems() -> [any DatabaseItem] {
        return allItems
    }
    
    func getItemsByType<T: DatabaseItem>(_ type: T.Type) -> [T] {
        return allItems.compactMap { $0 as? T }
    }
    
    func isResearched(_ itemName: String) -> Bool {
        return ResearchManager.shared.isResearched(itemName)
    }
}
