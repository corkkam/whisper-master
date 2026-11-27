import SwiftUI

/// The one-time consent for `delegate_task` to start a Crew task (`CrewRuns`). Dev
/// builds only, in the Crew card. Nothing is offered to the model until the user agrees.
struct CrewHandOffRow: View {
    @Bindable var state: AppState
    @State private var showingConsent = false

    var body: some View {
        SettingsRow(
            "Hand tasks to the Crew",
            subtitle: subtitle
        ) {
            if state.crewHandOffAllowed {
                Button("Revoke") { state.crewHandOffAllowed = false }
                    .textButton()
            } else {
                Button("Review and allow\u{2026}") { showingConsent = true }
                    .secondaryButton()
            }
        }
        .sheet(isPresented: $showingConsent) {
            AgentEndpointConsentSheet(
                host: "the Crew",
                intro: "When you hold fn + control, the assistant can start a Crew task with "
                    + "crew run, in the Crew project the faces show. The Crew runs Claude Code, "
                    + "which sends the task to Anthropic under your own account, and Anthropic's "
                    + "terms and retention apply. What the agents read in that project while they "
                    + "work goes there too.",
                sentItems: [
                    "The task, as the assistant wrote it from what you said.",
                    "Your answer to a Crew question, when you speak one.",
                ],
                neverSentItems: AgentEndpointConsentSheet.neverSent
                    + ["Your sign-in. The app never reads Claude Code's login."],
                footer: "Each task waits for your Once on the notch. The Crew's agents run tools "
                    + "with no card of their own: the Crew's guard and its autonomy level decide "
                    + "where a task stops for you. Stop all Crew runs is in this card.",
                onAllow: {
                    state.crewHandOffAllowed = true
                    showingConsent = false
                },
                onCancel: { showingConsent = false })
        }
    }

    private var subtitle: String {
        guard state.crewFacesEnabled else { return "Turn on Show Crew faces first. The task goes to that crew." }
        guard let project = state.agents.crew.project else {
            return "No Crew project yet. Run one crew task in a project once."
        }
        return state.crewHandOffAllowed
            ? "With fn + control, the assistant can start a task in \(AgentSession.repoName(fromPath: project)). "
                + "Its questions and answers show on the notch."
            : "Nothing is sent until you review what goes to the Crew and allow it."
    }
}
