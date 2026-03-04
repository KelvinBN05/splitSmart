import Foundation

struct AppUser: Equatable {
    let id: String
    let email: String?
}

protocol AuthService {
    func currentUser() -> AppUser?
    func signIn(email: String, password: String) async throws -> AppUser
    func signUp(email: String, password: String) async throws -> AppUser
    func signOut() throws
}
