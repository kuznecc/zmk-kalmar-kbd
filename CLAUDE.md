# CLAUDE.md

Project memory for this ZMK keyboard config repo. Read by Claude Code each session.

## Project

ZMK firmware user-config for split "A. Dux" keyboard (board `nice_nano_v2`,
shields `a_dux_left` / `a_dux_right`), pinned to ZMK `v0.3.0` (Zephyr `4.1.0`).
CI builds via `.github/workflows/build.yml`. Firmware also built locally via
containerized script (see below).

## Build & flash (daily use)

Needs Docker or Podman running.

```bash
./local_build.sh          # build both halves + settings_reset + draw keymap
./local_build.sh build    # build targets only
./local_build.sh list     # list targets from build.yaml
./local_build.sh reset    # settings_reset -> reset_ble.uf2
./local_build.sh help
```

Artifacts land in `_local_build_artifacts/` (`a_dux_left.uf2`, `a_dux_right.uf2`,
`reset_ble.uf2`). Flash: double-tap reset on half (mounts as USB drive), copy
matching `*.uf2`. `reset_ble.uf2` clears BLE bonds.

## Local build script — maintenance via `local_build_solution.md`

`local_build_solution.md` = **authoritative spec** for local firmware build
script (unified replacement for `local_build.sh`). Self-contained: repo context,
upstream GitHub sources, what adopted from each, goals to preserve, acceptance
criteria, update playbook.

**When asked to implement or create the local build script:**
1. Read `local_build_solution.md` end to end first — source of truth.
2. Follow §0 (repo context), §3 (possessed solutions), §4 (preserved goals).
3. Verify against §4a (acceptance criteria) before declaring done.
4. No blind upstream pull — re-fetch referenced scripts and adapt;
   never depend on skubmdi's published GHCR image (see §2.3).

**When asked to update/upgrade the local build script (e.g. months later, new ZMK
or Zephyr version):**
1. Read `local_build_solution.md` §5 (update playbook), follow in order.
2. Treat **CI reusable workflow** (§2.1) as source of truth for correct
   image tag, west step sequence, module handling — re-check first.
3. Confirm ZMK version pin in sync across `.github/workflows/build.yml` and
   `config/west.yml` (§0), and image SDK matches pulled `zephyr_version`.
4. Re-fetch upstream scripts (§2.2, §2.3), check their maintenance/cadence
   (`gh api …/commits?path=…`) before trusting any change.
5. **Keep `local_build_solution.md` updated** when solution changes:
   new sources, adopted pieces, version pins, acceptance criteria. Doc must
   stay accurate hand-off for next agent.