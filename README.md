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
| `status [--porcelain\|-q]` | Print the state of every entry; exit 1 on drift   |
| `backup`            | Snapshot current destination files into a timestamp dir  |
| `restore [SNAP]`    | Restore a snapshot (latest when none is named)           |
| `adopt PATH`        | Move an existing file into the repo and symlink it back  |
| `ssh [OPTIONS]`     | Render ssh `Host` blocks from an inventory into `~/.ssh/config` |

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

## Status and scripting

`status` prints one line per manifest entry with one of four states:

| State      | Meaning                                                      |
|------------|--------------------------------------------------------------|
| `linked`   | The destination is a symlink to the repo file                |
| `missing`  | Nothing exists at the destination                            |
| `conflict` | A real file or a foreign symlink sits at the destination     |
| `nosource` | The repo file is gone (a managed link to it is now dangling) |

The exit status makes it usable as a gate in CI, a login hook or another
script:

| Exit | Meaning                                                    |
|------|------------------------------------------------------------|
| 0    | Every entry is `linked` (an empty manifest counts)         |
| 1    | At least one entry is `missing`, `conflict` or `nosource`  |
| 2    | The manifest cannot be read or parsed, or a bad argument   |

`status --porcelain` prints `STATE<TAB>DEST<TAB>SRC` per entry, with DEST and
SRC exactly as written in the manifest; this format will not change.
`status -q` (`--quiet`) prints only the counts, for example
`linked=4 missing=1 conflict=0 nosource=0`. When both are given the last one
wins.

```sh
dotmgr --repo ~/dotfiles status -q || dotmgr --repo ~/dotfiles link
dotmgr --repo ~/dotfiles status --porcelain | awk -F'\t' '$1 != "linked"'
```

## SSH config

`dotmgr ssh` renders `Host` blocks from a host inventory into one marked
region of an ssh config file. Everything outside the region is left
byte-for-byte as it was, so hand-written entries survive every run.

```
dotmgr ssh [--inventory FILE] [--env NAME] [--out FILE] [--no-validate]
```

- `--inventory` defaults to `<repo>/ssh.inventory`, `--out` to
  `<target>/.ssh/config`.
- `--env NAME` selects an environment: its `[env NAME]` options, the
  `@NAME` overrides, and hosts limited to it with `envs`. Without `--env`
  only hosts that have no `envs` list are rendered and no env options apply.
- The region sits between `# BEGIN dotmgr ssh` and `# END dotmgr ssh`. If the
  file has no markers yet, the block is put at the top: ssh uses the first
  value it finds for each option, so rendered hosts win over a hand-written
  `Host *`. The block ends with `Match all`, which puts any lines that follow
  back in global scope.
- Before writing, the full new file is checked with `ssh -G -F FILE HOST` for
  every rendered host. If ssh rejects it, nothing is written. `-G` evaluates
  the config without connecting, but it does run `Match exec` commands, as
  any ssh invocation would. `--no-validate` skips this, for machines without
  an ssh client. Set `DOTMGR_SSH` to use a different `ssh` binary.
- A real write copies the current file into a timestamped backup run (so
  `dotmgr restore` can bring it back) and then replaces the file with a rename
  in the same directory. The file mode is kept; a new file is created `0600`.
  Nothing is written or backed up when the output would not change.
- `--dry-run` prints a unified diff of the change and writes nothing.
- A symlinked output (for example a config that `dotmgr link` manages) is
  refused, since the rename would replace the link; pass the real file with
  `--out`.

The inventory is a plain INI-style file, so `dotmgr` stays free of a YAML
parser. See [examples/ssh.inventory.example](examples/ssh.inventory.example).

```ini
# Options for every host.
[defaults]
User = deploy

# Options for every host under --env prod.
[env prod]
ProxyJump = jump1.prod.example.com,jump2.prod.example.com

# Options for hosts that list "web" in groups; the @prod part only under --env prod.
[group web]
User = www
[group web @prod]
Port = 2222

# One host. groups and envs are dotmgr keys, not ssh options.
[host web1]
groups = web
HostName = 10.0.0.11
[host web1 @prod]
HostName = 10.9.0.11

# Emitted verbatim as a Match block.
[match host *.internal]
StrictHostKeyChecking = yes
```

Option lines are ssh_config keywords written `Key = value` or `Key value`.
For each host the layers apply in this order, later ones winning: defaults,
env, each group in the order listed in `groups` (plain, then `@ENV`), the
host, the host's `@ENV` section. A layer that sets a key replaces every
earlier value of that key, keys compare case-insensitively like ssh does, and
repeating a key inside one section keeps every line (`IdentityFile`,
`LocalForward`). Each host is emitted as one canonical `Host NAME` line with
its options fully resolved, so names may not contain spaces or the pattern
characters `*`, `?` and `!`. A group, env or `@ENV` that is used but not
declared, a duplicate section, or an option outside a section is an error.

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
