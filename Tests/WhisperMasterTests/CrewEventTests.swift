import XCTest

@testable import WhisperMaster

/// A fixed instant for the Crew tests: `crewDate("2026-11-27T14:00:00.000Z")`.
func crewDate(_ text: String) -> Date {
    CrewEvent.parse(text) ?? Date(timeIntervalSince1970: 0)
}

/// The 10 golden lines as events.
func crewGoldenList() -> [CrewEvent] {
    crewGoldenEvents.split(separator: "\n").compactMap { CrewEvent.decode(line: String($0)) }
}

final class CrewEventTests: XCTestCase {

    func testEveryGoldenLineDecodes() {
        let lines = crewGoldenEvents.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 10)
        for line in lines {
            XCTAssertNotNil(CrewEvent.decode(line: line), line)
        }
    }

    func testFirstGoldenLineFields() throws {
        let line = try XCTUnwrap(crewGoldenEvents.split(separator: "\n").first.map(String.init))
        let e = try XCTUnwrap(CrewEvent.decode(line: line))
        XCTAssertEqual(e.v, 1)
        XCTAssertEqual(e.ts, crewDate("2026-11-27T14:00:00.000Z"))
        XCTAssertEqual(e.src, "crew")
        XCTAssertEqual(e.event, "run.start")
        XCTAssertEqual(e.session, "s1")
        XCTAssertEqual(e.agent, "juno")
        XCTAssertEqual(e.project, "/tmp/crew-golden")
        XCTAssertNil(e.tool)
        XCTAssertNil(e.kind)
        XCTAssertNil(e.note)
        XCTAssertEqual(e.agents, [])
    }

    func testHuddleLineKeepsAgents() {
        let list = crewGoldenList()
        XCTAssertEqual(list[2].event, "huddle.start")
        XCTAssertEqual(list[2].agents, ["pm", "c-input"])
        XCTAssertEqual(list[9].tool, "Bash")
        XCTAssertEqual(list[9].kind, "test")
    }

    func testFractionalSecondsAreKept() throws {
        let line = #"{"v":1,"ts":"2026-11-27T14:05:01.120Z","src":"claude","event":"tool.start","session":null,"agent":"c-input","project":"/p","tool":"Bash","kind":"test","note":null,"agents":[]}"#
        let e = try XCTUnwrap(CrewEvent.decode(line: line))
        XCTAssertEqual(e.ts.timeIntervalSince(crewDate("2026-11-27T14:05:01.000Z")), 0.12, accuracy: 0.001)
        XCTAssertNil(e.session)
    }

    func testBadLinesAreRejected() {
        XCTAssertNil(CrewEvent.decode(line: ""))
        XCTAssertNil(CrewEvent.decode(line: "not json"))
        XCTAssertNil(CrewEvent.decode(line: #"{"v":1,"ts":"2026-11-27T14:00:00.000Z""#))
        XCTAssertNil(CrewEvent.decode(line: #"{"v":1,"ts":"yesterday","event":"prompt","agent":"a","project":"/p"}"#))
        XCTAssertNil(CrewEvent.decode(line: #"{"v":1,"event":"prompt","agent":"a","project":"/p"}"#))
    }

    func testOtherVersionIsRejected() {
        let line = #"{"v":2,"ts":"2026-11-27T14:00:00.000Z","src":"crew","event":"prompt","session":null,"agent":"a","project":"/p","tool":null,"kind":null,"note":null,"agents":[]}"#
        XCTAssertNil(CrewEvent.decode(line: line))
    }

    func testUnknownKeyIsIgnored() throws {
        let line = #"{"v":1,"ts":"2026-11-27T14:00:00.000Z","src":"crew","event":"prompt","session":null,"agent":"a","project":"/p","tool":null,"kind":null,"note":null,"agents":[],"future":{"x":1}}"#
        let e = try XCTUnwrap(CrewEvent.decode(line: line))
        XCTAssertEqual(e.agent, "a")
    }

    func testUnknownEventNameStillDecodes() throws {
        let line = #"{"v":1,"ts":"2026-11-27T14:00:00.000Z","src":"crew","event":"brand.new","session":null,"agent":"a","project":"/p","tool":null,"kind":null,"note":null,"agents":[]}"#
        XCTAssertEqual(try XCTUnwrap(CrewEvent.decode(line: line)).event, "brand.new")
    }

    func testEncodeThenDecodeRoundTrips() throws {
        let e = CrewEvent(
            ts: crewDate("2026-11-27T14:00:05.250Z"), src: "claude", event: "huddle.start",
            session: "s9", agent: "lead", project: "/p", note: "ok", agents: ["pm", "qa"])
        let data = try JSONEncoder().encode(e)
        let line = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(line.contains("2026-11-27T14:00:05.250Z"))
        XCTAssertEqual(CrewEvent.decode(line: line), e)
    }
}
