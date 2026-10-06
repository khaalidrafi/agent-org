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
3. The conversation: **one exchange per prompt-response pair**, each exchange
   ONE level-1 heading whose text is the prompt, the answer under it inside an
   Org `quote` block preceded by `#+ATTR_TEXINFO: :author <model>` (see the
   exchange rule below).  The exchange carries a `:thinking:` drawer of the
   reasoning and ONE `:tool:` drawer whose items are its tool calls —
   `  - KEYWORD title`, with what that call printed as the item's body, four
   columns in (see §3).  Both drawers sit BELOW the quote: the drawer is the
   tool half of the activity, and the quote is the answer, which is what the
   separation is *for*.  The persistent `* User` type-ahead box stays at the
   end of the buffer (§7); it is where the next prompt is typed, not an
   exchange.

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
#+TODO: TODO ONGOING | COMPLETE FAILED

:COMMANDS:
/goose — talk to the goose agent
:END:

:QUEUE:
- ask about the tests\nfirst
:END:

* Refactor the auth module

 and keep the tests green

#+ATTR_TEXINFO: :author Claude Sonnet
#+begin_quote
 The parser is *line* based:

 - one rule per line
#+end_quote

:thinking:
 Let me look at the buffer first…
:end:

:tool:
  - TODO read_file
  - COMPLETE write_file
    + def login(user):
:end:

* User

```

Nothing else may live in the body.  Status, progress and errors never
become text — see §6.

**One heading per exchange, and the heading IS the prompt** — the user's order:
*"From now on, there will be ONE heading for each prompt-response pair.  The
heading will contain the prompt.  And, the response should be contained in an Org
quote block, with the narrator/author as the model name."*  So `agent-org-buffer-begin-exchange`
writes the prompt as the heading (its first line after the `* `, every later line
indented ONE space so it stays the heading's own affixed metadata rather than a
second paragraph), and the answer arrives inside `#+begin_quote`.  Attribution is
the keyword line above the block, `#+ATTR_TEXINFO: :author <model>`, which is Org's
own way to name the speaker of a quotation (`info "(org) Quotations in Texinfo
export"`): Texinfo export renders it as an `@author` on the `quote` environment.
HTML and LaTeX export ignore an author on a quotation in Org 9.7, so the line is
also plain-readable in the buffer itself — which is where a chat is actually read.
The model name comes from the buffer status (label, else wire id) exactly as the
header line's model segment does, flattened by `agent-org-buffer--label` because a
config option's `name` is agent free text and a newline on a keyword line would
split it in two.

Three consequences are load-bearing, and each is a test:

* **A turn with no answer text gets no quote.**  A tool-only turn is a heading,
  its drawers, and nothing else — `agent-org-buffer--drop-empty-quote` removes the
  `:author`/`#+begin_quote`/`#+end_quote` furniture when the agent never wrote a
  word, because an empty quote is a block a reader has to open to discover
  there is nothing in it.
* **A heading of ANY level ends a quote block**, so a Markdown `# Heading` in a
  reply cannot keep its size here (it becomes bold — §15), and any `*` the agent
  or a shell result puts at column 0 is indented one space before it lands in the
  body (§16).
* **Nothing locates a turn by heading text.**  Placement is the turn anchor and
  `agent-org-buffer--render-end`; the quote's closer is a rear-advancing marker
  (`agent-org-buffer--quote-end`) so every chunk, drawer repaint and flush inserts
  ABOVE `#+end_quote` and the block stays shut at every instant of the stream.

**The buffer is named for its session**: `<agent>:<project> [<session id>]`, with no
`agent-org: ` prefix and no `*…*` delimiters.  `C-x b` and any switcher list names,
and a bare `Qoder` tells someone with three qoder chats open nothing — nor does one
name tell them which of two projects it is a chat OF.  So the agent leads, because
that is what a person scans for, and the last directory
component of the session cwd follows the colon, in the `file:directory` idiom
Emacs users already read.  **The session title is not in the name** — the user's
report was exactly that: *"Buffer names are showing session names in place of agent
names."*  A title says what a chat is ABOUT, arrives late, and changes on its own
(`session_info_update`), so a name built from it mutates under a person reading the
buffer list; the title is the buffer's `#+TITLE:` and its transcript's, and the
resume chooser shows it from `session/list`.  The id is omitted until the agent
gives one; the project is there from creation, so even the handshake name
(`goose:myproj`) places the buffer.  Both name facts come from
`agent-org-buffer--wanted-name`, whose `<agent>:<project>` part is
`agent-org-buffer--chat-label` — the same function `agent-org-switch-buffer`
builds its first column from, so one chat has one name in every list (§13);
after creation the name is applied by
`agent-org-buffer-set-status`, on the updates that carry `:session-id`: the
provider and the `:project` are fixed when the buffer is created, so the id is the
only half of a name that arrives later, and a per-chunk usage or title update
builds no string and renames nothing.  The equality guard in
`agent-org-buffer--apply-name` exists because
`generate-new-buffer-name` counts *this* buffer, so renaming on every
update walks a session through `Qoder:agent-org [s]<2><3><4>`.
Nothing agent-supplied reaches the name any more, so
`agent-org-buffer--label` is a `#+TITLE:`, quote-author and header-line
concern, not a buffer one.  `agent-org-buffer-create` does give its buffer one internal
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

The block is folded by default — with one exception, decided per kind.  Per
`info "(org) Initial visibility` (§2.2.2), first-visit folding is normally
driven by `#+STARTUP:` — but these buffers are created programmatically and
never "visited", so we fold the drawers directly (see §5) rather than relying
on a startup line, and `agent-org-buffer--metadata-open-drawers` is the list
of kinds that arrive UNFOLDED.  Today that is QUEUE: a queue that appears in
the middle of a turn is news, and folded it is invisible exactly when it
matters.  A drawer the user folded by hand stays folded — the list is a
default for creation, never an instruction to every repaint.

**`:QUEUE:` is the one volatile drawer, and it comes last.**  COMMANDS, MODES
and CONFIG are reference the agent advertised once; QUEUE holds the prompts
the user sent into a busy session — text that is neither reference nor
conversation yet, because a queued prompt gets its exchange heading only when
it drains.  It belongs to the block because the block is inside the range the
transcript mirrors (§14), and a prompt the agent has never seen is the one
thing its `session/load` replay cannot give back.  One escaped line per
prompt, oldest first (`agent-org-buffer--queue-encode`: newline and backslash
flattened, `- ` prefixed so a prompt that *is* `:END:` cannot close its own
drawer); an empty queue renders **no** drawer, because that absence is what
stops a resume re-sending a prompt that already went out.  It is also the only
drawer with no line cap (§17), and editing it is `agent-org-queue-edit`'s job
in a buffer of its own — never typing inside this drawer (§17).

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
`refresh-metadata`.  The title is the chat's topic and lives in the document;
it is never the buffer's name (§1).

---

## 3. Tool calls are items of a `:tool:` drawer

Each ACP tool call renders as **one item per `toolCallId`**, inside the exchange's
`:tool:` drawer (which sits below its quote block, see §1):

```org
:tool:
  - KEYWORD title
    what the call printed
:end:
```

The `toolCallId` is *not* in the line — it is the agent's bookkeeping, and the
turn's `agent-org-buffer--tools` alist already owns the call, so every update
redraws the whole drawer from that list rather than hunting for a marker.
Neither is a number: `N.` used to prefix the title as the index into a
per-call output drawer (§3.1), and one item per call needs no index — a call
is found by the title written on its own line.  This
is the user's order: *"No need to add numbers to tool drawers.  Consecutive
tool calls belong to a single drawer."*  Then, on the bodies: *"Tool call
outputs belong to the same TODO headings."*

`KEYWORD` maps the ACP `status` onto a per-file TODO set, in the words the
user asked for:

| ACP status    | Org keyword | meaning         |
|---------------|-------------|-----------------|
| (nil/pending) | `TODO`      | queued          |
| `in_progress` | `ONGOING`   | running         |
| `completed`   | `COMPLETE`  | finished ok     |
| `failed`      | `FAILED`    | errored/aborted |

### Why a drawer item, not a `**` headline

The drawer spec is the reason a call *cannot* be a heading inside a drawer —
`info "(org) Drawers` (§2.7):

> They can contain anything **but a headline and another drawer**.

The first version of this file therefore put calls in `**` headings *above* the
`:thinking:` drawer, and paid twice for it: one marker per call plus a
locate-by-search helper, and a class of bugs where a headline landed at the
drawer's `match-end` — i.e. inside its body — so `agent-org-buffer--redraw-drawer`'s
next wholesale rewrite (every thought chunk) erased every call except the turn's
last one, silently.  Live qoder replayed four tool calls and the buffer showed one.

As items of their own drawer, calls and thoughts are drawn by ONE primitive, the
ordering trap cannot recur, and each kind gets its own fold: the `:tool:` drawer is
OPEN (what the agent is doing right now is what the user came to watch) and the
`:thinking:` drawer folded (raw reasoning is not the point of the turn).  The FOLD
argument of `agent-org-buffer--redraw-drawer` is that drawer's **default**, not a
one-time instruction: a folded-default drawer keeps whatever fold it is in (one the
user opened stays open), while the open-default board is left open by every paint —
Org re-hides drawers on paths no variable guards, and a board that stayed collapsed
after that would hide the agent's next action.  `agent-org-mode` therefore also sets
`org-hide-drawer-startup` nil buffer-locally: Org's own startup visibility ends with
a call that folds every drawer in the buffer (`org-cycle.el:643`).  The board's
INDENT is itself measured: §3.1.

What the headline shape bought is partly given back: a keyword on a drawer line is
**text**, not an Org TODO state, so `C-c C-t` does not cycle it (`org-toggle-todo`
acts on headlines, and a line in a drawer is not one).  The per-file `#+TODO:` line
stays for that same reason reversed — it names the only state a reader of a
transcript or a chat can see for a call, and a file whose heading vocabulary is
declared is a file Org parses the way it looks.

### 3.1 What a call printed: the SAME item's body

Every call that printed gets its output under its own board line, four columns
in, as the contents of that item — one drawer holds the state and the result of
every call of the turn, in the order the agent made them:

```org
:tool:
  - COMPLETE ls -R
    agent-org.el
    TODOs.org
  - ONGOING grep -rn foo
    * a heading
    ::END:
    plain
:end:
```

This is the shape the user asked for twice: *"Consecutive tool calls belong to a
single drawer.  :tool: drawers are only to separate from responses"*, then
*"Tool call outputs belong to the same TODO headings."*  The first cut answered
that with a second, folded `:tool-output:` drawer, and it cost more than it
saved: a reader scanned the board, then hunted the same title again below it,
and one call's state and its result sat in two folds that could be opened
against each other.

**Why the list sits at two columns and its body at four** — nothing here is
aesthetic, and nothing in a drawer body may sit at column 0 (§3.2):
`org-element-parse-buffer`, run on a buffer that already has the turn's
heading, reports **no list at all** for an item at column 0 with a body at two
columns (a drawer of loose text), and **one `plain-list` of N items, the drawer
intact and the turn's single heading untouched** for the indented form
(`test-agent-org-tool-drawer-is-one-list-to-org`).  A body at two columns would
also be a sibling `- ` item, i.e. a second call that never ran.

The trade is accepted, not hidden: one drawer has **one fold state**, so bodies
now travel with the open board instead of staying collapsed the way agent-shell
ships it (`agent-shell-tool-use-expand-by-default` nil).  TAB on the turn folds
calls and output in one motion, which is also why nothing needs truncating.

The extraction (`agent-org-buffer--tool-output`) is agent-shell's rule, in its
order: the `content` blocks, else `rawOutput.formatted_output` **only when it is
a string** (Codex reports terminal output that way and leaves `content` empty),
else nothing.  A block type we cannot render is *named*, `[unsupported content:
TYPE]`, never silently dropped.  Diff and tool-call updates arrive through the
same path, so a completed call shows what it printed and a still-running one
shows what it printed so far.  Nothing is truncated: folding is the affordance,
and a record that quietly lost its middle is worse than a long one.  A call with
no output gets **no body lines** — one line and no blank indent.

`agent-org-buffer--tools-shown` is the whole rendered board as last painted, so a
status-only update that changes nothing costs no redraw.  It used to be a `:shown`
field on each entry, which stopped meaning anything once the bodies shared the
drawer: the drawer is redrawn as one string, and a per-entry guard could not stop
a rewrite of every byte the turn ever printed.  Measured (Celeron,
`test-agent-org-one-drawer-board-redraw-cost`): 20 calls of 40
lines each cost ~140-340 ms for the turn, ~7-16 ms per redraw of the growing
800-line body — a busy machine prints more, so re-measure rather than quoting.
If a real session outgrows that, the drawer grows append-only instead, in
`agent-org-buffer--tool-board-body`.

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
stream writes — `:thinking:` and `:tool:` alike:

* every line gets **one space of indent** (a headline must start at column 0);
* a bare END line additionally gets a **doubled colon**, ` ::END:`, which is not
  the marker and still reads as the text it is;
* blank lines stay blank (they are legal inside a drawer, and dropping them would
  flatten the output's own shape).

A tool body takes **three further spaces** on top of the guard's one, which is
what makes it the contents of its `  - KEYWORD title` item rather than loose
drawer text (§3.1); its escapes therefore appear as `    * …` and `    ::END:`.

### 3.3 A quote body has the same problem, with one more shape

The answer's `#+begin_quote` block (§1) is guarded by
`agent-org-buffer--block-safe-lines`, which takes the drawer guard's indent rule
and adds the one thing that only a quote can trip over: **an agent that prints
`#+end_quote` at column 0 closes the block early**, and everything after it leaves
its own answer — which an agent quoting Org syntax, or a shell result that cat'ed
this package's own source, does routinely.  So a line that is exactly a block
closer is wrapped as verbatim (`=#+end_quote=`), which reads as the text it is and
is not markup.  The indent is load-bearing for the same reason as in a drawer: the
first character of every body line is ours, never the agent's.

The guard is not a nicety.  Measured with `org-element-parse-buffer' on the
exchange, counting what the parser really made (the same three cases the test
suite replays):

| Body line as the agent wrote it | Unguarded | Guarded |
|---+---+---|
| `* bullet answer` at column 0 | **0** quote-blocks, 2 headlines | 1 quote-block, 0 paragraphs outside it |
| `#+end_quote` mid-body | the block closes there: 1 paragraph escapes it | 0 escape (`=#+end_quote=`) |
| `#+begin_src sh` … `#+end_src` | a `src-block` INSIDE the quote | the same, indented — nesting is legal |

The first row is the one that decides the design: with the guard off, the answer
has no block at all, so it has no author line either — the attribution §1 exists
to write is silently thrown away with the quotation that carried it.  The third
row is why indenting is cheap: a source block nested in a quotation is legal Org
(info "(org) Example blocks"), so converted code samples survive the guard.

### The per-file keyword line

We do **not** touch the global `org-todo-keywords`.  Instead the metadata
block carries (column 0):

```org
#+TODO: TODO ONGOING | COMPLETE FAILED
```

Per `info "(org) Per-file keywords` (§5.2.5):

> For file-local settings, you need to add special lines to the file which
> set the keywords and interpretation for **that file only**… starting in
> column zero anywhere in the file.

The `|` separates not-done states (`TODO`, `ONGOING`) from done states
(`COMPLETE`, `FAILED`).  We apply the line with `org-set-regexps-and-options`
at buffer creation and after each metadata rewrite — this is the programmatic
equivalent of the `C-c C-c` the manual tells an interactive user to press
after editing the line.  `org-todo-keywords-1` becomes buffer-local; the global
default is left untouched (asserted in the test suite).

The set is still declared even though a call is now a drawer ITEM, where its
keyword is text rather than an Org state: the line the user reads is the record
of what a call is doing, and a file that names its own vocabulary explains that
record without the reader having to know this package.  The words themselves are
the user's (`"use ONGOING|COMPLETE|FAILED keywords for tool call TODOs"`), and
`COMPLETE`/`FAILED` both sit after the bar because a call that finished badly is
still finished — neither is the `CANCELLED` a person cycles to on purpose.

### In-place updates, never duplicates

`tool_call_update` for a known `toolCallId` **redraws the turn's `:tool:` drawer
from `agent-org-buffer--tools`**, so the call's item changes state in place and a
second item for the same call can never appear — the alist is the only place a
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

Thinking text accumulates in **one** `:thinking:` drawer per exchange, updated
in place, BELOW that exchange's quote block (§1).  This is the legitimate drawer
use from §2.7: plain content, no
headlines inside — but thinking is markdown-flavoured prose, so a `* ` bullet in
it is a headline to Org; its body goes through the same
`agent-org-buffer--drawer-safe-lines` guard as a tool output (§3.2).  A tool call is an item of a SEPARATE `:tool:` drawer (§3), so
the two kinds of agent activity each get their own fold — the thought folded by
default, the calls and their output open by default (§5) — and neither can erase
the other, because
`agent-org-buffer--redraw-drawer` searches for its own `^:NAME:$` bounded by the
turn.  Drawer order within a turn is arrival order: whichever of the two the
agent produced first is drawn first.

---

## 5. Folding

Fold state is driven **directly** with `org-fold-region`, never
`org-fold-hide-drawer-toggle`.  Reason (documented in our source, discovered
the hard way): `org-fold-hide-drawer-toggle` validates the `org-element` cache
before it acts, and while a turn streams that cache is stale — the drawer lines
are rewritten underneath it by the render path — so it signals
`"Not at a drawer"` and the fold silently does not happen.  `org-fold-region`
works on positions alone and is safe on the hot path.

A drawer the user manually opened stays open across updates: we detect
`invisible-p` on the body, unfold → swap → refold, preserving intent.  That is
the rule for a drawer whose **default** is folded (`:thinking:`, and the
metadata drawers).  A drawer whose default is open — the `:tool:` board — is
left open by every paint, because a fold Org's machinery puts on it is not the
user's intent: `org-mode`'s startup visibility, the prefixed global cycle and
`org-clean-visibility-after-subtree-move` all re-hide every drawer in the
region, one of them behind a variable and two of them behind nothing.  So
`agent-org-mode` sets `org-hide-drawer-startup` nil **buffer-locally** (the
variable is an alias of `org-cycle-hide-drawer-startup`, and `setq-local`
follows an alias to its target), and `agent-org-buffer--redraw-drawer` takes
FOLD as the drawer's default rather than as a one-time instruction at creation.
Your own `TAB` on a finished turn still folds calls and output together and
stays folded — nothing repaints a turn that has stopped.

The unfold before a swap is guarded by `invisible-p`, not unconditional:
`org-fold-region` walks the region it is given, and calling it on an
already-open board of a heavy turn more than doubled the per-paint cost (the
number `test-agent-org-one-drawer-board-redraw-cost` prints).

---

## 6. All feedback goes to the header line — never the mode line, never the body

Two hard rules, both from `AGENTS.md` and enforced by tests:

1. **Body stays pure conversation.**  No status messages, comment blocks, or
   bullet lines are ever inserted as content.  The body holds only the
   exchanges — a prompt's heading, its attributed quote block, that turn's
   `:thinking:` and `:tool:` drawers — the `* User` type-ahead box, and the one
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
  Our levels: `*` = one exchange — the prompt itself is the heading text —
  plus the `* User`
  type-ahead box, and NOTHING else.  A reply never contributes a headline: the
  answer is a quote block (§1) and a Markdown heading inside one becomes bold
  (§15), because a headline of any level would end the block.  A tool call is a
  drawer line, not a heading (§3).  Directly under the heading sit its response
  clock drawers (§22) — a `:PROPERTIES:` and a `:LOGBOOK:`, which are part of the
  exchange, never a headline of their own.
* **An empty line after a subtree is part of it** and is hidden when the
  subtree folds; two or more empty lines leave one visible separator.  Our
  `agent-org-buffer--separator` inserts exactly the one blank line that keeps
  a freshly appended heading from abutting prior text — matching this rule so
  the collapsed view stays structured.

---

## 9. Resume replay — buffer it, then paint once

`agent-org-resume-session` replays a session's history into a fresh buffer.  Restored
turns are laid out **exactly** like typed ones (the prompt's heading, the
`:author` line and quote block, the `:thinking:` and `:tool:` drawers), because
the replay feeds the same
`agent-org-buffer-*` primitives through `agent-org--buffer-update`.  Nothing
about resume gets a private renderer.

The contract that keeps it cheap on a slow machine:

* Conversational updates (`agent-org--replay-kinds`) arriving while
  `:loading` is set are **buffered**, never painted.  Every render site rewrites
  a whole drawer and re-protects its region, so painting per chunk would redo
  that work hundreds of times for history nobody can read until the pass ends.
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
* **It does not switch `font-lock-mode` off for that pass.**  The bulk-paint
  intuition is wrong here, because the restore is not symmetric: the OFF works
  anywhere, but `(font-lock-mode 1)` in a buffer no window is showing does
  nothing at all (§16), and a resume very often paints into exactly such a
  buffer.  Suppress-and-restore therefore *permanently* removed a chat's
  colours — the user's second "colors gone again!" — and an update raising
  mid-paint removed them even from a shown buffer, silently, since acp swallows
  errors in its response callbacks.  The paint now only `font-lock-flush`es
  afterwards, inside the `unwind-protect` that also stops the progress
  reporter.
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
context: tool board lines (`  - KEYWORD title`), chat buffer names and resume
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
* `agent-org-buffer--chat-label` (`<agent>:<project>` — the provider and the
  project, never the session title) is the label in the buffer name **and** in
  the switcher's first column.  Adding a naming rule means editing that one
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
* **Mirror, never append log.** A tool call is one drawer ITEM rewritten in
  place TODO→ONGOING→COMPLETE (§3).  An append-only log can only add, so the file would
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
| `* item` (bullet) | a **level-1 headline** | it ends the answer's quote block and becomes a sibling of the exchange headings |
| `---` under a paragraph | a **headline** | same, with no title |
| `\|:--\|--:\|` (Markdown's alignment rule) | an ordinary **data row** | the table loses its header, and `--:` even exports as an em-dash |
| `**bold**` | bold inside bold | `*bold*` is Org's one marker; two is nesting |

* **A Markdown heading becomes a BOLD line, never an Org headline** (`# Title` →
  `*Title*`).  It used to be shifted one level down (`#` → `**`), and that is the
  shape this document described until the exchange rule (§1) put the answer inside
  a quote block: **a headline of ANY level ends a quote block**, so a reply's own
  heading — at any level — would cut the rest of the answer out of its own block
  and out of its attribution.  There is no level below one that is not still a
  headline, so the words are kept and the size is lost, which is the least
  damaging reading of a heading that cannot exist here.  `*Title*` with no space
  after the star is emphasis and never a headline (info "(org) Headlines": stars
  must be followed by whitespace) — which is why the stars hug the text.
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
`test-agent-org-markdown-conversion-cost-per-line` — the test PRINTS the number
and the box's load moves it by 3x, so treat these as a band, not a constant):
400 markup-DENSE lines (`**bold** *emph* and `code` see [docs](...)`) in 42–141
ms, i.e. **~110–350 µs per line**, and plain prose in 7–23 ms — **~17–58 µs per
line**.  A real answer is mostly plain prose, so a 50-line reply costs a few ms
once; 2000 lines — a full replay — costs well under a second inside the one
synchronous pass a replay already is, and the streaming path adds one small
delete+insert per chunk.
That is the same order as the 3–15 ms a transcript boundary write costs (§14), and
it is paid per LINE, never per character.  Nothing here justifies defaulting the
switch off; if a future rule makes it expensive, the test's ceiling (1 s for 400
lines) fails first.

---

## 16. Org colours: a chat buffer asks for them when it is SHOWN

`font-lock-mode` cannot be enabled in a buffer no window is showing.  This is
not a theory, it was measured in the live session: `(font-lock-mode 1)` in a
hidden buffer leaves the buffer-local variable `nil` — no error, no warning, no
trace — and `turn-on-font-lock` does the same, while in a buffer that IS
displayed the very same call sticks and the colors appear.

Everything follows from that asymmetry:

* **A chat buffer is born hidden.**  `agent-org-buffer-create` runs inside an
  acp handshake callback, before any window shows it, so nothing at creation
  can give it colors — not `org-mode`, not the ambient `global-font-lock-mode`,
  which only acts when a buffer is created or displayed.  Hence
  `agent-org-mode` adds `agent-org-buffer--ensure-font-lock` to the
  **buffer-local** `window-configuration-change-hook` (the 4th argument, `t`,
  so the entry dies with the chat and is removed when the mode is turned off).
  Emacs runs that hook with the buffer current when it first appears in a
  window: the earliest moment the request can succeed.
* **The hook is an `unless`, not a toggle.**  It re-runs on *every* window
  change, and a repeat `(font-lock-mode 1)` would tear down and rebuild
  jit-lock over a transcript that can be thousands of lines long, for nothing.
* **No render path may switch font-lock off** to "save" time — see §9.  An OFF
  is restorable and an ON is not, so suppression is a one-way door whenever
  the paint happens to land in the background.
* **Batch Emacs is the hidden case forever**, so no test may assert that
  enabling works or check a face.  They stub `font-lock-mode`/`font-lock-flush`
  and pin the *calls*: `test-agent-org-replay-never-touches-font-lock-even-when-the-paint-errors`
  (the paint must not call `font-lock-mode` at all, not even to restore it) and
  `test-agent-org-chat-buffer-asks-for-font-lock-when-displayed` (the
  buffer-local hook is installed, and running it is what asks).

---

## 17. The prompt queue: one region, in the chat, text-not-position

A queue of prompts is a LIST, and the only interesting thing about a list of
things you are about to say is its ORDER.  The first port had three commands
and none of them could reorder: `agent-org-queue-view` printed a read-only
listing in a hidden buffer, `agent-org-queue-remove` picked a number in the
minibuffer, and `agent-org-queue-edit` re-read the LAST entry only through
`read-string`.  All three were the same list seen three ways.  Then it was ONE
command in ONE other buffer, and now it is one region in the chat itself (§20
for its shape): `agent-org-queue-edit` on `C-c C-q` puts point on the
`entries, `agent-org-queue-apply` writes them back, and there is nothing to
switch to.  One action, one name in `M-x`, same rule as §10.

* **Reconciliation is by TEXT, never by position.**  `agent-org--queue-note`
  records what the agent SENT and what arrived QUEUED while the user was
  editing, and `agent-org-queue-apply` drops the first and appends the second.
  By position it is wrong twice over: the drain takes the front of the
  SESSION's list while the user may have moved that entry anywhere, so an
  entry moved up would be dropped from the wrong place and an edited prompt
  would be lost.  An entry the user edited AFTER it went out is the one case
  that does get sent again — the agent never saw those words.

* **Apply is the only writer.**  A queue a person is rearranging must not
  change under his hands, and a transcript must never claim a prompt the agent
  was not sent.  So the drawer in the metadata block and the file's copy are
  regenerated from the SESSION (§20), never from the region, and an unapplied
  edit is invisible to both until it is applied.

* **Entry grammar.**  Headline `* NEXT <first line>` / `* WAIT <first line>`,
  with the rest of the prompt on the lines below, EVERY line indented by one
  space (`agent-org-buffer--queue-entry` with `--queue-text`'s dedent as its
  exact inverse).  The indent is not decoration: a prompt is the user's own
  words, those words can be an Org document, and a `*` at column 0 is a
  headline — which would cut one prompt into two entries and send half of each.
  Blank lines are kept (they are the user's), which is why the split keeps the
  empty strings.

* **A blank entry is a slot, and is dropped.**  `C-c C-a` appends one
  `* WAIT` slot and lands point in it: "add a prompt" and "write down the next
  thing to ask" are the same gesture here.  `agent-org-buffer-queue-parse`
  drops an entry whose text is blank, because `agent-org-send` refuses an empty
  draft and the queue must not smuggle one through by leaving a heading bare.

* **The header count, the entries, the drawer and the file are one list.**
  `agent-org--queue-refresh` drives all four from
  `(plist-get session :pending-prompts)`, and the mirror is written THERE rather
  than left for a turn boundary: a queued prompt that never reaches a boundary
  — the user quits Emacs, the agent dies, the machine loses power — is exactly
  the text they would most want back, and no other writer has ever seen it.

* **The queue survives a failed turn.**  `agent-org--drain-queue` is reached
  only from a successful turn end (`agent-org--send-turn`'s failure callback
  never drains), so a broken agent is not hammered and the queue survives for
  the user to inspect — as does `agent-org-cancel-turn`'s.

* **Resume restores the queue and sends the first prompt.**  A queued prompt
  was never sent, so it is in no `session/load` replay, in no `* User` heading
  and in no agent memory: the transcript's `:QUEUE:` drawer is its only
  surviving copy.  `agent-org--finish-replay` reads it BEFORE the replay paints
  (the paint mirrors the buffer, and a replayed buffer carries no queue) and
  applies it AFTER `agent-org--session-ready` (a drained prompt needs an
  interactive session: id set, box open, `:loading` gone).  An empty queue
  restores nothing, which is what stops a drained prompt being sent twice.

## 18. What the client tells the agent about the connection

An agent has no reliable view of its own connection.  Asked "which model are
you?" it answers from the default baked into its system prompt, which is a
lie the moment this client selected another model through
`session/set_config_option` — the ordinary case for MiniMax served by
OpenCode — and a session id is a value only the client ever holds.  So every
prompt is TWO ACP text blocks: what the person typed, then the client's three
facts.

* **The user's block is first, and verbatim.**  `agent-org--make-content-blocks`
  is unchanged; `agent-org--prompt-blocks` appends beside it.  This is the one
  place agent-org adds anything to a request, and it adds rather than rewrites,
  so an agent quoting the question quotes the person, and every existing reader
  of "the first block" — here and in the agent — stays honest.
* **One send site, so a drained prompt is not a special case.**  The block is
  built in `agent-org--send-turn`, which is the choke point for a typed prompt
  and for one released by `agent-org--drain-queue`.  Building it in
  `agent-org-send` instead would put the facts on the first question of a
  session and never again — the turn a re-ordered queue makes most different.
* **Rebuilt per turn.**  `C-c C-m` between two questions is normal, and a block
  computed at session start would tell the agent a model that stopped being
  true turn one ago, which is worse than saying nothing.
* **A fact the client does not know is ABSENT, never `nil`.**  Goose advertises
  no `configOptions` of this shape; a `model: nil` line is an agent told
  something false.  The block still goes out with the other two facts.
* **One line per value, and nothing truncated.**  A model's label comes from the
  agent's own `configOptions` and is agent text, so §12's standing rule applies:
  never trust a harness label to be short or single-line.
  `agent-org--context-field` is `agent-org-buffer--label`'s whitespace collapse
  WITHOUT its 60-column cut — this string is never displayed, and half a model
  name on the wire is the lie the block exists to prevent.
* **Both spellings, always.**  `agent: Qoder (qoder)` and
  `model: MiniMax M3 (minimax/MiniMax-M3)`: the label is what a person reads and
  an agent quotes, the id is what a commit trailer or a config request needs, and
  neither derives from the other.  One value is written once, so a line never
  reads `model: QModel (QModel)`.
* **Delimited, and labelled as the client's.**  `<agent-org-context>` …
  `</agent-org-context>` with a first line saying "not part of the user's
  request", so an agent neither quotes the block as the question nor treats it as
  an instruction to act on.  Live qoder, asked to print the fact lines back, did
  all three: verbatim values, and the block attributed to the client.

The wire is spec-legal: a `PromptRequest`'s `prompt` is a LIST of content
blocks (`acp-make-session-prompt-request` vconcat's its `:prompt`), so
side-channel metadata is a second block rather than a new method or a mutated
message.  `agent-org-send-session-context` nil is the off switch, and it proves
the block is an addition: exactly one block leaves, byte-for-byte the draft.

Tests: 7 (`test-agent-org-context-block-*`, `…-send-appends-a-context-block-*`,
`…-drained-prompt-carries-the-same-context-block`), all seen failing first.  The
exact text of the block is pinned, not merely its fields, because a format an
agent has to guess at is a format it will misquote.  Mutation-checked: dropping
the append fails 7, substituting the truncating flattener fails 3, and printing
`model: nil` instead of omitting the line fails 4.

---

## 19. Lite mode: three gates, and the three things it must not touch

The user's order: "a lite mode which will use absolute minimum resources
with per-session/global scoping".  Minimum resources, so every saving is a
cost somebody pays on purpose and every non-saving is a decision.

**The scope is `agent-org-lite-mode` globally and `agent-org-buffer--lite`
per buffer, and the buffer's value is a SCOPE, not a setting** — `inherit`
follows the global, `on` and `off` pin one session against it.  A chat buffer
*is* a session, so there is no third thing to key the scope on, and the buffer
dies with it.  Three states and not two because "follow the global setting"
has to be reachable again after an override; `agent-org-lite-mode-toggle`
cycles them and says which one it landed on, because a session that quietly
stopped recording its transcript is the kind of thing a person notices a week
later.  `agent-org-lite-p` is the ONE reader: everything that acts on lite goes
through it, so a second place that read the variable would be a second rule.

**The three gates**, each measurable, none of them a rendering change:

1. **No transcript write — while a queued prompt is not waiting.**
   `agent-org-lite-mode` says the whole of it; the rule is
   `agent-org-buffer-transcribe`.  A whole-file write of 3–15 ms at every turn
   boundary buys a MIRROR of history the agent can replay by itself.  A queued
   prompt is *not* in any replay, in no `* User` heading and in no agent
   memory (§17), so a lite session writes its file exactly while `:queued` is
   non-nil and stops the moment the queue drains.  "Never" would have been the
   cheaper rule and would have thrown away the one piece of the queue that
   exists nowhere else.
2. **No undo records.**  `agent-org-buffer--record-undo-p` is the one gate,
   read by `agent-org-mode` (which seeds `buffer-undo-list`), by
   `agent-org-lite-mode-toggle` (which moves it) and by the two bulk insertion
   paths (`agent-org--render-replay`, `agent-org-queue--repaint`'s successor).
   Programmatic inserts are not undoable anyway, so what this really saves is
   the user's own typing at the prompt box.
3. **No whole-buffer Org reparse per metadata rebuild.**
   `agent-org-buffer-refresh-metadata` re-reads the buffer through
   `org-set-regexps-and-options` on every usage update, and the only reason is
   the `#+TODO:` line, which is the same bytes every time.
   `agent-org-buffer--todo-parsed` is our own flag rather than Org's
   `org-todo-keywords-1` (which lives in org-agenda.el, a package this one does
   not require for one read) and it is set by the same call that runs the
   parse.  `test-agent-org-lite-skipping-the-reparse-keeps-the-keywords-live`
   is the test that says the skip is safe: ONGOING is still a keyword after it.

**What lite mode does NOT do**, each because it is a fact about the
conversation rather than a decoration: **font-lock** — switching it off is the
one-way door of §16 and the display-time hook would switch it straight back on,
so a lite chat would pay the memory and lose the colours; **the `:thinking:`
and `:tool:` drawers** — the agent's reasoning and its calls are the
transcript; **Markdown conversion** — it is ~110 µs per markup-dense line
against a network fetch measured in seconds, and it is what makes a reply
readable Org at all.

**The `:Lite: yes` property line** is the one place the mode is visible: a
transcript is a record, and how it was being recorded is a fact about it.  The
renderer takes the scope as an ARGUMENT because it is a pure function of the
status plist, the same rule `agent-org-buffer--chat-label` follows.

## 20. The queue is a region of the chat, and the words on it are derived

The user's order: "queued prompts should be shown in the Org buffer at the
bottom with TODO headings with WAIT keywords with the next in-line prompt as
NEXT. User can edit them, and add his own at the bottom."

**The entries are `* NEXT`/`* WAIT` headings between the last exchange and the
live `* User` box.**  They are not in a drawer at the top, because a drawer is
part of the metadata block and that block is deleted and reinserted on every
usage update — which is exactly why the queue needed a second buffer while it
lived there.  They are not *after* the box either: `--render-end` answers with
`--queue-start` when a region exists, so a turn rendered while a queue waits
lands ABOVE the queue and the box stays the last thing in the buffer.

**`NEXT` and `WAIT` are per-file keywords in front of the done bar**
(`agent-org-buffer--todo-setup`), so `#+TODO: NEXT WAIT TODO ONGOING |
COMPLETE FAILED`: unlike a tool call, an entry IS a headline, so on it the
keyword is a real Org state and `NEXT`/`WAIT` join the vocabulary the file
declares.  **The word is DERIVED from position on every render**, never read
back from the buffer: a keyword that drifted from the queue's order would be a
lie about which prompt leaves next, and a `M-UP` must be able to move a
heading without anyone restating what it means.

**The region's preamble is comment lines and they are ABOVE the first entry.**
That placement is load-bearing, not cosmetic: an entry's text is everything
from its headline to the next one, so a note *after* the last entry parses as
part of that prompt and is sent to the agent.  (Measured while this was
written: the queue parsed back as one prompt ending in "M-x
agent-org-queue-apply".)  Above the first headline it is outside every entry's
body, and `agent-org-buffer--queue-headline-text` recovers a prompt's first
line from its headline with `string-prefix-p` rather than a regexp — the one
place that has to, and a pattern with a group in it is a pattern that can lose
its closing paren (which it did, once, and every entry came back with its
first line swallowed).

**The repaint never lands over an edit.**  `agent-org-buffer-refresh-queue`
repaints only when the session's queue and `--queue-shown` differ AND the
region still reads as `--queue-shown`; a region the user has changed is left
alone and `agent-org-queue-apply` reconciles instead.  That is the contract
the queue editor had, for the same reason, and it is what makes the region safe
to type in: a queue a person is rearranging must not change under his hands,
and a transcript must never claim a prompt the agent was not sent.

**`:QUEUE:` drawer and the entries are two projections of ONE list**, both
rendered from `:pending-prompts`, and the drawer is regenerated from the
SESSION and never from the entries — which is right, because an unapplied edit
must not reach the file.

**The box is inserted at `point-max` and the region's END marker is re-armed
afterwards.**  Both markers are rear-advancing, so inserting the box *at* the
end marker would push the marker down past the box and swallow the box into the
region (measured: the queue parsed as one prompt whose text ended with the
words `* User'`).  Re-arming after the insert is true in every case, including
the one that bit here — a region sitting at the very end has no line after it
to insert into.

**`M-UP`/`M-DOWN` are narrowed, not lifted.**  `agent-org-buffer--queue-only`
moves an entry when point is in the region and refuses (`agent-org-buffer--blocked`)
everywhere else: a chat refuses Org's structure commands because they would cut
the CONVERSATION's heading boundaries apart, and the region is the one place
where a structural act is the user's own business.

## 21. The resource monitor is a buffer, and its timer follows display

**A buffer of Org tables, never a header-line segment.**  §6 gives the bar
exactly one status string; a monitor is a number that changes while nobody is
doing anything; and a bar that redrew on a timer in every open chat would be
the load the monitor exists to report.  §6's other half applies too — nothing
periodic is ever written into a transcript — while the buffer stays a real
document: fold it, align it, `TAB` between cells.

**The one repeating timer in the package is armed by display and disarmed by
hiding** (`agent-org--resource-displayed-p`, which asks for the WINDOW LIST
across all frames: `get-buffer-window` answers for one frame, so a monitor in a
background frame would read as hidden).  A batch Emacs has a frame and windows
(measured), so "displayed" there is real and the test shows and hides a window
for real rather than stubbing the check.

**The region it owns is `point-max`, and its title is written once.**
`agent-org--resource-paint` deletes from the first HEADING to `point-max`, which
is the mirror image of `agent-org-buffer-refresh-metadata` (`point-min` up to
the first heading): there the conversation owns everything below the first
heading, here the headings belong to the generated block.

**A CPU column is a rate from two samples, and `/proc` is parsed by a pure
function.**  A total would be a fact about the session's age; "140%" is the
fact that one agent is spinning the machine.  `agent-org--stat-cpu-ticks`
counts from AFTER the `comm` field, because `(Web Content)` is a real process
name and a naive split reads the wrong two numbers while reporting no error at
all — and the parsers are separated from the file reads so the `/proc` format
can be pinned by a test on a machine whose processes are not ours to inspect.

**`agent-org-clock-ticks-per-second` is a `defcustom`, not a constant,
because nothing in Emacs can answer it.**  `sysconf' is void in the Emacs this
was built against (measured), and asking the kernel by spawning `getconf` from a
monitor is the one cost the feature exists to avoid.

## 22. Each exchange is clocked — and the clock never blocks Org's

User order: *"Each heading will be clocked, too, to derive the total response
time of the agent since the prompt were sent"*, and *"your clocking MUSTN'T
block user's Org clocking"*.  So the boundary writes two things directly under
the exchange's `*` heading, before its `#+ATTR_TEXINFO`/`#+begin_quote` answer
(§1, §8):

```org
* Capital?
:PROPERTIES:
:RESPONSE: 4500
:END:
:LOGBOOK:
CLOCK: [2026-10-07 Wed 00:57]--[2026-10-07 Wed 02:12] =>  1:15
:END:
#+ATTR_TEXINFO: :author QModel
#+begin_quote
 Paris.
#+end_quote
```

* `:RESPONSE:` in the property drawer is the **measurement** — exact whole
  seconds from the prompt going out to the turn boundary.  It sits *directly*
  under the heading, which is where `org-entry-get`, `org-set-property` and
  completion look, so a person or an agenda command reads it as a real
  property.
* The `CLOCK:` line in the `:LOGBOOK:` drawer is Org's **canonical completed
  range**, in `org-clock-out`'s own form: two inactive timestamps joined by `--`
  and an `=>` duration.  It is for Org's clock tools (`org-clock-collect`, the
  agenda's clocktable) — and because the timestamps are minute-granular, the
  duration they encode can round a sub-minute answer to `0:00`.  That is fine:
  the range is for Org's tools, the exact seconds live in the property.

**The whole design is chosen so it cannot occupy the one global "running
clock" slot that Org's clocking turns on.**  Org blocks a second `org-clock-in`
only when a clock is *running* — the state held in `org-clock-marker` /
`org-clock-hd-marker` / `org-clock-is-active`.  Three rules keep our recording
off that slot:

1. We **never call `org-clock-in`, `org-clock-out` or `org-clock-load`, and
   never set any `org-clock-*` variable.**  The boundary emits text; it touches
   none of Org's live clock state.  Zero coupling, so zero blocking.
2. We write only a **completed** range (`[start]--[end] => H:MM`).  A completed
   line is *history* — `org-clock-load` skips it.  An **open** `CLOCK:` line
   (no `--`) is the one form that `org-clock-load` would mistake for a running
   clock, and we deliberately never emit one.
3. Our timing is a **buffer-local stamp** (`agent-org-buffer--turn-start`), a
   piece of state entirely separate from Org's global marker.

This is verified end-to-end: a test loads the transcript copy into a plain
`org-mode` buffer, confirms `org-clock-is-active` is nil (our closed clocks look
like nothing running), runs a *real* `org-clock-in` / `org-clock-out` on the
same exchange, and confirms the user's clock was accepted while our `:RESPONSE:`
and our closed range survived untouched — two clock nodes in the drawer.

**Two measured traps this had to get right:**

* `org-time-stamp-formats` here is `("%Y-%m-%d %a" . "%Y-%m-%d %a %H:%M")` —
  its **car is date-ONLY** (no `%H:%M`) and **neither half carries brackets**.
  Building the timestamp from the car gave two equal day-stamps, a zero range,
  and an unparseable `CLOCK:` line.  The line is built from the **cdr wrapped in
  `[...]`**, the inactive form `org-clock` itself writes.
* The writer computes the `=>` duration from those minute-truncated timestamps
  (via `org-time-string-to-seconds`), **not** from `seconds`, so the range is
  internally consistent for Org's own clock parsers — a `CLOCK:` line whose
  printed duration disagreed with its timestamps is exactly the kind of thing an
  agenda would silently mis-sum.

**Replayed exchanges carry no clock.**  `agent-org-buffer--record-clock-p` is
bound nil for the resume-replay paint (`agent-org--render-replay`), so
`begin-exchange` never stamps a start and the boundary is a no-op.  A `session/load`
replay carries neither the moment the prompt was sent nor a real elapsed turn;
a range computed from restore-time wall clock would be a fabricated measurement
filed among the real ones.  The exchanges render identically — only the clock is
withheld.

`agent-org-buffer--close-response-clock` spends the stamp on first write, so a
late second boundary call (a callback after the turn already closed) cannot file
a second clock on the same heading.


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
