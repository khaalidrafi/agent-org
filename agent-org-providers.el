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
;;                   option, which is how one ACP server fronts many
;;                   models — OpenCode does, so MiniMax needs it.
;;
;; Add a provider by pushing onto `agent-org-providers'.

;;; Code:

(require 'cl-lib)
(require 'map)

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
   ;; MiniMax ships no ACP server; OpenCode is the host that speaks ACP and
   ;; serves its catalog, so the MiniMax provider is an OpenCode session with
   ;; a MiniMax model pinned.
   (list :id 'minimax
         :name "MiniMax"
         :command '("opencode" "acp")
         :model "opencode/minimax-m2.7"
         :environment #'agent-org-opencode-environment))
  "List of supported ACP providers.
Each entry is a plist; see `agent-org-providers.el' commentary."
  :type '(repeat sexp)
  :group 'agent-org)

(defcustom agent-org-default-provider 'qoder
  "Provider `agent-org-resume' uses when called without a prefix arg.
Must be the `:id' of an entry in `agent-org-providers'.  Qoder is the
default because it answers `session/list' and supports
`session/load', which is what resume needs; Goose advertises both but
its `session/list' does not answer in practice."
  :type '(choice (const :tag "Qoder" qoder)
                 (const :tag "Goose" goose)
                 (const :tag "OpenCode" opencode)
                 (const :tag "MiniMax" minimax)
                 (symbol :tag "Other provider id"))
  :group 'agent-org)

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

(defun agent-org-qoder-environment ()
  "Return environment variables for the Qoder ACP client.
Passes QODER_PERSONAL_ACCESS_TOKEN through when the environment has
it; otherwise the CLI's own stored login (`qoder login') is used."
  (let ((token (getenv "QODER_PERSONAL_ACCESS_TOKEN")))
    (if token
        (list (format "QODER_PERSONAL_ACCESS_TOKEN=%s" token))
      nil)))

(provide 'agent-org-providers)
;;; agent-org-providers.el ends here
