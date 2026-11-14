# agent-harness-base (canonical, khaalidrafi/agent-team-ci) — CI turn container
# with agent bodies PREINSTALLED.
# MODULAR (Owner order 2026-10-30 #hq: "on each CI run, only agents needed
# by that run can be built/used"): one shared `base` stage + one
# `body-<name>` stage per agent + a `harness` stage that unions ALL bodies
# (default target = legacy full image). Consumers build ONLY the bodies a
# run needs via ci/bin/harness_run_build.sh (--target body-<name> per
# body): BuildKit skips every other body stage entirely, and a change to
# one body's layers no longer invalidates any other body's cache.
# Owner order 2026-10-20 (#hq): "Use Docker containers with agents
# preinstalled. Don't install in CI. That's a waste of time. You'll have
# to make agent configs, too, and reuse them."
# Owner order 2026-10-27 (#hq): this Dockerfile lives in the agent-team-ci
# SUBMODULE every agent-team repo consumes at ci/. Build it from the
# CONSUMING REPO'S ROOT as build context:
#   docker buildx build -f ci/docker/harness/Dockerfile -t <team-harness> .
# DUAL-LAW ARCHITECTURE (Owner order 2026-10-27 #hq):
#   GLOBAL law  = ci/AGENTS.md (this submodule) — baked into each body's
#                 global/user rules slot IN THAT BODY'S STAGE below;
#                 present in every repo, and the submodule pointer pins
#                 the law version per commit.
#   LOCAL law   = the consuming repo's own root AGENTS.md — NOT baked
#                 (optional file): bodies auto-read it from CWD. Baked
#                 bodies run prepend-free (Owner 2026-10-27 #hq: no
#                 need to prepend with law_brief.sh); the brief is
#                 REQUIRED ONLY for bodies with no bake below (dsh /
#                 Cursor / mcode). No agent ever runs lawless.
# Secrets are NEVER baked: provider keys are injected per run as env vars
# (OPENROUTER_API_KEY / ZAI_API_KEY / GROQ_API_KEY /
#  QODER_PERSONAL_ACCESS_TOKEN / CODEBUDDY_*) from repo secrets.
# Project harnesses (extra deps: node modules, python venvs) extend this
# image: FROM <this image> + your project layers — see templates/.

# ===========================================================================
# Shared base: OS plumbing + Node 22 + run user + team plumbing.
# Kept deliberately SMALL — every body stage builds on it and its layers
# are shared by all bodies in the cache.
# ===========================================================================
FROM debian:stable-slim AS base

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git curl ca-certificates bzip2 jq procps \
 && rm -rf /var/lib/apt/lists/*

# --- Node 22 (Owner order 2026-10-27 #hq fleet: pi needs Node >= 22.19,
#     mcode needs 22.19+/24-26; debian stable ships an older nodejs) -------
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

# --- Non-root run user (matches the Actions runner uid 1001) ---------------
RUN useradd -m -u 1001 agent

ENV HOME=/home/agent \
    GOOSE_PROVIDER=openrouter \
    GOOSE_MODEL=nvidia/nemotron-3.5-lightning:free

# agent-team.el chat command (Owner order 2026-10-27 #hq: CHAT.org
# is COMMAND-MAINTAINED — seats send chat via `team-chat', never by
# hand). Baked at a pinned agent-team.el commit; AGENT_TEAM_EL_SHA is
# bumped with the consuming repo's kit pointer bump.
ARG AGENT_TEAM_EL_SHA=ed63926
RUN mkdir -p /opt/agent-team \
 && curl -fsSL "https://raw.githubusercontent.com/khaalidrafi/agent-team.el/${AGENT_TEAM_EL_SHA}/agent-team.el" \
      -o /opt/agent-team/agent-team.el
COPY ci/docker/harness/team-chat /usr/local/bin/team-chat
RUN chmod +x /usr/local/bin/team-chat

STOPSIGNAL SIGTERM

# ===========================================================================
# Body stages — one per agent, INDEPENDENT of each other (all FROM base).
# Every body keeps its FATAL version check: a body that cannot run fails
# its own build loudly, never hides behind || true. Body payloads live
# under /usr/local (installers, npm -g) and /home/agent (config bakes);
# the harness_run_build.sh overlay copies exactly those two prefixes.
# Baked global-law slots per body (docs verified 2026-10-21/27/29):
#   OpenCode  ~/.config/opencode/AGENTS.md (opencode.ai/docs/rules)
#   Goose     ~/.config/goose/.goosehints (global hints file)
#   CodeBuddy ~/.codebuddy/CODEBUDDY.md (USER-level memory)
#   Qoder     ~/.qoder/AGENTS.md (USER-level static memory)
#   OMP       ~/.omp/agent/AGENTS.md + RULES.md (user-wide context/rules)
#   pi        ~/.pi/agent/AGENTS.md (user instructions across workdirs)
#   Copilot   ~/.copilot/copilot-instructions.md (user-level global)
#   Devin     ~/.config/devin/AGENTS.md (rules for every project)
#   dsh / Cursor / mcode / Cline / gemini-cli / kilo: NO verified global
#             rules slot — the global law rides ci/bin/law_brief.sh
#             (REQUIRED for these bodies), LOCAL law = repo-root AGENTS.md.
# ===========================================================================

# --- OpenCode body (preinstalled once, reused every turn) -------------------
# Installed under /usr/local/lib so the non-root run user can traverse it.
FROM base AS body-opencode
RUN export HOME=/usr/local/lib/opencode-home \
 && curl -fsSL https://opencode.ai/install | bash \
 && chmod -R a+rX /usr/local/lib/opencode-home \
 && ln -sf /usr/local/lib/opencode-home/.opencode/bin/opencode /usr/local/bin/opencode
COPY --chown=1001:1001 ci/docker/harness/opencode.json /home/agent/.config/opencode/opencode.json
COPY --chown=1001:1001 ci/AGENTS.md /home/agent/.config/opencode/AGENTS.md

# --- Goose body (direct tarball: the download_cli.sh installer opens
#     /dev/tty and dies on headless runners — demo/01 turn 2 evidence) ------
FROM base AS body-goose
RUN mkdir -p /tmp/goose-dl \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 -m 300 -o /tmp/goose-dl/goose.tar.bz2 \
      https://github.com/block/goose/releases/download/stable/goose-x86_64-unknown-linux-gnu.tar.bz2 \
 && test -s /tmp/goose-dl/goose.tar.bz2 && tar -xjf /tmp/goose-dl/goose.tar.bz2 -C /tmp/goose-dl \
 && install -m 0755 /tmp/goose-dl/goose /usr/local/bin/goose \
 && rm -rf /tmp/goose-dl
COPY --chown=1001:1001 ci/docker/harness/goose-config.yaml /home/agent/.config/goose/config.yaml
COPY --chown=1001:1001 ci/AGENTS.md /home/agent/.config/goose/.goosehints

# --- Qoder body (keys landed 2026-10-21: Owner PAT -> repo secret
#     QODER_PERSONAL_ACCESS_TOKEN; CLI auto-detects CI and uses the PAT,
#     no browser — Task 6 auth research).
#     RUNTIME ROOT CAUSE (proof run 39467719908): the installer's `qoder'
#     launcher resolves the real CLI under ITS HOME — run the launcher
#     with HOME pinned to the install dir (build here, runtime in the
#     consumers' ci.yml). Version check is FATAL.
#     PATH FIX (CI evidence 2026-10-21, runs 39470194454/39470807232): the
#     installer does NOT put the dispatcher on PATH at all — it lives at
#     $HOME/.qoder/entry/qoder and resolves the real CLI via
#     $HOME/.local/bin/qodercli. Symlink the entry into /usr/local/bin. ---
FROM base AS body-qoder
RUN export HOME=/usr/local/lib/qoder-home \
 && curl -fsSL https://qoder.com/install | bash \
 && chmod -R a+rwX /usr/local/lib/qoder-home \
 && ln -sf /usr/local/lib/qoder-home/.qoder/entry/qoder /usr/local/bin/qoder \
 && timeout 60 qoder --version
COPY --chown=1001:1001 ci/AGENTS.md /home/agent/.qoder/AGENTS.md

# --- CodeBuddy body (Owner law 2026-10-21 17:47Z: CodeBuddy is kept for
#     its BUILT-IN models only. For API-served brains there is no novelty
#     in any body — "any agent can ride APIs, no surprise" — so the model
#     brain is installed into the BODY THAT FITS the work instead. Baked
#     and DORMANT until a CodeBuddy account credential exists (access
#     keys are pro-only; CODEBUDDY_AUTH_TOKEN / CODEBUDDY_API_KEY envs
#     ready to wire the moment one lands). Headless needs -y in -p mode
#     for tool use.) ----------------------------------------------------
FROM base AS body-codebuddy
RUN npm install -g @tencent-ai/codebuddy-code \
 && ln -sf "$(command -v codebuddy)" /usr/local/bin/codebuddy \
 && timeout 60 /usr/local/bin/codebuddy --version
# CB free tier 2026-11-03: only hy* models are free (ds@cb offer ended);
# the chain lane pins --model hy3 explicitly, this ENV documents the default.
ENV CODEBUDDY_DEFAULT_MODEL=hy3
COPY --chown=1001:1001 ci/AGENTS.md /home/agent/.codebuddy/CODEBUDDY.md

# --- pi body (earendil-works/pi 1.4.x — "a minimal, extensible agent
#     harness that you can make your own"; Owner order 2026-10-27 #hq:
#     look into its configs and customize it for agent-team usage).
#     CUSTOMIZED: the global law is baked into ~/.pi/agent/AGENTS.md —
#     pi's own docs (docs/configuration.md, read 2026-10-27): the agent
#     directory ~/.pi/agent holds AGENTS.md as "user instructions applied
#     across working directories". Headless: `pi --print`, `--mode json`.
#     Brains: BYOK via env vars / auth.json — keys are env-injected per
#     run, NEVER baked. npm --ignore-scripts per upstream README. ---
FROM base AS body-pi
RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent \
 && timeout 60 pi --version
COPY --chown=1001:1001 ci/AGENTS.md /home/agent/.pi/agent/AGENTS.md

# --- dsh body (DeepSeek Harness, @deepseek-ai/dsh 0.2.x — DEV PREVIEW,
#     breaking changes expected; Owner order 2026-10-27 #hq: add it).
#     Headless bundle: one-shot Agent/Session runner, no Host/HTTP —
#     CI-ready. Pure BYOK (DeepSeek key + anthropic/openai/moonshotai/zai
#     + custom OpenAI/Anthropic-compatible gateways): creds live in
#     $DSH_HOME/.credentials.yaml and are env-injected per run, NEVER
#     baked. The global law rides ci/bin/law_brief.sh (REQUIRED for
#     this body — no baked global slot) + project AGENTS.md. ---
FROM base AS body-dsh
RUN npm install -g @deepseek-ai/dsh \
 && timeout 60 dsh --version

# --- mcode body (MiniMax Code CLI 0.7.x). Headless: `mcode exec`
#     (PROVEN 2026-10-22 end-to-end); TUI `mcode`; `mcode init .` writes
#     the project AGENTS.md (project law auto-read). AUTH: repo secret
#     MCODE_AUTH_JSON -> CI writes ~/.minimax/auth/prod/en/mcode-public/
#     auth.json + auth-state.json at run time (CI-seedable refresh grant,
#     no PKCE needed — CANDIDATES.org profile). ASK-FIRST BODY (Owner
#     order 2026-10-27 #hq): the M-Plan-Free quota is LIMITED — the Lead
#     asks the Owner BEFORE a lane burns mcode credit. ---
FROM base AS body-mcode
RUN npm install -g @minimax-ai/code \
 && timeout 60 mcode --version

# --- Cursor CLI body (Anysphere; Owner correction 2026-10-27 #hq:
#     "Cursor, Copilot also have CLI"). Install verified headless
#     2026-10-27 (cursor/2026.10.22); the launcher resolves its own dir
#     through symlinks, so a /usr/local/bin symlink is safe. Headless:
#     `agent -p "..."` (--output-format text|json|stream-json, --trust).
#     Auth: CURSOR_API_KEY env per run — NEVER baked. Law: Cursor reads
#     AGENTS.md at the project root/subdirs + .cursor/rules; its "User
#     Rules" are dashboard-only (no file path) so the GLOBAL law rides
#     ci/bin/law_brief.sh (REQUIRED for this body). ASK-FIRST BODY:
#     Cursor usage is credit-limited — ask the Owner before a lane
#     burns it. ---
FROM base AS body-cursor
RUN export HOME=/usr/local/lib/cursor-home \
 && curl -fsSL https://cursor.com/install | bash \
 && chmod -R a+rX /usr/local/lib/cursor-home \
 && ln -sf /usr/local/lib/cursor-home/.local/bin/agent /usr/local/bin/agent \
 && ln -sf /usr/local/lib/cursor-home/.local/bin/cursor-agent /usr/local/bin/cursor-agent \
 && timeout 60 agent --version

# --- GitHub Copilot CLI body (@github/copilot 1.0.x; Owner correction
#     2026-10-27 #hq: "Copilot also has CLI"). Installer verified
#     headless 2026-10-27 (PREFIX=/usr/local). Headless: `copilot -p
#     "..."` (--allow-tool / --allow-all-tools). Auth: GH_TOKEN or
#     GITHUB_TOKEN env (fine-grained PAT with the "Copilot Requests"
#     permission) — env-injected per run, NEVER baked. VERIFIED
#     user-level global instructions: $HOME/.copilot/copilot-instructions.md
#     (+ modular $HOME/.copilot/instructions/*.instructions.md;
#     COPILOT_HOME redirects; docs: Copilot CLI > Customize Copilot >
#     Custom instructions) — GLOBAL law BAKED there below, prepend-free.
#     Also reads repo .github/copilot-instructions.md + AGENTS.md
#     natively (LOCAL law). ASK-FIRST BODY (Owner 2026-10-27 #hq):
#     EVERY prompt burns one premium request from the monthly quota —
#     ask the Owner before a lane uses it. ---
FROM base AS body-copilot
RUN curl -fsSL https://gh.io/copilot-install | PREFIX=/usr/local bash \
 && timeout 60 copilot --version
COPY --chown=1001:1001 ci/AGENTS.md /home/agent/.copilot/copilot-instructions.md

# --- OMP body (oh-my-pi, omp.sh — Owner roster CHARTER.md MODELS/Local).
#     Owner order 2026-10-27 #hq: "where is OMP?" — it sat roster-only,
#     never baked. Binary install verified headless 2026-10-27: static
#     omp-linux-x64 (no dynamic deps), sha256-verified by the installer,
#     no bun needed (--binary mode). Version check is FATAL like the
#     other bodies. ---
FROM base AS body-omp
RUN export HOME=/usr/local/lib/omp-home \
 && curl -fsSL https://omp.sh/install | sh -s -- --binary \
 && chmod -R a+rX /usr/local/lib/omp-home \
 && ln -sf /usr/local/lib/omp-home/.local/bin/omp /usr/local/bin/omp \
 && timeout 60 omp --version
COPY --chown=1001:1001 ci/AGENTS.md /home/agent/.omp/agent/AGENTS.md
COPY --chown=1001:1001 ci/AGENTS.md /home/agent/.omp/agent/RULES.md

# --- Devin body (CognitionAI/devin-cli — OWNER ORDER 2026-10-29 #hq:
#     "Add devin to docker with auth"). npm `devin' 3000.11.x; --version
#     verified headless 2026-10-29 in-sandbox. ACP server: `devin acp'
#     (JSON-RPC over stdio, docs.devin.ai/cli/reference/commands — the
#     SAME subcommand Zed/JetBrains/Xcode spawn; initialize smoke-tested
#     2026-10-29). Headless single-turn: `devin -p ... --respect-
#     workspace-trust false' in CI. AUTH (never baked; CORRECTED
#     2026-10-29 — Owner intel + in-sandbox measurement, 3000.11.228):
#     the vendor doc line "reads WINDSURF_API_KEY if set" is CLOUD-
#     sessions only — the local `devin acp' server ignores it (with
#     the key set: initialize answers nothing, exit 0; `devin models':
#     "Not logged in") and honors ONLY the credentials.toml written by
#     a real `devin auth login' (browser PKCE; --force-manual-token-
#     flow pastes the browser-issued CODE, not the API key — re-measured
#     2026-11-01 on 3000.11.234: pasting the cog_ key there fails with
#     "Failed to exchange code"). RE-VERIFIED 2026-11-01, headless
#     forge replaces the PKCE courier plan: credentials.toml is a plain
#     TOML {windsurf_api_key = <DEVIN_API_KEY>} (chmod 600) — the CLI
#     validates it server-side vs server.codeium.com (`devin models`
#     lists 46 families with the real key; a fake key errors
#     "Authentication required: invalid api key"). CI restores it per
#     run from the DEVIN_API_KEY secret; recipe sealed in vault
#     secrets/README.md (a38e8ab).
#     Global law slot VERIFIED: ~/.config/devin/AGENTS.md — baked below,
#     prepend-free. ---
FROM base AS body-devin
RUN npm install -g devin \
 && timeout 60 devin --version
COPY --chown=1001:1001 ci/AGENTS.md /home/agent/.config/devin/AGENTS.md

# --- Cline body (npm `cline' 3.x — the umbrella QA seat's body,
#     nemotron-3.5-lightning@cline; bake unblocks the QA seat's
#     cline-on-CI body proof — installs in CI are banned 2026-10-20).
#     ACP server: `cline --acp' (what agent-org fronts). Version check
#     is FATAL. AUTH (never baked): its own credential store — vault
#     holds CLINE_API_KEY / CLINE_AUTH_JSON for CI injection; --data-dir
#     isolates state per seat. NO verified global rules path — the
#     global law rides ci/bin/law_brief.sh (REQUIRED for this body,
#     same treatment as dsh/Cursor/mcode), LOCAL law = repo-root
#     AGENTS.md. No invented paths. ---
FROM base AS body-cline
RUN npm install -g cline \
 && timeout 60 cline --version

# --- gemini-cli body (WO-16 Lead step, Owner order 2026-10-29 #hq "Add
#     all missing ACP clients to agent-org"): the parity seat wired the
#     provider entry on vendor docs (geminicli.com --acp flag) and
#     REPORTED the evidence gap — the binary was never in the image.
#     Bake closes it: npm @google/gemini-cli, FATAL --version. AUTH
#     (never baked): its own credential store / GEMINI_API_KEY at run
#     time. ACP surface re-prove (initialize/loadSession) = seat work
#     per the WO-16 note. ---
FROM base AS body-gemini
RUN npm install -g @google/gemini-cli \
 && timeout 60 gemini --version

# --- kilo body (WO-20 half (a), Owner order 2026-10-29 #hq "add Kilo
#     Code"): bake a kilo body beside the devin/cline bodies. npm
#     @kilocode/cli, command `kilo`, headless `kilo run --auto` (verify
#     flags against the CLI's own help at run time — REPORT gaps, never
#     invent). FATAL --version. NO creds baked — auth rides the seat's
#     own store / vault holds. ---
FROM base AS body-kilo
RUN npm install -g @kilocode/cli \
 && timeout 60 kilo --version

# --- pi-acp adapter (github.com/svkozak/pi-acp; npm --ignore-scripts,
#     the same hygiene as the pi body). Closes the ONE body the image
#     bakes but could not drive: agent-org's pi provider spawns
#     `pi-acp' (reported to @lead 2026-10-28). FATAL check = a live
#     initialize handshake (grep agentInfo) — the adapter has no
#     documented --version. Smoke-tested 2026-10-29: answers
#     "pi-acp" 0.0.34, loadSession t, session list + delete. pi's own
#     config stays the credential store; nothing exported.
#     FIX 2026-10-30: the install RUN was missing (smoke test only) —
#     every harness build died here since b59ebba, stalling the
#     agent-org chain (STALL 46, "segment no-branch"). ---
FROM base AS body-pi-acp
RUN npm install -g --ignore-scripts pi-acp
RUN printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}' \
  | timeout 60 pi-acp | grep -q 'pi-acp'

# ===========================================================================
# Full harness: base + EVERY body unioned together. DEFAULT target —
# legacy `docker buildx build` without --target keeps producing exactly
# this image (the agent-team.el ghcr publish job and dormant teams).
# Modular runs do NOT build this stage; they overlay only their bodies.
# COPY of a directory MERGES into the destination (never deletes), so
# overlaying each body's /usr/local + /home/agent onto base keeps base
# files (team-chat, /opt/agent-team) and sibling-body files intact.
# ===========================================================================
FROM base AS harness
COPY --from=body-opencode /usr/local /usr/local
COPY --from=body-opencode --chown=1001:1001 /home/agent /home/agent
COPY --from=body-goose /usr/local /usr/local
COPY --from=body-goose --chown=1001:1001 /home/agent /home/agent
COPY --from=body-qoder /usr/local /usr/local
COPY --from=body-qoder --chown=1001:1001 /home/agent /home/agent
COPY --from=body-codebuddy /usr/local /usr/local
COPY --from=body-codebuddy --chown=1001:1001 /home/agent /home/agent
COPY --from=body-pi /usr/local /usr/local
COPY --from=body-pi --chown=1001:1001 /home/agent /home/agent
COPY --from=body-dsh /usr/local /usr/local
COPY --from=body-dsh --chown=1001:1001 /home/agent /home/agent
COPY --from=body-mcode /usr/local /usr/local
COPY --from=body-mcode --chown=1001:1001 /home/agent /home/agent
COPY --from=body-cursor /usr/local /usr/local
COPY --from=body-cursor --chown=1001:1001 /home/agent /home/agent
COPY --from=body-copilot /usr/local /usr/local
COPY --from=body-copilot --chown=1001:1001 /home/agent /home/agent
COPY --from=body-omp /usr/local /usr/local
COPY --from=body-omp --chown=1001:1001 /home/agent /home/agent
COPY --from=body-devin /usr/local /usr/local
COPY --from=body-devin --chown=1001:1001 /home/agent /home/agent
COPY --from=body-cline /usr/local /usr/local
COPY --from=body-cline --chown=1001:1001 /home/agent /home/agent
COPY --from=body-gemini /usr/local /usr/local
COPY --from=body-gemini --chown=1001:1001 /home/agent /home/agent
COPY --from=body-kilo /usr/local /usr/local
COPY --from=body-kilo --chown=1001:1001 /home/agent /home/agent
COPY --from=body-pi-acp /usr/local /usr/local
COPY --from=body-pi-acp --chown=1001:1001 /home/agent /home/agent
RUN chown -R agent:agent /home/agent
