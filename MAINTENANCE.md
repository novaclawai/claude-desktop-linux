# Maintenance

This fork carries a small security-hardening layer on top of
`aaddrick/claude-desktop-debian`; keep that layer current by mirroring
upstream onto `main`, rebasing the hardening branch with `./sync.sh`, and
re-verifying after every Claude Desktop version bump.

## Three update streams

Three things move independently. Track each one separately.

| Stream | What it is | Where it lives |
| --- | --- | --- |
| The wrapper | The upstream Linux repackaging — patches, the launcher, `frame-fix-wrapper`, the build system | `aaddrick/claude-desktop-debian`, mirrored on `main` |
| Claude Desktop | The upstream Electron app: its **version** and the **pinned SHA-256** the build verifies | `scripts/setup/detect-host.sh` on `upstream/main` (bumped automatically by the `check-claude-version` workflow) |
| This hardening | The P0/P1 security edits in this fork | branch `claude/nifty-dirac-5l22f9` |

## Routine

`main` is a **pure upstream mirror** — never commit hardening to it. To pull
upstream forward and re-stack the hardening branch:

```bash
./sync.sh    # adds the upstream remote, fetches, resets main, rebases the branch
```

After any Claude Desktop version bump (new `CLAUDE_DESKTOP_VERSION` / new pinned
SHA-256 in `scripts/setup/detect-host.sh`), re-verify before trusting a build:

```bash
./build.sh --build deb                                  # --build rpm on Fedora
./scripts/verify-patches.sh build/electron-app/app.asar # all markers must be OK
claude-desktop --doctor                                 # or the built launcher
```

The `security-watch` workflow (`.github/workflows/security-watch.yml`) runs the
same diff weekly: it compares `upstream/main` against `.security-baseline` over
the security-sensitive paths and opens a tracking issue (with an AI review)
whenever any of them change, refusing to advance the baseline until a human
signs off.

## Applied hardening (P0/P1)

All edits are on `claude/nifty-dirac-5l22f9`. The two Cowork fixes are
upstreamable (see below).

| Pri | Area | Change |
| --- | --- | --- |
| P0 | Cowork backend | `detectBackend()` in `scripts/cowork-vm-service.js` now **fails closed**: when the bwrap user-namespace probe fails, or when no sandbox backend (bwrap/KVM) is available, it throws instead of silently returning `HostBackend` (no isolation). The explicit `COWORK_VM_BACKEND=host` override is untouched. |
| P1 | Cowork paths | `resolveSubpath()` in `scripts/cowork-vm-service.js` now clamps results to `$HOME`: a resolved path that is not `$HOME` or under `$HOME/` is logged (`resolveSubpath: traversal blocked`) and replaced with `os.homedir()`, mirroring the existing `translateGuestPath()` guard. |
| P1 | Supply chain | `verify_sha256()` in `scripts/_common.sh` now **fails closed** on an empty expected hash — it errors (`No SHA-256 hash for <label>; refusing to proceed`) and returns 1 instead of warning and returning 0. |

## Operational guidance

Full step-by-step setup (fresh VM and host, with verification) lives in
[`docs/learnings/sandbox-enablement.md`](docs/learnings/sandbox-enablement.md).
Defense-in-depth for running and building this fork, in brief:

- **Arm the sandboxes by installing the `.deb`.** On Ubuntu 23.10+/24.04+ the
  postinst installs AppArmor `userns` profiles for both `/usr/bin/bwrap`
  (Cowork) and the Electron binary (Chromium), and sets `chrome-sandbox` SUID —
  so bubblewrap (the default, real-isolation Cowork backend) just works. Use
  `export COWORK_VM_BACKEND=kvm` for full-VM isolation wherever `/dev/kvm`
  exists (a host, or a VM with nested virtualization enabled).
- **Prefer an X11 session to keep the Chromium sandbox.** On Wayland the
  deb/nix launchers add `--no-sandbox` (toggle near
  `scripts/launcher-common.sh:319-321`); the AppImage always adds it. Running
  under X11 avoids that downgrade.
- **Build inside a throwaway container.** The build pulls **unpinned npm**
  for the Electron toolchain, plus `node-pty` and `appimagetool`, all of which
  **execute on the build host**. Isolate that blast radius.
- **Avoid the AppImage format for host installs.** It always disables the
  Chromium sandbox (FUSE constraints); prefer the deb/rpm under X11.
- **Pin `node-pty` only from a known-good lockfile.** Pin it from a successful
  build's lockfile, not speculatively.

## Upstreaming

The two Cowork fixes above (the `resolveSubpath()` containment guard and the
fail-closed `detectBackend()`) are not fork-specific and should go upstream —
they relate to **issue #554**. Each is proposed as its own focused PR:

- `fix/resolvesubpath-traversal` — the `resolveSubpath()` guard (edit B).
- `fix/cowork-fail-closed-backend` — the fail-closed backend (edits C and D).

The `verify_sha256()` fail-closed change is also a candidate to upstream if the
maintainers want a stricter default.
