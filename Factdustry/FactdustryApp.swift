//
//  FactdustryApp.swift
//  Factdustry
//
//  Created by Bright on 5/22/25.
//

import SwiftUI
import SwiftData

@main
struct FactdustryApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            //Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
    
    @StateObject private var hoverObserver = GlobalHoverObserver()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(hoverObserver)
                .ignoresSafeArea()
                .statusBarHidden()
                .background(
                    // Add the window accessor here at the top level
                    WindowAccessor { window in
                        hoverObserver.install(on: window)
                    }
                )
        }
        .modelContainer(sharedModelContainer)
    }
}

//@main
//struct MyApp: App {
//    @StateObject private var hoverObs = GlobalHoverObserver()
//
//    var body: some Scene {
//        WindowGroup {
//            ContentView()
//                .environmentObject(hoverObs)
//                // inject our WindowAccessor underneath everything
//                .background(
//                    WindowAccessor { window in
//                        hoverObs.install(on: window)
//                    }
//                )
//        }
//    }
//}
