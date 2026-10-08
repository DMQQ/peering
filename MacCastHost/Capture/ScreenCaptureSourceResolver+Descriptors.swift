import AppKit
import CoreGraphics
import Foundation
import RemoteCore
import ScreenCaptureKit
import os

extension ScreenCaptureSourceResolver {
    static func descriptors(
        from content: SCShareableContent,
        elsewhere: Set<CGWindowID> = []
    ) -> [CaptureSourceDescriptor] {
        // One icon encode per process, shared between an application's row and its windows' rows; the catalogue is rebuilt on every launch and quit.
        var icons = ApplicationIcons()
        let displayRows = displays(from: content)
        let applicationRows = applications(from: content, elsewhere: elsewhere, icons: &icons)
        let windowRows = windows(from: content, elsewhere: elsewhere, icons: &icons)
        return displayRows + applicationRows + windowRows
    }

    /// `NSRunningApplication.icon` can briefly be nil while an app launches; the bundle icon is available earlier.
    static func applicationIcon(for processID: pid_t) -> Data? {
        guard let running = NSRunningApplication(processIdentifier: processID) else { return nil }
        if let data = iconPNGData(for: running) { return data }
        guard let bundleURL = running.bundleURL else { return nil }
        return iconPNGData(for: NSWorkspace.shared.icon(forFile: bundleURL.path))
    }

    private static func displays(from content: SCShareableContent) -> [CaptureSourceDescriptor] {
        content.displays.compactMap { display in
            // `SCDisplay.width`/`height` are points; the pixel mapping needs pixels, or the remote cursor drifts the further it is dragged.
            let pixelWidth = CGDisplayPixelsWide(display.displayID)
            let pixelHeight = CGDisplayPixelsHigh(display.displayID)
            guard pixelWidth > 0, pixelHeight > 0 else { return nil }

            return CaptureSourceDescriptor(
                kind: .display,
                title: screenName(for: display.displayID) ?? "Display \(display.displayID)",
                subtitle: "\(pixelWidth)×\(pixelHeight)",
                source: .display(display.displayID),
                pixelSize: CGSize(width: pixelWidth, height: pixelHeight),
                // Only a display the phone asked for; tells the client which rows it may rename and remove.
                isManagedVirtualDisplay: VirtualDisplay.isPhoneManaged(display.displayID),
                // Exists only in software at all; `VirtualDisplay.name(for:)` is non-nil for exactly those.
                isVirtualDisplay: VirtualDisplay.name(for: display.displayID) != nil
            )
        }
    }

    private static func applications(
        from content: SCShareableContent,
        elsewhere: Set<CGWindowID>,
        icons: inout ApplicationIcons
    ) -> [CaptureSourceDescriptor] {
        var seenBundleIDs = Set<String>()
        var seenNames = Set<String>()
        var result: [CaptureSourceDescriptor] = []

        for application in content.applications {
            let running = NSRunningApplication(processIdentifier: application.processID)
            // ScreenCaptureKit includes agents, menu extras and system surfaces.
            guard running?.activationPolicy == .regular else { continue }
            // A list of identifiers, not a check on bundle location: that would exclude Terminal (`/System/Applications`) and Safari (App cryptex), and these three report a regular activation policy on some macOS versions.
            if let bundleIdentifier = running?.bundleIdentifier,
               Self.isSystemSurface(bundleIdentifier) {
                continue
            }

            let owned = content.windows.filter {
                $0.owningApplication?.processID == application.processID
                    && isUserFacingWindow($0, elsewhere: elsewhere)
            }
            guard let bounds = unionFrame(of: owned) else { continue }

            let title = name(for: application, processID: application.processID)
            let bundleIdentifier = running?.bundleIdentifier
            if let bundleIdentifier {
                guard seenBundleIDs.insert(bundleIdentifier).inserted else { continue }
            } else {
                guard seenNames.insert(title.localizedLowercase).inserted else { continue }
            }

            let scale = backingScale(for: bounds)
            let iconData = icons.icon(for: application.processID)

            result.append(CaptureSourceDescriptor(
                kind: .application,
                // Not `application.applicationName` directly: it is empty for some processes, leaving an unidentifiable blank cell.
                title: title,
                subtitle: owned.count == 1 ? "1 window" : "\(owned.count) windows",
                bundleIdentifier: bundleIdentifier,
                iconPNGData: iconData,
                source: .application(application.processID),
                pixelSize: CGSize(width: bounds.width * scale, height: bounds.height * scale)
            ))
        }

        return result.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// A name for an application that is never empty.
    ///
    /// ScreenCaptureKit's own name is preferred, since it is what the application calls itself.
    /// The fallbacks go through `NSRunningApplication` and only then name it by pid, which is the
    /// identity the client sends back: never wrong, just less readable. An empty string is
    /// unusable.
    private static func name(for application: SCRunningApplication, processID: pid_t) -> String {
        let candidates = [
            application.applicationName,
            NSRunningApplication(processIdentifier: processID)?.localizedName,
            NSRunningApplication(processIdentifier: processID)?.bundleIdentifier,
        ]
        for candidate in candidates {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return "Application \(processID)"
    }

    private static func windows(
        from content: SCShareableContent,
        elsewhere: Set<CGWindowID>,
        icons: inout ApplicationIcons
    ) -> [CaptureSourceDescriptor] {
        var result: [CaptureSourceDescriptor] = []

        for window in content.windows {
            guard isUserFacingWindow(window, elsewhere: elsewhere) else { continue }
            guard let application = window.owningApplication, let bounds = unionFrame(of: [window]) else {
                continue
            }
            let running = NSRunningApplication(processIdentifier: application.processID)
            guard running?.activationPolicy == .regular else { continue }

            let title = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? application.applicationName
            let scale = backingScale(for: bounds)

            result.append(CaptureSourceDescriptor(
                kind: .window,
                title: title,
                subtitle: application.applicationName,
                bundleIdentifier: running?.bundleIdentifier,
                iconPNGData: icons.icon(for: application.processID),
                source: .window(window.windowID),
                pixelSize: CGSize(width: bounds.width * scale, height: bounds.height * scale)
            ))
        }

        return result.sorted { lhs, rhs in
            let applicationOrder = (lhs.subtitle ?? "").localizedStandardCompare(rhs.subtitle ?? "")
            if applicationOrder != .orderedSame { return applicationOrder == .orderedAscending }

            let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    /// On screen, or in `elsewhere` (open on a desktop that is not showing, which still streams). A closed-but-unreleased or minimised window is neither; ScreenCaptureKit lists both and renders neither.
    static func isUserFacingWindow(_ window: SCWindow, elsewhere: Set<CGWindowID> = []) -> Bool {
        guard window.windowLayer == 0,
              window.isOnScreen || elsewhere.contains(window.windowID),
              window.frame.width >= 1,
              window.frame.height >= 1
        else { return false }
        // By owner too: system surfaces report a regular activation policy and own windows that look ordinary, so the application rows' rule applies here as well.
        if let bundleIdentifier = NSRunningApplication(
            processIdentifier: window.owningApplication?.processID ?? 0
        )?.bundleIdentifier, isSystemSurface(bundleIdentifier) {
            return false
        }
        return !isNamelessSurface(window)
    }

    /// A net under ``isSystemSurface(_:)``: a regular application's untitled surface. Such a surface lists and photographs black and a stream for it says nothing, leaving an unpressable picker row (a Dictionary window titled "Window").
    /// Matched as a set of localised words ("Fenêtre" on a French Mac); only the standalone word counts, so "Window Manager" is left alone.
    private static func isNamelessSurface(_ window: SCWindow) -> Bool {
        guard let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return systemWindowTitles.contains(title.lowercased())
    }

    private static let systemWindowTitles: Set<String> = [
        "window", "fenêtre", "fenster", "ventana", "finestra", "venster", "okno", "ikkuna",
    ]

    /// A short identifier list plus a name pattern: `<Name>UIService` processes (lookup popovers, share sheets) own untitled windows and cannot be enumerated. Traced with ``Tools/CaptureProbe`` from `LinkedNotesUIService`, a 254x254 "Window" on layer 25. See ``isNamelessSurface(_:)``.
    private static func isSystemSurface(_ bundleIdentifier: String) -> Bool {
        systemSurfaces.contains(bundleIdentifier) || bundleIdentifier.hasSuffix("UIService")
    }

    /// Regular by activation policy, and not applications.
    private static let systemSurfaces: Set<String> = [
        "com.apple.controlcenter",
        "com.apple.wallpaper.agent",
        "com.apple.WindowManager",
    ]

    static func installedApplications() -> [InstalledApplicationDescriptor] {
        // The system domain is where Terminal (`/System/Applications`) and Safari (App cryptex) live; a symlink in `/Applications` does not lead an enumerator there.
        let roots = FileManager.default.urls(
            for: .applicationDirectory,
            in: [.localDomainMask, .userDomainMask, .systemDomainMask]
        )
        var byBundleIdentifier: [String: InstalledApplicationDescriptor] = [:]

        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isApplicationKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator where url.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame {
                guard let bundle = Bundle(url: url),
                      let bundleIdentifier = bundle.bundleIdentifier,
                      !bundleIdentifier.isEmpty,
                      bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool != true,
                      bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool != true
                else { continue }

                let title = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                guard !title.isEmpty else { continue }

                let icon = NSWorkspace.shared.icon(forFile: url.path)
                byBundleIdentifier[bundleIdentifier] = InstalledApplicationDescriptor(
                    bundleIdentifier: bundleIdentifier,
                    title: title,
                    iconPNGData: iconPNGData(for: icon)
                )
            }
        }

        return byBundleIdentifier.values.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private static func iconPNGData(for application: NSRunningApplication) -> Data? {
        guard let icon = application.icon else { return nil }
        return iconPNGData(for: icon)
    }

    /// Downsamples before PNG encoding: a 1024-point icon would cost megabytes of control-channel data. 128 pixels, since the grid draws 74 points at three times the pixels and 48 read as a blurred square.
    private static func iconPNGData(for icon: NSImage) -> Data? {
        let dimension = 128
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: dimension,
                height: dimension,
                bitsPerComponent: 8,
                bytesPerRow: dimension * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        var proposedRect = CGRect(x: 0, y: 0, width: dimension, height: dimension)
        guard let source = icon.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(source, in: proposedRect)
        guard let scaled = context.makeImage() else { return nil }
        let data = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
        guard let data, data.count <= CaptureSourceDescriptor.maximumIconByteCount else { return nil }
        return data
    }

    /// A degenerate frame means minimised or off-screen; its zero size would divide by zero in the coordinate mapping.
    static func unionFrame(of windows: [SCWindow]) -> CGRect? {
        let frames = windows.map(\.frame).filter { $0.width >= 1 && $0.height >= 1 }
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }
}
