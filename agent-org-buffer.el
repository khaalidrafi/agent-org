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
;; columns, using the tool keyword set (`agent-org-tool-todo-keywords',
;; installed through `org-todo-keywords' -- see
;; `agent-org-buffer--install-todo-keywords'): pending→TODO,
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
;; body holds conversation (prompt/answer turns, per-turn :tool: and
;; :thinking: drawers) plus one auto-managed metadata block at the very
;; top: a PROPERTIES drawer first, then the `#+TITLE:' keyword line (the
;; harness's own session title, verbatim), then
;; COMMANDS/MODES/CONFIG drawers — drawers folded by default, and no
;; heading, since `* ' lines belong to the conversation.  No keyword setup
;; line: TODO states travel through `org-todo-keywords', scoped to the
;; buffer, so the block never declares anything and a rebuild never parses
;; anything (see `agent-org-buffer--install-todo-keywords').
;;
;; Design (agent-shell-style always-typable buffer):
;;   - No comint, no terminal, no global read-only — just Org text.
;;   - Programmatic text (headings, streamed chunks, tool calls,
;;     thoughts) is frozen with the `read-only' text property: the
;;     cursor may travel over history freely, but editing it signals
;;     `text-read-only'.
;;   - The buffer always ends in a live `* PROMPT' type-ahead box: the
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
- No whole-buffer Org reparse per metadata rebuild.  A full session used to pay
  one `org-set-regexps-and-options' re-read of the WHOLE buffer per rebuild --
  the call existed to pick up the metadata block's `#+TODO:' line -- and a lite
  session paid it once.  The keyword sets now come from `org-todo-keywords',
  installed when the buffer starts (`agent-org-buffer--install-todo-keywords'),
  so no rebuild parses anything and this third gate has no code behind it: the
  saving went to BOTH modes, which is the better outcome and the reason it is
  still listed here rather than quietly dropped.

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

(defcustom agent-org-sticky-heading t
  "When non-nil, pin the prompt you are reading to the top of the window.
User order (2026-10-13): \"stick prompt headings to the top as buffer is
scrolled down.  They will be contained in one line and truncated when scrolled
down.\"  One heading per exchange (§1) means the question IS the heading, so
scrolling into a long answer loses the line that says what the answer answers;
the pin puts it back.

Emacs 30.2 has no sticky-line facility -- the manual's `sticky' is either a
text property (rear/front-nonsticky) or a frame parameter -- so this is a
buffer-local `window-scroll-functions' hook feeding a SECOND header-line row.
The first row stays §6's ONE status string.  nil turns the feature off and
clears a pin already raised, so the setting takes effect on the chat you are
looking at rather than only the next one.

One pin per BUFFER, not per window: two windows on one chat share the value,
and the row follows whichever window scrolled last."
  :type 'boolean
  :group 'agent-org-buffer)

(defconst agent-org-sticky-heading-ellipsis "…"
  "What a truncated pinned heading ends with.
Not an option: the row's width arithmetic is asserted in the tests, and a
wider ellipsis would silently change what fits a narrow window.")

(defconst agent-org-sticky-heading-regexp "^\\* "
  "A level-1 headline: its star and the space after it, at column 0.
Level 1 is the exchange and level 2 is a part of the answer, and only the
exchange is pinned -- a part's keyword changes every few seconds while the
agent works, the prompt does not.
Column 0 is what makes a plain string search sound here: §3.2 keeps every
agent-supplied line indented by one space, so a `*' can never start a line
inside an answer, a quote or a drawer.")

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
later `C-c a m' renames the NEXT answer and leaves the older ones alone."
  :type 'boolean
  :group 'agent-org-buffer)

(defcustom agent-org-activity-style 'headings
  "How a turn's thinking, text and tool calls are put on the page.
The DEFAULT is `headings', on the user's order of 2026-10-09: \"we'll use TODO
subheadings for EACH part of the response - thinking, text, tool calls.  And,
each of them should be clocked.\"  A part is a headline, so it owns a
`:LOGBOOK:' and Org's own tools (TAB, a clock table, `org-clock-sum') apply to
it.

`headings' each part IS a TODO headline (`** COMPLETE Read file'), a thinking
           run is one `** TODO Thinking' headline, and the answer opens with
           `** RESPONDING <model>' and settles to `** RESPONDED <model>'.
           Parts land in the order they happened, newest at the bottom, and
           every one of them is clocked.  Folding is Org's own subtree fold --
           this package runs no fold code at all in this mode.
`drawers'  each run of calls sits in one `:tool:' drawer and each run of
           thinking in one `:thinking:' drawer, the calls as list items, the
           answer's prose pinned ABOVE them (the pre-2026-10-09 reading: one
           block to scroll back to, at the price of strict order).  Thinking
           drawers and boards fold by Org's own drawer visibility; the tool
           board is drawn open, the thinking drawer folded.
`none'     no container at all.  A call is a plain list item in the turn's body
           with its output under it, and a thinking run is a `Thinking:'
           paragraph.  Nothing to open, nothing to fold.

Headlines are why this is an option and not a fix: Org forbids a headline
inside a drawer (info \"(org) Drawers\"), so a call can be a `**' or it can sit
in a `:tool:' drawer, never both.  All three keyword sets are installed in every
chat whatever this says, so switching the style mid-conversation restyles the
turns it paints next and needs no reparse; a transcript opened from disk gets
them too, at visit (`agent-org-buffer--find-file-transcript').

The record is the same in all three modes (`agent-org-buffer--tools' is the
turn's calls in call order, `agent-org-buffer--thought' the current thinking
run), so only the paint changes and no mode can disagree with another about
what the agent did."
  :type '(choice (const :tag "TODO headlines, one per part, clocked" headings)
                 (const :tag "Drawers (:tool: / :thinking:)" drawers)
                 (const :tag "No container" none))
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
:mode-name :project :title :used :size :tokens :cost-amount :cost-currency
:commands :modes-list :config :queued.  STATE is one of `idle', `starting',
`loading' (session/load replay in flight), `streaming', `ready', `awaiting'
or `error'.  The list keys hold wire-format alists collected from ACP
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

(defun agent-org-buffer--mode-display (status)
  "Permission-mode string to SHOW for STATUS: the agent's label, else the id.
The id is the wire value (`yolo' for Qoder's bypass-permissions mode) and
the name is what the agent calls it in its own UI (\"Bypass Permissions\")
— the user's order was to show the second.  A `current_mode_update'
carries only the id, so the name can be missing; the id is the fallback
rather than nil, the same way `--model-display' works."
  (or (plist-get status :mode-name) (plist-get status :mode)))

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
                        (agent-org-buffer--mode-display status)
                        (plist-get status :project)
                        (agent-org-buffer--context-indicator status)
                        (agent-org-buffer--cost-indicator status)
                        (propertize (car seg) 'face (cdr seg))))
             " ➤ "))))

(defvar-local agent-org-buffer--sticky-heading nil
  "The heading pinned at the top edge of the window showing this chat, or nil.
Written only by `agent-org-buffer--sticky-update' (a buffer-local
`window-scroll-functions' entry) and read only by
`agent-org-buffer--render-header-lines'.  It is a DISPLAY copy of a line already
in the buffer: nothing here writes text into the body, which §14's byte mirror
and §17's repaint markers both depend on.")

(defun agent-org-buffer--sticky-heading-at (top &optional width)
  "The level-1 heading line above buffer position TOP, as one display line.
WIDTH is the window's body width in columns, defaulting to the selected
window's; the line is truncated to it, so the header can never WRAP and push
the status row off the bar.

nil when there is nothing to pin, which is the two common states: TOP is on a
headline of its own -- it is on the page already, and a second copy of it is
noise -- or TOP is above the first heading, the auto-managed metadata block of
a chat that has not been asked anything yet.

Read-only and match-data-clean by `save-excursion'/`save-match-data': a scroll
hook is not allowed to move point in the user's buffer or to leave a scan's
match data behind for whatever redisplay code runs after it."
  (save-match-data
    (save-excursion
      (let ((width (or width (window-body-width))))
        (goto-char top)
        (move-beginning-of-line 1)
        (unless (looking-at agent-org-sticky-heading-regexp)
          (when (re-search-backward agent-org-sticky-heading-regexp nil t)
            (propertize
             (truncate-string-to-width
              (buffer-substring-no-properties (line-beginning-position)
                                              (line-end-position))
              width nil nil agent-org-sticky-heading-ellipsis)
             ;; Org's own level-1 face: the row says the same thing the heading
             ;; says, so it wears what the heading would have worn
             'face 'org-level-1)))))))

(defun agent-org-buffer--sticky-update (window top)
  "Record the heading pinned at WINDOW's top edge, for this buffer's header row.
`window-scroll-functions' runs this with WINDOW's buffer current and TOP as its
new top-position, which is the whole input: no window-parameter bookkeeping and
no per-frame state, at the cost of one shared value per buffer (see
`agent-org-buffer--sticky-heading').

Cost is one backward string search -- bounded by the exchange above, since the
line at TOP is where it starts -- plus one truncation, and it runs only when a
window actually scrolls, never per chunk."
  (setq agent-org-buffer--sticky-heading
        (and agent-org-sticky-heading
             (agent-org-buffer--sticky-heading-at
              top (window-body-width window)))))

(defun agent-org-buffer--render-header-lines ()
  "The chat's header line: the status row, and the pinned prompt under it.
Split from `agent-org-buffer--render-header-line' so that one stays exactly
what §6 asks for -- ONE status string -- and this adds at most a second row,
which is not a status but a heading the buffer already owns.  With nothing
pinned the bar is the single row it was before the feature, and the pin goes
BELOW the status so the status never moves."
  (let ((status (agent-org-buffer--render-header-line)))
    (if agent-org-buffer--sticky-heading
        (concat status "\n" agent-org-buffer--sticky-heading)
      status)))

;;; TODO keyword sets.
;;
;; Three SETS, not one list: a prompt answers or fails, a tool call completes
;; or fails, and an agent plan step is done or skipped -- three different verbs
;; for three different kinds of line, which is why they must not share one
;; sequence.  Org's multi-set form is what makes them coexist: `C-c C-t' on a
;; line picks the set by the keyword already on it (info "(org) Multiple
;; keyword lists"), so a `** COMPLETE ls' headline cycles through the call
;; words and can never be turned into a `RESPONDED' tool call.
;;
;; Declared through `org-todo-keywords' BUFFER-LOCALLY, not through a `#+TODO:'
;; line in the metadata block, on the user's order: "Don't use #+TODO to set
;; keywords.  Use org-todo-keywords and scope it for agent-org buffers, with
;; multi-set sequences as seen in Org manual."  The in-buffer line is also the
;; expensive way: `org-set-regexps-and-options' re-reads the WHOLE buffer, so a
;; metadata rebuild paid a full reparse of every transcript on disk (see
;; `agent-org-buffer--install-todo-keywords').

(defcustom agent-org-prompt-todo-keywords
  '("PROMPT" "RESPONDING" "IDLE" "NEXT" "WAIT"
    "|" "RESPONDED" "CANCELLED" "ERROR")
  "The set a PROMPT headline wears, mirroring the header line's state.
The user's own vocabulary, in the order a turn passes through it: `PROMPT' the
moment the question is in the buffer, RESPONDING while the agent streams, IDLE
when the turn stopped and waits on HIM (a permission request, a plan to
approve), and past the bar RESPONDED, CANCELLED (the user pressed ESC), or
ERROR (the agent exited badly).

NEXT and WAIT ride in the UNFINISHED half of this same set, and that
placement is a measurement rather than a preference: the queue's two words
(`agent-org-buffer--queue-keywords') are positions -- the head prompt says
NEXT, every one behind it WAITs -- and a set of their own cannot express
that.  Tried on Org 9.7.11: `(\"NEXT\" \"WAIT\" \"|\")' answers
`org-not-done-keywords' = (\"NEXT\") and `org-done-keywords' = (\"WAIT\"), i.e.
every waiting prompt but the first is rendered as a DONE item.  Appending
them here keeps both unfinished and keeps positions 0-2 exactly what
`agent-org-buffer--prompt-keyword-for-state' reads, so the exchange-word
mapping is untouched.
See `agent-org-buffer--prompt-keyword-for-state' for the state→word rule and
`agent-org-buffer--install-todo-keywords' for why no `#+TODO:' line exists.
Edit the list to change the words; `|' is the separator between unfinished
and done and must stay in the list.  A chat that is already open picks up a
change when `agent-org-refresh-todo-keywords' runs."
  :type '(repeat (choice :tag "Keyword or |"
                         (string :tag "Keyword")
                         (const :tag "bar between unfinished and done" "|")))
  :group 'agent-org-buffer)

(defcustom agent-org-thinking-todo-keywords
  '("THINKING" "|" "THOUGHT")
  "The set a THINKING run's headline cycles through.
A part of the response, like a call or a stretch of prose, so it gets its own
two words: the run is THINKING while chunks are arriving and THOUGHT once
anything appears below it (`agent-org-buffer--settled-keyword' takes the first
DONE word of this set).  Sharing the prompt set's TODO made a thinking run
indistinguishable from a queued prompt, which is why the sets are disjoint."
  :type '(repeat (choice :tag "Keyword or |"
                         (string :tag "Keyword")
                         (const :tag "bar between unfinished and done" "|")))
  :group 'agent-org-buffer)

(defcustom agent-org-response-todo-keywords
  '("WRITING" "|" "WROTE")
  "The set the ANSWER PROSE part's headline cycles through.
WRITING while the answer streams, WROTE at the boundary.  Separate from the
prompt set on purpose: the prompt's word reports the state of the WHOLE
exchange (see `agent-org-buffer-set-status'), this one the state of the
answer's own text, and the two differ whenever the agent thought or called
something after writing its last line."
  :type '(repeat (choice :tag "Keyword or |"
                         (string :tag "Keyword")
                         (const :tag "bar between unfinished and done" "|")))
  :group 'agent-org-buffer)

(defcustom agent-org-tool-todo-keywords
  '("RUNNING" "|" "EXECUTED" "FAILED")
  "The set a TOOL CALL part's headline cycles through.
ACP reports a call as `pending', `in_progress', `completed' or `failed' and
`agent-org-buffer--tool-keyword' maps those onto this set POSITIONALLY, never
by name: the unfinished words in order take `pending' then `in_progress', the
done words in order take `completed' then `failed'.  This set has ONE
unfinished word, so pending and in_progress both read RUNNING -- the user's
vocabulary makes no distinction between queued and started, and a customized
list with two unfinished words gets it back.
Whether the word is a STATE or TEXT depends on the activity style
(`agent-org-activity-style'): as a `** EXECUTED Read file' headline it is a
real state `C-c C-t' cycles; inside a `:tool:' drawer or a plain list item a
headline is forbidden, so the same word is only text the reader sees (info
\"(org) Drawers\")."
  :type '(repeat (choice :tag "Keyword or |"
                         (string :tag "Keyword")
                         (const :tag "bar between unfinished and done" "|")))
  :group 'agent-org-buffer)

(defcustom agent-org-plan-todo-keywords
  '("TODO" "WORKING" "|" "DONE")
  "The set an AGENT PLAN item cycles through.
ACP plans (a `session/update' of `plan' entries, and the `todowrite' tool call
harnesses use for the same list) carry `pending', `in_progress' and
`completed' -- the same three facts as a tool call, but a plan step is the
agent's OWN declared work, and a reader folds a plan and edits a tool call in
different words.  `TODO' here is the only TODO left in the installation now
that prompts have their own word, which is why this set is installed LAST: a
`* TODO' heading written by an older transcript or by the user resolves to it.
Rendered by `agent-org-buffer-insert-plan' when a plan arrives, and mirrored
to `AGENTS-TODOs.org'."
  :type '(repeat (choice :tag "Keyword or |"
                         (string :tag "Keyword")
                         (const :tag "bar between unfinished and done" "|")))
  :group 'agent-org-buffer)

(defun agent-org-buffer--todo-keyword-sets ()
  "The five sets in Org's multi-set form: a list of (sequence . KEYWORDS).
Order is part of the contract -- prompts, thinking, writing, tool calls, plan
items -- because a keyword present in more than one set is resolved by the
FIRST set that owns it, and the five defaults are DISJOINT so the order only
has to be stable, not clever (see
`test-agent-org-metadata-installs-five-disjoint-todo-sets').  Prompts stay
first and plans last because those two sets hold the words a hand-written or
legacy headline is most likely to carry (`PROMPT', `TODO')."
  (list (cons 'sequence agent-org-prompt-todo-keywords)
        (cons 'sequence agent-org-thinking-todo-keywords)
        (cons 'sequence agent-org-response-todo-keywords)
        (cons 'sequence agent-org-tool-todo-keywords)
        (cons 'sequence agent-org-plan-todo-keywords)))

(defun agent-org-buffer--install-todo-keywords ()
  "Derive this buffer's TODO regexps from the three sets.
Called with the buffer current, in three situations: a NEW chat (before
`org-mode' runs), a transcript being visited (Org has already derived the
default set there), and after one of the three option lists changes.

The mechanism is not obvious and the two facts it rests on were MEASURED
on Org 9.7.11, which is why this function is one call rather than a
`setq-local':

  - Org derives the keyword regexps while the major mode starts.  A
    buffer-local `org-todo-keywords' installed AFTER `(org-mode)' is
    invisible to that derivation, and re-calling
    `org-set-regexps-and-options' bare then RESETS the buffer to the
    global default set -- silently turning every `** COMPLETE ls'
    headline back into a headline whose first word is text.  So the value
    has to be let-bound around the call that does the deriving, and this
    function is the ONLY place the derivation happens.

  - `org-set-regexps-and-options' is what reads a variable's value into
    the buffer's own regexps for an already-live `org-mode' buffer, and it
    re-reads the whole buffer -- cheap once at visit, and exactly the cost
    the metadata rebuild used to pay per usage update when the sets lived
    in a `#+TODO:' line.

Binding `org-todo-keywords' rather than setting it buffer-locally also
dodges Emacs' \"Making org-todo-keywords buffer-local while locally
let-bound!\" warning: the derived locals (`org-todo-keywords-1' and
friends) are what has to outlive this call, and `org-set-local' makes
them so -- measured to survive the binding."
  (let ((org-todo-keywords (agent-org-buffer--todo-keyword-sets)))
    (if (derived-mode-p 'org-mode)
        (org-set-regexps-and-options)
      (org-mode))))

;;;; Clock display: total clocked time, WITH SECONDS, on every heading
;;;;
;;;; A FORK of `org-clock-display' (user order 2026-10-11), on by default in a
;;;; chat.  The fork is not taste, it is arithmetic: Org's own display sums a
;;;; subtree through `org-clock-sum', whose answer is in WHOLE MINUTES —
;;;; measured on Org 9.7.11, a 45-second `CLOCK:' range sums to 0 — and
;;;; `org-duration-from-minutes' then formats that 0 as `0:00' (or `0:00:00'
;;;; with `org-duration-format' set to `h:mm:ss', which still has no seconds to
;;;; show).  agent-org's clocks ARE second-precise (§22: the exact whole seconds
;;;; live in the heading's own `:PROPERTIES:' drawer, `:RESPONSE:' for a whole
;;;; exchange and `:SECONDS:' for one part of a response), so the totals here
;;;; come from those numbers and never pass through a minute.
;;;;
;;;; What is shown is a `display' OVERLAY over the WHOLE heading line.  That is
;;;; the whole reason this can be on by default: an overlay is not text, so
;;;; `buffer-substring-no-properties' — the transcript mirror (§14), the
;;;; queue parse (§17), the markdown rewrite (§15) and every repaint marker —
;;;; all read exactly the bytes they read before.  A heading that gained the
;;;; time as TEXT would move `--render-end', put the total in the transcript and
;;;; break the `* PROMPT' heading match on the way.
;;;;
;;;; The SHAPE is `org-clock-put-overlay''s (org-clock.el): the overlay spans
;;;; the line and displays headline + `?'-padding to column 60 + ` %9s ' in the
;;;; `org-clock-overlay' face, which is what makes the duration land at the
;;;; RIGHT of the heading instead of wherever the heading happens to end (user
;;;; order, 2026-10-13: /"the clock should be right aligned in the heading").
;;;; The padding char is Org's middle dot, not a space, so a short heading
;;;; cannot collapse the gap; and the duration goes through our own
;;;; `agent-org-clock--format' rather than Org's ` %9s' / minutes arithmetic,
;;;; which is the fork this whole section is.

(defcustom agent-org-clock-display-default t
  "Whether a chat shows clocked totals the moment it opens.
The seed of the buffer-local `agent-org-clock-display-mode', read once when
`agent-org-mode' turns on (user order 2026-10-11: \"enable it by default\"), so
it affects NEW chats — an open one toggles with \\<agent-org-mode-map>
\\[agent-org-clock-display].  Nil is the old behaviour: a chat that only shows
timings after you ask.  The NAME says DEFAULT because the command
`agent-org-clock-display' is what the user actually presses; a defcustom and a
command cannot share a name and stay readable in M-x."
  :type 'boolean
  :group 'agent-org-buffer)

(defconst agent-org-clock--exchange-property "RESPONSE"
  "The `:PROPERTIES:' key holding a whole exchange's exact seconds.
Written by `agent-org-buffer--close-response-clock' through
`agent-org-buffer--clock-lines'.")

(defconst agent-org-clock--part-property "SECONDS"
  "The `:PROPERTIES:' key holding one response part's exact seconds.
Written by `agent-org-buffer--clock-part' through
`agent-org-buffer--clock-lines'.")

(defconst agent-org-clock--overlay-category 'agent-org-clock
  "The overlay `category' naming this package's clock totals.
One symbol is how `agent-org-clock--remove' finds its own overlays and
`org-clock-remove-overlays' does not, so our display and Org's can coexist in
one buffer without either erasing the other.")

(defun agent-org-clock--format (seconds)
  "SECONDS as an Org duration, `H:MM:SS'.
The seconds half is the point of this function: `org-duration-from-minutes'
takes MINUTES and Org's callers hand it a whole number, so anything under a
minute is gone before it reaches the string.  Pure — no buffer, no time
library, no `org-duration-format' — which is why the format is test-pinned on
any machine.  SECONDS is clamped at 0: a negative range would print a minus
sign inside a heading and read as a broken clock."
  (let ((s (max 0 (floor seconds))))
    (format "%d:%02d:%02d" (/ s 3600) (% (/ s 60) 60) (% s 60))))

(defconst agent-org-clock--stamp-regexp
  (concat "\\`\\[\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\) "
          "[A-Za-z]+ \\([0-9]\\{2\\}\\):\\([0-9]\\{2\\}\\):\\([0-9]\\{2\\}\\)\\]\\'")
  "An Org stamp whose time carries SECONDS, as six capturing groups.
The groups are year, month, day, hour, minute, second.  Written in two pieces
because the whole thing on one line runs past the compiler's column limit; the
closing bracket is part of the pattern — leaving it out makes `\\'' never match,
which is how this function first answered zero for a twelve-second range.")

(defun agent-org-clock--stamp-time (stamp)
  "An Org bracketed time-stamp STRING as an Emacs time, SECONDS and all.
Org's own converter cannot be used on a stamp that carries seconds: it runs the
string through `org-parse-time-string', and Org 9.7.11 answers `(0 0 10 11 10
2026 …)' for `[… Sun 10:00:12]' — the seconds are parsed AWAY, so a
twelve-second range would sum to zero and a hand-written clock of that length
would show nothing.  Reading the six fields here and handing them to
`encode-time' with a nil zone (local time, exactly as Org reads them) is what
makes the number real.
A stamp that does not match `agent-org-clock--stamp-regexp' — the minute shape
`org-clock-in' writes, or any other Org form — goes to Org's own parser, which
reads those correctly.  We never WRITE such a stamp ourselves: §22 keeps the
`CLOCK:' line in the shape Org parses, and the exact seconds ride in the
property, which this function reads first."
  (if (string-match agent-org-clock--stamp-regexp stamp)
      (encode-time (list (string-to-number (match-string 6 stamp))
                         (string-to-number (match-string 5 stamp))
                         (string-to-number (match-string 4 stamp))
                         (string-to-number (match-string 3 stamp))
                         (string-to-number (match-string 2 stamp))
                         (string-to-number (match-string 1 stamp))
                         nil nil nil))
    (org-time-string-to-time stamp)))

(defun agent-org-clock--heading-seconds ()
  "This heading's own clocked seconds, or nil.  Point must be at a heading.
The heading's OWN `:PROPERTIES:' drawer answers first — that is the number
`agent-org-buffer--clock-lines' filed, exact to the second.  With none, the
heading's own `:LOGBOOK:' is summed instead, from its stamps at whatever
precision they carry: this is what makes a clock the USER filed with
`org-clock-in'/'-out' show up, which is the point of §22's rule that our
recording must never block theirs.
An OPEN `CLOCK:' range is skipped — a running clock is the user's Org clock and
guessing at its end here would put a number on screen that changes on its own.
`org-entry-get' is used rather than a hand-rolled search because it reads the
drawer at the top of this subtree and nothing above it: a part heading inside an
exchange must not inherit the exchange's total.

THE FAST PATH is the line straight after the heading: our furniture and Org's
BOTH live in a `:PROPERTIES:' or `:LOGBOOK:' drawer there, so a heading whose
next line is prose has nothing to read and costs one line rather than a walk of
its whole subtree — which is what makes running this at every turn boundary
affordable on the target machine."
  (when (save-excursion (forward-line 1) (looking-at-p ":\\(PROPERTIES\\|LOGBOOK\\):"))
    (or (when-let* ((raw (or (org-entry-get nil agent-org-clock--exchange-property)
                             (org-entry-get nil agent-org-clock--part-property))))
          ;; `string-match-p', not `string-match': a scan that reads match data
          ;; must not have it replaced under it by a helper (AGENTS.md).
          (and (string-match-p "\\`[0-9]+\\'" raw) (string-to-number raw)))
        (save-excursion
          (save-restriction
            (narrow-to-region (line-end-position)
                              (progn (org-end-of-subtree t t) (point)))
            (goto-char (point-min))
            (let ((total 0) (found nil))
              (while (re-search-forward
                      "^CLOCK: \\(\\[[^]]*\\]\\)--\\(\\[[^]]*\\]\\)"
                      (point-max) t)
                ;; a CLOSED range only: `CLOCK: [start]' with no `--' is a
                ;; running clock, the user's own Org clock and not ours to put
                ;; an invented end on.  BOTH stamps are copied out before any
                ;; call: `org-parse-time-string' (under
                ;; `org-time-string-to-time') runs `string-match' and replaces
                ;; the match data, so reading group 2 afterwards would see
                ;; someone else's match (AGENTS.md).
                (let ((from-stamp (match-string-no-properties 1))
                      (to-stamp (match-string-no-properties 2)))
                  (let ((from (agent-org-clock--stamp-time from-stamp))
                        (to (agent-org-clock--stamp-time to-stamp)))
                    (setq total (+ total (max 0 (floor (float-time (time-subtract to from)))))
                          found t))))
              (and found total)))))))

(defun agent-org-clock--remove ()
  "Delete this buffer's clock-total overlays.  Run with the chat current."
  (remove-overlays (point-min) (point-max) 'category agent-org-clock--overlay-category))

(defvar-local agent-org-clock--last-counts nil
  "The `(SHOWN . TOTAL-SECONDS)' of the last `agent-org-clock--draw' pass.
Buffer-local so the toggle command can report what the mode's own pass just
drew instead of walking the headings twice; nil until a pass has run, which is
also how a buffer that never displayed is told apart from one that saw no
clocks.")

(defun agent-org-clock--overlay-text (beg end seconds)
  "The `display' for a heading line BEG..END carrying SECONDS of clocked time.
Org's `org-clock-put-overlay' shape, which is what the user asked for on
2026-10-13 (\"the clock should be right aligned in the heading\"):

    * PROMPT Capital?········ 0:00:45

BEG is where the headline TEXT starts -- past the stars, exactly where Org
starts its own overlay -- because an overlay only REPLACES the text it
covers: covering the whole line would show the stars as plain text and lose
the `org-level-N' face Org gave them.  The column is measured AT BEG, the
way `org-clock-put-overlay' measures it at its own overlay start, so a
two-star and a three-star heading pad to the same place.

The headline text, then `?' padding up to the column where Org's own
display puts its duration (60, the same number
`org-clock-put-overlay' uses), then ` H:MM:SS ' in the
`org-clock-overlay' face.  The padding is what makes the alignment
mean anything: without it a 10-character heading and a 60-character
heading would end their totals in different columns.

Column 60 is Org's choice and it does not fit a narrow window -- Org's own
display has the same behaviour, so matching it is the point -- but a window
NARROWER than the padded line simply truncates the duration on screen and
`agent-org-clock--overlay-text' is never asked about it, because the padding
is computed from the heading's own columns, not from a window."
  (let ((headline (buffer-substring-no-properties beg end))
        (column (save-excursion (goto-char beg) (current-column))))
    (concat headline
            (propertize (make-string
                         (max 0 (- 60 column (string-width headline)))
                         ?·)
                        'face 'shadow)
            (propertize (format " %s " (agent-org-clock--format seconds))
                        'face 'org-clock-overlay))))

(defun agent-org-clock--draw ()
  "Show every heading's clocked total in this buffer, as overlays.
The work `agent-org-clock-display-mode' does on the way in; it is separate
because the mode would otherwise re-enter itself: the command that toggles the
mode cannot also be the function the mode's body calls.

Each heading with a timing gets its duration RIGHT-ALIGNED on the heading
line by `agent-org-clock--overlay-text', and the counts land in
`agent-org-clock--last-counts'.  It says NOTHING in the echo
area — the boundary and chat-creation callers are silent, because every status
string a chat owns belongs on its header line, not in the area
(`agent-org-buffer-set-status'), and only `agent-org-clock-display' reports the
total on the user's own request.

The total counts the EXCHANGE headings only, since a part's time is already
inside its exchange and adding both would double-count the turn.  Costs one pass
over the headings, run at a turn boundary and never per chunk (§19)."
  (agent-org-clock--remove)
  (let ((shown 0) (total 0))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when (org-at-heading-p)
          (let ((seconds (agent-org-clock--heading-seconds)))
            (when seconds
              ;; the total counts level-1 headings: one per exchange, so a
              ;; part's time is never added to the turn that already holds it
              (when (= (org-outline-level) 1)
                (setq total (+ total seconds)))
              ;; the overlay starts past the stars, where
              ;; `org-clock-put-overlay' starts its own: an overlay REPLACES
              ;; what it covers, so covering the stars would show them as
              ;; plain text and lose the `org-level-N' face Org gave them.
              (looking-at "[*]+ ")
              (let ((ov (make-overlay (match-end 0) (line-end-position))))
                (overlay-put ov 'category agent-org-clock--overlay-category)
                ;; `display', not inserted text: the transcript mirror, the
                ;; queue parse and every repaint marker read the buffer's
                ;; bytes, and those bytes must not change when a display is
                ;; drawn.
                (overlay-put ov 'display
                             (agent-org-clock--overlay-text
                              (match-end 0) (line-end-position) seconds))
                (setq shown (1+ shown))))))
        (forward-line 1)
        (while (and (not (eobp)) (not (org-at-heading-p)))
          (forward-line 1))))
    (setq agent-org-clock--last-counts (cons shown total))))

(define-minor-mode agent-org-clock-display-mode
  "Show clocked totals, in seconds, at the end of chat headings.
Buffer-local, and ON by default for a chat when
`agent-org-clock-display-default' is non-nil — which is what \"enable it by
default\" means for a display feature: a GLOBAL minor mode would put a total on
headings in files this package does not own.  Turning it off removes the
overlays and leaves the buffer's text exactly as it was.

DEFINED BEFORE `agent-org-clock-display', which reads this mode's variable: the
byte-compiler with `byte-compile-error-on-warn t' treats an unknown free
variable as an error, and the order is the only reason the two are not in
command-first reading order."
  :init-value nil
  :lighter nil
  (if agent-org-clock-display-mode
      (agent-org-clock--draw)
    (agent-org-clock--remove)))

(defun agent-org-clock-display (&optional arg)
  "Show every heading's clocked total in this chat, down to the SECOND.
The fork of `org-clock-display' — see the section above for the measurement that
made a fork necessary: Org sums a subtree in WHOLE MINUTES, so a 45-second part
displays as `0:00' there and as `0:00:45' here.

With no argument this TOGGLES the display, in this buffer only.  With a prefix
argument, turn it OFF — the escape hatch for a chat where the totals are noise.
Re-enabling re-reads the clocks, which is also how a hand-edited `:RESPONSE:'
value reaches the screen."
  (interactive "P")
  (unless (derived-mode-p 'org-mode)
    (user-error "Not an Org buffer"))
  (if arg
      (progn (agent-org-clock-display-mode -1)
             (message "[agent-org] clock display off"))
    (let ((before agent-org-clock-display-mode))
      (agent-org-clock-display-mode 'toggle)
      ;; only a pass that JUST drew reports: the boundary's silent refresh must
      ;; not steal the echo area, and neither must turning the display off
      (when (and (not before) agent-org-clock-display-mode)
        (let* ((counts (or agent-org-clock--last-counts '(0 . 0)))
               (shown (car counts)))
          (message "[agent-org] clock: %d heading%s, total %s"
                   shown
                   (if (= shown 1) "" "s")
                   (agent-org-clock--format (cdr counts))))))))

(defun agent-org-clock--refresh-duration ()
  "Recompute the `=>  H:MM' duration of the CLOCK line at point, keeping stamps.
`org-ctrl-c-ctrl-c' on a CLOCK line calls `org-clock-update-time-maybe', which
re-parses the stamps through `org-parse-time-string' — SECONDS DROPPED — and
rewrites them in `org-time-stamp-formats' (minute-granular), so it silently
deletes the seconds our stamps carry (measured on Org 9.7.11: a
`[00:30:12]--[00:30:57]' line came back `[00:30]--[00:30]').  This does what the
update is FOR and nothing else: the two stamps are read with
`agent-org-clock--stamp-time' (which sees the seconds) and the duration is their
difference truncated to the minute — the same arithmetic
`agent-org-buffer--clock-lines' files, so a hand-edited stamp is brought back
into agreement without losing the seconds.  Answers t when point was on a CLOCK
line, nil otherwise.  Runs `inhibit-read-only', because our clock block is
protected furniture and the user's `C-c C-c' must still work there."
  (beginning-of-line)
  (when (looking-at (concat "CLOCK: \\(\\[[^]]*\\]\\)--\\(\\[[^]]*\\]\\)"
                            "\\(?: =>  *[0-9]+:[0-9][0-9]\\)?$"))
    (let* ((beg (match-beginning 0))
           (end (match-end 0))
           ;; BOTH stamps are copied out BEFORE `stamp-time': it runs
           ;; `string-match' internally and would replace the match data this
           ;; scan is built on (AGENTS.md).
           (from-stamp (match-string-no-properties 1))
           (to-stamp (match-string-no-properties 2))
           (from (agent-org-clock--stamp-time from-stamp))
           (to (agent-org-clock--stamp-time to-stamp))
           ;; the stamps' own difference truncated to the minute, clamped at
           ;; zero, exactly as the writer computes it.
           (range (* 60 (max 0 (- (/ (floor (float-time to)) 60)
                                  (/ (floor (float-time from)) 60))))))
      (let ((inhibit-read-only t))
        (goto-char beg)
        (delete-region beg end)
        (insert (format "CLOCK: %s--%s =>  %d:%02d"
                        from-stamp to-stamp
                        (/ range 3600) (% (/ range 60) 60))))
      t)))

(defun agent-org-ctrl-c-ctrl-c ()
  "`C-c C-c' in a chat, without eating the seconds from a CLOCK line.
The one thing this adds to `org-ctrl-c-ctrl-c' is the CLOCK line: Org's own
handler re-parses the stamps through `org-parse-time-string' (seconds dropped)
and rewrites them minute-granular, so pressing `C-c C-c' on one of ours deletes
the seconds the transcript is meant to show (user order 2026-10-14: \"We also
need our own C-c C-c, which won't delete seconds from CLOCK line\").  On a CLOCK
line we refresh only the `=>' duration and leave the stamps alone
(`agent-org-clock--refresh-duration'); everywhere else this IS
`org-ctrl-c-ctrl-c', so refreshing a clocktable, editing a block and every other
Org gesture the chord offers still work — the package WRAPS Org here, it does
not steal the command."
  (interactive)
  (unless (agent-org-clock--refresh-duration)
    (org-ctrl-c-ctrl-c)))

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
      ;; the entry point to `org-mode' for every chat: our three keyword sets
      ;; have to be in force while the mode derives its regexps, which is the
      ;; one thing a later `setq-local' cannot retroactively do
      (agent-org-buffer--install-todo-keywords)
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
        ;; harness reports its session title
        (insert (format "#+TITLE: %s\n\n" name))
        (agent-org-buffer--protect (point-min) (point-max)))
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
  "Marker at the start of the trailing live `* PROMPT' type-ahead box.
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
prompt/response pair.  The pair's drawers are located relative to this
anchor, not to the buffer end, because the body trails it: the answer's
quote block, the `:thinking:' drawer, the `:tool:' drawer and the
type-ahead box all live after the heading, so the heading is never the
last thing in the turn.")

(defvar-local agent-org-buffer--prompt-word-p nil
  "Non-nil when the heading at `--turn-anchor' IS a prompt the user sent.
It is the permission slip for the one body-side edit the status model makes:
the heading's first word mirrors the header line
(`agent-org-buffer--set-exchange-keyword').  An ORPHAN turn -- history the agent
has with no question in front of it -- leaves this nil, because `* Agent' is not
a prompt and never had a PROMPT→RESPONDED life to report.
Set by `agent-org-buffer-begin-exchange', cleared by
`agent-org-buffer--orphan-heading'.")

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
so far when the agent THINKS something, and the next call opens a fresh drawer
below that thought.  A REPLY CHUNK seals nothing: the turn's prose is written at
the end of the answer text, which is always above every block, so a board sealed
by prose could only ever land directly below the board it came from -- two
`:tool:' drawers touching, which is the shape the user forbade (\"There CAN'T be
another :tool: drawer right after a :tool: drawer\").  Before any of this the
board was created once per turn and every later call was repainted into it, so a
call made after the agent had moved on was displayed ABOVE the words
and thoughts that preceded it and the transcript read the turn backwards.")

(defvar-local agent-org-buffer--tool-drawer-live-p nil
  "Non-nil when this turn's live `:tool:' drawer is still at the turn's end.
It is what makes the next tool call REUSE the open drawer instead of opening a
second one: `agent-org-buffer-insert-tool' passes FRESH to
`agent-org-buffer--redraw-drawer' exactly when this is nil.  A drawer sealed by
`agent-org-buffer--seal-tool-board' is closed for business -- it keeps its text
and its fold, but it is no longer where new calls go.")

(defvar-local agent-org-buffer--thought-drawer-live-p nil
  "Non-nil while the thinking run in `agent-org-buffer--thought' is the turn's
LAST block, so the next thought chunk is appended into the SAME drawer.
The other half of the pair above, and the answer to \"the thinking drawer is
above tool ones and being updated in place.  You CAN have multiple thinking
drawers\": a drawer is reused only while nothing has been drawn BELOW it,
and the one thing that gets drawn below a thought is a fresh `:tool:' board
-- so
`agent-org-buffer-insert-tool' clears this flag when it opens one.  The next
chunk then starts a second drawer and a second accumulated segment, and the
transcript reads thought, action, thought in the order it happened.

A board that is REPAINTED in place (a call that is still running, which the seal
deliberately does not close over) paints nothing below the thought, so it leaves
this flag alone and the run continues in its own drawer.")

(defvar-local agent-org-buffer--parts nil
  "Alist (KEY . PLIST) of the `headings'-style response parts drawn this turn.
KEY names the part: \"response\" for the answer prose, \"thinking\" for a
thinking run, and `tool:<toolCallId>' for one tool call.  PLIST is
\(:heading M :body-beg M :body-end M :start T :clocked P) — the three markers
say where the part is on the page, `:start' is the moment the activity appeared
(it is what its `CLOCK:' line measures from) and `:clocked' keeps a second
boundary from filing a second clock.

ONE PART PER ACTIVITY RUN, and the part is a real `**' headline, which is what
makes this style the only one that can clock a part: Org attaches a clock to a
headline, and info \"(org) Drawers\" forbids a headline inside a drawer, so a
call drawn as a `:tool:' item has no heading to clock.

Overwriting a key is deliberate and safe for \"response\"/\"thinking\": a closed
part keeps its text, its settled keyword and its clock in the buffer and nothing
ever rewrites it, so its markers are no longer needed.  A tool call's key is
never reused — the SAME id reports again (in_progress then completed) and the
part is repainted WHERE THE USER SAW IT START, which is what `:heading' and the
body markers are for.")

(defvar-local agent-org-buffer--live-part nil
  "The KEY of the part new activity appends into, or nil when none is live.
The order rule this serves is the user's: \"fix response order.  I still need to
scroll up to see what the agent said last!!\"  A part is live only while it is
the LAST thing in the exchange; the moment an activity of another kind arrives,
the live part closes and the new one opens BELOW it.  So the buffer reads in the
order things happened, newest at the bottom, and the answer's prose is no longer
pinned above the tool board — exactly the shape that made the user scroll up.
`agent-org-buffer--text-end' keeps that pin for the other two styles, where the
older order rule asked for it.")

(defvar-local agent-org-buffer--activity-marks nil
  "Alist (KIND . (BEG . END)) of markers around a block drawn WITHOUT a drawer.
Used when `agent-org-activity-style' is `none': a drawer is found again by
searching for its `:NAME:' and `:end:' lines, `headings' keeps its own markers
in `agent-org-buffer--parts', and a bare list item has neither, so its own
bounds are the only thing that can tell the painter what to replace.  KIND is
the same string the drawer would be named (\"tool\", \"thinking\").

Set when a block is created, moved to the end of the body on every repaint, and
killed with the turn reset.  A stale marker is harmless:
`agent-org-buffer--live-mark' returns nil for a marker that points into no
buffer, and the paint falls back to creating a new block.")

(defvar-local agent-org-buffer--thought nil
  "Thinking text accumulated for the current thinking RUN, rendered into this
turn's `:thinking:' drawer by `agent-org-buffer-append-thought'.
One run, not one turn: a fresh drawer starts a fresh segment, which is what
makes the drawers say different things instead of every thought of a long
turn landing in the first one (see
`agent-org-buffer--thought-drawer-live-p').")

(defvar-local agent-org-buffer--thought-tail nil
  "The thinking run's unfinished LAST LINE, as text with no newline in it.
The `headings' style APPENDS to a part instead of re-rendering the whole run (a
fresh render per arriving token is quadratic on a 4 GB machine), so it keeps the
half-said line here, both to merge with the next chunk and to know which line of
the body is provisional and may therefore be replaced.  It is ON the page: the
user reads a thought as it arrives rather than waiting for a newline, exactly as
`agent-org-buffer--md-fragment' holds prose.  Cleared when the part closes
(`agent-org-buffer--open-part') and with the turn
(`agent-org-buffer--reset-activity').")

(defvar-local agent-org-buffer--answer-written-p nil
  "Non-nil once this turn's answer has had a line of text appended.
Set by `agent-org-buffer--advance-text-end' -- the one place answer text moves
the insertion marker -- and cleared when the turn state resets.  It is how
`agent-org-buffer--drop-empty-response' tells an answer that only ever streamed
tools from one that said something: the marker has moved on by the time the turn
closes, so \"is the line under the marker blank\" is no longer a test for
emptiness (with real text it now points at the gap above a drawer, and that gap
reads blank) -- the flag is the direct record of whether any prose landed.")

(defun agent-org-buffer--reset-activity ()
  "Forget the finished turn's activity blocks, so the next turn starts clean.
The one place that lists the turn-local activity state, because forgetting
half of it is a bug with a memory in it: a live flag left set paints this
turn's first call into the PREVIOUS turn's drawer (the search is bounded to
the turn, so the worse half is that it finds nothing and the flag lies), and
a container-less block's markers left pointing at the old turn would be
REplaced by the new turn's first repaint -- deleting history to draw a
status line.

Both turn starts call this: `agent-org-buffer-begin-exchange' for a turn with a
question in front of it, `agent-org-buffer--orphan-heading' for restored history
that arrives with none."
  (dolist (cell agent-org-buffer--activity-marks)
    (dolist (m (cdr cell))
      (when (markerp m) (set-marker m nil))))
  (dolist (cell agent-org-buffer--parts)
    (dolist (m (list (plist-get (cdr cell) :heading)
                     (plist-get (cdr cell) :body-beg)
                     (plist-get (cdr cell) :body-end)))
      (when (markerp m) (set-marker m nil))))
  (setq agent-org-buffer--activity-marks nil
        agent-org-buffer--parts nil
        agent-org-buffer--live-part nil
        agent-org-buffer--tools nil
        agent-org-buffer--tools-shown nil
        agent-org-buffer--tool-group-start 0
        agent-org-buffer--tool-drawer-live-p nil
        agent-org-buffer--thought-drawer-live-p nil
        agent-org-buffer--thought nil
        agent-org-buffer--thought-tail nil))

;;;; Forward declaration

(declare-function agent-org-send "agent-org" ())
(declare-function agent-org-set-session-model "agent-org" (model))
(declare-function agent-org-queue-edit "agent-org" ())
(declare-function agent-org-queue-resume "agent-org" ())
(declare-function agent-org-queue-enqueue "agent-org" (text))
(declare-function agent-org-queue-remove "agent-org" (&optional which))
(declare-function agent-org-queue-list "agent-org" ())
(declare-function agent-org-cancel-turn "agent-org" ())
(declare-function agent-org-queue-prepend "agent-org" (text))
(declare-function agent-org-interrupt-and-send "agent-org" ())
(declare-function agent-org-queue-restore "agent-org" ())

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

(defconst agent-org-buffer--cancel-note "turn cancelled"
  "The `:note' that marks a Ready state as a turn the USER stopped.
`agent-org-cancel-turn' is the only writer, and the heading-word rule is the
only reader that cares: `ready' alone settles a prompt as RESPONDED, while
`ready' with this note settles it as CANCELLED.  Shared as a constant because a
string typed twice is a rule that drifts apart the first time one is edited.")

(defun agent-org-buffer--prompt-keyword-for-state (state note)
  "The prompt-set word for header-line STATE with NOTE, or nil for no edit.
The one mapping behind the user's order that a prompt's keyword \"should reflect
the status indicator in header line\": streaming→RESPONDING, awaiting→IDLE (a
turn waiting on HIM is the one state he must not miss), ready→RESPONDED, a
cancelled turn→CANCELLED, error→ERROR.  `starting' and `loading' answer nil --
before a prompt exists there is no heading to wear a word, and a restore is not
an answer.

POSITIONAL like every other word this package writes
(`agent-org-buffer--keyword-set-word'), so renaming the set renames the
mirroring: the three unfinished words are taken in order (PROMPT, RESPONDING,
IDLE) and the three done words in order (RESPONDED, CANCELLED, ERROR).  A set
trimmed shorter than a state needs answers nil, which leaves the heading wearing
whatever it already said -- never a word the buffer does not know."
  (let ((words agent-org-prompt-todo-keywords))
    (pcase state
      ('streaming (agent-org-buffer--keyword-set-word words t 1))
      ('awaiting (agent-org-buffer--keyword-set-word words t 2))
      ('ready (if (equal note agent-org-buffer--cancel-note)
                  (agent-org-buffer--keyword-set-word words nil 1)
                (agent-org-buffer--keyword-set-word words nil 0)))
      ('error (agent-org-buffer--keyword-set-word words nil 2))
      (_ nil))))

(defun agent-org-buffer--set-exchange-keyword (buffer word)
  "Rewrite the current exchange heading's word to WORD, touching nothing else.
One word on one line: the replaced region is between the heading's stars and
the space after the word, so the prompt text, the answer under it and every
drawer of the turn stay exactly where they are.  A heading with no word yet (an
older transcript, a prompt rendered before this existed) gets WORD INSERTED.

No-op when WORD is nil, when no exchange is open, and when the heading is not a
prompt (`agent-org-buffer--prompt-word-p') -- that flag is what keeps a status
change off an orphan `* Agent' heading.

Wraps the whole edit in `save-match-data': this runs INSIDE ACP notification
callbacks, and a `string-match' left behind would clobber the global match data
whatever scan a later `match-string' is resting on (the documented trap in
AGENTS.md)."
  (when (and word (buffer-live-p buffer))
    (with-current-buffer buffer
      (when (and agent-org-buffer--prompt-word-p
                 (agent-org-buffer--live-mark agent-org-buffer--turn-anchor))
        (save-match-data
          (let* ((heading (agent-org-buffer--live-mark
                           agent-org-buffer--turn-anchor))
                 (line (buffer-substring-no-properties
                        heading (save-excursion (goto-char heading)
                                                (line-end-position)))))
            ;; ONE match for the stars, one for `stars + a word + space', and the
            ;; offsets read off whichever applies -- `match-end' is global state,
            ;; so it is captured before the second match runs.
            (when (string-match "^\\*+ " line)
              (let* ((stars-end (match-end 0))
                     (worded (string-match "^\\*+ \\([A-Z]+\\) " line))
                     ;; only a word THIS set owns counts: a prompt that opens with
                     ;; capitals ("* DO IT NOW") is the user's text, not a state
                     (old (and worded
                               (car (member (match-string-no-properties 1 line)
                                            (agent-org-buffer--prompt-set-words)))))
                     (from (+ heading (if old (match-beginning 1) stars-end)))
                     ;; the space AFTER the word is part of what is replaced:
                     ;; a state word is a different length than the one it
                     ;; retires, and the inserted text carries its own space,
                     ;; so excluding it would leave `* RESPONDED  Do it?'
                     (to (+ heading (if old (1+ (match-end 1)) stars-end))))
                (unless (equal old word)
                  (let ((inhibit-read-only t))
                    (save-excursion
                      (delete-region from to)
                      (goto-char from)
                      (insert (concat word " ")))))))))))))

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
                         :mode :mode-name :project :title :used :size :tokens :cost-amount
                         :cost-currency :commands :modes-list :config :queued))
        (when (plist-member status key)
          (setq agent-org-buffer--status
                (plist-put agent-org-buffer--status key (plist-get status key)))))
      (when (plist-member status :session-id)
        (agent-org-buffer--apply-name))
      ;; THE ONE BODY-SIDE EDIT, and this is its only writer: the exchange
      ;; heading's word mirrors the state the bar just started to show, so the
      ;; two can never disagree (see `--prompt-keyword-for-state' for the
      ;; mapping, `--set-exchange-keyword' for what it refuses to touch, and
      ;; CONVENTIONS.md §6 for why this is the exception to "status never
      ;; touches the body").
      (when (plist-member status :state)
        (agent-org-buffer--set-exchange-keyword
         buffer
         (agent-org-buffer--prompt-keyword-for-state
          (plist-get agent-org-buffer--status :state)
          ;; the note that decides CANCELLED is the one THIS call carries: a
          ;; `:note' left over from an earlier turn must not re-cancel a prompt
          ;; that has since been answered (`:note' outlives the handshake by
          ;; design, so the merged plist is the wrong source here)
          (and (plist-member status :note) (plist-get status :note)))))
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
`C-c a a' in a chat, which is the user's own \"add one here\" -- the same
gesture the queue editor offered as an entry command.  Point lands inside the
new entry, because a slot nobody is looking at is not a slot."
  (interactive)
  (goto-char (agent-org-buffer-queue-insert-entry (current-buffer)))
  (message "[agent-org] new queued prompt; type it, then M-x agent-org-queue-apply"))

(defun agent-org-buffer-queue-kill ()
  "Kill the queued prompt at point in this buffer."
  (interactive)
  (agent-org-buffer-queue-kill-entry (current-buffer)))

(defun agent-org-buffer--build-mode-map (map)
  "Fill MAP with `agent-org-mode's bindings, and return it.
A function that FILLS a map rather than one that RETURNS a fresh one, because a
hot load (`emacsclient -e (load …)', the workflow AGENTS.md prescribes) must
reach the buffers that are already running: `defvar' leaves an already-bound
symbol alone, and `minor-mode-map-alist' holds the keymap OBJECT each buffer
activated on, so re-setting the variable to a new map leaves a live chat on the
OLD keys forever -- measured here, where a reloaded `agent-org-mode-map' still
answered `C-c C-c' with `agent-org-send' and went on eating
`org-ctrl-c-ctrl-c'.  Filling the one existing object instead makes a reload
rebind every buffer immediately."
  (let ((send-map (make-sparse-keymap)))
    ;; ONE prefix, `C-c a' (user order 2026-10-11: shorter keys).  What has to
    ;; stay true is that it shadows NO Org command: measured on a loaded Org
    ;; 9.7.11, `C-c a' is unbound in `org-mode-map' -- the family Org keeps for
    ;; itself is `C-c C-<letter>', where -c is `org-ctrl-c-ctrl-c', -m PARSES as
    ;; `C-c RET' = `org-ctrl-c-ret', and -q, -r, -k, -l, -a, -d are tags, reveal,
    ;; kill-note, link, attach and deadline.  The old prefix was `C-c C-g', one
    ;; of the two slots in that family Org leaves free; `C-c a' is one keystroke
    ;; shorter.  KNOWN OVERLAP: in the user's own config the global `C-c a' is
    ;; gptel's prefix (20 bindings), and a minor-mode map outranks the global
    ;; map, so gptel is unreachable from a CHAT buffer.  `test-agent-org-mode-map
    ;; -shadows-no-org-binding' pins the Org half of that, which is the half the
    ;; package is responsible for; the letters below are plain.
    (define-key send-map (kbd "s") #'agent-org-send)
    (define-key send-map (kbd "m") #'agent-org-set-session-model)
    (define-key send-map (kbd "q") #'agent-org-queue-edit)
    (define-key send-map (kbd "r") #'agent-org-queue-resume)
    (define-key send-map (kbd "k") #'agent-org-cancel-turn)
    (define-key send-map (kbd "l") #'agent-org-lite-mode-toggle)
    (define-key send-map (kbd "a") #'agent-org-buffer-queue-add)
    (define-key send-map (kbd "d") #'agent-org-buffer-queue-kill)
    ;; the three verbs agent-shell has and this queue did not: put a prompt on
    ;; the list from wherever point is, take one off by the NUMBER the queue
    ;; shows, and read the list without scrolling to the buffer's end.
    (define-key send-map (kbd "e") #'agent-org-queue-enqueue)
    (define-key send-map (kbd "x") #'agent-org-queue-remove)
    (define-key send-map (kbd "v") #'agent-org-queue-list)
    ;; the three the user ordered on top of those: `n' for the prompt that has to
    ;; go NEXT -- ahead of what already waits, where `e' appends -- `i' to stop the
    ;; agent and ask something else in the same gesture, and shift-`Q' for the
    ;; repair of a region he has messed up.  It shares `q's letter with the goto
    ;; because the two are the same question -- "what is really in my queue?" --
    ;; answered by looking and by putting it right.
    (define-key send-map (kbd "n") #'agent-org-queue-prepend)
    (define-key send-map (kbd "i") #'agent-org-interrupt-and-send)
    (define-key send-map (kbd "Q") #'agent-org-queue-restore)
    ;; the clock display is on by default, so the key is the WAY OUT of it and
    ;; the way back -- `c' because it names the thing and sits with no queue verb
    (define-key send-map (kbd "c") #'agent-org-clock-display)
    (define-key map (kbd "C-c a") send-map)
    ;; our own `C-c C-c': it WRAPS `org-ctrl-c-ctrl-c' (delegates everywhere
    ;; except a CLOCK line, where Org's own handler would delete the seconds our
    ;; stamps carry), so the chord still refreshes a clocktable and edits a
    ;; block while a clock keeps its seconds.  See `agent-org-ctrl-c-ctrl-c'.
    (define-key map (kbd "C-c C-c") #'agent-org-ctrl-c-ctrl-c)
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

(defvar agent-org-mode-map (agent-org-buffer--build-mode-map (make-sparse-keymap))
  "Keymap for `agent-org-mode'.
The one keymap object this package fills at load; see
`agent-org-buffer--build-mode-map' for why it is filled, not replaced.")

;; Re-fill the SAME object on a reload: the `defvar' above is a no-op once the
;; symbol is bound, so without this a hot load changed the file and not the
;; running editor.  `(setcdr map nil)' empties a sparse keymap in place -- the
;; `keymap' tag is its `car', and this map has no parent to lose.  It must be a
;; separate expression: `setcdr' RETURNS the new cdr (nil), so passing its value
;; to the builder hands the builder nil and `define-key' signals at load.
(progn
  (setcdr agent-org-mode-map nil)
  (agent-org-buffer--build-mode-map agent-org-mode-map))

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
Type at the live `* PROMPT' prompt at the end of the buffer.
Keys -- all of them under `C-c a', which `org-mode-map' leaves free (the guard
is `test-agent-org-mode-map-shadows-no-org-binding'):
  C-c a s  Send the typed prompt (queues it while the agent responds)
  C-c a k  Cancel the running turn
  C-c a l  Cycle this session's lite scope (C-u: the global one)
  C-c a m  Switch the session's model
  C-c a q  Go to the prompts waiting in this session's queue
  C-c a Q  Restore the region from the session's queue (edits to kill ring)
  C-c a r  Resume the queue: send the next waiting prompt now
  C-c a a  Add a queued prompt at the bottom
  C-c a d  Kill the queued prompt at point
  C-c a e  Queue a prompt from the minibuffer, at the back
  C-c a n  Queue a prompt from the minibuffer, as the NEXT one out
  C-c a x  Remove a queued prompt by the number `C-c a v' shows
  C-c a v  List the waiting prompts in the echo area
  C-c a i  Interrupt the running turn and send the box, in one go
  C-c a c  Toggle the clocked-total display (C-u: force it off)
  M-UP / M-DOWN  Reorder the queued prompt at point (in the queue only)
M-RET, M-LEFT/RIGHT, S-UP/DOWN, `C-c -' and `C-c C-t' are bound to an error
here ON PURPOSE: Org's structure commands on those keys write through
`read-only' text properties and would corrupt a heading boundary mid-stream."
  :init-value nil
  :lighter nil
  :keymap agent-org-mode-map
  (if agent-org-mode
      (progn
        (when agent-org-use-header-line
          (setq header-line-format
                '(:eval (agent-org-buffer--render-header-lines))))
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
                  #'agent-org-buffer--ensure-font-lock nil t)
        ;; Clock totals on by default (user order 2026-10-11), and BUFFER-
        ;; locally: a global mode would decorate headings in files this package
        ;; does not own.  Seeded from the custom here, so a chat opens with the
        ;; display it was configured for; the pass itself is silent (see
        ;; `agent-org-clock--draw').
        (when agent-org-clock-display-default
          (agent-org-clock-display-mode 1))
        ;; Sticky prompt headings (user order 2026-10-13): BUFFER-LOCAL, for
        ;; the same reason as the font-lock hook above --
        ;; `window-scroll-functions' runs for every window in the session, and
        ;; a global entry would go hunting for headlines in the user's notes.
        ;; The option is read here as well as in the updater, so turning it off
        ;; and back on re-installs the hook rather than needing a fresh chat.
        (when agent-org-sticky-heading
          (add-hook 'window-scroll-functions
                    #'agent-org-buffer--sticky-update nil t)))
    (kill-local-variable 'header-line-format)
    (kill-local-variable 'add-log-current-defun-function)
    (kill-local-variable 'org-hide-drawer-startup)
    ;; a buffer that is no longer a chat stops pinning headings, and stops
    ;; carrying the row it was showing (the hook is what writes it, and the
    ;; hook is gone)
    (remove-hook 'window-scroll-functions
                 #'agent-org-buffer--sticky-update t)
    (kill-local-variable 'agent-org-buffer--sticky-heading)
    ;; undo recording is the mode's, so the mode gives it back: a buffer
    ;; that is no longer a chat gets ordinary undo behaviour whatever scope
    ;; it was left in
    (setq buffer-undo-list t)
    (remove-hook 'window-configuration-change-hook
                 #'agent-org-buffer--ensure-font-lock t)
    ;; a buffer that is no longer a chat must not keep the chat's decorations
    (when agent-org-clock-display-mode (agent-org-clock-display-mode -1))))

;;;; Session metadata block (Org-native, agent-shell bootstrapping)

(defun agent-org-buffer--keyword-set-word (keywords not-done-p index)
  "The word at INDEX in one half of the sequence KEYWORDS.
NOT-DONE-P picks the half BEFORE the `|' bar, else the half after it; INDEX is
0-based.  A set with no bar is read as one unfinished half -- that is what Org
itself does with `TODO DOING DONE' -- and an INDEX past the end of its half
CLAMPS to the last word of that half, so a user who trims a set to one word
still gets a state on every heading instead of a headline whose first word is
text.  Nil only when the chosen half is empty.

THE RULE this exists to serve: a renderer never NAMES a word, it names a
POSITION -- \"a failed call is the tool set's second done word\", not
\"FAILED\".  Renaming a set then renames every headline that reads it, and a
test run with renamed sets catches a hardcoded word the default words would
hide (`test-agent-org-headings-parts-wear-their-own-set-words')."
  (let* ((bar (seq-position keywords "|" #'equal))
         (half (if bar
                   (if not-done-p (seq-take keywords bar)
                     (seq-drop keywords (1+ bar)))
                 keywords))
         (word (if (< index (length half)) (nth index half)
                 (car (last half)))))
    (and (stringp word) (not (string-empty-p word)) word)))

(defun agent-org-buffer--prompt-set-words ()
  "Every word the prompt set owns, bar excluded.
`agent-org-buffer--set-exchange-keyword' reads this to tell a heading's STATE
from the user's own first word: `* DO IT NOW' is a question, `* PROMPT do it' is
a prompt that has not been answered.  Only a word of this set can be replaced by
a status write, because only this package puts one there."
  (remove "|" agent-org-prompt-todo-keywords))

(defun agent-org-buffer--tool-keyword (status)
  "Org TODO keyword for ACP tool STATUS (nil/unknown means pending).
Read POSITIONALLY out of `agent-org-tool-todo-keywords' -- the unfinished half
in order takes `pending' then `in_progress', the done half in order takes
`completed' then `failed' -- so the default set's single unfinished word makes
both running states read RUNNING and a customized set with two gets the
distinction back.  Whether the word is a STATE or TEXT depends on the activity
style (`agent-org-activity-style'): as a `** EXECUTED Read file' headline it is
a real state `C-c C-t' cycles; inside a `:tool:' drawer or a plain list item a
headline is forbidden, so the same word is only text the reader sees (info
\"(org) Drawers\")."
  (pcase status
    ("completed"
     (agent-org-buffer--keyword-set-word agent-org-tool-todo-keywords nil 0))
    ("failed"
     (agent-org-buffer--keyword-set-word agent-org-tool-todo-keywords nil 1))
    ("in_progress"
     (agent-org-buffer--keyword-set-word agent-org-tool-todo-keywords t 1))
    (_
     (agent-org-buffer--keyword-set-word agent-org-tool-todo-keywords t 0))))

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
              (format ":Mode: %s\n"
                      (or (agent-org-buffer--mode-display status) "unknown"))
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
             ;; the provider name only stands in until one arrives.  The
             ;; TODO keyword sets are NOT written here any more: they come
             ;; from `agent-org-buffer--install-todo-keywords', on the
             ;; user's order to scope `org-todo-keywords' to these buffers
             ;; instead of stamping a `#+TODO:' line into every transcript.
             (format "#+TITLE: %s\n"
                     (or (plist-get status :title) provider))
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
and a rebuild deletes and re-inserts the whole block, re-applies the
read-only properties and re-folds every drawer it drew — measurable on a
slow machine.  (It used to also re-parse the buffer's TODO keywords here;
the sets now live in `org-todo-keywords', so no rebuild parses anything.)")

(defun agent-org-buffer-refresh-metadata (buffer)
  "Replace the Org metadata block at the top of BUFFER from its status.
Delete-then-insert keeps this idempotent.  The block spans point-min
up to (but not including) the first conversation heading, so chat
text is never touched.  Drawers the user had left folded are re-folded
after the rebuild; ones they opened stay open, and a drawer that does
not exist yet arrives folded (`agent-org-buffer--metadata-drawers').

Skips entirely when the rendered block is byte-identical to
`agent-org-buffer--metadata-cache': no deletion, no insertion, no
read-only pass and no drawer re-fold."
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
fully programmatic path.

The ONE place the freeze is stopped short is a range that ends exactly at the
queue region's first byte -- which is where every turn renders, since
`--render-end' answers with `--queue-start'.  Without it the last frozen
character's `front-sticky' reaches past `--queue-editable' and the region's
first line refuses a keystroke (`text-read-only' on a prompt the user is
typing) -- a live bug, and invisible in the region's own text because the
property is never ON it, only inherited at the border.  Scoped to that one
position rather than to every protected range: measured, the blanket version
made a turn's own clock edit fall through to its whole-block fallback and lay a
second drawer over the one it had just shut."
  (let ((inhibit-read-only t))
    (add-text-properties beg end
                         '(read-only t front-sticky (read-only)))
    (when-let* ((region (agent-org-buffer--queue-region))
                ((= (car region) end)))
      (put-text-property (1- end) end 'rear-nonsticky '(read-only)))
    ;; Answers T, and a caller depends on it: `--clock-complete' ends here, and
    ;; its answer decides whether the turn's clock is shut IN PLACE or a whole
    ;; second drawer gets laid over it -- `add-text-properties' happens to
    ;; return a property list, but the guard above returns nil on every buffer
    ;; with no queue, and a nil there is a doubled clock (the same `insert
    ;; returns nil' trap this file already documents twice).
    t))

(defun agent-org-buffer--separator ()
  "Ensure point starts a fresh line preceded by a blank one.
Headings inserted right after text would otherwise abut it, which
Org tolerates but renders poorly."
  (unless (bolp) (insert "\n"))
  (when (and (> (point) (point-min))
             (not (eq ?\n (char-before (1- (point))))))
    (insert "\n")))

(defconst agent-org-buffer--prompt-word
  (agent-org-buffer--keyword-set-word agent-org-prompt-todo-keywords t 0)
  "The keyword the live type-ahead box and a fresh exchange both wear.
`PROMPT' by the user's order (2026-10-11): /\"the heading should say =PROMPT=
keyword by default instead of `User'\"/.  The box was the only headline in a chat
spelled as plain text -- a keyword, and the FIRST unfinished word of the prompt
set, is what a reader sees first and what the TODO machinery can cycle.  Read
through `agent-org-buffer--prompt-keyword-for-state' for the rest of the states;
this constant is only the word the set's OWN vocabulary gives position 0, so
renaming the set renames the box.  `begin-exchange' writes the same word, which
is why a send that dies before its first chunk still shows a state rather than a
bare headline.")

(defconst agent-org-buffer--box-rule "----------------------------------------------------------------\n\n"
  "The border the `* PROMPT' box owns, immediately above its heading.
The user's order (2026-10-11): /\"The separator above user prompt heading
should ALWAYS show, not when a prompt is queued.\"/  It used to arrive only as
the first line of the queue region's preamble, so a chat with nothing waiting
ended with the box glued to the last exchange.  Five or more hyphens at column
0 is an Org horizontal rule (info \"(org) Horizontal rules\"), so this is real
markup rather than a decoration, and it is exported as a rule by Org itself.

It is inserted ABOVE the box's anchor, which is what keeps the property the
tests pin: no chunk can land between the rule and the heading it belongs to,
because `--render-end' answers with the anchor.  It is NOT read-only: the
user's order (2026-10-13) is /\"EVERYTHING below the separator MUSTN'T be
read-only\"/, so the rule is a typeable line -- the freeze starts at the
`* PROMPT' heading's own bytes and stops at its own newline (see
`agent-org-buffer-insert-prompt').  The queue region keeps its own rule --
that one is the border against the read-only conversation above the region,
this one is the border above the box he types in, and a chat with a queue
therefore shows both (measured, and asserted).")

(defun agent-org-buffer--prompt-box-heading ()
  "Position of this buffer's live prompt-box heading, or nil when it has none.
Found from `agent-org-buffer--prompt-anchor' -- the byte the box was opened at
-- and NEVER by walking back from `point-max'.  The draft is the user's own
text, and a person listing two modules types `* auth' at column 0, which in Org
is a level-1 HEADLINE: walking back from the bottom therefore stopped at
whichever bullet was typed last, the box vanished from the package's own view,
and every send answered /Nothing to send; type your prompt under the PROMPT
heading/ (the report: \"Can't use headings inside prompts\").  The first heading
at or after the anchor is the box's own whatever the draft holds below it, and
the anchor cannot be typed over -- it sits on the frozen rule line above it."
  (when-let ((anchor (agent-org-buffer--live-mark agent-org-buffer--prompt-anchor)))
    (save-excursion
      (goto-char anchor)
      (when (re-search-forward "^\\*" (point-max) t)
        (match-beginning 0)))))

(defun agent-org-buffer--open-prompt-p ()
  "Non-nil when the current buffer has a typeable prompt box.
The box is a bare prompt-set head word with NOTHING after it.  Read the
heading line's own bytes rather than `org-get-heading': `PROMPT' is a real
TODO keyword (`agent-org-buffer--prompt-word'), that function's arglist
differs between Org 9.7 and 9.8, and stripping the keyword answers \"\" on
the box -- hiding the very word that identifies it.  A sent exchange wears
the same word WITH the question as its heading body, so \"stars, the word,
no rest\" is what tells the box from an exchange in either regime.

The box is located by `agent-org-buffer--prompt-box-heading', not at the
bottom of the buffer, and the draft begins on the line after the heading: the
box writes no drawer and no cookie there, so asking `org-end-of-meta-data'
where the body starts would let a first line that merely LOOKS like furniture
(`#+TITLE: ...') be skipped out of the prompt."
  (condition-case nil
      (when-let ((head (agent-org-buffer--prompt-box-heading)))
        (save-excursion
          (goto-char head)
          (and (string= (string-trim
                         (buffer-substring-no-properties (point) (line-end-position)))
                        ;; the same word an exchange heading opens with, so the
                        ;; box and a sent prompt never spell the question two
                        ;; ways -- see `agent-org-buffer--prompt-word'
                        (concat "* " agent-org-buffer--prompt-word))
               (forward-line 1)
               (not (get-text-property (point) 'read-only)))))
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
turn's answer above it or the `* PROMPT' box below it.  Rear-advancing for
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

(defconst agent-org-buffer--queue-keywords '("NEXT" "WAIT")
  "The two words a queue entry wears, by WHERE it sits: head, then the rest.
The user's own vocabulary for a waiting list -- `First in queue should NEXT todo
keyword, and the rest will be WAIT' -- and it says the one thing a reader cannot
otherwise see at a glance: which prompt goes out when the turn ends.

Because the word now carries POSITION, every edit that changes the order has
to restate the words (`agent-org-buffer-queue-restate'), and a drifted word is
a lie about the send order rather than a harmless label.  That is the cost of
this spelling, paid for by the fact that the page tells the truth by
itself.  Both words live in the prompt set's UNFINISHED half for the measured
reason given there: a set of their own makes WAIT a DONE keyword.")

(defconst agent-org-buffer--queue-legacy-keywords '("PROMPT" "TODO")
  "Retired prompt states, READ but never WRITTEN.
`PROMPT' was the one-word spelling that sat between these two, when the queue's
order was said by position alone; `TODO' is older still.  Every transcript from
before them holds those headlines, and the parser accepts them so a resume does
not silently drop a prompt the user queued weeks ago -- a dropped prompt is LOST
WORK, not a cosmetic miss.
`agent-org-buffer--queue-entry' never writes them, so a queue that is redrawn
converges the file on NEXT/WAIT.  The cost is that a bare `* TODO' at the
bottom of a chat is ambiguous with a plan item, which is why the plan
renderer writes `**' parts, never `*' headings.")

(defconst agent-org-buffer--queue-headline-re
  "^[*] NEXT \\|^[*] WAIT \\|^[*] PROMPT \\|^[*] TODO "
  "A queued prompt's headline: a current keyword or a retired one.
Four anchored alternatives and NO grouping, which is not a style choice:
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

(defun agent-org-buffer--queue-word (index)
  "The keyword for the entry at POSITION INDEX in the region, counting from 0.
The whole of the queue's on-page truth in one line: 0 is NEXT -- the prompt that
goes out when the turn ends -- and anything below it is WAIT.  Deriving the word
from the index is what lets a repaint, a move and a kill all state the queue
correctly without any of them having to remember which entry was which."
  (if (zerop index)
      (car agent-org-buffer--queue-keywords)
    (nth 1 agent-org-buffer--queue-keywords)))

(defun agent-org-buffer--queue-entry (text &optional index)
  "One queued prompt's heading and body: TEXT under the keyword for INDEX.
INDEX is the entry's position in the region and defaults to 0, so a caller that
renders the whole queue numbers every entry and a caller that adds one at the
bottom says WAIT -- see `agent-org-buffer--queue-word'.

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
                          (agent-org-buffer--queue-word (or index 0))
                          (if (string-empty-p first) "" first))))
    (if (string-empty-p rest)
        (concat heading "\n")
      (concat heading "\n" rest "\n"))))

(defconst agent-org-buffer--queue-note-text
  "----------------------------------------------------------------

# Prompts waiting to be sent: NEXT goes first, then every WAIT.
# Edit them here, then M-x agent-org-queue-apply.
# Messed it up? M-x agent-org-queue-restore repaints this from the real queue.
"
  "The region's preamble: a rule line, then Org comments, ABOVE the entries.
`#' and not `;;' because this is Org: a line starting with a semicolon is
ordinary TEXT, and since the queue is mirrored into every transcript it put a
fake paragraph at the bottom of every conversation file the user shares.  His
correction, verbatim: \"Org uses =#= for comments, not =;=.  Fix queue
comment.\"

The hyphens are the border he asked for between the frozen conversation above
and the queue he edits -- five or more at column 0 is an Org horizontal rule
(info \"(org) Horizontal rules\"), so the border is real markup, and it is
INSIDE the region so a repaint owns it.

The comments are FIRST for a reason that is not cosmetic: an entry's text is
everything from its headline to the next one, so a note AFTER the last entry
would be parsed as part of that prompt and sent to the agent (measured while
this was written: the queue parsed back as one prompt ending in
\"M-x agent-org-queue-apply\").  Above the first headline it is outside every
entry's body, and it is still the one thing a reader of a TRANSCRIPT cannot work
out for himself.")

(defun agent-org-buffer-render-queue (prompts)
  "The whole queue REGION for PROMPTS, oldest first.
Every entry wears the keyword of its POSITION -- `agent-org-buffer--queue-word',
so exactly one NEXT at the top and WAIT below it -- which is why a repaint, a
move and a kill all go through here rather than patching one heading.  PROMPTS
nil renders as the EMPTY STRING, and no queue leaves no trace at all: an empty
entry is a slot to compose in, which is what `agent-org-queue-edit' asks
`agent-org-buffer-queue-insert-entry' for, and a permanent blank heading would
put a headline in every transcript for nothing.

A non-nil PROMPTS whose only member is the empty string renders the preamble
and NO entry, which is how a slot exists before the user has typed anything."
  (if (null prompts)
      ""
    (concat agent-org-buffer--queue-note-text
            (let ((index 0))
              (mapconcat (lambda (prompt)
                           ;; an empty prompt renders as NOTHING: the slot a
                           ;; user is about to type in is not an entry yet, and a
                           ;; bare `* NEXT' heading here would be one that says
                           ;; it (the renderer is called with the list before
                           ;; the heading is inserted)
                           (prog1 (if (string-empty-p prompt)
                                      ""
                                    (agent-org-buffer--queue-entry
                                     prompt index))
                             (setq index (1+ index))))
                         prompts
                         "")))))

;;;; The queue region: waiting prompts at the bottom of the chat

(defun agent-org-buffer--queue-mark (position)
  "A rear-advancing marker at POSITION, for a queue region's edges."
  (let ((marker (make-marker)))
    (set-marker-insertion-type marker t)
    (move-marker marker position)
    marker))

(defun agent-org-buffer--queue-editable ()
  "Make this buffer's queue region typeable, including at its two edges.
THE user's complaint: \"I can't even delete as it says read-only.\"  Nothing
here is a property the region ASKED for -- it inherited one, and Emacs's
property-spreading rule is what did it: text inserted at a position takes
properties from the character BEFORE it (unless that character says
`rear-nonsticky').  `--queue-paint' inserts the region at `--render-end',
which is the end of the frozen conversation above it, so EVERY byte of the
queue came in carrying `read-only t'.  The region was never editable anywhere,
and no reading of its own text would have shown why.

So this clears what the insert inherited and then un-sticks the boundary, in the
two places the same rule reaches the region from outside:

  - the region's own text: `read-only' and `front-sticky' off, so a delete, a
    kill and a typed word all work anywhere inside it;
  - the character ABOVE the region's first byte: `rear-nonsticky', so the next
    turn that renders down to this boundary cannot re-infect the region's first
    line the way the first paint did.

The region's LAST position is deliberately left alone: `--queue-end' is
re-armed by `agent-org-buffer-insert-prompt' at the `* PROMPT' box's first
character, and typing THERE is typing into the box's frozen heading -- the
refusal is correct, and the way to add a prompt by hand is RET at the end of
the last entry, which is inside the region and therefore typeable."
  (let ((region (agent-org-buffer--queue-region)))
    (when region
      (let ((inhibit-read-only t)
            (beg (car region))
            (end (min (cdr region) (point-max))))
        (when (> end beg)
          (remove-text-properties beg end '(read-only t front-sticky nil)))
        (when (> beg (point-min))
          (put-text-property (1- beg) beg 'rear-nonsticky '(read-only)))))))

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
        (agent-org-buffer--queue-editable)))))

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

(defun agent-org-buffer--queue-minus (prompts shown)
  "PROMPTS with one occurrence of each text in SHOWN removed, order kept.
The arrival test for `agent-org-buffer-refresh-queue', and it has to be by TEXT
and by COUNT: two queued prompts with the same words are two prompts, so
removing every match would lose one, and removing by POSITION would re-send a
prompt the agent already took while the user's re-ordering moved it elsewhere.
SHOWN here is everything the page already accounts for -- the entries the user
is editing AND `--queue-shown', the list the last paint wrote -- because a line
he has typed into is still the prompt it was, and a line he deleted is a prompt
he does not want back."
  (let ((out (copy-sequence prompts)))
    (dolist (text shown out)
      (let ((at (seq-position out text #'equal)))
        (when at (setq out (seq-remove-at-position out at)))))))

(defun agent-org-buffer--queue-append (prompts)
  "Add PROMPTS as entries at the END of this buffer's queue region.
The dirty-region half of `agent-org-buffer-refresh-queue'.  This INSERTS and
never deletes: the region holds the user's own words, so the one operation that
cannot damage them is the one that adds to the end.  Both markers are
rear-advancing, so the region grows over the new entries and the `* PROMPT' box
below stays where it is; `save-excursion' keeps point out of the way of whatever
he is typing."
  (let ((region (agent-org-buffer--queue-region))
        (inhibit-read-only t))
    (when region
      (let ((index (length (agent-org-buffer--queue-headlines))))
        (save-excursion
          (goto-char (cdr region))
          ;; The renderer ends every entry with a newline, but the REGION can
          ;; arrive without one: `agent-org-queue-edit' leaves point after a blank
          ;; slot's heading and the user's words then land on their own line with
          ;; nothing closing it (measured -- the append glued the new entry onto
          ;; the typed text as `half-typed* TODO from the box').  So close the
          ;; line if the user's editing left it open, and add the entry after it.
          (unless (bolp)
            (insert "\n"))
          ;; numbered from the entries already on the page, and NOT through
          ;; `mapconcat': that hands the function the SEPARATOR as a second
          ;; argument, which would become the entry's position.
          (dolist (prompt prompts)
            (insert (agent-org-buffer--queue-entry prompt index))
            (setq index (1+ index)))))
      (setq agent-org-buffer--queue-shown
            (append agent-org-buffer--queue-shown prompts))
      (agent-org-buffer--queue-editable))))

(defun agent-org-buffer--queue-stale (prompts)
  "This region's entries that PROMPTS no longer holds AND that we wrote.
Called with the chat buffer current.  Two conditions, and the second is the one
that protects the user: `agent-org-buffer--queue-shown' is the list the last
paint wrote, so an entry whose text is not in it is something HE wrote -- a
prompt he rewrote, one he typed into a blank slot -- and no drain can claim it.
What survives the filter is exactly the entry the agent took out of the session
while his hands were on the page: painted, then sent."
  (seq-filter (lambda (text)
                (and (seq-position agent-org-buffer--queue-shown text #'equal)
                     (not (seq-position prompts text #'equal))))
              (agent-org-buffer-queue-parse)))

(defun agent-org-buffer--queue-reap (prompts)
  "Delete the drained entries from a queue region the user has touched.
Returns the texts removed; called with the chat buffer current.

THE live bug: \"Prompt queue is not updating automatically.\"  The edit guard in
`agent-org-buffer-refresh-queue' is right that a repaint must not delete a
half-typed prompt -- but that guard covers the WHOLE region, so one touch froze
the surface for good: every later drain left its entry sitting at the bottom of
the chat as a prompt still waiting, and `--queue-shown' went on naming prompts
the agent had already answered, which then made `--queue-minus' swallow a fresh
prompt that reused those words.  Reaping is the per-entry half of a guard that
was all-or-nothing: the entries we wrote and the session dropped go, everything
he wrote stays.

Deleting is not `agent-org-buffer-queue-kill-entry', deliberately: that is the
interactive verb, and its two courtesies -- the kill ring and the echo-area
message -- are wrong for something the agent causes at the end of a turn.  A
prompt already answered must not be `C-y' reachable, and a chat reports on its
header line, not in the echo area (§6).  `buffer-undo-list' is bound away for
the same reason: an undo that resurrected a sent prompt would put it back on
the queue at the next apply.

`agent-org-buffer-queue-restate' then re-arms the markers and the keywords, so
the survivors say where they now sit in the send order.  That re-render also
drops a blank slot he is composing in -- the parser has no text to give back --
which is the same cost the interactive kill already pays; nothing he has typed
is lost, only an empty heading."
  (let ((stale (agent-org-buffer--queue-stale prompts)))
    (when stale
      (let ((spots (agent-org-buffer--queue-headlines))
            (inhibit-read-only t)
            (buffer-undo-list t))
        (save-excursion
          (dolist (at (reverse spots))
            (save-excursion
              (goto-char at)
              (let* ((bounds (agent-org-buffer-queue-entry-bounds))
                     (entry (agent-org-buffer--queue-parse-text
                             (buffer-substring-no-properties
                              (car bounds) (cdr bounds)))))
                (when (and entry (member (car entry) stale))
                  (delete-region (car bounds) (cdr bounds))))))))
      (agent-org-buffer-queue-restate (current-buffer))
      (setq agent-org-buffer--queue-shown
            (agent-org-buffer--queue-minus agent-org-buffer--queue-shown
                                           stale)))
    stale))

(defun agent-org-buffer-refresh-queue (buffer prompts)
  "Show PROMPTS in BUFFER's queue region, without touching what the user typed.
Idempotent by construction, and the region is NEVER appended to twice: a paint
deletes between the two markers and reinserts, and the dirty path recomputes the
arrivals from the page each time.

TWO cases, because the region has two owners.  While it is PRISTINE
(`agent-org-buffer--queue-pristine-p') the buffer is ours and a refresh repaints
it from PROMPTS whenever the two differ.  Once the user has changed it -- an
edit, a re-order, a killed entry, a blank slot he is typing in -- the region is
HIS text, and a repaint would delete a half-typed prompt in the middle of a
word; so a refresh then REAPS the entries the session has dropped
(`agent-org-buffer--queue-reap') and APPENDS the prompts the page does not
already account for (`agent-org-buffer--queue-minus'), and touches nothing
else.  That difference -- rewrite, or edit in place -- is what the user could
not see when the header said \"3 queued\" and the bottom showed one.

Either way a region with NOTHING in it is then retired: no session queue, no
entry or even blank slot on the page, markers dropped.  Left standing, that
residue is a border and three comment lines above the type-ahead box that
promise a queue that is not there (§17).

Nothing is written to the SESSION here, and the order on the page stays the send
order: `agent-org-queue-apply' is what reconciles the two, dropping by text the
prompt the agent took while this was being edited."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (if (agent-org-buffer--queue-pristine-p)
          (unless (equal prompts agent-org-buffer--queue-shown)
            (agent-org-buffer--queue-paint (agent-org-buffer--queue-region)
                                           prompts))
        (agent-org-buffer--queue-reap prompts)
        (let ((fresh (agent-org-buffer--queue-minus
                      prompts
                      (append (agent-org-buffer-queue-parse)
                              agent-org-buffer--queue-shown))))
          (when fresh
            (agent-org-buffer--queue-append fresh))))
      (when (and (null prompts)
                 (null (agent-org-buffer--queue-headlines))
                 (agent-org-buffer-queue-p))
        (agent-org-buffer--queue-paint (agent-org-buffer--queue-region)
                                       nil)))))

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
guess.

The end is the NEXT headline or the REGION's own end, never `point-max':
entries are level-1 headings and so is the `* PROMPT' box below them, so the
last entry's subtree as Org sees it runs to the end of the buffer.  Measured on
the kill -- `C-c a d' on the last queued prompt took `kill-region' through the
frozen box, which answered `text-read-only' instead of removing the prompt, and
`M-DOWN' on it pushed the prompt BELOW the box, out of the region and off the
page."
  (let* ((region (agent-org-buffer--queue-region))
         (spots (agent-org-buffer--queue-headlines))
         (here (car (last (seq-take-while (lambda (s) (<= s (point))) spots)))))
    (unless here
      (user-error "Not on a queued prompt"))
    (cons here (or (seq-find (lambda (s) (> s here)) spots) (cdr region)))))

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
                  (agent-org-buffer--queue-mark (point))))
          (agent-org-buffer--queue-editable)))
      ;; `--queue-shown' is NOT updated here: it is the baseline the edit guard
      ;; compares against, and a move IS a touch.  The apply is what makes the
      ;; session agree with what the region now says.
      (when entries
        nil))))

(defun agent-org-buffer-queue-restore (buffer prompts)
  "Replace BUFFER's whole queue region with PROMPTS, the user's edits and all.
The force path `agent-org-queue-restore' asks for, and the one place the edit
guard is deliberately overruled -- so the region's text goes on the KILL RING
first: the region is the user's own writing, and a restore that silently threw
away a prompt he had typed into it but never applied would be the loss worth
making recoverable with `C-y'.

`--queue-paint' then re-arms the markers, re-declares the region editable and
sets `--queue-shown' to PROMPTS -- which is what makes the region PRISTINE
again, so the ordinary refreshes resume the moment he stops editing.  The
session's list is not touched by this: restore makes the page agree with the
queue, never the queue agree with the page."
  (with-current-buffer buffer
    (let ((text (agent-org-buffer--queue-region-text)))
      (unless (string-blank-p text)
        (kill-new (substring-no-properties text))))
    (agent-org-buffer--queue-paint
     (agent-org-buffer--queue-region) prompts)))

(defun agent-org-buffer-queue-insert-entry (buffer)
  "Append a blank `* NEXT' (or `* WAIT') entry to BUFFER's queue region.
Return the position at the END of its heading text -- where the user's next
keystroke belongs.  Returning `point-max' (as this did until a live chat showed
the difference) leaves point on the line AFTER the heading, so the words the
user types become a BODY line under an empty `* NEXT ', and the page reads as a
slot he typed beside rather than into.  It still round-trips -- the parser takes
an entry as its headline plus the lines under it -- which is exactly why no test
caught it, and the layout is the thing a chat is for.

A blank entry is a SLOT to type in, which is how the user adds a prompt of his
own at the bottom -- and `--queue-parse' drops it if he leaves it empty, so
composing one cannot send a blank.  Its word is its POSITION in the region: NEXT
when the slot is the only thing there, WAIT behind an entry that already is."
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
      (let ((heading-start (point)))
        (insert (format "* %s \n"
                        (agent-org-buffer--queue-word
                         (length (agent-org-buffer--queue-headlines)))))
        (agent-org-buffer--queue-editable)
        (goto-char heading-start)
        (line-end-position)))))

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

(defun agent-org-buffer-queue-kill-text (buffer text)
  "Kill the first entry in BUFFER's region whose text is TEXT; t if it did.
Why a session-level verb needs the page: once the user has edited the region it
is HIS text and a refresh only appends (`agent-org-buffer-refresh-queue'), so
removing a prompt from the SESSION's list alone would leave the entry sitting at
the bottom of the chat -- and the next apply reads the region and would put it
back on the queue.  Deleting by TEXT is the same rule the apply drops a sent
prompt by: the entry may have been moved anywhere while the agent was answering.
NIL when the region does not hold it, which is the normal case for a prompt
added while he was editing (it was never on his page to delete)."
  (with-current-buffer buffer
    (catch 'done
      (dolist (at (agent-org-buffer--queue-headlines))
        (let ((entry (agent-org-buffer--queue-parse-text
                      (buffer-substring-no-properties
                       at (or (seq-find (lambda (s) (> s at))
                                        (agent-org-buffer--queue-headlines))
                            (cdr (agent-org-buffer--queue-region)))))))
          (when (and entry (equal (car entry) text))
            (save-excursion (goto-char at)
                            (agent-org-buffer-queue-kill-entry buffer))
            (throw 'done t))))
      nil)))

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
  "Ensure BUFFER ends with a live `* PROMPT' type-ahead box.
The heading wears the prompt set's first word
(`agent-org-buffer--prompt-word'), so the box reads as a state the TODO
machinery understands rather than as a plain-text label -- the user's order
of 2026-10-11: /\"the heading should say =PROMPT= keyword by default instead of
`User'\"/.
Only the box's heading is frozen, and only as far as its own newline; the body
under it -- and the separator and horizontal rule above it -- stay typeable
(user's order, 2026-10-13: /\"EVERYTHING below the separator MUSTN'T be
read-only\"/).  No-op when a box is already open, so every turn boundary can
call it without stacking boxes.

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
        (let ((box-beg (point))
              (head-beg (progn (agent-org-buffer--separator)
                               (insert agent-org-buffer--box-rule)
                               (insert (format "* %s\n" agent-org-buffer--prompt-word))
                               ;; the box's frozen prefix is the HEADING'S OWN
                               ;; BYTES and nothing above it (user's order,
                               ;; 2026-10-13: \"EVERYTHING below the separator
                               ;; MUSTN'T be read-only\").  The separator line,
                               ;; the `--box-rule' and the blank between them
                               ;; used to come inside `--protect', which froze
                               ;; the rule too -- measured live: every byte from
                               ;; the rule's first hyphen onward `read-only t'.
                               (line-beginning-position 0))))
          ;; The separator's own newlines sit between the box and the frozen
          ;; conversation above it, so they came in carrying that freeze: the
          ;; box was inserted INTO frozen text, and a newline inserted next to
          ;; a `front-sticky' read-only char inherits it.  Clearing the whole
          ;; prefix below the separator is what makes the rule line and the
          ;; blank under it typeable -- the property is not ON the rule, it is
          ;; inherited by the keystroke from the newline in front of it.
          ;; `rear-nonsticky' on the char immediately ABOVE the box is the last
          ;; half: an insert AT `box-beg' still reads that neighbour's
          ;; `front-sticky' and is refused (measured: position 23, the frozen
          ;; newline ending the metadata block).  The same cure
          ;; `--queue-editable' applies to the region's first byte.
          (let ((inhibit-read-only t))
            (remove-text-properties box-beg head-beg
                                    '(read-only nil front-sticky nil))
            (when (> box-beg (point-min))
              (put-text-property (1- box-beg) box-beg
                                 'rear-nonsticky '(read-only))))
          ;; The box ends at the heading's OWN newline and reaches no further:
          ;; a second newline put the user's first keystroke one line BELOW an
          ;; empty one, so the line under the heading read as frozen (user's
          ;; order, 2026-10-11: \"the prompt area MUSTN'T be read-only\").
          ;; `rear-nonsticky' on that last frozen char is what makes the
          ;; difference between a heading and a typeable prompt.
          (agent-org-buffer--protect head-beg (point))
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
          ;; text ended with the words `* PROMPT'.
          (when queue
            (setq-local agent-org-buffer--queue-end
                        (agent-org-buffer--queue-mark box-beg))
            ;; The box's first character carries `front-sticky' read-only, and it
            ;; sits exactly at the region's end -- so the region had to be
            ;; re-declared editable after the box went in, whichever of the two
            ;; was created last.  The box keeps its own freeze from that character
            ;; onward; what this stops is the freeze reaching UP into the queue.
            (agent-org-buffer--queue-editable))
          (unless stay (goto-char orig)))))))

(defun agent-org-buffer-take-draft (buffer)
  "Return the text typed at BUFFER's live box and empty the box.
The box itself stays open and last, ready for the next message: this is
what sending looks like in a chat that keeps a persistent prompt.
Signals a `user-error' when no box is open or nothing has been typed.

The whole draft is everything from the line after the box's heading to the end
of the buffer -- which may contain headings the user typed, and is taken as
TEXT: `agent-org-buffer-begin-exchange' indents them on the way in, so a
prompt written as a bullet list is one prompt and not three."
  (with-current-buffer buffer
    (unless (agent-org-buffer--open-prompt-p)
      (user-error "Nothing to send; type your prompt under the PROMPT heading"))
    (let ((beg (save-excursion
                 (goto-char (agent-org-buffer--prompt-box-heading))
                 (forward-line 1)
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
    (agent-org-buffer--ensure-response-part (current-buffer))
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
`:tool:' drawer and the type-ahead box below it (measured).

Called at EVERY boundary (`agent-org-buffer-append-thought',
`agent-org-buffer-insert-tool', `agent-org-buffer-end-agent-turn'), which is
also where a part style gets its order right: the arriving line is prose, so it
is written into the prose's part BEFORE the thought or call that triggered the
flush opens its own part below."
  (when (or agent-org-buffer--md-fragment agent-org-buffer--md-src-p)
    (when (and agent-org-buffer--md-fragment
               (not (string-empty-p agent-org-buffer--md-fragment)))
      (agent-org-buffer--ensure-response-part (current-buffer))
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
      (agent-org-buffer--ensure-response-part (current-buffer))
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
      (if (string-empty-p flat) agent-org-buffer--prompt-word flat))))

(defun agent-org-buffer-begin-exchange (buffer text)
  "Open one prompt/response pair in BUFFER, headed by the question TEXT.
User order: \"there will be ONE heading for each prompt/response pair.  The
heading will contain the prompt.\"  So this replaces the old `* PROMPT' echo
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
      (let ((inhibit-read-only t)
            ;; THE TURN'S CLOCK OPENS WITH ITS HEADING: the stamp is taken HERE,
            ;; not at the next boundary, because it is the moment the question
            ;; went out -- and the block written under the heading carries the
            ;; beginning timestamp alone, so a reader sees the agent working (see
            ;; `agent-org-buffer--clock-open-lines').  Suppressed for the replay
            ;; paint (see `agent-org-buffer--record-clock-p'): restored history
            ;; has no timing to invent, and an orphan turn never records one
            ;; either -- no prompt was sent to measure from, so this stays nil, no
            ;; block is opened and the boundary writes no clock.
            (clock-start (and agent-org-buffer--record-clock-p
                              (current-time))))
        (save-excursion
          (goto-char (agent-org-buffer--render-end))
          (agent-org-buffer--separator)
          (let ((beg (point)))
            ;; The heading wears the prompt set's FIRST word from the moment it
            ;; exists: `PROMPT' is what an unanswered question IS, and it is the
            ;; same word a queue entry carries, so a send that dies before its
            ;; first chunk still shows a state rather than a bare headline.
            ;; `agent-org-buffer-set-status' then mirrors the header line onto
            ;; this word for the rest of the turn.
            (insert (format "* %s %s\n"
                            (or (agent-org-buffer--keyword-set-word
                                 agent-org-prompt-todo-keywords t 0)
                                "TODO")
                            (agent-org-buffer--heading-text text)))
            (when clock-start
              (insert (agent-org-buffer--clock-open-lines
                       clock-start agent-org-clock--exchange-property)))
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
                         beg)
            (setq agent-org-buffer--prompt-word-p t))
          (setq agent-org-buffer--awaiting-answer-p t
                ;; spent by `agent-org-buffer--close-response-clock' at the next
                ;; boundary, which SHUTS the block opened above rather than
                ;; writing a second one.
                agent-org-buffer--turn-start clock-start
                ;; a fresh turn has written no answer prose yet: this is what
                ;; `agent-org-buffer--drop-empty-response' keys on, and a stale
                ;; t from the previous turn would keep an empty prefix alive
                agent-org-buffer--answer-written-p nil
                ;; markdown->org is turn-local too: a held half line from the
                ;; previous answer must not open this one, and a fence left
                ;; unclosed by a truncated reply must not hide this answer
                ;; inside a code block
                agent-org-buffer--md-fragment nil
                agent-org-buffer--md-src-p nil)
          ;; the tool board is a window on the record, so a new turn starts at
          ;; its first entry with no drawer open and no block markers live: the
          ;; previous turn's drawer is its text now, and a call here must not be
          ;; painted into it
          (agent-org-buffer--reset-activity))))))

;;;; Streaming (the hot path)

(defun agent-org-buffer--response-label ()
  "The word that names whoever is answering: a model name, else \"Agent\".
`agent-org-buffer--model-display' (the agent's own label else its id),
flattened by `agent-org-buffer--label' because a config option's `name' is
agent text and a newline here would start the answer on the wrong line.  With
no model at all (Goose advertises none of this shape) or
`agent-org-response-prefix' nil, the word is \"Agent\": an empty label is a
claim about nobody.

Two renderings read this: the prefix line (`--prefix-line') and, in `headings'
style, the `** RESPONDING <model>' headline of the answer part."
  (or (and agent-org-response-prefix
           (when-let* ((model (agent-org-buffer--model-display
                               agent-org-buffer--status)))
             (agent-org-buffer--label model)))
      "Agent"))

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
answered, and a later `C-c a m' renames the answers after it and leaves the
older ones alone."
  (format "%s: " (agent-org-buffer--response-label)))

(defun agent-org-buffer--text-end ()
  "Where the next byte of the answer belongs in this buffer.
In `headings' style that is the end of the LIVE answer part's body: prose is a
part like any other, so a line written after a tool call landed BELOW that call
and the reader never has to scroll up for what the agent said last
(`agent-org-buffer--ensure-response-part' is what leaves a part live here).

For the other two styles it is the answer's own insertion point while one is
open --- a marker the text path keeps at the end of the answer written so far
(see `agent-org-buffer--advance-text-end') --- so every chunk lands ABOVE the
`:thinking:' and `:tool:' drawers this turn has already drawn, whatever order
they arrived in.  That pin is what a repainted drawer needs (one board, never a
copy below) and what the user rejected for the default.  Falls back to
`agent-org-buffer--render-end' when no answer is open (a boundary arriving
between turns).

Always called with the chat buffer current."
  (or (agent-org-buffer--part-body-end "response")
      (agent-org-buffer--live-mark agent-org-buffer--quote-end)
      (agent-org-buffer--render-end)))

(defun agent-org-buffer--advance-text-end (position)
  "Leave the answer's insertion marker at POSITION, the end of text just added.
Called by every writer that appends answer text at `agent-org-buffer--text-end',
with the `(point)' reached after its insert.  This is the marker's one mover:
because it is NOT rear-advancing (see `agent-org-buffer-start-agent-turn'), a
drawer drawn at the same spot cannot shove it down and strand the prose under
the board, and only an actual answer line advances it -- so consecutive chunks
still land in arrival order, each under the last.

In `headings' style the marker moved is the live answer part's `:body-end', the
one writer that walks it down the buffer — text belongs to this part until
another part opens below it — and the flag below is what tells a closed turn's
empty prose part from a real answer.

Does nothing between turns, when no answer marker is live."
  (let ((part-end (and (equal agent-org-buffer--live-part "response")
                       ;; the MARKER, not `--part-body-end's POSITION: this is
                       ;; the one place that has to move it, and `move-marker'
                       ;; wants the marker itself.
                       (plist-get (agent-org-buffer--part "response")
                                  :body-end))))
    (when (or (markerp part-end) (markerp agent-org-buffer--quote-end))
      (setq agent-org-buffer--answer-written-p t)
      (move-marker (if (markerp part-end)
                       part-end
                     agent-org-buffer--quote-end)
                   position))))

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
  ;; NOT a prompt: `* Agent' is an answer with no question, so no status write
  ;; may put a prompt-set word on it (see `--prompt-word-p').
  (setq agent-org-buffer--prompt-word-p nil
        agent-org-buffer--awaiting-answer-p t
        agent-org-buffer--answer-written-p nil
        agent-org-buffer--md-fragment nil
        agent-org-buffer--md-src-p nil)
  (agent-org-buffer--reset-activity))

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
          ;; `headings' style writes NO furniture here.  The answer is a part
          ;; like a thought or a call, opened by the first line of prose
          ;; (`agent-org-buffer--ensure-response-part'), so a turn that only ran
          ;; tools has no `** RESPONDING' headline to drop at the boundary and
          ;; no prefix line above the board: the parts carry the order and the
          ;; model name themselves.  Every later writer below branches on the
          ;; live part's marker rather than on `--quote-end', which stays nil.
          (unless (agent-org-buffer--parts-p)
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
                (setq-local agent-org-buffer--quote-end marker)))))
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

(defun agent-org-buffer--clock-open-lines (start property)
  "The clock block for an activity that BEGAN at START and has not ended.
PROPERTY names the `:PROPERTIES:' entry holding the exact whole seconds; the
open block writes 0 there, and `agent-org-buffer--clock-complete' replaces it
with the real number when the activity closes.

THE BLOCK IS WRITTEN WHEN THE ACTIVITY OPENS, not at its end (user order
2026-10-11: \"You shouldn't insert the whole `CLOCK:' in the end.  Start by
adding the beginning timestamp.  Then, add the ending time with duration in the
end.\").  A chat that shows a running `CLOCK:' is the honest picture while the
agent works, and it means the closing pass rewrites ONE LINE instead of laying
down a whole drawer over text that has moved since.

An open line is safe to leave behind, and that was measured rather than assumed
(Org 9.7.11, a buffer with one `CLOCK: [start]' in its `:LOGBOOK:'):
`org-clock-load' does not adopt it, `org-clock-in' on another heading still
succeeds, and `org-clock-sum' counts it as 0 minutes.  So the one form §22 said
we must never write is the one form the user's own clocking is indifferent to.
The stamps carry SECONDS (user order 2026-10-14: \"Seconds no longer showing up
in clock timestamps\"): a second-precise STAMP still parses as one `clock' node
and still sums (measured on Org 9.7.11 AND 9.8.10 — a `[HH:MM:SS]' range of
135 s answers 1 node / 2 minutes), so the reader of the transcript, which draws
no overlay, sees the seconds.  What must stay minute-granular is the `=>'
DURATION: a duration carrying seconds is the shape that parses to ZERO nodes."
  (format ":PROPERTIES:\n:%s: 0\n:END:\n:LOGBOOK:\nCLOCK: %s\n:END:\n"
          property
          (format-time-string "[%Y-%m-%d %a %H:%M:%S]" start)))

(defun agent-org-buffer--clock-complete (start property)
  "Shut the open clock block for the activity that began at START, as of now.
Point must be at the bol of the block's `:PROPERTIES:' line; the whole edit is
confined to the six lines below it.  Sets PROPERTY to the exact whole seconds
and completes the open `CLOCK: [start]' into Org's own closed range, SECOND-
precise stamps and a minute-granular `h:mm' duration (the duration must stay
minute-granular: that is the half Org's parser refuses seconds in).

Answers nil and touches NOTHING when the block is not the shape this package
wrote -- which is what makes the caller's whole-block fallback reachable: a turn
opened by an older definition, or a hot-reload that left the markers pointing at
text it never wrote.  A partially-rewritten block is worse than none: `=>' is
printed text, not a second source, so a range that disagrees with its own stamps
is what Org and any clock table will read.  Always called with the chat buffer
current and `inhibit-read-only' bound."
  (when (looking-at-p ":PROPERTIES:")
    (let* ((block-bol (point))
           (limit (save-excursion (forward-line 6) (point)))
           (end (current-time))
           (seconds (max 0 (floor (float-time (time-subtract end start)))))
           (ts-fmt "[%Y-%m-%d %a %H:%M:%S]")
           (ts-start (format-time-string ts-fmt start))
           (ts-end (format-time-string ts-fmt end))
           ;; the duration is the two stamps' OWN difference truncated to the
           ;; minute, so what Org recomputes from the line agrees with what it
           ;; reads off it (§22's gotcha: `=>' is printed text, not a source),
           ;; clamped at zero for the reason `--clock-lines' spells out.
           (range-minutes (- (/ (floor (float-time end)) 60)
                             (/ (floor (float-time start)) 60)))
           (range (* 60 (max 0 range-minutes)))
           ;; built once, so the line Org reads and the line this inserts are
           ;; the same text.
           (clock-text (format "CLOCK: %s--%s =>  %d:%02d"
                               ts-start ts-end
                               (/ range 3600) (% (/ range 60) 60))))
      (save-excursion
        (and (re-search-forward (format "^:%s: [0-9]+$"
                                        (regexp-quote property)) limit t)
             ;; BOTH MATCHES ARE LOCATED BEFORE ANYTHING IS EDITED, and the
             ;; positions are kept as numbers: `and' would otherwise stop at the
             ;; first edit, because `insert' RETURNS NIL — measured, and it is
             ;; the reason every completion fell through to the caller's fallback
             ;; and laid a second drawer over the one it had just shut.
             (let ((prop-from (match-beginning 0))
                   (prop-to (match-end 0))
                   ;; THE START STAMP IS NOT REWRITTEN: the one written when the
                   ;; block opened is the one the range opens with, which is the
                   ;; whole point of writing it early.  `[^]]*' and not `.*'
                   ;; because this must find an OPEN line and nothing else: on a
                   ;; closed one the greedy match would reach the second `]' and
                   ;; then fail `$', and a nil here sends the caller into its
                   ;; fallback -- a SECOND drawer on a heading that already has
                   ;; its clock, which every Org total then counts twice.
                   (clock (re-search-forward "^CLOCK: \\[[^]]*\\]$" limit t)))
               (and clock
                    (let ((clock-from (match-beginning 0))
                          (clock-to (match-end 0)))
                      ;; the LATER line is edited first: replacing `:RESPONSE: 0'
                      ;; with `:RESPONSE: 4500' moves everything after it by the
                      ;; difference in length, and the clock positions were taken
                      ;; before that.
                      (delete-region clock-from clock-to)
                      (goto-char clock-from)
                      (insert clock-text)
                      (delete-region prop-from prop-to)
                      (goto-char prop-from)
                      (insert (format ":%s: %d" property seconds))
                      ;; the two rewritten lines are new text, so they carry no
                      ;; properties: a measurement stays furniture the user
                      ;; reads but cannot edit.
                      (agent-org-buffer--protect block-bol (point))))))))))

(defun agent-org-buffer--clock-lines (start property)
  "The Org clock block for the activity that began at START, as of now.
PROPERTY names the `:PROPERTIES:' entry holding the exact whole seconds:
`RESPONSE:' for a whole exchange, `SECONDS:' for one part of a response.

This is the FALLBACK shape: `agent-org-buffer--clock-open-lines' is what an
activity normally gets, and this whole block is written only when no open one is
there to complete.

The `CLOCK:' range keeps ORG'S OWN SHAPE with one deliberate change, measured
on Org 9.7.11 AND 9.8.10: the STAMPS carry seconds (`[HH:MM:SS]' still parses as
ONE `clock' node and still sums — a 135 s range answers 2 minutes), while the
`=>' DURATION stays minute-granular, because a DURATION carrying seconds is the
half that parses to ZERO nodes.  The seconds therefore show in the timestamps
themselves, which is what the transcript (a plain Org file that draws no
overlay) can show; the exact whole seconds still ride in the property, and
`agent-org-clock-display' still puts them on screen in a live chat."
  (let* ((end (current-time))
         (seconds (max 0 (floor (float-time (time-subtract end start)))))
         (ts-fmt "[%Y-%m-%d %a %H:%M:%S]")
         (ts-start (format-time-string ts-fmt start))
         (ts-end (format-time-string ts-fmt end))
         ;; the duration is the two stamps' own difference truncated to the
         ;; minute, so what Org recomputes from the line agrees with what it
         ;; reads off it (§22's gotcha: `=>' is printed text, not a second source)
         ;; clamped at zero: a START after `now' — a clock step, an NTP jump, a
         ;; fall-back across DST — makes that difference NEGATIVE, and Org reads
         ;; `=> 0:-43' as no clock at all (measured by fuzzing this function over
         ;; 20k random turns: the stamps-only cases were all consistent, the
         ;; future-start case was the one shape that broke).  A zero range with an
         ;; exact property is a lie of omission; a negative one is garbage Org.
         (range-minutes (- (/ (floor (float-time end)) 60)
                           (/ (floor (float-time start)) 60)))
         (range (* 60 (max 0 range-minutes))))
    (format ":PROPERTIES:\n:%s: %d\n:END:\n:LOGBOOK:\nCLOCK: %s--%s =>  %d:%02d\n:END:\n"
            property seconds ts-start ts-end
            (/ range 3600) (% (/ range 60) 60))))

;;;; Response parts: each part of a turn is one clocked `**' headline
;;;;
;;;; The whole of this section runs only for `agent-org-activity-style'
;;;; `headings', the default.  Its one job is the order the user asked for on
;;;; 2026-10-09 -- \"fix response order.  I still need to scroll up to see what
;;;; the agent said last!!\" — answered by \"By default, we'll use TODO
;;;; subheadings for EACH part of the response - thinking, text, tool calls.
;;;; And, each of them should be clocked.\"

(defun agent-org-buffer--parts-p ()
  "Non-nil when this buffer draws a turn as clocked parts.
THE one reading of `agent-org-activity-style' for the render path, run with the
chat buffer current: the style is a global option, so a test that binds it
around one turn changes exactly the turns it means to."
  (eq agent-org-activity-style 'headings))

(defun agent-org-buffer--part (key)
  "This buffer's part record for KEY, or nil.  Run with the chat buffer current."
  (cdr (assoc key agent-org-buffer--parts #'equal)))

(defun agent-org-buffer--part-mark (key property)
  "The live position of part KEY's PROPERTY marker, or nil.
A dead marker means the part was painted in a buffer that has since been
rewritten, and the caller then opens a new part rather than painting into
nothing."
  (when-let* ((part (agent-org-buffer--part key)))
    (agent-org-buffer--live-mark (plist-get part property))))

(defun agent-org-buffer--part-empty-p (key)
  "Non-nil when part KEY has no body at all.
The two body markers answer with the same position, which is how an answer
stretch that was opened and then interrupted — the agent thought or called
something instead of finishing its sentence — is recognized as the nothing it
is, before it settles into a headline saying RESPONDED about no text."
  (let ((beg (agent-org-buffer--part-mark key :body-beg))
        (end (agent-org-buffer--part-mark key :body-end)))
    (and beg end (= beg end))))

(defun agent-org-buffer--part-body-end (key)
  "The live end of part KEY's body, but only while that part is live.
This is what `agent-org-buffer--text-end' reads: a part that is live IS the last
block of the turn, so its body end is where the next line of prose belongs; a
part that was closed is somewhere ABOVE newer activity and must not be written
into: that is the bug this gate prevents, prose climbing back up the turn to
sit above the tool board that came after it.  Run with the chat buffer current."
  (and (equal agent-org-buffer--live-part key)
       (agent-org-buffer--part-mark key :body-end)))

(defun agent-org-buffer--tool-part-p (key)
  "Non-nil when KEY names a tool call's part rather than prose or a thought.
The distinction is who owns the heading's word: a call's status comes off the
wire (TODO→ONGOING→COMPLETE/FAILED) and reports AGAIN after an interrupt, so its
part keeps its markers and is repainted where the user saw it start.  A thinking
run and a stretch of answer prose are finished the moment anything appears below
them, so their cell is dropped with the clock and a later thought opens a new
part instead of rewriting the old one."
  (and (stringp key) (string-prefix-p "tool:" key)))

(defun agent-org-buffer--part-open-word (key)
  "The word part KEY's heading wears WHILE THE ACTIVITY RUNS.
The thinking set's first unfinished word (THINKING) for a thought run, the
response set's (WRITING) for answer prose -- each part reads its OWN set, which
is what makes a `**' heading say the KIND of activity as well as its state.
A tool call answers nil: its word comes off the wire
(`agent-org-buffer--tool-keyword') and a renderer that guessed one would
overwrite a status the agent reported."
  (cond
   ((agent-org-buffer--tool-part-p key) nil)
   ((equal key "thinking")
    (agent-org-buffer--keyword-set-word agent-org-thinking-todo-keywords t 0))
   (t (agent-org-buffer--keyword-set-word agent-org-response-todo-keywords t 0))))

(defun agent-org-buffer--settled-keyword (key)
  "The word part KEY's heading settles to when its activity ends, or nil.
The first DONE word of the part's OWN set -- \"WROTE\" for the answer,
\"THOUGHT\" for a thinking run -- so a user who renames a set renames the settle
with it, and nil for a tool call: the wire owns that word and a turn that ended
with a call still running must not claim it finished."
  (cond
   ((agent-org-buffer--tool-part-p key) nil)
   ((equal key "thinking")
    (agent-org-buffer--keyword-set-word agent-org-thinking-todo-keywords nil 0))
   (t (agent-org-buffer--keyword-set-word agent-org-response-todo-keywords nil 0))))

(defun agent-org-buffer--open-part (buffer key keyword label lines)
  "Open a `** KEYWORD LABEL' part holding LINES at the end of this exchange.
The part IS the last thing in the turn, so what the agent did most recently is
what the reader sees last — the order rule this whole section exists for.  A
different part still live above it is finished first: one activity, one heading,
and an activity that resumes after an interrupt is a NEW part below, never a
line pushed back into a heading that other parts have moved past.

LABEL is agent text (a tool title is a whole shell command live from qoder), so
it goes through `agent-org-buffer--label'; a heading must be one line and a
column-0 `*' in its body would end the part early.
BODY markers are FRONT-grazing, both of them, and stay put unless a writer moves
them by hand: `:body-beg' starts BELOW this part's clock block -- the block is
filed the moment the heading exists, so the body region can never contain a
measurement -- and `:body-end' is moved down by the writers that add text.
A part therefore ends where the next one begins, which is what keeps an
arrival-order repaint from deleting its neighbours."
  (with-current-buffer buffer
    (when (and agent-org-buffer--live-part
               (not (equal agent-org-buffer--live-part key)))
      (agent-org-buffer--finish-part buffer agent-org-buffer--live-part))
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (agent-org-buffer--render-end))
        (agent-org-buffer--separator)
        (let* ((heading (point))
               ;; THE CLOCK OPENS WITH THE PART, not when it closes: the block
               ;; goes in directly under the heading, and `:body-beg' is born on
               ;; the line below its `:END:'.  That is what an open clock is FOR
               ;; here -- the activity's start is on the page while it runs -- and
               ;; it removes the older hazard as a side effect: `--clock-part'
               ;; used to lay a whole drawer down BETWEEN the two body markers and
               ;; then walk BEG (and, for an empty body, END) past it by hand, and
               ;; a front-grazing END left behind that way inverted the region, so
               ;; the call's next report deleted its own clock.
               (clock-start (and agent-org-buffer--record-clock-p (current-time)))
               (body-beg (progn
                           (insert (format "** %s %s\n"
                                           (or keyword "TODO")
                                           (agent-org-buffer--label
                                            (or label ""))))
                           (when clock-start
                             (insert (agent-org-buffer--clock-open-lines
                                      clock-start
                                      agent-org-clock--part-property)))
                           (point)))
               (body-end (progn
                           (when lines
                             (insert (mapconcat #'identity lines "\n"))
                             (unless (bolp) (insert "\n")))
                           (point))))
          (agent-org-buffer--protect heading body-end)
          ;; Every part marker is made by `copy-marker' with ONE argument, and
          ;; the buffer is already current (`with-current-buffer' above) — so
          ;; this is worth spelling out, because the natural-looking
          ;; `(copy-marker POSITION BUFFER)' is not a thing.  `copy-marker' is
          ;; `(copy-marker MARKER &optional INSERTION-TYPE)': passing the buffer
          ;; as that second argument is passing a non-nil one, which silently
          ;; makes the marker REAR-grazing.  Every append then slid `:body-beg'
          ;; down onto `:body-end' (so `--part-empty-p' read a written-out
          ;; thinking run as nothing and deleted it) and slid every `:body-end'
          ;; to the bottom of the turn (so the next part opened INSIDE the old
          ;; part's region, and `--replace-part-body' deleted the answer that
          ;; had arrived since).  All three measurements of the broken ordering
          ;; came from this one argument.
          ;;
          ;; FRONT is what the design wants, not a default to fall into.  A part
          ;; ends where the NEXT part begins: `--open-part' inserts there, so a
          ;; part's region must stop growing the moment another appears below
          ;; it.  Appends still extend the body, because the three writers that
          ;; add text to a part move END by hand afterwards
          ;; (`--append-part-stream', `--replace-part-body' and
          ;; `--advance-text-end').
          (let ((head-mark (copy-marker heading))
                (beg-mark (copy-marker body-beg))
                (end-mark (copy-marker body-end)))
            (setf (alist-get key agent-org-buffer--parts nil nil #'equal)
                  (list :heading head-mark
                        :body-beg beg-mark
                        :body-end end-mark
                        :start clock-start
                        :clocked nil))
            (setq agent-org-buffer--live-part key
                  ;; a new part ends the thinking run whose provisional line was
                  ;; written by the old one, so the next chunk starts a fresh
                  ;; fragment instead of rewriting a line in a closed part
                  agent-org-buffer--thought-tail nil)))))))

(defun agent-org-buffer--set-part-keyword (buffer key keyword)
  "Rewrite part KEY's heading word to KEYWORD, in place, touching nothing else.
One word on one line: the region replaced is between the heading's stars and its
space, so the body, the clock drawers that now sit under the heading, and every
part below stay exactly where they are.  The match is on the line's OWN text
(`buffer-substring', not a search) so no scan's match data is clobbered and the
offsets are absolute by adding the heading position."
  (with-current-buffer buffer
    (when-let* ((heading (agent-org-buffer--part-mark key :heading))
                (line (buffer-substring-no-properties
                       heading (save-excursion (goto-char heading)
                                               (line-end-position)))))
      (when (and keyword
                 (string-match "^\\*+ \\([A-Z]+\\)?" line)
                 (not (string= (match-string 1 line) keyword)))
        (let ((inhibit-read-only t)
              (from (+ heading (match-beginning 1)))
              (to (+ heading (match-end 1))))
          (save-excursion
            (delete-region from to)
            (goto-char from)
            (when (> (length keyword) 0) (insert keyword))))))))

(defun agent-org-buffer--replace-part-body (buffer key lines)
  "Swap part KEY's body for LINES, keeping its heading, clock and place in order.
This is the tool path's repaint: a call reports twice (ONGOING, then the
COMPLETE that carries its output) and BOTH states belong on the SAME headline
where the user saw it open --- moving the completion to the turn's end
would read as if the call happened after the thought that interrupted it.
Everything between the two body markers goes; the clock drawers live at or above
`:body-beg' (it moved past them when they were filed), so a repaint can never
delete a measurement."
  (with-current-buffer buffer
    (let ((beg (agent-org-buffer--part-mark key :body-beg))
          (end (agent-org-buffer--part-mark key :body-end)))
      (when (and beg end)
        (let ((inhibit-read-only t))
          (save-excursion
            (delete-region beg end)
            (goto-char beg)
            (insert (mapconcat #'identity lines "\n"))
            (unless (bolp) (insert "\n"))
            (agent-org-buffer--protect beg (point))
            (move-marker (plist-get (agent-org-buffer--part key) :body-end)
                         (point))))))))

(defun agent-org-buffer--append-part-stream (buffer key text)
  "Append TEXT to part KEY's body as a TEXT STREAM, not as one line per chunk.
The thinking path's writer.  The wire splits a run wherever its tokens land --
\"the agent \" then \"thinks twice\" -- so this merges what it holds back with
TEXT (`agent-org-buffer--split-stream'), writes the complete lines, and leaves
the unfinished remainder as the body's LAST line.  That last line is
PROVISIONAL: the next chunk deletes just it and rewrites the merged text, which
is the same one-line window the markdown converter keeps for prose.  Two
properties fall out of it, and the ordering rule needs both: a sentence is never
broken across two lines, and the body ALWAYS ends on a line boundary, so the
next block can be laid down underneath a streaming run without a heading gluing
onto the agent's words.  Cost stays O(one line) per update.

A call cannot use this -- its second report carries the whole output, which is a
replacement, and `agent-org-buffer--replace-part-body' is what deletes."
  (with-current-buffer buffer
    (let ((beg (agent-org-buffer--part-mark key :body-beg))
          (end (agent-org-buffer--part-mark key :body-end)))
      (when (and beg end)
        (let* ((held agent-org-buffer--thought-tail)
               ;; was a provisional line written last time?  An EMPTY held value
               ;; means no: the previous chunk ended on a newline, so the body's
               ;; last line is SETTLED and deleting it would drop a line of the
               ;; agent's thought off the page.
               (prov (and held (not (string-empty-p held))))
               (piece (agent-org-buffer--split-stream held text))
               (lines (append (unless (string-empty-p (car piece))
                                (agent-org-buffer--drawer-safe-lines (car piece)))
                              (unless (string-empty-p (cdr piece))
                                (agent-org-buffer--drawer-safe-lines (cdr piece)))))
               (inhibit-read-only t))
          (save-excursion
            ;; the body's last line is the fragment written last time: it is
            ;; REPLACED, or the merged text would carry the fragment twice
            (let ((target (if (and prov (> end beg))
                              (progn (goto-char end) (forward-line -1)
                                      (line-beginning-position))
                            end)))
              (delete-region target end)
              (goto-char target)
              (when lines
                (insert (mapconcat #'identity lines "\n") "\n"))
              (agent-org-buffer--protect target (point))
              (move-marker (plist-get (agent-org-buffer--part key) :body-end)
                           (point))))
            (setq agent-org-buffer--thought-tail (cdr piece)))))))

(defun agent-org-buffer--clock-part (buffer key)
  "Shut part KEY's clock: complete the open `CLOCK:' line, once.
The measurement runs from the moment the activity appeared to now, and it is
KEYED OFF THE ACTIVITY, not off the exchange: `agent-org-buffer--turn-start' is
spent by the exchange's own close and would answer nil for every part but the
first, so a part carries its own start (see `agent-org-buffer--parts').  The
`SECONDS:' name is Org's own generic entry property, which keeps a part's number
readable by `org-clock-sum' and a clock table without a second vocabulary.

The block this completes was written by `agent-org-buffer--open-part' when the
heading appeared, so the close is a two-line edit IN PLACE: no text moves, and
the body markers, which were born below the furniture, are not touched.  The
whole-block insert below is the FALLBACK, for a part whose open block is missing
-- a hot-reload that caught a running turn, or a part made before this shape
existed -- and it keeps the marker bookkeeping that shape needs.

Nothing is written when `agent-org-buffer--record-clock-p' is nil — a replayed
turn has no timing to invent, and a fabricated clock among the real ones is the
one thing the user's Org clocking cannot tolerate — but the part is still marked
clocked, so a boundary after the replay files none either."
  (with-current-buffer buffer
    (when-let* ((cell (assoc key agent-org-buffer--parts #'equal))
                (part (cdr cell)))
      (unless (plist-get part :clocked)
        (setf (alist-get key agent-org-buffer--parts nil nil #'equal)
              (plist-put part :clocked t))
        (let ((start (plist-get part :start))
              (heading (agent-org-buffer--part-mark key :heading))
              (beg (agent-org-buffer--part-mark key :body-beg))
              (end (agent-org-buffer--part-mark key :body-end)))
          (when (and start agent-org-buffer--record-clock-p)
            ;; `let*', not `let': a `let' evaluates EVERY init form before it
            ;; binds ANY of them, so binding `inhibit-read-only' here and editing
            ;; the block in the same form's value would run the edit with the
            ;; variable still nil — and `delete-region' on protected furniture is
            ;; a `text-read-only' out of a timer, where nothing can hear it.
            (let* ((inhibit-read-only t)
                   ;; THE BLOCK IS ALREADY ON THE PAGE: `--open-part' filed it
                   ;; under the heading when the activity appeared, so shutting the
                   ;; measurement is a two-line edit found from the heading.
                   (closed (and heading
                                (save-excursion
                                  (goto-char heading)
                                  (forward-line 1)
                                  (agent-org-buffer--clock-complete
                                   start agent-org-clock--part-property)))))
              (unless closed
                ;; NOTHING ELSE IS INSERTED on the success path: the fallback
                ;; would lay a second drawer over the one that is now shut, and
                ;; two `CLOCK:' lines on one heading double-count in every Org
                ;; total.
                (when beg
                  ;; both markers on one point: the block is filed BETWEEN them,
                  ;; so an empty body must move its END with its BEG (see the
                  ;; note below).
                  (let ((empty (and end (= beg end))))
                    (save-excursion
                      (goto-char beg)
                      (insert (agent-org-buffer--clock-lines
                               start agent-org-clock--part-property))
                      ;; the clock block is furniture the user reads but must not
                      ;; edit: `--protect' is what keeps `C-x u' and a stray key
                      ;; out of a measurement.
                      (agent-org-buffer--protect beg (point))
                      ;; BEG is front-grazing (see `--open-part'), so the block
                      ;; just filed is INSIDE the body region it marks.  Move it
                      ;; past the measurement: a later repaint of this part's body
                      ;; deletes between BEG and END, and must not be able to eat
                      ;; a clock.
                      (move-marker (plist-get (agent-org-buffer--part key) :body-beg)
                                   (point))
                      ;; and the same for END when the body was empty.  A call that
                      ;; has printed nothing sits at beg == end, and a
                      ;; front-grazing END stays BEHIND the block this insert lays
                      ;; down: the region would INVERT, and the call's next report
                      ;; -- which deletes between the two markers -- would take the
                      ;; clock with it.  Measured on the replayed turn this came
                      ;; from: the completion ate its own `CLOCK:' line.
                      (when empty
                        (move-marker (plist-get (agent-org-buffer--part key) :body-end)
                                     (point))))))))))))))

(defun agent-org-buffer--finish-part (buffer key)
  "End part KEY: settle its word, file its clock, and stop appending to it.
An empty prose/thinking part is DELETED, heading and all — the same reasoning
that dropped the `Agent:' line in a tool-only turn: a heading claiming the agent
responded, with nothing under it, is noise in the user's notes and a clock
measuring an activity that showed nothing is a lie about a duration.

A TOOL CALL IS NEVER that heading: the wire sends `tool_call' with a title and
status and no content, so the part is empty the whole time the call runs, and
the FACT it reports is the call itself.  Deleting it took the headline off the
page, dropped the cell that maps a `toolCallId' to its place, and left the later
`completed' report with nowhere to land — it then re-opened at the BOTTOM of the
turn (out of arrival order) and its repaint ate the next call's heading.  Four
replayed calls rendered as two headings this way.  So a call keeps its headline
wearing the wire's word and its clock, empty body or not, exactly as
`agent-org-buffer--close-parts' already assumes.

The cell goes with the deletion for those two kinds because nothing rewrites a
closed thought or a closed stretch of prose: a later one is a NEW activity and
must open below.  A tool call's cell survives so its next report can still find
its headline."
  (with-current-buffer buffer
    (when (equal agent-org-buffer--live-part key)
      (setq agent-org-buffer--live-part nil))
    (when (agent-org-buffer--part key)
      (if (and (agent-org-buffer--part-empty-p key)
               (not (agent-org-buffer--tool-part-p key)))
          (agent-org-buffer--delete-part buffer key)
        (agent-org-buffer--set-part-keyword buffer key
                                           (agent-org-buffer--settled-keyword key))
        (agent-org-buffer--clock-part buffer key))
      (unless (agent-org-buffer--tool-part-p key)
        (agent-org-buffer--forget-part key)))))

(defun agent-org-buffer--delete-part (buffer key)
  "Take part KEY's headline and body out of the buffer, markers and cell with it."
  (with-current-buffer buffer
    (when-let* ((cell (assoc key agent-org-buffer--parts #'equal)))
      (let ((beg (agent-org-buffer--part-mark key :heading))
            (end (agent-org-buffer--part-mark key :body-end))
            (inhibit-read-only t))
        (when (and beg end)
          (save-excursion
            (delete-region beg end)
            ;; the blank line `--open-part' put above the heading is now the gap
            ;; before whatever follows: one of them has to go or every dropped
            ;; part leaves a hole.
            (goto-char beg)
            (when (and (> beg (point-min))
                       (eq ?\n (char-before (1- beg))))
              (delete-char -1))))
        (setf (cdr cell) nil)
        (agent-org-buffer--forget-part key)))))

(defun agent-org-buffer--forget-part (key)
  "Drop KEY's cell and kill its markers, leaving the buffer text alone."
  (when-let* ((cell (assoc key agent-org-buffer--parts #'equal)))
    (dolist (m (list (plist-get (cdr cell) :heading)
                     (plist-get (cdr cell) :body-beg)
                     (plist-get (cdr cell) :body-end)))
      (when (markerp m) (set-marker m nil)))
    (setq agent-org-buffer--parts
          (seq-filter (lambda (c) (not (eq c cell)))
                      agent-org-buffer--parts))))

(defun agent-org-buffer--ensure-response-part (buffer)
  "Make sure the answer prose has a live part to be written into.
Called by every writer of answer text just before it inserts, because in this
style the prose is a part like any other: if the agent thought or called
something after the last line it wrote, the prose's part is no longer the last
block, and the next line opens a fresh `** RESPONDING <model>' below it rather
than climbing back up the turn.  `agent-org-buffer--text-end' reads the marker
this leaves live, so the writers themselves stay unchanged.

The word comes from the RESPONSE set (`agent-org-buffer--part-open-word'), so a
user who renamed WRITING gets renamed headlines; a set with no unfinished word
at all falls back to the universal `TODO' rather than a heading with no state,
which would not be a headline Org can cycle.

Outside `headings' style this does nothing at all: the prefix line written by
`agent-org-buffer-start-agent-turn' and `agent-org-buffer--quote-end' are that
style's answer part, and the writers are the same functions either way."
  (when (agent-org-buffer--parts-p)
    (with-current-buffer buffer
      (unless (equal agent-org-buffer--live-part "response")
        (agent-org-buffer--open-part
         buffer "response"
         (agent-org-buffer--part-open-word "response")
         (agent-org-buffer--response-label) nil)))))

(defun agent-org-buffer--close-parts (buffer)
  "Finish every part still open at the turn boundary, newest activity last.
The live part goes through `--finish-part' (settle, clock, drop if empty); the
ones it left behind are calls whose last report was not terminal and whose clock
is therefore overdue — the turn ENDED, so that is the honest end of their span
even though the wire never said COMPLETE.  An already-clocked part is skipped by
the guard in `--clock-part', so a second boundary call files nothing twice."
  (with-current-buffer buffer
    (when agent-org-buffer--live-part
      (agent-org-buffer--finish-part buffer agent-org-buffer--live-part))
    (dolist (cell (copy-sequence agent-org-buffer--parts))
      (let ((key (car cell)))
        (when-let* ((part (cdr cell)))
          ;; an empty PROSE part or thought is not an activity worth a number of
          ;; seconds — it is a heading that will be dropped; a call that printed
          ;; nothing ran just the same, so it keeps its clock.
          (unless (or (plist-get part :clocked)
                      (and (not (agent-org-buffer--tool-part-p key))
                           (agent-org-buffer--part-empty-p key)))
            (agent-org-buffer--clock-part buffer key)))))))

(defun agent-org-buffer--close-response-clock ()
  "Shut this turn's `CLOCK:' line and `:RESPONSE:' property, once.
Called with the chat buffer current, at the turn boundary.  Does nothing
when there is no recorded start — between turns, on an orphan, and on
EVERY replayed exchange (`agent-org-buffer--record-clock-p' nil means
`agent-org-buffer-begin-exchange' never opened a block) — and consumes the
stamp first, so a second boundary call files a second clock never.

What it normally does is a TWO-LINE EDIT IN PLACE, because the block is not
written here: `agent-org-buffer-begin-exchange' laid it under the heading the
moment the question went out, with the beginning timestamp alone.  Closing adds
the end stamp, the `=>' duration and the exact seconds (user order
2026-10-11: \"You shouldn't insert the whole `CLOCK:' in the end.  Start by
adding the beginning timestamp.  Then, add the ending time with duration in the
end.\").

The whole-block insert is the fallback, for an exchange whose heading has no
open block in the shape this package writes: a hot-reload that caught a running
turn, or a buffer whose turn was opened by an older definition.

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
  - the line is `org-clock-out' format — a closed range with an `=>'
    duration — in Org's OWN minute granularity, because a `CLOCK:' carrying
    seconds parses to zero clock nodes in 9.7.11 (§22).  The seconds the
    user asked for ride in the property, which is what
    `agent-org-clock-display' reads.

An OPEN `CLOCK:' line is written NOW, and left open only for the seconds the
activity actually runs: that was the stated reason this package refused it, and
measurement retired the refusal (Org 9.7.11: `org-clock-load' does not adopt an
open line, `org-clock-in' on another heading still succeeds, `org-clock-sum'
counts it as 0 minutes — see `agent-org-buffer--clock-open-lines').  What an
open line must never survive is the activity: every boundary shuts it.

Always called with the chat buffer current."
  (when-let* ((start agent-org-buffer--turn-start))
    (setq agent-org-buffer--turn-start nil)    ; spend it: one clock per turn
    (when-let* ((anchor (agent-org-buffer--live-mark
                         agent-org-buffer--turn-anchor))
                (inhibit-read-only t))
      (save-excursion
        (goto-char anchor)
        (forward-line 1)                       ; bol of the line after the heading
        (unless (agent-org-buffer--clock-complete
                 start agent-org-clock--exchange-property)
          (let ((beg (point)))
            (insert (agent-org-buffer--clock-lines
                     start agent-org-clock--exchange-property))
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
furniture entirely if the agent never said anything.

In `headings' style the bookkeeping is the same with a different shape: the
flush lands in the prose's part, every part then settles its word and files its
own clock (`agent-org-buffer--close-parts'), and a part that ended up with
nothing under it is deleted rather than left as a heading claiming an answer."
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
          (agent-org-buffer--close-parts buffer)
          (setq agent-org-buffer--streaming-p nil
                agent-org-buffer--stream-start nil))
        ;; The response clock closes at EVERY boundary, streaming or not:
        ;; a tool-only turn answered in 90 seconds measured just as well as
        ;; a paragraph, and a cancelled turn's elapsed time is the number
        ;; the user wanted when they asked for a killable session.  Outside
        ;; the `when' above so a late second call still finds the stamp
        ;; spent rather than a second clock.
        (agent-org-buffer--close-response-clock)
        ;; The exchange's own word settles here too, for the same reason the
        ;; clock is not left to the status path: REPLAY runs these primitives
        ;; with no per-turn status events, so if only `set-status' wrote words
        ;; every restored prompt would sit in the transcript claiming to still
        ;; be waiting.  A live turn then OVERLAYS this with whatever the bar
        ;; says -- CANCELLED and ERROR arrive after the boundary, in that order.
        (agent-org-buffer--set-exchange-keyword
         buffer
         (agent-org-buffer--keyword-set-word agent-org-prompt-todo-keywords
                                             nil 0))))
    ;; The seconds the boundary just filed go on screen HERE, not in a hook on
    ;; each clock write: one pass over the headings per turn, after every drawer
    ;; of the turn exists, is the whole cost.  Lite mode (§19) is the first gate
    ;; because a display that recomputes the buffer on every boundary is exactly
    ;; the per-turn work lite exists to refuse; a chat with the mode off is the
    ;; user's own choice and stays untouched.
    (when (and agent-org-clock-display-mode (not (agent-org-lite-p buffer)))
      (agent-org-clock--draw))))

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
      ;; A reply chunk seals the board ONLY in `headings' style, where the prose
      ;; is itself a block at the END of the turn: the next call then belongs
      ;; below what the agent has said since.  In `drawers' and `none' the answer
      ;; is written above every block of the turn, so a board sealed by prose
      ;; could only land directly below the board it came from -- two `:tool:'
      ;; drawers touching, the shape the user forbade
      ;; (`test-agent-org-no-adjacent-tool-drawers').
      (when (agent-org-buffer--parts-p)
        (agent-org-buffer--seal-tool-board))
      ;; The answer's own part opens on the FIRST chunk, not on the first
      ;; finished line: in `headings' style the `** RESPONDING <model>' heading
      ;; is the furniture a reader looks at to see what the agent is saying
      ;; now, and a token-capped agent can stream a whole reply before a single
      ;; newline lands.  A no-op outside that style, and harmless there: the
      ;; line still arrives when its newline does.
      (agent-org-buffer--ensure-response-part buffer)
      (if agent-org-convert-markdown
          (agent-org-buffer--markdown-receive text)
        ;; the verbatim path writes the whole chunk at once, so it opens the
        ;; prose part itself; the converter's writers (`--markdown-write', the
        ;; flush) do the same on the lines they land.
        (agent-org-buffer--ensure-response-part buffer)
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
               ;; The floor of that search is BELOW the answer's end marker
               ;; whenever there is room below it (the live type-ahead box or
               ;; queue), so a `:thinking:' line inside the agent's OWN text
               ;; cannot be mistaken for the drawer.  When the marker sits AT
               ;; the end of the turn -- a drawer created with nothing under
               ;; it makes the rear-advancing marker jump past its own
               ;; `:end:', and then marker IS turn-end -- an empty window
               ;; would find nothing and paint a duplicate; fall back to the
               ;; turn anchor, which bounds the search to this turn's blocks.
               (region-start (if (and mark-pos (< mark-pos turn-end))
                                 mark-pos
                               (or anchor-pos mark-pos turn-end)))
               ;; While a turn streams it runs from its anchor to
               ;; `turn-end': the live type-ahead box trails it, so the
               ;; search stops at the box rather than at `point-max'.
               ;; Without a box (a replay) `turn-end' IS `point-max'.
               ;; The LIVE drawer of a kind is the LAST one of that kind in
               ;; the turn, never the first: a run reuses its drawer only
               ;; while nothing of another kind has been drawn below it (the
               ;; `--thought-drawer-live-p' / `--tool-drawer-live-p' flags),
               ;; so a second `:thinking:' board lands UNDER the first and
               ;; the live run is the one at the bottom.  Searching FORWARD
               ;; painted the earliest drawer instead, which is how a later
               ;; thought overwrote an earlier one.  Searching BACKWARD from
               ;; the end of the turn answers with the live one directly.
               ;; The bound is still below the answer's end marker whenever
               ;; there is room there, so a `:thinking:' line the agent
               ;; quoted into its OWN text cannot be mistaken for a drawer.
               (drawer-beg
                (and (not fresh)
                     (save-excursion
                       (goto-char turn-end)
                       (when (re-search-backward (format "^:%s:$" name)
                                                 region-start t)
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

(defun agent-org-buffer--none-flush (lines)
  "Return LINES with the drawer body's two columns removed.
The board is BUILT drawer-shaped (`--tool-board-body': a call at two columns,
its output at four) because that is the shape the `:tool:' container needs.  A
block painted with no container has nothing to nest under, so the same lines at
the same indent read as a list dangling off the preceding paragraph."
  (mapcar (lambda (l) (if (string-prefix-p "  " l) (substring l 2) l))
          lines))

(defun agent-org-buffer--paint-activity (buffer kind lines &optional fold fresh)
  "Draw this turn's activity block KIND (\"tool\" or \"thinking\") holding LINES.
The container comes from `agent-org-activity-style': `drawers' hands over to
`agent-org-buffer--redraw-drawer', which finds the block again by its `:NAME:'
and `:end:' lines; `none' and `headings' have no such lines, so they go to
`agent-org-buffer--repaint-block', which remembers where it put the block.

FOLD is the drawer's default and is read only by the drawer path -- a bare list
item has nothing to fold, and a headline folds with Org's own subtree fold (TAB
on it), which is why the heading mode ships with no fold code at all.  FRESH
means the same thing on both paths: the block found so far is history, and this
LINES body opens a new one at the end of the turn."
  (if (eq agent-org-activity-style 'drawers)
      (agent-org-buffer--redraw-drawer buffer kind lines fold fresh)
    (agent-org-buffer--repaint-block buffer kind lines fresh)))

(defun agent-org-buffer--repaint-block (buffer kind lines fresh)
  "Replace this turn's container-less block KIND with LINES, or draw a new one.
Without a `:tool:' line to search for, the block's own bounds are the only thing
that can say what to replace, so they live in
`agent-org-buffer--activity-marks' as a (BEG . END) marker pair per kind.
Both are front-grazing: text inserted AT the end of the block -- the next
block of the other kind, which lands at the turn's end -- must not be
swallowed by this block's region, and the END marker is moved by hand after
a repaint anyway.

The marker dance at the end is the same hazard the drawer path documents: a
block created at the turn's end, when the answer's rear-advancing marker
also sits at the turn's end, slides that marker past the whole block, and
the next prose chunk would land BELOW it.  So the answer marker is put back
where it stood."
  (with-current-buffer buffer
    (let ((inhibit-read-only t)
          (body (mapconcat #'identity lines "\n"))
          (cell (cdr (assoc kind agent-org-buffer--activity-marks))))
      (save-excursion
        (let ((beg (and (not fresh) cell
                        (agent-org-buffer--live-mark (car cell))))
              (end (and (not fresh) cell
                        (agent-org-buffer--live-mark (cdr cell)))))
          (if (and beg end (<= beg end))
              (progn
                (delete-region beg end)
                (goto-char beg)
                (insert body "\n")
                (agent-org-buffer--protect beg (point))
                (move-marker (cdr cell) (point)))
            (let ((answer-mark (agent-org-buffer--live-mark
                                agent-org-buffer--quote-end)))
              (goto-char (agent-org-buffer--render-end))
              (agent-org-buffer--separator)
              (let ((block-beg (point)))
                (insert body "\n")
                (agent-org-buffer--protect block-beg (point))
                (setf (alist-get kind agent-org-buffer--activity-marks
                                 nil nil #'equal)
                      (cons (copy-marker block-beg) (copy-marker (point)))))
              (when (and (markerp agent-org-buffer--quote-end) answer-mark)
                (move-marker agent-org-buffer--quote-end answer-mark)))))))))

(defun agent-org-buffer--split-stream (pending text)
  "Return PENDING+TEXT as its complete lines plus the unfinished tail.
A CONS of (COMPLETE . TAIL).  The rule a streamed block appends by: a chunk off
the wire is a fragment of a text stream, so only what lies up to the LAST
newline may go on the page -- the rest is still being said, and closing it at
the boundary would break a sentence across two lines.  PENDING is whatever the
last call held back (see `agent-org-buffer--thought-tail'), so a run of chunks
that never contains a newline is held whole rather than written in pieces."
  (let* ((stream (concat pending text))
         (i (length stream)))
    (while (and (> i 0) (not (eq ?\n (aref stream (1- i)))))
      (setq i (1- i)))
    (if (zerop i)
        (cons "" stream)
      (cons (substring stream 0 (1- i)) (substring stream i)))))

(defun agent-org-buffer-append-thought (buffer text)
  "Record thinking TEXT as this run's thinking block in BUFFER.
Three shapes, from `agent-org-activity-style', and one rule they all share: a
run is reused only while it is still the LAST block of the turn, so a thought
that arrives after a tool call opens a new one below it and the transcript reads
thought, action, thought in the order it happened.

`headings' (the default) makes the run a clocked `** TODO Thinking' headline and
APPENDS to that body: the complete lines are written once and only the
unfinished last line is rewritten as the stream grows, so a long run stays
O(one line) per update and a sentence split across two chunks still reads as
one line.  `drawers' accumulates the whole run in
`agent-org-buffer--thought' and re-renders the folded `:thinking:' drawer;
`none' paints the same accumulated text as bare list items, through the one
dispatch `agent-org-buffer--paint-activity' (which is what a style option that
no render site read used to mean: the drawers call sat below it)."
  (when (and text (not (string-empty-p text)))
    (with-current-buffer buffer
      (unless agent-org-buffer--streaming-p
        (agent-org-buffer-start-agent-turn buffer nil))
      ;; a thought is non-tool activity: the run of calls it interrupts gets a
      ;; drawer of its own, and the next call opens a new one BELOW the thought
      ;; instead of joining the board above it
      (agent-org-buffer--seal-tool-board)
      ;; the block lands below the turn's text, so freeze the line the
      ;; converter still owns first: a provisional tail must not outlive this
      ;; boundary or the next chunk would rewrite the drawer
      (agent-org-buffer--markdown-flush-here)
      (if (agent-org-buffer--parts-p)
          (progn
            (unless (equal agent-org-buffer--live-part "thinking")
              (agent-org-buffer--open-part buffer "thinking"
                                           (agent-org-buffer--part-open-word
                                            "thinking")
                                           "Thinking" nil))
            (agent-org-buffer--append-part-stream buffer "thinking" text))
        ;; ONE DRAWER PER RUN, and the run is over as soon as anything is drawn
        ;; below it: `agent-org-buffer-insert-tool' clears the flag when it opens
        ;; a new board, so the next chunk starts a second drawer holding a second
        ;; segment.  Without that hand-off every thought of a turn piled into the
        ;; FIRST drawer, which sat above every board drawn after it, and the
        ;; transcript read "the agent thought everything, then did everything".
        (let ((fresh (not agent-org-buffer--thought-drawer-live-p)))
          (when fresh (setq agent-org-buffer--thought nil))
          (setq agent-org-buffer--thought
                (concat agent-org-buffer--thought text)
                agent-org-buffer--thought-drawer-live-p t)
          (agent-org-buffer--paint-activity
           buffer "thinking"
           (append
            ;; A thought with no drawer around it is an indented paragraph with
            ;; no label, so `none' names it.  Inside a drawer the `:thinking:'
            ;; line IS that label, and repeating it would be prose claiming to be
            ;; a state.
            (and (eq agent-org-activity-style 'none) '("Thinking:"))
            (agent-org-buffer--drawer-safe-lines agent-org-buffer--thought))
           t fresh))))))

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

(defun agent-org-buffer--tool-board-groups (entries)
  "Fold ENTRIES into consecutive groups of one label and one status.
Each group is (LABEL STATUS . CALLS), CALLS in wire order.  Only
CONSECUTIVE calls of the same title and status fold — the board is a
window over the record, and a repeated title says \"the agent ran this
again\", which is information; splitting the run would read as one call.
Collapsing is RENDERING: `agent-org-buffer--tools' stays one entry per
`toolCallId' and nothing in it is touched."
  (let (groups)
    (dolist (entry entries)
      (let* ((label (agent-org-buffer--label
                     (or (plist-get (cdr entry) :title) "tool")))
             (status (plist-get (cdr entry) :status)))
        ;; a group is (LABEL STATUS . CALLS); the tail is the call list, so
        ;; the status sits at (cadr ...) and `cdar' would drag the calls in
        (if (and groups
                 (equal (caar groups) label)
                 (equal (cadr (car groups)) status))
            (setcar groups (cons label
                                 (cons status
                                       (cons entry (cddar groups)))))
          (push (cons label (cons status (list entry))) groups))))
    ;; groups were pushed newest-first (the same way LINES is pushed);
    ;; the board renders oldest-first, so the fold must not reorder
    (nreverse (mapcar (lambda (g) (cons (car g) (cons (cadr g)
                                                      (nreverse (cddr g)))))
                      groups))))

(defun agent-org-buffer--tool-board-body ()
  "This turn's `:tool:' drawer body: one item per call, its output under it.
Built from `agent-org-buffer--tools', so the drawer cannot drift from the
record: a call is `  - KEYWORD title' and, when it printed anything, that
text is the item's body at four columns.  A call is named by its TITLE and
needs no number to point at a second drawer, because there is no second
drawer -- the user's order: \"Tool call outputs belong to the same TODO
headings\", after \"Consecutive tool calls belong to a single drawer\".

Consecutive calls of one title and one status fold into a single item
carrying the count — three completed `run tests' calls read
`  - COMPLETE run tests (x3)' — with every call's output kept beneath it,
in call order (the user's ruling 2026-10-21, TODOs.org §Tool-call
grouping).  A RUNNING call never folds into COMPLETED ones: the keyword
is the item's state, and a folded state would be a lie about all of them.

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
    (dolist (group (agent-org-buffer--tool-board-groups
                    (nthcdr agent-org-buffer--tool-group-start
                            agent-org-buffer--tools)))
      (let ((label (car group))
            (status (cadr group))
            (members (cddr group))
            drew-output)
        (push (format "  - %s %s%s"
                      (agent-org-buffer--tool-keyword status)
                      label
                      (if (> (length members) 1)
                          (format " (x%d)" (length members))
                        ""))
              lines)
        ;; every call's body survives the fold, call order preserved; each
        ;; member's blank line separates its output from what follows
        (dolist (entry members)
          (let ((output (plist-get (cdr entry) :output)))
            (when (and output (not (string-empty-p output)))
              (setq drew-output t)
              (dolist (line (agent-org-buffer--drawer-safe-lines output))
                (push (if (string-empty-p line) "" (concat "   " line))
                      lines))
              (push "" lines))))
        ;; a group with no output still closes with one blank, the same
        ;; rhythm a lone outputless item had before the fold existed
        (unless drew-output (push "" lines))))
    (nreverse lines)))

(defun agent-org-buffer--tool-part-lines (entry)
  "The body of one call's part: what it printed, under its headline.
The same text the drawer path puts at four columns beneath an item, here at one
column beneath a heading.  `agent-org-buffer--drawer-safe-lines' again, because
a shell result that quotes an Org file can carry a `*' bullet or a bare
`:END:', and in a part body either would end the part or close the clock
drawers filed under its heading."
  (let ((output (plist-get entry :output)))
    (if (and output (not (string-empty-p output)))
        (agent-org-buffer--drawer-safe-lines output)
      nil)))

(defun agent-org-buffer--paint-tool-part (buffer id)
  "Draw the tool call ID's part as its own clocked `**' headline.
The part opens at the end of the turn on the call's FIRST report --- that is
the moment the user sees it start --- and every later report of the same id
rewrites THAT heading's word and its body where it stands, even after a thought
or another call moved the turn's end past it.  Moving the completion below
would claim the call happened after the thing that interrupted it, and would
leave the state the user was watching duplicated at the bottom.

Its clock is filed by a TERMINAL status rather than by an interrupt: an
interrupted call has not finished, so its span ends when the wire says so, or
at the turn boundary, whichever comes first
(`agent-org-buffer--close-parts')."
  (let* ((key (concat "tool:" id))
         (cell (assoc id agent-org-buffer--tools))
         (entry (cdr cell))
         (keyword (agent-org-buffer--tool-keyword
                   (plist-get entry :status)))
         (lines (agent-org-buffer--tool-part-lines entry)))
    (if (agent-org-buffer--part key)
        (progn
          (agent-org-buffer--set-part-keyword buffer key keyword)
          (agent-org-buffer--replace-part-body buffer key lines))
      ;; a call with no title at all still needs a heading a reader can name
      (agent-org-buffer--open-part buffer key keyword
                                   (or (plist-get entry :title) "tool")
                                   lines))
    (when (agent-org-buffer--tool-entry-final-p cell)
      (agent-org-buffer--clock-part buffer key))))

(defun agent-org-buffer-insert-tool (buffer content)
  "Record the tool call or update CONTENT, then repaint the turn's one board.
CONTENT is the tool-call alist from the ACP notification.  Each toolCallId
owns exactly one ITEM of the current turn's `:tool:' drawer -- `  - KEYWORD
title', with what the call printed indented under it.  KEYWORD maps the ACP
status onto the tool set (`agent-org-tool-todo-keywords'):
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
        (if (agent-org-buffer--parts-p)
            (agent-org-buffer--paint-tool-part buffer id)
          (let* ((fresh (not agent-org-buffer--tool-drawer-live-p))
                 (board (agent-org-buffer--tool-board-body))
                 ;; With no drawer to sit inside, the board's two-column items
                 ;; would be a NESTED list under nothing, so `none' flushes the
                 ;; body left.  The RECORD and the guard below stay in the
                 ;; drawer's own shape, which is what the guard compares.
                 (body (if (eq agent-org-activity-style 'none)
                           (agent-org-buffer--none-flush board)
                         board)))
            (unless (equal board agent-org-buffer--tools-shown)
              (setq agent-org-buffer--tools-shown board
                    ;; the drawer this body was painted into is now the live one,
                    ;; so the NEXT call reuses it -- unless a thought or a reply
                    ;; has sealed it since, which is what FRESH asked about
                    agent-org-buffer--tool-drawer-live-p t)
              ;; A board drawn BELOW the thinking run is the other half of that
              ;; hand-off: it ends the run, so the next chunk starts a second
              ;; drawer instead of piling into the first one.  Only a FRESH board
              ;; does it -- a call still running is repainted in place, which puts
              ;; nothing below the thought.
              (when fresh
                (setq agent-org-buffer--thought-drawer-live-p nil))
              (agent-org-buffer--paint-activity buffer "tool" body nil fresh))))))))

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

(defcustom agent-org-transcript-dir ".agent-org"
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
inside a directory named like `agent-org-transcript-dir' (`.agent-org'
by default, or whatever basename an absolute setting ends in).  A relative
setting is reduced to its basename here, so the answer is the same whatever
`default-directory' happens to resolve it against.

Judged on the path alone, so it works for a file no session has open -- that
is exactly when a person `find-file's a transcript to read it."
  (when-let* ((dir (file-name-directory file))
              (parent (file-name-nondirectory (directory-file-name dir)))
              (wanted (file-name-nondirectory
                        (directory-file-name
                         (expand-file-name agent-org-transcript-dir)))))
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
never sent, so it is in no `session/load' replay and in no `* PROMPT' heading
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
`agent-org-transcript-dir' is a relative name by default, and
`expand-file-name' is what turns that into \"the chat's own directory\":
called with the chat buffer current, `default-directory' is the session cwd
the buffer was created in.  An absolute setting expands to itself, so one
global pool is still a setting away rather than a code change."
  (expand-file-name (agent-org-buffer--transcript-name session-id)
                    (file-name-as-directory
                     (expand-file-name agent-org-transcript-dir))))

(defun agent-org-buffer-transcript-queue (session-id)
  "The prompts SESSION-ID's transcript has waiting, oldest first; nil if none.
Resume needs this because a queued prompt was never sent: it is in none of
the places a restore normally finds text — not the agent's `session/load'
replay (the agent never saw it), not the buffer (a fresh one), not a
`* PROMPT' heading.  The queue block `agent-org-buffer-transcribe' appended to
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

(defun agent-org-buffer--find-file-transcript ()
  "Give a visited transcript its keyword sets, then open it read-only.
Installed on `find-file-hook' below; the whole function is a no-op for
anything that is not a transcript (see
`agent-org-buffer--transcript-file-p'), so a global hook costs one string
comparison per file visit and changes no other buffer.

The keyword half is new with the `org-todo-keywords' scope and is the reason
this hook is not just about read-only any more: the sets are no longer
announced in the FILE (there is no `#+TODO:' line to read), so a transcript
visited in another buffer starts with Org's default set and every `** COMPLETE
ls' headline on screen reads as plain text.  Installing them here costs one
reparse of a file the user chose to open, and only when `org-mode' has already
derived something to override -- `find-file-hook' runs BEFORE major-mode
selection for a brand-new buffer, and a hook that called `(org-mode)' there
would hijack every file visit into Org.

The read-only half is unchanged: `agent-org-transcripts-read-only' nil leaves
the buffer writable, and `write-region' from the transcriber is unaffected --
it writes the FILE with VISIT nil and does not go through this buffer's
`buffer-read-only', so a mirror still updates while it is on screen read-only."
  (when (and (buffer-file-name)
             (agent-org-buffer--transcript-file-p (buffer-file-name)))
    (when (derived-mode-p 'org-mode)
      (agent-org-buffer--install-todo-keywords))
    (when agent-org-transcripts-read-only
      (setq-local buffer-read-only t)
      (message "agent-org: transcript is a mirror, opened read-only (C-x C-q to edit)"))))

(add-hook 'find-file-hook #'agent-org-buffer--find-file-transcript)

;;;###autoload
(defun agent-org-refresh-todo-keywords ()
  "Re-derive this buffer's TODO keywords from the three option lists.
Edit `agent-org-prompt-todo-keywords', `agent-org-tool-todo-keywords' or
`agent-org-plan-todo-keywords' -- `M-x customize-variable' or Lisp -- and an
open chat still holds the words it was created with, because Org derived its
regexps once (`agent-org-buffer--install-todo-keywords').  Run this after the
edit.  Nothing else needs it: a new chat and a visited transcript both install
the sets as they start."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Not an Org buffer"))
  (agent-org-buffer--install-todo-keywords)
  (message "agent-org: TODO keywords now %S"
           (mapcar #'cdr (agent-org-buffer--todo-keyword-sets))))

(provide 'agent-org-buffer)
;;; agent-org-buffer.el ends here
