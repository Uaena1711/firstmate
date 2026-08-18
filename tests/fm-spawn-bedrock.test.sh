#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's explicit --bedrock opt-in.
#
# These tests drive fm-spawn through the worktree settings write with a fake tmux
# pane and a real isolated git worktree, then read the settings file the crewmate
# would actually start under. The regression that matters most is the default: a
# present config/crew-bedrock must not activate Bedrock on its own.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-bedrock)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

write_bedrock_config() {
  local home=$1 profile=$2 region=$3
  printf 'AWS_PROFILE=%s\nAWS_REGION=%s\n' "$profile" "$region" > "$home/config/crew-bedrock"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

run_ship_spawn() {
  run_spawn "$@" --mode no-mistakes --yolo off
}

read_case_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

settings_query() {
  local wt=$1 filter=$2
  jq -r "$filter" "$wt/.claude/settings.local.json"
}

assert_hooks_intact() {
  local wt=$1 context=$2
  assert_contains "$(settings_query "$wt" '.hooks.Stop[0].hooks[0].command')" ".turn-ended" \
    "$context: the Stop hook's turn-end notification did not survive the settings merge"
  assert_contains "$(settings_query "$wt" '.hooks.UserPromptSubmit[0].hooks[0].command')" "fm-busy-event.sh" \
    "$context: the busy-state hook did not survive the settings merge"
  [ "$(settings_query "$wt" '[.hooks | keys[]] | sort | join(",")')" = "SessionEnd,Stop,StopFailure,UserPromptSubmit" ] \
    || fail "$context: the hooks block lost or gained an event after the settings merge"
}

test_config_alone_does_not_activate_bedrock() {
  local rec id out status
  id=bedrock-default-off-b1
  rec=$(make_spawn_case bedrock-default-off claude "$id")
  read_case_record "$rec"
  write_bedrock_config "$HOME_DIR" standing-profile eu-central-1

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without --bedrock should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report claude"
  [ "$(settings_query "$WT_DIR" 'has("env")')" = false ] \
    || fail "config/crew-bedrock alone activated Bedrock; the default must stay the ordinary Anthropic account"
  assert_no_grep CLAUDE_CODE_USE_BEDROCK "$WT_DIR/.claude/settings.local.json" \
    "settings.local.json carries Bedrock env with no --bedrock flag"
  pass "a present config/crew-bedrock writes no provider env without --bedrock"
}

test_no_config_and_no_flag_writes_no_env() {
  local rec id out status
  id=bedrock-absent-b2
  rec=$(make_spawn_case bedrock-absent claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn with neither config nor flag should succeed"
  [ "$(settings_query "$WT_DIR" 'has("env")')" = false ] \
    || fail "spawn wrote a provider env block with no Bedrock configuration at all"
  assert_hooks_intact "$WT_DIR" "no-bedrock spawn"
  pass "a spawn with no Bedrock configuration writes no env block"
}

test_flag_writes_env_from_config() {
  local rec id out status
  id=bedrock-flag-b3
  rec=$(make_spawn_case bedrock-flag claude "$id")
  read_case_record "$rec"
  write_bedrock_config "$HOME_DIR" standing-profile eu-central-1

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --bedrock)
  status=$?
  expect_code 0 "$status" "claude spawn with --bedrock should succeed"
  [ "$(settings_query "$WT_DIR" '.env.CLAUDE_CODE_USE_BEDROCK')" = 1 ] \
    || fail "--bedrock did not set CLAUDE_CODE_USE_BEDROCK"
  [ "$(settings_query "$WT_DIR" '.env.AWS_PROFILE')" = standing-profile ] \
    || fail "--bedrock did not take AWS_PROFILE from config/crew-bedrock"
  [ "$(settings_query "$WT_DIR" '.env.AWS_REGION')" = eu-central-1 ] \
    || fail "--bedrock did not take AWS_REGION from config/crew-bedrock"
  assert_hooks_intact "$WT_DIR" "--bedrock spawn"
  pass "--bedrock writes the provider env from config/crew-bedrock and keeps the hooks intact"
}

test_flag_profile_overrides_config_profile() {
  local rec id out status
  id=bedrock-override-b4
  rec=$(make_spawn_case bedrock-override claude "$id")
  read_case_record "$rec"
  write_bedrock_config "$HOME_DIR" standing-profile eu-central-1

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --bedrock=task-profile)
  status=$?
  expect_code 0 "$status" "claude spawn with --bedrock=<profile> should succeed"
  [ "$(settings_query "$WT_DIR" '.env.AWS_PROFILE')" = task-profile ] \
    || fail "--bedrock=<profile> did not override the profile recorded in config/crew-bedrock"
  [ "$(settings_query "$WT_DIR" '.env.AWS_REGION')" = eu-central-1 ] \
    || fail "--bedrock=<profile> dropped the region recorded in config/crew-bedrock"
  pass "--bedrock=<profile> overrides the configured profile and keeps the configured region"
}

test_flag_without_any_profile_refuses_before_launch() {
  local rec id out status
  id=bedrock-noprofile-b5
  rec=$(make_spawn_case bedrock-noprofile claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --bedrock)
  status=$?
  expect_code 1 "$status" "--bedrock with no resolvable profile should refuse the spawn"
  assert_contains "$out" "--bedrock needs an AWS profile" \
    "the refusal did not name the missing requirement"
  assert_absent "$HOME_DIR/state/$id.meta" "the refusal wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "the refusal typed a launch command"
  pass "--bedrock with no resolvable profile refuses instead of writing a half-configured worktree"
}

test_empty_flag_value_refuses() {
  local rec id out status
  id=bedrock-emptyvalue-b6
  rec=$(make_spawn_case bedrock-emptyvalue claude "$id")
  read_case_record "$rec"
  write_bedrock_config "$HOME_DIR" standing-profile eu-central-1

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --bedrock=)
  status=$?
  expect_code 1 "$status" "--bedrock= with an empty value should refuse the spawn"
  assert_contains "$out" "--bedrock=<aws-profile> requires a non-empty value" \
    "the refusal did not name the empty profile value"
  assert_absent "$HOME_DIR/state/$id.meta" "the empty-value refusal wrote task metadata"
  pass "--bedrock= with an empty value refuses rather than falling back silently"
}

test_flag_refused_on_non_claude_harness() {
  local rec id out status
  id=bedrock-codex-b7
  rec=$(make_spawn_case bedrock-codex codex "$id")
  read_case_record "$rec"
  write_bedrock_config "$HOME_DIR" standing-profile eu-central-1

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --bedrock)
  status=$?
  expect_code 1 "$status" "--bedrock on a non-claude harness should refuse the spawn"
  assert_contains "$out" "--bedrock applies only to the claude harness" \
    "the refusal did not explain that Bedrock is claude-only"
  assert_absent "$HOME_DIR/state/$id.meta" "the non-claude refusal wrote task metadata"
  pass "--bedrock refuses loudly on a harness with no Bedrock provider switch"
}

test_non_claude_harness_is_unaffected_without_the_flag() {
  local rec id out status harness
  # kimi, pi and pi-signed are omitted because their spawns now resolve a real
  # executable on PATH first (a full Kimi home, or resolve_pi_executable), which
  # this fake bin deliberately does not provide. All of them reach the same
  # claude-only branch as the harnesses below, so coverage is unchanged.
  for harness in codex opencode grok; do
    id="bedrock-untouched-$harness-b8"
    rec=$(make_spawn_case "bedrock-untouched-$harness" "$harness" "$id")
    read_case_record "$rec"
    write_bedrock_config "$HOME_DIR" standing-profile eu-central-1

    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
    status=$?
    expect_code 0 "$status" "$harness spawn with config/crew-bedrock present should succeed"
    assert_contains "$out" "spawned $id harness=$harness" "spawn did not report the $harness harness"
    assert_no_grep CLAUDE_CODE_USE_BEDROCK "$HOME_DIR/state/$id.meta" \
      "$harness task metadata mentions Bedrock"
    assert_absent "$WT_DIR/.claude/settings.local.json" \
      "$harness spawn wrote claude's settings.local.json"
  done
  pass "codex, opencode, and grok spawns are untouched by Bedrock configuration"
}

test_scout_accepts_the_flag() {
  local rec id out status
  id=bedrock-scout-b9
  rec=$(make_spawn_case bedrock-scout claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout --bedrock=scout-profile)
  status=$?
  expect_code 0 "$status" "scout spawn with --bedrock should succeed"
  [ "$(settings_query "$WT_DIR" '.env.AWS_PROFILE')" = scout-profile ] \
    || fail "scout spawn did not receive the requested Bedrock profile"
  [ "$(settings_query "$WT_DIR" 'has("env") and (.env | has("AWS_REGION"))')" = false ] \
    || fail "scout spawn invented an AWS_REGION with no configured region"
  pass "a scout spawn opts in the same way and omits an unconfigured region"
}

test_config_alone_does_not_activate_bedrock
test_no_config_and_no_flag_writes_no_env
test_flag_writes_env_from_config
test_flag_profile_overrides_config_profile
test_flag_without_any_profile_refuses_before_launch
test_empty_flag_value_refuses
test_flag_refused_on_non_claude_harness
test_non_claude_harness_is_unaffected_without_the_flag
test_scout_accepts_the_flag

echo "# all fm-spawn-bedrock tests passed"
