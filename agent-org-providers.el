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
         :environment #'agent-org-codebuddy-environment))
  "List of supported ACP providers.
Each entry is a plist; see `agent-org-providers.el' commentary."
  :type '(repeat sexp)
  :group 'agent-org)

(defcustom agent-org-default-provider 'qoder
  "Provider `agent-org-resume-session' uses when called without a prefix arg.
Must be the `:id' of an entry in `agent-org-providers'.  Qoder is the
default because it answers `session/list' and supports
`session/load', which is what resume needs; Goose advertises both but
its `session/list' does not answer in practice."
  :type '(choice (const :tag "Qoder" qoder)
                 (const :tag "Goose" goose)
                 (const :tag "OpenCode" opencode)
                 (const :tag "MiniMax" minimax)
                 (const :tag "Copilot" copilot)
                 (const :tag "Cursor" cursor)
                 (const :tag "CodeBuddy" codebuddy)
                 (symbol :tag "Other provider id"))
  :group 'agent-org)

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

(provide 'agent-org-providers)
;;; agent-org-providers.el ends here
