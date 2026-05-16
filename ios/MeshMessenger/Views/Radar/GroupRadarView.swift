import SwiftUI
import MultipeerConnectivity

struct GroupRadarView: View {
    let groupId: UUID

    @EnvironmentObject private var meshEngine: MeshEngine
    @EnvironmentObject private var proximityEngine: ProximityEngine
    @EnvironmentObject private var groupStore: GroupStore
    @EnvironmentObject private var session: AuthSession
    @EnvironmentObject private var dmStore: DMStore

    @State private var dmTargetUsername: String?
    @State private var sweepDegrees: Double = 0

    private var group: LocalGroup? {
        groupStore.groups.first { $0.id == groupId }
    }

    private var groupMemberSet: Set<String> {
        Set(group?.memberUsernames ?? [])
    }

    private var nearbyMembers: [MCPeerID] {
        meshEngine.connectedPeers.filter { peer in
            let u = peer.displayName
            return groupMemberSet.contains(u) && u != session.currentUsername
        }
    }

    var body: some View {
        Group {
            if nearbyMembers.isEmpty {
                ContentUnavailableView(
                    "No group members nearby",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text("Group members within Bluetooth range will appear here.")
                )
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        radarCanvas
                            .frame(maxWidth: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)

                        Divider().padding(.top, 12)

                        ForEach(nearbyMembers, id: \.displayName) { peer in
                            memberRow(for: peer)
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) {
                sweepDegrees = 360
            }
        }
        .sheet(isPresented: Binding(
            get: { dmTargetUsername != nil },
            set: { if !$0 { dmTargetUsername = nil } }
        )) {
            if let username = dmTargetUsername,
               let myUsername = session.currentUsername {
                let dmId = DMStore.conversationId(userA: myUsername, userB: username)
                NavigationStack {
                    DirectChatView(dmId: dmId, peerUsername: username)
                }
            }
        }
    }

    // MARK: - Radar canvas

    private var radarCanvas: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let cx = geo.size.width / 2
            let cy = geo.size.height / 2
            let maxR = size / 2 - 28

            ZStack {
                // Dark background disk
                Circle()
                    .fill(Color(.systemFill).opacity(0.3))
                    .frame(width: size, height: size)
                    .position(x: cx, y: cy)

                // Concentric distance rings
                ForEach(Array(radarRings.enumerated()), id: \.offset) { idx, ring in
                    let r = ring.fraction * maxR
                    Circle()
                        .stroke(ring.color.opacity(0.5), lineWidth: 1)
                        .frame(width: r * 2, height: r * 2)
                        .position(x: cx, y: cy)

                    Text(ring.label)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(ring.color.opacity(0.8))
                        .position(x: cx + r - 2, y: cy - 7)
                }

                // Grid lines (cross-hairs)
                ForEach([0.0, 45.0, 90.0, 135.0], id: \.self) { deg in
                    let rad = deg * .pi / 180
                    Path { p in
                        p.move(to: CGPoint(x: cx + cos(rad) * maxR, y: cy + sin(rad) * maxR))
                        p.addLine(to: CGPoint(x: cx - cos(rad) * maxR, y: cy - sin(rad) * maxR))
                    }
                    .stroke(Color.green.opacity(0.12), lineWidth: 0.5)
                }

                // Sweep effect
                Group {
                    // Fade trail behind sweep line
                    AngularGradient(
                        stops: [
                            .init(color: .green.opacity(0), location: 0.6),
                            .init(color: .green.opacity(0.18), location: 1.0),
                        ],
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(90)
                    )
                    .clipShape(Circle())
                    .frame(width: maxR * 2, height: maxR * 2)
                    .position(x: cx, y: cy)

                    // Sweep line
                    Path { p in
                        p.move(to: CGPoint(x: cx, y: cy))
                        p.addLine(to: CGPoint(x: cx + maxR, y: cy))
                    }
                    .stroke(Color.green.opacity(0.9), lineWidth: 1.5)
                }
                .rotationEffect(.degrees(sweepDegrees), anchor: UnitPoint(x: cx / geo.size.width, y: cy / geo.size.height))

                // Me — center dot
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 10, height: 10)
                    .position(x: cx, y: cy)

                // Peer dots
                ForEach(nearbyMembers, id: \.displayName) { peer in
                    let username = peer.displayName
                    let prox = proximityEngine.peers.first { $0.username == username }
                    let band = prox?.band ?? .far
                    let r = peerRadius(band: band, maxR: maxR)
                    let angle = stableAngle(for: username)
                    let px = cx + cos(angle) * r
                    let py = cy + sin(angle) * r

                    // Glow ring + dot
                    Circle()
                        .fill(bandColor(band).opacity(0.25))
                        .frame(width: 26, height: 26)
                        .position(x: px, y: py)
                    Circle()
                        .fill(bandColor(band))
                        .frame(width: 11, height: 11)
                        .position(x: px, y: py)

                    // Username label
                    Text(username.prefix(10).description)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 3))
                        .position(x: px, y: py - 18)
                }
            }
        }
    }

    // MARK: - Member row

    @ViewBuilder
    private func memberRow(for peer: MCPeerID) -> some View {
        let username = peer.displayName
        let prox = proximityEngine.peers.first { $0.username == username }

        HStack(spacing: 12) {
            Circle()
                .fill(bandColor(prox?.band ?? .outOfRange))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(username).font(.body)
                if let p = prox {
                    Text(String(format: "~%.0f m · %@", p.estimatedMeters, p.band.label))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("In mesh range · distance unknown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                dmStore.openConversation(with: username)
                dmTargetUsername = username
            } label: {
                Label("Message", systemImage: "bubble.right")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Capsule())
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private var radarRings: [(fraction: Double, label: String, color: Color)] {
        [
            (0.25, "<5 m",  .green),
            (0.50, "<20 m", Color(red: 0.2, green: 0.8, blue: 0.6)),
            (0.75, "<50 m", .yellow),
            (1.00, "50 m+", .orange),
        ]
    }

    private func peerRadius(band: ProximityBand, maxR: Double) -> Double {
        switch band {
        case .rightHere:  return maxR * 0.20
        case .nearby:     return maxR * 0.45
        case .close:      return maxR * 0.70
        case .far:        return maxR * 0.88
        case .outOfRange: return maxR * 0.88
        }
    }

    private func bandColor(_ band: ProximityBand) -> Color {
        switch band {
        case .rightHere:  return .green
        case .nearby:     return Color(red: 0.2, green: 0.8, blue: 0.6)
        case .close:      return .yellow
        case .far:        return .orange
        case .outOfRange: return .gray
        }
    }

    /// Stable angle in radians derived from username so each peer occupies a consistent
    /// position on the radar across refreshes.
    private func stableAngle(for username: String) -> Double {
        let hash = username.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return Double(((hash % 360) + 360) % 360) * .pi / 180
    }
}
