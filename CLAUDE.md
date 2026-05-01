# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Bash + Make installer that one-shots **CAPEv2 host stack + KVM/libvirt + anti-VM QEMU 9.2.2 / SeaBios 1.16.3** on a clean **Ubuntu 24.04 noble** target. Hard-coded for the China network environment (TUNA mirrors; `gh-proxy.com` fallback when `github.com` HTTPS is blocked). The repo's scope is Phase B only — the host. Windows guest provisioning (Phase C) is documented in `README.md` but not automated.

## Common commands

All targets must run on the target machine (Ubuntu 24.04). Most require root.

```bash
sudo make all                          # full install (~50 min on clean noble)
sudo bash bootstrap.sh all             # same, but auto-installs `make` first

sudo make <stage>                      # run one stage (e.g. 40-kvm-libvirt)
sudo make force-<stage>                # rerun a stage, bypassing idempotency guards (FORCE=1)

sudo make uninstall-dry                # preview uninstall, mutates nothing
sudo make uninstall                    # real uninstall (interactive `yes` prompt)
sudo make uninstall-yes                # uninstall, skip prompt (CI/batch)
sudo make u<NN>-<stage>                # run one uninstall stage

sudo make import-guest GUEST_QCOW2=...   # Phase C: register a pre-built Win10 qcow2 as cuckoo1
sudo make c<NN>-<stage>                # Phase C single stage (c10/c20/c30/c40/c50)

make help                              # list all targets / stages
make clean                             # wipe logs/ and state/ (does not touch installed components)
```

There is **no test suite**. The verification harness is `scripts/install/99-smoke-test.sh` (services up, ports listening, libvirt usable, venv imports, `virt-host-validate`). Treat a successful `sudo make all` end-to-end as the integration test; rerun individual stages with `force-<stage>` while iterating.

User config: copy `config.env.sample` → `config.env`. Only two parameters are exposed (by design — see `docs/WHY.md` ADR-Q4): `SUBNET` and `DB_PASSWORD`. The Makefile does **not** honor environment-variable overrides; it only reads `config.env`.

## Architecture

### Stage orchestration

`Makefile` declares two ordered chains as a chain of `.PHONY` targets, each shelling out to `scripts/<stage>.sh`:

- **Install:** `00-preflight → 10-mirrors → 20-host-stack → 30-poetry-fix → 31-cape-config → 40-kvm-libvirt → 50-anti-vm-qemu → 51-anti-vm-seabios → 99-smoke-test`
- **Uninstall:** `u00-preflight → u10-stop-services → u20-backup-data → u30-purge-apt → u40-remove-files → u50-remove-systemd-units → u60-revert-system-config → u70-remove-users → u80-clean-cron → u99-verify`
- **Phase C (client guest):** `c10-import-guest → c20-define-domain → c30-register-kvm-conf → c40-smoke-guest → c50-snapshot-and-cape`. Triggered by `sudo make import-guest GUEST_QCOW2=...`. Requires Phase B (`make all`) to have completed. The Mac-side workflow (manual UTM Win10 install + 1 PowerShell in-guest + 1 Mac shell export script) is documented in `docs/guest/win10-ltsc.md`.

Install stages are linked by Make prerequisites (`51 ← 50 ← 40 ← …`), so any single-stage invocation re-checks earlier stages — but each stage is fully idempotent, so re-checks are cheap. Uninstall stages intentionally **lack** prereq edges: `u30` failing must not block `u40+` (best-effort cleanup).

### `lib/common.sh` is the contract every script uses

Every `scripts/*.sh` starts with:

```bash
source "${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/lib/common.sh"
stage_init "<stage-name>"
# … work …
stage_done
```

`stage_init` redirects stdout/stderr into `logs/<stage>.log` and installs an `ERR` trap that prints the last 50 lines on failure. Do not echo to the terminal in stages — use `log_info / log_ok / log_warn / log_err` (they write to fd 3/4, the saved original stderr).

Reusable helpers exposed by `common.sh`:

- **Idempotency probes** (return 0 = "already done"): `pkg_installed`, `user_in_group`, `service_active`, `service_enabled`, `venv_ready`, `file_sha_ok`, `net_active`, `listening_on`. Pattern: `if done_or_force <probe...>; then echo "[~] skip"; stage_done; exit 0; fi`. `done_or_force` returns failure when `FORCE=1` so `force-<stage>` bypasses guards.
- **Retry:** `retry <attempts> <initial-delay-sec> <cmd…>` with exponential backoff. Wrap **every** `curl`, `wget`, `apt-get`, and any other network/flaky call.
- **GitHub access:** `00-preflight` writes `state/github.env` containing `GH_PROXY=` (direct) or `GH_PROXY=https://gh-proxy.com/` (mirror). Use `gh_url <https://github.com/…>` when generating download URLs; for `git clone`, the preflight stage also installs a system-wide `git config url.<gh-proxy>.insteadOf` so `git clone https://github.com/…` is rewritten transparently.
- **DRY_RUN wrappers** (uninstall only): `run cmd…` prints under `DRY_RUN=1` and executes otherwise; `run_or_warn` is the same but never propagates failure (best-effort). They do not `eval` — for pipes/heredocs, gate manually with `if [ "$DRY_RUN" != "1" ]; then …; fi`.

### Vendored upstream scripts

`vendor/` snapshots upstream installers and patches that this project depends on:

- `vendor/cape2.sh.patched` — patched copy of upstream `kevoreilly/CAPEv2/installer/cape2.sh`. Patches: switch MongoDB repo to TUNA + use local GPG key + retry, comment out the buggy `poetry pip install -r pyproject.toml` line (real venv is built by stage 30), add a 60s timeout to `community.py` (avoids ~21 min hang on `raw.githubusercontent.com`).
- `vendor/kvm-qemu.sh.patched` — pinned snapshot, currently no patch hunks.
- `vendor/pyproject-tuna-source.toml` — appended to CAPE's `pyproject.toml` to add a `[[tool.poetry.source]]` entry pointing to TUNA.
- `vendor/mongodb-server-8.0.asc` — local copy of the MongoDB GPG key (upstream `pgp.mongodb.com` is unreliable from CN).
- `vendor/checksums.sh` — pinned URLs + sha256 for QEMU 9.2.2 and SeaBios 1.16.3 source tarballs.

When upstream changes, do a manual three-way merge into the `.patched` files; do not chase upstream automatically.

### Runtime state layout

- `logs/<stage>.log` — per-stage full output, regenerated each run.
- `state/github.env` — sourced by `gh_url` / `load_github_env`.
- Both directories are gitignored and wiped by `make clean`.

## Conventions specific to this repo

- **Single OS target.** Anything in this repo may assume Ubuntu 24.04 noble + x86_64 + VT-x. `00-preflight` enforces that — do not add cross-distro branches.
- **CN-first networking is hard-coded, not configurable.** TUNA URLs are written into `pyproject.toml`, `pip.conf`, apt sources, etc. Do not add multi-mirror fallback / region toggles unless explicitly asked (see ADR-Q1 / ADR-Q4).
- **Idempotency is mandatory** for new stages. The user runs `make` repeatedly while iterating, so a stage that's "done" must detect that fact via system probes (not marker files — see ADR-Q5) and `exit 0` cleanly.
- **Errors propagate, network is retried.** Scripts run under `set -eEuo pipefail`. Wrap network calls in `retry`; use `|| true` for genuinely best-effort lines (and prefer `run_or_warn` in uninstall).
- **Uninstall preserves the SSH session.** `u70-remove-users.sh` must guard against deleting `UID >= 1000` accounts — the user's login user (often `cape` on Phase-A-only boxes) lives there. `u00-preflight` warns when `SUDO_USER` matches a target.
- **Systemd unit naming.** `cape` and `cape-processor` are intentionally `mask`ed by `31-cape-config` because Phase B has no Windows guest yet — they would crash-loop. Phase-C work needs to `unmask` them; do not silently un-mask in Phase B stages.
- **The Makefile root check exempts `help`, `clean`, and `uninstall-dry`.** When adding a new non-mutating target, add it to `NONROOT_TARGETS`.

## Where to look first

- `README.md` — user-facing entry point, also has the only Phase C (Windows guest) walkthrough.
- `docs/WHY.md` — ADR log of every architectural decision (Q1–Q13 + uninstall ADR + Phase 240 verification findings). Read this before changing high-level structure.
- `docs/INSTALL.md` / `docs/UNINSTALL.md` — per-stage manuals (what each stage does, how to verify by hand).
- `docs/TROUBLESHOOTING.md` — symptom-indexed runbook.
