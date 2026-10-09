import Foundation
import Observation

/// The signed-in identity used for the greeting and the sidebar account row.
///
/// Whisper Master is a local-first, on-device app with no backend, so this is a
/// **self-contained local account**, not a real cloud identity provider — no
/// network, no credentials verified anywhere. It stores a name/email the user
/// enters (or a guest identity) so the UI can greet them and show a plan label;
/// signing out just clears it. (If a real provider like Clerk is ever added,
/// this is the seam to swap it behind.)
@MainActor
@Observable
final class AccountStore {
    static let defaultsKey = "WhisperMaster.account.v1"

    struct Account: Codable, Equatable {
        var fullName: String
        var email: String
        /// A guest chose "continue without an account".
        var isGuest: Bool
    }

    private(set) var account: Account?

    init() {
        account = Self.load()
    }

    var isSignedIn: Bool { account != nil }

    /// First name for the greeting; a friendly default when signed out / guest.
    var firstName: String {
        guard let name = account?.fullName.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return "there"
        }
        return name.split(separator: " ").first.map(String.init) ?? name
    }

    var displayName: String {
        if let account, !account.fullName.trimmingCharacters(in: .whitespaces).isEmpty {
            return account.fullName
        }
        return account?.isGuest == true ? "Guest" : "Not signed in"
    }

    /// Shown under the name in the sidebar — honest about the on-device model.
    var planLabel: String { "Pro · on-device" }

    /// Two-letter monogram for the avatar.
    var initials: String {
        let parts = displayName.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }
        let joined = String(letters).uppercased()
        return joined.isEmpty ? "?" : joined
    }

    func signIn(name: String, email: String) {
        account = Account(
            fullName: name.trimmingCharacters(in: .whitespacesAndNewlines),
            email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            isGuest: false
        )
        persist()
    }

    func continueAsGuest() {
        account = Account(fullName: "Guest", email: "", isGuest: true)
        persist()
    }

    func signOut() {
        account = nil
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }

    private func persist() {
        guard let account, let data = try? JSONEncoder().encode(account) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private static func load() -> Account? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(Account.self, from: data)
    }
}
