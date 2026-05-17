import SwiftUI
import PhotosUI
@preconcurrency import FirebaseFirestore

// MARK: - ViewModel

@MainActor
private final class MapViewModel: ObservableObject {
    @Published var pins: [FirestorePin] = []
    @Published var mapImageUrl: String?
    @Published var uiImage: UIImage?
    @Published var isUploadingMap = false
    @Published var errorMessage: String?
    @Published var reportPinTarget: FirestorePin?

    private var pinsListener: ListenerRegistration?
    private var mapUrlListener: ListenerRegistration?
    private let service = MapService()

    private var seenPinIds: Set<String> = []
    private var pinListenerReady = false
    private var groupName: String = ""
    private var myUsername: String?

    func start(groupId: String, groupName: String, myUsername: String?) {
        self.groupName = groupName
        self.myUsername = myUsername

        pinsListener = service.observePins(groupId: groupId) { [weak self] pins in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.pinListenerReady {
                    self.seenPinIds = Set(pins.compactMap { $0.id })
                    self.pinListenerReady = true
                } else {
                    for pin in pins {
                        guard let id = pin.id, !self.seenPinIds.contains(id) else { continue }
                        self.seenPinIds.insert(id)
                        if pin.username != self.myUsername {
                            LocalNotificationHelper.postPinAdded(
                                by: pin.username,
                                in: self.groupName,
                                groupId: groupId
                            )
                        }
                    }
                }
                self.pins = pins
            }
        }
        mapUrlListener = service.observeMapUrl(groupId: groupId) { [weak self] url in
            Task { @MainActor [weak self] in
                self?.mapImageUrl = url
                if let url, let parsed = URL(string: url) {
                    await self?.loadImage(from: parsed)
                } else {
                    self?.uiImage = nil
                }
            }
        }
    }

    func stop() {
        pinsListener?.remove()
        mapUrlListener?.remove()
        pinsListener = nil
        mapUrlListener = nil
        pinListenerReady = false
        seenPinIds = []
    }

    func addPin(groupId: String, x: Double, y: Double, username: String, uid: String, description: String) async {
        let hex = GroupMapView.colorHex(for: username)
        do {
            try await service.addPin(groupId: groupId, x: x, y: y, username: username, uid: uid, colorHex: hex, description: description)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deletePin(groupId: String, pinId: String) async {
        do {
            try await service.deletePin(groupId: groupId, pinId: pinId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updatePinDescription(groupId: String, pinId: String, description: String) async {
        do {
            try await service.updatePinDescription(groupId: groupId, pinId: pinId, description: description)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func uploadMap(groupId: String, item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let img = UIImage(data: data) else {
            errorMessage = "Failed to process image."
            return
        }
        let downsampled = img.downsampled(toMaxDimension: 1920)
        guard let jpeg = downsampled.jpegData(compressionQuality: 0.8) else {
            errorMessage = "Failed to encode image."
            return
        }
        isUploadingMap = true
        do {
            _ = try await service.uploadMapImage(jpeg, groupId: groupId)
        } catch {
            errorMessage = error.localizedDescription
        }
        isUploadingMap = false
    }

    private static let imageCache = NSCache<NSString, UIImage>()
    private static let imageSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(
            memoryCapacity: 20 * 1024 * 1024,
            diskCapacity: 100 * 1024 * 1024,
            diskPath: "MapImageCache"
        )
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: cfg)
    }()

    private func loadImage(from url: URL) async {
        let key = url.absoluteString as NSString
        if let cached = Self.imageCache.object(forKey: key) {
            uiImage = cached; return
        }
        if let (data, _) = try? await Self.imageSession.data(from: url),
           let img = UIImage(data: data) {
            Self.imageCache.setObject(img, forKey: key)
            uiImage = img
        }
    }
}

// MARK: - View

struct GroupMapView: View {
    let groupId: UUID

    @EnvironmentObject private var session: AuthSession
    @EnvironmentObject private var groupStore: GroupStore
    @EnvironmentObject private var blockStore: BlockStore
    @EnvironmentObject private var syncEngine: SyncEngine
    @StateObject private var vm = MapViewModel()

    private var visiblePins: [FirestorePin] {
        vm.pins.filter { !blockStore.isBlocked($0.username) }
    }

    @State private var selectedPin: FirestorePin?
    @State private var imageItem: PhotosPickerItem?
    @State private var pendingPinLocation: CGPoint?
    @State private var pendingPinDescription: String = ""

    private var group: LocalGroup? {
        groupStore.groups.first { $0.id == groupId }
    }
    private var isAdmin: Bool { session.currentUid == group?.adminId }

    var body: some View {
        VStack(spacing: 12) {
            if let img = vm.uiImage {
                if isAdmin { adminReplaceButton(img: img) }

                ZoomableMapView(
                    image: img,
                    pins: visiblePins,
                    uiColorForPin: { pin in UIColor(Self.pinColor(for: pin.colorHex)) },
                    onMapTap: { point in
                        guard session.currentUsername != nil,
                              session.currentUid != nil else { return }
                        pendingPinLocation = point
                    },
                    onPinTap: { pin in selectedPin = pin }
                )
                .aspectRatio(img.size.height > 0 ? img.size.width / img.size.height : 1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal)

                Text("Tap to place a pin · Pinch to zoom")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            } else if vm.mapImageUrl != nil {
                ProgressView("Loading map…").frame(height: 300)
            } else {
                noMapPlaceholder
            }
        }
        .padding(.vertical)
        .task {
            vm.start(
                groupId: groupId.uuidString,
                groupName: group?.name ?? "",
                myUsername: session.currentUsername
            )
        }
        .onDisappear { vm.stop() }
        .onChange(of: imageItem) { _, item in
            guard let item else { return }
            guard syncEngine.isOnline else {
                vm.errorMessage = "Map images require an internet connection."
                return
            }
            Task { await vm.uploadMap(groupId: groupId.uuidString, item: item) }
        }
        .sheet(item: $selectedPin) { pin in
            PinDetailSheet(
                pin: pin,
                groupId: groupId.uuidString,
                currentUsername: session.currentUsername ?? "",
                currentUid: session.currentUid ?? "",
                isAdmin: isAdmin,
                onDeletePin: { id in
                    selectedPin = nil
                    Task { await vm.deletePin(groupId: groupId.uuidString, pinId: id) }
                },
                onSaveDescription: { id, desc in
                    selectedPin = nil
                    Task { await vm.updatePinDescription(groupId: groupId.uuidString, pinId: id, description: desc) }
                },
                onDone: { selectedPin = nil }
            )
            .environmentObject(blockStore)
        }
        .sheet(isPresented: Binding(
            get: { pendingPinLocation != nil },
            set: { if !$0 { pendingPinLocation = nil; pendingPinDescription = "" } }
        )) {
            pinPlacementSheet
        }
        .alert("Error", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            if let msg = vm.errorMessage { Text(msg) }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func adminReplaceButton(img: UIImage) -> some View {
        HStack {
            Spacer()
            let uploading = vm.isUploadingMap
            PhotosPicker(selection: $imageItem, matching: .images, preferredItemEncoding: .compatible) {
                if uploading {
                    Label("Uploading…", systemImage: "arrow.up.circle").font(.caption)
                } else {
                    Label("Replace Map", systemImage: "photo.badge.plus").font(.caption)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(uploading)
            .padding(.trailing)
        }
    }

    private var noMapPlaceholder: some View {
        let uploading = vm.isUploadingMap
        return VStack(spacing: 16) {
            Image(systemName: "map")
                .font(.system(size: 60))
                .foregroundStyle(.tertiary)
            Text("No map yet")
                .font(.title3.bold())
            if isAdmin {
                PhotosPicker(selection: $imageItem, matching: .images, preferredItemEncoding: .compatible) {
                    if uploading {
                        Label("Uploading…", systemImage: "arrow.up.circle")
                    } else {
                        Label("Upload Map Image", systemImage: "photo.badge.plus")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(uploading)
            } else {
                Text("Ask the group leader to upload a map image.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    @ViewBuilder
    private var pinPlacementSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What's here? (optional)", text: $pendingPinDescription, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("Description")
                }
            }
            .navigationTitle("Place Pin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        pendingPinLocation = nil
                        pendingPinDescription = ""
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Place") {
                        guard let loc = pendingPinLocation,
                              let username = session.currentUsername,
                              let uid = session.currentUid else { return }
                        let desc = pendingPinDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                        pendingPinLocation = nil
                        pendingPinDescription = ""
                        Task {
                            await vm.addPin(
                                groupId: groupId.uuidString,
                                x: loc.x, y: loc.y,
                                username: username, uid: uid,
                                description: desc
                            )
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Color helpers

    private static let hexPalette = [
        "#FF3B30", "#007AFF", "#34C759", "#FF9500",
        "#AF52DE", "#FF2D55", "#FFCC00", "#5AC8FA"
    ]

    static func colorHex(for username: String) -> String {
        var hash: UInt32 = 5381
        for b in username.utf8 { hash = hash &* 33 &+ UInt32(b) }
        return hexPalette[Int(hash % UInt32(hexPalette.count))]
    }

    static func pinColor(for hexString: String) -> Color {
        switch hexString {
        case "#FF3B30": return Color(red: 1.00, green: 0.23, blue: 0.19)
        case "#007AFF": return Color(red: 0.00, green: 0.48, blue: 1.00)
        case "#34C759": return Color(red: 0.20, green: 0.78, blue: 0.35)
        case "#FF9500": return Color(red: 1.00, green: 0.58, blue: 0.00)
        case "#AF52DE": return Color(red: 0.69, green: 0.32, blue: 0.87)
        case "#FF2D55": return Color(red: 1.00, green: 0.18, blue: 0.33)
        case "#FFCC00": return Color(red: 1.00, green: 0.80, blue: 0.00)
        case "#5AC8FA": return Color(red: 0.35, green: 0.78, blue: 0.98)
        default:        return .red
        }
    }
}

// MARK: - Pin detail model

@MainActor
private final class PinDetailModel: ObservableObject {
    @Published var comments: [PinComment] = []
    @Published var isLoadingComments = true

    private var listener: ListenerRegistration?
    private let service = MapService()
    private let groupId: String
    private let pinId: String

    init(groupId: String, pinId: String) {
        self.groupId = groupId
        self.pinId = pinId
    }

    func startListening() {
        guard listener == nil else { return }
        listener = service.observePinComments(groupId: groupId, pinId: pinId) { [weak self] comments in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isLoadingComments = false
                self.comments = comments
            }
        }
    }

    func stop() {
        listener?.remove()
        listener = nil
    }

    func addComment(username: String, text: String) async throws {
        try await service.addPinComment(groupId: groupId, pinId: pinId, username: username, text: text)
    }
}

// MARK: - Pin detail sheet

private struct PinDetailSheet: View {
    let pin: FirestorePin
    let groupId: String
    let currentUsername: String
    let currentUid: String
    let isAdmin: Bool
    let onDeletePin: (String) -> Void
    let onSaveDescription: (String, String) -> Void
    let onDone: () -> Void

    @EnvironmentObject private var blockStore: BlockStore
    @StateObject private var model: PinDetailModel

    @State private var editingDescription: String
    @State private var newCommentText = ""
    @State private var showAddComment = false
    @State private var isSubmittingComment = false
    @State private var submissionError: String?
    @State private var reportPin: FirestorePin?

    private var isOwner: Bool { pin.uid == currentUid }

    init(pin: FirestorePin, groupId: String, currentUsername: String, currentUid: String,
         isAdmin: Bool, onDeletePin: @escaping (String) -> Void,
         onSaveDescription: @escaping (String, String) -> Void, onDone: @escaping () -> Void) {
        self.pin = pin
        self.groupId = groupId
        self.currentUsername = currentUsername
        self.currentUid = currentUid
        self.isAdmin = isAdmin
        self.onDeletePin = onDeletePin
        self.onSaveDescription = onSaveDescription
        self.onDone = onDone
        _editingDescription = State(initialValue: pin.description ?? "")
        _model = StateObject(wrappedValue: PinDetailModel(groupId: groupId, pinId: pin.id ?? ""))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        Circle()
                            .fill(GroupMapView.pinColor(for: pin.colorHex))
                            .frame(width: 50, height: 50)
                            .overlay(Circle().stroke(Color.white.opacity(0.5), lineWidth: 3))
                            .shadow(radius: 4)
                        Spacer()
                    }
                    VStack(spacing: 4) {
                        Text(pin.username).font(.title2.bold())
                        Text(pin.createdAt.dateValue(), style: .date)
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(pin.createdAt.dateValue(), style: .time)
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }

                Section("Description") {
                    if isOwner {
                        TextField("Add a description…", text: $editingDescription, axis: .vertical)
                            .lineLimit(2...6)
                    } else if let desc = pin.description, !desc.isEmpty {
                        Text(desc)
                    } else {
                        Text("No description").foregroundStyle(.secondary)
                    }
                }

                Section("Additional Descriptions") {
                    if model.isLoadingComments {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    } else if model.comments.isEmpty {
                        Text("No additional descriptions yet.")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    } else {
                        ForEach(model.comments) { comment in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(comment.username)
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                Text(comment.text)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section {
                    if showAddComment {
                        TextField("Describe what you see here…", text: $newCommentText, axis: .vertical)
                            .lineLimit(2...5)
                        if let err = submissionError {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        HStack {
                            Button("Cancel") {
                                showAddComment = false
                                newCommentText = ""
                                submissionError = nil
                            }
                            .foregroundStyle(.secondary)
                            Spacer()
                            Button("Submit") { submitComment() }
                                .fontWeight(.semibold)
                                .disabled(newCommentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmittingComment)
                        }
                    } else {
                        Button("Add another description") {
                            showAddComment = true
                            submissionError = nil
                        }
                    }
                }

                if isOwner {
                    Section {
                        Button("Save Description") {
                            guard let id = pin.id else { return }
                            onSaveDescription(id, editingDescription.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                        Button("Remove Pin", role: .destructive) {
                            guard let id = pin.id else { return }
                            onDeletePin(id)
                        }
                    }
                } else {
                    if isAdmin {
                        Section {
                            Button("Remove Pin", role: .destructive) {
                                guard let id = pin.id else { return }
                                onDeletePin(id)
                            }
                        }
                    }
                    Section {
                        Button("Report Pin") { reportPin = pin }
                            .foregroundStyle(.orange)
                        let isBlocked = blockStore.isBlocked(pin.username)
                        Button(isBlocked ? "Unblock \(pin.username)" : "Block \(pin.username)",
                               role: isBlocked ? nil : .destructive) {
                            isBlocked ? blockStore.unblock(pin.username) : blockStore.block(pin.username)
                            onDone()
                        }
                    }
                }
            }
            .navigationTitle("Pin Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onDone() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            model.startListening()
        }
        .onDisappear { model.stop() }
        .sheet(item: $reportPin) { p in
            ReportSheet(groupId: groupId, pin: p, reporterUid: currentUid) {
                reportPin = nil
                onDone()
            }
        }
    }

    private func submitComment() {
        let trimmed = newCommentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSubmittingComment = true
        submissionError = nil
        newCommentText = ""
        showAddComment = false
        Task {
            do {
                try await model.addComment(username: currentUsername, text: trimmed)
            } catch {
                submissionError = error.localizedDescription
                showAddComment = true
            }
            isSubmittingComment = false
        }
    }
}

// MARK: - Report sheet

private struct ReportSheet: View {
    let groupId: String
    let pin: FirestorePin
    let reporterUid: String
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reason: String = ""
    @State private var isSending = false
    @State private var sent = false

    private let service = ReportService()

    var body: some View {
        NavigationStack {
            Form {
                Section("Why are you reporting this pin?") {
                    TextField("Describe the issue…", text: $reason, axis: .vertical)
                        .lineLimit(3...6)
                }
                Section {
                    Button("Submit Report") {
                        Task {
                            isSending = true
                            try? await service.reportPin(
                                groupId: groupId,
                                pinId: pin.id ?? "",
                                pinOwnerUid: pin.uid,
                                reporterUid: reporterUid,
                                reason: reason.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                            isSending = false
                            sent = true
                        }
                    }
                    .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending || sent)
                }
            }
            .navigationTitle("Report Pin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Report Submitted", isPresented: $sent) {
                Button("OK") { dismiss(); onDone() }
            } message: {
                Text("Thank you. The group admin will review this within 24 hours.")
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - UIImage downsampling

extension UIImage {
    func downsampled(toMaxDimension maxDim: CGFloat) -> UIImage {
        let scale = min(maxDim / size.width, maxDim / size.height, 1)
        guard scale < 1 else { return self }
        let newSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}
