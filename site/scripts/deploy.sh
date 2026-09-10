#!/usr/bin/env bash
#
# Build the landing page and publish it, in one step.
#
# DigitalOcean App Platform serves `docs/` on `main` as committed, rebuilding on push — there
# is no Actions workflow. So publishing is: build, commit the output, push. Doing that by hand
# invites the two failures this script exists to prevent: pushing source without rebuilding, so
# the live site silently stays on the old bundle; and assuming the push deployed, which it does
# not guarantee.
#
#   npm run deploy
#   npm run deploy -- "Rewrite the hero"
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

MESSAGE="${1:-Rebuild the landing page}"

# The live site, and the App Platform app behind it. The app rebuilds from `main` on push.
SITE_URL="https://next-notes.com/"
DO_APP_ID="e2366c03-b11d-4c56-8d07-fdea08b21cdc"

# --- Guards -----------------------------------------------------------------------------

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "main" ]; then
    echo "refusing: the app deploys 'main', and you are on '$BRANCH'." >&2
    echo "Merge to main first, or the push will not change the live site." >&2
    exit 1
fi

ORIGIN="$(git remote get-url origin 2>/dev/null || echo '')"
if [ -z "$ORIGIN" ]; then
    echo "refusing: no 'origin' remote." >&2
    exit 1
fi
# This repository was started from a public one that is not ours. Nothing may be pushed there.
if printf '%s' "$ORIGIN" | grep -qi "murmur-youtube"; then
    echo "refusing: origin is $ORIGIN, which is not our repository." >&2
    exit 1
fi

# --- Build ------------------------------------------------------------------------------

echo "==> building"
( cd "$ROOT/site" && npm run build )

# --- Commit -----------------------------------------------------------------------------

if git diff --quiet -- docs && git diff --cached --quiet -- docs; then
    echo "==> docs unchanged, nothing new to commit"
else
    echo "==> committing docs"
    git add docs
    # Path-limited on purpose: whatever else is half-staged in the tree is not this deploy's
    # business, and sweeping it into a "Rebuild the site" commit would hide it.
    git commit -m "$MESSAGE" -- docs
fi

# --- Push -------------------------------------------------------------------------------

if [ -n "$(git log --oneline origin/main..HEAD 2>/dev/null || true)" ]; then
    echo "==> pushing"
    git push origin main
else
    echo "==> nothing to push"
fi

# --- Verify -----------------------------------------------------------------------------
#
# A push is not a deployment. App Platform rebuilds asynchronously and takes a minute or two,
# so the only honest confirmation is fetching the live page and checking it serves the bundle
# that was just built.

EXPECTED="$(grep -o 'assets/index-[A-Za-z0-9_-]*\.js' docs/index.html | head -1)"

echo "==> waiting for $SITE_URL to serve $EXPECTED"
for attempt in $(seq 1 12); do
    # Cache-busted on purpose. The App Platform edge sends s-maxage=86400, so without this a
    # stale HTML document can outlive the deploy and make a good build look broken.
    LIVE="$(curl -fsS --max-time 20 "${SITE_URL}?cb=${RANDOM}${attempt}" 2>/dev/null \
            | grep -o 'assets/index-[A-Za-z0-9_-]*\.js' | head -1 || true)"
    if [ "$LIVE" = "$EXPECTED" ]; then
        # The HTML is current. Confirm the bundle it points at is actually reachable — a
        # wrong `base` in vite.config.ts produces exactly this: correct HTML, 404 assets,
        # blank page.
        if curl -fsS -o /dev/null --max-time 20 "https://next-notes.com/${EXPECTED}?cb=${RANDOM}"; then
            echo "==> live: $SITE_URL"
            exit 0
        fi
        echo "    attempt $attempt: HTML is current but $EXPECTED does not resolve" >&2
    else
        echo "    attempt $attempt: serving ${LIVE:-nothing yet}"
    fi
    sleep 15
done

echo "the push succeeded but the live site is still not serving the new bundle after 3 minutes." >&2
echo "Check the deployment:  doctl apps list-deployments $DO_APP_ID" >&2
exit 1
