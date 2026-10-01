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
3. The conversation: alternating `* User` and `* Agent` level-1 headings,
   each Agent turn optionally carrying `**` tool headings and one
   `:thinking:` drawer.

```org
:PROPERTIES:
:Provider: goose
:Session: 01J...
:Mode:     auto
:Model:    claude-...
:Context:  12k/200k (6%)
:Cost:     $0.00
:END:

#+TITLE: Refactor the auth module
#+TODO: TODO DOING | DONE CANCELLED

:COMMANDS:
/goose — talk to the goose agent
:END:

* User

What does agent-org-buffer.el do?

* Agent
** TODO read_file [tc1]
** DONE write_file [tc2]
:thinking:
Let me look at the buffer first…
:END:
```

Nothing else may live in the body.  Status, progress and errors never
become text — see §6.

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

## 3. Tool calls are `** TODO` subheadings

Each ACP tool call renders as **one headline per `toolCallId`**, directly
under the current `* Agent` heading:

```org
** KEYWORD title [toolCallId]
```

`KEYWORD` maps the ACP `status` onto a per-file TODO set:

| ACP status    | Org keyword | meaning       |
|---------------|-------------|---------------|
| (nil/pending) | `TODO`      | queued        |
| `in_progress` | `DOING`     | running       |
| `completed`   | `DONE`      | finished ok   |
| `failed`      | `CANCELLED` | errored/aborted |

### Why headlines, not a `:tool:` drawer

The drawer spec is explicit — `info "(org) Drawers` (§2.7):

> They can contain anything **but a headline and another drawer**.

Tool calls *are* headline-shaped (a title + a state we want to cycle), so a
drawer could never legitimately hold them without breaking Org's own content
model.  Making them real subheadings means `C-c C-t` cycles their state, the
agenda could one day collect them, and `TAB` folds them like any other node —
all for free, using the manual's native machinery.

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

### In-place updates, never duplicates

`tool_call_update` for a known `toolCallId` **rewrites the existing heading
line** via its stored marker; it must never append a second heading for the
same call.  Markers are turn-local: `start-agent-turn` deactivates the
previous turn's tool markers, so a reused `toolCallId` (e.g. after `resume`)
creates a fresh heading under the *new* turn instead of reaching back into the
old one.

> Gotchas we've been bitten by, and pinned with tests:
> * `plist-put` returns the **plist**, not the value — never feed it to
>   `move-marker`; set the marker, then store it.
> * `mark` is nil unless the region is active; for bookkeeping markers read
>   `marker-buffer`/`marker-position` (helper `agent-org-buffer--live-mark`).

---

## 4. Extended thinking is a folded `:thinking:` drawer

Thinking text (not tool calls) accumulates in **one** `:thinking:` drawer per
Agent turn, updated in place.  This is the legitimate drawer use from
§2.7: plain content, no headlines inside.  Tool headings are kept *above* the
drawer within the turn so the foldable thought sits at the bottom.

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
   `* Agent` turns, `**` tool headings, the `:thinking:` drawer, and the one
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

One trap inside that rule: `agent-org-buffer--status-segment` renders exactly
**one** status string, and for `starting` and `ready` it renders the *state
label*, not the `:message`.  So `:message "something went mildly wrong"` is
silently invisible while the session is Ready.  A real failure must therefore
set `:state 'error` (which does show the message, as `Error: …`), and a
non-failure note that must not steal the Ready segment — e.g. a provider's
pinned model not being offered by the agent — goes to the echo area with
`message` instead.  Never invent a third channel, and never write to the body.

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
  Our levels: `*` = turn (User/Agent), `**` = tool call.  No deeper.
* **An empty line after a subtree is part of it** and is hidden when the
  subtree folds; two or more empty lines leave one visible separator.  Our
  `agent-org-buffer--separator` inserts exactly the one blank line that keeps
  a freshly appended heading from abutting prior text — matching this rule so
  the collapsed view stays structured.

---

## 9. Resume replay — buffer it, then paint once

`agent-org-resume-session` replays a session's history into a fresh buffer.  Restored
turns are laid out **exactly** like typed ones (`* User`, `* Agent`, `**` tool
headings, `:thinking:` drawer), because the replay feeds the same
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

Anything the agent *names* is free text, and it arrives as such.  A live qoder
session titled its tool calls with the whole shell command (one title was
`which agent-shell-list ... ; echo "---"; emacsclient ...` across a dozen
lines), and a resume `session/list` returned the entire first prompt as a
session's `title`.  Verbatim, that is fatal to a heading: only the first line
becomes the `**` heading, the rest falls into the body, and the in-place
rewrite of a heading replaces a single line — so three of four replayed tool
calls vanished from the buffer entirely.  `agent-org-buffer--label` therefore
collapses whitespace runs and truncates to `agent-org-buffer--label-width`
before any agent text reaches a one-line context: tool headings (`** KEYWORD
title [id]`) and resume candidates alike, always with the id kept visible
because the id is what identifies the thing.

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
* **Degradation is always `session/new` plus an echo-area note** — never an error
  state, never a body line (§6).  Starting a chat must not be blocked by the
  feature that shows you the older ones.
* **Candidate labels are `TITLE  DATE  [id]`** (`agent-org--session-display`), with
  the date from `agent-org--format-session-date` ("Today, 14:02", "Yesterday, 09:11",
  "Sep 28, 10:22", "Sep 02, 2024").  Recency is `updatedAt`, falling back to
  `createdAt` (live goose omits `updatedAt`), and ISO-8601 sorts correctly as a
  string, so ordering is a `string>` on the stamp.  The id is always last because
  it is the part that actually selects.

Live against qoder in this directory: 38 sessions in one page (no `nextCursor`),
titles and `updatedAt`/`createdAt` stamps as the real wire sends them, and the
`Today, HH:MM` / `Yesterday, HH:MM` / `Mon DD, HH:MM` branches all appearing in
the candidates.  On a loaded machine (load average 16) a later listing on the
same kind of session never answered — the reason `agent-org-session-list-timeout`
exists.

---

## Manual nodes referenced

* `(org) Headlines` — §2.1 structure, left margin, separator lines.
* `(org) Visibility Cycling` / `(org) Initial visibility` — §2.2.2,
  `#+STARTUP`, `VISIBILITY`.
* `(org) Drawers` — §2.7, "anything but a headline and another drawer".
* `(org) Properties and Columns` — the `PROPERTIES` drawer.
* `(org) Per-file keywords` — §5.2.5, column-0 `#+TODO:` line.

Keep this file honest: if you change how buffers are rendered, update the
rule here **and** the test that pins it.
