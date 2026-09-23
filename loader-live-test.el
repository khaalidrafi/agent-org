;;; loader-live-test.el --- Live smoke test: header-line reaches Ready -*- lexical-binding: t; -*-
;;; Commentary:
;; Boots a real Goose session and waits until the chat buffer's
;; header-line status reaches :ready with a session id.  Requires the
;; real `acp' package and a working `goose acp' binary.
;; Run with: emacs -Q --batch -l loader-live-test.el
;;; Code:

(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(add-to-list 'load-path
             (car (last (sort (directory-files (locate-user-emacs-file "elpa/") t
                                             "^acp-[0-9]")
                              #'string<))))
(require 'agent-org)

(defun loader-live--ready-p ()
  "Non-nil when any session reached Ready with a session id."
  (seq-some (lambda (s)
              (and (plist-get s :session-id)
                   (with-current-buffer (plist-get s :buffer)
                     (eq 'ready (plist-get agent-org-buffer--status :state)))))
            agent-org--sessions))

(agent-org-start 'goose)
(catch 'ready
  (dotimes (_ 120)
    (accept-process-output nil 1)
    (sit-for 0.01) ;; tick acp's queue-drain timers in batch
    (when (loader-live--ready-p)
      (message "Success: header-line reached Ready")
      (throw 'ready t)))
  (error "Timeout waiting for Ready status"))

;;; loader-live-test.el ends here
