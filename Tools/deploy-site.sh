#!/bin/bash
# Deploy the marketing site, and only the marketing site, to the relay box.
#
# The site is served by the relay but it is not the relay. A one-line change to a stylesheet
# should not need a Rust toolchain, a CI run, a release tag and a binary swap, and this is the
# path that skips all four. See deploy-relay.sh for the other one.
#
# It also closes the reason such a change used to be invisible after a successful deploy. The
# stylesheet is served with a four hour max-age, and the HTML asked for it by a name that never
# changed, so a browser could hold the old sheet for hours after the upload had landed. Every
# deploy now stamps the asset URLs with a hash of the file's contents: a changed file is a changed
# URL, and the cache has nothing stale to answer with. A file that did not change keeps its URL
# and stays cached, which is the point of doing it by content rather than by build number.
#
#   Tools/deploy-site.sh
#   Tools/deploy-site.sh --yes
#
# Environment overrides, as in deploy-relay.sh: PEERINGD_SSH, PEERINGD_SSH_PORT,
# PEERINGD_REMOTE_SITE, PEERINGD_PUBLIC.

set -euo pipefail

SSH_TARGET="${PEERINGD_SSH:-root@pro01.mikr.us}"
# `-p` for ssh and `-P` for scp, which is not a typo and not interchangeable. To scp, a lowercase
# `-p` means "preserve times", so passing the port that way makes it treat the number as a file.
SSH_ARGS=(-p "${PEERINGD_SSH_PORT:-10190}")
SCP_ARGS=(-P "${PEERINGD_SSH_PORT:-10190}")
REMOTE_SITE="${PEERINGD_REMOTE_SITE:-/srv/peering/site}"
PUBLIC="${PEERINGD_PUBLIC:-https://getpeering.app}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE_DIR="$REPO_DIR/Relay/site"

YES="${1:-}"
if [ -n "$YES" ] && [ "$YES" != "--yes" ]; then
    echo "usage: $(basename "$0") [--yes]" >&2
    exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$SITE_DIR" "$STAGE/site"

echo "==> stamping asset URLs"
# A hash of the contents, shortened to ten hex characters. Long enough that two real revisions
# will not collide, short enough to stay readable in a URL.
CSS_V="$(shasum -a 256 "$STAGE/site/styles.css" | cut -c1-10)"
JS_V="$(shasum -a 256 "$STAGE/site/app.js" | cut -c1-10)"
echo "    styles.css  v=$CSS_V"
echo "    app.js      v=$JS_V"

# The disk image needs the same treatment as the stylesheet, and the reason is not visible from
# this machine. The relay already answers a DMG with `Cache-Control: no-cache`, so the origin is
# correct, but `dmg` is on Cloudflare's default cache-by-extension list and the zone's Browser
# Cache TTL replaces that header on the way out. The edge was serving `max-age=14400`, so anybody
# who had downloaded the previous release within those four hours got the old image back from
# their own browser with no request reaching this box at all. On 22 September 2026 that handed a
# protocol-16 build to somebody who had just been told their Mac was too old, and the download
# page was the one place the fix was supposed to come from.
#
# A changed query string is a different cache key at every layer, which is what the stylesheet
# stamp relies on too. The path stays fixed, so a link from outside the site keeps working.
DMG_V=""
if [ -f "$STAGE/site/download/Peering.dmg" ]; then
    DMG_V="$(shasum -a 256 "$STAGE/site/download/Peering.dmg" | cut -c1-10)"
    echo "    Peering.dmg v=$DMG_V"
fi

# **The images, which were the last thing left out of this and are the reason it exists.**
#
# A webp here is served with a seven-day `max-age` and the pages asked for it by a name that never
# changed, so a changed picture reached this box and stopped at the edge. Measured on 25 September
# 2026: `app-mac.webp` was the new file on disk, the public URL returned the version from two days
# before with `cf-cache-status: HIT` and an `age` of a day, and the same URL with a query string
# returned the new bytes straight from the origin. The stamp below is the fix; noticing by hand is
# not a check.
#
# Every file in `assets/`, not only the webps: a favicon and an `og:image` are cached the same way
# and are just as embarrassing served stale. An image whose bytes have not changed keeps its
# version and therefore its cache entry, which is the point of hashing the contents.
IMAGE_VERSIONS=()
for image in "$STAGE"/site/assets/*; do
    [ -f "$image" ] || continue
    IMAGE_VERSIONS+=("$(basename "$image"):$(shasum -a 256 "$image" | cut -c1-10)")
done
# `${arr[@]+"${arr[@]}"}` rather than a plain expansion: this is bash 3.2, where an empty array
# under `set -u` is an unbound variable.
for entry in ${IMAGE_VERSIONS[@]+"${IMAGE_VERSIONS[@]}"}; do
    echo "    assets/${entry%%:*} v=${entry##*:}"
done

for page in "$STAGE"/site/*.html; do
    # The empty argument after -i is the backup suffix, and it is required on macOS. Without it
    # sed reads the next argument as the suffix and edits nothing.
    sed -i '' \
        -e "s#href=\"/styles.css\"#href=\"/styles.css?v=$CSS_V\"#g" \
        -e "s#src=\"/app.js\"#src=\"/app.js?v=$JS_V\"#g" \
        "$page"
    if [ -n "$DMG_V" ]; then
        sed -i '' \
            -e "s#href=\"/download/Peering.dmg\"#href=\"/download/Peering.dmg?v=$DMG_V\"#g" \
            "$page"
    fi
    for entry in ${IMAGE_VERSIONS[@]+"${IMAGE_VERSIONS[@]}"}; do
        name="${entry%%:*}"
        version="${entry##*:}"
        # Matched on the closing quote rather than on the whole attribute, because these are
        # written both as a path and as a full URL in `content=`, and both end at the delimiter.
        # The dot in a filename is a wildcard to a regular expression, so it is escaped first.
        escaped="$(printf '%s' "$name" | sed 's/\./\\./g')"
        sed -i '' -e "s#/assets/$escaped\"#/assets/$name?v=$version\"#g" "$page"
    done
done

# Checked rather than assumed, because a rewrite that silently matches nothing produces a deploy
# that looks like it worked and leaves every browser on the old stylesheet. That is the exact
# failure this script was written to end, so it does not get to reappear as a quiet one.
if ! grep -q "styles.css?v=$CSS_V" "$STAGE"/site/*.html; then
    echo "the stylesheet rewrite matched no page. Has the <link> changed shape?" >&2
    exit 1
fi

# The same check for the image, and it matters more: a stale stylesheet looks wrong, where a stale
# DMG is an old build that installs cleanly and then refuses to talk to the phone.
if [ -n "$DMG_V" ] && ! grep -q "download/Peering.dmg?v=$DMG_V" "$STAGE"/site/*.html; then
    echo "the disk image rewrite matched no page. Has the download link changed shape?" >&2
    exit 1
fi

# **An invariant rather than a check per asset: no asset URL may be left without a version.**
# A per-image check only covers the images that existed when it was written, and the way this went
# wrong the first time is exactly that — the stamps covered the stylesheet, the script and the disk
# image, and the pictures were simply not in the list. This fails on the next one somebody adds.
if grep -qE '/assets/[A-Za-z0-9._-]+"' "$STAGE"/site/*.html; then
    echo "an asset URL is still unstamped, so a browser could hold the old one:" >&2
    grep -oE '/assets/[A-Za-z0-9._-]+"' "$STAGE"/site/*.html >&2
    exit 1
fi

if [ "$YES" != "--yes" ]; then
    printf 'upload to %s:%s and swap into place? [y/N] ' "$SSH_TARGET" "$REMOTE_SITE"
    read -r answer
    case "$answer" in [yY]*) ;; *) echo "left alone."; exit 1 ;; esac
fi

echo "==> uploading to $SSH_TARGET"
scp -q -r "${SCP_ARGS[@]}" "$STAGE/site" "$SSH_TARGET:/tmp/peering-site-new"

# The staging directory is swapped in rather than rsynced over directly, so the site is never
# half a revision while it is being read. `--delete` then takes the files of the old revision
# away, with `.impeccable` excluded because that is a working directory rather than a page.
echo "==> installing"
ssh "${SSH_ARGS[@]}" "$SSH_TARGET" bash -euo pipefail <<REMOTE
mkdir -p "$REMOTE_SITE"
rm -rf "$REMOTE_SITE.new"
mv /tmp/peering-site-new "$REMOTE_SITE.new"
rsync -a --delete --exclude '.impeccable' "$REMOTE_SITE.new/" "$REMOTE_SITE/"
rm -rf "$REMOTE_SITE.new"
REMOTE

# Asked of the public hostname rather than of the box, because the whole point of the stamp is
# that a browser sees it. An upload that landed on the disk but not through the cache is the one
# this check exists to catch, and it is invisible to a check run on the far side of it.
#
# Asked more than once, because the files are swapped in a single `mv` on the box but the answer is
# read back through a CDN, and a moment where the two disagree is expected rather than a fault.
#
# The body is captured into a variable and matched with a glob, and that is not a style choice. The
# obvious `curl ... | grep -q ...` cannot work here. Under `set -o pipefail` a pipeline reports the
# failure of any stage, and `grep -q` exits the moment it matches, which leaves curl writing into a
# pipe with no reader. curl fails with a write error, the pipeline reports failure, and the check
# fails for a page that matched. It reported two successful deploys as failures before this was
# understood, which is the worst thing a check can do to the person reading it.
echo "==> verifying"
served=""
for attempt in $(seq 1 10); do
    page="$(curl -s --max-time 10 "$PUBLIC/" || true)"
    case "$page" in
        *"styles.css?v=$CSS_V"*)
            echo "    $PUBLIC is serving styles.css?v=$CSS_V"
            served=yes
            break
            ;;
    esac
    sleep 3
done

if [ -z "$served" ]; then
    echo "!! $PUBLIC is not serving styles.css?v=$CSS_V after 10 tries" >&2
    echo "   The files are installed on the box. Look at the page's own cache, then at the swap." >&2
    exit 1
fi
