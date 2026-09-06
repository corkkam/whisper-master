import SwiftUI

/// Ask / Auto / Plan for one session, on the band.
///
/// It lives beside the question rather than behind a settings trip because the
/// moment someone wants to stop being asked is the moment they are being asked. One
/// tap here and the rest of the turn stops interrupting.
///
/// **Auto is not "approve everything".** It trades the approval card for the turn
/// undo, which is only an honest trade because kunai snapshots the working tree
/// before every turn. That is why the control carries `explanation` and why
/// `bypassPermissions` is not one of the options: it would trade the card for
/// nothing.
struct AgentModeControl: View {
    let mode: KunaiWire.PermissionMode
    let onSelect: (KunaiWire.PermissionMode) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(KunaiWire.PermissionMode.allCases) { option in
                Button(option.label) { onSelect(option) }
                    .buttonStyle(.plain)
                    .font(Typography.notchCaption)
                    .foregroundStyle(
                        option == mode ? Theme.Notch.text : Theme.Notch.textTertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Theme.Notch.text.opacity(option == mode ? 0.16 : 0)))
                    .pointerCursor()
                    .accessibilityLabel("\(option.label). \(option.explanation)")
                    .accessibilityAddTraits(option == mode ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.Notch.text.opacity(0.05)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Permission mode")
    }
}
