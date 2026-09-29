;;; test-agent-org.el --- Tests for agent-org -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Khalid

;; Author: Khalid
;; Version: 0.1.0

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Unit tests for the Org chat buffer, the header-line status model and
;; the ACP notification dispatcher.  Run headless against the mock acp
;; in tests/acp-mock.el, which must be loaded before `agent-org'.

;;; Code:

(require 'ert)
(load (expand-file-name "acp-mock.el" (file-name-directory load-file-name)))
(require 'agent-org)
(require 'agent-org-buffer)
(require 'agent-org-loader)
(require 'agent-org-providers)

;;;; Provider registry

(ert-deftest test-agent-org-goose-provider-present ()
  "Goose provider is registered with required fields."
  (let ((goose (seq-find (lambda (p) (eq (plist-get p :id) 'goose))
                         agent-org-providers)))
    (should goose)
    (should (equal (plist-get goose :name) "Goose"))
    (should (equal (plist-get goose :command) '("goose" "acp")))
    (should (fboundp (plist-get goose :environment)))))

;;;; Buffer creation

(ert-deftest test-agent-org-buffer-create ()
  "Creates an org-mode buffer with agent-org-mode, typeable, and status."
  (let ((buf (agent-org-buffer-create "test")))
    (with-current-buffer buf
      (should buf)
      (should (buffer-live-p buf))
      (should (string-prefix-p "*agent-org: test" (buffer-name buf)))
      (should (derived-mode-p 'org-mode))
      (should-not buffer-read-only)
      (should-not (bound-and-true-p cursor-intangible-mode))
      (should (bound-and-true-p agent-org-mode))
      (should (equal (plist-get agent-org-buffer--status :state) 'starting))
      (should header-line-format))
    (kill-buffer buf)))

;;;; Session registry

(ert-deftest test-agent-org--session-for-buffer ()
  "Returns session plist for the registered buffer."
  (let* ((buf (agent-org-buffer-create "registry-test"))
         (entry (list :name 'test :client nil :buffer buf :session-id nil :streaming nil)))
    (agent-org--register-session entry)
    (should (eq (plist-get (agent-org--session-for-buffer buf) :buffer) buf))
    (kill-buffer buf)))

;;;; Header-line status (the "top bar")

(ert-deftest test-agent-org-status-never-pollutes-buffer ()
  "Status updates change the header line, not the conversation body."
  (let ((buf (agent-org-buffer-create "status")))
    (agent-org-buffer-set-status buf :state 'ready :message "Ready" :session-id "abc123")
    (with-current-buffer buf
      ;; body holds only the #+TITLE metadata line — no headings, no status text
      (should (string-match-p "\\`#\\+TITLE:" (buffer-string)))
      (should-not (string-match-p "^\\* " (buffer-string)))
      (should-not (string-match-p "System" (buffer-string)))
      (should-not (string-match-p "begin_comment" (buffer-string)))
      (should-not (string-match-p "abc123" (buffer-string)))
      ;; status is reflected in the header-line model
      (should (equal (plist-get agent-org-buffer--status :state) 'ready))
      (should (equal (plist-get agent-org-buffer--status :session-id) "abc123"))
      (let ((rendered (agent-org-buffer--render-header-line)))
        (should (string-match-p "Ready" rendered))
        (should (string-match-p "abc123" rendered))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-status-error-renders-error-label ()
  "An error state renders an Error label in the header line."
  (let ((buf (agent-org-buffer-create "err")))
    (agent-org-buffer-set-status buf :state 'error :message "boom")
    (with-current-buffer buf
      (should (string-match-p "Error" (agent-org-buffer--render-header-line)))
      (should (string-match-p "boom" (agent-org-buffer--render-header-line))))
    (kill-buffer buf)))

;;;; Streaming (the hot path)

(ert-deftest test-agent-org-buffer-streaming-lifecycle ()
  "Append-chunk starts an Agent turn; end-turn clears the streaming flag."
  (let* ((buf (agent-org-buffer-create "stream"))
         (session (list :name 'test :buffer buf)))
    (with-current-buffer buf
      (should-not agent-org-buffer--streaming-p))
    (agent-org-buffer-append-chunk buf "Hello " session)
    (with-current-buffer buf
      (should agent-org-buffer--streaming-p)
      (should (string-match-p "Hello " (buffer-string)))
      (should (string-match-p "\\* Agent" (buffer-string))))
    (agent-org-buffer-append-chunk buf "world" session)
    (with-current-buffer buf
      (should (string-match-p "Hello world" (buffer-string))))
    (agent-org-buffer-end-agent-turn buf)
    (with-current-buffer buf
      (should-not agent-org-buffer--streaming-p))
    (kill-buffer buf)))

;;;; Notification dispatch (single, non-recursive handler)

(ert-deftest test-agent-org-on-notification-routes-status-not-buffer ()
  "Message chunks go to the body; lifecycle goes to the header line."
  (let* ((buf (agent-org-buffer-create "dispatch"))
         (session (list :name 'test :client nil :buffer buf
                        :session-id nil :streaming t)))
    ;; agent message chunk -> body + streaming status
    (agent-org--on-notification
     session
     `((method . "session/update")
       (params . ((update . ((sessionUpdate . "agent_message_chunk")
                             (content . ((type . "text") (text . "hi there")))))))))
    (with-current-buffer buf
      (should (string-match-p "hi there" (buffer-string)))
      (should (equal (plist-get agent-org-buffer--status :state) 'streaming))
      ;; no diagnostic text ever lands in the body
      (should-not (string-match-p "ACP error" (buffer-string)))
      (should-not (string-match-p "Session started" (buffer-string))))
    ;; session_info_update -> ready status + session id captured; the only
    ;; body addition is the auto-managed top metadata block
    (agent-org--on-notification
     session
     `((method . "session/update")
       (params . ((sessionId . "sess-9")
                  (update . ((sessionUpdate . "session_info_update")))))))
    (with-current-buffer buf
      (should (equal (plist-get session :session-id) "sess-9"))
      (should (equal (plist-get agent-org-buffer--status :state) 'ready))
      (should (string-match-p ":Session: +sess-9" (buffer-string)))
      ;; no status labels ever land in the body
      (should-not (string-match-p "Ready\\|Starting\\|Connecting" (buffer-string))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-on-notification-is-not-recursive ()
  "The dispatcher handles a notification exactly once (no self-recursion)."
  (let* ((buf (agent-org-buffer-create "recur"))
         (session (list :name 'test :client nil :buffer buf
                        :session-id nil :streaming t))
         (calls 0))
    (cl-letf (((symbol-function 'agent-org-buffer-append-chunk)
               (lambda (&rest _) (cl-incf calls))))
      (agent-org--on-notification
       session
       `((method . "session/update")
         (params . ((update . ((sessionUpdate . "agent_message_chunk")
                               (content . ((text . "x"))))))))))
    (should (= calls 1))
    (kill-buffer buf)))

(ert-deftest test-agent-org-idle-session-drops-agent-content ()
  "Without a live prompt (session :streaming nil), chunk/thought/tool
updates never touch the body: a fresh session cannot fill itself with
Agent turns, thinking or tool calls nobody asked for."
  (let* ((buf (agent-org-buffer-create "idle"))
         (session (list :name 'test :client nil :buffer buf :session-id nil)))
    (dolist (update (list
                     '((sessionUpdate . "agent_message_chunk")
                       (content . ((type . "text") (text . "unasked"))))
                     '((sessionUpdate . "agent_thought_chunk")
                       (content . ((type . "text") (text . "Thinking..."))))
                     '((sessionUpdate . "tool_call")
                       (toolCallId . "tcX") (title . "shell"))))
      (agent-org--on-notification
       session `((method . "session/update")
                 (params ((update . ,update))))))
    (with-current-buffer buf
      (should-not (string-match-p "Agent\\|:thinking:\\|unasked\\|Thinking\\|shell"
                                  (buffer-string))))
    (kill-buffer buf)))

;;;; Thought chunks

(ert-deftest test-agent-org-buffer-thought ()
  "Thought chunks are written into a single well-formed :thinking: drawer."
  (let ((buf (agent-org-buffer-create "think")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-thought buf "reasoning one")
    (agent-org-buffer-append-thought buf "reasoning two")
    (with-current-buffer buf
      (should (string-match-p ":thinking:" (buffer-string)))
      (should (string-match-p "reasoning one" (buffer-string)))
      (should (string-match-p "reasoning two" (buffer-string)))
      ;; exactly one closing marker despite two appends
      (goto-char (point-min))
      (let ((n 0))
        (while (search-forward ":end:" nil t) (cl-incf n))
        (should (= n 1))))
    (kill-buffer buf)))

;;;; Tool call headings

(ert-deftest test-agent-org-buffer-tool-insert ()
  "Tool calls render as `** KEYWORD title [id]' subheadings — status
maps to the per-file TODO keyword set (pending→TODO, in_progress→DOING,
completed→DONE, failed→CANCELLED) — never as a :tool: drawer."
  (let ((buf (agent-org-buffer-create "tool")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool buf '((title . "read_file")
                                        (toolCallId . "tc1")
                                        (status . "in_progress")))
    (with-current-buffer buf
      (should (string-match-p "^\\*\\* DOING read_file \\[tc1\\]$" (buffer-string)))
      (should-not (string-match-p "^:tool:$" (buffer-string)))
      ;; the heading belongs under the Agent heading, never before it
      (should (string-match-p "\\* Agent\n\n\\*\\* DOING read_file \\[tc1\\]"
                              (buffer-string)))
      (should (= 1 (ao--count-occurrences (buffer-string) "^\\*\\* "))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-updates-rewrite-heading-in-place ()
  "tool_call_update for a known id rewrites its heading's keyword/title
in place; new ids append their own heading."
  (let ((buf (agent-org-buffer-create "toolup")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool buf '((title . "shell") (toolCallId . "tc1")
                                        (status . "pending")))
    (should (with-current-buffer buf
              (string-match-p "^\\*\\* TODO shell \\[tc1\\]$" (buffer-string))))
    ;; update without a title must not downgrade it to "tool"
    (agent-org-buffer-insert-tool buf '((toolCallId . "tc1") (status . "completed")))
    (agent-org-buffer-insert-tool buf '((toolCallId . "tc2")))
    (with-current-buffer buf
      (should (= 2 (ao--count-occurrences (buffer-string) "^\\*\\* ")))
      (should (= 1 (ao--count-occurrences (buffer-string) "\\[tc1\\]")))
      (should (= 1 (ao--count-occurrences (buffer-string) "\\[tc2\\]")))
      (should (string-match-p "^\\*\\* DONE shell \\[tc1\\]$" (buffer-string)))
      (should-not (string-match-p "TODO shell" (buffer-string)))
      (should (string-match-p "^\\*\\* TODO tool \\[tc2\\]$" (buffer-string))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-state-resets-per-turn ()
  "A new Agent turn gets its own headings; old ids re-appear fresh."
  (let ((buf (agent-org-buffer-create "toolturn")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool buf '((title . "shell") (toolCallId . "tcA")))
    (agent-org-buffer-end-agent-turn buf)
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool buf '((title . "tree") (toolCallId . "tcB")))
    ;; a reused id (harness may echo an old call) must not merge into
    ;; the previous turn's heading
    (agent-org-buffer-insert-tool buf '((title . "shell") (toolCallId . "tcA")
                                        (status . "completed")))
    (with-current-buffer buf
      (should (= 1 (ao--count-occurrences (buffer-string) "^\\*\\* TODO shell \\[tcA\\]$")))
      (should (= 1 (ao--count-occurrences (buffer-string) "^\\*\\* DONE shell \\[tcA\\]$")))
      (should (= 1 (ao--count-occurrences (buffer-string) "^\\*\\* TODO tree \\[tcB\\]$")))
      ;; a merged turn would leave only two headings
      (should (= 3 (ao--count-occurrences (buffer-string) "^\\*\\* "))))
    (kill-buffer buf)))

;;;; Prompt protection helpers

(ert-deftest test-agent-org-buffer-insert-prompt-idempotent ()
  "insert-prompt adds one open prompt; repeats and streaming are no-ops."
  (let ((buf (agent-org-buffer-create "prompt")))
    (with-current-buffer buf
      (agent-org-buffer-insert-prompt buf)
      (should (= 1 (ao--count-substrings "* User")))
      (should (get-text-property (point-min) 'read-only)) ; heading frozen
      (should (agent-org-buffer--open-prompt-p)) ; body typeable
      (agent-org-buffer-insert-prompt buf)
      (should (= 1 (ao--count-substrings "* User"))) ; idempotent
      (setq agent-org-buffer--streaming-p t)
      (agent-org-buffer-insert-prompt buf)
      (should (= 1 (ao--count-substrings "* User")))) ; no prompt mid-turn
    (kill-buffer buf)))

(ert-deftest test-agent-org-buffer-read-prompt-freezes-typed-text ()
  "read-prompt returns the typed text and freezes the whole prompt."
  (let ((buf (agent-org-buffer-create "freeze")))
    (with-current-buffer buf
      (agent-org-buffer-insert-prompt buf)
      ;; simulate typing with real self-insert-command
      (dolist (ch (append "Hello agent" nil))
        (let ((last-command-event ch))
          (funcall #'self-insert-command 1)))
      (should (equal (agent-org-buffer-read-prompt buf) "Hello agent"))
      ;; after the freeze everything up to point-max is protected
      (should (get-text-property (point-min) 'read-only))
      (should (get-text-property (1- (point-max)) 'read-only))
      ;; but the cursor may still travel there
      (should-not (get-text-property (point-min) 'cursor-intangible)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-frozen-history-is-navigable ()
  "Frozen text takes the cursor; only editing it is refused."
  (let ((buf (agent-org-buffer-create "nav")))
    (with-current-buffer buf
      (agent-org-buffer-insert-prompt buf)
      (agent-org-buffer-append-chunk buf "streamed" (list :buffer buf))
      (goto-char (point-min))
      (should (eq ?# (following-char))) ; cursor stays where put
      (should-error
       (let ((last-command-event ?x))
         (funcall #'self-insert-command 1))
       :type 'text-read-only)
      (should (= (point) (point-min)))
      (should-not (string-match-p "x" (buffer-string))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-insert-prompt-escapes-frozen-point ()
  "With point trapped on frozen text, a new prompt takes point to it."
  (let ((buf (agent-org-buffer-create "escape")))
    (with-current-buffer buf
      (agent-org-buffer-insert-prompt buf)
      (ao--type "Hi")
      (agent-org-buffer-read-prompt buf) ; as send freezes it
      (agent-org-buffer-append-chunk buf "Hello" (list :buffer buf))
      (agent-org-buffer-end-agent-turn buf)
      (goto-char (point-min))
      (agent-org-buffer-insert-prompt buf)
      (should (agent-org-buffer--open-prompt-p))
      (should (= (point) (point-max))))
    (kill-buffer buf)))

;;;; Session registry cleanup

(ert-deftest test-agent-org-buffer-kill-unregisters-session ()
  "Killing a chat buffer drops its entry from `agent-org--sessions'."
  (let* ((buf (agent-org-buffer-create "killme"))
         (entry (list :name 'test :client nil :buffer buf)))
    (agent-org--register-session entry)
    (should (agent-org--session-for-buffer buf))
    (kill-buffer buf)
    (should-not (agent-org--session-for-buffer buf))))

;;;; Header-line lifecycle

(ert-deftest test-agent-org-mode-disable-clears-header-line ()
  "Disabling `agent-org-mode' restores the buffer's original header line."
  (let ((buf (agent-org-buffer-create "hl")))
    (with-current-buffer buf
      (should header-line-format)
      (agent-org-mode -1)
      (should-not header-line-format))
    (kill-buffer buf)))

(ert-deftest test-agent-org-status-falls-back-to-message ()
  "With `agent-org-use-header-line' nil, set-status reports via message."
  (let* ((agent-org-use-header-line nil)
         (buf (agent-org-buffer-create "fb"))
         (seen nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) seen))))
      (with-current-buffer buf
        (should-not header-line-format)
        (agent-org-buffer-set-status buf :state 'ready :message "Ready")))
    (should (seq-some (lambda (m) (string-match-p "Ready" m)) seen))
    (kill-buffer buf)))

;;;; Thinking drawer scoping

(ert-deftest test-agent-org-thinking-drawer-stays-in-current-turn ()
  "Each Agent turn gets its own :thinking: drawer; no cross-turn bleed."
  (let ((buf (agent-org-buffer-create "turns")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-thought buf "first")
    (agent-org-buffer-end-agent-turn buf)
    (agent-org-buffer-insert-user buf "next question")
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-thought buf "second")
    (with-current-buffer buf
      (goto-char (point-min))
      (let ((n 0))
        (while (search-forward ":thinking:" nil t) (cl-incf n))
        (should (= n 2)))
      (goto-char (point-min))
      (let ((m 0))
        (while (search-forward ":end:" nil t) (cl-incf m))
        (should (= m 2))))
    (kill-buffer buf)))

;;;; Permission cancellation

(ert-deftest test-agent-org-permission-quit-sends-cancelled ()
  "Quitting the permission prompt responds with :cancelled and restores status."
  (let* ((buf (agent-org-buffer-create "perm"))
         (session (list :name 'test :client nil :buffer buf :session-id "s"))
         (made nil)
         (sent 0))
    (cl-letf (((symbol-function 'agent-org--prompt-permission)
               (lambda (_opts) (signal 'quit nil)))
              ((symbol-function 'acp-make-session-request-permission-response)
               (lambda (&rest kw) (push kw made) kw))
              ((symbol-function 'acp-send-response)
               (lambda (&rest _args) (cl-incf sent))))
      (agent-org--on-request
       session
       `((method . "session/request_permission")
         (id . 7)
         (params . ((options) (toolCall)))))
      (should (= sent 1))
      (let ((kw (car made)))
        (should (plist-get kw :cancelled))
        (should-not (plist-member kw :option-id))))
    ;; status returns to the pre-request snapshot, not a hardcoded state
    (with-current-buffer buf
      (should (eq 'starting (plist-get agent-org-buffer--status :state))))
    (kill-buffer buf)))

(defun ao--count-substrings (substring)
  "Number of literal occurrences of SUBSTRING in the current buffer.
`how-many' in Emacs 30 lacks the REGEXP-P argument, so count directly."
  (save-excursion
    (goto-char (point-min))
    (let ((n 0))
      (while (search-forward substring nil t)
        (cl-incf n))
      n)))

;;;; Live-prompt send flow

(defun ao--make-test-session (name)
  "Create a chat buffer named for NAME with a registered ready session.
Returns (BUFFER . SESSION)."
  (let* ((buf (agent-org-buffer-create name))
         (session (list :name 'test :client nil :buffer buf
                        :session-id "sid-test" :streaming nil)))
    (agent-org--register-session session)
    (agent-org-buffer-set-session buf session)
    (cons buf session)))

(defun ao--type (text)
  "Simulate typing TEXT with real `self-insert-command' at point."
  (dolist (ch (append text nil))
    (let ((last-command-event ch))
      (funcall #'self-insert-command 1))))

(ert-deftest test-agent-org-send-freezes-prompt-and-streams ()
  "Typing at the live prompt and sending freezes it; one User heading."
  (let* ((pair (ao--make-test-session "send"))
         (buf (car pair))
         (session (cdr pair)))
    (cl-letf (((symbol-function 'acp-send-request) (lambda (&rest _args) nil)))
      (with-current-buffer buf
        (agent-org-buffer-insert-prompt buf)
        (ao--type "Hi")
        (agent-org-send)
        (should (= 1 (ao--count-substrings "* User")))
        (should (get-text-property (1- (point-max)) 'read-only)) ; frozen body
        (should (eq 'streaming (plist-get agent-org-buffer--status :state)))
        (should (plist-get session :streaming))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-send-callback-reopens-prompt ()
  "Ending the turn (success callback) appends a fresh live prompt."
  (let* ((pair (ao--make-test-session "reopen"))
         (buf (car pair))
         (captured nil))
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest kw) (setq captured kw))))
      (with-current-buffer buf
        (agent-org-buffer-insert-prompt buf)
        (ao--type "Hi")
        (agent-org-send)
        (funcall (plist-get captured :on-success) nil)
        (should (= 2 (ao--count-substrings "* User")))
        (should (agent-org-buffer--open-prompt-p))
        (should (eq 'ready (plist-get agent-org-buffer--status :state)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-send-rejects-empty-prompt ()
  "An empty live prompt is an error; nothing is sent."
  (let ((buf (car (ao--make-test-session "empty"))))
    (with-current-buffer buf
      (agent-org-buffer-insert-prompt buf)
      (should-error (agent-org-send) :type 'user-error)
      (should (= 1 (ao--count-substrings "* User"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-send-rejects-when-no-open-prompt ()
  "If the buffer does not end in an open prompt, send explains why."
  (let ((buf (car (ao--make-test-session "noprompt"))))
    (with-current-buffer buf
      (agent-org-buffer-insert-user buf "already sent")
      (should-error (agent-org-send) :type 'user-error))
    (kill-buffer buf)))

(ert-deftest test-agent-org-send-rejects-while-streaming ()
  "The streaming guard rejects sends while the agent is responding."
  (let* ((pair (ao--make-test-session "busy"))
         (session (cdr pair)))
    (setf (plist-get session :streaming) t)
    (should-error (with-current-buffer (car pair) (agent-org-send))
                  :type 'user-error)
    (kill-buffer (car pair))))

(ert-deftest test-agent-org-session-ready-inserts-prompt-once ()
  "`agent-org--session-ready' is idempotent across repeated session updates."
  (let* ((pair (ao--make-test-session "ready"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :session-id) nil)
    (agent-org--session-ready session "sid-1")
    (agent-org--session-ready session "sid-1")
    (with-current-buffer buf
      (should (= 1 (ao--count-substrings "* User")))
      (should (equal "sid-1" (plist-get session :session-id)))
      (should (eq 'ready (plist-get agent-org-buffer--status :state))))
    ;; A mid-turn session_info_update must not slip a prompt in.
    (with-current-buffer buf
      (agent-org-buffer--protect (point-min) (point-max)) ; as send freezes it
      (setf (plist-get session :streaming) t)
      (agent-org--session-ready session "sid-1")
      (should (= 1 (ao--count-substrings "* User"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-programmatic-text-is-protected ()
  "Agent chunks and tool headings carry the read-only property."
  (let ((buf (agent-org-buffer-create "props")))
    (with-current-buffer buf
      (agent-org-buffer-insert-prompt buf)
      (agent-org-buffer-append-chunk buf "streamed" (list :buffer buf))
      (should (save-excursion
                (goto-char (point-min))
                (and (search-forward "streamed" nil t)
                     (get-text-property (match-beginning 0) 'read-only))))
      (agent-org-buffer-insert-tool buf '((title . "read_file") (toolCallId . "tc")))
      (should (save-excursion
                (goto-char (point-min))
                (and (re-search-forward "^\\*\\* TODO read_file \\[tc\\]$" nil t)
                     (get-text-property (match-beginning 0) 'read-only)))))
    (kill-buffer buf)))

;;;; Header-line model (agent-shell style, single status segment)

(defun ao--count-occurrences (string regexp)
  "Number of REGEXP matches in STRING."
  (with-temp-buffer
    (insert string)
    (save-excursion
      (goto-char (point-min))
      (let ((n 0))
        (while (re-search-forward regexp nil t)
          (cl-incf n))
        n))))

(ert-deftest test-agent-org-header-status-not-duplicated ()
  "State label and placeholder message never render twice."
  (let ((buf (agent-org-buffer-create "dup")))
    (agent-org-buffer-set-status buf :state 'ready :message "Ready" :session-id "s1")
    (with-current-buffer buf
      (should (= 1 (ao--count-occurrences
                    (agent-org-buffer--render-header-line) "Ready"))))
    (agent-org-buffer-set-status buf :state 'starting :message "Connecting…")
    (with-current-buffer buf
      (let ((r (agent-org-buffer--render-header-line)))
        (should (string-match-p "Starting" r))
        (should-not (string-match-p "Connecting" r))))
    (agent-org-buffer-set-status buf :state 'streaming :message "Sending…")
    (with-current-buffer buf
      (let ((r (agent-org-buffer--render-header-line)))
        (should (string-match-p "Sending…" r))
        (should-not (string-match-p "Streaming" r))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-header-format-number-compact ()
  "Compact token formatting matches agent-shell (k/m/b suffixes)."
  (should (equal (agent-org-buffer--format-number-compact 42) "42"))
  (should (equal (agent-org-buffer--format-number-compact 1000) "1k"))
  (should (equal (agent-org-buffer--format-number-compact 128000) "128k"))
  (should (equal (agent-org-buffer--format-number-compact 2000000) "2m")))

(ert-deftest test-agent-org-header-context-and-cost ()
  "Context and cost segments render from usage fields."
  (let ((buf (agent-org-buffer-create "usage")))
    (agent-org-buffer-set-status buf :used 90000 :size 128000
                                 :cost-amount 0.4237 :cost-currency "USD")
    (with-current-buffer buf
      (let ((r (agent-org-buffer--render-header-line)))
        (should (string-match-p "90k/128k" r))
        (should (string-match-p "\\$0\\.43" r))))
    (agent-org-buffer-set-status buf :used nil :size nil
                                 :cost-amount nil :cost-currency nil)
    (with-current-buffer buf
      (let ((r (agent-org-buffer--render-header-line)))
        (should-not (string-match-p "/" r))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-header-shows-model-mode-project ()
  "Model, mode and project segments appear in agent-shell order."
  (let ((buf (agent-org-buffer-create "fields")))
    (agent-org-buffer-set-status buf :model "gomodel" :mode "auto")
    (with-current-buffer buf
      (let ((r (agent-org-buffer--render-header-line)))
        (should (string-match-p "gomodel" r))
        (should (string-match-p "auto" r))
        (should (string-match-p "➤" r))
        ;; order: provider before model before mode
        (should (< (string-match-p "fields" r)
                   (string-match-p "gomodel" r)
                   (string-match-p "auto" r)))))
    (kill-buffer buf)))

;;;; Org session-metadata block

(defun ao--fake-session-new-resp ()
  "Canned goose-shaped session/new response alist."
  `((sessionId . "sid-x")
    (title . "Initial Session Title")
    (modes . ((currentModeId . "auto")
              (availableModes .
               [((id . "auto") (name . "auto")
                 (description . "Automatically approve tool calls"))
                ((id . "chat") (name . "chat")
                 (description . "Chat only, no tool calls"))])))
    (configOptions .
     [((id . "provider") (name . "Provider") (type . "select")
       (currentValue . "gomodel"))])))

(ert-deftest test-agent-org-metadata-section-on-ready ()
  "session-ready with a full response builds the top metadata block."
  (let* ((pair (ao--make-test-session "meta"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :session-id) nil)
    (agent-org--session-ready session "sid-x" (ao--fake-session-new-resp))
    (with-current-buffer buf
      (should (string-match-p "\\`:PROPERTIES:" (buffer-string)))
      ;; no heading is used for metadata; conversation owns `* ' lines
      (should-not (string-match-p "Session info" (buffer-string)))
      (should (string-match-p "^:Session: +sid-x" (buffer-string)))
      (should (string-match-p "^:Mode: +auto" (buffer-string)))
      (should (string-match-p "^:Model: +gomodel" (buffer-string)))
      (should (string-match-p "^#\\+TITLE: " (buffer-string)))
      (should (string-match-p "^:MODES:" (buffer-string)))
      (should (string-match-p "chat (id: chat) — Chat only" (buffer-string)))
      (should (string-match-p "^:CONFIG:" (buffer-string)))
      (should (string-match-p "Provider — gomodel" (buffer-string)))
      ;; block ends with a blank line before the first heading
      (should (string-match-p ":END:\n\n\\* User" (buffer-string)))
      ;; metadata is frozen and the live prompt still ends the buffer
      (should (get-text-property (point-min) 'read-only))
      (should (agent-org-buffer--open-prompt-p))
      (save-excursion
        (goto-char (point-max))
        (org-back-to-heading t)
        (should (equal (org-get-heading t t t t) "User"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-title-initializes-from-session-new-response ()
  "A title in the session/new response lands in `#+TITLE:' verbatim —
the harness's own session title, with no provider prefix."
  (let* ((pair (ao--make-test-session "title-init"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :session-id) nil)
    (agent-org--session-ready session "sid-t1" (ao--fake-session-new-resp))
    (with-current-buffer buf
      (should (string-match-p "^#\\+TITLE: Initial Session Title$"
                              (buffer-string)))
      (should (= 1 (ao--count-occurrences (buffer-string) "#\\+TITLE:")))
      (should (equal "Initial Session Title"
                     (plist-get agent-org-buffer--status :title))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-title-falls-back-to-provider-until-set ()
  "Before the harness reports a title, `#+TITLE:' shows the provider
name alone; the fallback disappears once a title arrives."
  (let* ((pair (ao--make-test-session "title-fb"))
         (buf (car pair)))
    (with-current-buffer buf
      (should (string-match-p "^#\\+TITLE: title-fb$" (buffer-string))))
    (agent-org-buffer-set-status buf :title "Real Harness Title")
    (agent-org-buffer-refresh-metadata buf)
    (with-current-buffer buf
      (should (string-match-p "^#\\+TITLE: Real Harness Title$" (buffer-string)))
      (should-not (string-match-p "^#\\+TITLE: title-fb$" (buffer-string)))
      (should (= 1 (ao--count-occurrences (buffer-string) "#\\+TITLE:"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-title-updates-from-session-info-update ()
  "Mid-session `session_info_update' notifications rename `#+TITLE:'
and keep the buffer consistent (one title line, no duplicates)."
  (let* ((pair (ao--make-test-session "title-upd"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :session-id) nil)
    (agent-org--session-ready session "sid-t2" (ao--fake-session-new-resp))
    (with-current-buffer buf
      (should (string-match-p "^#\\+TITLE: Initial Session Title$"
                              (buffer-string))))
    ;; the agent renames the session; title rides inside the update
    (agent-org--on-notification
     session
     `((method . "session/update")
       (params . ((sessionId . "sid-t2")
                  (update . ((sessionUpdate . "session_info_update")
                             (title . "Renamed by agent")))))))
    (with-current-buffer buf
      (should (string-match-p "^#\\+TITLE: Renamed by agent$" (buffer-string)))
      (should (= 1 (ao--count-occurrences (buffer-string) "#\\+TITLE:"))))
    ;; title may also ride directly on params (other ACP clients)
    (agent-org--on-notification
     session
     `((method . "session/update")
       (params . ((sessionId . "sid-t2")
                  (title . "Params title")
                  (update . ((sessionUpdate . "session_info_update")))))))
    (with-current-buffer buf
      (should (string-match-p "^#\\+TITLE: Params title$" (buffer-string)))
      (should (= 1 (ao--count-occurrences (buffer-string) "#\\+TITLE:"))))
    (kill-buffer buf)))

(defun ao--drawer-folded-p (name)
  "Non-nil when the drawer NAME body in the current buffer is hidden."
  (save-excursion
    (goto-char (point-min))
    (and (re-search-forward (format "^:%s:" name) nil t)
         (progn (forward-line 1)
                (invisible-p (point))))))

(ert-deftest test-agent-org-metadata-folded-by-default ()
  "Every metadata drawer starts folded; the TITLE line stays visible."
  (let* ((pair (ao--make-test-session "fold"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :session-id) nil)
    (agent-org--session-ready session "sid-x" (ao--fake-session-new-resp))
    (with-current-buffer buf
      (should (ao--drawer-folded-p "PROPERTIES"))
      (should (ao--drawer-folded-p "MODES"))
      (should (ao--drawer-folded-p "CONFIG"))
      (should-not (string-match-p ":VISIBILITY:" (buffer-string)))
      ;; the TITLE keyword line is always visible
      (should (save-excursion
                (goto-char (point-min))
                (re-search-forward "^#\\+TITLE:")
                (not (invisible-p (match-beginning 0)))))
      ;; the folded content is still there, and the prompt stays open
      (should (string-match-p ":MODES:" (buffer-string)))
      (should (agent-org-buffer--open-prompt-p))
      (agent-org--session-ready session "sid-x" (ao--fake-session-new-resp))
      (should (ao--drawer-folded-p "MODES")))
    (kill-buffer buf)))

(ert-deftest test-agent-org-metadata-keeps-user-expanded-state ()
  "Refreshing a drawer the user opened does not re-fold it."
  (let* ((pair (ao--make-test-session "unfold"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :session-id) nil)
    (agent-org--session-ready session "sid-x" (ao--fake-session-new-resp))
    (with-current-buffer buf
      (should (ao--drawer-folded-p "MODES"))
      (save-excursion
        (goto-char (point-min))
        (re-search-forward "^:MODES:")
        (org-fold-hide-drawer-toggle))
      (agent-org-buffer-refresh-metadata buf)
      (should-not (ao--drawer-folded-p "MODES"))
      (should (ao--drawer-folded-p "CONFIG"))
      ;; still a single block
      (should (= 1 (ao--count-occurrences (buffer-string) "^:MODES:"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-metadata-refresh-idempotent ()
  "Repeated ready/notification updates never duplicate the block."
  (let* ((pair (ao--make-test-session "meta2"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :session-id) nil)
    (agent-org--session-ready session "sid-x" (ao--fake-session-new-resp))
    (agent-org--session-ready session "sid-x" (ao--fake-session-new-resp))
    (agent-org--on-notification
     session
     `((method . "session/update")
       (params . ((update . ((sessionUpdate . "available_commands_update")
                             (availableCommands .
                              [((name . "compact")
                                (description . "Compact the conversation"))
                               ((name . "status")
                                (description . "Show session status"))])))))))
    (with-current-buffer buf
      (should (= 1 (ao--count-substrings ":MODES:")))
      (should (= 1 (ao--count-substrings "#+TITLE:")))
      (should (= 1 (ao--count-substrings "* User")))
      (should (string-match-p ":COMMANDS:" (buffer-string)))
      (should (string-match-p "/compact — Compact the conversation"
                              (buffer-string))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-metadata-usage-update ()
  "usage_update feeds header and the Context property line."
  (let* ((pair (ao--make-test-session "usage2"))
         (buf (car pair))
         (session (cdr pair)))
    (agent-org--on-notification
     session
     `((method . "session/update")
       (params . ((update . ((sessionUpdate . "usage_update")
                             (used . 12000) (size . 128000)))))))
    (with-current-buffer buf
      (should (equal 12000 (plist-get agent-org-buffer--status :used)))
      (should (string-match-p "12k/128k"
                              (agent-org-buffer--render-header-line)))
      (should (string-match-p "^:Context: +12k/128k" (buffer-string))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-send-records-usage-cost ()
  "PromptResponse usage/cost land in the status model and header."
  (let* ((pair (ao--make-test-session "cost"))
         (buf (car pair))
         (captured nil))
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest kw) (setq captured kw))))
      (with-current-buffer buf
        (agent-org-buffer-insert-prompt buf)
        (ao--type "Hi")
        (agent-org-send)
        (funcall (plist-get captured :on-success)
                 '((usage (totalTokens . 500))
                   (cost (amount . 0.4237) (currency . "USD"))))
        (should (= 500 (plist-get agent-org-buffer--status :tokens)))
        (should (string-match-p "\\$0\\.43"
                                (agent-org-buffer--render-header-line)))
        ;; nil response (as other tests send) stays safe
        (agent-org-buffer-insert-prompt buf)
        (ao--type "Hi again")
        (agent-org-send)
        (funcall (plist-get captured :on-success) nil)
        (should (= 500 (plist-get agent-org-buffer--status :tokens)))))
    (kill-buffer buf)))

;;;; Tool keyword setup & mode-line hygiene

(ert-deftest test-agent-org-metadata-declares-tool-todo-keywords ()
  "The metadata block carries the per-file `#+TODO:' setup line that
gives tool headings their DOING/DONE/CANCELLED states, and Org actually
parses it (C-c C-c on a tool heading offers these keywords)."
  (let* ((pair (ao--make-test-session "kw"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :session-id) nil)
    (agent-org--session-ready session "sid-k" (ao--fake-session-new-resp))
    (with-current-buffer buf
      (should (string-match-p "^#\\+TODO: TODO DOING | DONE CANCELLED$"
                              (buffer-string)))
      (should (= 1 (ao--count-occurrences
                    (buffer-string) "^#\\+TODO:")))
      ;; the line is inside the metadata block: before the first heading
      (save-excursion
        (goto-char (point-min))
        (re-search-forward "^#\\+TODO:")
        (should (< (point) (save-excursion (goto-char (point-min))
                                           (re-search-forward "^\\* ")))))
      ;; and `org-set-regexps-and-options' really applied it: the
      ;; buffer-local keyword set now includes DOING/CANCELLED, which
      ;; the global default set does not
      (should (equal '("TODO" "DOING" "DONE" "CANCELLED")
                     org-todo-keywords-1))
      (should-not (member "DOING" (default-value 'org-todo-keywords-1))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-leaves-mode-line-alone ()
  "The chat buffer's mode line carries no agent-org lighter and no
mode-line construct is mutated: all status lives in the header line."
  (let ((buf (agent-org-buffer-create "ml")))
    (with-current-buffer buf
      (should (null (assq 'agent-org-mode minor-mode-alist)))
      (agent-org-buffer-set-status buf :state 'ready :message "Ready")
      (should (equal (default-value 'mode-line-format) mode-line-format)))
    (kill-buffer buf)))

(provide 'test-agent-org)
;;; test-agent-org.el ends here
