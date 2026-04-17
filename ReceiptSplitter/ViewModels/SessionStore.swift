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
    private let userProfileRepository: UserProfileRepository
    private var authStateObserver: NSObjectProtocol?

    init(
        authService: AuthService = FirebaseAuthService(),
        userProfileRepository: UserProfileRepository = FirestoreUserProfileRepository()
    ) {
        self.authService = authService	
        self.userProfileRepository = userProfileRepository
        self.authStateObserver = authService.observeAuthState { [weak self] appUser in
            Task { @MainActor in
                self?.state = appUser.map(State.signedIn) ?? .signedOut
            }
        }
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
            let user = try await withTimeout(seconds: 15) {
                try await self.authService.signIn(email: email, password: password)
            }
            state = .signedIn(user)
            Task {
                try? await self.userProfileRepository.upsertUserProfile(for: user)
            }
        } catch is TimeoutError {
            authErrorMessage = "Sign in timed out. Check your connection and try again."
        } catch {
            let nsError = error as NSError
            authErrorMessage = readableAuthError(from: nsError, fallback: error.localizedDescription)
        }
    }

    func signUp(email: String, password: String) async {
        authErrorMessage = nil
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            let user = try await withTimeout(seconds: 15) {
                try await self.authService.signUp(email: email, password: password)
            }
            state = .signedIn(user)
            Task {
                try? await self.userProfileRepository.upsertUserProfile(for: user)
            }
        } catch is TimeoutError {
            authErrorMessage = "Create account timed out. Check your connection and try again."
        } catch {
            let nsError = error as NSError
            authErrorMessage = readableAuthError(from: nsError, fallback: error.localizedDescription)
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

    private func readableAuthError(from error: NSError, fallback: String) -> String {
        if error.domain == NSURLErrorDomain {
            return "Network error. Check your internet connection and try again."
        }
        return fallback
    }

    private struct TimeoutError: Error {}

    private func withTimeout<T>(
        seconds: Double,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }

            guard let result = try await group.next() else {
                throw TimeoutError()
            }

            group.cancelAll()
            return result
        }
    }
}
