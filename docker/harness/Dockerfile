# agent-org team harness — THIN extension of the canonical CI kit image
# (khaalidrafi/agent-team-ci, ci/docker/harness/Dockerfile).
# INTEGRATION.md section 2: project harnesses EXTEND the canonical image —
# `FROM <base>` + only the layers this repo uniquely needs; a local fork
# without an upstream port is a compliance violation.
#
# Build (from the repo root — the base needs the repo context for the
# ci/AGENTS.md law bake):
#   docker buildx build -f ci/docker/harness/Dockerfile -t agent-org-base:local .
#   docker buildx build -f docker/harness/Dockerfile  -t agent-org-harness:local .
#
# Adds exactly what agent-org's chain needs and the canonical image lacks:
#   - emacs-nox: the repo IS Emacs Lisp (byte-compile + ERT landing gate)
#     and the agent-org batch lane is an `emacs --batch' send (Owner
#     R-2-77: CI sends go THROUGH agent-org; Owner 2026-10-27: the SAME
#     agent-org session is reused per member, transcripts preserved).
#   - the acp package at the PINNED tag agent-org's Package-Requires
#     pins (no-dup law: fetched, never vendored into this repo). The
#     batch lane gets it via AGENT_ORG_LOAD_PATH=/opt/acp-site:/workspace
#     (the workspace itself supplies the agent-org*.el sources).
FROM agent-org-base:local

RUN apt-get update \
 && apt-get install -y --no-install-recommends emacs-nox \
 && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/acp-site \
 && curl -fsSL "https://raw.githubusercontent.com/xenodium/acp.el/v0.14.3/acp.el" \
      -o /opt/acp-site/acp.el \
 && test -s /opt/acp-site/acp.el \
 && grep -q "acp" /opt/acp-site/acp.el
