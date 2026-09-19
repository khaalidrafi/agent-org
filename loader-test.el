;;; loader-test.el --- Test that the loader appears and clears

(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(add-to-list 'load-path "/home/khalid/.emacs.d/elpa/acp-20260906.1056")
(require 'agent-org)

(defun my-loader-test ()
  (message "Starting test…")
  (agent-org-start "goose")
  ;; Wait up to 30 seconds for the loader to clear (Agent ready message)
  (let ((max 30) (found nil))
    (dotimes (i max)
      (accept-process-output nil 1)
      (when (string-match-p "Agent ready" (current-message))
        (setq found t)
        (cl-return)))
    (unless found
      (error "Loader never cleared")))
  (message "Test passed – loader cleared"))

(my-loader-test)

;;; loader-test.el ends here
