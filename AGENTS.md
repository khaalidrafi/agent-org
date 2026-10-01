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
#   the very top: the PROPERTIES drawer first, then `#+TITLE:', then
#   COMMANDS/MODES/CONFIG drawers — all folded by default, no heading
#   (headings belong to the conversation).  Rewritten by
#   `agent-org-buffer-refresh-metadata'; never edit it by hand.
# - Per-turn tool calls render as `** KEYWORD title [id]` subheadings under
#   the current `* Agent` heading, one heading per toolCallId, KEYWORD from
#   the per-file `#+TODO: TODO DOING | DONE CANCELLED` set (pending→TODO,
#   in_progress→DOING, completed→DONE, failed→CANCELLED); updates rewrite the
#   heading line in place via its marker, never duplicating it.  Tool calls
#   are HEADLINES, not a drawer: the Org drawer spec (info "(org) Drawers")
#   forbids headlines inside drawers, so a :tool: drawer could never hold
#   them anyway.  Extended thinking stays in ONE folded `:thinking:` drawer
#   under the same heading.  Fold state is driven directly with
#   `org-fold-region', NOT `org-fold-hide-drawer-toggle', whose org-element
#   cache is stale while a turn streams with font-lock off ("Not at a
#   drawer").
# - A tool heading is inserted at the `:thinking:` marker's
#   `match-beginning`, never at the position `re-search-forward' RETURNS
#   (the match's end = the drawer body's first line).  A headline placed
#   there is *inside* the drawer, and `agent-org-buffer--redraw-drawer'
#   rewrites the whole body on the next thought chunk — so every tool
#   call except the turn's last one silently vanished.  Beware the same
#   trap in general: `line-beginning-position' returns a position, it
#   does not move point.
# - Text the agent supplies (tool-call `title', session `title') goes
#   through `agent-org-buffer--label' before it lands on a one-line
#   context (heading line, completion candidate).  Live qoder titles tool
#   calls with the whole shell command — hundreds of characters across
#   many lines — and verbatim that breaks the heading.  Never trust a
#   harness-provided label to be short or single-line.
# - Resume replay: updates in `agent-org--replay-kinds' arriving while a
#   session is `:loading' are BUFFERED, never painted one chunk at a time;
#   the `session/load' response is NOT the flush point (qoder answers first
#   and streams history after it — flushing there silently dropped every
#   agent turn).  `agent-org--arm-replay-render' re-arms a quiet-period
#   timer per late update and `agent-org--finish-replay' paints the whole
#   history once, with `buffer-undo-list t'.  Past
#   `agent-org-replay-settle-cap' the pending render is left to fire.
#   Tests drive this synchronously: `ao--capture-wire' captures
#   `run-at-time'/'cancel-timer', so `ao--settle' is how a test says "the
#   agent went quiet".
# - Restored turns use the SAME rendering primitives as typed ones; never
#   add a second renderer for replay, or the two will drift.

