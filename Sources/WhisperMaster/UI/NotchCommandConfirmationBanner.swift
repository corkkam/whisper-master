import SwiftUI

/// Shown briefly in the notch after a spoken command lands in Notes & Reminders
/// ("Note saved", "Reminder set for 5:00 PM"). Because the command path suppresses
/// the paste, this is the only feedback the user gets, so it confirms the words
/// went somewhere. Non-interactive — it appears for a moment and retracts.
struct NotchCommandConfirmationBanner: View {
    let message: String

    var body: some View {
        NotchBannerRow(
            icon: "checkmark.circle.fill",
            title: message,
            subtitle: "Saved to Notes & Reminders"
        )
    }
}
