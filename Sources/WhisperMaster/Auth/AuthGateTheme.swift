import ClerkKitUI
import SwiftUI

/// Whisper Master's appearance for ClerkKitUI's prebuilt views.
///
/// `AuthView` renders the sign-in card itself, so without this it arrives in
/// Clerk's stock palette (violet primary, system font, 6pt radii) sitting in the
/// middle of our window — the one surface in the app that looked like someone
/// else's product. Every value here is a `Theme` token, so the card carries the
/// app's accent semantics: **ember for the primary action** (the thing you do)
/// and **signal for focus** (the machine answering), never the reverse.
///
/// Only the tokens Clerk exposes are set — it derives borders, pressed states and
/// state tints from these (`ClerkTheme.Colors.init`), so these have to be the
/// ground-safe cuts: everything is measured against the app's one paper ground.
@MainActor
enum ClerkAppearance {
    static let theme = ClerkTheme(
        colors: colors,
        fonts: fonts,
        // Clerk uses one radius for fields and buttons alike; `controlRadius` is
        // the app's input-well radius, and it nests correctly inside the card's
        // `panelRadius`. Buttons here are soft rects rather than the ladder's
        // capsules — that's Clerk's geometry, and matching the card it sits in
        // reads better than a pill it can't quite make.
        design: .init(borderRadius: Theme.controlRadius)
    )

    private static var colors: ClerkTheme.Colors {
        .init(
            primary: Theme.Ember.base,
            // The card's own fill. Opaque on purpose: Clerk paints this behind
            // every step of the flow, and a translucent value would let two
            // screens show through each other during a navigation push.
            background: Theme.surface,
            input: Theme.surfaceSunken,
            danger: Theme.danger,
            success: Theme.accent2,
            warning: Theme.warning,
            foreground: Theme.textPrimary,
            mutedForeground: Theme.textTertiary,
            primaryForeground: Theme.Ember.on,
            inputForeground: Theme.textPrimary,
            // Clerk generates its neutral shades from this, and asks for a dark
            // value on a light ground — which is exactly what the state-layer
            // tint already is.
            neutral: Theme.StateLayer.tint,
            // Focus is the machine acknowledging you, so it's signal. Clerk draws
            // it at 28% opacity, so this has to be the ground-safe cut rather
            // than the vivid hue or it disappears on paper.
            ring: Theme.accent2,
            muted: Theme.surfaceSunken,
            secondaryButtonBackground: Theme.surfaceGlass2,
            secondaryButtonForeground: Theme.textPrimary,
            shadow: Color(hex: 0x1a2233),
            border: Theme.StateLayer.tint
        )
    }

    /// Bricolage Grotesque for the card's title, Instrument Sans for everything
    /// else — the app's pairing. Body sits at 15 rather than the app's 14: Clerk's
    /// floating field label shrinks from the body size, and 14 left it undersized.
    private static var fonts: ClerkTheme.Fonts {
        .init(
            largeTitle: Typography.heading(30, .heavy, relativeTo: .largeTitle),
            title: Typography.heading(24, .bold, relativeTo: .title),
            title2: Typography.heading(21, .bold, relativeTo: .title2),
            title3: Typography.heading(18, .semibold, relativeTo: .title3),
            headline: Typography.sans(15, .semibold, relativeTo: .headline),
            subheadline: Typography.sans(13, .regular, relativeTo: .subheadline),
            body: Typography.sans(15, .regular, relativeTo: .body),
            callout: Typography.sans(14, .medium, relativeTo: .callout),
            footnote: Typography.sans(12, .regular, relativeTo: .footnote),
            caption: Typography.sans(12, .medium, relativeTo: .caption),
            caption2: Typography.sans(11, .semibold, relativeTo: .caption2)
        )
    }
}
