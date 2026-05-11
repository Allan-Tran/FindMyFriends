import SwiftUI
import SwiftData

struct ChatView: View {
    let groupId: UUID

    @EnvironmentObject private var session: AuthSession
    @EnvironmentObject private var router: MessageRouter
    @EnvironmentObject private var groupStore: GroupStore
    @EnvironmentObject private var meshEngine: MeshEngine
    @EnvironmentObject private var syncEngine: SyncEngine
    @Environment(\.modelContext) private var modelContext

    @Query private var messages: [LocalMessage]
    @State private var draft: String = ""

    init(groupId: UUID) {
        self.groupId = groupId
        let predicate = #Predicate<LocalMessage> { $0.groupId == groupId }
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
        .navigationTitle(groupName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var groupName: String {
        groupStore.groups.first(where: { $0.id == groupId })?.name ?? "Group"
    }

    private var connectivityBar: some View {
        HStack(spacing: 12) {
            Label("\(meshEngine.connectedPeers.count) peer\(meshEngine.connectedPeers.count == 1 ? "" : "s") nearby", systemImage: "antenna.radiowaves.left.and.right")
                .font(.caption)
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
            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            Button {
                let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else { return }
                draft = ""
                Task { await router.sendChat(content: content, to: groupId) }
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

struct MessageBubble: View {
    let message: LocalMessage
    let isMine: Bool

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: 40) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
                if !isMine {
                    Text(message.senderUsername)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
                Text(message.content)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isMine ? Color.accentColor : Color.gray.opacity(0.2))
                    .foregroundStyle(isMine ? Color.white : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                HStack(spacing: 4) {
                    Text(message.sentAt, style: .time)
                    if message.isLate { Text("· late").foregroundStyle(.orange) }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if !isMine { Spacer(minLength: 40) }
        }
    }
}
