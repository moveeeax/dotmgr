# dotmgr

A small, dependency-free Bash tool for managing dotfiles. It keeps your
configuration files in one repository and symlinks them into your home
directory, backing up anything it would otherwise clobber.

- Single script (`bin/dotmgr`) plus a sourced library (`lib/dotmgr.sh`).
- Manifest-driven: one file describes what links where.
- Safe by default: conflicts are backed up before anything is replaced, and
  every command supports `--dry-run`.
- Idempotent: re-running `link` only touches what has drifted.

## Install

Copy the two files somewhere on your `PATH`, keeping their relative layout
(the script sources `../lib/dotmgr.sh`):

```sh
make install PREFIX="$HOME/.local"
```

Or just run it straight from a checkout: `./bin/dotmgr status`.

## The manifest

By default `dotmgr` reads `dotmgr.manifest` from the repository root. Each
non-empty, non-comment line is one of:

```
# Explicit mapping: repo source -> destination
nvim/init.vim -> .config/nvim/init.vim

# Shorthand: "path" is the same as "path -> path"
.bashrc
.gitconfig
```

- Blank lines and lines beginning with `#` are ignored.
- The source is resolved relative to the repository (`--repo`).
- The destination is resolved relative to the target directory (`--target`,
  your `$HOME` by default). A leading `/` is treated as an absolute path and a
  leading `~/` expands against the target.
- Neither side may contain a `..` component; use an absolute destination if you
  need to manage a file outside the target directory.
- An entry whose source and destination resolve to the *same* path is rejected,
  since linking a file to itself would destroy it.

## Safety rules

`dotmgr` moves, replaces and deletes files, so it is deliberately strict:

- A real file or foreign symlink at a destination is **moved into a timestamped
  backup** before the managed symlink replaces it — nothing is clobbered.
- Destinations outside the target directory are snapshotted under a
  `_dotmgr_abs/` subdirectory that preserves their full path, so two entries
  sharing a basename cannot overwrite each other and `restore` returns each
  file to the location it actually came from.
- `adopt` only accepts paths under the target directory. Adopting from outside
  it cannot produce a manifest entry that round-trips.
- An empty `--repo`/`--target`/`--backup-dir`, or `--target /`, is refused
  rather than silently retargeting every operation at the filesystem root.
- A manifest that cannot be read or parsed aborts the command with a non-zero
  exit status; no command proceeds against a partially understood manifest.

## Commands

```
dotmgr [GLOBAL OPTIONS] COMMAND [ARGS]
```

| Command             | What it does                                              |
|---------------------|----------------------------------------------------------|
| `link`              | Create symlinks; back up real files or foreign links     |
| `unlink [--restore]`| Remove managed symlinks; optionally restore latest backup|
| `status`            | Print `linked` / `missing` / `conflict` per entry        |
| `backup`            | Snapshot current destination files into a timestamp dir  |
| `restore [SNAP]`    | Restore a snapshot (latest when none is named)           |
| `adopt PATH`        | Move an existing file into the repo and symlink it back  |

Global options: `--repo DIR`, `--target DIR`, `--manifest FILE`,
`--backup-dir DIR`, `-n/--dry-run`, `-h/--help`, `--version`.

## Examples

```sh
# See what would happen, then do it.
dotmgr --repo ~/dotfiles status
dotmgr --repo ~/dotfiles --dry-run link
dotmgr --repo ~/dotfiles link

# Pull an existing config into the repo and start tracking it.
dotmgr --repo ~/dotfiles adopt ~/.tmux.conf

# Roll back: remove the managed links and put the originals back.
dotmgr --repo ~/dotfiles unlink --restore
```

Backups live under `$XDG_DATA_HOME/dotmgr/backups` (default
`~/.local/share/dotmgr/backups`), one timestamped snapshot per run.

## Development

```sh
make lint    # shellcheck the script and library
make test    # run the bats suite
make check   # both
```

## License

MIT. See [LICENSE](LICENSE).
