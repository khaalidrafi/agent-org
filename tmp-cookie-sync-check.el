;;; tmp-cookie-sync-check.el --- scratch: cookies vs source docstrings -*- lexical-binding: t; -*-
(require 'cl-lib)
(require 'seq)
(add-to-list 'load-path default-directory)
(load "tests/acp-mock.el" nil t)
(load "agent-org-providers" nil t)

(defun ao-cookie-doc (fn)
  "The docstring argument of FN's `autoload' cookie, decoded by `read'."
  (with-current-buffer (find-file-noselect "agent-org-autoloads.el")
    (goto-char (point-min))
    (when (re-search-forward
           (concat "(autoload '" (regexp-quote (symbol-name fn)) " ") nil t)
      (nth 2 (read (current-buffer) t)))))

(let ((mismatch 0))
  (dolist (fn '(agent-org-kilo-start-agent
                agent-org-gemini-start-agent
                agent-org-pi-start-agent
                agent-org-devin-start-agent
                agent-org-omp-start-agent))
    (let ((src (documentation-property fn 'function-documentation))
          (cook (ao-cookie-doc fn)))
      (if (equal src cook)
          (message "SYNCED  %s" fn)
        (cl-incf mismatch)
        (message "DIFF    %s\n  SRC  %S\n  COOK %S" fn src cook))))
  (message "%d mismatched" mismatch))
