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

(ert-deftest test-agent-org-copilot-provider-present ()
  "GitHub Copilot is its OWN ACP agent: `copilot --acp'.
Copilot CLI speaks ACP (public preview) and keeps its own login, so — like
MiniMax Code — it pins nothing (its default model is already the right one)
and only passes a headless COPILOT_GITHUB_TOKEN through when present."
  (let ((copilot (agent-org--provider-spec 'copilot)))
    (should (equal (plist-get copilot :name) "Copilot"))
    (should (equal (plist-get copilot :command) '("copilot" "--acp")))
    (should-not (plist-get copilot :model))
    (should (equal (plist-get copilot :environment)
                   #'agent-org-copilot-environment))))

(ert-deftest test-agent-org-cursor-provider-present ()
  "Cursor's CLI binary is `agent', with ACP a subcommand: `agent acp'.
A reader would guess `cursor acp'; it is not — the command mirrors
agent-shell's `agent-shell-cursor-acp-command'.  Auth defaults to an
external `agent login' (no ACP authenticate request, unlike agent-shell's
optional cursor_login flow, which agent-org does not drive), so the entry
pins no model."
  (let ((cursor (agent-org--provider-spec 'cursor)))
    (should (equal (plist-get cursor :name) "Cursor"))
    (should (equal (plist-get cursor :command) '("agent" "acp")))
    (should-not (plist-get cursor :model))
    (should (equal (plist-get cursor :environment)
                   #'agent-org-cursor-environment))))

(ert-deftest test-agent-org-codebuddy-provider-present ()
  "CodeBuddy is its own CLI agent: `codebuddy --acp'.
Login is kept by the CLI itself, so nothing is exported by default."
  (let ((codebuddy (agent-org--provider-spec 'codebuddy)))
    (should (equal (plist-get codebuddy :name) "CodeBuddy"))
    (should (equal (plist-get codebuddy :command) '("codebuddy" "--acp")))
    (should-not (plist-get codebuddy :model))
    (should (equal (plist-get codebuddy :environment)
                   #'agent-org-codebuddy-environment))))

(ert-deftest test-agent-org-copilot-cursor-codebuddy-start-open-themselves ()
  "Each new per-provider command is the same thin call with its id baked in.
The drift test already proves one `agent-org-<id>-start-agent' exists for
every registered id; this proves each actually opens ITS OWN session, so a
copy-pasted command that starts the wrong agent is caught.  Under the mock
there is no live process, so the kill hook stays silent."
  (ao--capture-wire
    (dolist (pair '((copilot . agent-org-copilot-start-agent)
                    (cursor . agent-org-cursor-start-agent)
                    (codebuddy . agent-org-codebuddy-start-agent)))
      (let ((buf (funcall (cdr pair))))
        (should (buffer-live-p buf))
        (should (eq (car pair)
                    (plist-get (agent-org--session-for-buffer buf) :name)))
        (kill-buffer buf)))))

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

;;;; Buffer names: <agent>:<project> [id]

(ert-deftest test-agent-org-buffer-name-carries-project ()
  "The agent's name leads, and the project follows the colon.
`Qoder:agent-org [sid]' is the shape the user asked for by name: the
harness first, because that is what a person scans for, and the last
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

(ert-deftest test-agent-org-buffer-name-wears-the-agent-not-the-title ()
  "A session title never enters the buffer name.
`Qoder' says which harness answers; the agent's own title says what the
chat is ABOUT, and the user asked for the first: \"Buffer names are
showing session names in place of agent names.\"  The title is not lost —
it is the `#+TITLE:' of the buffer and of its transcript — it just is not
the buffer's name.  (This fixture's agent reports \"Initial Session
Title\" on `session/new', which used to rename the buffer.)"
  (let ((default-directory ao--name-dir))
    (let* ((pair (ao--make-test-session "nametest"))
           (buf (car pair))
           (session (cdr pair)))
      (setf (plist-get session :session-id) nil)
      (agent-org--session-ready session "sid-x" (ao--fake-session-new-resp))
      (should (equal "nametest:ao-proj [sid-x]" (buffer-name buf)))
      (should (equal "Initial Session Title"
                     (plist-get (buffer-local-value 'agent-org-buffer--status buf)
                                :title)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-buffer-name-wears-the-provider-with-no-title ()
  "A session whose agent titles nothing is named the same as one that did.
There is no fallback any more: the provider is the name, so the two cases
cannot diverge — which is what makes an agent that never sends
`session_info_update' (goose) read like one that does."
  (let ((default-directory ao--name-dir))
    (let ((buf (agent-org-buffer-create "standin")))
      (agent-org-buffer-set-status buf :session-id "sid-9")
      (should (equal "standin:ao-proj [sid-9]" (buffer-name buf)))
      (agent-org-buffer-set-status buf :title "Something the agent wrote")
      (should (equal "standin:ao-proj [sid-9]" (buffer-name buf)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-buffer-name-ignores-a-late-title ()
  "A title arriving mid-conversation does not rename the buffer.
qoder titles a session after the first turn, and a chat whose name changes
under the user mid-read is worse than a name that never described the
topic: `C-x b' windows, isearch and a window's `buffer-name' in a mode
line all follow the buffer, not the session."
  (let ((default-directory ao--name-dir))
    (let* ((pair (ao--make-test-session "latetitle"))
           (buf (car pair)))
      (agent-org-buffer-set-status buf :session-id "sid-l")
      (should (equal "latetitle:ao-proj [sid-l]" (buffer-name buf)))
      (agent-org-buffer-set-status buf :title "Refactor the parser")
      (should (equal "latetitle:ao-proj [sid-l]" (buffer-name buf)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-buffer-name-keeps-a-multiline-title-out ()
  "Agent free text cannot reach the name at all, so it cannot break it.
The name used to be built from a title and needed the one-line label
filter to survive it; now no agent text enters the name, which is the
stronger guarantee — a 200-character title with newlines in it leaves the
name exactly as the provider and project made it.  The filter still
matters for `#+TITLE:' and the turn heading, which DO carry agent text."
  (let ((default-directory ao--name-dir))
    (let ((buf (agent-org-buffer-create "multiline"))
          (long (concat "First line\n" (make-string 200 ?x) "\ntrailing")))
      (agent-org-buffer-set-status buf :session-id "sid-m" :title long)
      (with-current-buffer buf
        (should-not (string-match-p "\n" (buffer-name)))
        (should (equal "multiline:ao-proj [sid-m]" (buffer-name))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-buffer-name-does-not-accumulate-suffixes ()
  "Re-announcing the same facts is not a rename.
`generate-new-buffer-name' counts OUR OWN buffer when it already wears
that name, so an unconditional rename would walk
`Qoder:agent-org [s]<2><3><4>' over a session's lifetime — every status
update, of which a turn sends dozens."
  (let ((default-directory ao--name-dir))
    (let* ((pair (ao--make-test-session "churn"))
           (buf (car pair)))
      (dotimes (_ 5)
        (agent-org-buffer-set-status buf :session-id "sid-c"
          :title "Same Title")
        (agent-org-buffer-set-status buf :used 100 :size 200 :state 'streaming)
        (agent-org-buffer-set-status buf :state 'ready))
      (should (equal "churn:ao-proj [sid-c]" (buffer-name buf)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-buffer-names-stay-unique-per-session ()
  "Two chats of one harness in one project: the id separates them.
Same provider, same project, so before an id exists the wanted name
collides — and a collision must produce a live, distinct buffer rather
than clobbering the other.  Once both ids are in, the names are exact
again, which is the point of putting the id in the name."
  (let ((default-directory ao--name-dir))
    (let* ((a (ao--make-test-session "qoder"))
           (b (ao--make-test-session "qoder"))
           (bufa (car a))
           (bufb (car b)))
      ;; created in the same project with the same provider: the second
      ;; wanted name is taken, so it is uniquified, and it stays alive
      (should (equal "qoder:ao-proj" (buffer-name bufa)))
      (should (equal "qoder:ao-proj<2>" (buffer-name bufb)))
      (agent-org-buffer-set-status bufa :session-id "sid-1")
      (agent-org-buffer-set-status bufb :session-id "sid-2")
      (should (equal "qoder:ao-proj [sid-1]" (buffer-name bufa)))
      (should (equal "qoder:ao-proj [sid-2]" (buffer-name bufb)))
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
      ;; the answer lands INSIDE the quote block, and a streaming chunk keeps
      ;; no trailing space (the partial line is rewritten by the next chunk)
      (should (string-match-p "^ Hello" (buffer-string)))
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
in_progress→ONGOING, completed→COMPLETE, failed→FAILED), and the keyword is
the line's first word so the state reads the same here as it did on a
heading.  User orders: \"Tool calls should be inside :tool: drawers.\", then
\"use ONGOING|COMPLETE|FAILED keywords for tool call TODOs.\"
Org forbids headlines inside drawers (info \"(org) Drawers\"), so the
calls became DRAWER LINES, and the turn's headings belong to the
conversation alone: `**' is gone."
  (let ((buf (agent-org-buffer-create "tool")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool buf '((title . "read_file")
                                        (toolCallId . "tc1")
                                        (status . "in_progress")))
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (string-match-p "^  - ONGOING read_file$" text))
      (should (string-match-p "^:tool:$" text))
      (should (= 1 (ao--count-occurrences text "^:tool:$")))
      (should-not (string-match-p "^\\*\\* " text))
      ;; under the Agent heading, and closed: marker, line, :end:
      (should (apply #'ao--ordered text
                     (list "* Agent" ":tool:" "  - ONGOING read_file" ":end:"))))
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
      (should (string-match-p "^  - COMPLETE shell$" text))
      ;; the redraw replaced the line rather than adding one
      (should (= 1 (ao--count-occurrences text "^  - "))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-updates-rewrite-their-line-in-place ()
  "tool_call_update for a known id rewrites its line's keyword/title;
new ids append their own line, in the order the agent made the calls."
  (let ((buf (agent-org-buffer-create "toolup")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool buf '((title . "shell") (toolCallId . "tc1")
                                        (status . "pending")))
    (should (with-current-buffer buf
              (string-match-p "^  - TODO shell$" (buffer-string))))
    ;; update without a title must not downgrade it to "tool"
    (agent-org-buffer-insert-tool buf '((toolCallId . "tc1") (status . "completed")))
    (agent-org-buffer-insert-tool buf '((toolCallId . "tc2")))
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (= 2 (ao--count-occurrences text "^  - ")))
      (should (= 1 (ao--count-occurrences text "^  - COMPLETE shell$")))
      (should-not (string-match-p "TODO shell" text))
      (should (string-match-p "^  - TODO tool$" text))
      (should (apply #'ao--ordered text (list "  - COMPLETE shell" "  - TODO tool"))))
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
      (should (= 2 (ao--count-occurrences (buffer-string) "^  - ")))
      (should (string-match-p "^  - TODO ls -la" (buffer-string)))
      (should-not (string-match-p "^second line$" (buffer-string)))
      ;; cut, not merely re-wrapped
      (should-not (string-match-p (make-string 300 ?x) (buffer-string))))
    ;; and the pending→done rewrite still replaces one clean line
    (agent-org-buffer-insert-tool buf '((toolCallId . "tc1")
                                        (status . "completed")))
    (with-current-buffer buf
      (should (= 1 (ao--count-occurrences (buffer-string) "^\\*+ ")))
      (should (= 2 (ao--count-occurrences (buffer-string) "^  - ")))
      (should (string-match-p "^  - COMPLETE ls -la" (buffer-string)))
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
      (should (= 2 (ao--count-occurrences text "^  - ")))
      (should (= 1 (ao--count-occurrences text "^:tool:$")))
      (should (= 1 (ao--count-occurrences text "^:thinking:$")))
      (should (string-match-p "^  - TODO one$" text))
      (should (string-match-p "^  - COMPLETE two$" text))
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
                                   (re-search-forward "^  - TODO shell$")
                                   (point))))
      (should (invisible-p
               (save-excursion (goto-char (point-min))
                               (re-search-forward "^ a very long thought$")
                               (point)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-chat-buffer-refuses-orgs-startup-drawer-fold ()
  "Org's startup fold is off in a chat: WE decide which drawer is open.
`org-cycle-set-startup-visibility' -- what `org-mode' runs and what
`C-c C-k' with a prefix runs -- ends with
`(when org-cycle-hide-drawer-startup (org-cycle-hide-drawers (quote all)))'
(org-cycle.el:643), so one visibility cycle re-folds every board the
package just opened.  A default that an unrelated subsystem can take away
is not a default, so the variable goes buffer-local NIL here and stays t
for every other Org buffer."
  (let ((buf (agent-org-buffer-create "startfold")))
    (with-current-buffer buf
      (should-not org-hide-drawer-startup)
      (should (default-value 'org-hide-drawer-startup)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-board-opens-when-the-agent-adds-to-it ()
  "A board the agent is still writing to is never left collapsed.
Org re-hides drawers in the paths that are not gated by
`org-hide-drawer-startup' (a subtree move runs
`org-clean-visibility-after-subtree-move', org.el:7089), and any of them
can fold a turn's board behind the user.  The next tool update expands it:
the board is the live activity view, so a fold that is not the user's own
TAB on the heading does not survive new activity.  A `:thinking:' drawer
keeps the fold it has, because the package never re-folds what the user
opened.

WHICH board is opened is the newer half of the rule: the thought between the
two calls seals the first one (`agent-org-buffer--seal-tool-board'), so the
second call opens a NEW drawer at the end of the turn and the sealed one stays
folded.  Expanding live activity and preserving history are both wanted, and
with two boards they are no longer the same board."
  (let ((buf (agent-org-buffer-create "reopen")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool buf '((toolCallId . "tc1") (title . "shell")
                                         (status . "completed")))
    (agent-org-buffer-append-thought buf "a long thought\n")
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (org-cycle-hide-drawers 'all))
      ;; the premise: Org really did fold this turn's drawers
      (should (invisible-p (save-excursion (goto-char (point-min))
                                           (re-search-forward "^  - COMPLETE shell$")
                                           (point))))
      (agent-org-buffer-insert-tool buf '((toolCallId . "tc2") (title . "tree")
                                          (status . "pending")))
      ;; the live board is open again: this call is what the agent is doing now
      (should-not (invisible-p (save-excursion (goto-char (point-min))
                                               (re-search-forward "^  - TODO tree$")
                                               (point))))
      ;; the sealed board keeps the fold it was given -- it is history now, and
      ;; a user who wants it back presses TAB on it like any other drawer
      (should (invisible-p (save-excursion (goto-char (point-min))
                                           (re-search-forward "^  - COMPLETE shell$")
                                           (point))))
      (should (= 2 (ao--count-occurrences (buffer-string) "^:tool:$")))
      ;; thinking is not the activity view: the fold it was given stays
      (should (invisible-p (save-excursion (goto-char (point-min))
                                           (re-search-forward "^ a long thought$")
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
      ;; the lines carry no number, so what separates the two turns' `shell'
      ;; calls is their keyword -- and each turn owns its own drawer
      (should (= 1 (ao--count-occurrences (buffer-string) "^  - TODO shell$")))
      (should (= 1 (ao--count-occurrences (buffer-string) "^  - COMPLETE shell$")))
      (should (= 1 (ao--count-occurrences (buffer-string) "^  - TODO tree$")))
      ;; a merged turn would hold two lines, not three
      (should (= 3 (ao--count-occurrences (buffer-string) "^  - "))))
    (kill-buffer buf)))

;;;; Tool-call output, under its own line in the turn's ONE `:tool:' drawer

(defun ao--tool-text-block (text)
  "One ACP `content' item carrying TEXT, in the shape the wire sends.
The union is {type: \"content\", content: <ContentBlock>}, and a JSON
array parses to a VECTOR (`:object-type 'alist' turns objects into alists
of DOTTED pairs, arrays into nothing else), so a fixture with a list, or
with the inner block wrapped in one more pair of parens, tests a shape no
agent sends.  The same shape agent-shell's own tests pin."
  `((content . [((type . "content")
                 (content (type . "text") (text . ,text)))])))

(ert-deftest test-agent-org-tool-output-keeps-every-line-under-its-call ()
  "A multi-line result stays ONE item: every line at the content column.
User order: \"Tool call outputs belong to the same TODO headings.\"  The
board line and what the call printed are now the same item, so the indent is
the only thing that keeps line two from being read as line one's successor
call -- four columns, which is the item's content column this drawer uses
(`test-agent-org-tool-drawer-is-one-list-to-org' asks the parser about it).
A body line at column 2 would be a NEW item of the list, not a continuation."
  (let ((buf (agent-org-buffer-create "out1")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "tc1") (title . "shell") (status . "completed")
           ,@(ao--tool-text-block "total 42\ndrwxr-xr-x  khalid")))
    (let ((text (with-current-buffer buf (buffer-string))))
      ;; the status line reads keyword + title, and nothing numbers it
      (should (string-match-p "^  - COMPLETE shell$" text))
      (should (string-match-p "^    total 42$" text))
      (should (string-match-p "^    drwxr-xr-x  khalid$" text))
      ;; marker, item, body, closer -- all of it INSIDE the one drawer
      (should (apply #'ao--ordered text
                     (list ":tool:" "  - COMPLETE shell" "    total 42"
                           "    drwxr-xr-x  khalid" ":END:"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-board-lines-carry-no-number ()
  "Nothing on a tool line is a number: `- KEYWORD TITLE', full stop.
The `N.' existed only as the index into a per-call output drawer, and with
one drawer whose items ARE the calls an index is meaningless -- a call is
named by its title, and its output is right under it.
A number would also be a lie after a resume: replay rebuilds the record from
the updates the agent sends, and nothing guarantees the same count."
  (let ((buf (agent-org-buffer-create "ononum")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "tc1") (title . "one") (status . "pending")))
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "tc2") (title . "two") (status . "completed")))
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (= 1 (ao--count-occurrences text "^  - TODO one$")))
      (should (= 1 (ao--count-occurrences text "^  - COMPLETE two$")))
      (should-not (string-match-p "^- [A-Z]+ [0-9]+\\." text)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-output-falls-back-to-raw-output ()
  "No `content' blocks: `rawOutput.formatted_output' is the output.
Codex reports terminal output that way and leaves `content' empty, so
reading only the spec's field renders a completed shell call blank
(agent-shell does the same, for the same reason).  `rawOutput' itself is
agent-defined free JSON."
  (let ((buf (agent-org-buffer-create "outraw")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "tc1") (title . "ls") (status . "completed")
           (rawOutput . ((formatted_output . "stdout line\nstderr line\n")))))
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (= 1 (ao--count-occurrences text "^:tool:$")))
      (should (string-match-p "^    stdout line$" text))
      (should (string-match-p "^    stderr line$" text)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-output-ignores-a-non-string-raw-output ()
  "A `formatted_output' that is not text is no output at all.
`rawOutput' is whatever the agent felt like sending -- a number, an
object, a vector.  Printing `42' as if it were a shell result would be a
lie, and an item with an empty body is noise under a board that is meant to
be read at a glance, so the call gets its line and nothing else."
  (let ((buf (agent-org-buffer-create "outrawnum")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "tc1") (title . "ls") (status . "completed")
           (rawOutput . ((formatted_output . 42)))))
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (= 1 (ao--count-occurrences text "^  - COMPLETE ls$")))
      (should-not (string-match-p "^    " text))
      (should-not (string-match-p "42" text)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-output-names-a-block-it-cannot-render ()
  "Content we have no surface for is NAMED, never silently dropped.
agent-shell's rule, kept verbatim so a reader of either tool sees the same
hint: `[unsupported content: TYPE]'."
  (let ((buf (agent-org-buffer-create "outvid")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "tc1") (title . "screenshot") (status . "completed")
           (content . [((type . "content")
                        (content (type . "video") (uri . "file:///v.mp4")))])))
    (with-current-buffer buf
      (should (string-match-p "\\[unsupported content: video\\]"
                              (buffer-string))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-output-diff-block-shows-the-file-and-text ()
  "A `diff' block says which file and what it now holds.
ACP's second ToolCallContent shape is {type: \"diff\", path, newText}; an
agent editing a file reports the change this way, and \"edited
~/.bashrc\" with no body is the least useful sentence in the chat."
  (let ((buf (agent-org-buffer-create "outdiff")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "tc1") (title . "edit") (status . "completed")
           (content . [((type . "diff") (path . "/home/khalid/x.org")
                        (newText . "* new\n"))])))
    (with-current-buffer buf
      (let ((text (buffer-string)))
        (should (= 1 (ao--count-occurrences text "^:tool:$")))
        (should (string-match-p "^    diff /home/khalid/x.org$" text))
        (should (string-match-p "^    \\* new$" text))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-output-update-rewrites-its-body-in-place ()
  "A second update for the same call replaces its body, never adds one.
`tool_call_update' patches: the same id arrives again with a longer
output, then with the final one.  One call, one ITEM -- the rule the board
already followed for its line now covers the body too, because line and body
are the same item of the same drawer."
  (let ((buf (agent-org-buffer-create "outrepl")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "tc1") (title . "shell") (status . "in_progress")
           ,@(ao--tool-text-block "partial 42")))
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "tc1") (status . "completed")
           ,@(ao--tool-text-block "final 43")))
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (= 1 (ao--count-occurrences text "^:tool:$")))
      (should (= 1 (ao--count-occurrences text "^:end:$")))
      ;; the call is named ONCE, and it is a board line, not a second item
      (should (= 1 (ao--count-occurrences text "^  - COMPLETE shell$")))
      (should (= 1 (ao--count-occurrences text "^    final 43$")))
      (should-not (string-match-p "partial 42" text)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-output-travels-with-the-open-board ()
  "Output is visible, because it now shares the drawer that shows progress.
The bodies used to sit in a folded `:tool-output:' drawer -- agent-shell's
default (`agent-shell-tool-use-expand-by-default' nil) -- so that a turn of
six `cat's did not bury the reply.  Merging them into the board trades that
quiet for one place to read: ONE drawer, ONE fold state, and `:tool:' is
born OPEN because what the agent is doing now is what the user came to
watch.  The fold is still the affordance for a long body -- TAB on the turn,
and the whole board including its output folds away at once."
  (let ((buf (agent-org-buffer-create "outfold")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "tc1") (title . "shell") (status . "completed")
           ,@(ao--tool-text-block "a very long output")))
    (with-current-buffer buf
      (dolist (pattern (list "^  - COMPLETE shell$" "^    a very long output$"))
        (should-not (invisible-p
                     (save-excursion (goto-char (point-min))
                                     (re-search-forward pattern)
                                     (point))))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-output-cannot-break-the-drawer ()
  "Agent output is free text and may contain Org structure.  A line that
is `* heading' at column 0 ENDS the drawer for the parser (measured: the
whole `:tool:' drawer vanishes from `org-element-parse-buffer' and two
headlines appear), and a line that is `:END:' closes it early -- including
the lowercase and indented forms, which Org also accepts.  Tool output is
filed as-is in a drawer, and this agent reads Org files for a living, so
both shapes arrive routinely.  Hence: indent every line, and double the
colon of a bare `:END:'.  The body stays verbatim-readible, and the drawer
stays a drawer.  Since the output shares the BOARD with these lines, one more
escape rides on top of the guard's own space: the four-column indent that
makes the text an item's content rather than a sibling call."
  (let ((buf (agent-org-buffer-create "outhostile")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "tc1") (title . "read") (status . "completed")
           ,@(ao--tool-text-block
              "* a headline\nplain\n  :END:\n:PROPERTIES:\n:ID: x\n:END:")))
    (let ((text (with-current-buffer buf (buffer-string))))
      ;; one headline in the whole buffer: the turn's own
      (should (= 1 (ao--count-occurrences text "^\\*+ ")))
      (should (= 1 (ao--count-occurrences text "^:tool:$")))
      ;; the escaped forms, at the item's content column, plus the real closer
      (should (string-match-p "^    \\* a headline$" text))
      (should (string-match-p "^    ::END:$" text))
      ;; and the parser agrees: it sees the drawer, and no headline grew
      (with-current-buffer buf
        (let ((drawers nil) (heads 0))
          (org-element-map (org-element-parse-buffer) '(drawer headline)
            (lambda (e)
              (if (eq (car e) 'drawer)
                  (push (org-element-property :drawer-name e) drawers)
                (cl-incf heads))))
          (should (member "tool" drawers))
          (should (= 1 heads)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-thinking-drawer-survives-a-headline-line ()
  "The same guard covers `:thinking:', which has always had the hazard.
Extended thinking is markdown-flavoured prose: `* ' bullets and `:END:'
are normal characters in it.  One primitive protects every drawer the
stream writes, so a thought can no longer dissolve the drawer around it."
  (let ((buf (agent-org-buffer-create "thinhostile")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-thought buf "plan:\n* do this\n:END:\n")
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (= 1 (ao--count-occurrences text "^:thinking:$")))
      (should (= 1 (ao--count-occurrences text "^\\*+ ")))
      (should (string-match-p "^ ::END:$" text))
      (should (string-match-p "^ \\* do this$" text)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-output-skips-a-call-with-nothing-to-show ()
  "Every call gets a line; only calls that printed get a body.
Three calls, output on the third: the board has three items and exactly one
body line -- a call with nothing to say costs no blank indent, so the drawer
stays readable as a list of what happened rather than a list with holes."
  (let ((buf (agent-org-buffer-create "outnum")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool buf '((toolCallId . "a") (title . "one")
                                        (status . "pending")))
    (agent-org-buffer-insert-tool buf '((toolCallId . "b") (title . "two")
                                        (status . "pending")))
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "c") (title . "three") (status . "completed")
           ,@(ao--tool-text-block "third output")))
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (= 1 (ao--count-occurrences text "^:tool:$")))
      (should (= 1 (ao--count-occurrences text "^    \\S-")))
      (should (= 3 (ao--count-occurrences text "^  - ")))
      (should (string-match-p "^    third output$" text))
      (should (apply #'ao--ordered text
                     (list "  - TODO one" "  - TODO two" "  - COMPLETE three"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-output-is-this-turns-only ()
  "Each Agent turn owns its board, bodies included.
`agent-org-buffer--redraw-drawer' bounds its search to the current turn and
`agent-org-buffer--tools' is reset per turn, so turn two's output cannot
overwrite turn one's -- the per-turn reset
`test-agent-org-tool-state-resets-per-turn' pins for the lines, pinned here
for the bodies they carry, which now live in the same drawer and so need a
stronger check: two drawers, each holding its own turn's text."
  (let ((buf (agent-org-buffer-create "outturn")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "tcA") (title . "one") (status . "completed")
           ,@(ao--tool-text-block "first turn text")))
    (agent-org-buffer-end-agent-turn buf)
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "tcB") (title . "two") (status . "completed")
           ,@(ao--tool-text-block "second turn text")))
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (= 2 (ao--count-occurrences text "^:tool:$")))
      (should (= 2 (ao--count-occurrences text "^    \\S-")))
      (should (apply #'ao--ordered text
                     (list "  - COMPLETE one" "    first turn text"
                           "  - COMPLETE two" "    second turn text"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-call-with-no-content-gets-no-body ()
  "A call that never reports output costs the chat nothing.
`tool_call' arrives with a title and a status only -- the common case for
a call still running -- and its item is the one line.  An empty body would
be a blank indent under a keyword the reader is still waiting on."
  (let ((buf (agent-org-buffer-create "outnone")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool buf '((toolCallId . "tc1") (title . "ls")
                                        (status . "pending")))
    (agent-org-buffer-insert-tool buf '((toolCallId . "tc1") (status . "completed")))
    (with-current-buffer buf
      (let ((text (buffer-string)))
        (should (= 1 (ao--count-occurrences text "^:tool:$")))
        (should (= 1 (ao--count-occurrences text "^  - COMPLETE ls$")))
        (should-not (string-match-p "^    \\S-" text))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-output-sits-under-its-own-board-line ()
  "The output belongs to its call's TODO line, in the turn's ONE `:tool:' drawer.
The user's order, twice over: \"Tool call outputs belong to the same TODO
headings\", and before it \"Consecutive tool calls belong to a single
drawer.\"  A separate `:tool-output:' drawer was the first cut; it made a
reader scan the board then hunt the same title in a second drawer, and a
call's state and its result lived two places at once.  One drawer now holds
the line and, indented under it, what the call printed.  The list is
indented TWO columns and its body four, which is the shape the parser
accepts inside a drawer: measured with `org-element-parse-buffer' on a
buffer whose turn already has a headline, a col-0 item with a 2-column body
reported no list at all, while the indented form reports ONE plain-list with
two items and the drawer intact."
  (let ((buf (agent-org-buffer-create "join1")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "tc1") (title . "shell") (status . "completed")
           ,@(ao--tool-text-block "total 42")))
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (string-match-p "^  - COMPLETE shell$" text))
      (should (string-match-p "^    total 42$" text))
      ;; one drawer for both, and the second one is GONE
      (should (= 1 (ao--count-occurrences text "^:tool:$")))
      (should-not (string-match-p "^:tool-output:$" text))
      (should (apply #'ao--ordered text
                     (list ":tool:" "  - COMPLETE shell" "    total 42"
                           ":END:"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-drawer-is-one-list-to-org ()
  "The parser reads the merged board as ONE drawer holding ONE list of items.
This is the assertion that says the merge is legal Org and not merely
well-aligned text: an indented body stays inside its item, the drawer
survives `org-element-parse-buffer', and the turn keeps its ONE heading."
  (let ((buf (agent-org-buffer-create "join2")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "tc1") (title . "ls") (status . "completed")
           ,@(ao--tool-text-block "first body")))
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "tc2") (title . "pwd") (status . "completed")
           ,@(ao--tool-text-block "second body")))
    (should (apply #'ao--ordered
                   (with-current-buffer buf (buffer-string))
                   (list "  - COMPLETE ls" "    first body"
                         "  - COMPLETE pwd" "    second body")))
    (with-current-buffer buf
      (let ((drawers '()) (heads 0) (items 0) (lists 0))
        (org-element-map (org-element-parse-buffer)
            '(drawer headline item plain-list)
          (lambda (e)
            (cond ((eq (car e) 'drawer)
                   (push (org-element-property :drawer-name e) drawers))
                  ((eq (car e) 'headline) (cl-incf heads))
                  ((eq (car e) 'item) (cl-incf items))
                  ((eq (car e) 'plain-list) (cl-incf lists)))))
        (should (equal '("tool") (delete-dups drawers)))
        (should (= 1 heads))
        (should (= 1 lists))
        ;; two calls, two items: the bodies are their contents
        (should (= 2 items))))
    (kill-buffer buf)))

(defun ao--tool-drawer-bodies (text)
  "The body of every `:tool:' drawer in TEXT, in buffer order.
A drawer is the region between a `:tool:' line and the next `:end:' line, which
is how Org itself delimits one (info \"(org) Drawers\").  Reading the bodies out
of TEXT rather than off the buffer is what lets a test ask WHICH drawer a call
landed in -- the question `test-agent-org-tool-output-is-this-turns-only' asks
by counting markers, which cannot tell two same-worded calls apart."
  (let ((rest text) (bodies '()))
    (while (string-match "^:tool:$" rest)
      (let ((body-start (match-end 0)))
        (if (string-match "^:end:$" rest body-start)
            (progn
              (push (substring rest body-start (match-beginning 0)) bodies)
              (setq rest (substring rest (match-end 0))))
          (setq rest nil))))
    (nreverse bodies)))

(ert-deftest test-agent-org-tool-board-opens-a-new-drawer-after-activity ()
  "A tool call after the agent has spoken or thought opens a NEW `:tool:' drawer.
The user's order: \"Activity order MUST be kept.  New :tool: calls should always
appear at the end of response, not a previous drawer.\"  Before this the board
was created once per turn and every later call was repainted into it, so a call
made after the agent had moved on was displayed ABOVE the words and thoughts
that came before it -- the transcript read the turn backwards.  What separates
two runs of calls is any NON-tool activity, which is the user's own earlier
rule: \"The order of tool call and response/thinking separates them.  Activity
order gets precedence.\"

So the turn keeps ONE record (`agent-org-buffer--tools', in call order) and the
drawer is a WINDOW on it: thinking or a reply seals the open drawer, and the
next call starts a fresh one below everything written since.  Each drawer holds
only the calls that ran while it was the live one."
  (let ((buf (agent-org-buffer-create "act1")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "tc1") (title . "first") (status . "completed")
           ,@(ao--tool-text-block "first body")))
    (agent-org-buffer-append-thought buf "weighing the options")
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "tc2") (title . "second") (status . "completed")
           ,@(ao--tool-text-block "second body")))
    (let* ((text (with-current-buffer buf (buffer-string)))
           (bodies (ao--tool-drawer-bodies text)))
      (should (= 2 (length bodies)))
      ;; each drawer holds exactly its own call, body included
      (should (string-match-p "COMPLETE first" (car bodies)))
      (should (string-match-p "first body" (car bodies)))
      (should-not (string-match-p "second" (car bodies)))
      (should (string-match-p "COMPLETE second" (cadr bodies)))
      (should (string-match-p "second body" (cadr bodies)))
      (should-not (string-match-p "first" (cadr bodies)))
      ;; and the new drawer sits at the END of the turn, below the thought
      (should (apply #'ao--ordered text
                     (list "COMPLETE first" "weighing the options"
                           "COMPLETE second"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-board-reply-also-starts-a-new-drawer ()
  "Reply text separates two runs of calls exactly as thinking does.
`agent-org-buffer-append-thought' is not the only thing that closes the open
board: an answer chunk is the same kind of evidence that the agent moved on, and
it is the commoner -- text streams, a tool runs, more text streams.  Pinned
separately because the two call sites are two lines of code in two functions,
and a fix that sealed on thinking alone would leave this case still repainting
backwards.

The order asserted is the order this architecture can actually hold, and the
difference from the thinking case is worth stating rather than papering over: a
turn's whole reply is ONE quote block, opened before anything else and closed at
`#+end_quote', and the drawers live BELOW that line.  So reply text can never sit
between two drawers -- it is always above them -- and the rule the user asked
for still holds in the only direction that matters: the new drawer is at the END
of the response, after the drawer of the calls that ran before it."
  (let ((buf (agent-org-buffer-create "act2")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "tc1") (title . "ls") (status . "completed")
           ,@(ao--tool-text-block "a.org")))
    (agent-org-buffer-append-chunk buf "now I will check the tests" nil)
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "tc2") (title . "grep") (status . "completed")
           ,@(ao--tool-text-block "b.org")))
    (let* ((text (with-current-buffer buf (buffer-string)))
           (bodies (ao--tool-drawer-bodies text)))
      (should (= 2 (length bodies)))
      (should-not (string-match-p "grep" (car bodies)))
      (should-not (string-match-p "ls" (cadr bodies)))
      (should (apply #'ao--ordered text
                     (list "now I will check the tests" "COMPLETE ls"
                           "COMPLETE grep"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-unfinished-call-is-not-sealed-away ()
  "A call that is still running keeps the live drawer, so its completion is seen.
This is the trap the window has to avoid: `in_progress' and `pending' calls WILL
report again, usually after the agent has said or thought something in between.
Sealing past one would take it out of the drawer the reader is watching, and the
`completed' update that follows would have no drawer to render in -- the call
would stay TODO for the rest of the turn.  So the seal waits for the whole live
run to be terminal, which is also why this turn keeps ONE drawer despite three
interleaved thoughts."
  (let ((buf (agent-org-buffer-create "act5")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "tc1") (title . "one") (status . "in_progress")))
    (agent-org-buffer-append-thought buf "hmm")
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "tc1") (title . "one") (status . "completed")))
    (let* ((text (with-current-buffer buf (buffer-string)))
           (bodies (ao--tool-drawer-bodies text)))
      (should (= 1 (length bodies)))
      (should (string-match-p "COMPLETE one" (car bodies)))
      ;; the completion was painted in the SAME drawer the call started in
      (should-not (string-match-p "TODO one" text)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-consecutive-tool-calls-share-one-drawer ()
  "Consecutive calls keep ONE drawer -- activity order must not overshoot.
The user's other order: \"Consecutive tool calls belong to a single drawer.\"  A
fix that opened a drawer per CALL would satisfy the previous test and break
this one, and the transcript would grow a drawer per tool call: the exact noise
\"Consecutive tool calls belong to a single drawer\" was given to stop."
  (let ((buf (agent-org-buffer-create "act3")))
    (agent-org-buffer-start-agent-turn buf nil)
    (dolist (id '("tc1" "tc2" "tc3"))
      (agent-org-buffer-insert-tool
       buf `((toolCallId . ,id) (title . ,id) (status . "completed"))))
    (let ((bodies (ao--tool-drawer-bodies (with-current-buffer buf (buffer-string)))))
      (should (= 1 (length bodies)))
      (should (string-match-p "COMPLETE tc1" (car bodies)))
      (should (string-match-p "COMPLETE tc2" (car bodies)))
      (should (string-match-p "COMPLETE tc3" (car bodies))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-activity-before-any-call-opens-no-empty-drawer ()
  "Thinking before the first call must not leave an empty `:tool:' drawer behind.
Sealing an EMPTY window is a no-op, and this is where that rule is visible: the
agent usually thinks before its first tool call, so sealing on thought and then
opening on the next call must produce ONE drawer -- the call's -- at the end of
the turn.  A seal that started a new group unconditionally would put an empty
`:tool:'/`\\n:END:' pair above it."
  (let ((buf (agent-org-buffer-create "act4")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-thought buf "planning the first command")
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "tc1") (title . "only") (status . "completed")))
    (let ((bodies (ao--tool-drawer-bodies (with-current-buffer buf (buffer-string)))))
      (should (= 1 (length bodies)))
      (should (string-match-p "COMPLETE only" (car bodies)))
      (should-not (string-match-p "^\\s-*$\\s-*" (car bodies))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-keywords-are-ongoing-complete-failed ()
  "The board's vocabulary is the user's: ONGOING, COMPLETE, FAILED.
`pending' keeps Org's own TODO, the state before the call runs, and the word
every Org reader already understands.  The DOING/DONE/CANCELLED triad is
gone -- and `DONE' with it, which in a file that declares COMPLETE as its
done state would be a keyword the file does not know.  Asserted together
with the `#+TODO:' line, because a keyword on a board line the file has not
declared is text pretending to be a state."
  (let ((buf (agent-org-buffer-create "kw3")))
    (agent-org-buffer-start-agent-turn buf nil)
    (dolist (pair '(("pending" . "TODO")
                    ("in_progress" . "ONGOING")
                    ("completed" . "COMPLETE")
                    ("failed" . "FAILED")))
      (should (equal (cdr pair)
                     (agent-org-buffer--tool-keyword (car pair)))))
    (dolist (pair '(("tc1" . "pending") ("tc2" . "in_progress")
                    ("tc3" . "completed") ("tc4" . "failed")))
      (agent-org-buffer-insert-tool buf `((toolCallId . ,(car pair))
                                          (title . ,(car pair))
                                          (status . ,(cdr pair)))))
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (= 1 (ao--count-occurrences text "^  - TODO tc1$")))
      (should (= 1 (ao--count-occurrences text "^  - ONGOING tc2$")))
      (should (= 1 (ao--count-occurrences text "^  - COMPLETE tc3$")))
      (should (= 1 (ao--count-occurrences text "^  - FAILED tc4$")))
      (should-not (string-match-p "^  - \\(DOING\\|DONE\\|CANCELLED\\) " text))
      ;; and the file declares exactly that set, done states last
      (should (string-match-p "^#\\+TODO: NEXT WAIT TODO ONGOING | COMPLETE FAILED$"
                             text)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-drawer-redraws-once-per-change ()
  "One board means one redraw guard: an update that changes nothing paints nothing.
With the bodies inside the board, a status-only update would otherwise
rewrite and re-protect every byte the turn's calls ever printed -- the cost
`test-agent-org-one-drawer-board-redraw-cost' measures.  So `:shown' moved from
per-entry to the whole rendered board (`agent-org-buffer--tools-shown'):
the guard asks whether the DRAWER would come out the same, which is exactly
what it must not do twice."
  (let ((buf (agent-org-buffer-create "guard4"))
        (paints 0)
        (orig (symbol-function 'agent-org-buffer--redraw-drawer)))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "tc1") (title . "shell") (status . "completed")
           ,@(ao--tool-text-block "total 42")))
    (cl-letf (((symbol-function 'agent-org-buffer--redraw-drawer)
               (lambda (buffer name lines &optional fold fresh)
                 (cl-incf paints)
                 (funcall orig buffer name lines fold fresh))))
      ;; identical re-delivery: same title, same status, same output
      (agent-org-buffer-insert-tool
       buf `((toolCallId . "tc1") (title . "shell") (status . "completed")
             ,@(ao--tool-text-block "total 42")))
      (should (= 0 paints))
      ;; a keyword change IS a change, and it repaints the ONE drawer
      (agent-org-buffer-insert-tool buf '((toolCallId . "tc1") (status . "failed")))
      (should (= 1 paints)))
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (= 1 (ao--count-occurrences text "^:tool:$")))
      (should (= 1 (ao--count-occurrences text "^    total 42$")))
      (should (string-match-p "^  - FAILED shell$" text)))
    ;; the guard is per turn, not global: turn two starts empty
    (agent-org-buffer-end-agent-turn buf)
    (agent-org-buffer-start-agent-turn buf nil)
    (should (null (buffer-local-value 'agent-org-buffer--tools-shown buf)))
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
      (let ((before (buffer-string)))
        (should-error
         (let ((last-command-event ?x))
           (funcall #'self-insert-command 1))
         :type 'text-read-only)
        (should (= (point) (point-min)))
        ;; the refused keystroke changed nothing — comparing the whole buffer
        ;; beats searching for "x", which case-fold-search would match against
        ;; the `X' in the quote block's `#+ATTR_TEXINFO' line
        (should (equal before (buffer-string)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-insert-prompt-escapes-frozen-point ()
  "With point trapped on frozen text, opening a box takes point to it.
The box-free state this reconstructs is a replay mid-paint: turns render
at `point-max' until the session is ready and the type-ahead box opens."
  (let ((buf (agent-org-buffer-create "escape")))
    (with-current-buffer buf
      (agent-org-buffer-begin-exchange buf "Hi")
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

;;;; Mode line: `which-function-mode' must survive our read-only text

(ert-deftest test-agent-org-which-function-answers-property-free ()
  "The heading handed to `which-function' carries no text properties.
`which-func-format' shows whatever `which-function' returns, and it shows
it by APPLYING a face: `(:propertize which-func-current …)'.  Applying a
property to text that carries `read-only' is a modification, so Emacs
signals `text-read-only' -- inside `format-mode-line'.  doom-modeline builds
its whole right-hand side in one such call, so one read-only heading blanks
the entire bar (the user's \"doom-modeline is still blank!\").  Org's own
`add-log-current-defun-function' answers with `buffer-substring', which
copies properties: in a chat buffer that string is our protected heading
line, `read-only' and all."
  (let ((buf (agent-org-buffer-create "whichfunc")))
    (with-current-buffer buf
      (agent-org-buffer-insert-prompt buf)
      (should (functionp add-log-current-defun-function))
      (save-excursion
        (goto-char (point-min))
        (re-search-forward "^\\* User$")
        (let ((name (funcall add-log-current-defun-function)))
          (should (equal "User" name))
          (should-not (get-text-property 0 'read-only name))
          ;; and it is genuinely faceable: this is the call that used to
          ;; raise `text-read-only' during mode-line construction
          (should
           (not (condition-case nil
                    (progn (add-face-text-property 0 (length name) 'mode-line t name)
                           nil)
                  (error t)))))
      ;; the protection itself is untouched: only the copy is clean, so
      ;; the heading is still untypeable
      (save-excursion
        (goto-char (point-min))
        (re-search-forward "^\\* User$")
        (should (get-text-property (point) 'read-only)))))
    ;; and turning the mode off gives the buffer back Org's own answer
    (with-current-buffer buf
      (agent-org-mode -1)
      (should-not (local-variable-p 'add-log-current-defun-function)))
    (kill-buffer buf)))

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
    (agent-org-buffer-begin-exchange buf "next question")
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

;;;; Permission prompt: real ACP option shape

(defun ao--permission-request (options)
  "A `session/request_permission' carrying OPTIONS, shaped as the wire sends it.
A permission is always about a tool call, which is what OpenCode and
MiniMax actually send."
  `((method . "session/request_permission")
    (id . 7)
    (params . ((options . ,options)
               (toolCall . ((toolCallId . "t1")
                            (title . "run ls")
                            (status . "pending")))))))

(ert-deftest test-agent-org-permission-prompt-offers-option-names ()
  "The prompt lists each option's `name' and answers with its `optionId'.

A PermissionOption is (optionId, name, kind); the first reader here asked
for `label' and `id', keys no agent ever sends, so both reads answered
nil and the dialog was one `nil' candidate beside our own Cancel.
COMPLETING-READ is stubbed, NOT the prompter: stubbing the prompter is
how that shipped with a green suite."
  (let* ((buf (agent-org-buffer-create "perm-names"))
         (session (list :name 'test :client nil :buffer buf :session-id "s"))
         (collection nil)
         (made nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt coll &rest _args)
                 (setq collection coll)
                 "Allow once"))
              ((symbol-function 'acp-make-session-request-permission-response)
               (lambda (&rest kw) (push kw made) kw))
              ((symbol-function 'acp-send-response)
               (lambda (&rest _args) nil)))
      (agent-org--on-request
       session
       (ao--permission-request
        `(((optionId . "allow_once") (name . "Allow once") (kind . "allow_once"))
          ((optionId . "reject_once") (name . "Reject once") (kind . "reject_once")))))
      (should (equal '("Allow once" "Reject once" "Cancel") collection))
      (should-not (seq-contains-p collection nil))
      (let ((kw (car made)))
        (should (equal "allow_once" (plist-get kw :option-id)))
        (should-not (plist-member kw :cancelled)))
      ;; the awaiting status belongs to the request, not the answer
      (with-current-buffer buf
        (should (eq 'starting (plist-get agent-org-buffer--status :state)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-permission-cancel-entry-sends-cancelled ()
  "The Cancel entry answers `cancelled' -- and never a nil option id."
  (let* ((buf (agent-org-buffer-create "perm-cancel"))
         (session (list :name 'test :client nil :buffer buf :session-id "s"))
         (made nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt _coll &rest _args) "Cancel"))
              ((symbol-function 'acp-make-session-request-permission-response)
               (lambda (&rest kw) (push kw made) kw))
              ((symbol-function 'acp-send-response)
               (lambda (&rest _args) nil)))
      (agent-org--on-request
       session
       (ao--permission-request
        `(((optionId . "allow_once") (name . "Allow once") (kind . "allow_once")))))
      (let ((kw (car made)))
        (should (plist-get kw :cancelled))
        (should-not (plist-member kw :option-id))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-permission-option-without-name-shows-its-id ()
  "An option carrying no `name' still reads as something: its `optionId'.
An agent is not obliged to name its options; a blank candidate is not an
answer a person can pick."
  (let* ((buf (agent-org-buffer-create "perm-noname"))
         (session (list :name 'test :client nil :buffer buf :session-id "s"))
         (collection nil)
         (made nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt coll &rest _args)
                 (setq collection coll)
                 (car coll)))
              ((symbol-function 'acp-make-session-request-permission-response)
               (lambda (&rest kw) (push kw made) kw))
              ((symbol-function 'acp-send-response)
               (lambda (&rest _args) nil)))
      (agent-org--on-request
       session
       (ao--permission-request
        `(((optionId . "approve-3") (kind . "allow_once")))))
      (should (equal '("approve-3" "Cancel") collection))
      (should (equal "approve-3" (plist-get (car made) :option-id))))
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

(ert-deftest test-agent-org-send-echoes-the-prompt-as-its-heading-above-a-persistent-box ()
  "Sending freezes the draft into its own heading above the box; the box
survives the send open and empty, so the next prompt is typeable at once
(agent-shell's persistent-prompt UX).  The sent question is no longer body
text under a generic `* User': it IS the heading now."
  (let* ((pair (ao--make-test-session "send"))
         (buf (car pair))
         (session (cdr pair)))
    (cl-letf (((symbol-function 'acp-send-request) (lambda (&rest _args) nil)))
      (with-current-buffer buf
        (agent-org-buffer-insert-prompt buf)
        (ao--type "Hi")
        (agent-org-send)
        (should (= 1 (ao--count-substrings "* User"))) ; only the box remains
        (should (= 1 (ao--count-substrings "* Hi")))   ; the prompt is the heading
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
                             ":thinking:" ":tool:" "  - TODO shell"
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
        (should (= 1 (ao--count-substrings "* User"))) ; the box, not a second one
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
      (agent-org-buffer-begin-exchange buf "already sent")
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
The drained text is rendered as its own exchange heading above the
still-open type-ahead box before it goes on the wire; the queue
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
        (should (string-match-p "^\\* two$" (buffer-string))))
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
        ;; three exchange headings (one/two/three) and ONE persistent box
        (should (= 1 (ao--count-substrings "* User")))
        (should (= 1 (ao--count-substrings "* one")))
        (should (= 1 (ao--count-substrings "* two")))
        (should (= 1 (ao--count-substrings "* three")))
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
        (should (string-match-p "^\\* queued$" (buffer-string)))
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

;;;; The queue, edited where it is read: `* NEXT'/`* WAIT' at the buffer end

(defun ao--queued (prompts)
  "A test session whose queue is PROMPTS, with the entries rendered.
Returns (CHAT . SESSION).  The refresh is the real one, so the entries, the
`:QUEUE:' drawer and the transcript all stand where a live enqueue would
leave them -- these tests are about the shape the user edits, not about a
renderer called directly."
  (let* ((pair (ao--make-test-session "queue"))
         (chat (car pair))
         (session (cdr pair)))
    (setf (plist-get session :pending-prompts) prompts)
    (agent-org--queue-refresh session chat)
    (cons chat session)))

(defun ao--queue-headings ()
  "This chat buffer's queue entry headlines, as strings, top to bottom."
  (with-current-buffer (current-buffer)
    (mapcar (lambda (at)
              (save-excursion (goto-char at) (buffer-substring-no-properties
                                              (point) (line-end-position))))
            (agent-org-buffer--queue-headlines))))

(ert-deftest test-agent-org-queue-entries-sit-at-the-buffer-bottom ()
  "The waiting prompts are `* NEXT'/`* WAIT' headings between the last exchange
and the live `* User' box -- not in a drawer at the top, and not after the box.
The user asked for them at the bottom and for the box to stay the last
thing they type in, so the order is exchange, then entries, then box."
  (let* ((pair (ao--make-test-session "q-place"))
         (buf (car pair)))
    (unwind-protect
        (with-current-buffer buf
          (agent-org-buffer-insert-prompt buf)
          (setf (plist-get (cdr pair) :pending-prompts) '("first" "second"))
          (agent-org--queue-refresh (cdr pair) buf)
          (let ((text (buffer-string)))
            (should (apply #'ao--ordered text
                           (list "* NEXT first" "* WAIT second" "* User")))
            (should (string-match-p "^\\* NEXT first$" text))
            (should (string-match-p "^\\* WAIT second$" text))
            ;; and the file DECLARES both words, which is what makes them
            ;; states rather than text (the live set is Org's own business:
            ;; `org-todo-keywords-1' lives in org-agenda.el)
            (should (string-match-p "^#\\+TODO: NEXT WAIT " text))
            (should (agent-org-buffer--todo-live-p))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-queue-round-trips-every-entry ()
  "Render then parse: each waiting prompt comes back byte-identical.
The renderer puts ONE space in front of every body line, so a prompt whose
own line begins with `*' cannot become a headline of the chat and be read as
a boundary; the parser removes exactly that one space again.  An entry is
everything from its headline to the next, so a prompt keeps its blank lines."
  (let* ((prompts (list "plain one"
                        "two\nlines\n  indented\n* star at column 0"
                        ":END: here\n\nand a blank line above"))
         (pair (ao--queued prompts)))
    (with-current-buffer (car pair)
      (should (equal prompts (agent-org-buffer-queue-parse nil)))
      ;; and only the entries are entries: three prompts, three headlines,
      ;; even though one of them is about Org drawers
      (should (= 3 (length (agent-org-buffer--queue-headlines)))))
    (kill-buffer (car pair))))

(ert-deftest test-agent-org-queue-parse-is-confined-to-the-region ()
  "Only NEXT and WAIT lines are entries, and only inside the region.
An agent's answer can contain anything, and a turn's own heading is the user's
prompt: neither may be read as a queued prompt, or a resume would send the
conversation back at the agent."
  (let* ((pair (ao--make-test-session "q-region"))
         (buf (car pair)))
    (unwind-protect
        (with-current-buffer buf
          (agent-org-buffer-insert-prompt buf)
          (setf (plist-get (cdr pair) :pending-prompts) '("waiting"))
          (agent-org--queue-refresh (cdr pair) buf)
          (agent-org-buffer-begin-exchange buf "a question about * NEXT text")
          (agent-org-buffer-insert-tool
           buf '((toolCallId . "t1") (title . "run * WAIT now") (status . "pending")))
          (should (equal '("waiting") (agent-org-buffer-queue-parse nil))))
      (kill-buffer (car pair)))))

(ert-deftest test-agent-org-queue-move-reorders-and-restates-the-words ()
  "M-DOWN moves an entry, and the words are re-derived from the new order.
A heading that kept its old keyword after a move would promise a place in the
send order it no longer has: the entry that moves up is now the one that goes
out next, so it must SAY so."
  (let ((pair (ao--queued '("one" "two" "three"))))
    (with-current-buffer (car pair)
      (should (equal '("* NEXT one" "* WAIT two" "* WAIT three")
                     (ao--queue-headings)))
      (goto-char (point-min))
      (search-forward "* NEXT one")
      (agent-org-buffer-queue-move-down)
      (should (equal '("two" "one" "three") (agent-org-buffer-queue-parse nil)))
      (should (equal '("* NEXT two" "* WAIT one" "* WAIT three")
                     (ao--queue-headings)))
      ;; and the moved entry is the one that would go out next
      (goto-char (point-min))
      (search-forward "* WAIT three")
      (agent-org-buffer-queue-move-up)
      (should (equal '("two" "three" "one") (agent-org-buffer-queue-parse nil)))
      (should (equal '("* NEXT two" "* WAIT three" "* WAIT one")
                     (ao--queue-headings))))
    (kill-buffer (car pair))))

(ert-deftest test-agent-org-queue-move-is-refused-outside-the-region ()
  "M-UP in the CONVERSATION is still the blocker: a chat body is not re-orderable.
The narrowing is by point, not a lifted block, so the conversation's heading
boundaries -- what locates every turn -- stay untouchable."
  (let ((pair (ao--queued '("one" "two"))))
    (with-current-buffer (car pair)
      (goto-char (point-min))
      (should-error (agent-org-buffer-queue-move-up) :type 'user-error)
      ;; the command form too: point is not in the region, so it refuses
      (goto-char (point-min))
      (should-error (agent-org-buffer-queue-move-up) :type 'user-error))
    (kill-buffer (car pair))))

(ert-deftest test-agent-org-queue-add-makes-a-slot-at-the-bottom ()
  "C-c C-a appends a blank `* WAIT' entry and lands point in it.
A blank entry is dropped on parse, so composing one cannot send a blank -- and
the word is WAIT whatever the queue holds, because a new entry is last and
cannot be the next to go out."
  (let ((pair (ao--queued '("one"))))
    (with-current-buffer (car pair)
      (agent-org-buffer-queue-add)
      (should (equal '("* NEXT one" "* WAIT ") (ao--queue-headings)))
      (should (equal '("one") (agent-org-buffer-queue-parse nil)))
      ;; typing into the slot makes it an entry, still last
      (end-of-line)
      (insert "another")
      (should (equal '("one" "another") (agent-org-buffer-queue-parse nil))))
    (kill-buffer (car pair))))

(ert-deftest test-agent-org-queue-kill-removes-one-entry ()
  "C-c C-d kills the entry at point and the rest keep their order.
The words are re-stated after the kill, so the new head wears NEXT."
  (let ((pair (ao--queued '("one" "two" "three"))))
    (with-current-buffer (car pair)
      (goto-char (point-min))
      (search-forward "* WAIT two")
      (agent-org-buffer-queue-kill)
      (should (equal '("one" "three") (agent-org-buffer-queue-parse nil)))
      (should (equal '("* NEXT one" "* WAIT three") (ao--queue-headings))))
    (kill-buffer (car pair))))

(ert-deftest test-agent-org-queue-refresh-is-idempotent ()
  "Re-rendering the same queue leaves one copy of every entry.
The region is delete-then-insert between two markers, so a refresh at a turn
boundary cannot append a second `* NEXT' -- the failure mode a reader would
see as a prompt sent twice."
  (let* ((pair (ao--queued '("one" "two")))
         (chat (car pair))
         (session (cdr pair)))
    (dotimes (_ 3)
      (agent-org--queue-refresh session chat))
    (with-current-buffer chat
      (should (equal '("one" "two") (agent-org-buffer-queue-parse nil)))
      (should (= 1 (ao--count-occurrences (buffer-string) "^\\* NEXT one$"))))
    (kill-buffer chat)))

(ert-deftest test-agent-org-queue-refresh-never-lands-after-the-box ()
  "The entries stay ABOVE the live box, even when a queue arrives mid-turn.
`--render-end' answers with the queue's own start marker, so a turn rendered
while a queue waits lands above the queue and the box stays last."
  (let* ((pair (ao--make-test-session "q-anchor"))
         (buf (car pair))
         (session (cdr pair)))
    (unwind-protect
        (with-current-buffer buf
          (agent-org-buffer-insert-prompt buf)
          (setf (plist-get session :pending-prompts) '("waiting"))
          (agent-org--queue-refresh session buf)
          ;; the user typed a draft, and a turn renders above the queue
          (goto-char (point-max))
          (insert "draft")
          (agent-org-buffer-append-thought buf "thinking")
          (should (apply #'ao--ordered (buffer-string)
                         (list "* NEXT waiting" "* User"))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-queue-drain-promotes-the-next-word ()
  "When a queued prompt goes out, the one behind it takes the NEXT word.
The word is the send order, so it has to follow the list rather than travel
with the entry: the entry the user did not touch is now the one that goes
out next."
  (let* ((pair (ao--make-test-session "q-drain-word"))
         (buf (car pair))
         (session (cdr pair))
         (sent nil))
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest kw) (push kw sent)))
              ((symbol-function 'acp-make-session-prompt-request)
               (lambda (&rest a) (plist-get a :prompt))))
      (setf (plist-get session :pending-prompts) '("first" "second"))
      (agent-org--queue-refresh session buf)
      (with-current-buffer buf
        (agent-org-buffer-insert-prompt buf)
        (agent-org--drain-queue session buf)
        (should (equal '("second") (agent-org-buffer-queue-parse nil)))
        (should (equal '("* NEXT second") (ao--queue-headings)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-queue-refresh-never-undoes-a-move ()
  "A re-order survives the next refresh, because the BASELINE is what moves.
The obvious fix --- re-state `--queue-shown' after a move so the region looks
touched --- is the bug: then the region reads as unedited again and the next
refresh paints the session's old order straight back over the user's gesture."
  (let* ((pair (ao--queued '("one" "two")))
         (chat (car pair))
         (session (cdr pair)))
    (with-current-buffer chat
      (goto-char (point-min))
      (search-forward "* NEXT one")
      (agent-org-buffer-queue-move-down)
      (should (equal '("two" "one") (agent-org-buffer-queue-parse nil)))
    ;; a refresh with a queue the session still thinks is the old one
    (agent-org--queue-refresh session chat)
    (with-current-buffer chat
      (should (equal '("two" "one") (agent-org-buffer-queue-parse nil)))
      (should (equal '("* NEXT two" "* WAIT one") (ao--queue-headings))))
    ;; and applying is what makes the session agree
    (with-current-buffer chat
      (agent-org-queue-apply))
    (should (equal '("two" "one") (plist-get session :pending-prompts)))
    (kill-buffer chat))))

(ert-deftest test-agent-org-queue-refresh-keeps-a-fresh-slot ()
  "A blank `* WAIT' slot in an EMPTY queue is not clobbered by a refresh.
The parser drops a blank entry, so a guard that compared parsed lists would
call this region untouched --- and a prompt queued a moment later would delete
the half-typed prompt in it.  The guard compares raw TEXT for exactly this."
  (let* ((pair (ao--make-test-session "q-slot"))
         (buf (car pair)))
    (unwind-protect
        (with-current-buffer buf
          (agent-org-queue-edit)
          (should (equal '("* WAIT ") (ao--queue-headings)))
          (insert "half-typed")
          ;; the session gains a prompt while the slot is being typed
          (setf (plist-get (cdr pair) :pending-prompts) '("from the box"))
          (agent-org--queue-refresh (cdr pair) buf)
          (should (equal '("half-typed")
                         (agent-org-buffer-queue-parse buf))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-queue-refresh-leaves-an-edit-alone ()
  "A queue that changes while the user is editing is NOT repainted over him.
The region is the user's text: a drain that arrives mid-edit would otherwise
delete a half-typed prompt.  So a repaint happens only while the region still
reads as what was last written into it."
  (let* ((pair (ao--queued '("one" "two")))
         (chat (car pair))
         (session (cdr pair)))
    (with-current-buffer chat
      (goto-char (point-min))
      (search-forward "* NEXT one")
      (end-of-line)
      (insert " -- edited"))
    ;; the session's list moved on while the user was typing
    (setf (plist-get session :pending-prompts) '("two"))
    (agent-org--queue-refresh session chat)
    (with-current-buffer chat
      (should (equal '("one -- edited" "two")
                     (agent-org-buffer-queue-parse nil)))
      (should (string-match-p "^\\* NEXT one -- edited$" (buffer-string))))
    (kill-buffer chat)))

(ert-deftest test-agent-org-queue-apply-drops-what-the-agent-already-sent ()
  "A prompt that went out mid-edit is removed BY TEXT on apply.
By position it would be wrong twice over: the user may have moved that entry
anywhere, and the drain took the front of the SESSION's list."
  (let* ((pair (ao--queued '("one" "two")))
         (chat (car pair))
         (session (cdr pair)))
    (with-current-buffer chat
      ;; the agent answers, so "one" goes out and the queue holds "two"
      (setf (plist-get session :pending-prompts) '("two"))
      (agent-org-buffer-begin-exchange chat "one")
      (agent-org--queue-note chat 'agent-org-buffer--queue-sent "one")
      ;; and the region still shows both, with the user's re-ordering
      (goto-char (point-min))
      (search-forward "* WAIT two")
      (agent-org-buffer-queue-move-up))
    (with-current-buffer chat
      (agent-org-queue-apply))
    ;; the entry the user moved UP is still the prompt the agent took, so the
    ;; queue is what is left: one prompt, and it is the one that waited
    (should (equal '("two") (plist-get session :pending-prompts)))
    (kill-buffer chat)))

(ert-deftest test-agent-org-queue-apply-keeps-what-arrived-mid-edit ()
  "A prompt typed into the box mid-edit goes back at the END on apply.
The region never showed it, so an apply that wrote the region's contents
verbatim would overwrite it away -- a queue entry the user paid for."
  (let* ((pair (ao--queued '("one")))
         (chat (car pair))
         (session (cdr pair)))
    (setf (plist-get session :pending-prompts) '("one" "fresh"))
    (agent-org--queue-note chat 'agent-org-buffer--queue-added "fresh")
    (with-current-buffer chat
      (goto-char (point-min))
      (search-forward "* NEXT one")
      (end-of-line)
      (insert " -- edited"))
    (with-current-buffer chat
      (agent-org-queue-apply))
    (should (equal '("one -- edited" "fresh") (plist-get session :pending-prompts)))
    (kill-buffer chat)))

(ert-deftest test-agent-org-queue-edit-goes-to-the-entries ()
  "C-c C-q puts point on the waiting prompts, and makes one when there are none.
An empty queue is not an error and not a no-op: a blank `* WAIT' slot is where
the next thing to ask gets written, and it is dropped on apply if left empty."
  (let* ((pair (ao--make-test-session "q-edit"))
         (buf (car pair)))
    (unwind-protect
        (with-current-buffer buf
          (should-not (agent-org-buffer-queue-p buf))
          (agent-org-queue-edit)
          (should (agent-org-buffer-queue-p buf))
          (should (equal '("* WAIT ") (ao--queue-headings)))
          ;; a second call does not stack regions
          (agent-org-queue-edit)
          (should (equal '("* WAIT ") (ao--queue-headings))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-queue-edit-refuses-a-non-chat-buffer ()
  "`agent-org-queue-edit' in a buffer with no session says so."
  (with-temp-buffer
    (should-error (agent-org-queue-edit) :type 'user-error)))

(ert-deftest test-agent-org-queue-keys-are-bound-in-the-chat ()
  "One pager, one surface: every queue command is bound in the chat itself.
`agent-org-queue-view' and `agent-org-queue-remove' are gone -- a read-only
listing and a number-picker that could only delete are both the same queue
the entries now show and edit.  There is no second buffer to switch to."
  (should (eq #'agent-org-queue-edit
              (lookup-key agent-org-mode-map (kbd "C-c C-q"))))
  (should (eq #'agent-org-buffer-queue-add
              (lookup-key agent-org-mode-map (kbd "C-c C-a"))))
  (should (eq #'agent-org-buffer-queue-kill
              (lookup-key agent-org-mode-map (kbd "C-c C-d"))))
  ;; `[(meta up)]' and not `(kbd "M-UP")': the kbd parser wants ONE character
  ;; after a modifier, so it raises at LOAD time on the two-letter "UP"
  (should (eq #'agent-org-buffer-queue-move-up
              (lookup-key agent-org-mode-map [(meta up)])))
  (should (eq #'agent-org-buffer-queue-move-down
              (lookup-key agent-org-mode-map [(meta down)])))
  (should-not (fboundp 'agent-org-queue-view))
  (should-not (fboundp 'agent-org-queue-remove))
  (should-not (fboundp 'agent-org-queue-mode)))

(ert-deftest test-agent-org-queue-drawer-arrives-open-in-the-chat-buffer ()
  "Waiting prompts are SHOWN, not folded: the `:QUEUE:' drawer is created
OPEN, like the tool board, because a queue that appears mid-turn is news.
A queue that empties takes its drawer away."
  (let* ((pair (ao--make-test-session "q-fold"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :pending-prompts) (list "waiting one"))
    (agent-org--queue-refresh session buf)
    (with-current-buffer buf
      (goto-char (point-min))
      (should (re-search-forward "^:QUEUE:" nil t))
      (forward-line 1)
      (should-not (invisible-p (point)))
      (should (looking-at "- waiting one")))
    (setf (plist-get session :pending-prompts) nil)
    (agent-org--queue-refresh session buf)
    (with-current-buffer buf
      (should-not (save-excursion
                    (goto-char (point-min))
                    (re-search-forward "^:QUEUE:" nil t))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-queue-drawer-shows-every-waiting-prompt ()
  "No cap on the queue: 55 waiting prompts are 55 lines in the buffer.
The reference drawers may end in `… (+N more)' and nothing is lost, because
the agent can always be asked again; the queue IS the record the transcript
mirrors, so a truncation there destroys a prompt the user paid for."
  (let* ((pair (ao--make-test-session "q-cap"))
         (buf (car pair))
         (session (cdr pair))
         (prompts (cl-loop for i from 1 to 55 collect (format "prompt %d" i))))
    (setf (plist-get session :pending-prompts) prompts)
    (agent-org--queue-refresh session buf)
    (with-current-buffer buf
      (should (= 55 (ao--count-substrings "\n- prompt ")))
      (should-not (string-match-p "more)" (buffer-string))))
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
        (should (= 1 (ao--count-substrings "* User"))))
      ;; the agent's late (cancelled) answer must not re-close the turn,
      ;; drain twice, or insert another prompt
      (funcall (plist-get (car sent) :on-success) nil)
      (should (= 1 (length sent)))
      (with-current-buffer buf
        (should (= 1 (ao--count-substrings "* User"))))
      (funcall (plist-get (car sent) :on-failure) nil "late failure")
      (with-current-buffer buf
        (should (= 1 (ao--count-substrings "* User")))
        (should (eq 'ready (plist-get agent-org-buffer--status :state)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-cancel-turn-keeps-the-queue-waiting ()
  "A cancelled turn releases NOTHING that was waiting behind it.
The user's order, after a live cancel fired every queued prompt at once:
\"Cancelling turn should never resume queue.\"  The prompts were queued to
join a conversation the user has just stopped; sending the first of them is a
turn the user never asked for, and each one that answers fires the next, so a
single cancel emptied the whole queue in seconds.

So cancel closes the cancelled turn and leaves `:pending-prompts' exactly as
it was: still in the session, still in the buffer's `:QUEUE:' drawer, still in
the transcript file.  `agent-org-queue-resume' is the only way one goes out,
besides a later turn ending successfully."
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
        (agent-org-send)                      ; goes on the wire
        (ao--type "next")
        (agent-org-send)                      ; queues "next"
        (ao--type "last")
        (agent-org-send))                     ; queues "last"
      (let ((before (length sent)))
        (with-current-buffer buf
          (agent-org-cancel-turn)
          ;; no new request: the cancel is a notification, and the only one
          (should (= before (length sent)))
          (should-not (plist-get session :streaming))
          (should (equal '("next" "last") (plist-get session :pending-prompts)))
          ;; the buffer is usable again, and says so in the body: no heading
          ;; for a prompt that was never sent
          (should (agent-org-buffer--open-prompt-p))
          (should-not (string-match-p "^\\* next$" (buffer-string)))
          ;; and the waiting prompts are still where the user can read them
          (should (string-match-p "^:QUEUE:$" (buffer-string)))
          (should (string-match-p "\n- next\n" (buffer-string)))
          (should (string-match-p "\n- last\n" (buffer-string))))
        ;; the cancelled turn's late answer must not drain it either
        (funcall (plist-get (car sent) :on-success) nil)
        (should (= before (length sent)))
        (should (equal '("next" "last") (plist-get session :pending-prompts)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-queue-resume-sends-one-and-leaves-the-rest ()
  "`agent-org-queue-resume' is the way back after a cancel: ONE prompt goes
out, FIFO, and the rest keep waiting — the queue then drains by itself at each
successful turn end, as it always did.
Port of `agent-shell-prompt-queue-resume' (agent-shell-prompt-queue.el:370)."
  (let* ((pair (ao--make-test-session "q-resume"))
         (buf (car pair))
         (session (cdr pair))
         (sent nil))
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest kw) (push kw sent)))
              ((symbol-function 'acp-make-session-prompt-request)
               (lambda (&rest a) (plist-get a :prompt))))
      (setf (plist-get session :pending-prompts) (list "one" "two"))
      (with-current-buffer buf
        (agent-org-queue-resume)
        (should (equal '("one") (ao--sent-texts sent)))
        (should (equal '("two") (plist-get session :pending-prompts)))
        (should (string-match-p "^\\* one$" (buffer-string)))
        (should (string-match-p "\n- two\n" (buffer-string)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-queue-resume-while-busy-sends-nothing ()
  "A turn already running owns the queue: resuming mid-turn would put a
second prompt on the wire beside it.  agent-shell says so in the echo area
rather than erroring, because the user's own prompts drain the queue the
moment the turn ends.  (`agent-shell-prompt-queue-resume':381.)"
  (let* ((pair (ao--make-test-session "q-busy"))
         (buf (car pair))
         (session (cdr pair))
         (sent nil))
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest kw) (push kw sent))))
      (setf (plist-get session :pending-prompts) (list "one"))
      (setf (plist-get session :streaming) t)
      (with-current-buffer buf
        (agent-org-queue-resume)
        (should-not sent)
        (should (equal '("one") (plist-get session :pending-prompts)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-queue-resume-on-an-empty-queue-rejects ()
  "Nothing waiting is a `user-error', not a silent success: the command is
how a person gets a prompt they thought was queued, and an empty queue is the
answer they need to see."
  (let ((buf (car (ao--make-test-session "q-empty"))))
    (with-current-buffer buf
      (should-error (agent-org-queue-resume) :type 'user-error))
    (kill-buffer buf)))

(ert-deftest test-agent-org-queue-resume-is-bound ()
  "Every queue command is reachable by a key as well as by `M-x': the queue
is read in the middle of a turn, when typing `M-x' costs the thread of it."
  (should (equal #'agent-org-queue-resume
                 (lookup-key agent-org-mode-map (kbd "C-c C-r")))))

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
                (and (re-search-forward "^  - TODO read_file$" nil t)
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
gives the tool board its ONGOING/COMPLETE/FAILED states, and Org actually
parses it (C-c C-c on a heading of this file offers these keywords).
The line and the board must agree: a `COMPLETE' printed in a file that
declares only DONE is text pretending to be a state, and `C-c C-t' would
offer the user a different word from the one they are reading."
  (let* ((pair (ao--make-test-session "kw"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :session-id) nil)
    (agent-org--session-ready session "sid-k" (ao--fake-session-new-resp))
    (with-current-buffer buf
      (should (string-match-p "^#\\+TODO: NEXT WAIT TODO ONGOING | COMPLETE FAILED$"
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
      ;; buffer-local keyword set now includes ONGOING/FAILED, which
      ;; the global default set does not
      (should (equal '("NEXT" "WAIT" "TODO" "ONGOING" "COMPLETE" "FAILED")
                     org-todo-keywords-1))
      (should-not (member "ONGOING" (default-value 'org-todo-keywords-1))))
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
  "The batched replay paints one heading per question, its answer as a
quote block, the tool drawer and the thinking drawer in history order,
closes all turns, and leaves font-lock alone."
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
          ;; the two user chunks collapse into ONE heading with joined text,
          ;; and the answer carries no heading of its own — it is a quote block
          (should (= 1 (ao--count-occurrences s "^\\* Hello world$")))
          (should (= 1 (ao--count-occurrences s "^\\* Next question$")))
          (should (= 0 (ao--count-occurrences s "^\\* Agent$")))
          (should (= 1 (ao--count-occurrences s "^#\\+begin_quote$")))
          (should (apply #'ao--ordered s
                         (list "Hello world" "Answer"
                               "^  - COMPLETE shell$"
                               "thinking hard" "Next question")))
          (should (string-match-p "^:thinking:$" s))
          (should (string-match-p "^:tool:$" s)))
        (should-not agent-org-buffer--streaming-p)
        ;; A replay never suppresses font-lock (see
        ;; `test-agent-org-replay-never-touches-font-lock'): the paint pass leaves
        ;; the buffer's own state exactly as it found it.  Batch Emacs can never
        ;; enable font-lock, so this reads as nil in both cases -- what is pinned is
        ;; that the replay changed nothing.
        (should (eq font-lock-mode font-lock-was))
        (should (null (plist-get session :replay)))))
    (kill-buffer buf)))

;;;; A chat buffer gets its colors when it is SHOWN

(ert-deftest test-agent-org-chat-buffer-asks-for-font-lock-when-displayed ()
  "A chat buffer must ask for font-lock at display time, not at creation.
`font-lock-mode' cannot be enabled in a buffer NO window is showing: measured in
a live Emacs, `(font-lock-mode 1)' in a hidden buffer leaves the variable nil
with no error and no trace, and so does `turn-on-font-lock'.  Chat buffers are
created hidden (`agent-org-buffer-create' is called from a handshake callback),
so the ambient `global-font-lock-mode' can never reach them and they open with
no Org colors at all.  `agent-org-mode' therefore adds
`agent-org-buffer--ensure-font-lock' to this buffer's
`window-configuration-change-hook', which Emacs runs with the buffer current
when it first appears in a window.

Batch Emacs is the hidden case, so the stub plays the part of a displayed
buffer: it records the request and sets the variable, which is what a window
would have made Emacs do."
  (let ((b (agent-org-buffer-create "flshow"))
        (asked nil))
    (unwind-protect
        (cl-letf (((symbol-function 'font-lock-mode)
                   (lambda (&optional arg)
                     (push arg asked)
                     (when arg (setq-local font-lock-mode t))))
                  ((symbol-function 'font-lock-flush)
                   (lambda (&rest _) nil)))
          (with-current-buffer b
            ;; the premise: creation left it off, exactly as a live hidden buffer
            (should-not font-lock-mode)
            ;; the mode really did install itself on THIS buffer's display hook
            (should (memq #'agent-org-buffer--ensure-font-lock
                          (symbol-value 'window-configuration-change-hook)))
            ;; Emacs' own display path: the buffer-local hook, buffer current
            (run-hooks 'window-configuration-change-hook)
            (should font-lock-mode)
            (should (memq 1 asked))
            ;; and asking again costs nothing: it is an `unless', not a toggle
            (let ((before (length asked)))
              (run-hooks 'window-configuration-change-hook)
              (should (equal before (length asked))))))
      (kill-buffer b))))

;;;; A failed replay must not cost the buffer its colors

(ert-deftest test-agent-org-replay-never-touches-font-lock-even-when-the-paint-errors ()
  "No render path may switch font-lock off, because its OFF is restorable and
its ON is not: in a live Emacs `(font-lock-mode 1)' in a buffer no window is
showing does nothing at all.  So a replay that suppressed font-lock and restored
it afterwards lost the chat's colors forever whenever the resume painted into a
background buffer -- the user's second \"colors gone again!\" -- and an error in
the middle lost them even in a shown one.

The whole suppression is therefore gone: a replay leaves `font-lock-mode'
untouched and only flushes.  The honest batch pin is the SEQUENCE of calls: the
paint may not call `font-lock-mode' at all, not even to put it back."
  (let* ((pair (ao--make-test-session "flerr"))
         (buf (car pair))
         (session (cdr pair))
         (raised nil)
         (errored nil)
         (calls nil))
    (with-current-buffer buf
      ;; the premise: this buffer's colors are ON before the replay
      (setq-local font-lock-mode t))
    (setf (plist-get session :loading) t)
    (setf (plist-get session :replay)
          (list (ao--update-notif
                 '((sessionUpdate . "agent_message_chunk")
                   (content . ((type . "text") (text . "boom-proof")))))))
    (cl-letf (((symbol-function 'agent-org--buffer-update)
               (lambda (&rest _)
                 (setq raised t)
                 (signal 'error '("paint boom"))))
              ((symbol-function 'font-lock-mode)
               (lambda (&optional arg) (push (list 'mode arg) calls)))
              ((symbol-function 'font-lock-flush)
               (lambda (&rest a) (push (cons 'flush a) calls)))
              ((symbol-function 'agent-org--progress-stop)
               (lambda (&rest _) (push 'stop calls))))
      (condition-case nil
          (agent-org--render-replay session)
        (error (setq errored t))))
    (should raised)                    ; the paint really did raise
    (should errored)                   ; …and the error propagated to acp
    (with-current-buffer buf
      ;; CAR-SAFE, not CAR: the stop marker is pushed as the bare symbol
      ;; `stop', and `car' (or `assq') over that element errors.
      (should (null (seq-filter (lambda (c) (eq (car-safe c) 'mode)) calls)))
      (should font-lock-mode)          ; nothing could have taken it away
      (should (seq-filter (lambda (c) (eq (car-safe c) 'flush)) calls))
      (should (memq 'stop calls)))     ; the Restoring report cannot leak
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
  "A replayed turn keeps the same shape as a typed one: one heading wearing
the question, its answer a quote block, one `:tool:' drawer line per distinct
toolCallId, thoughts folded in their own drawer, and an update rewriting its
own line instead of adding a second.  Live qoder replayed 4 tool calls but the
buffer showed 1 heading, so this pins the whole turn down at once."
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
          (should (equal 1 (ao--count-occurrences text "^\\* Do things$")))
          (should (equal 1 (ao--count-occurrences text "^#\\+begin_quote$")))
          (should (equal 4 (ao--count-occurrences text "^  - ")))
          ;; the completed call was rewritten in place, the others stayed
          ;; pending
          (should (equal 1 (ao--count-occurrences text "^  - COMPLETE read a$")))
          (should (equal 3 (ao--count-occurrences text "^  - TODO ")))
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
the status a quote's author reads is the status a live session has — the
point of this helper is that no test hand-writes `:model-name'.  NAME nil
is an agent reporting a value it never named, which is the id-fallback case.
ID nil is an agent advertising no model option at all (Goose answers with
no `configOptions' of this shape), which is the no-model case.  SESSION-ID
defaults to the wire's own \"sid-new\"; the transcript tests pass their
own, because the id is what names their file.  Caller kills the buffer."
  (let ((agent-org-session-strategy 'new))
    (let ((buf (agent-org-start 'qoder)))
      (ao--drive "initialize" ao--fake-init-resp)
      (ao--drive "session/new"
                 (if id
                     (ao--config-resp id (and name (list (cons id name)))
                                      session-id)
                   `((sessionId . ,(or session-id "sid-new"))
                     (configOptions . []))))
      buf)))

(ert-deftest test-agent-org-quote-author-wears-the-id-when-nothing-names-it ()
  "An agent that reports a value but no label gets the value on the quote.
`agent-org--ingest-config' stores the advertised `name' in `:model-name' and
falls back to the wire id when the agent names nothing, so an `:author' built
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
        (should (re-search-forward
                 "^#\\+ATTR_TEXINFO: :author ghost-model$" nil t)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-quote-author-flattens-a-multiline-model-name ()
  "A model label is agent free text, so it cannot break the keyword line.
`agent-org-buffer--label' is the gate every agent-supplied string passes
before it lands on a one-line context; a config option named \"A\\nB\" must
produce ONE attribute line, not an attribute and a stray paragraph that Org
would read as the quote's body with a lost structure."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel-large" "QModel\nLarge  with\n\n  spaces")))
      (with-current-buffer buf
        (agent-org-buffer-start-agent-turn buf (agent-org-buffer--session))
        (goto-char (point-min))
        (should (re-search-forward
                 (concat "^#\\+ATTR_TEXINFO: :author "
                         (agent-org-buffer--label
                          "QModel\nLarge  with\n\n  spaces")
                         "$")
                 nil t))
        (should-not (re-search-forward "^[ \t]*Large" nil t)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-replay-paints-the-model-it-was-told ()
  "Restored history is attributed to the model known NOW, which is all the wire says.
`session/load' replays chunks with no model attached to any of them, so a
resumed transcript cannot claim per-turn models it never learned — this test
states what the replay really does, through the same primitive a live turn
uses, instead of pretending it remembers.  It is also the guard that naming
the quote's author did not break the restored-history path, which paints
hundreds of chunks in one synchronous run.  Two agent chunks with no question
before them are one orphan turn: a `* Agent' heading and ONE quote block whose
`:author' is the model the client currently knows."
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
        (should (= 1 (ao--count-occurrences
                      s "^#\\+ATTR_TEXINFO: :author Qwen3\\.8-Flash$")))
        (should (= 1 (ao--count-occurrences s "^\\* Agent$")))))
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

(ert-deftest test-agent-org-start-double-prefix-forces-the-latest-session ()
  "C-u C-u opens the most recently MODIFIED session, and asks nothing.
`latest' is the strategy that means \"open the chat I was last in\", and
until now it was reachable only by editing `agent-org-session-strategy'.
One prefix arg has always meant `new', so the second tier carries the
other answer -- the same 16-and-up reading `agent-org-resume-session'
already uses for its own second tier.

Recency is the listing's `updatedAt', falling back to `createdAt' for a
session nobody ever touched, NOT the order the agent put them in: this
wire answers oldest first."
  (ao--capture-wire
    (let ((current-prefix-arg '(16))
          (agent-org-session-strategy 'prompt))
      (let ((buf (cl-letf (((symbol-function 'agent-org--read-provider)
                            (lambda () 'qoder)))
                   (call-interactively 'agent-org-start))))
        (ao--never-prompt
          (ao--drive "initialize" ao--fake-init-resp)
          (ao--drive
           "session/list"
           `((sessions . [((sessionId . "s-stale") (title . "Old work")
                           (updatedAt . "2026-08-01T10:00:00+0000"))
                          ((sessionId . "s-live") (title . "Last thing I did")
                           (updatedAt . "2026-10-04T18:30:00+0000"))
                          ((sessionId . "s-quiet") (title . "Born, never touched")
                           (createdAt . "2026-07-01T09:00:00+0000"))])))
        (should-not (ao--sent-get "session/new"))
        (let ((params (map-elt (plist-get (ao--sent-get "session/load") ':request)
                               ':params)))
          (should (equal (map-elt params 'sessionId) "s-live")))
        (kill-buffer buf))))))

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
  "Two registered chats, both Ready, with distinct ids and harnesses.
Returns ((BUFFER-1 . SESSION-1) . (BUFFER-2 . SESSION-2)).  The fixture
`ao--make-test-session' gives both the same id and leaves the brand-new
buffer on `starting', so this pins both facts: a switcher that lists two
identical rows is the bug this section exists to prevent, and the state
column is what the tests below read.

`agent-org--sessions' is global and other suites leave their chat buffers
alive, so a caller that counts rows must bind it nil around the whole
body — that is the test's job, not this helper's, because the binding has
to outlive the registration."
  (let ((one (ao--make-test-session "qoder"))
        (two (ao--make-test-session "goose")))
    (setf (plist-get (cdr one) :session-id) "sid-one")
    (setf (plist-get (cdr two) :session-id) "sid-two")
    ;; distinct PROVIDERS, not distinct titles: a row's label is the agent
    ;; and the project, so two chats of one harness in one project would
    ;; give this section two identical rows to compare and no way to tell
    ;; which row is which.  The titles are still set — they are what the
    ;; `#+TITLE:' of each chat is made of, and a test that reads them from
    ;; the name is the bug this fixture used to hide.
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
      (should (string-prefix-p "goose:" (car (nth 0 choices))))
      (should (string-match-p "\\[sid-two\\]\\'" (car (nth 0 choices))))
      (should (string-prefix-p "qoder:" (car (nth 1 choices))))
      (kill-buffer (car one))
      (kill-buffer (car two)))))

(ert-deftest test-agent-org-switch-candidates-wear-the-provider-and-project ()
  "A chat that has been titled nothing still gets a readable row, and it
gets the SAME row shape as one that has: the label is the provider and the
project, so there is no fallback path left to test.  The project directory
comes from `agent-org-buffer-create', which knows the cwd from the moment
the buffer exists, and the id from `session/new' — which is what makes a
title-less agent (goose advertises none) indistinguishable in shape from
one that titles everything (qoder)."
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

(ert-deftest test-agent-org-switch-candidates-label-the-chat-not-its-topic ()
  "A row's label is the agent and the project, never the session title.
The switcher shares `agent-org-buffer--chat-label' with the buffer name
deliberately, so a fix that stopped the title entering the NAME must not
leave it entering the ROW — one chat, one label, and the user's complaint
was that the label described the topic instead of the harness."
  (ao--isolated-registry
    (let* ((pair (ao--two-chats))
           (one (car pair))
           (two (cdr pair)))
      (agent-org-buffer-set-status (car one) :project "org-docs")
      (agent-org-buffer-set-status (car two) :project "agent-org")
      (let ((choices (agent-org--switch-candidates)))
        ;; row 0 is `two', row 1 is `one' (registry order)
        (should (string-prefix-p "goose:agent-org" (car (nth 0 choices))))
        (should (string-prefix-p "qoder:org-docs" (car (nth 1 choices))))
        (should-not (string-match-p "loader" (car (nth 0 choices))))
        (should-not (string-match-p "login" (car (nth 1 choices))))
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
label pads like a Latin one.  Ragged rows are the whole reason a chat list
is read by scanning down one column instead of reading across.

The column's start is ROW's first dimmed character, and NOT its first run
of two spaces: the short label is padded with spaces and the separator is
spaces too, so on a padded row the first double space sits somewhere
INSIDE the padding — counting to it measures where the padding happened to
begin, which is why this assertion read (18 47) while the rows, printed,
were identical 65-column strings."
  (ao--isolated-registry
    (let* ((pair (ao--two-chats))
           (one (car pair))
           (two (cdr pair)))
      ;; row 0 is `two' (registry order) and keeps its short label, so a
      ;; shared column start proves the SHORT row was padded to the long one.
      ;; The long half of the pair is the PROVIDER, because that is the only
      ;; part of the label an agent can make long now a title never enters it.
      (agent-org-buffer-set-status (car one) :provider
                                   "a harness whose name runs on for very long indeed")
      (let ((labels (mapcar #'car (agent-org--switch-candidates))))
        (should (= 2 (length labels)))
        (should (apply #'equal (seq-map #'ao--dim-column labels)))
        ;; Equal total width too: the ids are the same length here, so the two
        ;; rows can only line up if the SHORT label was padded out to the
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
                                   "^\\* align the columns$"
                                   "^#\\+ATTR_TEXINFO: :author QModel Large$"
                                   "tok tok"
                                   "^:thinking:$" "reasoning here"
                                   "^:tool:$" "^  - TODO grep -rn foo$")))
              (kill-buffer buf))))))))

(ert-deftest test-agent-org-transcript-rewrites-a-tool-line-instead-of-logging-it ()
  "A tool that finished appears as COMPLETE once — no ONGOING line above it.
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
              (should (= 1 (ao--count-occurrences text "^  - COMPLETE run tests$")))
              (should (= 0 (ao--count-occurrences text "^  - \\(TODO\\|ONGOING\\) run tests$")))
              (kill-buffer buf))))))))

(ert-deftest test-agent-org-transcript-files-tool-output-under-its-line ()
  "What the tool printed is part of the record, so it reaches the file.
The transcript mirrors the buffer, and the output is now an item of the
BOARD itself -- which is the cheap way to get durable tool output: no second
writer, no second format, and one drawer holds both the state and the result
in the chat and in the file an hour later."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (ao--capture-wire
        (let* ((buf (ao--chat-on-model "qmodel-large" "QModel Large" "sid-out"))
               (session (agent-org--session-for-buffer buf))
               (sent nil))
          (cl-letf (((symbol-function 'acp-send-request)
                     (lambda (&rest kw) (push kw sent)))
                    ((symbol-function 'acp-make-session-prompt-request)
                     (lambda (&rest a) (plist-get a :prompt))))
            (with-current-buffer buf
              (ao--type "show me the tree")
              (agent-org-send))
            (agent-org--on-notification
             session (ao--update-notif
                      `((sessionUpdate . "tool_call_update")
                        (toolCallId . "t1") (title . "ls -R") (status . "completed")
                        ,@(ao--tool-text-block "agent-org.el\nTODOs.org"))))
            (funcall (plist-get (car sent) :on-success) nil)
            (let ((text (ao--transcript-text temp-dir "sid-out")))
              (should (= 1 (ao--count-occurrences text "^:tool:$")))
              (should (= 1 (ao--count-occurrences text "^  - COMPLETE ls -R$")))
              (should (string-match-p "^    agent-org.el$" text))
              (should (string-match-p "^    TODOs.org$" text))
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
              ;; three exchange headings, one per prompt (the type-ahead box is
              ;; below the render end and never mirrored)
              (should (= 3 (ao--count-occurrences text "^\\* ")))
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
          (agent-org-buffer-begin-exchange buf "a new turn")
          (agent-org-buffer-transcribe buf)
          (should (= 2 ao--writes)))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-transcript-force-rewrites-an-unchanged-body ()
  "FORCE ignores the two skips an ordinary boundary honours.
They exist to save a whole-file write — the unchanged-body cache and lite
mode — but a SYNC is not a boundary, it is the user asking the file to catch
up NOW, so both are bypassed.  The file is deleted under a warm cache to show
the cache check is skipped, then lite mode is set to show its gate is too.
`agent-org-transcribe' nil is NOT overridden (see the off test): FORCE asks
the mirror to catch up, not to override the decision to keep no files."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (let* ((pair (ao--make-test-session "force"))
             (buf (car pair))
             (file (expand-file-name "sid-force.org" temp-dir)))
        (agent-org-buffer-set-status buf :session-id "sid-force" :state 'ready)
        (agent-org-buffer-refresh-metadata buf)
        (agent-org-buffer-transcribe buf)        ; writes and warms the cache
        (should (file-exists-p file))
        ;; unchanged body, warm cache: an ordinary call skips the rewrite
        (delete-file file)
        (agent-org-buffer-transcribe buf)
        (should-not (file-exists-p file))
        ;; FORCE rewrites it even though nothing changed
        (agent-org-buffer-transcribe buf t)
        (should (file-exists-p file))
        ;; lite with an empty queue: an ordinary call writes nothing at all
        (delete-file file)
        (with-current-buffer buf (setq agent-org-buffer--lite 'on))
        (agent-org-buffer-transcribe buf)
        (should-not (file-exists-p file))
        ;; FORCE writes even in lite mode
        (agent-org-buffer-transcribe buf t)
        (should (file-exists-p file))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-transcript-sync-rewrites-the-file-with-the-current-rendering ()
  "`agent-org-transcript-sync' re-mirrors NOW, no turn required.
This is the feature's reason to exist: a status the CURRENT build renders but
that the file predates.  Change `:title' without touching a boundary, then
run the command — it refreshes the metadata and force-writes, so the file
carries the new title.  The metadata is NOT refreshed by hand first: that is
what proves the command itself does it."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (let* ((pair (ao--make-test-session "sync"))
             (buf (car pair)))
        (agent-org-buffer-set-status buf :session-id "sid-sync" :state 'ready
                                     :title "First")
        (agent-org-buffer-refresh-metadata buf)
        (agent-org-buffer-transcribe buf)
        (should (string-match-p "^#\\+TITLE: First$"
                                (ao--transcript-text temp-dir "sid-sync")))
        ;; the title changes with no turn and no boundary call
        (agent-org-buffer-set-status buf :title "Second")
        (with-current-buffer buf (agent-org-transcript-sync))
        (let ((text (ao--transcript-text temp-dir "sid-sync")))
          (should (string-match-p "^#\\+TITLE: Second$" text))
          (should-not (string-match-p "^#\\+TITLE: First$" text)))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-transcript-sync-prefix-covers-every-open-chat ()
  "A prefix arg makes sync iterate every live chat, not just this buffer.
Two sessions, both files deleted, ONE prefixed call from a buffer that is not
a chat at all, both files back — which also proves the `C-u' form reads the
registry rather than the current buffer."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (let (bufs)
        (dolist (sid '("sid-all-1" "sid-all-2"))
          (let* ((pair (ao--make-test-session sid))
                 (buf (car pair))
                 (file (expand-file-name (concat sid ".org") temp-dir)))
            (agent-org-buffer-set-status buf :session-id sid :state 'ready)
            (agent-org-buffer-refresh-metadata buf)
            (agent-org-buffer-transcribe buf)
            (should (file-exists-p file))
            (delete-file file)
            (push buf bufs)))
        (with-temp-buffer (agent-org-transcript-sync t))
        (dolist (sid '("sid-all-1" "sid-all-2"))
          (should (file-exists-p (expand-file-name (concat sid ".org") temp-dir))))
        (dolist (b bufs) (kill-buffer b))))))

(ert-deftest test-agent-org-transcript-sync-refuses-when-transcription-is-off ()
  "Sync says so instead of silently doing nothing when files are off.
`agent-org-transcribe' nil is the opt-out; FORCE overrides the cache and lite
skips, never this.  A silent success would read as \"the transcript updated\"
when no transcript exists to update."
  (ert-with-temp-directory temp-dir
    (let ((agent-org-transcribe nil)
          (agent-org-transcript-directory temp-dir))
      (let* ((pair (ao--make-test-session "off-sync"))
             (buf (car pair)))
        (agent-org-buffer-set-status buf :session-id "sid-nooff" :state 'ready)
        (should-error (with-current-buffer buf (agent-org-transcript-sync))
                      :type 'user-error)
        (should (null (ao--transcript-files temp-dir)))
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

;;;; Wire traffic

(defun ao--client-for (session command)
  "Give SESSION a mock client spawned for COMMAND, as `agent-org--open-session' would.
`ao--make-test-session' leaves `:client' nil — most tests never send
anything — so a test about the client's own entourage (its traffic buffer)
installs one after the fact."
  (let ((client (acp-make-client :command command :command-params '("acp"))))
    (setf (plist-get session :client) client)
    client))

(ert-deftest test-agent-org-show-traffic-demands-a-chat ()
  "M-x agent-org-show-traffic in a buffer with no agent is a refusal.
The alternative — an empty log buffer — reads as \"the agent sent
nothing\", which is a claim about the wire and would be false: no wire
belongs to that buffer at all."
  (with-temp-buffer
    (should-error (agent-org-show-traffic) :type 'user-error)))

(ert-deftest test-agent-org-show-traffic-needs-a-live-client ()
  "A chat whose agent is gone has no log to open.
`:client' is nil for a session that never finished spawning and for one
released by `agent-org--kill-session', and the buffer outlives both — the
command must say so rather than conjure a buffer for a client that no
longer exists."
  (let* ((pair (ao--make-test-session "noclient"))
         (buf (car pair)))
    (should-not (agent-org--traffic-buffer (cdr pair)))
    (should-error (agent-org-show-traffic buf) :type 'user-error)
    (kill-buffer buf)))

(ert-deftest test-agent-org-show-traffic-names-the-switch-when-empty ()
  "An empty log says why it is empty, because the cause is a setting.
acp consults `acp-logging-enabled' per message, so a chat opened before
logging was on keeps answering normally while its log stays at zero
bytes — the reader must be told to turn `agent-org-log-traffic' on and
restart, not left to conclude the agent is silent."
  (let ((acp-logging-enabled nil)
        (agent-org-log-traffic nil))
    (let* ((pair (ao--make-test-session "quiet"))
           (buf (car pair)))
      (ao--client-for (cdr pair) "quiet-agent")
      (let ((msg (condition-case err
                     (progn (agent-org-show-traffic buf) nil)
                   (user-error (error-message-string err)))))
        (should (string-match-p "agent-org-log-traffic" msg)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-show-traffic-opens-this-chats-log ()
  "The command lands in the traffic buffer belonging to THIS chat.
One buffer per client, named for its command and instance count; a turn
logged on another chat's client must not appear here, or the reader is
checking a wire they did not ask about."
  (let ((acp-logging-enabled t))
    (let* ((pair (ao--make-test-session "logged"))
           (buf (car pair))
           (client (ao--client-for (cdr pair) "logged-agent")))
      (with-current-buffer (acp-traffic-buffer :client client)
        (let ((inhibit-read-only t))
          (insert "12:00:00.000 → request      session/prompt\n")))
      (agent-org-show-traffic buf)
      (should (eq (current-buffer) (acp-traffic-buffer :client client)))
      (should (search-forward "session/prompt" nil t))
      (kill-buffer buf))))

;;;; Queued prompts: on disk, and back on resume

(defmacro ao--wire-prompt-texts (&rest body)
  "Run BODY with `acp-make-session-prompt-request' building a real-shaped request.
`tests/acp-mock.el' answers NIL for it, and `ao--capture-wire' keys its
capture on the request's =:method= — so a drained prompt would be captured
under NIL and be invisible to `ao--sent-get'.  This is the shape the real
acp package sends: a method plus =:params= carrying the prompt blocks."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'acp-make-session-prompt-request)
              (lambda (&rest kw)
                `((:method . "session/prompt")
                  (:params . ((sessionId . ,(plist-get kw :session-id))
                              (prompt . ,(plist-get kw :prompt))))))))
     ,@body))

(defun ao--sent-prompt-texts ()
  "The text of every `session/prompt' captured in `ao--sent', oldest first.
The capture keys on the request's =:method=, which is why the prompt
request needs `ao--wire-prompt-texts': the mock's builder answers NIL, and
a NIL request would be captured under NIL — a drained prompt the test
could not see."
  (mapcar (lambda (entry)
            (let ((params (map-elt (plist-get (cdr entry) :request) ':params)))
              (map-elt (car (map-elt params 'prompt)) 'text)))
          (reverse (seq-filter (lambda (entry)
                                 (equal (car entry) "session/prompt"))
                               ao--sent))))

(ert-deftest test-agent-org-queue-drawer-lists-the-waiting-prompts ()
  "A prompt that has not been sent is written into the metadata block.
The frozen conversation cannot show it — a queued prompt gets its `* User'
heading only when it drains — so the queue needs a home above the
headings, which is also the part of the buffer the transcript mirrors.
One line per prompt, oldest first, so the file records the order the
prompts will go out in."
  (let ((rendered (agent-org-buffer--render-metadata
                   (list :provider "Qoder" :session-id "s-queue"
                         :queued (list "first" "second")))))
    (should (string-match-p ":QUEUE:\n- first\n- second\n:END:" rendered))
    (should (= 1 (ao--count-occurrences rendered "^:QUEUE:$")))))

(ert-deftest test-agent-org-queue-line-escape-is-lossless ()
  "A prompt goes onto ONE drawer line and comes back byte for byte.
Two reasons the text cannot be written verbatim: a blank line or a line
reading `:END:' would end the drawer early, and a queue entry is the
user's own multi-line draft.  So newline and backslash are escaped and
the line is prefixed with `- ', which keeps a literal `:END:' from
starting the line.  `:QUEUE:' is a machine-read drawer — decode is the
exact inverse of encode, including on the pathological cases."
  (dolist (text (list "one line"
                      "two\nlines"
                      "a backslash \\ and a newline\nhere"
                      ":END:\n- not a drawer end"
                      ""))
    (let ((line (agent-org-buffer--queue-encode text)))
      (should (string-prefix-p "- " line))
      (should-not (string-match-p "\n" line))
      (should (equal text (agent-org-buffer--queue-decode line)))))
  (should (equal "- two\\nlines"
                 (agent-org-buffer--queue-encode "two\nlines"))))

(ert-deftest test-agent-org-queue-drawer-arrives-open-and-stays-when-folded ()
  "The waiting prompts are shown: a `:QUEUE:' drawer is created OPEN.
It used to be folded like COMMANDS/MODES/CONFIG, on the reasoning that a
queue is bookkeeping; the user's order -- \"Show the prompt queue within the
buffer\" -- is the better call, because a queue that appears mid-turn is
news and a folded one is invisible exactly when it matters.  Reference
material still arrives folded, and a board the user folded by hand is left
folded: the default governs creation, not the user."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel-large" "QModel Large" "sid-fold")))
      (with-current-buffer buf
        (agent-org-buffer-set-status buf :queued (list "waiting"))
        (agent-org-buffer-refresh-metadata buf)
        (should-not (invisible-p
                     (save-excursion (goto-char (point-min))
                                     (re-search-forward "^- waiting$")
                                     (point)))))
      ;; fold it by hand, then change the queue: the user's fold survives
      (with-current-buffer buf
        (save-excursion
          (goto-char (point-min))
          (re-search-forward "^:QUEUE:")
          (org-fold-hide-drawer-toggle))
        (agent-org-buffer-set-status buf :queued (list "waiting" "and more"))
        (agent-org-buffer-refresh-metadata buf)
        (should (invisible-p
                 (save-excursion (goto-char (point-min))
                                 (re-search-forward "^- waiting$")
                                 (point)))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-queue-drawers-do-not-share-their-fold-default ()
  "COMMANDS stays folded while QUEUE opens: one default per kind.
The two are different things -- one is reference the agent can be asked for
again, the other is the user's own work waiting to go out."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel-large" "QModel Large" "sid-mixed")))
      (with-current-buffer buf
        (agent-org-buffer-set-status
         buf :queued (list "waiting")
         :commands (list `((name . "help") (description . "show help"))))
        (agent-org-buffer-refresh-metadata buf)
        (should (invisible-p
                 (save-excursion (goto-char (point-min))
                                 (re-search-forward "^/help")
                                 (point))))
        (should-not (invisible-p
                     (save-excursion (goto-char (point-min))
                                     (re-search-forward "^- waiting$")
                                     (point)))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-transcript-queue-reads-its-own-lines-only ()
  "The reader takes `:QUEUE:' lines, and nothing that is not an entry.
A drawer line that does not start with \"- \" cannot be a prompt: skipping
it means a hand-edited transcript, or a stray marker, restores the prompts
rather than enqueueing the marker as one."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (let ((buf (agent-org-buffer-create "qr")))
        (with-current-buffer buf
          (agent-org-buffer-set-status buf :session-id "sid-qr")
          (let ((file (agent-org-buffer--transcript-file "sid-qr")))
            (make-directory (file-name-directory file) t)
            (with-temp-buffer
              ;; `- keep\ntoo' on disk: what `agent-org-buffer--queue-encode'
              ;; writes for a prompt with a real newline in it — ONE
              ;; backslash, not the doubled pair a literal backslash gets.
              (insert ":QUEUE:\n- keep me\n- keep\\ntoo\n… (+3 more)\n:END:\n")
              (write-region nil nil file nil 'silent))
            (should (equal '("keep me" "keep\ntoo")
                           (agent-org-buffer-transcript-queue "sid-qr")))))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-queued-prompt-reaches-the-file-mid-turn ()
  "Queuing writes the transcript: a quit must not swallow the prompt.
The mirror is otherwise a turn-boundary writer, and a queued prompt that
never reaches a boundary — the user quits Emacs, or the agent dies — is
exactly the text the user would most want back.  So the queue's own
mutations are boundaries of their own.
This is also the test that pins the READ ordering: the file on disk is the
only copy of the queue, because the resumed buffer has none."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (ao--capture-wire
        (let* ((buf (ao--chat-on-model "qmodel-large" "QModel Large" "sid-mid"))
               (session (agent-org--session-for-buffer buf))
               (sent nil))
          (cl-letf (((symbol-function 'acp-send-request)
                     (lambda (&rest kw) (push kw sent)))
                    ((symbol-function 'acp-make-session-prompt-request)
                     (lambda (&rest a) (plist-get a :prompt))))
            (with-current-buffer buf
              (ao--type "turn one")
              (agent-org-send))                       ; streaming, no answer yet
            (with-current-buffer buf
              (ao--type "wait for me\nplease")
              (agent-org-send))                       ; queues it
            (should (equal '("wait for me\nplease")
                           (plist-get session :pending-prompts)))
            (let ((text (ao--transcript-text temp-dir "sid-mid")))
              (should (string-match-p ":QUEUE:\n- wait for me\\\\nplease\n:END:"
                                      text))
              ;; read back the way resume does, from the file alone
              (should (equal (list "wait for me\nplease")
                             (with-current-buffer buf
                               (agent-org-buffer-transcript-queue "sid-mid"))))))
          (kill-buffer buf))))))

(ert-deftest test-agent-org-queue-drawer-clears-when-the-prompt-is-sent ()
  "A drained prompt leaves the drawer, so resume never sends it twice.
The file is the queue's only durable copy: if a sent prompt stayed
listed, the next resume would re-send a turn the agent already answered.
Draining therefore re-mirrors, and an empty queue renders no drawer at
all rather than an empty one."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (ao--capture-wire
        (let* ((buf (ao--chat-on-model "qmodel-large" "QModel Large" "sid-drain"))
               (session (agent-org--session-for-buffer buf))
               (sent nil))
          (cl-letf (((symbol-function 'acp-send-request)
                     (lambda (&rest kw) (push kw sent)))
                    ((symbol-function 'acp-make-session-prompt-request)
                     (lambda (&rest a) (plist-get a :prompt))))
            (with-current-buffer buf
              (ao--type "turn one")
              (agent-org-send))
            (with-current-buffer buf
              (ao--type "queued")
              (agent-org-send))
            ;; turn one answers: "queued" goes on the wire and the queue empties
            (funcall (plist-get (car (last sent)) :on-success) nil)
            (should (null (plist-get session :pending-prompts)))
            (with-current-buffer buf
              ;; the drained prompt is conversation now: headed, and gone
              ;; from the drawer that was holding it
              (should (string-match-p "^\\* queued$" (buffer-string)))
              (should-not (string-match-p "^:QUEUE:$" (buffer-string))))
            (should-not (string-match-p "^:QUEUE:$"
                                        (ao--transcript-text temp-dir "sid-drain"))))
          (kill-buffer buf))))))

(ert-deftest test-agent-org-resume-reloads-the-queued-prompts-and-sends ()
  "Resume brings back what the last session had queued, in order.
User order: \"Save queued prompts to transcripts and reload them on
resume.\"  The prompts were never sent, so the agent's own replay cannot
contain them — only our transcript can.  Restoring into an idle session
and leaving them there would strand them: nothing else drains a queue on
a session that is not busy, so the flush point drains, which puts the
first one on the wire and keeps the rest waiting exactly as they were."
  (ert-with-temp-directory temp-dir
    (with-temp-file
        (expand-file-name (agent-org-buffer--transcript-name "sid-rest")
                          temp-dir)
      (insert ":PROPERTIES:\n:ID: sid-rest\n:END:\n"
              ;; an OLD transcript, retired `#+TODO:' vocabulary and all: the
              ;; file on disk is whatever a previous session wrote, and resume
              ;; must read its queue without caring
              "#+TITLE: Before\n#+TODO: TODO DOING | DONE CANCELLED\n\n"
              ":QUEUE:\n- finish the tests\n- then run org-check\n:END:\n"))
    ;; Transcription is ON deliberately: `agent-org--session-ready' mirrors
    ;; the freshly replayed buffer — which has no queue in it — over this
    ;; file, so the test only passes if the queue was read BEFORE that write.
    (ao--transcript-in temp-dir
      (ao--capture-wire
        (let* ((buf (agent-org-resume-session 'qoder "sid-rest"))
               (session (agent-org--session-for-buffer buf)))
          (ao--drive "initialize" ao--fake-init-resp)
          (ao--drive "session/load" '((sessionId . "sid-rest")))
          (ao--wire-prompt-texts
            (ao--settle))
          ;; the first prompt is out on the wire as its own turn; the rest wait
          (should (equal (list "finish the tests") (ao--sent-prompt-texts)))
          (should (equal '("then run org-check")
                         (plist-get session :pending-prompts)))
          (with-current-buffer buf
            (should (string-match-p "^\\* finish the tests$"
                                    (buffer-string)))
            (should (string-match-p "1 queued"
                                    (agent-org-buffer--render-header-line))))
          (kill-buffer buf))))))

(ert-deftest test-agent-org-resume-without-a-queue-drawer-sends-nothing ()
  "A transcript without the drawer restores an empty queue: no phantom turn.
Most resumes have nothing waiting, and one invented from a stale file
would spend tokens the user never asked for.  Absent drawer, absent
`session/prompt'."
  (ert-with-temp-directory temp-dir
    (let ((agent-org-transcript-directory temp-dir)
          (agent-org-transcribe nil))
      (with-temp-file
          (expand-file-name (agent-org-buffer--transcript-name "sid-none")
                            temp-dir)
        (insert ":PROPERTIES:\n:ID: sid-none\n:END:\n#+TITLE: Quiet\n"))
      (ao--capture-wire
        (let* ((buf (agent-org-resume-session 'qoder "sid-none"))
               (session (agent-org--session-for-buffer buf)))
          (ao--drive "initialize" ao--fake-init-resp)
          (ao--drive "session/load" '((sessionId . "sid-none")))
          (ao--wire-prompt-texts (ao--settle))
          (should (null (plist-get session :pending-prompts)))
          (should (null (ao--sent-prompt-texts)))
          (should-not (plist-get (buffer-local-value 'agent-org-buffer--status buf)
                                 :queued))
          (kill-buffer buf))))))

(ert-deftest test-agent-org-resume-without-a-transcript-file-just-loads ()
  "No file, no error: the transcript is a convenience, not a dependency.
A session resumed with `agent-org-transcribe' off, or one that predates
the feature, has nothing to read — and a resume that failed on a missing
file would be a regression for every user who never queued a prompt."
  (ert-with-temp-directory temp-dir
    (let ((agent-org-transcript-directory
           (expand-file-name "nope/" temp-dir))
          (agent-org-transcribe nil))
      (ao--capture-wire
        (let ((buf (agent-org-resume-session 'qoder "sid-absent")))
          (ao--drive "initialize" ao--fake-init-resp)
          (ao--drive "session/load" '((sessionId . "sid-absent")))
          (ao--wire-prompt-texts (ao--settle))
          (should (equal 'ready
                         (plist-get (buffer-local-value
                                     'agent-org-buffer--status buf)
                                    :state)))
          (kill-buffer buf))))))

;;;; Markdown -> Org in the reply body

(defun ao--md (line &optional src-p)
  "Org line that `agent-org-buffer--markdown-line' makes of LINE.
The SRC-P return value is dropped: these tests ask what a reader sees."
  (car (agent-org-buffer--markdown-line line src-p)))

(ert-deftest test-agent-org-markdown-headings-become-bold-inside-a-quote ()
  "A Markdown ATX heading cannot be an Org headline inside the reply's quote.
The answer now lives in a `#+begin_quote' block and a headline of ANY level
ends one — the parser stops the block at the star and everything the agent
said after it leaves its own answer.  It cannot be shifted a level down
either, since level 1 is the conversation's own level (the exchange heading).
So the words are kept and the size is lost: `# Title' -> `*Title*'.  `#' at
column 0 is an Org COMMENT, so doing nothing would hide the heading from every
export instead."
  (should (equal "*Ship it*" (ao--md "# Ship it")))
  (should (equal "*Plan*" (ao--md "## Plan")))
  (should (equal "*Deep*" (ao--md "###### Deep")))
  ;; a heading with inline markup keeps it, converted inside the bold
  (should (equal "*see =x=*" (ao--md "# see `x`")))
  ;; no space after the hashes is not a markdown heading (and `#' stays a comment)
  (should (equal "#hashtag" (ao--md "#hashtag")))
  ;; an indented heading is a code-ish line, not a heading in either syntax
  (should (equal "  ## not a heading" (ao--md "  ## not a heading"))))

(ert-deftest test-agent-org-markdown-star-bullets-become-dashes ()
  "`* item' is a level-1 HEADLINE in Org, not a bullet.
Measured with `org-element-parse-buffer': two `* item' lines report two
headlines and no list -- so an agent's ordinary bullet list would shred the
turn around it.  `- ' is the bullet both syntaxes agree on."
  (should (equal "- item" (ao--md "* item")))
  (should (equal "- a\n- b" (concat (ao--md "* a") "\n" (ao--md "* b"))))
  (should (equal "  - nested" (ao--md "  * nested")))
  ;; already-Org bullets, ordered lists and checkboxes are left alone
  (should (equal "- keep" (ao--md "- keep")))
  (should (equal "+ keep" (ao--md "+ keep")))
  (should (equal "1. keep" (ao--md "1. keep")))
  (should (equal "- [ ] todo" (ao--md "- [ ] todo"))))

(ert-deftest test-agent-org-markdown-emphasis-becomes-org-markup ()
  "One star means italic in Org and bold in Markdown, so `**' must go first.
The pass is single-scan, not two rewrites: converting `**b**' to `*b*' and
then running the `*i*' rule over the RESULT would italicise the bold.
Backquoted code becomes `=' verbatim (Org's own inline-code marker), and
underscores are never touched -- `foo_bar_baz' is an identifier, and a
second pass over it would print it as emphasis."
  (should (equal "*bold* text" (ao--md "**bold** text")))
  (should (equal "/emph/ here" (ao--md "*emph* here")))
  (should (equal "a =b= c" (ao--md "a `b` c")))
  (should (equal "*a* /b/ =c=" (ao--md "**a** *b* `c`")))
  (should (equal "snake_case_stays" (ao--md "snake_case_stays")))
  (should (equal "** not emphasis" (ao--md "** not emphasis"))))

(ert-deftest test-agent-org-markdown-link-becomes-org-link ()
  "Brackets first, description second: `[[URL][TEXT]]'.
Org's own syntax, in the order the org-syntax reference pins -- a Markdown
link left alone exports as text plus a bare autolink."
  (should (equal "[[https://x.org][docs]]" (ao--md "[docs](https://x.org)")))
  (should (equal "see [[file:a.el][a]] now" (ao--md "see [a](file:a.el) now"))))

(ert-deftest test-agent-org-markdown-fence-becomes-a-src-block ()
  "The fence line and its SRC-P flag travel together.
A fenced block is the one place where markdown markup is TEXT, so the state
flag decides which lines get converted at all -- and inside the block the
`#' and `*' rules must not fire (an Org comment marker or a headline in the
middle of a code sample would corrupt the sample).  `#+end_src' is emitted
for the closing fence, whatever language the opening one named."
  (let ((open (agent-org-buffer--markdown-line "```sh" nil)))
    (should (equal "#+begin_src sh" (car open)))
    (should (equal t (cdr open)))
    (let ((body (agent-org-buffer--markdown-line "# a shell comment" (cdr open))))
      (should (equal "# a shell comment" (car body)))
      (should (equal t (cdr body))))
    (let ((close (agent-org-buffer--markdown-line "```" (cdr open))))
      (should (equal "#+end_src" (car close)))
      (should (equal nil (cdr close))))))

(ert-deftest test-agent-org-markdown-table-rule-becomes-org-columns ()
  "Markdown's alignment rule is not Org's separator row.
Measured with `org-export-string-as': `|---|---|' after a header does give a
`thead', but `|:--|:-:|--:|' does not -- the table loses its header and the
rule exports as a data row (`--:' becomes an em-dash).  So every rule line
becomes Org's own writer shape `|---+---|', which has no colons to misread."
  (should (equal "|---+---|" (ao--md "|---|---|")))
  (should (equal "|---+---+---|" (ao--md "|:--|:-:|--:|")))
  (should (equal "| a | b |" (ao--md "| a | b |"))))

(ert-deftest test-agent-org-markdown-horizontal-rule-stays-inert ()
  "`---' under a paragraph is a HEADLINE in Org.
Org reads `Some text' + `---' as one level-2 heading, so markdown's
divider would swallow the sentence above it.  One space of indent takes
that reading away (a headline must start at column 0) and still reads as a
divider in the buffer."
  (should (equal " ---" (ao--md "---")))
  (should (equal " ***" (ao--md "***")))
  (should (equal " -----  " (ao--md "-----  "))))

(ert-deftest test-agent-org-markdown-conversion-off-leaves-text-verbatim ()
  "The switch is the way out: nil and the agent's markup bytes land as sent.
Verbatim is a rendering sentence, not a licence to break the block, so the
one-space indent that keeps a `*' from ending the quote still applies -- but
`#' is never rewritten to a bold and the agent's own stars survive."
  (let ((agent-org-convert-markdown nil)
        (buf (agent-org-buffer-create "mdoff")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-chunk buf "# Title\n* item\n" nil)
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (string-match-p "^ # Title$" text))
      (should (string-match-p "^ \\* item$" text)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-markdown-streaming-writes-every-chunk-once ()
  "A line appears as it arrives and is converted when it stops being partial.
Chunks stop wherever the model's tokenizer stopped, so `**bold' can end one and
`**' open the next.  Holding the line until its newline (the first design) made
a one-line reply invisible until the turn ended — the user watched an empty
buffer while the agent answered.  So the last line is written as PROVISIONAL
text and the next chunk rewrites that region: the stars are on screen only while
they are still the whole truth, the converted form appears exactly once, and in
the same place."
  (let ((buf (agent-org-buffer-create "mdsplit")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-chunk buf "say **bold" nil)
    (with-current-buffer buf
      ;; nothing waits for a newline: the answer is on screen mid-word
      (should (string-match-p "say \\*\\*bold" (buffer-string))))
    (agent-org-buffer-append-chunk buf "** alpha\n" nil)
    (with-current-buffer buf
      (should (string-match-p "say \\*bold\\* alpha" (buffer-string)))
      (should-not (string-match-p "\\*\\*bold\\*\\*" (buffer-string)))
      ;; REWRITTEN, not appended: one copy of the words that were provisional.
      ;; (`ao--count-substrings' is case-INsensitive, which is why the probe word
      ;; is not something the buffer's own `#+TODO:' keyword line
      ;; line contains.)
      (should (equal 1 (ao--count-substrings "say")))
      (should (equal 1 (ao--count-substrings "alpha"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-markdown-two-emphasis-runs-terminate ()
  "A line with TWO markup runs converts and does not hang the scan.
The helpers read the global match data after calling `string-match' themselves,
which is how `**bold** *emph*' made `agent-org-buffer--md-inline' advance to a
position BEHIND the match it had just consumed and rescan it forever.  Asserted
as a conversion result, because the bug's other symptom was an Emacs that never
came back."
  (should (equal "*bold* /emph/ done"
                 (ao--md "**bold** *emph* done")))
  (should (equal "*a* b *c*" (ao--md "**a** b **c**")))
  ;; and arithmetic stars still survive the scan whole
  (should (equal "2*3*4 plus 5*6*7" (ao--md "2*3*4 plus 5*6*7"))))

(ert-deftest test-agent-org-markdown-turn-end-flushes-the-last-line ()
  "Nothing may be held when the turn closes, and an open fence must close.
The final line of a reply usually arrives with no trailing newline, so a
streaming-only rule would drop it; and a `#+begin_src' left open swallows
everything after it in the buffer AND in the transcript, which is the one
corruption this feature must never cause."
  (let ((buf (agent-org-buffer-create "mdflush")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-chunk buf "## Tail" nil)
    (agent-org-buffer-end-agent-turn buf)
    ;; `##' is a markdown heading, which inside the reply's quote becomes the
    ;; bold `*Tail*' (a headline of any level would end the block) -- and it is
    ;; in the buffer BEFORE the turn closes, because a reply's last line usually
    ;; never sends a newline.
    (should (string-match-p "^ \\*Tail\\*$"
                            (with-current-buffer buf (buffer-string))))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-chunk buf "```sh\nls" nil)
    (agent-org-buffer-end-agent-turn buf)
    (let ((text (with-current-buffer buf (buffer-string))))
      ;; `\\+' because in an Emacs regexp `+' is an interval operator, so
      ;; "^#\\+begin" asks for one-or-more hashes and never matches the keyword.
      ;; One leading space: the whole answer sits inside the quote block.
      (should (string-match-p "^ #\\+begin_src sh$" text))
      (should (string-match-p "^ #\\+end_src$" text))
      (with-current-buffer buf
        (should (org-element-map (org-element-parse-buffer) 'src-block
                  (lambda (e) t) nil 'first-match))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-markdown-chunks-after-a-newline-still-write ()
  "A chunk that ENDS a line must not leave the converter holding a dead marker.
The line a chunk completes is the last thing the provisional region held, so
the next chunk looks for its marker to rewrite it -- and a marker detached with
`set-marker' but still stored in the variable answers `markerp' t and
`marker-position' nil, which reaches `goto-char' as nil.  Reproduced by feeding
three chunks in order, because two is not enough to hit it: the crash happens on
the chunk AFTER the one that ended a line."
  (let ((buf (agent-org-buffer-create "mdthree")))
    (agent-org-buffer-start-agent-turn buf nil)
    (dolist (chunk (list "first " "line\nsecond " "line\nthird"))
      (agent-org-buffer-append-chunk buf chunk nil))
    (agent-org-buffer-end-agent-turn buf)
    (with-current-buffer buf
      (should (string-match-p "first line" (buffer-string)))
      (should (string-match-p "second line" (buffer-string)))
      (should (string-match-p "third" (buffer-string)))
      ;; and the lines are in the order they arrived, one copy each ("line"
      ;; appears twice: once in "first line", once in "second line")
      (should (equal 2 (ao--count-substrings "line"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-markdown-chunk-ending-with-newline-starts-a-new-line ()
  "A chunk that ENDS on a newline must not glue the next chunk onto that line.
Tokenizer stops land ON newlines constantly, so `say this\n' is an ordinary
chunk.  `split-string' drops the empty string after a trailing separator, which
makes an all-complete chunk look like one whose last line is still arriving --
and since the stored fragment is what the next chunk is concatenated to, the
newline vanished and `next that' joined `say this' as one line.  Asserted on the
buffer rather than on the fragment variable, because what a reader sees is the
contract."
  (let ((buf (agent-org-buffer-create "mdglue")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-chunk buf "say this\n" nil)
    (agent-org-buffer-append-chunk buf "next that\n" nil)
    ;; a heading arriving as its own chunk is the same case, and the one a user
    ;; would notice: a line of stars welded to the prose above it is not a
    ;; heading at all
    (agent-org-buffer-append-chunk buf "# Heading" nil)
    (agent-org-buffer-end-agent-turn buf)
    (with-current-buffer buf
      (should (string-match-p "^ say this$" (buffer-string)))
      (should (string-match-p "^ next that$" (buffer-string)))
      (should (string-match-p "^ \\*Heading\\*$" (buffer-string)))
      (should-not (string-match-p "thisnext" (buffer-string))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-markdown-converts-the-user-prompt-too ()
  "Both sides of the conversation are Org text to a reader.  The prompt is
one whole message, so its lines convert as it becomes the exchange heading
and its body, and the agent still receives the markdown the user typed -- the
conversion is rendering, never the wire.  `# Asking' cannot stay a headline
(the conversation owns level 1), so it renders as the bold the reply's own
headings use; `* please' is a bullet, which both syntaxes agree on."
  (let ((buf (agent-org-buffer-create "mduser")))
    (agent-org-buffer-begin-exchange buf "# Asking\n* please")
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (string-match-p "^\\* \\*Asking\\*$" text))
      (should (string-match-p "^ - please$" text))
      (should-not (string-match-p "^# Asking$" text))
      (should-not (string-match-p "^\* please$" text)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-markdown-converted-text-is-still-frozen ()
  "Rewriting the text must not lose the read-only property.  Every render
site protects the region it inserted; the converter changes what is inserted,
not where or under what property."
  (let ((buf (agent-org-buffer-create "mdfrozen")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-chunk buf "# H\n**b**\n" nil)
    (agent-org-buffer-end-agent-turn buf)
    (with-current-buffer buf
      (goto-char (point-min))
      (should (re-search-forward "^ \\*H\\*$" nil t))
      (should (get-text-property (match-beginning 0) 'read-only)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-one-drawer-board-redraw-cost ()
  "One drawer for the lines AND the bodies means each new call rewrites the
earlier ones, so the shape has to be measured, not assumed.  This is a heavy
ordinary turn: 20 calls, 40 output lines each, every update arriving with
content -- so the board is redrawn 20 times over a body that grows to 800
lines, each redraw a delete, an insert and the read-only protection of the
result.  Printed with a loose ceiling on purpose: if this ever reaches
seconds on this machine, the drawer must grow APPEND-ONLY instead, and
`agent-org-buffer--tool-board-body' is the one place that builds it."
  (let* ((buf (agent-org-buffer-create "outcost"))
         (body (let ((out ""))
                 (dotimes (_ 40)
                   (setq out (concat out "output line of a real tool result\n")))
                 out))
         (start (float-time)))
    (agent-org-buffer-start-agent-turn buf nil)
    (dotimes (i 20)
      (agent-org-buffer-insert-tool
       buf `((toolCallId . ,(format "tc%d" i))
             (title . ,(format "call %d" i)) (status . "completed")
             ,@(ao--tool-text-block body))))
    (let ((elapsed (- (float-time) start)))
      (princ (format "\ntool board: 20 calls x 40 lines in %.1f ms (%.1f ms per redraw)\n"
                     (* elapsed 1000) (/ (* elapsed 1000) 20.0)))
      (should (< elapsed 3.0)))
    (with-current-buffer buf
      (should (= 1 (ao--count-occurrences (buffer-string) "^:tool:$")))
      (should (= 20 (ao--count-occurrences (buffer-string) "^  - COMPLETE "))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-markdown-conversion-cost-per-line ()
  "The overhead the porting note asked to measure, printed and pinned as a ceiling.
A reply is tens of lines and a replay is thousands, all painted in one
synchronous pass on a 4 GB machine -- if this ever cost more than about a
millisecond per line the switch should default off rather than make the user
wait.  Measured here (Celeron, spinning disk): 115 us per markup-DENSE line,
and plain prose is several times cheaper, so a 50-line answer is ~2 ms and a
2000-line replay ~230 ms -- against the 3-15 ms a transcript boundary write
already costs (CONVENTIONS.md §14).  The ceiling is loose on purpose (a flaky
bound is worse than none) and the printed numbers are the report."
  (let* ((dense "**bold** *emph* and `code` see [docs](https://x.org)\n")
         (plain "The quick brown fox jumps over the lazy dog, for scale.\n")
         (n 400))
    (dolist (spec (list (cons "dense" dense) (cons "plain" plain)))
      (let* ((text (let ((out ""))
                     (dotimes (_ n) (setq out (concat out (cdr spec))))
                     out))
             (lines (length (split-string text "\n" t)))
             (start (float-time)))
        (agent-org-buffer--markdown-convert text)
        (let ((elapsed (- (float-time) start)))
          (princ (format "\nmarkdown->org %s: %d lines in %.1f ms (%.1f us/line)\n"
                         (car spec) lines (* elapsed 1000)
                         (/ (* elapsed 1000000) lines)))
          (should (< elapsed 1.0)))))))

;;;; The agent learns which model, session and agent it is

(defun ao--all-prompt-blocks ()
  "Every `session/prompt' captured by `ao--capture-wire', oldest first.
Each entry is the list of content blocks as the wire would carry them, so
a test can see the user's own block and the client's context block apart.
Needs `ao--wire-prompt-texts': the mock's request builder answers NIL, and
a NIL request would be captured under NIL and be invisible here."
  (mapcar (lambda (entry)
            (append (map-elt (map-elt (plist-get (cdr entry) :request) ':params)
                             'prompt)
                    nil))
          (reverse (seq-filter (lambda (entry)
                                 (equal (car entry) "session/prompt"))
                               ao--sent))))

(defun ao--sent-blocks (sent)
  "The content blocks of every prompt in SENT, oldest first.
The `cl-letf' idiom the queue tests use (a stubbed
`acp-make-session-prompt-request' that hands back its `:prompt' argument),
so this is the same view `ao--all-prompt-blocks' gives the
`ao--capture-wire' idiom."
  (mapcar (lambda (kw) (plist-get kw :request)) (reverse sent)))

(ert-deftest test-agent-org-send-appends-a-context-block-after-the-users-words ()
  "The prompt is two text blocks: the user's words, then the client's facts.
The user's block stays EXACTLY what was typed — this is the one place the
client adds to the wire, and it adds beside the request rather than inside
it, so an agent quoting the question quotes the person.  Appending LAST is
also what keeps every existing reader of the first block honest."
  (let ((sent nil))
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest kw) (push kw sent)))
              ((symbol-function 'acp-make-session-prompt-request)
               (lambda (&rest a) (plist-get a :prompt))))
      (let ((pair (ao--make-test-session "ctx-first"))
            (agent-org-send-session-context t))
        (with-current-buffer (car pair)
          (agent-org-buffer-insert-prompt (car pair))
          (ao--type "What is a monad?")
          (agent-org-send))
        (let ((blocks (car (ao--sent-blocks sent))))
          (should (= 2 (length blocks)))
          (should (equal "What is a monad?" (map-elt (car blocks) 'text)))
          (should (equal "text" (map-elt (cadr blocks) 'type)))
          (should (string-prefix-p "<agent-org-context>"
                                   (map-elt (cadr blocks) 'text)))
          (should (string-suffix-p "</agent-org-context>\n"
                                   (map-elt (cadr blocks) 'text))))
        (kill-buffer (car pair))))))

(ert-deftest test-agent-org-context-block-names-the-agent-model-and-session-id ()
  "The block carries the three facts, in the form the agent can quote back.
An agent asked \"which model are you?\" answers from its own idea of the
default, which is wrong the moment the client has selected another model
through `session/set_config_option' — the whole reason OpenCode-fronted
MiniMax exists.  Both the label and the id go: the label is what a person
reads, the id is what a commit trailer or a config request needs, and the
agent cannot derive one from the other.
The exact text is the spec here, because a format an agent has to guess at
is a format it will misquote."
  (ao--capture-wire
    (ao--wire-prompt-texts
      (let ((agent-org-send-session-context t)
            (buf (ao--chat-on-model "minimax/MiniMax-M3" "MiniMax M3"
                                    "7c1f-abc")))
        (with-current-buffer buf
          (agent-org-buffer-insert-prompt buf)
          (ao--type "hi")
          (agent-org-send))
        (should (equal (map-elt (cadr (car (ao--all-prompt-blocks))) 'text)
                       (concat
                        "<agent-org-context>\n"
                        "Client metadata about this connection,"
                        " not part of the user's request.\n"
                        "agent: Qoder (qoder)\n"
                        "model: MiniMax M3 (minimax/MiniMax-M3)\n"
                        "session: 7c1f-abc\n"
                        "</agent-org-context>\n")))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-context-block-follows-a-model-change ()
  "The block is built per turn, because the middle fact can change mid-session.
`C-c C-m' is a normal thing to do between two questions; a block computed
once at session start would tell the agent a model that stopped being true
turn one ago, which is worse than saying nothing."
  (ao--capture-wire
    (ao--wire-prompt-texts
      ;; Not `ao--chat-on-model': it advertises ONE model, and a switch needs
      ;; both ids in the option list, because `agent-org-set-session-model'
      ;; rejects an id the agent never offered.
      (let* ((agent-org-send-session-context t)
             (agent-org-session-strategy 'new)
             (models (list (cons "qmodel" "QModel")
                           (cons "qmodel-large" "QModel Large")))
             (buf (agent-org-start 'qoder)))
        (ao--drive "initialize" ao--fake-init-resp)
        (ao--drive "session/new" (ao--config-resp "qmodel" models "sid-ctx"))
        (with-current-buffer buf
          (agent-org-buffer-insert-prompt buf)
          (ao--type "first")
          (agent-org-send))
        ;; the turn must END before the second prompt: a streaming session
        ;; queues it, and a queued prompt drains with its own turn, its own
        ;; block — which is a different test
        (ao--drive "session/prompt" nil)
        (with-current-buffer buf (agent-org-set-session-model "qmodel-large"))
        (ao--drive "session/set_config_option"
                   (ao--config-resp "qmodel-large" models "sid-ctx"))
        (with-current-buffer buf
          (agent-org-buffer-insert-prompt buf)
          (ao--type "second")
          (agent-org-send))
        (let ((blocks (ao--all-prompt-blocks)))
          (should (= 2 (length blocks)))
          (should (string-match-p "model: QModel (qmodel)"
                                  (map-elt (cadr (car blocks)) 'text)))
          (should (string-match-p "model: QModel Large (qmodel-large)"
                                  (map-elt (cadr (nth 1 blocks)) 'text)))
          (should (equal "second" (map-elt (car (nth 1 blocks)) 'text))))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-context-block-can-be-switched-off ()
  "nil sends only what the user typed.
The documented rule is that the agent receives the user's text unchanged;
this is the escape hatch that keeps that sentence true for a person who
does not want the client speaking for them, and the proof that the block
is an addition and not a rewrite of the draft."
  (let ((sent nil))
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest kw) (push kw sent)))
              ((symbol-function 'acp-make-session-prompt-request)
               (lambda (&rest a) (plist-get a :prompt))))
      (let ((pair (ao--make-test-session "ctx-off"))
            (agent-org-send-session-context nil))
        (with-current-buffer (car pair)
          (agent-org-buffer-insert-prompt (car pair))
          (ao--type "just me")
          (agent-org-send))
        (let ((blocks (car (ao--sent-blocks sent))))
          (should (= 1 (length blocks)))
          (should (equal "just me" (map-elt (car blocks) 'text))))
        (kill-buffer (car pair))))))

(ert-deftest test-agent-org-context-block-drops-the-model-line-without-a-model ()
  "An agent that advertises no model option gets a block with no model line.
Goose reports no `configOptions' of this shape; a `model: nil' line would
be the agent told something false, and \"unknown\" is not a model.  The
other two facts are still worth having, so the block goes anyway."
  (let ((sent nil))
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest kw) (push kw sent)))
              ((symbol-function 'acp-make-session-prompt-request)
               (lambda (&rest a) (plist-get a :prompt))))
      (let ((pair (ao--make-test-session "ctx-nomodel"))
            (agent-org-send-session-context t))
        (with-current-buffer (car pair)
          (agent-org-buffer-insert-prompt (car pair))
          (ao--type "hello")
          (agent-org-send))
        (let ((ctx (map-elt (cadr (car (ao--sent-blocks sent))) 'text)))
          ;; `^' in an Elisp regexp is the string's start, not the line's, so
          ;; the check is on the lines themselves.
          (should-not (seq-some (lambda (line) (string-prefix-p "model:" line))
                                (split-string ctx "\n" t)))
          (should (string-match-p "session: sid-test" ctx))
          ;; the label is the buffer's own provider name — this fixture was
          ;; created with "ctx-nomodel" rather than started, so that is what
          ;; a person would read on its header line — and the id in brackets
          ;; is the session's, which is the point of sending both
          (should (string-match-p "agent: ctx-nomodel (test)" ctx))
          ;; five lines, not six: the absent fact leaves no gap
          (should (= 5 (length (split-string ctx "\n" t)))))
        (kill-buffer (car pair))))))

(ert-deftest test-agent-org-drained-prompt-carries-the-same-context-block ()
  "A prompt that waited its turn is sent through the same door, so it
carries the same facts.  `agent-org--send-turn' is the single choke point
for typed and drained prompts alike; a context block built in
`agent-org-send' instead would go out on the first question of a session
and never again, which is exactly the turn a re-ordered queue makes most
different."
  (let ((sent nil))
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest kw) (push kw sent)))
              ((symbol-function 'acp-make-session-prompt-request)
               (lambda (&rest a) (plist-get a :prompt))))
      (let* ((pair (ao--make-test-session "ctx-drain"))
             (buf (car pair))
             (session (cdr pair))
             (agent-org-send-session-context t))
        (setf (plist-get session :streaming) t)
        (with-current-buffer buf
          (agent-org-buffer-set-status buf :state 'streaming :message "Sending…")
          (agent-org-buffer-insert-prompt buf)
          (ao--type "queued one")
          (agent-org-send))                       ; queued: no send yet
        (should (= 0 (length sent)))
        (setf (plist-get session :streaming) nil)
        (agent-org--drain-queue session buf)
        (let ((blocks (car (ao--sent-blocks sent))))
          (should (equal "queued one" (map-elt (car blocks) 'text)))
          (should (string-match-p "session: sid-test"
                                  (map-elt (cadr blocks) 'text))))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-context-block-flattens-an-agent-supplied-label ()
  "A model label is agent text, and agent text can contain newlines.
One newline inside the block is a line the reading code — and the agent
quoting it back — has to guess about, so each value goes on exactly one
line.  Flattening must not TRUNCATE: a half-model-name on the wire is the
lie this block exists to prevent, and the standing rule is never to trust
a harness label to be short (AGENTS.md)."
  (ao--capture-wire
    (ao--wire-prompt-texts
      (let* ((agent-org-send-session-context t)
             (long (make-string 80 ?x))
             (buf (ao--chat-on-model "m\n2" (format "Big\nModel %s" long)
                                    "sid-flat")))
        (with-current-buffer buf
          (agent-org-buffer-insert-prompt buf)
          (ao--type "hi")
          (agent-org-send))
        (let ((ctx (map-elt (cadr (car (ao--all-prompt-blocks))) 'text)))
          (should (equal 6 (length (split-string ctx "\n" t))))
          ;; one line, so the whole value sits between "model: " and the
          ;; closing tag with no break in it
          (should (equal 1 (length (seq-filter (lambda (line) (string-prefix-p "model:" line))
                                               (split-string ctx "\n" t)))))
          (should (string-match-p (concat "model: Big Model " long
                                          " (m 2)")
                                  ctx))
          ;; the id is flattened too, and it is still there in full: the
          ;; agent may need to name it in a request
          (should-not (string-match-p "m\n2" ctx))
          (should-not (string-match-p "Big\n" ctx))
          (should-not (string-match-p "…" ctx)))
        (kill-buffer buf)))))

;;;; One heading per exchange: the prompt is the heading, the answer a quote

(defun ao--quote-blocks ()
  "Every quote block in the current buffer, as (BEGIN END TEXT).
The parser is the only witness that matters here: a `* ' line inside
`#+begin_quote' does not stay in the block (measured: the parser ENDS the
block, makes a headline, and the answer falls out of its fold), so a test
that only greps the text would pass on a broken turn.  Call it with the chat
buffer current."
  (let ((data (org-element-parse-buffer)))
    (org-element-map data 'quote-block
      (lambda (q)
        (list (org-element-property :begin q)
              (org-element-property :end q)
              (buffer-substring-no-properties
               (org-element-property :begin q)
               (org-element-property :end q)))))))

(defun ao--send-one (prompt)
  "Type PROMPT in this buffer's box and send it through the real `agent-org-send'.
The box is created first, because that is the state a live chat is in: a
test that types without a box is testing the error path.  Leaves the
session streaming, so the caller decides how the turn ends."
  (agent-org-buffer-insert-prompt (current-buffer))
  (ao--type prompt)
  (agent-org-send))

(ert-deftest test-agent-org-exchange-heading-wears-the-prompt ()
  "ONE heading per prompt-response pair, and its text IS the prompt.
User order: \"From now on, there will be ONE heading for each
prompt-response pair.  The heading will contain the prompt.\"  So the sent
question is no longer echoed under a `* User' heading: it becomes the
heading itself, and the exchange has exactly one.  The type-ahead box keeps
its `* User' heading because it is an input control, not a pair."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (ao--send-one "What is the capital of France?")
        (should (equal 1 (ao--count-occurrences (buffer-string)
                                               "^\\* What is the capital of France\\?$")))
        (should (equal 1 (ao--count-occurrences (buffer-string) "^\\* User$")))
        ;; and nothing of the question is left as body text under a heading:
        ;; the heading is the record
        (should-not (string-match-p "\nWhat is the capital" (buffer-string))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-answer-lands-in-a-quote-block-authored-by-the-model ()
  "The reply is quoted, and the quote names the model as its author.
User order: \"the response should be contained in an Org quote block, with
the narrator/author as the model name\", and the manual's mechanism for an
author on a quotation is the Texinfo affiliated keyword \(info
\"(org) Quotations in Texinfo export\"\): `#+ATTR_TEXINFO: :author NAME' on
the line before `#+BEGIN_QUOTE'.  The keyword line is where the old
`* <model>' heading's provenance moved to: the heading is the question now,
and it is written once, so a later `C-c C-m' cannot rewrite an older answer."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (ao--send-one "Capital?")
        (agent-org-buffer-append-chunk buf "Paris.\n" (agent-org-buffer--session))
        (agent-org-buffer-end-agent-turn buf)
        (should (apply #'ao--ordered (buffer-string)
                       (list "^\\* Capital\\?$"
                             "^#\\+ATTR_TEXINFO: :author QModel$"
                             "^#\\+begin_quote$"
                             "Paris\\."
                             "^#\\+end_quote$"
                             "^\\* User$")))
        (should (equal 1 (length (ao--quote-blocks))))
        ;; the answer is INSIDE the block, not merely somewhere after it
        (should (string-match-p "Paris\\." (nth 2 (car (ao--quote-blocks))))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-quote-is-closed-at-every-moment-of-a-turn ()
  "Streaming writes INTO the block, before its `#+end_quote' line.
A turn is painted chunk by chunk, and an open `#+begin_quote' is not a
cosmetic problem: it swallows the drawers drawn at a boundary, the
type-ahead box, and the rest of the transcript file.  So the closing marker
is placed when the answer starts and the text is inserted above it — the
buffer is valid Org while the agent is still talking.  Asserted mid-turn,
with a chunk still to come."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (ao--send-one "Talk")
        (agent-org-buffer-append-chunk buf "Half a sent" (agent-org-buffer--session))
        (should (equal 1 (length (ao--quote-blocks))))
        (should (string-match-p "Half a sent" (nth 2 (car (ao--quote-blocks)))))
        (agent-org-buffer-append-chunk buf "ence.\nSecond line.\n"
                                       (agent-org-buffer--session))
        (should (equal 1 (length (ao--quote-blocks))))
        ;; the body line carries its one space of guard indent (the answer can
        ;; contain a `*' line, and only column 0 is safe from becoming a
        ;; headline that ends the block).  The pattern's newline is a real
        ;; `\n' in the string, not `\\n': in an Elisp regexp the two-character
        ;; escape does not match a newline.
        (should (string-match-p "Half a sentence\\.\n Second line"
                                (nth 2 (car (ao--quote-blocks)))))
        (agent-org-buffer-end-agent-turn buf)
        (should (equal 1 (length (ao--quote-blocks)))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-reply-cannot-close-its-own-quote ()
  "A reply that QUOTES Org markup is still only text inside the block.
Measured with `org-element-parse-buffer': a line reading `#+end_quote'
closes the block EVEN INDENTED, so the agent's own words can end the
structure they are inside — and everything after it, including the next
chunk and the drawers, leaves the quote.  The guard escapes the leading
`#', which is not a marker and still reads as the text it is."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (ao--send-one "Quote this")
        (agent-org-buffer-append-chunk buf "#+end_quote\nstill inside\n"
                                       (agent-org-buffer--session))
        (should (equal 1 (length (ao--quote-blocks))))
        (let ((text (nth 2 (car (ao--quote-blocks)))))
          (should (string-match-p "still inside" text))
          (should (string-match-p "#\\+end_quote" text)))
        ;; and the chunk after the hostile line still lands in the block
        (agent-org-buffer-append-chunk buf "and more.\n"
                                       (agent-org-buffer--session))
        (should (string-match-p "and more" (nth 2 (car (ao--quote-blocks)))))
        (agent-org-buffer-end-agent-turn buf))
      (kill-buffer buf))))

(ert-deftest test-agent-org-verbatim-reply-cannot-break-the-quote ()
  "With conversion off, agent text is still inert inside the block.
`agent-org-convert-markdown' nil means the agent's bytes land verbatim, and
a Markdown bullet is a `* ' line at column 0 — which the parser turns into a
HEADLINE that ends the block (measured: no quote block, two headlines, and
the answer scattered over the buffer).  The guard indents it, which keeps it
a list (measured: an indented `- item' is still an unordered list) and keeps
the turn one heading."
  (ao--capture-wire
    (let ((agent-org-convert-markdown nil)
          (buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (ao--send-one "Raw please")
        (agent-org-buffer-append-chunk buf "* one\n* two\n"
                                       (agent-org-buffer--session))
        (should (equal 1 (length (ao--quote-blocks))))
        (should (equal 2 (ao--count-occurrences (buffer-string) "^\\* ")))
        ;; one heading for the exchange plus the box: nothing invented by the
        ;; agent's bullets
        (should (equal 1 (length (ao--quote-blocks))))
        (agent-org-buffer-end-agent-turn buf))
      (kill-buffer buf))))

(ert-deftest test-agent-org-activity-lands-in-arrival-order-under-an-exchange ()
  "Position in the exchange is NOTIFICATION ORDER, exactly like agent-shell.
The user's order: \"Keep the activity order just like agent-shell.\"  In
agent-shell every `session/update' branch calls the same fragment placer
(`agent-shell-ui--update-fragment', agent-shell-ui.el:327), which appends at
`point-max' or after the group's last child -- so the buffer order IS arrival
order and an answer can never move above the reasoning that preceded it.
Measured here: a thought and a tool call arriving BEFORE the first answer
chunk used to be pushed BELOW the quote, because opening a turn wrote its
furniture at that instant.  That is a kind grouping (answer, then thinking,
then tools), not an activity record, and the agent's reasoning is the thing
that came first.

So the quote block opens when the first TEXT arrives and not before, and each
drawer keeps the position it was first given.  The reply is still one block
(§1), and no drawer can land inside it: every body line of the answer is
indented one space by `agent-org-buffer--block-safe-lines', so a `:thinking:'
or `:tool:' at column 0 is never the reply's own text -- which is what makes
searching the whole turn region for a drawer safe again."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (let ((session (agent-org-buffer--session)))
          (agent-org-buffer-begin-exchange buf "Do it")
          (agent-org-buffer-append-thought buf "hmm\n")
          (agent-org-buffer-insert-tool buf '((title . "read_file")
                                             (toolCallId . "t1")
                                             (status . "pending")))
          (agent-org-buffer-append-chunk buf "the answer\n" session)
          ;; and the activity KEEPS going after the answer started
          (agent-org-buffer-append-thought buf " then more\n")
          (agent-org-buffer-insert-tool buf '((title . "shell")
                                             (toolCallId . "t2")
                                             (status . "completed")))
          (agent-org-buffer-end-agent-turn buf)
          (let ((text (buffer-string)))
            ;; heading, then answer in quote, then drawers below
            (should (apply #'ao--ordered text
                           (list "^\\* Do it$"
                                 "^#\\+begin_quote$" "the answer"
                                 "^#\\+end_quote$"
                                 "^:thinking:$" "hmm" "then more"
                                 "^:tool:$" "  - TODO read_file" "  - COMPLETE shell")))
            ;; ONE drawer of each kind for the whole exchange, repainted in
            ;; place, never a second one below the answer
            (should (equal 1 (ao--count-occurrences text "^:thinking:$")))
            (should (equal 1 (ao--count-occurrences text "^:tool:$")))
            (should (equal 1 (ao--count-occurrences text "^  - COMPLETE shell$")))
            ;; the answer is one intact block, and it holds no drawer marker
            (should (equal 1 (length (ao--quote-blocks))))
            (let ((block (nth 2 (car (ao--quote-blocks)))))
              (should (string-match-p "the answer" block))
              (should-not (string-match-p "^:thinking:$" block))
              (should-not (string-match-p "^:tool:$" block)))))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-drawers-land-below-the-quote ()
  "The turn's furniture keeps one order: answer, then thinking, then tools.
`:thinking:' and `:tool:' are drawn at the end of the turn region, which now
ends below the quote's `#+end_quote' line — and they must be, because a
drawer inside a quote block is not a drawer the parser sees (measured: a
`:thinking:' line inside the block is TEXT), while `--redraw-drawer' searches
the region TEXTUALLY.  So the answer's own `:thinking:' line must not become
the drawer."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (let ((session (agent-org-buffer--session)))
          (ao--send-one "Do it")
          (agent-org-buffer-append-chunk buf "start\n:thinking:\nfake\n" session)
          (agent-org-buffer-append-thought buf "a real thought" )
          (agent-org-buffer-insert-tool buf '((title . "shell") (toolCallId . "t1")))
          (agent-org-buffer-append-chunk buf "more answer\n" session)
          (agent-org-buffer-end-agent-turn buf)
          ;; the answer is one intact block that still holds the fake marker
          (should (equal 1 (length (ao--quote-blocks))))
          (should (string-match-p ":thinking:" (nth 2 (car (ao--quote-blocks)))))
          (should (string-match-p "more answer" (nth 2 (car (ao--quote-blocks)))))
          ;; and the real drawers are below it, in order
          (should (apply #'ao--ordered (buffer-string)
                         (list "^#\\+end_quote$" "^:thinking:$" "a real thought"
                               "^:tool:$" "  - TODO shell")))
          (should (equal 1 (ao--count-occurrences (buffer-string) "^ a real thought$")))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-markdown-heading-in-a-reply-becomes-a-bold-line ()
  "A Markdown heading cannot be an Org headline inside a quote, so it is bold.
`agent-org-buffer--md-structure' used to shift `# Title' down to `** Title'
because level 1 belonged to the conversation.  Inside the block a headline
of ANY level ends it (measured: `** shifted heading' gives no quote block and
two headlines), and Org has no heading in a block — the closest rendering
that survives is the text bold on its line.  `*Title*' is safe: a headline
needs a space after the stars."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (ao--send-one "Write docs")
        (agent-org-buffer-append-chunk buf "# Setup\nbody text\n"
                                       (agent-org-buffer--session))
        (agent-org-buffer-end-agent-turn buf)
        (should (equal 1 (length (ao--quote-blocks))))
        (should (string-match-p "^ \\*Setup\\*$"
                                (nth 2 (car (ao--quote-blocks)))))
        (should-not (string-match-p "^\\*\\* Setup$" (buffer-string))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-multi-line-prompt-keeps-its-rest-under-the-heading ()
  "A heading is one line, so a multi-line prompt keeps its other lines as body.
The first line is the heading because that is what a person scans; the rest
stays in the exchange, because the prompt is the user's own words and a
record that quietly dropped lines 2..n is worse than a long heading.  Those
lines are guarded the same way the answer is: a `*' at column 0 in the second
line would otherwise cut the exchange in two.  The prompt goes in through
`agent-org-buffer-begin-exchange' rather than the box, because typing a `*' at
column 0 makes an Org headline IN THE BOX and the box stops being a box — a
separate, older property of a live prompt buffer, and not what this test is
about."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (agent-org-buffer-begin-exchange buf
          "Summarise this\n* bullet not a heading\nlast line")
        (should (equal 1 (ao--count-occurrences (buffer-string)
                                                "^\\* Summarise this$")))
        ;; the Markdown bullet became an Org dash (the echo converts like the
        ;; reply does) and took the one space of guard indent, so it is a list
        ;; item and not a headline that splits the exchange in two
        (should (string-match-p "^ - bullet not a heading" (buffer-string)))
        (should (string-match-p "last line" (buffer-string)))
        ;; one heading for the exchange plus the box, and nothing the paste made
        (should (equal 2 (ao--count-occurrences (buffer-string) "^\\* "))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-two-exchanges-name-their-own-authors ()
  "A model switch authors the NEXT quote, never the last one.
The keyword line is baked when the answer starts, so two replies from two
models stand in the transcript with two different authors and no per-turn
map is needed: the line IS the record.  Asserting the older one survives
unchanged is the regression this could otherwise introduce, because a later
pass that re-derived the author from the CURRENT status would silently
rewrite history."
  (ao--capture-wire
    (let* ((buf (ao--chat-on-model "qmodel" "QModel"))
           (session (with-current-buffer buf (agent-org-buffer--session))))
      (with-current-buffer buf
        (agent-org-buffer-begin-exchange buf "First question")
        (agent-org-buffer-append-chunk buf "One.\n" session)
        (agent-org-buffer-end-agent-turn buf)
        (agent-org-buffer-set-status buf :model "qmodel-large"
                                     :model-name "QModel Large")
        (agent-org-buffer-begin-exchange buf "Second question")
        (agent-org-buffer-append-chunk buf "Two.\n" session)
        (agent-org-buffer-end-agent-turn buf)
        (should (equal 1 (ao--count-occurrences (buffer-string)
                                                "^#\\+ATTR_TEXINFO: :author QModel$")))
        (should (equal 1 (ao--count-occurrences (buffer-string)
                                               "^#\\+ATTR_TEXINFO: :author QModel Large$")))
        (should (apply #'ao--ordered (buffer-string)
                       (list "First question" ":author QModel$" "One\\."
                             "Second question" ":author QModel Large$" "Two\\."))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-quote-author-falls-back-to-agent-without-a-model ()
  "No model reported is not an author line that says nothing.
Goose can answer with no `model' config option in its response at all, and a
`:author' with an empty value is a claim about nobody — so the word stays
\"Agent\", which is what the heading used to say in the same case."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model nil nil)))
      (with-current-buffer buf
        (agent-org-buffer-begin-exchange buf "Hello")
        (agent-org-buffer-append-chunk buf "Hi.\n" (agent-org-buffer--session))
        (agent-org-buffer-end-agent-turn buf)
        (should (equal 1 (ao--count-occurrences (buffer-string)
                                                "^#\\+ATTR_TEXINFO: :author Agent$"))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-quote-author-option-off-keeps-the-word-agent ()
  "`agent-org-quote-model-author' nil is the stable word.
A model name on the quotation is a claim about the agent's catalog in the
middle of the user's notes; someone keeping transcripts across a provider
switch will want the stable word instead, and that preference must be
reachable without patching."
  (ao--capture-wire
    (let ((agent-org-quote-model-author nil)
          (buf (ao--chat-on-model "qmodel-large" "QModel Large")))
      (with-current-buffer buf
        (agent-org-buffer-begin-exchange buf "Hello")
        (agent-org-buffer-append-chunk buf "Hi.\n" (agent-org-buffer--session))
        (agent-org-buffer-end-agent-turn buf)
        (should (equal 1 (ao--count-occurrences (buffer-string)
                                                "^#\\+ATTR_TEXINFO: :author Agent$")))
        (should-not (string-match-p ":author QModel" (buffer-string))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-orphan-agent-chunk-gets-a-heading-of-its-own ()
  "An answer with no question in front of it is still valid Org.
`session/load' history can carry agent updates that no `user_message_chunk'
precedes, and a chunk cannot be dropped because there is no heading to put it
under: the fallback word names the turn the way the old heading did."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model nil nil)))
      (with-current-buffer buf
        (agent-org-buffer-append-chunk buf "Unsolicited.\n"
                                       (agent-org-buffer--session))
        (agent-org-buffer-end-agent-turn buf)
        (should (equal 1 (ao--count-occurrences (buffer-string) "^\\* Agent$")))
        (should (equal 1 (length (ao--quote-blocks))))
        (should (string-match-p "Unsolicited" (nth 2 (car (ao--quote-blocks))))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-turn-with-no-answer-text-keeps-no-quote-furniture ()
  "A tool-only exchange is its heading plus its board, and nothing else.
`agent-org-buffer-start-agent-turn' opens the block BEFORE the first chunk,
because a chunk may never arrive: an agent that only ran tools, or one that
hit its token limit, would otherwise leave an empty quotation in the user's
notes — and an empty =#+begin_quote= is not a fact about a silent agent, it is
noise, with an `:author' line claiming somebody said something.  So the turn
boundary drops the three furniture lines when no text ever landed between them.

The guard is the whole test: EMPTY means \"the line above the closer is the
opener\".  Comparing positions instead — `line-end-position' of the opener
against the closer's bol — can NEVER fire, because the opener's own newline
sits between them, and that is exactly the bug this shape had: every tool-only
turn kept an empty block while a position-comparing test passed for the wrong
reason.

And the closer's marker must go with the furniture: it is what
`agent-org-buffer--text-end' reads, so a stale one would put the NEXT
exchange's answer at a deleted position."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (let ((session (agent-org-buffer--session)))
          (agent-org-buffer-begin-exchange buf "Run the tests")
          (agent-org-buffer-start-agent-turn buf session)
          (agent-org-buffer-insert-tool buf '((title . "shell")
                                             (toolCallId . "t1")
                                             (status . "completed")))
          (agent-org-buffer-end-agent-turn buf)
          (should (equal 0 (length (ao--quote-blocks))))
          (should-not (string-match-p "begin_quote" (buffer-string)))
          (should-not (string-match-p "ATTR_TEXINFO" (buffer-string)))
          ;; the exchange itself survives, board and all
          (should (equal 1 (ao--count-occurrences (buffer-string)
                                                 "^\\* Run the tests$")))
          (should (string-match-p "^:tool:$" (buffer-string)))
          ;; the next exchange, which DOES get an answer, is unaffected
          (agent-org-buffer-begin-exchange buf "And now explain")
          (agent-org-buffer-append-chunk buf "Because I ran them.\n" session)
          (agent-org-buffer-end-agent-turn buf)
          (should (equal 1 (length (ao--quote-blocks))))
          (should (string-match-p "Because I ran them"
                                  (nth 2 (car (ao--quote-blocks)))))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-replay-paints-the-same-exchange-shape ()
  "A restored chat is headed by its questions and its answers are quoted.
Replay carries the prompt: `session/load' sends `user_message_chunk' updates,
which is what the heading is built from — so a restored transcript reads
exactly like a live one, and the same primitives do both (no second
renderer).  An agent chunk arriving BEFORE any user chunk is the orphan case,
and it gets the fallback heading rather than eating the next question."
  (ao--capture-wire
    (let ((buf (agent-org-resume-session 'qoder "sid-exch")))
      (let ((session (agent-org--session-for-buffer buf)))
        (ao--drive "initialize" ao--fake-init-resp)
        (ao--drive "session/load" '((sessionId . "sid-exch")))
        (dolist (update
                 (list '((sessionUpdate . "agent_message_chunk")
                         (content . ((type . "text") (text . "Orphan answer.\n"))))
                       '((sessionUpdate . "user_message_chunk")
                         (content . ((type . "text") (text . "Why?"))))
                       '((sessionUpdate . "agent_message_chunk")
                         (content . ((type . "text") (text . "Because.\n"))))))
          (agent-org--on-notification session (ao--update-notif update)))
        (ao--settle)
        (with-current-buffer buf
          ;; two answers, so two blocks: the orphan's and the one that answers
          ;; "Why?"  The question itself is a heading, never a block.
          (should (equal 2 (ao--count-occurrences (buffer-string) "^#\\+end_quote$")))
          (should (equal 1 (ao--count-occurrences (buffer-string) "^\\* Agent$")))
          (should (equal 1 (ao--count-occurrences (buffer-string) "^\\* Why\\?$")))
          (should (apply #'ao--ordered (buffer-string)
                         (list "^\\* Agent$" "Orphan answer"
                               "^\\* Why\\?$" "^#\\+begin_quote$" "Because")))))
      (kill-buffer buf))))


;;;; Per-exchange response clock: CLOCK: line + :RESPONSE: property
;;
;; User order (TODOs.org): "Each heading will be clocked, too, to derive the
;; total response time of the agent since the prompt were sent."  The settled
;; shape: a canonical `CLOCK:' line (the form `org-clock-in' writes, so a
;; person editing it by hand gets Org's own machinery) inside the exchange's
;; `:LOGBOOK:' drawer, plus a `:RESPONSE:' property with the EXACT seconds —
;; the minute-granular range says what Org sees, the property says what was
;; measured.  Started when the prompt goes out (the stamp is taken by
;; `agent-org-buffer-begin-exchange'), closed at the turn boundary; replayed
;; exchanges carry no clock rather than a false one, and a completed clock line
;; must never be mistaken for a running one (`agent-org-buffer--turn-start'
;; only feeds OUR writer, never `org-clock').

(defun ao--rewind-turn-start (seconds)
  "Claim the open turn in the current buffer began SECONDS ago.
The clock records wall time and a test cannot wait for a minute to pass; the
seam is the buffer-local start stamp itself, which only the turn boundary
reads.  Pick a multiple of 60 in tests and the minute-granular `CLOCK:' range
is deterministic whatever second the suite runs in."
  (setq agent-org-buffer--turn-start
        (time-subtract (current-time) (seconds-to-time seconds))))

(defun ao--clock-line-p (string)
  "Non-nil when STRING contains a canonical closed CLOCK line.
The exact form `org-clock-in'/`org-clock-out' leave behind: two bracketed
timestamps joined by `--' and an `=>' duration, so any tool that reads
clocks (org-clock-collect, a person's grep) finds ours."
  (string-match-p
   "^CLOCK: \\[20[0-9][0-9]-[0-9][0-9]-[0-9][0-9] [A-Za-z]+ [0-9][0-9]:[0-9][0-9]\\]--\\[.+\\] => +[0-9]+:[0-9][0-9]$"
   string))

(defun ao--count-nodes (type)
  "How many TYPE nodes the parser sees in the current buffer.
`org-element-count' is newer than the Org this package ships against, and
the count here is the assertion that STRUCTURE survived: a drawer that
stops being a drawer, or a `*' line that splits a heading, changes what the
parser reports while the text still reads fine to the eye."
  (let ((n 0))
    (org-element-map (org-element-parse-buffer) type
      (lambda (_) (cl-incf n)))
    n))

(ert-deftest test-agent-org-typed-exchange-gets-a-response-clock ()
  "A prompt typed into a live chat leaves a clock under its heading.
Asserted through ORG'S OWN reader, not a grep: `org-entry-get' answering
\"4500\" is proof the `:PROPERTIES:' drawer sits directly below the heading
where Org looks, and `org-element' counting one `clock' node is proof the
range is the canonical form rather than a comment that merely looks like
one.  A second boundary call must not write a second clock: the stamp is
consumed when the line goes in.

4500 s = 75 minutes, a multiple of a minute, so the `=>  1:15' duration the
writer computes from the minute-truncated timestamps is the same whatever
second the suite runs in; the exact count lives in the property."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (ao--send-one "Capital?")
        (ao--rewind-turn-start 4500)
        (agent-org-buffer-append-chunk buf "Paris.\n" (agent-org-buffer--session))
        (agent-org-buffer-end-agent-turn buf)
        (should (ao--clock-line-p (buffer-string)))
        (should (string-match-p " =>  1:15$" (buffer-string)))
        ;; heading, its drawer, its logbook, then the answer as before
        (should (apply #'ao--ordered (buffer-string)
                       (list "^\\* Capital\\?$"
                             "^:PROPERTIES:$" ":RESPONSE: 4500$" "^:END:$"
                             "^:LOGBOOK:$" "^CLOCK: \\[" "^:END:$"
                             "^#\\+begin_quote$" "Paris" "^#\\+end_quote$")))
        ;; Org's own property reader finds it at the heading
        (save-excursion
          (goto-char (point-min))
          (re-search-forward "^\\* Capital\\?$")
          (should (equal "4500" (org-entry-get (point) "RESPONSE"))))
        ;; the range is a genuine Org CLOCK node, not a line that only LOOKS
        ;; like one — `org-clock-parse-clock-line' is gone in this Org, and
        ;; `org-element' is the parser every clock tool (collet, a person's
        ;; agenda) reads through, so counting its `clock' nodes is the proof
        (should (equal 1 (ao--count-nodes 'clock)))
        ;; and the buffer still parses as ONE headline for the exchange
        (should (equal 2 (ao--count-nodes 'headline)))
        ;; a second close (a late callback after the boundary) adds no clock
        (agent-org-buffer-end-agent-turn buf)
        (should (equal 1 (ao--count-occurrences (buffer-string) "^CLOCK: "))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-each-exchange-gets-its-own-clock ()
  "Two exchanges, two clocks — and the first is untouched by the second.
The stamp is TURN state like the tool board: each `begin-exchange' takes a
fresh one and each boundary spends it, so a close can never attribute one
turn's elapsed time to another heading.

`ao--send-one' leaves the SESSION streaming (only the wire's turn-end
callback clears it), so between the two exchanges the test clears
`:streaming' exactly as that callback would — otherwise the second prompt
would be QUEUED behind a turn the buffer had already closed.  Both rewinds
are whole minutes, so each `CLOCK:' duration is deterministic whatever
second the suite runs in; a sub-minute answer would honestly round to
`0:00' with the true seconds only in the property."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (ao--send-one "First?")
        (ao--rewind-turn-start 4500)
        (agent-org-buffer-append-chunk buf "One.\n" (agent-org-buffer--session))
        (agent-org-buffer-end-agent-turn buf)
        (setf (plist-get (agent-org-buffer--session) :streaming) nil)
        (ao--send-one "Second?")
        (ao--rewind-turn-start 3600)
        (agent-org-buffer-append-chunk buf "Two.\n" (agent-org-buffer--session))
        (agent-org-buffer-end-agent-turn buf)
        (should (equal 2 (ao--count-occurrences (buffer-string) "^CLOCK: ")))
        (should (equal 1 (ao--count-occurrences (buffer-string)
                                                ":RESPONSE: 4500$")))
        (should (equal 1 (ao--count-occurrences (buffer-string)
                                                ":RESPONSE: 3600$")))
        ;; the first exchange keeps its own numbers, in its own place
        (should (apply #'ao--ordered (buffer-string)
                       (list "^\\* First\\?$" ":RESPONSE: 4500$"
                             "^CLOCK: \\[" " =>  1:15$"
                             "One"
                             "^\\* Second\\?$" ":RESPONSE: 3600$"
                             "^CLOCK: \\[" " =>  1:00$"
                             "Two"))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-replayed-exchanges-carry-no-clock ()
  "A restored session has no timing to invent, so it gets no clock.
User order behind the whole feature is \"the total response time of the
agent SINCE THE PROMPT WERE SENT\" — a replay carries neither moment, and a
clock computed from `session/load' wall time would be a fabricated
measurement filed under real ones.  The exchanges still render identically
(that is the replay test above); only the clock is withheld."
  (ao--capture-wire
    (let ((buf (agent-org-resume-session 'qoder "sid-clock")))
      (let ((session (agent-org--session-for-buffer buf)))
        (ao--drive "initialize" ao--fake-init-resp)
        (ao--drive "session/load" '((sessionId . "sid-clock")))
        (dolist (update
                 (list '((sessionUpdate . "user_message_chunk")
                         (content . ((type . "text") (text . "Asked"))))
                       '((sessionUpdate . "agent_message_chunk")
                         (content . ((type . "text") (text . "Answered.\n"))))))
          (agent-org--on-notification session (ao--update-notif update)))
        (ao--settle)
        (with-current-buffer buf
          ;; the exchange is there...
          (should (equal 1 (ao--count-occurrences (buffer-string)
                                                  "^\\* Asked$")))
          ;; ...and no clock or RESPONSE property anywhere in it
          (should-not (string-match-p "^CLOCK: " (buffer-string)))
          (should-not (string-match-p ":RESPONSE:" (buffer-string)))
          (should-not (string-match-p "^:LOGBOOK:$" (buffer-string)))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-response-clock-does-not-block-org-clocking ()
  "Our completed clocks leave Org's own clock machinery free.
User order: \"Your clocking MUSTN'T block user's Org clocking.  You should
make separate commands for response clocking based on Org's clocking code.\"
The separation is by FORM, not by hooking around Org: we never call
`org-clock-in', and a COMPLETED `CLOCK:' line (start AND end AND duration)
is not the state `org-clock' hunts for — an unfinished one
(`CLOCK: [start]' with no `--') would be, making every chat look like a
running clock after `org-clock-load' and refusing the user their own.
Proved on the transcript copy (the file is where a person actually
clocks): entering and leaving a real clock on a clocked exchange adds
Org's line and changes nothing ours, and `org-clock-is-active' stays nil
before and after for as long as we only ever wrote closed ranges.
(`org-clock-current-task' no longer exists in this Org; `org-clock-is-active'
is the supported predicate for \"is the one global running-clock slot taken\".)"
  (require 'org-clock)
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (ao--send-one "Capital?")
        (ao--rewind-turn-start 4500)
        (agent-org-buffer-append-chunk buf "Paris.\n" (agent-org-buffer--session))
        (agent-org-buffer-end-agent-turn buf)
        (let ((text (buffer-substring-no-properties (point-min) (point-max))))
          (with-temp-buffer
            (org-mode)
            ;; no persist file, no clock left running in the batch session:
            ;; org-clock's state is GLOBAL, so a leaked running clock here
            ;; would be exactly the blocking this test must not itself cause
            (let ((org-clock-persist nil))
              (unwind-protect
                  (progn
                    (insert text)
                    ;; a closed clock is not a running one
                    (should-not (org-clock-is-active))
                    (goto-char (point-min))
                    (re-search-forward "^\\* Capital\\?$")
                    (org-clock-in)
                    (should (org-clock-is-active))
                    (org-clock-out)
                    (should-not (org-clock-is-active))
                    ;; ours survived untouched, and Org added its own range
                    (should (equal "4500"
                                   (save-excursion
                                     (goto-char (point-min))
                                     (re-search-forward "^\\* Capital\\?$")
                                     (org-entry-get (point) "RESPONSE"))))
                    (should (string-match-p ":RESPONSE: 4500$" (buffer-string)))
                    (should (>= (ao--count-nodes 'clock) 2)))
                (when (org-clock-is-active) (org-clock-cancel))))))
        (kill-buffer buf)))))


;;;; Lite mode: the minimum resources, scoped per session or globally
;;
;; User order (TODOs.org): "Add a resource monitor for each session", and "a lite
;; mode which will use absolute minimum resources with per-session/global
;; scoping".  Lite mode is three gates, and none of them is a rendering change:
;; the transcript write (unless a queue is waiting), undo recording, and the
;; whole-buffer Org reparse on every metadata rebuild.  What it does NOT do is
;; stated in `agent-org-lite-mode', because a "lite" mode that switched off
;; font-lock or dropped the agent's reasoning would be a different package.

(defun ao--lite-chat (&optional name)
  "A chat buffer whose session scope starts at `inherit'.
Created directly rather than through `ao--make-test-session', whose session
plist is fixed: the scope is a BUFFER-LOCAL variable, so a fresh buffer is all
this needs."
  (let ((buf (agent-org-buffer-create (or name "lite"))))
    (with-current-buffer buf
      (setq agent-org-buffer--lite 'inherit))
    buf))

(ert-deftest test-agent-org-lite-follows-the-global-setting ()
  "With no scope of its own, a session follows `agent-org-lite-mode'.
The default scope is `inherit' precisely so that flipping the global variable
is a complete answer for the common case of \"make every chat cheap\", with no
per-session bookkeeping to unwind."
  (let ((buf (ao--lite-chat "follow")))
    (with-current-buffer buf
      (let ((agent-org-lite-mode nil))
        (should-not (agent-org-lite-p)))
      (let ((agent-org-lite-mode t))
        (should (agent-org-lite-p))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-lite-session-scope-overrides-the-global ()
  "`on' and `off' pin one session against the global setting, in both directions.
This is the per-session/global scoping the user asked for: the one chat filling
the disk goes lite while the rest stay full, and a global setting of t does not
force itself on a chat that has opted out."
  (let ((buf (ao--lite-chat "scoped")))
    (with-current-buffer buf
      (let ((agent-org-lite-mode nil))
        (setq agent-org-buffer--lite 'on)
        (should (agent-org-lite-p))
        (setq agent-org-buffer--lite 'off)
        (should-not (agent-org-lite-p)))
      (let ((agent-org-lite-mode t))
        (should-not (agent-org-lite-p))
        (setq agent-org-buffer--lite 'on)
        (should (agent-org-lite-p))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-lite-toggle-cycles-the-scope-and-pins-undo ()
  "C-c C-l cycles inherit -> on -> off -> inherit, and undo follows the result.
Three states because \"follow the global setting\" has to be reachable again: a
binary toggle would strand a session in an override forever.  Undo recording is
the resource the mode owns outright, so the toggle owns it: a session that
becomes lite stops accumulating undo entries in the same command that says so."
  (let ((buf (ao--lite-chat "cycle")))
    (with-current-buffer buf
      (let ((agent-org-lite-mode nil)
            (inhibit-message t))
        (should (eq agent-org-buffer--lite 'inherit))
        (agent-org-lite-mode-toggle)
        (should (eq agent-org-buffer--lite 'on))
        (should-not buffer-undo-list)
        (agent-org-lite-mode-toggle)
        (should (eq agent-org-buffer--lite 'off))
        (should buffer-undo-list)
        (agent-org-lite-mode-toggle)
        (should (eq agent-org-buffer--lite 'inherit))
        (should buffer-undo-list)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-lite-toggle-with-a-prefix-moves-the-global ()
  "C-u C-c C-l flips `agent-org-lite-mode' and leaves every session scope alone.
A session that pinned its own scope must not be dragged along by a global
change, or the per-session setting would be a claim rather than a scope."
  (let ((buf (ao--lite-chat "global")))
    (with-current-buffer buf
      (let ((agent-org-lite-mode nil)
            (inhibit-message t))
        (agent-org-lite-mode-toggle t)
        (should agent-org-lite-mode)
        (should (eq agent-org-buffer--lite 'inherit))
        ;; and now it resolves through the global setting, which moved
        (should (agent-org-lite-p))
        (agent-org-lite-mode-toggle t)
        (should-not agent-org-lite-mode)
        (should-not (agent-org-lite-p))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-lite-word-reads-the-scope ()
  "The monitor's MODE column: Lite, Full, a dot for no scope of its own.
One word per state in one function, because the monitor and the toggle both want
to say the same thing about a session and two spellings of it would drift."
  (let ((buf (ao--lite-chat "word")))
    (with-current-buffer buf
      (should (equal (agent-org-buffer--lite-word buf) "·"))
      (setq agent-org-buffer--lite 'on)
      (should (equal (agent-org-buffer--lite-word buf) "Lite"))
      (setq agent-org-buffer--lite 'off)
      (should (equal (agent-org-buffer--lite-word buf) "Full")))
    (kill-buffer buf)
    ;; a dead buffer has no scope, which is also a dot
    (should (equal (agent-org-buffer--lite-word buf) "·"))))

(ert-deftest test-agent-org-lite-property-line-is-only-there-when-lite ()
  "The metadata block says `:Lite: yes' for a lite session and nothing when full.
A transcript is a record, and how it was being recorded is a fact about it.  The
renderer takes the scope as an ARGUMENT because it is a pure function of the
status plist: reading a buffer-local variable inside it would answer for
whichever buffer happened to be current."
  (let ((status (list :provider "Qoder" :session-id "s-lite")))
    (should-not (string-match-p ":Lite:"
                                (agent-org-buffer--render-metadata status)))
    (should (string-match-p ":Lite: yes"
                            (agent-org-buffer--render-metadata status t)))
    ;; and it does not move the property out of the PROPERTIES drawer
    (should (string-match-p ":Cost: \$0\.00\n:Lite: yes\n:END:"
                            (agent-org-buffer--render-metadata status t)))))

(ert-deftest test-agent-org-lite-transcript-writes-nothing-while-the-queue-is-empty ()
  "A lite session stops writing its transcript once nothing is waiting.
The mirror is history the agent itself can replay, and it is a whole-file write
of 3-15 ms at every turn boundary on a machine that is already struggling; a
queued prompt is NOT replayable, so the mode spends the write on exactly that."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (let ((buf (agent-org-buffer-create "lite-nofile")))
        (with-current-buffer buf
          (setq agent-org-buffer--lite 'on)
          (agent-org-buffer-set-status buf :session-id "s-lite-write")
          (agent-org-buffer-begin-exchange buf "a question")
          (ao--counting-writes
            (agent-org-buffer-transcribe buf)
            (should (= 0 ao--writes))))
        (kill-buffer buf))
      ;; a full session, same fixture, does write
      (let ((buf (agent-org-buffer-create "full-file")))
        (with-current-buffer buf
          (agent-org-buffer-set-status buf :session-id "s-full-write")
          (agent-org-buffer-begin-exchange buf "a question")
          (ao--counting-writes
            (agent-org-buffer-transcribe buf)
            (should (= 1 ao--writes))))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-lite-still-records-a-queued-prompt ()
  "Lite writes the transcript WHILE a prompt is queued, and resume reads it back.
The one thing that exists nowhere else: a queued prompt was never sent, so it is
in no `session/load' replay, in no `* User' heading and in no agent memory.  Lite
mode spends the write on exactly that and stops the moment the queue empties --
which is why the rule is \"a non-empty queue\", not \"never\"."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (let ((buf (agent-org-buffer-create "lite-queue")))
        (with-current-buffer buf
          (setq agent-org-buffer--lite 'on)
          (agent-org-buffer-set-status buf :session-id "s-lite-queue")
          (agent-org-buffer-set-status buf :queued '("first" "second"))
          ;; the mirror is the BUFFER, so the queue has to be in the block
          ;; before the file can carry it -- which is what
          ;; `agent-org--queue-refresh' does on every queue change
          (agent-org-buffer-refresh-metadata buf)
          (agent-org-buffer-transcribe buf)
          (should (equal (ao--transcript-files temp-dir)
                         '("s-lite-queue.org")))
          (should (equal (agent-org-buffer-transcript-queue "s-lite-queue")
                         '("first" "second")))
          ;; drained: the file stops being rewritten
          (agent-org-buffer-set-status buf :queued nil)
          (ao--counting-writes
            (agent-org-buffer-transcribe buf)
            (should (= 0 ao--writes))))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-lite-undo-switch-follows-the-scope ()
  "A lite session stops recording undo; a full one records.
The switch is `buffer-undo-list' itself, and the switch is what this package
owns.  Both fixtures reach their scope through the real command, so the switch
is moved by the same code that moves for a person.

The RECORDS are deliberately not asserted, and the reason is worth writing
down: undo records are flushed to the buffer at a command boundary, so a batch
Emacs (no command loop) answers differently from a live one -- measured here:
typing with the switch nil leaves one record in the buffer, and typing with it
t leaves none, which is the opposite of what a session does.  A test pinning
that would be pinning batch Emacs, not this package.  The saving it buys is
the switch being off for the whole life of the chat."
  (dolist (scope '(on off))
    (let ((buf (agent-org-buffer-create (format "undo-%s" scope))))
      (unwind-protect
          (with-current-buffer buf
            (let ((inhibit-message t))
              (agent-org-lite-mode-toggle)    ; inherit -> on
              (when (eq scope 'off)
                (agent-org-lite-mode-toggle))) ; on -> off
            (should (eq (if (eq scope 'on) 'on 'off)
                        agent-org-buffer--lite))
            (should (eq (not (eq scope 'on))
                        (agent-org-buffer--record-undo-p)))
            (should (eq (not (eq scope 'on)) buffer-undo-list))
            ;; and the switch is still off after the buffer has been used
            (agent-org-buffer-insert-prompt buf)
            (ao--type "a draft")
            (should (string-match-p "a draft" (buffer-string)))
            (should (eq (not (eq scope 'on)) (agent-org-buffer--record-undo-p))))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-lite-parses-the-todo-line-once-per-buffer ()
  "A lite session runs `org-set-regexps-and-options' once, a full one every rebuild.
The metadata block is deleted and reinserted on every usage update, and the
reparse re-reads the WHOLE buffer; the `#+TODO:' line it exists to load is the
same bytes every time.  So a lite session parses it once and then skips."
  (let ((buf (agent-org-buffer-create "reparse")))
    (with-current-buffer buf
      (let ((agent-org-buffer--lite 'on)
            (parses 0))
        (cl-letf (((symbol-function 'org-set-regexps-and-options)
                   (lambda (&optional _) (cl-incf parses))))
          (agent-org-buffer-refresh-metadata buf)
          (agent-org-buffer-set-status buf :used 10 :size 100)
          (agent-org-buffer-refresh-metadata buf)
          (agent-org-buffer-set-status buf :used 20 :size 100)
          (agent-org-buffer-refresh-metadata buf))
        (should (= 1 parses))))
    (kill-buffer buf))
  (let ((buf (agent-org-buffer-create "reparse-full")))
    (with-current-buffer buf
      (let ((agent-org-buffer--lite 'off)
            (parses 0))
        (cl-letf (((symbol-function 'org-set-regexps-and-options)
                   (lambda (&optional _) (cl-incf parses))))
          (agent-org-buffer-refresh-metadata buf)
          ;; a CHANGED block, or the metadata cache skips the rebuild and the
          ;; reparse with it -- which is why each call here follows a status
          ;; change, exactly as a usage update does in a live turn
          (agent-org-buffer-set-status buf :used 10 :size 100)
          (agent-org-buffer-refresh-metadata buf))
        (should (= 2 parses))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-lite-skipping-the-reparse-keeps-the-keywords-live ()
  "After the skip the file's own keyword set is still parsed: ONGOING is a keyword.
The optimisation is only safe because the set is already live; if a lite
session's board words stopped being keywords, the saving would be a corruption.
Org's own parser answers it, which is how this suite settles Org questions."
  (let ((buf (agent-org-buffer-create "keywords-live")))
    (with-current-buffer buf
      (let ((agent-org-buffer--lite 'on))
        ;; a real rebuild with the real reparse first, then the skipped ones
        (agent-org-buffer-refresh-metadata buf)
        (agent-org-buffer-set-status buf :used 10 :size 100)
        (agent-org-buffer-refresh-metadata buf)
        (agent-org-buffer-set-status buf :used 20 :size 100)
        (agent-org-buffer-refresh-metadata buf))
      ;; read them HERE, with the chat current: `org-todo-keywords-1' is a
      ;; buffer-local of the file that declared it, so asking from anywhere
      ;; else asks about a buffer that never had one
      (should (member "ONGOING" org-todo-keywords-1))
      (should (member "COMPLETE" org-todo-keywords-1))
      ;; and Org agrees at a heading that uses one of them
      (with-current-buffer buf
        (goto-char (point-min))
        (when (re-search-forward "^\\* " nil t)
          (should (equal (org-entry-get nil "TODO") "ONGOING")))))
    (kill-buffer buf)))

;;;; The resource monitor: what each session costs this machine
;;
;; A separate Org buffer of tables, never a header-line segment: the bar carries
;; exactly one status string (CONVENTIONS.md 6), and a redraw on a timer in every
;; open chat would be the load the monitor exists to report.

(ert-deftest test-agent-org-proc-status-kb-parses-a-proc-status-line ()
  "`VmRSS' is read as KIB out of a `/proc' status body.
Pure parsing, so the shape of a kernel file is pinned without depending on any
particular process: `55628' KIB is 55628000 bytes, and a body without the field
is nil rather than zero."
  (let ((body "Name:\temacs\nVmPeak:\t  123456 kB\nVmRSS:\t   55628 kB\nThreads:\t3\n"))
    (should (= 55628 (agent-org--status-kb body "VmRSS")))
    (should (= 123456 (agent-org--status-kb body "VmPeak")))
    (should-not (agent-org--status-kb body "VmNope"))))

(ert-deftest test-agent-org-proc-cpu-ticks-counts-from-after-the-process-name ()
  "CPU ticks are read past the `comm' field, whatever the process is called.
`(Web Content)' is a real Linux process name, and a naive split of the whole
line would read its two spaces as two fields -- shifting every number while
reporting no error at all.  So the counting starts after the last `) '."
  (let ((plain "(sleep) S 1 2 3 4 5 6 7 8 9 10 100 20 0 0"))
    ;; after comm, utime is the twelfth field and stime the thirteenth
    (should (= 120 (agent-org--stat-cpu-ticks plain))))
  (let* ((spaced "(Web Content) S 1 2 3 4 5 6 7 8 9 10 100 20 0 0")
         ;; the same line read the naive way: two spaces INSIDE the comm shift
         ;; every field, so the reader reports some other pair of numbers and no
         ;; error at all.  The difference is the whole reason for the guard.
         (naive (split-string spaced " " t))
         (naive-sum (+ (string-to-number (nth 11 naive))
                       (string-to-number (nth 12 naive)))))
    (should (= 120 (agent-org--stat-cpu-ticks spaced)))
    (should-not (= 120 naive-sum)))
  (should-not (agent-org--stat-cpu-ticks "no parens here")))

(ert-deftest test-agent-org-parse-load-takes-three-numbers ()
  "Only the three averages; the process split and last pid are not load."
  ;; floats, because /proc writes them as decimals: 8.51 is not 8
  (should (equal '(1.0 5.0 15.0) (agent-org--parse-load "1.00 5.00 15.00 8/330 20744\n")))
  (should (equal '(0.12 0.24 0.48) (agent-org--parse-load "0.12 0.24 0.48 2/9 123")))
  (should-not (agent-org--parse-load "")))

(ert-deftest test-agent-org-bytes-reads-short-and-an-absent-measurement-as-different ()
  "98 MB and 1.4 GB, and an em-dash for nothing at all.
Zero is a claim and nil is an absence: a crashed agent process is not a small
one, so a missing RSS must not print as `0 B'."
  (should (equal "0 B" (agent-org--bytes 0)))
  (should (equal "512 B" (agent-org--bytes 512)))
  (should (equal "2 kB" (agent-org--bytes 2048)))
  (should (equal "1.0 MB" (agent-org--bytes 1048576)))
  (should (equal "98.0 MB" (agent-org--bytes (* 98 1024 1024))))
  (should (equal "1.4 GB" (agent-org--bytes 1474838528)))
  (should (equal "—" (agent-org--bytes nil))))

(ert-deftest test-agent-org-cpu-rate-needs-two-samples-and-honours-the-interval ()
  "A rate from consecutive samples; nil for a first sample, a zero interval, or a
pid that was reused (ticks going backwards).  Above 100% is ordinary: it means
the agent is running on more than one core."
  (let ((now (float-time)))
    ;; 100 ticks over 2 s at 100 Hz = 50% of one core
    (should (= 50.0 (agent-org--cpu-rate (cons 100 now)
                                         (list :ticks 200 :at (+ now 2.0)))))
    ;; twice the ticks in the same time is twice the CPU
    (should (= 100.0 (agent-org--cpu-rate (cons 100 now)
                                          (list :ticks 300 :at (+ now 2.0)))))
    (should-not (agent-org--cpu-rate nil (list :ticks 200 :at (+ now 2.0))))
    (should-not (agent-org--cpu-rate (cons 100 now)
                                      (list :ticks 200 :at now)))
    ;; a reused pid: fewer ticks than last time is not a rate
    (should-not (agent-org--cpu-rate (cons 300 now)
                                      (list :ticks 200 :at (+ now 2.0))))
    ;; no process means no measurement
    (should-not (agent-org--cpu-rate (cons 100 now)
                                      (list :ticks nil :at (+ now 2.0))))))

(ert-deftest test-agent-org-resource-table-is-a-table-to-org ()
  "The monitor renders a real Org table, separator row and all.
`org-element-parse-buffer' is the judge, which is how the rest of this suite
settles Org questions: a block of text that LOOKS like a table is not one, and
without the `|---+---|' line the parser reports no table at all."
(with-temp-buffer
    (insert (agent-org--resource-table
             '("Session" "State")
             '(("qoder:proj" "Ready") ("goose:proj" "Streaming"))))
    (org-mode)
    (goto-char (point-min))
    (should (re-search-forward "^[|] Session [|] State [|]$" nil t))
    (should (re-search-forward "^[|] --- \\+ --- [|]$" nil t))
    (let ((tables 0) (rows 0) (heads 0))
      ;; counted as ELEMENTS, not as lines: Org gives one `table-row' per line
      ;; the table owns, separator included, so four rows is a header, a
      ;; separator and two sessions
      (org-element-map (org-element-parse-buffer) '(table)
        (lambda (_e) (cl-incf tables)))
      (org-element-map (org-element-parse-buffer) '(table-row)
        (lambda (_e) (cl-incf rows)))
      (should (= 1 tables))
      (should (= 4 rows))
      ;; and nothing on those lines is mistaken for a headline or a drawer
      (org-element-map (org-element-parse-buffer) '(headline drawer)
        (lambda (_e) (cl-incf heads)))
      (should (= 0 heads)))))

(ert-deftest test-agent-org-resource-monitor-lists-every-open-session ()
  "One row per registered session, plus the machine totals above them.
The monitor's whole job is the comparison between chats, so a session with no
row is a session whose resources cannot be compared; the machine table counts
sessions and agents separately because a chat whose agent died is still an open
chat."
  (let ((default-directory ao--name-dir))
    (let* ((one (ao--make-test-session "mon1"))
           (two (ao--make-test-session "mon2"))
           (buf (agent-org-resource-monitor)))
      (unwind-protect
          (with-current-buffer buf
            (let ((text (buffer-string)))
              (should (string-match-p "^\\* Machine$" text))
              (should (string-match-p "^\\* Sessions$" text))
              (should (string-match-p "mon1:ao-proj" text))
              (should (string-match-p "mon2:ao-proj" text))
              ;; one row per session, no more
              (should (= 2 (ao--count-occurrences text "^[|] mon[12]:ao-proj")))))
        (kill-buffer buf))
      (kill-buffer (car one))
      (kill-buffer (car two)))))

(ert-deftest test-agent-org-resource-monitor-scope-prefix-shows-one-session ()
  "A prefix argument narrows the monitor to the session it was called from.
\"Just mine\" is the reading when one chat is suspected, and scoping it on the
MONITOR rather than on the caller is what keeps a later refresh from widening
it: the scope is recorded on the monitor buffer."
  (let ((default-directory ao--name-dir))
    (let* ((one (ao--make-test-session "scoped1"))
           (two (ao--make-test-session "scoped2"))
           (buf nil))
      (unwind-protect
          (with-current-buffer (car one)
            (setq buf (agent-org-resource-monitor t))
            (with-current-buffer buf
              (let ((text (buffer-string)))
                (should (string-match-p "scoped1:ao-proj" text))
                (should-not (string-match-p "scoped2:ao-proj" text)))))
        (when (buffer-live-p buf) (kill-buffer buf))
        (kill-buffer (car one))
        (kill-buffer (car two))))))

(ert-deftest test-agent-org-resource-monitor-shows-the-scope-and-the-undo-it-removed ()
  "A lite session's row says Lite, and says its buffer records no undo.
The two features are one story: the monitor is how a person SEES what the toggle
did, and the undo column is a resource it actually removed.  A monitor showing
only the scope would be asking to be taken on trust."
  (let ((default-directory ao--name-dir))
    (let* ((pair (ao--make-test-session "shown-lite"))
           (buf (car pair))
           (mon nil))
      (with-current-buffer buf
        (setq agent-org-buffer--lite 'on)
        (setq buffer-undo-list nil))
      (unwind-protect
          (progn
            (with-current-buffer buf
              (setq mon (agent-org-resource-monitor t)))
            (with-current-buffer mon
              (let ((text (buffer-string)))
                (should (string-match-p "[|] Lite [|]" text))
                (should (string-match-p " no-undo [|]" text)))))
        (when (buffer-live-p mon) (kill-buffer mon))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-resource-monitor-repaint-is-idempotent ()
  "Redrawing the monitor replaces its body instead of stacking copies.
Same rule as a chat's metadata block: the paint deletes up to the first heading
and reinserts, so a refresh that runs three times leaves one Machine table and
one row per session.  A monitor that appended would be unreadable in a minute."
  (let ((default-directory ao--name-dir))
    (let* ((pair (ao--make-test-session "idem"))
           (mon (agent-org-resource-monitor)))
      (unwind-protect
          (with-current-buffer mon
            (dotimes (_ 3) (agent-org-resource-refresh))
            (let ((text (buffer-string)))
              (should (= 1 (ao--count-occurrences text "^\\* Machine$")))
              (should (= 1 (ao--count-occurrences text "^\\* Sessions$")))
              (should (= 1 (ao--count-occurrences text "^[|] Session [|]")))
              (should (= 1 (ao--count-occurrences text "idem:ao-proj")))))
        (kill-buffer mon)
        (kill-buffer (car pair))))))

(ert-deftest test-agent-org-resource-monitor-reads-a-live-agent-process ()
  "The agent column names the process the session really spawned.
`acp' keeps it under `:process' as an alist KEY, so this is also the check that
the monitor reads the client the way the kill query does -- `plist-get' would
answer nil here and every row would print an em-dash.  The row therefore
carries a real RSS in KIB from `/proc', which is the measurement the whole
monitor exists to show."
  ;; the process is spawned OUTSIDE the fixture's `default-directory':
  ;; `ao--name-dir' is a name that need not exist (no other test here touches
  ;; the disk) and `make-process' chdirs into `default-directory'
  (let ((proc (make-process :name "ao-monitor-proc"
                            :command (list "sleep" "30"))))
    (let ((default-directory ao--name-dir))
      (let* ((buffer (agent-org-buffer-create "agent-col"))
             (session (list :name 'test :buffer buffer :session-id "s-proc"
                            :client (list (cons :process proc))
                            :streaming nil :pending-prompts nil))
             (mon nil))
        (unwind-protect
            (progn
              (agent-org--register-session session)
              (agent-org-buffer-set-session buffer session)
              (with-current-buffer buffer
                (setq mon (agent-org-resource-monitor t)))
              (with-current-buffer mon
                (let* ((text (buffer-string))
                       ;; the row is SESSION | STATE | MODE | AGENT | CPU | RSS ...
                       (row (car (seq-filter (lambda (line)
                                               (string-match-p "ao-monitor-proc" line))
                                             (split-string text "\n" t))))
                       (cells (split-string row "|" t)))
                  (should row)
                  ;; splitting on `|' with OMIT-NILS drops the empty fields the
                  ;; leading and trailing bars leave, so cell 3 is the AGENT
                  ;; column of the header SESSION STATE MODE AGENT CPU RSS ...
                  ;; and the AGENT cell is Emacs's NAME for the process -- what
                  ;; `list-processes' prints, which for a live session is acp's
                  ;; own name and not the binary on disk
                  (should (equal " ao-monitor-proc " (nth 3 cells)))
                  ;; the CPU cell is a dash on a FIRST sample (a rate needs
                  ;; two), and the RSS cell is a real measurement from /proc
                  (should (equal " — " (nth 4 cells)))
                  (should-not (equal " — " (nth 5 cells)))
                  (should (string-match-p "MB\\| B\\|KB" (nth 5 cells))))))
          ;; the agent goes FIRST, and that is what the real kill path asks
          ;; about: a live child puts `agent-org--kill-query' on the hook, and
          ;; a batch Emacs answers that question with EOF -- which would leave
          ;; the registry holding a session this test never cleaned up.  A
          ;; dead child needs no consent, so the buffer kill is silent.
          (delete-process proc)
          (when (buffer-live-p mon) (kill-buffer mon))
          (kill-buffer buffer))))
    (when (process-live-p proc) (delete-process proc))))

(ert-deftest test-agent-org-resource-monitor-timer-follows-display ()
  "The refresh timer is armed while the monitor is displayed and dropped when it is not.
This is the resource promise the feature rests on: the one repeating timer this
package runs is armed by display and disarmed by hiding, so a forgotten monitor
window costs a loaded machine nothing.

Display is REAL here, not stubbed.  A batch Emacs has a frame and a window
(measured), so `agent-org-resource-monitor' genuinely shows its buffer and
genuinely arms a timer -- the fixture then switches the window away and asks
again.  The timer function itself is counted rather than left to fire, because a
0.01 s repeat left armed would wake Emacs inside a later test."
  (let ((default-directory ao--name-dir))
    (let* ((pair (ao--make-test-session "display"))
           (armed 0)
           (buf nil)
           (scratch (get-buffer-create " ao-scratch ")))
      (let ((agent-org-resource-refresh-interval 0.01))
        (with-current-buffer (car pair)
          (setq buf (agent-org-resource-monitor)))
        (unwind-protect
            (progn
              ;; shown: the timer is live
              (should (agent-org--resource-displayed-p))
              (should agent-org--resource-timer)
              ;; hide it the way a person would: another buffer in EVERY
              ;; window showing it -- `display-buffer' opens a window of its
              ;; own rather than replacing the selected one, so switching the
              ;; selected window away is not enough
              (dolist (w (get-buffer-window-list buf nil t))
                (set-window-buffer w scratch))
              (should-not (agent-org--resource-displayed-p))
              (cl-letf (((symbol-function 'run-at-time)
                         (lambda (&rest _) (cl-incf armed) 'timer)))
                (agent-org--resource-retimer)
                (should (= 0 armed))
                (should-not agent-org--resource-timer))
              ;; and shown again, it comes back
              (set-window-buffer (get-buffer-window scratch) buf)
              (cl-letf (((symbol-function 'run-at-time)
                         (lambda (&rest _) (cl-incf armed) 'timer)))
                (agent-org--resource-retimer)
                (should (= 1 armed))
                (setq agent-org--resource-timer nil)))
          (when (buffer-live-p buf) (kill-buffer buf))
          (kill-buffer scratch)))
      (kill-buffer (car pair)))))

(ert-deftest test-agent-org-resource-monitor-timer-dies-with-its-buffer ()
  "Releasing the monitor cancels its timer, once.
The buffer IS the justification for the timer, so a timer outliving it is a
wakeup that samples nothing -- the same rule `agent-org--forget-session'
follows for an agent process."
  (let ((cancelled 0))
    (let ((agent-org--resource-timer 'fake-timer))
      (cl-letf (((symbol-function 'cancel-timer)
                 (lambda (&rest _) (cl-incf cancelled))))
        (with-temp-buffer
          (agent-org-resource-monitor-mode 1)
          (agent-org--forget-monitor)
          (should-not agent-org--resource-timer)
          (should (= 1 cancelled))
          ;; idempotent: a second release has nothing to cancel
          (agent-org--forget-monitor)
          (should (= 1 cancelled)))))))

(ert-deftest test-agent-org-resource-monitor-refresh-needs-a-monitor ()
  "`agent-org-resource-refresh' with no monitor open does nothing at all.
A refresh that opened one would surprise a person who typed it in the wrong
buffer, and the command is also how the monitor is read in a batch Emacs."
  (when (get-buffer "*agent-org resources*")
    (kill-buffer (get-buffer "*agent-org resources*")))
  (should-not (agent-org-resource-refresh))
  (should-not (get-buffer "*agent-org resources*")))

(provide 'test-agent-org)
;;; test-agent-org.el ends here
