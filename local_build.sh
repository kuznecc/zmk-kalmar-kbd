#!/usr/bin/env bash
set -euo pipefail # Exit on error, treat unset variables as error, propagate pipeline errors

# --- Configuration ---
BOARD_NAME="nice_nano_v2"
SHIELD_LEFT_NAME="a_dux_left"
SHIELD_RIGHT_NAME="a_dux_right"
KBD_KEYMAP_FILE="config/a_dux.keymap"

# --- Paths ---
USER_CONFIG_REPO_PATH="$(pwd)"
OUTPUT_ARTIFACTS_PATH="${USER_CONFIG_REPO_PATH}/_local_build_artifacts"
ZMK_SOURCE_DIR="${OUTPUT_ARTIFACTS_PATH}/zmk"
PYTHON_VENV_DIR="${OUTPUT_ARTIFACTS_PATH}/python_venv"
PARSED_KBD_KEYMAP_FILE="${OUTPUT_ARTIFACTS_PATH}/parsed_keymap.yaml"
OUTPUT_SVG_FILE="${OUTPUT_ARTIFACTS_PATH}/keymap.svg"

# --- Script Variables ---
ZMK_DOCKER_IMAGE="zmkfirmware/zmk-dev-arm:3.5-branch"
ZMK_DOCKER_CONTAINER_NAME="zmk-builder-container"
INNER_SCRIPT_NAME="_docker_build_steps_split_update.sh"
INNER_SCRIPT_PATH="${OUTPUT_ARTIFACTS_PATH}/${INNER_SCRIPT_NAME}"

cleanup() {
    rm -f "${INNER_SCRIPT_PATH}"
    rm -f "${PARSED_KBD_KEYMAP_FILE}"
    rm -f docker-compose.yml
}
trap cleanup EXIT

mkdir -p "${OUTPUT_ARTIFACTS_PATH}"

rm -rf "${OUTPUT_ARTIFACTS_PATH}/*.uf2"
rm -rf "${OUTPUT_SVG_FILE}"

#                                                   --- Main Script ---

# ======================================================================================================================
# 1. Clone or Update the ZMK firmware repository locally
if [ ! -d "${ZMK_SOURCE_DIR}" ]; then
  git clone https://github.com/zmkfirmware/zmk.git "${ZMK_SOURCE_DIR}"
else
  (cd "${ZMK_SOURCE_DIR}" && git pull) || { echo "Failed to update ZMK repository. Aborting."; exit 1; }
fi

# ======================================================================================================================
# 2. Create the inner script that will run inside Docker
cat > "${INNER_SCRIPT_PATH}" <<INNER_EOF
#!/usr/bin/env bash
set -euo pipefail

ZMK_APP_DIR="/workspaces/zmk/app"
ZMK_CONFIG_DIR_IN_CONTAINER="/workspaces/zmk-config"
INTERNAL_CONTAINER_ARTIFACTS_PATH="/artifacts"

cd /workspaces/zmk

if [ ! -d ".west" ]; then
    west init -l app/
fi

# if fails to update
#    -> try to drop folder like       ->  rm -rf ${ZMK_SOURCE_DIR}/modules/hal/quicklogic
#    -> try to drop whole zmk folder  ->  rm -rf ${ZMK_SOURCE_DIR}
west update

mkdir -p "\${INTERNAL_CONTAINER_ARTIFACTS_PATH}"

build_one_shield() {
    local board_name="\$1"
    local shield_name="\$2"
    local build_dir_suffix="\$3" # e.g., "left" or "right"

    echo "--------------------------------------------------"
    echo "Building for: Board='\${board_name}', Shield='\${shield_name}' (output suffix: \${build_dir_suffix})"
    local build_dir_name="build_\${build_dir_suffix}"

    echo "Executing: west build -b \${board_name} -d \${build_dir_name} -- -DSHIELD=\${shield_name}"
    west build -s app -p always -b "\${board_name}" -d "\${build_dir_name}" -- \\
        -DSHIELD="\${shield_name}" \\
        -DZMK_CONFIG="\${ZMK_CONFIG_DIR_IN_CONTAINER}/config" \\
        -DKEYMAP_FILE="\${ZMK_CONFIG_DIR_IN_CONTAINER}/config/a_dux.keymap"

    local firmware_source_path="/workspaces/zmk/\${build_dir_name}/zephyr/zmk.uf2"
    local firmware_dest_path="\${INTERNAL_CONTAINER_ARTIFACTS_PATH}/\${shield_name}.uf2"



    if [ -f "\${firmware_source_path}" ]; then
        cp "\${firmware_source_path}" "\${firmware_dest_path}"
    else
        echo "ERROR: Build failed or firmware file not found for '\${shield_name}'."
        echo "Expected at (inside container): '\${firmware_source_path}'"
        # Consider adding 'exit 1' here if you want the script to stop on the first build failure
    fi
    echo "--------------------------------------------------"
}

# Build for a split keyboard (left and right halves)
build_one_shield "${BOARD_NAME}" "${SHIELD_LEFT_NAME}" "left"
build_one_shield "${BOARD_NAME}" "${SHIELD_RIGHT_NAME}" "right"
INNER_EOF

chmod +x "${INNER_SCRIPT_PATH}"

# ======================================================================================================================
# 3. Run Docker container and execute the inner script
echo "Running Docker container (${ZMK_DOCKER_IMAGE})..."
docker run --rm -it \
    --workdir /workspaces/zmk \
    -v "${ZMK_SOURCE_DIR}:/workspaces/zmk" \
    -v "${USER_CONFIG_REPO_PATH}:/workspaces/zmk-config" \
    -v "${OUTPUT_ARTIFACTS_PATH}:/artifacts" \
    "${ZMK_DOCKER_IMAGE}" \
    /bin/bash "/artifacts/${INNER_SCRIPT_NAME}"

# # docker compose based option to preserve container that may be reused or discovered
#cat > docker-compose.yml <<EOF
#version: '3.8'
#services:
#  zmk-builder:
#    image: ${ZMK_DOCKER_IMAGE}
#    container_name: ${ZMK_DOCKER_CONTAINER_NAME}
#    working_dir: /workspaces/zmk
#    volumes:
#      - "${ZMK_SOURCE_DIR}:/workspaces/zmk"
#      - "${USER_CONFIG_REPO_PATH}:/workspaces/zmk-config"
#      - "${OUTPUT_ARTIFACTS_PATH}:/artifacts"
#    # This command keeps the container running in the background.
#    command: tail -f /dev/null
#EOF
#docker-compose pull > /dev/null 2>&1
#docker-compose up -d --force-recreate
#docker exec -it "${ZMK_DOCKER_CONTAINER_NAME}" /bin/bash "/artifacts/${INNER_SCRIPT_NAME}"

echo "Docker run finished."
echo "Firmware files (if successful) should be in: ${OUTPUT_ARTIFACTS_PATH}/"


# ======================================================================================================================
echo "--- Generating keymap visualization ---"

if [ ! -d "${PYTHON_VENV_DIR}" ]; then
  python3 -m venv "${PYTHON_VENV_DIR}"
  "${PYTHON_VENV_DIR}/bin/pip" install keymap-drawer
fi

echo "Step 1/2: Parsing ZMK keymap file: ${KBD_KEYMAP_FILE}"
"${PYTHON_VENV_DIR}/bin/keymap" parse -z "${KBD_KEYMAP_FILE}" > "${PARSED_KBD_KEYMAP_FILE}"

echo "Step 2/2: Drawing SVG"
"${PYTHON_VENV_DIR}/bin/keymap" draw "${PARSED_KBD_KEYMAP_FILE}" >"${OUTPUT_SVG_FILE}"

echo "--- Process complete! ---"