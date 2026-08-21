import XCTest

@testable import WhisperMaster

/// The public host is written down in several places and they must agree.
///
/// `CLAUDE.md` has said so for a long time; nothing enforced it, and the drift is
/// silent in the worst possible way — an upload succeeds against one bucket while
/// the shipped binary reads another, so the artifact is a 404 to every user and
/// nothing anywhere reports an error. That is precisely how `s1-mini-4bit.zip`
/// came to be published somewhere the app never looks.
///
/// These two are compiled in, so a test can hold them together. The other two —
/// `Scripts/channel.sh` and `.env`'s `R2_PUBLIC_BASE_URL` — are shell, and are
/// covered by the host-mismatch abort at the top of `Scripts/release.sh`.
final class DistributionHostTests: XCTestCase {

    private func host(of urlString: String) -> String? {
        URL(string: urlString)?.host
    }

    func testTheModelMirrorAndTheUpdateFeedShareOneHost() {
        let feed = UpdateChannel.stable.feedURLString
        guard let feedHost = host(of: feed) else {
            return XCTFail("update feed is not a URL: \(feed)")
        }
        guard let mirrorHost = ModelInstaller.mirrorBaseURL.host else {
            return XCTFail("model mirror base URL has no host")
        }
        XCTAssertEqual(
            mirrorHost, feedHost,
            "models and updates must come from the same bucket — a split is invisible "
                + "until users get a 404")
    }

    /// Every channel's feed, not just stable: a beta pointed at a different host
    /// would strand exactly the people testing a release.
    func testEveryChannelFeedUsesThatSameHost() {
        let hosts = Set(UpdateChannel.allCases.compactMap { host(of: $0.feedURLString) })
        XCTAssertEqual(hosts.count, 1, "all channels share one host; found \(hosts)")
    }

    /// A plain-HTTP or hostless mirror would mean model archives fetched without
    /// TLS. The checksum pin makes tampering detectable, not impossible to attempt.
    func testTheMirrorIsHTTPS() {
        XCTAssertTrue(
            ModelInstaller.mirrorBaseURL.scheme == "https",
            "model archives are fetched over TLS")
    }
}
