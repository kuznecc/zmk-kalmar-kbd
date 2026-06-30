#!/usr/bin/env bash
#
# Local ZMK firmware build for the split "A. Dux" keyboard (board nice_nano_v2,
# shields a_dux_left / a_dux_right), pinned to ZMK v0.3.0 / Zephyr 4.1.0.
#
# Reproduces the official CI build (.github/workflows/build.yml ->
# zmkfirmware/zmk/.github/workflows/build-user-config.yml) closely enough that
# local output == CI output. See local_build_solution.md for the full rationale.
#
# Primary base: carlosedp/zmk-config build_local.sh (pure-bash build.yaml parser,
# stable image default, west init -l config, dynamic targets, no forced KEYMAP_FILE).
# Grafted from skubmdi/docker-zmk-builder: read-only repo mount (zero repo
# pollution), CI-exact -DZMK_EXTRA_MODULES gated on zephyr/module.yml, and the
# west zephyr-export step.
#
# Quick start:
#   ./local_build.sh            # one-shot: init + build all + settings_reset + draw
#   ./local_build.sh help
#
set -euo pipefail

# --- Configuration -----------------------------------------------------------
RUNTIME="${RUNTIME:-docker}"  # macOS/Apple Silicon default; amd64 image via emulation
IMG="${ZMK_IMAGE:-zmkfirmware/zmk-build-arm:stable}"
BUILD_CONFIG="${BUILD_CONFIG:-build.yaml}"
KEYMAP_DRAWER_VERSION="${KEYMAP_DRAWER_VERSION:-0.23.0}"
KEYMAP_FILE="${KEYMAP_FILE:-config/a_dux.keymap}"

# --- Paths -------------------------------------------------------------------
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS="${REPO}/_local_build_artifacts"
WS="${ARTIFACTS}/ws"              # west workspace (deps + build dirs) -> container /zmk
VENV="${ARTIFACTS}/python_venv"
INNER="${ARTIFACTS}/_inner_build.sh"

# --- Logging -----------------------------------------------------------------
log()  { echo -e "\033[1;34m[INFO]\033[0m $*"; }
ok()   { echo -e "\033[0;32m[ OK ]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[0;31m[FAIL]\033[0m $*" >&2; }

# -----------------------------------------------------------------------------
# build.yaml parser (pure bash, no yq). Emits one line per target:
#   board|shield|snippet|cmake_args|artifact_name
# Adapted from carlosedp. Deviation: when artifact-name is absent we name the
# output by shield (falling back to board), so split halves land as
# a_dux_left.uf2 / a_dux_right.uf2 (CI/acceptance naming) instead of board_shield.
# -----------------------------------------------------------------------------
parse_build_config() {
  [ -f "$BUILD_CONFIG" ] || { err "build config not found: $BUILD_CONFIG"; exit 1; }

  strip_comment() { local v="$1"; v="${v%%\ \#*}"; echo "${v%"${v##*[![:space:]]}"}"; }

  emit() {
    [ -n "$1" ] || return 0
    local name="$5"
    if [ -z "$name" ]; then name="${2:-$1}"; fi   # artifact-name || shield || board
    echo "$1|$2|$3|$4|$name"
  }

  local in_include=0 board="" shield="" snippet="" cargs="" aname="" last=""
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue
    if [[ "$line" =~ ^include: ]]; then in_include=1; continue; fi
    [ $in_include -eq 1 ] || continue

    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+board:[[:space:]]*(.+) ]]; then
      emit "$board" "$shield" "$snippet" "$cargs" "$aname"
      board="$(strip_comment "${BASH_REMATCH[1]}")"; shield=""; snippet=""; cargs=""; aname=""; last=""
    elif [[ "$line" =~ ^[[:space:]]+shield:[[:space:]]*(.+) ]]; then
      shield="$(strip_comment "${BASH_REMATCH[1]}")"; last="shield"
    elif [[ "$line" =~ ^[[:space:]]+snippet:[[:space:]]*(.+) ]]; then
      snippet="$(strip_comment "${BASH_REMATCH[1]}")"; last="snippet"
    elif [[ "$line" =~ ^[[:space:]]+cmake-args:[[:space:]]*(.+) ]]; then
      cargs="$(strip_comment "${BASH_REMATCH[1]}")"; last="cmake_args"
    elif [[ "$line" =~ ^[[:space:]]+artifact-name:[[:space:]]*(.+) ]]; then
      aname="$(strip_comment "${BASH_REMATCH[1]}")"; last="artifact_name"
    elif [[ "$line" =~ ^[[:space:]]{6,}([^[:space:]].+) ]] && [ "$last" = "cmake_args" ]; then
      cargs="$cargs $(strip_comment "${BASH_REMATCH[1]}")"
    fi
  done <"$BUILD_CONFIG"
  emit "$board" "$shield" "$snippet" "$cargs" "$aname"
}

# Local checkout path of the zmk project from config/west.yml (default: zmk).
# Only an explicit path: override inside the zmk project entry counts; bounded to
# that entry so a sibling list item or the manifest-level self: path is ignored.
west_zmk_path() {
  local f="config/west.yml" in_zmk=0 entry_indent=-1 p="zmk"
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue
    if [[ "$line" =~ ^([[:space:]]*)-[[:space:]]+name:[[:space:]]*zmk[[:space:]]*$ ]]; then
      in_zmk=1; entry_indent=${#BASH_REMATCH[1]}; continue
    fi
    if [ $in_zmk -eq 1 ]; then
      local indent="${line%%[![:space:]]*}"
      # Leaving the zmk entry: a new list item or any key at/under its indent.
      if [ "${#indent}" -le "$entry_indent" ]; then break; fi
      if [[ "$line" =~ ^[[:space:]]+path:[[:space:]]*(.+) ]]; then p="${BASH_REMATCH[1]}"; break; fi
    fi
  done <"$f"
  echo "$p"
}

check_docker() {
  command -v "$RUNTIME" >/dev/null 2>&1 || { err "$RUNTIME not installed"; exit 1; }
  "$RUNTIME" info >/dev/null 2>&1 || { err "$RUNTIME daemon not running. Start Docker Desktop and retry."; exit 1; }
}

# Run a generated inner script inside the build container.
# Mounts: WS (writable isolated workspace) -> /zmk ; repo (read-only) ->
#         /srcrepo ; artifacts -> /artifacts. Mirrors CI: the workspace holds a
#         COPY of config/ plus west-managed deps; the repo stays pristine and is
#         referenced read-only for -DZMK_EXTRA_MODULES.
container_run() {
  mkdir -p "$WS"
  "$RUNTIME" run --rm \
    --workdir /zmk \
    -v "${WS}:/zmk" \
    -v "${REPO}:/srcrepo:ro" \
    -v "${ARTIFACTS}:/artifacts" \
    -e "CMAKE_PREFIX_PATH=/zmk/zephyr" \
    "$IMG" \
    bash /artifacts/"$(basename "$INNER")"
}

# Shared west-bootstrap snippet (idempotent), emitted into the inner script.
# Copies config/ into the isolated workspace (CI "isolated temporary directory"
# step), then west init -l <workspace>/config / update / zephyr-export.
emit_west_bootstrap() {
  cat <<'WEST'
cd /zmk
mkdir -p /zmk/config
cp -R /srcrepo/config/. /zmk/config/
if [ ! -d .west ]; then
  west init -l /zmk/config
fi
west update --fetch-opt=--filter=tree:0
west zephyr-export
WEST
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------
cmd_list() {
  log "Targets in ${BUILD_CONFIG}:"
  parse_build_config | while IFS='|' read -r board shield snippet cargs name; do
    printf "  %-20s board=%s shield=%s %s\n" "$name" "$board" "${shield:-—}" "${cargs:+cmake-args=$cargs}"
  done
}

cmd_build() {
  check_docker
  mkdir -p "$ARTIFACTS"

  local targets; targets="$(parse_build_config)"
  [ -n "$targets" ] || { err "no targets parsed from ${BUILD_CONFIG}"; exit 1; }

  local filter="${1:-}"
  local zmk_app; zmk_app="$(west_zmk_path)"

  local extra_modules=""
  if [ -f "${REPO}/zephyr/module.yml" ]; then
    extra_modules="-DZMK_EXTRA_MODULES=/srcrepo"
    log "zephyr/module.yml present -> ${extra_modules}"
  fi

  # Generate the inner script: bootstrap west, then one west build per target.
  { echo "#!/usr/bin/env bash"; echo "set -euo pipefail"; emit_west_bootstrap; } >"$INNER"

  local built=0
  while IFS='|' read -r board shield snippet cargs name; do
    [ -n "$board" ] || continue
    if [ -n "$filter" ] && [[ "$name" != $filter ]]; then continue; fi
    built=$((built+1))

    local d="/zmk/build/${name}"
    {
      echo ""
      echo "echo '=== Building ${name} (board=${board} shield=${shield:-—}) ==='"
      # Drop any prior output so a failed compile can't leave a stale artifact.
      echo "rm -f /artifacts/${name}.uf2 /artifacts/${name}.config"
      printf 'west build -p -b %q -s /zmk/%s/app -d %q' "$board" "$zmk_app" "$d"
      [ -n "$snippet" ] && printf ' -S %q' "$snippet"
      printf ' -- -DZMK_CONFIG=/zmk/config'
      [ -n "$extra_modules" ] && printf ' %s' "$extra_modules"
      [ -n "$shield" ] && printf ' -DSHIELD=%q' "$shield"
      [ -n "$cargs" ] && printf ' %s' "$cargs"
      echo ""
      # Fail loudly if the expected firmware artifact is missing.
      echo "if [ ! -f ${d}/zephyr/zmk.uf2 ]; then echo 'ERROR: ${name}: zmk.uf2 missing'; exit 1; fi"
      echo "cp ${d}/zephyr/zmk.uf2 /artifacts/${name}.uf2"
      echo "cp ${d}/zephyr/.config /artifacts/${name}.config 2>/dev/null || true"
      echo "echo 'wrote /artifacts/${name}.uf2'"
    } >>"$INNER"
  done <<<"$targets"

  [ "$built" -gt 0 ] || { err "filter '${filter}' matched no targets"; exit 1; }

  log "Building ${built} target(s) with ${IMG} via ${RUNTIME} (amd64 under emulation — slow)"
  container_run
  ok "firmware build complete"
}

# settings_reset: special target. No -DZMK_CONFIG, no keymap — just the core
# settings_reset shield on the board. Output -> reset_ble.uf2.
cmd_reset() {
  check_docker
  mkdir -p "$ARTIFACTS"

  local board; board="$(parse_build_config | head -n1 | cut -d'|' -f1)"
  [ -n "$board" ] || board="nice_nano_v2"
  local zmk_app; zmk_app="$(west_zmk_path)"

  { echo "#!/usr/bin/env bash"; echo "set -euo pipefail"; emit_west_bootstrap; } >"$INNER"
  {
    echo ""
    echo "echo '=== Building settings_reset (board=${board}) ==='"
    printf 'west build -p -b %q -s /zmk/%s/app -d /zmk/build/settings_reset -- -DSHIELD=settings_reset\n' "$board" "$zmk_app"
    echo "if [ ! -f /zmk/build/settings_reset/zephyr/zmk.uf2 ]; then echo 'ERROR: settings_reset: zmk.uf2 missing'; exit 1; fi"
    echo "cp /zmk/build/settings_reset/zephyr/zmk.uf2 /artifacts/reset_ble.uf2"
    echo "echo 'wrote /artifacts/reset_ble.uf2'"
  } >>"$INNER"

  log "Building settings_reset (board=${board})"
  container_run
  ok "settings_reset -> reset_ble.uf2"
}

# keymap visualization. NON-FATAL: failure here does not fail the build.
cmd_draw() {
  mkdir -p "$ARTIFACTS"
  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not found — skipping keymap draw"; return 0
  fi
  (
    set -e
    if [ ! -x "${VENV}/bin/keymap" ]; then
      log "Creating venv + keymap-drawer==${KEYMAP_DRAWER_VERSION}"
      python3 -m venv "$VENV"
      "${VENV}/bin/pip" install --quiet --upgrade pip
      "${VENV}/bin/pip" install --quiet "keymap-drawer==${KEYMAP_DRAWER_VERSION}"
    fi
    log "Parsing ${KEYMAP_FILE} -> keymap.yaml"
    "${VENV}/bin/keymap" parse -z "${REPO}/${KEYMAP_FILE}" >"${ARTIFACTS}/keymap.yaml"
    log "Drawing keymap.svg"
    "${VENV}/bin/keymap" draw "${ARTIFACTS}/keymap.yaml" >"${ARTIFACTS}/keymap.svg"
  ) && ok "keymap.svg generated" || warn "keymap draw failed (non-fatal — firmware build still OK)"
}

cmd_clean()     { log "Removing build dirs"; rm -rf "${WS}/build"; ok "build dirs removed"; }
cmd_clean_all() { log "Removing all workspace deps + caches"; rm -rf "$WS" "$VENV"; ok "removed ${WS} and ${VENV}"; }

verify_all() {
  log "Verifying artifacts under _local_build_artifacts/"
  local missing=0 f
  for f in a_dux_left.uf2 a_dux_right.uf2 reset_ble.uf2; do
    if [ -f "${ARTIFACTS}/${f}" ]; then ok "found ${f} ($(du -h "${ARTIFACTS}/${f}" | cut -f1))"; else err "MISSING ${f}"; missing=1; fi
  done
  if [ -f "${ARTIFACTS}/keymap.svg" ]; then ok "found keymap.svg"; else warn "keymap.svg missing (non-fatal)"; fi
  [ "$missing" -eq 0 ] || { err "required firmware artifact(s) missing"; exit 1; }
}

cmd_all() {
  cmd_build ""
  cmd_reset
  cmd_draw
  verify_all
  ok "one-shot build complete — artifacts in ${ARTIFACTS}/"
}

usage() {
  cat <<EOF
Local ZMK build — A. Dux (ZMK v0.3.0 / Zephyr 4.1.0)

Usage: ./local_build.sh [command]

  (no command)   one-shot: build all targets + settings_reset + draw keymap  [default]
  all            same as default
  build [name]   build all build.yaml targets, or only those matching [name] (wildcard ok)
  reset          build settings_reset firmware -> reset_ble.uf2
  draw           render keymap.svg from ${KEYMAP_FILE} (non-fatal)
  list           list targets parsed from ${BUILD_CONFIG}
  clean          remove build dirs (keep west deps)
  clean_all      remove west deps + python venv
  help           this help

Env: RUNTIME=${RUNTIME}  ZMK_IMAGE=${IMG}
     KEYMAP_DRAWER_VERSION=${KEYMAP_DRAWER_VERSION}
Outputs: ${ARTIFACTS}/
EOF
}

main() {
  local cmd="${1:-all}"
  case "$cmd" in
    all|"")     cmd_all ;;
    build)      shift; cmd_build "${1:-}" ;;
    reset)      cmd_reset ;;
    draw)       cmd_draw ;;
    list)       cmd_list ;;
    clean)      cmd_clean ;;
    clean_all)  cmd_clean_all ;;
    help|-h|--help) usage ;;
    *) err "unknown command: $cmd"; usage; exit 1 ;;
  esac
}

main "$@"
