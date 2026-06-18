# Pinned dependency references

Known-good npm lockfiles captured from a **verified, reproducible build**.

- `node-pty.package-lock.json` + `node-pty.package.json` — `node-pty`, the only npm package that ships inside `app.asar` (native module), pinned at `node-pty@1.1.0` (`npm audit`: 0 vulnerabilities). **The build enforces this pair**: `scripts/patches/cowork.sh` runs `npm ci` from it, so every build installs the exact version with integrity-hash verification (a tampered or drifted tarball fails the build). To bump: regenerate the pair (`npm install node-pty@<ver>` in a scratch dir), re-audit, and replace both files here.

Checked continuously by:
- `scripts/verify-deps.sh` — run after a build; `npm audit` + drift-vs-pinned gate.
- `.github/workflows/dep-audit.yml` — weekly `npm audit` of these lockfiles; opens an issue if a pinned version later gets a disclosed advisory (the gap pinning can't close on its own).

Full rationale + the validation procedure: [`docs/learnings/sandbox-enablement.md`](../docs/learnings/sandbox-enablement.md).
