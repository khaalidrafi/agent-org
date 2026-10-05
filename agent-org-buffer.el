;;; agent-org-buffer.el --- Org chat buffer for agent-org -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Khalid

;; Author: Khalid
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (org "9.0"))
;; Keywords: tools, agents, ai, org

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

;; Org-native chat buffer: each turn is a level-1 headline and chunks
;; stream with font-lock left on, so Org colors stay live throughout the
;; turn (only the freshly appended region is fontified, never the whole
;; buffer).  No render path switches font-lock OFF, because an OFF is
;; restorable and an ON is not in a hidden buffer; `agent-org-mode' instead
;; asks for colors once, when the buffer first appears in a window
;; (`agent-org-buffer--ensure-font-lock').
;;
;; Tool calls render as one `- KEYWORD title' line of a `:tool:' drawer
;; under the current `* Agent' heading, using the per-file keyword set
;; declared by the metadata block (`#+TODO: TODO DOING | DONE
;; CANCELLED'): pending→TODO, in_progress→DOING, completed→DONE,
;; failed→CANCELLED.  Thoughts keep the folded :thinking: drawer, drawn by
;; the same primitive; the tool drawer is created OPEN (progress is what
;; the user came to watch) and the thought drawer FOLDED.  A drawer can
;; hold no headings, which is why a call is a line and not a `**'.
;;
;; What a call PRINTED is filed in ONE further folded drawer for the turn,
;; `:tool-output:', where each call is a `- TITLE' item with its body
;; indented under it — output cannot live inside `:tool:' because Org
;; forbids a drawer inside a drawer, and one shared fold state would either
;; hide the live status lines or flood the chat with bodies (agent-shell's
;; tool bodies are collapsed by default for the same reason).  A call that
;; sent no output gets no item, and nothing is numbered: the number existed
;; only to index a per-call drawer, and a call named by its title needs no
;; index.  Every drawer body goes through
;; `agent-org-buffer--drawer-safe-lines' first: agent text routinely
;; contains `* heading' and `:END:' at column 0, and either one silently
;; destroys the drawer holding it.
;;
;; All status, progress and error feedback is shown in the buffer's
;; `header-line' (the top bar), the same way `gptel' and `agent-shell'
;; surface state.  The mode line is left untouched (no lighter).  The
;; body holds conversation (User/Agent turns, per-turn :tool: and
;; :thinking: drawers) plus one auto-managed metadata block at the very
;; top: a PROPERTIES drawer first, then the `#+TITLE:' keyword line (the
;; harness's own session title, verbatim), then the `#+TODO:' setup line
;; declaring the tool-call keyword set, then
;; COMMANDS/MODES/CONFIG drawers — drawers folded by default, and no
;; heading, since `* ' lines belong to the conversation.
;;
;; Design (agent-shell-style always-typable buffer):
;;   - No comint, no terminal, no global read-only — just Org text.
;;   - Programmatic text (headings, streamed chunks, tool calls,
;;     thoughts) is frozen with the `read-only' text property: the
;;     cursor may travel over history freely, but editing it signals
;;     `text-read-only'.
;;   - The buffer always ends in a live `* User' type-ahead box: the
;;     heading is frozen, the body below it stays typeable at all times,
;;     mid-turn included — that is where queue input is typed.  Turns
;;     render above it (see `agent-org-buffer--render-end'), so a
;;     streaming response never scribbles over a fresh draft.
;;   - Status lives in `header-line', never in the buffer body.
;;   - Font-lock stays on through streaming; only freshly appended
;;     regions are re-fontified, never the whole buffer (a bulk paint is
;;     done once per replay, by `agent-org--render-replay').
;;   - The session's Org file (see `agent-org-transcribe') is a MIRROR of
;;     this buffer's frozen body, rewritten at turn boundaries — not an
;;     append log.  One renderer, so the file can never disagree with the
;;     chat: a tool line that changed TODO→DONE in place is DONE in the
;;     file, and twenty chunks of an answer cost no writes at all.
;;   - A reply arrives in Markdown and is stored as Org
;;     (`agent-org-convert-markdown'): `# Title' would be an Org comment
;;     and `* item' a level-1 headline, so structure is rewritten on the
;;     way in — headings shifted one level down, star bullets to dashes,
;;     fences to `#+begin_src' — and the last, still-arriving line is
;;     rewritten by the next chunk rather than held back, so a one-line
;;     answer appears as it is typed.  The agent still receives the
;;     Markdown the user sent: this is rendering, not translation.

;;; Code:

(require 'cl-lib)
(require 'map)
(require 'seq)
(require 'org)

(defgroup agent-org-buffer nil
  "Org chat buffers for agent-org."
  :group 'agent-org
  :prefix "agent-org-buffer-")

;;;; Status header line (the "top bar")

(defface agent-org-status-ready
  '((t :inherit success))
  "Face for the Ready state in the `agent-org' header line."
  :group 'agent-org-buffer)

(defface agent-org-status-busy
  '((t :inherit warning))
  "Face for transient states (starting/streaming/awaiting) in the header line."
  :group 'agent-org-buffer)

(defface agent-org-status-error
  '((t :inherit error))
  "Face for the Error state in the header line."
  :group 'agent-org-buffer)

(defcustom agent-org-use-header-line t
  "When non-nil, show session status in the buffer `header-line'.
When nil, status falls back to minibuffer `message' calls only.
Either way, status text is never written into the chat buffer body."
  :type 'boolean
  :group 'agent-org-buffer)

(defcustom agent-org-use-model-headings t
  "When non-nil, an agent turn is headed by the model that answered it.
So a turn reads \"* MiniMax M3\" instead of \"* Agent\": which model produced
an answer is a fact about the transcript, and the header line that says so is
gone the moment the buffer is buried or the file is re-read a week later.
Nil keeps the stable word for anyone who wants headings not to carry a
provider's catalog naming into their notes.

Only the heading TEXT changes: every placement still goes through the
turn anchor and `agent-org-buffer--render-end', so no code finds a turn by
its heading."
  :type 'boolean
  :group 'agent-org-buffer)

(defcustom agent-org-convert-markdown t
  "When non-nil, Markdown in a reply becomes real Org markup.
Agents answer in Markdown and the chat body is Org, and the two syntaxes
disagree in ways that are STRUCTURAL in Org rather than merely cosmetic:
\"# Title\" is an Org COMMENT (it vanishes from every export), \"* item\" is a
level-1 HEADLINE (it cuts the turn in two), \"---\" under a sentence is a
headline too, and \"**bold**\" is only stars on the screen.  So the turn's
text and the user's own echo are converted on the way in
(`agent-org-buffer--markdown-line'): structure first, inline markup in ONE
pass, and an unterminated code fence closed rather than left to swallow the
rest of the buffer.

Nil is the escape hatch: the agent's bytes land verbatim, exactly as this
package did before.  Nothing on the wire changes either way -- the agent still
receives the Markdown the user typed, so this is rendering, not translation.
The cost is a handful of regexps per LINE (never per character), paid once as
each line completes; the measured number is printed by
`test-agent-org-markdown-conversion-cost-per-line'."
  :type 'boolean
  :group 'agent-org-buffer)

(defvar-local agent-org-buffer--status
  (list :provider "agent-org" :state 'idle :message nil :session-id nil)
  "Status plist backing this buffer's header line and metadata block.
Keys: :provider :state :message :note :session-id :model :model-name :mode
:project :title :used :size :tokens :cost-amount :cost-currency :commands
:modes-list :config :queued.  STATE is one of `idle', `starting', `loading'
(session/load replay in flight), `streaming', `ready', `awaiting' or
`error'.  The list keys hold wire-format alists collected from ACP
notifications.

`:queued' is the one list key that is not wire data: the prompts waiting
to be sent, oldest first, as the session holds them.  The metadata
block's `:QUEUE:' drawer is rendered from it, which is how a prompt the
user typed but never sent reaches the transcript, and how resume finds it
again (see `agent-org-buffer-transcript-queue').

`:model' is the wire id (`minimax/MiniMax-M3') and `:model-name' the
label the agent advertises for it (\"MiniMax M3\"); the bar renders the
second and falls back to the first, so a display change can never touch
what gets sent back to the agent.

`:message' is what a non-ready state SAYS (see
`agent-org-buffer--status-segment'), so it is invisible while Ready.
`:note' is the different thing: one short fact about the session that has
to survive reaching Ready — why the directory listing gave up, say.  Keep
it to a line, and to one clause; it is a suffix on a status bar, not a
log.")

(defun agent-org-buffer--state-label (state)
  "Human-readable label for STATUS state."
  (pcase state
    ('starting "Starting")
    ('loading "Restoring")
    ('streaming "Streaming")
    ('ready "Ready")
    ('awaiting "Awaiting permission")
    ('error "Error")
    (_ "Idle")))

(defun agent-org-buffer--state-face (state)
  "Face for STATUS state."
  (pcase state
    ('error 'agent-org-status-error)
    ((or 'starting 'loading 'streaming 'awaiting) 'agent-org-status-busy)
    ('ready 'agent-org-status-ready)
    (_ 'default)))

(defun agent-org-buffer--status-segment (status)
  "Return the single (TEXT . FACE) status segment for STATUS.
Exactly one status string is ever shown in the header line: generic
placeholder messages never ride along with the state label, and
diagnostics (errors) are folded into the single segment.  The one
exception is `:note' on a Ready state: it is a fact that has to outlive
the handshake (`agent-org-buffer--status'), so it qualifies the label
instead of replacing it."
  (let* ((state (or (plist-get status :state) 'idle))
         (label (agent-org-buffer--state-label state))
         (message (plist-get status :message))
         (note (plist-get status :note))
         (face (agent-org-buffer--state-face state)))
    (cons (pcase state
            ('error (if message (format "Error: %s" message) "Error"))
            ('awaiting (if (and message
                                (not (string-equal message "Permission required")))
                           message
                         label))
            ((or 'starting 'ready)
             (if (and note (eq state 'ready))
                 (format "%s (%s)" label note)
               label))
            ('loading (or message label))
            ('streaming (or message label))
            (_ label))
          face)))

;;;; Usage indicators (ports of agent-shell-usage.el helpers)

(defun agent-org-buffer--format-number-compact (num)
  "Format NUM with agent-shell-style k/m/b unit suffixes."
  (cond
   ((< num 1000) (format "%d" num))
   ((< num 1000000) (format "%.0fk" (/ num 1000.0)))
   ((< num 1000000000) (format "%.0fm" (/ num 1000000.0)))
   (t (format "%.1fb" (/ num 1000000000.0)))))

(defun agent-org-buffer--context-percent (used size)
  "Percent of context USED of SIZE as a float, or nil when unknown."
  (when (and used size (> size 0))
    (/ (* used 100.0) size)))

(defun agent-org-buffer--context-indicator (status)
  "Context usage string (bar + used/size) for STATUS, or nil.
Bar height and color scale with the used percentage, like the
`agent-shell' context indicator."
  (let ((pct (agent-org-buffer--context-percent (plist-get status :used)
                                                (plist-get status :size))))
    (when pct
      (let* ((bars "▁▂▃▄▅▆▇█")
             (face (cond ((< pct 60) 'agent-org-status-ready)
                         ((< pct 85) 'agent-org-status-busy)
                         (t 'agent-org-status-error)))
             (bar (propertize (string (aref bars (min 7 (floor (/ (* pct 8) 100)))))
                              'face face)))
        (format "%s %s/%s" bar
                (agent-org-buffer--format-number-compact
                 (or (plist-get status :used) 0))
                (agent-org-buffer--format-number-compact
                 (plist-get status :size)))))))

(defun agent-org-buffer--cost-indicator (status)
  "Cost string for STATUS (rounded up to the cent), or nil if unknown."
  (let ((amount (plist-get status :cost-amount)))
    (when (and amount (> amount 0))
      (let ((cents (/ (ceiling (* amount 100)) 100.0)))
        (if (equal (plist-get status :cost-currency) "USD")
            (format "$%.2f" cents)
          (format "%.2f %s" cents (or (plist-get status :cost-currency)
                                      "")))))))

(defun agent-org-buffer--model-display (status)
  "Model string to SHOW for STATUS: the agent's label, else the id.
The id is a wire value — `minimax/MiniMax-M3' is what
`session/set_config_option' takes — and an agent does not always name the
model it reports as current, so the id is the fallback rather than nil: a
status bar that drops the model field reads as \"no model\"."
  (or (plist-get status :model-name) (plist-get status :model)))

(defun agent-org-buffer--render-header-line ()
  "Render `agent-org-buffer--status' as a header-line string.
Agent-shell-style fields joined with a single separator; empty fields
are dropped so no dangling separators appear.  Pure function of the
buffer-local status plist; safe to call headless.

The session id is deliberately NOT a segment: it lives in the body's
PROPERTIES drawer as a `:ID:' property, where it is readable and
selectable.  A `[sid]' on the bar is clutter that changes once per
session and says nothing about the session's state."
  (let* ((status agent-org-buffer--status)
         (seg (agent-org-buffer--status-segment status)))
    (concat " "
            (mapconcat
             #'identity
             (delq nil (list
                        (propertize (or (plist-get status :provider)
                                        "agent-org")
                                    'face 'bold)
                        (agent-org-buffer--model-display status)
                        (plist-get status :mode)
                        (plist-get status :project)
                        (agent-org-buffer--context-indicator status)
                        (agent-org-buffer--cost-indicator status)
                        (propertize (car seg) 'face (cdr seg))))
             " ➤ "))))

;; Defined here rather than in the metadata section below: `buffer-create'
;; seeds the title block with it, and a use before `defconst' byte-compiles
;; as a free-variable reference.
(defconst agent-org-buffer--todo-setup "#+TODO: TODO DOING | DONE CANCELLED"
  "Per-file keyword set (`org-set-regexps-and-options' reads it from
the metadata block) naming the tool-call states: pending→TODO,
in_progress→DOING, completed→DONE, failed→CANCELLED.  A call is now a
line of the `:tool:' drawer rather than a heading -- Org forbids
headlines inside drawers -- so on that line a keyword is TEXT the reader
sees, not an Org state `C-c C-t' can cycle (that acts on headlines).
Declaring the set still pays: it documents the only vocabulary a
transcript or a chat uses for a call, in the file that uses it.")

;;;; Buffer creation

(defun agent-org-buffer-create (name)
  "Create and return a new Org chat buffer for provider NAME.
Its initial name is `agent-org-buffer--wanted-name' — project and
provider, id still absent — so the buffer is findable by project from
the handshake onward.  Buffer is in `org-mode' and `agent-org-mode'
with a status header line.  Programmatic text is protected by
`read-only' text properties, not by a global `buffer-read-only', so the
live prompt at the end is always typeable."
  ;; The leading space marks the FIRST name as an internal one: it exists
  ;; for the three lines it takes to seed the status, and `apply-name'
  ;; replaces it with the real chat name before this buffer is ever
  ;; listable.  A blank name would hide a session whose rename failed.
  (let ((buf (generate-new-buffer (format " *agent-org-%s*" name))))
    (with-current-buffer buf
      (org-mode)
      (setq agent-org-buffer--status
            (list :provider name :state 'starting :message "Connecting…"
                  :session-id nil
                  :project (file-name-nondirectory
                            (directory-file-name default-directory))))
      ;; the name wants the project, and the project is only known once
      ;; the status exists: wear the full shape from the first moment
      (agent-org-buffer--apply-name)
      (let ((inhibit-read-only t))
        ;; seed metadata: provider name stands in as the title until the
        ;; harness reports its session title; the tool keyword set must
        ;; be live from the first turn on
        (insert (format "#+TITLE: %s\n%s\n\n" name agent-org-buffer--todo-setup))
        (agent-org-buffer--protect (point-min) (point-max))
        (org-set-regexps-and-options))
      (agent-org-mode 1))
    buf))

(defun agent-org-buffer-set-session (buffer session)
  "Bind SESSION to BUFFER as a buffer-local variable."
  (with-current-buffer buffer
    (setq-local agent-org-buffer--session session)))

(defun agent-org-buffer--session ()
  "Return the session plist for the current buffer."
  (or (and (boundp 'agent-org-buffer--session)
           agent-org-buffer--session)
      (user-error "No agent-org session in this buffer")))

(defvar-local agent-org-buffer--session nil
  "The `agent-org' session plist for this buffer.")

(defvar-local agent-org-buffer--streaming-p nil
  "Non-nil while an agent turn is actively streaming.
Font-lock stays on the whole time; only the freshly appended region is
re-fontified, so Org colors never vanish mid-turn.")

(defvar-local agent-org-buffer--prompt-anchor nil
  "Marker at the start of the trailing live `* User' type-ahead box.
The box -- its leading separator, its frozen heading and the user's
unsubmitted draft -- is the last thing in the buffer while a turn
streams.  Every per-turn render inserts BEFORE this marker (see
`agent-org-buffer--render-end') rather than at `point-max', so a
streaming response never scribbles over what the user is typing and the
box stays typeable.  nil when no box is open.")

(defvar-local agent-org-buffer--stream-start nil
  "Point at the start of the current streaming body.")

(defvar-local agent-org-buffer--turn-anchor nil
  "Marker at the start of the streaming `* Agent' heading, if any.
The turn's drawers are located relative to this anchor, not to the
buffer end, because the body trails it: the type-ahead box, the
`:thinking:' drawer and the `:tool:' drawer all live after the heading,
so the heading is never the last thing in the turn.")

(defvar-local agent-org-buffer--tools nil
  "Alist ((ID . PLIST) ...) of the current Agent turn's tool calls.
PLIST is (:title T :status S :output O :shown SH); each ID owns one line of
the turn's `:tool:' drawer and, with output, one `- TITLE' item of the
turn's single `:tool-output:' drawer.  The whole status drawer is redrawn
from this list on every update (`agent-org-buffer-insert-tool'), so no
marker per call: the list IS the record, and its order is the order the
agent made the calls -- which is also the order the output items appear in.
`:shown' holds the output last written, so a status-only update never
re-inserts the shared body that did not change.")

(defvar-local agent-org-buffer--thought nil
  "Thinking text accumulated for the current Agent turn, rendered into
the per-turn :thinking: drawer by `agent-org-buffer-append-thought'.")

;;;; Forward declaration

(declare-function agent-org-send "agent-org" ())
(declare-function agent-org-set-session-model "agent-org" (model))
(declare-function agent-org-queue-view "agent-org" ())
(declare-function agent-org-cancel-turn "agent-org" ())

;;;; Status updates

(defun agent-org-buffer--wanted-name ()
  "The buffer name this buffer's session facts call for.
A chat buffer is the session: `C-x b' and the switcher list its name, and
`Qoder' says nothing at all to someone with three qoder chats open.  So
the name is `<who>:<project> [<session id>]' — the agent, or the harness's
own title once it has one, then the project directory it is a chat OF,
then the ACP id the wire addresses it by.

The provider stands in for a title that has not arrived, exactly as it
does for `#+TITLE:', and the id is left out until the agent has given one
(the buffer is named this way from the moment `session/new' is answered,
and qoder titles a session only after the first turn).  Title text is
agent-supplied free text, hence `agent-org-buffer--label': a buffer name
with a newline in it breaks the completion UI.

No `agent-org: ' prefix and no `*…*' delimiters: the user asked for the
name to BE the chat, and the package's own name costs a chat its place in
`C-x b', where `*agent-org: …*' sorts together with everything else in the
product rather than with the project it belongs to.

The name's first part is `agent-org-buffer--chat-label', which
`agent-org-switch-buffer' builds its first column from as well: one chat,
one display label, wherever it is shown."
  (let* ((status agent-org-buffer--status)
         (sid (plist-get status :session-id)))
    (format "%s%s"
            (agent-org-buffer--chat-label status)
            (if sid (format " [%s]" sid) ""))))

(defun agent-org-buffer--chat-label (status)
  "The display label of the chat described by the status plist STATUS.
`<who>:<project>': the harness's own title, the provider standing in
before a title arrives and `agent-org' if not even that is known, then the
directory the chat was started in after the colon.  The idiom is the one
Emacs users already read as \"thing it is a buffer OF\" (`file:directory'
in the buffer menu) and the one the user asked for by name.  The project
still has to be IN the name: measured live, a session in this repo and a
session in org-docs produced two switcher rows identical but for their
UUIDs while `C-x b' was already telling them apart.  Flattened by
`agent-org-buffer--label' (the title is agent free text) and never
truncated, so the label can out-grow a column; the padding code copes.

STATUS is a parameter, not a read of `agent-org-buffer--status': the
switcher labels OTHER buffers, and a function that is only correct when
called in the right buffer is a bug waiting for the next caller."
  (let ((project (plist-get status :project))
        (label (agent-org-buffer--label
                (or (plist-get status :title)
                    (plist-get status :provider)
                    "agent-org"))))
    (if (and project (not (string-empty-p project)))
        (concat label ":" project)
      label)))

(defun agent-org-buffer--apply-name ()
  "Rename the current buffer to `agent-org-buffer--wanted-name', if needed.
The equality test is not an optimisation.  `generate-new-buffer-name'
counts this very buffer when it already wears the name, so renaming on
every status update would walk a session through
`T [s]<2><3><4>' — a turn sends dozens of updates.
Renaming with `rename-buffer' rather than `rename-uniquely' because the
name is the point, not a fresh one: RENAME-ALL-PROCESSES stays nil so
the agent process keeps the name `acp' gave it, which is what
`M-x list-processes' is read by."
  (let ((want (agent-org-buffer--wanted-name)))
    (unless (equal (buffer-name) want)
      (rename-buffer (generate-new-buffer-name want)))))

(defun agent-org-buffer-set-status (buffer &rest status)
  "Update BUFFER's header-line status from plist STATUS.
Recognised keys are those of `agent-org-buffer--status'.
Only keys present in STATUS are changed, so passing
`:message nil` clears the message while leaving other fields intact.
With `agent-org-use-header-line' nil, the rendered status is shown via
`message' instead.  Status never touches the buffer body.

A `:title' or `:session-id' in STATUS also re-names the buffer, because
those two and the creation-time `:project' are all a name is made of: a
usage or state update does no string building and no rename."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (dolist (key '(:provider :state :message :note :session-id :model :model-name
                         :mode :project :title :used :size :tokens :cost-amount
                         :cost-currency :commands :modes-list :config :queued))
        (when (plist-member status key)
          (setq agent-org-buffer--status
                (plist-put agent-org-buffer--status key (plist-get status key)))))
      (when (or (plist-member status :title)
               (plist-member status :session-id))
        (agent-org-buffer--apply-name))
      (if agent-org-use-header-line
          (force-mode-line-update)
        (message "%s" (string-trim (agent-org-buffer--render-header-line))))
      agent-org-buffer--status)))

;;;; Minor mode

(defun agent-org-buffer--blocked (&rest _)
  "Refuse Org structure-editing commands in chat buffers."
  (interactive)
  (user-error "Chat content is managed automatically"))

(defvar agent-org-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'agent-org-send)
    (define-key map (kbd "C-c C-m") #'agent-org-set-session-model)
    (define-key map (kbd "C-c C-q") #'agent-org-queue-view)
    (define-key map (kbd "C-c C-k") #'agent-org-cancel-turn)
    ;; Org structure commands bypass `read-only' text properties and would
    ;; corrupt heading boundaries; block them all.
    (dolist (key (list (kbd "M-RET") (kbd "C-c C-t")
                       [(meta up)] [(meta down)] [(meta left)] [(meta right)]
                       [(shift up)] [(shift down)]
                       (kbd "C-c -")))
      (define-key map key #'agent-org-buffer--blocked))
    map))

(defun agent-org-buffer--which-function ()
  "The heading around point, with NO text properties, for `which-function'.
Org's own answer (`add-log-current-defun-function' set by `org-mode') is a
`buffer-substring' of the heading line, so in a chat buffer it carries this
package's `read-only' property.  `which-func-format' then displays that
string by APPLYING a face to it, and applying a property to read-only text
is a modification: Emacs signals `text-read-only' inside
`format-mode-line'.  doom-modeline builds its entire right half in ONE such
call, so a single protected heading blanks the whole mode line.  Answering
with a property-free copy keeps the bar alive without weakening the
protection -- the buffer text itself is untouched -- and nil away from a
heading is what `which-function' wants: it skips its imenu fallback only
because this variable is non-nil, so a streaming chat never pays for an
index scan."
  (when (and (derived-mode-p 'org-mode) (org-at-heading-p))
    (let ((heading (ignore-errors (org-get-heading t t t t))))
      (when (and heading (not (string-empty-p heading)))
        (substring-no-properties heading)))))

(defun agent-org-buffer--ensure-font-lock ()
  "Ask for Org colors in this chat buffer, once it is on display.
A chat buffer is created inside an acp handshake callback, so NO window shows
it yet, and `font-lock-mode' cannot be enabled in such a buffer: measured in a
live Emacs, `(font-lock-mode 1)' there leaves the buffer-local variable nil
without an error, a warning or any trace, and `turn-on-font-lock' does the
same.  That is why ambient `global-font-lock-mode' never reaches a chat: the
global minor mode only acts on buffers when they are created or shown while it
is on, and the creation happened in the dark.  Emacs runs
`window-configuration-change-hook' with the buffer current the moment it first
appears in a window, which is the earliest point the request can succeed, so
`agent-org-mode' installs this there.

`unless', not a toggle: the hook re-runs on EVERY window change, and a second
`(font-lock-mode 1)' would tear down and rebuild jit-lock over a transcript
that can be thousands of lines long, for nothing."
  (unless font-lock-mode
    (font-lock-mode 1)))

(define-minor-mode agent-org-mode
  "Minor mode for `agent-org' Org chat buffers.
Type at the live `* User' prompt at the end of the buffer.
Keys:
  C-c C-c  Send the typed prompt (queues it while the agent responds)
  C-c C-k  Cancel the running turn
  C-c C-m  Switch the session's model
  C-c C-q  List the prompts queued for this session"
  :init-value nil
  :lighter nil
  :keymap agent-org-mode-map
  (if agent-org-mode
      (progn
        (when agent-org-use-header-line
          (setq header-line-format
                '(:eval (agent-org-buffer--render-header-line))))
        (setq-local add-log-current-defun-function
                    #'agent-org-buffer--which-function)
        ;; Buffer-local (the 4th arg), so this hook entry dies with the chat
        ;; and never runs in a buffer that only wants Org's own colors.
        (add-hook 'window-configuration-change-hook
                  #'agent-org-buffer--ensure-font-lock nil t))
    (kill-local-variable 'header-line-format)
    (kill-local-variable 'add-log-current-defun-function)
    (remove-hook 'window-configuration-change-hook
                 #'agent-org-buffer--ensure-font-lock t)))

;;;; Session metadata block (Org-native, agent-shell bootstrapping)

(defun agent-org-buffer--tool-keyword (status)
  "Org TODO keyword for ACP tool STATUS (nil/unknown means pending)."
  (pcase status
    ("in_progress" "DOING")
    ("completed" "DONE")
    ("failed" "CANCELLED")
    (_ "TODO")))

(defun agent-org-buffer--metadata-drawer (name entries)
  "Render drawer NAME with ENTRIES (already-formatted strings).
Nil when no entries; capped at 50 lines with a +N-more tail."
  (when entries
    (let ((shown (seq-take entries 50)))
      (concat (format ":%s:\n" name)
              (mapconcat #'identity shown "\n")
              "\n"
              (when (> (length entries) 50)
                (format "… (+%d more)\n" (- (length entries) 50)))
              ":END:\n"))))

(defun agent-org-buffer--queue-encode (text)
  "Escape TEXT onto ONE line of the `:QUEUE:' drawer.
A queue entry is the user's own draft, so it can run to many lines and can
contain a blank line or a bare `:END:' — either would cut the drawer short
and leave the rest of the prompt outside it.  So one line per prompt:
backslash doubles, newline and carriage return become =\\n= and =\\r=, and
the `- ' prefix keeps even a prompt that IS `:END:' from starting its line
with one.  The drawer is machine-read, so nothing is beautified:
`agent-org-buffer--queue-decode' is the exact inverse and the queue
survives a restart byte for byte."
  (with-temp-buffer
    (insert "- ")
    (dotimes (i (length text))
      (insert (pcase (aref text i)
                 (?\\ "\\\\")
                 (?\n "\\n")
                 (?\r "\\r")
                 (c (string c)))))
    (buffer-string)))

(defun agent-org-buffer--queue-decode (line)
  "The prompt stored on queue drawer LINE, unescaped.
Inverse of `agent-org-buffer--queue-encode'.  An unknown escape keeps the
character that follows it, so a drawer written by a newer version reads
back as text on resume instead of losing a prompt to an error."
  (let ((body (if (string-prefix-p "- " line)
                  (substring line 2)
                (string-trim line)))
        (i 0))
    (with-temp-buffer
      (while (< i (length body))
        (let ((c (aref body i)))
          (if (and (= c ?\\) (< (1+ i) (length body)))
              (progn
                (insert (pcase (aref body (1+ i))
                          (?n ?\n)
                          (?r ?\r)
                          (other (string other))))
                (cl-incf i 2))
            (insert c)
            (cl-incf i))))
      (buffer-string))))

(defun agent-org-buffer--config-value (option)
  "The current value of config OPTION, as a person should read it.
When the agent pairs `currentValue' with a label in the option's own
`options' list, print the label: the CONFIG drawer used to print the
raw id, so the same buffer said \"QModel Large\" in the header line and
\"qmodel-large\" in the drawer two lines below.  `seq-find' accepts the
wire's vector as well as a list, and the id stays as the fallback for
values outside the advertised catalog — an agent can report a model it
does not name, and blanking the field there would lie harder."
  (let ((current (map-elt option 'currentValue)))
    (if (null current)
        ""
      (let ((options (map-elt option 'options)))
        (or (and options
                 (map-elt (seq-find (lambda (o)
                                      (equal (map-elt o 'value) current))
                                    options)
                          'name))
            current)))))

(defun agent-org-buffer--render-metadata (status)
  "Render the buffer-top Org metadata block for STATUS (pure).
The PROPERTIES drawer comes first, carrying the scalars (Provider, ID,
Mode, Model, Context, Cost, Tokens), then the `#+TITLE:' keyword line,
then COMMANDS/MODES/CONFIG drawers listing everything the agent
reported, then QUEUE with the prompts waiting to be sent.  No heading:
`* ' lines belong to the conversation.  Drawers whose lists are still
unknown are omitted — including QUEUE the moment the queue empties,
which is what stops a drained prompt being restored a second time — and
so is the `:ID:' line until an id exists; a `:ID: unknown' would be a
property Org's id machinery would choke on, and a lie besides."
  (let* ((provider (or (plist-get status :provider) "agent-org"))
         (sid (plist-get status :session-id))
         (used (plist-get status :used))
         (size (plist-get status :size))
         (pct (agent-org-buffer--context-percent used size))
         (context (if pct
                      (format "%s/%s (%.0f%%)"
                              (agent-org-buffer--format-number-compact (or used 0))
                              (agent-org-buffer--format-number-compact size)
                              pct)
                    "unknown"))
         (commands (mapcar (lambda (c)
                            (format "/%s — %s" (map-elt c 'name)
                                    (or (map-elt c 'description) "")))
                          (plist-get status :commands)))
         (modes (mapcar (lambda (m)
                         (format "%s (id: %s) — %s" (map-elt m 'name)
                                 (map-elt m 'id)
                                 (or (map-elt m 'description) "")))
                       (plist-get status :modes-list)))
         (config (mapcar (lambda (o)
                          (format "%s — %s" (map-elt o 'name)
                                  (agent-org-buffer--config-value o)))
                        (plist-get status :config)))
         ;; Waiting prompts, oldest first, one escaped line each.  The
         ;; conversation cannot show them: a queued prompt gets its
         ;; `* User' heading only when it drains.
         (queued (mapcar #'agent-org-buffer--queue-encode
                         (plist-get status :queued))))
    (concat
     (mapconcat
      #'identity
      (delq nil
            (list
             (concat
              ":PROPERTIES:\n"
              (format ":Provider: %s\n" provider)
              ;; qoder issues a real UUID per session, so this doubles
              ;; as an Org id-link target once per-heading ids land
              (if sid (format ":ID: %s\n" sid) "")
              (format ":Mode: %s\n" (or (plist-get status :mode) "unknown"))
              (format ":Model: %s\n"
                      (or (agent-org-buffer--model-display status) "unknown"))
              (format ":Context: %s\n" context)
              (format ":Cost: %s\n"
                      (or (agent-org-buffer--cost-indicator status) "$0.00"))
              (when-let* ((tokens (plist-get status :tokens)))
                (format ":Tokens: %d\n" tokens))
              ":END:\n")
             ;; `#+TITLE:' is the harness's own session title, verbatim;
             ;; the provider name only stands in until one arrives.
             (concat
              (format "#+TITLE: %s\n"
                      (or (plist-get status :title) provider))
              (concat agent-org-buffer--todo-setup "\n"))
             (agent-org-buffer--metadata-drawer "COMMANDS" commands)
             (agent-org-buffer--metadata-drawer "MODES" modes)
             (agent-org-buffer--metadata-drawer "CONFIG" config)
             ;; last: the one list that changes mid-turn, so the
             ;; reference drawers above never shift position
             (agent-org-buffer--metadata-drawer "QUEUE" queued)))
      "\n")
     ;; blank line separating the block from the first conversation
     ;; heading (refresh deletes up to that heading)
     "\n")))

(defconst agent-org-buffer--metadata-drawers
  '("PROPERTIES" "COMMANDS" "MODES" "CONFIG" "QUEUE")
  "Names of the folded-by-default drawers in the metadata block.
`agent-org-buffer-refresh-metadata' reads this to remember which drawers
the user had opened, and a name missing here is a drawer that reappears
unfolded on every rebuild — QUEUE included for that reason, not because
its prompts are reference material.")

(defvar-local agent-org-buffer--metadata-cache nil
  "Last metadata block written at the top of this buffer, or nil.
`agent-org-buffer-refresh-metadata' compares the freshly rendered
block against it and skips the rebuild when they match.  That matters
because usage/commands updates arrive constantly while a turn streams,
and each rebuild would re-parse the whole buffer
(`org-set-regexps-and-options') — measurable on a slow machine.")

(defun agent-org-buffer-refresh-metadata (buffer)
  "Replace the Org metadata block at the top of BUFFER from its status.
Delete-then-insert keeps this idempotent.  The block spans point-min
up to (but not including) the first conversation heading, so chat
text is never touched.  Drawers the user had left folded are re-folded
after the rebuild; ones they opened stay open.

Skips entirely when the rendered block is byte-identical to
`agent-org-buffer--metadata-cache': no deletion, no insertion, and no
`org-set-regexps-and-options' reparse of the whole buffer."
  (with-current-buffer buffer
    (let ((rendered (agent-org-buffer--render-metadata agent-org-buffer--status)))
      (unless (equal rendered agent-org-buffer--metadata-cache)
        (let ((inhibit-read-only t))
          (save-excursion
            (let ((folded
                   (mapcar
                    (lambda (name)
                      (cons name
                            (save-excursion
                              (goto-char (point-min))
                              (if (re-search-forward (format "^:%s:" name) nil t)
                                  (progn (forward-line 1)
                                         (invisible-p (point)))
                                ;; drawer not present yet: fold it when created
                                t))))
                    agent-org-buffer--metadata-drawers)))
              (goto-char (point-min))
              (if (re-search-forward "^\\* " nil t)
                  (beginning-of-line)
                (goto-char (point-max)))
              (delete-region (point-min) (point))
              (goto-char (point-min))
              (let ((beg (point)))
                (insert rendered)
                (setq agent-org-buffer--metadata-cache rendered)
                (agent-org-buffer--protect beg (point))
                ;; parse the freshly inserted `#+TODO:' setup line so tool
                ;; headings get their buffer-local keyword set; only
                ;; needed because the block text actually changed
                (org-set-regexps-and-options)
                (dolist (state folded)
                  (when (cdr state)
                    (save-excursion
                      (goto-char beg)
                      (when (re-search-forward (format "^:%s:" (car state)) nil t)
                        (org-fold-hide-drawer-toggle)))))))))))))

;;;; Protection + live prompt

(defun agent-org-buffer--protect (beg end)
  "Freeze buffer text between BEG and END against editing.
The cursor may still travel over it; only modifications signal
`text-read-only'.  `add-text-properties' itself refuses to touch
already read-only text, so the suppression is bound here for the
fully programmatic path."
  (let ((inhibit-read-only t))
    (add-text-properties beg end
                         '(read-only t front-sticky (read-only)))))

(defun agent-org-buffer--separator ()
  "Ensure point starts a fresh line preceded by a blank one.
Headings inserted right after text would otherwise abut it, which
Org tolerates but renders poorly."
  (unless (bolp) (insert "\n"))
  (when (and (> (point) (point-min))
             (not (eq ?\n (char-before (1- (point))))))
    (insert "\n")))

(defun agent-org-buffer--open-prompt-p ()
  "Non-nil when the current buffer ends in a typeable User prompt."
  (condition-case nil
      (save-excursion
        (goto-char (point-max))
        (org-back-to-heading t)
        (when (string= (org-get-heading t t t t) "User")
          (org-end-of-meta-data t)
          (not (get-text-property (point) 'read-only))))
    (error nil)))

(defun agent-org-buffer--render-end ()
  "Where the next per-turn block belongs in the current buffer.
The live type-ahead box's start when one is open -- so a streaming turn
renders above it and the draft the user is typing survives -- and
`point-max' otherwise (during a replay, before any box exists).
Always called with the chat buffer current."
  (if (and agent-org-buffer--prompt-anchor
           (marker-buffer agent-org-buffer--prompt-anchor))
      (marker-position agent-org-buffer--prompt-anchor)
    (point-max)))

(defun agent-org-buffer-insert-prompt (buffer)
  "Ensure BUFFER ends with a live `* User' type-ahead box.
Only the box's leading separator and its heading are frozen; the body
stays typeable.  No-op when a box is already open, so every turn
boundary can call it without stacking boxes.

The box is deliberately never consumed by sending (see
`agent-org-buffer-take-draft'): it stays at the buffer end while a turn
streams, which is what lets the user type the next prompt -- or queue
one -- mid-turn.  Everything the turn renders lands above it, because
the streaming path appends at `agent-org-buffer--render-end' rather than
at `point-max'."
  (with-current-buffer buffer
    (unless (agent-org-buffer--open-prompt-p)
      (let* ((inhibit-read-only t)
             (orig (point))
             ;; keep point where it was unless it was at the end or
             ;; trapped in frozen text (then it belongs at the prompt)
             (stay (or (eq orig (point-max))
                       (get-text-property orig 'read-only))))
        (goto-char (point-max))
        (let ((box-beg (point)))
          (agent-org-buffer--separator)
          (insert "* User\n\n")
          (agent-org-buffer--protect box-beg (point))
          ;; typed text after the heading must not inherit the freeze
          (put-text-property (1- (point)) (point)
                             'rear-nonsticky '(read-only))
          ;; the anchor sits at the box's very start, separator included:
          ;; rendering above it can never glue text to the heading.
          ;; Rear-advancing so text inserted AT the anchor position pushes
          ;; the marker (and the box) down instead of the marker staying
          ;; behind it, which would make every render land before the last
          ;; and stream the turn in reverse
          (let ((anchor (make-marker)))
            (set-marker-insertion-type anchor t)
            (move-marker anchor box-beg)
            (setq-local agent-org-buffer--prompt-anchor anchor))
          (unless stay (goto-char orig)))))))

(defun agent-org-buffer-take-draft (buffer)
  "Return the text typed at BUFFER's live box and empty the box.
The box itself stays open and last, ready for the next message: this is
what sending looks like in a chat that keeps a persistent prompt.
Signals a `user-error' when no box is open or nothing has been typed."
  (with-current-buffer buffer
    (unless (agent-org-buffer--open-prompt-p)
      (user-error "Nothing to send; type your prompt under the User heading"))
    (let ((beg (save-excursion
                 (goto-char (point-max))
                 (org-back-to-heading t)
                 (org-end-of-meta-data t)
                 (point))))
      (let ((text (string-trim (buffer-substring-no-properties
                                beg (point-max)))))
        (when (string-empty-p text)
          (user-error "Empty prompt"))
        (let ((inhibit-read-only t))
          (delete-region beg (point-max)))
        (goto-char (point-max))
        text))))

(defun agent-org-buffer-insert-user (buffer text)
  "Insert a frozen User heading with TEXT into BUFFER (programmatic use).
Lands above the live type-ahead box when one is open, so a drained queue
prompt renders in history order rather than underneath the draft.

The echo is a complete message, so it converts in one pass
(`agent-org-buffer--markdown-convert') rather than the streaming feed --
but with the SAME rules, which is why one reply reads alike on both sides of
the exchange.  The agent still receives the Markdown as typed: the conversion
belongs to the rendering, never to the wire."
  (with-current-buffer buffer
    (when agent-org-convert-markdown
      (setq text (agent-org-buffer--markdown-convert text)))
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (agent-org-buffer--render-end))
        (let ((beg (point)))
          (agent-org-buffer--separator)
          (insert (format "* User\n\n%s\n" text))
          (agent-org-buffer--protect beg (point)))))))

;;;; Markdown -> Org on the reply body

(defconst agent-org-buffer--md-inline-regexp
  "\\*\\{1,2\\}[^*\n]+?\\*\\{1,2\\}\\|`[^`\n]+`\\|\\[[^]\n]*\\](\\([^)\n]*\\))"
  "One alternation for every inline Markdown markup this converter knows.
The pass must be SINGLE scan, not a chain of rewrites: turning `**b**' into
`*b*' and then running the `*i*' rule over the RESULT italicises the bold it
just made.  Scanning left to right and consuming each match means markup is
rewritten exactly once and never sees its own output.

Order inside the alternation is the order of preference at one position; the
link alternative captures its URL because that is the only part a renderer
needs grouped -- the rest is read back off the match string.")

(defvar-local agent-org-buffer--md-fragment nil
  "Last line of the streaming Agent turn, still incomplete and still Markdown.
A chunk stops wherever the model's tokenizer stopped, so `**bold' can end one
chunk and `**' open the next.  The fragment's Org rendering IS in the buffer —
provisionally, at `agent-org-buffer--md-tail' — and the next chunk rewrites it,
which is what makes a split construct reach the buffer once, as markup, while
still letting the user watch the answer arrive.")

(defvar-local agent-org-buffer--md-tail nil
  "Marker at the start of the provisional last line of the streaming turn.
The region from here to `agent-org-buffer--render-end' is the only text
`agent-org-buffer--markdown-receive' ever rewrites: everything before it is
finished, and anything drawn at a boundary (`:tool:', `:thinking:') is finished
too, because `agent-org-buffer--markdown-flush-here' freezes the tail first.
Nil while no line is pending.")

(defvar-local agent-org-buffer--md-src-p nil
  "Non-nil while the streaming Agent turn is inside a fenced code block.
Its body is CODE, so no conversion rule may fire on it (`# comment' in a
shell sample is not a heading) -- and an unclosed block must be shut at turn
end, because an open `#+begin_src' swallows everything after it in the buffer
AND in the transcript.")

(defun agent-org-buffer--md-table-rule (line)
  "Org column rule for the Markdown table separator LINE.
Measured with `org-export-string-as': `|---|---|' after a header row IS
Org's separator (it exports a `thead'), but Markdown's alignment form
`|:--|:-:|--:|' is not -- the colons make it an ordinary cell, so the table
loses its header AND the row exports as data, with `--:' turned into an
em-dash.  So every rule line becomes Org's own writer shape `|---+---|',
which carries no colons to misread.  Leading indent is kept: a table inside
a list item stays inside it."
  (let ((cells (seq-remove #'string-empty-p
                           (mapcar #'string-trim (split-string line "|")))))
    (concat (and (string-match "^[ \t]+" line) (match-string 0 line))
            "|" (mapconcat (lambda (_) "---") cells "+") "|")))

(defun agent-org-buffer--md-emphasis-p (match line start)
  "Non-nil when the `*' run MATCH at START in LINE really emphasises.
Markdown will not make emphasis of `2*3*4' or of `* list': its opening
delimiter may not be preceded by an alphanumeric, and its body may not begin
or end in whitespace.  Without those two checks a stray star in arithmetic
turns into italics, which is a corruption of the reply, not a rendering."
  (let ((lead (string-match "[^*]" match))
        (tail (string-match "\\*+\\'" match)))
    (and lead tail
         (or (zerop start)
             (not (string-match-p "[[:alnum:]_]" (string (aref line (1- start)))))
             ;; at line begin there is nothing to clash with
             )
         (> tail lead)
         (not (string-match-p "[ \t]" (substring match lead (1+ lead))))
         (not (string-match-p "[ \t]" (substring match (1- tail) tail))))))

(defun agent-org-buffer--md-inline-render (match)
  "Org markup for one inline MATCH of `agent-org-buffer--md-inline-regexp'."
  (cond
   ((string-prefix-p "`" match)
    (concat "=" (substring match 1 (1- (length match))) "="))
   ((string-prefix-p "*" match)
    (let ((lead (string-match "[^*]" match))
          (tail (string-match "\\*+\\'" match)))
      (if (> lead 1)
          (concat "*" (substring match lead tail) "*")
        (concat "/" (substring match lead tail) "/"))))
   (t
    (let ((link-end (string-match "\\](\\([^)\n]*\\))" match)))
      (format "[[%s][%s]]"
              (substring match (+ link-end 2) (1- (length match)))
              (substring match 1 link-end))))))

(defun agent-org-buffer--md-inline (line)
  "Org inline markup for LINE's Markdown inline markup, in one left-to-right pass."
  (let ((out nil) (pos 0))
    (while (string-match agent-org-buffer--md-inline-regexp line pos)
      ;; Take everything the scan needs BEFORE the helpers run: both
      ;; `--md-emphasis-p' and `--md-inline-render' call `string-match'
      ;; themselves and the match data is global, so `match-end' read after
      ;; them is the helper's last match, not this one.  (That is what made the
      ;; scan loop forever on `**bold** *emph*': it advanced to a position
      ;; BEHIND the match it had just consumed.)
      (let ((start (match-beginning 0))
            (end (match-end 0))
            (match (match-string 0 line)))
        (if (and (string-prefix-p "*" match)
                 (not (agent-org-buffer--md-emphasis-p match line start)))
            ;; Not emphasis after all.  Skip the whole run of stars, not one
            ;; character: a rejected match starts at the run's FIRST star, so
            ;; resuming just past it finds a match beginning there and rejects
            ;; it again, and the scan never passes it.  Advancing past the run
            ;; also stops `* a' being rewritten as a bullet two characters
            ;; later.
            (progn (push (substring line pos end) out)
                   (setq pos end))
          (push (substring line pos start) out)
          (push (agent-org-buffer--md-inline-render match) out)
          (setq pos end))))
    (push (substring line pos) out)
    (mapconcat #'identity (nreverse out) "")))

(defun agent-org-buffer--md-structure (line)
  "Org structural markup for the Markdown LINE, before inline rules run.
Only what starts at column 0 is structure: `#' there is an Org comment and
`*' there is a headline, which is the whole reason this function exists.
A Markdown heading is shifted ONE level down (`#' -> `**') because level 1 in
this buffer belongs to the conversation -- a reply's `# Title' must nest
inside its own turn, not become a sibling of it."
  (cond
   ((string-match "^\\(#+\\) \\(.*\\)" line)
    (concat (make-string (1+ (length (match-string 1 line))) ?*) " "
            (agent-org-buffer--md-inline (match-string 2 line))))
   ((string-match "^\\([ \t]*\\)\\* \\(.*\\)" line)
    ;; Exactly ONE star: `* item' is Markdown's bullet and an Org headline, but
    ;; `** not emphasis' is neither, and a looser `\\*+ ' would have rewritten it
    ;; as a bullet before any inline rule got the chance to say so.
    (concat (match-string 1 line) "- "
            (agent-org-buffer--md-inline (match-string 2 line))))
   (t (agent-org-buffer--md-inline line))))

(defun agent-org-buffer--markdown-line (line src-p)
  "Org version of one Markdown LINE, threading the fence state SRC-P.
Return (ORG-LINE . SRC-P).  The three cases the reply body actually needs, in
the order that keeps them from overlapping: a fence line flips the state and
becomes a source block marker; inside a block everything is verbatim, because
a shell sample full of `#' and `*' is code, not markup; and outside one, a
divider line is indented one space (`---' under a paragraph is an Org
headline) and a table rule gains its column groups before
`agent-org-buffer--md-structure' handles headings, bullets and inline markup.

The rules are deliberately few and each is either STRUCTURAL (getting it wrong
corrupts the document) or the two emphasis forms agents write constantly.
`_text_' is left alone: in Org the underscore is emphasis only between
non-word characters anyway, and rewriting it would eat `foo_bar_baz'.
`~~text~~' is left alone because it reads as written and is only cosmetic."
  (let ((case-fold-search nil))
    (cond
     ((string-match "^[ \t]*```\\([A-Za-z0-9_+.-]*\\)[ \t]*$" line)
      (cons (if src-p "#+end_src"
                (format "#+begin_src %s" (match-string 1 line)))
            (not src-p)))
     (src-p (cons line src-p))
     ((string-match-p "^[ \t]*\\(?:-\\{3,\\}\\|\\*\\{3,\\}\\|_{3,}\\)[ \t]*$" line)
      (cons (concat " " line) src-p))
     ((and (string-match-p "^[ \t]*|[-: |]*|[ \t]*$" line)
           (string-match-p "-" line))
      (cons (agent-org-buffer--md-table-rule line) src-p))
     (t (cons (agent-org-buffer--md-structure line) src-p)))))

(defun agent-org-buffer--markdown-convert-lines (lines src-p)
  "Org text of the Markdown LINES, starting in fence state SRC-P.
Return (TEXT . SRC-P).  LINE-BY-LINE is the whole design: a fence is a state
that begins on one line and ends on another, so nothing else can thread it."
  (let ((out nil))
    (dolist (line lines)
      (let ((rendered (agent-org-buffer--markdown-line line src-p)))
        (setq src-p (cdr rendered))
        (push (car rendered) out)))
    (cons (mapconcat #'identity (nreverse out) "\n") src-p)))

(defun agent-org-buffer--markdown-convert (text)
  "Org markup for the complete Markdown TEXT of one message.
Closes a fence the author left open: one `#+begin_src' without its
`#+end_src' hides the rest of the turn, the rest of the buffer and the rest
of the transcript file, and an agent that hit its token limit can send one."
  (let ((result (agent-org-buffer--markdown-convert-lines
                 (split-string text "\n") nil)))
    (if (cdr result)
        (concat (car result) "\n#+end_src")
      (car result))))

(defun agent-org-buffer--markdown-write (frozen partial)
  "Rewrite this buffer's provisional tail as FROZEN lines then one PARTIAL line.
FROZEN is the Org rendering of the lines this chunk completed (nil when it
completed none); PARTIAL is the Org rendering of the line still arriving (nil
when nothing is pending).  Run it in the chat buffer.

The region replaced is exactly the one the previous PARTIAL wrote, so nothing
that was already finished — and no drawer drawn at a boundary — can be touched
by a later chunk."
  (when (or (and frozen (not (string-empty-p frozen)))
            (and partial (not (string-empty-p partial)))
            (markerp agent-org-buffer--md-tail))
    (let ((inhibit-read-only t))
      (save-excursion
        ;; Read the position BEFORE detaching: `set-marker' with nil leaves the
        ;; variable holding a perfectly live marker OBJECT whose
        ;; `marker-position' is nil, and `markerp' cannot tell the two apart
        ;; (measured: the chunk after one that ended with a newline crashed with
        ;; `integer-or-marker-p nil' on the way to `goto-char').
        (let* ((tail-pos (and (markerp agent-org-buffer--md-tail)
                              (marker-position agent-org-buffer--md-tail)))
               (beg (or tail-pos (agent-org-buffer--render-end))))
          (when (markerp agent-org-buffer--md-tail)
            (set-marker agent-org-buffer--md-tail nil)
            (setq agent-org-buffer--md-tail nil))
          (goto-char beg)
          (delete-region beg (max beg (agent-org-buffer--render-end)))
          (when (and frozen (not (string-empty-p frozen)))
            (let ((start (point)))
              (insert frozen "\n")
              (agent-org-buffer--protect start (point))))
          (when (and partial (not (string-empty-p partial)))
            (let ((start (point)))
              (insert partial)
              (move-marker (setq-local agent-org-buffer--md-tail (make-marker))
                           start)
              (agent-org-buffer--protect start (point)))))))))

(defun agent-org-buffer--markdown-receive (text)
  "Take one streamed Agent TEXT chunk into this buffer, converting as it arrives.
Nothing waits for a newline: the line still arriving is written as provisional
text and rewritten by the next chunk (`agent-org-buffer--md-tail'), so a
one-line answer that never sends a newline appears AS the agent sends it rather
than all at once when the turn closes.  The rewrite is why the fragment is kept:
a construct split across two chunks (`**bold' + `**') is converted from the
joined string, so it reaches the buffer once, as markup.

Run it in the chat buffer, after the turn's heading exists."
  (let* ((combined (concat agent-org-buffer--md-fragment text))
         (parts (split-string combined "\n"))
         (tail (car (last parts)))
         (done (butlast parts))
         (frozen nil))
    (when done
      (let ((result (agent-org-buffer--markdown-convert-lines
                     done agent-org-buffer--md-src-p)))
        (setq agent-org-buffer--md-src-p (cdr result)
              frozen (car result))))
    (agent-org-buffer--markdown-write
     frozen
     ;; The partial line is converted WITHOUT keeping the state it reports: a
     ;; fence opener seen early would otherwise put the rest of the turn inside
     ;; a code block before its newline ever arrived.
     (when (and tail (not (string-empty-p tail)))
       (car (agent-org-buffer--markdown-line tail agent-org-buffer--md-src-p))))
    (setq agent-org-buffer--md-fragment tail)))

(defun agent-org-buffer--markdown-flush-here ()
  "Freeze the converter's provisional line in this buffer.
The text is already there — streaming writes every chunk — so this ends the
line, closes a fence the agent never closed, and FORGETS the state.  Forgetting
is load-bearing, not tidiness: a provisional region must not outlive a
boundary, because the next chunk would rewrite everything from its marker to
`agent-org-buffer--render-end', which by then holds the drawer drawn here.  So
a paragraph may be split across a drawer, which is what the drawer is for;
nothing is ever rewritten twice.

Called at every boundary that draws below the turn's text — `append-thought',
`insert-tool', `end-agent-turn'."
  (when (or agent-org-buffer--md-fragment agent-org-buffer--md-src-p
            (markerp agent-org-buffer--md-tail))
    (let ((inhibit-read-only t))
      (save-excursion
        (when (markerp agent-org-buffer--md-tail)
          (set-marker agent-org-buffer--md-tail nil)
          (setq agent-org-buffer--md-tail nil))
        (setq agent-org-buffer--md-fragment nil)
        (goto-char (agent-org-buffer--render-end))
        (let ((start (point)))
          (unless (bolp) (insert "\n"))
          (when agent-org-buffer--md-src-p
            (insert "#+end_src\n")
            (setq agent-org-buffer--md-src-p nil))
          (agent-org-buffer--protect start (point)))))))

;;;; Streaming (the hot path)

(defun agent-org-buffer--turn-heading ()
  "The heading text of the Agent turn about to start in this buffer.
With `agent-org-use-model-headings' (the default) that is the model in
force — `agent-org-buffer--model-display', which is the agent's own label
else its id — flattened by `agent-org-buffer--label', because a config
option's `name' is agent text and a newline on a heading line is a broken
headline.  With no model at all (Goose advertises none of this shape) or the
option off, the word is \"Agent\": `* ' alone would be a malformed headline.

Written ONCE, at turn start, and never derived again — which is why no
per-turn model map is needed: the heading text IS the record of which model
answered, and a later `C-c C-m' renames the turns after it and leaves the
older ones alone."
  (or (and agent-org-use-model-headings
           (when-let* ((model (agent-org-buffer--model-display
                               agent-org-buffer--status)))
             (agent-org-buffer--label model)))
      "Agent"))

(defun agent-org-buffer-start-agent-turn (buffer _session)
  "Begin a new Agent heading in BUFFER if one isn't already streaming.
Font-lock stays on for the whole turn so Org colors never vanish while
streaming.  Incremental cost is kept low by the append path, which only
ever fontifies the freshly inserted chunk (see
`agent-org-buffer-append-chunk'), not the whole buffer.

The heading names the model answering, and it reads that from the
buffer-local status — hence the unused SESSION: the two callers that start a
turn without a session in hand (a thought chunk or a tool update arriving
before any chunk did) get the same heading as the streaming path, because
the fact lives with the buffer.

The whole mutation runs in `save-excursion': a turn can start while the
user is mid-sentence in the type-ahead box, and this is one of the
functions that does so — leaving point on the box's anchor would strand
it on the heading's leading separator, where the next keystroke inserts
ABOVE the box instead of inside it."
  (with-current-buffer buffer
    (save-excursion
      (let ((inhibit-read-only t))
        (unless agent-org-buffer--streaming-p
          (goto-char (agent-org-buffer--render-end))
          (agent-org-buffer--separator)
          (let ((beg (point)))
            (insert (format "* %s\n\n" (agent-org-buffer--turn-heading)))
            (agent-org-buffer--protect beg (point))
            (move-marker (setq-local agent-org-buffer--turn-anchor
                                     (make-marker))
                         beg))
          ;; turn-local tool state: the drawer is rebuilt from scratch
          ;; under a new heading, so the previous turn's entries (and any
          ;; reused toolCallId arriving after `resume') start fresh
          (setq agent-org-buffer--streaming-p t
                agent-org-buffer--stream-start (point)
                agent-org-buffer--tools nil
                agent-org-buffer--thought nil
                ;; markdown->org is turn-local too: a held half line from the
                ;; previous turn must not open this one, and a fence left
                ;; unclosed by a truncated reply must not hide this turn's
                ;; text inside a code block.  The provisional tail goes with
                ;; them — it points into the PREVIOUS turn's text, and
                ;; rewriting from there would delete it.
                agent-org-buffer--md-fragment nil
                agent-org-buffer--md-src-p nil
                agent-org-buffer--md-tail nil))))))

(defun agent-org-buffer-end-agent-turn (buffer)
  "Finish the streaming Agent turn in BUFFER.
Font-lock is left as it was -- streaming never turned it off, so there
is nothing to re-enable here.  `save-excursion' for the same reason as
`agent-org-buffer-start-agent-turn': the turn can end under a live
draft, and point belongs with the user, not on the box's anchor."
  (with-current-buffer buffer
    (save-excursion
      (let ((inhibit-read-only t))
        (when agent-org-buffer--streaming-p
          ;; End the line the converter still owns and close a fence the agent
          ;; never closed; the text itself is already in the buffer, so this is
          ;; bookkeeping, not a paint (see the flush's docstring).
          (agent-org-buffer--markdown-flush-here)
          (goto-char (agent-org-buffer--render-end))
          (unless (bolp) (insert "\n"))
          (setq agent-org-buffer--streaming-p nil
                agent-org-buffer--stream-start nil))))))

(defun agent-org-buffer-append-chunk (buffer text session)
  "Append TEXT chunk from agent into BUFFER.
Starts a new Agent heading if not already streaming.

With `agent-org-convert-markdown' (the default) the chunk goes to
`agent-org-buffer--markdown-receive', which converts it and keeps only the last,
still-arriving line provisional — so what the buffer holds is always what the
user reads, and the transcript mirrors that.  Without it the agent's bytes land
verbatim, exactly as this package behaved before the option existed."
  (when (and text (not (string-empty-p text)))
    (agent-org-buffer-start-agent-turn buffer session)
    (with-current-buffer buffer
      (if agent-org-convert-markdown
          (agent-org-buffer--markdown-receive text)
        (let ((inhibit-read-only t))
          (save-excursion
            (goto-char (agent-org-buffer--render-end))
            (let ((beg (point)))
              (insert text)
              (agent-org-buffer--protect beg (point)))))))))

;;;; Auto-folded per-turn structure (tool and thinking drawers)

(defun agent-org-buffer--drawer-safe-lines (text)
  "TEXT as drawer-body lines that cannot re-shape the drawer.
Two shapes that are ordinary in agent text are STRUCTURAL in Org: a line
whose first character is `*' is a headline, and a line reading `:END:'
CLOSES the drawer it is in.  Drawers may contain neither (info \"(org)
Drawers\"), and the parser obeys: measured with `org-element-parse-buffer'
on a drawer holding a `* heading' line, it reports NO drawer at all and two
headlines -- the turn's whole tool state falls out of its fold and into the
body.  `:END:' is matched case-insensitively and leading whitespace does
not save you, so a shell result quoting an Org file can carry every one of
these.  So: indent each line one space (a headline must start at column 0)
and double the leading colon of a bare `:END:' line, which is not the
marker and still reads as the text it is.

Blank lines stay blank -- they are inside a drawer, where the manual says
anything but a headline or another drawer is allowed, and dropping them
would flatten the output's own shape.  This is also why no output is ever
truncated: folding is the affordance, and a record that quietly lost its
middle is worse than a long one."
  (let ((case-fold-search t))
    (mapcar (lambda (line)
              (cond
               ((string-empty-p line) "")
               ((string-match-p "^[ \t]*:END:[ \t]*$" line)
                ;; both guards at once: the space means no line of the body
                ;; ever starts at column 0, the doubled colon means this one
                ;; cannot be read as a marker even by the tolerant match
                (concat " :" (string-trim line)))
               (t (concat " " line))))
            (split-string (string-trim-right text) "\n"))))

(defun agent-org-buffer--live-mark (marker)
  "Position of MARKER, or nil when it points into no buffer.
`mark' is the wrong tool here: it returns nil whenever the region is
inactive, which is nearly always the case for a bookkeeping marker."
  (and (markerp marker)
       (marker-buffer marker)
       (marker-position marker)))

(defun agent-org-buffer--redraw-drawer (buffer name lines &optional fold)
  "Replace the current turn's :NAME: drawer in BUFFER with LINES (list of strings).
Creates the drawer at the end of the turn region when absent -- folded
when FOLD is non-nil, open when it is nil -- and, when the drawer is
already there, swaps the body in place and restores the fold state, so a
drawer the user opened stays open and one they closed stays closed.  FOLD
therefore describes only a drawer that does not exist yet: the
`:thinking:' drawer is born folded (the raw reasoning is not the point of
the turn), the `:tool:' drawer born open (what the agent is DOING right
now is).  The search is bounded by the turn anchor, not the last heading,
because the turn's drawers and body lines all trail that heading.  Fold
state is driven with `org-fold-region' directly:
`org-fold-hide-drawer-toggle' validates the org-element cache, which
is stale for the just-streamed region until it is re-fontified, and
raises \"Not at a drawer\"."
  (with-current-buffer buffer
    (let ((inhibit-read-only t)
          (body (mapconcat #'identity lines "\n")))
      (save-excursion
        (let* ((turn-end (agent-org-buffer--render-end))
               (region-start (or (agent-org-buffer--live-mark
                                  agent-org-buffer--turn-anchor)
                                 turn-end))
               ;; While a turn streams it runs from its anchor to
               ;; `turn-end': the live type-ahead box trails it, so the
               ;; search stops at the box rather than at `point-max'.
               ;; Without a box (a replay) `turn-end' IS `point-max'.
               (drawer-beg
                (save-excursion
                  (goto-char region-start)
                  (when (re-search-forward (format "^:%s:$" name) turn-end t)
                    (match-beginning 0)))))
          (if (not drawer-beg)
              (progn
                (goto-char turn-end)
                (agent-org-buffer--separator)
                (let ((beg (point)))
                  (insert (format ":%s:\n%s\n:end:\n" name body))
                  (agent-org-buffer--protect beg (point))
                  (when fold
                    (goto-char beg)
                    (forward-line 1)
                    (let ((content (point)))
                      (re-search-forward "^:end:$")
                      (org-fold-region content (line-end-position) t 'drawer)))))
            (let* ((content (save-excursion
                              (goto-char drawer-beg)
                              (forward-line 1)
                              (point)))
                   (drawer-end
                    (save-excursion
                      (goto-char content)
                      (re-search-forward "^:end:$")
                      (line-end-position)))
                   (body-end (save-excursion
                               (goto-char drawer-end)
                               (line-beginning-position)))
                   (folded (invisible-p content)))
              (when folded
                (org-fold-region content drawer-end nil 'drawer))
              (delete-region content body-end)
              (goto-char content)
              (insert body "\n")
              (agent-org-buffer--protect content (point))
              (when folded
                (org-fold-region content (line-end-position) t 'drawer)))))))))

(defun agent-org-buffer-append-thought (buffer text)
  "Append thinking TEXT to a folded thinking drawer in BUFFER.
Chunks accumulate in `agent-org-buffer--thought' and the drawer is
re-rendered, bounded to the current turn so each Agent turn keeps its
own drawer."
  (when (and text (not (string-empty-p text)))
    (with-current-buffer buffer
      (unless agent-org-buffer--streaming-p
        (agent-org-buffer-start-agent-turn buffer nil))
      ;; the drawer lands below the turn's text, so freeze the line the
      ;; converter still owns first: a provisional tail must not outlive this
      ;; boundary or the next chunk would rewrite the drawer
      (agent-org-buffer--markdown-flush-here)
      (setq agent-org-buffer--thought
            (concat agent-org-buffer--thought text))
      (agent-org-buffer--redraw-drawer
       buffer "thinking"
       (agent-org-buffer--drawer-safe-lines agent-org-buffer--thought) t))))

(defconst agent-org-buffer--label-width 60
  "Characters of agent-supplied text shown on a single line.")

(defun agent-org-buffer--label (text)
  "Collapse whitespace runs in TEXT and cut it to one short line.
Anything the agent names — a tool call's title, a session title — is
free text about a thing, not an Org heading.  A live qoder session titles
its tool calls with the whole shell command, which is hundreds of
characters over a dozen lines: verbatim, everything after the first
newline falls out of the heading into the body, and the in-place rewrite
of a heading (which replaces one line) shreds the turn around it.
Multi-line text is never lost this way, it just does not get a line of
its own — the full detail is the agent's to keep."
  (let ((flat (mapconcat #'identity
                         (split-string (or text "") "[ \t\n\r]+" t)
                         " ")))
    (if (< (length flat) agent-org-buffer--label-width)
        flat
      (concat (substring flat 0 (1- agent-org-buffer--label-width)) "…"))))

(defun agent-org-buffer--content-block-text (block)
  "Org-ready text for one ACP content BLOCK (the union inside `content').
Only `text' has a real rendering here; a `resource_link' becomes an Org
link, which is what a reader clicks, and an embedded text `resource'
becomes its text.  Anything else is NAMED, in agent-shell's words
(`[unsupported content: TYPE]'), because a silently dropped block reads as
\"the tool printed nothing\" -- and an agent that took a screenshot is not
printing nothing."
  (pcase (map-elt block 'type)
    ("text" (or (map-elt block 'text) ""))
    ("resource_link"
     (let ((uri (map-elt block 'uri))
           (name (map-elt block 'name)))
       (if uri (format "[[%s][%s]]" uri (or name uri)) (or name ""))))
    ("resource"
     (or (map-nested-elt block '(resource text))
         "[unsupported content: resource]"))
    (type (format "[unsupported content: %s]" (or type "unknown")))))

(defun agent-org-buffer--tool-block-text (item)
  "Org-ready text for one ToolCallContent ITEM of a tool call.
ACP's union has three arms -- {type: \"content\", content: <block>},
{type: \"diff\", path, newText}, {type: \"terminal\", terminalId} -- and a
diff is the result of an edit, so it is shown as the file it touches plus
what the file now holds; agent-shell shells out to `diff' for a unified
rendering, which is a nicer picture and a heavier turn.  A block that
skips the union entirely (some agents send the inner text straight) is
handled by the `text' arm, and a terminal -- an agent-shell-only surface
here -- is named rather than dropped."
  (let ((type (map-elt item 'type)))
    (cond
     ((map-elt item 'content)
      (agent-org-buffer--content-block-text (map-elt item 'content)))
     ((equal type "diff")
      (format "diff %s\n%s"
              (or (map-elt item 'path) "?")
              (or (map-elt item 'newText) "")))
     ((map-elt item 'text) (map-elt item 'text))
     (t (format "[unsupported content: %s]" (or type "unknown"))))))

(defun agent-org-buffer--tool-output (update)
  "The output text tool UPDATE carries, or \"\" when it carries none.
The spec files a call's result under `content'; `rawOutput' is
agent-defined free JSON, and Codex answers through
`rawOutput.formatted_output' while leaving `content' empty -- so reading
only the spec's field shows a completed shell call that printed nothing.
A non-string `formatted_output' (a number, an object) is not text, so it
is no output.  Same order as agent-shell's
`agent-shell--tool-call-update-output-markdown', which is the parity the
user asked for: \"Please look into agent-shell on how it handles
responses.\""
  (let ((text (mapconcat #'agent-org-buffer--tool-block-text
                         (append (map-elt update 'content) nil)
                         "\n\n"))
        (raw (map-nested-elt update '(rawOutput formatted_output))))
    (cond ((not (string-empty-p text)) text)
          ((stringp raw) raw)
          (t ""))))

(defun agent-org-buffer--tool-output-body ()
  "This turn's `:tool-output:' drawer body: one item per call that printed.
The whole turn shares ONE drawer for what its calls printed (the user's
order: \"Consecutive tool calls belong to a single drawer\"), so a call is
named by its TITLE -- the same title the board above shows -- and no number
is needed to point from one to the other.  Built from
`agent-org-buffer--tools', like the board, so the drawer cannot drift from
the record and a call that reported nothing simply has no item.

Each output goes through `agent-org-buffer--drawer-safe-lines' and takes one
further space of indent, which is what puts it under its `- TITLE' item as
that item's contents rather than as loose drawer text.  The title is
flattened by `agent-org-buffer--label' for the same reason the board line
is: agent titles are whole shell commands."
  (let (lines)
    (dolist (entry agent-org-buffer--tools)
      (let ((output (plist-get (cdr entry) :output)))
        (when (and output (not (string-empty-p output)))
          (push (format "- %s"
                        (agent-org-buffer--label
                         (or (plist-get (cdr entry) :title) "tool")))
                lines)
          (dolist (line (agent-org-buffer--drawer-safe-lines output))
            (push (if (string-empty-p line) "" (concat " " line)) lines))
          (push "" lines))))
    (nreverse lines)))

(defun agent-org-buffer-insert-tool (buffer content)
  "Record the tool call or update CONTENT: one status line, plus its output.
CONTENT is the tool-call alist from the ACP notification.  Each
toolCallId owns exactly one line `- KEYWORD title' of the current turn's
`:tool:' drawer, KEYWORD mapping the ACP status onto the per-file TODO set
(`agent-org-buffer--todo-setup').  No number: it existed only as the index
into a per-call output drawer, and those are gone.  Later updates overwrite
the stored title/status and the WHOLE drawer is redrawn from
`agent-org-buffer--tools', so an id can never sprout a second line and no
per-call marker can go stale -- the list is the record, its order the order
the agent made the calls.  The id never appears on the line: it is the
agent's bookkeeping, and the entry looked up under it already owns the line.

LINES, not headings: Org forbids headlines inside drawers (info \"(org)
Drawers\"), so a call that wants to sit in a `:tool:' drawer cannot be a
`**' heading.  That is the user's order -- \"Tool calls should be inside
:tool: drawers\" -- and the reason `**' disappeared from the turn: the
Agent heading is now the turn's only heading, and its tool calls fold
open beside a folded `:thinking:' drawer.

What the call PRINTED goes into one further drawer for the turn,
`:tool-output:' (`agent-org-buffer--tool-output-body'), folded, where each
call is a `- TITLE' item with its output indented under it.  It cannot join
the status board for the reason the calls cannot be headings in it: a drawer
holds no other drawer, and one fold state for the whole board would mean
either hiding the live status lines or flooding the chat with a `cat' of a
file -- agent-shell's own default for tool output is collapsed
(`agent-shell-tool-use-expand-by-default' nil).  A call that reports no
output gets no item."
  (let ((id (map-elt content 'toolCallId))
        (title (or (map-elt content 'title) (map-elt content 'toolName)))
        (status (map-elt content 'status)))
    (when id
      (with-current-buffer buffer
        (unless agent-org-buffer--streaming-p
          (agent-org-buffer-start-agent-turn buffer nil))
        ;; same reason as the thought drawer: the board is drawn below the
        ;; turn's text, so a line still in the converter must go in first
        (agent-org-buffer--markdown-flush-here)
        (let ((entry (cdr (assoc id agent-org-buffer--tools))))
          (unless entry
            ;; every key pre-exists so `plist-put' below always mutates in
            ;; place: it only prepends -- returning a NEW list -- when a
            ;; key is absent, and `entry' here would keep the old one.
            (setq entry (list :title nil :status nil :output nil :shown nil)
                  agent-org-buffer--tools
                  (append agent-org-buffer--tools (list (cons id entry)))))
          (when title (plist-put entry :title title))
          (when status (plist-put entry :status status))
          ;; last non-empty report wins, the way agent-shell patches a
          ;; stored call: an update that carries no `content' is a status
          ;; change, not a rewrite of what the tool printed
          (let ((output (agent-org-buffer--tool-output content)))
            (unless (string-empty-p output) (plist-put entry :output output)))
          ;; render-time fallbacks, never stored, so a title-less update
          ;; cannot downgrade the title; the label is flattened because a
          ;; drawer entry is one line
          (agent-org-buffer--redraw-drawer
           buffer "tool"
           (mapcar (lambda (e)
                     (format "- %s %s"
                             (agent-org-buffer--tool-keyword
                              (plist-get (cdr e) :status))
                             (agent-org-buffer--label
                              (or (plist-get (cdr e) :title) "tool"))))
                   agent-org-buffer--tools))
          (let ((output (plist-get entry :output)))
            ;; `:shown' is the redraw guard, and it matters more now the
            ;; bodies share a drawer: a status change would otherwise rewrite
            ;; and re-protect every byte the turn's calls ever printed
            (when (and output (not (equal output (plist-get entry :shown))))
              (plist-put entry :shown output)
              (agent-org-buffer--redraw-drawer
               buffer "tool-output" (agent-org-buffer--tool-output-body) t))))))))

;;;; Transcript file

(defcustom agent-org-transcribe t
  "When non-nil, each chat session is mirrored to its own Org file.
One file per session, named for its ACP session id, rewritten at every
turn boundary.  Off, no file is created and no disk is touched: a chat
whose transcript is a real org file under version control does not want
a second copy appearing behind it.

The file is a MIRROR of the buffer, not an append log.  That choice is
forced by the tool drawer: its line for one call is rewritten in place
TODO→DOING→DONE, so an append-only log would keep every superseded
state of every call in the file, and the transcript would be a
different document from the chat that produced it.  Mirroring means one
renderer — the buffer — and the file simply agrees with it."
  :type 'boolean
  :group 'agent-org-buffer)

(defcustom agent-org-transcript-directory ".agent-org"
  "Where the per-session Org transcripts go, relative to the chat's project.
The default is a RELATIVE directory name, and a relative name is resolved
against the chat buffer's `default-directory' — the session's cwd — so
every project keeps its own chats in its own `.agent-org/', the way it
keeps its own README.  Set an absolute path for one global pool instead;
anything with `~' in it expands as Emacs usually does.

A project directory is where a person looks for the record of a chat in
that project, which is why this default replaced a path under
`~/.emacs.d'.  The cost is that transcripts now sit inside a repo, so
`.agent-org/' is a line worth adding to its `.gitignore' unless the
transcripts are notes you want committed."
  :type 'directory
  :group 'agent-org-buffer)

(defun agent-org-buffer--transcript-name (session-id)
  "File name of SESSION-ID's transcript: the sanitized id, then `.org'.
The id is the only fact about a chat that survives a rename, a title
change and a restart, so it is what maps a file to a session — and it
doubles as the Org `:ID:' the metadata block already puts in the same
file, which makes every transcript an `id:=-linkable document.

The id arrives over the wire, so it is not a file name yet: every
character outside `A-Za-z0-9._-' becomes a dash.  Qoder sends UUIDs and
Goose timestamps, but nothing in the ACP spec says the next server will
not send `../../etc/passwd' — without this the writer is a
path-traversal primitive handed to whatever agent the user connects to."
  (concat (replace-regexp-in-string "[^A-Za-z0-9._-]" "-" session-id t t)
          ".org"))

(defvar-local agent-org-buffer--transcript-cache nil
  "The exact text last written to this buffer's transcript file.
A boundary can fire with nothing new — a repeated title push, a second
Ready, a usage update that changed the header but not the conversation —
and the write is a whole-file `write-region'.  Comparing against what was
last put there skips those, and keeps the file's mtime honest: an
untouched transcript does not look like it was edited.")

(defun agent-org-buffer-transcribe (buffer)
  "Mirror BUFFER's conversation to its transcript file, when it changed.
The mirror is the frozen body — `point-min' to
`agent-org-buffer--render-end' — which is exactly the conversation and
nothing else: the same marker that keeps a streaming turn from
scribbling over the user's draft separates \"sent\" from \"still
typing\", so a draft that was never taken never reaches the file.  The
metadata block is inside that range, which is how the `:QUEUE:' drawer —
prompts the user sent into a busy session, so not conversation
yet — comes along.

Called from turn boundaries and from the queue's own mutations (see
agent-org.el), never from a render site: twenty chunks of an answer cost
no writes, so a slow disk cannot stall a stream.  No-op with
`agent-org-transcribe' nil, or before the agent has given the session an
id."
  (when (and agent-org-transcribe (buffer-live-p buffer))
    (with-current-buffer buffer
      (let ((session-id (plist-get agent-org-buffer--status :session-id)))
        (when session-id
          (let ((text (buffer-substring-no-properties
                       (point-min) (agent-org-buffer--render-end))))
            (unless (equal text agent-org-buffer--transcript-cache)
              (agent-org-buffer--write-transcript session-id text))))))))

(defun agent-org-buffer--transcript-file (session-id)
  "Path of SESSION-ID's transcript, resolved against THIS buffer's project.
`agent-org-transcript-directory' is a relative name by default, and
`expand-file-name' is what turns that into \"the chat's own directory\":
called with the chat buffer current, `default-directory' is the session cwd
the buffer was created in.  An absolute setting expands to itself, so one
global pool is still a setting away rather than a code change."
  (expand-file-name (agent-org-buffer--transcript-name session-id)
                    (file-name-as-directory
                     (expand-file-name agent-org-transcript-directory))))

(defun agent-org-buffer-transcript-queue (session-id)
  "The prompts SESSION-ID's transcript has waiting, oldest first; nil if none.
Resume needs this because a queued prompt was never sent: it is in none of
the places a restore normally finds text — not the agent's `session/load'
replay (the agent never saw it), not the buffer (a fresh one), not a
`* User' heading.  The drawer the last session mirrored is the only copy
that survives.

Called with the chat buffer current, so the file resolves against the same
project the writer used — looking in the wrong directory would silently
restore nothing.

nil is the ordinary answer: no file (`agent-org-transcribe' off, or a
session older than the feature), no drawer, or an empty one.  An unreadable
file is nil too: a transcript is a convenience, and one that cannot be read
must not stop a session loading."
  (when session-id
    (let ((file (agent-org-buffer--transcript-file session-id)))
      (when (file-readable-p file)
        (condition-case nil
            (with-temp-buffer
              (insert-file-contents file)
              (goto-char (point-min))
              (when (re-search-forward "^:QUEUE:[ \t]*\n" nil t)
                ;; the body is one line per prompt, up to BUT NOT INCLUDING
                ;; the `:END:' line — `re-search-forward' returns a match's
                ;; END, so the region has to stop at `match-beginning'.
                (let ((beg (point)))
                  (when (re-search-forward "^:END:[ \t]*$" nil t)
                    (mapcar #'agent-org-buffer--queue-decode
                            (split-string
                             (buffer-substring-no-properties
                              beg (match-beginning 0))
                             "\n" t))))))
          (file-error nil))))))
(defun agent-org-buffer--write-transcript (session-id text)
  "Replace this buffer's transcript file with TEXT.
Called with the chat buffer current, which is what gives
`agent-org-buffer--transcript-file' its project.
VISIT is nil on purpose: a non-nil one would make the chat buffer
`visit' the transcript, and then `C-x s' would save the live draft into
it and auto-save would follow.  `buffer-substring-no-properties' already
stripped the faces, so what lands is plain Org.

A failure is a note in the echo area and nothing more.  The transcript is
a convenience; the conversation is the feature — a full disk, or a project
directory the user has no write bit on, must not break a turn.  The cache
is left untouched, so the next boundary tries again."
  (let ((file (agent-org-buffer--transcript-file session-id)))
    (condition-case err
        (progn
          (make-directory (file-name-directory file) t)
          (write-region text nil file nil)
          (setq agent-org-buffer--transcript-cache text))
      (file-error
       (message "agent-org: transcript not written (%s): %s"
                file (error-message-string err))))))

(provide 'agent-org-buffer)
;;; agent-org-buffer.el ends here
