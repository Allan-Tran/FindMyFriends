import Foundation
import SwiftData
@preconcurrency import FirebaseFirestore

@MainActor
final class DMStore: ObservableObject {
    @Published private(set) var conversations: [LocalDMConversation] = []

    /// Set to the DM id the user is actively viewing so incoming messages aren't
    /// double-counted as unread while the conversation is on screen.
    var activeConversationId: UUID?

    private let context: ModelContext
    private let router: MessageRouter
    private let session: AuthSession
    private let dmRelayService = DMRelayService()
    private let userService = UserService()

    private var dmListeners: [UUID: ListenerRegistration] = [:]
    private var lastSeen: [UUID: Date] = [:]

    var totalUnreadCount: Int {
        conversations.reduce(0) { $0 + $1.unreadCount }
    }

    init(context: ModelContext, router: MessageRouter, session: AuthSession) {
        self.context = context
        self.router = router
        self.session = session

        router.onIncomingDM = { [weak self] id, peerUsername in
            guard let self else { return }
            self.openConversation(with: peerUsername)
            // startDMListener is called inside openConversation after the Firestore doc is created
        }

        router.onDMRelaySend = { [weak self] envelope, dmId in
            guard let self, let uid = self.session.currentUid else { return }
            try? await self.dmRelayService.post(envelope: envelope, dmId: dmId.uuidString, senderUid: uid)
        }

        router.onIncomingDMChat = { [weak self] dmId, senderUsername, sentAt, content in
            guard let self,
                  let conv = self.conversations.first(where: { $0.id == dmId }),
                  sentAt > conv.lastReadAt,
                  self.activeConversationId != dmId else { return }
            LocalNotificationHelper.postDMChat(from: senderUsername, preview: content, dmId: dmId.uuidString)
        }
    }

    func load() {
        let descriptor = FetchDescriptor<LocalDMConversation>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        conversations = (try? context.fetch(descriptor)) ?? []
        for conv in conversations {
            router.registerDM(conv.id)
            startDMListener(for: conv.id)
        }
    }

    func stop() {
        for (_, listener) in dmListeners { listener.remove() }
        dmListeners.removeAll()
    }

    @discardableResult
    func openConversation(with peerUsername: String) -> LocalDMConversation? {
        guard let myUsername = session.currentUsername else { return nil }
        let id = Self.conversationId(userA: myUsername, userB: peerUsername)
        if let existing = conversations.first(where: { $0.id == id }) {
            router.registerDM(id)
            return existing
        }
        let conv = LocalDMConversation(id: id, myUsername: myUsername, peerUsername: peerUsername)
        context.insert(conv)
        try? context.save()
        conversations.insert(conv, at: 0)
        router.registerDM(id)
        Task {
            if await createFirestoreDoc(dmId: id, myUsername: myUsername, peerUsername: peerUsername) {
                startDMListener(for: id)
            }
        }
        return conv
    }

    /// Called on a silent background push with kind="dm-relay".
    func handleIncomingDMPush(dmId: UUID) async {
        if conversations.first(where: { $0.id == dmId }) == nil {
            guard let myUid = session.currentUid,
                  let names = try? await dmRelayService.participantUsernames(dmId: dmId.uuidString),
                  let senderUid = try? await dmRelayService.senderUid(dmId: dmId.uuidString) else { return }
            let peerUsername = myUid == senderUid ? names.recipient : names.sender
            openConversation(with: peerUsername)
        }
        await fetchDMRelay(for: dmId)
    }

    /// One-shot catch-up for all known conversations — called on background push wake.
    func fetchAll() async {
        for conv in conversations { await fetchDMRelay(for: conv.id) }
    }

    func markUpdated(_ id: UUID) {
        guard let conv = conversations.first(where: { $0.id == id }) else { return }
        conv.updatedAt = Date()
        try? context.save()
        conversations.sort { $0.updatedAt > $1.updatedAt }
    }

    func markRead(for dmId: UUID) {
        guard let conv = conversations.first(where: { $0.id == dmId }) else { return }
        conv.unreadCount = 0
        conv.lastReadAt = Date()
        try? context.save()
        objectWillChange.send()
    }

    // MARK: - Private

    private func startDMListener(for dmId: UUID) {
        guard dmListeners[dmId] == nil else { return }
        let since = lastSeen[dmId]
        let listener = dmRelayService.observeMessages(dmId: dmId.uuidString, since: since) { [weak self] msg in
            Task { @MainActor [weak self] in self?.ingestRelay(msg, dmId: dmId) }
        }
        dmListeners[dmId] = listener
    }

    private func ingestRelay(_ msg: FirestoreRelayMessage, dmId: UUID) {
        guard let data = Data(base64Encoded: msg.envelopePayload),
              let envelope = try? MeshCodec.decoder.decode(MeshMessage.self, from: data) else { return }
        router.ingest(envelope, source: .relay)
        let msgDate = msg.storedAt.dateValue()
        if msgDate > (lastSeen[dmId] ?? .distantPast) {
            lastSeen[dmId] = msgDate
        }
        // Count as unread if: from the peer, newer than last read, and user isn't in this chat.
        if let conv = conversations.first(where: { $0.id == dmId }),
           msg.senderUid != session.currentUid,
           msgDate > conv.lastReadAt,
           activeConversationId != dmId {
            conv.unreadCount += 1
            try? context.save()
            LocalNotificationHelper.postDMChat(
                from: envelope.senderUsername,
                preview: envelope.content,
                dmId: dmId.uuidString
            )
        }
        markUpdated(dmId)
    }

    private func fetchDMRelay(for dmId: UUID) async {
        guard let items = try? await dmRelayService.fetchOnce(dmId: dmId.uuidString, since: lastSeen[dmId]) else { return }
        for item in items { ingestRelay(item, dmId: dmId) }
    }

    // Returns false only when the peer's UID can't be resolved, meaning we have no
    // way to create or verify the DM document. In all other cases (including UPDATE
    // denied because the doc already exists from the peer's side) we return true and
    // let the relay listener proceed.
    @discardableResult
    private func createFirestoreDoc(dmId: UUID, myUsername: String, peerUsername: String) async -> Bool {
        guard let myUid = session.currentUid,
              let peerUid = try? await userService.uid(forUsername: peerUsername) else { return false }
        try? await dmRelayService.ensureDMDocument(
            dmId: dmId.uuidString,
            senderUid: myUid, senderUsername: myUsername,
            recipientUid: peerUid, recipientUsername: peerUsername
        )
        return true
    }

    // MARK: - Deterministic UUID

    static func conversationId(userA: String, userB: String) -> UUID {
        let key = [userA, userB].sorted().joined(separator: "\0")
        var h: UInt64 = 14695981039346656037
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        let h2 = h &* 6364136223846793005 &+ 1442695040888963407
        var b = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { b[i] = UInt8((h >> (UInt64(i) * 8)) & 0xFF) }
        for i in 0..<8 { b[8+i] = UInt8((h2 >> (UInt64(i) * 8)) & 0xFF) }
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],
                           b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
    }
}
