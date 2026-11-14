#!/usr/bin/env bash
# commit_msg_guard.sh — enforce the commit-message SUBSTANCE law
# (taught by the agent-team prompt templates + the turn-step brief —
# Owner 2026-10-27 #hq: "This rule doesn't belong to AGENTS.md, but your
# AGENT-TEAM prompt templates"; this guard is enforcement, not the source):
# subjects must describe what changed; mechanical turn metadata is banned.
#
# Owner order 2026-10-27 (#hq): commit messages are written by agents
# about what changed in the code — never "ci turn", "stall", etc.
# Owner order 2026-10-29 (#hq): changes made by agents on CI MUST be
# committed by that agent's author, not the model that ran CI — a
# `turn(<seat>):` commit authored by the CI bot identity is a violation.
#
# Usage: commit_msg_guard.sh <git-range>
#   e.g. commit_msg_guard.sh origin/ai/main..HEAD
#
# Exit 0 = every commit in the range passes.
# Exit 1 = violations printed (sha + subject + reason).
# Exit 2 = the range itself could not be read (never pass silently).
#
# Rules:
#   1. Subject carries >= 3 words.
#   2. Subject does not START with turn-metadata labels:
#      ci-turn / ci-chain / ci turn / ci chain / wip / progress /
#      misc / various / done / temp / tmp / changes / commit / stall=N.
#      (`turn(<seat>):` is the harness's RESERVED host-commit prefix —
#      governed by rule 3, not banned outright.)
#   3. A `turn(<seat>):` subject (host-committed agent work) must carry
#      the AGENT as git author in the AGENTS.md model format
#      MODEL <MODEL@PROVIDER> — never agent-team-ci@users.noreply,
#      never a raw lane string ("model@provider") as the NAME,
#      never "unknown" (Owner correction 2026-10-30 #hq).
set -u

RANGE="${1:?usage: commit_msg_guard.sh <git-range>}"

BANNED_RE='^(ci[-_ ]?(turn|chain)|wip\b|progress\b|misc\b|various\b|done\b|temp\b|tmp\b|changes\b|commit\b|stall=[0-9])'
CI_MACHINE_RE='agent-team-ci@users\.noreply\.github\.com'

fail=0
count=0
# An unresolvable range must FAIL LOUDLY, never pass silently: a gate
# that cannot read the history must not wave it through.
LOG=$(git log --format='%h%x09%an <%ae>%x09%s' "$RANGE" 2>/tmp/cmg-err.txt)
if [ $? -ne 0 ]; then
  echo "commit-msg guard: BAD RANGE '${RANGE}' — $(head -1 /tmp/cmg-err.txt)"
  rm -f /tmp/cmg-err.txt
  exit 2
fi
rm -f /tmp/cmg-err.txt
while IFS= read -r line; do
  [ -n "$line" ] || continue
  IFS=$'\t' read -r sha author subj <<< "$line"
  count=$((count + 1))
  reasons=""
  words=$(printf '%s' "$subj" | wc -w)
  if [ "$words" -lt 3 ]; then
    reasons="${reasons}subject has <3 words; "
  fi
  if printf '%s' "$subj" | grep -qiE "$BANNED_RE"; then
    reasons="${reasons}mechanical/turn-metadata subject; "
  fi
  # Owner law 2026-10-29: agent work carries the agent's author.
  # Owner correction 2026-10-30: that author is a MODEL identity in the
  # AGENTS.md format MODEL <MODEL@PROVIDER> (e.g.
  # "Qwen3.8-Flash <qwen3.8-flash@qoder.com>") — never the CI machine,
  # never a raw lane string as the name, never "unknown".
  case "$subj" in
    turn\(*)
      if printf '%s' "$author" | grep -qE "$CI_MACHINE_RE"; then
        reasons="${reasons}agent work authored by the CI machine (law: turn work carries the agent's author); "
      fi
      if printf '%s' "$author" | grep -qE '^[^<]*@[^<]*<'; then
        reasons="${reasons}author name is a lane string, not a model name (law: MODEL <MODEL@PROVIDER>); "
      fi
      if printf '%s' "$author" | grep -qiE '^[^<]*unknown[^<]*<'; then
        reasons="${reasons}author name is unknown (law: author is a model identity MODEL <MODEL@PROVIDER>); "
      fi
      if ! printf '%s' "$author" | grep -qE '<[^@]+@[^>]+>$'; then
        reasons="${reasons}author email malformed (law: MODEL <MODEL@PROVIDER>); "
      fi
      ;;
  esac
  # Owner order 2026-10-31 #hq: control subjects describe their change in
  # plain words — "unknown" means the writer did not know what ran, which
  # is exactly the spam the Owner rejected.
  case "$subj" in
    control:*|ci-turn:*|ci-chain:*)
      if printf '%s' "$subj" | grep -qiE '(^|[ :])unknown([ ,.;!]|$)'; then
        reasons="${reasons}control subject says 'unknown' (law: name the lane/seat); "
      fi
      ;;
  esac
  if [ -n "$reasons" ]; then
    echo "VIOLATION ${sha}: ${subj}"
    echo "  -> author: ${author}"
    echo "  -> ${reasons}"
    echo "     law: subjects name WHAT changed (file/feature/behavior + effect); turn work carries the agent's model author (MODEL <MODEL@PROVIDER>)"
    fail=1
  fi
done <<< "$LOG"

if [ "$fail" = 0 ]; then
  echo "commit-msg guard: ${count} commit(s) in ${RANGE} all describe their changes"
else
  echo "commit-msg guard: FAIL — ${RANGE} carries violations (see above)"
fi
exit $fail
