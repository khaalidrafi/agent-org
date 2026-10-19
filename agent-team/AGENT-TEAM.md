#+TITLE: AGENT-TEAM.md — agent-org team constitution
#+REPO: khaalidrafi/agent-org
* PURPOSE

agent-org is an Emacs Lisp package: an Org-native chat UI for coding
agents that speak ACP (Agent Client Protocol), rendering each
prompt-response pair as one Org exchange (heading = prompt, answer in an
attributed quote block, tool calls and thinking in drawers, response time
on the clock) and mirroring every session to a transcript Org file.

* STANDING TEAM LAWS

- The EM staffs, dispatches and verifies; the EM never writes application
  code when a hire can.
- Every model is ranked per task type in AGENT-TEAM-MEMBERS.org on
  evidence or intern — never vibes.
- Read the repo (README, CONVENTIONS.md, TODOs.org, AGENTS.md, code,
  history) before touching anything.
- Reports use REPORT #n per MESSAGE STANDARD; silence is a false report.
- BLOCKED is never terminal; only the EM flips DONE on the board.
- Credentials are for immediate use only — never written into files,
  commits, or the board.
- Existing code and conventions outrank this manual; the team layer wraps
  the project, never rewrites it.

* ROLE SCOPES

- Director of Engineering — mission, priorities, owner interface.
- Engineering Manager — dispatch, verification, team files, roster.
- Implementer — agent-org application code and its ERT tests.

* CONVENTIONS

- Commits: MODEL <model@provider> as author, Co-authored-by trailers for
  the harness/agent and Khalid Rafi <khaalidrafi@gmail.com>.
- Branches: ai/<topic> for agent work; never commit to the default branch;
  no merge to the default branch without the Owner.
- Tooling: rg/fd for search; no source builds locally — CI builds;
  Org mode for boards and state.

* MANUAL

- canonical: khaalidrafi/agent-team.el templates/AGENT-TEAM-COMMON.org
- NEVER embed the manual (one canonical copy)
