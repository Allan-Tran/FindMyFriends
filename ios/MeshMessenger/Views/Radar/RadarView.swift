import SwiftUI

struct RadarView: View {
    @EnvironmentObject private var router: MessageRouter
    @EnvironmentObject private var proximityEngine: ProximityEngine

    var body: some View {
        NavigationStack {
            List {
                if proximityEngine.peers.isEmpty {
                    ContentUnavailableView(
                        "Nothing nearby",
                        systemImage: "dot.radiowaves.left.and.right",
                        description: Text("Devices running Mesh Messenger nearby will appear here as you walk around.")
                    )
                } else {
                    ForEach(ProximityBand.allCases, id: \.self) { band in
                        let peers = proximityEngine.peers.filter { $0.band == band }
                        if !peers.isEmpty {
                            Section(band.label) {
                                ForEach(peers) { peer in
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(peer.username ?? peer.id)
                                                .font(.body)
                                            Text(String(format: "~%.1fm  RSSI %.0fdBm", peer.estimatedMeters, peer.smoothedRssi))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        BandDot(band: band)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Radar")
        }
    }
}

private struct BandDot: View {
    let band: ProximityBand
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 12, height: 12)
    }
    private var color: Color {
        switch band {
        case .rightHere: return .green
        case .nearby: return .mint
        case .close: return .yellow
        case .far: return .orange
        case .outOfRange: return .gray
        }
    }
}
