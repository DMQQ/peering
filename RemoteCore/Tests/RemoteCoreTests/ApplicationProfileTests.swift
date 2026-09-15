import Foundation
import Testing

@testable import RemoteCore

@Suite("ApplicationActions")
struct ApplicationActionsTests {
    /// The common case, and the one that must not misbehave: an app nobody has written a profile
    /// for keeps the client's own macros, and a lookup that invented something for it would be
    /// worse than one that finds nothing.
    @Test("an application with no profile resolves to nil")
    func unknownApplication() {
        #expect(ApplicationActions.profile(forBundleID: "com.example.something") == nil)
        #expect(ApplicationActions.profile(forBundleID: nil) == nil)
        #expect(ApplicationActions.profile(forBundleID: "") == nil)
    }

    @Test("a known application resolves to its own profile")
    func knownApplication() {
        let terminal = ApplicationActions.profile(forBundleID: "com.apple.Terminal")
        #expect(terminal?.name == "Terminal")
        #expect(terminal?.bundleID == "com.apple.Terminal")
        #expect(terminal?.actions.isEmpty == false)
    }

    /// The table is a list folded into a dictionary keyed by each row's own `bundleID`. A row
    /// whose id and key disagreed would be a profile that exists and can never be found, which
    /// is the kind of mistake a lookup table hides until someone asks for it by name.
    @Test("every profile is reachable by its own bundle identifier")
    func tableIsKeyedCorrectly() {
        let all = ApplicationActions.known
        #expect(all.isEmpty == false)
        for profile in all {
            #expect(ApplicationActions.profile(forBundleID: profile.bundleID)?.name == profile.name)
        }
    }

    @Test("bundle identifiers are unique")
    func bundleIdentifiersAreUnique() {
        let ids = ApplicationActions.known.map(\.bundleID)
        #expect(Set(ids).count == ids.count)
    }

    /// The client keys its buttons by action id, so a duplicate inside one profile would make
    /// two different keystrokes the same button — and the wrong one would be the one that stuck.
    @Test("action ids are unique within a profile")
    func actionIDsAreUniqueWithinAProfile() {
        for profile in ApplicationActions.known {
            let ids = profile.actions.map(\.id)
            #expect(Set(ids).count == ids.count)
        }
    }

    /// A title is the keystroke and a detail is why anyone would press it. Both are shown, so
    /// neither can be left empty without the button reading as a bug.
    @Test("every action has something to show")
    func actionsAreLabelled() {
        for profile in ApplicationActions.known {
            #expect(profile.name.isEmpty == false)
            for action in profile.actions {
                #expect(action.title.isEmpty == false)
                #expect(action.detail.isEmpty == false)
            }
        }
    }

    /// Keycodes here are macOS virtual keycodes, the same convention the client's macros use.
    /// A character or a USB HID usage smuggled in among them would send a different key than
    /// the one the title promises, on a machine nobody is looking at.
    @Test("terminal actions use control modifiers and command actions use command")
    func modifiersMatchTheApplication() {
        let terminal = ApplicationActions.profile(forBundleID: "com.apple.Terminal")
        let control = terminal?.actions.filter { $0.modifiers == .control } ?? []
        #expect(control.count >= 6)

        let xcode = ApplicationActions.profile(forBundleID: "com.apple.dt.Xcode")
        let build = xcode?.actions.first { $0.id == "xcode.build" }
        #expect(build?.keyCode == 11)
        #expect(build?.modifiers == .command)
    }
}
