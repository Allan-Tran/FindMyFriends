import SwiftUI
import SwiftData
import PhotosUI

struct ChatView: View {
    let groupId: UUID

    @EnvironmentObject private var session: AuthSession
    @EnvironmentObject private var router: MessageRouter
    @EnvironmentObject private var meshEngine: MeshEngine
    @EnvironmentObject private var syncEngine: SyncEngine
    @EnvironmentObject private var groupStore: GroupStore
    @EnvironmentObject private var blockStore: BlockStore

    @Query private var messages: [LocalMessage]
    @State private var draft: String = ""
    @State private var imageItem: PhotosPickerItem?
    @State private var isUploadingImage = false
    @State private var imageUploadError: String?

    private var visibleMessages: [LocalMessage] {
        messages.filter { !blockStore.isBlocked($0.senderUsername) }
    }

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
                        ForEach(visibleMessages) { msg in
                            let isMine = msg.senderUsername == session.currentUsername
                            MessageBubble(message: msg, isMine: isMine)
                                .id(msg.id)
                                .contextMenu {
                                    if !isMine {
                                        blockMenuButton(for: msg.senderUsername)
                                    }
                                }
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
        .onAppear {
            groupStore.activeGroupId = groupId
            groupStore.markRead(for: groupId)
        }
        .onDisappear {
            if groupStore.activeGroupId == groupId {
                groupStore.activeGroupId = nil
            }
        }
        .onChange(of: messages.count) { _, _ in
            groupStore.markRead(for: groupId)
        }
        .onChange(of: imageItem) { _, item in
            guard let item else { return }
            imageItem = nil
            Task { await sendImage(item) }
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

    @ViewBuilder
    private func blockMenuButton(for username: String) -> some View {
        if blockStore.isBlocked(username) {
            Button("Unblock \(username)", systemImage: "hand.raised.slash") {
                blockStore.unblock(username)
            }
        } else {
            Button("Block \(username)", systemImage: "hand.raised", role: .destructive) {
                blockStore.block(username)
            }
        }
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
            PhotosPicker(selection: $imageItem, matching: .images, preferredItemEncoding: .compatible) {
                Image(systemName: "photo")
                    .font(.system(size: 22))
            }
            .foregroundStyle(isUploadingImage ? .secondary : Color.accentColor)
            .buttonStyle(.borderless)
            .disabled(isUploadingImage)

            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)

            if isUploadingImage {
                ProgressView().frame(width: 28, height: 28)
            } else {
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
            // Online: upload to Firebase Storage, send a compact URL via mesh + relay.
            let resized = img.downsampled(toMaxDimension: 854)
            guard let jpeg = resized.jpegData(compressionQuality: 0.8) else { return }
            isUploadingImage = true
            defer { isUploadingImage = false }
            do {
                let url = try await MapService().uploadChatImage(
                    jpeg, groupId: groupId.uuidString, imageId: UUID().uuidString
                )
                await router.sendChat(content: "img:\(url)", to: groupId)
            } catch {
                imageUploadError = error.localizedDescription
            }
        } else {
            // Offline: encode image inline and send via Bluetooth mesh only.
            // Smaller dimensions and quality keep the payload under ~25 KB.
            let resized = img.downsampled(toMaxDimension: 480)
            guard let jpeg = resized.jpegData(compressionQuality: 0.6) else { return }
            let base64 = jpeg.base64EncodedString()
            await router.sendMeshOnly(content: "imgdata:\(base64)", to: groupId)
        }
    }
}

struct MessageBubble: View {
    let message: LocalMessage
    let isMine: Bool

    private var imageURL: URL? {
        guard message.content.hasPrefix("img:") else { return nil }
        return URL(string: String(message.content.dropFirst(4)))
    }

    private var inlineImage: UIImage? {
        guard message.content.hasPrefix("imgdata:") else { return nil }
        let b64 = String(message.content.dropFirst(8))
        guard let data = Data(base64Encoded: b64) else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: 40) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
                if !isMine {
                    Text(message.senderUsername)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
                if let url = imageURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        case .failure:
                            Label("Image unavailable", systemImage: "photo.badge.exclamationmark")
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(8)
                        case .empty:
                            ProgressView().padding(20)
                        @unknown default:
                            EmptyView()
                        }
                    }
                    .frame(maxWidth: 240)
                } else if let img = inlineImage {
                    Image(uiImage: img)
                        .resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .frame(maxWidth: 240)
                } else {
                    Text(message.content)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(isMine ? Color.accentColor : Color.gray.opacity(0.2))
                        .foregroundStyle(isMine ? Color.white : Color.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
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
