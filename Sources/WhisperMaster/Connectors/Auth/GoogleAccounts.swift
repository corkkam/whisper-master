import Foundation

/// The Google accounts this Mac already holds a grant for.
///
/// Connectors keep **one grant each** — a Gmail connection and a Calendar connection to
/// the same mailbox are separate Keychain items with separate refresh tokens, so either
/// can be removed without breaking the other, and neither silently inherits the other's
/// scopes.
///
/// What is reused is the *consent*, not the credential: knowing the address lets the
/// second connection run incremental authorization (`OAuthPKCEFlow.AccountChoice.reuse`)
/// against the account already signed in, so Google asks only for the scopes that are
/// new instead of walking the user through picking an account and signing in again.
///
/// Pure, and separate from the store so it can be tested without one.
enum GoogleAccounts {
    /// Addresses of every instance connected through the app's own Google sign-in,
    /// newest connection first, deduplicated case-insensitively.
    ///
    /// Reads `identity` rather than `label`: the label is user-editable and often
    /// "Work", while `identity` is what the provider itself reported at connect, which
    /// is the only thing `login_hint` can be built from.
    static func connected(in instances: [ConnectorInstance]) -> [String] {
        var seen = Set<String>()
        var accounts: [String] = []
        for instance in instances.sorted(by: { $0.connectedAt > $1.connectedAt })
        where instance.config.isManagedGoogleGrant {
            let address = instance.identity.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty, seen.insert(address.lowercased()).inserted else { continue }
            accounts.append(address)
        }
        return accounts
    }

    /// Whether `kind` already has a connection to `address` — the duplicate check each
    /// sign-in runs before it stores anything.
    ///
    /// Scoped to one kind on purpose: the same address connected for mail *and* for
    /// calendar is two legitimate connections, not a duplicate.
    static func isAlreadyConnected(_ address: String,
                                   kind: ConnectorKind,
                                   in instances: [ConnectorInstance]) -> Bool {
        instances.contains {
            $0.kind == kind
                && $0.config.isManagedGoogleGrant
                && $0.identity.compare(address, options: .caseInsensitive) == .orderedSame
        }
    }
}
