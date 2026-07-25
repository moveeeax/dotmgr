#!/usr/bin/env bats

load test_helper

setup() { setup_env; }
teardown() { teardown_env; }

@test "dm_parse_manifest splits an explicit mapping" {
  write_manifest "vim/vimrc -> .vimrc"
  run dm_parse_manifest "$DOTMGR_MANIFEST"
  [ "$status" -eq 0 ]
  [ "$output" = $'vim/vimrc\t.vimrc' ]
}

@test "dm_parse_manifest expands shorthand to src -> src" {
  write_manifest ".bashrc"
  run dm_parse_manifest "$DOTMGR_MANIFEST"
  [ "$output" = $'.bashrc\t.bashrc' ]
}

@test "dm_parse_manifest skips blank lines and comments" {
  write_manifest "# a comment" "" "  # indented comment" ".gitconfig"
  run dm_parse_manifest "$DOTMGR_MANIFEST"
  [ "$output" = $'.gitconfig\t.gitconfig' ]
}

@test "dm_parse_manifest trims whitespace around the arrow" {
  write_manifest "   src/file    ->    dest/file   "
  run dm_parse_manifest "$DOTMGR_MANIFEST"
  [ "$output" = $'src/file\tdest/file' ]
}

@test "dm_parse_manifest handles multiple entries in order" {
  write_manifest ".bashrc" "nvim/init.vim -> .config/nvim/init.vim" ".gitconfig"
  run dm_parse_manifest "$DOTMGR_MANIFEST"
  [ "${lines[0]}" = $'.bashrc\t.bashrc' ]
  [ "${lines[1]}" = $'nvim/init.vim\t.config/nvim/init.vim' ]
  [ "${lines[2]}" = $'.gitconfig\t.gitconfig' ]
}

@test "dm_parse_manifest reads a final line without a trailing newline" {
  printf '%s' ".profile -> .profile" > "$DOTMGR_MANIFEST"
  run dm_parse_manifest "$DOTMGR_MANIFEST"
  [ "$output" = $'.profile\t.profile' ]
}

@test "dm_parse_manifest dies on a missing file" {
  run dm_parse_manifest "$TMP/nope.manifest"
  [ "$status" -ne 0 ]
  [[ "$output" == *"manifest not found"* ]]
}

@test "dm_parse_manifest rejects a destination that escapes the target" {
  write_manifest "evil -> ../../.ssh/authorized_keys"
  run dm_parse_manifest "$DOTMGR_MANIFEST"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must not contain a '..'"* ]]
}

@test "dm_parse_manifest rejects a source that escapes the repo" {
  write_manifest "../../etc/shadow -> .shadow"
  run dm_parse_manifest "$DOTMGR_MANIFEST"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must not contain a '..'"* ]]
}

# Regression: die() inside `< <(dm_parse_manifest ...)` only exited the
# process-substitution subshell, so every command reported success on a
# manifest it had never actually read.
@test "commands fail loudly when the manifest cannot be parsed" {
  export DOTMGR_MANIFEST="$TMP/absent.manifest"
  run cmd_link
  [ "$status" -ne 0 ]
  run cmd_status
  [ "$status" -ne 0 ]
  run cmd_unlink
  [ "$status" -ne 0 ]
  run cmd_backup
  [ "$status" -ne 0 ]
}

@test "commands fail on an invalid manifest without touching the target" {
  mkrepo_file ".bashrc"
  write_manifest ".bashrc -> .bashrc" "x -> ../escape"
  run cmd_link
  [ "$status" -ne 0 ]
  [ ! -e "$DOTMGR_TARGET/.bashrc" ]
}
