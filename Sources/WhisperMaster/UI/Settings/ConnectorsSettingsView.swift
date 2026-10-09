import SwiftUI

/// Connectors screen: a "Connected" grid and an "Available" grid of glass tiles.
/// Honest about state — Calendar is real (EventKit); the rest show "Needs setup"
/// once switched on, because there's no backend behind them yet.
struct ConnectorsSettingsView: View {
    @Bindable var connectors: ConnectorStore

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            let connected = connectors.connected
            if !connected.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel("Connected")
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(connected) { kind in
                            ConnectorTile(kind: kind, connectors: connectors)
                        }
                    }
                }
            }

            let available = connectors.available
            if !available.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel("Available")
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(available) { kind in
                            ConnectorTile(kind: kind, connectors: connectors)
                        }
                    }
                }
            }
        }
    }
}

private struct ConnectorTile: View {
    let kind: ConnectorKind
    @Bindable var connectors: ConnectorStore

    private var isConnected: Bool { connectors.isConnected(kind) }
    private var needsSetup: Bool { connectors.needsSetup(kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(kind.tint.opacity(0.16))
                    Image(systemName: kind.iconSystemName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(kind.tint)
                }
                .frame(width: 42, height: 42)
                Spacer(minLength: 0)
                statusBadge
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(kind.title)
                    .font(Typography.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(kind.subtitle)
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)
            actionButton
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .padding(16)
        .glassCard()
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isConnected && !needsSetup {
            badge("Connected", color: Theme.success, filled: true)
        } else if needsSetup {
            badge("Needs setup", color: Theme.accent, filled: false)
        } else if kind == .calendar && connectors.calendar.authorizationStatus == .denied {
            badge("Denied", color: Theme.danger, filled: false)
        }
    }

    private func badge(_ text: String, color: Color, filled: Bool) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(Typography.sans(10.5, .semibold)).foregroundStyle(color)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(filled ? 0.14 : 0.1)))
    }

    @ViewBuilder
    private var actionButton: some View {
        if !isConnected {
            PrimaryButton(title: connectButtonTitle, icon: kind == .calendar ? nil : "plus") {
                Task { await connectors.connect(kind) }
            }
        } else if kind == .calendar {
            SecondaryButton(title: "Manage in System Settings", icon: "arrow.up.right") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    NSWorkspace.shared.open(url)
                }
            }
        } else {
            SecondaryButton(title: "Disconnect") { connectors.disconnect(kind) }
        }
    }

    private var connectButtonTitle: String {
        if kind == .calendar {
            return connectors.calendar.isUndetermined ? "Connect" : "Grant access"
        }
        return "Connect"
    }
}
