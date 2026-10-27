;;; probe183.el --- scratch: print a real transcript shape -*- lexical-binding: t; -*-
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

(ert-with-temp-directory temp-dir
  (let ((agent-org-transcribe t)
        (agent-org-transcri[REDACTED:pattern] temp-dir)
        (default-directory (file-name-as-directory temp-dir)))
    (ao--capture-wire
      (let* ((buf (ao--chat-on-model "qmodel-large" "QModel Large" "sid-probe"))
             (session (agent-org--session-for-buffer buf)))
        (cl-letf (((symbol-function 'acp-send-request)
                   (lambda (&rest kw) (push kw ao--sent)))
                  ((symbol-function 'acp-make-session-prompt-request)
                   (lambda (&rest a) (plist-get a :prompt))))
          ;; ---- turn 1
          (with-current-buffer buf
            (ao--type "what does ** render mean?")
            (agent-org-send))
          (agent-org--on-notification
           session (ao--update-notif
                    '((sessionUpdate . "agent_thought_chunk")
                      (content . ((type . "text") (text . "checking §15"))))))
          (dotimes (_ 3)
            (agent-org--on-notification
             session (ao--update-notif
                      '((sessionUpdate . "agent_message_chunk")
                        (content . ((type . "text") (text . "It means ")))))))
          (agent-org--on-notification
           session (ao--update-notif
                    '((sessionUpdate . "tool_call")
                      (toolCallId . "t1") (title . "grep -rn foo")
                      (status . "pending"))))
          (agent-org--on-notification
           session (ao--update-notif
                    '((sessionUpdate . "tool_call_update")
                      (toolCallId . "t1") (status . "completed")
                      (content . [((type . "content")
                                   (content . ((type . "text")
                                               (text . "matched here "))))]))))
          (agent-org--on-notification
           session (ao--update-notif
                    '((sessionUpdate . "agent_message_chunk")
                      (content . ((type . "text")
                                  (text . "a bullet.\n- one\n- two"))))))
          (funcall (plist-get (car ao--sent) :on-success)
                   '((stopReason . "end_turn")))
          ;; ---- turn 2, multi-line prompt
          (with-current-buffer buf
            (goto-char (point-max))
            (ao--type "second prompt\n  indented continuation")
            (agent-org-send))
          (agent-org--on-notification
           session (ao--update-notif
                    '((sessionUpdate . "agent_message_chunk")
                      (content . ((type . "text") (text . "Answer two."))))))
          (funcall (plist-get (car ao--sent) :on-success)
                   '((stopReason . "end_turn")))
          ;; ---- a queued prompt while a third turn runs
          (with-current-buffer buf
            (goto-char (point-max))
            (ao--type "third prompt")
            (agent-org-send))
          (agent-org-queue-enqueue "queued while busy")
          (funcall (plist-get (car ao--sent) :on-success)
                   '((stopReason . "end_turn")))
          (princ "\n=== TRANSCRIPT FILE ===\n")
          (princ (with-temp-buffer
                   (insert-file-contents
                    (expand-file-name (agent-org-buffer--transcript-name "sid-probe")
                                      temp-dir))
                   (buffer-string)))
          (princ "\n=== END TRANSCRIPT ===\n")
          (kill-buffer buf))))))

;;; probe183.el ends here
