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

;; Org-native chat buffer: each turn is a level-1 headline, chunks
;; stream as raw text (font-lock off during streaming for speed),
;; and Org formatting is applied on turn-complete.
;;
;; Tool calls render as level-2 `** KEYWORD title [id]' subheadings
;; under the current `* Agent' heading, using the per-file keyword set
;; declared by the metadata block (`#+TODO: TODO DOING | DONE
;; CANCELLED'): pending→TODO, in_progress→DOING, completed→DONE,
;; failed→CANCELLED.  Thoughts keep the folded :thinking: drawer (a
;; drawer can hold no headings, so tools never shared that model).
;;
;; All status, progress and error feedback is shown in the buffer's
;; `header-line' (the top bar), the same way `gptel' and `agent-shell'
;; surface state.  The mode line is left untouched (no lighter).  The
;; body holds conversation (User/Agent turns, tool-call subheadings,
;; thoughts) plus one auto-managed metadata block at the very top: a
;; PROPERTIES drawer first, then the `#+TITLE:' keyword line (the
;; harness's own session title, verbatim), then the `#+TODO:' setup
;; line declaring the tool-heading keyword set, then
;; COMMANDS/MODES/CONFIG drawers — drawers folded by default, and no
;; heading, since `* ' lines belong to the conversation.
;;
;; Design (agent-shell-style always-typable buffer):
;;   - No comint, no terminal, no global read-only — just Org text.
;;   - Programmatic text (headings, streamed chunks, tool calls,
;;     thoughts) is frozen with the `read-only' text property: the
;;     cursor may travel over history freely, but editing it signals
;;     `text-read-only'.
;;   - Between turns the buffer ends in a live `* User' prompt: the
;;     heading is frozen, the body below it stays typeable, so the
;;     user just types and hits C-c C-c.
;;   - Status lives in `header-line', never in the buffer body.
;;   - Font-lock disabled during active streaming for max throughput,
;;     re-enabled on `agent-org-buffer-end-agent-turn'.

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

(defvar-local agent-org-buffer--status
  (list :provider "agent-org" :state 'idle :message nil :session-id nil)
  "Status plist backing this buffer's header line and metadata block.
Keys: :provider :state :message :note :session-id :model :model-name :mode
:project :title :used :size :tokens :cost-amount :cost-currency :commands
:modes-list :config.  STATE is one of `idle', `starting', `loading'
(session/load replay in flight), `streaming', `ready', `awaiting' or
`error'.  The list keys hold wire-format alists collected from ACP
notifications.

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
buffer-local status plist; safe to call headless."
  (let* ((status agent-org-buffer--status)
         (seg (agent-org-buffer--status-segment status))
         (sid (plist-get status :session-id)))
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
                        (when sid
                          (propertize (format "[%s]" sid) 'face 'shadow))
                        (agent-org-buffer--context-indicator status)
                        (agent-org-buffer--cost-indicator status)
                        (propertize (car seg) 'face (cdr seg))))
             " ➤ "))))

;;;; Buffer creation

(defun agent-org-buffer-create (name)
  "Create and return a new Org chat buffer for provider NAME.
Its initial name is `agent-org-buffer--wanted-name' — project and
provider, id still absent — so the buffer is findable by project from
the handshake onward.  Buffer is in `org-mode' and `agent-org-mode'
with a status header line.  Programmatic text is protected by
`read-only' text properties, not by a global `buffer-read-only', so the
live prompt at the end is always typeable."
  (let ((buf (generate-new-buffer (format "*agent-org: %s*" name))))
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
Font-lock is suppressed while this is set.")

(defvar-local agent-org-buffer--stream-start nil
  "Point at the start of the current streaming body.")

(defvar-local agent-org-buffer--turn-anchor nil
  "Marker at the start of the streaming `* Agent' heading, if any.
Tool headings and the :thinking: drawer are located relative to this
anchor, not to the buffer end, because `**' tool headings make the
Agent heading no longer the last heading of the turn.")

(defvar-local agent-org-buffer--tools nil
  "Ordered alist ((ID :marker MARKER :title TITLE :status STATUS) ...)
for the current Agent turn; each ID owns one `**' tool heading, and
`agent-org-buffer-insert-tool' rewrites it in place via MARKER.")

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
`*agent-org: qoder*' says nothing at all to someone with three qoder
chats open.  So the name carries the project directory, the harness's
own title and the ACP session id — the three things that make one
buffer different from the next, and the shape agent-shell's \"Claude
Agent @ project\" names converge on.

The provider stands in for a title that has not arrived, exactly as it
does for `#+TITLE:', and the id is left out until the agent has given one
(the buffer is named this way from the moment `session/new' is answered,
and qoder titles a session only after the first turn).  Title text is
agent-supplied free text, hence `agent-org-buffer--label': a buffer name
with a newline in it breaks the completion UI."
  (let* ((status agent-org-buffer--status)
         (sid (plist-get status :session-id))
         (project (plist-get status :project))
         (label (agent-org-buffer--label
                 (or (plist-get status :title)
                     (plist-get status :provider)
                     "agent-org"))))
    (format "*agent-org: %s%s%s*"
            (if (and project (not (string-empty-p project)))
                (concat project " ")
              "")
            label
            (if sid (format " [%s]" sid) ""))))

(defun agent-org-buffer--apply-name ()
  "Rename the current buffer to `agent-org-buffer--wanted-name', if needed.
The equality test is not an optimisation.  `generate-new-buffer-name'
counts this very buffer when it already wears the name, so renaming on
every status update would walk a session through
`*agent-org: T [s]*<2><3><4>' — a turn sends dozens of updates.
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
                         :cost-currency :commands :modes-list :config))
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
      (when agent-org-use-header-line
        (setq header-line-format
              '(:eval (agent-org-buffer--render-header-line))))
    (kill-local-variable 'header-line-format)))

;;;; Session metadata block (Org-native, agent-shell bootstrapping)

(defconst agent-org-buffer--todo-setup "#+TODO: TODO DOING | DONE CANCELLED"
  "Per-file keyword set (`org-set-regexps-and-options' reads it from
the metadata block) backing tool-call headings: pending→TODO,
in_progress→DOING, completed→DONE, failed→CANCELLED.")

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
The PROPERTIES drawer comes first, carrying the scalars (Provider,
Session, Mode, Model, Context, Cost, Tokens), then the `#+TITLE:'
keyword line, then COMMANDS/MODES/CONFIG drawers listing everything
the agent reported.  No heading: `* ' lines belong to the
conversation.  Drawers whose lists are still unknown are omitted."
  (let* ((provider (or (plist-get status :provider) "agent-org"))
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
              (format ":Session: %s\n"
                      (or (plist-get status :session-id) "unknown"))
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
             (agent-org-buffer--metadata-drawer "CONFIG" config)))
      "\n")
     ;; blank line separating the block from the first conversation
     ;; heading (refresh deletes up to that heading)
     "\n")))

(defconst agent-org-buffer--metadata-drawers
  '("PROPERTIES" "COMMANDS" "MODES" "CONFIG")
  "Names of the folded-by-default drawers in the metadata block.")

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

(defun agent-org-buffer-insert-prompt (buffer)
  "Append a live `* User' prompt to BUFFER unless one is already open.
Only the heading is frozen; the body stays typeable.  No-op while a
turn is streaming, so mid-turn session updates never slip a prompt
into the response."
  (with-current-buffer buffer
    (unless (or agent-org-buffer--streaming-p
                (agent-org-buffer--open-prompt-p))
      (let* ((inhibit-read-only t)
             (orig (point))
             ;; keep point where it was unless it was at the end or
             ;; trapped in frozen text (then it belongs at the prompt)
             (stay (or (eq orig (point-max))
                       (get-text-property orig 'read-only))))
        (goto-char (point-max))
        (let ((beg (point)))
          (agent-org-buffer--separator)
          (insert "* User\n\n")
          (agent-org-buffer--protect beg (point))
          ;; typed text after the heading must not inherit the freeze
          (put-text-property (1- (point)) (point)
                             'rear-nonsticky '(read-only))
          (unless stay (goto-char orig)))))))

(defun agent-org-buffer-read-prompt (buffer)
  "Freeze the live prompt in BUFFER and return its trimmed text.
Signals a user-error when the buffer does not end in an open prompt
or when nothing has been typed yet."
  (with-current-buffer buffer
    (unless (agent-org-buffer--open-prompt-p)
      (user-error "Nothing to send; type your prompt under the User heading"))
    (save-excursion
      (goto-char (point-max))
      (org-back-to-heading t)
      (let ((beg (point)))
        (org-end-of-meta-data t)
        (let ((text (string-trim (buffer-substring-no-properties
                                  (point) (point-max)))))
          (when (string-empty-p text)
            (user-error "Empty prompt"))
          (agent-org-buffer--protect beg (point-max))
          text)))))

(defun agent-org-buffer-insert-user (buffer text)
  "Insert a frozen User heading with TEXT into BUFFER (programmatic use)."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (point-max))
        (let ((beg (point)))
          (agent-org-buffer--separator)
          (insert (format "* User\n\n%s\n" text))
          (agent-org-buffer--protect beg (point)))))))

;;;; Streaming (the hot path)

(defun agent-org-buffer-start-agent-turn (buffer _session)
  "Begin a new Agent heading in BUFFER if one isn't already streaming.
Disable font-lock for the duration of the turn."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (unless agent-org-buffer--streaming-p
        (goto-char (point-max))
        (agent-org-buffer--separator)
        (let ((beg (point)))
          (insert "* Agent\n\n")
          (agent-org-buffer--protect beg (point))
          (move-marker (setq-local agent-org-buffer--turn-anchor
                                   (make-marker))
                       beg))
        ;; Turning font-lock off for a turn is the single biggest win on
        ;; a slow machine: without it every chunk re-fontifies the
        ;; buffer.  Guarded so a replay of many turns pays one
        ;; mode switch, not one per turn.
        (when font-lock-mode (font-lock-mode -1))
        ;; turn-local tool state: drop the previous turn's markers so a
        ;; reused toolCallId (e.g. after `resume') cannot rewrite its
        ;; old heading
        (dolist (e agent-org-buffer--tools)
          (when-let* ((m (plist-get (cdr e) :marker)))
            (set-marker m nil)))
        (setq agent-org-buffer--streaming-p t
              agent-org-buffer--stream-start (point)
              agent-org-buffer--tools nil
              agent-org-buffer--thought nil)))))

(defun agent-org-buffer-end-agent-turn (buffer)
  "Finish the streaming Agent turn in BUFFER, re-enable font-lock."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (when agent-org-buffer--streaming-p
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (setq agent-org-buffer--streaming-p nil
              agent-org-buffer--stream-start nil)
        ;; re-enable only when `start-agent-turn' actually turned it
        ;; off; a redundant call would re-fontify the whole buffer
        (unless font-lock-mode
          (font-lock-mode 1)
          (font-lock-flush))))))

(defun agent-org-buffer-append-chunk (buffer text session)
  "Append TEXT chunk from agent into BUFFER.
Starts a new Agent heading if not already streaming."
  (when (and text (not (string-empty-p text)))
    (agent-org-buffer-start-agent-turn buffer session)
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (point-max))
          (let ((beg (point)))
            (insert text)
            (agent-org-buffer--protect beg (point))))))))

;;;; Auto-folded per-turn structure (tool headings, thinking drawer)

(defun agent-org-buffer--live-mark (marker)
  "Position of MARKER, or nil when it points into no buffer.
`mark' is the wrong tool here: it returns nil whenever the region is
inactive, which is nearly always the case for a bookkeeping marker."
  (and (markerp marker)
       (marker-buffer marker)
       (marker-position marker)))

(defun agent-org-buffer--redraw-drawer (buffer name lines)
  "Replace the current turn's :NAME: drawer in BUFFER with LINES (list of strings).
Creates the drawer at the end of the turn region (folded) when absent;
when present, swaps the body in place and restores the fold state, so
a drawer the user opened stays open.  The search is bounded by the
turn anchor, not the last heading, because `**' tool headings make the
Agent heading no longer the buffer's last heading.  Fold state is
driven with `org-fold-region' directly:
`org-fold-hide-drawer-toggle' validates the org-element cache, which
is stale while a turn streams with font-lock off, and raises
\"Not at a drawer\"."
  (with-current-buffer buffer
    (let ((inhibit-read-only t)
          (body (mapconcat #'identity lines "\n")))
      (save-excursion
        (let* ((region-start (or (agent-org-buffer--live-mark
                                  agent-org-buffer--turn-anchor)
                                 (point-max)))
               ;; While a turn streams it is the last thing in the
               ;; buffer: `start-agent-turn' appends the `* Agent'
               ;; heading at point-max and every per-turn insert lands
               ;; at or after its anchor, so anchor..point-max is
               ;; exactly this turn — searching forward from the anchor
               ;; can only hit this turn's drawer.
               (drawer-beg
                (save-excursion
                  (goto-char region-start)
                  (when (re-search-forward (format "^:%s:$" name) nil t)
                    (match-beginning 0)))))
          (if (not drawer-beg)
              (progn
                (goto-char (point-max))
                (agent-org-buffer--separator)
                (let ((beg (point)))
                  (insert (format ":%s:\n%s\n:end:\n" name body))
                  (agent-org-buffer--protect beg (point))
                  (goto-char beg)
                  (forward-line 1)
                  (let ((content (point)))
                    (re-search-forward "^:end:$")
                    (org-fold-region content (line-end-position) t 'drawer))))
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
      (setq agent-org-buffer--thought
            (concat agent-org-buffer--thought text))
      (agent-org-buffer--redraw-drawer
       buffer "thinking"
       (split-string agent-org-buffer--thought "\n")))))

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

(defun agent-org-buffer--goto-tool-heading-position ()
  "Point where the next tool heading of the current turn belongs.
After everything already in the turn, but before the :thinking: drawer
so tool headings stay grouped above the thought fold.  The turn runs
from `agent-org-buffer--turn-anchor' to the end of the buffer (while
streaming it is always the last thing there).  The drawer search runs
in `save-excursion': a failed `re-search-forward' leaves point
somewhere in the scanned region, not back at the start.

Take the match's BEGINNING: `re-search-forward' returns its end, which
for `^:thinking:$' is the newline that ends the marker line — the
beginning of the drawer's body.  Inserting a heading there puts it
INSIDE the drawer, and `agent-org-buffer--redraw-drawer' replaces the
whole body on the next thought chunk, deleting it.  A live qoder turn
that way lost three of its four tool calls.  (`line-beginning-position'
cannot rescue this: it only returns a position, it does not move
point.)"
  (goto-char (or (agent-org-buffer--live-mark
                  agent-org-buffer--turn-anchor)
                 (point-max)))
  (let ((drawer (save-excursion
                  (when (re-search-forward "^:thinking:$" nil t)
                    (match-beginning 0)))))
    (if drawer
        (goto-char drawer)
      (goto-char (point-max)))))

(defun agent-org-buffer-insert-tool (buffer content)
  "Record the tool call or update CONTENT in BUFFER as a `**' subheading.
CONTENT is the tool-call alist from the ACP notification.  Each
toolCallId owns exactly one heading `** KEYWORD title' under the current
`* Agent' heading, KEYWORD mapping the ACP status onto the per-file TODO
set (`agent-org-buffer--todo-setup'); later updates rewrite that heading
in place via its stored marker.  The id never appears in the heading
text — it is the agent's bookkeeping, and the marker found under it
already owns the line.  Tool calls are headlines, so they cannot live
in a drawer (Org forbids headlines inside drawers) and instead fold with
TAB like any heading."
  (let ((id (map-elt content 'toolCallId))
        (title (or (map-elt content 'title) (map-elt content 'toolName)))
        (status (map-elt content 'status)))
    (when id
      (with-current-buffer buffer
        (unless agent-org-buffer--streaming-p
          (agent-org-buffer-start-agent-turn buffer nil))
        (let* ((entry (cdr (assoc id agent-org-buffer--tools)))
               (keyword (agent-org-buffer--tool-keyword
                         (or status (and entry (plist-get entry :status)))))
               ;; render-time fallbacks, never stored, so a title-less
               ;; update cannot downgrade the title; the label is
               ;; flattened because a heading is exactly one line
               (name (agent-org-buffer--label
                      (or title (and entry (plist-get entry :title)) "tool")))
               ;; no trailing newline: the in-place rewrite keeps the
               ;; line's own, and the fresh insert adds one explicitly
               (htext (format "** %s %s" keyword name)))
          (or entry
              (setq entry (list :marker nil :title nil :status nil)
                    agent-org-buffer--tools
                    (append agent-org-buffer--tools (list (cons id entry)))))
          (when title (plist-put entry :title title))
          (when status (plist-put entry :status status))
          (let ((inhibit-read-only t)
                (old (plist-get entry :marker)))
            (save-excursion
              (if (and (markerp old) (marker-buffer old) (marker-position old))
                  (progn
                    ;; rewrite the existing heading line in place
                    (goto-char old)
                    (beginning-of-line)
                    (delete-region (point) (line-end-position))
                    (insert htext)
                    (agent-org-buffer--protect
                     (line-beginning-position) (line-end-position)))
                (progn
                  ;; fresh heading, then remember where it lives
                  (agent-org-buffer--goto-tool-heading-position)
                  (agent-org-buffer--separator)
                  (let ((beg (point))
                        (marker (make-marker)))
                    (insert (concat htext "\n"))
                    (agent-org-buffer--protect beg (point))
                    (set-marker marker beg)
                    (plist-put entry :marker marker)))))))))))

(provide 'agent-org-buffer)
;;; agent-org-buffer.el ends here
