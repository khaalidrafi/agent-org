#!/usr/bin/env bash
# E2E for agent-org-batch.el — one batch send against tests/fake-acp-agent.py.
# No model, no API key, no network beyond the pinned acp fetch (no-dup
# law: acp.el is fetched at a PINNED TAG, never vendored into this repo).
#
# Owner order 2026-10-26 #hq (R-2-77 endgame): CI sends go THROUGH
# agent-org so the send fires the same prompt-send hook interactive
# Emacs fires.  This script proves the whole path on every landing:
# spawn -> initialize -> session/new -> send -> raw response file +
# the send-moment clock command actually ran.
#
# Exit 0 = PASS.  Any failure prints E2E FAIL and exits 1.
set -u
cd "$(dirname "$0")/.."
REPO="$PWD"
ACP_TAG="v0.14.3"          # the version agent-org's Package-Requires pins
ACP_DIR="${TMPDIR:-/tmp}/acp-el-$ACP_TAG"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "E2E FAIL: $1"; exit 1; }

command -v "${EMACS:-emacs}" >/dev/null 2>&1 || fail "emacs not found"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"

# --- the pinned acp fetch (shared law with the byte-compile gate) --------
if [ ! -f "$ACP_DIR/acp.el" ]; then
  mkdir -p "$ACP_DIR"
  for f in acp.el acp-traffic.el; do
    curl -fsSL "https://raw.githubusercontent.com/xenodium/acp.el/$ACP_TAG/$f" \
      -o "$ACP_DIR/$f" || fail "cannot fetch $f at $ACP_TAG"
  done
fi

# --- one fake send --------------------------------------------------------
printf 'hello fake agent, reply with the token\n' > "$TMP/prompt.txt"
: > "$TMP/clock.stamp"
AGENT_ORG_PROVIDER=fake \
AGENT_ORG_PROVIDER_COMMAND="python3 $REPO/tests/fake-acp-agent.py" \
AGENT_ORG_PROMPT="$TMP/prompt.txt" \
AGENT_ORG_OUT="$TMP/response.txt" \
AGENT_ORG_TIMEOUT=60 \
AGENT_ORG_CLOCK_CMD="date +%s%N > $TMP/clock.stamp" \
AGENT_ORG_LOAD_PATH="$ACP_DIR:$REPO" \
"${EMACS:-emacs}" --batch -l "$REPO/agent-org-batch.el" \
  --eval '(agent-org-batch-send)' > "$TMP/log.txt" 2>&1
RC=$?

grep -E "agent-org-batch" "$TMP/log.txt" | tail -2 >&2
[ "$RC" = "0" ] || fail "batch send exited $RC (see $TMP/log.txt)"
grep -q "BATCH-E2E-OK" "$TMP/response.txt" \
  || fail "response file lacks the fake agent's token"
[ -s "$TMP/clock.stamp" ] || fail "send-moment clock command never ran"
echo "E2E PASS: batch send ok (response + send-moment clock)"

# --- resume happy path (Owner order 2026-10-27 #hq: reuse the same
#     agent-org session per member): pinned id in, same id out ----------
printf 'resume check\n' > "$TMP/prompt-resume.txt"
AGENT_ORG_PROVIDER=fake \
AGENT_ORG_PROVIDER_COMMAND="python3 $REPO/tests/fake-acp-agent.py --load" \
AGENT_ORG_PROMPT="$TMP/prompt-resume.txt" \
AGENT_ORG_OUT="$TMP/response-resume.txt" \
AGENT_ORG_SESSION_ID="sid-resume-me" \
AGENT_ORG_SESSION_OUT="$TMP/session-out.txt" \
AGENT_ORG_TIMEOUT=60 \
AGENT_ORG_LOAD_PATH="$ACP_DIR:$REPO" \
"${EMACS:-emacs}" --batch -l "$REPO/agent-org-batch.el" \
  --eval '(agent-org-batch-send)' > "$TMP/log-resume.txt" 2>&1
RC=$?
grep -E "agent-org-batch" "$TMP/log-resume.txt" | tail -2 >&2
[ "$RC" = "0" ] || fail "resume send exited $RC (see $TMP/log-resume.txt)"
grep -q "BATCH-E2E-OK" "$TMP/response-resume.txt" \
  || fail "resume send lacks the fake agent's token"
grep -q "sid-resume-me" "$TMP/session-out.txt" \
  || fail "session-out lacks the resumed session id"
echo "E2E PASS: resume ok (pinned session loaded, id persisted)"

# --- stale resume DEGRADES to a fresh session (context loss never
#     fails the turn) -----------------------------------------------------
AGENT_ORG_PROVIDER=fake \
AGENT_ORG_PROVIDER_COMMAND="python3 $REPO/tests/fake-acp-agent.py --load-fail" \
AGENT_ORG_PROMPT="$TMP/prompt-resume.txt" \
AGENT_ORG_OUT="$TMP/response-degrade.txt" \
AGENT_ORG_SESSION_ID="sid-stale" \
AGENT_ORG_SESSION_OUT="$TMP/session-out-degrade.txt" \
AGENT_ORG_TIMEOUT=60 \
AGENT_ORG_LOAD_PATH="$ACP_DIR:$REPO" \
"${EMACS:-emacs}" --batch -l "$REPO/agent-org-batch.el" \
  --eval '(agent-org-batch-send)' > "$TMP/log-degrade.txt" 2>&1
RC=$?
grep -E "agent-org-batch" "$TMP/log-degrade.txt" | tail -2 >&2
[ "$RC" = "0" ] || fail "degrade send exited $RC (see $TMP/log-degrade.txt)"
grep -q "BATCH-E2E-OK" "$TMP/response-degrade.txt" \
  || fail "degrade send lacks the fake agent's token"
grep -q "sid-fake-e2e" "$TMP/session-out-degrade.txt" \
  || fail "degrade did not fall through to a fresh session id"
echo "E2E PASS: stale resume degraded to a fresh session (turn survived)"

# --- transcripts preserved (AGENT_ORG_TRANSCRIPT_DIR) --------------------
printf 'transcript check\n' > "$TMP/prompt-tx.txt"
mkdir -p "$TMP/tx"
AGENT_ORG_PROVIDER=fake \
AGENT_ORG_PROVIDER_COMMAND="python3 $REPO/tests/fake-acp-agent.py" \
AGENT_ORG_PROMPT="$TMP/prompt-tx.txt" \
AGENT_ORG_OUT="$TMP/response-tx.txt" \
AGENT_ORG_TRANSCRIPT_DIR="$TMP/tx" \
AGENT_ORG_TIMEOUT=60 \
AGENT_ORG_LOAD_PATH="$ACP_DIR:$REPO" \
"${EMACS:-emacs}" --batch -l "$REPO/agent-org-batch.el" \
  --eval '(agent-org-batch-send)' > "$TMP/log-tx.txt" 2>&1
RC=$?
grep -E "agent-org-batch" "$TMP/log-tx.txt" | tail -2 >&2
[ "$RC" = "0" ] || fail "transcript send exited $RC (see $TMP/log-tx.txt)"
ls "$TMP/tx"/sid-*.org >/dev/null 2>&1 \
  || fail "no sid-*.org transcript in AGENT_ORG_TRANSCRIPT_DIR"
echo "E2E PASS: transcript mirror ok (.agent-org layout preserved)"

echo "E2E ALL GREEN: send + clock, resume + persist, degrade, transcripts"
