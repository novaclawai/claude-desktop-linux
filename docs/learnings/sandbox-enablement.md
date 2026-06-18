# Cowork + Chromium sandbox enablement (userns-restricted distros)

Claude Desktop ships two independent sandboxes — Cowork's **bubblewrap** agent jail and **Chromium's** renderer sandbox — and on Ubuntu 23.10+/24.04+ both are gated behind `kernel.apparmor_restrict_unprivileged_userns=1`; the `.deb` postinst arms both automatically, so the only manual step is the desktop-session type.

```bash
# Fresh machine, short version:
sudo apt install ./claude-desktop_<ver>_amd64.deb   # pulls bubblewrap (Recommends);
                                                     # arms chrome-sandbox + 2 AppArmor profiles
# → log into an "Ubuntu on Xorg" session            # Chromium sandbox is OFF under Wayland
claude-desktop --doctor                              # expect exit 0, "Cowork isolation: bubblewrap"
```

## The two sandboxes, the two blockers

- **Cowork (bubblewrap)** — the agent's Claude Code process runs inside a `bwrap` namespace jail. `bwrap` needs an **unprivileged user namespace**.
- **Chromium (renderer sandbox)** — Electron's zygote/renderer sandbox. Also wants unprivileged userns, with the setuid `chrome-sandbox` helper as the fallback path.

**Blocker 1 — the userns restriction.** Ubuntu 23.10+ sets `kernel.apparmor_restrict_unprivileged_userns=1`, which blocks unprivileged user namespaces *unless the calling binary has an AppArmor profile granting `userns`*. Symptoms when unmet:
- `bwrap`: probe fails with `setting up uid map: Permission denied`.
- Chromium: FATAL on a `sandbox/.../credentials.cc` error at launch.

**Blocker 2 — Wayland forces `--no-sandbox`.** The deb/nix launcher appends `--no-sandbox` on a Wayland session (`scripts/launcher-common.sh:319-321`; the AppImage always does, `:245`). That disables Chromium's sandbox regardless of AppArmor/SUID setup — so the Chromium sandbox is only actually live under **X11/Xorg**.

**The fork's hardening makes this load-bearing.** `detectBackend()` now **fails closed** — if no sandbox backend works, Cowork *refuses to start* instead of silently running host-direct (see [`cowork-vm-daemon.md`](cowork-vm-daemon.md) and the [maintenance notes](../../MAINTENANCE.md)). So on a userns-restricted distro **without** the AppArmor profile, Cowork won't run at all. The profile is what turns it on.

## What the `.deb` postinst does for you

A plain `sudo apt install ./claude-desktop_*.deb` runs `postinst`, which:

1. Sets `chrome-sandbox` → `root:root` mode `4755` (`/usr/lib/claude-desktop/node_modules/electron/dist/chrome-sandbox`).
2. Installs **`/etc/apparmor.d/claude-desktop`** — grants `userns` to the Electron binary (Chromium sandbox).
3. Installs **`/etc/apparmor.d/claude-desktop-bwrap`** — grants `userns` to `/usr/bin/bwrap` (Cowork). **Deferred** if another profile already attaches to `/usr/bin/bwrap` (a hand-made `/etc/apparmor.d/bwrap`, or `apparmor-profiles`' `bwrap-userns-restrict`).
4. Pulls in `bubblewrap` via `Recommends`.

Both AppArmor steps are **gated on `[ -e /proc/sys/kernel/apparmor_restrict_unprivileged_userns ]`** — i.e. only on Ubuntu-family kernels that enforce the restriction; on stock Debian/others they're skipped (not needed). Profiles load immediately via `apparmor_parser -r`, or stage for the next reboot.

**Net:** on Ubuntu 24.04 a plain install makes Cowork's bwrap backend work *and* arms the Chromium sandbox. The manual AppArmor steps recorded in this project's session history were only necessary because the daemon was probed **before** the package was installed — install-first needs none of them.

## Runbook A — fresh VirtualBox VM

1. **Get the `.deb`.** Build it on a throwaway box — `./build.sh --build deb` (deps: `p7zip-full icoutils imagemagick dpkg-dev build-essential python3`; the patch suite must include the `#649` `--add-dir` fix). Or copy a known-good artifact in.
2. **Install** — in a *real terminal* (not the agent's `!` prompt; `sudo` needs a TTY for the password):
   ```bash
   sudo apt install /path/to/claude-desktop_<ver>_amd64.deb
   ```
   Watch for `Setting chrome-sandbox permissions...` and `AppArmor profile installed at ...` in the output.
3. **Switch to Xorg** — log out, at GDM pick **⚙️ → "Ubuntu on Xorg"**, log back in. (Required for the Chromium sandbox; see Blocker 2.)
4. **Verify** — see *Verification* below.
5. **(Optional) KVM backend** — see *Cowork KVM* below.

## Runbook B — bare-metal host

Same install. Two differences from the VM:

- A host normally exposes `/dev/kvm` natively, so you can step Cowork up to the **KVM** backend (full-VM isolation) without the nested-virt dance.
- Still pick an **X11/Xorg** session for the Chromium sandbox (or evaluate *Open question* below).
- **Trust the build first.** The build runs *unpinned* `npm install` + native compilation on the build host — build in a throwaway env and validate in a VM before putting the artifact on a host. See [`MAINTENANCE.md`](../../MAINTENANCE.md).

## Verification

```bash
claude-desktop --doctor          # exit 0; want these lines:
  # [PASS] Display server: X11
  # [PASS] Chrome sandbox: permissions OK
  # [PASS] bubblewrap: sandbox probe succeeded
  #        Cowork isolation: bubblewrap (namespace sandbox)

# Prove the Chromium sandbox is actually live (launch the app first):
pgrep -af "node_modules/electron/dist/[e]lectron" | grep -- --no-sandbox
  # NO output  → sandbox ON.  Any --no-sandbox line → sandbox OFF (you're on Wayland).

# Probe bwrap by hand:
bwrap --ro-bind / / true; echo $?     # 0 = userns allowed
```

The `[e]` bracket in the `pgrep` pattern stops it matching its own command line (see *Gotchas*). A healthy sandboxed Electron tree shows sandboxed zygotes (`--type=zygote`) **and** one unsandboxed zygote (`--no-zygote-sandbox`, for the GPU/utility processes) — that split is normal; the decisive signal is the absence of `--no-sandbox` on the main browser process.

## Build-trust & supply-chain validation

Before trusting a build on a host, verify the *build* — the VM only contains the build's blast radius; the same `.deb` on a host carries whatever was baked in.

```bash
# 1. Provenance: app.asar is Anthropic's official code, SHA-256-pinned at build.
#    Build log shows: "SHA-256 verified: Claude Desktop installer".

# 2. Dependency audit — two npm sets run at build time:
#    a) node-pty (ships in-app, native)   b) Electron toolchain (build host)
( cd build/node-pty-build && npm audit )                 # expect: 0 vulnerabilities
grep -E "audited [0-9]+ packages|found [0-9]+ vulnerab" build.log   # toolchain audit

# 3. Reproducibility — diff a fresh build's asar contents vs the installed one:
( cd build/electron-app/app.asar.contents && find . -type f -exec sha256sum {} + ) \
  | awk '{print $2" "$1}' | sort        # compare two builds; identical == deterministic

# 4. Egress — what it phones home to (root; close other apps first):
sudo timeout 90 tcpdump -nn -i any 'udp port 53' 2>/dev/null \
  | grep -oE 'A+\? [a-z0-9._-]+' | awk '{print $2}' | sort -u
```

**Results captured this session** (Claude Desktop `1.12603.1`, Ubuntu 24.04):

| Check | Result |
| --- | --- |
| App provenance (SHA-256 pin) | ✅ verified |
| `node-pty` (ships in-app) | ✅ `1.1.0`, `npm audit` 0 vulns — lockfile at [`pinned/node-pty.package-lock.json`](../../pinned/node-pty.package-lock.json) |
| Electron toolchain (83 pkgs) | ✅ `npm audit` 0 vulns (1 deprecation `boolean@3.2.0`, not a vuln); Electron binary checksum-verified by `@electron/get` |
| Reproducibility | ✅ two builds → **153/153 packed + 8/8 unpacked files byte-identical**; shipped `cowork-vm-service.js` == source |
| Egress | ⚠️ Anthropic (`assets.claude.ai`, API) + 3rd-party telemetry **Sift** (fraud) & **Datadog** (RUM), loaded as claude.ai *web content* (not in the build) |

**Honest caveats — what these do and don't prove:**

- **Reproducibility proves determinism, not dependency safety.** A malicious *pinned* dep would also reproduce identically. What covers that here: the only shipping native dep (`node-pty`) is a well-known package at a pinned, 0-vuln version; everything else is Anthropic's SHA-verified code or the checksum-verified Electron binary.
- **The lockfile is a record, not enforcement.** `build.sh` installs via `npm install <pkgs>` (no committed lockfile), so `pinned/node-pty.package-lock.json` is a known-good *reference* for drift-detection. Enforcement = wire `build.sh` to `npm ci` from committed lockfiles (a build-process change, not yet done).
- **Egress: non-root `ss`/snapshot sampling is unreliable** — it misses IPv6 and short-lived connections (Sift and Datadog only surfaced after fixing capture bugs). Use the root `tcpdump` line above, or an egress allowlist, for a guaranteed-complete map. The third parties are claude.ai's product telemetry (identical on the official app), not introduced by this build.

**"Ready for a host" checklist:**

1. ✅ `app.asar` SHA-256 pin verified (each build)
2. ✅ patches = your reviewed diff (`verify-patches` OK; daemon == source)
3. ✅ shipping native dep (`node-pty`) audited clean + version-pinned
4. ✅ build reproducible (byte-identical across two builds)
5. ⚠️ egress = Anthropic + claude.ai's embedded 3rd-party telemetry (Sift, Datadog) — enforce with an allowlist if desired
6. ✅ sandboxes active (Chromium + Cowork bwrap)
7. ☐ on the host: run as your normal user (not root); optional egress allowlist / dedicated user
8. ☐ *(optional)* wire `build.sh` to `npm ci` from committed lockfiles for durable pinning

## Cowork KVM backend (optional, strongest isolation)

```bash
export COWORK_VM_BACKEND=kvm
```
Requirements the daemon (and `--doctor`) check: `/dev/kvm` (readable/writable), `/dev/vhost-vsock`, `qemu-system-x86_64`, `virtiofsd`, `socat`.

- **VirtualBox guest:** enable **"Enable Nested VT-x/AMD-V"** (System → Processor; VM powered off) or `VBoxManage modifyvm "<vm>" --nested-hw-virt on`. That's what exposes `/dev/kvm` inside the guest.
- **Host:** `/dev/kvm` is usually present already.

`bubblewrap` is the lighter default and is sufficient for most uses; reach for KVM when you want VM-grade isolation.

## Gotchas

### `bwrap: setting up uid map: Permission denied`
The userns restriction with no AppArmor profile for `bwrap`. Install the `.deb` (postinst handles it) or add a profile granting `userns` to `/usr/bin/bwrap` and `sudo apparmor_parser -r` it. Takes effect on the next `bwrap` exec — no reboot needed.

### Chromium renders but the sandbox is off
You're on a **Wayland** session; the launcher added `--no-sandbox`. Switch to Xorg. (`--doctor` "Display server" tells you which you're on.)

### `--doctor` says "Chrome sandbox: permissions OK" but the sandbox isn't engaged
That check verifies the helper *file* perms, not runtime. On Wayland it's still bypassed by `--no-sandbox`. Confirm engagement with the `pgrep` process check above, on X11.

### Black screen with an "X" mouse cursor after choosing "Ubuntu on Xorg" (VirtualBox)
A known VirtualBox + GNOME-on-Xorg **graphics** issue — unrelated to CPU virtualization. **Nested VT-x/AMD-V does not fix it** (that only exposes `/dev/kvm`). Mitigations: Graphics Controller = **VMSVGA**, Video Memory ≥ **128 MB**, try **3D acceleration off**; a clean cold boot often clears a one-off hang (forced power-offs mid-hang can leave stale state).

### `/tmp` files vanished
`/tmp` is cleared on reboot. Don't stash the `.deb`, AppArmor profiles, or logs there across a reboot.

### `pgrep` says the app is running when it isn't
`pgrep -af <pat>` matches its **own** command line (which contains `<pat>`). Use the bracket trick: `pgrep -af "[c]laude-desktop"`.

### `sudo` fails in the agent's `!` prompt
`sudo: a terminal is required to read the password`. The `!` prompt runs without a TTY — run `sudo` commands in a real terminal.

## Open question — keep the Chromium sandbox on Wayland?

Now that the package installs `/etc/apparmor.d/claude-desktop` (userns for the Electron binary), Chromium's userns sandbox *should* be viable on Wayland too — the only thing disabling it is the launcher's hard-coded `--no-sandbox` for deb/nix on Wayland. Dropping that default (so Wayland keeps the sandbox) is untested and may reintroduce the Wayland/Electron crashes it was added to avoid; evaluate before changing, and record the call in [`docs/decisions.md`](../decisions.md).

## What this session changed (the hardening)

On branch `claude/nifty-dirac-5l22f9` (mirrored to the fork as a backup):

- `scripts/cowork-vm-service.js` — `resolveSubpath()` `$HOME` containment guard; `detectBackend()` **fails closed** (no silent host-direct). Relates to issue #554.
- `scripts/_common.sh` — `verify_sha256()` fails closed on an empty expected hash.
- `scripts/patches/config.sh` — the `#649` `--add-dir` patch now filters **every** dispatch site (fixed a build-blocking anchor drift: the upstream bundle now carries the loop twice).
- `scripts/doctor.sh` — reports Cowork **fail-closed** instead of `host-direct` when no backend is available.

See [`MAINTENANCE.md`](../../MAINTENANCE.md) for the update-stream model and re-verify routine.

## Rollback / cleanup

```bash
sudo apt remove claude-desktop          # postrm handles package-managed files
# If this machine has a hand-made bwrap profile (not package-managed):
sudo rm /etc/apparmor.d/bwrap
sudo apparmor_parser -R /etc/apparmor.d/bwrap 2>/dev/null || true
```
The package-managed profiles (`/etc/apparmor.d/claude-desktop`, `…-bwrap`) are the package's to manage; put any local overrides in `/etc/apparmor.d/local/claude-desktop[-bwrap]` so upgrades don't clobber them.
