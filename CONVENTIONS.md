# agent-org — Org conventions for chat buffers

This document records **why** our buffers are shaped the way they are,
grounded in the upstream Org manual (Emacs 29 `info "(org)"`).  Every rule
below cites the node it comes from.  When in doubt, `Read the Docs First`:
the manual, not folklore.

The buffers we generate are ordinary `.org` files: a user should be able to
open one, `M-x org-mode`, fold with `TAB`, cycle TODO states with `C-c C-t`,
and see sensible structure.  We do not invent a bespoke syntax.

---

## 1. Buffer layout

Top to bottom, a session buffer is exactly:

1. **One auto-managed metadata block** at `point-min` (see §2).
2. A blank line separating it from the conversation.
3. The conversation: alternating `* User` and `* Agent` level-1 headings.
   An Agent turn carries a `:thinking:` drawer of its reasoning, a `:tool:`
   drawer with one line per tool call, and one `:tool-N:` drawer holding what
   call *N* printed — for every call that printed something (see §3).
   By default the Agent heading is not the word
   `Agent` but the model that answered — `* MiniMax M3` (see below).

```org
:PROPERTIES:
:Provider: goose
:ID:       01J...
:Mode:     auto
:Model:    Claude Sonnet
:Context:  12k/200k (6%)
:Cost:     $0.00
:END:

#+TITLE: Refactor the auth module
#+TODO: TODO DOING | DONE CANCELLED

:COMMANDS:
/goose — talk to the goose agent
:END:

:QUEUE:
- ask about the tests\nfirst
:END:

* User

What does agent-org-buffer.el do?

* Claude Sonnet
:thinking:
Let me look at the buffer first…
:end:
:tool:
- TODO 1. read_file
- DONE 2. write_file
:end:
:tool-2:
+ def login(user):
:end:
```

Nothing else may live in the body.  Status, progress and errors never
become text — see §6.

**The Agent heading names the model that answered** (`agent-org-use-model-headings`,
default on): `* Claude Sonnet`, not `* Agent`.  Which model produced an answer is
a fact about the transcript, and the header line that says so is gone as soon as
the buffer is buried or the file is re-read.  The text comes from
`agent-org-buffer--turn-heading` — the buffer status's model label, else its id,
else the word `Agent` — flattened by `agent-org-buffer--label` because a config
option's `name` is agent text and a newline on a heading line is a broken
headline.  Two rules keep this cosmetic: the heading is written **once**, at turn
start, so it records the model in force then and a later `C-c C-m` renames only
the turns after it; and nothing ever finds a turn by its heading text — placement
goes through the turn anchor and `agent-org-buffer--render-end`, which is why the
two callers that start a turn with no session (a thought chunk or a tool update
arriving first) get the same heading as the streaming path.

**The buffer is named for its session**: `<who>:<project> [<session id>]`, with no
`agent-org: ` prefix and no `*…*` delimiters.  `C-x b` and any switcher list names,
and a bare `Qoder` tells someone with three qoder chats open nothing — nor does
`Fix the login bug [sid]` once two projects produce that title.  So the agent (or
its title) leads, because that is what a person scans for, and the last directory
component of the session cwd follows the colon, in the `file:directory` idiom
Emacs users already read.  The provider stands in for a title that has not
arrived, exactly as it does for `#+TITLE:`, and the id is omitted until the agent
gives one; the project is there from creation, so even the handshake name
(`goose:myproj`) places the buffer.  All three facts come from
`agent-org-buffer--wanted-name`, whose `<who>:<project>` part is
`agent-org-buffer--chat-label` — the same function `agent-org-switch-buffer`
builds its first column from, so one chat has one name in every list (§13);
after creation the name is applied by
`agent-org-buffer-set-status`, on the updates that carry `:title` or
`:session-id`: those and the creation-time `:project` are all a name is made
of, so a per-chunk usage update builds no string and renames nothing.  Two
traps that the equality guard in `agent-org-buffer--apply-name` exists to
prevent: `generate-new-buffer-name` counts *this* buffer, so renaming on every
update walks a session through `T [s]<2><3><4>`; and a title is agent-supplied
free text, hence `agent-org-buffer--label` — a newline in a buffer name breaks
the completion UI.  `agent-org-buffer-create` does give its buffer one internal
name, ` *agent-org-<provider>*` — the leading space is Emacs' own convention for
a buffer that should not be listed — and renames it three lines later, before
anything could see it.
`rename-buffer` with `RENAME-ALL-PROCESSES` nil, so the agent process
keeps the name `acp` gave it and `M-x list-processes` still reads sensibly.

---

## 2. The metadata block

The very top of the buffer is **one** auto-managed block, rewritten whole by
`agent-org-buffer-refresh-metadata`.  Never hand-edit it.  Its shape is
fixed by two manual rules:

* **PROPERTIES drawer first, then `#+TITLE:`.**  A property drawer is the
  manual's blessed home for entry scalars (`info "(org) Properties and
  Columns"`); we use it for Provider/Session/Mode/Model/Context/Cost/Tokens.
* **No heading in the metadata block.**  `*` lines belong to the
  conversation only.  The block spans `point-min` up to the first `* ` line,
  which is what `refresh-metadata` deletes-and-reinserts to stay idempotent.

The block is folded by default.  Per `info "(org) Initial visibility`
(§2.2.2), first-visit folding is normally driven by `#+STARTUP:` — but these
buffers are created programmatically and never "visited", so we fold the
drawers directly (see §5) rather than relying on a startup line.

**`:QUEUE:` is the one volatile drawer, and it comes last.**  COMMANDS, MODES
and CONFIG are reference the agent advertised once; QUEUE holds the prompts
the user sent into a busy session — text that is neither reference nor
conversation yet, because a queued prompt gets its `* User` heading only when
it drains.  It belongs to the block because the block is inside the range the
transcript mirrors (§14), and a prompt the agent has never seen is the one
thing its `session/load` replay cannot give back.  One escaped line per
prompt, oldest first (`agent-org-buffer--queue-encode`: newline and backslash
flattened, `- ` prefixed so a prompt that *is* `:END:` cannot close its own
drawer); an empty queue renders **no** drawer, because that absence is what
stops a resume re-sending a prompt that already went out.

Rebuilds are cheap-checked: `refresh-metadata` renders the block first and
compares it against `agent-org-buffer--metadata-cache`, doing nothing when it
is byte-identical.  That matters because `usage_update` arrives many times per
turn, and a rebuild costs a full `org-set-regexps-and-options` reparse.

### `#+TITLE:` is the harness session title, verbatim

`agent-org` never decorates the title.  The `#+TITLE:` line carries **exactly**
the title the agent/harness set via ACP (`session/info` /
`session_title_updated`), stored through `agent-org-buffer-set-status :title`.
Until a title arrives, the **provider name alone** stands in as a fallback —
never a `"Goose - <something>"` mashup, never a truncated prompt.  The rule
is: *whatever the harness calls this session is what `#+TITLE:` says.*  A
rename from the agent therefore flows straight through on the next
`refresh-metadata`.

---

## 3. Tool calls are lines of a `:tool:` drawer

Each ACP tool call renders as **one line per `toolCallId`**, inside the current
agent turn's `:tool:` drawer (the turn heading is named for the model, see §1):

```org
:tool:
- KEYWORD N. title
:end:
```

The `toolCallId` is *not* in the line — it is the agent's bookkeeping, and the
turn's `agent-org-buffer--tools` alist already owns the call, so every update
redraws the whole drawer from that list rather than hunting for a marker.
`N` is the call's position in that order, and it is what pairs the line with the
`:tool-N:` drawer of its output below (§3.1); a gap in the numbering therefore
means "this call printed nothing", which is why no empty drawer is created.

`KEYWORD` maps the ACP `status` onto a per-file TODO set:

| ACP status    | Org keyword | meaning       |
|---------------|-------------|---------------|
| (nil/pending) | `TODO`      | queued        |
| `in_progress` | `DOING`     | running       |
| `completed`   | `DONE`      | finished ok   |
| `failed`      | `CANCELLED` | errored/aborted |

### Why a drawer line, not a `**` headline

The drawer spec is the reason a call *cannot* be a heading inside a drawer —
`info "(org) Drawers` (§2.7):

> They can contain anything **but a headline and another drawer**.

The first version of this file therefore put calls in `**` headings *above* the
`:thinking:` drawer, and paid twice for it: one marker per call plus a
locate-by-search helper, and a class of bugs where a headline landed at the
drawer's `match-end` — i.e. inside its body — so `agent-org-buffer--redraw-drawer`'s
next wholesale rewrite (every thought chunk) erased every call except the turn's
last one, silently.  Live qoder replayed four tool calls and the buffer showed one.

As lines of their own drawer, calls and thoughts are drawn by ONE primitive, the
ordering trap cannot recur, and each kind gets its own fold: the `:tool:` drawer is
born OPEN (what the agent is doing right now is what the user came to watch) and the
`:thinking:` drawer born folded (raw reasoning is not the point of the turn), with
`agent-org-buffer--redraw-drawer`'s FOLD argument describing only a drawer that does
not exist yet — one the user has already opened stays open.

What the headline shape bought is partly given back: a keyword on a drawer line is
**text**, not an Org TODO state, so `C-c C-t` does not cycle it (`org-toggle-todo`
acts on headlines, and a line in a drawer is not one).  The per-file `#+TODO:` line
stays for that same reason reversed — it names the only state a reader of a
transcript or a chat can see for a call, and a file whose heading vocabulary is
declared is a file Org parses the way it looks.

### 3.1 What a call printed: a folded `:tool-N:` drawer

Output goes in a drawer of its own, named by the number on the call's status
line, for three reasons:

* **Org forbids nesting.**  §2.7: a drawer holds "anything but a headline and
  another drawer" — so the body of `:tool:` cannot contain the output of the
  calls it lists.  Sibling drawers both parse.
* **One drawer has one fold state.**  The status lines must stay visible (that
  is the live progress the user watches) while the bodies must not fill the
  screen.  Shared drawer = choose one; agent-shell reaches the same conclusion
  and ships `agent-shell-tool-use-expand-by-default` nil, i.e. collapsed.
* **Activity order is preserved.**  The status drawer lists the calls in the
  order the agent made them, and each body sits under the turn with the same
  number, so reading down the turn is reading the agent's actions in order —
  which is the ordering the user asked to keep from agent-shell.

The extraction (`agent-org-buffer--tool-output`) is agent-shell's rule, in its
order: the `content` blocks, else `rawOutput.formatted_output` **only when it is
a string** (Codex reports terminal output that way and leaves `content` empty),
else nothing.  A block type we cannot render is *named*, `[unsupported content:
TYPE]`, never silently dropped.  Diff and tool-call updates arrive through the
same path, so a completed call shows what it printed and a still-running one
shows what it printed so far.  Nothing is truncated: folding is the affordance,
and a record that quietly lost its middle is worse than a long one.

`:shown` on the entry is the body last written, so the many status-only updates
that follow an output-bearing one cost no redraw of the body.

### 3.2 A drawer body may not re-shape its own drawer

Agent text is free text, and two shapes that are ordinary in it are **structural**
in Org: a line whose first character is `*` is a headline, and a line reading
`:END:` closes the drawer it sits in.  Measured with `org-element-parse-buffer`: a
`:tool:` drawer holding one `* heading` line reports *no drawer at all and two
headlines* — the turn's whole tool state falls out of its fold and into the body.
And `:END:` is matched case-insensitively and whitespace-tolerantly, so `:end:`,
`:End:` and `  :END:` all close it (a shell result quoting an Org file, or a
markdown thought's `* ` bullet, carries these routinely).

`agent-org-buffer--drawer-safe-lines` is the one primitive guarding every body the
stream writes — `:thinking:` and `:tool-N:` alike:

* every line gets **one space of indent** (a headline must start at column 0);
* a bare END line additionally gets a **doubled colon**, ` ::END:`, which is not
  the marker and still reads as the text it is;
* blank lines stay blank (they are legal inside a drawer, and dropping them would
  flatten the output's own shape).

### The per-file keyword line

We do **not** touch the global `org-todo-keywords`.  Instead the metadata
block carries (column 0):

```org
#+TODO: TODO DOING | DONE CANCELLED
```

Per `info "(org) Per-file keywords` (§5.2.5):

> For file-local settings, you need to add special lines to the file which
> set the keywords and interpretation for **that file only**… starting in
> column zero anywhere in the file.

The `|` separates not-done states (`TODO`, `DOING`) from done states
(`DONE`, `CANCELLED`).  We apply the line with `org-set-regexps-and-options`
at buffer creation and after each metadata rewrite — this is the programmatic
equivalent of the `C-c C-c` the manual tells an interactive user to press
after editing the line.  `org-todo-keywords-1` becomes buffer-local; the global
default is left untouched (asserted in the test suite).

The set is still declared even though a call is now a drawer LINE, where its
keyword is text rather than an Org state: the line the user reads is the record
of what a call is doing, and a file that names its own vocabulary explains that
record without the reader having to know this package.

### In-place updates, never duplicates

`tool_call_update` for a known `toolCallId` **redraws the turn's `:tool:` drawer
from `agent-org-buffer--tools`**, so the call's line changes state in place and a
second line for the same call can never appear — the alist is the only place a
`toolCallId` is stored, and the drawer is a rendering of it.  The alist is
turn-local: `start-agent-turn` clears it, so a reused `toolCallId` (e.g. after
`resume`) starts fresh under the *new* turn instead of rewriting a line frozen in
the old one.

> Gotchas we've been bitten by, and pinned with tests:
> * `plist-put` **prepends a new list** when the key is absent, returning it; the
>   entry you keep then diverges from the stored one.  Both keys of a tool entry
>   are created up front so `plist-put` always mutates in place.
> * `line-beginning-position` returns a position, it does not move point — and
>   `re-search-forward` returns a match's **end**.  Inserting at either of those
>   relative to a drawer marker put the content INSIDE the drawer body, which the
>   next redraw deleted.  (This is the bug that hid every tool call but the last;
>   drawing the drawer whole from a list made the class of bug unreachable.)

---

## 4. Extended thinking is a folded `:thinking:` drawer

Thinking text accumulates in **one** `:thinking:` drawer per Agent turn, updated
in place.  This is the legitimate drawer use from §2.7: plain content, no
headlines inside — but thinking is markdown-flavoured prose, so a `* ` bullet in
it is a headline to Org; its body goes through the same
`agent-org-buffer--drawer-safe-lines` guard as a tool output (§3.2).  A tool call is a line of a SEPARATE `:tool:` drawer (§3), so
the two kinds of agent activity each get their own fold — the thought is born
folded, the calls born visible — and neither can erase the other, because
`agent-org-buffer--redraw-drawer` searches for its own `^:NAME:$` bounded by the
turn.  Drawer order within a turn is arrival order: whichever of the two the
agent produced first is drawn first.

---

## 5. Folding

Fold state is driven **directly** with `org-fold-region`, never
`org-fold-hide-drawer-toggle`.  Reason (documented in our source, discovered
the hard way): while a turn streams we keep `font-lock-mode` off, so the
`org-element` cache that `org-fold-hide-drawer-toggle` validates is stale and
it signals `"Not at a drawer"`.  `org-fold-region` works on positions alone
and is safe on the hot path.

A drawer the user manually opened stays open across updates: we detect
`invisible-p` on the body, unfold → swap → refold, preserving intent.

---

## 6. All feedback goes to the header line — never the mode line, never the body

Two hard rules, both from `AGENTS.md` and enforced by tests:

1. **Body stays pure conversation.**  No status messages, comment blocks, or
   bullet lines are ever inserted as content.  The body holds only `* User` /
   `* Agent` turns, the turn's `:thinking:` and `:tool:` drawers, and the one
   metadata block.
2. **Status lives in the `header-line`** (the top bar, gptel/agent-shell
   style) via `agent-org-buffer-set-status`.  We do **not** mutate the
   `mode-line` and add **no** minor-mode lighter — `agent-org-mode` is
   defined with `:lighter nil`.  A buffer must never end up with a blank
   mode line because of us; `test-agent-org-leaves-mode-line-alone` asserts
   `mode-line-format` stays equal to its default value and that
   `agent-org-mode` is absent from `minor-mode-alist`.

Why the header line rather than the mode line: the mode line is shared
real-estate that many packages and Emacs itself write to; a custom lighter
there is noise and a blanking risk.  The header line at the top is our
designated status surface and is what the user's eye is on while a session
streams.

What that surface says is a *label*, never a wire value.  The model segment is
the `name' the agent advertises for its current model ("MiniMax M3"), not the
id (`minimax/MiniMax-M3`) that `session/set_config_option' takes — an id is
what a machine routes on, not what a person reads, and the `C-c C-m' chooser
already listed labels, so the two agree.  Both live on the status plist
(`:model-name' to show, `:model' to send) and only
`agent-org--ingest-config' writes the pair, from one read of `configOptions',
so a bar cannot drift from the model actually in force.  An agent that reports
a current value it does not name falls back to the id: an absent model field
reads as "no model", which is the worse of the two lies.

One trap inside that rule: `agent-org-buffer--status-segment` renders exactly
**one** status string, and for `starting` and `ready` it renders the *state
label*, not the `:message`.  So `:message "something went mildly wrong"` is
silently invisible while the session is Ready.  A real failure must therefore
set `:state 'error` (which does show the message, as `Error: …`), and a
non-failure note that must not steal the Ready segment — e.g. a provider's
pinned model not being offered by the agent — goes to the echo area with
`message` instead.  Never invent a third channel, and never write to the body.

The echo area therefore has two users, and the difference is lifetime.  A *note*
is one line, left alone to expire on `message-log-max`'s own timer.  A *report*
is a line that is replaced as work proceeds and cleared when it ends: while a
session LOADS, `agent-org--progress-start' / `-step' / `-stop' drive a
`progress-reporter' there for the two phases that can actually be slow —
`session/list' paging and the `session/load' replay.  It is not a third channel:
it is the echo area, and it exists because the header line can only ever say
which *state* the buffer is in, not how much of it has arrived.  Three rules
keep it from becoming noise:

* **Nothing steps it on a timer.** The events that happen — one replay chunk,
  one page — are the tick.  `progress-reporter-update' documents itself as doing
  nothing when the change is too small or too soon, so the redisplay rate is
  bounded by `agent-org-progress-min-time' (Emacs's own 0.2 s default) while an
  idle agent costs nothing at all.
* **Each phase owns its report end to end.** `agent-org--list-sessions' closes
  its own on every one of its outcomes; `agent-org--list-timeout' closes the one
  the pager cannot reach; the replay's is closed by the render, the cancel and
  the kill of the buffer.  `agent-org--progress-start' replaces, so a leak
  cannot leave two owners of one line.
* **Closing clears rather than announces** (`(message nil)`, not
  `progress-reporter-done`), and it happens *before* any note is written into
  the same area — otherwise the stop erases the explanation that just followed
  it.

`:note` is not a third channel — it is the header channel, for the one case
where the echo area demonstrably was not enough.  A `session/list` that timed
out fell back to `session/new` with nothing on screen but `Ready`, and the user
reported "I'm getting no prompts for sessions at start": the feature looked
broken precisely because the degradation was invisible.  So a ready segment may
qualify its label — `Ready (new session: listing timed out after 20s)` — from
`agent-org-buffer--status`'s `:note` key.  The rules that keep it honest: it is
suffix text, never a replacement for the label; it is set by
`agent-org--note-new-session`, which runs the agent's own words through
`agent-org-buffer--label` so the header stays one line; and it is cleared by
`agent-org-loader-begin`, so a reason belongs to the attempt that produced it.
`starting` deliberately ignores it — during a bootstrap the user is watching the
state change, not reading footnotes.

---

## 7. Read-only protection

Conversation content and the metadata block are frozen with `read-only` +
`front-sticky` text properties (`agent-org-buffer--protect`).  The cursor
travels freely over history (browse/copy work); only *modification* is
refused.  The live `* User` prompt at the end is the sole editable region —
its heading is frozen, its body is typeable, and typed text carries
`rear-nonsticky` so it doesn't inherit the freeze.

Org structure commands (`M-RET`, `C-c C-t` on boundaries, meta/shift arrows,
`C-c -`) are remapped to a `user-error` in `agent-org-mode-map`, because they
bypass `read-only` properties and would corrupt heading boundaries.

---

## 8. Headline conventions (the manual's basics we rely on)

From `info "(org) Headlines` (§2.1):

* Headlines start at the **left margin** with one or more `*` + a space.
  Our levels: `*` = turn (User/Agent), and a deeper level only where a
  Markdown heading in a reply was converted (§15) — a tool call is a drawer
  line, not a heading (§3).
* **An empty line after a subtree is part of it** and is hidden when the
  subtree folds; two or more empty lines leave one visible separator.  Our
  `agent-org-buffer--separator` inserts exactly the one blank line that keeps
  a freshly appended heading from abutting prior text — matching this rule so
  the collapsed view stays structured.

---

## 9. Resume replay — buffer it, then paint once

`agent-org-resume-session` replays a session's history into a fresh buffer.  Restored
turns are laid out **exactly** like typed ones (`* User`, the model-named agent
heading, the `:thinking:` and `:tool:` drawers), because the replay feeds the same
`agent-org-buffer-*` primitives through `agent-org--buffer-update`.  Nothing
about resume gets a private renderer.

The contract that keeps it cheap on a slow machine:

* Conversational updates (`agent-org--replay-kinds`) arriving while
  `:loading` is set are **buffered**, never painted.  Painting per chunk would
  re-fontify the whole buffer for every chunk of a 200-turn session.
* The `session/load` **response is not the flush point**.  The protocol puts
  history before it, but live qoder answers first and streams the replay
  right after — flushing on the response silently dropped every agent turn,
  tool call and thought.  Instead each late update re-arms a quiet-period
  timer (`agent-org-replay-settle-delay`) and `agent-org--finish-replay`
  renders once the agent stops talking.
* `agent-org-replay-settle-cap` bounds that: past it the armed render is left
  to fire rather than being pushed back, so a chatty agent cannot hold a
  buffer in `Restoring` forever.  Partial history beats a stuck buffer.
* The render runs as one insertion pass with `buffer-undo-list t`, then the
  load response's modes/config still reach the header line (kept in
  `:replay-response`).
* `:loading` means *not yet typable*: `agent-org-send` refuses while it is
  set, and `agent-org--session-ready` will not insert a prompt on top of
  history still arriving.
* Killing the buffer cancels the pending render, so no timer ever fires
  against a dead buffer.
* The two halves of replay report differently, because only one of them has a
  denominator.  Updates arriving get a spinner (`agent-org--progress-step`
  with **no value**): nobody knows how many chunks an agent intends to replay,
  and counting them per chunk would walk a growing list on every one —
  quadratic on exactly the long session that needs the feedback.  The paint
  pass knows `total` up front, so it gets a percentage, and it is the only
  phase that blocks Emacs long enough (one synchronous run) to be worth
  measuring.

Anything the agent *names* is free text, and it arrives as such.  A live qoder
session titled its tool calls with the whole shell command (one title was
`which agent-shell-list ... ; echo "---"; emacsclient ...` across a dozen
lines), and a resume `session/list` returned the entire first prompt as a
session's `title`.  Verbatim, that is fatal to a one-line context: a drawer is
closed by a line reading `:end:`, so text carrying a newline can end the
`:tool:` drawer early and leave the rest of the call's description to the next
redraw; a buffer name with a newline cannot be completed in `C-x b` at all; and
a heading takes only its first line, the remainder falling into the body.
`agent-org-buffer--label` therefore collapses whitespace runs and truncates to
`agent-org-buffer--label-width` before any agent text reaches a one-line
context: tool drawer lines (`- KEYWORD title`), chat buffer names and resume
candidates alike, always with the id kept visible because the id is what
identifies the thing.

This applies to live turns exactly as to replayed ones — the same tool_call
updates stream during a normal prompt.  Multi-line content is never *lost*,
it just does not get a line of its own; drawers (`:thinking:`,
`#+RESULTS:`-style blocks) are where multi-line text belongs.

Header line state for this phase is `loading`, labelled **"Restoring"** — a
transient (busy-colored) state like `starting`/`streaming`.  It is body-free
like every other state (§6).

---

## 10. Starting is a decision, taken once, in the command

`agent-org-start` does not simply mean `session/new`.  `agent-org-session-strategy`
(`new` / `latest` / `prompt`, names borrowed from agent-shell) decides what the
handshake is followed by, and `agent-org--begin-start` is the only place that acts
on it.

* **The strategy is read when the command runs, never when the agent answers.**
  `agent-org-start` captures it into a local and threads it through
  `agent-org--begin-start` and `agent-org--choose-start`.  A callback that re-reads
  the variable follows whatever happens to be bound minutes later: a live probe that
  bound `new` around `agent-org-start` still went and listed the directory, because
  the `let` had exited by the time `initialize` replied.  The same rule already
  applies to `current-prefix-arg`, which the command loop unbinds before any
  callback runs.
* **One pager: `agent-org--list-sessions`.**  `agent-org-start` and
  `agent-org--resume-locate` both call it, so paging behaviour cannot drift
  between them.  It follows `nextCursor` until the agent stops offering one
  (`agent-org-session-list-page-limit` caps the requests), and a cursor the agent
  repeats is treated as a **failure**, not as another page — otherwise a buggy
  agent pages forever.  It hands `on-success` one synthesized
  `((sessions . VECTOR))`, so nothing downstream can tell one page from ten.
* **A listing has exactly one owner.**  `:list-state` goes `pending` then
  `settled`, and `agent-org--settle-listing` returns t for only the first of
  answer / failure / timeout.  Without it, goose's late (never-arriving, in
  practice) answer could load a second session into a buffer already opening one.
* **A session that is already open is shown, not loaded twice.**  A
  `session/list` of the directory includes chats open in other windows, and the
  wire does not say so, so `agent-org--session-open-p` asks the registry for a
  *live* buffer holding the id (a dead buffer whose kill-hook has not run is not
  "open").  `agent-org--session-candidates` marks such a row with
  `agent-org--open-marker` — inside the title column, so the measuring pass
  includes it — and `agent-org--load-session` is the one choke point that turns
  the choice into `pop-to-buffer`: it sends no `session/load`, kills the
  half-open buffer (which shuts down the agent spawned for it), and says so in
  the echo area.  One ACP session id, one client: two buffers replaying the same
  history and both accepting prompts is not a shape worth supporting.
* **Degradation is always `session/new` plus an echo-area note** — never an error
  state, never a body line (§6).  Starting a chat must not be blocked by the
  feature that shows you the older ones.
* **Candidate labels are `TITLE  DATE  [id]`** (`agent-org--session-display`), with
  the date from `agent-org--format-session-date` ("Today, 14:02", "Yesterday, 09:11",
  "Sep 28, 10:22", "Sep 02, 2024").  Recency is `updatedAt`, falling back to
  `createdAt` (live goose omits `updatedAt`), and ISO-8601 sorts correctly as a
  string, so ordering is a `string>` on the stamp.  The id is always last because
  it is the part that actually selects.
* **The columns line up, and the order is pinned** — both because the list is
  scanned, not read.  `agent-org--session-candidates` makes a measuring pass
  (`agent-org--session-columns`) to take each column's widest value, then pads every
  row to it, so a 60-character qoder prompt does not push the dates out of a
  vertical line.  Titles are already capped by `agent-org-buffer--label-width`, so
  padding cannot widen the line beyond label + date + id.  Padding and measuring are
  both in **display columns** (`string-width`) — `string-pad` pads by character
  count, which puts a CJK title's date a dozen columns early.  The date and id
  columns are `shadow`-faced: they are metadata, and dimming them is what makes the
  title the thing you read.
* **A plain list collection would be re-sorted.**  `completing-read` accepts a
  function, and only a function can answer the `metadata` action — which is how
  `display-sort-function` reaches the UI (`agent-org--completion-collection`, same
  as agent-shell).  With `identity` the UI shows the list in the order we built it;
  without it, `New session` can land anywhere and the newest-first rule the pager
  worked for is lost at the last step.
* **Look the choice up by property-free text, not `assoc`**
  (`agent-org--selection-value`).  `assoc` compares with `equal`, `equal` on strings
  compares text properties, and the displays now carry `face` properties — so a
  completion framework that hands back a rebuilt string instead of the collection's
  own member would match nothing and silently resume the wrong chat.

Live against qoder in this directory: 38 sessions in one page (no `nextCursor`),
titles and `updatedAt`/`createdAt` stamps as the real wire sends them, and the
`Today, HH:MM` / `Yesterday, HH:MM` / `Mon DD, HH:MM` branches all appearing in
the candidates.  On a loaded machine (load average 16) a later listing on the
same kind of session never answered — the reason `agent-org-session-list-timeout`
exists.

---

## 11. A cancelled prompt cleans up, because nothing else will

`completing-read` signals `quit` on ESC / `C-g`.  At a session prompt that signal
is raised *inside an acp response callback*, and acp runs every callback under
`condition-case-unless-debug` — so an unguarded `quit` is **swallowed**: no error,
no backtrace, just a chat buffer parked on "Starting"/"Restoring" with a live
agent process behind it.

* Both prompt sites (`agent-org--choose-start`, `agent-org--resume-locate`) wrap
  the read in `agent-org--quit-cancels`, which calls `agent-org--cancel-open`:
  kill the buffer (the kill-hook of §9's release path shuts the agent down and
  unarms its timers) and say so in the echo area — the buffer that would show a
  header status is gone.
* **`nil` means cancelled.**  Both readers complete with `REQUIRE-MATCH`, so `nil`
  is not a possible answer; a caller that gets `nil` sends neither `session/new`
  nor `session/load`.
* Reuse the buffer instead of killing it only if a future command wants a
  "cancelled, keep the window" mode — that is a different decision, and it needs
  its own test.

---

## 12. Killing a chat buffer asks, because an agent is running

`acp` starts the agent with `:noquery t` and attaches no process buffer of its
own, so Emacs' `process-kill-buffer-query-function` finds nothing to ask about
and `kill-buffer` on a live chat is silent — on a machine where one stray
`qoder --acp` child costs ~100 MB.

* `agent-org--kill-query` joins `kill-buffer-query-functions` **buffer-locally**
  (installed beside the kill-hook by `agent-org--register-session`) and returns
  nil to abort the kill.  Its wording is Emacs' own, `Process %s is running;
  kill it? `, because that is the question the editor asks about a `*shell*`
  buffer and this is the same kind of thing: a child the user did not start by
  hand.
* Only a **live** process asks.  A crashed agent leaves a buffer that is merely
  unresponsive; consent for killing it is friction.  No session at all (a
  non-chat buffer, or a chat whose hook has already run) also answers yes, which
  is why the mock `acp-make-client` client carries no live `:process`.
* The query never releases anything.  A YES lets the kill proceed and
  `agent-org--forget-session` on `kill-buffer-hook` (§9) does the shutdown: one
  release path, already under test.
* Every kill agent-org performs **on its own** goes through
  `agent-org--kill-buffer-silently`, which binds `agent-org--inhibit-kill-query`:
  `agent-org--cancel-open`, `agent-org--show-open-instead`, and
  `agent-org-reload`.  Those run from inside acp response callbacks, where a
  prompt is a trap rather than a question — see §11.

---

## 13. A chat has one display label, and one row-builder for both lists

Two UIs name the same chats: the `agent-org-start` / `agent-org-resume-session`
chooser (sessions on the agent's disk) and `agent-org-switch-buffer` (sessions
with a live buffer).  They must look like one product, so the second reuses the
first's parts rather than writing its own:

| Job                            | Function                        |
|--------------------------------|---------------------------------|
| widest cell in a column        | `agent-org--column-width`       |
| left-align by DISPLAY columns  | `agent-org--pad`                |
| one padded, dimmed row         | `agent-org--session-display`    |
| pinned-order completion        | `agent-org--completion-collection` |
| resolve a choice safely        | `agent-org--selection-value`    |

* Measure the batch **before** painting any of it: `agent-org--chat-columns`
  returns unpadded `(LABEL . STATUS)` and only `agent-org--switch-candidates`
  knows the maxima to pad to.
* A row's value is the **buffer object**.  A name is what the agent renames, and
  resolving a row by name after the fact switches to nothing.
* A column is located by its `shadow` face transition, never by the spaces in
  front of it — padding and separator are both spaces, so a space search
  measures where the padding began.
* `agent-org-buffer--chat-label` (`<who>:<project>`, the provider standing in for
  a title that has not arrived) is the label in the buffer name **and** in the
  switcher's first column.  Adding a naming rule means editing that one
  function.
* It takes the status plist as an argument: the switcher labels other buffers,
  and `with-current-buffer` there is a function that can move point in a chat
  the user only meant to look at.

---

## 14. The session's Org file is a mirror, written at boundaries

`agent-org-transcribe` (default on) keeps one file per session in
`agent-org-transcript-directory`, named `<sanitized session id>.org`.  Its body
is the chat buffer's frozen body — `point-min` to `agent-org-buffer--render-end`
— so the transcript is the same document the user is reading, and the same
`:ID:` in its `PROPERTIES` drawer makes it an `id:`-linkable target.

* **The default directory is the project's own `.agent-org'.**  The option is
  a *relative* name, and `agent-org-buffer--transcript-file` resolves it with
  `expand-file-name` while the chat buffer is current — so `default-directory`
  is the session cwd and each project keeps its chats in its own
  `.agent-org/`, the way it keeps its own README.  An absolute setting expands
  to itself, so one global pool is a setting, not a code change.  Because the
  files now land inside a repo, `.agent-org/` belongs in that repo's
  `.gitignore` unless the transcripts are notes to commit (this repo does).
* **Mirror, never append log.** A tool call is one drawer line rewritten in
  place TODO→DOING→DONE (§3).  An append-only log can only add, so the file would
  keep every superseded state of every call — a different document from the
  chat that produced it.  Mirroring keeps one renderer, which is the same rule
  §9 states for replay: never add a second paint path.
* **Boundaries only, never the render path.** `agent-org-buffer-transcribe` is
  called by `agent-org--session-ready`, `agent-org--send-turn` (before the
  request, and in both callbacks), `agent-org-cancel-turn`,
  `agent-org--sync-title`, `agent-org--forget-session` and
  `agent-org--queue-refresh` — the last because a queued prompt that never
  reaches a turn boundary (the user quits Emacs mid-turn) is otherwise lost,
  and no other writer has ever seen it.  It is *not* called
  by `agent-org-buffer-append-chunk`, `--redraw-drawer` or `insert-tool`, so
  twenty chunks of an answer cost zero writes and a slow disk cannot stall a
  stream.  `test-agent-org-transcript-costs-writes-per-turn-not-per-chunk`
  pins that count at exactly 2.
* **A kill is a boundary too.** A turn in flight has no end coming, so
  `agent-org--forget-session` writes before `acp-shutdown`: without it the last
  answer of every session — the one the user stopped reading — is the one
  missing from the file.
* **The draft is not conversation.** `point-max` would include the live
  `* User` box and whatever is half-typed in it; `agent-org-buffer--render-end`
  excludes both, which is the same marker that keeps a streaming turn off the
  user's text (§11 of the buffer design).
* **The id is agent text, so it is sanitized.** Every character outside
  `[A-Za-z0-9._-]` becomes a dash (`agent-org-buffer--transcript-name`).  The
  id arrives over the wire and becomes a path; without this the writer is a
  path-traversal primitive handed to whatever server the user connects to.
* **A failed write is a note, not a broken turn.** `condition-case` on
  `file-error` → `message`, and the dedupe cache is left alone so the next
  boundary retries.
* `write-region`'s VISIT argument stays nil: a non-nil one would make the chat
  buffer *visit* its transcript, and then `C-x s` would save the live draft
  into it and auto-save would follow.

Measured on this machine (spinning disk, 4 GB RAM, `emacs -Q --batch`, one
boundary write of the whole mirror): 3 ms for a short chat, 6 ms at 20 turns
(21 KB), 9 ms at 50 turns (103 KB), 15 ms at 100 turns (407 KB); an unchanged
body is skipped in 0.02–3.4 ms.  The per-chunk append model this replaced costs
90–170 ms for the same 20 turns, spent inside the stream.

---

## 15. Markdown in a reply becomes Org structure

Agents answer in Markdown; the chat body is Org.  `agent-org-convert-markdown`
(default on) rewrites the reply's text — and the user's own echo — on the way
into the buffer, because the two syntaxes disagree in ways that are STRUCTURAL
in Org, not cosmetic.  Every claim below is what
`org-element-parse-buffer` reported for the unconverted bytes:

| Markdown as written | What Org makes of it | Consequence |
|---+---+---|
| `# Title` | an Org **comment** | the heading vanishes from every export |
| `* item` (bullet) | a **level-1 headline** | it cuts the turn in two, and joins the conversation's own `* User` / `* Agent` siblings |
| `---` under a paragraph | a **headline** | same, with no title |
| `\|:--\|--:\|` (Markdown's alignment rule) | an ordinary **data row** | the table loses its header, and `--:` even exports as an em-dash |
| `**bold**` | bold inside bold | `*bold*` is Org's one marker; two is nesting |

* **A heading is shifted ONE level down** (`#` → `**`, `###` → `*****`), never
  rewritten in place: level 1 in this buffer belongs to the conversation (§8),
  so a reply's `# Title` must nest inside its own turn, not become a sibling of
  it.  That keeps the transcript's outline honest — `C-c C-t TAB` on a chat still
  shows turns, not fragments of one answer.
* **One scan, not a chain of rewrites.** Converting `**b**` to `*b*` and then
  running the `*i*` rule over the *result* italicises the bold it just made.  So
  all inline forms live in one alternation
  (`agent-org-buffer--md-inline-regexp`) and one left-to-right pass consumes each
  match exactly once.
* **A `*` run has to prove it is emphasis.** Markdown's own rule: the opening
  delimiter may not be preceded by an alphanumeric, and the body may not begin or
  end in whitespace.  Without that check `2*3*4` becomes italics — which is a
  corruption of the reply, not a rendering of it.  A rejected match is emitted
  literally and the scan resumes one character later (re-reading the same position
  would loop forever).
* **A code fence is a state, so it threads line by line.** `agent-org-buffer`
  keeps it buffer-local and turn-local (`--md-src-p`): inside a block nothing is
  converted, because a shell sample full of `#` and `*` is code.  And an
  unterminated `#+begin_src` is always closed — by `--markdown-convert` for a
  whole message and by `--markdown-flush-here` at a boundary — because an open one
  swallows the rest of the buffer *and* the rest of the transcript file, and an
  agent that hit its token limit can send exactly that.
* **Streaming converts as the text arrives, and rewrites only the last line.**
  A chunk stops wherever the model's tokenizer stopped, so `**bold` can end one
  chunk and `**` open the next.  Holding the unfinished line until its newline
  (the first design) made a one-line reply — which usually never sends a newline
  — invisible until the turn ended, so the user watched an empty buffer while the
  agent answered.  Now every chunk is written, and the line still arriving is
  *provisional*: `agent-org-buffer--markdown-write` replaces the region from
  `--md-tail` to `--render-end` with the conversion of everything received so far
  in that line.  The rewrite is why a split construct reaches the buffer once, as
  markup, instead of first as stars.
* **A chunk that ends on a newline leaves nothing provisional.**  It is the
  common stop, not an edge case — a model emits `say this\n` and starts the next
  line in the following chunk.  `split-string` keeps the empty field after a
  trailing separator, so the completed line lands in `done` and the pending
  fragment is empty: nothing is stored to be concatenated without its newline.
  (Assumed otherwise during development, and measured otherwise: the fragment
  variable is never `("say this")`, which is what gluing two lines together
  would have needed.  Pinned by
  `test-agent-org-markdown-chunk-ending-with-newline-starts-a-new-line`.)
* **A provisional region must not outlive a boundary.**  `--md-tail` marks text
  the next chunk is allowed to delete.  Anything drawn after a boundary — a
  `:thinking:` drawer, the tool board, the end of the turn — is finished text, so
  `agent-org-buffer--markdown-flush-here` runs at each of those three sites: it
  ends the line, closes an open fence, and FORGETS the state.  Forgetting is
  load-bearing rather than tidy: a stale marker would put the next chunk's
  `delete-region` straight through the drawer.  So a paragraph may be split by a
  drawer (which is what the drawer is for), and nothing is ever rewritten twice.
* **The wire never changes.** The agent receives the Markdown the user typed; the
  conversion belongs to the rendering, never to the request.  Both sides of the
  exchange use the same rules, so one reply reads alike above and below its
  heading.
* **`_text_` and `~~text~~` are deliberately left alone.** In Org the underscore
  is emphasis only between non-word characters anyway, and rewriting it would eat
  `foo_bar_baz`; strikethrough reads as written and is purely cosmetic.  Numbered
  lists and `- [ ]` checkboxes need no rule — they already mean the same thing in
  both syntaxes — but inline code does: a backtick is not Org markup at all, so
  `` `code` `` becomes `=code=` like every other form.  That is why this converter
  is a handful of regexps rather than a parser.

Nil for `agent-org-convert-markdown` is the escape hatch: the agent's bytes land
verbatim, exactly as this package behaved before the option existed.  No test
depends on the conversion — the Markdown tests pin both directions, so the
default can be argued about without touching a renderer.

Cost, measured on this machine (spinning disk, 4 GB RAM, `emacs -Q --batch`,
`test-agent-org-markdown-conversion-cost-per-line`): 400 markup-DENSE lines
(`**bold** *emph* and `code` see [docs](...)`) in 42–55 ms, i.e. **~110 µs per
line**, and plain prose in 7 ms — **~17 µs per line**.  So a 50-line answer costs
about 2 ms once, a 2000-line replay about 230 ms inside the one synchronous pass a
replay already is, and the streaming path adds one small delete+insert per chunk.
That is the same order as the 3–15 ms a transcript boundary write costs (§14), and
it is paid per LINE, never per character.  Nothing here justifies defaulting the
switch off; if a future rule makes it expensive, the test's ceiling (1 s for 400
lines) fails first.

---

## Manual nodes referenced

* `(org) Headlines` — §2.1 structure, left margin, separator lines.
* `(org) Visibility Cycling` / `(org) Initial visibility` — §2.2.2,
  `#+STARTUP`, `VISIBILITY`.
* `(org) Drawers` — §2.7, "anything but a headline and another drawer".
* `(org) Properties and Columns` — the `PROPERTIES` drawer.
* `(org) Per-file keywords` — §5.2.5, column-0 `#+TODO:` line.
* `(org) Emphasis and Set Tags` — §15: the five markers, and what may or may not
  surround them.
* `(org) Plain Lists` / `(org) Tables` — §15: what a `-`/`1.`/`|` line has to
  look like to be read as one.

Keep this file honest: if you change how buffers are rendered, update the
rule here **and** the test that pins it.
