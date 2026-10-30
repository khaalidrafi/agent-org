;;; agent-org-providers.el --- Provider definitions for agent-org -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Khalid

;; Author: Khalid
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (acp "0.14.3"))
;; Keywords: tools, agents, ai

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Each provider is a plist:
;;   :id           - symbol (e.g. 'goose)
;;   :name         - human-readable name
;;   :command      - full command line (binary . args), e.g. '("goose" "acp")
;;   :environment  - function returning a list of "VAR=val" strings
;;   :model        - optional model id to pin for every session of this
;;                   provider (see `agent-org--apply-pinned-model').  Only
;;                   meaningful when the agent exposes a `model' config
;;                   option, which is how ONE ACP server fronts MANY models
;;                   — OpenCode does.  An agent that is itself a single
;;                   vendor's product (MiniMax Code, Qoder) needs no pin:
;;                   its own default model is already the right one.
;;
;; Add a provider by pushing onto `agent-org-providers', and give it the
;; matching entry point `agent-org-<id>-start-agent' (the naming follows
;; agent-shell: `agent-shell-goose-start-agent' etc.), which a test in
;; tests/test-agent-org.el checks for every registered id.

;;; Code:

(require 'cl-lib)
(require 'map)

;; agent-org.el requires this file, so the link is one-way: the
;; `agent-org-<id>-start-agent' commands below are compiled against a
;; declaration and resolved when the package is loaded.
(declare-function agent-org-start "agent-org" (provider))

(defcustom agent-org-providers
  (list
   ;; slave-agent (https://github.com/<fork>) is the master's own agent: a
   ;; light-core Hermes derivative built for devs, hackers and power users, and
   ;; the reason this package exists.  Its ACP server is a standalone console
   ;; script (`slave-acp', = acp_adapter.entry:main) rather than a CLI
   ;; subcommand, so an editor spawn does not load the whole `slave' CLI, and it
   ;; never provisions dependencies on launch — the package manager owns that.
   ;; It answers `session/list' and supports `session/load', so resume works,
   ;; and it fronts many providers through its own config, so pin nothing:
   ;; ~/.slave/config.yaml already names the model.  Credentials live in
   ;; ~/.slave/.env, which the adapter loads itself, so nothing is exported by
   ;; default; `SLAVE_HOME' is passed through when set, which is how an Emacs
   ;; session talks to one profile's state dir instead of the launch default.
   (list :id 'slave-agent
         :name "slave-agent"
         :command '("slave-acp")
         :environment #'agent-org-slave-agent-environment)
   (list :id 'goose
         :name "Goose"
         :command '("goose" "acp")
         :environment #'agent-org-goose-environment)
   (list :id 'qoder
         :name "Qoder"
         :command '("qoder" "--acp")
         :environment #'agent-org-qoder-environment)
   (list :id 'opencode
         :name "OpenCode"
         :command '("opencode" "acp")
         :environment #'agent-org-opencode-environment)
   ;; MiniMax Code (`mcode') is its own terminal coding agent with its own
   ;; stdio ACP server — a different product from OpenCode, which merely
   ;; *hosts* MiniMax models among many others.  So `minimax' spawns
   ;; `mcode acp' and pins nothing: the CLI's own default model
   ;; (`defaultModel' in ~/.minimax/config.yaml) is a MiniMax model
   ;; already.
   (list :id 'minimax
         :name "MiniMax"
         :command '("mcode" "acp")
         :environment #'agent-org-mcode-environment)
   ;; GitHub Copilot is its OWN ACP agent — the `copilot' CLI exposes an ACP
   ;; server with `--acp' (public preview).  It fronts several models but its
   ;; own default is the right starting point, so pin nothing (like MiniMax);
   ;; a headless COPILOT_GITHUB_TOKEN is passed through when the environment
   ;; already carries one, otherwise the CLI's own login is used.
   (list :id 'copilot
         :name "Copilot"
         :command '("copilot" "--acp")
         :environment #'agent-org-copilot-environment)
   ;; Cursor's terminal agent binary is `agent' (NOT `cursor'), and ACP is a
   ;; subcommand — mirroring agent-shell's `agent-shell-cursor-acp-command'.
   ;; Auth defaults to an external `agent login'; CURSOR_API_KEY /
   ;; CURSOR_AUTH_TOKEN are passed through when present.  (agent-shell can also
   ;; drive an ACP `cursor_login' authenticate request; agent-org has no
   ;; authenticate step in its handshake, so we rely on the out-of-band path.)
   (list :id 'cursor
         :name "Cursor"
         :command '("agent" "acp")
         :environment #'agent-org-cursor-environment)
   ;; CodeBuddy (`codebuddy --acp') is its own CLI agent, login kept by the CLI.
   (list :id 'codebuddy
         :name "CodeBuddy"
         :command '("codebuddy" "--acp")
         :environment #'agent-org-codebuddy-environment)
   ;; Cline is its own CLI agent whose ACP server is exposed with `--acp'
   ;; (command mirrors agent-shell's `agent-shell-cline-acp-command').  Like
   ;; CodeBuddy it keeps its own credential store, so nothing is exported and
   ;; no model is pinned — Cline is a single product, not a server fronting
   ;; many models.
   (list :id 'cline
         :name "Cline"
         :command '("cline" "--acp")
         :environment #'agent-org-cline-environment)
   ;; OMP (oh-my-pi, omp.sh) is a native ACP agent: `omp acp' over stdio is
   ;; the launch shape its own docs recommend for client configuration
   ;; (omp.sh/docs/acp — `omp --mode acp' is equivalent but not the
   ;; recommended spelling).  MEASURED in the harness image 2026-10-28
   ;; (omp v18.13.3): `omp --help' COMMANDS lists `acp — Run omp as an ACP
   ;; (Agent Client Protocol) server over stdio' and `omp acp --help' takes
   ;; no flags.  It advertises session create/list/load/resume/fork/close,
   ;; so resume works, and it resolves its own model from
   ;; ~/.omp/agent/config.yml plus `PI_*' credential env fallbacks to its
   ;; stored login (PI_LLM_API_KEY &c., all present in the binary), so pin
   ;; nothing.  `OMP_PROFILE' / `PI_CONFIG_DIR' are the documented selectors
   ;; of WHICH omp profile owns the session, so those two pass through.
   ;; LIVE SMOKE 2026-10-28 (this image): an `initialize' over stdin answers
   ;; loadSession t and sessionCapabilities (list, fork, resume, close), so
   ;; resume-replay and the pager both apply to it.  It also carries
   ;; _meta.steering.supported = t — a vendor hint, NOT the ACP standard, so
   ;; the Steer port goes through the standard `session/cancel' plus a new
   ;; prompt (TODOs.org §Steer) and reads no _meta.
   (list :id 'omp
         :name "OMP"
         :command '("omp" "acp")
         :environment #'agent-org-omp-environment)
   ;; Pi (earendil-works/pi) has NO native ACP server, so this rides the
   ;; community adapter `pi-acp' (github.com/svkozak/pi-acp, npm install -g
   ;; pi-acp), which speaks ACP JSON-RPC over stdio and spawns
   ;; `pi --mode rpc' itself.  MEASURED 2026-10-28: `pi --help' (v1.4.x in
   ;; the image) lists modes text/json/rpc and NO acp subcommand, so the
   ;; adapter is the only ACP surface.  Two limits the adapter documents and
   ;; an ACP client must respect: it implements NO fs/* or terminal/*
   ;; delegation (pi reads, writes and executes locally, so an editor's
   ;; unsaved buffers are invisible to it), and MCP servers arrive in the
   ;; params but are never wired through to pi.  It answers `session/load'
   ;; from its OWN map file (~/.pi/pi-acp/session-map.json), not from ACP
   ;; history.  Provider keys belong to pi's own config — nothing is
   ;; exported.
   ;; NOT SMOKE-TESTED: the harness image bakes `pi' but not the `pi-acp'
   ;; adapter, so a Pi chat needs `npm install -g pi-acp' first (reported to
   ;; @lead 2026-10-28 as the one body the image still cannot drive).
   (list :id 'pi
         :name "Pi"
         :command '("pi-acp")
         :environment #'agent-org-pi-environment)
   ;; DSH (DeepSeek Harness, @deepseek-ai/dsh) serves ACP as a PROFILE, not
   ;; a flag or a separate bin: `dsh --profile acp' (apps/cli/README — "SDK
   ;; and ACP are profiles, not separate public bins").  MEASURED in the
   ;; harness image 2026-10-28 (dsh 0.2.1-rc.2): the baked
   ;; `@deepseek-ai/dsh-acp-app' names its command "dsh --profile acp"
   ;; (lib/index.js:21), so the shape is the vendor's own, not invented.
   ;; Its automation surface (packages/acp/acp/README) is narrower than the
   ;; others: session/list, `session/resume' and `session/close' yes,
   ;; `session/load', fork, delete, modes, commands, plans, terminals and
   ;; client filesystem operations NO.  So resume-replay is unavailable and
   ;; `agent-org-start' degrades to `session/new' at the capability gate;
   ;; `agent-org-resume-session' says so rather than hanging.  Model and
   ;; reasoning effort DO arrive as `session/set_config_option' options, so
   ;; the C-c a m path works (`:mode' is not — dsh rejects modes).
   ;; Credentials live in $DSH_HOME/.credentials.yaml; DEEPSEEK_API_KEY is
   ;; the documented `apiKeyEnv' default fallback for the official route.
   ;; LIVE SMOKE 2026-10-28 (this image): `initialize' answers
   ;; agentInfo "deepseek-harness-acp" with sessionCapabilities (close,
   ;; list, resume) and NO loadSession key at all — exactly the gate our
   ;; `agent-org--supports-load-p' reads, so a DSH chat opens fresh.
   (list :id 'dsh
         :name "DSH"
         :command '("dsh" "--profile" "acp")
         :environment #'agent-org-dsh-environment)
   ;; Gemini CLI (google-gemini/gemini-cli) serves ACP with the `--acp' FLAG,
   ;; verified against its own developer guide BEFORE wiring (geminicli.com/
   ;; docs/cli/acp-mode, page updated 2026-04-10): "To start Gemini CLI in ACP
   ;; mode, use the `--acp' flag:  gemini --acp" — JSON-RPC 2.0 over stdio,
   ;; implementation in packages/cli/src/acp/acpClient.ts.  NOT baked in the
   ;; harness image: measured 2026-10-29 in this very container, `gemini' is
   ;; absent from PATH, so `agent-org--open-session' raises "Command not
   ;; found: gemini" until `npm install -g @google/gemini-cli' runs (reported
   ;; to @lead) — the same standing Cline has, a real ACP agent the roster
   ;; test does not claim the image provides.
   ;; Its documented method list covers `initialize', `newSession',
   ;; `loadSession', `prompt' and `cancel', so resume-REPLAY applies — but
   ;; `session/list' is NOT among the listed methods, so the picker may have
   ;; nothing to page: `agent-org--lists-sessions-p' reads the advertisement
   ;; and failure degrades to `session/new' with an echo-area note (§10).
   ;; `setSessionMode' moves the tool-approval level (modes exist), and the
   ;; model arrives through `unstable_setSessionModel' — NOT a `model' config
   ;; option, which is why nothing is PINNED here: a pin rides
   ;; `session/set_config_option' and `agent-org--apply-pinned-model' sends
   ;; only an advertised id.  Unlike the `pi-acp' adapter it does implement
   ;; the proxied file system (agent reads and writes through the ACP client)
   ;; and it wires MCP servers registered at `initialize' through to the
   ;; model.
   ;; The capabilities above are READ FROM THE DOCS, not from a live
   ;; `initialize' — this image has no `gemini' to ask.  A smoke test after it
   ;; is baked should re-prove them the way 8ca27a8 re-proved omp and dsh.
   ;; Auth is the CLI's own: `gemini' sign-in with a Google account caches
   ;; credentials under ~/.gemini, and the documented headless path is
   ;; GEMINI_API_KEY (AI Studio) or Vertex AI ADC.  A live ACP `authenticate'
   ;; request would open a browser, which an Emacs-spawned child cannot finish
   ;; — same out-of-band story as Cursor and Cline.
   (list :id 'gemini
         :name "Gemini"
         :command '("gemini" "--acp")
         :environment #'agent-org-gemini-environment)
  ;; Devin (CognitionAI/devin-cli) serves ACP natively: `devin acp' speaks
  ;; JSON-RPC over stdio and is meant to be spawned by an ACP-aware client —
  ;; the same subcommand Zed, JetBrains and Xcode configure (docs.devin.ai/
  ;; cli/reference/commands).  MEASURED 2026-10-29 (devin 3000.11.228,
  ;; in-sandbox smoke): an `initialize' over stdio starts the server
  ;; (acp_startup log, credential load step present).  AUTH — the vendor
  ;; doc says the ACP server "reads credentials from WINDSURF_API_KEY if
  ;; set, otherwise from the credentials stored by `devin auth login'",
  ;; but MEASURED 2026-10-29 (Owner intel, confirmed in-sandbox on
  ;; 3000.11.228): WINDSURF_API_KEY serves CLOUD sessions only — with it
  ;; set the local server still exits silently on initialize (no JSON-RPC
  ;; response, exit 0) and `devin models' reports "Not logged in".  The
  ;; local ACP server honors ONLY the credentials.toml written by a real
  ;; `devin auth login' (browser PKCE; --force-manual-token-flow pastes
  ;; the browser-issued code, NOT the API key).  agent-org therefore
  ;; passes the env through untouched (cloud lanes may use it) while the
  ;; seat's real activation = CLI login credentials.  It fronts many models ("every frontier model") and DEVIN_MODEL
  ;; is its documented default-model selector, so pin nothing — the
  ;; account's own default is already right; DEVIN_MODEL passes through
  ;; when the environment names it.
  ;; CI HAS NO BROWSER: a lane that must authenticate non-interactively
  ;; carries the whole login file in DEVIN_CREDENTIALS_TOML, and
  ;; `agent-org-devin-environment' materialises it before the spawn (WO-17).
  (list :id 'devin
        :name "Devin"
        :command '("devin" "acp")
        :environment #'agent-org-devin-environment))
  "List of supported ACP providers.
Each entry is a plist; see `agent-org-providers.el' commentary."
  :type '(repeat sexp)
  :group 'agent-org)

(defcustom agent-org-default-provider 'qoder
  "Provider `agent-org-resume-session' uses when called without a prefix arg.
Must be the `:id' of an entry in `agent-org-providers'.  Qoder is the
default because it answers `session/list' and supports
`session/load', which is what resume needs; Goose advertises both but
its `session/list' does not answer in practice.  slave-agent implements
both methods too, and becomes the better default as soon as it is proven
live on that path from this package -- until then the claim is untested."
  :type '(choice (const :tag "slave-agent" slave-agent)
                 (const :tag "Qoder" qoder)
                 (const :tag "Goose" goose)
                 (const :tag "OpenCode" opencode)
                 (const :tag "MiniMax" minimax)
                 (const :tag "Copilot" copilot)
                 (const :tag "Cursor" cursor)
                 (const :tag "CodeBuddy" codebuddy)
                 (const :tag "Cline" cline)
                 (const :tag "OMP" omp)
                 (const :tag "Pi" pi)
                 (const :tag "DSH" dsh)
                 (const :tag "Gemini" gemini)
                 (const :tag "Devin" devin)
                 (symbol :tag "Other provider id"))
  :group 'agent-org)

;;;###autoload
(defun agent-org-slave-agent-start-agent ()
  "Start an interactive slave-agent agent-org chat.
slave-agent is the master's own agent, so this is the command the package
was written around: it opens on the model named in ~/.slave/config.yaml
(no pin) and resumes the directory's earlier slave-agent sessions through
`session/list'.  Run `slave-acp --check' in a shell if this fails to
start -- that says whether the ACP extra is installed."
  (interactive)
  (agent-org-start 'slave-agent))

;;;###autoload
(defun agent-org-goose-start-agent ()
  "Start an interactive Goose agent-org chat."
  (interactive)
  (agent-org-start 'goose))

;;;###autoload
(defun agent-org-qoder-start-agent ()
  "Start an interactive Qoder agent-org chat."
  (interactive)
  (agent-org-start 'qoder))

;;;###autoload
(defun agent-org-opencode-start-agent ()
  "Start an interactive OpenCode agent-org chat.
OpenCode is one ACP server fronting many vendors' models, so this opens
on its shared default; use `agent-org-set-session-model' to move between
them, MiniMax included."
  (interactive)
  (agent-org-start 'opencode))

;;;###autoload
(defun agent-org-minimax-start-agent ()
  "Start an interactive MiniMax Code agent-org chat.
MiniMax Code is `mcode', its own agent — not MiniMax models served
through OpenCode."
  (interactive)
  (agent-org-start 'minimax))

;;;###autoload
(defun agent-org-copilot-start-agent ()
  "Start an interactive GitHub Copilot agent-org chat.
The `copilot' CLI serves ACP over `--acp' (public preview); authenticate
with the CLI's own login once outside Emacs, or export
COPILOT_GITHUB_TOKEN for headless use."
  (interactive)
  (agent-org-start 'copilot))

;;;###autoload
(defun agent-org-cursor-start-agent ()
  "Start an interactive Cursor agent-org chat.
Cursor's terminal agent is the `agent' binary and ACP is its subcommand
(`agent acp'); log in once outside Emacs with `agent login', or export
CURSOR_API_KEY / CURSOR_AUTH_TOKEN."
  (interactive)
  (agent-org-start 'cursor))

;;;###autoload
(defun agent-org-codebuddy-start-agent ()
  "Start an interactive CodeBuddy agent-org chat.
CodeBuddy keeps its own login, so run `codebuddy' once outside Emacs to
authenticate before starting (`codebuddy --acp')."
  (interactive)
  (agent-org-start 'codebuddy))

;;;###autoload
(defun agent-org-cline-start-agent ()
  "Start an interactive Cline agent-org chat.
Cline's CLI serves ACP over `--acp'; it keeps its own credential store, so
sign in once outside Emacs (see https://cline.bot/cli) before starting."
  (interactive)
  (agent-org-start 'cline))

;;;###autoload
(defun agent-org-omp-start-agent ()
  "Start an interactive OMP (oh-my-pi) agent-org chat.
OMP serves ACP natively on stdio (`omp acp'); it authenticates from its own
stored credentials or `PI_*' environment fallbacks, so run `omp' and
`/login <provider>' once outside Emacs if this fails to start
(https://omp.sh/docs/acp)."
  (interactive)
  (agent-org-start 'omp))

;;;###autoload
(defun agent-org-pi-start-agent ()
  "Start an interactive Pi agent-org chat through the `pi-acp' adapter.
Pi has no ACP server of its own: this spawns `pi-acp', which bridges ACP
stdio to `pi --mode rpc' (github.com/svkozak/pi-acp, `npm install -g
pi-acp' -- the harness image bakes `pi' but not the adapter).  Expect the
adapter's documented limits — no client filesystem or terminal delegation,
and MCP servers are not passed through to pi.  Pi keeps its own provider
config, so configure that outside Emacs first."
  (interactive)
  (agent-org-start 'pi))

;;;###autoload
(defun agent-org-dsh-start-agent ()
  "Start an interactive DSH (DeepSeek Harness) agent-org chat.
ACP is a profile there, not a flag: this spawns `dsh --profile acp', which
auto-initializes on first use (apps/cli/README in deepseek-ai/deepseek-
harness).  The automation surface omits `session/load', so a DSH chat opens
fresh and resumes by listing rather than replaying history; store the key
through dsh's own settings or export DEEPSEEK_API_KEY."
  (interactive)
  (agent-org-start 'dsh))

;;;###autoload
(defun agent-org-gemini-start-agent ()
  "Start an interactive Gemini CLI agent-org chat.
Gemini CLI serves ACP over stdio with the `--acp' flag (`gemini --acp', see
https://geminicli.com/docs/cli/acp-mode); it keeps its own credentials —
sign in with a Google account once outside Emacs, or export GEMINI_API_KEY
for the documented headless path.  The harness image does not bake `gemini'
yet, so this raises \"Command not found\" until `npm install -g
@google/gemini-cli'."
  (interactive)
  (agent-org-start 'gemini))

;;;###autoload
(defun agent-org-devin-start-agent ()
  "Start an interactive Devin agent-org chat.
Devin serves ACP natively on stdio (`devin acp' — the subcommand Zed,
JetBrains and Xcode spawn); authenticate once outside Emacs with
`devin auth login' — the only credential the local ACP server honors
(WINDSURF_API_KEY serves Devin's cloud sessions, not local ACP).
A machine with no browser can carry that login file instead: export
DEVIN_CREDENTIALS_TOML and it is placed before the spawn."
  (interactive)
  (agent-org-start 'devin))

(defun agent-org--env-value (var)
  "The value of environment VAR, or nil when unset OR empty.
`getenv' answers \"\" for a `VAR=' entry, which is non-nil: forwarding that
would set the child's VAR to blank and OVERRIDE the agent's own credential
resolution (its login, its ~/.…/.env) with nothing.  Every provider here is
pass-through-or-nothing, so a blank is the same as absent."
  (let ((value (getenv var)))
    (when (and value (not (string-empty-p value)))
      value)))

(defun agent-org-slave-agent-environment ()
  "Return environment variables for the slave-agent ACP client.
Nothing is exported by default: the adapter loads ~/.slave/.env itself, so
the credential store is out of Emacs's hands.  `SLAVE_HOME' is the state
dir the agent binds, and one slave-agent process may serve many profiles,
so passing it through is how an Emacs chat opens against a specific
profile's home rather than the launch default."
  (let ((home (agent-org--env-value "SLAVE_HOME")))
    (when home
      (list (format "SLAVE_HOME=%s" home)))))

(defun agent-org-goose-environment ()
  "Return environment variables for the Goose ACP client.
Uses OPENAI_API_KEY from the environment if present."
  (let ((key (agent-org--env-value "OPENAI_API_KEY")))
    (when key
      (list (format "OPENAI_API_KEY=%s" key)))))

(defun agent-org-opencode-environment ()
  "Return environment variables for the OpenCode ACP client.
OpenCode keeps its own credential store (`opencode auth login'), so
nothing has to be exported and this returns nil by default; a MINIMAX_API
key in the environment is passed through for configs that read it."
  (let ((key (or (agent-org--env-value "MINIMAX_API_KEY")
                 (agent-org--env-value "MINIMAX_CODE_KEY"))))
    (when key
      (list (format "MINIMAX_API_KEY=%s" key)))))

(defun agent-org-mcode-environment ()
  "Return environment variables for the MiniMax Code (`mcode') ACP client.
MiniMax Code keeps its own login (`mcode login', or `mcode acp login') in
`~/.minimax/auth', so nothing has to be exported and this returns nil by
default; a MINIMAX_API_KEY in the environment is passed through for
configs that read it."
  (let ((key (agent-org--env-value "MINIMAX_API_KEY")))
    (when key
      (list (format "MINIMAX_API_KEY=%s" key)))))

(defun agent-org-qoder-environment ()
  "Return environment variables for the Qoder ACP client.
Passes QODER_PERSONAL_ACCESS_TOKEN through when the environment has
it; otherwise the CLI's own stored login (`qoder login') is used."
  (let ((token (agent-org--env-value "QODER_PERSONAL_ACCESS_TOKEN")))
    (when token
      (list (format "QODER_PERSONAL_ACCESS_TOKEN=%s" token)))))

(defun agent-org-copilot-environment ()
  "Return environment variables for the GitHub Copilot ACP client.
Copilot keeps its own login (the device flow), so nothing is exported by
default; COPILOT_GITHUB_TOKEN is passed through when the environment has
it, which is the CLI's documented non-interactive credential."
  (let ((token (agent-org--env-value "COPILOT_GITHUB_TOKEN")))
    (when token
      (list (format "COPILOT_GITHUB_TOKEN=%s" token)))))

(defun agent-org-cursor-environment ()
  "Return environment variables for the Cursor agent ACP client.
Authentication defaults to an external `agent login', so nil is returned;
CURSOR_API_KEY (preferred) or CURSOR_AUTH_TOKEN is passed through when the
environment carries one.  These are the same two secrets agent-shell's
`agent-shell-cursor-authentication' accepts, minus its optional ACP
`cursor_login' handshake, which agent-org does not drive."
  (cond ((agent-org--env-value "CURSOR_API_KEY")
         (list (format "CURSOR_API_KEY=%s"
                       (agent-org--env-value "CURSOR_API_KEY"))))
        ((agent-org--env-value "CURSOR_AUTH_TOKEN")
         (list (format "CURSOR_AUTH_TOKEN=%s"
                       (agent-org--env-value "CURSOR_AUTH_TOKEN"))))))

(defun agent-org-codebuddy-environment ()
  "Return environment variables for the CodeBuddy ACP client.
CodeBuddy keeps its own login (`codebuddy' signed in outside Emacs), so
nothing has to be exported and this returns nil by default."
  nil)

(defun agent-org-cline-environment ()
  "Return environment variables for the Cline ACP client.
Cline keeps its own credential store (signed in through the CLI outside
Emacs), so nothing has to be exported and this returns nil by default —
the same out-of-band login CodeBuddy uses."
  nil)

(defun agent-org-omp-environment ()
  "Return environment variables for the OMP (oh-my-pi) ACP client.
Nothing credential-shaped is forwarded: omp resolves `PI_*' provider keys
against its own stored login (omp.sh/docs/env), and Emacs reading that
store would make it a second source of truth for a secret.  `OMP_PROFILE'
and `PI_CONFIG_DIR' are the documented selectors of which omp profile and
config root the session binds — the same steer `SLAVE_HOME' is for
slave-agent — so they pass through when the environment names them."
  (let ((profile (agent-org--env-value "OMP_PROFILE"))
        (config-dir (agent-org--env-value "PI_CONFIG_DIR"))
        (out nil))
    (when profile
      (setq out (cons (format "OMP_PROFILE=%s" profile) out)))
    (when config-dir
      (setq out (cons (format "PI_CONFIG_DIR=%s" config-dir) out)))
    (nreverse out)))

(defun agent-org-pi-environment ()
  "Return environment variables for the Pi ACP client.
ALWAYS nil.  The `pi-acp' adapter runs the `pi' executable, and pi resolves
its provider keys from its own settings and auth.json (its README:
\"configure pi separately for your model providers/API keys\") — so there is
no variable this package may name.  Forwarding a key would be exactly the
second source of truth the Secret Law forbids."
  nil)

(defun agent-org-dsh-environment ()
  "Return environment variables for the DSH (DeepSeek Harness) ACP client.
DSH keeps its credentials in `$DSH_HOME/.credentials.yaml' and resolves a
route's key from the `apiKeyEnv' name it configures, whose default for the
official DeepSeek route is DEEPSEEK_API_KEY (packages/llm/
llm-deepseek-api-key).  So only two things cross, both pass-through: the
state dir this session binds, and that documented fallback."
  (let ((home (agent-org--env-value "DSH_HOME"))
        (key (agent-org--env-value "DEEPSEEK_API_KEY"))
        (out nil))
    (when home
      (setq out (cons (format "DSH_HOME=%s" home) out)))
    (when key
      (setq out (cons (format "DEEPSEEK_API_KEY=%s" key) out)))
    (nreverse out)))

(defun agent-org-gemini-environment ()
  "Return environment variables for the Gemini CLI ACP client.
Nothing is exported by default: `gemini' keeps its own credential state under
~/.gemini (cached Google sign-in, ADC, or a `.gemini/.env' it loads itself),
and Emacs reading that store would make it a second source of truth for a
secret.  The documented headless keys pass through, preferred-first —
GEMINI_API_KEY (AI Studio) then GOOGLE_API_KEY (a Vertex AI API key) —
because the authentication guide warns that setting either DISABLES the ADC
route, so forwarding both would fight itself."
  (let ((var (cond ((agent-org--env-value "GEMINI_API_KEY") "GEMINI_API_KEY")
                   ((agent-org--env-value "GOOGLE_API_KEY") "GOOGLE_API_KEY"))))
    (when var
      (list (format "%s=%s" var (agent-org--env-value var))))))

(defun agent-org-devin--credentials-file ()
  "Path of the credentials file the `devin' CLI reads for local ACP.
The vendor location is $HOME/.local/share/devin/credentials.toml; HOME is
read from `process-environment' (the same place every other env lookup
here reads) and `~' is the fallback when a machine has no HOME.  XDG_DATA_HOME
is NOT consulted: the spec names $HOME/.local/share, and a lane that set
XDG_DATA_HOME without the CLI agreeing with us would get a file the CLI
never reads — a silent failure instead of a loud one."
  (expand-file-name ".local/share/devin/credentials.toml"
                    (or (getenv "HOME") (expand-file-name "~"))))

(defun agent-org-devin--restore-credentials ()
  "Write the DEVIN_CREDENTIALS_TOML environment value as the CLI's file.
Returns the file name written, or nil when the variable is absent or
blank (per `agent-org--env-value', a blank is the same as absent so a
lane that never sealed a credential can never blank out a working
`devin auth login' store).  This is the non-interactive half of the
login the local ACP server insists on: `devin auth login' is a browser
PKCE flow that cannot run in CI, so the sealed value carries the whole
file (WO-17, Owner fiat 2026-10-30 #hq: the code lands now, the live
seal when the Owner uploads).
The VALUE is never logged, never echoed and never handed to the child's
environment — it rides only into the file, so it cannot surface in the
*acp* traffic log, `ps', or /proc/PID/environ.  Modes are the point: the
directory goes 700 BEFORE the write (a 644 file under a 755 directory is
readable by the machine, and `write-region' does not honour
`default-file-modes' — measured 2026-10-30: 644 anyway) and the file
goes 600 after it.  A failure to place the file is a `user-error', not a
warning: a spawn without credentials dies silently on `initialize'
(measured 2026-10-29), so continuing would hide the real cause."
  (let ((value (agent-org--env-value "DEVIN_CREDENTIALS_TOML")))
    (when value
      (let* ((file (agent-org-devin--credentials-file))
             (dir (file-name-directory file)))
        (condition-case err
            (progn
              (make-directory dir t)
              (set-file-modes dir #o700)
              (write-region value nil file nil 'nomessage)
              (set-file-modes file #o600)
              file)
          ((file-error error)
           (user-error "Cannot write Devin credentials into %s: %s"
                       dir (error-message-string err))))))))

(defun agent-org-devin-environment ()
  "Return environment variables for the Devin ACP client.
WINDSURF_API_KEY is the vendor-documented non-interactive credential for
Devin's CLOUD sessions (measured 2026-10-29: the local `devin acp'
server does not accept it — its only local credential is the
credentials.toml from `devin auth login'); DEVIN_MODEL is its documented
default-model selector.  Both pass through when present; per
`agent-org--env-value' a blank is the same as absent, so a blank
WINDSURF_API_KEY can never override the CLI's own stored login.
DEVIN_CREDENTIALS_TOML is the one variable that is NOT forwarded: it is
the login file itself, materialised by
`agent-org-devin--restore-credentials' before the spawn.  This function
is that \"before\" — `agent-org--open-session' funcalls every provider's
`:environment' while building the client, so every lane (interactive
start, resume, batch/CI) passes here, and `agent-org--open-session'
starts the process only after it returns."
  (agent-org-devin--restore-credentials)
  (let ((key (agent-org--env-value "WINDSURF_API_KEY"))
        (model (agent-org--env-value "DEVIN_MODEL"))
        (out nil))
    (when key
      (setq out (cons (format "WINDSURF_API_KEY=%s" key) out)))
    (when model
      (setq out (cons (format "DEVIN_MODEL=%s" model) out)))
    (nreverse out)))

(provide 'agent-org-providers)
;;; agent-org-providers.el ends here
