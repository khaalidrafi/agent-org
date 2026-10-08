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
         :environment #'agent-org-cline-environment))
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

(defun agent-org-slave-agent-environment ()
  "Return environment variables for the slave-agent ACP client.
Nothing is exported by default: the adapter loads ~/.slave/.env itself, so
the credential store is out of Emacs's hands.  `SLAVE_HOME' is the state
dir the agent binds, and one slave-agent process may serve many profiles,
so passing it through is how an Emacs chat opens against a specific
profile's home rather than the launch default."
  (let ((home (getenv "SLAVE_HOME")))
    (when home
      (list (format "SLAVE_HOME=%s" home)))))

(defun agent-org-goose-environment ()
  "Return environment variables for the Goose ACP client.
Uses OPENAI_API_KEY from the environment if present."
  (let ((key (getenv "OPENAI_API_KEY")))
    (if key
        (list (format "OPENAI_API_KEY=%s" key))
      nil)))

(defun agent-org-opencode-environment ()
  "Return environment variables for the OpenCode ACP client.
OpenCode keeps its own credential store (`opencode auth login'), so
nothing has to be exported and this returns nil by default; a MINIMAX_API
key in the environment is passed through for configs that read it."
  (let ((key (or (getenv "MINIMAX_API_KEY")
                 (getenv "MINIMAX_CODE_KEY"))))
    (when key
      (list (format "MINIMAX_API_KEY=%s" key)))))

(defun agent-org-mcode-environment ()
  "Return environment variables for the MiniMax Code (`mcode') ACP client.
MiniMax Code keeps its own login (`mcode login', or `mcode acp login') in
`~/.minimax/auth', so nothing has to be exported and this returns nil by
default; a MINIMAX_API_KEY in the environment is passed through for
configs that read it."
  (let ((key (getenv "MINIMAX_API_KEY")))
    (when key
      (list (format "MINIMAX_API_KEY=%s" key)))))

(defun agent-org-qoder-environment ()
  "Return environment variables for the Qoder ACP client.
Passes QODER_PERSONAL_ACCESS_TOKEN through when the environment has
it; otherwise the CLI's own stored login (`qoder login') is used."
  (let ((token (getenv "QODER_PERSONAL_ACCESS_TOKEN")))
    (if token
        (list (format "QODER_PERSONAL_ACCESS_TOKEN=%s" token))
      nil)))

(defun agent-org-copilot-environment ()
  "Return environment variables for the GitHub Copilot ACP client.
Copilot keeps its own login (the device flow), so nothing is exported by
default; COPILOT_GITHUB_TOKEN is passed through when the environment has
it, which is the CLI's documented non-interactive credential."
  (let ((token (getenv "COPILOT_GITHUB_TOKEN")))
    (when token
      (list (format "COPILOT_GITHUB_TOKEN=%s" token)))))

(defun agent-org-cursor-environment ()
  "Return environment variables for the Cursor agent ACP client.
Authentication defaults to an external `agent login', so nil is returned;
CURSOR_API_KEY (preferred) or CURSOR_AUTH_TOKEN is passed through when the
environment carries one.  These are the same two secrets agent-shell's
`agent-shell-cursor-authentication' accepts, minus its optional ACP
`cursor_login' handshake, which agent-org does not drive."
  (cond ((getenv "CURSOR_API_KEY")
         (list (format "CURSOR_API_KEY=%s" (getenv "CURSOR_API_KEY"))))
        ((getenv "CURSOR_AUTH_TOKEN")
         (list (format "CURSOR_AUTH_TOKEN=%s" (getenv "CURSOR_AUTH_TOKEN"))))))

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

(provide 'agent-org-providers)
;;; agent-org-providers.el ends here
