#!/usr/bin/env bash
# Tests for bin/fm-update.sh: fast-forward-only self-update of a running
# firstmate repo and every registered secondmate home.
#
# The guarantees under test mirror fm-fleet-sync.sh and prime directive #3:
#   - The running firstmate repo (on its default branch) fast-forwards from
#     origin; a leased secondmate home (detached HEAD on the default branch)
#     fast-forwards the same way.
#   - FAST-FORWARD ONLY: a dirty, diverged, offline, or wrong-branch target is
#     skipped and reported, never forced or stashed, so unlanded work survives.
#   - The update is a single-parent fast-forward (never a merge commit) and a
#     fast-forward of one worktree never disturbs another worktree's checkout
#     or the shared default branch.
#   - The caller-action summary is correct: reread-firstmate flips to yes only
#     when the instruction surface (AGENTS.md / bin / .agents/skills) changed, and
#     nudge-secondmates lists exactly the live secondmates that advanced.
#   - Secondmate homes resolve from both state/<id>.meta and the
#     data/secondmates.md registry, deduped, and the firstmate repo is never
#     re-processed as one of its own secondmates.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPDATE="$ROOT/bin/fm-update.sh"

# Deterministic, isolated git identity for fixture commits.
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-update-tests)

# Build a fresh world: a bare origin seeded with one commit, a firstmate repo
# clone checked out on main, and a home dir with state/ and data/. Echoes the
# world dir. Files seeded: AGENTS.md, README.md, bin/tool.sh, and an internal skill note.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data"
  # Fresh watcher beacon keeps fm-guard quiet.
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null

  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  printf 's1\n' > "$w/seed/.agents/skills/note.md"
  # Matches the real firstmate repo's .gitignore: data/, state/, config/, and
  # projects/ are private per-home directories, never tracked. Autostash
  # writes its record under data/, so a fixture without this would make
  # mkdir -p data/ show up as untracked and falsely look "still dirty".
  printf 'data/\nstate/\nconfig/\nprojects/\n' > "$w/seed/.gitignore"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main

  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true

  printf '%s\n' "$w"
}

# Add a secondmate home as a DETACHED worktree of the firstmate repo (matching
# how treehouse leases a secondmate home), plus its state meta. Args: world id.
add_sm() {
  local w=$1 id=$2
  git -C "$w/main" worktree add -q --detach "$w/$id" main
  {
    printf 'window=main:fm-%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'home=%s/%s\n' "$w" "$id"
  } > "$w/home/state/$id.meta"
  printf '%s\n' "$id" > "$w/$id/.fm-secondmate-home"
}

# Advance origin by one commit. mode=instr changes the instruction surface
# (AGENTS.md, bin, .agents/skills) plus README; mode=readme changes only README.
bump_origin() {
  local w=$1 mode=$2
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'r-%s\n' "$mode" >> "$w/seed/README.md"
  if [ "$mode" = instr ]; then
    printf 'v2\n' > "$w/seed/AGENTS.md"
    printf 'echo b\n' > "$w/seed/bin/tool.sh"
    printf 's2\n' > "$w/seed/.agents/skills/note.md"
  fi
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "bump-$mode"
  git -C "$w/seed" push -q origin main
}

run_update() {
  local w=$1
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>/dev/null
}

# Like run_update but forwards extra CLI flags (--autostash / --rebase).
run_update_flags() {
  local w=$1
  shift
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" "$@" 2>/dev/null
}

# --- T1: main + secondmate behind, instruction change; FF, not a merge ------
# Combines the former T1 (fast-forward + reread + nudge signalling) and T2
# (the advance is a single-parent fast-forward, never a merge commit) into one
# world so both contracts are proven against the same update run.
test_updates_main_and_secondmate() {
  local w out
  w=$(new_world t1)
  add_sm "$w" sm1
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "secondmate fast-forwarded"
  assert_contains "$out" "reread-firstmate: yes" "instruction change triggers reread"
  assert_contains "$out" "nudge-secondmates: fm-sm1" "updated secondmate is nudged"

  # Fast-forward landed: HEAD == origin/main on both targets.
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "firstmate HEAD not at origin/main"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$(git -C "$w/sm1" rev-parse origin/main)" ] \
    || fail "secondmate HEAD not at origin/main"
  # Firstmate stays on its default branch; secondmate stays detached.
  [ "$(git -C "$w/main" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "firstmate left its default branch"
  git -C "$w/sm1" symbolic-ref -q HEAD >/dev/null \
    && fail "secondmate worktree is no longer detached"
  # A fast-forwarded tip has exactly one parent; a merge commit would have two.
  [ "$(git -C "$w/main" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "firstmate tip is not a single-parent fast-forward"
  [ "$(git -C "$w/sm1" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "secondmate tip is not a single-parent fast-forward"
  pass "T1 main + secondmate fast-forward (single-parent), reread + nudge signalled"
}

# --- T3: README-only change does not trigger a reread ----------------------
test_reread_gate_is_instruction_only() {
  local w out
  w=$(new_world t3)
  add_sm "$w" sm1
  bump_origin "$w" readme

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate still advanced"
  assert_contains "$out" "reread-firstmate: no" "non-instruction change skips reread"
  # The secondmate still advanced, so it is still nudged (update-based nudge).
  assert_contains "$out" "nudge-secondmates: fm-sm1" "advanced secondmate still nudged"
  pass "T3 reread gates on instruction surface, nudge on advancement"
}

# --- T4: dirty secondmate is skipped, its edit preserved -------------------
test_dirty_secondmate_skipped() {
  local w out
  w=$(new_world t4)
  add_sm "$w" sm1
  bump_origin "$w" instr
  printf 'uncommitted local edit\n' >> "$w/sm1/AGENTS.md"

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: dirty working tree" "dirty home skipped"
  assert_not_contains "$out" "fm-sm1" "skipped secondmate is not nudged"
  grep -q 'uncommitted local edit' "$w/sm1/AGENTS.md" \
    || fail "dirty edit was discarded"
  pass "T4 dirty secondmate skipped, local edit preserved"
}

# --- T5: diverged secondmate is skipped, its commit preserved --------------
test_diverged_secondmate_skipped() {
  local w out before
  w=$(new_world t5)
  add_sm "$w" sm1
  # Local commit on the secondmate's detached HEAD makes it diverge from origin.
  printf 'fork work\n' > "$w/sm1/AGENTS.md"
  git -C "$w/sm1" add -A
  git -C "$w/sm1" commit -qm local-work
  before=$(git -C "$w/sm1" rev-parse HEAD)
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: diverged from origin/main" "diverged home skipped"
  assert_not_contains "$out" "fm-sm1" "diverged secondmate is not nudged"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$before" ] \
    || fail "diverged secondmate HEAD moved (unlanded work at risk)"
  pass "T5 diverged secondmate skipped, local commit preserved"
}

# --- T6: idempotent; second run reports already current --------------------
test_idempotent_already_current() {
  local w out
  w=$(new_world t6)
  add_sm "$w" sm1
  bump_origin "$w" instr
  run_update "$w" >/dev/null   # first run advances both

  out=$(run_update "$w")       # second run: nothing to do

  assert_contains "$out" "firstmate: already current" "firstmate already current"
  assert_contains "$out" "secondmate sm1: already current" "secondmate already current"
  assert_contains "$out" "reread-firstmate: no" "no reread when nothing changed"
  assert_contains "$out" "nudge-secondmates: none" "no nudge when nothing advanced"
  pass "T6 idempotent: a second run is a no-op"
}

# --- T7: registry backstop + dedup + self-exclusion, one world -------------
# One world carries every secondmate-resolution edge at once:
#   reg1 - registered in secondmates.md only, NO live meta (registry backstop);
#   sm1  - present in BOTH meta and the registry (must be processed exactly once);
#   selfish - a bogus registry line pointing the firstmate repo at itself.
# Asserts: reg1 advances but is NOT nudged (no live metadata); sm1 advances,
# is processed once, and IS nudged; the firstmate repo is never re-processed.
test_registry_backstop_dedup_and_self_exclusion() {
  local w out count
  w=$(new_world t7)
  add_sm "$w" sm1
  git -C "$w/main" worktree add -q --detach "$w/reg1" main
  printf 'reg1\n' > "$w/reg1/.fm-secondmate-home"
  {
    printf -- '- reg1 - domain supervisor (home: %s/reg1; scope: things; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- sm1 - dup (home: %s/sm1; scope: x; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- selfish - self (home: %s/main; scope: x; projects: p; added 2026-06-23)\n' "$w"
  } > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate reg1: updated " "registry-only secondmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "meta+registry secondmate fast-forwarded"
  count=$(printf '%s\n' "$out" | grep -c '^secondmate sm1:' || true)
  [ "$count" -eq 1 ] || fail "secondmate sm1 processed $count times, expected 1 (dedup across meta+registry)"
  assert_not_contains "$out" "secondmate selfish" "firstmate repo re-processed as its own secondmate"
  # sm1 has live metadata, so it is nudged; reg1 has none, so it is not. Pin the
  # nudge line exactly and confirm reg1 is absent from it (not from the whole
  # output, where 'secondmate reg1: updated' legitimately appears).
  local nudge_line
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-secondmates:')
  assert_contains "$nudge_line" "fm-sm1" "live-meta secondmate is nudged"
  assert_not_contains "$nudge_line" "reg1" "registry-only secondmate without live metadata is not nudged"
  pass "T7 registry backstop resolves, dedups meta+registry, excludes the firstmate repo"
}

# --- T9: firstmate repo on a feature branch is skipped ---------------------
test_firstmate_wrong_branch_skipped() {
  local w out before
  w=$(new_world t9)
  bump_origin "$w" instr
  # Simulate firstmate mid-shipping its own change: not on the default branch.
  git -C "$w/main" checkout -q -b feature/wip
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: on feature/wip, expected main" "off-default firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "skipped firstmate HEAD moved"
  pass "T9 firstmate off its default branch is skipped, not forced"
}

test_firstmate_detached_head_skipped() {
  local w out before
  w=$(new_world t10)
  bump_origin "$w" instr
  git -C "$w/main" checkout -q --detach HEAD
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: detached HEAD, expected main" "detached firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when detached firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "detached firstmate HEAD moved"
  pass "T10 firstmate detached HEAD is skipped"
}

test_unsafe_secondmate_home_skipped_before_git_update() {
  local w out bad before
  w=$(new_world t11)
  bad="$w/home/projects/bad"
  mkdir -p "$w/home/projects"
  git clone -q "$w/origin.git" "$bad"
  printf 'bad\n' > "$bad/.fm-secondmate-home"
  before=$(git -C "$bad" rev-parse HEAD)
  printf -- '- bad - bad home (home: %s; scope: x; projects: p; added 2026-06-23)\n' \
    "$bad" > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate bad: skipped: unsafe home: secondmate home cannot be inside the active firstmate home" \
    "unsafe project-like home skipped"
  assert_contains "$out" "nudge-secondmates: none" "unsafe home is not nudged"
  [ "$(git -C "$bad" rev-parse HEAD)" = "$before" ] \
    || fail "unsafe secondmate home HEAD moved"
  pass "T11 unsafe secondmate home is not fast-forwarded"
}

# --- T12: --help mentions the opt-in flags, still exits 0 ------------------
test_help_mentions_flags() {
  local out
  out=$("$UPDATE" --help 2>&1)
  assert_contains "$out" "--autostash" "help text documents --autostash"
  assert_contains "$out" "--rebase" "help text documents --rebase"
  pass "T12 --help documents the opt-in flags"
}

# --- T13: --autostash restores a dirty secondmate's local edit -------------
test_autostash_restores_dirty_secondmate() {
  local w out
  w=$(new_world t13)
  add_sm "$w" sm1
  # readme mode leaves AGENTS.md untouched on origin, so the local edit below
  # has no overlapping region to conflict with on restore.
  bump_origin "$w" readme
  printf 'uncommitted local edit\n' >> "$w/sm1/AGENTS.md"

  out=$(run_update_flags "$w" --autostash)

  assert_contains "$out" "secondmate sm1: updated " "dirty secondmate advanced with --autostash"
  assert_contains "$out" "autostash restored" "advance line reports the restore"
  assert_contains "$out" "nudge-secondmates: fm-sm1" "advanced secondmate is still nudged"
  grep -q 'uncommitted local edit' "$w/sm1/AGENTS.md" \
    || fail "local edit was not restored after autostash"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$(git -C "$w/sm1" rev-parse origin/main)" ] \
    || fail "secondmate did not fast-forward to origin/main"
  [ -z "$(git -C "$w/sm1" stash list)" ] || fail "stash was not cleared after a clean restore"
  [ ! -e "$w/sm1/data/pending-autostash.meta" ] || fail "autostash record was not cleared after a clean restore"
  pass "T13 --autostash stashes, fast-forwards, and restores a dirty secondmate"
}

# --- T14: untracked files block autostash, named, never stashed ------------
test_autostash_skips_on_untracked_files() {
  local w out
  w=$(new_world t14)
  add_sm "$w" sm1
  bump_origin "$w" instr
  printf 'scratch\n' > "$w/sm1/SCRATCH.txt"

  out=$(run_update_flags "$w" --autostash)

  assert_contains "$out" "secondmate sm1: skipped: untracked files block autostash: SCRATCH.txt" \
    "untracked file is named and blocks autostash"
  [ -z "$(git -C "$w/sm1" stash list)" ] || fail "an untracked-only target must never be stashed"
  [ ! -e "$w/sm1/data/pending-autostash.meta" ] || fail "no record should exist when nothing was stashed"
  [ -f "$w/sm1/SCRATCH.txt" ] || fail "untracked file was disturbed"
  pass "T14 untracked files skip autostash by name, without ever stashing"
}

# --- T15: a pre-existing record blocks a new autostash run -----------------
test_autostash_blocked_by_outstanding_record() {
  local w out
  w=$(new_world t15)
  add_sm "$w" sm1
  bump_origin "$w" instr
  printf 'uncommitted local edit\n' >> "$w/sm1/AGENTS.md"
  mkdir -p "$w/sm1/data"
  {
    printf 'target=%s\n' "$w/sm1"
    printf 'stash_sha=0000000000000000000000000000000000000000\n'
    printf 'created=2020-01-01T00:00:00Z\n'
    printf 'message=fake pre-existing record\n'
  } > "$w/sm1/data/pending-autostash.meta"

  out=$(run_update_flags "$w" --autostash)

  assert_contains "$out" "secondmate sm1: skipped: outstanding autostash record at" \
    "a pre-existing record blocks a second autostash run"
  [ -z "$(git -C "$w/sm1" stash list)" ] || fail "a blocked run must never create a new stash"
  grep -q 'uncommitted local edit' "$w/sm1/AGENTS.md" \
    || fail "dirty edit was disturbed by the blocked run"
  pass "T15 an outstanding autostash record blocks a new run for that target"
}

# --- T16: a restore conflict preserves the stash and the record ------------
test_autostash_restore_conflict_preserves_stash_and_record() {
  local w out sha
  w=$(new_world t16)
  add_sm "$w" sm1
  # Force a real 3-way conflict: origin and the local edit both replace the
  # single line in AGENTS.md, so popping the stash back onto the newly
  # fast-forwarded tree collides with the incoming change.
  bump_origin "$w" instr
  printf 'v1-local\n' > "$w/sm1/AGENTS.md"

  out=$(run_update_flags "$w" --autostash)

  assert_contains "$out" "secondmate sm1: updated " "the fast-forward itself still lands"
  assert_contains "$out" "restore needs attention" "a restore conflict is reported loudly"
  assert_contains "$out" "the stash is preserved at" "the exact stash is named in the report"
  assert_contains "$out" "nudge-secondmates: fm-sm1" "the target still advanced, so it is still nudged"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$(git -C "$w/sm1" rev-parse origin/main)" ] \
    || fail "the fast-forward must still have landed despite the restore conflict"
  grep -q '<<<<<<<' "$w/sm1/AGENTS.md" || fail "conflict markers were not left for a human"
  [ -n "$(git -C "$w/sm1" stash list)" ] || fail "the stash must survive a restore conflict"
  [ -f "$w/sm1/data/pending-autostash.meta" ] || fail "the record must survive a restore conflict"
  sha=$(grep '^stash_sha=' "$w/sm1/data/pending-autostash.meta" | cut -d= -f2-)
  [ -n "$sha" ] || fail "the surviving record must still name the exact stash sha"
  git -C "$w/sm1" cat-file -e "$sha" 2>/dev/null || fail "the recorded sha must resolve to a real stash object"
  pass "T16 a restore conflict keeps both the stash and the record, and reports how to finish"
}

# --- T17: --rebase replays a diverged secondmate's local commit ------------
test_rebase_replays_diverged_secondmate() {
  local w out before
  w=$(new_world t17)
  add_sm "$w" sm1
  printf 'local content\n' > "$w/sm1/LOCALFILE.md"
  git -C "$w/sm1" add -A
  git -C "$w/sm1" commit -qm local-commit
  before=$(git -C "$w/sm1" rev-parse HEAD)
  bump_origin "$w" instr

  out=$(run_update_flags "$w" --rebase)

  assert_contains "$out" "secondmate sm1: rebased " "diverged secondmate is rebased, not skipped"
  assert_contains "$out" "nudge-secondmates: fm-sm1" "rebased secondmate is still nudged"
  [ -f "$w/sm1/LOCALFILE.md" ] || fail "local commit's content was lost during rebase"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" != "$before" ] || fail "rebase did not move HEAD"
  git -C "$w/sm1" merge-base --is-ancestor origin/main HEAD \
    || fail "rebased secondmate is not built on top of the new origin base"
  pass "T17 --rebase replays a diverged secondmate's local commit onto the new base"
}

# --- T18: --rebase alone aborts cleanly on conflict, local work intact -----
test_rebase_conflict_aborts_and_restores_original_state() {
  local w out before
  w=$(new_world t18)
  add_sm "$w" sm1
  printf 'local-conflicting-content\n' > "$w/sm1/AGENTS.md"
  git -C "$w/sm1" add -A
  git -C "$w/sm1" commit -qm local-conflicting-commit
  before=$(git -C "$w/sm1" rev-parse HEAD)
  bump_origin "$w" instr

  out=$(run_update_flags "$w" --rebase)

  assert_contains "$out" "secondmate sm1: skipped: rebase conflict against" \
    "a rebase conflict is reported, not silently forced"
  assert_contains "$out" "local commits unchanged" "the report states local commits were preserved"
  assert_not_contains "$out" "nudge-secondmates: fm-sm1" "a skipped secondmate is not nudged"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$before" ] \
    || fail "HEAD moved despite the aborted rebase"
  [ -z "$(git -C "$w/sm1" status --porcelain)" ] \
    || fail "working tree was left dirty after the aborted rebase"
  [ ! -d "$w/sm1/.git/rebase-apply" ] && [ ! -d "$w/sm1/.git/rebase-merge" ] \
    || fail "a rebase was left in progress after the abort"
  pass "T18 a rebase conflict aborts cleanly, restoring the exact original state"
}

# --- T19: dirty+diverged needs BOTH flags; either alone still skips --------
test_dirty_and_diverged_needs_both_flags() {
  local w out
  w=$(new_world t19)
  add_sm "$w" sm1
  printf 'local commit content\n' > "$w/sm1/LOCALFILE.md"
  git -C "$w/sm1" add -A
  git -C "$w/sm1" commit -qm local-commit
  # readme mode leaves AGENTS.md untouched on origin, so this dirty edit has
  # no overlapping region to conflict with when the stash is restored.
  printf 'dirty edit\n' >> "$w/sm1/AGENTS.md"
  bump_origin "$w" readme

  out=$(run_update_flags "$w" --rebase)
  assert_contains "$out" "secondmate sm1: skipped: dirty working tree" \
    "--rebase alone does not imply --autostash; a dirty target still skips on dirty"
  [ -z "$(git -C "$w/sm1" stash list)" ] || fail "--rebase alone must never stash"

  out=$(run_update_flags "$w" --autostash)
  assert_contains "$out" "secondmate sm1: skipped: diverged from origin/main" \
    "--autostash alone does not imply --rebase; a diverged target still skips on divergence"
  [ -z "$(git -C "$w/sm1" stash list)" ] || fail "--autostash alone must never stash a target it will skip as diverged"

  out=$(run_update_flags "$w" --autostash --rebase)
  assert_contains "$out" "secondmate sm1: rebased " "both flags together advance a dirty and diverged target"
  grep -q 'dirty edit' "$w/sm1/AGENTS.md" || fail "dirty edit was lost when both flags were combined"
  [ -f "$w/sm1/LOCALFILE.md" ] || fail "local commit content was lost when both flags were combined"
  pass "T19 a dirty and diverged target needs both flags; either alone still skips exactly as before"
}

# --- T20: --autostash also reaches the primary firstmate repo itself -------
test_autostash_reaches_primary_repo() {
  local w out
  w=$(new_world t20)
  # readme mode leaves AGENTS.md untouched on origin, so the local edit below
  # has no overlapping region to conflict with on restore.
  bump_origin "$w" readme
  printf 'captain local edit\n' >> "$w/main/AGENTS.md"

  out=$(run_update_flags "$w" --autostash)

  assert_contains "$out" "firstmate: updated " "the primary repo itself advances with --autostash"
  assert_contains "$out" "autostash restored" "the primary repo's local edit is reported restored"
  grep -q 'captain local edit' "$w/main/AGENTS.md" \
    || fail "the primary repo's local edit was not restored"
  [ "$(git -C "$w/main" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "the primary repo must stay on its default branch, never detached"
  [ -z "$(git -C "$w/main" stash list)" ] || fail "primary repo stash was not cleared"
  pass "T20 --autostash reaches the primary firstmate repo, not only secondmates"
}

test_updates_main_and_secondmate
test_reread_gate_is_instruction_only
test_dirty_secondmate_skipped
test_diverged_secondmate_skipped
test_idempotent_already_current
test_registry_backstop_dedup_and_self_exclusion
test_firstmate_wrong_branch_skipped
test_firstmate_detached_head_skipped
test_unsafe_secondmate_home_skipped_before_git_update
test_help_mentions_flags
test_autostash_restores_dirty_secondmate
test_autostash_skips_on_untracked_files
test_autostash_blocked_by_outstanding_record
test_autostash_restore_conflict_preserves_stash_and_record
test_rebase_replays_diverged_secondmate
test_rebase_conflict_aborts_and_restores_original_state
test_dirty_and_diverged_needs_both_flags
test_autostash_reaches_primary_repo

echo "# all fm-update tests passed"
