#!/usr/bin/env bats

load test_helper

setup() { setup_env; }
teardown() { teardown_env; }

@test "adopt moves the file into the repo and leaves a symlink" {
  mktarget_file ".bashrc" "my-config"
  : > "$DOTMGR_MANIFEST"
  run cmd_adopt ".bashrc"
  [ "$status" -eq 0 ]
  [ -L "$DOTMGR_TARGET/.bashrc" ]
  [ -f "$DOTMGR_REPO/.bashrc" ]
  [ "$(cat "$DOTMGR_REPO/.bashrc")" = "my-config" ]
  [ "$(readlink "$DOTMGR_TARGET/.bashrc")" = "$DOTMGR_REPO/.bashrc" ]
}

@test "adopt records the entry in the manifest" {
  mktarget_file ".gitconfig" "cfg"
  : > "$DOTMGR_MANIFEST"
  run cmd_adopt ".gitconfig"
  [ "$status" -eq 0 ]
  grep -q ".gitconfig -> .gitconfig" "$DOTMGR_MANIFEST"
}

@test "adopt handles a nested destination path" {
  mktarget_file ".config/app/config.yml" "nested"
  : > "$DOTMGR_MANIFEST"
  run cmd_adopt ".config/app/config.yml"
  [ "$status" -eq 0 ]
  [ -L "$DOTMGR_TARGET/.config/app/config.yml" ]
  [ -f "$DOTMGR_REPO/.config/app/config.yml" ]
}

@test "adopt does not duplicate an existing manifest entry" {
  mktarget_file ".bashrc" "x"
  write_manifest ".bashrc -> .bashrc"
  run cmd_adopt ".bashrc"
  [ "$status" -eq 0 ]
  count="$(grep -c ".bashrc -> .bashrc" "$DOTMGR_MANIFEST")"
  [ "$count" -eq 1 ]
}

@test "adopt refuses a path that is already a symlink" {
  ln -s /whatever "$DOTMGR_TARGET/.bashrc"
  : > "$DOTMGR_MANIFEST"
  run cmd_adopt ".bashrc"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already a symlink"* ]]
}

@test "adopt refuses a missing path" {
  : > "$DOTMGR_MANIFEST"
  run cmd_adopt ".nope"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such file"* ]]
}

@test "dry-run adopt leaves the original file in place" {
  mktarget_file ".bashrc" "keep"
  : > "$DOTMGR_MANIFEST"
  DOTMGR_DRY_RUN=1 run cmd_adopt ".bashrc"
  [ "$status" -eq 0 ]
  [ -f "$DOTMGR_TARGET/.bashrc" ]
  [ ! -L "$DOTMGR_TARGET/.bashrc" ]
  [ ! -e "$DOTMGR_REPO/.bashrc" ]
}
