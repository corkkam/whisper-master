import SwiftUI

/// The one-time consent for `delegate_task`: the assistant may hand a task to Claude
/// Code on this Mac (the Desk, `AgentDesk`). Dev builds only, behind the remote tiers'
/// flag. Nothing is offered to the model until the user agrees here.
struct DeskHandOffRow: View {
    @Bindable var state: AppState
    @State private var showingConsent = false

    var body: some View {
        SettingsRow(
            "Hand tasks to Claude Code",
            subtitle: subtitle
        ) {
            if state.deskHandOffAllowed {
                Button("Revoke") { state.deskHandOffAllowed = false }
                    .textButton()
            } else {
                Button("Review and allow\u{2026}") { showingConsent = true }
                    .secondaryButton()
            }
        }
        .sheet(isPresented: $showingConsent) {
            Self.consentSheet(
                onAllow: {
                    state.deskHandOffAllowed = true
                    showingConsent = false
                },
                onCancel: { showingConsent = false })
        }
    }

    private var subtitle: String {
        guard AgentDesk.folder(state.agentDefaultDirectory) != nil else {
            return "Set a project folder first. The assistant's tasks run there."
        }
        return state.deskHandOffAllowed
            ? "With fn + control, the assistant can send a task to Claude Code. You approve each one on the notch."
            : "Nothing is sent until you review what goes to Claude Code and allow it."
    }

    /// The endpoint's sheet, in the Desk's words: what leaves this Mac on a hand-off.
    static func consentSheet(onAllow: @escaping () -> Void,
                             onCancel: @escaping () -> Void) -> AgentEndpointConsentSheet {
        AgentEndpointConsentSheet(
            host: "Claude Code",
            intro: "When you hold fn + control, the assistant can hand a task to a Claude Code "
                + "session on this Mac, through kunai, in your project folder. Claude Code sends "
                + "it to Anthropic under your own account, and Anthropic's terms and retention "
                + "apply. What Claude Code reads in that folder while it works goes there too.",
            sentItems: [
                "The task, as the assistant wrote it from what you said.",
                "Text you selected, when the assistant puts it in the task.",
            ],
            neverSentItems: AgentEndpointConsentSheet.neverSent
                + ["Your sign-in. The app never reads Claude Code's login."],
            footer: "Each task waits for your Once on the notch, and Claude Code asks before each "
                + "tool it runs. An allow rule or a hook in your own Claude Code settings can run "
                + "a tool with no card.",
            onAllow: onAllow,
            onCancel: onCancel)
    }
}
