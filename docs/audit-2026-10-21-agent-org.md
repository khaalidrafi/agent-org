# Independent Secret-Leak Verification Audit — khaalidrafi/agent-org (v2)

- Task ID: 16-b · Auditor: independent security-auditor seat (no coordination with Task 15 auditor)
- Date: 2026-10-21 · Repo: `/home/z/my-project/agent-org` (local clone, read-only; branch `ai/quickstart` @ `2a909bf`, = `origin/ai/main`)
- Method: independent re-count + fresh full scan (per-commit `git grep -E -f` over every commit reachable from ALL refs, cross-checked with `git log --all -p -U0` streamed through `rg`, plus `-uu` (hidden+ignored-inclusive) worktree scan, filename forensics, entropy heuristic). Pattern list = the 10 mandated patterns + supplements (`x-access-token:`, `eyJ` JWT shape, `pt-` guard shape).
- REDACTION: no full credential value is reproduced anywhere in this report (none found; previews shortened to `xxxx…(len=N)` form regardless).

---

## 1. Verdict on prior SECURITY-AUDIT.org (Task 15, published in `0d753c8`)

**CONFIRMED — CLEAN verdict stands under independent re-scan with a superset of the original patterns. Specifics:**

| Prior claim | Independent result | Status |
|---|---|---|
| 86 commits scanned | `git rev-list --all --count` today = **89**. At the audit's own snapshot (parent of publish commit `0d753c8`, i.e. `0d753c8^`): **exactly 86** | ✅ accurate **at audit time**; stale by 2 commits (`14e98e5`, `2a909bf` — both post-audit gate/test work, secret-free, see §3) |
| 448 unique blobs scanned | Blobs reachable from `0d753c8^` = **exactly 448**. Today from all refs = **465** (+17 blobs from the 2 newer commits) | ✅ accurate at audit time; refresh count = 465 |
| CLEAN — zero credential-shaped strings in any commit or worktree | 89 commits × 465 blobs × all refs re-scanned: **0 CONFIRMED, 0 LIKELY**; 7 unique hit-lines, all classified FALSE-POSITIVE (§3) | ✅ CONFIRMED |
| "sk- flags were mid-word FPs on `risk-tiers`" (tests/test-agent-org-review-teach.el) | ✅ Verified. Every `sk-` substring in the **entire history** (113 hit-lines across 5 paths) resolves to: elisp identifiers `agent-org-review-teach-risk-tiers*` / `review-teach-risk-*-…` (agent-org-review-teach.el:114,126,195,198; tests/test-agent-org-review-teach.el:19,28,36,39,40), prose `ask-before-you-kill` (AI-REVIEW.org), the detector's own regex literal (secret-guard.sh:20), and the audit doc's own pattern list (SECURITY-AUDIT.org:10,18-20). Longest suffix after `sk-` anywhere = `tiers-in-descending-order` (25 chars) — cannot match the mandated `sk-[A-Za-z0-9_-]{32,}`. **No rotation needed; nothing was ever a live credential** | ✅ CONFIRMED |

Corrections/expansions (not verdict-changing):
- Prior scope note says the earlier flagged file was the test file with "two" shapes; the full history contains additional benign `sk-` sources (AI-REVIEW.org `ask-before-you-kill`, guard regex, audit doc text) that any naive `sk-` grep will keep re-flagging — worth a word-boundary note in the audit doc to prevent future noise.
- Prior audit did not enumerate: `origin/ai/staffing` (86 commits) and `origin/ai/teamify` (87 commits) were both covered implicitly (both are ancestors of `origin/ai/main`; verified `git merge-base --is-ancestor`). No disjoint branch history exists. 0 tags, 0 stashes, 0 unreachable objects (`git fsck --unreachable` empty).

## 2. Scan scope

- Commits: **89** (`git rev-list --all --count`); per ref: origin/ai/main 89, origin/ai/quickstart 89, ai/quickstart 89, origin/ai/teamify 87, ai/teamify 87, origin/ai/staffing 86 (ancestors of main; union = 89). Tags: 0.
- Blobs: **465** unique reachable blobs (725 objects total = 89 commit + 171 tree + 465 blob); blobs re-scanned per commit snapshot via `git grep` × 89 commits.
- Branches: all 7 refs enumerated above; local == remote for quickstart/teamify; HEAD `2a909bf` == `origin/ai/main` ✓.
- Working tree: **31 tracked files**, 0 untracked-nonignored, 5 untracked-but-ignored (`*.elc` byte-compile artifacts — scanned, clean). Scan used `-uu` (hidden + ignored) because `.github/` is a hidden dir that default rg/Grep traversal silently skips — coverage verified file-set-identical to `git ls-files` + the 5 `.elc`.
- Git internals: no stashes, no unreachable/loose dangling content, `info/exclude` is the untouched template.
- Hit counts by class: **CONFIRMED 0 · LIKELY 0 · FALSE-POSITIVE 7 unique lines** (6 strict-pattern + 1 kv-pattern; 18 raw history hit-lines = 6 lines × 3 commit snapshots, 3 kv snapshots of 1 line).
- Entropy heuristic `[A-Za-z0-9+/=_-]{28,}` near key-like names: 3 unique mixed-case tokens in worktree, 0 extra in history — all three are **UUID-format example session IDs** in a `#+begin_example` UI mock, README.org:424-426 → FALSE-POSITIVE (e.g. `7f9e…(len=36)`).
- Bearer pass: 0 hits anywhere. Telegram shape / AKIA / AIza / xox / webhook URLs (larksuite, feishu, discord, slack) / PEM private keys / JWT `eyJ` / `gsk_` / `gh[pousr]_` / `github_pat_`: 0 non-FP hits anywhere.

## 3. Findings table (all FALSE-POSITIVE — killed by manual context review)

| # | Class | Type | Location (file:line) | Commit(s) | Redacted preview | Live in HEAD |
|---|---|---|---|---|---|---|
| 1 | FALSE-POSITIVE | Detector's own regex literal (contains `ghp_…`, `github_pat_…`, `sk-…`, `x-access-token:…` shapes as source code) | .github/scripts/secret-guard.sh:20 | 0d753c8, 14e98e5, 2a909bf | `GENERIC='pt-…|ghp_…'` (pattern source, not a value) | yes |
| 2 | FALSE-POSITIVE | Actions token interpolation in HTTPS remote URL (`${{ github.token }}` = ephemeral run-scoped, not stored) | .github/workflows/agent-team.yml:141 | 0d753c8, 14e98e5, 2a909bf | `https://x-access-token:${{ github.t…` | yes |
| 3 | FALSE-POSITIVE | same | .github/workflows/agent-team.yml:156 | 0d753c8, 14e98e5, 2a909bf | `https://x-access-token:${{ github.t…` | yes |
| 4 | FALSE-POSITIVE | same | .github/workflows/agent-team.yml:515 | 0d753c8, 14e98e5, 2a909bf | `https://x-access-token:${{ github.t…` | yes |
| 5 | FALSE-POSITIVE | same | .github/workflows/agent-team.yml:665 | 0d753c8, 14e98e5, 2a909bf | `https://x-access-token:${{ github.t…` | yes |
| 6 | FALSE-POSITIVE | Audit doc's own pattern-name list | SECURITY-AUDIT.org:10 | 0d753c8, 14e98e5, 2a909bf | `github_pat_ / ghp_ / gho_ / x-acce…` | yes |
| 7 | FALSE-POSITIVE | Env-var passthrough (variable reference, not a literal) | .github/workflows/agent-team.yml:367 | 0d753c8, 14e98e5, 2a909bf | `OPENAI_API_KEY="$ZAI_API_KEY" \…` | yes |
| 8 | FALSE-POSITIVE | UUID example session IDs in doc example block | README.org:424,425,426 | pre-0d753c8 (and HEAD) | `7f9e…(len=36)`, `3dfe…(len=36)`, `b480…(len=36)` | yes |
| 9 | FALSE-POSITIVE | `risk-tiers`/`ask-…` identifier family flagged by naive `sk-` grep | agent-org-review-teach.el:114,126,195,198 · tests/test-agent-org-review-teach.el:19,28,36,39,40 · AI-REVIEW.org (50 lines) · SECURITY-AUDIT.org:10,18-20 | throughout history | `…risk-tiers-in-descending-order…` | yes |

**CONFIRMED credentials: none. LIKELY: none. Nothing to rotate.**

Filename forensics (`git log --all --diff-filter=A --name-only`, 31 unique paths ever added): only risky-name match = `.github/scripts/secret-guard.sh` (the guard itself). **No `.env*`, `*.pem`, `*.key`, `id_rsa*`, `.netrc`, `.npmrc`, `*credential*`, `*token*`, `*.pfx`, `*.keystore` was ever committed.**

## 4. Rotation list

**EMPTY** — no CONFIRMED (or LIKELY) credential exists in any commit, any branch, or the worktree. No revocation/rotation actions required for this repo.

## 5. Hygiene recommendations

1. **secret-guard.sh GENERIC pattern gaps** (line 20): add `gho_|ghu_|ghs_|ghr_` (only `ghp_` covered), `gsk_[A-Za-z0-9]{20,}`, explicit `sk-ant-|sk-or-v1-|sk-proj-` (current `sk-[A-Za-z0-9]{16,}` misses Anthropic-style keys because the first `-` after `sk-ant` breaks the alnum run), `AKIA[0-9A-Z]{16}`, `AIza[0-9A-Za-z_-]{35}`, `xox[baprs]-`, `Bearer\s+\S{20,}`, `hooks.slack.com|discord.com/api/webhooks|hooks.larksuite|open.feishu.cn`, `BEGIN [A-Z ]*PRIVATE KEY`, JWT `eyJ…\…\…` shape.
2. **collect_values env-prefix gap**: `^(GROQ|…|ANTHROPIC)…` does not match `DISCORD_WEBHOOK_*` (starts with `DISCORD`) nor `GITHUB_TOKEN`/`GH_*`; add `DISCORD|GITHUB|GH_` to the prefix alternation.
3. **.gitignore additions**: `.env*`, `*.pem`, `*.key`, `id_rsa*`, `id_ed25519*`, `.netrc`, `.npmrc`, `*.pfx`, `*.keystore`, `*.p12`. Currently only `*.elc *~ \#*\# *.tar /.agent-org/` are covered.
4. **Audit-tooling gap (this audit's own lesson)**: default `rg`/Grep traversal skips hidden dirs — `.github/**` (workflows, guard scripts) is invisible to naive scans. Any future audit script must scan with hidden+ignored coverage (`rg -uu` or explicit `.github` traversal); the git-object-based pass is immune but the worktree pass is not.
5. **Noise reduction**: add a word-boundary note (or `\bsk-`) to SECURITY-AUDIT.org's FP note so future naive `sk-` greps stop re-flagging `risk-tiers` / `ask-before-you-kill` / the guard regex / the audit doc itself (9 + 50 + 3 + 3 history hit-lines of pure noise).
6. Minor: 5 untracked `*.elc` build artifacts sit in the worktree; harmless, but `git clean -fX` before packaging/archiving the repo.

---
*End of report. Raw scan artifacts retained at /tmp/audit16b/ (hit lists, file censuses, entropy candidate sets).*
