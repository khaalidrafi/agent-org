#!/usr/bin/env bash
# agent-org landing gate: byte-compile clean + offline ERT suite green.
# Mirrors the laws in AGENTS.md ("Build & lint" + "Test") — dependency
# order respected: loader/buffer before the rest; stale .elc removed.
set -euo pipefail
cd "$(dirname "$0")/../.."

export EMACS="${EMACS:-emacs}"

# 1) byte-compile, zero warnings (dependency order matters:
#    agent-org-buffer.elc must exist before agent-org.el compiles).
#    tests/acp-mock.el is LOADED FIRST: it (provide 'acp)s, so
#    agent-org.el's `(require 'acp)` resolves without the real acp
#    package (an install-time concern, not a gate concern; load-path
#    name lookup can never find "acp" in "acp-mock.el").
rm -f *.elc tests/*.elc
$EMACS -Q --batch -l tests/acp-mock.el \
  --eval "(add-to-list 'load-path \".\")" \
  --eval "(setq byte-compile-error-on-warn t)" \
  --eval "(batch-byte-compile)" \
  agent-org-autoloads.el agent-org-buffer.el agent-org-loader.el \
  agent-org-providers.el agent-org-review-teach.el agent-org.el \
  agent-org-batch.el

# 2) offline ERT suite (mock ACP in tests/, never a real package).
$EMACS -Q --batch \
  --eval "(add-to-list 'load-path \".\")" \
  --eval "(add-to-list 'load-path \"tests\")" \
  -l tests/acp-mock.el \
  --eval "(load \"tests/test-agent-org.el\")" \
  --eval "(ert-run-tests-batch-and-exit)"

$EMACS -Q --batch \
  --eval "(add-to-list 'load-path \".\")" \
  --eval "(add-to-list 'load-path \"tests\")" \
  -l tests/acp-mock.el \
  --eval "(load \"tests/test-agent-org-batch.el\")" \
  --eval "(ert-run-tests-batch-and-exit)"

$EMACS -Q --batch \
  --eval "(add-to-list 'load-path \".\")" \
  --eval "(add-to-list 'load-path \"tests\")" \
  -l tests/acp-mock.el \
  --eval "(load \"tests/test-agent-org-review-teach.el\")" \
  --eval "(ert-run-tests-batch-and-exit)"

# 3) headless send E2E (the REAL landing proof for the send path:
#    batch send over the pinned acp package against tests/fake-acp-agent.py
#    — no model, no API key, no goose binary; the goose-dependent
#    loader-test.el is a LIVE smoke, it never ran on a CI runner and
#    kept this gate red for four days).
bash tests/e2e-agent-org-batch.sh

echo "GATE GREEN: byte-compile clean, ERT suite green, send E2E green"
