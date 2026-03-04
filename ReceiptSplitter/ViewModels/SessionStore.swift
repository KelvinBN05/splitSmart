import Foundation

@MainActor
final class SessionStore: ObservableObject {
    enum State: Equatable {
        case loading
        case signedOut
        case signedIn(AppUser)
    }

    @Published private(set) var state: State = .loading
    @Published var authErrorMessage: String?
    @Published private(set) var isAuthenticating = false

    private let authService: AuthService

    init(authService: AuthService = FirebaseAuthService()) {
        self.authService = authService
        restoreSession()
    }

    func restoreSession() {
        if let user = authService.currentUser() {
            state = .signedIn(user)
        } else {
            state = .signedOut
        }
    }

    func signIn(email: String, password: String) async {
        authErrorMessage = nil
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            let user = try await authService.signIn(email: email, password: password)
            state = .signedIn(user)
        } catch {
            authErrorMessage = error.localizedDescription
        }
    }

    func signUp(email: String, password: String) async {
        authErrorMessage = nil
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            let user = try await authService.signUp(email: email, password: password)
            state = .signedIn(user)
        } catch {
            authErrorMessage = error.localizedDescription
        }
    }

    func signOut() {
        authErrorMessage = nil
        do {
            try authService.signOut()
            state = .signedOut
        } catch {
            authErrorMessage = error.localizedDescription
        }
    }
}
