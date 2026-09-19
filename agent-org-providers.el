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
;;   :command      - list (binary . params), e.g. '("goose" "acp")
;;   :command-params - (kept in :command for acp-make-client)
;;   :environment  - function returning a list of "VAR=val" strings
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
         :environment #'agent-org-goose-environment))
  "List of supported ACP providers.
Each entry is a plist; see `agent-org-providers.el' commentary."
  :type '(repeat sexp)
  :group 'agent-org)

(defun agent-org-goose-environment ()
  "Return environment variables for the Goose ACP client.
Uses OPENAI_API_KEY from the environment if present."
  (let ((key (getenv "OPENAI_API_KEY")))
    (if key
        (list (format "OPENAI_API_KEY=%s" key))
      nil)))

(provide 'agent-org-providers)
;;; agent-org-providers.el ends here
