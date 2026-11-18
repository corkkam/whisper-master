import AppKit
import SwiftUI
import XCTest

@testable import WhisperMaster

/// The band's one `TimelineView` wraps its frame for the band's whole life. If
/// it were added or removed around a transition, the content's identity would
/// change, which resets the focused button and VoiceOver focus.
@MainActor
final class OnboardingTimelineIdentityTests: XCTestCase {
    private let full = OnboardingMotionPolicy.resolve(
        reduceMotion: false, lowPower: false, thermal: .nominal, voiceOver: false)

    /// The snapshot renderer draws a paused `TimelineView`, so the band keeps
    /// the wrapper under `isSnapshot` too.
    func testImageRendererDrawsAPausedTimelineView() throws {
        let view = TimelineView(.animation(minimumInterval: nil, paused: true)) { _ in
            Color(red: 1, green: 0, blue: 0)
        }
        .frame(width: 4, height: 4)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let pixel = try XCTUnwrap(bitmap.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB))
        // Drawn, not left clear. The colour-space conversion shifts the channels a little.
        XCTAssertGreaterThan(pixel.alphaComponent, 0.9)
        XCTAssertGreaterThan(pixel.redComponent, pixel.greenComponent + 0.5)
    }

    /// The band in a hosting view on a live clock driven by hand: through a beat
    /// change and a grant, and past their ends, its content appears once.
    func testTheBandsContentAppearsOnceAcrossTransitions() {
        var now: TimeInterval = 100
        let permissions = FakePermissions()
        let model = NotchOnboardingModel(
            permissions: permissions,
            capture: FakeCapture(),
            clock: OnboardingClock(now: { now }, isFixed: false),
            engineStatus: { .ready },
            onComplete: { _ in },
            onDismiss: {})
        var appearances = 0
        let host = NSHostingView(rootView: NotchOnboardingView(
            model: model, state: AppState(), onContentAppear: { appearances += 1 }))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 264),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host

        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        settle()
        model.begin(.reveal, policy: full)
        model.introDidEnd()
        settle()
        model.advance()
        settle()
        permissions.trusted = true
        model.refresh()
        XCTAssertNotNil(model.rowChange)
        settle()
        now += 2
        settle()
        XCTAssertGreaterThan(now, model.activeUntil)
        settle()
        XCTAssertEqual(appearances, 1)
        window.contentView = nil
    }
}
