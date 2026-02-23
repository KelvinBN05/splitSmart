//
//  ReceiptSplitterApp.swift
//  ReceiptSplitter
//
//  Created by Kelvin Nguyen on 2/22/26.
//

import SwiftUI

@main
struct ReceiptSplitterApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
