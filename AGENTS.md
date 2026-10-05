# AGENTS.md — agent-org contributor / agent guide

## Build & lint
# Byte-compile (zero warnings required).  DEPENDENCY FIRST: compiling
# agent-org.el loads agent-org-buffer from its .elc, so a freshly added
# function there reads as "not known to be defined" until the buffer file
# has been recompiled.  Same trap as the stale .elc the test command warns
# about — `rm -f *.elc' when in doubt.
emacs -Q --batch \
  --eval "(add-to-list 'load-path \"/home/khalid/.emacs.d/elpa/acp-20260914.1318\")" \
  --eval "(add-to-list 'load-path \".\")" \
  --eval "(setq byte-compile-error-on-warn t)" \
  --eval "(batch-byte-compile)" agent-org-buffer.el agent-org.el agent-org-loader.el agent-org-providers.el

# Single-file compile:
emacs -Q --batch --eval "(add-to-list 'load-path \"/home/khalid/.emacs.d/elpa/acp-20260914.1318\")" \
  --eval "(add-to-list 'load-path \".\")" --eval "(byte-compile-file \"agent-org.el\")"

## Test
# Offline ERT suite (uses the mock acp in tests/, never the real package):
emacs -Q --batch \
  --eval "(add-to-list 'load-path \"/home/khalid/agent-org\")" \
  --eval "(load \"tests/test-agent-org.el\")" \
  --eval "(ert-run-tests-batch-and-exit)"

# The suite sets `load-prefer-newer': without it a stale `.elc' left in this
# directory by a package-build step silently shadows the sources under test.

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
# - Per-turn tool calls render as one `- KEYWORD title' LINE of the current
#   turn's `:tool:' drawer, one line per toolCallId, KEYWORD from the per-file
#   `#+TODO: TODO DOING | DONE CANCELLED` set (pending→TODO,
#   in_progress→DOING, completed→DONE, failed→CANCELLED).  NO NUMBER on the
#   line: it existed only to index a per-call output drawer, and one drawer
#   for the turn needs no index (the user's order: "No need to add numbers to
#   tool drawers").  There is NO marker per call either: every update redraws
#   the whole drawer from `agent-org-buffer--tools', the turn-local alist that
#   IS the record, so one call cannot get a second line and a reused
#   toolCallId after `resume' starts fresh under the new turn.  A call is a
#   line and not a headline because the Org drawer spec (info "(org) Drawers")
#   forbids headlines inside drawers: the earlier `**' shape had to keep the
#   calls ABOVE the `:thinking:' drawer to stay legal, and any headline that
#   landed inside that body was erased by the next thought chunk (measured
#   live: qoder replayed 4 tool calls, the buffer showed 1).
#   `agent-org-buffer--redraw-drawer' draws every kind and takes the FOLD a
#   newly created drawer gets: `:tool:' born OPEN (what the agent is doing now
#   is what the user came to watch), `:thinking:' and `:tool-output:' born
#   FOLDED; a drawer that already exists keeps whatever fold the user left it
#   at.  A keyword on a drawer line is TEXT, not an Org TODO state -- `C-c C-t'
#   acts on headlines, so a call's state is read, not cycled.  Fold state is
#   driven directly with `org-fold-region', NOT
#   `org-fold-hide-drawer-toggle', whose org-element cache is stale while a
#   turn streams ("Not at a drawer").
# - What a call PRINTED goes into ONE folded `:tool-output:' drawer for the
#   turn, in which each call is a `- TITLE' item with its body indented under
#   it — consecutive calls belong to a single drawer (the user's order), so a
#   turn of six calls is two drawers (board + bodies), not eight.  Output
#   cannot join the `:tool:' drawer: drawers may not nest (info "(org)
#   Drawers"), and one drawer has one fold state, so a shared drawer would
#   either hide live status or flood the chat with bodies — agent-shell
#   collapses tool bodies by default for the same reason.  The name a reader
#   follows is the TITLE, which the board above already shows.
#   Extraction is `agent-org-buffer--tool-output', in agent-shell's order: the
#   `content' blocks, else `rawOutput.formatted_output' ONLY when it is a
#   string (a number is not a shell result), else nothing — and nothing means
#   NO item, not an empty one.  A block with no surface is NAMED
#   (`[unsupported content: TYPE]'), never dropped.  `:shown' in the entry
#   holds what was last written: it now guards a rewrite of the WHOLE shared
#   body, so a status-only update must not re-protect every byte the turn ever
#   printed (measured on a quiet machine: 20 calls x 40 lines = ~5 ms per
#   redraw, ~105 ms for the turn, `test-agent-org-shared-tool-output-drawer-
#   redraw-cost'; the same test prints 213 ms when the box is busy).
# - Every drawer BODY the stream writes goes through
#   `agent-org-buffer--drawer-safe-lines': a `*' at column 0 is a headline and a
#   line reading `:END:' closes the drawer, and BOTH are ordinary characters in
#   agent text (a shell result quoting an Org file, a markdown thought's `* '
#   bullet).  Measured with `org-element-parse-buffer': one `* heading' line in a
#   drawer reports NO drawer and two headlines.  The escape is one space of
#   indent (a headline must start at column 0) plus, for an END line, a doubled
#   colon — `:END:' is matched case-insensitively and whitespace-tolerantly, so
#   `:end:', `:End:' and `  :END:' all close it.  Blank lines stay blank; that is
#   also why no output is ever truncated: folding is the affordance.
# - Never place a headline at the position `re-search-forward' RETURNS: that is
#   a match's END, which for a drawer marker is INSIDE the body, and
#   `agent-org-buffer--redraw-drawer' rewrites the whole body on the next
#   thought chunk -- that is how every tool call but the turn's last one
#   silently vanished.  Beware the same trap in general:
#   `line-beginning-position' returns a position, it does not move point.
#   Redrawing the drawer from a list made this unreachable for tool calls; the
#   lesson stands for anything else anchored to a marker.
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
# - NO render path may switch `font-lock-mode' OFF, and the replay is the proof
#   of why: an OFF is restorable and an ON IS NOT.  Measured live, in a buffer
#   no window is showing, `(font-lock-mode 1)' leaves the buffer-local variable
#   NIL — silently, with no error and no trace — and `turn-on-font-lock' does
#   the same, while in a displayed buffer it sticks.  So the replay's
#   suppress-for-the-bulk-paint-and-restore-afterwards lost a chat its colors
#   FOREVER whenever `session/load' painted into a background buffer (the
#   user's second "colors gone again!"), and an update that raised mid-paint
#   lost them even in a shown one, acp's own `condition-case-unless-debug'
#   swallowing the trace.  The suppression is therefore GONE:
#   `agent-org--render-replay' only flushes after the paint, inside the
#   `unwind-protect' that also stops the progress reporter (a raise there must
#   not leak a "Restoring" line).  Flushing is free when colors are off — the
#   real `font-lock-flush' checks `font-lock-mode' itself — and jit-lock makes
#   the per-chunk cost of leaving them on a redisplay-time job, not a
#   per-insertion re-scan.
# - A chat buffer therefore gets its colors at DISPLAY time, not creation:
#   `agent-org-buffer-create' runs inside an acp handshake callback, so the
#   buffer is always hidden then and ambient `global-font-lock-mode' can never
#   reach it.  `agent-org-mode' adds `agent-org-buffer--ensure-font-lock' to
#   the BUFFER-LOCAL `window-configuration-change-hook' (4th arg t, removed on
#   off), which Emacs runs with the buffer current when it first appears in a
#   window; the hook is an `unless', not a toggle, because it re-runs on every
#   window change and a repeat `(font-lock-mode 1)' rebuilds jit-lock over a
#   transcript thousands of lines long.
# - Batch Emacs cannot turn font-lock on at all, so no test asserts faces or a
#   successful enable.  They pin BEHAVIOUR by stubbing `font-lock-mode' and
#   `font-lock-flush' and setting the buffer-local variable as the premise:
#   `test-agent-org-replay-never-touches-font-lock-even-when-the-paint-errors'
#   records the CALL SEQUENCE (no `font-lock-mode' call at all, a flush, a
#   reporter stop) and `test-agent-org-chat-buffer-asks-for-font-lock-when-displayed'
#   runs the buffer-local hook the way a window would.
# - Restored turns use the SAME rendering primitives as typed ones; never
#   add a second renderer for replay, or the two will drift.
# - The header line shows exactly ONE status string, and for `starting'/
#   `ready' it is the STATE LABEL, not `:message'
#   (`agent-org-buffer--status-segment').  So a bare `:message' is invisible
#   while Ready.  A real request failure must set `:state 'error' (which
#   does render its message); a non-failure note that must not steal the
#   Ready segment goes to the echo area with `message'.  Never the body.
#   The exception is `:note', which qualifies a Ready label (`Ready (new
#   session: listing timed out)') because an invisible listing fallback read
#   as "the prompt never happens".  Set it through `agent-org--note-new-session'
#   (agent text goes through `agent-org-buffer--label', one line always), never
#   by reusing `:message'.  (The echo area has a second, transient user: a
#   progress report while a session LOADS — see the loading bullet below.)
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
# - The header line and `:Model:' show the option's `name' ("MiniMax M3"), never
#   the id (`minimax/MiniMax-M3'), because an id is a wire value a person is not
#   reading.  Both are stored (`:model` is still the id, and the only thing
#   `session/set_config_option' may send) and an unnamed current value falls
#   back to the id — a bar that drops the model field reads as "no model",
#   which is the worse lie.  Every writer goes through
#   `agent-org--ingest-config', so the pair cannot drift apart.
# - A chat buffer is named for its session: `<who>:<project> [sid]` — the title
#   (provider standing in until one arrives), then the project after the colon.
#   NO `agent-org: ` prefix and no `*…*` delimiters: the user asked for
#   `Qoder:agent-org [SESSION_ID]` and the package's own name only costs a chat
#   its place in `C-x b` (the rule is pinned by
#   `test-agent-org-buffer-name-wears-no-star-delimiters`).  Built by
#   `agent-org-buffer--wanted-name', applied by `agent-org-buffer-set-status'
#   ONLY on an update carrying `:title' or `:session-id' — those are the facts a
#   name is made of (`:project' is fixed at creation, from the session cwd), so a
#   per-chunk usage update builds no string.  `agent-org-buffer-create' names the
#   buffer itself, once the status (and therefore the project) exists, so even the
#   handshake buffer is findable by project; its own first name is the internal
#   ` *agent-org-<provider>*' (leading space = never listed), replaced three lines
#   later.  The provider
#   stands in for a title that has not arrived (as it does for `#+TITLE') and
#   qoder's `session_info_update' renames the buffer later.  The equality test in
#   `agent-org-buffer--apply-name' is not an optimisation: `generate-new-buffer-name'
#   counts this very buffer, so renaming per update walks the session through
#   `T [s]<2><3><4>'.  Titles are agent free text — through `agent-org-buffer--label'
#   (a newline in a buffer name breaks completion).  `rename-buffer' with
#   RENAME-ALL-PROCESSES nil keeps the acp process name readable in list-processes.
#   The id is /also/ an Org `:ID:' property, but never a header-line segment: the
#   bar carries state, the name carries identity.
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
#   are `TITLE  DATE  [id]' (`agent-org--session-columns' +
#   `agent-org--format-session-date'), sorted by `agent-org--session-stamp'
#   (`updatedAt' else `createdAt' — live goose omits `updatedAt'), newest first,
#   with `New session' always first in the list.
# - The candidate list is scanned, not read, so its SHAPE is the feature:
#   `agent-org--session-candidates' pads both columns to the batch's widest row
#   (a measuring pass over `agent-org--session-columns' first), and dims the date
#   and id with `shadow' so the title is what stands out.  Measured AND padded in
#   display columns (`string-width'): `string-pad' counts characters, which puts a
#   CJK title's date a dozen columns early.  And the order is pinned:
#   `completing-read' must be handed `agent-org--completion-collection',
#   a FUNCTION, because `display-sort-function' only travels on the `metadata'
#   action — a plain list is re-sorted by the UI and newest-first is lost at the
#   last step.  Because the displays now carry text properties, resolve a choice
#   with `agent-org--selection-value' (property-free `equal'), NEVER `assoc':
#   `equal' on strings compares properties too, and a framework that rebuilds the
#   string would match nothing and resume the wrong chat.
# - A listed session that a live buffer already holds is SHOWN, never loaded
#   again: `agent-org--session-open-p' answers from the registry (buffer-live-p,
#   so a session whose kill-hook has not run is not "open"), the candidate carries
#   `agent-org--open-marker', and `agent-org--load-session' — the single choke
#   point — pops that buffer instead of sending `session/load', killing the
#   half-open buffer (which releases the agent spawned for it) and noting the
#   switch in the echo area.
# - Killing the chat buffer MUST release the agent: `acp' owns the process it
#   spawned, so dropping the registry entry leaves an `qoder --acp' child running
#   (~100 MB each — measured live: 1 session registered, 16 stray acp processes).
#   `agent-org--forget-session' therefore calls `acp-shutdown' and unarms both
#   timers, and `agent-org--list-timeout' re-checks `buffer-live-p' as the second
#   lock (a timer is best-effort insurance, never the guarantee).  Assert the
#   BEHAVIOUR in tests, not the `cancel-timer' call: `ao--capture-wire' stubs
#   `cancel-timer', so firing the stored timer is how a test says "the deadline
#   arrived".
# - Killing a chat buffer ASKS first while its agent is alive: `agent-org--kill-query'
#   on `kill-buffer-query-functions' (buffer-local, installed beside the kill-hook by
#   `agent-org--register-session'), wording copied from Emacs' own `Process %s is
#   running; kill it? ' — Emacs never asks by itself because acp starts the agent
#   with `:noquery t' and no buffer, so `process-kill-buffer-query-function' cannot
#   see it.  A dead child answers YES (crashed agent, no consent needed) and so does
#   no session at all.  The query releases nothing — the kill-hook above owns the
#   shutdown.  So every kill agent-org performs ON ITS OWN (`agent-org--cancel-open',
#   `agent-org--show-open-instead', `agent-org-reload') goes through
#   `agent-org--kill-buffer-silently', which binds `agent-org--inhibit-kill-query':
#   a prompt raised inside an acp callback is a trap, not a question (see the ESC
#   bullet).
# - An acp client is an ALIST of dotted keyword pairs — `acp-make-client' returns
#   `(list (cons :process nil) ...)' (acp.el:90) and mutates it with `map-put!',
#   which for a list is the alist operation.  So read `:process' with `map-elt' (as
#   acp's own `acp--client-started-p' does); `plist-get' walks it as a flat plist,
#   matches nothing and answers NIL — silently, on a Ready session with a live
#   process right there (measured live: MAP-ELT gave `#<process acp-client(goose)-1>',
#   PLIST-GET nil).  The keys carry colons, which is what makes the flat-plist
#   reading look right.  Mocks must copy the SHAPE, not just the key names:
#   `tests/acp-mock.el' builds the dotted-pair alist, and with that fixture the
#   `plist-get' reader fails 3 kill tests instead of passing 156 and breaking live.
#   Generalise: when a stub exists to avoid a dependency, mirror the dependency's
#   data shape, or the suite tests the stub.
# - ESC at a session prompt is a `quit' that lands INSIDE an acp response
#   callback, and acp swallows it (`condition-case-unless-debug'): unguarded, the
#   chat buffer sat on "Starting"/"Restoring" holding a live agent process.  So
#   both prompt sites go through `agent-org--quit-cancels', which releases the
#   session by killing its buffer (the kill-hook path above is what shuts the
#   agent down) and notes it in the echo area.  A cancelled prompt yields NIL —
#   both readers complete with REQUIRE-MATCH, so nil is never a real answer, and
#   the caller must then send neither `session/new' nor `session/load'.
# - LOADING is reported in the echo area by a progress reporter, and the
#   events ARE the clock: `agent-org--progress-start' / `-step' / `-stop'
#   (agent-org.el, `:progress' on the session plist) wrap the two phases that can
#   actually be slow — `session/list' paging and the `session/load' replay.  NO
#   TIMER runs for them, deliberately: agent-shell's equivalent,
#   `agent-shell-active-message-show', animates its reporter with `run-at-time'
#   every 0.1 s, i.e. ten wakeups a second of which Emacs can display at most
#   five (`make-progress-reporter''s own MIN-TIME default is 0.2 s), and they go
#   on firing while the agent says nothing at all.  On this machine that is the
#   cost of a decoration.  `progress-reporter-update' is documented as doing
#   nothing when the change is too small or too soon, so stepping once per event
#   is self-limiting: raise `agent-org-progress-min-time' for less redraw, lower
#   it (or pin it to 0 in a test) to see every step.  Creating a report already
#   DISPLAYS its line, so a caller needs no first step to be seen.
# - Take the reporter's SHAPE from agent-shell, not its exit list.  Its hide is
#   called from five subscription sites, and a site added later leaks a spinner;
#   here each phase owns its report end to end — `agent-org--list-sessions' starts
#   on the first page and closes on every one of its own outcomes (last page,
#   page limit, repeated cursor, failure), `agent-org--list-timeout' closes the one
#   the pager cannot reach (the request that never answered), and
#   `agent-org--render-replay' / `agent-org--cancel-replay' /
#   `agent-org--forget-session' close the replay's.  Starting REPLACES, so phases
#   can only hand the line over, never fight over it.
# - Closing a report is `(message nil)', NOT `progress-reporter-done': every phase
#   here ends in something visible to read (the chooser, the restored history, the
#   error on the header), so a `...done' line is a redisplay nobody reads —
#   agent-shell pays it and then clears the area on the next line anyway.  ORDER
#   matters: stop BEFORE writing an echo-area note (the stop clears what follows
#   it), which is why `agent-org--list-timeout' stops first and explains itself
#   second.
# - Only the paint pass gets a PERCENTAGE, because it is the only phase with a
#   denominator (`agent-org--render-replay' knows how many updates it buffered) and
#   the only one that blocks Emacs in one synchronous run.  A spinner is stepped
#   with no value while history arrives: counting the buffer (`length' of a growing
#   list, once per chunk) and formatting a string per chunk are two costs that buy
#   nothing, because an indicator that moves already says "arriving".  Never step
#   with a computed count on a per-chunk path.
# - `agent-org-switch-buffer' (M-x, agent-shell's name) reuses the CHOOSER's
#   machinery rather than rebuilding it: `agent-org--column-width' measures,
#   `agent-org--pad' aligns by DISPLAY columns, `agent-org--session-display'
#   dims everything after the label, and the collection is
#   `agent-org--completion-collection' with `agent-org--selection-value'
#   resolving the choice.  Rows are `LABEL  STATUS  [id]' in REGISTRY order
#   (`agent-org--register-session' pushes, so the newest chat is first, and an
#   open session has no `session/list' stamp to sort by anyway).  What differs
#   from the chooser is the row's VALUE: a BUFFER object, never a name — the
#   agent renames its own chat, so a name looked up afterwards can match
#   nothing.  Killed-but-unforgotten entries are dropped with `buffer-live-p'.
# - One chat, ONE display label: `agent-org-buffer--chat-label' ("<project>
#   <title>", provider standing in for a title that has not arrived) is called
#   by `agent-org-buffer--wanted-name' AND by the switcher's first column.  Two
#   builders writing the same three rules is how one chat ends up called
#   "org-docs Qoder" in `C-x b' and plain "Qoder" in the switcher — which is
#   what the first live run printed: two rows identical but for a UUID.  So the
#   label takes the status PLIST as an argument instead of reading
#   `agent-org-buffer--status', because the switcher labels OTHER buffers and
#   a `with-current-buffer' there is a function that can move point in a chat
#   you only meant to look at.
# - Never locate an aligned column by the whitespace in front of it: a padded
#   label and the separator are both spaces, so `(string-match-p "  " row)'
#   measures where the PADDING began, not where the column starts (it failed a
#   passing implementation with `(18 47)' on two identical 65-column rows).
#   Measure the first character carrying the `shadow' face — the dim run IS the
#   column, by construction.
# - An Agent turn's heading is the MODEL that answered: `agent-org-buffer--turn-heading'
#   reads the buffer-local status (`agent-org-buffer--model-display' — the agent's
#   label, else its id) and flattens it with `agent-org-buffer--label', because a
#   config option's `name' is agent text and a newline on a heading line is a
#   broken headline.  No model at all (Goose advertises none of this shape), or
#   `agent-org-use-model-headings' nil, gives the word "Agent": `* ' alone is a
#   malformed headline.  The text is written ONCE at turn start and never derived
#   again, so a later `C-c C-m' renames the turns after it and the transcript
#   carries per-turn provenance for free — which is why the settled design's
#   `:turn-models' map was NOT built: nothing could read it (the heading is the
#   record), and a resume cannot know per-turn models anyway, since
#   `session/load' attaches no model to a chunk.
# - Never locate a turn by heading TEXT: placement is `agent-org-buffer--turn-anchor'
#   and `agent-org-buffer--render-end', which is what makes renaming the heading a
#   cosmetic change (5 pre-existing ~^\\* Agent$~ assertions stayed green — they run
#   on fixtures whose status carries no model, so they ARE the fallback path).
#   Same reason `agent-org-buffer-start-agent-turn' still ignores its SESSION
#   argument: the two callers that start a turn without one (a thought chunk or a
#   tool update arriving before any chunk) must get the same heading, and the fact
#   lives with the buffer, not the session.
# - The per-session transcript is a MIRROR of the buffer, not an append log, and
#   it is written only at turn boundaries (`agent-org-buffer-transcribe`: ready,
#   send, both send callbacks, cancel, late title, kill).  Never call it from a
#   render site: an append log could not show a tool call's drawer line as
#   DONE without
#   keeping its TODO line (CONVENTIONS.md §3, §14), and a per-chunk write spends
#   its cost inside the stream — measured 90-170 ms per turn here versus 2 whole-file
#   writes of 3-15 ms.  The mirror spans `point-min' to
#   `agent-org-buffer--render-end', so the live draft is never filed; the id in the
#   file name is sanitized to `[A-Za-z0-9._-]' because it arrives over the wire and
#   becomes a path; a `file-error' is a `message', never a broken turn; and
#   `write-region' VISIT stays nil or the chat buffer would start `visiting' its own
#   transcript and `C-x s' would save the draft into it.  The directory is the
#   RELATIVE `.agent-org' resolved against the CHAT buffer's `default-directory'
#   (`agent-org-buffer--transcript-file'), so each project keeps its own
#   transcripts; only an absolute setting means a global pool.  So a test suite
#   that leaves transcription on writes into whatever directory the batch was
#   launched in — measured: 22 `sid-*.org' in the package tree.  The suite now
#   binds `agent-org-transcribe' nil at the top of tests/test-agent-org.el, and
#   only `ao--transcript-in' turns it back on inside a temp directory.
# - A chat buffer's `read-only' text properties must never reach the mode line.
#   `which-function' (which-func.el) falls through to `add-log-current-defun',
#   which copies the heading TEXT WITH PROPERTIES and hands it to
#   `which-func-format' — `(:propertize which-func-current ...)' — and applying
#   a property to text that carries `read-only' signals `text-read-only'.  Under
#   `which-function-mode' + doom-modeline that error lands inside
#   `doom-modeline-format--main', which builds its whole right half with ONE
#   `format-mode-line' (doom-modeline-core.el), so nothing is rescued: the bar
#   goes blank (measured live: `(doom-modeline-format--main)' signaled
#   text-read-only, and returned a 77-char string with `inhibit-read-only'
#   bound).  So `agent-org-mode' sets a buffer-local
#   `add-log-current-defun-function' = `agent-org-buffer--which-function',
#   which returns `(substring-no-properties (org-get-heading t t t t))' at a
#   heading and nil elsewhere.  A non-nil `add-log-current-defun-function' also
#   suppresses which-func's own imenu fallback, so this one function is the
#   whole answer — not a hint to add a second.
# - A queued prompt is the only conversation text the agent has never seen, so
#   it is the only thing a resume cannot replay.  It lives in a `:QUEUE:' drawer
#   of the auto-managed metadata block — one line per prompt, oldest first,
#   escaped by `agent-org-buffer--queue-encode' (newline and backslash; the `- '
#   prefix keeps a prompt that IS `:END:' from closing its own drawer), read back
#   by `agent-org-buffer-transcript-queue'.  Set `:queued' on the status, never
#   write the drawer by hand: `agent-org--queue-refresh' is the single choke
#   point that mirrors session `:pending-prompts' into the block AND the file, so
#   every queue command (enqueue, remove, edit, drain) is a boundary of its own —
#   a mid-turn quit must not swallow what the user typed.
# - `agent-org--finish-replay' reads that drawer BEFORE rendering, and applies it
#   after `agent-org--session-ready'.  Both halves are load-bearing: session-ready
#   mirrors the freshly replayed buffer over the transcript, and a replayed buffer
#   carries no queue — reading after that write finds nothing.  Applying late is
#   what lets the restored prompt go on the wire to an interactive session (id set,
#   box open, `:loading' gone), and it drains rather than stranding the queue,
#   because nothing else drains a session that is not busy.  An empty queue renders
#   NO drawer: that absence is what stops a prompt being sent twice.
# - Agents answer in Markdown and the body is Org, and the disagreement is
#   STRUCTURAL, not cosmetic: `# Title' is an Org COMMENT (it vanishes from every
#   export), `* item' is a level-1 HEADLINE (it cuts the turn in two), `---' under
#   a paragraph is a headline too, and Markdown's alignment rule `|:--|--:|' is not
#   Org's separator row (measured: the table loses its header and `--:' exports as
#   an em-dash).  So `agent-org-convert-markdown' (default t) renders a reply — and
#   the user's own echo — through `agent-org-buffer--markdown-line': a heading
#   shifts ONE level down (level 1 belongs to the conversation), star bullets
#   become dashes, and the two emphasis forms are rewritten in a SINGLE
#   left-to-right pass — rewrite `**b**' to `*b*' and then run the `*i*' rule over
#   the RESULT and you have italicised the bold you just made.  `_text_' and
#   `~~text~~' are deliberately untouched (the first would eat `foo_bar_baz', the
#   second is cosmetic).  Nothing on the wire changes: the agent receives the
#   Markdown as typed, so this is rendering, not translation, and nil is the
#   verbatim escape hatch.
# - A code fence is a STATE, so conversion is line-by-line with it threaded
#   (`agent-org-buffer--md-src-p', buffer-local and turn-local): inside a block
#   nothing converts, because a shell sample full of `#' and `*' is code, and an
#   open `#+begin_src' swallows the rest of the buffer AND the rest of the
#   transcript file — which an agent that hit its token limit can send.  So every
#   close path (`--markdown-convert', `--markdown-flush-here') shuts it.
# - Streaming converts AS TEXT ARRIVES and rewrites only the last line.  A chunk
#   stops wherever the model's tokenizer stopped, so `**bold' may end one and `**'
#   open the next; the fix is NOT to hold the line until its newline (that made a
#   one-line reply — which usually never sends one — invisible until the turn
#   ended) but to write the partial line and let the next chunk replace that
#   region (`agent-org-buffer--markdown-write', from `--md-tail' to
#   `--render-end').  So a provisional region must never outlive a boundary that
#   draws below the turn's text: `agent-org-buffer--markdown-flush-here' runs at
#   `append-thought', `insert-tool' and `end-agent-turn' and FORGETS the state —
#   a stale marker would put the next chunk's `delete-region' through the drawer.
#   Two traps measured here: a marker detached with `set-marker' still answers
#   `markerp' t while `marker-position' is nil (the chunk AFTER one ending in a
#   newline crashed on `goto-char'), and a helper that calls `string-match'
#   clobbers the global match data the scan is built on.
#   Cost is a few regexps per line plus one small delete+insert per chunk:
#   `test-agent-org-markdown-conversion-cost-per-line' prints the number.
