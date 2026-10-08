import RemoteCore
import XCTest
@testable import MacCastKit

/// The picker's grouping and the mismatches where it could drop a window quietly.
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
        XCTAssertEqual(groups[0].application?.source, .application(10))
    }

    func testAWindowWhoseApplicationIsNotOfferedIsStillShown() {
        // The host filters apps and windows on different terms; dropping the window would hide something capturable.
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
        // The host refuses an application with no windows, so an empty heading could not work.
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
        // The host's own fallback when it decides two rows are the same application.
        let groups = SourceGrouping.applicationGroups(
            applications: [application("Peering", bundle: nil, pid: 20)],
            windows: [window("Overlay", of: "Peering", bundle: nil, id: 7)]
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].application?.source, .application(20))
        XCTAssertEqual(groups[0].windows.count, 1)
    }

    func testAWindowWithNoOwnerAtAllStillLandsSomewhere() {
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
        // Matched on bundle identifier, not position: a missing row must not make the next adopt its windows.
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
