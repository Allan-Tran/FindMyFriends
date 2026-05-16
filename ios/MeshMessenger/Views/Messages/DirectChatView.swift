import SwiftUI
import SwiftData

struct DirectChatView: View {
    let dmId: UUID
    let peerUsername: String

    @EnvironmentObject private var session: AuthSession
    @EnvironmentObject private var router: MessageRouter
    @EnvironmentObject private var meshEngine: MeshEngine
    @EnvironmentObject private var proximityEngine: ProximityEngine
    @EnvironmentObject private var syncEngine: SyncEngine
    @EnvironmentObject private var dmStore: DMStore

    @Query private var messages: [LocalMessage]
    @State private var draft = ""

    init(dmId: UUID, peerUsername: String) {
        self.dmId = dmId
        self.peerUsername = peerUsername
        let predicate = #Predicate<LocalMessage> { $0.groupId == dmId }
        _messages = Query(filter: predicate, sort: [SortDescriptor(\.sentAt, order: .forward)])
    }

    var body: some View {
        VStack(spacing: 0) {
            connectivityBar
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(messages) { msg in
                            MessageBubble(message: msg, isMine: msg.senderUsername == session.currentUsername)
                                .id(msg.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.last?.id) { _, newId in
                    if let id = newId {
                        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
            composer
        }
        .navigationTitle(peerUsername)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            dmStore.openConversation(with: peerUsername)
            dmStore.activeConversationId = dmId
            dmStore.markRead(for: dmId)
        }
        .onChange(of: messages.count) { _, _ in
            dmStore.markRead(for: dmId)
        }
        .onDisappear {
            if dmStore.activeConversationId == dmId {
                dmStore.activeConversationId = nil
            }
        }
    }

    private var connectivityBar: some View {
        HStack(spacing: 12) {
            let isNearby = meshEngine.connectedPeers.contains { $0.displayName == peerUsername }
            let bleProx = proximityEngine.peers.first { $0.username == peerUsername }

            VStack(alignment: .leading, spacing: 2) {
                if isNearby {
                    Label("\(peerUsername) is nearby", systemImage: "wave.3.right")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Label("\(peerUsername) is out of range", systemImage: "wave.3.right.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let prox = bleProx {
                    Text("~\(Int(prox.estimatedMeters))m · \(prox.band.label)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if syncEngine.isOnline {
                Label("Online", systemImage: "wifi").font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Offline", systemImage: "wifi.slash").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Message \(peerUsername)", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            Button {
                let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else { return }
                draft = ""
                Task {
                    await router.sendChat(content: content, to: dmId)
                    dmStore.markUpdated(dmId)
                }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(8)
        .background(.bar)
    }
}
