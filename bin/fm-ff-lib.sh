# shellcheck shell=bash
# Shared fast-forward machinery for firstmate self-sync.
# Usage: . bin/fm-ff-lib.sh   (after FM_ROOT and FM_HOME are set)
#
# This is the one implementation of "advance a firstmate checkout to a base by a
# clean fast-forward, never forcing or merging" used by every sync path:
#   - /updatefirstmate (bin/fm-update.sh) pulls from origin: base_mode "origin".
#   - the local-HEAD secondmate sync (bin/fm-spawn.sh on launch, bin/fm-bootstrap.sh
#     on startup) follows the PRIMARY checkout's current default-branch commit:
#     base_mode is that local commit, with NO fetch and no origin dependency.
#
# ff_target never stashes or rebases on its own initiative: a dirty or diverged
# target is skipped and reported unless the CALLER explicitly opts in per-call
# with the trailing autostash/rebase arguments (both default "no"). Only
# bin/fm-update.sh's own --autostash/--rebase CLI flags ever pass "yes" through;
# fm-spawn.sh's launch-time sync and fm-bootstrap.sh's secondmate-convergence
# sweep call with the same fixed argument count they always have, so they stay
# on the conservative skip-and-report path with no code change on their side.
# See ff_autostash_create/ff_autostash_restore below for the stash mechanics.
# A linked-worktree secondmate home already holds the primary's commit in the
# shared object store, so its local-HEAD sync is a purely local fast-forward that
# never touches the network. A standalone clone moves through that path only when
# it already has the target; otherwise it is skipped until the origin path updates it.
# A tracked-files fast-forward never touches the gitignored operational dirs
# (data/, state/, config/, projects/, .no-mistakes/), so it cannot disturb a
# secondmate's backlog, projects, or in-flight work.
# The seeded .fm-secondmate-home identity marker is gitignored too; the local
# sync tolerates only that marker during the one-time upgrade of pre-ignore
# linked-worktree homes.
# Homes are leased at a detached HEAD on the
# default branch, so the fast-forward advances HEAD only and never moves the
# shared default branch or any other worktree's checkout.

SUB_HOME_MARKER="${SUB_HOME_MARKER:-.fm-secondmate-home}"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-secondmate-registry-lib.sh"

# --- helpers ---------------------------------------------------------------

first_line() {
  printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'
}

# Prefer a `CONFLICT` line from multi-line git output: `git rebase` writes its
# "Rebasing (N/M)" progress as carriage-return-only updates, which collapse
# onto line 1 with no newline between them, burying the actual reason on a
# later real line. Falls back to first_line for output with no CONFLICT line.
conflict_or_first_line() {
  local out=$1 line
  line=$(printf '%s\n' "$out" | grep -m1 '^CONFLICT' || true)
  [ -n "$line" ] || line=$(first_line "$out")
  printf '%s\n' "$line"
}

default_branch() {
  local dir=$1 ref branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

# Resolve the PRIMARY checkout's current default-branch commit - the local-HEAD
# sync target every secondmate follows. Reads the default branch *ref* rather than
# HEAD, so even a primary stranded on a feature branch (the worktree tangle of
# section 8) still yields the true default-branch tip instead of propagating a
# stray feature branch to the fleet. Echoes the commit SHA, or returns 1.
primary_head_commit() {
  local root=$1 default
  default=$(default_branch "$root") || return 1
  git -C "$root" rev-parse --verify --quiet "refs/heads/$default^{commit}" 2>/dev/null || return 1
}

resolve_path() {
  # Resolve to a canonical absolute path, falling back to the literal input
  # when the directory does not exist (so callers can still dedup/skip on it).
  ( cd "$1" 2>/dev/null && pwd -P ) || printf '%s\n' "$1"
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || return 1
  cd "$path" && pwd -P
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

VALIDATED_HOME=""
VALIDATION_ERROR=""

validate_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      VALIDATION_ERROR="secondmate $name directory must resolve inside the secondmate home"
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P) || {
        VALIDATION_ERROR="secondmate $name directory cannot be resolved"
        return 1
      }
    elif [ -e "$dir" ]; then
      VALIDATION_ERROR="secondmate $name path is not a directory"
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      VALIDATION_ERROR="secondmate $name directory must resolve inside the secondmate home"
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      VALIDATION_ERROR="secondmate $name directory cannot be inside the active firstmate home"
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      VALIDATION_ERROR="secondmate $name directory cannot be inside the firstmate repo"
      return 1
    fi
  done
}

validate_secondmate_home() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  VALIDATED_HOME=""
  VALIDATION_ERROR=""
  abs_home=$(resolved_existing_dir "$home") || {
    VALIDATION_ERROR="not a directory"
    return 1
  }
  abs_active_home=$(resolved_existing_dir "$FM_HOME") || {
    VALIDATION_ERROR="active firstmate home is not a directory"
    return 1
  }
  abs_root=$(resolved_existing_dir "$FM_ROOT") || {
    VALIDATION_ERROR="firstmate repo is not a directory"
    return 1
  }
  if [ "$abs_home" = "/" ]; then
    VALIDATION_ERROR="secondmate home cannot be the filesystem root"
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    VALIDATION_ERROR="secondmate home cannot be the active firstmate home"
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    VALIDATION_ERROR="secondmate home cannot be the firstmate repo"
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    VALIDATION_ERROR="secondmate home cannot be inside the active firstmate home"
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    VALIDATION_ERROR="secondmate home cannot be inside the firstmate repo"
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    VALIDATION_ERROR="secondmate home cannot be an ancestor of the active firstmate home"
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    VALIDATION_ERROR="secondmate home cannot be an ancestor of the firstmate repo"
    return 1
  fi
  validate_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ -L "$abs_home/$SUB_HOME_MARKER" ]; then
    VALIDATION_ERROR="secondmate marker must not be a symlink"
    return 1
  fi
  if [ ! -f "$abs_home/$SUB_HOME_MARKER" ]; then
    VALIDATION_ERROR="not a seeded secondmate home"
    return 1
  fi
  marker_id=$(cat "$abs_home/$SUB_HOME_MARKER" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    VALIDATION_ERROR="marked for secondmate ${marker_id:-unknown}, expected $id"
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    VALIDATION_ERROR="not a firstmate home (missing AGENTS.md)"
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    VALIDATION_ERROR="not a firstmate home (missing bin/)"
    return 1
  fi
  VALIDATED_HOME="$abs_home"
}

# A single fetch refreshes every worktree that shares an object store, so fetch
# each distinct git-common-dir at most once. Used ONLY by the origin base mode;
# the local-HEAD sync never fetches.
FETCHED=""
fetch_once() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  if [ -n "$common" ]; then
    case " $FETCHED " in
      *" $common "*) return 0 ;;
    esac
  fi
  if git -C "$dir" fetch origin --prune --quiet 2>/dev/null; then
    [ -n "$common" ] && FETCHED="$FETCHED $common"
    return 0
  fi
  return 1
}

# Which watched instruction paths changed between HEAD and BASE (comma list).
# These are the files a running agent actually reads or runs: its instructions
# (AGENTS.md, which CLAUDE.md imports via @AGENTS.md), its agent-loaded skills
# (.agents/skills/), and its tooling (bin/). Public skills/ is installer-facing
# and intentionally not part of this watched instruction surface.
changed_instr() {
  local dir=$1 base=$2 p out=""
  for p in AGENTS.md bin .agents/skills; do
    if ! git -C "$dir" diff --quiet HEAD "$base" -- "$p" 2>/dev/null; then
      out="$out${out:+, }$p"
    fi
  done
  printf '%s' "$out"
}

# Full `git status --porcelain` listing (every line, not just the first), minus
# the seeded secondmate marker line when ignore_seed_marker=yes. Callers that
# only need a dirty/clean verdict just test it for emptiness; ff_target's
# autostash path also splits it into tracked vs untracked lines.
dirty_status() {
  local dir=$1 ignore_seed_marker=${2:-no}
  if [ "$ignore_seed_marker" = yes ]; then
    git -C "$dir" status --porcelain 2>/dev/null | awk -v marker="?? $SUB_HOME_MARKER" '$0 != marker { print }'
  else
    git -C "$dir" status --porcelain 2>/dev/null
  fi
}

# List this home's LIVE secondmate direct reports from state/<id>.meta records.
# The meta file is the liveness signal; data/secondmates.md is only the fallback
# for durable fields such as home= when an older/incomplete meta lacks them.
# Output is pipe-delimited: id|home|window|meta-file.
live_secondmate_meta_records() {
  local state=$1 registry=${2:-} meta id home window
  [ -d "$state" ] || return 0
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    grep -q '^kind=secondmate$' "$meta" 2>/dev/null || continue
    id=$(basename "$meta" .meta)
    home=$(grep '^home=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    if [ -z "$home" ] && [ -n "$registry" ]; then
      home=$(secondmate_registry_field "$registry" "$id" home || true)
    fi
    window=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    printf '%s|%s|%s|%s\n' "$id" "$home" "$window" "$meta"
  done
}

# --- opt-in autostash (bin/fm-update.sh --autostash only) ------------------
#
# Per-target durable record naming the exact stash commit, written under the
# TARGET's own data/ (never the caller's), so that target's own next session
# start surfaces it (bin/fm-bootstrap.sh's AUTOSTASH_PENDING line) regardless
# of which home's process created it. Its mere presence blocks a second
# autostash run against the same target - see the pre-existing-record check
# in ff_target_autostash below. docs/configuration.md "Autostash record" owns
# the record's schema for operators; this is the one place that writes it.
FF_AUTOSTASH_RECORD_NAME="pending-autostash.meta"

ff_autostash_record_path() {
  printf '%s/data/%s\n' "$1" "$FF_AUTOSTASH_RECORD_NAME"
}

ff_autostash_write_record() {
  local record=$1 target=$2 sha=$3 message=$4 tmp
  tmp="$record.tmp.$$"
  {
    printf 'target=%s\n' "$target"
    printf 'stash_sha=%s\n' "$sha"
    printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'message=%s\n' "$message"
  } > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$record" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# Stash dir's TRACKED changes only (never --include-untracked: a tracked
# file's content survives in git's object store even if the stash reference
# is lost, an untracked file's does not) and reset the working tree to HEAD.
# Writes the durable record BEFORE the stash becomes a real, recoverable
# stash entry (git stash store), so a process death between the two leaves
# either nothing (record never written) or a record naming a real,
# independently restorable git object. On any failure the working tree is
# left exactly as found - dirty, un-stashed - never partially stashed.
# Sets FF_AUTOSTASH_SHA on success, FF_AUTOSTASH_ERROR on failure.
FF_AUTOSTASH_SHA=""
FF_AUTOSTASH_ERROR=""
ff_autostash_create() {
  local dir=$1 record=$2 message=$3 ignore_seed_marker=$4 sha
  FF_AUTOSTASH_SHA=""
  FF_AUTOSTASH_ERROR=""
  sha=$(git -C "$dir" stash create "$message" 2>/dev/null) || true
  if [ -z "$sha" ]; then
    FF_AUTOSTASH_ERROR="could not create a stash commit from the tracked changes"
    return 1
  fi
  if ! mkdir -p "$dir/data" 2>/dev/null; then
    FF_AUTOSTASH_ERROR="could not create $dir/data for the autostash record"
    return 1
  fi
  if ! ff_autostash_write_record "$record" "$dir" "$sha" "$message"; then
    FF_AUTOSTASH_ERROR="could not write the autostash record at $record"
    return 1
  fi
  if ! git -C "$dir" stash store --quiet -m "$message" "$sha" 2>/dev/null; then
    rm -f "$record"
    FF_AUTOSTASH_ERROR="could not store the stash entry"
    return 1
  fi
  if ! git -C "$dir" reset --quiet --hard HEAD 2>/dev/null; then
    FF_AUTOSTASH_ERROR="could not reset the working tree after stashing; the stash is preserved - inspect and apply it with: git -C $dir stash apply $sha"
    return 1
  fi
  if [ -n "$(dirty_status "$dir" "$ignore_seed_marker")" ]; then
    FF_AUTOSTASH_ERROR="working tree unexpectedly still dirty after stashing tracked changes; the stash is preserved - inspect and apply it with: git -C $dir stash apply $sha"
    return 1
  fi
  FF_AUTOSTASH_SHA="$sha"
}

# Resolve the current stash@{N} reflog reference pointing at commit sha, or
# fail if none does (e.g. a human already popped or dropped it by hand).
# `git stash pop`/`drop` refuse a bare commit sha ("is not a stash
# reference") and require this exact ref form; `apply`/`show`/`cat-file`
# accept the bare sha directly, which is why only pop/drop need this lookup.
ff_stash_ref_for_sha() {
  local dir=$1 sha=$2 count i ref cur
  count=$(git -C "$dir" stash list 2>/dev/null | wc -l | tr -d '[:space:]')
  i=0
  while [ "$i" -lt "${count:-0}" ]; do
    ref="stash@{$i}"
    cur=$(git -C "$dir" rev-parse --quiet --verify "$ref" 2>/dev/null) || true
    if [ "$cur" = "$sha" ]; then
      printf '%s\n' "$ref"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# Restore a stash created by ff_autostash_create, by its exact recorded sha
# (never by stash@{N} index alone, so an unrelated stash a human made is
# never touched by mistake - the ref lookup above only ever resolves an index
# that currently points at THIS sha). On a clean restore, clears the record
# and returns 0. `git stash apply` never drops the stash on conflict, so a
# conflict here leaves both the stash and the working tree's conflict markers
# for a human, with the exact remediation command reported. Applied via
# `apply` + a resolved-ref `drop` rather than `pop`, because `pop` does not
# accept a bare commit sha. Sets FF_AUTOSTASH_ERROR on failure.
ff_autostash_restore() {
  local dir=$1 record=$2 sha=$3 out ref
  FF_AUTOSTASH_ERROR=""
  if ! git -C "$dir" cat-file -e "$sha" 2>/dev/null; then
    FF_AUTOSTASH_ERROR="recorded stash $sha no longer exists in $dir - resolve by hand, then remove $record"
    return 1
  fi
  if out=$(git -C "$dir" stash apply --quiet "$sha" 2>&1); then
    if ref=$(ff_stash_ref_for_sha "$dir" "$sha"); then
      git -C "$dir" stash drop --quiet "$ref" 2>/dev/null || true
    fi
    rm -f "$record"
    return 0
  fi
  if ref=$(ff_stash_ref_for_sha "$dir" "$sha"); then
    FF_AUTOSTASH_ERROR="restore conflict: $(first_line "$out"); the stash is preserved at $sha - resolve the conflict in $dir, run: git -C $dir stash drop $ref, then remove $record"
  else
    FF_AUTOSTASH_ERROR="restore conflict: $(first_line "$out"); the stash content is preserved at commit $sha (inspect with: git -C $dir show $sha) - resolve the conflict in $dir, then remove $record once recovered"
  fi
  return 1
}

# Advance dir from HEAD to base: an ff-only merge when diverged=no, or
# (diverged=yes) a `git rebase base` replay - never --force, never drops a
# commit, never rewrites anything already on base. Requires a clean tree.
# Never prints; sets FF_ADVANCE_* globals for the caller to report. Returns 0
# on success, 1 on failure (message in FF_ADVANCE_ERROR); a rebase conflict is
# already aborted (git rebase --abort) before returning, so HEAD is back at
# FF_ADVANCE_BEFORE either way a failure happens.
FF_ADVANCE_KIND=""
FF_ADVANCE_INSTR=""
FF_ADVANCE_BEFORE=""
FF_ADVANCE_AFTER=""
FF_ADVANCE_ERROR=""
ff_target_advance() {
  local dir=$1 base=$2 diverged=$3 out
  FF_ADVANCE_INSTR=$(changed_instr "$dir" "$base")
  FF_ADVANCE_BEFORE=$(git -C "$dir" rev-parse --short HEAD)
  FF_ADVANCE_ERROR=""
  if [ "$diverged" = yes ]; then
    FF_ADVANCE_KIND="rebased"
    if ! out=$(git -C "$dir" rebase "$base" 2>&1); then
      git -C "$dir" rebase --abort >/dev/null 2>&1 || true
      FF_ADVANCE_ERROR="rebase conflict against $base, aborted (local commits unchanged): $(conflict_or_first_line "$out")"
      return 1
    fi
  else
    FF_ADVANCE_KIND="updated"
    if ! out=$(git -C "$dir" merge --ff-only "$base" 2>&1); then
      FF_ADVANCE_ERROR="fast-forward failed: $(first_line "$out")"
      return 1
    fi
  fi
  FF_ADVANCE_AFTER=$(git -C "$dir" rev-parse --short HEAD)
  return 0
}

# Handles a dirty target for ff_target when autostash=yes. dirty is the full
# (possibly multi-line) dirty_status listing already computed by the caller.
# Untracked files are never stashed: if any are present, the target is always
# left non-clean by them (dirty_status's own definition of clean includes
# untracked files, and a tracked-only stash cannot change that), so this
# skips immediately, naming the untracked paths, without ever stashing -
# never partially, never as a wasted stash/restore round trip. A target that
# is also diverged needs rebase=yes too, checked BEFORE ever stashing, for
# the same reason: autostash alone cannot fix a divergence.
ff_target_autostash() {
  local dir=$1 label=$2 base=$3 rebase=$4 ignore_seed_marker=$5 dirty=$6 \
    untracked record as_local_rev as_base_rev as_diverged msg
  untracked=$(printf '%s\n' "$dirty" | awk '/^\?\?/ { sub(/^\?\? /, ""); print }')
  if [ -n "$untracked" ]; then
    echo "$label: skipped: untracked files block autostash: $(printf '%s' "$untracked" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    return 0
  fi

  record=$(ff_autostash_record_path "$dir")
  if [ -f "$record" ]; then
    echo "$label: skipped: outstanding autostash record at $record - restore it before autostash runs again"
    return 0
  fi

  as_local_rev=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || {
    echo "$label: skipped: cannot read HEAD"
    return 0
  }
  as_base_rev=$(git -C "$dir" rev-parse "$base" 2>/dev/null) || {
    echo "$label: skipped: cannot read $base"
    return 0
  }
  if [ "$as_local_rev" = "$as_base_rev" ]; then
    echo "$label: skipped: dirty working tree (already current otherwise)"
    return 0
  fi
  as_diverged=no
  if ! git -C "$dir" merge-base --is-ancestor "$as_local_rev" "$as_base_rev" 2>/dev/null; then
    as_diverged=yes
  fi
  if [ "$as_diverged" = yes ] && [ "$rebase" != yes ]; then
    echo "$label: skipped: diverged from $base"
    return 0
  fi

  if ! ff_autostash_create "$dir" "$record" "fm-autostash: $label" "$ignore_seed_marker"; then
    echo "$label: skipped: $FF_AUTOSTASH_ERROR"
    return 0
  fi

  if ff_target_advance "$dir" "$base" "$as_diverged"; then
    FF_STATUS="updated"
    FF_INSTR="$FF_ADVANCE_INSTR"
    msg="$label: $FF_ADVANCE_KIND $FF_ADVANCE_BEFORE..$FF_ADVANCE_AFTER"
    [ "$FF_ADVANCE_KIND" != rebased ] || msg="$msg onto $base"
    [ -z "$FF_ADVANCE_INSTR" ] || msg="$msg (instructions changed: $FF_ADVANCE_INSTR)"
    if ff_autostash_restore "$dir" "$record" "$FF_AUTOSTASH_SHA"; then
      echo "$msg (autostash restored)"
    else
      echo "$msg, but restore needs attention: $FF_AUTOSTASH_ERROR"
    fi
    return 0
  fi

  # Advance failed - HEAD is back at as_local_rev either way (ff-only never
  # moves on failure; a rebase conflict was already aborted), so the stash
  # restores onto exactly the tree it was taken from.
  if ff_autostash_restore "$dir" "$record" "$FF_AUTOSTASH_SHA"; then
    echo "$label: skipped: $FF_ADVANCE_ERROR (local changes restored)"
  else
    echo "$label: skipped: $FF_ADVANCE_ERROR; additionally, restore needs attention: $FF_AUTOSTASH_ERROR"
  fi
  return 0
}

# Fast-forward one target to a base. Prints its status line. Sets globals for the
# caller:
#   FF_STATUS = updated|current|skipped
#   FF_INSTR  = comma list of changed instruction paths (only when updated)
#
# base_mode selects where the fast-forward base comes from:
#   origin       - fetch origin and advance to origin/<default> (the /updatefirstmate
#                  path); requires an origin remote and network reachability.
#   <commit-ish> - advance to that LOCAL commit with NO fetch and no origin
#                  dependency (the local-HEAD secondmate sync). The commit must
#                  already exist in the target's object store, which it always does
#                  for a worktree of this same repo; a standalone clone that lacks
#                  it is skipped rather than fetched.
# Guards are ff-only in both modes by default: never force or merge; skip a
# dirty, diverged, or wrong-branch target and leave its work untouched. The
# trailing autostash/rebase arguments (both default "no") are the ONLY way
# to relax that, always opt-in per call - see the file header. Neither flag
# implies the other: a target that is both dirty and diverged needs both to
# advance; with only one, it is still skipped exactly as it always has been.
FF_STATUS=""
FF_INSTR=""
ff_target() {
  local dir=$1 label=$2 base_mode=$3 allow_detached=${4:-no} ignore_seed_marker=${5:-no} autostash=${6:-no} rebase=${7:-no}
  FF_STATUS="skipped"
  FF_INSTR=""

  if [ ! -d "$dir" ]; then
    echo "$label: skipped: not a directory"
    return 0
  fi
  if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "$label: skipped: not a git repo"
    return 0
  fi

  local default base cur instr local_rev base_rev before after out dirty
  default=$(default_branch "$dir") || {
    echo "$label: skipped: cannot determine default branch"
    return 0
  }

  # Resolve the fast-forward base from base_mode (see header).
  if [ "$base_mode" = origin ]; then
    if ! git -C "$dir" remote get-url origin >/dev/null 2>&1; then
      echo "$label: skipped: no origin remote"
      return 0
    fi
    if ! fetch_once "$dir"; then
      echo "$label: skipped: fetch failed"
      return 0
    fi
    base="origin/$default"
  else
    base="$base_mode"
  fi

  if ! git -C "$dir" rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
    echo "$label: skipped: $base does not exist"
    return 0
  fi

  cur=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || echo "")
  if [ -z "$cur" ] && [ "$allow_detached" != yes ]; then
    echo "$label: skipped: detached HEAD, expected $default"
    return 0
  fi
  if [ -n "$cur" ] && [ "$cur" != "$default" ]; then
    echo "$label: skipped: on $cur, expected $default"
    return 0
  fi

  dirty=$(dirty_status "$dir" "$ignore_seed_marker")
  if [ -n "$dirty" ]; then
    if [ "$autostash" != yes ]; then
      echo "$label: skipped: dirty working tree"
      return 0
    fi
    ff_target_autostash "$dir" "$label" "$base" "$rebase" "$ignore_seed_marker" "$dirty"
    return 0
  fi

  local_rev=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || {
    echo "$label: skipped: cannot read HEAD"
    return 0
  }
  base_rev=$(git -C "$dir" rev-parse "$base" 2>/dev/null) || {
    echo "$label: skipped: cannot read $base"
    return 0
  }
  if [ "$local_rev" = "$base_rev" ]; then
    FF_STATUS="current"
    echo "$label: already current"
    return 0
  fi
  if ! git -C "$dir" merge-base --is-ancestor HEAD "$base" 2>/dev/null; then
    if [ "$rebase" = yes ]; then
      if ff_target_advance "$dir" "$base" yes; then
        FF_STATUS="updated"
        FF_INSTR="$FF_ADVANCE_INSTR"
        if [ -n "$FF_INSTR" ]; then
          echo "$label: rebased $FF_ADVANCE_BEFORE..$FF_ADVANCE_AFTER onto $base (instructions changed: $FF_INSTR)"
        else
          echo "$label: rebased $FF_ADVANCE_BEFORE..$FF_ADVANCE_AFTER onto $base"
        fi
      else
        echo "$label: skipped: $FF_ADVANCE_ERROR"
      fi
      return 0
    fi
    echo "$label: skipped: diverged from $base"
    return 0
  fi

  instr=$(changed_instr "$dir" "$base")
  before=$(git -C "$dir" rev-parse --short HEAD)
  if ! out=$(git -C "$dir" merge --ff-only "$base" 2>&1); then
    echo "$label: skipped: fast-forward failed: $(first_line "$out")"
    return 0
  fi
  after=$(git -C "$dir" rev-parse --short HEAD)
  FF_STATUS="updated"
  FF_INSTR="$instr"
  if [ -n "$instr" ]; then
    echo "$label: updated $before..$after (instructions changed: $instr)"
  else
    echo "$label: updated $before..$after"
  fi
  return 0
}

# Sweep accumulators. The caller resets both before a sweep and reads
# FF_NUDGE_WINDOWS after.
FF_NUDGE_WINDOWS=""
FF_SEEN_HOMES=""

# Validate and fast-forward one secondmate home, accumulating its stable
# fm-<id> task selector into FF_NUDGE_WINDOWS when it should be live-converged.
# Args:
#   id home window base_mode nudge_requires_instr autostash rebase
# autostash/rebase default "no" and only ever carry "yes" when the caller is
# bin/fm-update.sh's own explicit CLI flags - see the file header. A home is
# nudged only when it ACTUALLY advanced (FF_STATUS=updated) and has a live
# window. With nudge_requires_instr=yes the advance must also have changed
# the instruction surface (FF_INSTR non-empty): an already-current home, or one
# whose only change was non-instruction tracked files, is left undisturbed. The
# firstmate repo itself (FM_ROOT) is never processed as its own secondmate, and
# each resolved home is processed at most once.
process_secondmate() {
  local id=$1 home=$2 window=${3:-} base_mode=$4 nudge_requires_instr=${5:-no} \
    autostash=${6:-no} rebase=${7:-no} home_real fm_root_real
  [ -n "$id" ] || return 0
  [ -n "$home" ] || return 0
  fm_root_real=$(resolve_path "$FM_ROOT")
  home_real=$(resolve_path "$home")
  [ "$home_real" != "$fm_root_real" ] || return 0
  if ! validate_secondmate_home "$id" "$home"; then
    echo "secondmate $id: skipped: unsafe home: $VALIDATION_ERROR"
    return 0
  fi
  home_real="$VALIDATED_HOME"
  case " $FF_SEEN_HOMES " in
    *" $home_real "*) return 0 ;;
  esac
  FF_SEEN_HOMES="$FF_SEEN_HOMES $home_real"

  ff_target "$home_real" "secondmate $id" "$base_mode" yes yes "$autostash" "$rebase"
  if [ "$FF_STATUS" = "updated" ] && [ -n "$window" ]; then
    if [ "$nudge_requires_instr" = yes ] && [ -z "$FF_INSTR" ]; then
      return 0
    fi
    FF_NUDGE_WINDOWS="$FF_NUDGE_WINDOWS fm-$id"
    if [ "$nudge_requires_instr" = yes ] && [ -n "$FF_INSTR" ] \
      && type fm_ff_after_instruction_update >/dev/null 2>&1; then
      fm_ff_after_instruction_update "$id" "$home_real" "$window" "$FF_INSTR"
    fi
  fi
}

# Sweep this home's LIVE secondmate direct reports - state/<id>.meta files with
# kind=secondmate - fast-forwarding each to base_mode. Passes base_mode,
# nudge_requires_instr, autostash, and rebase through to process_secondmate
# (autostash/rebase default "no" - see process_secondmate). Accumulates into
# FF_NUDGE_WINDOWS / FF_SEEN_HOMES, which the caller resets before and reads after.
# The registry argument is only for home= fallback on older or incomplete meta records.
sweep_live_secondmate_metas() {
  local state=$1 base_mode=$2 nudge_requires_instr=${3:-no} registry=${4:-$FM_HOME/data/secondmates.md} \
    autostash=${5:-no} rebase=${6:-no} id home window meta
  [ -d "$state" ] || return 0
  while IFS='|' read -r id home window meta; do
    if grep -q '^remote_host=.' "$meta" 2>/dev/null; then continue; fi
    process_secondmate "$id" "$home" "$window" "$base_mode" "$nudge_requires_instr" "$autostash" "$rebase"
  done < <(live_secondmate_meta_records "$state" "$registry")
}
