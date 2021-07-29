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
  local dest="$1" tilde='~'
  case "$dest" in
    /*) printf '%s\n' "$dest" ;;
    "$tilde") printf '%s\n' "${DOTMGR_TARGET%/}" ;;
    "$tilde"/*) printf '%s\n' "${DOTMGR_TARGET%/}/${dest:2}" ;;
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

# dm_trim STRING - strip leading and trailing whitespace.
dm_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# dm_parse_manifest FILE - emit normalised "SRC<TAB>DEST" rows.
#
# Manifest lines are one of:
#   src -> dest    explicit mapping
#   path           shorthand for "path -> path"
# Blank lines and lines whose first non-space character is '#' are ignored.
dm_parse_manifest() {
  local file="$1" line src dest
  [ -f "$file" ] || die "manifest not found: $file"
  while IFS= read -r line || [ -n "$line" ]; do
    line="$(dm_trim "$line")"
    [ -z "$line" ] && continue
    case "$line" in
      \#*) continue ;;
    esac
    if [[ "$line" == *"->"* ]]; then
      src="$(dm_trim "${line%%->*}")"
      dest="$(dm_trim "${line#*->}")"
    else
      src="$line"
      dest="$line"
    fi
    [ -n "$src" ] || die "manifest line has empty source: $line"
    [ -n "$dest" ] || die "manifest line has empty destination: $line"
    printf '%s\t%s\n' "$src" "$dest"
  done < "$file"
}

# dm_is_linked DEST SRC - true when DEST is a symlink already pointing at SRC.
dm_is_linked() {
  local dest="$1" src="$2"
  [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]
}

# dm_backup_into DEST RUNDIR - move an existing DEST into the backup run dir,
# preserving its path relative to the target directory.
dm_backup_into() {
  local dest="$1" rundir="$2" rel bpath
  rel="$(dm_rel_to_target "$dest")"
  bpath="$rundir/$rel"
  dm_do mkdir -p "$(dirname "$bpath")"
  dm_do mv "$dest" "$bpath"
  info "backed up: $dest -> $bpath"
}

# cmd_link - link every manifest entry into the target directory.
#
# Existing real files or foreign symlinks are moved into a single timestamped
# backup run before the managed symlink is created. Entries that are already
# correctly linked are left untouched, which makes re-running a no-op.
cmd_link() {
  [ -d "$DOTMGR_REPO" ] || die "repo directory not found: $DOTMGR_REPO"
  local run_dir made_backup=0 src dest src_abs dest_abs
  run_dir="${DOTMGR_BACKUP_DIR%/}/$(dm_timestamp)"
  while IFS=$'\t' read -r src dest; do
    src_abs="$(dm_abs_src "$src")"
    dest_abs="$(dm_expand_dest "$dest")"
    if [ ! -e "$src_abs" ] && [ ! -L "$src_abs" ]; then
      warn "source missing in repo, skipping: $src"
      continue
    fi
    if dm_is_linked "$dest_abs" "$src_abs"; then
      info "ok: $dest already linked"
      continue
    fi
    if [ -e "$dest_abs" ] || [ -L "$dest_abs" ]; then
      if [ "$made_backup" -eq 0 ]; then
        dm_do mkdir -p "$run_dir"
        made_backup=1
      fi
      dm_backup_into "$dest_abs" "$run_dir"
    fi
    dm_do mkdir -p "$(dirname "$dest_abs")"
    dm_do ln -s "$src_abs" "$dest_abs"
    info "linked: $dest -> $src"
  done < <(dm_parse_manifest "$DOTMGR_MANIFEST")
}
