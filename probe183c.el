;;; probe183c.el --- scratch: byte-exact transcript shapes for the #183 parser -*- lexical-binding: t; -*-
(require 'ert)
(require 'ert-x)
(setq load-prefer-newer t)
(setq agent-org-transcribe nil)
(add-to-list 'load-path "/workspace")
(load "/workspace/tests/acp-mock.el")
(require 'agent-org)
(require 'agent-org-buffer)
(require 'agent-org-loader)
(require 'agent-org-providers)
(load "/workspace/tests/test-agent-org.el")

(defun pc--show (title text)
  (princ (format "\n=== %s ===\n" title))
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (while (< (point) (point-max))
      (princ (format "|%s|\n" (buffer-substring (point) (line-end-position))))
      (forward-line 1))
    (princ (format "|EOF after %d chars|\n" (point-max)))))

(defun pc--run (style temp-dir)
  (let ((agent-org-activity-style style))
    (ao--transcript-in temp-dir
      (let* ((pair (ao--make-test-session "probe"))
             (buf (car pair))
             (session (cdr pair)))
        (agent-org-buffer-set-status buf :session-id "sid-probe"
                                     :model-name "QModel Large" :state 'ready)
        (agent-org-buffer-refresh-metadata buf)
        (agent-org-buffer-begin-exchange buf "first prompt line\n  second prompt line")
        (agent-org-buffer-append-thought buf "a thought")
        (agent-org-buffer-append-chunk buf "answer one\nmore" session)
        (agent-org-buffer-insert-tool
         buf '((toolCallId . "tc1") (title . "ls") (status . "completed")))
        (agent-org-buffer-append-chunk buf " answer two" session)
        (agent-org-buffer-end-agent-turn buf)
        (agent-org-buffer-begin-exchange buf "empty turn")
        (agent-org-buffer-end-agent-turn buf)
        (agent-org-buffer-set-status buf :queued '("queued one" "queued two"))
        (agent-org-buffer-transcribe buf t)
        (pc--show (format "style=%s" style)
                  (with-temp-buffer
                    (insert-file-contents
                     (expand-file-name (agent-org-buffer--transcript-name "sid-probe")
                                       temp-dir))
                    (buffer-string)))
        (pc--show (format "style=%s BUFFER-TAIL" style)
                  (with-current-buffer buf
                    (buffer-substring-no-properties
                     (agent-org-buffer--render-end) (point-max))))
        (kill-buffer buf)))))

(ert-with-temp-directory d (pc--run 'headings d))
(ert-with-temp-directory d (pc--run 'drawers d))

;;; probe183c.el ends here
