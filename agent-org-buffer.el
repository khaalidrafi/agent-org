;;; agent-org-buffer.el --- Org chat buffer for agent-org -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Khalid

;; Author: Khalid
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (org "9.0"))
;; Keywords: tools, agents, ai, org

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

;; Org-native chat buffer: each turn is a level-1 headline, chunks
;; stream as raw text (font-lock off during streaming for speed),
;; and Org formatting is applied on turn-complete.
;;
;; Design:
;;   - No comint, no terminal, no overlays — just Org text.
;;   - Font-lock disabled during active streaming for max throughput.
;;   - Re-enabled on `agent-org-buffer--finalize-turn'.

;;; Code:

(require 'cl-lib)
(require 'map)
(require 'seq)
(require 'org)

(defgroup agent-org-buffer nil
  "Org chat buffers for agent-org."
  :group 'agent-org
  :prefix "agent-org-buffer-")

;;;; Buffer creation

(defun agent-org-buffer-create (name)
  "Create and return a new Org chat buffer named *agent-org: NAME*.
Buffer is in `org-mode', `agent-org-mode' minor mode, read-only."
  (let ((buf (generate-new-buffer (format "*agent-org: %s*" name))))
    (with-current-buffer buf
      (org-mode)
      (agent-org-mode 1)
      (read-only-mode 1))
    buf))

(defun agent-org-buffer-set-session (buffer session)
  "Bind SESSION to BUFFER as a buffer-local variable."
  (with-current-buffer buffer
    (setq-local agent-org-buffer--session session)))

(defun agent-org-buffer--session ()
  "Return the session plist for the current buffer."
  (or (and (boundp 'agent-org-buffer--session)
           agent-org-buffer--session)
      (user-error "No agent-org session in this buffer")))

(defvar-local agent-org-buffer--session nil
  "The `agent-org' session plist for this buffer.")

(defvar-local agent-org-buffer--streaming-p nil
  "Non-nil while an agent turn is actively streaming.
Font-lock is suppressed while this is set.")

(defvar-local agent-org-buffer--stream-start nil
  "Point at the start of the current streaming body.")

;;;; Forward declaration

(declare-function agent-org-send "agent-org" ())

;;;; Minor mode

(defvar agent-org-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'agent-org-send)
    (define-key map (kbd "C-c C-u") #'agent-org-buffer-compose-prompt)
    (define-key map (kbd "C-c C-k") #'agent-org-buffer-cancel-compose)
    map))

(define-minor-mode agent-org-mode
  "Minor mode for `agent-org' Org chat buffers.
Keys:
  C-c C-c  Send prompt (from point or new prompt at end)
  C-c C-u  Compose a new User prompt at end of buffer
  C-c C-k  Cancel current composition"
  :init-value nil
  :lighter " aOrg"
  :keymap agent-org-mode-map)

;;;; Compose / send

(defun agent-org-buffer-compose-prompt ()
  "Insert a new empty User prompt heading at the end of the buffer.
Move point into it so the user can type freely; the rest of the
buffer stays read-only."
  (interactive)
  (let ((session (agent-org-buffer--session)))
    (with-current-buffer (plist-get session :buffer)
      (setq buffer-read-only nil)
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (insert "\n* User\n\n")
      (message "Type your prompt, then C-c C-c to send, C-c C-k to cancel"))))

(defun agent-org-buffer-cancel-compose ()
  "Cancel a composed User prompt if it is empty, re-lock buffer."
  (interactive)
  (let ((session (agent-org-buffer--session)))
    (with-current-buffer (plist-get session :buffer)
      (setq buffer-read-only t)
      (message "Composition cancelled; buffer locked"))))

(defun agent-org-buffer-read-prompt (buffer)
  "Return the text of the User turn at point in BUFFER.
If point is inside a User heading, return its body; otherwise
ask the user to compose one first."
  (with-current-buffer buffer
    (save-excursion
      (cond
       ;; Point is on a User heading — read its body
       ((and (org-at-heading-p)
             (string-match-p "\\`User\\|Agent"
                             (org-get-heading t t t t)))
        (unless (string-match-p "User" (org-get-heading t t t t))
          (user-error "Point is not on a User heading"))
        (org-end-of-meta-data t)
        (string-trim (buffer-substring-no-properties
                      (point) (org-entry-end-position))))
       ;; Point is near the end — compose a new prompt via minibuffer
       (t
        (let ((input (read-string "Prompt: ")))
          (when (and input (not (string-empty-p (string-trim input))))
            input)))))))

(defun agent-org-buffer-insert-user (buffer text)
  "Insert a User heading with TEXT into BUFFER."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (insert (format "\n* User\n\n%s\n" text))))))

;;;; Streaming (the hot path)

(defun agent-org-buffer-start-agent-turn (buffer _session)
  "Begin a new Agent heading in BUFFER if one isn't already streaming.
Disable font-lock for the duration of the turn."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (unless agent-org-buffer--streaming-p
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (insert "\n* Agent\n\n")
        (setq agent-org-buffer--streaming-p t
              agent-org-buffer--stream-start (point))
        (font-lock-mode -1)))))

(defun agent-org-buffer-end-agent-turn (buffer)
  "Finish the streaming Agent turn in BUFFER, re-enable font-lock."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (when agent-org-buffer--streaming-p
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (setq agent-org-buffer--streaming-p nil
              agent-org-buffer--stream-start nil)
        (font-lock-mode 1)
        (font-lock-flush)))))

(defun agent-org-buffer-append-chunk (buffer text session)
  "Append TEXT chunk from agent into BUFFER.
Starts a new Agent heading if not already streaming."
  (when (and text (not (string-empty-p text)))
    (agent-org-buffer-start-agent-turn buffer session)
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (point-max))
          (insert text))))))

(defun agent-org-buffer-append-thought (buffer text)
  "Append thinking TEXT to a thinking drawer in BUFFER.
Creates the drawer if it doesn't exist yet."
  (when (and text (not (string-empty-p text)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (save-excursion
          ;; Find or create a thinking drawer at the end of the current turn
          (goto-char (point-max))
          ;; Look backward for an existing thinking drawer
          (let ((drawer-start (save-excursion
                                       (search-backward ":thinking:" nil t))))
              (unless drawer-start
                (insert "\n:thinking:\n"))
              (insert text "\n:end:")))))))

(defun agent-org-buffer-insert-tool (buffer content)
  "Insert a tool-call heading under the current Agent turn in BUFFER.
CONTENT is the tool-call alist from the ACP notification."
  (let ((name (or (map-elt content 'toolName)
                  (map-elt content 'name)
                  "tool"))
        (tool-id (map-elt content 'toolCallId)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (point-max))
          (unless (bolp) (insert "\n"))
          (insert (format "** Tool: %s" name))
          (when tool-id
            (insert (format " [%s]" tool-id)))
          (insert "\n"))))))

(defun agent-org-buffer-insert-system (buffer message)
  "Insert a system notice MESSAGE into BUFFER."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (insert (format "\n- System: %s\n" message))))))

(provide 'agent-org-buffer)
;;; agent-org-buffer.el ends here
