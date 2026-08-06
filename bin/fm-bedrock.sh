#!/usr/bin/env bash
# Point Claude Code at AWS Bedrock for ONE project directory, scoped to that
# directory instead of the shell session.
#
# CLAUDE_CODE_USE_BEDROCK is a session-wide switch, so exporting it hijacks every
# Claude Code session until it is unset again. This writes the same settings into
# a single project's .claude/settings.local.json, which is gitignored, so the AWS
# profile and Bedrock routing never reach teammates and nothing has to be unset.
# The provider is global per session: a directory is either Bedrock or the
# Anthropic API, never both in one model picker.
#
# This is the standalone tool for a persistent project directory. A disposable
# crewmate worktree gets the same env block from `fm-spawn.sh --bedrock`, written
# before the agent launches; neither path activates from the mere presence of a
# config file.
#
# Usage:
#   fm-bedrock.sh --profile <name> [--region <region>] [--no-discover] <project-path>
#   fm-bedrock.sh --status <project-path>
#   fm-bedrock.sh --off <project-path>
#   fm-bedrock.sh --help
#
# Options:
#   -p, --profile <name>   AWS profile with Bedrock access; required to enable
#   -r, --region <region>  AWS region (default: eu-central-1)
#       --no-discover      Skip querying Bedrock for inference-profile ids and
#                          write only the env block, leaving Claude Code on its
#                          built-in Bedrock model defaults
#       --status           Print what the project is currently configured for
#       --off              Remove this script's Bedrock settings from the project
#
# Writes <project-path>/.claude/settings.local.json:
#   .env.CLAUDE_CODE_USE_BEDROCK = "1"
#   .env.AWS_REGION              = <region>
#   .env.AWS_PROFILE             = <profile>
#   .modelOverrides              = { "<claude-code-model-id>": "<bedrock-id>" }
# Existing keys are merged, not overwritten, and a .bak copy of the previous file
# is kept. .claude/settings.local.json is appended to the project's .gitignore
# when git does not already ignore it. Requires jq; discovery also requires the
# aws CLI and is skipped with a notice when it is unavailable.
# Claude Code reads these at startup, so restart it in that directory to apply.
set -eu

REGION="eu-central-1"
PROFILE=""
MODE="on"
DISCOVER=1
TARGET=""

die() { printf 'fm-bedrock: %s\n' "$*" >&2; exit 1; }
note() { printf '  %s\n' "$*"; }

usage() {
  sed -n '2,41p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    -p|--profile)  PROFILE="${2:-}"; [ -n "$PROFILE" ] || die "--profile needs a value"; shift 2 ;;
    --profile=*)   PROFILE="${1#--profile=}"; [ -n "$PROFILE" ] || die "--profile needs a value"; shift ;;
    -r|--region)   REGION="${2:-}"; [ -n "$REGION" ] || die "--region needs a value"; shift 2 ;;
    --region=*)    REGION="${1#--region=}"; [ -n "$REGION" ] || die "--region needs a value"; shift ;;
    --no-discover) DISCOVER=0; shift ;;
    --off)         MODE="off"; shift ;;
    --status)      MODE="status"; shift ;;
    -h|--help)     usage; exit 0 ;;
    -*)            die "unknown option: $1 (try --help)" ;;
    *)             [ -z "$TARGET" ] || die "only one project path allowed"; TARGET="$1"; shift ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq is required but not on PATH"
[ -n "$TARGET" ] || { usage >&2; exit 2; }
[ -d "$TARGET" ] || die "not a directory: $TARGET"

TARGET="$(cd "$TARGET" && pwd -P)"
FILE="$TARGET/.claude/settings.local.json"

if [ "$MODE" = status ]; then
  printf 'project: %s\n' "$TARGET"
  if [ ! -f "$FILE" ]; then
    printf 'bedrock: OFF (no .claude/settings.local.json)\n'
    exit 0
  fi
  if jq -e '.env.CLAUDE_CODE_USE_BEDROCK' "$FILE" >/dev/null 2>&1; then
    printf 'bedrock: ON\n'
  else
    printf 'bedrock: OFF\n'
  fi
  jq '{env: (.env // {}), modelOverrides: (.modelOverrides // {})}' "$FILE"
  exit 0
fi

if [ "$MODE" = off ]; then
  [ -f "$FILE" ] || { printf 'nothing to do - %s does not exist\n' "$FILE"; exit 0; }
  cp "$FILE" "$FILE.bak"
  tmp="$(mktemp)"
  jq '
    (if has("env") then
       .env |= del(.CLAUDE_CODE_USE_BEDROCK, .AWS_REGION, .AWS_PROFILE)
     else . end)
    | (if (.env? // {}) == {} then del(.env) else . end)
    | del(.modelOverrides)
  ' "$FILE" > "$tmp"
  jq -e . "$tmp" >/dev/null || { rm -f "$tmp"; die "produced invalid JSON; original untouched"; }
  mv "$tmp" "$FILE"
  printf 'bedrock config removed from %s\n' "$FILE"
  note "backup: $FILE.bak"
  note "restart Claude Code in that directory to pick it up"
  exit 0
fi

[ -n "$PROFILE" ] || die "--profile is required to enable Bedrock (try --help)"

# Bedrock cross-region inference profiles are prefixed by geography, not by the
# full region name: eu-central-1 -> "eu.", us-east-1 -> "us.", ap-* -> "apac.".
case "$REGION" in
  eu-*) PREFIX="eu" ;;
  us-*) PREFIX="us" ;;
  ap-*) PREFIX="apac" ;;
  ca-*) PREFIX="ca" ;;
  *)    PREFIX="${REGION%%-*}" ;;
esac

OVERRIDES='{}'
if [ "$DISCOVER" -eq 1 ]; then
  if ! command -v aws >/dev/null 2>&1; then
    note "aws CLI not found - skipping model discovery"
  else
    # Ask Bedrock which Anthropic inference profiles exist rather than hardcoding
    # ids that drift. The Claude Code model id is the profile id without its
    # "<geo>.anthropic." prefix and without any trailing date or -vN[:N] suffix:
    #   eu.anthropic.claude-opus-4-6-v1              -> claude-opus-4-6
    #   eu.anthropic.claude-sonnet-4-5-20250929-v1:0 -> claude-sonnet-4-5
    raw="$(aws bedrock list-inference-profiles \
             --region "$REGION" --profile "$PROFILE" \
             --max-results 100 \
             --query 'inferenceProfileSummaries[].inferenceProfileId' \
             --output json 2>/dev/null || true)"
    if [ -n "$raw" ] && printf '%s' "$raw" | jq -e 'type == "array"' >/dev/null 2>&1; then
      OVERRIDES="$(printf '%s' "$raw" | jq -c --arg pfx "${PREFIX}.anthropic." '
        map(select(startswith($pfx)))
        | map({
            key:   (sub("^[a-z0-9-]+\\.anthropic\\."; "") | sub("(-[0-9]{8})?-v[0-9]+(:[0-9]+)?$"; "")),
            value: .
          })
        | from_entries
      ' 2>/dev/null || echo '{}')"
      n="$(printf '%s' "$OVERRIDES" | jq 'length')"
      if [ "$n" -gt 0 ]; then
        note "discovered $n Anthropic inference profile(s) in $REGION"
      else
        note "no ${PREFIX}.anthropic.* inference profiles found in $REGION"
      fi
    else
      note "could not list Bedrock inference profiles (credentials, permission, or region?)"
      note "writing env only - Claude Code will use its built-in Bedrock defaults"
    fi
  fi
fi

mkdir -p "$TARGET/.claude"
[ -f "$FILE" ] || echo '{}' > "$FILE"
jq -e . "$FILE" >/dev/null 2>&1 || die "$FILE is not valid JSON - fix it first"
cp "$FILE" "$FILE.bak"

tmp="$(mktemp)"
jq --arg region "$REGION" --arg profile "$PROFILE" --argjson ovr "$OVERRIDES" '
  .env = ((.env // {}) + {
    "CLAUDE_CODE_USE_BEDROCK": "1",
    "AWS_REGION":  $region,
    "AWS_PROFILE": $profile
  })
  | if ($ovr | length) > 0
    then .modelOverrides = ((.modelOverrides // {}) + $ovr)
    else . end
' "$FILE" > "$tmp"
jq -e . "$tmp" >/dev/null || { rm -f "$tmp"; die "produced invalid JSON; original untouched"; }
mv "$tmp" "$FILE"

if git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1; then
  if ! git -C "$TARGET" check-ignore -q ".claude/settings.local.json" 2>/dev/null; then
    printf '\n.claude/settings.local.json\n' >> "$TARGET/.gitignore"
    note "added .claude/settings.local.json to .gitignore"
  fi
fi

printf 'bedrock enabled for %s\n' "$TARGET"
note "region:  $REGION"
note "profile: $PROFILE"
note "file:    $FILE  (backup: $FILE.bak)"
note "restart Claude Code in that directory to pick it up"
