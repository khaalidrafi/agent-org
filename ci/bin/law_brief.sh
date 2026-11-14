#!/usr/bin/env bash
# law_brief.sh — compose the DUAL-LAW brief for a CI agent run.
#
# Owner order 2026-10-27 (#hq): ALL agents running in Docker read BOTH
# laws — the GLOBAL law (AGENTS.md shipped in this agent-team-ci submodule,
# mounted at $WS/ci/AGENTS.md) and the LOCAL law (the repo's own root
# AGENTS.md). Every CI lane in every team repo MUST compose its prompt
# through this script so no agent ever runs lawless.
#
# Usage: law_brief.sh <segment-brief-file> [workspace-dir]
#   <segment-brief-file>  file holding the raw per-segment brief
#   [workspace-dir]       repo checkout root (default: $PWD)
#
# Environment:
#   CI_LAW_DIGEST  optional path to the repo's OWN condensed local-law
#                  digest. Budget-limited lanes (small context windows)
#                  may set this; the digest must be a committed,
#                  reviewed artifact in the repo — never invented on the
#                  fly. When set, the LOCAL LAW section carries the
#                  digest and says so.
#
# Output: the combined brief on stdout, ready to hand to any agent body
# (opencode / goose / qoder / codebuddy / raw-curl) as its prompt.
# Missing files degrade gracefully with a loud MISSING marker — never a
# silent lawless run.
set -u

SEG_FILE="${1:?usage: law_brief.sh <segment-brief-file> [workspace-dir]}"
WS="${2:-$PWD}"
GLOBAL="$WS/ci/AGENTS.md"
LOCAL="$WS/AGENTS.md"

emit() { printf '%s\n' "$1"; }

emit "================ GLOBAL LAW (ci/AGENTS.md — binds EVERY agent in EVERY repo) ================"
if [ -f "$GLOBAL" ]; then
  cat "$GLOBAL"
else
  emit "!!! GLOBAL LAW FILE MISSING at $GLOBAL — report BLOCKED, do not improvise law !!!"
fi

emit ""
emit "================ LOCAL LAW (this repo's own rules) ================"
if [ -n "${CI_LAW_DIGEST:-}" ] && [ -f "$CI_LAW_DIGEST" ]; then
  emit "(condensed digest of AGENTS.md — budget lane; full law at $LOCAL)"
  cat "$CI_LAW_DIGEST"
elif [ -f "$LOCAL" ]; then
  cat "$LOCAL"
else
  emit "(no root AGENTS.md in this repo — global law above is the only law; report the gap to the Lead)"
fi

emit ""
emit "================ SEGMENT BRIEF ================"
if [ -f "$SEG_FILE" ]; then
  cat "$SEG_FILE"
else
  emit "!!! SEGMENT BRIEF FILE MISSING at $SEG_FILE — report BLOCKED !!!"
fi
