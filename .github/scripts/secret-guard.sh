#!/usr/bin/env bash
# SECRET GUARD — Owner order 2026-10-21 18:27Z #hq ("Audit the whole repo
# for leaked secrets ... Members should use ENV var to send the PAT to each
# other ... What if they expose the secret in their chat?").
#
# Answers the Owner's question IN the pipeline: if any agent exposes a
# secret in the chat/org/commit, this guard redacts it BEFORE the push —
# the value never reaches git history. It never fails the run (a redacted
# message still lands; the value does not), it logs loudly.
#
# Usage:
#   secret-guard.sh staged        scan files staged for commit (diff --cached)
#   secret-guard.sh branch <base> scan branch diff vs <base>, amend HEAD
#   secret-guard.sh file <path>   scrub one file in place (session scrubber)
set -u

MODE="${1:-staged}"
# Generic credential shapes (Qoder PAT, Telegram bot token, GitHub PATs,
# OpenAI-style keys, bearer tokens). Exact values are matched separately.
GENERIC='pt-[A-Za-z0-9]{8,}|[0-9]{8,10}:[A-Za-z0-9_-]{30,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{16,}|x-access-token:[^@[:space:]]{8,}'

redact_file() {  # $1 = file -> prints "redacted:<what>" or nothing
  local f="$1" what=""
  [ -f "$f" ] && [ -s "$f" ] || return 0
  # exact env values of every secret-shaped var on this runner
  if [ -n "${SECRET_GUARD_VALUES:-}" ]; then
    while IFS= read -r v; do
      [ "${#v}" -ge 12 ] || continue
      if grep -qF -- "$v" "$f" 2>/dev/null; then
        local esc
        esc=$(printf '%s' "$v" | sed 's/[^[:alnum:]]/\\&/g')
        sed -i "s|${esc}|[REDACTED:env-value]|g" "$f"
        what="${what} env-value(len=${#v})"
      fi
    done <<< "$SECRET_GUARD_VALUES"
  fi
  if grep -qE "$GENERIC" "$f" 2>/dev/null; then
    sed -i -E "s/${GENERIC}/[REDACTED:pattern]/g" "$f"
    what="${what} generic-pattern"
  fi
  [ -n "$what" ] && { echo "redacted:${what}"; return 0; }
  return 1
}

collect_values() {  # exact values of secret-shaped env vars -> SECRET_GUARD_VALUES
  SECRET_GUARD_VALUES="$(env | grep -E '^(GROQ|OPENROUTER|ZAI|ZHIPU|QODER|TELEGRAM|LARK|CODEBUDDY|OPENAI|ANTHROPIC)[A-Z_]*(API_KEY|TOKEN|PAT|WEBHOOK[A-Z_]*)=' | cut -d= -f2- | grep -v '^$' || true)"
  SECRET_GUARD_VALUES="$(printf '%s' "$SECRET_GUARD_VALUES" | awk 'length($0)>=12' || true)"
}
collect_values

HITS=0
case "$MODE" in
  file)
    if out=$(redact_file "$2"); then
      echo "::warning::SECRET GUARD redacted secret(s) in $2 (${out#redacted:}) — value never stored"
      HITS=$((HITS+1))
    fi
    ;;
  staged)
    for f in $(git diff --cached --name-only); do
      if out=$(redact_file "$f"); then
        git add "$f"
        echo "::warning::SECRET GUARD redacted secret(s) in $f (${out#redacted:}) — value never committed"
        HITS=$((HITS+1))
      fi
    done
    ;;
  branch)
    BASE="${2:-origin/ai/main}"
    for f in $(git diff --name-only "$BASE"..HEAD 2>/dev/null); do
      if out=$(redact_file "$f"); then
        git add "$f"
        CHANGED=yes
        echo "::warning::SECRET GUARD redacted secret(s) in $f (${out#redacted:}) — amended before push"
        HITS=$((HITS+1))
      fi
    done
    [ -n "${CHANGED:-}" ] && git commit --amend --no-edit >/dev/null 2>&1 || true
    ;;
esac
echo "secret-guard: mode=${MODE} redactions=${HITS}"
exit 0
