#!/usr/bin/env bash
#
# dotmgr.sh - core library for the dotmgr dotfiles manager.
#
# This file is sourced by bin/dotmgr and by the bats test suite. It only
# defines functions and does not enable errexit itself, leaving shell option
# control to the caller (bin/dotmgr sets `set -euo pipefail`).
#
# The functions operate on four globals, which bin/dotmgr fills with defaults
# and the test suite sets explicitly:
#
#   DOTMGR_REPO       directory holding the tracked dotfiles
#   DOTMGR_TARGET     directory the files are linked into (usually $HOME)
#   DOTMGR_MANIFEST   manifest file mapping repo sources to targets
#   DOTMGR_BACKUP_DIR root under which timestamped backups are written
#   DOTMGR_DRY_RUN    when 1, mutating actions are logged but not performed

# Colour output only when stderr is a terminal.
if [ -t 2 ]; then
  _DM_C_RED=$'\033[31m'
  _DM_C_YELLOW=$'\033[33m'
  _DM_C_RESET=$'\033[0m'
else
  _DM_C_RED=""
  _DM_C_YELLOW=""
  _DM_C_RESET=""
fi

_dm_ts() {
  date +"%Y-%m-%dT%H:%M:%S%z"
}

# info MESSAGE... - log an informational line to stderr.
info() {
  printf '%s [INFO] %s\n' "$(_dm_ts)" "$*" >&2
}

# warn MESSAGE... - log a warning to stderr.
warn() {
  printf '%s [WARN] %s%s%s\n' "$(_dm_ts)" "$_DM_C_YELLOW" "$*" "$_DM_C_RESET" >&2
}

# die MESSAGE... - log an error to stderr and exit non-zero.
die() {
  printf '%s [ERROR] %s%s%s\n' "$(_dm_ts)" "$_DM_C_RED" "$*" "$_DM_C_RESET" >&2
  exit 1
}

# dm_dry_run - true when the caller asked for a dry run.
dm_dry_run() {
  [ "${DOTMGR_DRY_RUN:-0}" = "1" ]
}

# dm_do COMMAND... - run a mutating command, or log it under --dry-run.
dm_do() {
  if dm_dry_run; then
    info "[dry-run] $*"
    return 0
  fi
  "$@"
}

# dm_timestamp - a sortable stamp used to name backup snapshots.
dm_timestamp() {
  date +"%Y%m%d-%H%M%S"
}

# dm_abs_src SRC - absolute path of a manifest source inside the repo.
dm_abs_src() {
  printf '%s\n' "${DOTMGR_REPO%/}/$1"
}

# dm_expand_dest DEST - resolve a manifest destination to an absolute path.
#
# A leading "/" is kept verbatim, a leading "~" expands against the target
# directory, and anything else is treated as relative to the target.
dm_expand_dest() {
  local dest="$1"
  case "$dest" in
    /*) printf '%s\n' "$dest" ;;
    "~") printf '%s\n' "${DOTMGR_TARGET%/}" ;;
    "~/"*) printf '%s\n' "${DOTMGR_TARGET%/}/${dest#\~/}" ;;
    *) printf '%s\n' "${DOTMGR_TARGET%/}/$dest" ;;
  esac
}

# dm_rel_to_target PATH - path relative to the target dir, or its basename
# when the path lives outside the target. Used to lay out backups.
dm_rel_to_target() {
  local path="$1" base="${DOTMGR_TARGET%/}"
  case "$path" in
    "$base"/*) printf '%s\n' "${path#"$base"/}" ;;
    *) basename "$path" ;;
  esac
}
