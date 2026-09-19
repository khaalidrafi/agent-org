;;; agent-org-loader.el --- Loader & progress support for agent-org -*- lexical-binding: t; -*-

;; This file provides a minibuffer progress reporter while the ACP
;; client is establishing a session, and suppresses the default
;; `acp--insert-error' comment blocks during that phase.

(require 'acp)

(defvar agent-org--loader-reporter nil
  "Progress reporter shown while the ACP client is initializing.")

(defvar agent-org--suppress-acp-errors nil
  "When non‑nil, do NOT insert ACP error comment blocks into the Org buffer.")

(defun agent-org--show-loader ()
  "Display a minibuffer progress reporter while the session is not ready.
Set `agent-org--suppress-acp-errors' so comment blocks are hidden.
Return the reporter object (or nil if already shown)."
  (unless agent-org--loader-reporter
    (setq agent-org--loader-reporter (make-progress-reporter "Starting agent…" 0 100))
    (setq agent-org--suppress-acp-errors t)
    agent-org--loader-reporter))

(defun agent-org--update-loader (pct)
  "Update the loader to PCT (0‑100)."
  (when agent-org--loader-reporter
    (progress-reporter-update agent-org--loader-reporter pct)))

(defun agent-org--clear-loader ()
  "Finish the loader and re‑enable normal error reporting.
Also print a friendly message in the minibuffer."
  (when agent-org--loader-reporter
    (progress-reporter-done agent-org--loader-reporter)
    (setq agent-org--loader-reporter nil)
    (setq agent-org--suppress-acp-errors nil)
    (message "Agent ready")))

;; Silence the default ACP error inserter while we are loading.
(advice-add 'acp--insert-error :override
            (lambda (buffer message)
              (unless agent-org--suppress-acp-errors
                (with-current-buffer buffer
                  (insert (format "\n#+begin_comment\nACP error: %s\n#+end_comment\n" message))))))

;; New notification handler that integrates the loader.
(defun agent-org--loader-on-notification (session notification)
  "Handle ACP NOTIFICATION for SESSION with loader support.
Extract text from `agent_message_chunk` notifications and update the
progress reporter when a loader percentage is supplied.
All other notifications fall back to the original implementation.
The original implementation is stored as `agent-org--default-on-notification`.
If that symbol does not exist we simply ignore the notification.

  (let* ((buffer (plist-get session :buffer))
         (method (map-elt notification 'method))
         (params (map-elt notification 'params))
         (update (map-nested-elt params '(update sessionUpdate)))
         (loader (map-nested-elt params '(update loader)))
         (content (map-nested-elt params '(update content))))
    (cond
     ;; Session ID becomes known – clear loader.
     ((and (equal method "session/update") (equal update "session_info_update"))
      (let ((sid (map-elt (map-nested-elt params '(sessionInfo)) 'sessionId)))
        (when sid
          (setf (plist-get session :session-id) sid)
                (agent-org--clear-loader)
                (message "Session ID: %s" sid)))))
     ;; Agent message chunk – extract plain text.
     ((and (equal method "session/update") (equal update "agent_message_chunk"))
      (let ((text (or (map-elt content 'text)
                      (and (stringp content) content))))
        (when text
          (agent-org-buffer-append-chunk buffer text session))))
     ;; Turn complete – force a redisplay to finalize UI.
     ((and (equal method "session/update") (equal update "turn_complete"))
      (with-current-buffer buffer
        (org-ctrl-c-ctrl-c)))
     (t nil)))
    ;; Fallback to original handler if it exists.
    (when (fboundp 'agent-org--default-on-notification)
      (agent-org--default-on-notification session notification)))

;; Replace the original handler with our loader‑aware version.
(when (fboundp 'agent-org--on-notification)
  (defalias 'agent-org--default-on-notification (symbol-function 'agent-org--on-notification)))
(advice-add 'agent-org--on-notification :override #'agent-org--loader-on-notification)

(provide 'agent-org-loader)
