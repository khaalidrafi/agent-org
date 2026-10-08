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
;; Tool calls render as ONE `:tool:' drawer under the current `* Agent'
;; heading: each call is a list item `  - KEYWORD title' indented two
;; columns, using the per-file keyword set declared by the metadata block
;; (`#+TODO: TODO ONGOING | COMPLETE FAILED'): pending→TODO,
;; in_progress→ONGOING, completed→COMPLETE, failed→FAILED.  Thoughts keep
;; the folded :thinking: drawer, drawn by the same primitive; the tool
;; drawer is OPEN -- created open and repainted open, so no fold of Org's
;; own can leave the turn's activity hidden -- and the thought drawer
;; FOLDED, keeping whatever fold the user left it in.  A drawer can hold no
;; headings, which is why a call is an item line and not a `**'.
;;
;; What a call PRINTED is the SAME item's body, indented four columns: the
;; user's order was "Tool call outputs belong to the same TODO headings",
;; after "Consecutive tool calls belong to a single drawer" — a separate
;; `:tool-output:' drawer made a reader match a title in the board to the
;; same title below it, and it split one call's state and its result across
;; two folds.  One list, one item per call.  Every drawer body goes through
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
;;     this buffer's frozen body, plus the queue block below it, rewritten
;;     at turn boundaries — not an append log.  One renderer, so the file
;;     can never disagree with the chat: a tool line that changed
;;     TODO→COMPLETE in place is COMPLETE in the file, and twenty chunks of
;;     an answer cost no writes at all.
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

;;;; Lite mode (the minimum-resources scope)

(defcustom agent-org-lite-mode nil
  "When non-nil, every chat runs LITE: the minimum resources, honestly named.
This is the GLOBAL scope; a session that sets its own scope overrides it
(see `agent-org-lite-mode-toggle').  Lite is not a rendering change and never
hides conversation: it drops the three costs a chat pays for machinery nobody
is reading, and nothing else.

- No transcript write, except the one that carries something irreplaceable: a
  queued prompt exists in no other place, so a lite session writes its file
  while its queue is non-empty and stops the moment the queue drains.
- No undo records.  A chat body is generated text plus one live prompt box;
  nobody edits the transcript, so the undo list was pure memory, and on a
  long chat it is the largest thing in the buffer.
- No whole-buffer Org reparse per metadata rebuild.  The rebuild happens on
  every usage update, and `org-set-regexps-and-options' re-reads the WHOLE
  buffer; the block's `#+TODO:' line has to be parsed once, and a lite
  session parses it once (see `agent-org-buffer--todo-live-p').

What lite deliberately does NOT do, because each of these is a fact about the
conversation rather than a decoration: font-lock (turning it off is the
one-way door of CONVENTIONS.md 16, and colors are the reader's own map), the
`:thinking:' and `:tool:' drawers (an agent's reasoning and its calls are the
transcript), and Markdown conversion (it is ~110 us per markup-dense line
against a network fetch measured in seconds)."
  :type 'boolean
  :group 'agent-org-buffer)

(defvar-local agent-org-buffer--lite 'inherit
  "This session's lite-mode scope: `inherit', `on' or `off'.
A chat buffer IS a session, so the per-session scope is a buffer-local
variable and dies with the buffer.  `inherit' follows `agent-org-lite-mode';
`on' and `off' pin this session against it, which is what makes \"lite for
the one chat that is filling the disk, full for the rest\" sayable without
editing an init file.  Three states rather than two because \"follow the
global setting\" has to be reachable again after an override.")

(defun agent-org-lite-p (&optional buffer)
  "Non-nil when BUFFER's session runs in lite mode; BUFFER defaults to current.
The ONE reader of the scope: `agent-org-buffer--lite' is a scope, not a
setting, so every place that acts on lite reads this and nothing reads the
variable directly."
  (let ((scope (if buffer
                   (with-current-buffer buffer agent-org-buffer--lite)
                 agent-org-buffer--lite)))
    (cond ((eq scope 'inherit) agent-org-lite-mode)
          ((eq scope 'on) t)
          (t nil))))

(defun agent-org-buffer--lite-word (buffer)
  "How BUFFER's lite scope should be READ: \"Lite\", \"Full\" or \"·\".
The monitor's MODE column and the toggle's message both want one short word
for a three-valued scope, and \"·\" (no scope of its own) is what `inherit'
looks like next to the other two.  A DEAD buffer has no scope at all, which
is also the dot."
  (if (not (buffer-live-p buffer))
      "·"
    (pcase (with-current-buffer buffer agent-org-buffer--lite)
      ('on "Lite")
      ('off "Full")
      (_ "·"))))

(defun agent-org-lite-mode-toggle (&optional global)
  "Cycle this session's lite scope; with GLOBAL, flip the global default.
The scope cycles `inherit' → `on' → `off' → `inherit' and says which it
landed on, because a scope with three values cannot be a silent toggle: a
binary one would leave \"follow the global setting\" unreachable once a
session had been overridden, and a chat that quietly stopped recording its
transcript is the kind of thing a person only notices later.

With a prefix argument, GLOBAL is non-nil and the cycling happens on
`agent-org-lite-mode' instead: every session still on `inherit' follows at
once, and the message says so, because that is the only part of the effect
the command can promise.  Run on the session you want to keep lean."
  (interactive "P")
  (if global
      (setq agent-org-lite-mode (not agent-org-lite-mode))
    (setq agent-org-buffer--lite
          (pcase agent-org-buffer--lite
            ('inherit 'on)
            ('on 'off)
            (_ 'inherit)))
    ;; undo recording is the resource the toggle owns outright, so the
    ;; toggle owns it: a session that becomes lite stops accumulating undo
    ;; entries and one that becomes full starts again.  Turning it off
    ;; discards nothing a person wrote, because a chat body is read-only
    ;; text outside the prompt box.
    (setq buffer-undo-list (agent-org-buffer--record-undo-p)))
  (message "agent-org: %s"
           (if global
               (format "lite mode is %s — a session with its own scope is unaffected"
                       (if agent-org-lite-mode "ON" "OFF"))
             (pcase agent-org-buffer--lite
               ('on "this session is LITE (minimum resources)")
               ('off (format "this session is FULL (the global setting is %s)"
                             (if agent-org-lite-mode "ON" "OFF")))
               (_ (format "this session follows the global setting, which is %s"
                          (if agent-org-lite-mode "ON" "OFF")))))))

(defun agent-org-buffer--record-undo-p ()
  "Non-nil when this buffer should record undo entries.
The VALUE a `buffer-undo-list' binding wants, which is why it is a function
and not a variable: the replay and the queue render each bind
`buffer-undo-list' around a bulk insertion, and a lite session has to bind
nil there or one resume rebuilds the very undo list the mode exists to
avoid.  Two call sites would otherwise each re-derive the rule."
  (not (agent-org-lite-p)))

(defvar-local agent-org-buffer--todo-parsed nil
  "Non-nil once this buffer's `#+TODO:' line has been parsed into keywords.
Our own flag rather than Org's `org-todo-keywords-1', which lives in
org-agenda.el -- a package this one does not require for the sake of one
read.  What it answers is the only question a metadata rebuild has: does the
file's keyword set still need reading?  After the first parse it does not,
and `org-set-regexps-and-options' re-reads the WHOLE buffer (see
`agent-org-lite-mode').")

(defun agent-org-buffer--todo-live-p ()
  "Non-nil when this buffer's tool-call keyword set has already been parsed.
The board's `  - KEYWORD title' lines carry the file's own TODO words, and
those words reach Org through exactly one parse of the `#+TODO:' line in the
metadata block.  One parse is enough for the life of the buffer: a chat body
is read-only text, `C-c C-t' is bound to `agent-org-buffer--blocked' in a chat
buffer, and the line itself is rewritten byte-identically by every rebuild."
  agent-org-buffer--todo-parsed)

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

(defcustom agent-org-response-prefix t
  "When non-nil, an answer is introduced by a line naming who answered it.
The line reads \"MiniMax M3: \" --- the model in force, the agent's own label
else its id --- and the answer streams under it, the way agent-shell prefixes
each response with the model that produced it.  Which model answered is a fact
about the transcript, and the header line that says so is gone the moment the
buffer is buried or the file is re-read a week later.

It replaced `#+ATTR_TEXINFO: :author NAME' above a `#+begin_quote', which was
the Org manual's own way to attribute a quotation, when the user ended the
quotation (\"No more quote blocks.  Just use model name as prefix\"): the same
fact, in a shape that costs nothing.  With no model reported at all (Goose
advertises none of this shape), or with this option nil, the word is \"Agent\".

The heading is the user's question, so this line is the only place the
answer's provenance lives.  It is written once, when the answer starts, so a
later `C-c C-m' renames the NEXT answer and leaves the older ones alone."
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
to be sent, oldest first, as the session holds them.  They are the queue
region's headlines at the bottom of the chat, and
`agent-org-buffer-transcribe' mirrors that block into the transcript even
though it is below the conversation, which is how a prompt the user typed
but never sent survives, and how resume finds it again (see
`agent-org-buffer-transcript-queue').

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
(defconst agent-org-buffer--todo-setup
  "#+TODO: TODO RESPONDING IDLE | RESPONDED ERROR"
  "Per-file keyword set (`org-set-regexps-and-options' reads it from
 the metadata block) naming the states of a PROMPT -- the only headlines this
 package writes, and so the only words that have to be real Org states.

The user's own vocabulary, in his words: a queued prompt is TODO, the agent is
answering it RESPONDING, a turn that stopped and waits on HIM (a permission
request, a plan to approve) is IDLE, and past the bar a prompt is either
RESPONDED or ERROR.  Three before the bar because all three are unfinished
work, two after because a prompt ends in exactly those two ways.

The tool-call words are NOT declared here, on purpose.  A call is a line of
the `:tool:' drawer rather than a heading -- Org forbids headlines inside
drawers -- so its ONGOING, COMPLETE and FAILED are TEXT a reader sees, never a
state `C-c C-t' can cycle (that acts on headlines).  Declaring them would put
a call's words on the same completion list as a prompt's and let somebody mark
a prompt COMPLETE, which is the wrong verb: a prompt is answered or it fails.")

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
  "Marker at the start of the current exchange's heading, if any.
The heading's text is the user's prompt, and one heading covers the whole
prompt-response pair.  The pair's drawers are located relative to this
anchor, not to the buffer end, because the body trails it: the answer's
quote block, the `:thinking:' drawer, the `:tool:' drawer and the
type-ahead box all live after the heading, so the heading is never the
last thing in the turn.")

(defvar-local agent-org-buffer--quote-end nil
  "Marker at the END of this turn's answer, or nil when no answer is open.
Rear-advancing, so text inserted AT it -- which is where every chunk and every
drawer of this turn lands -- pushes it down instead of staying behind inside the
body.  It is what keeps a `:tool:\` drawer or a `:thinking:\` line below the
answer when the two arrive in the other order, and with the quote block gone it
is the ONLY thing holding that order (before, `#+end_quote' began its own line
and did the same job by structure; measured: that line also meant an agent could
end the block with a line of its own, which cost a guard on every reply line).

Named for what it replaced rather than for what it does now: `--text-end' is
the function that reads it, and the suffix is the answer's end either way.")

(defvar-local agent-org-buffer--awaiting-answer-p nil
  "Non-nil when this buffer's last heading is a question with no answer yet.
`agent-org-buffer-begin-exchange' sets it and `start-agent-turn' clears it.
The flag is what keeps ONE heading per pair: an answer arriving under it
joins that heading, while a chunk arriving with nothing to answer -- an
orphan in `session/load' history -- has to open a heading of its own rather
than write into the previous exchange.")

(defvar-local agent-org-buffer--turn-start nil
  "Lisp time of the moment the current exchange's prompt went out.
Taken by `agent-org-buffer-begin-exchange' and SPENT by
`agent-org-buffer--close-response-clock' at the turn boundary, which writes
the exchange's `CLOCK:' line and `:RESPONSE:' property from it.  Spending it
is what makes a second boundary call a no-op: the response time of one
prompt is one measurement, and a late callback after the boundary (a second
`end-agent-turn', a success that arrives after the next question opened)
must not file a second clock under a heading that already has its own.
nil between turns and after any close — which is also why an ORPHAN turn
(an answer with no prompt) gets no clock: there is no sent moment to
measure from.  `current-time', never the wire: the protocol timestamps
nothing the client could trust anyway.")

(defvar agent-org-buffer--record-clock-p t
  "Whether an exchange opening in this pass records a response clock.
Bound to nil around the resume-replay paint in
`agent-org--render-replay', because a restored session carries no timing to
invent: `session/load' stamps when history was REPLAYED, not when the answer
took, and a `CLOCK:' line computed from those moments would be a fabricated
measurement filed among the real ones.  A dynamic binding, not a
`defvar-local': the replay paints synchronously in one pass with no process
output interleaving, and `let' on a plain special is how a caller suppresses
one render without touching the buffer's state.")

(defvar-local agent-org-buffer--tools nil
  "Alist ((ID . PLIST) ...) of the current Agent turn's tool calls.
PLIST is (:title T :status S :output O); each ID owns ONE item of the
turn's `:tool:' drawer -- `- KEYWORD title' with what it printed indented
under it.  The whole drawer is redrawn from this list on every update
(`agent-org-buffer-insert-tool'), so no marker per call: the list IS the
record, and its order is the order the agent made the calls, which is also
the order the bodies appear in.")

(defvar-local agent-org-buffer--tools-shown nil
  "The rendered body of the turn's `:tool:' drawer, as last painted.
The redraw guard now that one drawer holds both the status lines and the
output: `agent-org-buffer-insert-tool' builds the whole body, compares it
with this, and paints only a difference.  A per-entry `:shown' could not
say the same thing -- an update that changes one keyword rewrites every
byte of a shared drawer anyway, so the guard has to be on the DRAWER.
Reset with `agent-org-buffer--tools' at each new turn.")

(defvar-local agent-org-buffer--tool-group-start 0
  "Index into `agent-org-buffer--tools' where the LIVE `:tool:' drawer begins.
Activity order is the user's rule -- \"Activity order MUST be kept.  New :tool:
calls should always appear at the end of response, not a previous drawer.\" --
and what separates two runs of calls is any NON-tool activity, from their own
earlier order: \"The order of tool call and response/thinking separates them.
Activity order gets precedence.\"

So the RECORD is one list for the whole turn (`agent-org-buffer--tools', in call
order) and each `:tool:' drawer is a WINDOW on it, starting at this index.
`agent-org-buffer--seal-tool-board' advances the window past the calls that ran
so far when the agent says or thinks something, and the next call opens a fresh
drawer below everything written since.  Before this the board was created once
per turn and every later call was repainted into it, so a call made after the
agent had moved on was displayed ABOVE the words and thoughts that preceded it
and the transcript read the turn backwards.")

(defvar-local agent-org-buffer--tool-drawer-live-p nil
  "Non-nil when this turn's live `:tool:' drawer is still at the turn's end.
It is what makes the next tool call REUSE the open drawer instead of opening a
second one: `agent-org-buffer-insert-tool' passes FRESH to
`agent-org-buffer--redraw-drawer' exactly when this is nil.  A drawer sealed by
`agent-org-buffer--seal-tool-board' is closed for business -- it keeps its text
and its fold, but it is no longer where new calls go.")

(defvar-local agent-org-buffer--thought nil
  "Thinking text accumulated for the current Agent turn, rendered into
the per-turn :thinking: drawer by `agent-org-buffer-append-thought'.")

(defvar-local agent-org-buffer--answer-written-p nil
  "Non-nil once this turn's answer has had a line of text appended.
Set by `agent-org-buffer--advance-text-end' -- the one place answer text moves
the insertion marker -- and cleared when the turn state resets.  It is how
`agent-org-buffer--drop-empty-response' tells an answer that only ever streamed
tools from one that said something: the marker has moved on by the time the turn
closes, so \"is the line under the marker blank\" is no longer a test for
emptiness (with real text it now points at the gap above a drawer, and that gap
reads blank) -- the flag is the direct record of whether any prose landed.")

;;;; Forward declaration

(declare-function agent-org-send "agent-org" ())
(declare-function agent-org-set-session-model "agent-org" (model))
(declare-function agent-org-queue-edit "agent-org" ())
(declare-function agent-org-queue-resume "agent-org" ())
(declare-function agent-org-cancel-turn "agent-org" ())

;;;; Status updates

(defun agent-org-buffer--wanted-name ()
  "The buffer name this buffer's session facts call for.
A chat buffer is the session: `C-x b' and the switcher list its name, so
the name is `<agent>:<project> [<session id>]' — which harness answers,
the project directory it is a chat OF, then the ACP id the wire addresses
it by.

The session TITLE is deliberately not in it.  A title is what the chat is
about and it arrives late, changes on its own (`session_info_update'), and
is agent free text; a buffer whose name mutates mid-read is worse than one
that never described the topic, and the user asked for the agent by name:
\"Buffer names are showing session names in place of agent names.\"  The
title is not lost — it is the `#+TITLE:' of the buffer and of its
transcript, and the resume chooser reads it from `session/list'.

No `agent-org: ' prefix and no `*…*' delimiters: the user asked for the
name to BE the chat, and the package's own name costs a chat its place in
`C-x b', where `*agent-org: …*' sorts together with everything else in the
product rather than with the project it belongs to.

The `<agent>:<project>' part is `agent-org-buffer--chat-label', which
`agent-org-switch-buffer' builds its first column from as well: one chat,
one display label, wherever it is shown."
  (let* ((status agent-org-buffer--status)
         (sid (plist-get status :session-id)))
    (format "%s%s"
            (agent-org-buffer--chat-label status)
            (if sid (format " [%s]" sid) ""))))

(defun agent-org-buffer--chat-label (status)
  "The display label of the chat described by the status plist STATUS.
`<agent>:<project>': the provider that owns the session, then the
directory the chat was started in after the colon.  The idiom is the one
Emacs users already read as \"thing it is a buffer OF\" (`file:directory'
in the buffer menu) and the one the user asked for by name
(`Qoder:agent-org [SESSION_ID]').  The project still has to be IN the
name: measured live, a session in this repo and a session in org-docs
produced two switcher rows identical but for their UUIDs while `C-x b' was
already telling them apart.

Only `:provider' and `:project' are read, and `agent-org' is the fallback
if even the provider is missing; nothing here is agent-supplied text, so
no label filter is needed and none is applied.  Flattening and truncation
stay `#+TITLE:', quote-author and header-line concerns.

STATUS is a parameter, not a read of `agent-org-buffer--status': the
switcher labels OTHER buffers, and a function that is only correct when
called in the right buffer is a bug waiting for the next caller."
  (let ((project (plist-get status :project))
        (label (or (plist-get status :provider) "agent-org")))
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

A `:session-id' in STATUS also re-names the buffer: the provider and the
project are fixed when the buffer is created, so the id is the only half
of a name that ever arrives later.  A usage, state or `:title' update does
no string building and no rename — the title is what the chat is ABOUT,
and the name says which harness answers it."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (dolist (key '(:provider :state :message :note :session-id :model :model-name
                         :mode :project :title :used :size :tokens :cost-amount
                         :cost-currency :commands :modes-list :config :queued))
        (when (plist-member status key)
          (setq agent-org-buffer--status
                (plist-put agent-org-buffer--status key (plist-get status key)))))
      (when (plist-member status :session-id)
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

(defun agent-org-buffer--queue-only (up)
  "Move the queued prompt at point one place, up when UP is non-nil.
THE DISPATCH that lets one key be two commands: inside the queue region
`M-UP'/`M-DOWN' reorder the user's own prompts, and everywhere else they stay
`agent-org-buffer--blocked'.  A chat buffer refuses Org's structure commands
because they would cut the CONVERSATION's heading boundaries apart (a headline
is what locates a turn), but the queue region is the user's text at the bottom
and moving it is the one structural act they need -- so the block is narrowed
by point rather than lifted.

Both directions go through the same function on purpose: a key that moves only
up in the region and only refuses out of it would be a key with two unrelated
meanings, and the region test is the only thing that tells them apart."
  (if (agent-org-buffer--queue-at-p)
      (agent-org-buffer-queue-move (current-buffer) up)
    (agent-org-buffer--blocked)))

(defun agent-org-buffer-queue-move-up ()
  "Move the queued prompt at point one place towards the front of the queue."
  (interactive)
  (agent-org-buffer--queue-only t))

(defun agent-org-buffer-queue-move-down ()
  "Move the queued prompt at point one place further back in the queue."
  (interactive)
  (agent-org-buffer--queue-only nil))

(defun agent-org-buffer-queue-add ()
  "Add a blank queued prompt at the bottom of this buffer, and go to it.
`C-c C-a' in a chat, which is the user's own \"add one here\" -- the same
gesture the queue editor offered as an entry command.  Point lands inside the
new entry, because a slot nobody is looking at is not a slot."
  (interactive)
  (goto-char (agent-org-buffer-queue-insert-entry (current-buffer)))
  (message "[agent-org] new queued prompt; type it, then M-x agent-org-queue-apply"))

(defun agent-org-buffer-queue-kill ()
  "Kill the queued prompt at point in this buffer."
  (interactive)
  (agent-org-buffer-queue-kill-entry (current-buffer)))

(defvar agent-org-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'agent-org-send)
    (define-key map (kbd "C-c C-m") #'agent-org-set-session-model)
    (define-key map (kbd "C-c C-q") #'agent-org-queue-edit)
    (define-key map (kbd "C-c C-r") #'agent-org-queue-resume)
    (define-key map (kbd "C-c C-k") #'agent-org-cancel-turn)
    (define-key map (kbd "C-c C-l") #'agent-org-lite-mode-toggle)
    (define-key map (kbd "C-c C-a") #'agent-org-buffer-queue-add)
    (define-key map (kbd "C-c C-d") #'agent-org-buffer-queue-kill)
    ;; the two movers, as named commands rather than lambdas: an autoloaded
    ;; keymap entry pointing at an anonymous function is not loadable
    ;; Org structure commands bypass `read-only' text properties and would
    ;; corrupt heading boundaries; block them all.  M-UP/M-DOWN are the two
    ;; exceptions, and only inside the queue region -- see
    ;; `agent-org-buffer--queue-only'.
    (dolist (key (list (kbd "M-RET") (kbd "C-c C-t")
                       [(meta left)] [(meta right)]
                       [(shift up)] [(shift down)]
                       (kbd "C-c -")))
      (define-key map key #'agent-org-buffer--blocked))
    ;; `[(meta up)]' and not `(kbd "M-UP")': the kbd parser wants ONE
    ;; character after a modifier and reads "UP" as two, so the modifier
    ;; prefix error is raised at LOAD time -- in a keymap, which every
    ;; chat buffer evaluates.
    (define-key map [(meta up)] #'agent-org-buffer-queue-move-up)
    (define-key map [(meta down)] #'agent-org-buffer-queue-move-down)
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
  C-c C-l  Cycle this session's lite scope (C-u: the global one)
  C-c C-m  Switch the session's model
  C-c C-q  Go to the prompts waiting in this session's queue
  C-c C-a  Add a queued prompt at the bottom
  C-c C-d  Kill the queued prompt at point
  M-UP / M-DOWN  Reorder the queued prompt at point (in the queue only)"
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
        ;; Lite mode is seeded here, where the buffer is still empty: the
        ;; mode has to apply to the whole life of the chat, not from the
        ;; first toggle onward.  Only the value is set, because the
        ;; variable is a SCOPE (see `agent-org-buffer--lite') and the
        ;; mode is not its owner — `agent-org-lite-mode-toggle' is, and it
        ;; moves the value as the scope changes.
        (setq buffer-undo-list (agent-org-buffer--record-undo-p))
        ;; Org re-hides EVERY drawer when a buffer's visibility is set --
        ;; `org-cycle-set-startup-visibility' ends with that call
        ;; (org-cycle.el:643) and mode startup runs it, as does the
        ;; prefixed `org-cycle-global'.  A board this package opened would
        ;; therefore fold itself again behind the user, so the fold is
        ;; decided here and only here: `:tool:' open, `:thinking:' folded.
        ;; Buffer-local only: every other Org file keeps Org's default.
        (setq-local org-hide-drawer-startup nil)
        ;; Buffer-local (the 4th arg), so this hook entry dies with the chat
        ;; and never runs in a buffer that only wants Org's own colors.
        (add-hook 'window-configuration-change-hook
                  #'agent-org-buffer--ensure-font-lock nil t))
    (kill-local-variable 'header-line-format)
    (kill-local-variable 'add-log-current-defun-function)
    (kill-local-variable 'org-hide-drawer-startup)
    ;; undo recording is the mode's, so the mode gives it back: a buffer
    ;; that is no longer a chat gets ordinary undo behaviour whatever scope
    ;; it was left in
    (setq buffer-undo-list t)
    (remove-hook 'window-configuration-change-hook
                 #'agent-org-buffer--ensure-font-lock t)))

;;;; Session metadata block (Org-native, agent-shell bootstrapping)

(defun agent-org-buffer--tool-keyword (status)
  "Org TODO keyword for ACP tool STATUS (nil/unknown means pending).
The vocabulary is the user's -- ONGOING, COMPLETE, FAILED -- and it is
deliberately NOT the set `agent-org-buffer--todo-setup' declares: a call is a
line of the `:tool:' drawer, Org forbids headlines inside drawers, so this
word is TEXT the reader sees and never a state `C-c C-t' can set.
`pending' keeps TODO."
  (pcase status
    ("in_progress" "ONGOING")
    ("completed" "COMPLETE")
    ("failed" "FAILED")
    (_ "TODO")))

(defun agent-org-buffer--metadata-drawer (name entries cap)
  "Render drawer NAME with ENTRIES (already-formatted strings).
Nil when no entries.  CAP is how many lines are shown before a `… (+N
more)' tail; nil shows them all.

Every drawer this renders is capped, because each is a preview of
something the agent can be asked for again — an omitted `/command' costs a
look, not a thing.  Nothing here holds a user's work: the prompts waiting
to be sent are queue headlines at the bottom of the chat
(`agent-org-buffer-render-queue'), not a drawer, because a drawer the
user cannot edit is the wrong home for text he means to type into."
  (when entries
    (let ((shown (if cap (seq-take entries cap) entries)))
      (concat (format ":%s:\n" name)
              (mapconcat #'identity shown "\n")
              "\n"
              (when (and cap (> (length entries) cap))
                (format "… (+%d more)\n" (- (length entries) cap)))
              ":END:\n"))))

(defconst agent-org-buffer--metadata-drawer-cap 50
  "Lines shown in a reference drawer before the `… (+N more)' tail.
A number an AI conversation can outrun easily — an agent with forty slash
commands is ordinary — which is why the cap is written down once instead
of living in three call sites.")

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

(defun agent-org-buffer--render-metadata (status &optional lite)
  "Render the buffer-top Org metadata block for STATUS (pure).
The PROPERTIES drawer comes first, carrying the scalars (Provider, ID,
Mode, Model, Context, Cost, Tokens), then the `#+TITLE:' keyword line,
then COMMANDS/MODES/CONFIG drawers listing everything the agent
reported.  No heading: `* ' lines belong to the conversation and to the
queue region below it.  Drawers whose lists are still unknown are omitted,
as is the `:ID:' line until an id exists; a `:ID: unknown' would be a
property Org's id machinery would choke on, and a lie besides.

LITE is the session's resolved lite scope, passed in for the same reason
the status is: this is a pure renderer, and a buffer-local read here
would answer for whichever buffer happened to be current.  It adds the
`:Lite:' line and nothing else."
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
                        (plist-get status :config))))
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
              ;; only when the session says so: a transcript is a record,
              ;; and "this session was told not to keep one" is a fact
              ;; worth having in it (see `agent-org-lite-mode')
              (when lite ":Lite: yes\n")
              ":END:\n")
             ;; `#+TITLE:' is the harness's own session title, verbatim;
             ;; the provider name only stands in until one arrives.
             (concat
              (format "#+TITLE: %s\n"
                      (or (plist-get status :title) provider))
              (concat agent-org-buffer--todo-setup "\n"))
             (agent-org-buffer--metadata-drawer "COMMANDS" commands
                                                agent-org-buffer--metadata-drawer-cap)
             (agent-org-buffer--metadata-drawer "MODES" modes
                                                agent-org-buffer--metadata-drawer-cap)
             (agent-org-buffer--metadata-drawer "CONFIG" config
                                                agent-org-buffer--metadata-drawer-cap)))
      "\n")
     ;; blank line separating the block from the first conversation
     ;; heading (refresh deletes up to that heading)
     "\n")))

(defconst agent-org-buffer--metadata-drawers
  '("PROPERTIES" "COMMANDS" "MODES" "CONFIG")
  "Names of the drawers in the metadata block.
`agent-org-buffer-refresh-metadata' reads this to remember which drawers the
user had opened, and a name missing here is a drawer that reappears unfolded
on every rebuild.  Every one of them arrives folded the first time — they
are all reference the agent can be asked again for.")

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
after the rebuild; ones they opened stay open, and a drawer that does
not exist yet arrives folded (`agent-org-buffer--metadata-drawers').

Skips entirely when the rendered block is byte-identical to
`agent-org-buffer--metadata-cache': no deletion, no insertion, and no
`org-set-regexps-and-options' reparse of the whole buffer."
  (with-current-buffer buffer
    (let ((rendered (agent-org-buffer--render-metadata agent-org-buffer--status
                                                      (agent-org-lite-p))))
      (unless (equal rendered agent-org-buffer--metadata-cache)
        (let ((inhibit-read-only t))
          (save-excursion
            (let ((folded
                   (mapcar
                    (lambda (name)
                      (cons name
                            (save-excursion
                              (goto-char (point-min))
                              ;; Already there: keep whatever the user left it
                              ;; in.  Not there yet: it arrives with this
                              ;; rebuild, and every drawer that remains is
                              ;; reference, so it arrives FOLDED -- that is the
                              ;; one case a nil here used to mean "open", and
                              ;; reading it as "leave alone" silently made every
                              ;; first render show its drawers unfolded.
                              (if (re-search-forward (format "^:%s:" name) nil t)
                                  (progn (forward-line 1)
                                         (invisible-p (point)))
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
                 ;; headings get their buffer-local keyword set.  Only the
                 ;; FIRST rebuild needs it, and only a full session pays:
                 ;; `org-set-regexps-and-options' re-reads the WHOLE buffer,
                 ;; and this runs on every usage update of every turn.
                 (when (or (not (agent-org-lite-p buffer))
                           (not (agent-org-buffer--todo-live-p)))
                   (org-set-regexps-and-options)
                   (setq agent-org-buffer--todo-parsed t))
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

(defvar-local agent-org-buffer--queue-start nil
  "Marker at the first byte of this buffer's queue region, or nil when empty.
Rear-advancing, so text inserted AT it -- which is where every turn renders,
since `--render-end' answers with it -- pushes the REGION down instead of
landing in the middle of it.  It is what makes the queue the last thing a chat
shows: a turn rendered below the waiting prompts would bury the prompts the
user is waiting to send.")

(defvar-local agent-org-buffer--queue-end nil
  "Marker just past this buffer's queue region, or nil when the queue is empty.
The region's other side, so a repaint deletes exactly the region and never the
turn's answer above it or the `* User' box below it.  Rear-advancing for
the same reason as `--queue-start'.")

(defvar-local agent-org-buffer--queue-shown nil
  "The prompts the queue region held at the last repaint.
THE EDIT GUARD, and the only reason in-place editing is safe here.  A refresh
arrives at every queue change and at every turn boundary, while the region is
the user's own text: a repaint that ignored this would delete a half-typed
prompt in the middle of a word.  So `agent-org-buffer-refresh-queue' repaints
only while the region still says what this says; once the user has changed it,
the session's list is reconciled at `agent-org-queue-apply' instead -- the same
contract the queue editor used to have, for the same reason.")

;;;; Queue region markers live with the other buffer state, above
;;;; `--render-end', which reads `--queue-start'.

(defun agent-org-buffer--live-mark (marker)
  "Position of MARKER, or nil when it points into no buffer.
`mark' is the wrong tool here: it returns nil whenever the region is
inactive, which is nearly always the case for a bookkeeping marker."
  (and (markerp marker)
       (marker-buffer marker)
       (marker-position marker)))

(defun agent-org-buffer--render-end ()
  "Where the next per-turn block belongs in the current buffer.
The queue region's start when there is one -- so a turn renders ABOVE the
waiting prompts and the queue stays the last thing in the chat -- then the live
type-ahead box's start when one is open (so a streaming turn renders above it
and the draft the user is typing survives), and `point-max' otherwise (during
a replay, before any queue and any box exist).
Always called with the chat buffer current."
  (cond ((agent-org-buffer--live-mark agent-org-buffer--queue-start)
         (agent-org-buffer--live-mark agent-org-buffer--queue-start))
        ((agent-org-buffer--live-mark agent-org-buffer--prompt-anchor)
         (agent-org-buffer--live-mark agent-org-buffer--prompt-anchor))
        (t (point-max))))

(defconst agent-org-buffer--queue-keywords '("TODO")
  "The one state a queued prompt's heading wears, in the user's words.
Every entry in the region waits, so every entry is TODO and WHICH one leaves
next is the ORDER of the headings, not a word on them.  The retired NEXT/WAIT
pair put that order into a keyword, so the head of the list had to be re-worded
on every edit and on every reorder; a position cannot drift from itself.")

(defconst agent-org-buffer--queue-legacy-keywords '("NEXT" "WAIT")
  "Retired prompt states, READ but never WRITTEN.
Every transcript written before this vocabulary existed holds `* NEXT'/`* WAIT'
entries.  The parser accepts them so a resume does not silently drop a prompt
the user queued yesterday; the renderer only ever uses
`agent-org-buffer--queue-keywords', so a file converges on the new word the
first time its queue is redrawn.")

(defconst agent-org-buffer--queue-headline-re
  "^[*] TODO \\|^[*] NEXT \\|^[*] WAIT "
  "A queued prompt's headline: a current keyword or a retired one.
Two or three anchored alternatives and NO grouping, which is not a style choice:
the only backslash in this literal is the alternation bar, so there is no
`\\(...\\)' for a lost backslash to turn into a literal paren.  That mistake is
not hypothetical -- it shipped once in this file and every queue entry came
back with its first line swallowed by a group that was never closed.

Only these words make a headline an ENTRY, so the conversation's own
headlines -- which are prompts and agent turns -- are never mistaken for a
queue, and a `* note' the user typed at the bottom is text he can keep.")

(defun agent-org-buffer--queue-headline-text (line)
  "LINE's prompt text when it is a queue headline, else nil.
String surgery and NOT a regexp, for the reason
`agent-org-buffer--queue-headline-re' gives: this is the one place that has to
recover a prompt's first line from its headline, and a pattern with a group in
it is a pattern that can lose its closing paren.  Every keyword is tried,
current and retired alike, because a prompt read out of an old file is the
same prompt."
  (cl-loop for keyword in (append agent-org-buffer--queue-keywords
                                  agent-org-buffer--queue-legacy-keywords)
           for prefix = (concat "* " keyword " ")
           when (string-prefix-p prefix line)
           return (substring line (length prefix))))

(defun agent-org-buffer--queue-parse-text (region)
  "The prompts stored in queue-region text REGION, oldest first.
The one reader of the queue's on-page form, used by
`agent-org-buffer-queue-parse' for the live region and by
`agent-org-buffer-transcript-queue' for a mirrored file, so the two can
never drift apart on the exact question of what a queued prompt IS.
REGION is the region's text and nothing else: an entry is its headline plus
every following line up to the next headline, so a multi-line prompt stays
ONE prompt.  Everything before the first headline is the preamble
(`agent-org-buffer--queue-note-text') and is dropped, as is a prompt that
trims to nothing — a bare heading is a slot the user has not typed in yet,
and `agent-org-send' refuses an empty draft.

Each body line gives back the one space `agent-org-buffer--queue-entry' put
on; blank lines are KEPT, because a prompt is the user's own text and its
own blank lines are part of it.  The entry as a whole is trimmed, so a
trailing newline from the renderer does not become a trailing blank line in
the prompt."
  (let (prompts body)
    (dolist (line (split-string region "\n"))
      (let ((head (agent-org-buffer--queue-headline-text line)))
        (if head
            (progn
              (when body
                (push (string-trim (mapconcat #'identity (nreverse body) "\n"))
                      prompts))
              (setq body (list head)))
          (when body
            (push (if (string-prefix-p " " line) (substring line 1) line) body)))))
    (when body
      (push (string-trim (mapconcat #'identity (nreverse body) "\n")) prompts))
    (delq nil
          (mapcar (lambda (prompt)
                    (and (not (string-blank-p prompt)) prompt))
                  (nreverse prompts)))))

(defun agent-org-buffer--queue-entry (text)
  "One queued prompt's heading and body: TEXT under TODO.
The same shape as an exchange heading (`agent-org-buffer-begin-exchange'): the
first line of the prompt IS the heading, and every later line takes one space
of indent so it stays the heading's own affixed metadata instead of becoming a
second paragraph -- and, more importantly, so a prompt that contains Org markup
cannot introduce a headline of its own.  A prompt that starts with `*' is the
user's own words about a document, and one space is all a headline needs to
stop being one (info \"(org) Headlines\").

EXACTLY one newline separates the heading from the body, and that is what
`agent-org-buffer--queue-text' counts on when it takes the body from the line
after the heading: a second one becomes a blank line, and a blank line between
a heading and its first body line is a prompt the user never wrote.  So a
single-line prompt is a heading and nothing else, and the entry's trailing
newline is the one the renderer owns."
  (let* ((lines (split-string (string-trim text) "\n"))
         (first (if lines (car lines) ""))
         (rest (mapconcat (lambda (line)
                            (if (string-empty-p line) line (concat " " line)))
                          (cdr lines)
                          "\n"))
         (heading (format "* %s %s"
                          (car agent-org-buffer--queue-keywords)
                          (if (string-empty-p first) "" first))))
    (if (string-empty-p rest)
        (concat heading "\n")
      (concat heading "\n" rest "\n"))))

(defconst agent-org-buffer--queue-note-text
  ";; Prompts waiting to be sent, oldest first.
;; Edit them here, then M-x agent-org-queue-apply.
"
  "The region's preamble, ABOVE the entries and never below them.
Comment lines, so it can never be read back as an entry, and FIRST for a
reason that is not cosmetic: an entry's text is everything from its headline
to the next one, so a note AFTER the last entry would be parsed as part of that
prompt and sent to the agent (measured while this was written: the queue
parsed back as one prompt ending in \"M-x agent-org-queue-apply\").  Above the
first headline it is outside every entry's body, and it is still the one thing
a reader of a TRANSCRIPT cannot work out for himself.")

(defun agent-org-buffer-render-queue (prompts)
  "The whole queue REGION for PROMPTS, oldest first.
Every entry wears TODO: the head of the list is the one that goes out when the
turn ends (`agent-org--drain-queue'), and that is shown by its ORDER, not by a
different word on it.  PROMPTS nil renders as the EMPTY STRING, and no queue
leaves no trace at all: an empty entry is a slot to compose in, which is what
`agent-org-queue-edit' asks `agent-org-buffer-queue-insert-entry' for, and a
permanent blank heading would put a headline in every transcript for nothing.

A non-nil PROMPTS whose only member is the empty string renders the preamble
and NO entry, which is how a slot exists before the user has typed anything."
  (if (null prompts)
      ""
    (concat agent-org-buffer--queue-note-text
            (mapconcat (lambda (prompt)
                         ;; an empty prompt renders as NOTHING: the slot a
                         ;; user is about to type in is not an entry yet, and a
                         ;; bare `* TODO' heading here would be one that says
                         ;; it (the renderer is called with the list before
                         ;; the heading is inserted)
                         (if (string-empty-p prompt)
                             ""
                           (agent-org-buffer--queue-entry prompt)))
                       prompts
                       ""))))

;;;; The queue region: waiting prompts at the bottom of the chat

(defun agent-org-buffer--queue-mark (position)
  "A rear-advancing marker at POSITION, for a queue region's edges."
  (let ((marker (make-marker)))
    (set-marker-insertion-type marker t)
    (move-marker marker position)
    marker))

(defun agent-org-buffer--queue-region ()
  "The queue region's bounds as (BEG . END) in this buffer, or nil when empty.
Computed fresh from the markers rather than cached: a marker position is always
current, and a cached pair would go stale on every insert at the region."
  (let ((beg (agent-org-buffer--live-mark agent-org-buffer--queue-start))
        (end (agent-org-buffer--live-mark agent-org-buffer--queue-end)))
    (when (and beg end)
      (cons beg (min end (point-max))))))

(defun agent-org-buffer-queue-p (&optional buffer)
  "Non-nil when BUFFER shows a queue region at all; the current buffer if nil.
The MARKERS and not the text, so a queue the user has emptied by hand is still
a region -- with nothing in it -- and a repaint can put it back where it
belongs.  A region found only by searching for a `* TODO' line would refuse."
  (with-current-buffer (or buffer (current-buffer))
    (not (null (agent-org-buffer--queue-region)))))

(defun agent-org-buffer--queue-paint (region prompts)
  "Replace the queue REGION with PROMPTS and re-arm both markers.
Called with this buffer current; REGION is nil or a (BEG . END) pair.  An empty
PROMPTS drops the markers too, so a session with no queue leaves no trace of
one -- in the buffer or in the transcript."
  (let ((inhibit-read-only t))
    (save-excursion
      (when region
        (delete-region (car region) (cdr region)))
      (let* ((beg (or (car region) (agent-org-buffer--render-end)))
             ;; a COPY of the position, because the two markers are made
             ;; after the insert and `beg' itself may have moved with it
             (start (copy-marker beg)))
        (goto-char beg)
        (insert (agent-org-buffer-render-queue prompts))
        (setq agent-org-buffer--queue-start (agent-org-buffer--queue-mark start)
              agent-org-buffer--queue-end (agent-org-buffer--queue-mark (point))
              agent-org-buffer--queue-shown prompts)
        (when (and (null prompts) (not (equal prompts "")))
          (setq agent-org-buffer--queue-start nil
                agent-org-buffer--queue-end nil))
        ;; the keywords have to be live for TODO to read as an Org state
        ;; on the headings the user is about to edit
        (org-set-regexps-and-options)))))

(defun agent-org-buffer--queue-region-text ()
  "The raw text of this buffer's queue region, empty when there is no region.
The RAW text, which is what makes the edit guard exact: an unedited region is
byte-for-byte `agent-org-buffer-render-queue's own output, and anything the
user did --- a re-order, a kill, a blank slot, one typed word --- is a
difference from that.  A comparison of PARSED entries would not do: the parser
drops a blank entry, so a brand-new slot in an empty queue would parse as the
same list and look untouched."
  (let ((region (agent-org-buffer--queue-region)))
    (if region
        (buffer-substring-no-properties (car region) (cdr region))
      "")))

(defun agent-org-buffer--queue-pristine-p ()
  "Non-nil when this buffer's queue region still says what was last written.
THE edit guard, and the only reason in-place editing is safe here (see
`agent-org-buffer--queue-shown').  Byte-for-byte against a fresh render of the
baseline, which is the one comparison that cannot be fooled by a change the
parser cannot see."
  (equal (agent-org-buffer--queue-region-text)
         (agent-org-buffer-render-queue agent-org-buffer--queue-shown)))

(defun agent-org-buffer-refresh-queue (buffer prompts)
  "Repaint BUFFER's queue region from PROMPTS, unless the user is mid-edit.
Idempotent by construction: the region between the two markers is deleted and
reinserted, so a refresh can never append a second copy -- the same rule as
`agent-org-buffer-refresh-metadata', over a region whose owner is the queue.

The GUARD is what makes editing here safe, and it has two halves.  Repaint only
when the session's queue and `--queue-shown' actually differ, so a usage
update cannot rewrite a line nobody touched; and then only while the region is
PRISTINE (`agent-org-buffer--queue-pristine-p'), so a region the user has
edited is left alone.  A prompt that went out while he was editing it stays on
the page until he applies, and the apply drops it by text
(`agent-org--queue-note').

`--queue-shown' is the BASELINE, not the region's content: a move, a kill and a
new slot deliberately leave it behind, because that difference is exactly what
tells the guard the region has been touched."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (unless (equal prompts agent-org-buffer--queue-shown)
        (when (agent-org-buffer--queue-pristine-p)
          (agent-org-buffer--queue-paint (agent-org-buffer--queue-region)
                                          prompts))))))

(defun agent-org-buffer--queue-headlines ()
  "Positions of this buffer's queue entry headlines, top to bottom.
`match-beginning', never what `re-search-forward' returns: that is the match's
END, one line into the entry's body.  Searched WITHIN the region, so a turn's
own heading cannot be read as a queued prompt even if an agent writes a
question that begins with those words."
  (let ((region (agent-org-buffer--queue-region)))
    (when region
      (save-excursion
        (goto-char (car region))
        (let (spots)
          (while (and (< (point) (cdr region))
                      (re-search-forward agent-org-buffer--queue-headline-re
                                         (cdr region) t))
            (push (match-beginning 0) spots))
          (nreverse spots))))))

(defun agent-org-buffer-queue-parse (&optional buffer)
  "BUFFER's queue entries as prompts, top to bottom; the current buffer if nil.
The live region's own text through `agent-org-buffer--queue-parse-text', which
is the same reader a transcript file uses — one rule for what a queued prompt
is, applied to both.  So a re-order or an in-place edit that has not been
applied yet is read as it LOOKS, blanks and all."
  (when (buffer-live-p (or buffer (current-buffer)))
    (with-current-buffer (or buffer (current-buffer))
      (agent-org-buffer--queue-parse-text
       (agent-org-buffer--queue-region-text)))))

(defun agent-org-buffer--queue-at-p ()
  "Non-nil when point is inside this buffer's queue region.
What lets one key be two commands: `M-UP'/`M-DOWN' move a queued prompt when
point is in the region and refuse everywhere else, where Org's own subtree
move would cut the conversation's own heading boundaries apart."
  (let ((region (agent-org-buffer--queue-region)))
    (and region
         (<= (car region) (point))
         (<= (point) (cdr region)))))

(defun agent-org-buffer-queue-entry-bounds ()
  "Start and end of the queue entry containing point, as a cons.
`user-error' when point is not on one: a move or a kill from outside the
region has no entry to act on, and taking the first one anyway would be a
guess."
  (let* ((spots (agent-org-buffer--queue-headlines))
         (here (car (last (seq-take-while (lambda (s) (<= s (point))) spots)))))
    (unless here
      (user-error "Not on a queued prompt"))
    (cons here (or (seq-find (lambda (s) (> s here)) spots) (point-max)))))

(defun agent-org-buffer-queue-restate (buffer)
  "Rewrite BUFFER's queue region from what it now holds, keywords and all.
Called after a move or a kill: the WORDS on the headlines are derived from
position (`agent-org-buffer--queue-keywords'), so a heading that kept its old
word after a move would promise a place in the send order it no longer has.
The prompts themselves are re-read from the region and re-rendered, so only the
keywords and the order change -- what the user typed is untouched.

The MARKERS are re-armed around the new text, and that is not tidiness: a
region whose markers still bracket the old positions has no entries to parse,
so the very next `agent-org-buffer-queue-parse' answers nil and the queue the
user can see has become a queue nothing can read.  Measured here, on the kill
that leaves two entries behind."
  (with-current-buffer buffer
    (let ((region (agent-org-buffer--queue-region))
          (entries (agent-org-buffer-queue-parse buffer)))
      (when region
        (let ((inhibit-read-only t)
              (start (copy-marker (car region))))
          (save-excursion
            (delete-region (car region) (cdr region))
            (goto-char (car region))
            (insert (agent-org-buffer-render-queue entries))
            (setq agent-org-buffer--queue-start
                  (agent-org-buffer--queue-mark start)
                  agent-org-buffer--queue-end
                  (agent-org-buffer--queue-mark (point))))))
      ;; `--queue-shown' is NOT updated here: it is the baseline the edit guard
      ;; compares against, and a move IS a touch.  The apply is what makes the
      ;; session agree with what the region now says.
      (when entries
        nil))))

(defun agent-org-buffer-queue-insert-entry (buffer)
  "Append a blank `* TODO' entry to BUFFER's queue region; return its position.
A blank entry is a SLOT to type in, which is how the user adds a prompt of his
own at the bottom -- and `--queue-parse' drops it if he leaves it empty, so
composing one cannot send a blank.  It wears the same word as every other entry:
position in the region, not the keyword, is what makes a prompt the next one
out."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (unless (agent-org-buffer-queue-p)
        ;; Paint the BASELINE the slot will be read against -- a list of one
        ;; empty string, which renders as the preamble and no entry -- and only
        ;; then insert the heading.  The two differ, so the edit guard sees a
        ;; touched region from the moment the slot exists: a refresh that
        ;; arrived then would delete a half-typed prompt.
        (agent-org-buffer--queue-paint nil (list "")))
      (goto-char (cdr (agent-org-buffer--queue-region)))
      (insert (format "* %s \n" (car agent-org-buffer--queue-keywords)))
      (point-max))))

(defun agent-org-buffer-queue-kill-entry (buffer)
  "Kill the queue entry at point in BUFFER, onto the kill ring.
A KILL, because this is the command with no confirmation and dropping a prompt
the user meant to keep is the mistake worth making recoverable: `C-y' puts the
entry back.  The rest are re-stated afterwards, so the words left on them match
the order the queue is now in."
  (with-current-buffer buffer
    (let ((bounds (agent-org-buffer-queue-entry-bounds)))
      (kill-region (car bounds) (cdr bounds)))
    (agent-org-buffer-queue-restate buffer)
    (message "[agent-org] queued prompt killed (C-y puts it back)")))

(defun agent-org-buffer-queue-move (buffer up)
  "Move the queue entry at point in BUFFER one place, up when UP is non-nil.
Org's own subtree move, so the text travels with its headline.  At the first or
the last entry Org refuses and nothing moves, which is the right answer: there
is nothing in front of the first and nothing behind the last."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (car (agent-org-buffer-queue-entry-bounds)))
      (if up (org-move-subtree-up) (org-move-subtree-down)))
    (agent-org-buffer-queue-restate buffer)
    (message "[agent-org] queued prompt moved %s" (if up "up" "down"))))

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
                       (get-text-property orig 'read-only)))
             (queue (agent-org-buffer-queue-p)))
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
          ;; The box went in at `point-max', which with a queue region already
          ;; painted is BELOW it, so the region's end moves to where the box
          ;; starts.  Re-arming the marker rather than inserting above it is
          ;; what makes that true in every case: a region sitting at the very
          ;; end has no line after it to insert into, and a rear-advancing end
          ;; marker pushed down by the box would swallow the box INTO the
          ;; region -- measured here, the queue then parsed as one prompt whose
          ;; text ended with the words `* User'.
          (when queue
            (setq-local agent-org-buffer--queue-end
                        (agent-org-buffer--queue-mark box-beg)))
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
  "The line of the streaming answer still arriving, in the agent's own words.
A chunk stops wherever the model's tokenizer stopped, so `**bold\' can end one
chunk and `**\' open the next.  It is appended to the buffer RAW as it arrives
— that is what the person is watching — and held here so that when its newline
lands the JOINED line can be converted and appended once, as markup.  Nothing is
ever rewritten (`agent-org-buffer--markdown-write' appends and nothing else),
which is the user's rule: \"Just append.\"")
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
A Markdown heading becomes a BOLD line (`# Title' -> `*Title*'), because this
reply now lives inside a quote block and a headline of ANY level ends one — the
parser stops the block at the star and everything the agent said afterwards
leaves its own answer.  It cannot be shifted a level down either, since level 1
is the conversation's own level (the exchange heading) and there is no level
below one that is not still a headline.  So the words are kept and the size is
lost, which is the least damaging reading of a heading that cannot exist here.
`*Title*' with no space after the star is emphasis and never a headline (info
\"(org) Headlines\": stars must be followed by whitespace) — which is why the
stars hug the text."
  (cond
   ((string-match "^\\(#+\\) \\(.*\\)" line)
    (concat "*" (agent-org-buffer--md-inline (match-string 2 line)) "*"))
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

(defun agent-org-buffer--markdown-write (lines)
  "Append the converted LINES of completed answer text to this buffer.
APPEND-ONLY, and that is the whole rule the user asked for (\"No need to
reorder, or to go back to insert text.  Just append.\"): nothing already in the
buffer is ever deleted, so a chunk can neither move text nor undo text the
person has already read.  There is no provisional region and no
`--md-tail' marker any more, because there is nothing left to rewrite.

The line COMPLETION is the granularity, and it is what makes append-only
possible: `agent-org-buffer--markdown-receive' holds the still-arriving line
in `agent-org-buffer--md-fragment' and converts it here, once, when its
newline lands.  A line therefore appears when it is finished rather than
character by character --- which is what a terminal, and agent-shell, do --- and
a Markdown construct split across two chunks (`**bold' + `**') still converts
correctly, because it is the JOINED line that is converted, not the chunk.

Everything goes through `agent-org-buffer--response-safe-lines', which is what
keeps agent text from becoming a HEADLINE of its own in the middle of an
exchange (measured with `org-element-parse-buffer'): a `*' at column 0 would
cut the turn in two and put the rest of the answer under a heading of its own.
Run it in the chat buffer."
  (when lines
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (agent-org-buffer--text-end))
        (unless (bolp) (insert "\n"))
        (let ((start (point)))
          (insert (mapconcat #'identity
                             (agent-org-buffer--response-safe-lines
                              (if (stringp lines) lines
                                (mapconcat #'identity lines "\n")))
                             "\n")
                  "\n")
          (agent-org-buffer--protect start (point))
          (agent-org-buffer--advance-text-end (point)))))))

(defun agent-org-buffer--markdown-receive (text)
  "Take one streamed Agent TEXT chunk into this buffer, appending it.
Run it in the chat buffer, after the turn's heading exists.

The lines this chunk FINISHED are converted and appended now; the line still
arriving is kept in `agent-org-buffer--md-fragment' and appended, converted,
when ITS newline lands --- and `agent-org-buffer--markdown-flush-here' catches
whatever is still arriving at the turn boundary.  Nothing is ever written
twice and nothing is ever rewritten: an earlier shape ALSO appended the raw
arriving line here, which left the buffer holding every line twice (once raw,
once converted), and that is the opposite of append-only.

The granularity is therefore the LINE, which is what a terminal, and
agent-shell, display: a Markdown construct split across two chunks (`**bold' +
`**') still converts correctly, because it is the JOINED line that is
converted, not the chunk."
  (let* ((combined (concat agent-org-buffer--md-fragment text))
         (parts (split-string combined "\n"))
         (tail (car (last parts)))
         (done (butlast parts))
         (result nil))
    (when done
      (setq result (agent-org-buffer--markdown-convert-lines
                    done agent-org-buffer--md-src-p))
      (setq agent-org-buffer--md-src-p (cdr result))
      (agent-org-buffer--markdown-write (car result)))
    (setq agent-org-buffer--md-fragment tail)))

(defun agent-org-buffer--markdown-flush-here ()
  "Finish this turn's arriving line, appending it converted.  Run in this buffer.
The text is appended as it arrives; this ends the last line, closes a fence the
agent never closed, and FORGETS the converter state.  Forgetting is
load-bearing, not tidiness: state left behind would put the next turn's opening
paragraph inside this turn's code block.

Still an append, so it goes in at the answer's insertion point and touches
nothing above it; and an unclosed fence is closed HERE, immediately after the
agent's last line, because a `#+begin_src' left open would swallow the
`:tool:' drawer and the type-ahead box below it (measured)."
  (when (or agent-org-buffer--md-fragment agent-org-buffer--md-src-p)
    (when (and agent-org-buffer--md-fragment
               (not (string-empty-p agent-org-buffer--md-fragment)))
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (agent-org-buffer--text-end))
          (unless (bolp) (insert "\n"))
          (let ((start (point)))
            (insert (mapconcat #'identity
                               (agent-org-buffer--response-safe-lines
                                (car (agent-org-buffer--markdown-convert-lines
                                      (list agent-org-buffer--md-fragment)
                                      agent-org-buffer--md-src-p)))
                               "\n")
                    "\n")
            (agent-org-buffer--protect start (point))
            (agent-org-buffer--advance-text-end (point))))))
    (when agent-org-buffer--md-src-p
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (agent-org-buffer--text-end))
          (unless (bolp) (insert "\n"))
          (let ((start (point)))
            (insert (car (agent-org-buffer--response-safe-lines "#+end_src")) "\n")
            (agent-org-buffer--protect start (point))
            (agent-org-buffer--advance-text-end (point))))))
    (setq agent-org-buffer--md-fragment nil
          agent-org-buffer--md-src-p nil)))

;;;; One heading per exchange: the question IS the heading

(defun agent-org-buffer--response-safe-lines (text)
  "TEXT as answer lines that cannot re-shape the exchange they sit in.
Two shapes are structural in Org and ordinary in agent text, and the quote
block that used to hold them inert is gone:

  - a `*' at column 0 is a level-1 HEADLINE, so a Markdown `* item' bullet —
    or prose that happens to start with a star — would END the exchange the
    answer belongs to and put the rest under a heading of its own;
  - a `:NAME:' at column 0 OPENS a drawer and `:END:' CLOSES one, so an agent
    quoting a transcript back at you can write `:thinking:' into its own
    answer — and `agent-org-buffer--redraw-drawer' searches the turn region
    TEXTUALLY for exactly those lines, so its own reply would be painted over
    (measured: the redraw's `re-search-forward' for the drawer's `:end:' runs
    past the fake opener and signals search-failed).

So precisely those lines take one space of indent, which is all a headline or a
drawer keyword needs to stop being one (info \"(org) Headlines', \"(org)
Drawers'), and everything else is left flush left so the reply reads as prose.
The earlier version of this guard indented EVERY line and wrapped
`#+end_quote'; both were for the quote block, and the block is gone (the user:
\"No more quote blocks\") — indenting all of it would turn ordinary paragraphs
into Org verbatim blocks.

This is also why the answer is never truncated and never re-flowed: a record
that quietly lost its middle is worse than an indented one."
  (let ((case-fold-search t))
    (mapcar (lambda (line)
              (if (or (string-empty-p line)
                      (not (string-match-p "^[ \t]*\\(?:\\*+[ \t]\\|:[A-Za-z0-9_+-]*:[ \t]*$\\)"
                                           line)))
                  line
                (concat " " (string-trim-right line))))
            (split-string (string-trim-right text) "\n"))))

(defun agent-org-buffer--heading-text (text)
  "The heading this exchange gets, from the FIRST line of the prompt TEXT.
A heading is one line and a prompt is whatever the user typed, so the first
line is the heading — the question a person scans for — and the rest of the
prompt stays under it (`agent-org-buffer-begin-exchange'), because a record
that quietly dropped lines 2..n is worse than a long heading.

Whitespace runs collapse: a newline on a heading line is a broken headline.
Nothing is TRUNCATED: `agent-org-buffer--label' is the gate for
AGENT-supplied labels — a live qoder titles a tool call with the whole shell
command — and a person's own question is not that.

With `agent-org-convert-markdown' the line takes the same structural rule a
reply does, so a pasted `## Setup' arrives as a bold `*Setup*' instead of
leaving Markdown stars on a heading; the agent still receives the Markdown as
typed, because all of this is rendering and none of it is the wire."
  (let ((first (car (split-string (string-trim text) "\n"))))
    (when agent-org-convert-markdown
      (setq first (agent-org-buffer--md-structure first)))
    (let ((flat (mapconcat #'identity (split-string first "[ \t\r]+" t) " ")))
      (if (string-empty-p flat) "User" flat))))

(defun agent-org-buffer-begin-exchange (buffer text)
  "Open one prompt-response pair in BUFFER, headed by the question TEXT.
User order: \"there will be ONE heading for each prompt-response pair.  The
heading will contain the prompt.\"  So this replaces the old `* User' echo
heading: the sent question is no longer body text under a generic word, it IS
the heading, and the answer that follows belongs to it
(`agent-org-buffer-start-agent-turn').

Lands above the live type-ahead box when one is open, so a drained queue
prompt renders in history order rather than underneath the draft — and the
box is never consumed here, which is what keeps a mid-turn draft alive.

Closes the previous turn first: a heading must not open inside the answer it
follows.  And it resets the turn-local tool, thought and converter state,
because the next `:tool:' board belongs to THIS exchange and is built from
scratch — as is the answer's quote block, whose furniture cannot be shared
across pairs."
  (when (and text (not (string-empty-p (string-trim text))))
    (with-current-buffer buffer
      (agent-org-buffer-end-agent-turn buffer)
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (agent-org-buffer--render-end))
          (agent-org-buffer--separator)
          (let ((beg (point)))
            (insert (format "* %s\n" (agent-org-buffer--heading-text text)))
            (let* ((rest (cdr (split-string (string-trim text) "\n"))))
              (when rest
                (when agent-org-convert-markdown
                  (setq rest (split-string
                              (agent-org-buffer--markdown-convert
                               (mapconcat #'identity rest "\n"))
                              "\n")))
                ;; the separator line before the answer's quote block comes from
                ;; `agent-org-buffer-start-agent-turn', so the body of a
                ;; multi-line question is the block's first lines, not a
                ;; paragraph glued to the furniture
                (insert "\n"
                        (mapconcat #'identity
                                   (agent-org-buffer--response-safe-lines
                                    (mapconcat #'identity rest "\n"))
                                   "\n"))))
            (insert "\n")
            (agent-org-buffer--protect beg (point))
            (move-marker (setq-local agent-org-buffer--turn-anchor
                                     (make-marker))
                         beg))
          (setq agent-org-buffer--awaiting-answer-p t
                ;; The response clock starts at the moment the question
                ;; goes out, which is THIS instant: the stamp is spent by
                ;; `agent-org-buffer--close-response-clock' at the next
                ;; boundary.  Suppressed for the replay paint (see
                ;; `agent-org-buffer--record-clock-p'): restored history
                ;; has no timing to invent, and an orphan turn never
                ;; records one either — no prompt was sent to measure
                ;; from, so its stamp stays nil and the boundary writes
                ;; no clock.
                agent-org-buffer--turn-start
                (and agent-org-buffer--record-clock-p
                     (current-time))
                agent-org-buffer--tools nil
                agent-org-buffer--tools-shown nil
                ;; the tool board is a window on the record, so a new turn
                ;; starts at its first entry with no drawer open: the previous
                ;; turn's drawer is its text now, and a call here must not be
                ;; painted into it
                agent-org-buffer--tool-group-start 0
                agent-org-buffer--tool-drawer-live-p nil
                agent-org-buffer--thought nil
                ;; a fresh turn has written no answer prose yet: this is what
                ;; `agent-org-buffer--drop-empty-response' keys on, and a stale
                ;; t from the previous turn would keep an empty prefix alive
                agent-org-buffer--answer-written-p nil
                ;; markdown->org is turn-local too: a held half line from the
                ;; previous answer must not open this one, and a fence left
                ;; unclosed by a truncated reply must not hide this answer
                ;; inside a code block
                agent-org-buffer--md-fragment nil
                agent-org-buffer--md-src-p nil))))))

;;;; Streaming (the hot path)

(defun agent-org-buffer--prefix-line ()
  "The line that introduces an answer: the model that is answering.
`Model name: ' --- the model in force, from
`agent-org-buffer--model-display' (the agent's own label else its id),
flattened by `agent-org-buffer--label' because a config option's `name' is
agent text and a newline here would start the answer on the wrong line.

This line USED to be `#+ATTR_TEXINFO: :author NAME' above a
`#+begin_quote', which was the manual's own way to attribute a quotation.
The user ended the quotation (\"No more quote blocks.  Just use model name as
prefix.\"), and a prefix line is the same fact in a shape that costs nothing:
no `#+begin_quote'/`#+end_quote' furniture to close, nothing for an agent to
escape from, and no block for Org to abandon.  With no model at all (Goose
advertises none of this shape) or `agent-org-response-prefix' nil, the word is
\"Agent\": an empty line is a claim about nobody.

Written ONCE, when the answer starts, and never derived again --- which is why
no per-turn model map is needed: this line IS the record of which model
answered, and a later `C-c C-m' renames the answers after it and leaves the
older ones alone."
  (format "%s: "
          (or (and agent-org-response-prefix
                   (when-let* ((model (agent-org-buffer--model-display
                                       agent-org-buffer--status)))
                     (agent-org-buffer--label model)))
              "Agent")))

(defun agent-org-buffer--text-end ()
  "Where the next byte of the answer belongs in this buffer.
The answer's own insertion point while one is open --- a marker the text
path keeps at the end of the answer written so far (see
`agent-org-buffer--advance-text-end') --- so every chunk lands ABOVE the
`:thinking:' and `:tool:' drawers this turn has already drawn, whatever order
they arrived in.  Falls back to `agent-org-buffer--render-end' when no answer
is open (a boundary arriving between turns).

Always called with the chat buffer current."
  (or (agent-org-buffer--live-mark agent-org-buffer--quote-end)
      (agent-org-buffer--render-end)))

(defun agent-org-buffer--advance-text-end (position)
  "Leave the answer's insertion marker at POSITION, the end of text just added.
Called by every writer that appends answer text at `agent-org-buffer--text-end',
with the `(point)' reached after its insert.  This is the marker's one mover:
because it is NOT rear-advancing (see `agent-org-buffer-start-agent-turn'), a
drawer drawn at the same spot cannot shove it down and strand the prose under
the board, and only an actual answer line advances it -- so consecutive chunks
still land in arrival order, each under the last.

Does nothing between turns, when no answer marker is live."
  (when (markerp agent-org-buffer--quote-end)
    (setq agent-org-buffer--answer-written-p t)
    (move-marker agent-org-buffer--quote-end position)))

(defun agent-org-buffer--orphan-heading ()
  "Open a heading for an answer that has no question in front of it.
`session/load' history can carry agent updates that no `user_message_chunk'
precedes, and dropping them because there is nothing to answer would lose the
history the restore was for.  The word is the old heading's \"Agent\", which
is what a turn with no recorded question actually is.

This is the start of a NEW turn, so it resets the turn-local record exactly as
`agent-org-buffer-begin-exchange' does for a question-headed turn: without it a
second orphan turn — the tool-only case, where nothing ever streams a fresh
quote — inherits the previous turn's `:tool:' board and thought text, because
`agent-org-buffer--tools' is the whole record the drawer redraws from.  With the
heading written by `begin-exchange' the reset already happened there and this
branch never runs, so the board is never cleared a second time mid-turn."
  (insert "* Agent\n\n")
  (move-marker (setq agent-org-buffer--turn-anchor (make-marker))
               (line-beginning-position))
  (setq agent-org-buffer--awaiting-answer-p t
        agent-org-buffer--tools nil
        agent-org-buffer--tools-shown nil
        agent-org-buffer--tool-group-start 0
        agent-org-buffer--tool-drawer-live-p nil
        agent-org-buffer--thought nil
        agent-org-buffer--answer-written-p nil
        agent-org-buffer--md-fragment nil
        agent-org-buffer--md-src-p nil))

(defun agent-org-buffer-start-agent-turn (buffer _session)
  "Open this exchange's answer in BUFFER under the model name, once per turn.
Font-lock stays on for the whole turn so Org colors never vanish while
streaming.  Incremental cost is kept low by the append path, which only ever
fontifies the text it just inserted (see `agent-org-buffer-append-chunk'), not
the whole buffer.

The furniture is ONE line --- the prefix (`agent-org-buffer--prefix-line') ---
and the answer is APPENDED under it for the whole turn
(`agent-org-buffer--text-end').  That line is what replaced the quote block:
`#+ATTR_TEXINFO' / `#+begin_quote' / `#+end_quote' were three lines whose only
job was to hold an attribution and keep the buffer valid Org while the agent
was still talking, and with the block gone there is nothing to close and nothing
for an agent to escape from.  The insertion marker stays (rear-advancing, at
the end of the prefix line), so every chunk and every drawer lands in the
right order no matter which arrives first.

It joins the heading `agent-org-buffer-begin-exchange' wrote, because one
heading covers the pair; with nothing to answer it opens a heading of its own
(`agent-org-buffer--orphan-heading') rather than writing into the previous
exchange.

The whole mutation runs in `save-excursion': a turn can start while the
user is mid-sentence in the type-ahead box, and this is one of the
functions that does so — leaving point on the box's anchor would strand
it on the heading's leading separator, where the next keystroke inserts
ABOVE the box instead of inside it."
  (with-current-buffer buffer
    (save-excursion
      (let ((inhibit-read-only t))
        (unless agent-org-buffer--streaming-p
          ;; already streaming means the answer is open: a second prefix per
          ;; exchange would be a second answer
          (setq agent-org-buffer--answer-written-p nil)
          (goto-char (agent-org-buffer--render-end))
          (agent-org-buffer--separator)
          (unless agent-org-buffer--awaiting-answer-p
            (agent-org-buffer--orphan-heading)
            (goto-char (agent-org-buffer--render-end))
            (agent-org-buffer--separator))
          (let ((beg (point)))
            (insert (agent-org-buffer--prefix-line))
            (insert "\n")
            (agent-org-buffer--protect beg (point))
            (let ((marker (make-marker)))
              ;; rear-advancing, so consecutive answer chunks append in order:
              ;; text written AT this position goes before the marker and it
              ;; keeps pointing at the end of the answer.  That is also the
              ;; hazard: a `:thinking:' / `:tool:' drawer drawn at
              ;; `agent-org-buffer--render-end' -- which, with nothing trailing
              ;; the answer yet, IS this marker position -- would push the
              ;; sticky marker down past the board, and the answer's next chunk
              ;; would land BELOW the drawers: the empty `Agent:' line on top
              ;; with the prose stranded under the board, the exact "I can't go
              ;; back and forth to read what the agent said" the user reported.
              ;; `agent-org-buffer--redraw-drawer' therefore puts the marker
              ;; back above any drawer it creates at this spot.
              (set-marker-insertion-type marker t)
              (move-marker marker (point))
              (setq-local agent-org-buffer--quote-end marker))))
          (setq agent-org-buffer--streaming-p t
                agent-org-buffer--awaiting-answer-p nil
                agent-org-buffer--stream-start (point))))))

(defun agent-org-buffer--drop-empty-response ()
  "Remove this turn's prefix line when no answer text ever arrived.
An attribution to nothing is noise in the user's notes: a turn that only ran
tools should read as the question plus its `:tool:' board.  Called at the turn
boundary, when nothing more can arrive.

The test is the flag, not the buffer: `agent-org-buffer--answer-written-p' is
set by `agent-org-buffer--advance-text-end' -- the one mover of the answer's
marker -- so it records directly whether any prose landed this turn.  A blank
line at the marker is NOT that test: once the marker has moved past the answer
text and a drawer has been drawn below it, the marker points at the gap above
the board, which reads blank, and an empty-looking line is no proof that the
answer was empty.  Keyed off the flag, a tool-only turn (flag nil) drops its
lonely `Agent:' line and a turn that said something (flag t) never does.

It is the PREFIX line alone that goes.  With no text written the marker never
moved, so it sits just past the newline that ends the prefix line: one
`forward-line' back is the prefix, and the region from its start to the marker
is exactly the `Agent:\\n' to remove -- never the drawer that follows."
  (unless agent-org-buffer--answer-written-p
    (when-let* ((end-pos (agent-org-buffer--live-mark agent-org-buffer--quote-end)))
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char end-pos)                  ; just past the prefix's newline
          (forward-line -1)                    ; onto the prefix line
          (delete-region (line-beginning-position) end-pos)))))
  (when (markerp agent-org-buffer--quote-end)
    (move-marker agent-org-buffer--quote-end nil)))

(defun agent-org-buffer--close-response-clock ()
  "Write this turn's `CLOCK:' line and `:RESPONSE:' property, once.
Called with the chat buffer current, at the turn boundary.  Does nothing
when there is no recorded start — between turns, on an orphan, and on
EVERY replayed exchange (`agent-org-buffer--record-clock-p' nil means
`agent-org-buffer-begin-exchange' never stamped one) — and consumes the
stamp first, so a second boundary call cannot file a second clock.

The shape is Org's own, chosen so the user's clocking and Org's tools meet
no surprise (user order: \"Your clocking MUSTN'T block user's Org
clocking\"):

  - the property drawer sits DIRECTLY under the heading, which is where
    `org-entry-get', `org-set-property' and completion look for it, with
    the exact whole seconds under `:RESPONSE:' — the measurement;
  - the closed range lives in a `:LOGBOOK:' drawer under it, which is where
    `org-clock-into-drawer' files completed clocks, so a user who later
    runs `org-clock-in' on the exchange gets their OWN planning `CLOCK:'
    line under the drawers and nothing of ours moves;
  - the line itself is `org-clock-in' format: minute-granular timestamps
    from `org-time-stamp-formats' and an `=>' duration COMPUTED from those
    timestamps, exactly as `org-clock-out' writes it.  A range of two equal
    minutes and a duration of `0:00' for a 40-second answer is therefore
    the honest canonical rendering — the minutes say what Org's own
    duration tools will count, and the seconds live in the property.

An OPEN `CLOCK:' line (no `--', no duration) is deliberately never written:
that is the one form `org-clock-load' would mistake for a running clock,
and a chat full of running clocks is how our recording would block the
user's own.

Always called with the chat buffer current."
  (when-let* ((start agent-org-buffer--turn-start))
    (setq agent-org-buffer--turn-start nil)    ; spend it: one clock per turn
    (when-let* ((anchor (agent-org-buffer--live-mark
                         agent-org-buffer--turn-anchor))
                (inhibit-read-only t))
      (let* ((end (current-time))
             (seconds (max 0 (floor (float-time (time-subtract end start)))))
             ;; A clock line's timestamps are INACTIVE — `[YYYY-MM-DD Day H:MM]' —
             ;; the exact form `org-clock' writes and `org-clock-parse-clock-line'
             ;; reads.  `org-time-stamp-formats'' CAR is date-only (no %H:%M) and
             ;; NEITHER half carries brackets, so the string is built from its CDR
             ;; wrapped in `[...]': the car would give two equal day-stamps and a
             ;; 75-minute answer would render as `0:00' with no parseable range.
             (ts-fmt (concat "[" (cdr org-time-stamp-formats) "]"))
             (ts-start (format-time-string ts-fmt start))
             (ts-end (format-time-string ts-fmt end))
             ;; the duration Org will read: computed from the minute-truncated
             ;; timestamps we just wrote, never from `seconds', so the range
             ;; is internally consistent for Org's own clock parsers
             (range (max 0 (floor (- (org-time-string-to-seconds ts-end)
                                     (org-time-string-to-seconds ts-start)))))
             (lines (format ":PROPERTIES:\n:RESPONSE: %d\n:END:\n:LOGBOOK:\nCLOCK: %s--%s =>  %d:%02d\n:END:\n"
                            seconds ts-start ts-end
                            (/ range 3600) (% (/ range 60) 60))))
        (save-excursion
          (goto-char anchor)
          (forward-line 1)                     ; bol of the line after the heading
          (let ((beg (point)))
            (insert lines)
            (agent-org-buffer--protect beg (point))))))))

(defun agent-org-buffer-end-agent-turn (buffer)
  "Finish the streaming Agent turn in BUFFER.
Font-lock is left as it was -- streaming never turned it off, so there
is nothing to re-enable here.  `save-excursion' for the same reason as
`agent-org-buffer-start-agent-turn': the turn can end under a live
draft, and point belongs with the user, not on the box's anchor.

The quote block needs no closing line — the answer was written INSIDE the
block for the whole turn (`agent-org-buffer--text-end'), so the buffer has
been valid Org since the first chunk.  What is left is bookkeeping: freeze
the line the converter still owns, end it inside the block, and drop the
furniture entirely if the agent never said anything."
  (with-current-buffer buffer
    (save-excursion
      (let ((inhibit-read-only t))
        (when agent-org-buffer--streaming-p
          ;; End the line the converter still owns and close a fence the agent
          ;; never closed; the text itself is already in the buffer, so this is
          ;; bookkeeping, not a paint (see the flush's docstring).  It lands
          ;; inside the block, because `--text-end' is the closing marker while
          ;; one is live.
          (agent-org-buffer--markdown-flush-here)
          (goto-char (agent-org-buffer--text-end))
          (unless (bolp) (insert "\n"))
          (agent-org-buffer--drop-empty-response)
          (setq agent-org-buffer--streaming-p nil
                agent-org-buffer--stream-start nil))
        ;; The response clock closes at EVERY boundary, streaming or not:
        ;; a tool-only turn answered in 90 seconds measured just as well as
        ;; a paragraph, and a cancelled turn's elapsed time is the number
        ;; the user wanted when they asked for a killable session.  Outside
        ;; the `when' above so a late second call still finds the stamp
        ;; spent rather than a second clock.
        (agent-org-buffer--close-response-clock)))))

(defun agent-org-buffer-append-chunk (buffer text session)
  "Append TEXT chunk from agent into BUFFER.
Opens this exchange's answer block if one isn't already streaming.

With `agent-org-convert-markdown' (the default) the chunk goes to
`agent-org-buffer--markdown-receive', which converts it and keeps only the last,
still-arriving line provisional — so what the buffer holds is always what the
user reads, and the transcript mirrors that.  Without it the agent's bytes land
as they were sent — but still through
`agent-org-buffer--response-safe-lines', because verbatim is a rendering
sentence, not a licence to let a `*' bullet end the answer's own quote block."
  (when (and text (not (string-empty-p text)))
    (agent-org-buffer-start-agent-turn buffer session)
    (with-current-buffer buffer
      ;; a reply chunk is non-tool activity too, and the commoner of the two:
      ;; text streams, a tool runs, more text streams.  Sealing here is what
      ;; makes the next call's drawer land below what the agent says from here
      ;; on rather than inside the board opened before it
      (agent-org-buffer--seal-tool-board)
      (if agent-org-convert-markdown
          (agent-org-buffer--markdown-receive text)
        (let ((inhibit-read-only t))
          (save-excursion
            (goto-char (agent-org-buffer--text-end))
            (let ((beg (point)))
              (insert (mapconcat #'identity
                                 (agent-org-buffer--response-safe-lines text)
                                 "\n"))
              (unless (bolp) (insert "\n"))
              (agent-org-buffer--protect beg (point))
              (agent-org-buffer--advance-text-end (point)))))))))

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

(defun agent-org-buffer--redraw-drawer (buffer name lines &optional fold fresh)
  "Replace the current turn's :NAME: drawer in BUFFER with LINES (list of strings).
Creates the drawer at the end of the turn region when absent -- folded
when FOLD is non-nil, open when it is nil -- and, when the drawer is
already there, swaps the body in place and settles the fold by the SAME
FOLD.  FOLD is therefore the drawer's DEFAULT, not a one-time instruction
at creation: a drawer whose default is folded keeps whatever fold it is in,
so one the user opened stays open, while a drawer whose default is open is
left open by every paint, because Org re-hides drawers in paths no variable
guards and a board must not quietly collapse the agent's next action.  The
`:thinking:' drawer's default is folded (the raw reasoning is not the point
of the turn), the `:tool:' drawer's open (what the agent is running right
now is).  The search is bounded by the turn anchor, not the last heading,
because the turn's drawers and body lines all trail that heading -- and it
STARTS below the answer's closing `#+end_quote', not at the heading, because
an agent that quotes a transcript back at you can put the word `:thinking:'
in its own text, and a search from the heading would find that line and
redraw the reply instead of the drawer.  Fold
state is driven with `org-fold-region' directly:
`org-fold-hide-drawer-toggle' validates the org-element cache, which
is stale for the just-streamed region until it is re-fontified, and
raises \"Not at a drawer\".

FRESH is how the caller says there is NO drawer to reuse: the search is
skipped and a new one is opened at the end of the turn, leaving the previous
drawer's text and fold where they are.  It is the difference between one
`:tool:' board per turn and one per run of consecutive calls -- see
`agent-org-buffer--tool-drawer-live-p' and the user's \"New :tool: calls should
always appear at the end of response, not a previous drawer\".  A `:thinking:'
drawer never passes it, because thought and tools are never interleaved into
one drawer's body."
  (with-current-buffer buffer
    (let ((inhibit-read-only t)
          (body (mapconcat #'identity lines "\n")))
      (save-excursion
        (let* ((turn-end (agent-org-buffer--render-end))
               (anchor-pos (agent-org-buffer--live-mark
                            agent-org-buffer--turn-anchor))
               (mark-pos (agent-org-buffer--live-mark
                          agent-org-buffer--quote-end))
               ;; The search starts BELOW the answer's end marker whenever
               ;; there is room below it (the live type-ahead box or queue,
               ;; so a `:thinking:' line inside the agent's OWN text cannot
               ;; be mistaken for the drawer).  But a drawer created with
               ;; nothing under the marker makes the rear-advancing marker
               ;; jump past its own `:end:' --- at that instant marker IS
               ;; turn-end --- and searching from there would miss the very
               ;; drawer it just leapt over and paint a second one below.
               ;; When that jump has happened, start at the turn anchor
               ;; instead: the drawer is between the anchor and the marker,
               ;; and the marker sitting exactly at the end of the last
               ;; drawer's body line makes the search find it.
               (region-start (if (and mark-pos (< mark-pos turn-end))
                                 mark-pos
                               (or anchor-pos mark-pos turn-end)))
               ;; While a turn streams it runs from its anchor to
               ;; `turn-end': the live type-ahead box trails it, so the
               ;; search stops at the box rather than at `point-max'.
               ;; Without a box (a replay) `turn-end' IS `point-max'.
               (drawer-beg
                (and (not fresh)
                     (save-excursion
                       (goto-char region-start)
                       (when (re-search-forward (format "^:%s:$" name) turn-end t)
                         (match-beginning 0))))))
          (if (not drawer-beg)
              (let ((answer-mark (agent-org-buffer--live-mark
                                  agent-org-buffer--quote-end)))
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
                      (org-fold-region content (line-end-position) t 'drawer))))
                ;; Pull the answer's marker back above the drawer we just laid
                ;; down.  A rear-advancing marker sits at the end of the answer
                ;; text, and a drawer created here -- which is `render-end',
                ;; i.e. the very bottom, the same position the marker holds
                ;; whenever nothing trails the answer yet -- slides that marker
                ;; past the separator AND the whole board, so the next chunk of
                ;; prose would land UNDER the drawers while an empty `Agent:'
                ;; line stayed on top.  The answer text always ends above this
                ;; drawer (the drawer is drawn below everything in the turn), so
                ;; restoring the marker to where it stood before the separator
                ;; keeps every future chunk in the text and never under the
                ;; board -- the ordering the user asked for.  Captured before
                ;; the separator so the blank line that precedes the drawer
                ;; stays BELOW the answer, not between prefix and prose.
                (when (and (markerp agent-org-buffer--quote-end) answer-mark)
                  (move-marker agent-org-buffer--quote-end answer-mark)))
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
                   ;; A drawer whose DEFAULT is folded keeps whatever fold
                   ;; it is in now, so one the user opened stays open.  A
                   ;; drawer whose default is OPEN is left open by every
                   ;; paint: Org re-hides drawers in paths no flag guards
                   ;; (a subtree move runs
                   ;; `org-clean-visibility-after-subtree-move',
                   ;; org.el:7089), and a board that stayed folded after
                   ;; that would hide what the agent is doing right now.
                   (keep (and fold (invisible-p content))))
              ;; Only when the body really IS folded: `org-fold-region'
              ;; walks the region, and an unconditional call on the open
              ;; board of a heavy turn doubled the per-paint cost (measured
              ;; in `test-agent-org-one-drawer-board-redraw-cost').  The
              ;; un-hide still has to happen BEFORE the delete, because a
              ;; fold Org stores as an overlay would otherwise survive it
              ;; and cover the freshly inserted body.
              (when (invisible-p content)
                (org-fold-region content drawer-end keep 'drawer))
              (delete-region content body-end)
              (goto-char content)
              (insert body "\n")
              (agent-org-buffer--protect content (point))
              (when keep
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
      ;; a thought is non-tool activity: the run of calls it interrupts gets a
      ;; drawer of its own, and the next call opens a new one BELOW the thought
      ;; instead of joining the board above it
      (agent-org-buffer--seal-tool-board)
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

(defun agent-org-buffer--tool-entry-final-p (entry)
  "Non-nil when tool call ENTRY has reached a state it will not leave.
ACP's statuses are `pending', `in_progress', `completed' and `failed' (see
`agent-org-buffer--tool-keyword'); the last two are terminal.  A call that is
still `pending' or `in_progress' can report again, and that report has to land
WHERE THE USER SAW IT START -- which is the rule that keeps an unfinished call
in the live drawer (see `agent-org-buffer--seal-tool-board').

`member', not `memq': the status arrives from `json-parse-string' as a fresh
string, and `memq' against a literal string is both wrong and a byte-compile
error (\"called with literal string that may never match\")."
  (and (plist-get (cdr entry) :status)
       (member (plist-get (cdr entry) :status) '("completed" "failed"))))

(defun agent-org-buffer--seal-tool-board ()
  "End the live `:tool:' drawer so the next tool call opens a NEW one.
Called from the two places where the agent does something that is not a tool
call -- `agent-org-buffer-append-thought' and `agent-org-buffer-append-chunk' --
because either one is evidence that the agent moved on, and a call made after it
belongs BELOW what the agent has said since, not inside the drawer that was
opened before.  That is the user's order: \"Activity order MUST be kept.  New
:tool: calls should always appear at the end of response, not a previous
drawer.\", after \"The order of tool call and response/thinking separates them.
Activity order gets precedence.\"

AN UNFINISHED CALL BLOCKS THE SEAL, and that is the whole subtlety.  The board
is a window on the record, so advancing the window is what takes entries out of
the drawer's body -- and a call the agent is still running WILL report again
(`in_progress' then `completed'), often after it has said something in between.
Sealing past it would move it out of the drawer the user is looking at, and the
completion would have nowhere to render: the call would sit at TODO for the rest
of the turn, or, worse, vanish from the board when the window next repaints.  So
the drawer is only closed once every call in it is terminal, and until then it
keeps taking new calls.  A live agent's tools finish, so this is a short wait;
a stalled one keeps its board, which is what a user watching a stall wants.

Sealing an EMPTY window is a no-op, and that is the common case rather than a
detail: an agent usually thinks before its first call, so sealing on that first
thought must not manufacture an empty drawer above the real one
(`test-agent-org-activity-before-any-call-opens-no-empty-drawer').

`agent-org-buffer--tools-shown' is cleared with it, and has to be: the
redraw guard compares the body the next window would paint against the one
last painted, so a new window whose first call renders to the same text as
the sealed board's last call -- same title, same keyword, no output, which
is exactly what two calls to the same tool look like -- would be skipped and
the call would never appear."
  (let ((live (nthcdr agent-org-buffer--tool-group-start
                      agent-org-buffer--tools)))
    (when (and live (cl-every #'agent-org-buffer--tool-entry-final-p live))
      (setq agent-org-buffer--tool-group-start (length agent-org-buffer--tools)
            agent-org-buffer--tool-drawer-live-p nil
            agent-org-buffer--tools-shown nil))))

(defun agent-org-buffer--tool-board-body ()
  "This turn's `:tool:' drawer body: one item per call, its output under it.
Built from `agent-org-buffer--tools', so the drawer cannot drift from the
record: a call is `  - KEYWORD title' and, when it printed anything, that
text is the item's body at four columns.  A call is named by its TITLE and
needs no number to point at a second drawer, because there is no second
drawer -- the user's order: \"Tool call outputs belong to the same TODO
headings\", after \"Consecutive tool calls belong to a single drawer\".

THE BOARD IS A WINDOW, not the whole turn: only the calls from
`agent-org-buffer--tool-group-start' onward are drawn, because the ones before
it already own a drawer further up the turn -- the one that was live when they
ran (`agent-org-buffer--seal-tool-board').  Drawing them again would put the
same call in two drawers, and the copy written here would sit at the END of the
response while the record says it ran at the top of it.

WHY THE LIST IS INDENTED TWO COLUMNS, not flush at the left margin like an
ordinary Org list: nothing in a drawer body may sit at column 0, which is
this package's standing rule, and the parser is the reason.  Measured with
`org-element-parse-buffer' on a buffer that already has the turn's
heading, an item at column 0 with a body at two columns reported NO list at
all (a drawer of loose text), while the same content with the list at two
and the body at four reported one plain-list with its items, the drawer
intact and the turn's single headline untouched.

`agent-org-buffer--drawer-safe-lines' runs on every output first (it is
what stops a `* heading' or a bare `:END:' line in a shell result from
dissolving the drawer), and a non-blank line then takes three further
spaces to reach the item's content column.  The title is flattened by
`agent-org-buffer--label': agent titles are whole shell commands."
  (let (lines)
    (dolist (entry (nthcdr agent-org-buffer--tool-group-start
                          agent-org-buffer--tools))
      (push (format "  - %s %s"
                    (agent-org-buffer--tool-keyword
                     (plist-get (cdr entry) :status))
                    (agent-org-buffer--label
                     (or (plist-get (cdr entry) :title) "tool")))
            lines)
      (let ((output (plist-get (cdr entry) :output)))
        (when (and output (not (string-empty-p output)))
          (dolist (line (agent-org-buffer--drawer-safe-lines output))
            (push (if (string-empty-p line) "" (concat "   " line)) lines))))
      (push "" lines))
    (nreverse lines)))

(defun agent-org-buffer-insert-tool (buffer content)
  "Record the tool call or update CONTENT, then repaint the turn's one board.
CONTENT is the tool-call alist from the ACP notification.  Each toolCallId
owns exactly one ITEM of the current turn's `:tool:' drawer -- `  - KEYWORD
title', with what the call printed indented under it.  KEYWORD maps the ACP
status onto the per-file TODO set (`agent-org-buffer--todo-setup'):
TODO, ONGOING, COMPLETE, FAILED.  Later updates overwrite the stored
title/status/output and the WHOLE drawer is redrawn from
`agent-org-buffer--tools', so an id can never sprout a second item and no
per-call marker can go stale -- the list is the record, its order the order
the agent made the calls.  The id never appears on the line: it is the
agent's bookkeeping, and the entry looked up under it already owns the line.

ITEMS, not headings: Org forbids headlines inside drawers (info \"(org)
Drawers\"), so a call that sits in a `:tool:' drawer cannot be a `**'
heading.  That is the user's own order -- \"Tool calls should be inside
:tool: drawers\" -- and the reason `**' disappeared from the turn.  What the
user asked for is what an item gives: the output belongs to the SAME call
line, in the SAME fold, not in a second drawer matched by title.

The paint is one `agent-org-buffer--redraw-drawer' of the whole body, guarded
by `agent-org-buffer--tools-shown': building a string and comparing it is
far cheaper than re-inserting and re-protecting a turn's worth of shell
output on an update that changed nothing.  A call with no output costs no
body lines."
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
            (setq entry (list :title nil :status nil :output nil)
                  agent-org-buffer--tools
                  (append agent-org-buffer--tools (list (cons id entry)))))
          (when title (plist-put entry :title title))
          (when status (plist-put entry :status status))
          ;; last non-empty report wins, the way agent-shell patches a
          ;; stored call: an update that carries no `content' is a status
          ;; change, not a rewrite of what the tool printed
          (let ((output (agent-org-buffer--tool-output content)))
            (unless (string-empty-p output) (plist-put entry :output output))))
        ;; render-time fallbacks live in the builder, never in the record, so
        ;; a title-less update cannot downgrade the title.  FRESH is read BEFORE
        ;; the flag is set: it asks whether a drawer was open when this call
        ;; arrived, which is the one thing the flag is about to stop being.
        (let* ((fresh (not agent-org-buffer--tool-drawer-live-p))
               (body (agent-org-buffer--tool-board-body)))
          (unless (equal body agent-org-buffer--tools-shown)
            (setq agent-org-buffer--tools-shown body
                  ;; the drawer this body was painted into is now the live one,
                  ;; so the NEXT call reuses it -- unless a thought or a reply
                  ;; has sealed it since, which is what FRESH asked about
                  agent-org-buffer--tool-drawer-live-p t)
            (agent-org-buffer--redraw-drawer buffer "tool" body nil fresh)))))))

;;;; Transcript file

(defcustom agent-org-transcribe t
  "When non-nil, each chat session is mirrored to its own Org file.
One file per session, named for its ACP session id, rewritten at every
turn boundary.  Off, no file is created and no disk is touched: a chat
whose transcript is a real org file under version control does not want
a second copy appearing behind it.

The file is a MIRROR of the buffer, not an append log.  That choice is
forced by the tool drawer: its item for one call is rewritten in place
TODO→ONGOING→COMPLETE, so an append-only log would keep every superseded
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

(defcustom agent-org-transcripts-read-only t
  "Open an agent-org transcript read-only when a buffer visits one.
A transcript is the MIRROR the package rewrites at every turn boundary
(`agent-org-buffer-transcribe'): a source of truth to READ, not edit.  Any
hand edit to it is thrown away by the next write, so `find-file' on one sets
`buffer-read-only' and says so, and `C-x C-q' still unlocks the buffer when
editing the file really is intended.  nil turns this off and leaves a
transcript editable like any other Org file."
  :type 'boolean
  :group 'agent-org-buffer)

(defun agent-org-buffer--transcript-file-p (file)
  "Non-nil when FILE is an agent-org transcript, judged by its directory.
The transcript's NAME is a sanitized session id and carries no marker of its
own, so the containing DIRECTORY is the signal: transcripts sit directly
inside a directory named like `agent-org-transcript-directory' (`.agent-org'
by default, or whatever basename an absolute setting ends in).  A relative
setting is reduced to its basename here, so the answer is the same whatever
`default-directory' happens to resolve it against.

Judged on the path alone, so it works for a file no session has open -- that
is exactly when a person `find-file's a transcript to read it."
  (when-let* ((dir (file-name-directory file))
              (parent (file-name-nondirectory (directory-file-name dir)))
              (wanted (file-name-nondirectory
                        (directory-file-name
                         (expand-file-name agent-org-transcript-directory)))))
    (and (> (length parent) 0)
         (string-equal parent wanted))))

(defvar-local agent-org-buffer--transcript-cache nil
  "The exact text last written to this buffer's transcript file.
A boundary can fire with nothing new — a repeated title push, a second
Ready, a usage update that changed the header but not the conversation —
and the write is a whole-file `write-region'.  Comparing against what was
last put there skips those, and keeps the file's mtime honest: an
untouched transcript does not look like it was edited.")

(defun agent-org-buffer-transcribe (buffer &optional force)
  "Mirror BUFFER's conversation to its transcript file, when it changed.
The mirror is the frozen body — `point-min' to
`agent-org-buffer--render-end' — which is exactly the conversation and
nothing else: the same marker that keeps a streaming turn from
scribbling over the user's draft separates \"sent\" from \"still
typing\".  The metadata block is inside that range; the queue block is not,
and `agent-org-buffer-transcribe' adds it, because a prompt the user sent
into a busy session is neither conversation yet nor a draft.

Called from turn boundaries and from the queue's own mutations (see
agent-org.el), never from a render site: twenty chunks of an answer cost
no writes, so a slow disk cannot stall a stream.  No-op with
`agent-org-transcribe' nil, or before the agent has given the session an
id.

The waiting prompts are NOT in that range — `--render-end' answers with
the queue region's own start so a turn can never bury them — so the block
is appended here from `:queued', the session's list.  Not copied from the
buffer: the region is the user's text and may be half-edited, and the
drain takes the list, so the list is what a resume must find.  The block is
the renderer's own output, so the file shows the same `* TODO'
headlines the chat shows, in the same order, and
`agent-org-buffer-transcript-queue' reads them back with the same parser.

LITE is the third gate, and it is not \"no file\": a lite session writes its
file while `:queued' is non-nil and stops the moment the queue drains.  The
queue is the one piece of conversation text that exists NOWHERE ELSE — it was
never sent, so it is in no `session/load' replay and in no `* User' heading
(see `agent-org-buffer-transcript-queue') — so dropping it to save a 3–15 ms
write trades the record of a prompt against the mirror of history the agent
itself can replay.  The queue wins; the mirror waits for it.

FORCE is the SYNC path (`agent-org-transcript-sync'), not a boundary: it
ignores the two guards above that merely save a write — the
`agent-org-buffer--transcript-cache' equality and the LITE gate — so the file
catches up with the buffer NOW even when the rendered text is unchanged and
even in lite mode.  It does not override `agent-org-transcribe' nil or a
session with no id yet: FORCE asks the mirror to catch up, not to keep a file
the user turned off."
  (when (and agent-org-transcribe (buffer-live-p buffer))
    (with-current-buffer buffer
      (let* ((status agent-org-buffer--status)
             (session-id (plist-get status :session-id))
             (queue (plist-get status :queued))
             (lite (agent-org-lite-p)))
        (when (and session-id (or force (not lite) queue))
          (let ((text (concat (buffer-substring-no-properties
                               (point-min) (agent-org-buffer--render-end))
                              (agent-org-buffer-render-queue queue))))
            (when (or force (not (equal text agent-org-buffer--transcript-cache)))
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
`* User' heading.  The queue block `agent-org-buffer-transcribe' appended to
the last session's mirror is the only copy that survives.

The block is found by its preamble (`agent-org-buffer--queue-note-text'),
which the renderer writes and a conversation line cannot be — and the LAST
such match is the one taken, because the block is always the final thing in
the file.  Slicing from there means the entries are read by
`agent-org-buffer--queue-parse-text', the same reader the live region uses,
so a file written by one version cannot mean something else to another.

Called with the chat buffer current, so the file resolves against the same
project the writer used — looking in the wrong directory would silently
restore nothing.

nil is the ordinary answer: no file (`agent-org-transcribe' off, a session
older than the feature, or one that never queued anything), or a block with
no entries in it.  An unreadable file is nil too: a transcript is a
convenience, and one that cannot be read must not stop a session loading."
  (when session-id
    (let ((file (agent-org-buffer--transcript-file session-id)))
      (when (file-readable-p file)
        (condition-case nil
            (with-temp-buffer
              (insert-file-contents file)
              (goto-char (point-min))
              (let ((note (regexp-quote agent-org-buffer--queue-note-text))
                    (beg nil))
                (while (re-search-forward note nil t)
                  (setq beg (match-beginning 0)))
                (when beg
                  (agent-org-buffer--queue-parse-text
                   (buffer-substring-no-properties beg (point-max))))))
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

(defun agent-org-buffer--find-file-read-only ()
  "Open the current buffer read-only if it is visiting a transcript.
Installed on `find-file-hook' below.  A no-op for anything that is not a
transcript (see `agent-org-buffer--transcript-file-p') or when
`agent-org-transcripts-read-only' is nil, so a global hook costs one string
comparison per file visit and changes no other buffer.  `write-region' from
the transcriber is unaffected: it writes the FILE with VISIT nil and does not
go through this buffer's `buffer-read-only', so a mirror still updates while
it is on screen read-only."
  (when (and agent-org-transcripts-read-only
             (buffer-file-name)
             (agent-org-buffer--transcript-file-p (buffer-file-name)))
    (setq-local buffer-read-only t)
    (message "agent-org: transcript is a mirror, opened read-only (C-x C-q to edit)")))

(add-hook 'find-file-hook #'agent-org-buffer--find-file-read-only)

(provide 'agent-org-buffer)
;;; agent-org-buffer.el ends here
