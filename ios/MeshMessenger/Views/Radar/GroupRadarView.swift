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

    private var group: LocalGroup? {
        groupStore.groups.first { $0.id == groupId }
    }

    private var groupMemberSet: Set<String> {
        Set(group?.memberUsernames ?? [])
    }

    // Peers connected via MultipeerConnectivity whose username is a group member.
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
                    description: Text("Group members within Bluetooth / Wi-Fi range will appear here.")
                )
            } else {
                List(nearbyMembers, id: \.displayName) { peer in
                    memberRow(for: peer)
                }
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

    @ViewBuilder
    private func memberRow(for peer: MCPeerID) -> some View {
        let username = peer.displayName
        let proximity = proximityEngine.peers.first { $0.username == username }

        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(username)
                    .font(.body)
                if let p = proximity {
                    Text(String(format: "~%.0fm · %@", p.estimatedMeters, p.band.label))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Within mesh range")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let p = proximity {
                BandDot(band: p.band)
            } else {
                Image(systemName: "wave.3.right")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
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
        .padding(.vertical, 4)
    }
}

private struct BandDot: View {
    let band: ProximityBand
    var body: some View {
        Circle().fill(color).frame(width: 10, height: 10)
    }
    private var color: Color {
        switch band {
        case .rightHere:  return .green
        case .nearby:     return .mint
        case .close:      return .yellow
        case .far:        return .orange
        case .outOfRange: return .gray
        }
    }
}
