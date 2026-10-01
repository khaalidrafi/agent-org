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

(ert-deftest test-agent-org-opencode-provider-present ()
  "OpenCode is registered as the ACP host, with no pinned model.
OpenCode is one server fronting many vendors' models, so a session opens
on its shared default until the user picks one (`agent-org-set-session-model') or
a provider entry pins one."
  (let ((opencode (agent-org--provider-spec 'opencode)))
    (should (equal (plist-get opencode :name) "OpenCode"))
    (should (equal (plist-get opencode :command) '("opencode" "acp")))
    (should-not (plist-get opencode :model))
    (should (fboundp (plist-get opencode :environment)))))

(ert-deftest test-agent-org-minimax-provider-present ()
  "MiniMax Code is its OWN agent: `mcode acp', not OpenCode in disguise.
MiniMax Code and OpenCode are different products; only OpenCode needs a
pinned model because it serves many vendors.  `mcode' is MiniMax's own
CLI, so a MiniMax session must spawn it and pin nothing — its default
model is already a MiniMax model."
  (let ((minimax (agent-org--provider-spec 'minimax)))
    (should (equal (plist-get minimax :name) "MiniMax"))
    (should (equal (plist-get minimax :command) '("mcode" "acp")))
    (should-not (equal (plist-get minimax :command)
                       (plist-get (agent-org--provider-spec 'opencode)
                                  :command)))
    (should-not (plist-get minimax :model))
    (should (equal (plist-get minimax :environment)
                   #'agent-org-mcode-environment))))

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

(ert-deftest test-agent-org-tool-heading-flattens-multiline-title ()
  "A tool title is agent text, never a heading.  Live qoder replays
shell calls whose title is the whole command: several lines, hundreds of
characters.  Inserted verbatim into `** KEYWORD title [id]' everything
after the first newline would fall into the body as loose text, and the
in-place rewrite (which deletes one line) would then shred the turn.  So
the label is flattened and truncated; the id still tells calls apart."
  (let ((buf (agent-org-buffer-create "toollong"))
        (long (concat "ls -la\n" (make-string 300 ?x) "\nsecond line")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool buf `((title . ,long)
                                        (toolCallId . "tc1")
                                        (status . "pending")))
    (agent-org-buffer-insert-tool buf '((title . "probe")
                                        (toolCallId . "tc2")
                                        (status . "pending")))
    (with-current-buffer buf
      ;; exactly one Agent heading plus the two tool headings: no line
      ;; spilled out of the heading it belongs to
      (should (= 3 (ao--count-occurrences (buffer-string) "^\\*+ ")))
      (should (string-match-p "^\\*\\* TODO ls -la .*\\[tc1\\]$" (buffer-string)))
      (should-not (string-match-p "^second line$" (buffer-string)))
      ;; cut, not merely re-wrapped
      (should-not (string-match-p (make-string 300 ?x) (buffer-string))))
    ;; and the pending→done rewrite still finds one clean line to replace
    (agent-org-buffer-insert-tool buf '((toolCallId . "tc1")
                                        (status . "completed")))
    (with-current-buffer buf
      (should (= 3 (ao--count-occurrences (buffer-string) "^\\*+ ")))
      (should (string-match-p "^\\*\\* DONE ls -la .*\\[tc1\\]$" (buffer-string)))
      (should-not (string-match-p "TODO ls" (buffer-string))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-heading-survives-later-thought-chunk ()
  "A thought arriving AFTER a tool call re-renders the whole
:thinking: drawer, and must not delete the heading beside it.  Live
qoder thinks between tool calls, so this is the normal streaming shape
of a turn — it used to leave only the turn's last tool call in the
buffer."
  (let ((buf (agent-org-buffer-create "toolthought")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool buf '((toolCallId . "tc1") (title . "one")
                                        (status . "pending")))
    (agent-org-buffer-append-thought buf "thinking\n")
    (agent-org-buffer-insert-tool buf '((toolCallId . "tc2") (title . "two")
                                        (status . "in_progress")))
    (agent-org-buffer-append-thought buf "more thinking\n")
    (agent-org-buffer-insert-tool buf '((toolCallId . "tc2") (title . "two")
                                        (status . "completed")))
    (agent-org-buffer-append-thought buf "end of it\n")
    (let* ((text (with-current-buffer buf (buffer-string)))
           (above-fold
            (with-current-buffer buf
              (buffer-substring-no-properties
               (point-min)
               (save-excursion
                 (goto-char (point-min))
                 (re-search-forward "^:thinking:$")
                 (match-beginning 0))))))
      (should (= 2 (ao--count-occurrences text "^\\*\\* ")))
      (should (= 2 (ao--count-occurrences above-fold "^\\*\\* ")))
      (should (= 1 (ao--count-occurrences text "^:thinking:$")))
      ;; the drawer still holds every thought chunk, in order
      (should (apply #'ao--ordered text
                     (list "thinking" "more thinking" "end of it"))))
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
Returns (BUFFER . SESSION).  The plist carries every key
`agent-org--open-session' installs: `setf' on `plist-get' mutates in
place only when the key already exists, so a session missing
`:loading'/`:replay' would silently ignore the resume tests' setup."
  (let* ((buf (agent-org-buffer-create name))
         (session (list :name 'test :client nil :buffer buf
                        :session-id "sid-test" :streaming nil
                        :loading nil :replay nil :replay-timer nil
                        :replay-session-id nil :replay-response nil
                        :replay-deadline nil)))
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

;;;; Resume (qoder provider, session/list -> session/load replay)

(defun ao--update-notif (update)
  "Wrap an update alist UPDATE as a session/update notification."
  `((method . "session/update")
    (params . ((update . ,update)))))

(defun ao--ordered (string &rest patterns)
  "Non-nil when PATTERNS all match STRING in the given order."
  (let ((from 0) (ok t))
    (dolist (p patterns ok)
      (if (string-match p string from)
          (setq from (match-end 0))
        (setq ok nil)))))

(ert-deftest test-agent-org-qoder-provider-registered ()
  "Qoder ships as a provider: `qoder --acp', env token passthrough."
  (let ((qoder (seq-find (lambda (p) (eq (plist-get p :id) 'qoder))
                         agent-org-providers)))
    (should qoder)
    (should (equal (plist-get qoder :name) "Qoder"))
    (should (equal (plist-get qoder :command) '("qoder" "--acp")))
    (should (fboundp (plist-get qoder :environment)))
    ;; the personal access token rides through when set...
    (should (equal (let ((process-environment
                          (cons "QODER_PERSONAL_ACCESS_TOKEN=tok"
                                process-environment)))
                     (funcall (plist-get qoder :environment)))
                   '("QODER_PERSONAL_ACCESS_TOKEN=tok")))
    ;; ...and is simply absent when not
    (should (equal (let ((process-environment
                          (seq-remove (lambda (e)
                                        (string-prefix-p
                                         "QODER_PERSONAL_ACCESS_TOKEN=" e))
                                      process-environment)))
                     (funcall (plist-get qoder :environment)))
                   nil))))

(ert-deftest test-agent-org-default-provider-resolves-spec ()
  "`agent-org-default-provider' names the provider resume uses without
a prefix argument; `agent-org--provider-spec' validates ids."
  (should (boundp 'agent-org-default-provider))
  (should (member agent-org-default-provider '(goose qoder)))
  (should (equal (plist-get (agent-org--provider-spec 'qoder) :name) "Qoder"))
  (should (equal (plist-get (agent-org--provider-spec 'goose) :command)
                 '("goose" "acp")))
  (should-error (agent-org--provider-spec 'nope) :type 'user-error))

(ert-deftest test-agent-org-session-candidates-from-list-resp ()
  "session/list responses map to (DISPLAY . ID) pairs, newest first;
untitled sessions still get an entry."
  (let* ((resp `((sessions . [((sessionId . "s1") (title . "Alpha")
                               (updatedAt . "2026-09-01"))
                              ((sessionId . "s2") (updatedAt . "2026-09-02"))])))
         (cands (agent-org--session-candidates resp)))
    (should (= 2 (length cands)))
    (should (equal (cdr (car cands)) "s2"))
    (should (equal (cdr (nth 1 cands)) "s1"))
    (should (string-match-p "Alpha" (car (nth 1 cands))))
    (should (equal (agent-org--session-candidates '((sessions . []))) nil))))

(ert-deftest test-agent-org-session-candidates-title-is-one-short-line ()
  "Live qoder puts the whole first prompt — thousands of characters
over many lines — in a session's `title', so the raw value would flood
the completion list and break the candidate lines.  DISPLAY must be one
short line that still carries the id, and an ordinary title must
survive untouched."
  (let* ((blob (concat "Resume all sessions paused with errors!\n"
                       (make-string 3000 ?x) "\nlast line"))
         (resp `((sessions . [((sessionId . "big") (title . ,blob)
                               (updatedAt . "2026-09-02"))
                              ((sessionId . "small") (title . "Short one")
                               (updatedAt . "2026-09-01"))])))
         (cands (agent-org--session-candidates resp))
         (display (lambda (id)
                    (car (seq-find (lambda (c) (equal (cdr c) id)) cands)))))
    (let ((big (funcall display "big")))
      (should-not (string-match-p "\n" big))
      (should (<= (length big) 80))
      (should (string-match-p "\\[big\\]\\'" big))
      (should (string-match-p "Resume all sessions" big))
      (should (string-match-p "…" big)))
    (should (equal (funcall display "small") "Short one  [small]"))))

(ert-deftest test-agent-org-read-session-id-single-or-error ()
  "One listed session needs no prompt; an empty list errors out."
  (should (equal (agent-org--read-session-id
                  `((sessions . [((sessionId . "solo") (title . "Only"))])))
                 "solo"))
  (should-error (agent-org--read-session-id '((sessions . [])))
                :type 'user-error))

(ert-deftest test-agent-org-loading-buffers-replay-without-rendering ()
  "While a session/load is in flight, conversational updates are
buffered onto :replay and NEVER painted: the history renders in one
batched pass when the load response arrives."
  (let* ((pair (ao--make-test-session "loadbuf"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :loading) t)
    (dolist (update (list
                     '((sessionUpdate . "user_message_chunk")
                       (content . ((type . "text") (text . "Q1"))))
                     '((sessionUpdate . "agent_message_chunk")
                       (content . ((type . "text") (text . "A1"))))
                     '((sessionUpdate . "tool_call")
                       (toolCallId . "t1") (title . "shell") (status . "pending"))
                     '((sessionUpdate . "agent_thought_chunk")
                       (content . ((type . "text") (text . "hmm"))))))
      (agent-org--on-notification session (ao--update-notif update)))
    (with-current-buffer buf
      (should (= 4 (length (plist-get session :replay))))
      (should-not (string-match-p "^\\* User\\|^\\* Agent\\|Q1\\|A1\\|shell"
                                  (buffer-string))))
    ;; a session_info_update mid-load sets the id but must NOT open a
    ;; prompt: the buffer isn't interactive until the load lands
    (agent-org--on-notification
     session `((method . "session/update")
               (params . ((sessionId . "sid-l")
                          (update . ((sessionUpdate . "session_info_update")))))))
    (should (equal (plist-get session :session-id) "sid-l"))
    (with-current-buffer buf
      (should-not (string-match-p "^\\* User$" (buffer-string))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-render-replay-builds-history ()
  "The batched replay paints User/Agent turns, tool headings and the
thinking drawer in history order, closes all turns, and restores
font-lock exactly once."
  (let* ((pair (ao--make-test-session "replay"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :loading) t)
    (dolist (update (list
                     '((sessionUpdate . "user_message_chunk")
                       (content . ((type . "text") (text . "Hello "))))
                     '((sessionUpdate . "user_message_chunk")
                       (content . ((type . "text") (text . "world"))))
                     '((sessionUpdate . "agent_message_chunk")
                       (content . ((type . "text") (text . "Answer"))))
                     '((sessionUpdate . "tool_call")
                       (toolCallId . "t1") (title . "shell") (status . "completed"))
                     '((sessionUpdate . "agent_thought_chunk")
                       (content . ((type . "text") (text . "thinking hard"))))
                     '((sessionUpdate . "user_message_chunk")
                       (content . ((type . "text") (text . "Next question"))))))
      (agent-org--on-notification session (ao--update-notif update)))
    (let ((font-lock-was (with-current-buffer buf font-lock-mode)))
      (agent-org--render-replay session)
      (with-current-buffer buf
        (let ((s (buffer-string)))
          ;; the two user chunks collapse into ONE heading with joined text
          (should (= 2 (ao--count-occurrences s "^\\* User$")))
          (should (= 1 (ao--count-occurrences s "^\\* Agent$")))
          (should (string-match-p "Hello world" s))
          (should (apply #'ao--ordered s
                         (list "Hello world" "Answer"
                               "^\\*\\* DONE shell \\[t1\\]$"
                               "thinking hard" "Next question")))
          (should (string-match-p "^:thinking:$" s))
          (should-not (string-match-p "^:tool:$" s)))
        (should-not agent-org-buffer--streaming-p)
        ;; A replay suppresses font-lock while painting and restores it
        ;; afterwards.  Batch sessions can never enable font-lock at all,
        ;; so the honest pin is that the value came back to what it was.
        (should (eq font-lock-mode font-lock-was))
        (should (null (plist-get session :replay)))))
    (kill-buffer buf)))

;;;; Resume end-to-end (drives the async chain with a capturing mock)

(defvar ao--sent nil
  "Requests captured by the resume wire mock, newest first.
Each entry is (METHOD :REQUEST REQUEST :on-success CALLBACK).")

(defun ao--sent-get (method)
  "The most recent captured entry for METHOD, or nil."
  (cdr (assoc method ao--sent)))

(defun ao--drive (method resp)
  "Fail unless METHOD was sent, then run its on-success with RESP."
  (let ((entry (ao--sent-get method)))
    (should entry)
    (funcall (plist-get entry :on-success) resp)))

(defvar ao--timer nil
  "Armed (FUNCTION . ARGS) of the pending timer inside `ao--capture-wire'.")

(defvar ao--armings 0
  "How many times `run-at-time' was called inside `ao--capture-wire'.
Tests assert on this to see a deferred render re-armed by late input.")

(defun ao--settle ()
  "Fire the pending timer, the way the event loop would after a delay.
Resume defers its batched render until the replayed updates stop
arriving; tests must not sleep on a real timer, so `ao--capture-wire'
captures `run-at-time' here and the test decides when quiet has come."
  (when ao--timer
    (apply #'funcall ao--timer)
    (setq ao--timer nil)))

(defmacro ao--capture-wire (&rest body)
  "Run BODY with `acp-send-request' capturing requests to `ao--sent'.
Lets a test pump the resume handshake synchronously, driving each
response callback the way the process filter would.  Timers are
captured too (see `ao--settle'), because nothing here may block on
real time."
  `(let ((ao--sent nil) (ao--timer nil) (ao--armings 0))
     (cl-letf (((symbol-function 'acp-send-request)
                ;; `&rest' then plist reads: an interpreted `&key' lambda
                ;; does not parse keywords at all, so the cl-letf'd
                ;; function would be called with the raw plist as
                ;; positional args.
                (lambda (&rest kw)
                  (let ((request (plist-get kw :request)))
                    (push (cons (map-elt request ':method)
                                (list :request request
                                      :on-success (plist-get kw :on-success)))
                          ao--sent))))
               ((symbol-function 'executable-find) (lambda (&rest _) t))
               ;; (run-at-time SECONDS REPEAT FUNCTION &rest ARGS).  Org
               ;; arms its own timers when a chat buffer is created, so
               ;; only the replay render is captured and counted.
               ((symbol-function 'run-at-time)
                (lambda (&rest args)
                  (when (eq (nth 2 args) 'agent-org--finish-replay)
                    (cl-incf ao--armings)
                    (setq ao--timer (cons (nth 2 args) (nthcdr 3 args))))
                  (list :captured-timer)))
               ((symbol-function 'cancel-timer) (lambda (&rest _) nil)))
       ,@body)))

(defconst ao--fake-init-resp
  '((agentCapabilities . ((loadSession . t)
                          (sessionCapabilities . ((list) (close) (delete))))))
  "Initialize response advertising load + list.")

(ert-deftest test-agent-org-resume-end-to-end-with-explicit-id ()
  "initialize -> session/load -> updates buffered -> batched render ->
ready + open prompt.  An explicit SESSION-ID skips session/list."
  (ao--capture-wire
    (let* ((buf (agent-org-resume-session 'qoder "sid-r"))
           (session (agent-org--session-for-buffer buf)))
      (should session)
      (should (eq (plist-get session :name) 'qoder))
      (should (equal (caar ao--sent) "initialize"))
      (ao--drive "initialize" ao--fake-init-resp)
      (should (equal (caar ao--sent) "session/load"))
      (should-not (ao--sent-get "session/list"))
      (let ((request (plist-get (ao--sent-get "session/load") :request)))
        (should (equal (map-elt (map-elt request ':params) 'sessionId)
                       "sid-r")))
      ;; while the load is in flight the header says Restoring and
      ;; replay updates never touch the body
      (with-current-buffer buf
        (should (equal (plist-get agent-org-buffer--status :state)
                       'loading))
        (should (string-match-p "Restoring"
                                (agent-org-buffer--render-header-line))))
      (dolist (update (list
                       '((sessionUpdate . "user_message_chunk")
                         (content . ((type . "text") (text . "Old question"))))
                       '((sessionUpdate . "agent_message_chunk")
                         (content . ((type . "text") (text . "Old answer"))))))
        (agent-org--on-notification session (ao--update-notif update)))
      (with-current-buffer buf
        (should-not (string-match-p "Old question" (buffer-string))))
      ;; the load response alone must not render: the agent is still
      ;; talking.  Quiet is what paints the history once and flips live.
      (ao--drive "session/load" '((sessionId . "sid-r")))
      (should (plist-get session :loading))
      (ao--settle)
      (with-current-buffer buf
        (should (string-match-p "Old question" (buffer-string)))
        (should (string-match-p "Old answer" (buffer-string)))
        (should (apply #'ao--ordered (buffer-string)
                       (list "Old question" "Old answer")))
        (should (equal (plist-get agent-org-buffer--status :state)
                       'ready))
        (should (agent-org-buffer--open-prompt-p)))
      (should (null (plist-get session :loading)))
      (should-not (plist-get session :streaming))
      (kill-buffer buf))))

(ert-deftest test-agent-org-resume-queries-list-when-no-id ()
  "Without an explicit id, resume lists sessions and loads the chosen
one (a single listing is auto-selected, no prompt)."
  (ao--capture-wire
    (let* ((buf (agent-org-resume-session 'qoder nil))
           (session (agent-org--session-for-buffer buf)))
      (ao--drive "initialize" ao--fake-init-resp)
      (should (equal (caar ao--sent) "session/list"))
      (ao--drive "session/list"
                 `((sessions . [((sessionId . "solo-1")
                                 (title . "Solo chat")
                                 (updatedAt . "2026-09-29T04:00:00Z"))])))
      (let ((request (plist-get (ao--sent-get "session/load") :request)))
        (should request)
        ;; ACP requests are alists of (:key . value) pairs, not plists:
        ;; read them with `map-elt', never `plist-get'.
        (should (equal (map-elt (map-elt request ':params) 'sessionId)
                       "solo-1")))
      (ao--drive "session/load" '((sessionId . "solo-1")))
      (ao--settle)
      (with-current-buffer buf
        (should (equal (plist-get agent-org-buffer--status :state)
                       'ready))
        (should (equal (plist-get session :session-id) "solo-1")))
      (kill-buffer buf))))

(ert-deftest test-agent-org-replay-renders-updates-arriving-after-response ()
  "The ACP spec says history arrives before the session/load response,
but live qoder answers first and streams the replay right after.  The
response must therefore NOT be the flush point: late updates stay
buffered, each one re-arms the quiet-period render, and the whole
history — before and after the response — lands in one pass."
  (ao--capture-wire
    (let ((buf (agent-org-resume-session 'qoder "sid-late")))
      (let ((session (agent-org--session-for-buffer buf)))
        (ao--drive "initialize" ao--fake-init-resp)
        (agent-org--on-notification
         session (ao--update-notif
                  '((sessionUpdate . "user_message_chunk")
                    (content . ((type . "text") (text . "Old question"))))))
        (ao--drive "session/load" '((sessionId . "sid-late")))
        (should (= 1 ao--armings))
        (with-current-buffer buf
          (should (equal 'loading (plist-get agent-org-buffer--status :state)))
          (should-not (string-match-p "Old question" (buffer-string))))
        ;; history that lands after the response is still buffered, and
        ;; pushes the render back rather than being dropped
        (agent-org--on-notification
         session (ao--update-notif
                  '((sessionUpdate . "agent_message_chunk")
                    (content . ((type . "text") (text . "Old answer"))))))
        (should (= 2 ao--armings))
        (should (= 2 (length (plist-get session :replay))))
        (with-current-buffer buf
          (should-not (string-match-p "Old answer" (buffer-string))))
        ;; quiet: one batched render, then live
        (ao--settle)
        (with-current-buffer buf
          (should (apply #'ao--ordered (buffer-string)
                         (list "Old question" "Old answer")))
          (should (equal 'ready (plist-get agent-org-buffer--status :state)))
          (should (agent-org-buffer--open-prompt-p)))
        (should (null (plist-get session :loading)))
        (should (null (plist-get session :replay)))
        (should (null (plist-get session :replay-timer)))
        (should (equal "sid-late" (plist-get session :session-id)))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-replay-paints-every-tool-call-of-a-turn ()
  "A replayed turn keeps the same shape as a typed one: one `* Agent'
heading, one `**' TODO heading per distinct toolCallId, thoughts folded,
and an update rewrites its own heading instead of adding a second.
Live qoder replayed 4 tool calls but the buffer showed 1 heading, so
this pins the whole turn down at once."
  (ao--capture-wire
    (let ((buf (agent-org-resume-session 'qoder "sid-tools")))
      (let ((session (agent-org--session-for-buffer buf)))
        (ao--drive "initialize" ao--fake-init-resp)
        (ao--drive "session/load" '((sessionId . "sid-tools")))
        (dolist (update
                 (list '((sessionUpdate . "user_message_chunk")
                         (content . ((type . "text") (text . "Do things"))))
                       '((sessionUpdate . "agent_thought_chunk")
                         (content . ((type . "text") (text . "plan"))))
                       '((sessionUpdate . "agent_message_chunk")
                         (content . ((type . "text") (text . "working"))))
                       '((sessionUpdate . "tool_call")
                         (toolCallId . "t1") (title . "read a") (status . "pending"))
                       '((sessionUpdate . "agent_thought_chunk")
                         (content . ((type . "text") (text . "more"))))
                       '((sessionUpdate . "tool_call")
                         (toolCallId . "t2") (title . "read b") (status . "pending"))
                       '((sessionUpdate . "agent_thought_chunk")
                         (content . ((type . "text") (text . "even more"))))
                       '((sessionUpdate . "tool_call")
                         (toolCallId . "t3") (title . "read c") (status . "pending"))
                       '((sessionUpdate . "agent_thought_chunk")
                         (content . ((type . "text") (text . "last"))))
                       '((sessionUpdate . "tool_call")
                         (toolCallId . "t4") (title . "read d") (status . "pending"))
                       ;; t1 finishes: rewrites its heading, never a fifth one
                       '((sessionUpdate . "tool_call_update")
                         (toolCallId . "t1") (status . "completed"))))
          (agent-org--on-notification session (ao--update-notif update)))
        (should (= 11 (length (plist-get session :replay))))
        ;; armed once by the load response, then pushed back as long as
        ;; updates keep coming
        (should (> ao--armings 1))
        (ao--settle)
        (let ((text (with-current-buffer buf (buffer-string))))
          (should (string-match-p "Do things" text))
          (should (equal 1 (ao--count-occurrences text "^\\* Agent$")))
          (should (equal 4 (ao--count-occurrences text "^\\*\\* ")))
          ;; the completed call was rewritten in place, the others stayed
          ;; pending
          (should (equal 1 (ao--count-occurrences text
                                                  "^\\*\\* DONE read a \\[t1\\]$")))
          (should (equal 3 (ao--count-occurrences text "^\\*\\* TODO ")))
          (should (equal 1 (ao--count-occurrences text "^:thinking:$")))
          (should (equal 'ready
                         (with-current-buffer buf
                           (plist-get agent-org-buffer--status :state)))))
        ;; Org forbids headlines inside a drawer, and the drawer body is
        ;; rewritten wholesale by the next thought: every heading must be
        ;; above the fold, none within it.  So the text before the
        ;; `:thinking:' line already holds all four.
        (let ((above-fold
               (with-current-buffer buf
                 (buffer-substring-no-properties
                  (point-min)
                  (save-excursion
                    (goto-char (point-min))
                    (re-search-forward "^:thinking:$")
                    (match-beginning 0))))))
          (should (= 4 (ao--count-occurrences above-fold "^\\*\\* "))))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-replay-settle-cap-stops-pushback ()
  "An agent that never pauses between replayed turns must not hold a
buffer in Restoring forever: past `agent-org-replay-settle-cap' the
armed render is left to fire instead of being pushed back again, and
the updates it buffers are still not dropped."
  (ao--capture-wire
    (let ((buf (agent-org-resume-session 'qoder "sid-cap")))
      (let ((session (agent-org--session-for-buffer buf)))
        (ao--drive "initialize" ao--fake-init-resp)
        (ao--drive "session/load" '((sessionId . "sid-cap")))
        (should (= 1 ao--armings))
        ;; a clock past `agent-org-replay-settle-cap', whatever the epoch
        (cl-letf (((symbol-function 'float-time) (lambda () 1e15)))
          (agent-org--on-notification
           session (ao--update-notif
                    '((sessionUpdate . "agent_message_chunk")
                      (content . ((type . "text") (text . "late"))))))
          (should (= 1 ao--armings)))
        (should (= 1 (length (plist-get session :replay))))
        (ao--settle)
        (with-current-buffer buf
          (should (string-match-p "late" (buffer-string)))
          (should (equal 'ready (plist-get agent-org-buffer--status :state))))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-metadata-refresh-skips-unchanged ()
  "A refresh whose rendered block is byte-identical is a no-op.
`usage_update' arrives many times per turn; rebuilding the block each
time would re-parse every heading in the buffer
(`org-set-regexps-and-options'), which is exactly what a slow machine
cannot afford.  The parse count is the pin."
  (let ((buf (agent-org-buffer-create "skip"))
        (parses 0))
    (cl-letf (((symbol-function 'org-set-regexps-and-options)
               (lambda (&rest _args) (cl-incf parses))))
      (agent-org-buffer-refresh-metadata buf)
      (should (= 1 parses))
      (let ((text (with-current-buffer buf (buffer-string))))
        (agent-org-buffer-refresh-metadata buf)
        (should (= 1 parses))
        (with-current-buffer buf (should (equal text (buffer-string))))
        (agent-org-buffer-set-status buf :used 1000 :size 2000)
        (agent-org-buffer-refresh-metadata buf)
        (should (= 2 parses))
        (with-current-buffer buf
          (should (string-match-p ":Context: 1k/2k (50%)"
                                  (buffer-string))))))
    (kill-buffer buf)))

;;;; Model selection (MiniMax over the OpenCode ACP host)

(defun ao--config-resp (current values &optional session-id)
  "A session response whose configOptions offer a single `model' option.
CURRENT is its currentValue; VALUES the options offered, as
\(VALUE . NAME) pairs, and SESSION-ID the session they belong to.  Both
`session/new' and `session/load' answer this way, and so does
`session/set_config_option' with the new set.  Vectors because the wire
decodes JSON arrays as vectors, and `name' because that is what OpenCode
calls the label field here."
  `((sessionId . ,(or session-id "sid-new"))
    (configOptions .
     [((id . "model") (name . "Model") (type . "select")
       (currentValue . ,current)
       (options . ,(vconcat
                    (seq-map (lambda (pair)
                               `((value . ,(car pair)) (name . ,(cdr pair))))
                             values))))])))

(defun ao--sent-count (method)
  "How many requests for METHOD the capture saw."
  (seq-count (lambda (entry) (string= (car entry) method)) ao--sent))

(defun ao--set-model-params ()
  "The params alist of the last session/set_config_option request."
  (map-elt (plist-get (ao--sent-get "session/set_config_option") ':request)
           ':params))

(defconst ao--pin-model "minimax/MiniMax-M3"
  "Model id the pinning tests make a provider want.  It is what MiniMax
Code's own config (`defaultModel' in ~/.minimax/config.yaml) calls a
MiniMax model, so the fake agents in these tests advertise it as if they
were a host that fronts many models.")

(defmacro ao--with-pinned-provider (&rest body)
  "Run BODY with the MiniMax provider entry given a `:model' pin.
No shipped provider pins anything now that MiniMax Code runs its own
`mcode acp' (`agent-org-providers.el'), but a many-model host such as
OpenCode still needs the pin path, so it stays covered against an entry
that in real use would not carry `:model'."
  `(let ((agent-org-providers
          (cons (plist-put (copy-sequence (agent-org--provider-spec 'minimax))
                           :model ao--pin-model)
                ;; the let's own initializer still sees the plain entry
                (seq-remove (lambda (p) (eq (plist-get p :id) 'minimax))
                            agent-org-providers))))
     ,@body))

(ert-deftest test-agent-org-pinned-model-start-sends-the-request ()
  "A provider that pins a model sends session/set_config_option for it.
This is the many-model-host case: OpenCode answers a fresh session with a
shared default (seen live: gomodel/aa-coding), so a pin is what makes the
provider mean the model it names."
  (ao--capture-wire
    (ao--with-pinned-provider
      (let* ((buf (agent-org-start 'minimax))
             (pinned ao--pin-model))
        (ao--drive "initialize" ao--fake-init-resp)
        (ao--drive "session/new"
                   (ao--config-resp "gomodel/aa-coding"
                    (list (cons "opencode/minimax-m2.5"
                                "OpenCode Zen/MiniMax-M2.5")
                          (cons pinned "OpenCode Zen/MiniMax"))))
        (let ((params (ao--set-model-params)))
          (should params)
          (should (equal (map-elt params 'configId) "model"))
          (should (equal (map-elt params 'value) pinned))
          (should (equal (map-elt params 'sessionId) "sid-new")))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-pinned-model-resume-sends-the-request ()
  "A resumed session of a pinning provider gets the pin too: `session/load'
answers with configOptions just like `session/new', and the replay flush
goes through the same ready path."
  (ao--capture-wire
    (ao--with-pinned-provider
      (let* ((buf (agent-org-resume-session 'minimax "sid-min"))
             (pinned ao--pin-model))
        (ao--drive "initialize" ao--fake-init-resp)
        (ao--drive "session/load" (ao--config-resp "opencode/minimax-m2.5"
                                                  (list (cons pinned "MiniMax"))
                                                  "sid-min"))
        (ao--settle)
        (let ((params (ao--set-model-params)))
          (should (equal (map-elt params 'value) pinned))
          ;; the pin must follow the session that was loaded, not the id
          ;; the request was made with before the replay flushed
          (should (equal (map-elt params 'sessionId) "sid-min")))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-pinned-model-already-current-is-not-resent ()
  "When the agent already reports the wanted model, say nothing on the wire.
Sending a no-op set_config_option would be one more round trip on a
process that is slow to answer."
  (ao--capture-wire
    (ao--with-pinned-provider
      (let ((buf (agent-org-start 'minimax))
            (pinned ao--pin-model))
        (ao--drive "initialize" ao--fake-init-resp)
        (ao--drive "session/new" (ao--config-resp pinned (list (cons pinned "MiniMax"))))
        (should (zerop (ao--sent-count "session/set_config_option")))
        ;; the session is usable regardless
        (with-current-buffer buf
          (should (equal 'ready (plist-get agent-org-buffer--status :state)))
          (should (equal pinned (plist-get agent-org-buffer--status :model))))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-pinned-model-not-offered-is-reported ()
  "A model the agent does not list is never sent, only reported.
OpenCode renames its catalog from release to release, so a pinned id can
go stale; failing the request would leave the header showing an error for
a session that works fine on another model.  The report is an echo-area
message because the Ready segment hides a bare status message."
  (ao--capture-wire
    (ao--with-pinned-provider
      (let ((buf (agent-org-start 'minimax))
            (seen nil))
        (cl-letf (((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (push (apply #'format fmt args) seen))))
          (ao--drive "initialize" ao--fake-init-resp)
          (ao--drive "session/new"
                     (ao--config-resp "gomodel/aa-coding"
                      (list (cons "opencode/minimax-m2.5"
                                  "OpenCode Zen/MiniMax-M2.5")))))
        (should (zerop (ao--sent-count "session/set_config_option")))
        (should (seq-some (lambda (m) (string-match-p "minimax" m)) seen))
        (with-current-buffer buf
          (should (equal 'ready (plist-get agent-org-buffer--status :state)))
          ;; the header keeps showing what the agent actually runs
          (should (equal "gomodel/aa-coding"
                         (plist-get agent-org-buffer--status :model))))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-pinned-model-applied-exactly-once ()
  "The pin survives repeated ready calls (mid-turn updates re-enter it).
Otherwise every `session_info_update' would re-send the same request."
  (ao--capture-wire
    (ao--with-pinned-provider
      (let ((buf (agent-org-start 'minimax)))
        (ao--drive "initialize" ao--fake-init-resp)
        (dotimes (_ 3)
          (ao--drive "session/new"
                     (ao--config-resp "gomodel/aa-coding"
                      (list (cons ao--pin-model "MiniMax")))))
        (should (= 1 (ao--sent-count "session/set_config_option")))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-minimax-start-pins-nothing ()
  "A MiniMax Code session asks the agent for no model at all.
`mcode' is MiniMax's own agent, so its own default model is the right
one; pinning would fight `defaultModel' in its config.  This guards the
old OpenCode-shaped design — MiniMax as a pinned model inside
`opencode acp' — from creeping back."
  (ao--capture-wire
    (let ((buf (agent-org-start 'minimax)))
      (ao--drive "initialize" ao--fake-init-resp)
      (ao--drive "session/new"
                 (ao--config-resp "minimax/MiniMax-M3"
                  (list (cons "minimax/MiniMax-M3" "MiniMax M3")
                        (cons "minimax/MiniMax-M2.7" "MiniMax M2.7"))))
      (should (zerop (ao--sent-count "session/set_config_option")))
      (with-current-buffer buf
        (should (equal 'ready (plist-get agent-org-buffer--status :state)))
        (should (equal "minimax/MiniMax-M3"
                       (plist-get agent-org-buffer--status :model))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-set-session-model-switches-and-updates-header ()
  "Choosing a model sends the request and re-reads the header from the
response, so what the top bar shows is what the agent agreed to."
  (ao--capture-wire
    (let ((buf (agent-org-start 'qoder)))
      (ao--drive "initialize" ao--fake-init-resp)
      (ao--drive "session/new"
                 (ao--config-resp "qmodel"
                  (list (cons "qmodel" "QModel")
                        (cons "qmodel-large" "QModel Large"))))
      (with-current-buffer buf (agent-org-set-session-model "qmodel-large"))
      (let ((params (ao--set-model-params)))
        (should (equal (map-elt params 'configId) "model"))
        (should (equal (map-elt params 'value) "qmodel-large")))
      (ao--drive "session/set_config_option"
                 (ao--config-resp "qmodel-large"
                  (list (cons "qmodel" "QModel")
                        (cons "qmodel-large" "QModel Large"))))
      (with-current-buffer buf
        (should (equal "qmodel-large"
                       (plist-get agent-org-buffer--status :model)))
        (should (string-match-p "qmodel-large"
                                (agent-org-buffer--render-header-line))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-set-session-model-rejects-unadvertised-model ()
  "A lisp caller cannot smuggle an id the agent never offered.
The check that keeps the interactive path honest is the same one that
matters when lisp calls in."
  (ao--capture-wire
    (let ((buf (agent-org-start 'qoder)))
      (ao--drive "initialize" ao--fake-init-resp)
      (ao--drive "session/new" (ao--config-resp "qmodel" (list (cons "qmodel" "QModel"))))
      (should-error (with-current-buffer buf
                      (agent-org-set-session-model "gpt-99"))
                    :type 'user-error)
      (should (zerop (ao--sent-count "session/set_config_option")))
      (kill-buffer buf))))

(ert-deftest test-agent-org-set-session-model-rejects-non-chat-buffer ()
  "Outside a chat buffer there is no session to reconfigure."
  (with-temp-buffer
    (should-error (agent-org-set-session-model "m") :type 'user-error)))

;;;; Command names, following agent-shell

(ert-deftest test-agent-org-session-command-names-match-agent-shell ()
  "Session-level commands borrow agent-shell's names.
agent-shell says `agent-shell-resume-session' and
`agent-shell-set-session-model' — the object of the verb is the session,
because one buffer's agent can be reconfigured in several ways (model,
mode, thought level, any config option).  The old short names are gone
rather than kept as aliases, so each action has exactly one name to
find in M-x."
  (dolist (name '(agent-org-start
                  agent-org-send
                  agent-org-resume-session
                  agent-org-set-session-model))
    (should (commandp name)))
  (dolist (gone '(agent-org-resume agent-org-set-model))
    (should-not (fboundp gone))))

(ert-deftest test-agent-org-every-provider-has-a-start-agent-command ()
  "Every registered provider has an `agent-org-<id>-start-agent'.
That is how agent-shell exposes its agents: one named entry point per
provider (`agent-shell-goose-start-agent'), so M-x completion on the
package prefix lists the choices instead of hiding them behind one
command that prompts.  The test, not a macro, is what keeps the two
lists from drifting: add a provider without its command and this fails."
  (dolist (spec agent-org-providers)
    (should (commandp (intern (format "agent-org-%s-start-agent"
                                      (plist-get spec :id)))))))

(ert-deftest test-agent-org-goose-start-agent-opens-goose ()
  "The per-provider command is a thin call with the id baked in: right
session, same buffer, nothing invented.  It must not grow its own
handshake, or the two entry paths would drift."
  (ao--capture-wire
    (let ((buf (agent-org-goose-start-agent)))
      (should (buffer-live-p buf))
      (should (eq 'goose (plist-get (agent-org--session-for-buffer buf) :name)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-failure-text-is-the-agents-own-sentence ()
  "A JSON-RPC error is reported by its message, not dumped whole.
Live opencode answered a prompt with -32603 and the header line got the
entire (:object …) (:json …) pair — hundreds of characters replacing the
Ready segment.  `agent-org--failure-text' is the one channel every
:on-failure callback uses now."
  (should (equal "Upstream request failed: Insufficient account funds"
                 (agent-org--failure-text
                  '((:object (jsonrpc . "2.0") (id . 4)
                             (error (code . -32603)
                                    (message . "Upstream request failed: Insufficient account funds")
                                    (data (service . "session")
                                          (errorName . "APIError"))))
                    (:json . "{\"jsonrpc\":\"2.0\",\"id\":4}")))))
  (should (equal "plain sentence" (agent-org--failure-text "plain sentence")))
  ;; an error carrying no message still reports something
  (should (string-match-p "404" (agent-org--failure-text '((:json . "404 not found"))))))

(provide 'test-agent-org)
;;; test-agent-org.el ends here
