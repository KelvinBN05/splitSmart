import SwiftUI
import FirebaseCore
#if os(iOS)
import FirebaseAppCheck
#endif

#if os(iOS)
private final class SplitSmartAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
#if DEBUG
        return AppCheckDebugProvider(app: app)
#else
        if #available(iOS 14.0, *) {
            return AppAttestProvider(app: app)
        } else {
            return DeviceCheckProvider(app: app)
        }
#endif
    }
}
#endif

@main
struct ReceiptSplitterApp: App {
    let persistenceController = PersistenceController.shared
    @StateObject private var sessionStore: SessionStore

    init() {
#if os(iOS)
        AppCheck.setAppCheckProviderFactory(SplitSmartAppCheckProviderFactory())
#endif
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
