import SwiftUI

/// Settings → Coding agents → "Agent engine": the switch, what is running, and the
/// buttons. The state comes from `ShedEngineSupervisor`, which checks every 30s.
struct ShedEngineSettingsCard: View {
    @Bindable var engine: ShedEngineSupervisor

    var body: some View {
        SettingsCard {
            SettingsRow(
                "Agent engine",
                subtitle: "Runs Shed, the engine behind your coding agents, on this Mac. "
                    + "It keeps running when the app quits."
            ) {
                ThemeToggle(isOn: $engine.isEnabled, label: "Agent engine")
            }
            RowDivider()
            SettingsRow("Status", subtitle: detail) {
                StatusPill(text: statusText, tone: tone)
            }
            if let port = engine.port {
                RowDivider()
                SettingsRow("Port and version", subtitle: sourceText) {
                    Text("\(port)  \(engine.version?.label ?? "")")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            if engine.source == .installed {
                RowDivider()
                SettingsRow(
                    "Replace with the bundled engine",
                    subtitle: "Stops the separate install (dev.shed.server and dev.shed.tunnel) and runs the "
                        + "bundled engine on the same data. Your password, devices and agents stay."
                ) {
                    SecondaryButton(title: "Replace") { engine.replaceInstalledWithBundled() }
                }
            }
            RowDivider()
            SettingsRow("Maintenance") {
                HStack(spacing: 8) {
                    if engine.source == .bundled {
                        SecondaryButton(title: "Restart engine") { engine.restart() }
                    }
                    SecondaryButton(title: "Open logs") { engine.openLogs() }
                    if engine.source == .bundled {
                        DestructiveButton(title: "Uninstall engine") { engine.uninstall() }
                    }
                }
            }
        }
    }

    private var statusText: String {
        switch engine.state {
        case .off: return "Off"
        case .notInstalled: return "Not installed"
        case .installing: return "Installing"
        case .starting: return "Starting"
        case .running: return "Running"
        case .needsNode: return "Needs Node"
        case .failed: return "Failed"
        }
    }

    private var tone: StatusPill.Tone {
        switch engine.state {
        case .running: return .positive
        case .installing, .starting, .needsNode: return .warning
        case .failed: return .danger
        case .off, .notInstalled: return .neutral
        }
    }

    private var detail: String? {
        switch engine.state {
        case .notInstalled(let m), .installing(let m), .needsNode(let m), .failed(let m): return m
        default: return nil
        }
    }

    private var sourceText: String {
        switch engine.source {
        case .bundled: return "The bundled engine."
        case .installed: return "The separate install in ~/.shed/app."
        case .devCopy: return "A development copy of Shed."
        case .none: return ""
        }
    }
}
