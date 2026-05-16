import SwiftUI
import SwiftData
import PhotosUI

struct DirectChatView: View {
    let dmId: UUID
    let peerUsername: String

    @EnvironmentObject private var session: AuthSession
    @EnvironmentObject private var router: MessageRouter
    @EnvironmentObject private var meshEngine: MeshEngine
    @EnvironmentObject private var proximityEngine: ProximityEngine
    @EnvironmentObject private var syncEngine: SyncEngine
    @EnvironmentObject private var dmStore: DMStore
    @EnvironmentObject private var blockStore: BlockStore

    @Query private var messages: [LocalMessage]
    @State private var draft = ""
    @State private var imageItem: PhotosPickerItem?
    @State private var isUploadingImage = false
    @State private var imageUploadError: String?

    private var visibleMessages: [LocalMessage] {
        messages.filter { !blockStore.isBlocked($0.senderUsername) }
    }

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
                        ForEach(visibleMessages) { msg in
                            MessageBubble(message: msg, isMine: msg.senderUsername == session.currentUsername)
                                .id(msg.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: visibleMessages.last?.id) { _, newId in
                    if let id = newId {
                        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
            composer
        }
        .navigationTitle(peerUsername)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    let isBlocked = blockStore.isBlocked(peerUsername)
                    Button(isBlocked ? "Unblock \(peerUsername)" : "Block \(peerUsername)",
                           systemImage: isBlocked ? "hand.raised.slash" : "hand.raised",
                           role: isBlocked ? nil : .destructive) {
                        isBlocked ? blockStore.unblock(peerUsername) : blockStore.block(peerUsername)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            dmStore.openConversation(with: peerUsername)
            dmStore.activeConversationId = dmId
            dmStore.markRead(for: dmId)
        }
        .onChange(of: messages.count) { _, _ in
            dmStore.markRead(for: dmId)
        }
        .onChange(of: imageItem) { _, item in
            guard let item else { return }
            imageItem = nil
            Task { await sendImage(item) }
        }
        .onDisappear {
            if dmStore.activeConversationId == dmId {
                dmStore.activeConversationId = nil
            }
        }
        .alert("Image Upload Failed", isPresented: Binding(
            get: { imageUploadError != nil },
            set: { if !$0 { imageUploadError = nil } }
        )) {
            Button("OK") { imageUploadError = nil }
        } message: {
            if let msg = imageUploadError { Text(msg) }
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
                    Label("\(peerUsername) is out of range", systemImage: "antenna.radiowaves.left.and.right.slash")
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
            PhotosPicker(selection: $imageItem, matching: .images, preferredItemEncoding: .compatible) {
                Image(systemName: "photo")
                    .font(.system(size: 22))
            }
            .foregroundStyle(isUploadingImage ? .secondary : Color.accentColor)
            .buttonStyle(.borderless)
            .disabled(isUploadingImage)

            TextField("Message \(peerUsername)", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)

            if isUploadingImage {
                ProgressView().frame(width: 28, height: 28)
            } else {
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
        }
        .padding(8)
        .background(.bar)
    }

    private func sendImage(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let img = UIImage(data: data) else {
            imageUploadError = "Failed to read the selected image."
            return
        }

        if syncEngine.isOnline {
            let resized = img.downsampled(toMaxDimension: 854)
            guard let jpeg = resized.jpegData(compressionQuality: 0.8) else { return }
            isUploadingImage = true
            defer { isUploadingImage = false }
            do {
                let url = try await MapService().uploadDMImage(
                    jpeg, dmId: dmId.uuidString, imageId: UUID().uuidString
                )
                await router.sendChat(content: "img:\(url)", to: dmId)
                dmStore.markUpdated(dmId)
            } catch {
                imageUploadError = error.localizedDescription
            }
        } else {
            let resized = img.downsampled(toMaxDimension: 480)
            guard let jpeg = resized.jpegData(compressionQuality: 0.6) else { return }
            let base64 = jpeg.base64EncodedString()
            await router.sendMeshOnly(content: "imgdata:\(base64)", to: dmId)
            dmStore.markUpdated(dmId)
        }
    }
}
