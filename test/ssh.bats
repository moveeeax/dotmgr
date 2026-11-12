#!/usr/bin/env bats

load test_helper

# fake_ssh EXIT [MESSAGE] - install a stand-in for `ssh` that records its
# arguments in $TMP/ssh.calls, prints MESSAGE to stderr and exits with EXIT.
fake_ssh() {
  local code="$1" msg="${2:-}"
  cat > "$TMP/fake-ssh" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/ssh.calls"
[ -z "$msg" ] || printf '%s\n' "$msg" >&2
exit $code
FAKE
  chmod +x "$TMP/fake-ssh"
  export DOTMGR_SSH="$TMP/fake-ssh"
}

# write_inventory LINE... - write each argument as an inventory line.
write_inventory() {
  printf '%s\n' "$@" > "$DOTMGR_REPO/ssh.inventory"
}

# managed_block - print the managed region of the default output file.
managed_block() {
  sed -n '/^# BEGIN dotmgr ssh$/,/^# END dotmgr ssh$/p' "$DOTMGR_TARGET/.ssh/config"
}

setup() {
  setup_env
  fake_ssh 0
  write_inventory \
    "[defaults]" \
    "User = deploy" \
    "" \
    "[env staging]" \
    "ProxyJump = bastion.staging" \
    "" \
    "[env prod]" \
    "ProxyJump = jump1.prod,jump2.prod" \
    "" \
    "[group web]" \
    "User = www" \
    "IdentityFile ~/.ssh/web_a" \
    "IdentityFile ~/.ssh/web_b" \
    "" \
    "[group web @prod]" \
    "Port = 2222" \
    "" \
    "[host web1]" \
    "groups = web" \
    "HostName = 10.0.0.11" \
    "" \
    "[host web1 @staging]" \
    "HostName = 10.1.0.11" \
    "" \
    "[host db1]" \
    "envs = prod" \
    "HostName = 10.0.0.21"
}
teardown() { teardown_env; }

@test "ssh writes a managed block into a new config file" {
  run cmd_ssh --env prod
  [ "$status" -eq 0 ]
  [ -f "$DOTMGR_TARGET/.ssh/config" ]
  [ "$(head -n 1 "$DOTMGR_TARGET/.ssh/config")" = "# BEGIN dotmgr ssh" ]
  [ "$(tail -n 1 "$DOTMGR_TARGET/.ssh/config")" = "# END dotmgr ssh" ]
  grep -qx "Host web1" "$DOTMGR_TARGET/.ssh/config"
  grep -qx "Host db1" "$DOTMGR_TARGET/.ssh/config"
}

@test "ssh resolves defaults, env, group and host layers in order" {
  cmd_ssh --env prod
  block="$(managed_block)"
  expected="$(printf '%s\n' \
    "Host web1" \
    "  HostName 10.0.0.11" \
    "  ProxyJump jump1.prod,jump2.prod" \
    "  User www" \
    "  IdentityFile ~/.ssh/web_a" \
    "  IdentityFile ~/.ssh/web_b" \
    "  Port 2222" \
    "" \
    "Host db1" \
    "  HostName 10.0.0.21" \
    "  User deploy" \
    "  ProxyJump jump1.prod,jump2.prod")"
  [[ "$block" == *"$expected"* ]]
}

@test "ssh applies host @env overrides and skips hosts limited to other envs" {
  cmd_ssh --env staging
  block="$(managed_block)"
  [[ "$block" == *"Host web1"$'\n'"  HostName 10.1.0.11"* ]]
  [[ "$block" == *"ProxyJump bastion.staging"* ]]
  [[ "$block" != *"Port 2222"* ]]
  [[ "$block" != *"Host db1"* ]]
}

@test "ssh without --env renders only unrestricted hosts and no env options" {
  cmd_ssh
  block="$(managed_block)"
  [[ "$block" == *"Host web1"* ]]
  [[ "$block" != *"Host db1"* ]]
  [[ "$block" != *"ProxyJump"* ]]
}

@test "ssh ends the block with Match all so following lines stay global" {
  cmd_ssh --env prod
  [ "$(managed_block | tail -n 2 | head -n 1)" = "Match all" ]
}

@test "ssh emits match sections verbatim" {
  printf '%s\n' "[match host *.internal]" "StrictHostKeyChecking yes" >> "$DOTMGR_REPO/ssh.inventory"
  cmd_ssh
  block="$(managed_block)"
  [[ "$block" == *"Match host *.internal"$'\n'"  StrictHostKeyChecking yes"* ]]
}

@test "ssh prepends the block and keeps hand-written content byte-for-byte" {
  mkdir -p "$DOTMGR_TARGET/.ssh"
  printf 'ServerAliveInterval 60\n\nHost personal\n  HostName me.example.com' > "$DOTMGR_TARGET/.ssh/config"
  cp "$DOTMGR_TARGET/.ssh/config" "$TMP/orig"
  run cmd_ssh --env prod
  [ "$status" -eq 0 ]
  [ "$(head -n 1 "$DOTMGR_TARGET/.ssh/config")" = "# BEGIN dotmgr ssh" ]
  # Everything after the END marker is the original file, missing final
  # newline included.
  sed '1,/^# END dotmgr ssh$/d' "$DOTMGR_TARGET/.ssh/config" > "$TMP/rest"
  printf '%s' "$(cat "$TMP/rest")" > "$TMP/rest.trimmed"
  cmp "$TMP/orig" "$TMP/rest.trimmed"
  [ "$(tail -c 1 "$DOTMGR_TARGET/.ssh/config")" = "m" ]
}

@test "ssh replaces only the region between existing markers" {
  mkdir -p "$DOTMGR_TARGET/.ssh"
  printf '%s\n' "# mine, above" "Host top" "  User me" \
    "# BEGIN dotmgr ssh" "Host stale" "# END dotmgr ssh" \
    "# mine, below" "Host bottom" > "$DOTMGR_TARGET/.ssh/config"
  run cmd_ssh --env prod
  [ "$status" -eq 0 ]
  cfg="$DOTMGR_TARGET/.ssh/config"
  [ "$(head -n 3 "$cfg")" = "$(printf '%s\n' "# mine, above" "Host top" "  User me")" ]
  [ "$(sed -n 4p "$cfg")" = "# BEGIN dotmgr ssh" ]
  [ "$(tail -n 2 "$cfg")" = "$(printf '%s\n' "# mine, below" "Host bottom")" ]
  ! grep -q "Host stale" "$cfg"
  grep -qx "Host web1" "$cfg"
}

@test "ssh refuses unbalanced or duplicated markers and leaves the file alone" {
  mkdir -p "$DOTMGR_TARGET/.ssh"
  printf '%s\n' "# BEGIN dotmgr ssh" "Host x" > "$DOTMGR_TARGET/.ssh/config"
  cp "$DOTMGR_TARGET/.ssh/config" "$TMP/orig"
  run cmd_ssh
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected exactly one"* ]]
  cmp "$TMP/orig" "$DOTMGR_TARGET/.ssh/config"
  printf '%s\n' "# BEGIN dotmgr ssh" "# END dotmgr ssh" "# BEGIN dotmgr ssh" "# END dotmgr ssh" \
    > "$DOTMGR_TARGET/.ssh/config"
  run cmd_ssh
  [ "$status" -ne 0 ]
}

@test "ssh backs up the previous config into a timestamped run" {
  mkdir -p "$DOTMGR_TARGET/.ssh"
  printf 'Host personal\n' > "$DOTMGR_TARGET/.ssh/config"
  run cmd_ssh
  [ "$status" -eq 0 ]
  backup="$(find "$DOTMGR_BACKUP_DIR" -path '*/.ssh/config' -type f)"
  [ -n "$backup" ]
  [ "$(cat "$backup")" = "Host personal" ]
  # The existing restore command can put it back.
  run cmd_restore
  [ "$status" -eq 0 ]
  [ "$(cat "$DOTMGR_TARGET/.ssh/config")" = "Host personal" ]
}

@test "ssh keeps the mode of an existing config and creates new ones as 0600" {
  run cmd_ssh
  [ "$status" -eq 0 ]
  mode="$(ls -l "$DOTMGR_TARGET/.ssh/config" | cut -c1-10)"
  [ "$mode" = "-rw-------" ]
  chmod 640 "$DOTMGR_TARGET/.ssh/config"
  run cmd_ssh --env prod
  [ "$status" -eq 0 ]
  mode="$(ls -l "$DOTMGR_TARGET/.ssh/config" | cut -c1-10)"
  [ "$mode" = "-rw-r-----" ]
}

@test "ssh is a no-op when the rendered config is unchanged" {
  cmd_ssh --env prod
  : > "$TMP/ssh.calls"
  run cmd_ssh --env prod
  [ "$status" -eq 0 ]
  [[ "$output" == *"up to date"* ]]
  [ ! -s "$TMP/ssh.calls" ]
  [ "$(find "$DOTMGR_BACKUP_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ]
}

@test "ssh --dry-run prints a diff and writes nothing" {
  export DOTMGR_DRY_RUN=1
  run cmd_ssh --env prod
  [ "$status" -eq 0 ]
  [[ "$output" == *"+Host web1"* ]]
  [[ "$output" == *"would write"* ]]
  [ ! -e "$DOTMGR_TARGET/.ssh" ]
  [ ! -e "$DOTMGR_BACKUP_DIR" ]
}

@test "ssh validates every rendered host with ssh -G against the new file" {
  run cmd_ssh --env prod
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$TMP/ssh.calls" | tr -d ' ')" -eq 2 ]
  [[ "$(sed -n 1p "$TMP/ssh.calls")" == "-G -F "*" web1" ]]
  [[ "$(sed -n 2p "$TMP/ssh.calls")" == "-G -F "*" db1" ]]
}

@test "ssh leaves the config untouched when ssh -G rejects the result" {
  mkdir -p "$DOTMGR_TARGET/.ssh"
  printf 'Host personal\n' > "$DOTMGR_TARGET/.ssh/config"
  fake_ssh 255 "line 6: Bad configuration option: bogus"
  run cmd_ssh
  [ "$status" -ne 0 ]
  [[ "$output" == *"Bad configuration option: bogus"* ]]
  [[ "$output" == *"not written"* ]]
  [ "$(cat "$DOTMGR_TARGET/.ssh/config")" = "Host personal" ]
  [ ! -e "$DOTMGR_BACKUP_DIR" ]
  [ -z "$(find "$DOTMGR_TARGET/.ssh" -name 'config.dotmgr.*')" ]
}

@test "ssh fails when ssh is unavailable unless --no-validate is given" {
  export DOTMGR_SSH="$TMP/no-such-ssh"
  run cmd_ssh
  [ "$status" -ne 0 ]
  [[ "$output" == *"--no-validate"* ]]
  [ ! -e "$DOTMGR_TARGET/.ssh/config" ]
  run cmd_ssh --no-validate
  [ "$status" -eq 0 ]
  [ -f "$DOTMGR_TARGET/.ssh/config" ]
}

@test "ssh refuses to replace a symlinked config" {
  mkdir -p "$DOTMGR_TARGET/.ssh"
  printf 'Host personal\n' > "$TMP/real-config"
  ln -s "$TMP/real-config" "$DOTMGR_TARGET/.ssh/config"
  run cmd_ssh
  [ "$status" -ne 0 ]
  [[ "$output" == *"is a symlink"* ]]
  [ -L "$DOTMGR_TARGET/.ssh/config" ]
}

@test "ssh honours --inventory and --out" {
  cp "$DOTMGR_REPO/ssh.inventory" "$TMP/inv"
  rm "$DOTMGR_REPO/ssh.inventory"
  run cmd_ssh --inventory "$TMP/inv" --out "$TMP/out/config" --env prod
  [ "$status" -eq 0 ]
  grep -qx "Host db1" "$TMP/out/config"
  [ ! -e "$DOTMGR_TARGET/.ssh/config" ]
}

@test "ssh rejects an env the inventory does not declare" {
  run cmd_ssh --env qa
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown env 'qa'"* ]]
}

@test "ssh rejects inventory mistakes with the file and line" {
  write_inventory "User = x"
  run cmd_ssh
  [ "$status" -ne 0 ]
  [[ "$output" == *"ssh.inventory:1: option outside of any section"* ]]

  write_inventory "[host a]" "groups = nope"
  run cmd_ssh
  [ "$status" -ne 0 ]
  [[ "$output" == *"undeclared group: nope"* ]]

  write_inventory "[host a]" "envs = nope"
  run cmd_ssh
  [ "$status" -ne 0 ]
  [[ "$output" == *"undeclared env: nope"* ]]

  write_inventory "[host a]" "[host a @prod]"
  run cmd_ssh
  [ "$status" -ne 0 ]
  [[ "$output" == *"undeclared env: prod"* ]]

  write_inventory "[host web*]"
  run cmd_ssh
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid host name"* ]]

  write_inventory "[host a]" "[host a]"
  run cmd_ssh
  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate section"* ]]

  write_inventory "[group g]" "groups = x"
  run cmd_ssh
  [ "$status" -ne 0 ]
  [[ "$output" == *"only valid in a [host NAME] section"* ]]

  write_inventory "[hosts a]"
  run cmd_ssh
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown section"* ]]

  write_inventory "[host a]" "Port ="
  run cmd_ssh
  [ "$status" -ne 0 ]
  [[ "$output" == *"option has no value"* ]]
  [ ! -e "$DOTMGR_TARGET/.ssh/config" ]
}

@test "ssh fails on a missing inventory" {
  rm "$DOTMGR_REPO/ssh.inventory"
  run cmd_ssh
  [ "$status" -ne 0 ]
  [[ "$output" == *"ssh inventory not found"* ]]
}

@test "ssh keys merge case-insensitively across layers" {
  write_inventory "[defaults]" "user = a" "[host h]" "User = b"
  cmd_ssh
  block="$(managed_block)"
  [[ "$block" == *"Host h"$'\n'"  User b"$'\n'* ]]
  [[ "$block" != *"user a"* ]]
}

@test "dm_main dispatches the ssh command" {
  run dm_main --repo "$DOTMGR_REPO" --target "$DOTMGR_TARGET" \
    --backup-dir "$DOTMGR_BACKUP_DIR" ssh --env prod
  [ "$status" -eq 0 ]
  grep -qx "Host web1" "$DOTMGR_TARGET/.ssh/config"
}

@test "the rendered block passes a real ssh -G" {
  command -v ssh > /dev/null 2>&1 || skip "ssh not installed"
  unset DOTMGR_SSH
  mkdir -p "$DOTMGR_TARGET/.ssh"
  printf 'ServerAliveInterval 60\n' > "$DOTMGR_TARGET/.ssh/config"
  run cmd_ssh --env prod
  [ "$status" -eq 0 ]
  run ssh -G -F "$DOTMGR_TARGET/.ssh/config" web1 < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"port 2222"* ]]
  [[ "$output" == *"proxyjump jump1.prod,jump2.prod"* ]]
  # The global option after the block still applies to managed hosts.
  [[ "$output" == *"serveraliveinterval 60"* ]]
}
