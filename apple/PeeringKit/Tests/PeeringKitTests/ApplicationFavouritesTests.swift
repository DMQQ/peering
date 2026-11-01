import Foundation
import PeeringKit
import Testing

private struct App: Sendable, Equatable {
    let bundle: String?
}

private func sections(favourites: [String], running: [String?], installed: [String]) -> ApplicationSections<App> {
    ApplicationSections(
        favourites: favourites,
        running: running.map(App.init),
        installed: installed.map(App.init),
        bundleIdentifier: \.bundle
    )
}

@Suite struct ApplicationFavouritesTests {
    private func store() -> ApplicationFavourites {
        let defaults = UserDefaults(suiteName: "ApplicationFavouritesTests.\(UUID().uuidString)") ?? .standard
        return ApplicationFavourites(hostID: "mac", defaults: defaults)
    }

    @Test func togglingAddsInOrderAndRemoves() {
        let favourites = store()
        favourites.toggle("a")
        favourites.toggle("b")
        #expect(favourites.bundleIdentifiers == ["a", "b"])
        favourites.toggle("a")
        #expect(favourites.bundleIdentifiers == ["b"])
        #expect(!favourites.contains("a"))
    }

    @Test func eachMacKeepsItsOwnFavourites() {
        let defaults = UserDefaults(suiteName: "ApplicationFavouritesTests.\(UUID().uuidString)") ?? .standard
        ApplicationFavourites(hostID: "one", defaults: defaults).toggle("a")
        #expect(ApplicationFavourites(hostID: "two", defaults: defaults).bundleIdentifiers.isEmpty)
    }

    @Test func aFavouriteIsShownOnlyInTheTopGroup() {
        let result = sections(favourites: ["b"], running: ["a", "b"], installed: ["a", "b", "c"])
        #expect(result.favourites == [App(bundle: "b")])
        #expect(result.running == [App(bundle: "a")])
        #expect(result.installed == [App(bundle: "c")])
    }

    @Test func favouritesKeepTheirPinnedOrder() {
        let result = sections(favourites: ["c", "a"], running: [], installed: ["a", "b", "c"])
        #expect(result.favourites == [App(bundle: "c"), App(bundle: "a")])
    }

    @Test func aFavouriteNoLongerOnTheMacIsLeftOut() {
        let result = sections(favourites: ["gone"], running: [], installed: ["a"])
        #expect(result.favourites.isEmpty)
        #expect(result.installed == [App(bundle: "a")])
    }

    @Test func aRunningAppWithNoBundleStaysInRunning() {
        let result = sections(favourites: [], running: [nil], installed: [])
        #expect(result.running == [App(bundle: nil)])
    }
}
