import Foundation
@preconcurrency import MultipeerConnectivity

/// Per-peer exponential back-off reconnect scheduler.
///
/// When a peer disconnects the browser will still see them (lostPeer is called
/// only when advertising stops). We track how many consecutive failures we've had
/// for each peer and back off the re-invite delay so we don't hammer the radio.
@MainActor
final class ReconnectManager {
    private struct PeerState {
        var consecutiveFailures: Int = 0
        var nextAttemptAfter: Date = .distantPast
        var pendingTask: Task<Void, Never>?
    }

    private var states: [MCPeerID: PeerState] = [:]

    // Backoff curve: 2^n seconds clamped to maxDelay.
    private let baseDelay: TimeInterval = 2
    private let maxDelay: TimeInterval = 120

    func scheduleReconnect(
        to peer: MCPeerID,
        via browser: MCNearbyServiceBrowser,
        on session: MCSession,
        context: Data?,
        timeout: TimeInterval = 15
    ) {
        var state = states[peer, default: PeerState()]

        // Cancel any pending attempt for this peer.
        state.pendingTask?.cancel()

        let delay = min(baseDelay * pow(2.0, Double(state.consecutiveFailures)), maxDelay)
        let jitter = TimeInterval.random(in: 0...(delay * 0.25))
        let wait = delay + jitter

        state.consecutiveFailures += 1
        state.nextAttemptAfter = Date().addingTimeInterval(wait)

        state.pendingTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.invite(peer, via: browser, on: session, context: context, timeout: timeout)
        }

        states[peer] = state
    }

    func didConnect(to peer: MCPeerID) {
        states[peer]?.consecutiveFailures = 0
        states[peer]?.pendingTask?.cancel()
        states[peer]?.pendingTask = nil
    }

    func cancelAll() {
        for (_, state) in states { state.pendingTask?.cancel() }
        states.removeAll()
    }

    private func invite(
        _ peer: MCPeerID,
        via browser: MCNearbyServiceBrowser,
        on session: MCSession,
        context: Data?,
        timeout: TimeInterval
    ) {
        guard session.connectedPeers.first(where: { $0 == peer }) == nil else { return }
        browser.invitePeer(peer, to: session, withContext: context, timeout: timeout)
    }
}
