import RemoteCore
import XCTest
@testable import MacCastKit

/// The picker's one grouping, and the cases that make it more than a sort.
///
/// Everything here is a catalogue the host could actually send, and the ones worth having are the
/// mismatches: a window whose application is not offered, an application with no windows, a
/// process with no bundle identifier to match on. Those are the shapes where a grouping drops
/// something quietly, and a picker that has lost a window looks exactly like a Mac with fewer
/// windows.
final class SourceGroupingTests: XCTestCase {
    private func application(
        _ title: String, bundle: String?, pid: Int32 = 1
    ) -> CaptureSourceDescriptor {
        CaptureSourceDescriptor(
            kind: .application,
            title: title,
            bundleIdentifier: bundle,
            source: .application(pid),
            pixelSize: CGSize(width: 800, height: 600)
        )
    }

    private func window(
        _ title: String, of application: String, bundle: String?, id: UInt32
    ) -> CaptureSourceDescriptor {
        CaptureSourceDescriptor(
            kind: .window,
            title: title,
            subtitle: application,
            bundleIdentifier: bundle,
            source: .window(id),
            pixelSize: CGSize(width: 400, height: 300)
        )
    }

    func testWindowsLandUnderTheirApplication() {
        let groups = SourceGrouping.applicationGroups(
            applications: [
                application("Safari", bundle: "com.apple.Safari", pid: 10),
                application("Xcode", bundle: "com.apple.dt.Xcode", pid: 11),
            ],
            windows: [
                window("Docs", of: "Safari", bundle: "com.apple.Safari", id: 1),
                window("News", of: "Safari", bundle: "com.apple.Safari", id: 2),
                window("ContentView.swift", of: "Xcode", bundle: "com.apple.dt.Xcode", id: 3),
            ]
        )

        XCTAssertEqual(groups.map(\.title), ["Safari", "Xcode"])
        XCTAssertEqual(groups[0].windows.map(\.title), ["Docs", "News"])
        XCTAssertEqual(groups[1].windows.map(\.title), ["ContentView.swift"])
        // The group carries the application's own row, which is what makes its heading tappable
        // as the whole application.
        XCTAssertEqual(groups[0].application?.source, .application(10))
    }

    func testAWindowWhoseApplicationIsNotOfferedIsStillShown() {
        // The catalogue can produce this: the host filters its application list for surfaces it
        // will not name, and its window list is filtered on different terms. A grouping that
        // dropped the window would hide something the Mac is willing to capture.
        let groups = SourceGrouping.applicationGroups(
            applications: [application("Safari", bundle: "com.apple.Safari", pid: 10)],
            windows: [
                window("Docs", of: "Safari", bundle: "com.apple.Safari", id: 1),
                window("Floating", of: "Something Else", bundle: "com.example.other", id: 2),
            ]
        )

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[1].title, "Something Else")
        XCTAssertNil(groups[1].application, "no row to select, so the heading is not a control")
        XCTAssertEqual(groups[1].windows.map(\.title), ["Floating"])
    }

    func testAnApplicationWithNoWindowsGetsNoSection() {
        // It could not be captured anyway — the host refuses an application with no windows on
        // any display — so a heading over an empty grid would be a row that cannot work.
        let groups = SourceGrouping.applicationGroups(
            applications: [
                application("Safari", bundle: "com.apple.Safari", pid: 10),
                application("Nothing Open", bundle: "com.example.empty", pid: 12),
            ],
            windows: [window("Docs", of: "Safari", bundle: "com.apple.Safari", id: 1)]
        )

        XCTAssertEqual(groups.map(\.title), ["Safari"])
    }

    func testAProcessWithNoBundleIdentifierIsMatchedByName() {
        // Which is the fallback the host itself uses when it decides two rows are the same
        // application, so the two ends group identically.
        let groups = SourceGrouping.applicationGroups(
            applications: [application("Peering", bundle: nil, pid: 20)],
            windows: [window("Overlay", of: "Peering", bundle: nil, id: 7)]
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].application?.source, .application(20))
        XCTAssertEqual(groups[0].windows.count, 1)
    }

    func testAWindowWithNoOwnerAtAllStillLandsSomewhere() {
        // Both fields the grouping matches on can be absent. The window is still offered by the
        // catalogue, so it still gets a group; what it does not get is a name it was never given.
        let groups = SourceGrouping.applicationGroups(
            applications: [],
            windows: [
                CaptureSourceDescriptor(
                    kind: .window, title: "Untitled", source: .window(9),
                    pixelSize: CGSize(width: 100, height: 100)
                )
            ]
        )

        XCTAssertEqual(groups.map(\.title), ["Windows"])
        XCTAssertNil(groups[0].application)
    }

    func testAnEmptyCatalogueGroupsToNothing() {
        XCTAssertTrue(SourceGrouping.applicationGroups(applications: [], windows: []).isEmpty)
    }

    func testWindowsFromTwoApplicationsWithOneIdentifierDoNotMerge() {
        // Matched on the bundle identifier, not on position or on arrival order: an application
        // list that happens to be missing a row must not make the next one adopt its windows.
        let groups = SourceGrouping.applicationGroups(
            applications: [application("Second", bundle: "com.example.second", pid: 31)],
            windows: [
                window("One", of: "First", bundle: "com.example.first", id: 1),
                window("Two", of: "Second", bundle: "com.example.second", id: 2),
            ]
        )

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map(\.windows.count), [1, 1])
        XCTAssertEqual(groups[1].application?.source, .application(31))
    }
}
