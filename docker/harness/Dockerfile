# agent-org agent harness — CI turn container with agent bodies
# PREINSTALLED (Owner order 2026-10-20 #hq: agents go into the image,
# not into CI). Secrets are NEVER baked: keys are env-injected per run
# from repo secrets.
#
# Bodies chosen BY FIT:
#   - qoder  — agentic coding CLI, PAT-auth (auto-detects CI, no
#              browser); the ONE lane PROVEN on CI for this team family
#              (agent-team.el run 39477554903, admincraft run
#              39477554903-family: real qoder JSON results).
#   - emacs-nox — the repo IS Emacs Lisp: byte-compile + ERT run at
#              turn time inside the container, same as the landing gate.
#
# Repo deps: none beyond emacs (org is built-in; acp mock is in tests/).

FROM buildpack-deps:bookworm-scm

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      emacs-nox jq procps \
 && rm -rf /var/lib/apt/lists/*

# --- Qoder body (exact recipe proven in khaalidrafi/agent-team.el:
#     install under /usr/local/lib/qoder-home, a+rwX, symlink the ENTRY
#     dispatcher, and pin HOME=/usr/local/lib/qoder-home at RUNTIME —
#     the launcher resolves the real CLI under ITS HOME, so a plain
#     /home/agent HOME prints "Qoder CLI is not installed").
#     Version check is FATAL. ----------------------------------------
RUN export HOME=/usr/local/lib/qoder-home \
 && curl -fsSL https://qoder.com/install | bash \
 && chmod -R a+rwX /usr/local/lib/qoder-home \
 && ln -sf /usr/local/lib/qoder-home/.qoder/entry/qoder /usr/local/bin/qoder \
 && timeout 60 env HOME=/usr/local/lib/qoder-home qoder --version

# --- Non-root run user (matches the Actions runner uid 1001) -----------
RUN useradd -m -u 1001 agent

ENV HOME=/home/agent
USER agent
