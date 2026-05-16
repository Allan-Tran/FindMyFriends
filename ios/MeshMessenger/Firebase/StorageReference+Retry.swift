import Foundation
import FirebaseStorage

extension StorageReference {
    func downloadURLWithRetry(maxRetries: Int = 3) async throws -> URL {
        var currentTry = 0
        while true {
            do {
                return try await self.downloadURL()
            } catch {
                currentTry += 1
                if currentTry >= maxRetries {
                    throw error
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
}
