# Local Build Solution

Planning document for a unified local ZMK firmware build script. It records what
the upstream GitHub solutions do, which pieces are adopted from each, and which
goals must be preserved from the existing in-repo `local_build.sh`. It is the
input for writing the implementation plan, and the reference for updating the
script over time.

---

## 0. Repo context (read first)

Facts an implementing agent needs; verify they still hold before coding.

- **Keyboard:** split "A. Dux" (`a_dux`). `a_dux` is a **ZMK core shield**
  (`zmk/app/boards/shields/a_dux`), not defined in this repo.
- **Targets:** board `nice_nano_v2`, shields `a_dux_left`, `a_dux_right`.
- **Pinned ZMK version:** `v0.3.0` → Zephyr `4.1.0`. The pin appears in **two**
  places that must stay in sync:
  - `.github/workflows/build.yml` → `uses: …@v0.3.0`
  - `config/west.yml` → `projects[name=zmk].revision: v0.3.0`
- **Relevant files in this repo:**
  - `build.yaml` — build matrix (`include:` list of board/shield). Source of truth
    for what to build.
  - `config/west.yml` — West manifest; imports zmk `app/west.yml` at the pinned rev.
  - `config/a_dux.keymap` — keymap (overrides the core shield's default).
  - `config/a_dux.conf` — Kconfig overrides (`CONFIG_ZMK_KEYBOARD_NAME="kalmar_kbd"`,
    pointing, sleep timeouts, …).
  - `zephyr/module.yml` — marks the repo as a ZMK module (`board_root: .`).
  - `boards/shields/` — currently empty (`.gitkeep`); reserved for custom shields.
  - `local_build.sh` — the existing script being replaced. **Read it** for the exact
    current container invocation, mount layout, inner-script pattern, and the
    settings-reset + keymap-drawer steps to preserve.
  - `keymap-drawer/` — committed keymap renders (output of the draw step).
  - Note: no `keymap_drawer.config.yaml` present (optional; drawer runs without it).
- **Host environment:** macOS on **Apple Silicon (`arm64`)** with Docker Desktop.
  The `zmkfirmware/zmk-build-arm` image is `amd64`; it runs under emulation on this
  host (slower, but works — the existing script already builds this way).

---

## 1. Solution description

A single shell script that builds this keyboard's ZMK firmware **locally**, inside
a container, reproducing the official GitHub Actions CI build closely enough that
local output equals CI output.

- **What it does**
  - Reads build targets dynamically from `build.yaml` (no hardcoded shields).
  - Runs the build inside the official ZMK container image so no Zephyr SDK /
    toolchain is installed on the host.
  - Initializes and updates the West workspace from the repo's own
    `config/west.yml` manifest (correct, pinned ZMK + Zephyr versions).
  - Adds the repo as an extra ZMK module when `zephyr/module.yml` is present, so
    custom boards/shields under `boards/` are found (matches CI behavior).
  - Builds each firmware target, plus a settings-reset image, and renders the
    keymap visualization.

- **What it uses**
  - Host: macOS / Apple Silicon (`arm64`); `amd64` image via emulation.
  - Container runtime: Docker (Podman supported as an alternative).
  - ZMK build image: `zmkfirmware/zmk-build-arm:stable` (tracks the current
    Zephyr SDK; required for ZMK v0.3.0 / Zephyr 4.1.0).
  - West (inside the container) driven by `config/west.yml`.
  - Python `keymap-drawer` (in an isolated venv) for the keymap SVG.

- **What it produces**
  - One `*.uf2` per target in `build.yaml` (e.g. `a_dux_left`, `a_dux_right`).
  - A settings-reset firmware: `reset_ble.uf2`.
  - A keymap visualization: `keymap.svg` (and parsed `keymap.yaml`).
  - Optional debug artifacts per target (`.config`, `.dts`, `.log`) for diagnosing
    bad builds.

- **Where results live**
  - All outputs collected under `_local_build_artifacts/` (kept out of the repo,
    gitignored). West-managed dependencies are isolated there or in the container,
    not scattered across the repo root.

---

## 2. References

### 2.1 Canonical source of truth — ZMK CI reusable workflow

- **URL:** https://github.com/zmkfirmware/zmk/blob/v0.3.0/.github/workflows/build-user-config.yml
- **Why it matters:** This is exactly what runs in this repo's CI
  (`.github/workflows/build.yml` calls it via
  `uses: zmkfirmware/zmk/.github/workflows/build-user-config.yml@v0.3.0`). The
  unified script must match this logic to guarantee local == CI.
- **Key things possessed:**
  - Image `zmkfirmware/zmk-build-arm:stable`.
  - Build matrix parsed from `build.yaml`.
  - `west init -l config` → uses `config/west.yml` (not ZMK's `app/west.yml`).
  - `west update --fetch-opt=--filter=tree:0` (blobless fetch, faster).
  - `west zephyr-export`.
  - Conditional `-DZMK_EXTRA_MODULES=<repo>` only when `zephyr/module.yml` exists.
  - Build into an isolated config dir; `-DZMK_CONFIG=<config>`.
  - No forced `-DKEYMAP_FILE` (ZMK auto-discovers `config/a_dux.keymap`).
  - Artifact rename to `<artifact-name>.uf2` with `.bin`/`.hex` fallback.

### 2.2 carlosedp/zmk-config — `build_local.sh` (primary base)

- **URL:** https://github.com/carlosedp/zmk-config/blob/main/build_local.sh
- **Maturity:** active ~14 months, ~1–2 commits/month, last updated 2026-06-16.
  No third-party image dependency. Recommended primary base.
- **Key things possessed:**
  - Correct image default `zmkfirmware/zmk-build-arm:stable`.
  - `west init -l config` + `west update` driven by `config/west.yml`.
  - `-DBOARD_ROOT=/zmk` so custom boards/shields are found.
  - Dynamic targets parsed from `build.yaml` (board/shield/snippet/cmake-args/
    artifact-name).
  - No forced `-DKEYMAP_FILE` (auto-discovery, matches CI).
  - Subcommand CLI: `init`, `update`, `list`, `build [name|wildcard]`, `clean`,
    `clean_all`, `gitignore`, `copy`.
  - Incremental builds (skip pristine) for fast iteration.
  - Per-target `-DCONFIG_*` Kconfig overrides written to a merged `.conf`.
  - Docker/Podman runtime switch (`RUNTIME=docker`).
  - Self-contained YAML parsing (no `yq` dependency).

### 2.3 skubmdi/docker-zmk-builder (secondary — ideas only)

- **URL:** https://github.com/skubmdi/docker-zmk-builder
- **Maturity:** created 2026-06-04, all commits in first 2 days, dormant since;
  0 stars. **Do not depend on its published GHCR image.** Borrow ideas only.
- **Key things possessed (ideas to graft):**
  - Read-only repo mount → zero repo pollution (deps stay in container).
  - Exact CI module logic: `-DZMK_EXTRA_MODULES` gated on `zephyr/module.yml`
    (closer to CI than carlosedp's `-DBOARD_ROOT`).
  - `west zephyr-export` step (carlosedp omits it, relies on `CMAKE_PREFIX_PATH`).
  - Rich debug artifacts emitted per target: `.uf2 .hex .bin .elf .map .dts
    .dts.pre .config .log`.
  - Parallel builds of all targets.

---

## 3. Possessed solutions and implementation

| # | From | What | How it is implemented upstream |
|---|------|------|--------------------------------|
| 1 | carlosedp / CI | Correct build image | Default `IMG=zmkfirmware/zmk-build-arm:stable`; `docker run … $IMG west build …` |
| 2 | carlosedp / CI | Use repo manifest | `west init -l config` then `west update` (reads `config/west.yml`) |
| 3 | carlosedp | Dynamic targets | Parse `build.yaml` `include[]` → `board\|shield\|snippet\|cmake-args\|artifact-name` |
| 4 | carlosedp | Build invocation | `west build -p -b <board> -s zmk/app -d build/<name> -- -DZMK_CONFIG=… [-DSHIELD=…] [cmake-args]` |
| 5 | carlosedp | Custom boards/shields | `-DBOARD_ROOT=/zmk` (repo root as board root) |
| 6 | carlosedp | CLI ergonomics | Subcommands `init/update/list/build/clean/clean_all/gitignore/copy`; wildcard target match |
| 7 | carlosedp | Fast iteration | `INCREMENTAL=true` skips the `-p` pristine flag |
| 8 | carlosedp | Kconfig overrides | `-DCONFIG_*` args collected → temp `.conf` → `-DEXTRA_CONF_FILE=…` (merged last) |
| 9 | carlosedp | Runtime switch | `RUNTIME=docker\|podman` |
| 10 | skubmdi / CI | Exact module logic | `if [ -e zephyr/module.yml ]; then args+=" -DZMK_EXTRA_MODULES=<repo>"; fi` |
| 11 | skubmdi / CI | Zephyr export | `west zephyr-export` after `west update` |
| 12 | skubmdi | Read-only repo mount | Mount repo `:ro`, copy `config/*` into workspace; deps isolated |
| 13 | skubmdi | Debug artifacts | After build, copy `zmk.{uf2,hex,bin,elf,map}`, `zephyr.dts(.pre)`, `.config`, build log |
| 14 | skubmdi | Parallel builds | Background each target build, `wait` at the end |
| 15 | CI | No forced keymap | Omit `-DKEYMAP_FILE`; rely on ZMK auto-discovery of `config/a_dux.keymap` |
| 16 | CI | Blobless fetch | `west update --fetch-opt=--filter=tree:0` |

---

## 4. My additions (goals to preserve from existing `local_build.sh`)

These are not in the upstream scripts and must be carried into the unified script.

| # | Addition | Current implementation in `local_build.sh` | Requirement for unified script |
|---|----------|---------------------------------------------|--------------------------------|
| A1 | **Settings-reset firmware** | Builds `-DSHIELD=settings_reset` → copies to `reset_ble.uf2` | Keep. Either as an explicit step or by adding a `settings_reset` entry to `build.yaml` |
| A2 | **Keymap visualization** | Python venv + `keymap-drawer`: `keymap parse -z config/a_dux.keymap` then `keymap draw` → `keymap.svg` | Keep as an optional post-build step / subcommand (e.g. `draw`) |
| A3 | **Isolated artifacts dir** | Everything under `_local_build_artifacts/` (uf2, svg, cached zmk, venv) | Keep. Outputs and caches must stay out of the repo tree and gitignored |
| A4 | **Self-contained one-shot run** | Single `./local_build.sh` builds both halves + reset + draws keymap | Provide a default command that does the full pipeline in one invocation |

### Known defects in `local_build.sh` to fix while porting

- Stale image `zmkfirmware/zmk-dev-arm:3.5-branch` → wrong Zephyr SDK for v0.3.0
  (Zephyr 4.1.0). **Root cause of malformed firmware.** Replace with
  `zmkfirmware/zmk-build-arm:stable`.
- `west init -l app/` ignores `config/west.yml` (any extra modules added there are
  dropped). Replace with `west init -l config`.
- Missing `-DZMK_EXTRA_MODULES` / board root → custom boards/shields not found.
- Forced `-DKEYMAP_FILE` → drop; use auto-discovery to match CI.

---

## 4a. Acceptance criteria (definition of done)

The implementing agent must confirm all of these before declaring success:

- A single command builds everything (the one-shot pipeline, goal A4).
- Produces, under `_local_build_artifacts/` (goal A3):
  - `a_dux_left.uf2`, `a_dux_right.uf2` (named per `build.yaml` artifact-name / target).
  - `reset_ble.uf2` (settings-reset, goal A1).
  - `keymap.svg` (keymap visualization, goal A2).
- Uses image `zmkfirmware/zmk-build-arm:stable` (NOT `zmk-dev-arm:3.5-branch`).
- Uses `west init -l config` (NOT `app/`), and the build resolves the keymap
  automatically (no `-DKEYMAP_FILE`).
- Repo working tree stays clean: no `.west/`, `zmk/`, `modules/`, `zephyr/` deps
  committed or left at repo root (isolate them or gitignore them).
- The produced `.uf2` set matches CI's artifact set for the same commit; the
  per-target Kconfig (`zephyr/.config`) reflects `config/a_dux.conf`
  (e.g. `CONFIG_ZMK_KEYBOARD_NAME="kalmar_kbd"`, `CONFIG_ZMK_POINTING=y`).

---

## 4b. As-built implementation notes (local_build.sh)

Recorded when the unified script was first implemented + verified (ZMK v0.3.0).

- **Mount topology (CI-faithful, idea #12):** writable workspace `WS` =
  `_local_build_artifacts/ws` → container `/zmk`; repo mounted **read-only** at
  `/srcrepo`; `_local_build_artifacts/` → `/artifacts`. The bootstrap copies
  `/srcrepo/config/.` into `/zmk/config` (mirrors CI's "isolated temporary
  directory" step), then `west init -l /zmk/config`. `-DZMK_EXTRA_MODULES=/srcrepo`
  points at the read-only repo root (matches CI's `${GITHUB_WORKSPACE}`). West deps
  (`.west zmk zephyr modules`) live only in `WS`; the repo tree stays clean.
- **Artifact naming deviation from carlosedp:** when a target has no
  `artifact-name`, output is named by **shield** (falling back to board), so the
  halves land as `a_dux_left.uf2` / `a_dux_right.uf2` (the §4a names) instead of
  carlosedp's `board_shield`.
- **keymap-drawer pin:** `0.23.0` (latest stable; requires Python ≥3.12). Override
  via `KEYMAP_DRAWER_VERSION`. Draw step is non-fatal.
- **Stale-output guard:** each target's `.uf2`/`.config` is deleted in-container
  before its build, so a failed compile cannot leave a stale artifact that fools
  verification.
- **Runtime default `docker`** (host is macOS/Apple Silicon; amd64 image via
  emulation). Override with `RUNTIME` / `ZMK_IMAGE`.
- **Verified outputs:** `a_dux_left.uf2`, `a_dux_right.uf2`, `reset_ble.uf2`,
  `keymap.svg`; per-target `.config` shows `CONFIG_ZMK_KEYBOARD_NAME="kalmar_kbd"`
  and `CONFIG_ZMK_POINTING=y`; repo tree clean after run.

---

## 5. Updating this solution over time

When ZMK / Zephyr versions move or upstream scripts change, re-derive against the
canonical source, in this order:

1. **Re-check the CI workflow first** (Section 2.1). It is the source of truth.
   - Confirm the image tag (`stable` vs a pinned `N.M-branch`).
   - Confirm the `west` step sequence (`init -l config`, `update`, `zephyr-export`)
     and the module/extra-modules conditions.
   - Read the version actually pulled: the build job's env prints
     `zephyr_version` — verify the local image SDK matches it.
2. **Re-pull the upstream scripts** (Sections 2.2, 2.3) and diff against the local
   unified script:
   - carlosedp: `https://raw.githubusercontent.com/carlosedp/zmk-config/main/build_local.sh`
   - skubmdi: `https://raw.githubusercontent.com/skubmdi/docker-zmk-builder/main/build.sh`
3. **Check upstream maintenance** before trusting a change:
   `gh api "repos/<owner>/<repo>/commits?path=<file>&per_page=10"` → look at dates
   and cadence. Prefer changes from actively maintained sources.
4. **Re-verify the four preserved goals** (Section 4) still produce their outputs
   (`reset_ble.uf2`, `keymap.svg`, isolated artifacts, one-shot run).
5. **Confirm local == CI** by reading CI artifacts/logs for the same commit and
   comparing produced `.uf2` set and `.config` Kconfig output.
