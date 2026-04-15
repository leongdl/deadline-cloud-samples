#!/bin/bash
# Simple Plugin Delivery for Blender
# Downloads plugin files from S3 and configures BLENDER_USER_SCRIPTS.
# Runs after all standard Blender env vars are set (999- prefix ensures
# lexicographic ordering).
#
# S3 convention: s3://<bucket>/<prefix>/plugins/<os>/blender/<version>/
# Generic path:  s3://<bucket>/<prefix>/plugins/generic/
#
# Required environment variables (set by the worker agent):
#   DEADLINE_JA_S3_BUCKET      - Job attachment S3 bucket name
#   DEADLINE_JA_ROOT_PREFIX    - Job attachment root prefix in the bucket
#   OPENJD_SESSION_WORKING_DIR - Session working directory path

# Skip if the required env vars aren't available (e.g. local testing without
# the worker agent, or the worker agent hasn't been updated yet).
if [ -z "${DEADLINE_JA_S3_BUCKET:-}" ] || [ -z "${BLENDER_VERSION:-}" ]; then
    return 0 2>/dev/null || exit 0
fi

_SP_PREFIX="${DEADLINE_JA_ROOT_PREFIX:+${DEADLINE_JA_ROOT_PREFIX}/}"
_SP_OS="linux"
if [ "$(uname -s)" = "MINGW"* ] || [ "$(uname -s)" = "MSYS"* ] || [ -n "${OS:-}" ]; then
    _SP_OS="windows"
fi

# Determine plugin download directory
_SP_PLUGIN_DIR="${OPENJD_SESSION_WORKING_DIR:-${TMPDIR:-/tmp}}/deadline-plugins/blender"
mkdir -p "$_SP_PLUGIN_DIR"

# Download generic plugins to the session working directory
_SP_GENERIC_DIR="${OPENJD_SESSION_WORKING_DIR:-${TMPDIR:-/tmp}}/deadline-plugins/generic"
_SP_GENERIC_SRC="s3://${DEADLINE_JA_S3_BUCKET}/${_SP_PREFIX}plugins/generic/"
if aws s3 ls "$_SP_GENERIC_SRC" >/dev/null 2>&1; then
    mkdir -p "$_SP_GENERIC_DIR"
    echo "Simple Plugins: Downloading generic plugins from $_SP_GENERIC_SRC"
    aws s3 cp "$_SP_GENERIC_SRC" "$_SP_GENERIC_DIR/" --recursive --quiet 2>/dev/null || true
fi

# Download Blender-specific plugins
_SP_DCC_SRC="s3://${DEADLINE_JA_S3_BUCKET}/${_SP_PREFIX}plugins/${_SP_OS}/blender/${BLENDER_VERSION}/"
if aws s3 ls "$_SP_DCC_SRC" >/dev/null 2>&1; then
    echo "Simple Plugins: Downloading Blender plugins from $_SP_DCC_SRC"
    aws s3 cp "$_SP_DCC_SRC" "$_SP_PLUGIN_DIR/" --recursive --quiet 2>/dev/null || true
fi

# Configure Blender to find the plugins via BLENDER_USER_SCRIPTS
# Blender scans $BLENDER_USER_SCRIPTS/addons/ for addon directories/files.
# We create the expected subdirectory structure.
if [ -d "$_SP_PLUGIN_DIR" ] && [ "$(ls -A "$_SP_PLUGIN_DIR" 2>/dev/null)" ]; then
    mkdir -p "$_SP_PLUGIN_DIR/addons"
    # Move any top-level .py or .zip files into addons/
    find "$_SP_PLUGIN_DIR" -maxdepth 1 -name '*.py' -o -name '*.zip' | while read -r f; do
        mv "$f" "$_SP_PLUGIN_DIR/addons/"
    done
    # Move any top-level directories (addon packages) into addons/
    find "$_SP_PLUGIN_DIR" -maxdepth 1 -mindepth 1 -type d ! -name addons | while read -r d; do
        _target="$_SP_PLUGIN_DIR/addons/$(basename "$d")"
        if [ -d "$_target" ]; then
            cp -rf "$d"/* "$_target"/ 2>/dev/null || true
            rm -rf "$d"
        else
            mv "$d" "$_SP_PLUGIN_DIR/addons/"
        fi
    done

    export BLENDER_USER_SCRIPTS="$_SP_PLUGIN_DIR"
    export _SP_PLUGIN_DIR
    echo "Simple Plugins: BLENDER_USER_SCRIPTS=$_SP_PLUGIN_DIR"
else
    echo "Simple Plugins: No Blender plugins found, skipping."
fi

# Clean up temp variables
unset _SP_PREFIX _SP_OS _SP_GENERIC_DIR _SP_GENERIC_SRC _SP_DCC_SRC
