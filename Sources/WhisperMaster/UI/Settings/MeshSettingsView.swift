import AppKit
import SwiftUI

/// The mesh panel: this Mac plus other Macs running Whisper Master on the
/// network, with privacy-safe generic names and each Mac's current load.
/// Latency and Bluetooth proximity arrive in later steps.
struct MeshSettingsView: View {
    let viewModel: DictationViewModel
    @Bindable var state: AppState

    /// This Mac's Tailscale status (best-effort, read-only). nil while the `.task`
    /// is still checking.
    @State private var tailscale: TailscaleStatus?
    /// Pairing QR, generated once when an address resolves.
    @State private var qrImage: NSImage?

    private var peers: [MeshPeer] { state.meshPeers }
    private var others: [MeshPeer] { peers.filter { !$0.isSelf } }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            summary
            remoteAccess
            keepAwake
            roster
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: peers)
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: tailscale)
        .task {
            let resolved = await TailscaleAddress.current()
            tailscale = resolved
            if case let .available(endpoint) = resolved {
                qrImage = QRCode.image(from: endpoint.pairingURL)
            }
        }
    }

    // MARK: Reach from anywhere (Tailscale)

    private var remoteAccess: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Reach this Mac from anywhere")
            SettingsCard {
                switch tailscale {
                case .available(let endpoint):
                    pairingContent(endpoint)
                case .notConnected:
                    infoContent(
                        icon: "wifi.slash",
                        title: "Tailscale isn’t connected",
                        message: "Open Tailscale and sign in, then reopen this window to get a pairing code."
                    )
                case .notInstalled:
                    infoContent(
                        icon: "arrow.down.circle",
                        title: "Install Tailscale to dictate from anywhere",
                        message: "Remote dictation uses Tailscale (free). Install it on this Mac and your phone, then a scannable pairing code appears here.",
                        link: (label: "Get Tailscale", url: "https://tailscale.com/download")
                    )
                case nil:
                    checkingContent
                }
            }
        }
    }

    private func pairingContent(_ endpoint: TailscaleEndpoint) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Off your Wi-Fi, pair the phone with this Mac to keep dictating over Tailscale. Scan the code from the phone app, or type the address in by hand.")
                .font(Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .center, spacing: 18) {
                if let qrImage {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 132, height: 132)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Theme.stroke, lineWidth: 1)
                        )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Scan to pair")
                        .font(Typography.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Phone app → Remote Mac → Scan QR code")
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    addressChip(endpoint)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 4)
    }

    private func infoContent(
        icon: String,
        title: String,
        message: String,
        link: (label: String, url: String)? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(Typography.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(message)
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let link, let url = URL(string: link.url) {
                    Link(link.label, destination: url)
                        .font(Typography.label)
                        .foregroundStyle(Theme.accent)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private var checkingContent: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Checking Tailscale…")
                .font(Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }

    private func addressChip(_ endpoint: TailscaleEndpoint) -> some View {
        HStack(spacing: 8) {
            Text(endpoint.display)
                .font(Typography.monoSmall)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(endpoint.display, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .help("Copy address")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surfaceSunken)
        )
    }

    // MARK: Summary

    private var summary: some View {
        SettingsCard(boxed: true, contentPadding: 18) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summaryHeadline)
                        .font(Typography.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Macs on this Wi-Fi share transcription. Your name is never shared. Each Mac shows up generically.")
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

    // MARK: Keep awake

    private var keepAwake: some View {
        SettingsCard {
            SettingsRow("Keep this Mac awake for phone dictation",
                        subtitle: "Stops the Mac from sleeping while idle so your phone can reach it even after the screen locks. Uses more battery; a dictation already in progress keeps the Mac awake on its own.") {
                ThemeToggle(isOn: $state.keepAwakeForRemote)
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
