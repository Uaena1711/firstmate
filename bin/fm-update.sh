#!/usr/bin/env bash
# Self-update a running firstmate and its secondmates to the latest origin.
#
# Mechanical half of the /updatefirstmate skill. Fast-forwards the running
# firstmate repo's default branch from origin, then fast-forwards every
# registered secondmate home. Local homes are treehouse worktrees or standalone
# clones; remote routes update their configured code root on that host and then
# fast-forward the persistent home to that root through
# fm-remote-secondmate-control.sh, a separate path that never calls into
# fm-ff-lib.sh and so never sees --autostash or --rebase - those two flags
# apply only to LOCAL targets (this repo and local secondmate homes).
# FAST-FORWARD ONLY BY DEFAULT,
# exactly like fm-fleet-sync.sh: never force, never create a merge commit;
# advance a target only when it is a clean fast-forward, otherwise skip and
# report. The two opt-in flags below relax that for a target this run is
# explicitly pointed at. A tracked-files fast-forward never touches the
# gitignored operational dirs (data/, state/, config/, projects/, .no-mistakes/),
# so a secondmate's in-flight work is never disrupted by the fast-forward
# itself. Worktrees of this repo share one object store, so a single fetch
# refreshes them all; standalone-clone homes are fetched on their own.
# Secondmate homes are leased at a detached HEAD on the default branch, so a
# fast-forward there advances HEAD only and never touches any other worktree's
# checkout or the shared `main` branch.
#
# The fast-forward mechanics live in bin/fm-ff-lib.sh (base_mode "origin" here);
# the same library drives the local-HEAD secondmate sync used by fm-spawn.sh and
# fm-bootstrap.sh, so there is one ff implementation, not several. Those two
# callers never pass --autostash or --rebase through - only this explicit,
# operator-invoked entry point can stash or rebase a target, so a background
# sweep can never do either on its own initiative.
#
# --autostash
#   When a target's working tree is dirty, stash its TRACKED changes only
#   (never --include-untracked - an untracked file's content lives nowhere
#   else, so a lost stash would destroy it), fast-forward (or rebase, with
#   --rebase, when also diverged), then restore the stash. Before the stash
#   is created, a durable per-target record naming the exact stash commit is
#   written under that target's own data/pending-autostash.meta, so an
#   interrupted run is always recoverable and a later session start reports
#   it (bin/fm-bootstrap.sh's AUTOSTASH_PENDING line; see docs/configuration.md
#   "Autostash record"). The record is cleared only after the restore is
#   confirmed to have applied cleanly. A target left dirty by untracked files
#   even after the tracked stash is skipped, naming those paths, instead of
#   ever stashing them. A restore conflict keeps both the stash and the
#   record and reports the exact commands to finish by hand; it never drops a
#   stash that did not cleanly apply. A target with an outstanding record
#   from a prior run is skipped until that record clears.
# --rebase
#   When a target has local commits the base lacks (diverged), replay them on
#   top of the incoming base instead of skipping. Never forces, drops a
#   commit, or rewrites anything already on the base. On conflict, aborts the
#   rebase (git rebase --abort) and reports - a half-rebased home is worse
#   than an un-updated one.
# The two flags are independent and do not imply each other: a target that is
# both dirty and diverged needs both flags; with only one, it is still
# skipped exactly as it is today. With neither flag, behavior is unchanged.
#
# It does NOT re-read AGENTS.md or nudge secondmates itself - those are LLM /
# tmux actions the skill performs. The script's job is the safe git mechanics
# plus a parseable summary telling the caller what to do next:
#   - one status line per target (updated/already current/skipped)
#   - reread-firstmate: yes|no    (did the running firstmate's instructions change)
#   - nudge-secondmates: fm-<id>...|none   (updated live secondmates to nudge)
#
# Usage: fm-update.sh [--autostash] [--rebase] [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SECONDMATES_MD="$FM_HOME/data/secondmates.md"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

AUTOSTASH=no
REBASE=no
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --autostash) AUTOSTASH=yes; shift ;;
    --rebase) REBASE=yes; shift ;;
    *) usage; exit 1 ;;
  esac
done

# --- main firstmate repo ---------------------------------------------------

reread_firstmate="no"
ff_target "$FM_ROOT" "firstmate" origin no no "$AUTOSTASH" "$REBASE"
if [ "$FF_STATUS" = "updated" ] && [ -n "$FF_INSTR" ]; then
  reread_firstmate="yes"
fi

# --- secondmates -----------------------------------------------------------
# An updated live secondmate is nudged whenever it advanced (nudge_requires_instr
# is "no" here): /updatefirstmate's nudge is a gentle re-read steer, kept on the
# same condition it has always used.

FF_NUDGE_WINDOWS=""
FF_SEEN_HOMES=""

# Live direct reports first: state/<id>.meta with kind=secondmate carries the
# authoritative home= path.
sweep_live_secondmate_metas "$STATE" origin no "$SECONDMATES_MD" "$AUTOSTASH" "$REBASE"

# Registry backstop: a secondmate registered in data/secondmates.md but without
# a live meta (e.g. between restarts) is still its persistent on-disk home.
if [ -f "$SECONDMATES_MD" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "- "*) ;;
      *) continue ;;
    esac
    if ! secondmate_registry_parse_line "$line"; then
      echo "secondmate registry: skipped malformed entry: $line" >&2
      continue
    fi
    id=$SECONDMATE_REGISTRY_ID
    home=$SECONDMATE_REGISTRY_HOME
    if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
      if remote_out=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh update "$id" < /dev/null 2>&1); then
        remote_result=$(printf '%s\n' "$remote_out" | tail -1)
        case "$remote_result" in
          synced:*)
            echo "remote secondmate $id: updated on $SECONDMATE_REGISTRY_HOST (${remote_result#synced: })"
            if [ -f "$STATE/$id.meta" ] && grep -qx 'kind=secondmate' "$STATE/$id.meta"; then
              FF_NUDGE_WINDOWS="$FF_NUDGE_WINDOWS fm-$id"
            fi
            ;;
          current:*) echo "remote secondmate $id: already current on $SECONDMATE_REGISTRY_HOST (${remote_result#current: })" ;;
          *) echo "remote secondmate $id: skipped on $SECONDMATE_REGISTRY_HOST: malformed update result" >&2 ;;
        esac
      else
        echo "remote secondmate $id: skipped on $SECONDMATE_REGISTRY_HOST: ${remote_out%%$'\n'*}" >&2
      fi
    else
      process_secondmate "$id" "$home" "" origin no "$AUTOSTASH" "$REBASE"
    fi
  done < "$SECONDMATES_MD"
fi

# --- caller action summary -------------------------------------------------

echo "reread-firstmate: $reread_firstmate"
echo "nudge-secondmates:${FF_NUDGE_WINDOWS:- none}"
