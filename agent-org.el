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
;; run with font-lock off, restored history is buffered and painted in
;; ONE pass (see `agent-org--render-replay'), and the metadata block
;; above the conversation is only rebuilt when its rendered text
;; actually changed.

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
falls back to `new': there is nothing to choose.  A prefix argument on
`agent-org-start' forces `new' for that one call.

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

Every key is installed by `agent-org--open-session', because `setf' on
`plist-get' can only mutate a property that already exists.")

(defun agent-org--register-session (entry)
  "Add ENTRY to `agent-org--sessions'.
Installs a buffer-local hook so the entry is dropped when its buffer
is killed."
  (push entry agent-org--sessions)
  (when-let* ((buf (plist-get entry :buffer)))
    (with-current-buffer buf
      (add-hook 'kill-buffer-hook #'agent-org--forget-session nil t))))

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
  (let ((buffer (plist-get session :buffer)))
    (when (buffer-live-p buffer)
      (kill-buffer buffer))))

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
      (kill-buffer ours)))
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
  "The label CONFIG's agent gives its current model, or nil.
The wire value is an id like `minimax/MiniMax-M3', which is what must be
sent back in `session/set_config_option' but is not what a person wants
read to them in a status bar; the advertised option carries the human
label in `name'.  Nil when the current value is outside the advertised
list — an agent can report a model it does not offer a name for — and the
caller then shows the id rather than an empty field."
  (let* ((option (agent-org--model-option config))
         (current (map-elt option 'currentValue)))
    (when current
      (map-elt (seq-find (lambda (o) (equal (map-elt o 'value) current))
                         (agent-org--wire-list (map-elt option 'options)))
               'name))))

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
                          :loading nil
                          :replay nil
                          :replay-timer nil
                          :replay-session-id nil
                          :replay-response nil
                          :replay-deadline nil
                          :list-state nil
                          :list-timer nil
                          :progress nil)))
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
choose from that, or from `New session'.  A prefix argument forces `new'
for this call, skipping the listing."
  (interactive (list (agent-org--read-provider)))
  (let* ((session (agent-org--open-session (agent-org--provider-spec provider)))
         (buffer (plist-get session :buffer))
         ;; decided NOW, not in the handshake callback:
         ;; `current-prefix-arg' belongs to the command loop, and the
         ;; strategy variable is whatever the caller had bound when they
         ;; asked.  Reading the variable late made a live probe that
         ;; bound `new' around `agent-org-start' still go and list the
         ;; directory, because by then the binding was gone
         (strategy (or (and current-prefix-arg 'new)
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

(cl-defun agent-org--list-sessions (session
                                    &key cursor seen pages
                                    (page-limit agent-org-session-list-page-limit)
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
      (agent-org--progress-start session "Listing sessions"))
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
                     (agent-org--progress-step session (format "%d so far" (length all)))
                     (cond
                      ((null next)
                       (agent-org--progress-stop session)
                       (funcall on-success `((sessions . ,all))))
                      ((member next seen)
                       (agent-org--progress-stop session)
                       (funcall on-failure
                                nil '((message . "agent repeated the same session/list cursor"))))
                      ((and page-limit (>= (1+ (length seen)) page-limit))
                       (agent-org--progress-stop session)
                       (funcall on-success `((sessions . ,all))))
                      (t
                       (agent-org--list-sessions
                        session
                        :cursor next
                        :seen (cons next seen)
                        :pages all
                        :page-limit page-limit
                        :on-success on-success
                        :on-failure on-failure)))))
     :on-failure (lambda (err msg)
                   (agent-org--progress-stop session)
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

(defun agent-org--finish-replay (session)
  "Render SESSION's buffered replay and open the session for prompts.
This is the flush point `agent-org--arm-replay-render' schedules: by now
the agent has sent everything it is going to send about history, so
`:loading' can drop and the buffered updates paint in one pass."
  (agent-org--unschedule-replay session)
  (setf (plist-get session :loading) nil)
  (agent-org--render-replay session)
  (agent-org--session-ready session
    (plist-get session :replay-session-id)
    (plist-get session :replay-response)))

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
  "Freeze replayed user prompt TEXT under its own `* User' heading.
No-op when TEXT is empty.  The Agent turn before it closes first, or
the heading would land inside that response.

A replay splits one prompt across several chunks, so this is where
they become a single turn again."
  (when (and text (not (string-empty-p (string-trim text))))
    (agent-org-buffer-end-agent-turn buffer)
    (agent-org-buffer-insert-user buffer (string-trim text))))

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
        (agent-org-buffer-end-agent-turn buffer)))
    (agent-org--progress-stop session)))

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
                 (let ((choice (agent-org--prompt-permission opts)))
                   (if (equal choice "cancel")
                       (acp-send-response
                        :client client
                        :response (acp-make-session-request-permission-response
                                   :request-id req-id :cancelled t))
                     (acp-send-response
                      :client client
                      :response (acp-make-session-request-permission-response
                                 :request-id req-id
                                 :option-id (car (split-string choice))))))
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
  "Prompt the user to pick one OPTION-ID from OPTIONS (alist list).
Returns the chosen option id string, or \"cancel\"."
  (let* ((candidates
          (seq-map (lambda (o) (cons (map-elt o 'label) (map-elt o 'id)))
                   options))
         (choice (completing-read "Allow? "
                                  (append (seq-map #'car candidates)
                                          '("cancel"))
                                  nil t)))
    (if (equal choice "cancel")
        "cancel"
      (or (cdr (assoc choice candidates)) choice))))

;;;; Content blocks

(defun agent-org--make-content-blocks (text)
  "Convert TEXT (a plain string) into a list of ACP ContentBlock alists.
Currently supports plain text blocks only."
  (list `((type . "text")
          (text . ,text))))

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

;;;###autoload
(defun agent-org-send ()
  "Send the typed prompt at the end of the chat buffer to the agent."
  (interactive)
  (let* ((buffer (current-buffer))
         (session (agent-org--session-for-buffer buffer)))
    (unless session
      (user-error "Not an agent-org chat buffer"))
    (when (plist-get session :streaming)
      (user-error "Agent is still responding"))
    ;; a replayed session_info_update already fills :session-id, so the
    ;; check below cannot cover an in-flight load
    (when (plist-get session :loading)
      (user-error "Session history is still loading"))
    (unless (plist-get session :session-id)
      (user-error "Session not ready"))
    (let ((text (agent-org-buffer-read-prompt buffer)))
      (with-current-buffer buffer (goto-char (point-max)))
      (let ((client (plist-get session :client))
            (sid (plist-get session :session-id)))
        (setf (plist-get session :streaming) t)
        (agent-org-buffer-set-status buffer :state 'streaming :message "Sending…")
        (acp-send-request
         :client client
         :request (acp-make-session-prompt-request
                   :session-id sid
                   :prompt (agent-org--make-content-blocks text))
         :buffer buffer
         :on-success (lambda (resp)
                       (setf (plist-get session :streaming) nil)
                       (agent-org-buffer-end-agent-turn buffer)
                       (agent-org--record-usage buffer resp)
                       (agent-org-buffer-set-status buffer :state 'ready)
                       (agent-org-buffer-insert-prompt buffer)
                       (agent-org-buffer-refresh-metadata buffer))
         :on-failure (lambda (_err msg)
                       (setf (plist-get session :streaming) nil)
                       (agent-org-buffer-end-agent-turn buffer)
                       (agent-org-buffer-set-status
                        buffer :state 'error
                        :message (format "prompt failed: %s"
                                         (agent-org--failure-text msg)))
                       (agent-org-buffer-insert-prompt buffer)))))))

(provide 'agent-org)
;;; agent-org.el ends here
