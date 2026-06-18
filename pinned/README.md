# Pinned dependency references

Known-good npm lockfiles captured from a **verified, reproducible build**, kept as **drift-detection references** — they are *not yet enforced* by the build.

- `node-pty.package-lock.json` — `node-pty`, the only npm package that ships inside `app.asar` (native module). Captured at `node-pty@1.1.0` (`npm audit`: 0 vulnerabilities). A fresh `./build.sh --build deb --clean no` regenerates it at `build/node-pty-build/package-lock.json`; diff against this file to detect dependency drift.

To make pinning **enforced** (not just recorded), wire `build.sh` to `npm ci` from a committed lockfile instead of `npm install <pkgs>`. Full rationale + the validation procedure: [`docs/learnings/sandbox-enablement.md`](../docs/learnings/sandbox-enablement.md).
