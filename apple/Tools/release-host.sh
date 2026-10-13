#!/bin/bash
# Release the Mac host: archive, Developer ID sign, notarise, staple, package, sign the Sparkle
# feed, publish to the site and verify what the public URL serves. One command, no Xcode window.
#
#   apple/Tools/release-host.sh                 build, notarise, publish
#   apple/Tools/release-host.sh --no-publish    stop after the verified disk image
#   apple/Tools/release-host.sh --version N     override the YYYYMMDDR number
#   apple/Tools/release-host.sh --allow-dirty   release a tree with uncommitted changes
#
# One-time setup, because a CLI export signs but does not notarise:
#   xcrun notarytool store-credentials "$PEERING_NOTARY_PROFILE" \
#       --apple-id <apple id> --team-id <team id> --password <app-specific password>
# The Sparkle private key must be in the login keychain (generate_keys put it there).
#
# Environment: PEERING_NOTARY_PROFILE (default peering-notary), PEERING_RELEASE_DIR (default
# $TMPDIR/peering-release).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPLE_DIR="$REPO_DIR/apple"
SITE_DIR="$REPO_DIR/relay/site"
PROFILE="${PEERING_NOTARY_PROFILE:-peering-notary}"
WORK="${PEERING_RELEASE_DIR:-${TMPDIR:-/tmp}/peering-release}"
PUBLIC="${PEERINGD_PUBLIC:-https://getpeering.app}"

VERSION=""
PUBLISH=yes
ALLOW_DIRTY=no
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
        --no-publish) PUBLISH=no; shift ;;
        --allow-dirty) ALLOW_DIRTY=yes; shift ;;
        *) echo "usage: $(basename "$0") [--version N] [--no-publish] [--allow-dirty]" >&2; exit 1 ;;
    esac
done

step() { printf '\n==> %s\n' "$1"; }
fail() { echo "!! $1" >&2; exit 1; }

# Sparkle compares sparkle:version as a number, so a build that does not beat the live feed is
# offered to nobody and nothing fails. Today's first build is DATE0, then DATE1 and so on.
next_version() {
    local today latest revision
    today="$(date +%Y%m%d)"
    latest="$(grep -o '<sparkle:version>[0-9]*' "$SITE_DIR/updates/appcast.xml" | head -1 | grep -o '[0-9]*$' || true)"
    revision=0
    if [ -n "$latest" ] && [ "${latest%?}" = "$today" ]; then revision=$(( ${latest#"$today"} + 1 )); fi
    echo "${today}${revision}"
}

preflight() {
    step "checking prerequisites"
    cd "$REPO_DIR"
    if [ "$ALLOW_DIRTY" = no ] && [ -n "$(git status --porcelain --untracked-files=no)" ]; then
        fail "the tree has uncommitted changes. Commit them, or pass --allow-dirty."
    fi
    if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
        fail "no notarytool profile named '$PROFILE'. Run once: xcrun notarytool store-credentials $PROFILE --apple-id <id> --team-id <team> --password <app-specific password>"
    fi
    SPARKLE="$(find "$HOME/Library/Developer/Xcode/DerivedData" -type d -path '*SourcePackages/artifacts/sparkle/Sparkle' 2>/dev/null | head -1)"
    [ -x "$SPARKLE/bin/generate_appcast" ] || fail "Sparkle's generate_appcast was not found. Build the host once in Xcode so SwiftPM fetches it."
    security find-generic-password -s "https://sparkle-project.org" >/dev/null 2>&1 \
        || fail "the Sparkle signing key is not in the login keychain."
    [ -n "$VERSION" ] || VERSION="$(next_version)"
    echo "    version $VERSION"
}

archive() {
    step "archiving $VERSION"
    rm -rf "$WORK"
    mkdir -p "$WORK"
    cd "$APPLE_DIR"
    xcodebuild -project Peering.xcodeproj -scheme PeeringHost -configuration Release \
        MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$VERSION" \
        -destination 'generic/platform=macOS' -allowProvisioningUpdates \
        -archivePath "$WORK/Peering.xcarchive" archive >"$WORK/archive.log" 2>&1 \
        || { tail -40 "$WORK/archive.log" >&2; fail "the archive failed (full log: $WORK/archive.log)"; }
}

# The team comes from the archive's own signature so no team ID is written into a tracked file.
export_signed() {
    step "exporting with Developer ID"
    local archived="$WORK/Peering.xcarchive/Products/Applications/Peering.app" team
    team="$(codesign -dv "$archived" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    [ -n "$team" ] || fail "could not read the team from the archive's signature"
    cat >"$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>teamID</key><string>$team</string>
<key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
    xcodebuild -exportArchive -archivePath "$WORK/Peering.xcarchive" -exportPath "$WORK/export" \
        -exportOptionsPlist "$WORK/ExportOptions.plist" -allowProvisioningUpdates >"$WORK/export.log" 2>&1 \
        || { tail -40 "$WORK/export.log" >&2; fail "the export failed (full log: $WORK/export.log)"; }
    APP="$WORK/export/Peering.app"
    [ -d "$APP" ] || fail "the export produced no Peering.app"
}

# Both properties fail silently: a thin build and a wrong version notarise like a good one.
verify_bundle() {
    step "checking the bundle"
    local built widget
    built="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
    [ "$built" = "$VERSION" ] || fail "CFBundleVersion is $built, expected $VERSION"
    for binary in "$APP/Contents/MacOS/Peering" \
        "$APP/Contents/PlugIns/PeeringHostWidgetExtension.appex/Contents/MacOS/PeeringHostWidgetExtension"; do
        case "$(lipo -archs "$binary")" in
            *arm64*x86_64*|*x86_64*arm64*) ;;
            *) fail "$binary is not universal" ;;
        esac
    done
    widget="$(xcrun vtool -show-build "$APP/Contents/MacOS/Peering" | grep minos | head -1)"
    echo "    universal, $widget"
    codesign --verify --deep --strict "$APP" || fail "the signature does not verify"
}

notarise() {
    step "notarising (Apple usually takes a few minutes)"
    ditto -c -k --keepParent "$APP" "$WORK/Peering-notarise.zip"
    xcrun notarytool submit "$WORK/Peering-notarise.zip" --keychain-profile "$PROFILE" --wait \
        | tee "$WORK/notarise.log"
    grep -q 'status: Accepted' "$WORK/notarise.log" || fail "Apple did not accept the submission (log: $WORK/notarise.log)"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP" >/dev/null || fail "no ticket is stapled to the app"
    spctl -a -vv "$APP" 2>&1 | grep -q 'Notarized Developer ID' || fail "Gatekeeper does not call the app a notarised Developer ID app"
}

package() {
    step "packaging the disk image"
    local stage="$WORK/dmg-stage" mount="$WORK/mount"
    DMG="$WORK/Peering-$VERSION.dmg"
    mkdir -p "$stage" "$mount"
    ditto "$APP" "$stage/Peering.app"
    ln -s /Applications "$stage/Applications"
    hdiutil create -volname Peering -srcfolder "$stage" -ov -format UDZO "$DMG" >/dev/null
    hdiutil attach -nobrowse -readonly -quiet -mountpoint "$mount" "$DMG"
    [ -L "$mount/Applications" ] && [ -d "$mount/Peering.app" ] \
        || { hdiutil detach "$mount" -quiet; fail "the image lacks the app or the Applications alias"; }
    case "$(lipo -archs "$mount/Peering.app/Contents/MacOS/Peering")" in
        *arm64*x86_64*|*x86_64*arm64*) ;;
        *) hdiutil detach "$mount" -quiet; fail "the app inside the image is not universal" ;;
    esac
    hdiutil detach "$mount" -quiet
    echo "    $DMG"
}

# generate_appcast runs over the whole updates folder so the feed keeps its history and writes
# deltas against older builds. The three copies are the part that goes missing when done by hand:
# the DMGs are gitignored, so a feed without its enclosure deploys green and serves a 404.
publish() {
    step "signing the feed"
    cp "$DMG" "$SITE_DIR/updates/"
    cp "$DMG" "$SITE_DIR/download/Peering.dmg"
    "$SPARKLE/bin/generate_appcast" --download-url-prefix "$PUBLIC/updates/" "$SITE_DIR/updates/"
    grep -q "Peering-$VERSION.dmg" "$SITE_DIR/updates/appcast.xml" || fail "the feed does not list $VERSION"
    grep -q "<sparkle:version>$VERSION<" "$SITE_DIR/updates/appcast.xml" || fail "the feed carries the wrong sparkle:version"

    step "deploying the site"
    "$REPO_DIR/relay/tools/deploy-site.sh" --yes
    verify_live
}

# The enclosure is read out of the live feed and fetched, because the site deploy only checks the
# stylesheet and is blind to a missing disk image.
verify_live() {
    step "verifying the public URLs"
    local enclosure local_size remote_size
    enclosure="$(curl -s --max-time 15 "$PUBLIC/updates/appcast.xml" | grep -o "https://[^\"]*Peering-$VERSION.dmg" | head -1)"
    [ -n "$enclosure" ] || fail "the live feed does not list $VERSION"
    local_size="$(stat -f %z "$DMG")"
    for url in "$enclosure" "$PUBLIC/download/Peering.dmg?v=$(date +%s)"; do
        remote_size="$(curl -s --max-time 120 -o /dev/null -w '%{size_download}' "$url")"
        [ "$remote_size" = "$local_size" ] || fail "$url served $remote_size bytes, expected $local_size"
        echo "    $url ok ($remote_size bytes)"
    done
}

preflight
archive
export_signed
verify_bundle
notarise
package
if [ "$PUBLISH" = yes ]; then
    publish
    printf '\nReleased %s. The feed and site files changed in the tree: review and commit them.\n' "$VERSION"
else
    printf '\nBuilt %s, notarised and verified. Not published (--no-publish): %s\n' "$VERSION" "$DMG"
fi
