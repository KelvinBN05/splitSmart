import Foundation
import FirebaseAuth

final class FirebaseAuthService: AuthService {
    func currentUser() -> AppUser? {
        guard let user = Auth.auth().currentUser else { return nil }
        return AppUser(id: user.uid, email: user.email)
    }

    func observeAuthState(_ onChange: @escaping (AppUser?) -> Void) -> NSObjectProtocol {
        Auth.auth().addStateDidChangeListener { _, user in
            let appUser = user.map { AppUser(id: $0.uid, email: $0.email) }
            onChange(appUser)
        }
    }

    func removeAuthStateObserver(_ observer: NSObjectProtocol) {
        Auth.auth().removeStateDidChangeListener(observer)
    }

    func signIn(email: String, password: String) async throws -> AppUser {
        let result = try await Auth.auth().signIn(withEmail: email, password: password)
        return AppUser(id: result.user.uid, email: result.user.email)
    }

    func signUp(email: String, password: String) async throws -> AppUser {
        let result = try await Auth.auth().createUser(withEmail: email, password: password)
        return AppUser(id: result.user.uid, email: result.user.email)
    }

    func signOut() throws {
        try Auth.auth().signOut()
    }
}
