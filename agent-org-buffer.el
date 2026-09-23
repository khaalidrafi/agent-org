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
;; All status, progress and error feedback is shown in the buffer's
;; `header-line' (the top bar), the same way `gptel' and `agent-shell'
;; surface state.  Nothing but real conversation (User/Agent turns,
;; tool calls, thoughts) is ever written into the buffer body.
;;
;; Design (agent-shell-style always-typable buffer):
;;   - No comint, no terminal, no global read-only — just Org text.
;;   - Programmatic text (headings, streamed chunks, tool calls,
;;     thoughts) is frozen with `read-only' + `cursor-intangible'
;;     text properties; `cursor-intangible-mode' keeps point out of it.
;;   - Between turns the buffer ends in a live `* User' prompt: the
;;     heading is frozen, the body below it stays typeable, so the
;;     user just types and hits C-c C-c.
;;   - Status lives in `header-line', never in the buffer body.
;;   - Font-lock disabled during active streaming for max throughput,
;;     re-enabled on `agent-org-buffer-end-agent-turn'.

;;; Code:

(require 'cl-lib)
(require 'map)
(require 'seq)
(require 'org)

(defgroup agent-org-buffer nil
  "Org chat buffers for agent-org."
  :group 'agent-org
  :prefix "agent-org-buffer-")

;;;; Status header line (the "top bar")

(defface agent-org-status-ready
  '((t :inherit success))
  "Face for the Ready state in the `agent-org' header line."
  :group 'agent-org-buffer)

(defface agent-org-status-busy
  '((t :inherit warning))
  "Face for transient states (starting/streaming/awaiting) in the header line."
  :group 'agent-org-buffer)

(defface agent-org-status-error
  '((t :inherit error))
  "Face for the Error state in the header line."
  :group 'agent-org-buffer)

(defcustom agent-org-use-header-line t
  "When non-nil, show session status in the buffer `header-line'.
When nil, status falls back to minibuffer `message' calls only.
Either way, status text is never written into the chat buffer body."
  :type 'boolean
  :group 'agent-org-buffer)

(defvar-local agent-org-buffer--status
  (list :provider "agent-org" :state 'idle :message nil :session-id nil)
  "Status plist backing this buffer's header line.
Keys: :provider, :state, :message, :session-id.
STATE is one of `idle', `starting', `streaming', `ready',
`awaiting' or `error'.")

(defun agent-org-buffer--state-label (state)
  "Human-readable label for STATUS state."
  (pcase state
    ('starting "Starting")
    ('streaming "Streaming")
    ('ready "Ready")
    ('awaiting "Awaiting permission")
    ('error "Error")
    (_ "Idle")))

(defun agent-org-buffer--state-face (state)
  "Face for STATUS state."
  (pcase state
    ('error 'agent-org-status-error)
    ((or 'starting 'streaming 'awaiting) 'agent-org-status-busy)
    ('ready 'agent-org-status-ready)
    (_ 'default)))

(defun agent-org-buffer--render-header-line ()
  "Render `agent-org-buffer--status' as a header-line string.
Pure function of the buffer-local status plist; safe to call headless."
  (let* ((status agent-org-buffer--status)
         (provider (or (plist-get status :provider) "agent-org"))
         (state (or (plist-get status :state) 'idle))
         (message (plist-get status :message))
         (sid (plist-get status :session-id))
         (label (agent-org-buffer--state-label state))
         (face (agent-org-buffer--state-face state)))
    (concat
     (propertize (format " %s" provider) 'face 'bold)
     "  "
     (propertize label 'face face)
     (when message (propertize (format " — %s" message) 'face 'shadow))
     (when sid (propertize (format "  [%s]" sid) 'face 'shadow)))))

;;;; Buffer creation

(defun agent-org-buffer-create (name)
  "Create and return a new Org chat buffer named *agent-org: NAME*.
Buffer is in `org-mode' and `agent-org-mode' with a status header line.
Programmatic text is protected by `read-only' text properties, not by
a global `buffer-read-only', so the live prompt at the end is always
typeable."
  (let ((buf (generate-new-buffer (format "*agent-org: %s*" name))))
    (with-current-buffer buf
      (org-mode)
      (cursor-intangible-mode 1)
      (setq agent-org-buffer--status
            (list :provider name :state 'starting :message "Connecting…" :session-id nil))
      (agent-org-mode 1))
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

;;;; Status updates

(defun agent-org-buffer-set-status (buffer &rest status)
  "Update BUFFER's header-line status from plist STATUS.
Recognised keys: :state, :message, :provider, :session-id.
Only keys present in STATUS are changed, so passing
`:message nil` clears the message while leaving other fields intact.
With `agent-org-use-header-line' nil, the rendered status is shown via
`message' instead.  Status never touches the buffer body."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (dolist (key '(:provider :state :message :session-id))
        (when (plist-member status key)
          (setq agent-org-buffer--status
                (plist-put agent-org-buffer--status key (plist-get status key)))))
      (if agent-org-use-header-line
          (force-mode-line-update)
        (message "%s" (string-trim (agent-org-buffer--render-header-line))))
      agent-org-buffer--status)))

;;;; Minor mode

(defun agent-org-buffer--blocked (&rest _)
  "Refuse Org structure-editing commands in chat buffers."
  (interactive)
  (user-error "Chat content is managed automatically"))

(defvar agent-org-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'agent-org-send)
    ;; Org structure commands bypass `read-only' text properties and would
    ;; corrupt heading boundaries; block them all.
    (dolist (key (list (kbd "M-RET") (kbd "C-c C-t")
                       [(meta up)] [(meta down)] [(meta left)] [(meta right)]
                       [(shift up)] [(shift down)]
                       (kbd "C-c -")))
      (define-key map key #'agent-org-buffer--blocked))
    map))

(define-minor-mode agent-org-mode
  "Minor mode for `agent-org' Org chat buffers.
Type at the live `* User' prompt at the end of the buffer.
Keys:
  C-c C-c  Send the typed prompt"
  :init-value nil
  :lighter " aOrg"
  :keymap agent-org-mode-map
  (if agent-org-mode
      (when agent-org-use-header-line
        (setq header-line-format
              '(:eval (agent-org-buffer--render-header-line))))
    (kill-local-variable 'header-line-format)))

;;;; Protection + live prompt

(defun agent-org-buffer--protect (beg end)
  "Freeze buffer text between BEG and END against edits and the cursor.
`add-text-properties' itself refuses to touch already read-only text,
so the suppression is bound here for the fully programmatic path."
  (let ((inhibit-read-only t))
    (add-text-properties beg end
                         '(read-only t cursor-intangible t
                           front-sticky (read-only)))))

(defun agent-org-buffer--open-prompt-p ()
  "Non-nil when the current buffer ends in a typeable User prompt."
  (condition-case nil
      (save-excursion
        (goto-char (point-max))
        (org-back-to-heading t)
        (when (string= (org-get-heading t t t t) "User")
          (org-end-of-meta-data t)
          (not (get-text-property (point) 'read-only))))
    (error nil)))

;;;###autoload
(defun agent-org-buffer-insert-prompt (buffer)
  "Append a live `* User' prompt to BUFFER unless one is already open.
Only the heading is frozen; the body stays typeable.  No-op while a
turn is streaming, so mid-turn session updates never slip a prompt
into the response."
  (with-current-buffer buffer
    (unless (or agent-org-buffer--streaming-p
                (agent-org-buffer--open-prompt-p))
      (let* ((inhibit-read-only t)
             (orig (point))
             (stay (eq orig (point-max))))
        (goto-char (point-max))
        (let ((beg (point)))
          (unless (bolp) (insert "\n"))
          (insert "* User\n\n")
          (agent-org-buffer--protect beg (point))
          ;; typed text after the heading must not inherit the freeze
          (put-text-property (1- (point)) (point)
                             'rear-nonsticky '(read-only cursor-intangible))
          (unless stay (goto-char orig)))))))

(defun agent-org-buffer-read-prompt (buffer)
  "Freeze the live prompt in BUFFER and return its trimmed text.
Signals a user-error when the buffer does not end in an open prompt
or when nothing has been typed yet."
  (with-current-buffer buffer
    (unless (agent-org-buffer--open-prompt-p)
      (user-error "Nothing to send; type your prompt under the User heading"))
    (save-excursion
      (goto-char (point-max))
      (org-back-to-heading t)
      (let ((beg (point)))
        (org-end-of-meta-data t)
        (let ((text (string-trim (buffer-substring-no-properties
                                  (point) (point-max)))))
          (when (string-empty-p text)
            (user-error "Empty prompt"))
          (agent-org-buffer--protect beg (point-max))
          text)))))

(defun agent-org-buffer-insert-user (buffer text)
  "Insert a frozen User heading with TEXT into BUFFER (programmatic use)."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (point-max))
        (let ((beg (point)))
          (unless (bolp) (insert "\n"))
          (insert (format "\n* User\n\n%s\n" text))
          (agent-org-buffer--protect beg (point)))))))

;;;; Streaming (the hot path)

(defun agent-org-buffer-start-agent-turn (buffer _session)
  "Begin a new Agent heading in BUFFER if one isn't already streaming.
Disable font-lock for the duration of the turn."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (unless agent-org-buffer--streaming-p
        (goto-char (point-max))
        (let ((beg (point)))
          (unless (bolp) (insert "\n"))
          (insert "* Agent\n\n")
          (agent-org-buffer--protect beg (point))
          (setq agent-org-buffer--streaming-p t
                agent-org-buffer--stream-start (point)))
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
          (let ((beg (point)))
            (insert text)
            (agent-org-buffer--protect beg (point))))))))

(defun agent-org-buffer-append-thought (buffer text)
  "Append thinking TEXT to a thinking drawer in BUFFER.
Opens the drawer with a single :end: on first call; later chunks are
inserted above the closing marker.  The drawer search is bounded to the
current heading so each Agent turn keeps its own drawer."
  (when (and text (not (string-empty-p text)))
    (with-current-buffer buffer
      (let* ((inhibit-read-only t)
             (limit (save-excursion
                      (goto-char (point-max))
                      (condition-case nil
                          (progn (org-back-to-heading) (point))
                        (error (point-min))))))
        (save-excursion
          (goto-char (point-max))
          (let ((drawer (save-excursion (search-backward ":thinking:" limit t)))
                (end (save-excursion (search-backward ":end:" limit t)))
                (beg (point)))
            (cond
             ((not drawer) (insert "\n:thinking:\n" text "\n:end:"))
             (end (goto-char end) (setq beg (point)) (insert text "\n"))
             (t (insert text "\n")))
            (agent-org-buffer--protect beg (point))))))))

(defun agent-org-buffer-insert-tool (buffer content)
  "Insert a tool-call heading under the current Agent turn in BUFFER.
CONTENT is the tool-call alist from the ACP notification."
  (let ((name (or (map-elt content 'title)
                  (map-elt content 'toolName)
                  (map-elt content 'name)
                  "tool"))
        (tool-id (map-elt content 'toolCallId)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (point-max))
          (let ((beg (point)))
            (unless (bolp) (insert "\n"))
            (insert (format "** Tool: %s" name))
            (when tool-id
              (insert (format " [%s]" tool-id)))
            (insert "\n")
            (agent-org-buffer--protect beg (point))))))))

(provide 'agent-org-buffer)
;;; agent-org-buffer.el ends here
