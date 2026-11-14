# agent-team-ci

Shared CI kit for the agent teams — consumed as a **git submodule** (`ci/`)
by every agent-team repo.

Owner orders landed 2026-10-27 (#hq):

1. **"Turn your CI stuffs into a submodule which every repo uses"** — the
   harness Dockerfile, agent configs, law wiring and commit guard live HERE,
   once, versioned per consuming repo by its submodule pointer.
2. **"Configure ALL agents in Docker to read both global and local
   AGENTS.md"** — the canonical harness bakes the global law into each
   body's verified global/user rules slot (OpenCode, Goose, Qoder,
   CodeBuddy, OMP, pi, Copilot) and bodies auto-read the repo's own
   AGENTS.md; `bin/law_brief.sh` is REQUIRED ONLY for the three bodies
   without a baked global slot (dsh / Cursor / mcode) — Copilot has a
   VERIFIED user-level path ($HOME/.copilot/copilot-instructions.md)
   and is baked; for baked bodies no prepend is needed, Owner
   2026-10-27 #hq: "no need to prepend with law_brief.sh".
3. **"Store global AGENTS.md in your CI submodule"** — `AGENTS.md` here IS
   the canonical global law. A consuming repo pins a law version by pinning
   the submodule pointer; updates propagate as ordinary pointer bumps.

## Layout

```
AGENTS.md                  canonical GLOBAL law (no commit policy — the commit
                           rule lives in the agent-team prompt templates)
bin/law_brief.sh           dual-law brief composer (REQUIRED only for slot-less bodies)
bin/commit_msg_guard.sh    commit-substance gate (bans "ci turn"/"stall"-style subjects)
docker/harness/Dockerfile  canonical agent-harness image (bodies preinstalled, laws baked/mounted)
docker/harness/*.json|yaml shared agent configs (opencode providers, goose)
templates/INTEGRATION.md   the adoption contract — read before wiring
.github/workflows/self-check.yml  proves the kit before anyone consumes it
```

## Adopt

```bash
git submodule add https://github.com/khaalidrafi/agent-team-ci.git ci
```

Then follow `templates/INTEGRATION.md`: submodule-aware checkouts, harness
build from your repo root (the bake delivers the law — baked bodies need
no `bin/law_brief.sh` prepend, Owner 2026-10-27 #hq), `bin/commit_msg_guard.sh`
gating your merge, commit generators fixed to descriptive subjects.

## Laws this kit enforces

- **Dual law**: no agent runs without both laws in its prompt (global from
  here; local from the repo's own `AGENTS.md`; `CI_LAW_DIGEST` sanctioned
  only as a committed, reviewed condensed digest for budget lanes).
- **Commit substance**: subjects describe the change, never turn metadata —
  no "ci turn", "ci-chain: stall=N", "turn(<seat>): ...", "wip". The RULE is
  taught by the agent-team prompt templates (agent-team.el templates/COMMON.org
  + the turn-step brief) — Owner 2026-10-27: "This rule doesn't belong to
  AGENTS.md"; this kit only ENFORCES it (the guard) and the briefs carry it.
- **No secret baking**: keys ride env vars per run; nothing credential-shaped
  ever lands in this repo (self-checked on every push).

## Versioning

Repos upgrade by moving the submodule pointer (`git submodule update
--remote ci` or a pinned sha) — a one-line, reviewable commit. Breaking
changes to the contract bump the notes here first; teams migrate on their
next turn and report evidence in their CHAT.org.
