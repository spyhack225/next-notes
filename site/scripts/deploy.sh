#!/usr/bin/env bash
#
# Build the landing page and publish it, in one step.
#
# GitHub Pages serves `docs/` on `main` as committed — there is no Actions workflow — so
# publishing is: build, commit the output, push. Doing that by hand invites the two failures
# this script exists to prevent: pushing source without rebuilding, so the live site silently
# stays on the old bundle; and assuming the push deployed, which it does not guarantee.
#
#   npm run deploy
#   npm run deploy -- "Rewrite the hero"
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

MESSAGE="${1:-Rebuild the landing page}"

# --- Guards -----------------------------------------------------------------------------

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "main" ]; then
    echo "refusing: Pages serves 'main', and you are on '$BRANCH'." >&2
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
# A push is not a deployment. Pages rebuilds asynchronously and can take a minute, so the
# only honest confirmation is fetching the live page and checking it serves the bundle that
# was just built.

EXPECTED="$(grep -o 'assets/index-[A-Za-z0-9_-]*\.js' docs/index.html | head -1)"
# `basename`/`dirname` rather than a regex: BSD sed on macOS rejects the non-greedy form,
# and this has to work on the machine the app is built on. `tr` folds the SSH `:` into a `/`
# so git@host:owner/repo and https://host/owner/repo parse the same way.
NORMALISED="$(printf '%s' "$ORIGIN" | tr ':' '/')"
REPO="$(basename "$NORMALISED" .git)"
OWNER="$(basename "$(dirname "$NORMALISED")")"
URL="https://${OWNER}.github.io/${REPO}/"

echo "==> waiting for $URL to serve $EXPECTED"
for attempt in $(seq 1 12); do
    LIVE="$(curl -fsS --max-time 20 "$URL" 2>/dev/null | grep -o 'assets/index-[A-Za-z0-9_-]*\.js' | head -1 || true)"
    if [ "$LIVE" = "$EXPECTED" ]; then
        echo "==> live: $URL"
        exit 0
    fi
    echo "    attempt $attempt: serving ${LIVE:-nothing yet}"
    sleep 15
done

echo "the push succeeded but the live site is still on the old bundle after 3 minutes." >&2
echo "Pages is probably still building. Check https://github.com/${OWNER}/${REPO}/deployments" >&2
exit 1
