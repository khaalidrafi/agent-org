;;; loader-live-test.el --- Verify loader works

;; Load paths for acp and our package
(add-to-list 'load-path "/home/khalid/.emacs.d/elpa/acp-20260906.1056")
(add-to-list 'load-path "/home/khalid/agent-org")

(require 'agent-org)

;; Start a session (Goose provider)
(agent-org-start 'goose)

;; Wait up to 30 seconds for the loader to disappear (session-id set)
(let ((max 30) (ready nil))
  (dotimes (i max)
    (accept-process-output nil 1)
    (when (seq-find (lambda (s) (plist-get s :session-id)) agent-org--sessions)
      (setq ready t)
      (cl-return)))
  (if ready
      (message "Loader cleared – session ready")
    (error "Loader never cleared within timeout")))

(message "Test completed successfully")
