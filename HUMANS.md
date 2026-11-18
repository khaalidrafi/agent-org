# HUMANS.md — agent-org

A guide for humans navigating and developing this codebase. Written
2026-11-18 per the org-wide rule that every agent-developed repo
carries one.

## What this is

An Org-native Emacs client for coding agents that speak ACP (Agent
Client Protocol). Unlike agent-shell it runs no hidden comint buffer:
it talks to the `acp` package directly and renders the conversation
AS an Org document. The design rule that shapes everything: the body
is a conversation in exchanges — one heading per prompt-response
pair, the heading text IS the prompt, the answer sits in an Org quote
block attributed to the model, tool calls follow as list items in an
open `:tool:` drawer (state TODO/ONGOING/COMPLETE/FAILED), extended
thinking in a folded `:thinking:` drawer, and one auto-managed
metadata block at the top. The whole body mirrors to one Org file per
session, so a chat leaves a document, not a buffer you had to save.

Each exchange also times the agent: a `:RESPONSE:` property (exact
seconds) plus a canonical Org CLOCK range under a `:LOGBOOK:`
drawer — opened when the prompt goes out, closed when the answer
lands — without ever occupying Org's one global running-clock slot
(the package never calls `org-clock-in`; resumed sessions carry no
clock rather than a fabricated one).

## Mental model

Two layers, one protocol:

- `agent-org.el` (3.7k lines) — the client: sessions, prompts, the
  ACP callback machinery, transcript persistence.
- `agent-org-buffer.el` (5.4k lines) — the renderer: everything that
  turns ACP events into the Org structure described above (exchanges,
  quote blocks, tool drawers, thinking drawers, clock lines, the
  metadata block, Markdown-to-Org conversion of agent replies).
- `agent-org-providers.el` (348 lines) — the seat table: which agent
  binaries speak ACP and how to start them (slave-agent, Devin, ...).
- `agent-org-loader.el` (63 lines) — session loading glue.
- `agent-org-review-teach.el` (370 lines) — review/teaching helpers.
- `agent-org-autoloads.el` — generated; do not hand-edit.
- `tests/` — offline ERT suite over `tests/acp-mock.el` (a mock acp
  that MUST stay in tests/: in the package root it shadows the real
  acp and live sessions silently do nothing).
- `docker/harness/` — the agent harness for CI.
- `CONVENTIONS.md` — every rendering rule WITH the measurements that
  justify it (cited as section numbers); `TODOs.org` — per-feature
  narrative; AGENTS.md — what an agent must not get wrong.

Status/progress/errors render in the buffer's HEADER LINE (like
gptel/agent-shell), never as system messages in the document body.

## The traps (documented in AGENTS.md, learn them before editing)

- **Dependency-first byte-compilation**: compiling `agent-org.el`
  loads `agent-org-buffer` from its `.elc`; a function freshly added
  there reads as "not defined" until the buffer file is recompiled.
  `rm -f *.elc` when in doubt — a stale `.elc` also shadows sources
  in the test suite and the live session (the suite binds
  `load-prefer-newer` for exactly this).
- **Version skew**: `emacs -Q --batch` runs the BUILT-IN Org (9.7.x)
  while a live server may load a newer ELPA org (9.8+); a rule pinned
  by a test is pinned against a different Org than the one it must
  please. Check `(org-version)` in the live server before believing a
  green suite covers an Org interaction.
- **The live-cache trap**: in a big old chat buffer the org-element
  cache can go stale (the renders edit the buffer from ACP callbacks)
  and then `org-element-at-point` signals, killing `org-entry-get`
  and the clock draw on EVERY heading. Reproduced live, invisible in
  batch; cured by `org-element-cache-reset`. The draw wraps in a
  `condition-case` that resets once and retries.
- Code style: alists everywhere, read with `map-elt`/`map-nested-elt`
  (map.el), seq.el for lists, `cl-defun` with `&key` for many-arg
  functions.

## Developing

```sh
# Byte-compile, zero warnings required (see the dependency-first note):
emacs -Q --batch --eval '(add-to-list 'load-path ".")' \
  --eval '(setq byte-compile-error-on-warn t)' \
  -f batch-byte-compile agent-org-buffer.el agent-org.el \
  agent-org-loader.el agent-org-providers.el

# Offline ERT suite (mock acp, never the real package):
emacs -Q --batch --eval '(add-to-list 'load-path ".")' \
  --eval '(load "tests/test-agent-org.el")' \
  --eval '(ert-run-tests-batch-and-exit)'

# Live smoke test (real acp + a working agent binary): ./run-loader-test.sh
```

Branch law: work lands on `ai/main`. NOTE: the GitHub repo's default
branch is currently `ai/quickstart` — a known anomaly under audit
(board row audit/02); do not "fix" it casually, the quickstart line
carries hundreds of commits whose attribution is being verified.
