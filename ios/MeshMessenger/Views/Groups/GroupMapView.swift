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

    func start(groupId: String) {
        pinsListener = service.observePins(groupId: groupId) { [weak self] pins in
            Task { @MainActor [weak self] in self?.pins = pins }
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
    }

    func addPin(groupId: String, x: Double, y: Double, username: String, uid: String) async {
        let hex = GroupMapView.colorHex(for: username)
        do {
            try await service.addPin(groupId: groupId, x: x, y: y, username: username, uid: uid, colorHex: hex)
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

    // Keyed by URL string so a new upload (new token) naturally busts the cache.
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
            uiImage = cached
            return
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

    private var group: LocalGroup? {
        groupStore.groups.first { $0.id == groupId }
    }
    private var isAdmin: Bool { session.currentUid == group?.adminId }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let img = vm.uiImage {
                    if isAdmin {
                        HStack {
                            Spacer()
                            let isUploadingMap = vm.isUploadingMap
                            PhotosPicker(selection: $imageItem, matching: .images, preferredItemEncoding: .compatible) {
                                if isUploadingMap {
                                    Label("Uploading…", systemImage: "arrow.up.circle")
                                        .font(.caption)
                                } else {
                                    Label("Replace Map", systemImage: "photo.badge.plus")
                                        .font(.caption)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isUploadingMap)
                            .padding(.trailing)
                        }
                    }
                    mapCanvas(img)
                    Text("Tap anywhere on the map to place your pin.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                } else if vm.mapImageUrl != nil {
                    ProgressView("Loading map…")
                        .frame(height: 300)
                } else {
                    noMapPlaceholder
                }
            }
            .padding(.vertical)
        }
        .task { vm.start(groupId: groupId.uuidString) }
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
            pinDetail(pin: pin)
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

    // MARK: - Map canvas

    private func mapCanvas(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity)
            .overlay {
                GeometryReader { geo in
                    ZStack {
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                    .onEnded { val in
                                        let nx = val.location.x / geo.size.width
                                        let ny = val.location.y / geo.size.height
                                        guard (0...1).contains(nx), (0...1).contains(ny) else { return }
                                        guard let username = session.currentUsername,
                                              let uid = session.currentUid else { return }
                                        Task {
                                            await vm.addPin(
                                                groupId: groupId.uuidString,
                                                x: nx, y: ny,
                                                username: username, uid: uid
                                            )
                                        }
                                    }
                            )

                        ForEach(visiblePins) { pin in
                            Circle()
                                .fill(Self.pinColor(for: pin.colorHex))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                                .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                                .position(x: pin.x * geo.size.width, y: pin.y * geo.size.height)
                                .onTapGesture { selectedPin = pin }
                        }
                    }
                }
            }
    }

    // MARK: - Subviews

    private var noMapPlaceholder: some View {
        let isUploadingMap = vm.isUploadingMap
        return VStack(spacing: 16) {
            Image(systemName: "map")
                .font(.system(size: 60))
                .foregroundStyle(.tertiary)
            Text("No map yet")
                .font(.title3.bold())
            if isAdmin {
                PhotosPicker(selection: $imageItem, matching: .images, preferredItemEncoding: .compatible) {
                    if isUploadingMap {
                        Label("Uploading…", systemImage: "arrow.up.circle")
                    } else {
                        Label("Upload Map Image", systemImage: "photo.badge.plus")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isUploadingMap)
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
    private func pinDetail(pin: FirestorePin) -> some View {
        NavigationStack {
            VStack(spacing: 20) {
                Circle()
                    .fill(Self.pinColor(for: pin.colorHex))
                    .frame(width: 60, height: 60)
                    .overlay(Circle().stroke(Color.white.opacity(0.5), lineWidth: 3))
                    .shadow(radius: 4)
                VStack(spacing: 4) {
                    Text(pin.username)
                        .font(.title2.bold())
                    Text(pin.createdAt.dateValue(), style: .date)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(pin.createdAt.dateValue(), style: .time)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if pin.uid == session.currentUid || isAdmin {
                    Button("Remove Pin", role: .destructive) {
                        if let id = pin.id {
                            selectedPin = nil
                            Task { await vm.deletePin(groupId: groupId.uuidString, pinId: id) }
                        }
                    }
                    .buttonStyle(.bordered)
                }
                if pin.uid != session.currentUid {
                    Button("Report Pin", role: .destructive) {
                        vm.reportPinTarget = pin
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .foregroundStyle(.orange)

                    let isBlocked = blockStore.isBlocked(pin.username)
                    Button(isBlocked ? "Unblock \(pin.username)" : "Block \(pin.username)",
                           role: isBlocked ? nil : .destructive) {
                        isBlocked ? blockStore.unblock(pin.username) : blockStore.block(pin.username)
                        selectedPin = nil
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .foregroundStyle(isBlocked ? .secondary : Color.red)
                }
            }
            .padding()
            .navigationTitle("Pin Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { selectedPin = nil }
                }
            }
        }
        .presentationDetents([.medium])
        .sheet(item: $vm.reportPinTarget) { pin in
            ReportSheet(groupId: groupId.uuidString, pin: pin, reporterUid: session.currentUid ?? "") {
                selectedPin = nil
            }
        }
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
