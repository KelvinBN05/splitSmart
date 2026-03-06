import Foundation

protocol ReceiptRepository {
    func fetchReceipts(ownerUserId: String) async throws -> [Receipt]
    func saveReceipt(_ receipt: Receipt, ownerUserId: String) async throws
    func deleteReceipt(receiptID: UUID, ownerUserId: String) async throws
}
