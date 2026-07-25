#!/usr/bin/env bats

load test_helper

setup() { setup_env; }
teardown() { teardown_env; }

@test "link creates a symlink for a new entry" {
  mkrepo_file ".bashrc"
  write_manifest ".bashrc -> .bashrc"
  run cmd_link
  [ "$status" -eq 0 ]
  [ -L "$DOTMGR_TARGET/.bashrc" ]
  [ "$(readlink "$DOTMGR_TARGET/.bashrc")" = "$DOTMGR_REPO/.bashrc" ]
}

@test "link creates missing parent directories for the destination" {
  mkrepo_file "nvim/init.vim"
  write_manifest "nvim/init.vim -> .config/nvim/init.vim"
  run cmd_link
  [ "$status" -eq 0 ]
  [ -L "$DOTMGR_TARGET/.config/nvim/init.vim" ]
}

@test "link backs up an existing real file before linking" {
  mkrepo_file ".bashrc" "from-repo"
  mktarget_file ".bashrc" "original-user-file"
  write_manifest ".bashrc -> .bashrc"
  run cmd_link
  [ "$status" -eq 0 ]
  [ -L "$DOTMGR_TARGET/.bashrc" ]
  # The original content survives somewhere under the backup root.
  found="$(grep -rl "original-user-file" "$DOTMGR_BACKUP_DIR" || true)"
  [ -n "$found" ]
}

@test "link backs up a foreign symlink as a conflict" {
  mkrepo_file ".gitconfig"
  ln -s /some/other/target "$DOTMGR_TARGET/.gitconfig"
  write_manifest ".gitconfig -> .gitconfig"
  run cmd_link
  [ "$status" -eq 0 ]
  [ "$(readlink "$DOTMGR_TARGET/.gitconfig")" = "$DOTMGR_REPO/.gitconfig" ]
  # A backup snapshot directory was created for the displaced link.
  run find "$DOTMGR_BACKUP_DIR" -name .gitconfig
  [ -n "$output" ]
}

@test "re-running link is idempotent and creates no new backups" {
  mkrepo_file ".bashrc"
  write_manifest ".bashrc -> .bashrc"
  cmd_link
  before="$(find "$DOTMGR_BACKUP_DIR" -type f 2>/dev/null | wc -l)"
  run cmd_link
  [ "$status" -eq 0 ]
  after="$(find "$DOTMGR_BACKUP_DIR" -type f 2>/dev/null | wc -l)"
  [ "$before" -eq "$after" ]
  [ -L "$DOTMGR_TARGET/.bashrc" ]
}

@test "link with no conflicts creates no backup directory" {
  mkrepo_file ".bashrc"
  write_manifest ".bashrc -> .bashrc"
  run cmd_link
  [ "$status" -eq 0 ]
  [ ! -d "$DOTMGR_BACKUP_DIR" ]
}

@test "link skips a manifest entry whose source is missing in the repo" {
  write_manifest "ghost -> .ghost"
  run cmd_link
  [ "$status" -eq 0 ]
  [[ "$output" == *"source missing"* ]]
  [ ! -e "$DOTMGR_TARGET/.ghost" ]
}

@test "link handles multiple entries in one run" {
  mkrepo_file ".bashrc"
  mkrepo_file ".gitconfig"
  write_manifest ".bashrc -> .bashrc" ".gitconfig -> .gitconfig"
  run cmd_link
  [ "$status" -eq 0 ]
  [ -L "$DOTMGR_TARGET/.bashrc" ]
  [ -L "$DOTMGR_TARGET/.gitconfig" ]
}

# Regression: with the repo inside the target, an entry whose source and
# destination resolve to the same path used to move the only real copy into a
# backup and leave a self-referential symlink that status then called "linked".
@test "link refuses an entry that maps a path onto itself" {
  export DOTMGR_REPO="$DOTMGR_TARGET/dotfiles"
  export DOTMGR_MANIFEST="$DOTMGR_REPO/dotmgr.manifest"
  mkdir -p "$DOTMGR_REPO"
  printf 'MY-REAL-BASHRC\n' > "$DOTMGR_REPO/.bashrc"
  write_manifest ".bashrc -> dotfiles/.bashrc"
  run cmd_link
  [ "$status" -ne 0 ]
  [[ "$output" == *"maps a path onto itself"* ]]
  # The real file is still a readable regular file, not a symlink to itself.
  [ ! -L "$DOTMGR_REPO/.bashrc" ]
  [ "$(cat "$DOTMGR_REPO/.bashrc")" = "MY-REAL-BASHRC" ]
}

@test "dry-run link makes no changes on disk" {
  mkrepo_file ".bashrc"
  mktarget_file ".bashrc" "keep-me"
  write_manifest ".bashrc -> .bashrc"
  DOTMGR_DRY_RUN=1 run cmd_link
  [ "$status" -eq 0 ]
  [ ! -L "$DOTMGR_TARGET/.bashrc" ]
  [ "$(cat "$DOTMGR_TARGET/.bashrc")" = "keep-me" ]
  [ ! -d "$DOTMGR_BACKUP_DIR" ]
}
