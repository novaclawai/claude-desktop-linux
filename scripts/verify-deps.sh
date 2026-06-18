#!/usr/bin/env bash
#===============================================================================
# verify-deps.sh — supply-chain gate for the build's npm dependencies.
#
# Audits node-pty (the only npm package that ships inside app.asar) for known
# advisories, and checks its lockfile against the committed pinned reference
# (drift detection). Run after a build; reusable in CI. Default work dir:
# ./build (override with $1).
#
# The Electron toolchain is intentionally not pinned here — its version tracks
# the upstream app, and its binary is checksum-verified by @electron/get — but
# `build.sh`'s own `npm install` audits it (see the build log).
#
# Exit codes: 0 ok · 1 usage/input · 2 vulnerabilities · 3 drift from pinned
#===============================================================================

work_dir="${1:-build}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
pinned_lock="$project_root/pinned/node-pty.package-lock.json"
pty_dir="$work_dir/node-pty-build"
rc=0

if [[ ! -d $pty_dir ]]; then
	echo "verify-deps: $pty_dir not found (run a build first)" >&2
	exit 1
fi

echo '--- node-pty: npm audit (fail on high/critical) ---'
if (cd "$pty_dir" && npm audit --audit-level=high); then
	echo '  OK: no high/critical advisories'
else
	echo '  FAIL: node-pty has high/critical advisories (above)' >&2
	rc=2
fi

echo '--- node-pty: drift vs pinned lockfile ---'
if [[ ! -f $pinned_lock ]]; then
	echo "  WARN: pinned lockfile missing ($pinned_lock)"
elif diff -q "$pinned_lock" "$pty_dir/package-lock.json" &> /dev/null; then
	echo '  OK: lockfile matches pinned/node-pty.package-lock.json'
else
	echo '  FAIL: node-pty lockfile drifted from pinned reference' >&2
	[[ $rc -eq 0 ]] && rc=3
fi

if [[ $rc -eq 0 ]]; then
	echo 'verify-deps: all checks passed'
fi
exit "$rc"
