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
# - The header line shows exactly ONE status string, and for `starting'/
#   `ready' it is the STATE LABEL, not `:message'
#   (`agent-org-buffer--status-segment').  So a bare `:message' is invisible
#   while Ready.  A real request failure must set `:state 'error' (which
#   does render its message); a non-failure note that must not steal the
#   Ready segment goes to the echo area with `message'.  Never the body.
# - Two different things named MiniMax: MiniMax CODE (`mcode', its own ACP
#   server via `mcode acp', provider id `minimax', pins nothing — its default
#   model is MiniMax already) and MiniMax MODELS served by another agent
#   (opencode fronts them, so `:model' is what makes that mean MiniMax).
#   Never let a provider entry borrow someone else's server.
# - One ACP server can front many models (opencode serves MiniMax this way).
#   A provider plist may pin `:model'; `agent-org--apply-pinned-model' sends
#   `session/set_config_option' once per session (it clears `:want-model'
#   first, because ready re-enters on every mid-turn update) and only for an
#   id the agent actually advertised — a stale pin is reported, never sent.
#   `agent-org-set-session-model' (C-c C-m) is the interactive path over the same
#   advertised list; the model option's id is "model", except goose calls it
#   "provider".
# - User-facing command names follow the agent-shell package (`~/agent-shell`,
#   same author, same ACP ground): session-level verbs name their object
#   (`agent-org-resume-session', `agent-org-set-session-model', matching
#   `agent-shell-resume-session' / `agent-shell-set-session-model'), and every
#   provider id in `agent-org-providers' gets an
#   `agent-org-<id>-start-agent' command in agent-org-providers.el, defined
#   explicitly (autoload scraping does not see macro-generated commands) as a
#   thin `(agent-org-start '<id>)' call.  `test-agent-org-every-provider-has-a-
#   start-agent-command' fails if the two lists drift.  Never keep an alias for
#   a renamed command: one action, one name in M-x.

# - "Start" is a strategy, not a request: `agent-org-session-strategy'
#   (`new' / `latest' / `prompt', default `prompt', names borrowed from agent-shell)
#   decides what happens after `initialize', and `agent-org--begin-start' is the
#   only reader of it.  A prefix argument forces `new' for one call and MUST be
#   captured synchronously in the command: the handshake callback runs after the
#   command loop has dropped `current-prefix-arg'.  An agent that cannot `list'
#   or cannot `load' never pays for the request.
# - One pager for both entry points: `agent-org--list-sessions' follows the
#   agent's `nextCursor' (page limit nil = every page; a cursor the agent
#   repeats is a FAILURE, not another request) and synthesizes
#   `((sessions . VECTOR))', so `agent-org--session-candidates' cannot tell one
#   page from ten.  `agent-org-start' and `agent-org--resume-locate' both call
#   it — never hand-send a second `session/list'.
# - A listing has exactly ONE owner: `:list-state' (`pending' then `settled')
#   guarded by `agent-org--settle-listing', so a `session/list' that answers
#   after `agent-org-session-list-timeout' fired cannot load a second session
#   into a buffer already opening one.  Failure, timeout and an empty listing
#   all degrade to `session/new' plus an echo-area note: starting a chat must
#   never be blocked by the feature that shows you the older ones.  Candidates
#   are `TITLE  DATE  [id]' (`agent-org--session-display' +
#   `agent-org--format-session-date'), sorted by `agent-org--session-stamp'
#   (`updatedAt' else `createdAt' — live goose omits `updatedAt'), newest first,
#   with `New session' always first in the list.
# - Killing the chat buffer MUST release the agent: `acp' owns the process it
#   spawned, so dropping the registry entry leaves an `qoder --acp' child running
#   (~100 MB each — measured live: 1 session registered, 16 stray acp processes).
#   `agent-org--forget-session' therefore calls `acp-shutdown' and unarms both
#   timers, and `agent-org--list-timeout' re-checks `buffer-live-p' as the second
#   lock (a timer is best-effort insurance, never the guarantee).  Assert the
#   BEHAVIOUR in tests, not the `cancel-timer' call: `ao--capture-wire' stubs
#   `cancel-timer', so firing the stored timer is how a test says "the deadline
#   arrived".
# - ESC at a session prompt is a `quit' that lands INSIDE an acp response
#   callback, and acp swallows it (`condition-case-unless-debug'): unguarded, the
#   chat buffer sat on "Starting"/"Restoring" holding a live agent process.  So
#   both prompt sites go through `agent-org--quit-cancels', which releases the
#   session by killing its buffer (the kill-hook path above is what shuts the
#   agent down) and notes it in the echo area.  A cancelled prompt yields NIL —
#   both readers complete with REQUIRE-MATCH, so nil is never a real answer, and
#   the caller must then send neither `session/new' nor `session/load'.
