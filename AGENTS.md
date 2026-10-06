# AGENTS.md — agent-org contributor / agent guide

CONVENTIONS.md is the reference that holds every rendering rule WITH the measurements
that justify it — cited below as §N.  TODOs.org holds the per-feature narrative.
This file is only what an agent must not get wrong.

## Build & lint

# Byte-compile, zero warnings required.  DEPENDENCY FIRST: compiling agent-org.el
# loads agent-org-buffer from its .elc, so a freshly added function there reads as
# "not defined" until the buffer file has been recompiled.  `rm -f *.elc' when in
# doubt — a stale .elc also shadows the sources in the test suite and the live session.
emacs -Q --batch \
  --eval "(add-to-list 'load-path \"/home/khalid/.emacs.d/elpa/acp-20260914.1318\")" \
  --eval "(add-to-list 'load-path \".\")" \
  --eval "(setq byte-compile-error-on-warn t)" \
  --eval "(batch-byte-compile)" agent-org-buffer.el agent-org.el agent-org-loader.el agent-org-providers.el

## Test

# Offline ERT suite (mock acp in tests/, never the real package):
emacs -Q --batch \
  --eval "(add-to-list 'load-path \"/home/khalid/agent-org\")" \
  --eval "(load \"tests/test-agent-org.el\")" \
  --eval "(ert-run-tests-batch-and-exit)"
# One test: add 'test-name as an argument to ert-run-tests-batch-and-exit.
# Live smoke test (real acp + a working `goose acp`): ./run-loader-test.sh
# tests/acp-mock.el MUST stay in tests/: in the package root it shadows the real
# acp and live sessions silently do nothing.
# The suite binds `load-prefer-newer' (the stale-.elc trap) and
# `agent-org-transcribe' nil (else it litters sid-*.org into the tree).

## Code style

- Alists everywhere; read with `map-elt' / `map-nested-elt' (`map.el'); `seq.el'
  for lists; `cl-defun' with `&key' for many-arg functions.
- Prefix every symbol: `agent-org-', `agent-org-buffer-', `agent-org-providers-'.
  `user-error' for user-facing, `error' for programmer bugs.  `lexical-binding: t'
  in every header.  Flatten `if`/`when`/`unless` bodies — no extra nesting.
- Wire data is alists (`json-parse-string :object-type 'alist'); plists ONLY for
  internal config (provider specs).
- `inhibit-read-only' only inside `with-current-buffer'; restore read-only after.
- Command names follow agent-shell (`~/agent-shell`): session verbs name their
  object; every provider id in `agent-org-providers' gets an explicit
  `agent-org-<id>-start-agent' there (autoload scraping misses macro-generated
  commands; a drift test pins the two lists).  One action, one name in M-x —
  never keep an alias of a renamed command.

## The buffer

- ALL status/progress/error feedback goes to the header line via
  `agent-org-buffer-set-status', NEVER the body or mode line.  The body holds
  exchanges plus one auto-managed metadata block at the top (PROPERTIES drawer,
  `#+TITLE:', `#+TODO:', COMMANDS/MODES/CONFIG drawers) rewritten by
  `agent-org-buffer-refresh-metadata' — never hand-edited.  §1, §2, §6.
- The header shows ONE status string, and for starting/ready it is the state
  LABEL, so a bare `:message' is invisible then: a real failure sets
  `:state 'error', a non-failure note goes to the echo area, and a Ready
  qualifier goes through `agent-org--note-new-session' (sets `:note').  §6.
- ONE HEADING PER EXCHANGE: the prompt IS the heading
  (`agent-org-buffer-begin-exchange', continuation lines indented one space);
  the answer sits under it in a `#+begin_quote' block preceded by
  `#+ATTR_TEXINFO: :author <model>'.  A turn with no answer text gets NO quote
  furniture.  §1, §8.
- EACH EXCHANGE IS CLOCKED: `--close-response-clock' writes a `:PROPERTIES:'
  drawer (`:RESPONSE:' = exact whole seconds) plus a `:LOGBOOK:' with a COMPLETED
  `CLOCK:' line directly under the heading.  It MUST never block the user's own
  Org clock, so: never call `org-clock-in'/`-load' or set `org-clock-*'; only
  ever a closed range (an OPEN `CLOCK:' is the one form `org-clock-load' mistakes
  for a running clock); timing is the buffer-local `--turn-start', spent at the
  boundary so a second close files no second clock.  Replay binds
  `--record-clock-p' nil — restored exchanges carry NO clock, never a fabricated
  one.  GOTCHA: `org-time-stamp-formats'' CAR is date-ONLY and neither half has
  brackets; build the line from the CDR wrapped in `[...]', and compute the `=>'
  duration from those truncated stamps (not `seconds') so it stays internally
  consistent for Org's parsers.  §22.
- NEVER place a headline of any level, or any column-0 line, inside the quote or
  a drawer body: a headline ENDS a quote block and a `:END:' closes a drawer
  (both measured with `org-element-parse-buffer' — the structure silently
  vanishes).  Every agent-supplied line passes `--block-safe-lines' /
  `--drawer-safe-lines': one space of indent, `:END:' doubled, bare
  `#+end_quote' wrapped as `=#+end_quote='.  §3.2, §3.3.
- Tool calls: ONE `:tool:' drawer per turn, one item per toolCallId
  (`  - KEYWORD title' at two columns; pending→TODO, in_progress→ONGOING,
  completed→COMPLETE, failed→FAILED from the per-file `#+TODO:' line).  A call's
  output is the SAME item's body at four columns.  Every update repaints the
  whole drawer from `agent-org-buffer--tools' (the turn-local record, reset per
  turn) — never append per update, which is how replayed calls used to vanish.
  A keyword on a drawer line is TEXT: a call's state is read, not cycled.  §3.
- FOLD is a drawer's DEFAULT, not a creation instruction: `:tool:' OPEN (every
  paint re-opens it — Org re-hides drawers on paths no variable guards, e.g. a
  subtree move), `:thinking:' FOLDED (keeps a fold the user made).
  `agent-org-mode' sets `org-hide-drawer-startup' nil BUFFER-LOCALLY (it is an
  alias and `setq-local' follows aliases, so one line covers both spellings).
  Drive folds with `org-fold-region' directly, NOT
  `org-fold-hide-drawer-toggle' (whose org-element cache is stale mid-stream →
  "Not at a drawer"); guard the repaint's un-hide with `invisible-p' (an
  unconditional one walked the region and doubled per-paint cost).  §5.
- Turn placement is MARKERS, never heading text: `--turn-anchor',
  `--render-end', and the rear-advancing `--quote-end' keep the block shut at
  every instant — every chunk and repaint inserts ABOVE `#+end_quote'.  A
  drawer search starts BELOW the quote's closer: an agent quoting a transcript
  can write `:thinking:' into its own answer, and a search from the heading
  would redraw the reply instead of the drawer.  The fact of whose turn it is
  lives with the BUFFER: `start-agent-turn' ignores its session argument so two
  callers that start a turn without one get the same heading.
- Queued prompts: ONE surface — a region of `* NEXT'/`* WAIT' headings between
  the last exchange and the live `* User' box (`--render-end' answers with
  `--queue-start', so a mid-queue turn lands above it).  NEXT/WAIT are per-file
  keywords derived from POSITION on every render, never read back; an entry's
  continuation lines carry one space (a `*' at column 0 would split the
  prompt); the preamble comments sit ABOVE the first entry (a note after the
  last would be parsed INTO it and sent).  `agent-org--queue-refresh' mirrors
  `:pending-prompts' into region, `:QUEUE:' drawer and transcript (no line cap,
  arrives open); the drawer regenerates from the SESSION, never from the
  region.  Reconciliation on apply is BY TEXT — dropping by position resends an
  answered prompt and loses an edited one.  §17, §20.
- The `* User' box is always last, always typeable; programmatic text carries
  `read-only' properties, and those must never reach the mode line:
  `which-function' copies heading text WITH properties and doom-modeline's ONE
  `format-mode-line' lets the `text-read-only' error eat the whole bar.  So
  `agent-org-mode' sets a buffer-local `add-log-current-defun-function' =
  `agent-org-buffer--which-function' (property-free `org-get-heading' at a
  heading, nil elsewhere — which also suppresses which-func's imenu fallback).
  §7.
- The transcript is a MIRROR of the buffer (point-min to `--render-end'),
  written ONLY at turn boundaries by `agent-org-buffer-transcribe' — never from
  a render site (90–170 ms per turn vs two 3–15 ms writes).  Per-project
  `.agent-org/sid-<id>.org' with the wire id sanitized to `[A-Za-z0-9._-]';
  a `file-error' is a `message', never a broken turn; `write-region' VISIT
  stays nil or `C-x s' would save a draft into the transcript.  §14.
- Markdown → Org on the way in (`agent-org-convert-markdown', default t; nil is
  the verbatim hatch): `# Title' is an Org COMMENT and `* item' a level-1
  HEADLINE, so structure shifts — headings one level down, star bullets to
  dashes, emphasis rewritten in a SINGLE left-to-right pass (two passes would
  italicise the bold just made).  A code fence is a STATE threaded line by
  line; every close path shuts an open block (an unclosed `#+begin_src'
  swallows the buffer — token-capped agents send them).  Streaming rewrites
  only the provisional last line (`--md-tail` to `--render-end`), and EVERY
  boundary (`append-thought', `insert-tool', `end-agent-turn') flushes and
  FORGETS it — a stale marker puts the next chunk's `delete-region' through
  the drawer.  Wire bytes never change: rendering, not translation.  §15.

## Sessions and the wire

- A chat buffer is named `<agent>:<project> [sid]` — never the session TITLE
  (arrives late, renames itself, is agent free text).  One label builder
  (`agent-org-buffer--chat-label`) for the buffer name AND the switcher; the
  rename happens only on an update carrying `:session-id' and only when the
  string differs — `generate-new-buffer-name' counts this very buffer, so
  per-update renames accumulate `<2><3><4>'.  §13.
- Every prompt carries a SECOND text block, `<agent-org-context>' (agent name,
  model name AND id, session id), built per turn and added at the ONE send
  site so a drained queue prompt gets the same facts.  The user's block stays
  FIRST and VERBATIM; a fact the client does not know is ABSENT, never nil;
  every value one-line-flattened (collapse WITHOUT truncation).
  `agent-org-send-session-context' nil is the hatch.  §18.
- An acp client is an ALIST of dotted keyword pairs (acp.el:90, mutated with
  `map-put!'): read `:process' with `map-elt' — `plist-get' walks it as a flat
  plist, matches nothing and answers NIL on a live session.  GENERALISE: a stub
  must mirror the dependency's DATA SHAPE, or the suite tests the stub (this
  bit twice: acp client, permission dialog).
- Resume replay: updates of `agent-org--replay-kinds' arriving while
  `:loading' are BUFFERED; the `session/load' response is NOT the flush point
  (qoder answers first and streams history after).  A quiet-period timer
  re-arms per late update; `agent-org--finish-replay' paints the whole history
  ONCE with `buffer-undo-list t'.  Restored turns use the SAME rendering
  primitives — never add a second replay renderer.  The queue drawer is read
  BEFORE rendering and applied AFTER `--session-ready' (the ready write mirrors
  the buffer over the transcript, and a replayed buffer carries no queue).
  §9.
- NO render path may switch `font-lock-mode' OFF: in a buffer no window shows,
  `(font-lock-mode 1)' silently FAILS to stick — an OFF is restorable, an ON is
  not.  A chat gets its colors at DISPLAY time instead
  (`agent-org-buffer--ensure-font-lock' on the buffer-local
  `window-configuration-change-hook', an `unless' not a toggle — a repeat
  rebuilds jit-lock over a whole transcript).  Batch Emacs cannot enable
  font-lock, so tests stub it and pin the CALL SEQUENCE.  §16.
- Killing a chat MUST release the agent (`acp-shutdown' in
  `agent-org--forget-session' — measured: 16 stray `qoder --acp' children,
  ~100 MB each) and ASKS first while the process is alive (`agent-org--kill-query'
  on `kill-buffer-query-functions': acp starts agents `:noquery' with no
  buffer, so Emacs never asks by itself).  Every kill the package performs on
  its own goes through `agent-org--kill-buffer-silently' (a prompt raised
  inside an acp callback is a trap).  A timer is insurance, never the
  guarantee: re-check `buffer-live-p'.  §12.
- ESC at a start/resume prompt is a `quit' INSIDE an acp response callback and
  acp swallows it: both prompt sites go through `agent-org--quit-cancels',
  which kills the buffer (the kill-hook shuts the agent) and sends NEITHER
  `session/new' NOR `session/load'.  A cancelled prompt yields nil — both
  readers complete with REQUIRE-MATCH, so nil is never a real answer.  §11.
- Starting is a strategy: `agent-org-session-strategy' (new/latest/prompt)
  read ONLY by `agent-org--begin-start'; a prefix arg forces `new' and MUST be
  captured synchronously in the command (handshake callbacks run after the
  command loop drops `current-prefix-arg').  Listing: ONE pager
  (`agent-org--list-sessions') follows nextCursor — a cursor the agent REPEATS
  is a failure, not another request — and one owner `:list-state'
  (pending→settled) guards it; failure, timeout and empty all degrade to
  `session/new' plus an echo-area note.  A session a live buffer already holds
  is SHOWN, never loaded twice.  §10.
- Aligned completion lists: pad by DISPLAY columns (`string-width', not
  `string-pad' — a CJK title shifts everything); hand `completing-read' the
  FUNCTION `agent-org--completion-collection' (display-sort-function only
  rides a metadata action); resolve choices with `agent-org--selection-value'
  (property-free `equal', NEVER `assoc').  Never locate an aligned column by
  the whitespace in front of it — measure the first `shadow'-faced char.  §13.
- Loading is reported by an event-driven progress reporter — NO timer (ten
  wakeups a second displays at most five and costs a slow machine a
  decoration): start/step/stop wrap list-paging and the replay, each PHASE owns
  its report end-to-end, starting REPLACES, closing is `(message nil)' before
  any echo note (not `progress-reporter-done').  Only the paint pass gets a
  percentage; never step with a computed count on a per-chunk path.
- Permission dialog: ACP options are keyed `optionId'/`name'/`kind' (a reader
  asking for `label'/`id' offered the user `nil' as an answer).  A nameless
  option shows its id; the prompter returns the chosen optionId or NIL for
  declined; the handler sends `:option-id' XOR `:cancelled' (upstream
  acp.el:797 errors on both and on neither).  Tests stub `completing-read'
  with the real `{optionId,name,kind}' object, NEVER the prompter itself.
- Models: one ACP server can front many (opencode serves MiniMax).  A provider
  plist may pin `:model'; `agent-org--apply-pinned-model' sends
  `session/set_config_option' ONCE per session (clears `:want-model' first —
  ready re-enters per mid-turn update) and only for an advertised id (a stale
  pin is reported, never sent).  C-c C-m is the interactive path; the option
  id is "model", except goose ("provider").  Bars show the option's `name',
  never the id; both stored, every writer through `agent-org--ingest-config'.
  MiniMax CODE (own server, pins nothing) and MiniMax-MODELS-via-opencode are
  different things: never let a provider borrow someone else's server.
- Agent-supplied text (tool titles, session titles, config-option names)
  ALWAYS goes through `agent-org-buffer--label' before a one-line context: live
  qoder titles a tool call with a whole multi-hundred-character shell command.
- Never place a headline at the position `re-search-forward' RETURNS — that is
  the match's END, inside the body a repaint is about to rewrite.
  (`line-beginning-position' returns a position too; it does not move point.)
  A detached marker still answers `markerp' while `marker-position' is nil;
  a helper calling `string-match' clobbers the global match data a scan is
  built on.

## Performance

- Target machine: 4 GB Celeron.  Per-chunk paths are O(one line): the markdown
  rewrite touches only the provisional tail, drawer repaints guard the un-hide,
  the redraw cost of a 20-call board is a measured test.
- Lite mode is a SCOPE: global default `agent-org-lite-mode', per-session
  `agent-org-buffer--lite' (inherit/on/off — the three states are what make
  "follow the global" reachable again after an override), cycled by C-c C-l
  (C-u for the global), read ONLY through `agent-org-lite-p'.  Three gates: no
  transcript write (EXCEPT while `:queued' is non-nil — a queued prompt exists
  in no replay and no agent memory), no undo records
  (`agent-org-buffer--record-undo-p' is the one gate), no whole-buffer reparse
  per metadata rebuild.  It must NOT touch font-lock, drawers or conversion —
  those are the conversation.  §19.
- The resource monitor is a BUFFER of Org tables (`agent-org-resource-monitor'),
  never a header segment; its one repeating timer is armed by display across
  ALL frames (`agent-org--resource-displayed-p' — `get-buffer-window' answers
  for one frame, so a background frame would read as hidden).  /proc parsing
  lives in PURE functions (`--status-kb', `--stat-cpu-ticks', `--parse-load')
  so formats are test-pinned on any machine; CPU is a RATE from two samples;
  `--stat-cpu-ticks' counts from AFTER the `comm' field (`(Web Content)' is a
  real process name and a naive split reads wrong numbers silently).  Tests
  show/hide a real window — batch Emacs HAS frames (measured).  §21.
- `byte-compile-error-on-warn' forbids `setq' over a `defvar-local' owned by
  another file: write through `make-local-variable' (what
  `agent-org--queue-note' does — a plain push onto `(symbol-value ...)' reads
  the global nil, conses onto it and throws the result away silently).

## Verifying and shipping a change

1. Clean rebuild (`rm -f *.elc' + compile command above) and full suite.
2. HOT-LOAD into the running Emacs — buffer file FIRST:
   `emacsclient -e "(load \"/home/khalid/agent-org/agent-org-buffer.el\" nil t)"`
   then the same for agent-org.el.  A live session left holding a half-reloaded
   mix raises void-function from its timers minutes later (this is exactly how
   Opencode's uncommitted, un-reloaded lite-mode work broke a running chat).
3. Docs: CONVENTIONS.md §s for rules, TODOs.org for the story, README.org for
   the user-facing shape (run the org-syntax check on any .org edited).
