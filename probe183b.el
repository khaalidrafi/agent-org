;;; probe183b.el --- scratch: byte-exact transcript line shapes -*- lexical-binding: t; -*-
(require 'ert)
(require 'ert-x)
(setq load-prefer-newer t)
(setq agent-org-transcribe nil)
(load "/workspace/tests/acp-mock.el")
(require 'agent-org)
(require 'agent-org-buffer)
(require 'agent-org-loader)
(require 'agent-org-providers)
(load "/workspace/tests/test-agent-org.el")

(defun pb--dump (title text)
  (princ (format "\n=== %s ===\n" title))
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (while (not (eobp))
      (princ (format "|%s|\n" (buffer-substring (point) (line-end-position))))
      (forward-line 1))))

(defun pb--run (style temp-dir)
  (let ((agent-org-activity-style style)
        (agent-org-transcribe t)
        (agent-org-transcri[REDACTED:pattern] temp-dir)
        (default-directory (file-name-as-directory temp-dir)))
    (ao--capture-wire
      (let* ((buf (ao--chat-on-model "qmodel-large" "QModel Large" "sid-pb"))
             (session (agent-org--session-for-buffer buf)))
        (cl-letf (((symbol-function 'acp-send-request)
                   (lambda (&rest kw) (push kw ao--sent)))
                  ((symbol-function 'acp-make-session-prompt-request)
                   (lambda (&rest a) (plist-get a :prompt))))
          (with-current-buffer buf
            (ao--type "first prompt line\nsecond prompt line")
            (agent-org-send))
          (agent-org--on-notification
           session (ao--update-notif
                    '((sessionUpdate . "agent_thought_chunk")
                      (content . ((type . "text") (text . "a thought"))))))
          (agent-org--on-notification
           session (ao--update-notif
                    '((sessionUpdate . "tool_call")
                      (toolCallId . "t1") (title . "ls")
                      (status . "pending"))))
          (agent-org--on-notification
           session (ao--update-notif
                    '((sessionUpdate . "agent_message_chunk")
                      (content . ((type . "text") (text . "answer part one"))))))
          (agent-org--on-notification
           session (ao--update-notif
                    '((sessionUpdate . "tool_call_update")
                      (toolCallId . "t1") (status . "completed")
                      (content . [((type . "content")
                                   (content . ((type . "text")
                                               (text . "out"))))]))))
          (agent-org--on-notification
           session (ao--update-notif
                    '((sessionUpdate . "agent_message_chunk")
                      (content . ((type . "text") (text . " answer part two"))))))
          (funcall (plist-get (car ao--sent) :on-success)
                   '((stopReason . "end_turn")))
          (agent-org-queue-enqueue "queued entry one")
          (agent-org-queue-enqueue "queued entry two")
          (pb--dump (format "style=%s" style)
                    (with-temp-buffer
                      (insert-file-contents
                       (expand-file-name (agent-org-buffer--transcript-name "sid-pb")
                                         temp-dir))
                      (buffer-string)))
          (kill-buffer buf))))))

(ert-with-temp-directory temp-dir (pb--run 'headings temp-dir))
(ert-with-temp-directory temp-dir (pb--run 'drawers temp-dir))

;;; probe183b.el ends here
