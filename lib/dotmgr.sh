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

# dm_version - print the toolkit version from the VERSION file.
dm_version() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if [ -f "$dir/VERSION" ]; then
    cat "$dir/VERSION"
  else
    printf 'unknown\n'
  fi
}

# dm_usage - print command-line help.
dm_usage() {
  cat <<'USAGE'
Usage: dotmgr [GLOBAL OPTIONS] COMMAND [ARGS]

Manage dotfiles by symlinking sources from a repository into a target
directory (your $HOME by default), driven by a manifest.

Commands:
  link                 Create managed symlinks, backing up any conflicts
  unlink [--restore]   Remove managed symlinks, optionally restoring a backup
  status               Show link / missing / conflict state for each entry
  backup               Snapshot the current target files
  restore [SNAPSHOT]   Restore a snapshot (latest when none is given)
  adopt PATH           Move an existing file into the repo and symlink it back

Global options:
  --repo DIR           Dotfiles repository (default: $DOTMGR_REPO or cwd)
  --target DIR         Where to link files (default: $HOME)
  --manifest FILE      Manifest path (default: <repo>/dotmgr.manifest)
  --backup-dir DIR     Backup root (default: XDG data dir)
  -n, --dry-run        Show actions without changing anything
  -h, --help           Show this help and exit
      --version        Print the version and exit
USAGE
}

# dm_main ARGS - parse global options and dispatch to a command.
dm_main() {
  : "${DOTMGR_REPO:=$PWD}"
  : "${DOTMGR_TARGET:=$HOME}"
  : "${DOTMGR_BACKUP_DIR:=${XDG_DATA_HOME:-$HOME/.local/share}/dotmgr/backups}"
  : "${DOTMGR_DRY_RUN:=0}"

  local cmd=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) DOTMGR_REPO="$2"; shift 2 ;;
      --repo=*) DOTMGR_REPO="${1#*=}"; shift ;;
      --target) DOTMGR_TARGET="$2"; shift 2 ;;
      --target=*) DOTMGR_TARGET="${1#*=}"; shift ;;
      --manifest) DOTMGR_MANIFEST="$2"; shift 2 ;;
      --manifest=*) DOTMGR_MANIFEST="${1#*=}"; shift ;;
      --backup-dir) DOTMGR_BACKUP_DIR="$2"; shift 2 ;;
      --backup-dir=*) DOTMGR_BACKUP_DIR="${1#*=}"; shift ;;
      -n|--dry-run) DOTMGR_DRY_RUN=1; shift ;;
      -h|--help) dm_usage; return 0 ;;
      --version) dm_version; return 0 ;;
      --) shift; break ;;
      -*) dm_usage >&2; die "unknown option: $1" ;;
      *) cmd="$1"; shift; break ;;
    esac
  done

  [ -n "$cmd" ] || { dm_usage >&2; die "no command given"; }
  : "${DOTMGR_MANIFEST:=${DOTMGR_REPO%/}/dotmgr.manifest}"

  case "$cmd" in
    link) cmd_link "$@" ;;
    unlink) cmd_unlink "$@" ;;
    status) cmd_status "$@" ;;
    backup) cmd_backup "$@" ;;
    restore) cmd_restore "$@" ;;
    adopt) cmd_adopt "$@" ;;
    help) dm_usage ;;
    *) dm_usage >&2; die "unknown command: $cmd" ;;
  esac
}

# dm_classify SRC_ABS DEST_ABS - echo the state of a single managed entry:
# "linked", "missing" or "conflict".
dm_classify() {
  local src_abs="$1" dest_abs="$2"
  if dm_is_linked "$dest_abs" "$src_abs"; then
    printf 'linked\n'
  elif [ -e "$dest_abs" ] || [ -L "$dest_abs" ]; then
    printf 'conflict\n'
  else
    printf 'missing\n'
  fi
}

# cmd_status - print the state of every manifest entry to stdout.
cmd_status() {
  local src dest src_abs dest_abs state
  while IFS=$'\t' read -r src dest; do
    src_abs="$(dm_abs_src "$src")"
    dest_abs="$(dm_expand_dest "$dest")"
    state="$(dm_classify "$src_abs" "$dest_abs")"
    printf '%-9s %s -> %s\n' "$state" "$dest" "$src"
  done < <(dm_parse_manifest "$DOTMGR_MANIFEST")
}

# dm_latest_snapshot - print the newest snapshot directory under the backup
# root, or return non-zero when there are none. Snapshot names are timestamps,
# so lexical order matches chronological order.
dm_latest_snapshot() {
  [ -d "$DOTMGR_BACKUP_DIR" ] || return 1
  local d newest=""
  for d in "$DOTMGR_BACKUP_DIR"/*/; do
    [ -d "$d" ] || continue
    newest="$d"
  done
  [ -n "$newest" ] || return 1
  printf '%s\n' "${newest%/}"
}

# dm_restore_from SNAPDIR - move every file and symlink from a snapshot back
# to its original location under the target directory.
dm_restore_from() {
  local snap="${1%/}" f rel dest
  [ -d "$snap" ] || die "snapshot not found: $snap"
  while IFS= read -r -d '' f; do
    rel="${f#"$snap"/}"
    dest="${DOTMGR_TARGET%/}/$rel"
    dm_do mkdir -p "$(dirname "$dest")"
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      dm_do rm -rf "$dest"
    fi
    dm_do mv "$f" "$dest"
    info "restored: $rel"
  done < <(find "$snap" -mindepth 1 \( -type f -o -type l \) -print0)
}

# cmd_unlink [--restore] - remove managed symlinks. With --restore, the latest
# backup snapshot is restored afterwards.
cmd_unlink() {
  local do_restore=0 src dest src_abs dest_abs
  while [ $# -gt 0 ]; do
    case "$1" in
      --restore) do_restore=1; shift ;;
      -*) die "unknown unlink option: $1" ;;
      *) die "unlink takes no positional arguments" ;;
    esac
  done
  while IFS=$'\t' read -r src dest; do
    src_abs="$(dm_abs_src "$src")"
    dest_abs="$(dm_expand_dest "$dest")"
    if dm_is_linked "$dest_abs" "$src_abs"; then
      dm_do rm "$dest_abs"
      info "unlinked: $dest"
    else
      info "not managed, leaving in place: $dest"
    fi
  done < <(dm_parse_manifest "$DOTMGR_MANIFEST")
  if [ "$do_restore" -eq 1 ]; then
    local snap
    snap="$(dm_latest_snapshot)" || die "no backups to restore"
    dm_restore_from "$snap"
  fi
}

# cmd_backup - copy the current target files for every manifest entry into a
# fresh timestamped snapshot. Symlinks are preserved as symlinks.
cmd_backup() {
  local snap made=0 src dest dest_abs rel bpath
  snap="${DOTMGR_BACKUP_DIR%/}/$(dm_timestamp)"
  while IFS=$'\t' read -r src dest; do
    dest_abs="$(dm_expand_dest "$dest")"
    if [ ! -e "$dest_abs" ] && [ ! -L "$dest_abs" ]; then
      continue
    fi
    if [ "$made" -eq 0 ]; then
      dm_do mkdir -p "$snap"
      made=1
    fi
    rel="$(dm_rel_to_target "$dest_abs")"
    bpath="$snap/$rel"
    dm_do mkdir -p "$(dirname "$bpath")"
    dm_do cp -a "$dest_abs" "$bpath"
    info "snapshot: $rel"
  done < <(dm_parse_manifest "$DOTMGR_MANIFEST")
  if [ "$made" -eq 0 ]; then
    warn "nothing to snapshot"
  else
    info "snapshot written to $snap"
  fi
}

# cmd_restore [SNAPSHOT] - restore a snapshot. With no argument the latest is
# used; a bare name is resolved under the backup root, and an absolute or
# existing path is used as given.
cmd_restore() {
  local arg="${1:-}" snap
  if [ -z "$arg" ]; then
    snap="$(dm_latest_snapshot)" || die "no backups to restore"
  elif [ -d "$arg" ]; then
    snap="$arg"
  else
    snap="${DOTMGR_BACKUP_DIR%/}/$arg"
  fi
  dm_restore_from "$snap"
}
