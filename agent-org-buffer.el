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
;; tool calls, thoughts) is ever written into the document body.
;;
;; Design:
;;   - No comint, no terminal, no overlays — just Org text.
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
Buffer is in `org-mode', `agent-org-mode' minor mode, read-only, with a
status header line installed by the minor mode."
  (let ((buf (generate-new-buffer (format "*agent-org: %s*" name))))
    (with-current-buffer buf
      (org-mode)
      (setq agent-org-buffer--status
            (list :provider name :state 'starting :message "Connecting…" :session-id nil))
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

(defvar agent-org-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'agent-org-send)
    (define-key map (kbd "C-c C-u") #'agent-org-buffer-compose-prompt)
    (define-key map (kbd "C-c C-k") #'agent-org-buffer-cancel-compose)
    map))

(define-minor-mode agent-org-mode
  "Minor mode for `agent-org' Org chat buffers.
Keys:
  C-c C-c  Send the User prompt at point (or read one via minibuffer)
  C-c C-u  Compose a new User prompt at end of buffer
  C-c C-k  Cancel current composition"
  :init-value nil
  :lighter " aOrg"
  :keymap agent-org-mode-map
  (if agent-org-mode
      (when agent-org-use-header-line
        (setq header-line-format
              '(:eval (agent-org-buffer--render-header-line))))
    (kill-local-variable 'header-line-format)))

;;;; Compose / send

(defun agent-org-buffer-compose-prompt ()
  "Insert a new empty User prompt heading at the end of the buffer.
Unlock the buffer for editing; point lands in the heading body so the
typed text is sent as-is by `agent-org-send'."
  (interactive)
  (let ((session (agent-org-buffer--session)))
    (with-current-buffer (plist-get session :buffer)
      (read-only-mode -1)
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (insert "\n* User\n\n")
      (message "Type your prompt, then C-c C-c to send, C-c C-k to cancel"))))

(defun agent-org-buffer-cancel-compose ()
  "Cancel composition: delete the empty User heading at point, re-lock."
  (interactive)
  (let ((session (agent-org-buffer--session)))
    (with-current-buffer (plist-get session :buffer)
      (when-let* ((body (agent-org-buffer--composed-prompt))
                  ((string-empty-p body)))
        (let ((inhibit-read-only t))
          (org-back-to-heading t)
          (kill-region (point)
                       (min (point-max) (1+ (org-entry-end-position))))))
      (read-only-mode 1)
      (goto-char (point-max))
      (message "Composition cancelled; buffer locked"))))

(defun agent-org-buffer--composed-prompt ()
  "Return the trimmed body of the User heading containing point, or nil."
  (condition-case nil
      (save-excursion
        (org-back-to-heading t)
        (when (string= (org-get-heading t t t t) "User")
          (org-end-of-meta-data t)
          (string-trim (buffer-substring-no-properties
                        (point) (org-entry-end-position)))))
    (error nil)))

(defun agent-org-buffer-read-prompt (buffer)
  "Return the prompt to send from BUFFER as a (TEXT . COMPOSED-P) pair.
When point is under a `* User' heading its body is used and
COMPOSED-P is t, so the caller must not insert another heading; an
empty composed heading is an error, not a minibuffer fall-through.
Otherwise the prompt is read from the minibuffer (COMPOSED-P nil)."
  (with-current-buffer buffer
    (let ((composed (agent-org-buffer--composed-prompt)))
      (if composed
          (progn
            (when (string-empty-p composed)
              (user-error "Empty prompt; type under the User heading or cancel with C-c C-k"))
            (cons composed t))
        (let ((input (string-trim (read-string "Prompt: "))))
          (when (string-empty-p input)
            (user-error "Empty prompt"))
          (cons input nil))))))

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
                (end (save-excursion (search-backward ":end:" limit t))))
            (cond
             ((not drawer) (insert "\n:thinking:\n" text "\n:end:"))
             (end (goto-char end) (insert text "\n"))
             (t (insert text "\n")))))))))

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
          (unless (bolp) (insert "\n"))
          (insert (format "** Tool: %s" name))
          (when tool-id
            (insert (format " [%s]" tool-id)))
          (insert "\n"))))))

(provide 'agent-org-buffer)
;;; agent-org-buffer.el ends here
