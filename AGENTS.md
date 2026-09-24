# AGENTS.md — agent-org contributor / agent guide

## Build & lint
# Byte-compile (zero warnings required):
emacs -Q --batch \
  --eval "(add-to-list 'load-path \"/home/khalid/.emacs.d/elpa/acp-20260914.1318\")" \
  --eval "(add-to-list 'load-path \".\")" \
  --eval "(setq byte-compile-error-on-warn t)" \
  --eval "(batch-byte-compile)" agent-org.el agent-org-buffer.el agent-org-loader.el agent-org-providers.el

# Single-file compile:
emacs -Q --batch --eval "(add-to-list 'load-path \"/home/khalid/.emacs.d/elpa/acp-20260914.1318\")" \
  --eval "(add-to-list 'load-path \".\")" --eval "(byte-compile-file \"agent-org.el\")"

## Test
# Offline ERT suite (uses the mock acp in tests/, never the real package):
emacs -Q --batch \
  --eval "(add-to-list 'load-path \"/home/khalid/agent-org\")" \
  --eval "(load \"tests/test-agent-org.el\")" \
  --eval "(ert-run-tests-batch-and-exit)"

# Run a single test by name:
emacs -Q --batch \
  --eval "(add-to-list 'load-path \"/home/khalid/agent-org\")" \
  --eval "(load \"tests/test-agent-org.el\")" \
  --eval "(ert-run-tests-batch-and-exit 'test-agent-org-header-status-not-duplicated)"

# Live smoke test (needs the real acp package and a working `goose acp` binary):
./run-loader-test.sh          # or: emacs -Q --batch -l loader-live-test.el

# IMPORTANT: tests/acp-mock.el provides `acp' for headless runs.  Keep it in
# tests/ — if it ever sits in the package root it shadows the real acp and
# live sessions silently do nothing.

## Code style
# - Alists everywhere; use `map-elt` / `map-nested-elt` (from `map.el`) to read them.
# - Prefer `seq.el` for list operations; prefer `map.el` for alist access.
# - Use `cl-defun` with `&key` for functions with multiple optional args.
# - Prefix all symbols: `agent-org-` (public), `agent-org--` (private), `agent-org-buffer-` / `agent-org-providers-` etc.
# - Errors: signal with `user-error` for user-facing, `error` for programmer bugs.
# - Always set `lexical-binding: t` in file headers.
# - ACP objects are alists parsed via `json-parse-string :object-type 'alist`.
# - No `plists` for wire data; use `plists` only for internal config (provider specs).
# - Flatten `if`/`when`/`unless` bodies — avoid extra nesting.
# - Suppress writes with `inhibit-read-only` only inside `with-current-buffer`; always restore read-only after.
# - ALL status / progress / error feedback goes to the chat buffer's header
#   line (top bar) via `agent-org-buffer-set-status'.  NEVER write system
#   messages, comment blocks, or bullet lines into the Org body.  The body
#   holds User/Agent conversation content plus ONE auto-managed block at
#   the very top: `#+TITLE:` + `#+PROPERTY:` lines and folded COMMANDS/
#   MODES/CONFIG drawers — no heading (headings belong to the
#   conversation).  Rewritten by `agent-org-buffer-refresh-metadata';
#   never edit it by hand.
