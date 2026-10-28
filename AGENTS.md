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
# VERSION SKEW, measured 2026-10-11: `emacs -Q --batch` runs the BUILT-IN Org
# (9.7.11 here) while the running Emacs loads ELPA `org` (9.8.10), so a rule
# pinned by a test is pinned against a different Org than the one it must
# please.  Check `(org-version)' in the live server before believing a green
# suite covers an Org interaction — and note Org 9.8 changed the property-drawer
# spelling (`RESPONSE: v', no leading colon), which 9.8 still READS in our form.
# LIVE-CACHE TRAP: in a big old chat buffer the 9.8 `org-element' cache can go
# stale — our renders edit the buffer from acp callbacks — and then
# `org-element-at-point' signals `wrong-type-argument number-or-marker-p nil',
# which makes `org-entry-get' (and so the whole clock draw) fail on EVERY
# heading.  Reproduced live, invisible in batch, and cured by
# `(org-element-cache-reset)': refresh live buffers with the draw inside a
# `condition-case' that resets once and retries, or `C-c a c' dies in a session
# that is working perfectly.

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
- STICKY PROMPT HEADING: `agent-org-sticky-heading` (on by default) adds a
  SECOND header row — the level-1 heading of the exchange under the window's top
  edge — appended BELOW the status row by `agent-org-buffer--render-header-lines`
  so the status never moves.  Emacs has no sticky-line facility, so this is a
  buffer-local `window-scroll-functions` entry writing
  `agent-org-buffer--sticky-heading`; NEVER text in the body (§14's byte mirror
  and §17's markers read bytes).  One display line, truncated to the window's
  body width with `agent-org-sticky-heading-ellipsis` (a wrapped bar would bury
  the status).  Nil while the heading itself is on the page, and level 1 only —
  a part's keyword changes every few seconds, the prompt does not.  The plain
  `^\\* ` search is sound because §3.2 indents every agent-supplied line.
  One pin per BUFFER, not per window.  §6.
- ONE HEADING PER EXCHANGE: the prompt IS the heading
  (`agent-org-buffer-begin-exchange', continuation lines indented one space);
  the answer sits under it in a `#+begin_quote' block preceded by
  `#+ATTR_TEXINFO: :author <model>'.  A turn with no answer text gets NO quote
  furniture.  §1, §8.
- EACH EXCHANGE IS CLOCKED: `agent-org-buffer-begin-exchange' files a
  `:PROPERTIES:' drawer (`:RESPONSE:' = 0 while it runs) plus a `:LOGBOOK:' with
  an OPEN `CLOCK: [start]' directly under the heading, and `--close-response-clock'
  shuts THAT line in place at the boundary (`CLOCK: [start]--[end] =>  h:mm', exact
  seconds into the property).  A heading whose open block cannot be found gets the
  whole block inserted instead — the fallback, for a hot-reloaded or older turn.
  It MUST never block the user's own Org clock, so: never call `org-clock-in'/
  `-load' or set `org-clock-*'; timing is the buffer-local `--turn-start', spent at
  the boundary so a second close files no second clock.  An OPEN line is safe and
  is NOT the shape `org-clock-load' mistakes for a running clock (measured: it
  stays inactive, `org-clock-in' elsewhere still works, `org-clock-sum' counts it
  as 0 minutes) — but every boundary must shut it, so no open line survives the
  activity.  Replay binds `--record-clock-p' nil — restored exchanges carry NO
  clock, never a fabricated one.  GOTCHA: `org-time-stamp-formats'' CAR is
  date-ONLY and neither half has
  brackets; build the line from the CDR wrapped in `[...]', and compute the `=>'
  duration from those truncated stamps (not `seconds') so it stays internally
  consistent for Org's parsers.  GOTCHA (RE-MEASURED 2026-10-14): a `CLOCK:'
  line carrying seconds in the DURATION parses to ZERO `clock' nodes, but a
  second-precise STAMP (`[HH:MM:SS]') still parses as ONE node and still sums
  (Org 9.7.11 AND 9.8.10: a 135 s range answers 2 minutes).  So the STAMPS now
  carry seconds — the transcript draws no overlay and the stamps are the only
  place the seconds can show there (user order: "Seconds no longer showing up in
  clock timestamps") — while the `=>' DURATION stays minute-granular and the
  exact whole seconds still ride in the property.  `C-c C-c' is OURS
  (`agent-org-ctrl-c-ctrl-c') because Org's own handler re-parses the stamps
  minute-granular and would delete the seconds.  §22.
- THE CLOCKED TOTALS ARE SHOWN BY OUR OWN FORK OF `org-clock-display': `C-c a c'
  (`agent-org-clock-display') toggles the buffer-local
  `agent-org-clock-display-mode', ON BY DEFAULT via
  `agent-org-clock-display-default'.  It reads `:RESPONSE:'/`:SECONDS:' because
  Org's arithmetic cannot: `org-clock-sum' returns whole MINUTES (a 45 s answer
  is `0:00' there and `0:00:45' here).  Totals are OVERLAYS carrying `display'
  (`display' REPLACES what it covers, which is the only shape that can be
  RIGHT-ALIGNED — Org's own `org-clock-put-overlay' pads the headline text to
  column 60 with `?' in `shadow' then writes ` H:MM:SS ' in `org-clock-overlay';
  we match that, and the column is measured PAST the stars so `* ' and `** '
  agree), never inserted text — the transcript mirror, the queue parse and the
  repaint
  markers all read the buffer's BYTES.  The total sums level-1 headings only, so
  a part's seconds are never billed twice.  `--draw' is silent and only
  `agent-org-clock-display' reports (§6: status rides the header line).  A
  heading's next line must show a `:PROPERTIES:'/`:LOGBOOK:' drawer before any
  subtree walk happens — that fast path is what makes a per-boundary pass
  affordable — and lite sessions skip the pass entirely (§19).
  `agent-org-clock--stamp-time' parses a stamp's seconds ITSELF, because
  `org-parse-time-string' drops them (measured: `(0 0 10 11 10 2026 ...)' for
  `10:00:12').  §22.1.
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
- Queued prompts: ONE surface — a region of entry headings between
  the last exchange and the live `* PROMPT' box (`--render-end' answers with
  `--queue-start', so a mid-queue turn lands above it).  Every entry wears the
  keyword of its POSITION (`* NEXT' first, `* WAIT' below —
  `agent-org-buffer--queue-word'), so a re-order, a kill and a drain all go
  through the renderer, which is the only thing that can keep the words true;
  an entry's continuation lines carry one space (a `*'
  at column 0 would split the prompt); the preamble comments sit ABOVE the
  first entry (a note after the last would be parsed INTO it and sent).
  THE REGION IS TYPEABLE AT EVERY POSITION INSIDE IT: `--queue-editable'
  clears the `read-only' the insert INHERITED from the frozen text above and
  un-sticks the character over the region's first byte, and `--protect'
  un-sticks wherever its END is the region's start — typing at `(cdr region)'
  itself is refused on purpose, since that byte is the box's frozen heading.
  `agent-org--queue-refresh' mirrors `:pending-prompts' into the region and
  the transcript; the transcript's block is re-rendered from the SESSION,
  never copied from the region.  Reconciliation on apply is BY TEXT —
  dropping by position resends an answered prompt and loses an edited one.
  A region the user edited is NEVER repainted, but it IS kept truthful one
  ENTRY at a time: an arrival it cannot account for (`agent-org-buffer--queue-minus'
  over `parse(region) ∪ --queue-shown') is APPENDED below the user's own text —
  refusing the repaint outright hid a queued prompt while the header counted it
  (live: 1 heading shown, `3 queued') — and an entry the session has dropped
  whose text is still exactly what we painted is REAPED
  (`agent-org-buffer--queue-reap'), because that same all-or-nothing guard froze
  the surface at the first touch and left every drained prompt sitting on the
  page as still waiting (live: `Prompt queue is not updating automatically').
  An entry the user rewrote is in neither set and stays.  A region with no
  session queue and no entry or slot on it is RETIRED (markers dropped), so a
  drained chat shows no border and three comment lines.  Reap is NOT
  `agent-org-buffer-queue-kill-entry': no kill ring, no message, no undo record.
  GOTCHA: `agent-org-buffer-queue-entry-bounds' ends at the NEXT headline or the
  REGION, never `point-max' — the entries are level-1 headings like the `* PROMPT'
  box, so the last entry's subtree runs off the page (measured: `C-c a d' there
  hit `text-read-only' in the frozen box instead of killing, and `M-DOWN' pushed
  the prompt below the box, out of the region).
  `agent-org-queue--set' is the ONLY writer of `:pending-prompts', so enqueue,
  remove, apply and the drain cannot diverge.  §17, §20.
- The `* PROMPT' box is always last and always typeable DIRECTLY under its
  heading (the freeze stops at the heading's own newline + `rear-nonsticky' —
  a second newline there is what made the user's first keystroke land two lines
  down); its heading is never a state word.  FIND THE BOX FROM
  `agent-org-buffer--prompt-box-heading' (the first heading at/after
  `--prompt-anchor'), NEVER with `org-back-to-heading' at `point-max': a draft
  is the user's text and a person types `* auth' at column 0, which IS a
  headline, so walking back from the bottom lands on his bullet and the box
  disappears (live report: `Can't use headings inside prompts').  Same reason
  `take-draft' reads from the LINE AFTER the heading instead of
  `org-end-of-meta-data' — the box owns no furniture, and a first line like
  `#+TITLE:' must not be skipped out of the prompt.  Programmatic text carries
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
- Starting is a strategy: `agent-org-session-strategy' (new/latest/prompt, DEFAULT
  `latest') read ONLY by `agent-org--begin-start'; `C-u' forces `prompt' and
  `C-u C-u' forces `new', and both MUST be captured synchronously in the command
  (handshake callbacks run after the command loop drops `current-prefix-arg').
  GOTCHA for tests and probes: in `let' the value forms run BEFORE any binding is
  established, so `(let ((agent-org-session-strategy 'prompt) (buf (agent-org-start
  'qoder)))' still starts with the GLOBAL strategy — bind it in an enclosing `let'.
  Listing: ONE pager
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
  pin is reported, never sent).  C-c a m is the interactive path; the option
  id is "model", except goose ("provider").  Bars show the option's `name',
  never the id; both stored, every writer through `agent-org--ingest-config'.
  MODES follow the same rule: `:mode' is the wire id (`yolo') and `:mode-name'
  the agent's own label ("Bypass Permissions"), rendered by
  `agent-org-buffer--mode-display'.  A `current_mode_update' carries ONLY the id,
  so the name is looked up in the status's `:modes-list' (`agent-org--session-modes')
  — one copy, the same reason as `agent-org--session-config'.  Goose's id and name
  are the same word, so only a Qoder-shaped fake catches a reader asking the
  wrong field.
  MiniMax CODE (own server, pins nothing) and MiniMax-MODELS-via-opencode are
  different things: never let a provider borrow someone else's server.
- KEYS: ONE prefix, `C-c a', which a loaded `org-mode-map' leaves free.  The
  package used to sit on `C-c C-g' (it binds NO `C-c C-<letter>' Org uses: Org
  9.7.11 claims every one of them except `C-g' and `C-h', and a chat IS an Org
  buffer -- `C-c C-c' was stealing `org-ctrl-c-ctrl-c', the only gesture Org
  offers for refreshing a clocktable or editing a block, both of which a chat
  contains), and moved to `C-c a' on 2026-10-11 because it is one keystroke
  shorter.  All fifteen verbs live in ONE sub-map there (s = send, k = cancel,
  i = interrupt-and-send, l = lite, m = model, q = queue goto, Q = restore, r =
  resume, a = add, d = delete, e = enqueue, n = prepend, x = remove, v = list, c
  = clock display) and the monitor refreshes on `C-c a g'.  COST, not controlled by the package:
  in the user's own config the GLOBAL `C-c a' is gptel's prefix (20 bindings),
  and a minor-mode map outranks the global map, so gptel is unreachable from a
  chat buffer.
  `test-agent-org-mode-map-shadows-no-org-binding' measures every binding
  against a loaded `org-mode-map' and asserts the scheme (non-guard keys
  under the one free prefix) as well as the absence of clashes -- the
  structural guards
  (`M-RET', `M-LEFT/RIGHT', `S-UP/DOWN', `C-c C-c', `C-c C-t', `C-c -') are
  ASSERTED to sit on a real Org command, because taking them over is the point.
  `C-c C-c' is a WRAP, not a steal (user order 2026-10-14): `agent-org-ctrl-c-ctrl-c'
  delegates to `org-ctrl-c-ctrl-c' everywhere EXCEPT a `CLOCK:' line, where Org's
  own handler re-parses the stamps minute-granular and would delete our seconds
  — so refreshing a clocktable and editing a block still work, and a clock keeps
  its seconds.  GOTCHA: ask
  whether the binding is a COMMAND; `lookup-key' answers with the integer 2 for
  any longer `C-c' sequence because `C-c' alone resolves to a keymap, and a
  prefix is not a stolen command.
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
  "follow the global" reachable again after an override), cycled by C-c a l
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
   Give it TIME: one of these loads measured 8–10 s on this machine, so a
   `timeout 60' around `emacsclient' looks like a self-deadlock and is not —
   the server answers instantly and the load is just slow.  Then VERIFY the
   change reached the running buffer (`key-binding` in the live chat), because
   a reload silently does not apply to KEYMAPS: `defvar' leaves an already-bound
   symbol alone, and `define-minor-mode' put the keymap OBJECT it activated on
   into `minor-mode-map-alist', so re-setting the variable gives live buffers
   the OLD keys forever.  Both maps are therefore ONE object re-FILLED in place
   at load (`--build-mode-map' / `--build-resource-monitor-map', each preceded
   by `(setcdr map nil)' — and `setcdr' RETURNS THE NEW CDR, so pass the map in
   a second expression, not as `setcdr''s value).  §7.
3. Docs: CONVENTIONS.md §s for rules, TODOs.org for the story, README.org for
   the user-facing shape (run the org-syntax check on any .org edited).

## Global agent law — DISTRIBUTED (Owner order 2026-10-21 03:53Z #hq:
## "don't forget to give global instructions' AGENTS.md to the team").
## Canonical source: khaalidrafi/agent-team.el AGENTS.md. This copy is
## verbatim where repo-agnostic; agent-team.el stays the master.

1. FORMAT LAW: every chat message (agent-team/CHAT.org) is an Org
   headline carrying FROM (`* MSG <from> -> @<to> :<kind:`), routing in
   Org tags, fields in a `:PROPERTIES:` drawer (`:FROM:`/`:TO:`/`:KIND:`/
   `:WHEN:`/`:CHANNEL:`), body indented, WHEN an Org inactive timestamp.
   Append at EOF only; never edit or delete existing entries.
2. TELEGRAM LAW: every Telegram-bound message opens with `FROM:` and
   `TO:` lines.
3. SECRET LAW: credentials NEVER travel in chat, files, commits, or
   messages — only as ENV VAR NAMES. A peer asked for a credential
   replies with the NAME + has-it/absent, and the asker reads the value
   from their OWN environment (`(getenv "NAME")`). Never echo a value.
   The SECRET GUARD (.github/scripts/secret-guard.sh) redacts leaked
   values at every commit/ingest/artifact choke point.
4. SESSION LAW: agents' CLI session files are collected at turn end,
   scrubbed of secrets, uploaded as `sessions-<seat>-*` artifacts (30d),
   and restored before the same seat's next turn — resume with context
   instead of starting cold.
5. OWNER LOCK: the Telegram bridge ingests ONLY the Owner's chat (secret
   TELEGRAM_OWNER_ID); every other chat is dropped and counted —
   impersonation impossible.
6. DOCKER LAW: agents are PREINSTALLED in the harness image
   (docker/harness/); CI never installs bodies at turn time. Keys are
   env-injected, never baked.
7. SEAT BOUNDARIES: seats never edit Lead-owned files
   (.github/workflows/*, agent-team/CONTROL.org, .gitattributes) —
   read and cite them with file:line evidence instead. Seats never push
   to ai/quickstart (the chain's finalize auto-merges their branch
   behind the gate).
8. BOARD DISCIPLINE: work items live on TODOs.org + the team board.
   Mark PROGRESS at start, log evidence in `:LOGBOOK:`, never self-mark
   DONE (Lead-only gate).
9. IDENTITY: commit as your seat identity, never as a generic bot.
10. NO SPEND, no destructive actions, stay in scope of the item you
    picked; escalate to @lead as `:escalation:` after 2 failed
    self-attempts.

## CI chain in one paragraph

`test` (byte-compile + ERT gate) → `turn` (TG ingest → session restore →
one agent segment in the preinstalled harness container → session
scrub+upload → branch push + rotation advance) → `finalize` (auto-merge
behind the gate → stall accounting → SELF-DISPATCH the next run while
the objective is open). The chain stops only on KILL-SWITCH ON,
OBJECTIVE-STATE COMPLETE, no objective, or tests red; a no-progress
streak shifts to backoff, never to failure. Owner gets deduped verdicts
on Telegram and the full GLM chat mirrored to this repo's Discord
channel (DISCORD_WEBHOOK_TEAM_AGENTORG webhook secret).
