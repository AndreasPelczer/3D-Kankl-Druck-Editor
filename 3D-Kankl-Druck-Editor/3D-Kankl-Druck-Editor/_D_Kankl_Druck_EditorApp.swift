//
//  _D_Kankl_Druck_EditorApp.swift
//  3D-Kankl-Druck-Editor
//
//  Created by Andreas Pelczer on 05.03.26.
//

import SwiftUI
import SwiftData

@main
struct _D_Kankl_Druck_EditorApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
