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

## Manual nodes referenced

* `(org) Headlines` — §2.1 structure, left margin, separator lines.
* `(org) Visibility Cycling` / `(org) Initial visibility` — §2.2.2,
  `#+STARTUP`, `VISIBILITY`.
* `(org) Drawers` — §2.7, "anything but a headline and another drawer".
* `(org) Properties and Columns` — the `PROPERTIES` drawer.
* `(org) Per-file keywords` — §5.2.5, column-0 `#+TODO:` line.

Keep this file honest: if you change how buffers are rendered, update the
rule here **and** the test that pins it.
