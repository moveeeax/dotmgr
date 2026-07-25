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

# Regression: outside the target the repo-relative path collapsed to a bare
# basename, so adopt wrote a manifest entry pointing at $TARGET/<basename>
# while the symlink it created sat somewhere else entirely.
@test "adopt refuses a path outside the target directory" {
  mkdir -p "$TMP/elsewhere"
  printf 'OUTSIDE\n' > "$TMP/elsewhere/conf"
  : > "$DOTMGR_MANIFEST"
  run cmd_adopt "$TMP/elsewhere/conf"
  [ "$status" -ne 0 ]
  [[ "$output" == *"only handles paths under the target directory"* ]]
  [ ! -L "$TMP/elsewhere/conf" ]
  [ "$(cat "$TMP/elsewhere/conf")" = "OUTSIDE" ]
  [ ! -s "$DOTMGR_MANIFEST" ]
}

@test "adopt refuses a path that traverses out of the target" {
  : > "$DOTMGR_MANIFEST"
  run cmd_adopt "../escape/conf"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must not contain a '..'"* ]]
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
