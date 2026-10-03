;;; agent-org-loader.el --- Session bootstrap progress for agent-org -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Khalid

;; Author: Khalid
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, agents, ai, org

;; This file is not part of GNU Emacs.

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

;; Thin bootstrap helpers that drive the chat buffer's header-line
;; (top bar) while an ACP session is being established.  Progress and
;; errors are surfaced through `agent-org-buffer-set-status'.  Nothing
;; is written into the buffer body.
;;
;; The handshake this covers gets no progress reporter: it is one round
;; trip with nothing to count and no events to step on, so the header's
;; `Connecting…' is the whole story.  The phases that can be slow — a
;; `session/list' paging for older chats and a `session/load' replay —
;; are reported in the echo area instead, by `agent-org--progress-start'
;; in agent-org.el.

;;; Code:

(require 'agent-org-buffer)

(defun agent-org-loader-begin (buffer)
  "Mark BUFFER as connecting.  Called right after session bootstrap starts.
Clears `:note' too: the reason a previous attempt gave up on the listing
belongs to that attempt, not to the session now opening."
  (agent-org-buffer-set-status buffer
    :state 'starting :message "Connecting…" :note nil))

(cl-defun agent-org-loader-finish (buffer &key session-id message)
  "Mark BUFFER's bootstrap complete and Ready.
Stores SESSION-ID and an optional STATUS MESSAGE."
  (agent-org-buffer-set-status buffer
    :state 'ready
    :session-id session-id
    :message (or message "Ready")))

(defun agent-org-loader-fail (buffer message)
  "Mark BUFFER's bootstrap as failed with error MESSAGE."
  (agent-org-buffer-set-status buffer :state 'error :message message))

(provide 'agent-org-loader)
;;; agent-org-loader.el ends here
