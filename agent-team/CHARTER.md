#+TITLE: CHARTER.md — agent-org team constitution
#+REPO: khaalidrafi/agent-org
* PURPOSE

agent-org is an Emacs Lisp package: an Org-native chat UI for coding
agents that speak ACP (Agent Client Protocol), rendering each
prompt/response pair as one Org exchange (heading = prompt, answer in an
attributed quote block, tool calls and thinking in drawers, response time
on the clock) and mirroring every session to a transcript Org file.

* STANDING TEAM LAWS

- The EM staffs, dispatches and verifies; the EM never writes application
  code when a hire can.
- Every model is ranked per task type in MEMBERS.org on
  evidence or intern — never vibes.
- Read the repo (README, CONVENTIONS.md, TODOs.org, AGENTS.md, code,
  history) before touching anything.
- Reports use REPORT #n per MESSAGE STANDARD; silence is a false report.
- BLOCKED is never terminal; only the EM flips DONE on the board.
- Credentials are for immediate use only — never written into files,
  commits, or the board.
- Both AGENTS.md files bind everywhere: the GLOBAL law (baked from the
  ci/ kit harness into your body's rules slot) and the LOCAL law (the
  repo's own AGENTS.md + CONVENTIONS.md). Project specifics: local wins.
- The .agent-org/ directory is the PRESERVED record (Owner order
  2026-10-27): auto-generated session transcripts and the per-seat
  session ids (.agent-org/sessions/<seat>.sid) are committed every
  turn — read them, never edit or delete them, never put secrets in them.
- Existing code and conventions outrank this manual; the team layer wraps
  the project, never rewrites it.


* ROLE SCOPES

- Director of Engineering — mission, priorities, owner interface.
- Engineering Manager — dispatch, verification, team files, roster.
- Implementer (features) — agent-org application code and its ERT tests;
  Claude Opus 4.7 owns core buffer/session features, Qwen3.8-Flash owns
  providers and prompt-queue mechanics (see MEMBERS.org).
- Scout — web research with citations; returns findings, never writes repo
  files.

* CONVENTIONS

- Commits: MODEL <model@provider> as author, Co-authored-by trailers for
  the harness/agent and Khalid Rafi <khaalidrafi@gmail.com>.
- Branches: ai/<topic> for agent work; never commit to the default branch;
  no merge to the default branch without the Owner.
- Tooling: rg/fd for search; no source builds locally — CI builds;
  Org mode for boards and state.
- CI kit: the ci/ submodule (khaalidrafi/agent-team-ci) carries the
  shared harness + both-law delivery + commit guard; the Lead bumps its
  pin whenever the kit moves (gitlinks pin a commit, never a branch).

* MANUAL

- canonical: khaalidrafi/agent-team.el templates/COMMON.org
- NEVER embed the manual (one canonical copy)
