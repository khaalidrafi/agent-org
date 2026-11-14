# agent-team-ci integration contract (every agent-team repo)

Owner order 2026-10-27 (#hq): the CI kit is a SUBMODULE every repo uses,
ALL Docker agents read BOTH rule files, and the global rule file lives
in this submodule. Adopting repos follow this contract.

## 1. Install

```bash
git submodule add https://github.com/khaalidrafi/agent-team-ci.git ci
git commit -m "ci: adopt agent-team-ci submodule (shared harness + dual-law kit)"
```

CI checkouts MUST include the submodule:

```yaml
- uses: actions/checkout@v4
  with:
    submodules: recursive
```

## 2. Harness image

Build the canonical tool image from YOUR repo root (context = repo root,
so the Dockerfile can copy `ci/AGENTS.md` — the global rule file — into
every tool's own settings file):

```yaml
- uses: docker/build-push-action@v6
  with:
    context: .
    file: ci/docker/harness/Dockerfile
```

Project-specific tools (baked node_modules, python venvs, ...) extend
the canonical image — write `FROM <your-team-harness>` in a thin local
Dockerfile and keep the tool installs + rule copies inherited, never
forked. If you must diverge, port the change upstream to agent-team-ci first;
a local fork without an upstream PR is a compliance violation.

## 3. Delivering both rule files (copy at build; paste only where needed)

For 7 tools (OpenCode, Goose, Qoder, CodeBuddy, OMP, pi, Copilot) the
build copies the global rule file into the tool's own settings file —
nothing else needed. The project rule file is the repo's own root
`AGENTS.md`, which every tool reads from the working directory anyway
(Owner 2026-10-27 #hq: "no need to prepend with law_brief.sh").

The THREE tools without a settings file (dsh / Cursor / mcode) MUST
still get the global rules by pasting them in front of the prompt —
otherwise they see only the project rules:

```bash
printf '%s\n' "$SEGMENT_BRIEF" > /tmp/segment-brief.txt
BRIEF="$(bash ci/bin/law_brief.sh /tmp/segment-brief.txt "$PWD")"
# hand $BRIEF to the agent body (env, argv, or file — body's contract)
```

Output = GLOBAL RULES (ci/AGENTS.md) + PROJECT RULES (repo root
AGENTS.md) + the work instructions. Missing files produce loud MISSING
markers, never a silent run without rules. Tight prompt budgets may set
`CI_LAW_DIGEST` to a COMMITTED condensed digest of the project rules —
never an improvised one.

Raw API calls (no tool in the middle) prepend the same composed text to
the messages array.

## 4. Commit-message guard

Land nothing with mechanical subjects. In your finalize/gate job:

```bash
bash ci/bin/commit_msg_guard.sh "${BASE_SHA}..HEAD" \
  || { git reset --hard origin/main; echo "gate=red-commit-msg"; }
```

Subjects must name WHAT changed (>= 3 words); banned openers: `ci-turn`,
`ci-chain`, `turn(...)`, `wip`, `progress`, `misc`, `done`, `stall=N`,
bare `update`/`fix`. State-file commits stay compliant by naming the
field that moved (e.g. `control: rotate #+TURN to <seat> after <seat>
segment`).

## 5. Commit generators

Fix every automated `git commit` in your workflows to produce
descriptive subjects per the global rule file. Agents write their OWN
commit messages describing their change — the work instructions must
say so.

## 6. Verification duty (first migration turn)

Report in your CHAT.org, with evidence:
- tool x global-rules x project-rules x mechanism matrix (which tool,
  which file, what carried it, request-id/token proof where the tool
  allows),
- per-category violation counts (path x rule clause x severity) for the
  whole-repo compliance audit, each with fix commit or BLOCKED,
- confirmation that `ci/bin/commit_msg_guard.sh` gates your merge.
