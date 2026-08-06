#!/usr/bin/env bash
# Behavior tests for bin/fm-bedrock.sh, the standalone per-directory Bedrock
# provisioning tool.
#
# Discovery is skipped throughout with --no-discover, so these tests never reach
# the aws CLI and pin only what the tool writes, reports, and removes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BEDROCK="$ROOT/bin/fm-bedrock.sh"
TMP_ROOT=$(fm_test_tmproot fm-bedrock)

make_project() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  fm_git_init_commit "$dir"
  # The tool canonicalizes its target, so fixtures compare against the same form.
  (cd "$dir" && pwd -P)
}

settings_query() {
  local dir=$1 filter=$2
  jq -r "$filter" "$dir/.claude/settings.local.json"
}

test_enable_writes_env_and_preserves_existing_keys() {
  local dir out status
  dir=$(make_project enable)
  mkdir -p "$dir/.claude"
  printf '{"hooks":{"Stop":[]},"permissions":{"allow":["Bash"]}}\n' > "$dir/.claude/settings.local.json"

  out=$("$BEDROCK" --profile demo --region us-east-1 --no-discover "$dir" 2>&1)
  status=$?
  expect_code 0 "$status" "enabling Bedrock on a project directory should succeed"
  assert_contains "$out" "bedrock enabled for $dir" "the tool did not confirm which directory it configured"
  [ "$(settings_query "$dir" '.env.CLAUDE_CODE_USE_BEDROCK')" = 1 ] || fail "CLAUDE_CODE_USE_BEDROCK was not set"
  [ "$(settings_query "$dir" '.env.AWS_PROFILE')" = demo ] || fail "AWS_PROFILE was not written"
  [ "$(settings_query "$dir" '.env.AWS_REGION')" = us-east-1 ] || fail "AWS_REGION was not written"
  [ "$(settings_query "$dir" '.permissions.allow[0]')" = Bash ] || fail "an existing settings key was overwritten by the merge"
  assert_present "$dir/.claude/settings.local.json.bak" "the tool kept no backup of the previous settings"
  pass "enabling merges the provider env without overwriting existing settings keys"
}

test_status_reports_on_and_off() {
  local dir out
  dir=$(make_project status)

  out=$("$BEDROCK" --status "$dir" 2>&1)
  assert_contains "$out" "bedrock: OFF" "status did not report an unconfigured directory as off"

  "$BEDROCK" --profile demo --no-discover "$dir" >/dev/null 2>&1
  out=$("$BEDROCK" --status "$dir" 2>&1)
  assert_contains "$out" "bedrock: ON" "status did not report a configured directory as on"
  assert_contains "$out" "demo" "status did not show the configured profile"
  pass "status reports the directory's current provider either way"
}

test_off_removes_only_the_bedrock_keys() {
  local dir out status
  dir=$(make_project off)
  mkdir -p "$dir/.claude"
  printf '{"env":{"OTHER":"keep"},"hooks":{"Stop":[]}}\n' > "$dir/.claude/settings.local.json"
  "$BEDROCK" --profile demo --no-discover "$dir" >/dev/null 2>&1

  out=$("$BEDROCK" --off "$dir" 2>&1)
  status=$?
  expect_code 0 "$status" "removing the Bedrock settings should succeed"
  assert_contains "$out" "bedrock config removed" "the tool did not confirm the removal"
  [ "$(settings_query "$dir" '.env.OTHER')" = keep ] || fail "an unrelated env key was removed with the Bedrock keys"
  [ "$(settings_query "$dir" '.env | has("CLAUDE_CODE_USE_BEDROCK")')" = false ] || fail "CLAUDE_CODE_USE_BEDROCK survived --off"
  [ "$(settings_query "$dir" 'has("hooks")')" = true ] || fail "--off removed the unrelated hooks block"
  pass "--off removes only the Bedrock keys and leaves the rest of the file alone"
}

test_enable_without_profile_refuses() {
  local dir out status
  dir=$(make_project noprofile)

  out=$("$BEDROCK" --no-discover "$dir" 2>&1)
  status=$?
  expect_code 1 "$status" "enabling without a profile should refuse"
  assert_contains "$out" "--profile is required to enable Bedrock" "the refusal did not name the missing profile"
  assert_absent "$dir/.claude/settings.local.json" "the refusal still wrote a settings file"
  pass "enabling without an AWS profile refuses before writing anything"
}

test_invalid_input_refuses() {
  local out status
  out=$("$BEDROCK" --bogus "$TMP_ROOT" 2>&1)
  status=$?
  expect_code 1 "$status" "an unknown option should refuse"
  assert_contains "$out" "unknown option: --bogus" "the refusal did not name the unknown option"

  out=$("$BEDROCK" --profile demo --no-discover "$TMP_ROOT/not-a-directory" 2>&1)
  status=$?
  expect_code 1 "$status" "a missing project directory should refuse"
  assert_contains "$out" "not a directory" "the refusal did not name the bad project path"
  pass "unknown options and bad project paths refuse with named diagnostics"
}

test_enable_refuses_malformed_settings() {
  local dir out status
  dir=$(make_project malformed)
  mkdir -p "$dir/.claude"
  printf '{not json\n' > "$dir/.claude/settings.local.json"

  out=$("$BEDROCK" --profile demo --no-discover "$dir" 2>&1)
  status=$?
  expect_code 1 "$status" "a malformed settings file should refuse"
  assert_contains "$out" "is not valid JSON" "the refusal did not name the malformed settings file"
  assert_grep 'not json' "$dir/.claude/settings.local.json" "the refusal modified the malformed file"
  pass "a malformed settings file refuses instead of being overwritten"
}

test_enable_writes_env_and_preserves_existing_keys
test_status_reports_on_and_off
test_off_removes_only_the_bedrock_keys
test_enable_without_profile_refuses
test_invalid_input_refuses
test_enable_refuses_malformed_settings

echo "# all fm-bedrock tests passed"
