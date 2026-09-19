(add-to-list 'load-path "/home/khalid/.emacs.d/elpa/acp-20260906.1056")
(add-to-list 'load-path "/home/khalid/agent-org")
(require 'agent-org)

;; Trace all notifications
(advice-add 'agent-org--loader-on-notification :before
            (lambda (s n) (message "NOTIFICATION: %s" (map-elt n 'method))))

(agent-org-start 'goose)
(let ((max 30) (ready nil))
  (dotimes (i max)
    (accept-process-output nil 1)
    (when (seq-find (lambda (s) (plist-get s :session-id)) agent-org--sessions)
      (setq ready t)
      (cl-return)))
  (if ready (message "Success") (error "Timeout")))
