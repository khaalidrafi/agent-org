;;; test-agent-org.el --- Tests for agent-org -*- lexical-binding: t; -*-

(require 'ert)
(require 'agent-org)
(require 'agent-org-buffer)
(require 'agent-org-providers)

;;; Provider registry

(ert-deftest test-agent-org-goose-provider-present ()
  "Goose provider is registered with required fields."
  (let ((goose (seq-find (lambda (p) (eq (plist-get p :id) 'goose))
                         agent-org-providers)))
    (should goose)
    (should (equal (plist-get goose :name) "Goose"))
    (should (equal (plist-get goose :command) '("goose" "acp")))
    (should (fboundp (plist-get goose :environment)))))

;;; Buffer creation

(defvar agent-org-test--displayed-p nil
  "Non-nil when a visible frame exists (interactive Emacs).
`font-lock-mode' is a delayed mode that only activates in a
displayed buffer, so font-lock assertions are skipped headless.")

(ert-deftest test-agent-org-buffer-create ()
  "Creates an org-mode buffer with agent-org-mode and read-only."
  (let ((buf (agent-org-buffer-create "test")))
    (with-current-buffer buf
      ;; font-lock is normally enabled via global-font-lock-mode.  Under
      ;; emacs -Q (no frame) the delayed mode cannot activate, so don't
      ;; assert it headless.
      (should buf)
      (should (buffer-live-p buf))
      (should (string-prefix-p "*agent-org: test" (buffer-name buf)))
      (should (derived-mode-p 'org-mode))
      (should buffer-read-only)
      (when agent-org-test--displayed-p
        (should font-lock-mode))
      (should (bound-and-true-p agent-org-mode)))
    (kill-buffer buf)))

;;; Session registry

(ert-deftest test-agent-org--session-for-buffer ()
  "Returns session plist for the registered buffer."
  (let* ((buf (agent-org-buffer-create "registry-test"))
         (entry (list :name 'test :client nil :buffer buf :session-id nil :streaming nil)))
    (agent-org--register-session entry)
    (should (eq (plist-get (agent-org--session-for-buffer buf) :buffer) buf))
    (kill-buffer buf)))

;;; Streaming without font-lock

(ert-deftest test-agent-org-buffer-streaming-lifecycle ()
  "Append-chunk starts an Agent turn, disables font-lock, end re-enables.
The disable/re-enable is only observable when a frame is displayed
(font-lock is a delayed mode); otherwise the streaming flag still
tracks the turn correctly."
  (let* ((buf (agent-org-buffer-create "stream"))
         (session (list :name 'test :buffer buf)))
    (with-current-buffer buf
      (when agent-org-test--displayed-p
        (font-lock-mode 1)
        (should font-lock-mode))
      (should-not agent-org-buffer--streaming-p))
    ;; Simulate an agent message chunk
    (agent-org-buffer-append-chunk buf "Hello " session)
    (with-current-buffer buf
      (should agent-org-buffer--streaming-p)
      (when agent-org-test--displayed-p
        ;; font-lock must have been disabled by start-agent-turn
        (should-not font-lock-mode))
      (should (string-match-p "Hello " (buffer-string)))
      (should (string-match-p "\\* Agent" (buffer-string))))
    ;; Append more
    (agent-org-buffer-append-chunk buf "world" session)
    (with-current-buffer buf
      (should (string-match-p "Hello world" (buffer-string))))
    ;; End turn — font-lock must be re-enabled
    (agent-org-buffer-end-agent-turn buf)
    (with-current-buffer buf
      (should-not agent-org-buffer--streaming-p)
      (when agent-org-test--displayed-p
        (should font-lock-mode)))
    (kill-buffer buf)))

;;; System messages

(ert-deftest test-agent-org-buffer-insert-system ()
  "System messages appear as Org comment blocks."
  (let ((buf (agent-org-buffer-create "sys")))
    (agent-org-buffer-insert-system buf "Session started: abc123")
    (with-current-buffer buf
      ;; #+ is literal in the buffer; need regex-safe match
      (should (string-match-p "#\\+begin_comment" (buffer-string)))
      (should (string-match-p "abc123" (buffer-string))))
    (kill-buffer buf)))

;;; Thought chunks

(ert-deftest test-agent-org-buffer-thought ()
  "Thought chunks are written into a :thinking: drawer."
  (let ((buf (agent-org-buffer-create "think")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-thought buf "reasoning about the problem")
    (with-current-buffer buf
      (should (string-match-p ":thinking:" (buffer-string)))
      (should (string-match-p "reasoning about the problem" (buffer-string)))
      (should (string-match-p ":end:" (buffer-string))))
    (kill-buffer buf)))

;;; Tool call insertion

(ert-deftest test-agent-org-buffer-tool-insert ()
  "Tool calls are inserted as level-2 Org headings."
  (let ((buf (agent-org-buffer-create "tool")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool buf '((toolName . "read_file") (toolCallId . "tc1")))
    (with-current-buffer buf
      (should (string-match-p "\\*\\* Tool: read_file \\[tc1\\]" (buffer-string))))
    (kill-buffer buf)))

;;; Prompt read

(ert-deftest test-agent-org-buffer-read-prompt-from-heading ()
  "Reads text from a User heading at point."
  (let ((buf (agent-org-buffer-create "prompt")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (insert "* User\n\nHello agent\n"))
      (goto-char (point-min))
      (should (equal (agent-org-buffer-read-prompt buf) "Hello agent")))
    (kill-buffer buf)))

;;; acp-make-session-prompt-request shape

(ert-deftest test-acp-prompt-request-shape ()
  "Prompt request has the expected ACP shape."
  (let ((req (acp-make-session-prompt-request :session-id "s1" :prompt "hi")))
    (should (equal (map-elt req :method) "session/prompt"))
    (should (equal (map-nested-elt req '(:params sessionId)) "s1"))
    ;; prompt is vectorized by acp-make-session-prompt-request
    (should (vectorp (map-nested-elt req '(:params prompt))))))

;;; ACP client creation shape

(ert-deftest test-acp-client-creation ()
  "acp-make-client produces a well-formed client alist."
  (let ((c (acp-make-client :command "echo" :command-params '("hello"))))
    (should (equal (map-elt c :command) "echo"))
    (should (equal (map-elt c :command-params) '("hello")))
    (should-not (map-elt c :process))))

(provide 'test-agent-org)
;;; test-agent-org.el ends here
