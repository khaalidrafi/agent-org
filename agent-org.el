;;; agent-org.el --- Org-mode UI for ACP (Agent Client Protocol) agents -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Khalid

;; Author: Khalid
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (acp "0.14.3") (org "9.0"))
;; Keywords: tools, agents, ai, org
;; URL: https://github.com/khaalidrafi/agent-org

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; `agent-org' is a lightweight, Org-native client for coding agents
;; that speak ACP (Agent Client Protocol).  Unlike `agent-shell', it
;; does not run a hidden comint/terminal buffer: it talks directly to
;; the `acp' package and renders agent output natively as Org
;; headlines, keeping the editor fast and document-centric.
;;
;; Minimal usable flow:
;;
;;   M-x agent-org-start             ;; new session
;;   M-x agent-org-resume-session    ;; replay an existing session's history
;;
;; `agent-org-start' picks a provider (e.g. Goose), opens an Org chat
;; buffer, starts an ACP session, and streams responses straight into
;; it.  A provider also has its own command, `agent-org-goose-start-agent'
;; (see `agent-org-providers.el').  `agent-org-resume-session' uses
;; `agent-org-default-provider' unless called with a prefix argument,
;; then asks the agent for its sessions (`session/list') and replays the
;; chosen one (`session/load').
;;
;; Status, progress and errors are shown in the chat buffer's
;; header line (the top bar), never in the document body.  See
;; `agent-org-buffer.el' for the status model and
;; `agent-org-providers.el' for adding new agents.
;;
;; Everything here is written for a low-spec machine: streaming turns
;; keep font-lock on so Org colors stay live (only the append path
;; fontifies, never the whole buffer), restored history is buffered and
;; painted in ONE pass that also never toggles font-lock -- an OFF is
;; restorable, an ON is not in a buffer no window is showing (see
;; `agent-org--render-replay' and `agent-org-buffer--ensure-font-lock') --
;; and the metadata block above the conversation is only rebuilt when its
;; rendered text actually changed.

;;; Code:

(require 'cl-lib)
(require 'map)
(require 'seq)
(require 'acp)
(require 'org)
(require 'agent-org-buffer)
(require 'agent-org-providers)
(require 'agent-org-loader)

(defgroup agent-org nil
  "Org-mode UI for ACP coding agents."
  :group 'tools
  :prefix "agent-org-")

;;;; What "start" means

(defconst agent-org-new-session-label "New session"
  "Candidate that starts a fresh session from the chooser.
It is offered FIRST, so an untouched RET keeps `agent-org-start'
meaning \"start\" even in a directory full of old chats.")

(defconst agent-org--open-marker " (open)"
  "Appended to a candidate's title when a live buffer already has that session.
Listing rows are the agent's history, and some of it is usually already
open in another window; without a marker the only way to find out is to
choose the row and watch nothing load.  Inside the title column, so the
padding measures it like any other text and the dates stay in line.")

(defun agent-org--validate-session-strategy (value)
  "Signal a user-error unless VALUE is a known session strategy; else nil.
The check is a setter rather than a :type accident because a strategy
that silently did nothing would be indistinguishable from the fast path
when `agent-org-start' opened a blank buffer anyway."
  (unless (memq value '(new latest prompt))
    (user-error "Unknown `agent-org-session-strategy' %S: use `new', `latest' or `prompt'"
                value)))

(defcustom agent-org-session-strategy 'prompt
  "How `agent-org-start' treats the sessions this directory already holds.

  `new'     start a fresh session, and never ask the agent to list.
  `latest'  load the most recently updated session of the directory.
  `prompt'  list the directory's sessions, newest first — each labelled
            title, last-updated date and id — and offer them plus
            `New session'.

The names follow agent-shell's `agent-shell-session-strategy'.  An agent
that does not advertise the `list' capability, or cannot `session/load',
falls back to `new': there is nothing to choose.  One call can override
the setting without editing it: `C-u M-x agent-org-start' forces `new',
and `C-u C-u' forces `latest' -- reopen the chat you were last in, which
is what makes `latest' a habit rather than a preference.

`prompt' costs one request before a session opens, and some agents are
slow or silent on `session/list' (Goose advertises the capability and
never replies) — that is what `agent-org-session-list-timeout' covers."
  :type '(choice (const :tag "Always start a new session" new)
                 (const :tag "Load the latest session" latest)
                 (const :tag "Prompt for a session" prompt))
  :set (lambda (sym value)
         (agent-org--validate-session-strategy value)
         (set-default sym value))
  :group 'agent-org)

(defun agent-org--validate-page-limit (value)
  "Signal a user-error unless VALUE is nil or a positive integer."
  (unless (or (null value) (and (integerp value) (> value 0)))
    (user-error "`agent-org-session-list-page-limit' must be nil or a positive integer, got %S"
                value)))

(defcustom agent-org-session-list-page-limit nil
  "How many `session/list' pages to fetch, following the agent's cursors.
nil means every page: the older sessions an agent hides behind its first
page are exactly what the chooser is for.  A positive integer caps the
requests and silently omits the rest, which is the option on a slow
agent — each page is another round trip to a process that takes seconds
to answer, on a machine that cannot spare them."
  :type '(choice (const :tag "Fetch every page" nil)
                 (integer :tag "Maximum pages"))
  :set (lambda (sym value)
         (agent-org--validate-page-limit value)
         (set-default sym value))
  :group 'agent-org)

(defcustom agent-org-session-list-timeout 20.0
  "Seconds `agent-org-start' waits for `session/list' before starting new.
Goose answers `initialize' and `session/new' and never `session/list',
so an unbounded wait would turn the default `prompt' strategy into a
command that appears to hang.  When the timer fires the session opens as
a fresh one and the echo area says why; a listing arriving afterwards is
ignored.  nil waits forever, for an agent you trust to answer.

The default is a judgement about slow machines rather than a measurement
of one: live qoder answered this directory's 38 sessions in a single page
in seconds, and later — with the machine at load average 16 — the same
request on the same kind of session never answered at all, which is
exactly the case the fallback exists for.  Anything under ~15 s risks
abandoning a listing that is merely cold, and the fallback is quiet
(an echo-area note), so it should not be reached by accident.  Raise it,
or set it to nil, on a machine where you would rather wait."
  :type '(choice (const :tag "Wait forever" nil)
                 (number :tag "Seconds"))
  :group 'agent-org)

(defcustom agent-org-progress-min-time 0.2
  "Seconds between echo-area updates of a loading progress report.
`make-progress-reporter' calls this MIN-TIME and documents it as the
minimum interval between echo-area updates; 0.2 is that function's own
default, restated here as a knob because this machine is the reason it
exists.  What it bounds is a redisplay — the echo area shares one with
the chat buffer, and the buffer is growing while a session is restored —
not the call, which is why the code steps the report once per event and
lets this do the arithmetic.
Raise it (0.5, 1.0) if the redraw is felt; a test sets it to 0 to watch
every step, or to an hour to prove the throttle."
  :type 'number
  :group 'agent-org)

(defcustom agent-org-log-traffic t
  "Keep the raw JSON of every ACP message each chat sends and receives.
On, `agent-org-show-traffic' opens a real log: one line per message with
the parsed object and its exact JSON stored as text properties, so RET
pretty-prints the response the agent actually sent — the thing no header
line, drawer or transcript can show, because all three render a
*projection* of it.

The switch belongs to acp, not to us: `acp-logging-enabled' is a global
variable and is consulted when a message arrives, so enabling this from
a chat that is already open works for its next message, and any other
acp client in the session logs too.  Turn it off and the traffic buffers
stop growing; what is already recorded stays until the buffer is killed.

Default t is a bias for a package whose users are watching an agent
answer: the per-message cost is one line appended to an off-screen
buffer (the objects, not the text, are what it retains), which buys the
only record that can settle a \"did the agent really say that?\"
question."
  :type 'boolean
  :group 'agent-org)

;;;; Session registry

(defvar agent-org--sessions nil
  "List of active sessions.
Each entry is a plist:
  :name        - provider id (symbol)
  :client      - acp client alist
  :buffer      - Org chat buffer
  :cwd         - working directory the agent was spawned in (string)
  :session-id  - ACP session-id (string, once known)
  :streaming   - non-nil while a turn is streaming
  :turn        - id (integer) of the in-flight prompt turn, nil between
                 turns or after `agent-org-cancel-turn' retired it; the
                 send callbacks compare it to their own turn and drop a
                 late answer to a cancelled request.  See
                 `agent-org--send-turn'.
  :loading     - non-nil while a `session/load' replay is in flight
  :replay      - `session/update' alists buffered while :loading,
                 newest first, painted by `agent-org--render-replay'
  :replay-timer        - pending quiet-period timer that renders
                 :replay, nil once it has fired or been cancelled; its
                 being non-nil also means the load response landed
  :replay-session-id   - session id to bind when the replay renders
  :replay-response     - the session/load response, kept for the render
                 so its modes/config options still reach the header
  :replay-deadline     - absolute float time after which the render is
                 no longer pushed back (see `agent-org--arm-replay-render')
  :list-state          - `pending' while a `session/list' the start is
                 waiting on is in flight, `settled' once either the
                 answer or the timeout owns the outcome (see
                 `agent-org--settle-listing')
  :list-timer          - pending `agent-org-session-list-timeout' timer,
                 nil once it has fired or been cancelled
  :progress            - the echo-area progress reporter of the load
                 phase in flight (a listing, or a `session/load'
                 replay), nil while nothing is being loaded.  See
                 `agent-org--progress-start'.
  :lists-sessions      - t once `initialize' answered with the `list'
                 session capability; gates the one-shot title sync
                 below, because a silent agent (Goose) hangs on
                 `session/list'
  :title-seeked        - non-nil once `agent-org--sync-title' has asked
                 `session/list' for this session's title, whether or not
                 an answer arrived: the question is asked at most once
  :pending-prompts     - prompts queued while :streaming (FIFO list of
                 strings), sent one per successful turn end by
                 `agent-org--drain-queue'.  These are the only
                 conversation text the agent has never seen, so they are
                 also the only thing a resume cannot replay: every change
                 here is mirrored into the transcript's =:QUEUE:= drawer
                 and read back out of it by
                 `agent-org--finish-replay'.  See
                 `agent-org-queue-when-busy'.

Every key is installed by `agent-org--open-session', because `setf' on
`plist-get' can only mutate a property that already exists.")

(defvar agent-org--inhibit-kill-query nil
  "Non-nil inside a kill agent-org decided on itself, so `agent-org--kill-query'
answers without asking.  Dynamically bound by
`agent-org--kill-buffer-silently' and read by no other path — an
inhibitor that some third-party buffer code could set is an agent that
gets killed by accident.")

(defun agent-org--register-session (entry)
  "Add ENTRY to `agent-org--sessions'.
Installs a buffer-local hook so the entry is dropped when its buffer
is killed."
  (push entry agent-org--sessions)
  (when-let* ((buf (plist-get entry :buffer)))
    (with-current-buffer buf
      (add-hook 'kill-buffer-hook #'agent-org--forget-session nil t)
      (add-hook 'kill-buffer-query-functions #'agent-org--kill-query nil t))))

(defun agent-org--forget-session ()
  "Release the current buffer's session: its timers, its agent and its entry.
`acp' spawns the agent process for itself and owns it, so dropping the
registry entry does NOT stop it — only `acp-shutdown' deletes the process.
Skipping that leaked one `qoder --acp' child (around 100 MB) per killed
chat buffer: found live with one session registered and nine processes
still running.  A replay or listing timer still armed would fire against
the dead buffer, so both are unarmed on the way out too."
  (let* ((buf (current-buffer))
         (session (agent-org--session-for-buffer buf)))
    (when session
      (dolist (key '(:replay-timer :list-timer))
        (when-let* ((timer (plist-get session key)))
          (cancel-timer timer)
          (setf (plist-get session key) nil)))
      ;; The echo area belongs to this session no more than its timers
      ;; do: a restore abandoned by killing the buffer would otherwise
      ;; keep redrawing its line under whatever the user opened next.
      (agent-org--progress-stop session)
      ;; A kill is not a turn boundary, and the turn in flight has no
      ;; end coming: without this the last answer of every session — the
      ;; one the user stopped reading — is the one missing from the file.
      ;; The buffer is still whole here, so the mirror is its real state.
      (agent-org-buffer-transcribe buf)
      ;; Shutdown first: it clears the client's handlers, so a late process
      ;; event cannot reach a buffer that is already going away.
      (when-let* ((client (plist-get session :client)))
        (acp-shutdown :client client))
      (setq agent-org--sessions
            (seq-remove (lambda (s) (eq (plist-get s :buffer) buf))
                        agent-org--sessions)))))

(defun agent-org--session-for-buffer (buffer)
  "Return the session plist whose :buffer is BUFFER, or nil."
  (seq-find (lambda (s) (eq (plist-get s :buffer) buffer))
            agent-org--sessions))

(defun agent-org--session-open-p (session-id)
  "The live chat buffer already holding SESSION-ID, or nil.
A `session/list' of this directory includes chats that are open in other
windows, and nothing on the wire says so — so a candidate is only
\\\"open\\\" when the registry still points a live buffer at its id.
A session whose buffer died but whose kill-hook has not run yet is not
open: offering to switch to a dead buffer would be worse than the double
load it replaces."
  (seq-some (lambda (s)
              (let ((buffer (plist-get s :buffer)))
                (and (equal (plist-get s :session-id) session-id)
                     (buffer-live-p buffer)
                     buffer)))
            agent-org--sessions))

(defun agent-org--agent-process (session)
  "The live agent PROCESS behind SESSION, or nil.
`acp' spawns the agent itself and keeps the process on its client under
`:process'.  It starts it with `:noquery t' and no `:buffer', so Emacs'
own `process-kill-buffer-query-function' can never find it: as far as the
editor is concerned a running qoder has no process at all.

A dead child is nil, not a reason to ask — the agent of a session that
crashed mid-turn leaves the buffer merely unresponsive, and killing it
needs no consent.

Read it with `map-elt' and the KEYWORD key, exactly as acp's own
`acp--client-started-p' does (acp.el).  The client LOOKS like a plist and
is not one: `acp-make-client' returns `(list (cons :process nil) ...)', an
ALIST of dotted keyword pairs, mutated by `map-put!' which for a list is
an alist operation.  So `plist-get' walks it as a flat plist, matches
nothing and answers nil — silently, on a Ready session, with a live
process sitting right there (measured live against `goose acp': MAP-ELT
gave `#<process acp-client(goose)-1>', PLIST-GET gave nil).  A fixture
flat enough for `plist-get' to work hides that, hence `acp-make-client'
in tests/acp-mock.el builds the same SHAPE, not merely the same keys."
  (when-let* ((proc (and session (map-elt (plist-get session :client) :process))))
    (and (processp proc) (process-live-p proc) proc)))

(defun agent-org--kill-query ()
  "Ask before killing the current buffer while its agent is running.
On `kill-buffer-query-functions', installed buffer-locally by
`agent-org--register-session'; returning nil aborts the kill.  The
question is Emacs' own, word for word — `Process %s is running; kill it? '
is what `kill-buffer' asks about a shell or compile buffer, and an
agent-org chat buffer holds exactly that kind of thing: a child process
the user did not start by hand and might not remember is alive.

Nothing is released here.  A YES lets the kill proceed and
`agent-org--forget-session' on `kill-buffer-hook' does the shutdown, so
there is one release path and it is the one the process-leak fix already
put under test.  Hook functions run with the target buffer current and
are documented not to change it, hence no `with-current-buffer'."
  (or agent-org--inhibit-kill-query
      (let ((proc (agent-org--agent-process
                   (agent-org--session-for-buffer (current-buffer)))))
        (if proc
            (yes-or-no-p (format "Process %s is running; kill it? " proc))
          t))))

(defun agent-org--kill-buffer-silently (buffer)
  "Kill BUFFER with the agent query answered YES in advance.
For the two kills agent-org performs on its OWN initiative:
`agent-org--cancel-open' releasing a buffer the user backed out of, and
`agent-org--show-open-instead' dropping the half-open buffer when the
session they chose is already live elsewhere.  Both have a running agent
attached, and asking about a buffer the user never asked to kill — from
inside an acp response callback, where a quit would be swallowed — is not
a question, it is a trap."
  (when (buffer-live-p buffer)
    (let ((agent-org--inhibit-kill-query t))
      (kill-buffer buffer))))

(defun agent-org--cancel-open (session)
  "Release SESSION because the user backed out before it ever opened.
Cancelling a `completing-read' signals `quit', which arrives inside the
acp response callback — and acp wraps every callback in
`condition-case-unless-debug', so an uncaught quit is SWALLOWED: the chat
buffer stayed on \"Starting\"/\"Restoring\" holding a live agent process,
with no way to prompt and nothing on the header line to explain it.
Killing the buffer IS the release: its `kill-buffer-hook' runs
`agent-org--forget-session', which shuts the agent down and unarms its
timers.  The echo area is the only channel left once the buffer is gone."
  (message "agent-org: cancelled - no session opened")
  (agent-org--kill-buffer-silently (plist-get session :buffer)))

(defun agent-org--show-open-instead (session buffer)
  "Raise BUFFER, which already holds the session SESSION was about to open.
One ACP session id, one client: loading it twice would give two buffers
the same history, both able to prompt, both replaying into each other.
The buffer this command opened is released the way a cancelled one is —
killed, which runs `agent-org--forget-session' and shuts down the agent
process spawned for it before it ever had a session.  The echo area is
where the explanation goes: the buffer being killed may be the one on
screen."
  (message "agent-org: %s is already open - showing it, not loading twice"
           (buffer-name buffer))
  (let ((ours (plist-get session :buffer)))
    (when (and (buffer-live-p ours) (not (eq ours buffer)))
      (agent-org--kill-buffer-silently ours)))
  (pop-to-buffer buffer))

(defmacro agent-org--quit-cancels (session &rest body)
  "Run BODY; if the user quit the session prompt, release SESSION and yield nil.
Both session readers complete with REQUIRE-MATCH, so nil is never a
legitimate answer, and a caller that sees nil must send neither
`session/new' nor `session/load'."
  (declare (indent 1) (debug t))
  `(condition-case-unless-debug nil
       (progn ,@body)
     (quit (agent-org--cancel-open ,session) nil)))

(defun agent-org--wire-list (value)
  "Return wire array VALUE as a list (JSON arrays arrive as vectors)."
  (cond
   ((vectorp value) (append value nil))
   ((listp value) value)
   (t nil)))

(defun agent-org--model-option (config)
  "Return the settable model option from configOptions list CONFIG.
Agents id it \"model\"; Goose exposes the same choice as \"provider\".
Nil when neither is offered."
  (seq-find (lambda (o) (member (map-elt o 'id) '("model" "provider")))
            config))

(defun agent-org--model-from-config (config)
  "Return the model-ish current value from configOptions list CONFIG.
Prefer an option with id \"model\", else \"provider\" (what goose
reports), else nil."
  (map-elt (agent-org--model-option config) 'currentValue))

(defun agent-org--model-values (config)
  "Values CONFIG's model option offers, as a list of strings.
`agent-org-set-session-model' will only send one of these: an id the
agent never listed fails the request, and OpenCode renames its catalog
between releases, so a stale id is a real possibility."
  (seq-map (lambda (o) (map-elt o 'value))
           (agent-org--wire-list
            (map-elt (agent-org--model-option config) 'options))))

(defun agent-org--model-name (config)
  "The label CONFIG's agent gives its current model, or a cleaned id.
The wire value is an id like `minimax/MiniMax-M3', which is what must be
sent back in `session/set_config_option' but is not what a person wants
read to them in a status bar; the advertised option carries the human
label in `name'.  When the current value is outside the advertised list
— an agent can report a model it does not offer a name for — fall back
to the id minus its provider path (\"MiniMax-M3\"), the most the id
itself can be made to say; only a missing current value answers nil,
and the caller then shows \"unknown\"."
  (let* ((option (agent-org--model-option config))
         (current (map-elt option 'currentValue)))
    (when current
      (or (map-elt (seq-find (lambda (o) (equal (map-elt o 'value) current))
                             (agent-org--wire-list (map-elt option 'options)))
                   'name)
          (car (last (split-string current "/" t)))))))

(defun agent-org--session-config (session)
  "Return SESSION's configOptions as last reported by the agent.
The buffer status holds them: it is what the header line and the metadata
block are rendered from, so a second copy in the session could drift."
  (plist-get (buffer-local-value 'agent-org-buffer--status
                                 (plist-get session :buffer))
             :config))

(defun agent-org--ingest-config (buffer config)
  "Show configOptions CONFIG on BUFFER's header line and metadata.
Shared by the session/new and session/load responses and by a
`session/set_config_option' answer, so the model shown is always the one
the agent just agreed to.

Both the id and the label are stored, from one read of CONFIG: `:model'
is the wire value (what tests assert and what a future request would
send) and `:model-name' is what the bar renders.  Storing only the label
would leave nothing to send back; storing only the id is the thing this
pair exists to fix."
  (agent-org-buffer-set-status buffer
    :config config
    :model (agent-org--model-from-config config)
    :model-name (agent-org--model-name config)))

(defun agent-org--set-model-request (session model)
  "Ask SESSION's agent to switch to MODEL, then refresh the header line.
The config id comes from the advertised option rather than the literal
\"model\", because that is what makes the same call work on a provider
that names it \"provider\"."
  (let* ((buffer (plist-get session :buffer))
         (option (agent-org--model-option (agent-org--session-config session))))
    (acp-send-request
     :client (plist-get session :client)
     :request (acp-make-session-set-config-option-request
               :session-id (plist-get session :session-id)
               :config-id (map-elt option 'id)
               :value model)
     :buffer buffer
     :on-success (lambda (resp)
                   (let ((config (agent-org--wire-list (map-elt resp 'configOptions))))
                     (when config (agent-org--ingest-config buffer config))))
     :on-failure (lambda (_err msg)
                   ;; same channel `agent-org-send' uses for a failed
                   ;; request: the Ready segment hides a bare :message
                   (agent-org-buffer-set-status buffer
                     :state 'error
                     :message (format "model set failed: %s" (agent-org--failure-text msg)))))))

(defun agent-org--apply-pinned-model (session)
  "Switch SESSION to the model its provider pins, once per session.
Clears `:want-model' before sending, so the repeated ready calls a turn
makes (title and usage updates re-enter it) cannot re-send the same
request.  A wanted model the agent does not offer is reported in the echo
area and left alone: the session works on some other model, and the header
line already shows which one, so refusing is not a session failure — it
must not steal the Ready segment either."
  (when-let* ((want (plist-get session :want-model))
              (option (agent-org--model-option (agent-org--session-config session))))
    (setf (plist-get session :want-model) nil)
    (let ((current (map-elt option 'currentValue)))
      (cond
       ((equal want current) nil)
       ((member want (agent-org--model-values (agent-org--session-config session)))
        (agent-org--set-model-request session want))
       (t (message "agent-org: %s does not offer %s; staying on %s"
                   (plist-get session :name) want current))))))

(defun agent-org--session-ready (session sid &optional resp)
  "Mark SESSION live under ACP session id SID and open the input prompt.
RESP is the full session/new response alist when available; its modes
and config options feed the header line and metadata block.  Safe to
call repeatedly: prompt insertion is idempotent and skipped while any
turn is in flight (Goose fires session_info_update mid-turn for title
updates; the send callbacks re-open the prompt afterwards).  Also
skipped while a `session/load' replay is in flight: the buffer is not
interactive until the history has been painted."
  (setf (plist-get session :session-id) sid)
  (let ((buffer (plist-get session :buffer))
        (modes (and resp (map-elt resp 'modes)))
        (config (and resp (agent-org--wire-list (map-elt resp 'configOptions)))))
    (when-let* ((title (and resp (map-elt resp 'title))))
      (agent-org-buffer-set-status buffer :title title))
    (when modes
      (agent-org-buffer-set-status buffer
        :mode (map-elt modes 'currentModeId)
        :modes-list (agent-org--wire-list (map-elt modes 'availableModes))))
    (when config
      (agent-org--ingest-config buffer config))
    (agent-org-loader-finish buffer :session-id sid)
    (agent-org-buffer-refresh-metadata buffer)
    ;; a boundary: the transcript mirrors the buffer, so it is written
    ;; after the metadata pass put the id and title in it
    (agent-org-buffer-transcribe buffer)
    ;; after `agent-org-loader-finish': it writes the Ready message, and a
    ;; hint about the pinned model has to outlive it
    (agent-org--apply-pinned-model session)
    (unless (or (plist-get session :streaming)
                (plist-get session :loading))
      (agent-org-buffer-insert-prompt buffer))))

;;;; Progress reporting while a session loads

(cl-defun agent-org--progress-start (session message &key total)
  "Give SESSION an echo-area progress report saying MESSAGE.
TOTAL, when a positive number, makes it a percentage of TOTAL; nil or
zero leaves the spinning indicator, which is right for a phase with no
denominator yet — nobody knows how many sessions an agent is going to
name, and a replay that buffered nothing has nothing to count.
Replaces any report SESSION already has: one session owns one echo area,
and two live reports would each step a line the other is waiting to
close.  `agent-org--open-session' installs `:progress', so the `setf'
below always has a property to write.  Creating the report is also what
DISPLAYS the line — `make-progress-reporter' says MESSAGE \"is shown in
the echo area, with a status indicator appended\" — so a caller that has
just started a report needs no first step to be seen.

No timer of ours runs here, and that is the whole low-end design.
`progress-reporter-update' is documented as relatively inexpensive: it
does nothing unless the change since its last display is big enough or
`agent-org-progress-min-time' seconds have passed.  So the events that
actually happen — a replay chunk, one page of a listing — can be the
clock, and a quiet agent costs nothing.  agent-shell's equivalent,
`agent-shell-active-message-show', animates its reporter with
`run-at-time' every 0.1 s instead: ten wakeups a second, of which Emacs
will display at most five, and which go on waking the machine while the
agent is saying nothing at all."
  (agent-org--progress-stop session)
  (setf (plist-get session :progress)
        ;; MIN-VALUE and MAX-VALUE together decide spinner versus
        ;; percentage; 0 is non-nil, so `and count' is what turns the
        ;; spinner into a fraction.  CURRENT-VALUE starts at the bottom,
        ;; and MAX-VALUE of 0 would divide by zero — hence `positive'.
        (let ((positive (and (numberp total) (> total 0) total)))
          (make-progress-reporter message (and positive 0) positive
                                  nil nil agent-org-progress-min-time))))

(defun agent-org--progress-step (session &optional value)
  "Advance SESSION's progress report to VALUE, when there is one to advance.
VALUE is a number for a report started with a total, and a string for a
spinner — that is what `progress-reporter-update' accepts, a non-numeric
report using VALUE as the text after its indicator.  Called with no
VALUE a spinner still turns.

No report is a no-op rather than an error, and that is the point: a
`session/update' that arrives after the session went ready, or after its
buffer was killed, must not take the echo area back."
  (when-let* ((reporter (plist-get session :progress)))
    (progress-reporter-update reporter value)))

(defun agent-org--progress-stop (session)
  "Close SESSION's progress report and clear the echo area.
Quiet by design.  `progress-reporter-done' prints \"...done\", which is
for a task whose result you cannot otherwise see; every phase here ends
in something readable — the chooser opens, the history is in the buffer,
the header line shows the error.  agent-shell's hide calls done and then
`(message nil)' back to back, so the word it paid a redisplay for is the
one thing nobody reads.
Idempotent: a session with no report clears nothing, because that echo
area may be showing someone else's message."
  (when (plist-get session :progress)
    (setf (plist-get session :progress) nil)
    (message nil)))

;;;; Failure reporting

(defun agent-org--failure-text (msg)
  "One-line description of a failed request's MSG, as acp reports it.
`acp-send-request' hands its :on-failure callback the whole response
message — `((:object . ERROR-ALIST) (:json . RAW))' — and live opencode
answered a prompt with that entire structure, hundreds of characters
long, in place of the header line's status segment.  The JSON-RPC error's
own `message' is the sentence the agent wrote for humans, so that is what
this returns; anything else about the failure (code, data, raw JSON) is
already in the *acp* log when the user needs it.  A plain string is
already a sentence and comes back unchanged."
  (cond
   ((stringp msg) msg)
   ((map-nested-elt msg '(:object error message)))
   ((map-elt msg ':json))
   (t (format "%S" msg))))

;;;; Lifecycle

(defun agent-org--read-provider ()
  "Complete a provider id among `agent-org-providers'."
  (intern (completing-read
           "Provider: "
           (seq-map (lambda (p) (symbol-name (plist-get p :id)))
                    agent-org-providers)
           nil t)))

(defun agent-org--provider-spec (provider)
  "Return the provider plist whose :id is the symbol PROVIDER.
Signals a user-error for an unknown id, so both entry points
(`agent-org-start' and `agent-org-resume-session') validate the same way."
  (let ((spec (seq-find (lambda (p) (eq (plist-get p :id) provider))
                        agent-org-providers)))
    (unless spec
      (user-error "Unknown provider: %S" provider))
    spec))

(defun agent-org--open-session (spec)
  "Spawn the agent described by provider SPEC and its chat buffer.
Spawns the CLI, registers the session, binds it to the buffer and
selects that buffer.  Returns the session plist; no ACP request has
been sent yet, so the caller picks `session/new' or `session/load'."
  (let ((command (plist-get spec :command)))
    (unless (executable-find (car command))
      (user-error "Command not found: %s" (car command)))
    ;; acp consults this when a message arrives, not when the client is
    ;; made, so setting it here captures this chat from its first request
    (when agent-org-log-traffic
      (setq acp-logging-enabled t))
    ;; capture the directory now: the resumed session must be loaded
    ;; against the same cwd it was created in
    (let* ((cwd default-directory)
           (buffer (agent-org-buffer-create (plist-get spec :name)))
           (client (acp-make-client
                    :context-buffer buffer
                    :command (car command)
                    :command-params (cdr command)
                    :environment-variables
                    (funcall (plist-get spec :environment))))
           (session (list :name (plist-get spec :id)
                          :client client
                          :buffer buffer
                          :cwd cwd
                          ;; `:want-model' is cleared once applied, so a
                          ;; provider pin cannot re-send per ready call;
                          ;; the header line's `:model' is the agent's
                          ;; current answer, a different thing
                          :want-model (plist-get spec :model)
                          :session-id nil
                          :streaming nil
                          :turn nil
                          :loading nil
                          :replay nil
                          :replay-timer nil
                          :replay-session-id nil
                          :replay-response nil
                          :replay-deadline nil
                          :list-state nil
                          :list-timer nil
                          :progress nil
                          ;; set from the initialize response: the title
                          ;; sync below is capability-gated, because a
                          ;; silent agent (Goose) hangs on session/list
                          :lists-sessions nil
                          ;; one-shot guard for `agent-org--sync-title'
                          :title-seeked nil
                          :pending-prompts nil)))
      (agent-org--register-session session)
      (agent-org--subscribe client session)
      (agent-org-buffer-set-session buffer session)
      (switch-to-buffer buffer)
      session)))

;;;###autoload
(defun agent-org-start (provider)
  "Start a session with PROVIDER and open its Org chat buffer.
When called interactively, prompt for the provider.  What \"start\"
means is `agent-org-session-strategy''s business: with the default
`prompt' the agent is asked what this directory already holds and you
choose from that, or from `New session'.  One prefix argument forces
`new' for this call, skipping the listing; two force `latest', which
opens the most recently modified session without asking -- the same
16-and-up reading `agent-org-resume-session' uses for its second tier."
  (interactive (list (agent-org--read-provider)))
  (let* ((session (agent-org--open-session (agent-org--provider-spec provider)))
         (buffer (plist-get session :buffer))
         ;; decided NOW, not in the handshake callback:
         ;; `current-prefix-arg' belongs to the command loop, and the
         ;; strategy variable is whatever the caller had bound when they
         ;; asked.  Reading the variable late made a live probe that
         ;; bound `new' around `agent-org-start' still go and list the
         ;; directory, because by then the binding was gone
         (strategy (or (and current-prefix-arg
                            (if (>= (prefix-numeric-value current-prefix-arg) 16)
                                'latest
                              'new))
                       agent-org-session-strategy)))
    (agent-org-loader-begin buffer)
    (agent-org--initialize session
                           (lambda (resp)
                             (agent-org--begin-start session resp strategy)))
    buffer))

(defun agent-org--initialize (session &optional next)
  "Run the ACP initialize handshake for SESSION, then continue with NEXT.
NEXT receives the initialize response and owns the follow-up request;
resume uses it to read the agent's session capabilities.  Without it a
fresh `session/new' is started."
  (let* ((client (plist-get session :client))
         (buffer (plist-get session :buffer)))
    (acp-send-request
     :client client
     :request (acp-make-initialize-request
               :protocol-version 1
               :client-info `((name . "agent-org")
                              (title . "agent-org")
                              (version . "0.1.0"))
               :read-text-file-capability t
               :write-text-file-capability t)
     :buffer buffer
     :on-success (lambda (resp)
                   ;; recorded for the whole life of the session: the
                   ;; title sync at first turn end may run long after
                   ;; this callback
                   (setf (plist-get session :lists-sessions)
                         (agent-org--lists-sessions-p resp))
                   (if next
                       (funcall next resp)
                     (agent-org--session-new session)))
     :on-failure (lambda (_err msg)
                   (agent-org-loader-fail buffer
                     (format "initialize failed: %s" (agent-org--failure-text msg)))))))

(defun agent-org--session-new (session)
  "Ask SESSION's agent for a brand-new session and open the prompt."
  (let* ((client (plist-get session :client))
         (buffer (plist-get session :buffer))
         (cwd (or (plist-get session :cwd) default-directory)))
    (acp-send-request
     :client client
     :request (acp-make-session-new-request :cwd cwd)
     :buffer buffer
     :on-success (lambda (resp)
                   (agent-org--session-ready session
                     (map-elt resp 'sessionId)
                     resp))
     :on-failure (lambda (_err msg)
                   (agent-org-loader-fail buffer
                     (format "session/new failed: %s" (agent-org--failure-text msg)))))))

;;;; Resume

(defun agent-org--supports-load-p (initialize-resp)
  "Non-nil when the agent described by INITIALIZE-RESP answers session/load."
  (map-nested-elt initialize-resp '(agentCapabilities loadSession)))

(defun agent-org--lists-sessions-p (initialize-resp)
  "Non-nil when INITIALIZE-RESP advertises the `list' session capability.
Capability entries are present-or-absent keys (`sessionCapabilities'
maps a name to an empty object), so test with `assq', never with the
value's truthiness."
  (let ((caps (map-nested-elt initialize-resp
                              '(agentCapabilities sessionCapabilities))))
    (and (assq 'list caps) t)))

(defun agent-org--provider-name (session)
  "Human name of the provider SESSION was opened with, for messages."
  (plist-get (agent-org--provider-spec (plist-get session :name)) :name))

(defun agent-org--format-session-date (stamp)
  "ISO-8601 session stamp STAMP as a short human date, or nil.
Today and yesterday are spelled out, because they are the chats you are
most likely to want back; a stamp from this year shows the date and the
clock; anything older shows its year instead of the time, which is not
worth reading on a session from 2024.  A missing or unparsable stamp
yields nil rather than a candidate ending in \"(nil)\"."
  (when (and (stringp stamp) (not (string-empty-p stamp)))
    (ignore-errors
      (let ((then (date-to-time stamp)))
        (cond
         ((equal (format-time-string "%F" then) (format-time-string "%F"))
          (format "Today, %s" (format-time-string "%H:%M" then)))
         ((equal (format-time-string "%F" then)
                 (format-time-string "%F"
                                     (time-subtract (current-time) (days-to-time 1))))
          (format "Yesterday, %s" (format-time-string "%H:%M" then)))
         ((equal (format-time-string "%Y" then) (format-time-string "%Y"))
          (format-time-string "%b %d, %H:%M" then))
         (t (format-time-string "%b %d, %Y" then)))))))

(defun agent-org--session-stamp (session)
  "The recency stamp of a listed SESSION: `updatedAt', else `createdAt', else \"\".
Goose lists sessions that were never updated, and either field may be
absent on the wire.  An empty string sorts oldest, which is the honest
answer for a session with no date at all."
  (let ((stamp (or (map-elt session 'updatedAt) (map-elt session 'createdAt))))
    (if (stringp stamp) stamp "")))

(defun agent-org--pad (string width)
  "STRING left-aligned in a column WIDTH display columns wide.
Nil WIDTH is a no-op.  Padded by hand because `string-pad' counts
characters, so a CJK or emoji title would get half the room it actually
takes on screen; the measure here is `string-width', the same one
`agent-org--column-width' reports, so rows are measured and padded
identically.  An over-long string is left alone, never truncated."
  (let ((gap (and width (- width (string-width string)))))
    (if (or (null gap) (<= gap 0))
        string
      (concat string (make-string gap ?\s)))))

(defun agent-org--session-columns (title stamp)
  "The (TITLE . DATE) texts of a listed session, unpadded.
Providers put the session's first prompt in its `title', and a live qoder
listing was seen returning several thousand characters of it across dozens
of lines — verbatim that floods the completion list and wraps every
candidate, so `agent-org-buffer--label' collapses and shortens it.  An
empty title becomes \"(untitled)\": a blank column is indistinguishable
from a formatting bug.  STAMP is the agent's ISO-8601 recency, the only
thing that tells two chats with the same opening line apart; no stamp
means no date, not a made-up one.

Split out of `agent-org--session-display' because aligning a batch of
candidates means measuring every row before painting any of them."
  (let ((short (agent-org-buffer--label title)))
    (cons (if (string-empty-p short) "(untitled)" short)
          (or (agent-org--format-session-date stamp) ""))))

(defun agent-org--column-width (columns which)
  "The widest of COLUMNs in the column selected by WHICH, in display columns.
`string-width' and not `length' because `agent-org--pad' aligns on display
columns too: measuring rows one way and padding them another is how an
aligned list goes ragged on a title nobody typed in ASCII.  0 for an empty
listing, so `max' never sees nil."
  (apply #'max (cons 0 (seq-map (lambda (c) (string-width (funcall which c)))
                                columns))))

(defun agent-org--session-display (cols id &optional title-width date-width)
  "One-line completion label for a session: its COLS, then ID.
TITLE-WIDTH and DATE-WIDTH pad the first two columns so a whole listing
lines up: recency is what you scan a session list for, and ragged titles
put every date in a different column.  The date and the id are dimmed, not
shortened — the title is the thing you read, the rest is metadata.  ID
stays last and unpadded: it is what actually selects the session, and
padding it would leave trailing whitespace in a completion candidate."
  (format "%s  %s  %s"
          (agent-org--pad (car cols) title-width)
          (propertize (agent-org--pad (cdr cols) date-width) 'face 'shadow)
          (propertize (format "[%s]" id) 'face 'shadow)))

(defun agent-org--session-candidates (list-resp)
  "Convert a `session/list' response LIST-RESP into session candidates.
Returns ((DISPLAY . SESSION-ID) ...) newest first; DISPLAY is built by
`agent-org--session-columns' and `agent-org--session-display'.  Ordering
is ours: the wire says agents may return entries in any order, and an
ISO-8601 stamp sorts correctly as a string.
The columns are padded to the batch's own maxima, so one long title moves
every other date into its column instead of leaving a ragged list.  A row
whose session a live buffer already holds gets
`agent-org--open-marker' on its title, because choosing it switches
instead of loading (see `agent-org--load-session')."
  (let* ((sessions (agent-org--wire-list (map-elt list-resp 'sessions)))
         (sorted (seq-sort (lambda (a b)
                             (string> (agent-org--session-stamp a)
                                      (agent-org--session-stamp b)))
                           sessions))
         (columns (seq-map (lambda (s)
                             (let ((cols (agent-org--session-columns
                                          (map-elt s 'title)
                                          (agent-org--session-stamp s))))
                               ;; marked before measuring: the marker is
                               ;; part of the column, so it cannot widen one
                               (when (agent-org--session-open-p
                                      (map-elt s 'sessionId))
                                 (setf (car cols)
                                       (concat (car cols) agent-org--open-marker)))
                               cols))
                           sorted))
         (title-width (agent-org--column-width columns #'car))
         (date-width (agent-org--column-width columns #'cdr)))
    (seq-mapn (lambda (s cols)
                (let ((id (map-elt s 'sessionId)))
                  (cons (agent-org--session-display cols id title-width date-width)
                        id)))
              sorted columns)))

;;;; Switching between open chats

(defun agent-org--chat-columns (buffer)
  "The (LABEL . STATUS) texts of BUFFER's switcher row, unpadded.
LABEL is the chat's own display label — the harness and the project
directory, `agent-org-buffer--chat-label' being the very function the
buffer name is built from, so `C-x b' and this list can never call one chat
two things.  The session TITLE is in neither: the label says which agent you
are talking to and what it is a chat OF, and the topic is `#+TITLE:' inside
the chat.  Nothing here is agent free text any more, so no label filter is
applied.  STATUS is the header line's OWN state word
(`agent-org-buffer--state-label'): two vocabularies for one state is how a
person stops trusting either, and the bar and this list are read in the same
minute.

Reads the buffer-local status directly rather than through
`with-current-buffer': nothing here needs the buffer's other state, and a
switcher that widens a chat's buffer for no reason is a switcher that can
move point."
  (let ((status (buffer-local-value 'agent-org-buffer--status buffer)))
    (cons (agent-org-buffer--chat-label status)
          (agent-org-buffer--state-label (plist-get status :state)))))

(defun agent-org--switch-candidates ()
  "((DISPLAY . BUFFER) ...) for every live chat, in registry order.
Registry order is newest-chat-first, because `agent-org--register-session'
pushes — the chat you just started is the one you are most likely leaving
or returning to, and the wire's recency has nothing to say about a
session no agent has titled yet.

Killed buffers are dropped: the registry is a stack of plists, and an
entry outlives its window until the kill-hook runs, so \"live\" is what
makes a row switchable rather than merely listed.

The id column is what makes two rows from one provider distinguishable;
before the agent answers there is no id, so the buffer name stands in —
names are unique by construction (`generate-new-buffer-name'), which is
what `agent-org--selection-value' needs to hand back the right buffer."
  (let* ((buffers (seq-filter #'buffer-live-p
                              (delq nil (seq-map (lambda (session)
                                                  (plist-get session :buffer))
                                                agent-org--sessions))))
         (columns (seq-map #'agent-org--chat-columns buffers))
         (label-width (agent-org--column-width columns #'car))
         (status-width (agent-org--column-width columns #'cdr)))
    (seq-mapn (lambda (buffer cols)
                (cons (agent-org--session-display
                       cols
                       (or (plist-get (agent-org--session-for-buffer buffer)
                                      :session-id)
                           (buffer-name buffer))
                       label-width status-width)
                      buffer))
              buffers columns)))

;;;###autoload
(defun agent-org-switch-buffer ()
  "Switch to another open `agent-org' chat buffer.
The name is agent-shell's (`agent-shell-switch-buffer') — one action, one
name in M-x.  Each row is LABEL  STATUS  [id], the columns padded to the
batch's widest, so you scan down the state column instead of reading six
buffer names that differ in the middle.  Choosing gives the BUFFER
object, not its name: an agent renames its own chat, and a name looked up
afterwards can match nothing.

`C-x b' already reaches every buffer; this is the short list of the ones
that have an agent behind them, which is also why it takes its rows from
the registry rather than from a mode-name scan of the buffer list."
  (interactive)
  (let ((choices (agent-org--switch-candidates)))
    (unless choices
      (user-error "No agent-org chats are open"))
    (let ((buffer (agent-org--selection-value
                   choices
                   (completing-read "agent-org buffer: "
                                    (agent-org--completion-collection choices)
                                    nil t))))
      (unless buffer
        (user-error "Nothing selected"))
      (switch-to-buffer buffer))))

(defun agent-org--traffic-buffer (session)
  "Return the buffer holding SESSION's raw wire JSON, creating it when missing.
nil when SESSION never got a client — a session whose spawn failed is in
the registry no longer than its error message, but a chat buffer outlives
`agent-org--kill-session', and a killed process takes its client with it."
  (when-let* ((client (plist-get session :client)))
    (acp-traffic-buffer :client client)))

;;;###autoload
(defun agent-org-show-traffic (&optional buffer)
  "Show the raw JSON BUFFER's chat exchanged with its agent.
BUFFER defaults to the current buffer.  One line per message — time,
direction, kind, method — and RET on a line pretty-prints that message's
object, which is the only way to read what the agent actually sent rather
than what the chat shows: the transcript, the header line and the drawers
are all renderings of a chosen subset, and a discrepancy between what an
agent answered and what the chat recorded is settled only by the bytes on
the wire.  `n' and `p' step between messages; `C-x C-s' saves the lot as
 Lisp data for a fixture.

The log is acp's own `acp-traffic-mode' buffer for this chat's client, so
it holds every request we sent and every response and notification that
came back, including the ones no part of agent-org consumes."
  (interactive)
  (let* ((buffer (or buffer (current-buffer)))
         (session (agent-org--session-for-buffer buffer)))
    (unless session
      (user-error "%s is not an agent-org chat" (buffer-name buffer)))
    (let ((traffic (agent-org--traffic-buffer session)))
      (unless traffic
        (user-error "%s has no running agent to log" (buffer-name buffer)))
      (when (= 0 (buffer-size traffic))
        (user-error "No traffic recorded for %s yet — %s"
                    (buffer-name buffer)
                    (if (or acp-logging-enabled agent-org-log-traffic)
                        "no message has arrived since it opened"
                      "set agent-org-log-traffic to t, then restart it")))
      (pop-to-buffer traffic)
      ;; newest first: the message that prompted the question is the last
      ;; one written, and point-max sits on the empty line after it
      (forward-line -1))))

(cl-defun agent-org--list-sessions (session
                                    &key cursor seen pages
                                    (page-limit agent-org-session-list-page-limit)
                                    quiet
                                    on-success on-failure)
  "Fetch the directory's `session/list' pages for SESSION, then ON-SUCCESS.
CURSOR is the continuation the agent offered on the previous page, SEEN
every cursor used so far, PAGES what has been gathered: a page past the
first is reached through exactly one cursor, so SEEN also counts the
pages.  PAGE-LIMIT nil means follow cursors until the agent stops
offering one; an integer caps the requests and the remainder is dropped.
ON-SUCCESS gets one synthesized response, `((sessions . VECTOR))', so
the candidates helper does not care how many pages it came from.
ON-FAILURE gets the ACP error and the raw message.

QUIET non-nil suppresses the echo-area progress report, for a background
lookup the user never asked for (see `agent-org--sync-title') -- it must
not replace what the echo area currently says.

An agent that hands back the cursor it was just sent would page here
forever, so a repeated cursor is a failure, not another request.

The paging owns its progress report end to end — started on the first
page, stepped once per page, closed on every one of the ways out — so
neither caller has to know it exists, and a `session/list' cannot end
with a line still spinning over the chooser."
  (agent-org--validate-page-limit page-limit)
  (let ((buffer (plist-get session :buffer)))
    (when (null cursor)
      ;; One report for the whole paging, and creating it already paints
      ;; the line in the echo area, so the wait before the first page is
      ;; described too.  The recursion leaves the report alone.
      (unless quiet
        (agent-org--progress-start session "Listing sessions")))
    (acp-send-request
     :client (plist-get session :client)
     :request (acp-make-session-list-request
               :cwd (or (plist-get session :cwd) default-directory)
               :cursor cursor)
     :buffer buffer
     :on-success (lambda (resp)
                   (let ((all (vconcat pages
                                       (or (map-elt resp 'sessions) [])))
                         (next (map-elt resp 'nextCursor)))
                     ;; A spinner has no denominator, so it gets a number
                     ;; of its own: how many the agent has named is the
                     ;; difference between "working" and "hung" while a
                     ;; silent agent pages.
                     (unless quiet
                       (agent-org--progress-step session (format "%d so far" (length all))))
                     (cond
                      ((null next)
                       (unless quiet (agent-org--progress-stop session))
                       (funcall on-success `((sessions . ,all))))
                      ((member next seen)
                       (unless quiet (agent-org--progress-stop session))
                       (funcall on-failure
                                nil '((message . "agent repeated the same session/list cursor"))))
                      ((and page-limit (>= (1+ (length seen)) page-limit))
                       (unless quiet (agent-org--progress-stop session))
                       (funcall on-success `((sessions . ,all))))
                      (t
                       (agent-org--list-sessions
                        session
                        :cursor next
                        :seen (cons next seen)
                        :pages all
                        :page-limit page-limit
                        :quiet quiet
                        :on-success on-success
                        :on-failure on-failure)))))
     :on-failure (lambda (err msg)
                   (unless quiet (agent-org--progress-stop session))
                   (funcall on-failure err msg)))))

(defun agent-org--settle-listing (session)
  "Own SESSION's pending listing outcome, and cancel its timeout.
Returns t for the one caller — answer, failure or timeout — that gets to
act, nil for whoever arrives after.  Without this a `session/list' that
answers late would load a second session into a buffer that is already
opening a fresh one."
  (when-let* ((timer (plist-get session :list-timer)))
    (cancel-timer timer)
    (setf (plist-get session :list-timer) nil))
  (prog1 (eq (plist-get session :list-state) 'pending)
    (setf (plist-get session :list-state) 'settled)))

(defun agent-org--list-timeout (session)
  "Stop waiting for SESSION's silent `session/list', and start a new session.
The function is named rather than a closure so a test can find and fire
the timer, and because the guard belongs on the session, not on the
timer's capture.  A listing that already answered is not re-decided:
`agent-org--settle-listing' gives the outcome to exactly one caller.

The buffer check is the second lock.  `agent-org--forget-session' unarms
this timer when a chat buffer is killed, but a timer is only best-effort
insurance against a dead buffer — so a firing one verifies the buffer is
still there before it claims the listing outcome and opens a session into
nothing."
  (let ((buffer (plist-get session :buffer)))
    (when (and buffer (buffer-live-p buffer)
               (agent-org--settle-listing session))
      ;; Close the report BEFORE the note: `agent-org--progress-stop'
      ;; clears the echo area, and the note is about to be written into
      ;; it.  The pager cannot do this itself — the request it is waiting
      ;; on is exactly the thing that never answered.
      (agent-org--progress-stop session)
      (message "agent-org: %s did not answer session/list within %ss; starting a new session"
               (agent-org--provider-name session)
               agent-org-session-list-timeout)
      (agent-org--note-new-session session
        (format "listing timed out after %ss" agent-org-session-list-timeout))
      (agent-org--session-new session))))

(defun agent-org--note-new-session (session reason)
  "Say on SESSION's header line why this session is new and not chosen.
The echo-area `message' these fallback paths also make is easy to miss,
and the header renders only the label \"Ready\" for a ready state
(CONVENTIONS.md §6) — so a listing that gave up looked exactly like a
listing that never ran.  That is how it was first reported, in fact.
REASON arrives as agent text, so it goes through
`agent-org-buffer--label': the header is one line, whatever the agent
chose to say in it."
  (agent-org-buffer-set-status (plist-get session :buffer)
    :note (agent-org-buffer--label (format "new session: %s" reason))))

(defun agent-org--completion-collection (choices)
  "A `completing-read' collection over CHOICES that keeps our order.
CHOICES is ((DISPLAY . VALUE) ...); the collection offers the DISPLAYs,
which are the only thing a human can read.  A plain list would be handed
over the UI's sort, and the order of this list IS information — newest
first, `New session' on top — so a two-year-old chat could land first.
`display-sort-function' only travels on `metadata', and only a function
collection can answer that action (agent-shell does exactly this).
`identity' means \"display them in the order you were given\"."
  (lambda (string pred action)
    (if (eq action 'metadata)
        '(metadata (display-sort-function . identity)
                   (cycle-sort-function . identity))
      (complete-with-action action (mapcar #'car choices) string pred))))

(defun agent-org--selection-value (choices selection)
  "The value in CHOICES whose display is SELECTION, or nil.
Not `assoc': a display carries `face' text properties for the dimmed
columns, `assoc' compares with `equal' which compares properties too, and
a completion framework that rebuilds the string rather than returning the
collection's member would then match nothing.  Each display ends with the
session id, so property-free text is a unique key."
  (let ((wanted (substring-no-properties selection)))
    (cdr (seq-find (lambda (choice)
                     (equal (substring-no-properties (car choice)) wanted))
                   choices))))

(defun agent-org--read-start-choice (candidates)
  "Complete over CANDIDATES plus `agent-org-new-session-label'.
Returns the chosen session id, or :new.  The display is for the human and
the cdr is what selects, same as `agent-org--read-session-id'.
`this-command' is bound because some completion frameworks otherwise
append the collection's default to every candidate, and the list fills
with noise."
  (let* ((choices (cons (cons agent-org-new-session-label :new) candidates))
         (this-command 'agent-org-start))
    (agent-org--selection-value
     choices
     (completing-read "Start or resume: "
                      (agent-org--completion-collection choices) nil t))))

(defun agent-org--choose-start (session list-resp strategy)
  "Open SESSION out of LIST-RESP the way STRATEGY says to.
`latest' takes the newest without asking; `prompt' offers the listing
with `New session' on top.  An empty directory is a new session either
way, and that is the common case for a first chat in a fresh project.
Quitting the prompt releases SESSION and sends nothing at all."
  (let* ((candidates (agent-org--session-candidates list-resp))
         (choice (cond
                  ((null candidates) :new)
                  ((eq strategy 'latest) (cdar candidates))
                  (t (agent-org--quit-cancels session
                       (agent-org--read-start-choice candidates))))))
    (cond
     ((null choice) nil)
     ((eq choice :new) (agent-org--session-new session))
     (t (agent-org--load-session session choice)))))

(defun agent-org--begin-start (session initialize-resp strategy)
  "Open SESSION after the handshake, honouring the command's STRATEGY.
`new', or an agent that cannot list or cannot load, goes straight to
`session/new' — no extra round trip for a listing that would be thrown
away.  Otherwise the directory's sessions are fetched, with
`agent-org-session-list-timeout' covering an agent that advertises
`list' and then never answers it, and `agent-org--choose-start' decides
what to open.  A failed listing is a new session plus an echo note too:
starting a chat must never be blocked by the feature that shows you the
older ones.

STRATEGY arrives already decided by `agent-org-start', which is the only
caller: reading `agent-org-session-strategy' here would read the value
in scope when the agent answers, not the one in scope when you asked."
  (agent-org--validate-session-strategy strategy)
  (if (or (eq strategy 'new)
          (not (agent-org--lists-sessions-p initialize-resp))
          (not (agent-org--supports-load-p initialize-resp)))
      (agent-org--session-new session)
    (setf (plist-get session :list-state) 'pending)
    (when agent-org-session-list-timeout
      (setf (plist-get session :list-timer)
            (run-at-time agent-org-session-list-timeout nil
                         #'agent-org--list-timeout session)))
    (agent-org--list-sessions
     session
     :on-success (lambda (list-resp)
                   (when (agent-org--settle-listing session)
                     (agent-org--choose-start session list-resp strategy)))
     :on-failure (lambda (_err msg)
                   (when (agent-org--settle-listing session)
                     (let ((reason (agent-org--failure-text msg)))
                       (message "agent-org: session/list failed (%s); starting a new session"
                                reason)
                       (agent-org--note-new-session session reason))
                     (agent-org--session-new session))))))

(defun agent-org--read-session-id (list-resp)
  "Pick the session to resume out of a `session/list' response LIST-RESP.
A single candidate is used without prompting; none is a user-error.
One prompt, one collection: this shares `agent-org--read-start-choice's
helpers so the resume list and the start list cannot drift apart."
  (let ((cands (agent-org--session-candidates list-resp)))
    (cond
     ((null cands) (user-error "No sessions to resume in this directory"))
     ((null (cdr cands)) (cdar cands))
     (t (let ((this-command 'agent-org-resume-session))
          (agent-org--selection-value
           cands
           (completing-read "Resume session: "
                            (agent-org--completion-collection cands) nil t)))))))

(defcustom agent-org-replay-settle-delay 0.4
  "Seconds of silence that end a `session/load' replay.
The buffered history is rendered once no conversational update has
arrived for this long.  Agents are not uniform about when they send it:
the protocol says before the load response, live qoder answers first
and streams the replay right after, so the response alone cannot be the
flush point.  Keep this short — the buffer stays on \"Restoring\"
meanwhile."
  :type 'number
  :group 'agent-org)

(defcustom agent-org-replay-settle-cap 20
  "Seconds after which a replay renders even if updates keep arriving.
An upper bound on how long a resume can hold a buffer in Restoring:
without it, an agent that never pauses between replayed turns would
delay `agent-org-replay-settle-delay' forever."
  :type 'number
  :group 'agent-org)

(defun agent-org--arm-replay-render (session)
  "Push back SESSION's buffered replay render by one settle delay.
Called when the load response lands, and again on every conversational
update that arrives after it, so the render happens once the agent
stops talking.  Past `agent-org-replay-settle-cap' the already armed
timer is left alone: rendering a partial history beats a buffer stuck
in Restoring."
  (let ((timer (plist-get session :replay-timer)))
    (when (or (null timer)
              (< (float-time) (or (plist-get session :replay-deadline) 0)))
      (when timer (cancel-timer timer))
      (setf (plist-get session :replay-timer)
            (run-at-time agent-org-replay-settle-delay nil
                         #'agent-org--finish-replay session)))))

(defun agent-org--unschedule-replay (session)
  "Cancel SESSION's armed replay render, keeping the buffered updates."
  (when-let* ((timer (plist-get session :replay-timer)))
    (cancel-timer timer))
  (setf (plist-get session :replay-timer) nil))

(defun agent-org--cancel-replay (session)
  "Drop SESSION's replay entirely: pending render, buffer, loading flag.
A failed load leaves nothing worth painting — and nothing worth
reporting, so the echo area is cleared here rather than left with a
spinner for a restore that is never coming."
  (agent-org--unschedule-replay session)
  (agent-org--progress-stop session)
  (setf (plist-get session :replay) nil)
  (setf (plist-get session :loading) nil))

(defun agent-org--recorded-queue (session)
  "The prompts SESSION's transcript says were still waiting, oldest first.
Read with the chat buffer current, because that is what resolves the
transcript against the session's own project — the same resolution the
writer used, so a reader cannot look in the wrong directory.  nil for the
common case: no file, no drawer, an empty drawer."
  (with-current-buffer (plist-get session :buffer)
    (agent-org-buffer-transcript-queue
     (or (plist-get session :replay-session-id)
         (plist-get session :session-id)))))

(defun agent-org--finish-replay (session)
  "Render SESSION's buffered replay and open the session for prompts.
This is the flush point `agent-org--arm-replay-render' schedules: by now
the agent has sent everything it is going to send about history, so
`:loading' can drop and the buffered updates paint in one pass.

The transcript's waiting prompts are read BEFORE anything else happens
here, and applied once the session is ready.  Both halves of that order
matter.  Read first because `agent-org--session-ready' mirrors the
freshly replayed buffer over that file, and a replayed buffer carries no
queue — the agent never saw a prompt that was never sent — so reading
after the write would find an empty drawer.  Applied last because a
drained prompt goes on the wire, and the wire needs an interactive
session: id set, prompt box open, `:loading' gone."
  (agent-org--unschedule-replay session)
  (setf (plist-get session :loading) nil)
  (let ((queued (agent-org--recorded-queue session)))
    (agent-org--render-replay session)
    (agent-org--session-ready session
      (plist-get session :replay-session-id)
      (plist-get session :replay-response))
    (when queued
      (setf (plist-get session :pending-prompts) queued)
      (message "[agent-org] %d queued prompt(s) reloaded from the transcript"
               (length queued))
      ;; the same drain a turn end performs: the first prompt goes out, the
      ;; rest keep waiting in the header count and in the drawer
      (agent-org--drain-queue session (plist-get session :buffer)))))

(defun agent-org--load-session (session session-id)
  "Replay SESSION-ID into SESSION's buffer with a `session/load' request.
`:loading' is set for the whole replay, so `agent-org--on-notification'
buffers conversational updates instead of painting them chunk by chunk;
the batched render fires once they stop arriving (see
`agent-org--arm-replay-render'), which is what keeps resume usable on a
low-spec machine — a 200-turn session would otherwise re-fontify the
buffer once per chunk.

Responses from the wire carry the session id only inside the replay
notifications, so the request's SESSION-ID is the fallback.

This is the one place that decides whether to send `session/load' at all:
when some buffer already holds SESSION-ID, showing it beats loading it
twice, whoever asked (`agent-org-start', `agent-org-resume-session' or a
typed id) and however the id was chosen."
  (let ((buffer (plist-get session :buffer))
        (cwd (or (plist-get session :cwd) default-directory)))
    (if-let* ((open (agent-org--session-open-p session-id)))
        (agent-org--show-open-instead session open)
      (setf (plist-get session :loading) t)
      (agent-org-buffer-set-status buffer :state 'loading :message "Restoring…")
      ;; The header line says which state the buffer is in; the echo area
      ;; says how much of it has landed.  Before this, a 200-turn restore
      ;; and a hung agent were indistinguishable for the whole replay.
      (agent-org--progress-start session "Restoring session history")
      (acp-send-request
       :client (plist-get session :client)
       :request (acp-make-session-load-request :session-id session-id :cwd cwd)
       :buffer buffer
       :on-success (lambda (resp)
                     ;; The response is not the end of the replay: hold the
                     ;; buffered updates until the agent goes quiet, then
                     ;; render (see `agent-org--arm-replay-render').
                     (setf (plist-get session :replay-session-id)
                           (or (map-elt resp 'sessionId) session-id))
                     (setf (plist-get session :replay-response) resp)
                     (setf (plist-get session :replay-deadline)
                           (+ (float-time) agent-org-replay-settle-cap))
                     (agent-org--arm-replay-render session))
       :on-failure (lambda (_err msg)
                     (agent-org--cancel-replay session)
                     (agent-org-loader-fail buffer
                       (format "session/load failed: %s"
                               (agent-org--failure-text msg))))))))

(defun agent-org--resume-locate (session initialize-resp session-id)
  "Work out which session of SESSION to load, then load it.
SESSION-ID given (the \\[universal-argument] \\[universal-argument] path)
skips the listing entirely.  Otherwise ask the agent to list the
sessions of this directory — possible only when it advertises the
`list' capability — and let `agent-org--read-session-id' pick.

Resume shares `agent-org--list-sessions' with `agent-org-start' rather
than sending its own request: two listing renderers would drift, and the
older chats a directory holds are exactly the ones past the first page.

Goose is known to advertise list and then never answer it, so the
request is left in flight with a Restoring header rather than guessed
at; Ctrl-G cancels it.  (`agent-org-start' cannot hang that way — it
arms `agent-org-session-list-timeout' — but resume already sits behind
an explicit request to resume, so falling back to a new session there
would be the wrong surprise.)"
  (let ((buffer (plist-get session :buffer)))
    (cond
     (session-id (agent-org--load-session session session-id))
     ((not (agent-org--lists-sessions-p initialize-resp))
      (agent-org-loader-fail buffer
        (format "%s does not list sessions" (agent-org--provider-name session))))
     (t
      (agent-org--list-sessions
       session
       :on-success (lambda (list-resp)
                     (if (agent-org--session-candidates list-resp)
                         ;; quitting releases the session by killing its
                         ;; buffer, so the load must not run after it
                         (when-let* ((id (agent-org--quit-cancels session
                                  (agent-org--read-session-id list-resp))))
                           (agent-org--load-session session id))
                       (agent-org-loader-fail buffer
                         "No sessions to resume in this directory")))
       :on-failure (lambda (_err msg)
                     (agent-org-loader-fail buffer
                       (format "session/list failed: %s"
                               (agent-org--failure-text msg)))))))))

;;;###autoload
(defun agent-org-resume-session (provider session-id)
  "Resume an existing session with PROVIDER, replaying its history.
With no prefix argument PROVIDER is `agent-org-default-provider'; one
\\[universal-argument] prompts for it.  The session itself is chosen
from the agent's `session/list' for the current directory; two
\\[universal-argument] prefixes read a SESSION-ID directly, which is
also how callers from lisp pin one."
  (interactive
   (list (if current-prefix-arg
             (agent-org--read-provider)
           agent-org-default-provider)
         (and (>= (prefix-numeric-value current-prefix-arg) 16)
              (read-string "Session id: "))))
  (let* ((spec (agent-org--provider-spec provider))
         (session (agent-org--open-session spec)))
    (agent-org--initialize
     session
     (lambda (resp)
       (if (agent-org--supports-load-p resp)
           (agent-org--resume-locate session resp session-id)
         (agent-org-loader-fail (plist-get session :buffer)
           (format "%s does not support session/load"
                   (plist-get spec :name))))))
    (plist-get session :buffer)))

;;;; Interrupt

;;;###autoload
(defun agent-org-cancel-turn ()
  "Stop the streaming turn: send ACP `session/cancel' and free the buffer.
Port of `agent-shell-interrupt' (agent-shell.el:2243), whose mechanism
is the fire-and-forget notification plus nothing else: agent-shell lets
the agent's own (cancelled) answer to the outstanding prompt request
end the turn.  That is not safe here — an agent that never answers
would keep the buffer frozen in Streaming forever, which is exactly the
state the user just tried to escape — so this closes the turn locally
the moment the notification goes out, and the turn id in SESSION's
`:turn' makes the late answer drop (`agent-org--send-turn').

The session survives (unlike `agent-org-reload', which restarts the agent
process).  The prompt queue survives and stays WAITING: a cancel is the user
saying \"stop\", and the prompts behind the cancelled turn were queued to join
the work being stopped.  Releasing them here put a turn on the wire nobody
asked for, and each one that answered fired the next, so one cancel emptied
the whole queue in seconds (live bug; the user's order: \"Cancelling turn
should never resume queue\").  `agent-org-queue-resume' (C-c C-r) is the way
back, and a later turn ending successfully drains FIFO as always."
  (interactive)
  (let* ((buffer (current-buffer))
         (session (agent-org--session-for-buffer buffer)))
    (unless session
      (user-error "Not an agent-org chat buffer"))
    (unless (plist-get session :session-id)
      (user-error "Session not ready"))
    (unless (plist-get session :streaming)
      (user-error "No turn in flight"))
    (acp-send-notification
     :client (plist-get session :client)
     :notification (acp-make-session-cancel-notification
                    :session-id (plist-get session :session-id)
                    :reason "User cancelled"))
    ;; Retire the turn BEFORE closing anything: the guard above drops
    ;; the agent's answer whenever `:turn' no longer matches the id the
    ;; request was sent under, and nil matches no id at all.
    (setf (plist-get session :turn) nil)
    (setf (plist-get session :streaming) nil)
    (agent-org-buffer-end-agent-turn buffer)
    ;; The note rides the Ready label by design (`:note' is the fact
    ;; that outlives the message): "Ready (turn cancelled)".
    (agent-org-buffer-set-status buffer :state 'ready :note "turn cancelled")
    ;; The box comes back by hand, because draining used to do it: with an
    ;; empty queue `agent-org--drain-queue' opens the prompt, and nothing
    ;; else on this path does.
    (agent-org-buffer-insert-prompt buffer)
    (agent-org--queue-refresh session buffer)
    (agent-org-buffer-refresh-metadata buffer)
    (agent-org-buffer-transcribe buffer)
    (when-let* ((waiting (length (plist-get session :pending-prompts)))
                ((> waiting 0)))
      (message "[agent-org] turn cancelled — %d queued prompt(s) held back: M-x agent-org-queue-resume"
               waiting))))

;;;; Reload

;;;###autoload
(defun agent-org-reload ()
  "Restart this chat's agent and replay the SAME session through resume.
Port of `agent-shell-reload' (agent-shell.el:1604), which is exactly
\"restart with the same =:session-id=\" — it does not re-read anything
from the old buffer.  The chat is killed silently with its agent (the
kill hook shuts the process down), then the recorded
\(:cwd . :session-id) pair goes back through `agent-org-resume-session',
which loads the whole history afresh from the agent and re-renders it in
the same window.  The buffer name regenerates from the replayed title
and id, so it comes back looking like the one that was replaced.

The old buffer must be gone before the load: `agent-org--load-session'
refuses to `session/load' an id a live buffer already holds and would
switch to it instead.  A prompt that was queued but never sent comes
back, because it lives in the transcript's =:QUEUE:= drawer rather than
in the buffer, and a restart goes through resume: the fresh agent gets
the prompts the old one never saw.  Worth knowing before restarting a
session you want to leave alone."
  (interactive)
  (let* ((buffer (current-buffer))
         (session (agent-org--session-for-buffer buffer)))
    (unless session
      (user-error "Not an agent-org chat buffer"))
    (unless (plist-get session :session-id)
      (user-error "Session not ready"))
    (when (plist-get session :loading)
      (user-error "Session history is still loading"))
    (when (and (plist-get session :streaming)
               (not (y-or-n-p "Agent is responding.  Reload anyway? ")))
      (user-error "Cancelled"))
    (let* ((sid (plist-get session :session-id))
           (cwd (or (plist-get session :cwd) default-directory))
           (provider (plist-get session :name))
           (windows (get-buffer-window-list buffer nil t)))
      (agent-org--kill-buffer-silently buffer)
      (let ((new (let ((default-directory cwd))
                   (agent-org-resume-session provider sid))))
        ;; Reuse the windows the killed chat was shown in, as
        ;; `agent-shell-restart' does; resume has already switched to the
        ;; new buffer somewhere, so at least one live window takes it.
        (dolist (w (seq-filter #'window-live-p windows))
          (set-window-buffer w new))
        new))))

;;;; Model selection

(defun agent-org--read-model ()
  "Complete a model id out of the current chat buffer's advertised options.
Returns the wire value; the candidate shown is the agent's own label
(e.g. \"OpenCode Zen/MiniMax-M2.7\"), which is why candidates are paired
with their values instead of being a plain list of strings."
  (let* ((session (agent-org--session-for-buffer (current-buffer)))
         (option (and session
                      (agent-org--model-option (agent-org--session-config session))))
         (candidates
          (seq-map (lambda (o)
                     (cons (agent-org-buffer--label
                            (or (map-elt o 'name) (map-elt o 'value)))
                           (map-elt o 'value)))
                   (agent-org--wire-list (map-elt option 'options)))))
    (unless candidates
      (user-error "This agent offers no model options"))
    ;; same label-keyed lookup as `agent-org--read-session-id': the display
    ;; is for the human, the cdr is what goes on the wire
    (cdr (assoc (completing-read "Model: " (seq-map #'car candidates) nil t)
                candidates))))

;;;###autoload
(defun agent-org-set-session-model (model)
  "Switch the current agent-org session to MODEL.
Interactively, complete over the models the agent advertises.  From lisp
MODEL must be one of those ids, so a typo cannot quietly become a failed
request: agents rename their catalog between releases.

Use this to move a `opencode acp' session between the models it fronts,
MiniMax included; `agent-org-providers' pins one per provider instead."
  (interactive (list (agent-org--read-model)))
  (let ((session (agent-org--session-for-buffer (current-buffer))))
    (unless session
      (user-error "Not an agent-org chat buffer"))
    (unless (plist-get session :session-id)
      (user-error "Session not ready"))
    (unless (member model (agent-org--model-values (agent-org--session-config session)))
      (user-error "Agent does not offer model: %s" model))
    (agent-org--set-model-request session model)))

;;;; Event subscription

(defun agent-org--subscribe (client session)
  "Wire CLIENT notifications/requests to SESSION's Org handlers."
  (acp-subscribe-to-notifications
   :client client
   :buffer (plist-get session :buffer)
   :on-notification (lambda (n)
                      (agent-org--on-notification session n)))
  (acp-subscribe-to-requests
   :client client
   :buffer (plist-get session :buffer)
   :on-request (lambda (r)
                 (agent-org--on-request session r)))
  (acp-subscribe-to-errors
   :client client
   :buffer (plist-get session :buffer)
   :on-error (lambda (err)
               (agent-org-buffer-set-status
                (plist-get session :buffer)
                :state 'error
                :message (format "ACP error: %s"
                                 (or (map-elt err 'message)
                                     (map-elt err 'data)
                                     "unknown"))))))

;;;; Notification dispatch

(defconst agent-org--replay-kinds
  '("user_message_chunk" "agent_message_chunk" "agent_thought_chunk"
    "tool_call" "tool_call_update")
  "Update kinds that carry conversation content.

While a `session/load' is in flight these are buffered rather than
rendered, because the agent replays the whole history of the session —
the protocol says before the load response, live qoder answers first
and streams it right after — and painting each chunk as it lands would
re-fontify the buffer once per chunk.  Anything outside this list
(usage, commands, mode, title) is metadata about the live session and is
dispatched immediately even during a replay.")

(defun agent-org--chunk-text (content)
  "Extract plain text from an ACP message/thought CONTENT value.
CONTENT may be a text ContentBlock alist or a bare string."
  (cond
   ((stringp content) content)
   ((and (listp content) (map-elt content 'text))
    (map-elt content 'text))))

(defun agent-org--buffer-update (buffer update)
  "Render one replayed content UPDATE into BUFFER.
The live streaming primitives do the work, so restored history is laid
out exactly like history that was typed: consecutive agent chunks flow
into one `* Agent' turn, tools become `**' TODO headings, thoughts
fold into the per-turn :thinking: drawer.  Status writes are omitted on
purpose — a restored turn finished long ago and must not touch the
header line."
  (let ((kind (map-elt update 'sessionUpdate)))
    (pcase kind
      ("agent_message_chunk"
       (when-let* ((text (agent-org--chunk-text (map-elt update 'content))))
         (agent-org-buffer-append-chunk buffer text nil)))
      ("agent_thought_chunk"
       (when-let* ((text (agent-org--chunk-text (map-elt update 'content))))
         (agent-org-buffer-append-thought buffer text)))
      ((or "tool_call" "tool_call_update")
       (agent-org-buffer-insert-tool buffer update))
      (_ nil))))

(defun agent-org--flush-user (buffer text)
  "Freeze replayed user prompt TEXT as the exchange heading it belongs to.
No-op when TEXT is empty.  The Agent turn before it closes first, or
the heading would land inside that response.

A replay splits one prompt across several chunks, so this is where
they become a single turn again.  The previous Agent turn needs no explicit
close here: opening an exchange closes it (`agent-org-buffer-begin-exchange'),
or the heading would land inside the answer it follows."
  (when (and text (not (string-empty-p (string-trim text))))
    (agent-org-buffer-begin-exchange buffer (string-trim text))))

(defun agent-org--render-replay (session)
  "Paint SESSION's buffered `session/load' replay into its buffer.
One pass over the buffered updates with undo recording off, so restoring
a long session is a single insertion run rather than thousands of
undo-worthy edits.  Clears `:replay' and leaves every turn closed, so
the caller can open the live prompt.

This pass is reported as a fraction rather than a spinner, and it is the
one phase with a denominator: the replay has been buffered and counted
by now.  It is also where a slow machine spends real seconds — hundreds
of Org insertions in a synchronous run, during which Emacs can tell the
user nothing except through the echo area.  Stepping the report once per
update costs a comparison; the display behind it is bounded by
`agent-org-progress-min-time', which is why the loop does not also need
to count down to some stride."
  (let* ((buffer (plist-get session :buffer))
         (updates (nreverse (plist-get session :replay)))
         (total (length updates))
         (painted 0)
         (pending nil))
    (setf (plist-get session :replay) nil)
    (agent-org--progress-start session "Restoring session history" :total total)
    (with-current-buffer buffer
      (let ((buffer-undo-list t))
        ;; Font-lock is NOT suppressed for this pass, whatever the bulk-paint
        ;; intuition says: `font-lock-mode' cannot be RE-enabled in a buffer no
        ;; window is showing, so the old off-then-restore lost the chat's
        ;; colors permanently on every resume that painted in the background
        ;; (`agent-org--flush-user' and `--buffer-update' keep font-lock on too;
        ;; see `agent-org-buffer--ensure-font-lock' for how a buffer first gets
        ;; it).  A flush at the end is still right: hundreds of lines landed at
        ;; once and the visible part should be redrawn in one go, not chunk by
        ;; chunk.  It is harmless when colors are off -- the real function
        ;; checks `font-lock-mode' itself.
        ;;
        ;; UNWIND, not a tail call: an update that raises here is swallowed by
        ;; acp's own `condition-case-unless-debug', so the flush and the report
        ;; stop would never run -- the chat would sit unfontified with a
        ;; "Restoring" line still on screen, silently.
        (unwind-protect
            (progn
              (dolist (update updates)
                (agent-org--progress-step session (cl-incf painted))
                (if (equal (map-elt update 'sessionUpdate) "user_message_chunk")
                    (setq pending (concat pending
                                          (agent-org--chunk-text
                                           (map-elt update 'content))))
                  (agent-org--flush-user buffer pending)
                  (setq pending nil)
                  (agent-org--buffer-update buffer update)))
              (agent-org--flush-user buffer pending)
              (agent-org-buffer-end-agent-turn buffer))
          (font-lock-flush)
          (agent-org--progress-stop session))))))

(defun agent-org--on-notification (session notification)
  "Dispatch one ACP NOTIFICATION for SESSION into the Org buffer.
This is the single, non-recursive notification handler; every update
kind is handled here and nothing is delegated to another handler."
  (let* ((buffer (plist-get session :buffer))
         (method (map-elt notification 'method))
         (params (map-elt notification 'params))
         (update (map-elt params 'update))
         (kind (map-elt update 'sessionUpdate)))
    (when (equal method "session/update")
      (if (and (plist-get session :loading)
               (member kind agent-org--replay-kinds))
          (progn
            (push update (plist-get session :replay))
            ;; The replay is what the wait consists of, so each chunk is
            ;; the tick: a report stepping here needs no timer of its own
            ;; to show that history is arriving.  It is passed no number,
            ;; because counting the buffer (`length' of a growing list,
            ;; O(n) per chunk) and formatting a string per chunk are two
            ;; costs this loop buys nothing — the indicator moving already
            ;; says "arriving", and the count that does pay for itself,
            ;; the painted fraction, comes from `agent-org--render-replay'.
            (agent-org--progress-step session)
            ;; A render is armed only after the load response lands, so
            ;; re-arming here is exactly what keeps history that arrives
            ;; *after* that response out of the bit-bucket.
            (when (plist-get session :replay-timer)
              (agent-org--arm-replay-render session)))
        (pcase kind
          ("session_info_update"
           (when-let* ((sid (map-elt params 'sessionId)))
             (when-let* ((title (or (map-elt update 'title)
                                    (map-elt params 'title))))
               (agent-org-buffer-set-status buffer :title title))
             ;; mid-replay only the identity/title is worth recording:
             ;; marking the session ready would flip the header to Ready
             ;; and open a prompt on top of history still arriving
             (if (plist-get session :loading)
                 (setf (plist-get session :session-id) sid)
               (agent-org--session-ready session sid))))
          ("agent_message_chunk"
           ;; Conversational updates belong to a turn the client asked
           ;; for; anything the agent emits outside a live prompt (e.g.
           ;; stray chunks after a cancel) is dropped, so a fresh
           ;; session body can never fill up unasked.
           (when (plist-get session :streaming)
             (agent-org-buffer-set-status buffer :state 'streaming :message nil)
             (when-let* ((text (agent-org--chunk-text (map-elt update 'content))))
               (agent-org-buffer-append-chunk buffer text session))))
          ("agent_thought_chunk"
           (when (plist-get session :streaming)
             (when-let* ((text (agent-org--chunk-text (map-elt update 'content))))
               (agent-org-buffer-append-thought buffer text))))
          ((or "tool_call" "tool_call_update")
           (when (plist-get session :streaming)
             (agent-org-buffer-insert-tool buffer update)))
          ("available_commands_update"
           (agent-org-buffer-set-status
            buffer :commands
            (agent-org--wire-list (map-elt update 'availableCommands)))
           (agent-org-buffer-refresh-metadata buffer))
          ("usage_update"
           (agent-org-buffer-set-status buffer
             :used (map-elt update 'used) :size (map-elt update 'size))
           (agent-org-buffer-refresh-metadata buffer))
          ("current_mode_update"
           (agent-org-buffer-set-status buffer
             :mode (map-elt update 'currentModeId))
           (agent-org-buffer-refresh-metadata buffer))
          ("config_option_update"
           (let ((config (agent-org--wire-list (map-elt update 'configOptions))))
             (when config
               (agent-org--ingest-config buffer config)
               (agent-org-buffer-refresh-metadata buffer))))
          (_ nil))))))

;;;; Incoming request handling

(defun agent-org--on-request (session request)
  "Handle an incoming ACP REQUEST from the agent (must respond)."
  (let* ((client (plist-get session :client))
         (buffer (plist-get session :buffer))
         (method (map-elt request 'method))
         (req-id (map-elt request 'id))
         (params (map-elt request 'params)))
    (pcase method
      ("fs/read_text_file"
       (let* ((path (map-elt params 'path))
              (expanded (expand-file-name path (plist-get session :cwd))))
         (if (file-readable-p expanded)
             (acp-send-response
              :client client
              :response (acp-make-fs-read-text-file-response
                         :request-id req-id
                         :content (with-temp-buffer
                                    (insert-file-contents expanded)
                                    (buffer-string))))
           (acp-send-response
            :client client
            :response (acp-make-fs-read-text-file-response
                       :request-id req-id
                       :error (acp-make-error
                               :code -32000
                               :message (format "File not readable: %s" path)))))))
      ("fs/write_text_file"
       (let* ((path (map-elt params 'path))
              (content (map-elt params 'content))
              (expanded (expand-file-name path (plist-get session :cwd))))
         (condition-case err
             (progn
               (with-temp-buffer
                 (insert content)
                 (write-region nil nil expanded nil 'silent))
               (acp-send-response
                :client client
                :response (acp-make-fs-write-text-file-response :request-id req-id)))
           (error
            (acp-send-response
             :client client
             :response (acp-make-fs-write-text-file-response
                        :request-id req-id
                        :error (acp-make-error
                                :code -32000
                                :message (format "Write failed: %S" err))))))))
      ("session/request_permission"
       (let ((previous
              ;; copy: plist-put mutates the status list in place
              (copy-sequence (buffer-local-value 'agent-org-buffer--status buffer)))
             (opts (map-elt params 'options)))
         (agent-org-buffer-set-status buffer :state 'awaiting :message "Permission required")
         (unwind-protect
             (condition-case nil
                 (let ((option-id (agent-org--prompt-permission opts)))
                   (acp-send-response
                    :client client
                    :response
                    (if option-id
                        (acp-make-session-request-permission-response
                         :request-id req-id :option-id option-id)
                      (acp-make-session-request-permission-response
                       :request-id req-id :cancelled t))))
               (quit
                (acp-send-response
                 :client client
                 :response (acp-make-session-request-permission-response
                            :request-id req-id :cancelled t))))
           (apply #'agent-org-buffer-set-status buffer previous))))
      (_
       (agent-org-buffer-set-status
        buffer :message (format "Unhandled request: %s" method))))))

(defun agent-org--prompt-permission (options)
  "Prompt the user over ACP permission OPTIONS; return the chosen optionId.

OPTIONS are PermissionOption objects -- alists keyed `optionId', `name'
and `kind' (see
https://agentclientprotocol.com/protocol/schema#permissionoption).  The
candidate is the option's `name', or its `optionId' when the agent sent
no name, so every candidate is at least a string a person can read.

Answer is nil when the user declines: picks the Cancel entry, or quits
with ESC (the caller traps that).  Reading `label' and `id' instead of
the keys above is what made this dialog offer one `nil' candidate."
  (let* ((candidates
          (seq-map (lambda (o)
                     (cons (or (map-elt o 'name)
                               (map-elt o 'optionId)
                               "?")
                           (map-elt o 'optionId)))
                   options))
         (choice (completing-read "Allow? "
                                  (append (seq-map #'car candidates)
                                          '("Cancel"))
                                  nil t)))
    ;; plain strings on both sides, so `assoc' is safe here: no candidate
    ;; carries text properties for this prompt.
    (cdr (assoc choice candidates))))

;;;; Content blocks

(defun agent-org--make-content-blocks (text)
  "Convert TEXT (a plain string) into a list of ACP ContentBlock alists.
Currently supports plain text blocks only."
  (list `((type . "text")
          (text . ,text))))

(defcustom agent-org-send-session-context t
  "Whether each prompt tells the agent which model, session and agent it is.
An agent asked \"which model are you?\" answers from its own idea of the
default, which is wrong the moment this client has selected another model
through `session/set_config_option' — exactly how MiniMax runs over
OpenCode.  The session id and the harness name have the same problem: all
three are the client's to know, and a commit trailer, a bug report or a
config request needs them.
With nil, agent-org sends only what you typed."
  :type 'boolean
  :group 'agent-org)

(defun agent-org--context-field (value)
  "Flatten VALUE to one line, without cutting it short.
A model's label comes out of the agent's own `configOptions' and a
provider's name out of its spec, so the standing rule applies: never trust
a harness label to be short or single-line (AGENTS.md).  The whitespace
collapse is `agent-org-buffer--label''s, MINUS its truncation — this string
goes on the wire and is never displayed, and half a model name is the lie
the block exists to prevent.  Returns nil for nothing to say, so an unknown
fact is absent rather than `nil'."
  (when-let* ((text (and value (format "%s" value)))
             (flat (mapconcat #'identity
                              (split-string text "[ \t\n\r]+" t)
                              " ")))
    (and (not (string-empty-p flat)) flat)))

(defun agent-org--context-line (label id &optional name)
  "One \"label: NAME (ID)\" fact, or \"label: ID\" when nothing names it.
Both spellings go because they answer different questions — NAME is what a
person and an agent read (\"MiniMax M3\"), ID is what a request or a trailer
needs (\"minimax/MiniMax-M3\") — and neither derives from the other.  An
unnamed or already-named-by-its-id value writes the value once, so no line
reads `model: QModel (QModel)'."
  (let* ((id (agent-org--context-field id))
         (flat (or (agent-org--context-field name) id)))
    (when flat
      (format "%s: %s%s" label flat
              (if (and id (not (string= flat id)))
                  (format " (%s)" id)
                "")))))

(defun agent-org--context-facts (session buffer)
  "The fact lines the agent is told about SESSION, as a list.
Order is fixed — agent, model, session — because the block is something a
person quotes at an agent and a test pins.  A fact the client does not know
is ABSENT, never `nil' or \"unknown\": goose advertises no model option of
this shape, and a `model: nil' line would be an agent told something false.
The model lives on BUFFER's status (it is what the header line renders, and
the only place the label and the id are stored together by
`agent-org--ingest-config'); the agent id and the session id live on
SESSION, because they identify the connection rather than this buffer."
  (let ((status (buffer-local-value 'agent-org-buffer--status buffer)))
    (seq-remove #'null
                (list (agent-org--context-line "agent"
                                               (plist-get session :name)
                                               (plist-get status :provider))
                      (agent-org--context-line "model"
                                               (plist-get status :model)
                                               (plist-get status :model-name))
                      (agent-org--context-line "session"
                                               (plist-get session
                                                          :session-id))))))

(defun agent-org--session-context-text (session buffer)
  "The <agent-org-context> block for one turn of SESSION, as a string.
Built PER TURN, because the middle fact changes mid-session: `C-c C-m'
between two questions is a normal thing to do, and a block computed at
session start would tell the agent a model that stopped being true turn one
ago — worse than saying nothing.
The delimiters are the point: they mark the text as the client talking about
the connection, not the person asking for something, so an agent never
quotes the block as the request or treats it as an instruction to act on."
  (let ((facts (agent-org--context-facts session buffer)))
    (concat "<agent-org-context>\n"
            "Client metadata about this connection,"
            " not part of the user's request.\n"
            (mapconcat #'identity facts "\n")
            ;; no blank line when a host gives no facts at all: a gap inside
            ;; a fixed-format block reads as a field that failed to print
            (and facts "\n")
            "</agent-org-context>\n")))

(defun agent-org--prompt-blocks (session buffer text)
  "The content blocks for TEXT: the user's words, then the client's facts.
The user's block is EXACTLY what was typed — `agent-org--make-content-blocks'
is unchanged, because this is the one place the client adds to the wire, and
it adds beside the request rather than inside it.  Appending LAST also keeps
every reader of \"the first block\" honest, on our side and the agent's: the
question stays the thing that leads.
`agent-org-send-session-context' nil leaves just that one block."
  (append (agent-org--make-content-blocks text)
          (when agent-org-send-session-context
            (list `((type . "text")
                    (text . ,(agent-org--session-context-text session
                                                             buffer)))))))

;;;; Usage accounting

(defun agent-org--record-usage (buffer resp)
  "Fold token/cost data from PromptResponse RESP into BUFFER's status.
RESP may be nil or lack either field (providers are not required to
report usage); anything missing is simply left untouched."
  (when-let* ((usage (and resp (map-elt resp 'usage)))
              (total (or (map-elt usage 'totalTokens)
                         (and-let* (((map-elt usage 'inputTokens)))
                           (+ (map-elt usage 'inputTokens)
                              (or (map-elt usage 'outputTokens) 0))))))
    (let ((previous (plist-get (buffer-local-value 'agent-org-buffer--status buffer)
                               :tokens)))
      (agent-org-buffer-set-status buffer :tokens (+ total (or previous 0)))))
  (when-let* ((cost (and resp (map-elt resp 'cost)))
              (amount (map-elt cost 'amount)))
    (agent-org-buffer-set-status buffer
      :cost-amount (float amount)
      :cost-currency (or (map-elt cost 'currency) "USD"))))

;;;; Sending

(defcustom agent-org-queue-when-busy t
  "Whether `agent-org-send' queues a prompt while the agent is streaming.
With nil, a mid-turn send errors \"Agent is still responding\" and the
typed text stays at the prompt.  The port of agent-shell's prompt queue
(`agent-shell-prompt-queue.el'): queued prompts go out FIFO as each turn
ENDS SUCCESSFULLY; a failed turn leaves the queue intact."
  :type 'boolean
  :group 'agent-org)

(defun agent-org--queue-message (base session)
  "Status text BASE with SESSION's pending count appended when nonzero.
Any previous \" (N queued)\" tail is stripped before recomputing, so
repeated enqueue/remove passes cannot stack suffixes on one message."
  (let ((base (replace-regexp-in-string " ([0-9]+ queued)\\'" "" base))
        (depth (length (plist-get session :pending-prompts))))
    (if (> depth 0)
        (format "%s (%d queued)" base depth)
      base)))

(defun agent-org--queue-refresh (session buffer)
  "Re-render BUFFER for SESSION's queue: its header count and its file.
Only a busy header carries the count: once the state is ready the
message is someone else's business again.

The prompts themselves go one per line into the =:QUEUE:= drawer of the
metadata block, which is the part of the buffer the transcript mirrors,
and the mirror is written HERE rather than left for a turn boundary.  A
queued prompt that never reaches a boundary — the user quits Emacs, the
agent dies, the machine loses power — is precisely the text they would
most want back, and no other writer has ever seen it."
  (agent-org-buffer-set-status
   buffer :queued (plist-get session :pending-prompts))
  (agent-org-buffer-refresh-metadata buffer)
  (agent-org-buffer-transcribe buffer)
  (let ((status (buffer-local-value 'agent-org-buffer--status buffer)))
    (when (memq (plist-get status :state) '(streaming loading))
      (agent-org-buffer-set-status
       buffer :message
       (agent-org--queue-message (or (plist-get status :message)
                                     "Streaming")
                                 session)))))

(defun agent-org--queue-enqueue (session buffer text)
  "Append TEXT to SESSION's pending queue and show the depth in BUFFER.
The editor, if one is open, is told too: it cannot see this prompt, and an
editor that overwrites the session's queue with its own contents would
silently drop it (see `agent-org-queue--note-added')."
  (setf (plist-get session :pending-prompts)
        (append (plist-get session :pending-prompts) (list text)))
  (agent-org--queue-refresh session buffer)
  (agent-org-queue--note-added buffer text)
  (message "[agent-org] queued prompt (%d waiting)"
           (length (plist-get session :pending-prompts))))

(defun agent-org--drain-queue (session buffer)
  "Send SESSION's next queued prompt into BUFFER, or open a live prompt.
Reached only from a successful turn end: `agent-org--send-turn''s
failure callback never drains, so a broken agent is not hammered and the
queue survives for the user to inspect.  A drained prompt opens its own
exchange above the live type-ahead box first
(`agent-org-buffer-begin-exchange'), exactly like a typed one; the box and
whatever draft it holds stay untouched."
  (let ((prompts (plist-get session :pending-prompts)))
    (if (null prompts)
        (agent-org-buffer-insert-prompt buffer)
      (setf (plist-get session :pending-prompts) (cdr prompts))
      (agent-org-buffer-begin-exchange buffer (car prompts))
      ;; Refresh AFTER the heading is in the buffer: the one write that
      ;; drops the prompt from the `:QUEUE:' drawer is then also the write
      ;; that puts it in the conversation, so no mirror on disk is ever
      ;; without it.  Getting this backwards makes a crash between the two
      ;; lose a prompt the user already paid for.
      (agent-org--queue-refresh session buffer)
      ;; The editor is told the SAME text the agent took, and not by
      ;; position: an entry it moved is still the same prompt.
      (agent-org-queue--note-sent buffer (car prompts))
      (agent-org--send-turn session buffer (car prompts)))))

(defun agent-org--sync-title (session)
  "Ask `session/list' once for SESSION's title and apply it if found.

Some harnesses (qoder, live-verified) never push `session_info_update',
so the title the agent has chosen for the conversation only exists in the
directory listing.  Reading it once, after the first turn has run, is
what makes =#+TITLE:= stop showing the bare provider name forever.

The whole thing is one-shot per session: `:title-seeked' is set before
the request goes out, so a late or empty answer cannot trigger a second
page, and a title that arrives by any other route (a `session/new' that
carries one, a pushed update) is left untouched.  Gated on
`:lists-sessions' because an agent that does not advertise the capability
would be handed a request it never answers (Goose).  :quiet so a lookup
the user never asked for does not overwrite the echo area, and every
failure is silent: =#+TITLE:= simply keeps the fallback it already had."
  (let ((buffer (plist-get session :buffer))
        (sid (plist-get session :session-id)))
    (when (and (not (plist-get session :title-seeked))
               (plist-get session :lists-sessions)
               sid
               (not (plist-get (buffer-local-value 'agent-org-buffer--status buffer)
                               :title)))
      (setf (plist-get session :title-seeked) t)
      (agent-org--list-sessions
       session
       :quiet t
       :on-success (lambda (list-resp)
                     (when-let* ((row (seq-find (lambda (s)
                                                  (equal (map-elt s 'sessionId) sid))
                                                (agent-org--wire-list
                                                 (map-elt list-resp 'sessions))))
                                (title (map-elt row 'title))
                                ((not (string-empty-p title))))
                       ;; the buffer KEEPS its name (the name is the agent,
                       ;; not this title); the metadata pass is what puts
                       ;; the title in `#+TITLE:'
                       (agent-org-buffer-set-status buffer :title title)
                       (agent-org-buffer-refresh-metadata buffer)
                       ;; and the file catches up with it now, not at the
                       ;; next turn — a chat the user closes after one
                       ;; answer should not be filed under the fallback
                       (agent-org-buffer-transcribe buffer)))
       :on-failure (lambda (_err _msg) nil)))))

(defun agent-org--send-turn (session buffer text)
  "Put TEXT on the wire as the current turn of SESSION.
The exchange heading TEXT is written in BUFFER above the live type-ahead box
before this runs (by `agent-org-send' directly, or by
`agent-org--drain-queue' for a queued prompt); this only does the busy
bookkeeping and installs the two
callbacks.  Success ends the turn, accounts usage and drains the queue
(`agent-org--drain-queue'); failure leaves the queue where it is.

Each turn carries an id in SESSION's `:turn'.  `agent-org-cancel-turn'
retires it locally, and the agent's own (cancelled) answer to the
request then arrives against a turn id nobody holds — both callbacks
drop it rather than closing the turn a second time, draining the queue
twice, or overwriting the buffer's post-cancel state.

This function deliberately never moves point: the render primitives
append at `agent-org-buffer--render-end' themselves, and point must stay
in the user's type-ahead box across the turn boundary."
  (let* ((client (plist-get session :client))
         (sid (plist-get session :session-id))
         (turn (progn
                 (setf (plist-get session :turn)
                       (1+ (or (plist-get session :turn) 0)))
                 (plist-get session :turn))))
    (setf (plist-get session :streaming) t)
    (agent-org-buffer-set-status buffer :state 'streaming
      :message (agent-org--queue-message "Sending…" session))
    ;; the turn's first boundary: the prompt the user just sent is frozen
    ;; in the buffer, and a session that dies mid-answer should still have
    ;; the question on disk
    (agent-org-buffer-transcribe buffer)
    (acp-send-request
     :client client
     :request (acp-make-session-prompt-request
               :session-id sid
               :prompt (agent-org--prompt-blocks session buffer text))
     :buffer buffer
     :on-success (lambda (resp)
                   (when (eq (plist-get session :turn) turn)
                     (setf (plist-get session :turn) nil)
                     (setf (plist-get session :streaming) nil)
                     (agent-org-buffer-end-agent-turn buffer)
                     (agent-org--record-usage buffer resp)
                     (agent-org-buffer-set-status buffer :state 'ready)
                     (agent-org--drain-queue session buffer)
                     (agent-org-buffer-refresh-metadata buffer)
                     ;; the turn's second and last boundary: the answer,
                     ;; its tool drawer and its thought are all frozen
                     ;; into the buffer by now, so one mirror call puts
                     ;; the whole turn on disk
                     (agent-org-buffer-transcribe buffer)
                     ;; first turn done: the conversation now has a
                     ;; title worth reading, for agents that only
                     ;; reveal it through session/list
                     (agent-org--sync-title session)))
     :on-failure (lambda (_err msg)
                   (when (eq (plist-get session :turn) turn)
                     (setf (plist-get session :turn) nil)
                     (setf (plist-get session :streaming) nil)
                     (agent-org-buffer-end-agent-turn buffer)
                     (agent-org-buffer-set-status
                      buffer :state 'error
                      :message (format "prompt failed: %s"
                                       (agent-org--failure-text msg)))
                     (agent-org-buffer-insert-prompt buffer)
                     (agent-org-buffer-transcribe buffer))))))

;;;###autoload
(defun agent-org-send ()
  "Send what is typed in the live `* User' box to the agent.
Idle, the draft becomes a frozen User heading above the box and goes on
the wire; the box stays open, so the next prompt can be typed right away.
While a turn streams the same act merely queues the draft -- see
`agent-org-queue-when-busy' -- and it goes out, FIFO, when the running
turn ends successfully.  This type-ahead model is agent-shell's: the
prompt is always in the buffer, never in the minibuffer, so watching a
turn and preparing the next message happen in the same window."
  (interactive)
  (let* ((buffer (current-buffer))
         (session (agent-org--session-for-buffer buffer)))
    (unless session
      (user-error "Not an agent-org chat buffer"))
    (if (plist-get session :streaming)
        (progn
          (unless agent-org-queue-when-busy
            (user-error "Agent is still responding"))
          (agent-org--queue-enqueue session buffer
            (agent-org-buffer-take-draft buffer)))
      ;; a replayed session_info_update already fills :session-id, so the
      ;; check below cannot cover an in-flight load
      (when (plist-get session :loading)
        (user-error "Session history is still loading"))
      (unless (plist-get session :session-id)
        (user-error "Session not ready"))
      ;; take-draft first: a user-error from an empty box leaves the
      ;; buffer untouched, and the checks above ran before anything moved
      (let ((text (agent-org-buffer-take-draft buffer)))
        (agent-org-buffer-begin-exchange buffer text)
        (agent-org--send-turn session buffer text)))))

;;;; Queue editor: show, edit and re-order the waiting prompts
;;
;; One buffer, one action.  The first cut had three commands for the queue
;; — `agent-org-queue-view' printed a read-only list in a hidden buffer,
;; `agent-org-queue-remove' picked a number in the minibuffer, and
;; `agent-org-queue-edit' re-read the LAST entry only.  All three are the
;; same list seen three ways, and none of them could re-order it, which is
;; the one thing a queue of prompts needs: type the follow-up first, then
;; the question it answers.  The editor replaces them, and shows the queue
;; in the chat buffer itself (the `:QUEUE:' drawer) as well as in here.

(defvar agent-org-queue--editor nil
  "Buffer-local in a CHAT buffer: its live queue editor, or nil.
The link runs chat -> editor because the two things that change the queue
WITHOUT the user working in the editor — `agent-org--drain-queue' taking a
prompt off the front, `agent-org--queue-enqueue' adding one to the back —
both have the CHAT buffer in hand and must be able to find the editor to
tell it what happened.  The reverse pointer is
`agent-org-queue--chat'.
No `kill-buffer-hook' unsets this: `agent-org-queue--editor-for' checks
`buffer-live-p', so a killed editor stops answering on its own.")

(defvar agent-org-queue--chat nil
  "Buffer-local in a queue EDITOR: the chat buffer it belongs to, or nil.")

(defvar agent-org-queue--sent nil
  "Buffer-local in a queue editor: prompts the agent sent while it was open.
Newest first (`push' order); `agent-org-queue-apply' reads it reversed.
Recorded rather than applied, because the editor is a snapshot and the
session is the record: dropping the entry by POSITION would resend a prompt
the agent already answered — the drain takes the front of the SESSION's
list, and the user may have moved that entry anywhere in this buffer.")

(defvar agent-org-queue--added nil
  "Buffer-local in a queue editor: prompts queued while it was open.
Newest first, for the same reason as `agent-org-queue--sent'.  These go
BACK at the end on apply, in arrival order: the editor never showed them,
so it must not be allowed to overwrite them away.")

(defconst agent-org-queue--headline-re "^\\* [0-9]+[ \t]*$"
  "One queue entry's headline: a number and nothing else.
The number is the send order, printed by `agent-org-queue--renumber'.  An
entry's TEXT always starts on the line below, indented one space
(`agent-org-queue--indent'), so a prompt that begins with `*' cannot be
read as a headline here, and a headline this pattern does not match — the
preamble, or a `* note' a user typed — is not an entry and cannot be sent
by accident.")

(defun agent-org-queue--entry-positions ()
  "Buffer positions starting each entry headline in this buffer, top to bottom.
`match-beginning', never what `re-search-forward' returns: that is the
match's END, one line into the entry's body."
  (save-excursion
    (goto-char (point-min))
    (let (spots)
      (while (re-search-forward agent-org-queue--headline-re nil t)
        (push (match-beginning 0) spots))
      (nreverse spots))))

(defun agent-org-queue--entry-bounds ()
  "Start and end of the entry containing point, as a cons.
The end is the next headline, or `point-max' for the last entry.
`user-error' in the preamble above the entries: there is no entry there to
act on, and moving or killing from it would silently take the first one."
  (let* ((line-start (save-excursion (beginning-of-line) (point)))
         (spots (agent-org-queue--entry-positions))
         (here (car (last (seq-take-while (lambda (s) (<= s line-start))
                                          spots)))))
    (unless here (user-error "Not on a queue entry"))
    (cons here (or (seq-find (lambda (s) (> s here)) spots) (point-max)))))

(defun agent-org-queue--indent (text)
  "TEXT with ONE space in front of every non-blank line, no trailing newline.
A prompt is the user's own words, and those words can be an Org document:
a `*' at column 0 is a headline and would cut this buffer into two entries,
sending half of one prompt as another.  One space is all a headline needs
to stop being one (info \"(org) Headlines\"), and
`agent-org-queue--dedent' removes exactly that much, so an entry reads back
byte for byte — blank lines included, which is why the split keeps the
empty strings."
  (mapconcat (lambda (line)
               (if (string-empty-p line) line (concat " " line)))
             (split-string text "\n")
             "\n"))

(defun agent-org-queue--dedent (line)
  "LINE with the renderer's one leading space removed, if it has one.
Text typed straight into an entry — a new one, an appended word — never got
that space, so this is a no-op for it rather than a truncation."
  (if (string-prefix-p " " line) (substring line 1) line))

(defun agent-org-queue--entry-text (beg end)
  "The prompt stored between BEG (the headline's end) and END.
Inverse of `agent-org-queue--indent'.  The whole entry is trimmed at the
outside, so an entry the user left blank reads as blank and
`agent-org-queue--parse' can drop it; a prompt's internal blank lines and
indentation are kept exactly."
  (string-trim
   (mapconcat #'agent-org-queue--dedent
              (split-string (buffer-substring-no-properties beg end) "\n")
              "\n")))

(defun agent-org-queue--parse ()
  "The entries in this buffer, as a list of prompts, top to bottom.
An entry is everything from its headline to the next one, so a multi-line
prompt stays ONE prompt.  An entry whose text is blank is dropped:
`agent-org-send' refuses an empty draft, and the queue must not be able to
smuggle one through by leaving a headline bare."
  (save-excursion
    (let* ((spots (agent-org-queue--entry-positions))
           (ends (append (cdr spots) (list (point-max)))))
      (delq nil
            (cl-loop for spot in spots
                     for end in ends
                     for text = (agent-org-queue--entry-text
                                 (save-excursion (goto-char spot)
                                                 (line-end-position))
                                 end)
                     unless (string-blank-p text)
                     collect text)))))

(defun agent-org-queue--drop-sent (entries sent)
  "ENTRIES with one occurrence removed for each text in SENT.
Matched by TEXT, and only the first occurrence of each: two entries with
the same words are two prompts, and the agent taking one leaves the other
waiting.  Position would be easier and would be wrong — see
`agent-org-queue--sent'."
  (let ((out (copy-sequence entries)))
    (dolist (text sent out)
      (let ((at (seq-position out text #'equal)))
        (when at (setq out (seq-remove-at-position out at)))))))

(defun agent-org-queue--header ()
  "The editor's preamble: what this buffer is and how to work it.
No headline and no drawer, because a line matching
`agent-org-queue--headline-re' WOULD be an entry: the preamble is the only
text in here that is not a prompt, and it must never look like one."
  (let* ((chat (and (buffer-live-p agent-org-queue--chat) agent-org-queue--chat))
         (status (and chat (buffer-local-value 'agent-org-buffer--status chat)))
         (label (if status (agent-org-buffer--chat-label status) "agent-org")))
    (format (concat "#+TITLE: Prompt queue — %s\n\n"
                    "Sent in this order — entry 1 goes out when the current turn ends.\n"
                    "C-c C-c apply, C-c C-k abandon, C-c C-a new entry, C-c C-d kill entry.\n"
                    "M-UP / M-DOWN move the entry at point.\n\n")
            label)))

(defun agent-org-queue--repaint (prompts)
  "Draw PROMPTS as this buffer's entries, replacing everything.
An empty PROMPTS still gets one bare entry: this buffer is also the place
to compose the next prompt, and an entry with no text is dropped on apply,
so leaving it untouched cannot send anything.
Point's LINE survives, because applying is a save in the middle of work —
a cursor thrown to the top of the buffer is a cursor in the wrong entry.
`buffer-undo-list' is bound only here: undoing across a save would let `C-/'
put back entries the session's queue has already forgotten, which is a
buffer that lies."
  (let ((line (line-number-at-pos))
        (column (current-column))
        (buffer-undo-list t)
        (inhibit-read-only t))
    (erase-buffer)
    (insert (agent-org-queue--header))
    (cl-loop for text in (or prompts (list "")) for i from 1
             do (insert (format "* %d\n%s\n" i (agent-org-queue--indent text))))
    (goto-char (point-min))
    (forward-line (max 0 (1- line)))
    (move-to-column column)))

(defun agent-org-queue--renumber ()
  "Rewrite every entry headline to its position in the buffer.
The printed number is the send order, so after a move, an insert or a kill
it has to be recomputed — an entry numbered 3 that now sits first would
otherwise promise a place it no longer has."
  (save-excursion
    (let ((i 0))
      (goto-char (point-min))
      (while (re-search-forward agent-org-queue--headline-re nil t)
        (cl-incf i)
        (let ((head (match-beginning 0)))
          (delete-region head (line-end-position))
          (goto-char head)
          (insert (format "* %d" i)))))))

(defun agent-org-queue--buffer-name (chat)
  "The editor's buffer name for CHAT: one per session.
The chat label is the same `<agent>:<project>' the chat buffer wears, so
`C-x b' shows the pair together instead of two unrelated names."
  (format "*agent-org queue: %s*"
          (let ((status (buffer-local-value 'agent-org-buffer--status chat)))
            (if status (agent-org-buffer--chat-label status) "agent-org"))))

(defun agent-org-queue--editor-for (buffer)
  "BUFFER's live queue editor, or nil.
The liveness check IS the cleanup: a killed editor leaves a dead reference
in the chat buffer, and answering nil for it means the next
`agent-org-queue-edit' builds a fresh one rather than switching to a
buffer that no longer exists."
  (let ((buf (buffer-local-value 'agent-org-queue--editor buffer)))
    (and (buffer-live-p buf) buf)))

(defun agent-org-queue--note-sent (buffer text)
  "Tell BUFFER's editor, if one is open, that TEXT has gone out.
Called from the drain, which runs on a turn boundary and so can land in
the middle of an edit."
  (let ((editor (agent-org-queue--editor-for buffer)))
    (when editor
      (with-current-buffer editor
        (push text agent-org-queue--sent)))))

(defun agent-org-queue--note-added (buffer text)
  "Tell BUFFER's editor, if one is open, that TEXT was queued behind it.
The mirror of `agent-org-queue--note-sent': the prompt arrived while the
editor was open, so the editor cannot have shown it, and must not be able
to remove it by being the last writer."
  (let ((editor (agent-org-queue--editor-for buffer)))
    (when editor
      (with-current-buffer editor
        (push text agent-org-queue--added)))))

(defun agent-org-queue--check-editor ()
  "Fail unless this is a queue editor buffer.
Every command here works on entries, and a stray `C-c C-c' in an ordinary
Org file must say so rather than reach some session's queue."
  (unless (derived-mode-p 'agent-org-queue-mode)
    (user-error "Not an agent-org queue buffer")))

(defun agent-org-queue--chat-or-error ()
  "The chat buffer this editor belongs to, or a clean failure.
An error and not a silent nil: applying to a session that has gone would
report success while changing nothing."
  (let ((chat (and (buffer-live-p agent-org-queue--chat) agent-org-queue--chat)))
    (or chat (user-error "That session's chat buffer is gone"))))

(define-derived-mode agent-org-queue-mode org-mode "AO-Queue"
  "Major mode for editing one session's queued prompts.
An entry is a prompt: its headline is its place in the send order and the
indented lines under it are its text.  `C-c C-c' makes the entries the
session's queue; nothing else in this buffer can reach the agent, so
editing is safe until then.
Keys:
  C-c C-c  Apply — the entries become the session's queue
  C-c C-k  Abandon — close without writing anything
  C-c C-a  New empty entry at the end, ready to type
  C-c C-d  Kill the entry at point (it goes to the kill ring)
  M-UP     Move the entry at point one place nearer the front
  M-DOWN   Move it one place further back"
  :group 'agent-org
  ;; The entries are the whole document and there are never many of them,
  ;; so nothing here should be hidden: an entry the user cannot see is an
  ;; entry they cannot reorder.  Wrapping is what delivers that — and it is
  ;; `org-startup-truncated' that decides it, because `org-mode' applies its
  ;; own startup visibility AFTER a derived mode's body has run (measured
  ;; live: a `(setq-local truncate-lines t)' here was still nil by the time
  ;; the buffer was displayed).
  (setq-local org-startup-folded nil)
  (setq-local org-startup-truncated nil))

;; `define-derived-mode' gives this mode a sparse keymap and does NOT parent
;; it on `org-mode-map' (measured: `keymap-parent' answers nil), so the
;; subtree commands Org's own moves are reached through, and every other Org
;; binding, come from this line.  The keys are set here rather than in a
;; `defvar' because `define-derived-mode' defines the variable itself, and a
;; second `defvar' for it would be ignored — the mode's map object is the one
;; buffer-local value, so mutating it is the only way in.
(set-keymap-parent agent-org-queue-mode-map org-mode-map)
(define-key agent-org-queue-mode-map (kbd "C-c C-c") #'agent-org-queue-apply)
(define-key agent-org-queue-mode-map (kbd "C-c C-k") #'agent-org-queue-cancel)
(define-key agent-org-queue-mode-map (kbd "C-c C-a") #'agent-org-queue-insert-entry)
(define-key agent-org-queue-mode-map (kbd "C-c C-d") #'agent-org-queue-kill-entry)
(define-key agent-org-queue-mode-map [M-up] #'agent-org-queue-move-up)
(define-key agent-org-queue-mode-map [M-down] #'agent-org-queue-move-down)

;;;###autoload
(defun agent-org-queue-edit ()
  "Edit the prompts waiting for this session, and put them in new order.
Entry 1 is the prompt that goes out when the current turn ends.  The list
is editable as Org text: `M-UP'/`M-DOWN' move an entry, `C-c C-d' kills
one, `C-c C-a' adds one, `C-c C-c' applies the result and `C-c C-k'
abandons the whole edit.  Applying writes ONE thing — the session's
`:pending-prompts' — and the header count, the chat buffer's `:QUEUE:'
drawer and the transcript file all read that, so they cannot disagree.

A SEPARATE buffer rather than editing the chat's own `:QUEUE:' drawer in
place, because that drawer is part of the metadata block and the block is
deleted and reinserted on every usage update: a cursor and a half-typed
word in it would be destroyed mid-turn.  The drawer is for reading, this is
for working.

Called twice, this switches to the editor that is already open rather than
redrawing it: a refresh would silently drop the edits that were never
applied.  An empty queue is not an error either — the editor opens with one
blank entry, which is also how to compose a prompt to send later."
  (interactive)
  (let* ((chat (current-buffer))
         (session (agent-org--session-for-buffer chat)))
    (unless session
      (user-error "Not an agent-org chat buffer"))
    (let ((existing (agent-org-queue--editor-for chat)))
      (if existing
          (progn
            (pop-to-buffer existing)
            (message "[agent-org] queue editor already open (C-c C-c applies, C-c C-k abandons)"))
        (agent-org-queue--open chat (plist-get session :pending-prompts))))))

(defun agent-org-queue--open (chat prompts)
  "Create CHAT's queue editor showing PROMPTS, and display it.
The mode and the paint run with the buffer current BEFORE it is shown:
`agent-org-queue-mode' is `org-mode', whose startup wants to set buffer
locals, and a buffer displayed by `pop-to-buffer' is not necessarily
current — the same trap that cost a chat its colors (see
`agent-org-buffer--ensure-font-lock').  Displaying it afterwards is the
part that needs a window, so the order is mode, paint, show."
  (let ((buf (generate-new-buffer (agent-org-queue--buffer-name chat))))
    (with-current-buffer buf
      (agent-org-queue-mode)
      (setq-local agent-org-queue--chat chat
                  agent-org-queue--sent nil
                  agent-org-queue--added nil)
      (agent-org-queue--repaint prompts))
    (with-current-buffer chat
      (setq-local agent-org-queue--editor buf))
    (pop-to-buffer buf)
    (with-current-buffer buf
      ;; Now that a window shows it: batch Emacs cannot enable font-lock in
      ;; any buffer, hidden or not, so this is for the live session only and
      ;; no test can see it happen.
      (unless font-lock-mode
        (font-lock-mode 1)))
    buf))

;;;###autoload
(defun agent-org-queue-resume ()
  "Send the next prompt waiting in this session's queue, now.
Port of `agent-shell-prompt-queue-resume' (agent-shell-prompt-queue.el:370),
and the escape hatch for the state `agent-org-cancel-turn' leaves behind: the
turn is gone and the prompts that were queued behind it are still waiting.

ONE prompt per call, because that is what a turn end does too
(`agent-org--drain-queue') -- and once this one is answered, the rest follow
FIFO on their own.  While a turn runs nothing goes out: the agent is busy and
the queue already drains when it finishes, so agent-shell's own answer is a
message rather than an error, and this copies it.  An empty queue is an error,
though: the person calling this believes there is a prompt in it."
  (interactive)
  (let* ((buffer (current-buffer))
         (session (agent-org--session-for-buffer buffer)))
    (unless session
      (user-error "Not an agent-org chat buffer"))
    (unless (plist-get session :pending-prompts)
      (user-error "No pending prompts"))
    (if (plist-get session :streaming)
        (message "[agent-org] agent is busy — the queue goes out when this turn ends")
      (agent-org--drain-queue session buffer))))

;;;###autoload
(defun agent-org-queue-apply ()
  "Make this buffer's entries the session's queue, everywhere at once.
Reconciliation, in this order: entries the agent sent while the editor was
open are removed BY TEXT (`agent-org-queue--drop-sent'), then prompts that
arrived while the editor was open go back on the end, in arrival order.
So the editor is never the sole writer of a list it has not seen — and an
entry the user edited after it went out is the one case that does get sent
again, because the agent never saw those words.
The buffer stays open and is repainted from the result, which is what makes
an apply a save rather than a close: keep editing, apply again."
  (interactive)
  (agent-org-queue--check-editor)
  (let* ((chat (agent-org-queue--chat-or-error))
         (session (agent-org--session-for-buffer chat)))
    (unless session
      (user-error "That session is gone"))
    (let ((result (append (agent-org-queue--drop-sent
                           (agent-org-queue--parse)
                           (reverse agent-org-queue--sent))
                          (reverse agent-org-queue--added))))
      (setq agent-org-queue--sent nil
            agent-org-queue--added nil)
      (setf (plist-get session :pending-prompts) result)
      (agent-org--queue-refresh session chat)
      (agent-org-queue--repaint result)
      (message "[agent-org] queue applied: %d waiting" (length result)))))

;;;###autoload
(defun agent-org-queue-cancel ()
  "Abandon this editor: the session's queue never saw a byte of the edit.
That is the whole contract, and the reason apply is the only writer.  The
chat is shown before the kill so no window is left pointing at a buffer
that just went away."
  (interactive)
  (agent-org-queue--check-editor)
  (let ((chat (agent-org-queue--chat-or-error))
        (old (current-buffer)))
    (switch-to-buffer chat)
    (kill-buffer old)
    (message "[agent-org] queue edits abandoned")))

(defun agent-org-queue--to-headline ()
  "Put point on the headline of the entry under point.
These commands take an ENTRY as their object, so a cursor in the middle of
a prompt's third line still means \"this prompt\" — and Org's own subtree
moves insist on starting from a heading."
  (goto-char (car (agent-org-queue--entry-bounds))))

;;;###autoload
(defun agent-org-queue-move-up ()
  "Move the entry at point one place nearer the front of the queue.
Org's own subtree move, so the text travels with its headline.  At entry 1
Org refuses and nothing moves — which is the right answer, since nothing is
already in front of it."
  (interactive)
  (agent-org-queue--check-editor)
  (agent-org-queue--to-headline)
  (org-move-subtree-up)
  (agent-org-queue--renumber))

;;;###autoload
(defun agent-org-queue-move-down ()
  "Move the entry at point one place further back in the queue."
  (interactive)
  (agent-org-queue--check-editor)
  (agent-org-queue--to-headline)
  (org-move-subtree-down)
  (agent-org-queue--renumber))

;;;###autoload
(defun agent-org-queue-insert-entry ()
  "Append an empty entry and leave point inside it, ready to type.
AT THE END, because the queue is FIFO and a prompt typed now waits behind
the ones already waiting — the same place `agent-org--queue-enqueue' puts
a send from the type-ahead box, so the editor and the box agree.  `M-UP'
takes it anywhere else.
The number on the new headline is provisional: it is what position
`agent-org-queue--renumber' would print, and the next move or kill
recomputes every one anyway."
  (interactive)
  (agent-org-queue--check-editor)
  (goto-char (point-max))
  (unless (bolp)
    (insert "\n"))
  (insert (format "* %d\n" (1+ (length (agent-org-queue--entry-positions))))))

;;;###autoload
(defun agent-org-queue-kill-entry ()
  "Kill the entry at point, headline and body, onto the kill ring.
A KILL and not a delete, because this is the queue command with no
confirmation and dropping a prompt you meant to keep is the mistake worth
making recoverable: `C-y' puts the whole entry back.
Killing entry 1 kills the prompt that was FIRST in the list you were shown,
whatever its number says now — `agent-org-queue--renumber' follows so the
remaining numbers stay contiguous with the order they describe."
  (interactive)
  (agent-org-queue--check-editor)
  (agent-org-queue--to-headline)
  (let ((bounds (agent-org-queue--entry-bounds)))
    (kill-region (car bounds) (cdr bounds)))
  (agent-org-queue--renumber)
  (message "[agent-org] entry killed (C-y puts it back)"))

(provide 'agent-org)
;;; agent-org.el ends here
