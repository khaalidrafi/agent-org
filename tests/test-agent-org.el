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
;; `ert-with-temp-directory' — the transcript tests are the first here to
;; touch the disk, and that macro lives in ert-x, not ert.
(require 'ert-x)
;; A `.elc' beside the sources wins the load race, so a suite run after a
;; package-compile step would test the 4-am image of the code rather than
;; the edit under test — silently, and the warning only goes to
;; `standard-error'.  Prefer the newer file, always.
(setq load-prefer-newer t)
;; The transcript writer is ON by default, and most fixtures below produce a
;; Ready session with an id — so without this guard every such test mirrors its
;; chat into `agent-org-transcript-directory', which for a relative default is
;; the directory the suite happens to be running in.  Measured: a full run
;; dropped 22 `sid-*.org' files in the package tree.  A test that cares about
;; the file says so with `ao--transcript-in', which turns the writer back on
;; inside its own temp directory.
(setq agent-org-transcribe nil)
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

(defconst ao--name-dir "/tmp/ao-proj/"
  "Fixed `default-directory' for the buffer-name tests.
A name carries the project — the last directory component of the cwd the
buffer was created in — so tests that assert an exact name bind this
instead of inheriting whatever directory the suite was launched
from.  The directory need not exist: nothing here touches the disk.")

(ert-deftest test-agent-org-buffer-create ()
  "Creates an org-mode buffer with agent-org-mode, typeable, and status."
  (let ((default-directory ao--name-dir))
    (let ((buf (agent-org-buffer-create "test")))
      (with-current-buffer buf
        (should buf)
        (should (buffer-live-p buf))
        (should (string-prefix-p "test:ao-proj" (buffer-name buf)))
        (should (derived-mode-p 'org-mode))
        (should-not buffer-read-only)
        (should-not (bound-and-true-p cursor-intangible-mode))
        (should (bound-and-true-p agent-org-mode))
        (should (equal (plist-get agent-org-buffer--status :state) 'starting))
        (should header-line-format))
      (kill-buffer buf))))

;;;; Buffer names: <who>:<project> [id]

(ert-deftest test-agent-org-buffer-name-carries-project ()
  "The chat's own name leads, and the project follows the colon.
`Qoder:agent-org [sid]' is the shape the user asked for: the agent or the
title first, because that is what a person scans for, and the last
directory component of the cwd after the colon, because that is what
tells a chat of ~/proj-a from a chat of ~/proj-b (measured live: two
sessions in two projects produced two switcher rows identical but for
their UUIDs until the project entered the name).  The creation name
already wears both — a buffer is findable from the handshake, not only
after the agent answers."
  (let ((default-directory ao--name-dir))
    (let ((buf (agent-org-buffer-create "qoder")))
      (should (string-prefix-p "qoder:ao-proj" (buffer-name buf)))
      (agent-org-buffer-set-status buf :session-id "sid-prj")
      (should (equal "qoder:ao-proj [sid-prj]" (buffer-name buf)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-buffer-name-gains-title-and-id ()
  "Once the agent names the session, its buffer is that session.
`Qoder:agent-org' tells a user with three chats open nothing; the title
the harness reports, the project and the id the wire addresses are the
facts that make a buffer distinguishable in `C-x b' and in the switcher."
  (let ((default-directory ao--name-dir))
    (let* ((pair (ao--make-test-session "nametest"))
           (buf (car pair))
           (session (cdr pair)))
      (setf (plist-get session :session-id) nil)
      (agent-org--session-ready session "sid-x" (ao--fake-session-new-resp))
      (should (equal "Initial Session Title:ao-proj [sid-x]"
                     (buffer-name buf)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-buffer-name-wears-provider-without-a-title ()
  "A session with no title yet is still findable by id.
The provider name stands in exactly as it does for `#+TITLE:', so the
buffer is never left with the pre-handshake name once an id exists."
  (let ((default-directory ao--name-dir))
    (let ((buf (agent-org-buffer-create "standin")))
      (agent-org-buffer-set-status buf :session-id "sid-9")
      (should (equal "standin:ao-proj [sid-9]" (buffer-name buf)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-buffer-name-follows-a-late-title ()
  "A title that arrives mid-conversation renames the buffer.
qoder titles a session after the first turn (`session_info_update'), so
naming only at readiness would freeze every one of its buffers at the
provider's name."
  (let ((default-directory ao--name-dir))
    (let* ((pair (ao--make-test-session "latetitle"))
           (buf (car pair)))
      (agent-org-buffer-set-status buf :session-id "sid-l")
      (should (equal "latetitle:ao-proj [sid-l]" (buffer-name buf)))
      (agent-org-buffer-set-status buf :title "Refactor the parser")
      (should (equal "Refactor the parser:ao-proj [sid-l]"
                     (buffer-name buf)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-buffer-name-flattens-a-multiline-title ()
  "Agent-supplied titles go through the same one-line filter headings do.
A title is free text; a newline in a buffer name would break `C-x b'
rendering, so the label rule applies here too — and the truncation it
performs cannot swallow the project either, so the test pins the end of
the name as well as its beginning."
  (let ((default-directory ao--name-dir))
    (let ((buf (agent-org-buffer-create "multiline"))
          (long (concat "First line\n" (make-string 200 ?x) "\ntrailing")))
      (agent-org-buffer-set-status buf :session-id "sid-m" :title long)
      (with-current-buffer buf
        (should-not (string-match-p "\n" (buffer-name)))
        (should (string-prefix-p "First line" (buffer-name)))
        (should (string-suffix-p ":ao-proj [sid-m]" (buffer-name))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-buffer-name-does-not-accumulate-suffixes ()
  "Re-announcing the same title and id is not a rename.
`generate-new-buffer-name' counts OUR OWN buffer when it already wears
that name, so an unconditional rename would walk
`T [s]<2><3><4>' over a session's lifetime — every status update, of
which a turn sends dozens."
  (let ((default-directory ao--name-dir))
    (let* ((pair (ao--make-test-session "churn"))
           (buf (car pair)))
      (dotimes (_ 5)
        (agent-org-buffer-set-status buf :session-id "sid-c"
          :title "Same Title")
        (agent-org-buffer-set-status buf :used 100 :size 200 :state 'streaming)
        (agent-org-buffer-set-status buf :state 'ready))
      (should (equal "Same Title:ao-proj [sid-c]" (buffer-name buf)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-buffer-names-stay-unique-per-session ()
  "Two sessions, two buffers, one name each.
Ids differ, so the names differ; and a name that is already taken must
still produce a live, distinct buffer rather than clobbering the other."
  (let ((default-directory ao--name-dir))
    (let* ((a (ao--make-test-session "twin-a"))
           (b (ao--make-test-session "twin-b"))
           (bufa (car a))
           (bufb (car b)))
      (agent-org-buffer-set-status bufa :session-id "sid-1" :title "Twin")
      (agent-org-buffer-set-status bufb :session-id "sid-2" :title "Twin")
      (should (equal "Twin:ao-proj [sid-1]" (buffer-name bufa)))
      (should (equal "Twin:ao-proj [sid-2]" (buffer-name bufb)))
      ;; the same id twice cannot happen; the same title with no id can
      (agent-org-buffer-set-status bufb :session-id nil :title "Twin")
      (should (equal "Twin:ao-proj" (buffer-name bufb)))
      (kill-buffer bufa)
      (kill-buffer bufb))))

(ert-deftest test-agent-org-buffer-name-wears-no-star-delimiters ()
  "The name is the chat, not an internal Emacs buffer.
`*agent-org: …*' is the Emacs convention for a buffer that is not a file,
but it is noise in `C-x b', in the switcher and in a mode line that
repeats it, and the user's asked-for shape has no delimiters in it.  So
nothing in the name is decorative: no leading `agent-org: ', no stars."
  (let ((default-directory ao--name-dir))
    (let ((buf (agent-org-buffer-create "plain")))
      (should-not (string-match-p "\\*" (buffer-name buf)))
      (should-not (string-prefix-p "agent-org" (buffer-name buf)))
      (kill-buffer buf))))

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
  "Status updates change the header line; the session id lands in the body.
The id used to ride the header-line `[sid]' segment; it now belongs to
the document as a `:ID:' property in the top PROPERTIES drawer, so the
top bar stays a status bar and the id is copyable/readable in the
transcript.  The header must not repeat it."
  (let ((buf (agent-org-buffer-create "status")))
    (agent-org-buffer-set-status buf :state 'ready :message "Ready" :session-id "abc123")
    (agent-org-buffer-refresh-metadata buf)
    (with-current-buffer buf
      ;; the id lands in the body as a drawer property
      (should (string-match-p "^:ID: abc123$" (buffer-string)))
      (should-not (string-match-p "^\\* " (buffer-string)))
      (should-not (string-match-p "System" (buffer-string)))
      (should-not (string-match-p "begin_comment" (buffer-string)))
      ;; status is reflected in the header-line model
      (should (equal (plist-get agent-org-buffer--status :state) 'ready))
      (should (equal (plist-get agent-org-buffer--status :session-id) "abc123"))
      ;; but the header line no longer carries the id
      (let ((rendered (agent-org-buffer--render-header-line)))
        (should (string-match-p "Ready" rendered))
        (should-not (string-match-p "abc123" rendered))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-status-error-renders-error-label ()
  "An error state renders an Error label in the header line."
  (let ((buf (agent-org-buffer-create "err")))
    (agent-org-buffer-set-status buf :state 'error :message "boom")
    (with-current-buffer buf
      (should (string-match-p "Error" (agent-org-buffer--render-header-line)))
      (should (string-match-p "boom" (agent-org-buffer--render-header-line))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-status-note-rides-the-ready-label ()
  "`:note' is the one thing allowed to qualify a Ready state.  A bare
`:message' cannot do the job: for `starting'/`ready' the segment renders
the state LABEL and nothing else (CONVENTIONS.md §6), which is why a
listing that timed out was reported only in the echo area and read as
\"the prompt never happens\".  The note rides AFTER the label, so the
state stays readable, and it is still exactly one segment."
  (let ((buf (agent-org-buffer-create "note")))
    (with-current-buffer buf
      (agent-org-buffer-set-status buf :state 'ready)
      (should (equal "Ready" (car (agent-org-buffer--status-segment
                                   agent-org-buffer--status))))
      (agent-org-buffer-set-status buf :note "new session (listing timed out)")
      (let ((segment (car (agent-org-buffer--status-segment
                           agent-org-buffer--status))))
        (should (string-prefix-p "Ready" segment))
        (should (string-match-p "listing timed out" segment))
        ;; one segment, one line
        (should-not (string-match-p "\n" segment)))
      ;; an error still wins: a note must not dilute a real failure
      (agent-org-buffer-set-status buf :state 'error :message "boom")
      (should (equal "Error: boom" (car (agent-org-buffer--status-segment
                                         agent-org-buffer--status))))
      ;; and the note is gone once cleared, not left as trailing noise
      (agent-org-buffer-set-status buf :state 'ready :note nil)
      (should (equal "Ready" (car (agent-org-buffer--status-segment
                                   agent-org-buffer--status)))))
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
      (should (string-match-p ":ID: +sess-9" (buffer-string)))
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

(ert-deftest test-agent-org-streaming-never-toggles-font-lock ()
  "A streaming turn must not switch `font-lock-mode' off and back on.
The old per-turn toggle blanked every Org color while a turn ran and
re-rendered the whole buffer on finish.  Font-lock now stays as the user
set it: the value is identical before and after a full streamed turn, so
colors never vanish mid-turn.  In batch font-lock is off, so this cannot
assert it turns *on* -- the invariant is that we never touch it."
  (let ((buf (agent-org-buffer-create "flive")))
    (let ((before (with-current-buffer buf font-lock-mode)))
      (agent-org-buffer-start-agent-turn buf nil)
      (with-current-buffer buf
        (should (eq font-lock-mode before)))
      (agent-org-buffer-append-chunk buf "some answer" nil)
      (with-current-buffer buf
        (should (eq font-lock-mode before)))
      (agent-org-buffer-end-agent-turn buf)
      (with-current-buffer buf
        (should (eq font-lock-mode before))))
    (kill-buffer buf)))

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

;;;; Tool calls in a :tool: drawer

(ert-deftest test-agent-org-buffer-tool-insert ()
  "A tool call is one line of the turn's `:tool:` drawer.
Status maps onto the per-file TODO keyword set (pending→TODO,
in_progress→DOING, completed→DONE, failed→CANCELLED), and the keyword is
the line's first word so the state reads the same here as it did on a
heading.  User order: \"Tool calls should be inside :tool: drawers.\"
Org forbids headlines inside drawers (info \"(org) Drawers\"), so the
calls became DRAWER LINES, and the turn's headings belong to the
conversation alone: `**' is gone."
  (let ((buf (agent-org-buffer-create "tool")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool buf '((title . "read_file")
                                        (toolCallId . "tc1")
                                        (status . "in_progress")))
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (string-match-p "^- DOING read_file$" text))
      (should (string-match-p "^:tool:$" text))
      (should (= 1 (ao--count-occurrences text "^:tool:$")))
      (should-not (string-match-p "^\\*\\* " text))
      ;; under the Agent heading, and closed: marker, line, :end:
      (should (apply #'ao--ordered text
                     (list "* Agent" ":tool:" "- DOING read_file" ":end:"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-line-drops-raw-id ()
  "The visible line carries keyword and title only, never the id.
`toolCallId' is the agent's bookkeeping: the update finds its entry in
`agent-org-buffer--tools' under that id, so printing the id on the line
only adds wire noise a reader never asked for (the user's complaint:
tool-call ids should be stripped).  Nothing on disk or in the buffer may
still carry it after an update redraws the drawer."
  (let ((buf (agent-org-buffer-create "toohide")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool buf '((title . "shell")
                                        (toolCallId . "tc-hide-1")
                                        (status . "pending")))
    (agent-org-buffer-insert-tool buf '((toolCallId . "tc-hide-1")
                                        (status . "completed")))
    (let ((text (with-current-buffer buf (buffer-string))))
      (should-not (string-match-p "tc-hide-1" text))
      (should (string-match-p "^- DONE shell$" text))
      ;; the redraw replaced the line rather than adding one
      (should (= 1 (ao--count-occurrences text "^- "))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-updates-rewrite-their-line-in-place ()
  "tool_call_update for a known id rewrites its line's keyword/title;
new ids append their own line, in the order the agent made the calls."
  (let ((buf (agent-org-buffer-create "toolup")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool buf '((title . "shell") (toolCallId . "tc1")
                                        (status . "pending")))
    (should (with-current-buffer buf
              (string-match-p "^- TODO shell$" (buffer-string))))
    ;; update without a title must not downgrade it to "tool"
    (agent-org-buffer-insert-tool buf '((toolCallId . "tc1") (status . "completed")))
    (agent-org-buffer-insert-tool buf '((toolCallId . "tc2")))
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (= 2 (ao--count-occurrences text "^- ")))
      (should (= 1 (ao--count-occurrences text "^- DONE shell$")))
      (should-not (string-match-p "TODO shell" text))
      (should (string-match-p "^- TODO tool$" text))
      (should (apply #'ao--ordered text (list "- DONE shell" "- TODO tool"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-line-flattens-multiline-title ()
  "A tool title is agent text, never a line of its own.  Live qoder
replays shell calls whose title is the whole command: several lines,
hundreds of characters.  Verbatim, one drawer entry would become several
lines and the redraw could not tell them from calls it did not make.  So
the label is flattened and truncated; the id in `agent-org-buffer--tools'
still tells two calls apart."
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
      ;; exactly ONE heading in the turn -- the Agent heading -- and two
      ;; drawer lines: nothing spilled out of the line it belongs to
      (should (= 1 (ao--count-occurrences (buffer-string) "^\\*+ ")))
      (should (= 2 (ao--count-occurrences (buffer-string) "^- ")))
      (should (string-match-p "^- TODO ls -la" (buffer-string)))
      (should-not (string-match-p "^second line$" (buffer-string)))
      ;; cut, not merely re-wrapped
      (should-not (string-match-p (make-string 300 ?x) (buffer-string))))
    ;; and the pending→done rewrite still replaces one clean line
    (agent-org-buffer-insert-tool buf '((toolCallId . "tc1")
                                        (status . "completed")))
    (with-current-buffer buf
      (should (= 1 (ao--count-occurrences (buffer-string) "^\\*+ ")))
      (should (= 2 (ao--count-occurrences (buffer-string) "^- ")))
      (should (string-match-p "^- DONE ls -la" (buffer-string)))
      (should-not (string-match-p "TODO ls" (buffer-string))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-drawer-survives-later-thought-chunk ()
  "A thought arriving AFTER a tool call re-renders the whole
:thinking: drawer, and must not delete the turn's tool lines with it.
Live qoder thinks between tool calls, so this is the normal streaming
shape of a turn — and the reason the two drawers are drawn by the same
redraw primitive, bounded to the turn, rather than by a marker per call
(the old bug: a heading placed at a drawer match's END landed INSIDE the
drawer, and the next thought chunk erased every call but the last)."
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
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (= 2 (ao--count-occurrences text "^- ")))
      (should (= 1 (ao--count-occurrences text "^:tool:$")))
      (should (= 1 (ao--count-occurrences text "^:thinking:$")))
      (should (string-match-p "^- TODO one$" text))
      (should (string-match-p "^- DONE two$" text))
      ;; the thought drawer still holds every chunk, in order
      (should (apply #'ao--ordered text
                     (list "thinking" "more thinking" "end of it"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-drawer-is-open-and-thinking-folded ()
  "Progress is visible; thinking is not.
A folded tool drawer is a chat that looks idle while the agent shells and
edits, which is the one thing a user wants to see.  Extended thinking is
the opposite: long, and noise.  So the same redraw primitive takes the
fold choice per drawer, and the two differ."
  (let ((buf (agent-org-buffer-create "toolfold")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool buf '((toolCallId . "tc1") (title . "shell")
                                        (status . "pending")))
    (agent-org-buffer-append-thought buf "a very long thought\n")
    (with-current-buffer buf
      (should-not (invisible-p
                   (save-excursion (goto-char (point-min))
                                   (re-search-forward "^- TODO shell$")
                                   (point))))
      (should (invisible-p
               (save-excursion (goto-char (point-min))
                               (re-search-forward "^a very long thought$")
                               (point)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-state-resets-per-turn ()
  "A new Agent turn gets its own drawer; old ids re-appear fresh."
  (let ((buf (agent-org-buffer-create "toolturn")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool buf '((title . "shell") (toolCallId . "tcA")))
    (agent-org-buffer-end-agent-turn buf)
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool buf '((title . "tree") (toolCallId . "tcB")))
    ;; a reused id (harness may echo an old call) must not merge into
    ;; the previous turn's drawer
    (agent-org-buffer-insert-tool buf '((title . "shell") (toolCallId . "tcA")
                                        (status . "completed")))
    (with-current-buffer buf
      (should (= 2 (ao--count-occurrences (buffer-string) "^:tool:$")))
      (should (= 1 (ao--count-occurrences (buffer-string) "^- TODO shell$")))
      (should (= 1 (ao--count-occurrences (buffer-string) "^- DONE shell$")))
      (should (= 1 (ao--count-occurrences (buffer-string) "^- TODO tree$")))
      ;; a merged turn would hold two lines, not three
      (should (= 3 (ao--count-occurrences (buffer-string) "^- "))))
    (kill-buffer buf)))

;;;; Prompt protection helpers

(ert-deftest test-agent-org-buffer-insert-prompt-idempotent ()
  "insert-prompt adds one box; repeats -- streaming included -- are no-ops.
The box is persistent (agent-shell's model): streaming cannot stack a
second one, because the open box IS the type-ahead while the turn runs."
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
      (should (= 1 (ao--count-substrings "* User")))) ; the box streams with us
    (kill-buffer buf)))

(ert-deftest test-agent-org-buffer-take-draft-empties-box-stays-open ()
  "take-draft returns the typed text and leaves the box open and empty.
Sending no longer consumes the prompt heading: the draft is taken out of
a box that stays at the buffer end, ready for the next message."
  (let ((buf (agent-org-buffer-create "freeze")))
    (with-current-buffer buf
      (agent-org-buffer-insert-prompt buf)
      ;; simulate typing with real self-insert-command
      (ao--type "Hello agent")
      (should (equal (agent-org-buffer-take-draft buf) "Hello agent"))
      (should (= 1 (ao--count-substrings "* User"))) ; no new box, no lost one
      (should (agent-org-buffer--open-prompt-p))     ; still typeable
      (should-not (string-match-p "Hello agent" (buffer-string)))
      ;; the heading stays frozen...
      (should (get-text-property (point-min) 'read-only))
      ;; ...and typing fresh text must not inherit the freeze: the
      ;; heading's own newlines stay read-only, rear-nonsticky is what
      ;; keeps a typed draft typeable (open-prompt-p above proves it)
      )
    (kill-buffer buf)))

(ert-deftest test-agent-org-buffer-take-draft-rejects-blank ()
  "A whitespace-only draft is an error, and the text stays put."
  (let ((buf (agent-org-buffer-create "blank")))
    (with-current-buffer buf
      (agent-org-buffer-insert-prompt buf)
      (ao--type "   ")
      (should-error (agent-org-buffer-take-draft buf) :type 'user-error)
      (should (string-suffix-p "   " (buffer-string))))
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
  "With point trapped on frozen text, opening a box takes point to it.
The box-free state this reconstructs is a replay mid-paint: turns render
at `point-max' until the session is ready and the type-ahead box opens."
  (let ((buf (agent-org-buffer-create "escape")))
    (with-current-buffer buf
      (agent-org-buffer-insert-user buf "Hi")
      (agent-org-buffer-append-chunk buf "Hello" (list :buffer buf))
      (agent-org-buffer-end-agent-turn buf)
      (goto-char (point-min))
      (should (get-text-property (point) 'read-only)) ; trapped
      (agent-org-buffer-insert-prompt buf)
      (should (agent-org-buffer--open-prompt-p))
      (should (= (point) (point-max)))) ; rescued into the box
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
                        :session-id "sid-test" :streaming nil :turn nil
                        :loading nil :replay nil :replay-timer nil
                        :replay-session-id nil :replay-response nil
                        :replay-deadline nil :pending-prompts nil
                        :lists-sessions nil :title-seeked nil)))
    (agent-org--register-session session)
    (agent-org-buffer-set-session buf session)
    (cons buf session)))

(defun ao--type (text)
  "Simulate typing TEXT with real `self-insert-command' at point."
  (dolist (ch (append text nil))
    (let ((last-command-event ch))
      (funcall #'self-insert-command 1))))

(ert-deftest test-agent-org-send-echoes-above-a-persistent-box ()
  "Sending freezes the draft into a User heading above the box; the box
survives the send open and empty, so the next prompt is typeable at once
(agent-shell's persistent-prompt UX)."
  (let* ((pair (ao--make-test-session "send"))
         (buf (car pair))
         (session (cdr pair)))
    (cl-letf (((symbol-function 'acp-send-request) (lambda (&rest _args) nil)))
      (with-current-buffer buf
        (agent-org-buffer-insert-prompt buf)
        (ao--type "Hi")
        (agent-org-send)
        (should (= 2 (ao--count-substrings "* User"))) ; echo + box
        (should (string-match-p "\\* User\n\nHi" (buffer-string)))
        (should (agent-org-buffer--open-prompt-p))     ; box still typeable
        (should (eq 'streaming (plist-get agent-org-buffer--status :state)))
        (should (plist-get session :streaming))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-draft-survives-streaming-renders ()
  "Text typed into the box mid-turn is never rendered over.
The invariant the anchor exists for: every streaming insert lands BEFORE
the box, pushing it down instead of scribbling into the draft."
  (let ((buf (agent-org-buffer-create "typed-ahead")))
    (with-current-buffer buf
      (agent-org-buffer-insert-prompt buf)
      ;; a turn streams while the user is mid-sentence in the box
      (ao--type "next prompt")
      (let ((draft-marker (copy-marker (point))))
        (agent-org-buffer-append-chunk buf "thinking aloud " (list :buffer buf))
        (agent-org-buffer-append-thought buf "a thought")
        (agent-org-buffer-insert-tool buf '((title . "shell") (toolCallId . "t1")))
        (agent-org-buffer-end-agent-turn buf)
        ;; the draft is intact, still typeable, and point never moved
        (should (string-match-p "\\* User\n\nnext prompt" (buffer-string)))
        (should (= (marker-position draft-marker) (point)))
        (should (agent-org-buffer--open-prompt-p))
        ;; and the turn rendered strictly above the box, in render order:
        ;; the thought drawer came first, the tool drawer after it
        (should (apply #'ao--ordered (buffer-string)
                       (list "* Agent" "thinking aloud"
                             ":thinking:" ":tool:" "- TODO shell"
                             "next prompt")))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-send-callback-keeps-the-same-box ()
  "Ending the turn (success callback) does not stack a second box: the
type-ahead box was never consumed, so the buffer ends the turn with the
one it started with."
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
        (should (= 2 (ao--count-substrings "* User"))) ; echo + box, no third
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
  "With the queue option off, the streaming guard rejects sends."
  (let* ((pair (ao--make-test-session "busy"))
         (session (cdr pair))
         (agent-org-queue-when-busy nil))
    (setf (plist-get session :streaming) t)
    (should-error (with-current-buffer (car pair) (agent-org-send))
                  :type 'user-error)
    (should-not (plist-get session :pending-prompts))
    (kill-buffer (car pair))))

;;;; Prompt queue (submitting while the agent is still responding)

(defun ao--sent-texts (sent)
  "The prompt texts of captured send requests in SENT, oldest first.
Pairs with the `acp-make-session-prompt-request' stub used by the queue
tests, which hands back the :prompt argument verbatim: a list of the
plain alists `agent-org--make-content-blocks' builds."
  (mapcar (lambda (kw) (map-elt (car (plist-get kw :request)) 'text))
          (reverse sent)))

(ert-deftest test-agent-org-send-queues-while-streaming ()
  "A send while the agent responds takes the buffer draft and waits.
Nothing goes on the wire, the queue keeps FIFO order, and the header
message grows a pending count -- all without touching the minibuffer:
type-ahead, like a TUI agent."
  (let* ((pair (ao--make-test-session "q-enq"))
         (buf (car pair))
         (session (cdr pair))
         (sent nil))
    (setf (plist-get session :streaming) t)
    (with-current-buffer buf
      (agent-org-buffer-insert-prompt buf)
      (agent-org-buffer-set-status buf :state 'streaming :message "Sending…")
      (ao--type "queued one")
      (cl-letf (((symbol-function 'acp-send-request)
                 (lambda (&rest kw) (push kw sent))))
        (agent-org-send))
      (should (equal (list "queued one")
                     (plist-get session :pending-prompts)))
      (should (null sent))
      (should (plist-get session :streaming))
      (should (agent-org-buffer--open-prompt-p)) ; box stays, ready for more
      (should (string-match-p "1 queued"
                              (plist-get agent-org-buffer--status :message))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-queue-drains-in-order-on-success ()
  "Every successful turn end sends the next queued prompt, FIFO.
The drained text is rendered as its own frozen `* User' heading above
the still-open type-ahead box before it goes on the wire; the queue
empties, the box never had to be reopened, and a draft typed while the
drained turn streams is untouched."
  (let* ((pair (ao--make-test-session "q-drain"))
         (buf (car pair))
         (session (cdr pair))
         (sent nil))
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest kw) (push kw sent)))
              ((symbol-function 'acp-make-session-prompt-request)
               (lambda (&rest a) (plist-get a :prompt))))
      (with-current-buffer buf
        (agent-org-buffer-insert-prompt buf)
        (ao--type "one")
        (agent-org-send)                       ; real turn
        (ao--type "two")
        (agent-org-send)                       ; queues "two"
        (ao--type "three")
        (agent-org-send))                      ; queues "three"
      (should (equal '("two" "three") (plist-get session :pending-prompts)))
      (should (= 1 (length sent)))
      ;; turn "one" succeeds: "two" is rendered and sent, queue shrinks
      (funcall (plist-get (nth 0 sent) :on-success) nil)
      (should (equal '("one" "two") (ao--sent-texts sent)))
      (should (equal '("three") (plist-get session :pending-prompts)))
      (should (plist-get session :streaming))
      (with-current-buffer buf
        (should (string-match-p "\\* User\n\ntwo" (buffer-string))))
      ;; turn "two" succeeds: "three" goes out
      (funcall (plist-get (car sent) :on-success) nil)
      (should (equal '("one" "two" "three") (ao--sent-texts sent)))
      (should-not (plist-get session :pending-prompts))
      ;; turn "three" succeeds: nothing left, the one box is still there
      (funcall (plist-get (car sent) :on-success) nil)
      (should (= 3 (length sent)))
      (should-not (plist-get session :streaming))
      (with-current-buffer buf
        (should (agent-org-buffer--open-prompt-p))
        ;; three frozen echoes plus the single persistent box
        (should (= 4 (ao--count-substrings "* User")))
        (should (eq 'ready (plist-get agent-org-buffer--status :state)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-drain-keeps-fresh-draft ()
  "A draft typed while the drained turn runs is never swallowed by it.
The drained prompt renders above the box and the box keeps its own text:
this is where agent-shell sets the draft aside, and here the persistent
box makes that unnecessary -- but it has to stay true."
  (let* ((pair (ao--make-test-session "q-draft"))
         (buf (car pair))
         (session (cdr pair))
         (sent nil))
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest kw) (push kw sent)))
              ((symbol-function 'acp-make-session-prompt-request)
               (lambda (&rest a) (plist-get a :prompt))))
      (with-current-buffer buf
        (agent-org-buffer-insert-prompt buf)
        (ao--type "one")
        (agent-org-send)
        (ao--type "queued")
        (agent-org-send)                    ; queues "queued"
        (ao--type "untouched")              ; fresh draft, nothing sent
        (funcall (plist-get (car sent) :on-success) nil))
      (should (equal '("one" "queued") (ao--sent-texts sent)))
      (with-current-buffer buf
        (should (string-match-p "\\* User\n\nqueued" (buffer-string)))
        (should (string-suffix-p "untouched" (buffer-string)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-queue-survives-failed-turn ()
  "A failed turn does not drain: nothing hammers a dead agent.
The queue keeps its prompts in order so the user can look at the error
before deciding; the box was never consumed, so there is nothing to
reopen."
  (let* ((pair (ao--make-test-session "q-fail"))
         (buf (car pair))
         (session (cdr pair))
         (sent nil))
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest kw) (push kw sent)))
              ((symbol-function 'acp-make-session-prompt-request)
               (lambda (&rest a) (plist-get a :prompt))))
      (with-current-buffer buf
        (agent-org-buffer-insert-prompt buf)
        (ao--type "one")
        (agent-org-send)
        (ao--type "spare")
        (agent-org-send))                   ; queues "spare"
      (funcall (plist-get (car sent) :on-failure) nil "boom")
      (should (equal '("spare") (plist-get session :pending-prompts)))
      (should (= 1 (length sent)))
      (with-current-buffer buf
        (should (eq 'error (plist-get agent-org-buffer--status :state)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-queue-remove-drops-chosen ()
  "`agent-org-queue-remove' drops the entry the user picks by number."
  (let* ((pair (ao--make-test-session "q-rem"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :pending-prompts) (list "a" "b"))
    (with-current-buffer buf
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "2: b")))
        (agent-org-queue-remove))
      (should (equal '("a") (plist-get session :pending-prompts)))
      (should-error (progn
                      (setf (plist-get session :pending-prompts) nil)
                      (agent-org-queue-remove))
                    :type 'user-error))
    (kill-buffer buf)))

(ert-deftest test-agent-org-queue-edit-replaces-last ()
  "`agent-org-queue-edit' re-reads the last queued prompt with its text
as the default, keeping queue order."
  (let* ((pair (ao--make-test-session "q-edit"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :pending-prompts) (list "a" "b"))
    (with-current-buffer buf
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "b fixed")))
        (agent-org-queue-edit))
      (should (equal '("a" "b fixed")
                     (plist-get session :pending-prompts))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-queue-view-lists-pending ()
  "`agent-org-queue-view' shows every queued prompt, oldest first."
  (let* ((pair (ao--make-test-session "q-view"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :pending-prompts) (list "first one" "second"))
    (with-current-buffer buf
      (agent-org-queue-view))
    (let ((shown (get-buffer " *agent-org queue*")))
      (should shown)
      (with-current-buffer shown
        (should (string-match-p "2 prompt" (buffer-string)))
        (should (apply #'ao--ordered (buffer-string)
                       (list "1. first one" "2. second")))))
    (kill-buffer buf)))

;;;; Interrupt (cancel a running turn)

(ert-deftest test-agent-org-cancel-turn-notifies-and-frees-buffer ()
  "Cancel sends `session/cancel' for the live session and ends the turn
locally — the buffer goes Ready with a cancelled note and a fresh prompt,
without waiting for the agent to answer."
  (let* ((pair (ao--make-test-session "cancel"))
         (buf (car pair))
         (session (cdr pair))
         (sent nil)
         (acp-mock-notifications nil))
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest kw) (push kw sent)))
              ((symbol-function 'acp-make-session-prompt-request)
               (lambda (&rest a) (plist-get a :prompt))))
      (with-current-buffer buf
        (agent-org-buffer-insert-prompt buf)
        (ao--type "long task")
        (agent-org-send)
        (agent-org-cancel-turn))
      (let ((note (car acp-mock-notifications)))
        (should (= 1 (length acp-mock-notifications)))
        (should (equal "session/cancel" (map-elt note ':method)))
        (should (equal "sid-test"
                       (map-elt (map-elt note ':params) 'sessionId))))
      (should-not (plist-get session :streaming))
      (with-current-buffer buf
        (should (eq 'ready (plist-get agent-org-buffer--status :state)))
        (should (equal "turn cancelled"
                       (plist-get agent-org-buffer--status :note)))
        (should (agent-org-buffer--open-prompt-p))
        (should (= 2 (ao--count-substrings "* User"))))
      ;; the agent's late (cancelled) answer must not re-close the turn,
      ;; drain twice, or insert another prompt
      (funcall (plist-get (car sent) :on-success) nil)
      (should (= 1 (length sent)))
      (with-current-buffer buf
        (should (= 2 (ao--count-substrings "* User"))))
      (funcall (plist-get (car sent) :on-failure) nil "late failure")
      (with-current-buffer buf
        (should (= 2 (ao--count-substrings "* User")))
        (should (eq 'ready (plist-get agent-org-buffer--status :state)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-cancel-turn-keeps-and-drains-queue ()
  "The queue outlives the cancelled turn and goes out immediately: the
turn that was holding it back is gone."
  (let* ((pair (ao--make-test-session "cancel-q"))
         (buf (car pair))
         (session (cdr pair))
         (sent nil)
         (acp-mock-notifications nil))
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest kw) (push kw sent)))
              ((symbol-function 'acp-make-session-prompt-request)
               (lambda (&rest a) (plist-get a :prompt))))
      (with-current-buffer buf
        (agent-org-buffer-insert-prompt buf)
        (ao--type "running")
        (agent-org-send)
        (ao--type "next")
        (agent-org-send))                  ; queues "next"
      (with-current-buffer buf
        (agent-org-cancel-turn)
        (should (equal '("running" "next") (ao--sent-texts sent)))
        (should-not (plist-get session :pending-prompts))
        (should (plist-get session :streaming)) ; the drained turn is live
        (should (string-match-p "\\* User\n\nnext" (buffer-string)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-cancel-turn-rejects-when-idle ()
  "Nothing streaming, nothing to cancel."
  (let ((buf (car (ao--make-test-session "cancel-idle"))))
    (with-current-buffer buf
      (should-error (agent-org-cancel-turn) :type 'user-error))
    (kill-buffer buf)))

(ert-deftest test-agent-org-cancel-turn-sends-nothing-until-ready ()
  "No session id means no turn can be cancelled on the wire."
  (let* ((pair (ao--make-test-session "cancel-none"))
         (buf (car pair))
         (session (cdr pair))
         (acp-mock-notifications nil))
    (setf (plist-get session :session-id) nil)
    (setf (plist-get session :streaming) t)
    (with-current-buffer buf
      (should-error (agent-org-cancel-turn) :type 'user-error)
      (should-not acp-mock-notifications))
    (kill-buffer buf)))

;;;; Reload (restart the same session, agent-shell's `agent-shell-reload')

(ert-deftest test-agent-org-reload-replays-same-session-through-resume ()
  "Reload kills the chat with its agent and re-loads the same id: the
transcript is re-rendered from the agent's history, not kept from before.
The old buffer must be gone first, or `agent-org--session-open-p' would
redirect the load to it instead of replaying."
  (ao--capture-wire
    (let* ((buf (agent-org-resume-session 'qoder "sid-rel"))
           (session (agent-org--session-for-buffer buf)))
      (ao--drive "initialize" ao--fake-init-resp)
      (ao--drive "session/load" '((sessionId . "sid-rel")))
      (ao--settle)
      (with-current-buffer buf
        (should (equal "sid-rel"
                       (plist-get agent-org-buffer--status :session-id))))
      (let ((new (with-current-buffer buf (agent-org-reload))))
        (should-not (buffer-live-p buf))
        (should (buffer-live-p new))
        (should-not (eq new buf))
        ;; the resume handshake restarts from scratch on a new client
        (should (equal (caar ao--sent) "initialize"))
        (let ((nsession (agent-org--session-for-buffer new)))
          (should nsession)
          (should-not (plist-get nsession :session-id)))
        (ao--drive "initialize" ao--fake-init-resp)
        (let ((load (ao--sent-get "session/load")))
          (should load)
          (should (equal "sid-rel"
                         (map-elt (map-elt (plist-get load :request)
                                           ':params)
                                  'sessionId))))
        (ao--drive "session/load" '((sessionId . "sid-rel")))
        (ao--settle)
        (with-current-buffer new
          (should (equal "sid-rel"
                         (plist-get agent-org-buffer--status :session-id)))
          (should (agent-org-buffer--open-prompt-p)))
        (kill-buffer new)))))

(ert-deftest test-agent-org-reload-refuses-while-loading ()
  "A replay in flight owns the buffer; reload waits."
  (let* ((pair (ao--make-test-session "rel-load"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :loading) t)
    (with-current-buffer buf
      (should-error (agent-org-reload) :type 'user-error)
      (should (buffer-live-p buf)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-reload-rejects-unopened-session ()
  "No :session-id yet — there is nothing to reload into."
  (let* ((pair (ao--make-test-session "rel-none"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :session-id) nil)
    (with-current-buffer buf
      (should-error (agent-org-reload) :type 'user-error)
      (should (buffer-live-p buf)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-reload-asks-before-killing-a-live-turn ()
  "Streaming: `y-or-n-p' decides.  \"no\" leaves the chat untouched;
\"yes\" reloads anyway, and the queue goes with the killed buffer."
  (let* ((pair (ao--make-test-session "rel-busy"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :streaming) t)
    ;; reload hands the session's provider to `agent-org-resume-session',
    ;; which needs a real spec; the fixture's `test' has none
    (setf (plist-get session :name) 'qoder)
    (setf (plist-get session :pending-prompts) (list "queued"))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
      (with-current-buffer buf
        (should-error (agent-org-reload) :type 'user-error)
        (should (buffer-live-p buf))
        (should (equal '("queued") (plist-get session :pending-prompts)))))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
              ((symbol-function 'acp-send-request) (lambda (&rest _) nil))
              ((symbol-function 'acp-make-client) (lambda (&rest _) nil))
              ((symbol-function 'acp-subscribe-to-notifications)
               (lambda (&rest _) nil))
              ((symbol-function 'acp-subscribe-to-requests)
               (lambda (&rest _) nil))
              ((symbol-function 'acp-subscribe-to-errors)
               (lambda (&rest _) nil))
              ((symbol-function 'executable-find) (lambda (&rest _) t)))
      (with-current-buffer buf
        (let ((new (agent-org-reload)))
          (should-not (buffer-live-p buf))
          (should (buffer-live-p new))
          ;; the queue lived on the killed session entry; the new one is clean
          (should-not (plist-get (agent-org--session-for-buffer new)
                                 :pending-prompts))
          (kill-buffer new))))))

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
  "Agent chunks and tool drawer lines carry the read-only property."
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
                (and (re-search-forward "^- TODO read_file$" nil t)
                     (get-text-property (match-beginning 0) 'read-only))))
      ;; the drawer's own marker line too: a `:tool:' the user could edit
      ;; is a drawer that leaks into the next redraw
      (should (save-excursion
                (goto-char (point-min))
                (and (re-search-forward "^:tool:$" nil t)
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
      (should (string-match-p "^:ID: +sid-x" (buffer-string)))
      ;; the id is a drawer property, not a keyword line and not on the
      ;; header bar; inside the drawer it sits between Provider and Mode
      (should-not (string-match-p "^#\\+ID:" (buffer-string)))
      (should (apply #'ao--ordered (buffer-string)
                     (list ":PROPERTIES:" ":Provider:" ":ID:" ":Mode:")))
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

;;;; Title sync from session/list (agents that never push it)

(ert-deftest test-agent-org-title-fetched-from-list-after-first-turn ()
  "Qoder never sends `session_info_update', but it does list titles in
`session/list'.  After the first successful turn -- the turn is what
gives a fresh session a title worth reading -- agent-org asks the
directory once and lands the title in `#+TITLE:'."
  (ao--capture-wire
   (let* ((pair (ao--make-test-session "tsync"))
          (buf (car pair))
          (session (cdr pair)))
     ;; the stock mock hands back nil for a prompt request, which would
     ;; land in the wire capture under method nil; give it the real shape
     (cl-letf (((symbol-function 'acp-make-session-prompt-request)
                (lambda (&rest a)
                  `((:method . "session/prompt")
                    (:params . ((sessionId . ,(plist-get a :session-id))
                                (prompt . ,(plist-get a :prompt))))))))
     (setf (plist-get session :lists-sessions) t)
     (with-current-buffer buf
       (agent-org-buffer-insert-prompt buf)
       (ao--type "Review the request")
       (agent-org-send)
       (ao--drive "session/prompt" nil)
       (should (ao--sent-get "session/list"))
       (ao--drive "session/list"
                  (ao--list-resp (list (list "sid-other" "Other" (ao--today))
                                       (list "sid-test" "Review request"
                                             (ao--today)))))
       (should (equal "Review request"
                      (plist-get agent-org-buffer--status :title)))
       (should (string-match-p "^#\\+TITLE: Review request$"
                               (buffer-string)))))
     (kill-buffer buf))))

(ert-deftest test-agent-org-title-not-sought-without-list-capability ()
  "An agent that does not advertise `list' is never asked for a title:
Goose hangs on `session/list', so the lookup is capability-gated."
  (ao--capture-wire
   (let* ((pair (ao--make-test-session "tnolist"))
          (buf (car pair)))
     (cl-letf (((symbol-function 'acp-make-session-prompt-request)
                (lambda (&rest a)
                  `((:method . "session/prompt")
                    (:params . ((sessionId . ,(plist-get a :session-id))
                                (prompt . ,(plist-get a :prompt))))))))
       (with-current-buffer buf
         (agent-org-buffer-insert-prompt buf)
         (ao--type "hi")
         (agent-org-send)
         (ao--drive "session/prompt" nil)
         (should-not (ao--sent-get "session/list"))))
     (kill-buffer buf))))

(ert-deftest test-agent-org-title-not-sought-when-already-known ()
  "A title that arrived by itself (session/new response or a pushed
`session_info_update') wins: no list request, no clobbering."
  (ao--capture-wire
   (let* ((pair (ao--make-test-session "tknown"))
          (buf (car pair))
          (session (cdr pair)))
     (cl-letf (((symbol-function 'acp-make-session-prompt-request)
                (lambda (&rest a)
                  `((:method . "session/prompt")
                    (:params . ((sessionId . ,(plist-get a :session-id))
                                (prompt . ,(plist-get a :prompt))))))))
       (setf (plist-get session :lists-sessions) t)
       (with-current-buffer buf
         (agent-org-buffer-set-status buf :title "Pushed Title")
         (agent-org-buffer-insert-prompt buf)
         (ao--type "hi")
         (agent-org-send)
         (ao--drive "session/prompt" nil)
         (should-not (ao--sent-get "session/list"))
         (should (equal "Pushed Title"
                        (plist-get agent-org-buffer--status :title)))))
     (kill-buffer buf))))

(ert-deftest test-agent-org-title-looked-up-only-once ()
  "`:title-seeked' makes the sync a one-shot: the second turn does not
page the directory again, even when the first lookup came back empty."
  (ao--capture-wire
   (let* ((pair (ao--make-test-session "tonce"))
          (buf (car pair))
          (session (cdr pair)))
     (cl-letf (((symbol-function 'acp-make-session-prompt-request)
                (lambda (&rest a)
                  `((:method . "session/prompt")
                    (:params . ((sessionId . ,(plist-get a :session-id))
                                (prompt . ,(plist-get a :prompt))))))))
       (setf (plist-get session :lists-sessions) t)
       (with-current-buffer buf
         (agent-org-buffer-insert-prompt buf)
         (ao--type "one")
         (agent-org-send)
         (ao--drive "session/prompt" nil)
         (ao--drive "session/list" (ao--list-resp nil))
         (agent-org-buffer-insert-prompt buf)
         (ao--type "two")
         (agent-org-send)
         (ao--drive "session/prompt" nil)
         (should (= 1 (length (ao--list-pages))))))
     (kill-buffer buf))))

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
survive untouched.  The line also spends `agent-org-buffer--label-width'
on the title and then adds the recency date, so the whole thing is
bounded by label width + date + id rather than by 80.  The gaps below are
` +' not two spaces: columns are padded to the batch's widest row, which
is what `test-agent-org-session-candidates-align-in-columns' pins."
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
      (should (< (length big)
                 (+ agent-org-buffer--label-width 30)))
      (should (string-match-p "\\[big\\]\\'" big))
      (should (string-match-p "Resume all sessions" big))
      (should (string-match-p "…" big)))
    (should (string-match "\\`Short one +Sep 01, [0-9][0-9]:[0-9][0-9] +\\[small\\]\\'"
                          (funcall display "small")))))

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
  "The batched replay paints User/Agent turns, the tool drawer and the
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
                               "^- DONE shell$"
                               "thinking hard" "Next question")))
          (should (string-match-p "^:thinking:$" s))
          (should (string-match-p "^:tool:$" s)))
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

(defvar ao--list-timer nil
  "Armed (FUNCTION . ARGS) of the pending session/list timeout.
Goose advertises the `list' capability and then never answers it, so a
test that means \"the agent stayed silent\" fires this one.")

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

(defun ao--collection (collection)
  "The plain candidate list behind a `completing-read' COLLECTION.
agent-org hands `completing-read' a FUNCTION rather than a list so it can
carry completion metadata (pinned order); a test that wants to look at the
candidates has to ask the collection for them, which is exactly what the
completion UI does.  ACTION `t' is the documented \"give me every
completion\" — `all' is not an action at all (`complete-with-action'
answers it with nil), which is how this test first went silently green."
  (if (functionp collection)
      (funcall collection "" nil t)
    collection))

(defun ao--time-out ()
  "Fire the pending session/list timeout, as a silent agent would allow."
  (when ao--list-timer
    (apply #'funcall ao--list-timer)
    (setq ao--list-timer nil)))

(defun ao--list-pages ()
  "Params of every captured `session/list' request, oldest page first.
Pagination tests read the `cursor' out of the second entry to see that
the continuation the agent offered was actually followed."
  (seq-map (lambda (entry)
             (map-elt (plist-get (cdr entry) :request) ':params))
           (reverse (seq-filter (lambda (pair) (equal (car pair) "session/list"))
                                ao--sent))))

(defmacro ao--capture-wire (&rest body)
  "Run BODY with `acp-send-request' capturing requests to `ao--sent'.
Lets a test pump the resume handshake synchronously, driving each
response callback the way the process filter would.  Timers are
captured too (see `ao--settle'), because nothing here may block on
real time."
  `(let ((ao--sent nil) (ao--timer nil) (ao--list-timer nil) (ao--armings 0))
     (cl-letf (((symbol-function 'acp-send-request)
                ;; `&rest' then plist reads: an interpreted `&key' lambda
                ;; does not parse keywords at all, so the cl-letf'd
                ;; function would be called with the raw plist as
                ;; positional args.
                (lambda (&rest kw)
                  (let ((request (plist-get kw :request)))
                    (push (cons (map-elt request ':method)
                                (list :request request
                                      :on-success (plist-get kw :on-success)
                                      :on-failure (plist-get kw :on-failure)))
                          ao--sent))))
               ((symbol-function 'executable-find) (lambda (&rest _) t))
               ;; (run-at-time SECONDS REPEAT FUNCTION &rest ARGS).  Org
               ;; arms its own timers when a chat buffer is created, so
               ;; only the timers agent-org owns are captured and counted.
               ((symbol-function 'run-at-time)
                (lambda (&rest args)
                  (cond
                   ((eq (nth 2 args) 'agent-org--finish-replay)
                    (cl-incf ao--armings)
                    (setq ao--timer (cons (nth 2 args) (nthcdr 3 args)))))
                  (when (eq (nth 2 args) 'agent-org--list-timeout)
                    (setq ao--list-timer (cons (nth 2 args) (nthcdr 3 args))))
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
heading, one `:tool:' drawer line per distinct toolCallId, thoughts
folded in their own drawer, and an update rewriting its own line instead
of adding a second.  Live qoder replayed 4 tool calls but the buffer
showed 1 heading, so this pins the whole turn down at once."
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
                       ;; t1 finishes: rewrites its line, never a fifth one
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
          (should (equal 4 (ao--count-occurrences text "^- ")))
          ;; the completed call was rewritten in place, the others stayed
          ;; pending
          (should (equal 1 (ao--count-occurrences text "^- DONE read a$")))
          (should (equal 3 (ao--count-occurrences text "^- TODO ")))
          (should (equal 1 (ao--count-occurrences text "^:tool:$")))
          (should (equal 1 (ao--count-occurrences text "^:thinking:$")))
          (should (equal 'ready
                         (with-current-buffer buf
                           (plist-get agent-org-buffer--status :state)))))
        ;; Two drawers, never one inside the other: the thought fold is
        ;; rewritten wholesale by the next chunk, so a tool line that
        ;; landed in its body would vanish (that was the old bug, with
        ;; headings placed at the drawer match's END).  The body between
        ;; `:thinking:' and its `:end:' holds thought text only.
        (let ((thought-body
               (with-current-buffer buf
                 (buffer-substring-no-properties
                  (save-excursion
                    (goto-char (point-min))
                    (re-search-forward "^:thinking:$")
                    (line-end-position))
                  (save-excursion
                    (goto-char (point-min))
                    (re-search-forward "^:thinking:$")
                    (forward-line 1)
                    (re-search-forward "^:end:$")
                    (line-beginning-position))))))
          (should (= 0 (ao--count-occurrences thought-body "^- ")))
          (should (= 4 (ao--count-occurrences thought-body "more\\|plan\\|last"))))
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
provider mean the model it names.  `agent-org-session-strategy' is bound
to `new' because these tests drive `session/new' straight off
`initialize', and the default `prompt' lists the directory's older
sessions before there is any `session/new' to drive."
  (ao--capture-wire
    (ao--with-pinned-provider
      (let* ((agent-org-session-strategy 'new)
             (buf (agent-org-start 'minimax))
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
      (let* ((agent-org-session-strategy 'new)
             (buf (agent-org-start 'minimax))
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
      (let* ((agent-org-session-strategy 'new)
             (buf (agent-org-start 'minimax))
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
      (let* ((agent-org-session-strategy 'new)
             (buf (agent-org-start 'minimax)))
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
    (let* ((agent-org-session-strategy 'new)
           (buf (agent-org-start 'minimax)))
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
    (let* ((agent-org-session-strategy 'new)
           (buf (agent-org-start 'qoder)))
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
        (should (string-match-p "QModel Large"
                                (agent-org-buffer--render-header-line))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-set-session-model-rejects-unadvertised-model ()
  "A lisp caller cannot smuggle an id the agent never offered.
The check that keeps the interactive path honest is the same one that
matters when lisp calls in."
  (ao--capture-wire
    (let* ((agent-org-session-strategy 'new)
           (buf (agent-org-start 'qoder)))
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

;;;; Model NAME in the header line (the id is still what the wire wants)

(ert-deftest test-agent-org-header-shows-model-name-not-id ()
  "The top bar labels the model the way the agent labels it.
An id such as `minimax/MiniMax-M3' is a wire value: it is what
`session/set_config_option' must be sent, and `agent-org--model-values'
checks against it — but a human reading a status bar wants \"MiniMax M3\".
So the display comes from the advertised option's `name' while `:model'
keeps the id, because a header that could not tell the two apart could not
be trusted to show the model actually in force."
  (ao--capture-wire
    (let* ((agent-org-session-strategy 'new)
           (buf (agent-org-start 'qoder)))
      (ao--drive "initialize" ao--fake-init-resp)
      (ao--drive "session/new"
                 (ao--config-resp "qmodel-large"
                  (list (cons "qmodel" "QModel")
                        (cons "qmodel-large" "QModel Large"))))
      (with-current-buffer buf
        (let ((header (agent-org-buffer--render-header-line)))
          (should (string-match-p "QModel Large" header))
          (should-not (string-match-p "qmodel-large" header))
          (should (equal "qmodel-large"
                         (plist-get agent-org-buffer--status :model)))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-header-model-name-falls-back-to-id ()
  "A current model the agent does not name is still shown.
Agents can report a `currentValue' outside their own advertised list (the
catalog moves between releases); showing nothing there would read as
\"no model\", which is a worse lie than the id."
  (ao--capture-wire
    (let* ((agent-org-session-strategy 'new)
           (buf (agent-org-start 'qoder)))
      (ao--drive "initialize" ao--fake-init-resp)
      (ao--drive "session/new"
                 (ao--config-resp "ghost-model" (list (cons "qmodel" "QModel"))))
      (with-current-buffer buf
        (let ((header (agent-org-buffer--render-header-line)))
          (should (string-match-p "ghost-model" header))
          (should (equal "ghost-model"
                         (plist-get agent-org-buffer--status :model)))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-metadata-model-line-uses-name ()
  "The metadata block labels the model like the header does.
Two renderings of one fact that disagree is how a user starts distrusting
both, so `:Model:' is the name and the id stays on the wire."
  (ao--capture-wire
    (let* ((agent-org-session-strategy 'new)
           (buf (agent-org-start 'qoder)))
      (ao--drive "initialize" ao--fake-init-resp)
      (ao--drive "session/new"
                 (ao--config-resp "qmodel-large"
                  (list (cons "qmodel-large" "QModel Large"))))
      (with-current-buffer buf
        (should (string-match-p "^:Model: +QModel Large" (buffer-string)))
        (should-not (string-match-p "^:Model: +qmodel-large" (buffer-string))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-config-drawer-shows-model-label ()
  "The CONFIG drawer labels the current value the way the header does.
The drawer used to print `currentValue' verbatim, so the same buffer
said \"QModel Large\" in the header and \"qmodel-large\" two lines
below — two renderings of one fact that disagree.  The id returns only
as the fallback for a value the agent advertises no label for."
  (let* ((pair (ao--make-test-session "configlabel"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :session-id) nil)
    (agent-org--session-ready
     session "sid-x"
     (ao--config-resp "qmodel-large"
                      (list (cons "qmodel" "QModel")
                            (cons "qmodel-large" "QModel Large"))))
    (with-current-buffer buf
      (should (string-match-p "^Model — QModel Large$" (buffer-string)))
      (should-not (string-match-p "^Model — qmodel-large$" (buffer-string))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-model-name-prettifies-unadvertised-current ()
  "No advertised label does not mean no name: the id is still cleaned.
`agent-org--model-name' used to answer nil for a `currentValue' outside
the catalog, which left the full wire id — \"minimax/MiniMax-M3\" — as
the only thing a status line could show.  Dropping the provider path is
what the id itself can be made to say without inventing a label."
  (should (equal "MiniMax-M3"
                 (agent-org--model-name
                  (list (list `(id . "model") `(name . "Model")
                              `(currentValue . "minimax/MiniMax-M3")
                              (cons 'options
                                    (vector (list `(value . "other")
                                                  `(name . "Other")))))))))
  (should (equal "ghost-model"
                 (agent-org--model-name
                  (list (list `(id . "model") `(currentValue . "ghost-model"))))))
  (should-not (agent-org--model-name (list (list `(id . "model"))))))

(ert-deftest test-agent-org-model-name-follows-a-switch ()
  "After `agent-org-set-session-model' the bar shows the NEW model's name.
The switch response is the agent's own last word on configOptions, so the
label is re-read from it rather than remembered from the choice."
  (ao--capture-wire
    (let* ((agent-org-session-strategy 'new)
           (buf (agent-org-start 'qoder)))
      (ao--drive "initialize" ao--fake-init-resp)
      (ao--drive "session/new"
                 (ao--config-resp "qmodel"
                  (list (cons "qmodel" "QModel")
                        (cons "qmodel-large" "QModel Large"))))
      (with-current-buffer buf (agent-org-set-session-model "qmodel-large"))
      (ao--drive "session/set_config_option"
                 (ao--config-resp "qmodel-large"
                  (list (cons "qmodel" "QModel")
                        (cons "qmodel-large" "QModel Large"))))
      (with-current-buffer buf
        (should (string-match-p "QModel Large"
                                (agent-org-buffer--render-header-line)))
        (should-not (string-match-p "qmodel-large"
                                    (agent-org-buffer--render-header-line))))
      (kill-buffer buf))))

(defun ao--chat-on-model (id name &optional session-id)
  "A Ready chat buffer whose agent advertises model ID, labelled NAME.
Built through the real `agent-org-start' path inside `ao--capture-wire', so
the status a turn heading reads is the status a live session has — the
point of this helper is that no test hand-writes `:model-name'.  NAME nil
is an agent reporting a value it never named, which is the id-fallback case.
ID nil is an agent advertising no model option at all (Goose answers with
no `configOptions' of this shape), which is the no-model case.  SESSION-ID
defaults to the wire's own \"sid-new\"; the transcript tests pass their
own, because the id is what names their file.  Caller kills the buffer."
  (let ((agent-org-session-strategy 'new)
        (agent-org-use-model-headings t))
    (let ((buf (agent-org-start 'qoder)))
      (ao--drive "initialize" ao--fake-init-resp)
      (ao--drive "session/new"
                 (if id
                     (ao--config-resp id (and name (list (cons id name)))
                                      session-id)
                   `((sessionId . ,(or session-id "sid-new"))
                     (configOptions . []))))
      buf)))

(ert-deftest test-agent-org-turn-heading-wears-the-model-name ()
  "An agent turn is headed by the model that answered, not by \"Agent\".
User order: \"Use model name instead of 'Agent' by default.\"  One qoder
answer and one MiniMax answer are the same shape of heading while the bar
two lines up says something different, and a transcript read a week later
has no bar at all.  The heading is written once, at the moment the turn
begins, so it records the model IN FORCE THEN and no later switch can
rewrite it."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel-large" "QModel Large")))
      (with-current-buffer buf
        (agent-org-buffer-start-agent-turn buf (agent-org-buffer--session))
        (goto-char (point-min))
        (should (re-search-forward "^\\* QModel Large$" nil t))
        (should-not (re-search-forward "^\\* Agent$" nil t)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-turn-heading-falls-back-to-agent-without-a-model ()
  "No model reported is not a heading that says nothing.
Goose can answer with no `model' config option in its response at all, and
`* ' alone is a broken headline — so the word stays \"Agent\", which is what
it was before this feature."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model nil nil)))
      (with-current-buffer buf
        (should-not (plist-get agent-org-buffer--status :model))
        (agent-org-buffer-start-agent-turn buf (agent-org-buffer--session))
        (goto-char (point-min))
        (should (re-search-forward "^\\* Agent$" nil t)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-turn-heading-wears-the-id-when-nothing-names-it ()
  "An agent that reports a value but no label gets the value in the heading.
`agent-org--ingest-config' stores the advertised `name' in `:model-name' and
falls back to the wire id when the agent names nothing, so a heading built
from the display shows an id there — the same rule the header line follows (a
bar that drops the model field reads as \"no model\"), and an id is a clue
where the generic word is not.  Agents rename their catalog between
releases, so this is the case that keeps a transcript honest when the label
disappears."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "ghost-model" nil)))
      (with-current-buffer buf
        (should (equal "ghost-model"
                       (plist-get agent-org-buffer--status :model)))
        (agent-org-buffer-start-agent-turn buf (agent-org-buffer--session))
        (goto-char (point-min))
        (should (re-search-forward "^\\* ghost-model$" nil t)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-turn-heading-option-off-keeps-agent ()
  "`agent-org-use-model-headings' nil is the old document.
A model name in a heading is a claim about the agent's catalog in the
middle of the user's notes; someone keeping transcripts across a provider
switch will want the stable word instead, and that preference must be
reachable without patching."
  (ao--capture-wire
    (let ((agent-org-use-model-headings nil)
          (buf (ao--chat-on-model "qmodel-large" "QModel Large")))
      (with-current-buffer buf
        (agent-org-buffer-start-agent-turn buf (agent-org-buffer--session))
        (goto-char (point-min))
        (should (re-search-forward "^\\* Agent$" nil t))
        (should-not (re-search-forward "^\\* QModel Large$" nil t)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-turn-heading-flattens-a-multiline-model-name ()
  "A model label is agent free text, so it cannot break the headline.
`agent-org-buffer--label' is the gate every agent-supplied string passes
before it lands on a one-line context; a config option named \"A\\nB\" must
produce ONE heading line, not a heading and a stray paragraph that Org
would read as body text with a lost structure."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel-large" "QModel\nLarge  with\n\n  spaces")))
      (with-current-buffer buf
        (agent-org-buffer-start-agent-turn buf (agent-org-buffer--session))
        (goto-char (point-min))
        (should (re-search-forward
                 (concat "^\\* "
                         (agent-org-buffer--label "QModel\nLarge  with\n\n  spaces")
                         "$")
                 nil t))
        (should-not (re-search-forward "^[ \t]*Large" nil t)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-two-turn-headings-keep-their-own-models ()
  "A model switch renames the NEXT turn's heading, never the last one.
The heading is baked at turn start, so two answers from two models stand in
the transcript as two different headings — this is what the per-turn map in
the original design was for, and it needs no map: the text of the heading
IS the record.  Asserting the older heading survives unchanged is the
regression this feature could otherwise introduce, because a later render
pass that re-derived the label from the CURRENT status would silently
rewrite history."
  (ao--capture-wire
    (let* ((buf (ao--chat-on-model "qmodel" "QModel"))
           (session (with-current-buffer buf (agent-org-buffer--session))))
      (agent-org-buffer-append-chunk buf "First answer.\n" session)
      (agent-org-buffer-end-agent-turn buf)
      (agent-org-buffer-set-status buf :model "qmodel-large"
                                   :model-name "QModel Large")
      (agent-org-buffer-append-chunk buf "Second answer.\n" session)
      (agent-org-buffer-end-agent-turn buf)
      (with-current-buffer buf
        (goto-char (point-min))
        (should (re-search-forward "^\\* QModel$" nil t))
        (should (re-search-forward "^\\* QModel Large$" nil t))
        (should-not (re-search-forward "^\\* QModel$" nil t)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-replay-paints-the-model-it-was-told ()
  "Restored history is headed by the model known NOW, which is all the wire says.
`session/load' replays chunks with no model attached to any of them, so a
resumed transcript cannot claim per-turn models it never learned — this test
states what the replay really does, through the same primitive a live turn
uses, instead of pretending it remembers.  It is also the guard that naming
the heading did not break the restored-history path, which paints hundreds of
chunks in one synchronous run."
  (let* ((pair (ao--make-test-session "replay-model"))
         (buf (car pair))
         (session (cdr pair)))
    (agent-org-buffer-set-status buf :model "qfmodel" :model-name "Qwen3.8-Flash")
    (setf (plist-get session :loading) t)
    (dolist (update (list
                     '((sessionUpdate . "agent_message_chunk")
                       (content . ((type . "text")
                                   (text . "Answered before the restart"))))
                     '((sessionUpdate . "agent_message_chunk")
                       (content . ((type . "text") (text . " and after."))))))
      (agent-org--on-notification session (ao--update-notif update)))
    (agent-org--render-replay session)
    (with-current-buffer buf
      (let ((s (buffer-string)))
        (should (= 1 (ao--count-occurrences s "^\\* Qwen3\\.8-Flash$")))
        (should (= 0 (ao--count-occurrences s "^\\* Agent$")))))
    (kill-buffer buf)))

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

;;;; Session strategy: starting a chat offers the directory's older sessions

(defun ao--list-resp (sessions &optional next-cursor)
  "A `session/list' response for SESSIONS, plus a NEXT-CURSOR page token.
Each element of SESSIONS is (ID TITLE STAMP); a nil TITLE or STAMP is
left off the wire entirely, because agents really do omit them."
  (let ((body `((sessions . ,(vconcat
                              (seq-map (lambda (s)
                                         (append `((sessionId . ,(nth 0 s)))
                                                 (when (nth 1 s)
                                                   (list (cons 'title (nth 1 s))))
                                                 (when (nth 2 s)
                                                   (list (cons 'updatedAt (nth 2 s))))))
                                       sessions))))))
    (if next-cursor
        (append body (list (cons 'nextCursor next-cursor)))
      body)))

(defun ao--today ()
  "An ISO-8601 stamp for the current local instant, as an agent would send it."
  (format-time-string "%Y-%m-%dT%H:%M:%S%z"))

(defmacro ao--pick (id &rest body)
  "Run BODY answering every prompt by choosing the candidate for session ID.
A `completing-read' stand-in: the candidate labels carry a recency date
the test must not hard-code, so the choice is matched on the bracketed
id, which is the part that actually selects a session."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'completing-read)
              (lambda (_prompt collection &rest _)
                (seq-find (lambda (c)
                            (string-match-p (regexp-quote (format "[%s]" ,id)) c))
                          (ao--collection collection)))))
     ,@body))

(defvar ao--prompted-with nil
  "Collections the `ao--never-prompt' stand-in was handed, newest first.")

(defmacro ao--never-prompt (&rest body)
  "Run BODY failing loudly if anything prompts, recording what it offered."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'completing-read)
              (lambda (_prompt collection &rest _)
                (push collection ao--prompted-with)
                (error "this strategy must not prompt"))))
     ,@body))

(defmacro ao--cancel (&rest body)
  "Run BODY with every prompt answered the way ESC does: a quit signal.
This is how a test says \"the user changed their mind at the session
choice\", which is the case that used to leave a chat buffer stranded."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'completing-read)
              (lambda (&rest _) (signal 'quit nil))))
     ,@body))

(defvar ao--messages nil
  "What `message' was handed inside `ao--capture-messages', newest first.
A formatted string, or nil for the echo area being CLEARED — which is
what closing a progress report leaves behind, and the reason the
recorder cannot just `format' every call: `format' rejects a nil
argument, real Emacs accepts `(message nil)'.")

(defmacro ao--capture-messages (&rest body)
  "Run BODY recording every echo-area `message' call into `ao--messages'.
The header line hides a bare `:message' while Ready, and some notes (the
listing timeout, a cancel) are deliberately echo-area only — so the echo
area is a channel tests have to watch, not just the buffer.  Assert on it
INSIDE BODY: the binding is gone once the macro's last form has run."
  (declare (indent 0))
  `(let ((ao--messages nil))
     (cl-letf (((symbol-function 'message)
                (lambda (format-string &rest args)
                  (push (if format-string
                            (apply #'format format-string args)
                          nil)
                        ao--messages))))
       ,@body)))

(ert-deftest test-agent-org-session-strategy-is-a-named-choice ()
  "The three strategies are the whole vocabulary, and a typo says so.
`agent-shell-session-strategy' is what this copies; the validator exists
because a config value that silently did nothing would be
indistinguishable from the fast path."
  (should (equal agent-org-session-strategy 'prompt))
  (dolist (value '(new latest prompt))
    (should-not (agent-org--validate-session-strategy value))
    (setopt agent-org-session-strategy value)
    (should (eq (default-value 'agent-org-session-strategy) value)))
  (should-error (setopt agent-org-session-strategy 'bogus) :type 'user-error)
  (setopt agent-org-session-strategy 'prompt))

(ert-deftest test-agent-org-start-strategy-new-never-lists ()
  "`new' is the fast path: no session/list round trip, no silence timer.
On a 4 GB machine every extra request to a slow agent is seconds of
\"Starting\" for nothing, so a strategy that cannot use the listing must
not ask for it."
  (let ((agent-org-session-strategy 'new))
    (ao--capture-wire
      (let ((buf (agent-org-start 'qoder)))
        (ao--drive "initialize" ao--fake-init-resp)
        (should (ao--sent-get "session/new"))
        (should-not (ao--sent-get "session/list"))
        (should-not ao--list-timer)
        (kill-buffer buf)))))

(ert-deftest test-agent-org-start-prefix-arg-forces-a-new-session ()
  "C-u on the interactive command overrides `agent-org-session-strategy'.
The listing is worth a round trip only when you mean to choose from it;
one keypress has to be enough to say \"not this time\"."
  (ao--capture-wire
    (let ((current-prefix-arg '(4))
          (agent-org-session-strategy 'prompt))
      (cl-letf (((symbol-function 'agent-org--read-provider)
                 (lambda () 'qoder)))
        (call-interactively 'agent-org-start))
      (ao--drive "initialize" ao--fake-init-resp)
      (should (ao--sent-get "session/new"))
      (should-not (ao--sent-get "session/list"))
      (kill-buffer (current-buffer)))))

(ert-deftest test-agent-org-start-prompts-with-the-directory-sessions ()
  "Starting a chat means asking the agent what this directory already
holds, offering that list, and loading what was chosen instead of
opening a blank session.  This is agent-shell's `prompt' strategy, and
the default here."
  (ao--capture-wire
    (let ((buf (agent-org-start 'qoder)))
      (ao--drive "initialize" ao--fake-init-resp)
      (should (equal (caar ao--sent) "session/list"))
      (should-not (ao--sent-get "session/new"))
      (ao--pick "s-old"
        (ao--drive "session/list"
                   (ao--list-resp
                    `(("s-new" "Newest chat" ,(ao--today))
                      ("s-old" "Older chat" "2026-09-02T10:00:00+0000")))))
      (let ((params (map-elt (plist-get (ao--sent-get "session/load") ':request)
                             ':params)))
        (should (equal (map-elt params 'sessionId) "s-old")))
      (should-not (ao--sent-get "session/new"))
      (ao--drive "session/load" '((sessionId . "s-old")))
      (ao--settle)
      (with-current-buffer buf
        (should (equal (plist-get agent-org-buffer--status :session-id) "s-old"))
        (should (equal 'ready (plist-get agent-org-buffer--status :state))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-start-prompt-offers-new-session-too ()
  "The list the agent returns is not a trap: \"New session\" is a choice,
and the first one, so a plain Enter keeps the old behaviour.  A prompt
that could only resume would make `agent-org-start' the wrong command to
reach for."
  (let ((ao--prompted-with nil))
    (ao--capture-wire
      (let ((buf (agent-org-start 'qoder)))
        (ao--drive "initialize" ao--fake-init-resp)
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt collection &rest _)
                     (push collection ao--prompted-with)
                     (car (ao--collection collection)))))
          (ao--drive
           "session/list"
           (ao--list-resp `(("s1" "One chat" ,(ao--today))
                            ("s2" "Two chat" "2026-09-02T10:00:00+0000")))))
        (let ((choices (ao--collection (seq-first ao--prompted-with))))
          (should (= 3 (length choices)))
          (should (equal (car choices) agent-org-new-session-label)))
        (should (ao--sent-get "session/new"))
        (should-not (ao--sent-get "session/load"))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-start-strategy-latest-loads-newest-unasked ()
  "`latest' picks the newest session with no prompt at all, and wire
order is not recency order: agents may answer in any order, so this
sorts on `updatedAt' and falls back to `createdAt', which live goose
sends on sessions it never touched."
  (ao--capture-wire
    (let* ((agent-org-session-strategy 'latest)
           (buf (agent-org-start 'qoder)))
      (ao--never-prompt
        (ao--drive "initialize" ao--fake-init-resp)
        (ao--drive
         "session/list"
         `((sessions . [((sessionId . "s-mid") (title . "Mid")
                         (updatedAt . "2026-09-10T10:00:00+0000"))
                        ((sessionId . "s-old") (title . "Old")
                         (updatedAt . "2026-09-02T10:00:00+0000"))
                        ((sessionId . "s-born") (title . "Born, never touched")
                         (createdAt . "2026-09-20T09:00:00+0000"))])))
      (let ((params (map-elt (plist-get (ao--sent-get "session/load") ':request)
                             ':params)))
        (should (equal (map-elt params 'sessionId) "s-born")))
      (kill-buffer buf)))))

(ert-deftest test-agent-org-start-reads-the-strategy-at-command-time ()
  "The strategy is decided when the command runs, not when the agent answers.
A callback that re-reads the variable follows whatever is bound by the
time the handshake lands: a lisp caller's `let' around
`agent-org-start' is silently ignored, and so is any future
buffer-local.  This is not hypothetical — a live probe that bound `new'
around `agent-org-start' still went and asked a real qoder for its
directory listing, because the binding was gone by the time
`initialize' answered."
  (ao--capture-wire
    (let ((buf (let ((agent-org-session-strategy 'new))
                  (agent-org-start 'qoder))))
      ;; `buf' was returned from inside the binding, which has now exited
      (ao--drive "initialize" ao--fake-init-resp)
      (should (ao--sent-get "session/new"))
      (should-not (ao--sent-get "session/list"))
      (kill-buffer buf))))

(ert-deftest test-agent-org-start-carries-latest-into-the-chooser ()
  "The strategy the command read still decides after the round trip.
The chooser runs on the `session/list' response, which is two callbacks
downstream of the command, so the decision has to travel with the
session rather than be looked up again."
  (ao--capture-wire
    (let ((buf (let ((agent-org-session-strategy 'latest))
                  (agent-org-start 'qoder))))
      (ao--never-prompt
        (ao--drive "initialize" ao--fake-init-resp)
        (ao--drive "session/list"
                   (ao--list-resp `(("s-new" "Newest" ,(ao--today))
                                    ("s-old" "Older"
                                     "2026-09-02T10:00:00+0000")))))
      (let ((params (map-elt (plist-get (ao--sent-get "session/load") ':request)
                             ':params)))
        (should (equal (map-elt params 'sessionId) "s-new")))
      (kill-buffer buf))))

(ert-deftest test-agent-org-start-without-list-capability-just-starts ()
  "An agent that cannot list, or cannot load, gets no listing request.
`prompt' and `latest' both need session/list plus session/load; on an
agent advertising neither, the strategy degrades to `new' instead of
failing a session the user never asked to resume."
  (let ((agent-org-session-strategy 'prompt))
    (ao--capture-wire
      (let ((buf (agent-org-start 'opencode)))
        (ao--drive "initialize" '((agentCapabilities . ((loadSession . nil)))))
        (should (ao--sent-get "session/new"))
        (should-not (ao--sent-get "session/list"))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-session-list-follows-cursors ()
  "Older sessions live past the first page, so `nextCursor' is followed
until the agent stops offering one.  \"Lists the older sessions\" is not
true of a package that reads one page and calls it the list."
  (ao--capture-wire
    (let* ((agent-org-session-strategy 'latest)
           (buf (agent-org-start 'qoder)))
      (ao--never-prompt
        (ao--drive "initialize" ao--fake-init-resp)
        (ao--drive "session/list"
                   (ao--list-resp `(("s-p1" "Page one" "2026-09-01T10:00:00+0000"))
                                  "cursor-2"))
        (should (= 2 (ao--sent-count "session/list")))
        (should (equal (map-elt (nth 1 (ao--list-pages)) 'cursor) "cursor-2"))
        (should-not (map-elt (nth 0 (ao--list-pages)) 'cursor))
        (ao--drive "session/list"
                   (ao--list-resp `(("s-p2" "Page two, the older one" ,(ao--today))))))
      (let ((params (map-elt (plist-get (ao--sent-get "session/load") ':request)
                             ':params)))
        (should (equal (map-elt params 'sessionId) "s-p2")))
      (kill-buffer buf))))

(ert-deftest test-agent-org-session-list-page-limit-stops-paging ()
  "`agent-org-session-list-page-limit' bounds the requests and says
nothing when it truncates: on a slow agent the limit exists precisely to
stop waiting."
  (ao--capture-wire
    (let* ((agent-org-session-list-page-limit 1)
           (agent-org-session-strategy 'latest)
           (buf (agent-org-start 'qoder)))
      (ao--never-prompt
        (ao--drive "initialize" ao--fake-init-resp)
        (ao--drive "session/list"
                   (ao--list-resp
                    `(("s-p1" "Page one" ,(ao--today))
                      ("s-x" "Also page one" "2026-01-01T10:00:00+0000"))
                    "cursor-2"))
        (should (= 1 (ao--sent-count "session/list"))))
      (let ((params (map-elt (plist-get (ao--sent-get "session/load") ':request)
                             ':params)))
        (should (equal (map-elt params 'sessionId) "s-p1")))
      (kill-buffer buf))))

(ert-deftest test-agent-org-session-list-repeated-cursor-falls-back ()
  "An agent handing back the cursor it was just sent would page forever.
Two requests is enough: give up on the listing and start a new session,
because a broken session/list must not block a chat nobody wanted to
resume."
  (ao--capture-wire
    (let* ((agent-org-session-strategy 'prompt)
           (buf (agent-org-start 'qoder)))
      (ao--drive "initialize" ao--fake-init-resp)
      (ao--drive "session/list" (ao--list-resp `(("s1" "One" ,(ao--today))) "same"))
      (ao--never-prompt
        (ao--drive "session/list" (ao--list-resp `(("s2" "Two" ,(ao--today))) "same"))
        (should (= 2 (ao--sent-count "session/list")))
        (should (= 1 (ao--sent-count "session/new")))
        (should-not (ao--sent-get "session/load")))
      (kill-buffer buf))))

(ert-deftest test-agent-org-silent-agent-list-falls-back-to-new ()
  "Goose advertises `list' and never answers it — documented live.  With
`prompt' as the default, silence must cost one timeout, not the session:
after `agent-org-session-list-timeout' the start proceeds as a plain new
session, and an answer arriving afterwards is ignored."
  (ao--capture-wire
    (let ((buf (agent-org-start 'goose)))
      (ao--drive "initialize" ao--fake-init-resp)
      (should (ao--sent-get "session/list"))
      (should ao--list-timer)
      (ao--time-out)
      (should (= 1 (ao--sent-count "session/new")))
      (should-not (ao--sent-get "session/load"))
      ;; the agent finally speaks; what it offers is moot — the new
      ;; session is already opening
      (ao--never-prompt
        (ao--drive "session/list" (ao--list-resp `(("late" "Too late" ,(ao--today))))))
      (ao--drive "session/new" (ao--config-resp "model-x" '(("model-x" . "X"))))
      (should (= 1 (ao--sent-count "session/new")))
      (should-not (ao--sent-get "session/load"))
      (with-current-buffer buf
        (should (equal 'ready (plist-get agent-org-buffer--status :state))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-killing-the-chat-buffer-shuts-the-agent-down ()
  "Killing a chat buffer releases its agent PROCESS, not just its registry
entry.  Found live: `agent-org--sessions' held one session while nine
`qoder --acp' children were still running (~100 MB each, on a 4 GB box),
because `agent-org--forget-session' dropped the entry and left the `acp'
client — and therefore the process it spawned — alive."
  (ao--capture-wire
    (let ((acp-mock-shutdown-clients nil))
      (let* ((buf (agent-org-start 'qoder))
             (client (plist-get (agent-org--session-for-buffer buf) :client)))
        (should client)
        ;; `prompt' is the shipped default, so a plain start lists the
        ;; directory first — settle that before the buffer reaches Ready.
        (ao--never-prompt
          (ao--drive "initialize" ao--fake-init-resp))
        (ao--drive "session/list" (ao--list-resp nil))
        (ao--drive "session/new" '((sessionId . "s-keep")))
        (should (= 1 (length agent-org--sessions)))
        (kill-buffer buf)
        (should-not (agent-org--session-for-buffer buf))
        (should-not (memq buf (buffer-list)))
        (should (equal (list client) acp-mock-shutdown-clients))))))

;;;; Killing a chat buffer asks first, because an agent is running

(defun ao--chat-buffer-with-agent ()
  "A chat buffer whose session holds a live agent process.
Returns (BUFFER . PROCESS).  The process is a real `sleep': what is under
test is \"is there a live process to ask about\", and a stub object would
let the test pass on something that cannot be live."
  (let* ((pair (ao--make-test-session "killer"))
         (buf (car pair))
         (session (cdr pair))
         (proc (start-process "ao-test-agent" nil
                             (executable-find "sleep") "120")))
    (setf (plist-get session :client)
          (list (cons :mock-client 99) (cons :process proc)))
    (cons buf proc)))

(defmacro ao--answers-kill (&rest body)
  "Run BODY answering every kill prompt NO, recording the prompts.
Returns (ANSWER-LIST . PROMPT-TEXTS) — the prompts recorded, so a test
can assert the wording as well as the refusal."
  (declare (indent 0))
  `(let ((ao--prompts nil))
     (cl-letf (((symbol-function 'yes-or-no-p)
                (lambda (prompt &rest _)
                  (push prompt ao--prompts)
                  nil)))
       ,@body)
     (nreverse ao--prompts)))

(defmacro ao--agrees-to-kill (&rest body)
  "Run BODY answering every kill prompt YES, recording the prompts."
  (declare (indent 0))
  `(let ((ao--prompts nil))
     (cl-letf (((symbol-function 'yes-or-no-p)
                (lambda (prompt &rest _)
                  (push prompt ao--prompts)
                  t)))
       ,@body)
     (nreverse ao--prompts)))

(ert-deftest test-agent-org-kill-of-chat-buffer-with-agent-asks ()
  "Killing a chat buffer whose agent runs asks, like Emacs asks about
process buffers.  `acp' starts the agent with `:noquery t' and no
`:buffer', so Emacs' own `process-kill-buffer-query-function' can never
see it: without a query of ours, `M-x kill-buffer' silently dropped a
running agent — and the answer NO has to leave the buffer, its session
and its process all still there."
  (let* ((pair (ao--chat-buffer-with-agent))
         (buf (car pair))
         (proc (cdr pair)))
    (unwind-protect
        (let ((prompts (ao--answers-kill (kill-buffer buf))))
          (should (= 1 (length prompts)))
          (should (buffer-live-p buf))
          (should (agent-org--session-for-buffer buf))
          (should (process-live-p proc)))
      (delete-process proc)
      (kill-buffer buf))))

(ert-deftest test-agent-org-kill-query-wording-names-the-process ()
  "The prompt says WHICH process, in Emacs' own words.
`Process <name> is running; kill it? ' is what `kill-buffer' asks about
a shell or compile buffer; borrowing the sentence is what makes the
question feel like it belongs to Emacs rather than to a package."
  (let* ((pair (ao--chat-buffer-with-agent))
         (buf (car pair))
         (proc (cdr pair)))
    (unwind-protect
        (let ((prompts (ao--answers-kill (kill-buffer buf))))
          (should (= 1 (length prompts)))
          (should (string-match-p "\\`Process .* is running; kill it\\? \\'"
                                  (car prompts)))
          (should (string-match-p "ao-test-agent" (car prompts))))
      (delete-process proc)
      (kill-buffer buf))))

(ert-deftest test-agent-org-kill-query-yes-kills-and-releases-the-agent ()
  "YES kills the buffer AND shuts the agent down: the query is a question,
not a second release path — `agent-org--forget-session' on
`kill-buffer-hook' is still what deletes the process."
  (let* ((acp-mock-shutdown-clients nil)
         (pair (ao--chat-buffer-with-agent))
         (buf (car pair))
         (proc (cdr pair))
         (client (plist-get (agent-org--session-for-buffer buf) :client)))
    (let ((prompts (ao--agrees-to-kill (kill-buffer buf))))
      (should (= 1 (length prompts)))
      (should-not (buffer-live-p buf))
      (should-not (agent-org--session-for-buffer buf))
      (should (equal (list client) acp-mock-shutdown-clients)))))

(ert-deftest test-agent-org-kill-query-stays-silent-without-a-live-agent ()
  "No live process, no question.  A Ready buffer whose agent died
mid-conversation must still be killable in one keystroke, and every
buffer with `:client' nil — which is what the offline suite builds —
would otherwise hang batch tests on a prompt they cannot answer."
  (let* ((buf (agent-org-buffer-create "quiet"))
         (session (list :name 'test :client nil :buffer buf
                        :session-id "sid-q" :streaming nil
                        :loading nil :replay nil :replay-timer nil
                        :replay-session-id nil :replay-response nil
                        :replay-deadline nil)))
    (agent-org--register-session session)
    (agent-org-buffer-set-session buf session)
    (let ((prompts (ao--answers-kill (kill-buffer buf))))
      (should (zerop (length prompts)))
      (should-not (buffer-live-p buf)))))

(ert-deftest test-agent-org-kill-query-ignores-a-dead-process ()
  "A process object that has already exited is not a reason to ask.
`process-live-p' is the predicate, not `processp': the child of an agent
that crashed still sits on the client plist until the buffer is killed."
  (let* ((pair (ao--chat-buffer-with-agent))
         (buf (car pair))
         (proc (cdr pair)))
    (delete-process proc)
    (let ((prompts (ao--answers-kill (kill-buffer buf))))
      (should (zerop (length prompts)))
      (should-not (buffer-live-p buf)))))

(ert-deftest test-agent-org-own-cancels-kill-without-asking ()
  "The kill agent-org performs on ITS OWN behalf is never a question.
`agent-org--cancel-open' releases a half-open buffer when the user quits
the chooser, and `agent-org--show-open-instead' kills the buffer this
command just opened when the chosen session turns out to be live in
another window.  Both already have a running agent process attached, so
an un-bypassed query would ask the user about a buffer they never
asked to kill — in the middle of a response callback."
  (let* ((pair (ao--chat-buffer-with-agent))
         (buf (car pair))
         (proc (cdr pair))
         (session (agent-org--session-for-buffer buf)))
    (unwind-protect
        (progn
          (let ((prompts (ao--answers-kill (agent-org--cancel-open session))))
            (should (zerop (length prompts))))
          (should-not (buffer-live-p buf))
          ;; the cancel killed the buffer, so the second path gets a fresh one
          (let* ((other (ao--chat-buffer-with-agent))
                 (other-buf (car other))
                 (other-proc (cdr other))
                 (ours (ao--chat-buffer-with-agent))
                 (ours-buf (car ours)))
            (unwind-protect
                (let ((prompts (ao--answers-kill
                                 (agent-org--show-open-instead
                                  (agent-org--session-for-buffer ours-buf)
                                  other-buf))))
                  (should (zerop (length prompts)))
                  (should-not (buffer-live-p ours-buf))
                  (should (buffer-live-p other-buf)))
              (when (process-live-p other-proc)
                (delete-process other-proc))
              (when (buffer-live-p other-buf)
                (kill-buffer other-buf))
              (when (buffer-live-p ours-buf)
                (delete-process (cdr ours))
                (kill-buffer ours-buf)))))
      (when (process-live-p proc)
        (delete-process proc))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest test-agent-org-kill-query-is-buffer-local ()
  "The question belongs to chat buffers only.  `kill-buffer-query-functions'
is a global hook, so a chat buffer must not make an ordinary buffer ask
about a process it has never seen."
  (let ((buf (generate-new-buffer " *ao-plain-kill*")))
    (let ((prompts (ao--answers-kill (kill-buffer buf))))
      (should (zerop (length prompts))))
    (should-not (buffer-live-p buf))))

(ert-deftest test-agent-org-kill-query-is-registered-not-global ()
  "The query is installed per buffer by the registry, never on the global
hook — a package that adds itself to `kill-buffer-query-functions'
globally has to keep its answer correct for every buffer in Emacs."
  (should-not (memq 'agent-org--kill-query kill-buffer-query-functions))
  (let ((buf (agent-org-buffer-create "hooked")))
    (agent-org--register-session
     (list :name 'test :client nil :buffer buf :session-id nil
           :streaming nil :loading nil :replay nil :replay-timer nil
           :replay-session-id nil :replay-response nil :replay-deadline nil))
    (should (memq 'agent-org--kill-query
                  (buffer-local-value 'kill-buffer-query-functions buf)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-killing-during-a-listing-cancels-the-timeout ()
  "A buffer killed while a `session/list' is in flight must not go on to
open a session: `agent-org--forget-session' unarms the timeout, and
`agent-org--list-timeout' refuses to act on a dead buffer.  The behaviour
is what gets asserted, because `cancel-timer' is stubbed out inside
`ao--capture-wire' — firing the stored timer is how the test says \"the
deadline arrived\", and a session opened into a killed buffer is the bug."
  (ao--capture-wire
    (let ((acp-mock-shutdown-clients nil))
      (let ((buf (agent-org-start 'goose)))
        (ao--drive "initialize" ao--fake-init-resp)
        (should (ao--sent-get "session/list"))
        (should ao--list-timer)
        (kill-buffer buf)
        (ao--time-out)
        (should-not (ao--sent-get "session/new"))
        (should (= 1 (length acp-mock-shutdown-clients)))))))

(ert-deftest test-agent-org-cancelling-the-start-prompt-kills-the-chat-buffer ()
  "ESC at the session choice must clean up after itself.  `completing-read'
signals `quit', which escapes into the acp response callback — and acp
wraps every callback in `condition-case-unless-debug', so the quit is
SWALLOWED: the buffer stayed open on \"Starting\" with its agent process
running and no way to prompt.  Cancelling now kills the buffer, which is
what releases the agent (`agent-org--forget-session' -> `acp-shutdown'),
and says so in the echo area."
  (ao--capture-wire
    (let ((acp-mock-shutdown-clients nil)
          (buf (agent-org-start 'qoder)))
      (ao--drive "initialize" ao--fake-init-resp)
      (should (ao--sent-get "session/list"))
      (ao--capture-messages
        (ao--cancel
          (ao--drive "session/list"
                     (ao--list-resp `(("s1" "One chat" ,(ao--today))
                                      ("s2" "Two chat"
                                       "2026-09-02T10:00:00+0000")))))
        (should (seq-some (lambda (m) (string-match-p "cancel" m)) ao--messages)))
      (should-not (buffer-live-p buf))
      (should-not (agent-org--session-for-buffer buf))
      ;; nothing was opened in the buffer that is no longer there
      (should-not (ao--sent-get "session/new"))
      (should-not (ao--sent-get "session/load"))
      (should (= 1 (length acp-mock-shutdown-clients))))))

(ert-deftest test-agent-org-cancelling-the-resume-prompt-kills-the-chat-buffer ()
  "The same cleanup on `agent-org-resume-session', which prompts through
`agent-org--read-session-id' rather than `agent-org--read-start-choice'.
Two candidates, because one is auto-selected without asking and would
never reach the bug."
  (ao--capture-wire
    (let ((acp-mock-shutdown-clients nil)
          (buf (agent-org-resume-session 'qoder nil)))
      (ao--drive "initialize" ao--fake-init-resp)
      (should (ao--sent-get "session/list"))
      (ao--capture-messages
        (ao--cancel
          (ao--drive "session/list"
                     (ao--list-resp `(("s1" "One chat" ,(ao--today))
                                      ("s2" "Two chat"
                                       "2026-09-02T10:00:00+0000")))))
        (should (seq-some (lambda (m) (string-match-p "cancel" m)) ao--messages)))
      (should-not (buffer-live-p buf))
      (should-not (agent-org--session-for-buffer buf))
      (should-not (ao--sent-get "session/load"))
      (should (= 1 (length acp-mock-shutdown-clients))))))

(ert-deftest test-agent-org-start-silent-listing-says-why-on-the-header ()
  "A listing that never answers must not degrade in silence.  The echo
area note exists but is easy to miss — and after `session/new' the header
says plain Ready, so the first the user hears of the fallback is that the
prompt they configured never came.  The reason now sits on the Ready
segment."
  (ao--capture-wire
    (let ((buf (agent-org-start 'goose)))
      (ao--drive "initialize" ao--fake-init-resp)
      (should ao--list-timer)
      (ao--time-out)
      (ao--drive "session/new" '((sessionId . "s-t")))
      (with-current-buffer buf
        (should (equal 'ready (plist-get agent-org-buffer--status :state)))
        (should (string-match-p "timed out"
                                (plist-get agent-org-buffer--status :note)))
        (should (string-match-p "timed out"
                                (car (agent-org-buffer--status-segment
                                      agent-org-buffer--status)))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-start-failed-listing-says-why-on-the-header ()
  "Same channel for an agent that answers `session/list' with an error:
the failure text is the diagnostic, so it goes on the header too, short
and on one line however much the agent wrote."
  (ao--capture-wire
    (let ((buf (agent-org-start 'qoder)))
      (ao--drive "initialize" ao--fake-init-resp)
      (let ((entry (ao--sent-get "session/list")))
        (should entry)
        (funcall (plist-get entry :on-failure)
                 nil '((:object (error (code . -32603)
                                        (message . "boom"))) (:json . "{}"))))
      (ao--drive "session/new" '((sessionId . "s-f")))
      (with-current-buffer buf
        (should (equal 'ready (plist-get agent-org-buffer--status :state)))
        (let ((note (plist-get agent-org-buffer--status :note)))
          (should (string-match-p "boom" note))
          (should-not (string-match-p "\n" note))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-session-candidates-align-in-columns ()
  "Two chats whose titles differ wildly in length must still put their
dates in the same column, or the list reads as a ragged paragraph and the
one thing you scan for — recency — never lines up.  The id stays at the
end, because it is what actually selects."
  (let* ((stamp "2026-09-28T10:22:00+0000")
         (resp (list (cons 'sessions
                           (vector (list (cons 'sessionId "s-a")
                                         (cons 'title "Short")
                                         (cons 'updatedAt stamp))
                                   (list (cons 'sessionId "s-b")
                                         (cons 'title
                                           "A far longer opening prompt than the other one")
                                         (cons 'updatedAt stamp))))))
         (labels (seq-map #'car (agent-org--session-candidates resp))))
    (should (= 2 (length labels)))
    ;; titles carry no digits here, so the first digit is the date column
    (let ((cols (seq-map (lambda (l) (string-match-p "[0-9]" l)) labels)))
      (should (= 2 (length cols)))
      (should (apply #'equal cols)))
    (dolist (label labels)
      (should (string-match-p "\\[s-[ab]\\]\\'" label)))))

(ert-deftest test-agent-org-candidate-columns-align-by-display-width ()
  "A CJK title takes two display columns per character, so padding by
character COUNT leaves its date hanging a dozen columns early — and
`string-pad' pads by character count, which is how this was first got
wrong.  What has to be equal across rows is the width of everything
before the id, because that is what a completion UI lines up."
  (let* ((resp (list (cons 'sessions
                           (vector (list (cons 'sessionId "cjk")
                                         (cons 'title "日本語のタイトルです")
                                         (cons 'updatedAt "2026-09-28T10:22:00+0000"))
                                   (list (cons 'sessionId "lat")
                                         (cons 'title "Reconcile the failing ERT suite")
                                         (cons 'updatedAt "2026-09-27T10:22:00+0000"))))))
         (labels (seq-map #'car (agent-org--session-candidates resp))))
    (should (= 2 (length labels)))
    (should (apply #'equal
                   (seq-map (lambda (l)
                              (string-width (substring l 0 (string-match-p "\\[" l))))
                            labels)))))

(ert-deftest test-agent-org-prompt-collection-pins-our-order ()
  "The candidate order IS information (newest first, `New session' on
top), and a completion UI is free to re-sort a plain list collection.
Handing over a function with `display-sort-function' set to `identity' is
how agent-shell keeps its own ordering; without it a two-year-old chat can
land on top of the list you are about to choose from."
  (let ((ao--prompted-with nil))
    (ao--capture-wire
      (let ((buf (agent-org-start 'qoder)))
        (ao--drive "initialize" ao--fake-init-resp)
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt collection &rest _)
                     (push collection ao--prompted-with)
                     (car (ao--collection collection)))))
          (ao--drive
           "session/list"
           (ao--list-resp `(("s1" "One chat" ,(ao--today))
                            ("s2" "Two chat" "2026-09-02T10:00:00+0000")))))
        (let ((collection (seq-first ao--prompted-with)))
          (should (functionp collection))
          (let ((metadata (funcall collection "" nil 'metadata)))
            (should (eq (cdr (assq 'display-sort-function (cdr metadata)))
                        #'identity)))
          ;; asking it for everything returns OUR order, `New session' first
          (let ((choices (ao--collection collection)))
            (should (= 3 (length choices)))
            (should (equal (car choices) agent-org-new-session-label))
            (should (string-match-p "\\[s1\\]\\'" (nth 1 choices)))
            (should (string-match-p "\\[s2\\]\\'" (nth 2 choices)))))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-candidates-mark-an-already-open-session ()
  "A `session/list' of this directory includes chats this Emacs already
has open.  Nothing on the candidate says so, so choosing one loads the
same ACP session a second time: two clients, two buffers, one history.
The open rows say `(open)', and the marker is part of the title column
it is measured with, so adding it cannot push the dates out of line."
  (let* ((open-buffer (generate-new-buffer " *ao-open-test*"))
         (agent-org--sessions (list (list :buffer open-buffer
                                          :session-id "s-live")))
         (resp (list (cons 'sessions
                           (vector (list (cons 'sessionId "s-live")
                                         (cons 'title "Already open chat")
                                         (cons 'updatedAt "2026-09-28T10:22:00+0000"))
                                   (list (cons 'sessionId "s-shut")
                                         (cons 'title "Closed chat")
                                         (cons 'updatedAt "2026-09-27T10:22:00+0000"))))))
         (cands (agent-org--session-candidates resp))
         (labels (seq-map #'car cands)))
    (should (string-match-p "(open)" (nth 0 labels)))
    (should-not (string-match-p "(open)" (nth 1 labels)))
    (should (apply #'equal
                   (seq-map (lambda (l) (string-width (substring l 0 (string-match-p "\\[" l))))
                            labels)))
    ;; the marker is display only: what selects is still the id
    (should (equal (cdr (nth 0 cands)) "s-live"))
    (kill-buffer open-buffer)))

(ert-deftest test-agent-org-dead-buffer-does-not-mark-a-session-open ()
  "The registry is dropped by a kill-hook, but a hook that has not run
yet leaves a session pointing at a dead buffer.  Offering to switch to
that buffer would be worse than the double load: the choice would do
nothing."
  (let* ((gone (generate-new-buffer " *ao-gone-test*"))
         (agent-org--sessions (list (list :buffer gone :session-id "s-dead"))))
    (kill-buffer gone)
    (should-not (agent-org--session-open-p "s-dead"))))

(ert-deftest test-agent-org-choosing-an-open-session-shows-its-buffer ()
  "Choosing an open chat must raise the buffer that has it and send
nothing: no `session/load' (a second client on the same session id), and
no `session/new' either.  The half-open buffer this command created is
killed, which is what releases the agent process spawned for it
(`agent-org--forget-session')."
  (let* ((open (generate-new-buffer " *ao-open-choice*"))
         (agent-org--sessions (list (list :buffer open :session-id "s-live")))
         (acp-mock-shutdown-clients nil))
    (ao--capture-wire
      (let ((buf (agent-org-start 'qoder)))
        (ao--drive "initialize" ao--fake-init-resp)
        (ao--pick "s-live"
          (ao--drive "session/list"
                     (ao--list-resp `(("s-live" "Already open" ,(ao--today))))))
        (should-not (ao--sent-get "session/load"))
        (should-not (ao--sent-get "session/new"))
        (should-not (buffer-live-p buf))
        (should (eq (window-buffer (selected-window)) open))
        (should (= 1 (length acp-mock-shutdown-clients)))
        (kill-buffer open)))))

(ert-deftest test-agent-org-session-label-shows-when-it-last-spoke ()
  "A candidate for an older session is only usable if you can tell its
age: today, yesterday, this year's date, or a dated year.  The id stays
last, because it is what actually selects the session."
  (let* ((today (format-time-string "%Y-%m-%dT%H:%M:%S+0600"))
         (yesterday (format-time-string "%Y-%m-%dT12:00:00+0600"
                                        (time-subtract (current-time)
                                                       (days-to-time 1))))
         (resp `((sessions . [((sessionId . "t") (title . "Today one")
                               (updatedAt . ,today))
                              ((sessionId . "y") (title . "Yesterday one")
                               (updatedAt . ,yesterday))
                              ((sessionId . "old") (title . "Ancient")
                               (updatedAt . "2024-03-05T12:00:00+0600"))
                              ((sessionId . "none") (title . "No stamp"))])))
         (labels (seq-map #'car (agent-org--session-candidates resp))))
    (should (string-match-p "Today, [0-9][0-9]:[0-9][0-9]" (nth 0 labels)))
    (should (string-match-p "Yesterday, " (nth 1 labels)))
    (should (string-match-p "Mar 05, 2024" (nth 2 labels)))
    (should-not (string-match-p "[0-9][0-9]:[0-9][0-9]" (nth 3 labels)))
    (dolist (label labels)
      (should (string-match-p "\\[[a-z]+\\]\\'" label))
      (should-not (string-match-p "\n" label)))))

(ert-deftest test-agent-org-resume-uses-the-paged-listing-too ()
  "Resume and start share the pager, because two renderers would drift;
the single-candidate shortcut stays resume's own."
  (ao--capture-wire
    (let ((buf (agent-org-resume-session 'qoder nil)))
      (ao--drive "initialize" ao--fake-init-resp)
      (ao--pick "s-p2"
        (ao--drive "session/list"
                   (ao--list-resp `(("s-p1" "Page one" ,(ao--today))) "cursor-2"))
        (ao--drive "session/list"
                   (ao--list-resp `(("s-p2" "Page two"
                                     "2026-09-01T10:00:00+0000")))))
      (let ((params (map-elt (plist-get (ao--sent-get "session/load") ':request)
                             ':params)))
        (should (equal (map-elt params 'sessionId) "s-p2")))
      (should (= 2 (ao--sent-count "session/list")))
      (kill-buffer buf))))

;;;; Switching between open chat buffers (agent-shell's `agent-shell-switch-buffer')
;;
;; `C-x b' can already find a chat by name, but a name is one long string:
;; three qoder chats differ only in a title buried in the middle of it.  The
;; switcher's job is the ROW — label, live state, id — in columns you can
;; scan, which is exactly what the session listing already builds, so these
;; tests pin the reuse rather than a second formatter.

(defun ao--two-chats ()
  "Two registered chats, both Ready, with distinct ids and titles.
Returns ((BUFFER-1 . SESSION-1) . (BUFFER-2 . SESSION-2)).  The fixture
`ao--make-test-session' gives both the same id and leaves the brand-new
buffer on `starting', so this pins both facts: a switcher that lists two
identical rows is the bug this section exists to prevent, and the state
column is what the tests below read.

`agent-org--sessions' is global and other suites leave their chat buffers
alive, so a caller that counts rows must bind it nil around the whole
body — that is the test's job, not this helper's, because the binding has
to outlive the registration."
  (let ((one (ao--make-test-session "one"))
        (two (ao--make-test-session "two")))
    (setf (plist-get (cdr one) :session-id) "sid-one")
    (setf (plist-get (cdr two) :session-id) "sid-two")
    (agent-org-buffer-set-status (car one) :title "Fix the login bug"
                                 :session-id "sid-one" :state 'ready)
    (agent-org-buffer-set-status (car two) :title "Rewrite the loader"
                                 :session-id "sid-two" :state 'ready)
    (cons one two)))

(defun ao--dim-column (row)
  "The display-column offset of ROW's first DIMMED character, or nil.
`agent-org--session-display' leaves the title undecorated and puts the
`shadow' face on everything after it, so the first propertized character
IS the start of the date/status column — a measure that survives the
padding, unlike a search for the separator's spaces."
  (let ((i (next-single-property-change 0 'face row)))
    (and i (string-width (substring row 0 i)))))

(defmacro ao--isolated-registry (&rest body)
  "Run BODY with an empty session registry.
`agent-org--sessions' is global, and several earlier suites leave their
chat buffers alive, so a test that counts switcher rows would otherwise
count strangers — and a stranger's title is whatever the last test left
there, which is how a column assertion goes red for no reason."
  (declare (indent 0))
  `(let ((agent-org--sessions nil))
     ,@body))

(ert-deftest test-agent-org-switch-candidates-offer-every-open-chat ()
  "Every live chat buffer is a row, and the row's value is the BUFFER.
The cdr must be the buffer object, not its name: a name is what an agent
can rename out from under the registry, and choosing a chat by string
would then switch to nothing."
  (ao--isolated-registry
    (let* ((pair (ao--two-chats))
           (one (car pair))
           (two (cdr pair))
           (choices (agent-org--switch-candidates)))
      (should (= 2 (length choices)))
      (should (equal (mapcar #'cdr choices) (list (car two) (car one))))
      (should (string-match-p "Rewrite the loader" (car (nth 0 choices))))
      (should (string-match-p "\\[sid-two\\]\\'" (car (nth 0 choices))))
      (should (string-match-p "Fix the login bug" (car (nth 1 choices))))
      (kill-buffer (car one))
      (kill-buffer (car two)))))

(ert-deftest test-agent-org-switch-candidates-wear-the-provider-without-a-title ()
  "An agent that has titled nothing still gets a readable row.
The provider stands in, exactly as it does in the buffer name and
`#+TITLE:', so the switcher and `C-x b' never disagree about what a chat
is called.  The row carries the project directory after the colon, which
`agent-org-buffer-create' knows from the moment the buffer exists — this
is the one case where a chat has no title, so the label proves the
fallback reaches the switcher too."
  (ao--isolated-registry
    (let* ((pair (ao--make-test-session "untitled"))
           (choices (agent-org--switch-candidates))
           (project (file-name-nondirectory
                     (directory-file-name default-directory))))
      (should (= 1 (length choices)))
      (should (string-prefix-p (format "untitled:%s" project)
                               (car (nth 0 choices))))
      (should (string-match-p "\\[sid-test\\]\\'" (car (nth 0 choices))))
      (kill-buffer (car pair)))))

(ert-deftest test-agent-org-switch-candidates-name-the-project-too ()
  "The row's label is the buffer name's label, project included.
Live measurement: two qoder chats from one Emacs produced two rows that
were byte-identical except for a UUID (\"Qoder Streaming [b480…]\" and
\"Qoder Streaming [ef80…]\"), while `C-x b' was happily showing \"agent-org
Qoder\" and \"org-docs Qoder\".  The project directory is what distinguishes
two chats for the same harness, so the row wears it too — and it wears the
SAME string the buffer name is built from, not a second copy of the rules,
because two builders drift and one chat then has two names."
  (ao--isolated-registry
    (let* ((pair (ao--two-chats))
           (one (car pair))
           (two (cdr pair)))
      (agent-org-buffer-set-status (car one) :project "org-docs")
      (agent-org-buffer-set-status (car two) :project "agent-org")
      (let ((choices (agent-org--switch-candidates)))
        ;; row 0 is `two', row 1 is `one' (registry order)
        (should (string-match-p "\\`Rewrite the loader:agent-org" (car (nth 0 choices))))
        (should (string-match-p "\\`Fix the login bug:org-docs" (car (nth 1 choices))))
        ;; The shared builder, checked against the row rather than trusted:
        ;; this is what makes the assertion above survive a rename of the
        ;; buffer-name rules.
        (dolist (row choices)
          (should (string-prefix-p
                   (agent-org-buffer--chat-label
                    (buffer-local-value 'agent-org-buffer--status (cdr row)))
                   (car row))))
        (kill-buffer (car one))
        (kill-buffer (car two))))))

(ert-deftest test-agent-org-switch-candidates-show-the-state-the-bar-shows ()
  "The status column is the header line's own vocabulary.
Two words for one state (\"Ready\" on the bar, \"ready\" in the list) is
how a UI teaches you not to trust it, so the column comes from
`agent-org-buffer--state-label'."
  (ao--isolated-registry
    (let* ((pair (ao--two-chats))
           (one (car pair))
           (two (cdr pair)))
      (with-current-buffer (car two)
        (agent-org-buffer-set-status (car two) :state 'streaming))
      (let ((choices (agent-org--switch-candidates)))
        (should (string-match-p "Streaming" (car (nth 0 choices))))
        (should (string-match-p "Ready" (car (nth 1 choices)))))
      (kill-buffer (car one))
      (kill-buffer (car two)))))

(ert-deftest test-agent-org-switch-candidates-align-their-columns ()
  "The status column starts at the same display width in every row.
Measured the way the session listing measures: `string-width', so a CJK
title pads like a Latin one.  Ragged rows are the whole reason a chat list
is read by scanning down one column instead of reading across.

The column's start is ROW's first dimmed character, and NOT its first run
of two spaces: the short title is padded with spaces and the separator is
spaces too, so on a padded row the first double space sits somewhere
INSIDE the padding — counting to it measures where the padding happened to
begin, which is why this assertion read (18 47) while the rows, printed,
were identical 65-column strings."
  (ao--isolated-registry
    (let* ((pair (ao--two-chats))
           (one (car pair))
           (two (cdr pair)))
      ;; row 0 is `two' (registry order) and keeps its short title, so a
      ;; shared column start proves the SHORT row was padded to the long one
      (agent-org-buffer-set-status (car one) :title
                                   "A chat whose title runs on for very long indeed")
      (let ((labels (mapcar #'car (agent-org--switch-candidates))))
        (should (= 2 (length labels)))
        (should (apply #'equal (seq-map #'ao--dim-column labels)))
        ;; Equal total width too: the ids are the same length here, so the two
        ;; rows can only line up if the SHORT title was padded out to the
        ;; long one rather than the long one being cut down.
        (should (apply #'equal (seq-map #'string-width labels)))))))

(ert-deftest test-agent-org-switch-candidates-drop-a-killed-chat ()
  "A buffer that is gone is not offered, even if its entry is still in
`agent-org--sessions' — the registry is a stack of plists, and a plist
outlives its window until the kill-hook runs."
  (ao--isolated-registry
    (let* ((pair (ao--two-chats))
           (one (car pair))
           (two (cdr pair)))
      (kill-buffer (car two))
      (let ((choices (agent-org--switch-candidates)))
        (should (= 1 (length choices)))
        (should (equal (list (car one)) (mapcar #'cdr choices))))
      (kill-buffer (car one)))))

(ert-deftest test-agent-org-switch-buffer-switches-to-the-chosen-chat ()
  "The command reads a row and lands on that buffer, not on the other one."
  (ao--isolated-registry
    (let* ((pair (ao--two-chats))
           (one (car pair))
           (two (cdr pair)))
      (with-current-buffer (car one)
        (ao--pick "sid-two"
          (agent-org-switch-buffer))
        (should (eq (car two) (current-buffer))))
      (kill-buffer (car one))
      (kill-buffer (car two)))))

(ert-deftest test-agent-org-switch-buffer-with-nothing-open-signals ()
  "No chats, no minibuffer: a `user-error', not an empty completion.
Same shape as every other agent-org entry point — the user gets a reason
in the echo area, and nothing to cancel."
  (let ((completing-read-called nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) (setq completing-read-called t) "")))
      (should-error (agent-org-switch-buffer) :type 'user-error)
      (should-not completing-read-called))))

(ert-deftest test-agent-org-switch-buffer-pins-registry-order ()
  "The collection is a function that refuses the UI's re-sorting.
Registry order is newest-chat-first, which is the order a person switching
between chats wants; a plain list would be handed back alphabetically by
title and that information would be lost at the last step.  Same machinery
as the session chooser, so it must keep behaving the same."
  (ao--isolated-registry
    (let* ((pair (ao--two-chats))
           (one (car pair))
           (two (cdr pair))
           (collection nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt coll &rest _)
                   (setq collection coll)
                   (car (ao--collection coll)))))
        (agent-org-switch-buffer))
      (should (functionp collection))
      (let ((metadata (funcall collection "" nil 'metadata)))
        (should (eq (cdr (assq 'display-sort-function (cdr metadata)))
                    #'identity)))
      (should (equal (list (car two) (car one))
                     (mapcar #'cdr (agent-org--switch-candidates))))
      (kill-buffer (car one))
      (kill-buffer (car two)))))

(ert-deftest test-agent-org-switch-buffer-name-matches-agent-shell ()
  "The switcher borrows agent-shell's command name, not a synonym.
`agent-shell-switch-buffer' is what its users already type in M-x;
`agent-org-go-to-session' or `agent-org-select-buffer' would be a second
vocabulary for one action."
  (should (commandp 'agent-org-switch-buffer)))

;;;; Progress reporting while a session loads
;;
;; Two windows in agent-org are actually slow: fetching the directory's
;; older chats, and replaying one of them.  Both are now reported with
;; Emacs's own progress reporter in the echo area, which bounds its own
;; redisplays; the phase before them (the handshake) stays header-only,
;; because there is nothing to count and no events to step on.

(ert-deftest test-agent-org-progress-arms-no-timer ()
  "The report is stepped by the events that happen, never by a clock.
`agent-shell-active-message-show' animates its reporter with
`run-at-time' at 0.1s — ten wakeups a second, of which Emacs will
display at most five (`make-progress-reporter''s own MIN-TIME default is
0.2s), and which go on firing while the agent says nothing at all.  On a
Celeron that is the cost of a decoration: here a replay chunk or a
listing page IS the tick, so an idle agent costs zero."
  (let ((armings 0)
        (session (list :buffer nil :progress nil)))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (&rest _) (cl-incf armings) nil)))
      (agent-org--progress-start session "Restoring session history")
      (agent-org--progress-step session)
      (agent-org--progress-step session)
      (agent-org--progress-stop session))
    (should (= 0 armings))
    (should-not (plist-get session :progress))))

(ert-deftest test-agent-org-progress-throttles-the-echo-area ()
  "Stepping is cheap; displaying is not, so the interval bounds displays.
`progress-reporter-update' documents itself as relatively inexpensive:
it does nothing when the change since the last report is too small or
insufficient time has passed.  `agent-org-progress-min-time' is that
interval, and these two runs are the difference between a call and a
redisplay of a growing Org buffer: 20 steps an hour apart cost ONE
echo-area line — the one the report paints when it is created — while
the same 20 steps with the interval pinned to 0 show every one of them.
A slow machine raises the variable; the default is Emacs's own 0.2s."
  (let ((session (list :buffer nil :progress nil)))
    (ao--capture-messages
      (let ((agent-org-progress-min-time 3600))
        (agent-org--progress-start session "Restoring" :total 100)
        (dotimes (i 20) (agent-org--progress-step session (* (1+ i) 5))))
      ;; one line: the one the report painted when it was created
      (should (= 1 (length (remq nil ao--messages)))))
    (let ((session (list :buffer nil :progress nil)))
      (ao--capture-messages
        (let ((agent-org-progress-min-time 0))
          (agent-org--progress-start session "Restoring" :total 100)
          (dotimes (i 20) (agent-org--progress-step session (* (1+ i) 5))))
        ;; creation plus one per step, i.e. nothing suppressed
        (should (>= (length (remq nil ao--messages)) 20))))))

(ert-deftest test-agent-org-progress-replaces-the-reporter-it-starts-over ()
  "One session, one echo-area line: starting closes what was open.
The listing report and the replay report are consecutive phases of the
same `agent-org-start', so a second live reporter would mean two owners
of one line — and the older one would keep stepping a message nobody is
waiting for.  Only what is displayed AFTER the replacement matters here:
creating a report paints its line immediately, so the first phase is
entitled to the echo area while it is the phase you are in."
  (let ((session (list :buffer nil :progress nil)))
    (ao--capture-messages
      (let ((agent-org-progress-min-time 0))
        (agent-org--progress-start session "Listing sessions")
        (agent-org--progress-step session "12 so far")
        (let ((before (length ao--messages)))
          (agent-org--progress-start session "Restoring session history")
          (agent-org--progress-step session)
          ;; `ao--messages' is newest first, so the lines the replacement
          ;; produced are the ones in front of what was already there.
          (let ((fresh (seq-take ao--messages (- (length ao--messages) before))))
            (should fresh)
            (should-not (seq-filter (lambda (m) (and m (string-match-p "Listing" m)))
                                    fresh))
            (should (seq-filter (lambda (m) (and m (string-match-p "Restoring" m)))
                                fresh))
            (should (plist-get session :progress))))))))

(ert-deftest test-agent-org-progress-stop-clears-rather-than-says-done ()
  "Closing a report frees the echo area instead of printing `...done'.
`progress-reporter-done' exists to announce a task whose result you
cannot otherwise see; both of our phases produce something visible (the
chooser opens, the history is in the buffer), and the header line already
carries the state.  agent-shell calls done and then `(message nil)'
back-to-back, so its `done' line is a redisplay nobody reads — the one
cost we can simply not pay."
  (let ((session (list :buffer nil :progress nil)))
    (ao--capture-messages
      (let ((agent-org-progress-min-time 0))
        (agent-org--progress-start session "Restoring session history")
        (agent-org--progress-step session)
        (agent-org--progress-stop session))
      (should-not (plist-get session :progress))
      (should (null (car ao--messages)))
      (should-not (seq-filter (lambda (m) (and m (string-match-p "done" m)))
                              ao--messages)))))

(ert-deftest test-agent-org-listing-reports-and-clears-before-the-prompt ()
  "Fetching the older chats is reported, and the report is closed before
the chooser opens.
The header says `Connecting…' for the whole window between the handshake
and a live session — true, but not specific: this wait is the listing.
After it the user is reading candidates, so a progress line still
blinking over the minibuffer would be noise at exactly the wrong moment."
  (ao--capture-wire
    (let* ((agent-org-progress-min-time 0)
           (agent-org-session-strategy 'prompt)
           (at-prompt nil)
           (buf (agent-org-start 'qoder))
           (session (agent-org--session-for-buffer buf)))
      (ao--drive "initialize" ao--fake-init-resp)
      (should (plist-get session :progress))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (push (list :live (plist-get session :progress)
                               :latest (car ao--messages))
                         at-prompt)
                   (seq-find (lambda (c) (string-match-p "\\[s-new\\]" c))
                             (ao--collection collection)))))
        (ao--capture-messages
          (ao--drive "session/list"
                     (ao--list-resp `(("s-new" "Newest chat" ,(ao--today))
                                      ("s-old" "Older chat"
                                       "2026-09-01T10:00:00+0000"))))
          (should (= 1 (length at-prompt)))
          (should-not (plist-get (car at-prompt) :live))
          (should (null (plist-get (car at-prompt) :latest)))
          (should (seq-filter (lambda (m) (and m (string-match-p "Listing sessions" m)))
                              ao--messages)))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-listing-pages-step-the-report ()
  "Every page of a paged listing ticks the report, and says how many it has.
A directory with hundreds of chats is fetched over several requests; the
count in the report is the difference between \"working\" and \"hung\" on
a machine where one agent process already owns the CPU.
Both counts come from ONE report, because the continuation leaves it
running: the numbers climb rather than restarting, which is the only way
a paged listing reads as progress.  The report this test ends with is the
replay's, not the listing's — `latest' chose a session and
`agent-org--progress-start' handed the line over."
  (ao--capture-wire
    (let* ((agent-org-progress-min-time 0)
           (agent-org-session-strategy 'latest)
           (buf (agent-org-start 'qoder))
           (session (agent-org--session-for-buffer buf)))
      (ao--drive "initialize" ao--fake-init-resp)
      (ao--capture-messages
        (ao--drive "session/list"
                   (ao--list-resp `(("s-p1" "Page one" ,(ao--today))) "cursor-2"))
        (ao--drive "session/list"
                   (ao--list-resp `(("s-p2" "Page two"
                                     "2026-09-01T10:00:00+0000"))))
        (dolist (count '("1 so far" "2 so far"))
          (should (seq-filter (lambda (m) (and m (string-match-p count m)))
                              ao--messages)))
        (should (plist-get session :progress)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-replay-reports-as-history-arrives ()
  "`session/load' is the wait a user feels, so the echo area moves with it.
While the replay streams the buffer is not interactive and the header
cannot say how much has landed — a 200-turn restore looked identical to a
hung one.  Each buffered update steps the report, which is what makes a
spinner animate without any timer running."
  (ao--capture-wire
    (let* ((agent-org-progress-min-time 0)
           (buf (agent-org-resume-session 'qoder "sid-p"))
           (session (agent-org--session-for-buffer buf)))
      (ao--drive "initialize" ao--fake-init-resp)
      (should (plist-get session :progress))
      (ao--capture-messages
        (dolist (update (list
                         '((sessionUpdate . "user_message_chunk")
                           (content . ((type . "text") (text . "Old question"))))
                         '((sessionUpdate . "agent_message_chunk")
                           (content . ((type . "text") (text . "Old answer"))))))
          (agent-org--on-notification session (ao--update-notif update)))
        (should (>= (length (seq-filter (lambda (m)
                                          (and m (string-match-p "Restoring session history" m)))
                                        ao--messages))
                    2))
        (ao--drive "session/load" '((sessionId . "sid-p")))
        (ao--settle)
        (should-not (plist-get session :progress))
        (should (null (car ao--messages))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-painting-history-reports-a-percentage ()
  "The paint pass reports a fraction of the buffered updates.
This is the part that costs the machine real time — hundreds of Org
insertions in one synchronous run — and it is the only phase with a
denominator, since the buffered replay is counted by then.  A spinner
here would say \"busy\"; a percentage says how far to go."
  (ao--capture-wire
    (let* ((agent-org-progress-min-time 0)
           (buf (agent-org-resume-session 'qoder "sid-pct"))
           (session (agent-org--session-for-buffer buf)))
      (ao--drive "initialize" ao--fake-init-resp)
      (dolist (n '(1 2 3 4))
        (agent-org--on-notification
         session
         (ao--update-notif
          `((sessionUpdate . "agent_message_chunk")
            (content . ((type . "text") (text . ,(format "Turn %s" n))))))))
      (ao--drive "session/load" '((sessionId . "sid-pct")))
      (ao--capture-messages
        (ao--settle)
        (should (seq-filter (lambda (m)
                              (and m (string-match-p "[0-9]+%" m)))
                            ao--messages))
        (should-not (plist-get session :progress)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-killing-a-loading-buffer-clears-the-report ()
  "A restore abandoned by killing the chat buffer leaves no line behind.
`agent-org--forget-session' already owns every other exit of a loading
session — its timers, its agent process, its registry entry — and the
echo area is the fourth: without this the killed buffer's spinner kept
redrawing a line under whatever the user opened next."
  (ao--capture-wire
    (let* ((agent-org-progress-min-time 0)
           (buf (agent-org-resume-session 'qoder "sid-k"))
           (session (agent-org--session-for-buffer buf)))
      (ao--drive "initialize" ao--fake-init-resp)
      (should (plist-get session :progress))
      (ao--capture-messages
        (kill-buffer buf)
        (should-not (plist-get session :progress))
        (should (null (car ao--messages)))))))

(ert-deftest test-agent-org-failed-load-clears-the-report ()
  "A `session/load' that fails ends the report silently.
The header carries the error (`:state 'error' renders its message), so
the echo area's job is to get out of the way — no `...done', no spinner,
and nothing left that would cover the diagnostic."
  (ao--capture-wire
    (let* ((agent-org-progress-min-time 0)
           (buf (agent-org-resume-session 'qoder "sid-f"))
           (session (agent-org--session-for-buffer buf)))
      (ao--drive "initialize" ao--fake-init-resp)
      (ao--capture-messages
        (let ((entry (ao--sent-get "session/load")))
          (should entry)
          (funcall (plist-get entry :on-failure)
                   nil '((:object (error (code . -32603)
                                         (message . "boom"))) (:json . "{}"))))
        (should-not (plist-get session :progress))
        (should (null (car ao--messages))))
      (kill-buffer buf))))

;;;; One Org transcript file per session
;;
;; User order (TODOs.org): "By default, keep a single Org transcript file to map
;; to a session and regularly update it."  agent-shell appends each arriving
;; chunk to a markdown file; here the chat body IS already an Org document, so
;; the file is a MIRROR of its frozen part, rewritten at the turn boundaries.
;; Three consequences, and each has a test below:
;;  - one renderer, not two (a second paint path always drifts from the first);
;;  - a tool heading that went TODO -> DONE appears ONCE, as DONE, which an
;;    append log cannot express;
;;  - the cost is a couple of whole-file writes per TURN, never one per chunk.

(defmacro ao--transcript-in (dir &rest body)
  "Run BODY with transcription ON, writing into DIR.
The feature has exactly two knobs and every writer test wants both:
`agent-org-transcribe' on, and a directory that is not the real one under
`user-emacs-directory' where the user's own transcripts live."
  (declare (indent 1))
  `(let ((agent-org-transcribe t)
         (agent-org-transcript-directory ,dir))
     ,@body))

(defun ao--transcript-files (dir)
  "Every `.org' name in DIR, sorted.  How these tests count files.
`directory-files' answers \".\" and \"..\" too, and a transcript directory
holds nothing else, so the suffix filter is the whole assertion."
  (sort (seq-filter (lambda (f) (string-suffix-p ".org" f))
                    (directory-files dir))
        #'string<))

(defun ao--transcript-text (dir session-id)
  "The text SESSION-ID's transcript holds in DIR.
The path is built with `agent-org-buffer--transcript-name' as plumbing; the
name's SHAPE is pinned against a literal string by
`test-agent-org-transcript-file-is-named-for-the-session-id', so nothing
here is circular."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name (agent-org-buffer--transcript-name session-id) dir))
    (buffer-string)))

(defvar ao--writes nil
  "How many `.org' writes `ao--counting-writes' has swallowed.")

(defmacro ao--counting-writes (&rest body)
  "Run BODY with `write-region' swallowed and counted in `ao--writes'.
Only a `.org' target counts: `write-region' has other callers, and what is
being measured here is what the transcript writer does."
  (declare (indent 0))
  `(let ((ao--writes 0))
     (cl-letf (((symbol-function 'write-region)
                (lambda (start end filename &optional append visit &rest _)
                  (when (and (stringp filename) (string-suffix-p ".org" filename))
                    (cl-incf ao--writes)))))
       ,@body)))

(ert-deftest test-agent-org-transcript-file-is-named-for-the-session-id ()
  "A session's transcript is one file, named by its ACP id.
The id is the only fact that survives a rename, a title change and a
restart, so it is what maps a file to a session.  A chat with no turn yet
still gets the file: it carries the =:PROPERTIES:= drawer — including that
same id as Org's =:ID:=, which is what makes the transcript an
=id:=-linkable document — and the first thing in it is the header, not a
conversation."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (ao--capture-wire
        (let ((buf (ao--chat-on-model "qmodel-large" "QModel Large" "sid-42")))
          (should (equal '("sid-42.org") (ao--transcript-files temp-dir)))
          (let ((text (ao--transcript-text temp-dir "sid-42")))
            (should (string-match-p "^:ID: sid-42$" text))
            (should (string-match-p "^#\\+TITLE: " text))
            ;; the live type-ahead box is not conversation yet
            (should-not (string-match-p "^\\* User$" text)))
          (kill-buffer buf))))))

(ert-deftest test-agent-org-transcript-holds-a-completed-turn ()
  "One turn, on disk, in the order it happened: prompt, answer, tool, thought.
Twenty chunks stream an answer and the file holds one copy of it — the
transcript is written from the buffer at the turn boundary, so however the
agent split its reply, the document is the reply."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (ao--capture-wire
        (let* ((buf (ao--chat-on-model "qmodel-large" "QModel Large" "sid-turn"))
               (session (agent-org--session-for-buffer buf))
               (sent nil))
          (cl-letf (((symbol-function 'acp-send-request)
                     (lambda (&rest kw) (push kw sent)))
                    ((symbol-function 'acp-make-session-prompt-request)
                     (lambda (&rest a) (plist-get a :prompt))))
            (with-current-buffer buf
              (ao--type "align the columns")
              (agent-org-send))
            (dotimes (_ 20)
              (agent-org--on-notification
               session (ao--update-notif
                        '((sessionUpdate . "agent_message_chunk")
                          (content . ((type . "text") (text . "tok ")))))))
            (agent-org--on-notification
             session (ao--update-notif
                      '((sessionUpdate . "agent_thought_chunk")
                        (content . ((type . "text") (text . "reasoning here"))))))
            (agent-org--on-notification
             session (ao--update-notif
                      '((sessionUpdate . "tool_call")
                        (toolCallId . "t1") (title . "grep -rn foo")
                        (status . "pending"))))
            (funcall (plist-get (car sent) :on-success) nil)
            (let ((text (ao--transcript-text temp-dir "sid-turn")))
              (should (apply #'ao--ordered text
                             (list "^:ID: sid-turn$"
                                   "^\\* User$" "align the columns"
                                   "^\\* QModel Large$" "tok tok"
                                   "^:thinking:$" "reasoning here"
                                   "^:tool:$" "^- TODO grep -rn foo$")))
              (kill-buffer buf))))))))

(ert-deftest test-agent-org-transcript-rewrites-a-tool-line-instead-of-logging-it ()
  "A tool that finished appears as DONE once — no TODO line above it.
This is the test that says \"mirror, not append log\": a per-chunk append can
only add, so an in-place state change would leave the superseded line in the
file forever.  Here the buffer already redrew the `:tool:' drawer from the
stored status and the file simply agrees with the buffer."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (ao--capture-wire
        (let* ((buf (ao--chat-on-model "qmodel-large" "QModel Large" "sid-tool"))
               (session (agent-org--session-for-buffer buf))
               (sent nil))
          (cl-letf (((symbol-function 'acp-send-request)
                     (lambda (&rest kw) (push kw sent)))
                    ((symbol-function 'acp-make-session-prompt-request)
                     (lambda (&rest a) (plist-get a :prompt))))
            (with-current-buffer buf
              (ao--type "run it")
              (agent-org-send))
            (dolist (status '("pending" "in_progress" "completed"))
              (agent-org--on-notification
               session (ao--update-notif
                        `((sessionUpdate . "tool_call_update")
                          (toolCallId . "t1") (title . "run tests")
                          (status . ,status)))))
            (funcall (plist-get (car sent) :on-success) nil)
            (let ((text (ao--transcript-text temp-dir "sid-tool")))
              (should (= 1 (ao--count-occurrences text "^- DONE run tests$")))
              (should (= 0 (ao--count-occurrences text "^- \\(TODO\\|DOING\\) run tests$")))
              (kill-buffer buf))))))))

(ert-deftest test-agent-org-transcript-is-one-file-for-the-whole-session ()
  "Three turns, one file: the transcript maps to the SESSION, not to a turn.
A chat that spawned a file per answer would be a pile of fragments nobody
reads again, and `agent-org-reload' — which replays the same id through a
new buffer — lands on the same file for the same reason."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (ao--capture-wire
        (let* ((buf (ao--chat-on-model "qmodel-large" "QModel Large" "sid-multi"))
               (sent nil))
          (cl-letf (((symbol-function 'acp-send-request)
                     (lambda (&rest kw) (push kw sent)))
                    ((symbol-function 'acp-make-session-prompt-request)
                     (lambda (&rest a) (plist-get a :prompt))))
            (dolist (prompt '("first" "second" "third"))
              (with-current-buffer buf
                (ao--type prompt)
                (agent-org-send)
                (agent-org-buffer-append-chunk
                 buf (format "answer to %s" prompt)
                 (agent-org--session-for-buffer buf))
                (funcall (plist-get (car sent) :on-success) nil)))
            (should (equal '("sid-multi.org") (ao--transcript-files temp-dir)))
            (let ((text (ao--transcript-text temp-dir "sid-multi")))
              (should (apply #'ao--ordered text
                             (list "first" "answer to first"
                                   "second" "answer to second"
                                   "third" "answer to third")))
              (should (= 3 (ao--count-occurrences text "^\\* User$")))
              (kill-buffer buf))))))))

(ert-deftest test-agent-org-transcript-leaves-the-unsent-draft-out ()
  "What the user has typed but not sent never reaches the file.
The boundary between the two is `agent-org-buffer--render-end' — the same
marker that keeps a streaming turn from scribbling over a draft — so the
transcript is the conversation and a half-written thought stays in the
buffer.  A late title push is the boundary here: it re-marks the session
ready while a draft is live, which is exactly when the two could mix."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (ao--capture-wire
        (let* ((sid "sid-draft")
               (buf (ao--chat-on-model "qmodel-large" "QModel Large" sid))
               (session (agent-org--session-for-buffer buf))
               (sent nil))
          (cl-letf (((symbol-function 'acp-send-request)
                     (lambda (&rest kw) (push kw sent)))
                    ((symbol-function 'acp-make-session-prompt-request)
                     (lambda (&rest a) (plist-get a :prompt))))
            (with-current-buffer buf
              (ao--type "sent prompt")
              (agent-org-send)
              (funcall (plist-get (car sent) :on-success) nil)
              (ao--type "half a thought, still typing"))
            ;; a params-level sessionId is what the handler gates on: no
            ;; id, no ready pass, no boundary to test
            (agent-org--on-notification
             session
             `((method . "session/update")
               (params . ((sessionId . ,sid)
                          (update . ((sessionUpdate . "session_info_update")
                                     (title . "Renamed by the agent")))))))
            (let ((text (ao--transcript-text temp-dir "sid-draft")))
              (should (string-match-p "sent prompt" text))
              (should-not (string-match-p "half a thought" text))
              ;; and the metadata did catch up, in the same pass
              (should (string-match-p "^#\\+TITLE: Renamed by the agent$" text))
              (kill-buffer buf))))))))

(ert-deftest test-agent-org-transcript-paints-a-restored-session ()
  "A resumed chat is on disk without anyone sending a prompt into it.
Restoring is the case where a per-turn write would never fire: the history
arrives in one replay pass and the user may read it and close Emacs.
`agent-org--finish-replay' ends in `agent-org--session-ready', which is a
boundary, so the mirror is written once the history has landed."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (ao--capture-wire
        (let ((buf (agent-org-resume-session 'qoder "sid-restored")))
          (let ((session (agent-org--session-for-buffer buf)))
            (ao--drive "initialize" ao--fake-init-resp)
            (dolist (update (list
                             '((sessionUpdate . "user_message_chunk")
                               (content . ((type . "text") (text . "Old question"))))
                             '((sessionUpdate . "agent_message_chunk")
                               (content . ((type . "text") (text . "Old answer"))))))
              (agent-org--on-notification session (ao--update-notif update)))
            (ao--drive "session/load" '((sessionId . "sid-restored")))
            (ao--settle)
            (should (equal '("sid-restored.org") (ao--transcript-files temp-dir)))
            (let ((text (ao--transcript-text temp-dir "sid-restored")))
              (should (apply #'ao--ordered text (list "Old question" "Old answer"))))
            (kill-buffer buf)))))))

(ert-deftest test-agent-org-transcript-writes-nothing-when-turned-off ()
  "`agent-org-transcribe' nil means no file appears, at all.
The default is on, so this is the opt-out the user's wording asks for
(\"BY DEFAULT, keep a single Org transcript file\") honoured in the other
direction: someone whose transcripts are their own org files under version
control must be able to turn the writer off without patching it out."
  (ert-with-temp-directory temp-dir
    (let ((agent-org-transcribe nil)
          (agent-org-transcript-directory temp-dir))
      (ao--capture-wire
        (let* ((buf (ao--chat-on-model "qmodel-large" "QModel Large" "sid-off"))
               (sent nil))
          (cl-letf (((symbol-function 'acp-send-request)
                     (lambda (&rest kw) (push kw sent)))
                    ((symbol-function 'acp-make-session-prompt-request)
                     (lambda (&rest a) (plist-get a :prompt))))
            (with-current-buffer buf
              (ao--type "quiet")
              (agent-org-send)
              (funcall (plist-get (car sent) :on-success) nil))
          (should (null (ao--transcript-files temp-dir)))
          ;; the chat itself works exactly the same way
          (with-current-buffer buf
            (should (string-match-p "quiet" (buffer-string))))
          (kill-buffer buf)))))))

(ert-deftest test-agent-org-transcript-costs-writes-per-turn-not-per-chunk ()
  "One turn costs two whole-file writes: the send and the turn end.
This is the overhead claim on a 4 GB machine.  Twenty streaming chunks and a
thought add NOTHING, because the writer is called at boundaries and not from
the render path — which is also why a slow disk cannot stall a stream."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (ao--capture-wire
        (let* ((buf (ao--chat-on-model "qmodel-large" "QModel Large" "sid-cost"))
               (session (agent-org--session-for-buffer buf))
               (sent nil))
          (cl-letf (((symbol-function 'acp-send-request)
                     (lambda (&rest kw) (push kw sent)))
                    ((symbol-function 'acp-make-session-prompt-request)
                     (lambda (&rest a) (plist-get a :prompt))))
            ;; the fixture's own ready boundary already wrote once; count
            ;; the turn from here
            (ao--counting-writes
              (with-current-buffer buf
                (ao--type "cost me nothing")
                (agent-org-send))
              (dotimes (_ 20)
                (agent-org--on-notification
                 session (ao--update-notif
                          '((sessionUpdate . "agent_message_chunk")
                            (content . ((type . "text") (text . "chunk ")))))))
              (agent-org--on-notification
               session (ao--update-notif
                        '((sessionUpdate . "agent_thought_chunk")
                          (content . ((type . "text") (text . "think"))))))
              (funcall (plist-get (car sent) :on-success) nil)
              (should (= 2 ao--writes)))
          (kill-buffer buf)))))))

(ert-deftest test-agent-org-transcript-skips-an-unchanged-body ()
  "The same text is never written twice.
A boundary can fire with nothing new — a repeated title, a second ready
call — and the write is a whole-file `write-region', so the cheap guard is
to compare against what was last put there.  It also keeps the file's mtime
honest: an untouched transcript must not look like it was edited."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (let* ((pair (ao--make-test-session "unchanged"))
             (buf (car pair)))
        (agent-org-buffer-set-status buf :session-id "sid-same" :state 'ready)
        (agent-org-buffer-refresh-metadata buf)
        (ao--counting-writes
          (agent-org-buffer-transcribe buf)
          (should (= 1 ao--writes))
          (agent-org-buffer-transcribe buf)
          (should (= 1 ao--writes))
          ;; and one change is enough to make the next boundary real
          (agent-org-buffer-insert-user buf "a new turn")
          (agent-org-buffer-transcribe buf)
          (should (= 2 ao--writes)))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-transcript-sanitizes-an-id-that-looks-like-a-path ()
  "A session id is agent text, and it never gets to choose where a file lands.
Qoder issues UUIDs and Goose issues timestamps, but the id arrives over the
wire and becomes a file name, so every separator becomes a dash:
\"../../etc/passwd\" writes INSIDE the transcript directory, not outside it.
Without this the writer is a path-traversal primitive handed to whatever
server the user pointed Emacs at."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (ao--capture-wire
        (let ((buf (ao--chat-on-model "qmodel-large" "QModel Large"
                                      "../../evil")))
          (should (= 1 (length (ao--transcript-files temp-dir))))
          (should-not (string-match-p "/" (car (ao--transcript-files temp-dir))))
          ;; nothing escaped the directory
          (should-not (file-exists-p (expand-file-name "evil.org"
                                                       (file-name-directory
                                                        (directory-file-name temp-dir)))))
          (kill-buffer buf))))))

(ert-deftest test-agent-org-transcript-directory-default-is-a-project-dot-directory ()
  "The default is the RELATIVE name `.agent-org', not a path under ~/.emacs.d.
User order: \"Transcripts should live under a project's .agent-org/.\"  A
chat's own directory is the one place its transcript is found without a
search, the same reason a project keeps its own README — and a relative
default is what makes it so, because `expand-file-name' resolves it against
the buffer's `default-directory', which is the session cwd.  An absolute
value is still honoured (see the test below), so one global pool is a
setting away."
  (should (equal agent-org-transcript-directory ".agent-org"))
  (should-not (file-name-absolute-p agent-org-transcript-directory)))

(ert-deftest test-agent-org-transcript-lands-in-the-chats-own-project ()
  "A chat of ~/proj writes ~/proj/.agent-org/<sid>.org.
The whole point of the relative default, so it is asserted against a real
directory rather than against a computed string: the file must be THERE,
under the project, after the handshake that names the session.  A project
keeps its own transcript the way it keeps its own README."
  (ert-with-temp-directory project
    (let ((agent-org-transcribe t)
          (agent-org-transcript-directory ".agent-org")
          (default-directory (file-name-as-directory project)))
      (ao--capture-wire
        (let ((buf (ao--chat-on-model "qmodel-large" "QModel Large"
                                      "sid-proj")))
          (let ((in-project (expand-file-name ".agent-org" project)))
            (should (file-directory-p in-project))
            (should (equal '("sid-proj.org") (ao--transcript-files in-project))))
          (kill-buffer buf))))))

(ert-deftest test-agent-org-two-projects-keep-their-own-transcripts ()
  "Two chats, two projects, two directories.
One pool named by id makes a transcript impossible to find without knowing
which chat produced it; the project directory is the index.  Both buffers
are Ready with the same model, so only the cwd distinguishes them."
  (ert-with-temp-directory proj-a
    (ert-with-temp-directory proj-b
      (let ((agent-org-transcribe t)
            (agent-org-transcript-directory ".agent-org"))
        (ao--capture-wire
          (let* ((default-directory (file-name-as-directory proj-a))
                 (buf-a (ao--chat-on-model "qmodel-large" "QModel Large" "sid-a"))
                 (default-directory (file-name-as-directory proj-b))
                 (buf-b (ao--chat-on-model "qmodel-large" "QModel Large" "sid-b")))
            (should (equal '("sid-a.org")
                           (ao--transcript-files (expand-file-name ".agent-org" proj-a))))
            (should (equal '("sid-b.org")
                           (ao--transcript-files (expand-file-name ".agent-org" proj-b))))
            (kill-buffer buf-a)
            (kill-buffer buf-b)))))))

(ert-deftest test-agent-org-transcript-honours-an-absolute-directory-option ()
  "An absolute setting is a global pool, and the code must not join it twice.
`(expand-file-name \"/srv/t\" \"/proj/\")' answers \"/srv/t\" — the property
this test pins, because the same line of code resolves both cases and the
one that reads like a bug (`why is a path being expanded?') is what makes a
relative setting work."
  (ert-with-temp-directory project
    (ert-with-temp-directory pool
      (let ((agent-org-transcribe t)
            (agent-org-transcript-directory (file-name-as-directory pool))
            (default-directory (file-name-as-directory project)))
        (ao--capture-wire
          (let ((buf (ao--chat-on-model "qmodel-large" "QModel Large" "sid-abs")))
            (should (equal '("sid-abs.org") (ao--transcript-files pool)))
            (should-not (file-exists-p (expand-file-name ".agent-org" project)))
            (kill-buffer buf)))))))

(ert-deftest test-agent-org-transcript-failure-never-breaks-a-turn ()
  "An unwritable directory is a note in the echo area, not a broken chat.
The transcript is a convenience; the conversation is the feature.  Here the
path is under a regular FILE, so no directory can be created at all and
every write fails — and the turn must still stream, close and go Ready
exactly as it would with transcription off."
  (ert-with-temp-directory temp-dir
    (let ((blocker (expand-file-name "blocker" temp-dir)))
      (write-region "not a directory\n" nil blocker)
      (ao--transcript-in (expand-file-name "transcripts" blocker)
        (ao--capture-wire
          (let* ((buf (ao--chat-on-model "qmodel-large" "QModel Large" "sid-fail"))
                 (session (agent-org--session-for-buffer buf))
                 (sent nil))
            (cl-letf (((symbol-function 'acp-send-request)
                       (lambda (&rest kw) (push kw sent)))
                      ((symbol-function 'acp-make-session-prompt-request)
                       (lambda (&rest a) (plist-get a :prompt))))
              (with-current-buffer buf
                (ao--type "still works")
                (agent-org-send)
                (agent-org-buffer-append-chunk buf "the answer arrived" session)
                (funcall (plist-get (car sent) :on-success) nil))
            (should-not (plist-get session :streaming))
            (with-current-buffer buf
              (should (eq 'ready (plist-get agent-org-buffer--status :state)))
              (should (string-match-p "the answer arrived" (buffer-string))))
            (kill-buffer buf))))))))

(ert-deftest test-agent-org-transcript-flushes-when-the-buffer-is-killed ()
  "Killing a chat mid-turn still puts that turn on disk.
The turn end is a boundary and a kill is not, so without the kill hook the
last answer of every session — the one the user stopped reading — would be
the one missing from the file.  `agent-org--forget-session' writes before it
releases the agent."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (ao--capture-wire
        (let* ((buf (ao--chat-on-model "qmodel-large" "QModel Large" "sid-kill"))
               (session (agent-org--session-for-buffer buf))
               (sent nil))
          (cl-letf (((symbol-function 'acp-send-request)
                     (lambda (&rest kw) (push kw sent)))
                    ((symbol-function 'acp-make-session-prompt-request)
                     (lambda (&rest a) (plist-get a :prompt))))
            (with-current-buffer buf
              (ao--type "interrupted chat")
              (agent-org-send)
              (agent-org-buffer-append-chunk buf "partial answer" session))
            ;; no on-success: the buffer dies with the turn still open
            (should-not (string-match-p "partial answer"
                                        (ao--transcript-text temp-dir "sid-kill")))
            (kill-buffer buf)
            (should (string-match-p "partial answer"
                                    (ao--transcript-text temp-dir "sid-kill")))
            (should-not (agent-org--session-for-buffer buf))))))))

(provide 'test-agent-org)
;;; test-agent-org.el ends here

