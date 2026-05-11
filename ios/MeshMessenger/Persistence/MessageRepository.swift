import Foundation
import SwiftData

@MainActor
struct MessageRepository {
    let context: ModelContext

    func upsert(_ msg: LocalMessage) throws {
        let id = msg.id
        let descriptor = FetchDescriptor<LocalMessage>(predicate: #Predicate { $0.id == id })
        if let existing = try context.fetch(descriptor).first {
            if existing.deliveryStatus == .pending && msg.deliveryStatus == .delivered {
                existing.deliveryStatus = .delivered
            }
            return
        }
        context.insert(msg)
        try context.save()
    }

    func messages(in groupId: UUID) throws -> [LocalMessage] {
        let descriptor = FetchDescriptor<LocalMessage>(
            predicate: #Predicate { $0.groupId == groupId },
            sortBy: [SortDescriptor(\.sentAt, order: .forward)]
        )
        return try context.fetch(descriptor)
    }

    func latestReceivedAt(in groupId: UUID) throws -> Date? {
        var descriptor = FetchDescriptor<LocalMessage>(
            predicate: #Predicate { $0.groupId == groupId },
            sortBy: [SortDescriptor(\.receivedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.receivedAt
    }
}

@MainActor
struct GroupRepository {
    let context: ModelContext

    func all() throws -> [LocalGroup] {
        let descriptor = FetchDescriptor<LocalGroup>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return try context.fetch(descriptor)
    }

    func find(_ id: UUID) throws -> LocalGroup? {
        let descriptor = FetchDescriptor<LocalGroup>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }

    func upsert(_ group: LocalGroup) throws {
        if let existing = try find(group.id) {
            existing.name = group.name
            existing.adminId = group.adminId
            existing.inviteCode = group.inviteCode
            existing.memberUsernames = group.memberUsernames
            existing.lastSyncedAt = Date()
        } else {
            group.lastSyncedAt = Date()
            context.insert(group)
        }
        try context.save()
    }

    func remove(_ id: UUID) throws {
        guard let g = try find(id) else { return }
        context.delete(g)
        try context.save()
    }
}

@MainActor
struct KnownPeerRepository {
    let context: ModelContext

    func touch(peerId: String, username: String, groupId: UUID) throws {
        let key = "\(peerId)|\(groupId.uuidString)"
        let descriptor = FetchDescriptor<KnownPeer>(predicate: #Predicate { $0.compositeKey == key })
        if let existing = try context.fetch(descriptor).first {
            existing.username = username
            existing.lastSeenAt = Date()
        } else {
            context.insert(KnownPeer(peerId: peerId, username: username, groupId: groupId))
        }
        try context.save()
    }

    func peers(in groupId: UUID) throws -> [KnownPeer] {
        let descriptor = FetchDescriptor<KnownPeer>(
            predicate: #Predicate { $0.groupId == groupId },
            sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }
}
