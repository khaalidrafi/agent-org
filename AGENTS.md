# AGENTS.md — agent-org contributor / agent guide

## Build & lint
# Byte-compile (zero warnings required):
emacs -Q --batch \
  --eval "(add-to-list 'load-path \"/path/to/acp\")" \
  --eval "(add-to-list 'load-path \".\")" \
  --eval "(batch-byte-compile)" *.el

# Single-file compile:
emacs -Q --batch --eval "(add-to-list 'load-path \"/path/to/acp\")" \
  --eval "(add-to-list 'load-path \".\")" --eval "(byte-compile-file \"agent-org.el\")"

## Test
# No tests yet — add to tests/ using `ert-deftest`.
# Run a single test: emacs -Q --batch --eval "(require 'ert)" --eval "(ert-run-tests-batch-and-exit '(tag :name \"test-name\"))"

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
