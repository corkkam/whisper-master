import SwiftUI

/// Shown briefly in the notch after a spoken command (fn + control) is carried out —
/// "Note saved", "Reminder set for 5:00 PM", or the assistant's own report of what it
/// did ("Two meetings today", "Posted to #ops").
///
/// Because the command path suppresses the paste, this band is the *whole* of the
/// response: the words went somewhere the user can't see, so this is where they find
/// out where. The icon and the second line come from what actually happened rather
/// than from what the model said, so a checkmark never claims a save that didn't
/// occur.
struct NotchCommandConfirmationBanner: View {
    let message: String
    var detail: String = "Saved to Notes & Reminders"
    var icon: String = "checkmark.circle.fill"

    var body: some View {
        NotchBannerRow(
            icon: icon,
            title: message,
            subtitle: detail
        )
    }
}
