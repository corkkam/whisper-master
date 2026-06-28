import SwiftUI

/// The mesh panel: this Mac plus other Macs running Whisper Master on the
/// network, with privacy-safe generic names and each Mac's current load.
/// Latency and Bluetooth proximity arrive in later steps.
struct MeshSettingsView: View {
    let viewModel: DictationViewModel
    @Bindable var state: AppState

    private var peers: [MeshPeer] { state.meshPeers }
    private var others: [MeshPeer] { peers.filter { !$0.isSelf } }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            summary
            roster
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: peers)
    }

    // MARK: Summary

    private var summary: some View {
        SettingsCard(boxed: true, contentPadding: 18) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summaryHeadline)
                        .font(Typography.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Macs on this Wi-Fi share transcription. Your name is never shared — each Mac shows up generically.")
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    private var summaryHeadline: String {
        switch others.count {
        case 0: return "No other Macs nearby"
        case 1: return "1 other Mac nearby"
        default: return "\(others.count) other Macs nearby"
        }
    }

    // MARK: Roster

    private var roster: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("On this network")
            SettingsCard {
                ForEach(Array(peers.enumerated()), id: \.element.id) { index, peer in
                    PeerRow(peer: peer)
                    if index < peers.count - 1 { RowDivider() }
                }
                if others.isEmpty {
                    RowDivider()
                    scanningRow
                }
            }
        }
    }

    private var scanningRow: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Looking for other Macs on your Wi-Fi…")
                .font(Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 15)
    }
}

// MARK: - Peer row

private struct PeerRow: View {
    let peer: MeshPeer

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: Self.icon(for: peer.modelFamily))
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(peer.isSelf ? Theme.textTertiary : Theme.accent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(peer.displayName)
                    .font(Typography.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(loadCaption)
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                if !peer.isSelf, peer.proximity != .unknown {
                    proximityBadge
                        .transition(.opacity)
                }
                if !peer.isSelf, let latency = peer.latencyMs {
                    Text("\(latency) ms")
                        .font(Typography.monoSmall)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.surfaceSunken)
                        )
                        .transition(.opacity)
                }
                HStack(spacing: 8) {
                    StatusDot(color: peer.isSelf ? Theme.textTertiary : Theme.success, size: 8)
                    Text(peer.isSelf ? "This Mac" : "Reachable")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.vertical, 15)
    }

    private var proximityBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 10, weight: .semibold))
            Text(proximityLabel)
                .font(Typography.caption)
        }
        .foregroundStyle(proximityColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(proximityColor.opacity(0.12))
        )
    }

    private var proximityLabel: String {
        switch peer.proximity {
        case .near: return "Near"
        case .medium: return "Nearby"
        case .far: return "Far"
        case .unknown: return ""
        }
    }

    private var proximityColor: Color {
        switch peer.proximity {
        case .near: return Theme.success
        case .medium: return Theme.accent
        case .far, .unknown: return Theme.textTertiary
        }
    }

    private var loadCaption: String {
        switch peer.load {
        case 0: return "Idle"
        case 1: return "1 dictation in progress"
        default: return "\(peer.load) dictations in progress"
        }
    }

    private static func icon(for modelFamily: String) -> String {
        if modelFamily.hasPrefix("MacBook") { return "laptopcomputer" }
        if modelFamily == "Mac mini" { return "macmini" }
        if modelFamily.hasPrefix("iMac") { return "desktopcomputer" }
        return "desktopcomputer"
    }
}
