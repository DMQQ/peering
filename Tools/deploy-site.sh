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

echo "==> minifying CSS"
python3 - "$STAGE/site/styles.css" <<'PYEOF'
import re, sys
text = open(sys.argv[1]).read()
text = re.sub(r'/\*.*?\*/', '', text, flags=re.DOTALL)
text = re.sub(r'[ \t]*\n[ \t]*', '\n', text)
text = re.sub(r'\n{2,}', '\n', text)
text = re.sub(r' *([{};,>~+]) *', r'\1', text)
text = re.sub(r': +', ': ', text)
open(sys.argv[1], 'w').write(text.strip() + '\n')
PYEOF

echo "==> stamping asset URLs"
# A hash of the contents, shortened to ten hex characters. Long enough that two real revisions
# will not collide, short enough to stay readable in a URL.
CSS_V="$(shasum -a 256 "$STAGE/site/styles.css" | cut -c1-10)"
JS_V="$(shasum -a 256 "$STAGE/site/app.js" | cut -c1-10)"
echo "    styles.css  v=$CSS_V"
echo "    app.js      v=$JS_V"

for page in "$STAGE"/site/*.html; do
    # The empty argument after -i is the backup suffix, and it is required on macOS. Without it
    # sed reads the next argument as the suffix and edits nothing.
    sed -i '' \
        -e "s#href=\"/styles.css\"#href=\"/styles.css?v=$CSS_V\"#g" \
        -e "s#src=\"/app.js\"#src=\"/app.js?v=$JS_V\"#g" \
        "$page"
done

# Checked rather than assumed, because a rewrite that silently matches nothing produces a deploy
# that looks like it worked and leaves every browser on the old stylesheet. That is the exact
# failure this script was written to end, so it does not get to reappear as a quiet one.
if ! grep -q "styles.css?v=$CSS_V" "$STAGE"/site/*.html; then
    echo "the stylesheet rewrite matched no page. Has the <link> changed shape?" >&2
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
