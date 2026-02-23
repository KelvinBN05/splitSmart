import Foundation

struct Participant: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }

    var initials: String {
        let parts = name
            .split(separator: " ")
            .compactMap { $0.first }

        let letters = parts.prefix(2).map { String($0) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}
