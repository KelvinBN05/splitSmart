import SwiftUI
import FirebaseCore

@main
struct ReceiptSplitterApp: App {
    let persistenceController = PersistenceController.shared
    @StateObject private var sessionStore: SessionStore

    init() {
        FirebaseApp.configure()
        _sessionStore = StateObject(wrappedValue: SessionStore())
    }

    var body: some Scene {
        WindowGroup {
            AuthGateView()
                .environmentObject(sessionStore)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
