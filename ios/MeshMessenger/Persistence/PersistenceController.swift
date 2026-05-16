import Foundation
import SwiftData

@MainActor
final class PersistenceController {
    static let shared = PersistenceController()

    let container: ModelContainer

    private init() {
        let schema = Schema([LocalMessage.self, KnownPeer.self, LocalGroup.self, LocalDMConversation.self])
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )

        do {
            self.container = try ModelContainer(for: schema, configurations: config)
        } catch {
            // Schema changed during development — wipe the store at the path
            // SwiftData chose and recreate it from scratch.
            let base = config.url.path(percentEncoded: false)
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(atPath: base + suffix)
            }
            do {
                self.container = try ModelContainer(for: schema, configurations: config)
            } catch {
                fatalError("ModelContainer failed after store reset: \(error)")
            }
        }
    }

    var mainContext: ModelContext { container.mainContext }
}
