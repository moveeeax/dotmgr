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

# err MESSAGE... - log an error to stderr without exiting, for callers that
# need an exit status other than die's 1.
err() {
  printf '%s [ERROR] %s%s%s\n' "$(_dm_ts)" "$_DM_C_RED" "$*" "$_DM_C_RESET" >&2
}

# die MESSAGE... - log an error to stderr and exit non-zero.
die() {
  err "$@"
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

# dm_require_repo - abort unless the configured repository directory exists.
dm_require_repo() {
  [ -d "$DOTMGR_REPO" ] || die "repo directory not found: $DOTMGR_REPO"
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

# Snapshot subdirectory holding destinations that live outside the target
# directory. Kept deliberately unlikely to collide with a real dotfile name.
_DM_ABS_PREFIX="_dotmgr_abs"

# dm_rel_to_target PATH - the snapshot-relative location used to store PATH.
#
# Paths under the target directory keep their relative layout. An absolute
# path outside the target is stored under "$_DM_ABS_PREFIX/" with its full
# path preserved, so that two entries sharing a basename cannot overwrite each
# other in a snapshot and so that dm_restore_from can put the file back where
# it actually came from.
dm_rel_to_target() {
  local path="$1" base="${DOTMGR_TARGET%/}"
  case "$path" in
    "$base"/*) printf '%s\n' "${path#"$base"/}" ;;
    /*) printf '%s\n' "$_DM_ABS_PREFIX/${path#/}" ;;
    *) basename "$path" ;;
  esac
}

# dm_reject_traversal LABEL PATH - abort when PATH has a ".." component.
#
# Without this a manifest entry such as "x -> ../../.ssh/authorized_keys"
# resolves outside the target directory. Absolute destinations are still
# supported and are the intended way to manage files elsewhere.
dm_reject_traversal() {
  case "/$2/" in
    */../*) die "$1 must not contain a '..' path component: $2" ;;
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
    dm_reject_traversal "manifest source" "$src"
    dm_reject_traversal "manifest destination" "$dest"
    printf '%s\t%s\n' "$src" "$dest"
  done < "$file"
}

# dm_load_manifest - parse DOTMGR_MANIFEST into the DM_MANIFEST_ROWS global.
#
# dm_parse_manifest reports fatal problems with die(), and die() runs `exit`
# in whichever shell it happens to be in. Read as `< <(dm_parse_manifest ...)`
# that shell is only the process-substitution subshell, so every command
# silently carried on with an empty entry list and still returned success --
# `dotmgr link` against a mistyped manifest path exited 0 having done nothing.
# A checked command substitution puts that failure back in the caller's hands.
dm_load_manifest() {
  DM_MANIFEST_ROWS="$(dm_parse_manifest "$DOTMGR_MANIFEST")" || return 1
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
  dm_require_repo
  local run_dir made_backup=0 src dest src_abs dest_abs
  run_dir="${DOTMGR_BACKUP_DIR%/}/$(dm_timestamp)"
  dm_load_manifest || return 1
  while IFS=$'\t' read -r src dest; do
    [ -n "$src" ] || continue
    src_abs="$(dm_abs_src "$src")"
    dest_abs="$(dm_expand_dest "$dest")"
    # Linking a path to itself moves the only real copy into a backup and
    # leaves a self-referential symlink behind, which later runs then report
    # as "linked". Refuse instead of destroying the file.
    if [ "$src_abs" = "$dest_abs" ]; then
      die "manifest entry maps a path onto itself, refusing to link: $src -> $dest (both resolve to $src_abs)"
    fi
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
  done <<< "$DM_MANIFEST_ROWS"
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
  status [--porcelain | -q]
                       Show linked / missing / conflict / nosource per entry;
                       exits 0 when all are linked, 1 on drift, 2 on a
                       manifest error
  backup               Snapshot the current target files
  restore [SNAPSHOT]   Restore a snapshot (latest when none is given)
  adopt PATH           Move an existing file into the repo and symlink it back
  ssh [--inventory FILE] [--env NAME] [--out FILE] [--no-validate]
                       Render ssh Host blocks from an inventory into the
                       marked region of an ssh config (default ~/.ssh/config)

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

  # These directories are the base of every path this tool creates, moves and
  # removes. An empty value (an unset or blank $HOME, an option given an empty
  # argument) would silently retarget all of that at the filesystem root, so
  # refuse rather than trust the environment.
  [ -n "$DOTMGR_REPO" ] || die "repo directory must not be empty"
  [ -n "$DOTMGR_TARGET" ] || die "target directory must not be empty"
  [ -n "$DOTMGR_BACKUP_DIR" ] || die "backup directory must not be empty"
  [ -n "${DOTMGR_TARGET%/}" ] || die "target directory must not be the filesystem root"

  # Anchor a relative --repo/--target/--backup-dir to the invocation cwd.
  #
  # DOTMGR_REPO in particular becomes literal symlink target text in
  # dm_abs_src: `ln -s "$src_abs" "$dest_abs"`. Left relative, the symlink is
  # resolved by the kernel against the *symlink's own directory*, not the cwd
  # dotmgr was run from. `dotmgr --repo dotfiles link` run from anywhere other
  # than the target directory silently produced dangling links pointing at
  # "dotfiles/..." under $HOME instead of the intended checkout. Target and
  # backup-dir are normalised too so every path this tool prints or records
  # stays meaningful after the process's cwd is no longer available.
  case "$DOTMGR_REPO" in
    /*) ;;
    *) DOTMGR_REPO="$PWD/$DOTMGR_REPO" ;;
  esac
  case "$DOTMGR_TARGET" in
    /*) ;;
    *) DOTMGR_TARGET="$PWD/$DOTMGR_TARGET" ;;
  esac
  case "$DOTMGR_BACKUP_DIR" in
    /*) ;;
    *) DOTMGR_BACKUP_DIR="$PWD/$DOTMGR_BACKUP_DIR" ;;
  esac

  : "${DOTMGR_MANIFEST:=${DOTMGR_REPO%/}/dotmgr.manifest}"
  [ -n "$DOTMGR_MANIFEST" ] || die "manifest path must not be empty"

  case "$cmd" in
    link) cmd_link "$@" ;;
    unlink) cmd_unlink "$@" ;;
    status) cmd_status "$@" ;;
    backup) cmd_backup "$@" ;;
    restore) cmd_restore "$@" ;;
    adopt) cmd_adopt "$@" ;;
    ssh) cmd_ssh "$@" ;;
    help) dm_usage ;;
    *) dm_usage >&2; die "unknown command: $cmd" ;;
  esac
}

# dm_classify SRC_ABS DEST_ABS - echo the state of a single managed entry:
# "nosource", "linked", "missing" or "conflict".
#
# "nosource" wins over the other states: when the repo file is gone a managed
# symlink is dangling and `link` would skip the entry, so reporting it as
# "linked" or "missing" would point the user at the wrong fix.
dm_classify() {
  local src_abs="$1" dest_abs="$2"
  if [ ! -e "$src_abs" ] && [ ! -L "$src_abs" ]; then
    printf 'nosource\n'
  elif dm_is_linked "$dest_abs" "$src_abs"; then
    printf 'linked\n'
  elif [ -e "$dest_abs" ] || [ -L "$dest_abs" ]; then
    printf 'conflict\n'
  else
    printf 'missing\n'
  fi
}

# cmd_status [--porcelain | -q] - print the state of every manifest entry to
# stdout and report drift through the exit status:
#
#   0  every entry is linked (an empty manifest counts)
#   1  at least one entry is missing, conflict or nosource
#   2  the manifest cannot be read or parsed, or the arguments are invalid
#
# Default output is aligned text for people. --porcelain prints
# "STATE<TAB>DEST<TAB>SRC" per entry with DEST and SRC as written in the
# manifest, a format that will stay stable. -q prints only the per-state
# counts on one line.
cmd_status() {
  local mode="text" src dest src_abs dest_abs state
  local n_linked=0 n_missing=0 n_conflict=0 n_nosource=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --porcelain) mode="porcelain"; shift ;;
      -q|--quiet) mode="quiet"; shift ;;
      -*) err "unknown status option: $1"; return 2 ;;
      *) err "status takes no positional arguments"; return 2 ;;
    esac
  done
  dm_load_manifest || return 2
  while IFS=$'\t' read -r src dest; do
    [ -n "$src" ] || continue
    src_abs="$(dm_abs_src "$src")"
    dest_abs="$(dm_expand_dest "$dest")"
    state="$(dm_classify "$src_abs" "$dest_abs")"
    case "$state" in
      linked) n_linked=$((n_linked + 1)) ;;
      missing) n_missing=$((n_missing + 1)) ;;
      conflict) n_conflict=$((n_conflict + 1)) ;;
      nosource) n_nosource=$((n_nosource + 1)) ;;
    esac
    case "$mode" in
      text) printf '%-9s %s -> %s\n' "$state" "$dest" "$src" ;;
      porcelain) printf '%s\t%s\t%s\n' "$state" "$dest" "$src" ;;
    esac
  done <<< "$DM_MANIFEST_ROWS"
  if [ "$mode" = "quiet" ]; then
    printf 'linked=%d missing=%d conflict=%d nosource=%d\n' \
      "$n_linked" "$n_missing" "$n_conflict" "$n_nosource"
  fi
  [ $((n_missing + n_conflict + n_nosource)) -eq 0 ] || return 1
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
    case "$rel" in
      "$_DM_ABS_PREFIX"/*) dest="/${rel#"$_DM_ABS_PREFIX"/}" ;;
      *) dest="${DOTMGR_TARGET%/}/$rel" ;;
    esac
    # Last line of defence: an empty or root destination here would hand the
    # filesystem root to rm -rf.
    case "$dest" in
      "" | "/") die "refusing to restore to unsafe path: '$dest'" ;;
    esac
    dm_do mkdir -p "$(dirname "$dest")"
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      dm_do rm -rf "$dest"
    fi
    dm_do mv "$f" "$dest"
    info "restored: $dest"
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
  dm_load_manifest || return 1
  while IFS=$'\t' read -r src dest; do
    [ -n "$src" ] || continue
    src_abs="$(dm_abs_src "$src")"
    dest_abs="$(dm_expand_dest "$dest")"
    if dm_is_linked "$dest_abs" "$src_abs"; then
      dm_do rm "$dest_abs"
      info "unlinked: $dest"
    else
      info "not managed, leaving in place: $dest"
    fi
  done <<< "$DM_MANIFEST_ROWS"
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
  dm_load_manifest || return 1
  while IFS=$'\t' read -r src dest; do
    [ -n "$src" ] || continue
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
  done <<< "$DM_MANIFEST_ROWS"
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

# dm_append_manifest SRC DEST - append a mapping line to the manifest.
dm_append_manifest() {
  printf '%s -> %s\n' "$1" "$2" >> "$DOTMGR_MANIFEST"
}

# dm_manifest_has SRC - true when the manifest already lists SRC as a source.
dm_manifest_has() {
  local want="$1" src dest
  [ -f "$DOTMGR_MANIFEST" ] || return 1
  dm_load_manifest || return 1
  while IFS=$'\t' read -r src dest; do
    [ "$src" = "$want" ] && return 0
  done <<< "$DM_MANIFEST_ROWS"
  return 1
}

# cmd_adopt PATH - move an existing real file at PATH into the repo at the
# matching relative location, replace it with a symlink, and record it in the
# manifest if it is not already listed.
cmd_adopt() {
  [ $# -eq 1 ] || die "adopt requires exactly one PATH"
  dm_require_repo
  local dest_abs rel src_abs base="${DOTMGR_TARGET%/}"
  dm_reject_traversal "adopt path" "$1"
  dest_abs="$(dm_expand_dest "$1")"
  # Outside the target directory the repo-relative location collapses to a
  # basename, so the manifest entry it writes points somewhere else entirely:
  # link/status/unlink would all act on $TARGET/<basename> while the real
  # symlink sat at the original path, permanently orphaned.
  case "$dest_abs" in
    "$base"/*) ;;
    *) die "adopt only handles paths under the target directory ($base): $dest_abs" ;;
  esac
  if [ -L "$dest_abs" ]; then
    die "already a symlink, nothing to adopt: $dest_abs"
  fi
  if [ ! -e "$dest_abs" ]; then
    die "no such file to adopt: $dest_abs"
  fi
  rel="$(dm_rel_to_target "$dest_abs")"
  src_abs="$(dm_abs_src "$rel")"
  if [ -e "$src_abs" ] || [ -L "$src_abs" ]; then
    die "repo already has a file at: $src_abs"
  fi
  dm_do mkdir -p "$(dirname "$src_abs")"
  dm_do mv "$dest_abs" "$src_abs"
  dm_do ln -s "$src_abs" "$dest_abs"
  info "adopted: $rel"
  if dm_manifest_has "$rel"; then
    info "manifest already lists: $rel"
  else
    dm_do dm_append_manifest "$rel" "$rel"
    info "added to manifest: $rel -> $rel"
  fi
}

# --- ssh config rendering -------------------------------------------------
#
# `dotmgr ssh` renders Host blocks from an inventory file into one marked
# region of an ssh config file and leaves every other byte of that file alone.
#
# The inventory is an INI-style text file rather than YAML so the tool stays
# dependency-free. Sections:
#
#   [defaults]            options for every host
#   [env NAME]            options for every host when rendering --env NAME
#   [group NAME]          options for hosts that list NAME in `groups`
#   [group NAME @ENV]     group options that apply only under --env ENV
#   [host NAME]           one host; `groups` and `envs` are dotmgr keys
#   [host NAME @ENV]      host options that apply only under --env ENV
#   [match CRITERIA]      emitted verbatim as a `Match CRITERIA` block
#
# Option lines are "Key = value" or "Key value", as in ssh_config. For each
# host the layers are applied in the order defaults, env, each group in the
# order listed (plain, then @ENV), host, host @ENV; a later layer that sets a
# key replaces every earlier value of that key, and repeated lines for one key
# inside a single section are all kept (IdentityFile, LocalForward, ...).

_DM_SSH_BEGIN="# BEGIN dotmgr ssh"
_DM_SSH_END="# END dotmgr ssh"

# dm_ssh_valid_name NAME - true for a section name without whitespace or ssh
# pattern characters, so every rendered Host line is one canonical name.
dm_ssh_valid_name() {
  [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.:%+-]*$ ]]
}

# dm_ssh_section_index KIND NAME ENV - print the index of a parsed section
# header, or return non-zero when there is none.
dm_ssh_section_index() {
  local i
  for ((i = 0; i < ${#_DM_SSH_SEC_KIND[@]}; i++)); do
    if [ "${_DM_SSH_SEC_KIND[$i]}" = "$1" ] && [ "${_DM_SSH_SEC_NAME[$i]}" = "$2" ] \
      && [ "${_DM_SSH_SEC_ENV[$i]}" = "$3" ]; then
      printf '%s\n' "$i"
      return 0
    fi
  done
  return 1
}

# dm_ssh_has_word LIST WORD - true when the whitespace-separated LIST has WORD.
dm_ssh_has_word() {
  case " $1 " in
    *" $2 "*) return 0 ;;
  esac
  return 1
}

# dm_ssh_load_inventory FILE - parse an inventory into the _DM_SSH_* globals.
#
# Sections are stored in _DM_SSH_SEC_{KIND,NAME,ENV} (ENV is "-" when absent)
# and options in _DM_SSH_OPT_{SEC,KEY,LKEY,VAL}, where SEC is the index of the
# owning section and LKEY the lower-cased key used for merging, since ssh
# keywords are case-insensitive. Host `groups`/`envs` lists are kept in
# _DM_SSH_SEC_GROUPS/_DM_SSH_SEC_ENVS. Any problem aborts via die(), which
# runs in the caller's shell because this function is not called in a
# subshell.
dm_ssh_load_inventory() {
  local file="$1" line n=0 hdr kind name env extra key lkey value cur=-1 i
  local -a words
  [ -f "$file" ] || die "ssh inventory not found: $file"
  _DM_SSH_SEC_KIND=() _DM_SSH_SEC_NAME=() _DM_SSH_SEC_ENV=()
  _DM_SSH_SEC_GROUPS=() _DM_SSH_SEC_ENVS=()
  _DM_SSH_OPT_SEC=() _DM_SSH_OPT_KEY=() _DM_SSH_OPT_LKEY=() _DM_SSH_OPT_VAL=()
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="$(dm_trim "$line")"
    [ -z "$line" ] && continue
    case "$line" in
      \#*) continue ;;
    esac
    if [[ "$line" == "["*"]" ]]; then
      hdr="$(dm_trim "${line:1:${#line}-2}")"
      kind="" name="-" env="-" extra=""
      read -r kind name env extra <<< "$hdr"
      : "${name:=-}" "${env:=-}"
      case "$kind" in
        defaults)
          [ "$name" = "-" ] || die "$file:$n: [defaults] takes no name"
          ;;
        env)
          [ "$env" = "-" ] || die "$file:$n: [env NAME] takes no @ENV"
          ;;
        group | host)
          if [ "$env" != "-" ]; then
            if [ -n "$extra" ] || [[ "$env" != @?* ]]; then
              die "$file:$n: expected [$kind NAME] or [$kind NAME @ENV]: $line"
            fi
            env="${env#@}"
            dm_ssh_valid_name "$env" || die "$file:$n: invalid env name: $env"
          fi
          ;;
        match)
          # Criteria are passed through as written; ssh -G checks them.
          name="$(dm_trim "${hdr#match}")"
          env="-" extra=""
          [ -n "$name" ] || die "$file:$n: [match] needs criteria"
          ;;
        *) die "$file:$n: unknown section: $line" ;;
      esac
      if [ "$kind" != "defaults" ] && [ "$kind" != "match" ]; then
        dm_ssh_valid_name "$name" || die "$file:$n: invalid $kind name: $name"
      fi
      [ -z "$extra" ] || die "$file:$n: unexpected text in section header: $line"
      if dm_ssh_section_index "$kind" "$name" "$env" > /dev/null; then
        die "$file:$n: duplicate section: $line"
      fi
      cur=${#_DM_SSH_SEC_KIND[@]}
      _DM_SSH_SEC_KIND+=("$kind") _DM_SSH_SEC_NAME+=("$name") _DM_SSH_SEC_ENV+=("$env")
      _DM_SSH_SEC_GROUPS+=("") _DM_SSH_SEC_ENVS+=("")
      continue
    fi
    [ "$cur" -ge 0 ] || die "$file:$n: option outside of any section: $line"
    if [[ "$line" =~ ^([A-Za-z][A-Za-z0-9]*)[[:space:]]*=[[:space:]]*(.*)$ ]] \
      || [[ "$line" =~ ^([A-Za-z][A-Za-z0-9]*)[[:space:]]+(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="$(dm_trim "${BASH_REMATCH[2]}")"
    else
      die "$file:$n: expected 'Key = value': $line"
    fi
    [ -n "$value" ] || die "$file:$n: option has no value: $key"
    lkey="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
    case "$lkey" in
      groups | envs)
        if [ "${_DM_SSH_SEC_KIND[$cur]}" != "host" ] || [ "${_DM_SSH_SEC_ENV[$cur]}" != "-" ]; then
          die "$file:$n: '$key' is only valid in a [host NAME] section"
        fi
        value="${value//,/ }"
        # Collapse runs of separators so membership checks see single spaces.
        read -r -a words <<< "$value"
        value="${words[*]:-}"
        if [ "$lkey" = "groups" ]; then
          _DM_SSH_SEC_GROUPS[cur]="$value"
        else
          _DM_SSH_SEC_ENVS[cur]="$value"
        fi
        continue
        ;;
      host | match)
        die "$file:$n: '$key' cannot be an option; use a [host] or [match] section"
        ;;
    esac
    _DM_SSH_OPT_SEC+=("$cur") _DM_SSH_OPT_KEY+=("$key")
    _DM_SSH_OPT_LKEY+=("$lkey") _DM_SSH_OPT_VAL+=("$value")
  done < "$file"

  # Cross-references: catch typos instead of silently rendering without them.
  local g e
  for ((i = 0; i < ${#_DM_SSH_SEC_KIND[@]}; i++)); do
    env="${_DM_SSH_SEC_ENV[$i]}"
    if [ "$env" != "-" ]; then
      dm_ssh_section_index env "$env" - > /dev/null \
        || die "$file: section [${_DM_SSH_SEC_KIND[$i]} ${_DM_SSH_SEC_NAME[$i]} @$env] uses undeclared env: $env"
      dm_ssh_section_index "${_DM_SSH_SEC_KIND[$i]}" "${_DM_SSH_SEC_NAME[$i]}" - > /dev/null \
        || die "$file: [${_DM_SSH_SEC_KIND[$i]} ${_DM_SSH_SEC_NAME[$i]} @$env] has no matching [${_DM_SSH_SEC_KIND[$i]} ${_DM_SSH_SEC_NAME[$i]}] section"
    fi
    for g in ${_DM_SSH_SEC_GROUPS[$i]}; do
      dm_ssh_section_index group "$g" - > /dev/null \
        || die "$file: host ${_DM_SSH_SEC_NAME[$i]} lists undeclared group: $g"
    done
    for e in ${_DM_SSH_SEC_ENVS[$i]}; do
      dm_ssh_section_index env "$e" - > /dev/null \
        || die "$file: host ${_DM_SSH_SEC_NAME[$i]} lists undeclared env: $e"
    done
  done
}

# dm_ssh_apply_layer SECTION_INDEX - merge one section's options into the
# _DM_SSH_R_{LKEY,KEY,VAL} resolution arrays. Every key the section sets drops
# all earlier values of that key first.
dm_ssh_apply_layer() {
  local sec="$1" i j lk replaced=" "
  local -a nl nk nv
  for ((i = 0; i < ${#_DM_SSH_OPT_SEC[@]}; i++)); do
    [ "${_DM_SSH_OPT_SEC[$i]}" = "$sec" ] || continue
    lk="${_DM_SSH_OPT_LKEY[$i]}"
    if ! dm_ssh_has_word "$replaced" "$lk"; then
      nl=() nk=() nv=()
      for ((j = 0; j < ${#_DM_SSH_R_LKEY[@]}; j++)); do
        [ "${_DM_SSH_R_LKEY[$j]}" = "$lk" ] && continue
        nl+=("${_DM_SSH_R_LKEY[$j]}") nk+=("${_DM_SSH_R_KEY[$j]}") nv+=("${_DM_SSH_R_VAL[$j]}")
      done
      _DM_SSH_R_LKEY=() _DM_SSH_R_KEY=() _DM_SSH_R_VAL=()
      for ((j = 0; j < ${#nl[@]}; j++)); do
        _DM_SSH_R_LKEY+=("${nl[$j]}") _DM_SSH_R_KEY+=("${nk[$j]}") _DM_SSH_R_VAL+=("${nv[$j]}")
      done
      replaced="$replaced$lk "
    fi
    _DM_SSH_R_LKEY+=("$lk") _DM_SSH_R_KEY+=("${_DM_SSH_OPT_KEY[$i]}") _DM_SSH_R_VAL+=("${_DM_SSH_OPT_VAL[$i]}")
  done
}

# dm_ssh_apply KIND NAME ENV - apply the section KIND NAME ENV if it exists.
dm_ssh_apply() {
  local idx
  idx="$(dm_ssh_section_index "$1" "$2" "$3")" || return 0
  dm_ssh_apply_layer "$idx"
}

# dm_ssh_hosts ENV - print the names of the hosts rendered for ENV ("-" for
# no env), in inventory order. A host with an `envs` list is rendered only
# under one of those envs.
dm_ssh_hosts() {
  local env="$1" i
  for ((i = 0; i < ${#_DM_SSH_SEC_KIND[@]}; i++)); do
    [ "${_DM_SSH_SEC_KIND[$i]}" = "host" ] && [ "${_DM_SSH_SEC_ENV[$i]}" = "-" ] || continue
    if [ -n "${_DM_SSH_SEC_ENVS[$i]}" ]; then
      [ "$env" != "-" ] || continue
      dm_ssh_has_word "${_DM_SSH_SEC_ENVS[$i]}" "$env" || continue
    fi
    printf '%s\n' "${_DM_SSH_SEC_NAME[$i]}"
  done
}

# dm_ssh_render INVENTORY_LABEL ENV - print the managed block, markers
# included, for the loaded inventory. ENV is "-" for no env.
dm_ssh_render() {
  local label="$1" env="$2" host idx g i
  printf '%s\n' "$_DM_SSH_BEGIN"
  printf '# Generated by dotmgr from %s (env: %s).\n' "$label" "${env/#-/none}"
  printf '# Edits between these markers are overwritten on the next run.\n'
  while IFS= read -r host; do
    [ -n "$host" ] || continue
    idx="$(dm_ssh_section_index host "$host" -)"
    _DM_SSH_R_LKEY=() _DM_SSH_R_KEY=() _DM_SSH_R_VAL=()
    dm_ssh_apply defaults - -
    [ "$env" = "-" ] || dm_ssh_apply env "$env" -
    for g in ${_DM_SSH_SEC_GROUPS[$idx]}; do
      dm_ssh_apply group "$g" -
      [ "$env" = "-" ] || dm_ssh_apply group "$g" "$env"
    done
    dm_ssh_apply_layer "$idx"
    [ "$env" = "-" ] || dm_ssh_apply host "$host" "$env"
    printf '\nHost %s\n' "$host"
    # HostName first so each block reads as "name, address, then the rest".
    for ((i = 0; i < ${#_DM_SSH_R_KEY[@]}; i++)); do
      [ "${_DM_SSH_R_LKEY[$i]}" = "hostname" ] || continue
      printf '  %s %s\n' "${_DM_SSH_R_KEY[$i]}" "${_DM_SSH_R_VAL[$i]}"
    done
    for ((i = 0; i < ${#_DM_SSH_R_KEY[@]}; i++)); do
      [ "${_DM_SSH_R_LKEY[$i]}" != "hostname" ] || continue
      printf '  %s %s\n' "${_DM_SSH_R_KEY[$i]}" "${_DM_SSH_R_VAL[$i]}"
    done
  done < <(dm_ssh_hosts "$env")
  for ((idx = 0; idx < ${#_DM_SSH_SEC_KIND[@]}; idx++)); do
    [ "${_DM_SSH_SEC_KIND[$idx]}" = "match" ] || continue
    printf '\nMatch %s\n' "${_DM_SSH_SEC_NAME[$idx]}"
    for ((i = 0; i < ${#_DM_SSH_OPT_SEC[@]}; i++)); do
      [ "${_DM_SSH_OPT_SEC[$i]}" = "$idx" ] || continue
      printf '  %s %s\n' "${_DM_SSH_OPT_KEY[$i]}" "${_DM_SSH_OPT_VAL[$i]}"
    done
  done
  # ssh_config has no "end of block": every line belongs to the last Host or
  # Match above it. Without this, global options the user wrote after the
  # managed region would silently apply to the last rendered host only.
  printf '\n# Return to global scope for whatever follows this block.\n'
  printf 'Match all\n'
  printf '%s\n' "$_DM_SSH_END"
}

# dm_ssh_compose OUT BLOCK_FILE NEW_FILE - write the full new config to
# NEW_FILE: OUT with its marked region replaced by BLOCK_FILE, or BLOCK_FILE
# followed by OUT unchanged when OUT has no markers yet. The block goes first
# so its Host entries take precedence over a hand-written `Host *`, since ssh
# uses the first value it finds for each option. head/tail keep the rest of
# OUT byte-for-byte, including a missing final newline.
dm_ssh_compose() {
  local out="$1" block="$2" new="$3" begins ends b e
  if [ ! -e "$out" ]; then
    cat "$block" > "$new"
    return 0
  fi
  begins="$(grep -n -x -e "${_DM_SSH_BEGIN}[[:space:]]*" "$out" | cut -d: -f1 || true)"
  ends="$(grep -n -x -e "${_DM_SSH_END}[[:space:]]*" "$out" | cut -d: -f1 || true)"
  if [ -z "$begins" ] && [ -z "$ends" ]; then
    cat "$block" "$out" > "$new"
    return 0
  fi
  b="$begins" e="$ends"
  if [[ "$b" == *$'\n'* ]] || [[ "$e" == *$'\n'* ]] || [ -z "$b" ] || [ -z "$e" ] \
    || [ "$b" -ge "$e" ]; then
    err "$out: expected exactly one '$_DM_SSH_BEGIN' line followed by one '$_DM_SSH_END' line"
    return 1
  fi
  {
    # BSD head rejects a count of 0, so skip it when the block starts on line 1.
    [ "$b" -eq 1 ] || head -n "$((b - 1))" "$out"
    cat "$block"
    tail -n "+$((e + 1))" "$out"
  } > "$new"
}

# dm_ssh_validate FILE HOST... - run `ssh -G` against FILE for each host (or a
# placeholder when none are rendered) and fail with ssh's own message when it
# rejects the config. -G only evaluates the config; it does not connect.
dm_ssh_validate() {
  local file="$1" ssh="${DOTMGR_SSH:-ssh}" host errf
  shift
  command -v "$ssh" > /dev/null 2>&1 \
    || { err "cannot validate: '$ssh' not found (use --no-validate to skip)"; return 1; }
  [ $# -gt 0 ] || set -- dotmgr-validate
  errf="$(dirname "$file")/ssh-G.err"
  for host in "$@"; do
    if ! "$ssh" -G -F "$file" "$host" < /dev/null > /dev/null 2> "$errf"; then
      err "ssh -G rejected the rendered config for host $host:"
      sed 's/^/  /' "$errf" >&2
      return 1
    fi
  done
}

# cmd_ssh [--inventory FILE] [--env NAME] [--out FILE] [--no-validate] -
# render the inventory into the managed block of an ssh config file.
#
# The inventory defaults to <repo>/ssh.inventory and the output to
# <target>/.ssh/config. Under --dry-run the unified diff is printed to stdout
# and nothing is written. A real write validates the result with `ssh -G`,
# copies the current file into a timestamped backup run under the backup root
# (so `dotmgr restore` can put it back), and replaces it with a rename in the
# same directory, so a reader never sees a half-written config.
cmd_ssh() {
  local inv="" env="-" out="" validate=1 scratch block new tmp run_dir rel label rc=0
  local -a hosts=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --inventory) [ $# -ge 2 ] || die "--inventory needs a FILE"; inv="$2"; shift 2 ;;
      --inventory=*) inv="${1#*=}"; shift ;;
      --env) [ $# -ge 2 ] || die "--env needs a NAME"; env="$2"; shift 2 ;;
      --env=*) env="${1#*=}"; shift ;;
      --out) [ $# -ge 2 ] || die "--out needs a FILE"; out="$2"; shift 2 ;;
      --out=*) out="${1#*=}"; shift ;;
      --no-validate) validate=0; shift ;;
      -*) die "unknown ssh option: $1" ;;
      *) die "ssh takes no positional arguments" ;;
    esac
  done
  [ -n "$inv" ] || inv="${DOTMGR_REPO%/}/ssh.inventory"
  [ -n "$out" ] || out="$(dm_expand_dest .ssh/config)"
  [ -n "$env" ] || die "--env must not be empty"
  case "$inv" in /*) ;; *) inv="$PWD/$inv" ;; esac
  case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
  # Renaming over a symlink would replace the link itself, for example
  # turning a config that `dotmgr link` manages into an unmanaged copy.
  [ ! -L "$out" ] || die "output is a symlink, pass the file it points to with --out: $out"
  [ ! -e "$out" ] || [ -f "$out" ] || die "output is not a regular file: $out"

  dm_ssh_load_inventory "$inv"
  if [ "$env" != "-" ]; then
    if ! dm_ssh_valid_name "$env" || ! dm_ssh_section_index env "$env" - > /dev/null; then
      die "unknown env '$env': the inventory has no [env $env] section"
    fi
  fi
  while IFS= read -r rel; do
    [ -n "$rel" ] && hosts+=("$rel")
  done < <(dm_ssh_hosts "$env")
  [ ${#hosts[@]} -gt 0 ] || warn "no hosts to render for env: ${env/#-/none}"

  scratch="$(mktemp -d "${TMPDIR:-/tmp}/dotmgr-ssh.XXXXXX")"
  block="$scratch/block" new="$scratch/config"
  # Name the inventory relative to the repo when it lives there, so the
  # rendered header does not change between checkouts of the same repo.
  label="$inv"
  case "$inv" in
    "${DOTMGR_REPO%/}"/*) label="${inv#"${DOTMGR_REPO%/}"/}" ;;
  esac
  dm_ssh_render "$label" "$env" > "$block"
  dm_ssh_compose "$out" "$block" "$new" || rc=1

  if [ "$rc" -eq 0 ] && [ -e "$out" ] && cmp -s "$out" "$new"; then
    info "ssh config up to date: $out"
    rm -rf "$scratch"
    return 0
  fi
  if [ "$rc" -eq 0 ] && [ "$validate" -eq 1 ]; then
    if [ ${#hosts[@]} -gt 0 ]; then
      dm_ssh_validate "$new" "${hosts[@]}" || rc=1
    else
      dm_ssh_validate "$new" || rc=1
    fi
  fi
  if [ "$rc" -ne 0 ]; then
    rm -rf "$scratch"
    die "ssh config not written: $out"
  fi

  if dm_dry_run; then
    if [ -e "$out" ]; then
      diff -u -L "$out" -L "$out (new)" "$out" "$new" || true
    else
      diff -u -L /dev/null -L "$out (new)" /dev/null "$new" || true
    fi
    info "[dry-run] would write $out"
    rm -rf "$scratch"
    return 0
  fi

  if [ ! -d "$(dirname "$out")" ]; then
    mkdir -p "$(dirname "$out")"
    chmod 700 "$(dirname "$out")"
  fi
  if [ -e "$out" ]; then
    run_dir="${DOTMGR_BACKUP_DIR%/}/$(dm_timestamp)"
    rel="$(dm_rel_to_target "$out")"
    mkdir -p "$(dirname "$run_dir/$rel")"
    cp -p "$out" "$run_dir/$rel"
    info "backed up: $out -> $run_dir/$rel"
  fi
  # The temp file sits next to the output so the final mv is a rename on one
  # filesystem. Copying the old file first carries its mode over; a new file
  # keeps mktemp's 0600, which ssh accepts for a user config.
  tmp="$(mktemp "$out.dotmgr.XXXXXX")"
  [ ! -e "$out" ] || cp -p "$out" "$tmp"
  cat "$new" > "$tmp"
  mv -f "$tmp" "$out"
  rm -rf "$scratch"
  info "ssh config written: $out (${#hosts[@]} hosts)"
}
