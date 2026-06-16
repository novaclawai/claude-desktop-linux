#!/usr/bin/env bash
#===============================================================================
# sync.sh — refresh the upstream mirror and rebase the hardening branch.
#
# `main` is kept as a pure mirror of aaddrick/claude-desktop-debian. This helper
# refreshes that mirror from upstream and rebases the local hardening branch on
# top of it, then prints the re-verify commands to run afterwards.
#
# Usage: ./sync.sh   (run from the repo root)
#===============================================================================

upstream_url='https://github.com/aaddrick/claude-desktop-debian.git'
hardening_branch='claude/nifty-dirac-5l22f9'

# Add the upstream remote if it is not already configured.
if ! git remote get-url upstream &> /dev/null; then
	echo "Adding upstream remote: ${upstream_url}"
	git remote add upstream "$upstream_url" || exit 1
fi

echo 'Fetching upstream/main...'
git fetch upstream main || exit 1

echo 'Refreshing the local main mirror from upstream/main...'
git checkout -B main upstream/main || exit 1

echo "Rebasing ${hardening_branch} onto main..."
git checkout "$hardening_branch" || exit 1
if ! git rebase main; then
	echo 'resolve then: git rebase --continue'
	exit 1
fi

echo
echo 'Re-verify after sync:'
echo '  ./build.sh --build deb        # --build rpm on Fedora'
echo '  ./scripts/verify-patches.sh build/electron-app/app.asar'
echo '  claude-desktop --doctor      # or the built launcher binary'
