;;; loader-test.el --- Headless check: bootstrap reaches Ready -*- lexical-binding: t; -*-
;;; Commentary:
;; Starts a Goose session and asserts the chat buffer's header-line
;; status reaches :ready.  Requires the real `acp' package and a
;; working `goose acp' binary (not part of the offline ERT suite).
;; Run with: emacs -Q --batch -l loader-test.el
;;; Code:

(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(add-to-list 'load-path
             (car (last (sort (directory-files (locate-user-emacs-file "elpa/") t
                                             "^acp-[0-9]")
                              #'string<))))
(require 'agent-org)
(require 'agent-org-buffer)

(defun my-loader-test ()
  (message "Starting test…")
  (agent-org-start 'goose)
  (catch 'ready
    (dotimes (_ 120)
      (accept-process-output nil 1)
      (sit-for 0.01) ;; tick acp's queue-drain timers in batch
      (when (seq-some (lambda (s)
                        (and (plist-get s :session-id)
                             (with-current-buffer (plist-get s :buffer)
                               (eq 'ready (plist-get agent-org-buffer--status :state)))))
                      agent-org--sessions)
        (throw 'ready t)))
    (error "Loader never reached Ready"))
  (message "Test passed – header-line reached Ready"))

(my-loader-test)

;;; loader-test.el ends here
