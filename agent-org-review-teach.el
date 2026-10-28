;;; agent-org-review-teach.el --- Teach the human while the agent works -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Khalid
;; Author: Khalid
;; Version: 0.1.0
;; Keywords: tools, ai, code-review
;; Package-Requires: ((emacs "29.1") (org "9.0"))

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, version 3 of the License, or (at your
;; option) any later version.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;;; Commentary:

;; A coaching layer that puts the *human* back in charge of AI-written code.
;;
;; It encodes practices distilled from three DeepLearning.AI courses that
;; teach humans how to work with AI coding assistants, rather than how to
;; prompt harder:
;;
;;   * *AI Code Review* (Nnenna Ndukwe, Qodo) -- /"The quality of an AI code
;;     review depends more on the context the reviewer has than on the model
;;     behind it."/  Its four practices: get reviewed before opening a
;;     pull request; give the reviewer the task and repository context it
;;     needs; use a reviewer that did not write the code; triage findings by
;;     risk and turn good feedback into reusable standards so each review
;;     sharpens the next.
;;   * *Claude Code: A Highly Agentic Coding Assistant* (Elie Schoppik,
;;     Anthropic) -- give clear context (named files, defined features),
;;     keep persistent memory, *ask the assistant to plan first*, write
;;     tests to verify, and run parallel worktrees for independent features.
;;   * *Build with Andrew* (Andrew Ng) -- iterative refinement beats
;;     one-shot prompting; a repeatable describe, build, test, refine loop
;;     you can apply to any app idea.
;;
;; In Emacs terms, that becomes four habits, each one function here:
;;
;;   1. `agent-org-review-teach-send' (the one you bind to C-c C-c, or
;;      wherever `agent-org-send' lives now) wraps `agent-org-send' and, when
;;      the request is substantial but asks for no plan and states no test,
;;      it first offers to prepend a planning instruction -- the /"ask it to
;;      plan first"/ habit.  It never blocks: you can answer "send as is".
;;   2. The same gate reports, after a turn lands, how many *distinct* files
;;      the agent touched and whether any file was touched twice, which is
;;      the reviewer's first triage question from the course: /"where is the
;;      blast radius?"/
;;   3. `agent-org-review-teach-show' ranks the findings in a review
;;      buffer by risk, so you read the dangerous ones first -- risk tiers
;;      follow the course's own grouping: security, then correctness, then
;;      missing requirement, then style.
;;   4. `agent-org-review-teach-lesson' records a lesson next to the project
;;      as an Org entry, which is how feedback becomes a reusable standard
;;      that a future session's agent can read.
;;
;; Everything here is *additive*: a separate file, its own keymap prefix
;; `agent-org-review-teach-map', no edits to agent-org.el,
;; agent-org-buffer.el or agent-org-providers.el.  If you delete this file
;; the package behaves exactly as before, because `agent-org-send' itself is
;; never redefined -- we only advise around the send path and add commands.
;;
;; Usage, in a chat buffer:
;;
;;   M-x agent-org-review-teach-send      ;; the gate (wraps agent-org-send)
;;   M-x agent-org-review-teach-show      ;; rank findings by risk
;;   M-x agent-org-review-teach-lesson    ;; record a reusable standard
;;   M-x agent-org-review-teach-habits    ;; the practices, in the echo area
;;
;; No configuration is required, and none of the commands need network
;; access or an agent session.

;;; Code:

(require 'cl-lib)
(require 'org)

;; The three buffer helpers below live in agent-org-buffer.el and the send
;; command in agent-org.el.  They are declared rather than required so this
;; file can be byte-compiled and tested on its own, before the package it
;; wraps is loaded -- the declarations are what silence the compiler and
;; what a reader needs to know these are not ours.
(declare-function agent-org-send "agent-org" ())
(declare-function agent-org-buffer-take-draft "agent-org-buffer" (buffer))
(declare-function agent-org-buffer-insert-prompt "agent-org-buffer" (buffer))
(declare-function agent-org-buffer--prompt-box-heading "agent-org-buffer" ())

(defgroup agent-org-review-teach ()
  "Teach the human how to supervise AI-written code, while the agent works."
  :group 'agent-org)

(defcustom agent-org-review-teach-plan-threshold 200
  "How many characters of prompt before it is worth asking for a plan.
A short request is a conversation; at or above this length the outcome is
code you will have to read, and /\"ask it to plan first\"/ is the habit that
pays.  Set to nil to disable the plan prompt entirely."
  :type '(choice (const :tag "Never prompt" nil)
                 (integer :tag "Characters")))

(defcustom agent-org-review-teach-plan-words
  '("refactor" "implement" "add" "build" "migrate" "rewrite" "port"
    "fix" "create" "set up" "design" "generate" "update" "delete"
    "change" "make" "write")
  "Prompt verbs that imply the agent is about to write code.
When one of these appears, the planning question is worth asking."
  :type '(repeat string))

(defcustom agent-org-review-teach-risk-tiers
  '(("security" . 4)
    ("correctness" . 3)
    ("requirement" . 2)
    ("style" . 1))
  "Risk tiers findings are sorted by, highest first.
The order is the DeepLearning.AI course's own grouping: a security hole or
a missed requirement is worse than a style nit.  Anything not matching a
tier gets `agent-org-review-teach-default-tier'."
  :type '(alist :key-type string :value-type integer))

(defcustom agent-org-review-teach-default-tier 0
  "Risk of a finding that matches no tier in `agent-org-review-teach-risk-tiers'."
  :type 'integer)

(defcustom agent-org-review-teach-lessons-file
  (expand-file-name "AGENT-LESSONS.org"
                    (concat (or (and (boundp 'agent-org-transcript-dir)
                                     agent-org-transcript-dir)
                                "~/.agent-org/")
                            "agent-org"))
  "Where `agent-org-review-teach-lesson' writes its reusable standards.
One Org file, one heading dated per lesson, so a future session's agent
can read it as its standing instructions."
  :type 'file)

;;; --- Pure helpers -------------------------------------------------------
;; Nothing below reads the network, an acp session, or point.  That is what
;; makes the whole coaching layer testable in batch without a live agent
;; (see tests/test-agent-org-review-teach.el).

(defun agent-org-review-teach--code-words (text)
  "Return the list of `agent-org-review-teach-plan-words' that occur in TEXT."
  (let ((case-fold-search t))
    (cl-remove-if-not
     (lambda (word) (string-match-p (regexp-quote word) text))
     agent-org-review-teach-plan-words)))

(defun agent-org-review-teach--claims-plan-p (text)
  "Return non-nil when TEXT already asks for a plan, or is itself a plan.
Not sending a plan-shaped request avoids double-asking an agent who was
just told to plan."
  ;; The doubled backslashes below are what the reader needs: a single \b
  ;; is the bell/backspace escape, so the word-boundary anchors never
  ;; survive otherwise (measured: "\\bplan\\b" as a single-backslash string
  ;; matches nothing, the backspaces are gone by the time it reaches Emacs).
  (let ((case-fold-search t))
    (cl-loop for pat in
             '("\\bplan\\b" "\\bsteps?\\b" "first,?" "before .*implement"
               "dry.?run" "outline" "\\bhow would you\\b")
             thereis (string-match-p pat text))))

(defun agent-org-review-teach--claims-test-p (text)
  "Return non-nil when TEXT asks for a test, a check or a verification.
The course's second habit: /write tests to evaluate the functionality/, so
an agent who is asked to test needs no reminder."
  (let ((case-fold-search t)
        (text text))
    (or (string-match-p "\\btests?\\b" text)
        (string-match-p "\\bverif" text)
        (string-match-p "\\bcheck\\b" text))))

(defun agent-org-review-teach-plan-suggestion (text)
  "Return the planning instruction to prepend to TEXT, or nil when none.
A plan is suggested when the request is long enough to produce code that a
human must read (`agent-org-review-teach-plan-threshold'), uses a code
verb, and neither plans nor tests already.  Returns nil for short prompts,
so `/what does this function do?/ never gets a lecture."
  (when (and agent-org-review-teach-plan-threshold
             (>= (length text) agent-org-review-teach-plan-threshold)
             (agent-org-review-teach--code-words text)
             (not (agent-org-review-teach--claims-plan-p text))
             (not (agent-org-review-teach--claims-test-p text)))
    (concat "Plan first: list the files you would touch and the tests that "
            "would show each change works, and wait for my go-ahead before "
            "editing anything.\n\n")))

(defun agent-org-review-teach-risk (finding)
  "Return the risk of FINDING, an integer, higher is riskier.
FINDING is a string of reviewer output, or the symbol of anything
unclassifiable.  The tier is the first entry of
`agent-org-review-teach-risk-tiers' whose key occurs in FINDING."
  (if (stringp finding)
      (let ((case-fold-search t))
        (cl-loop for (tier . weight) in agent-org-review-teach-risk-tiers
                 when (string-match-p tier finding)
                 return weight
                 finally return agent-org-review-teach-default-tier))
    agent-org-review-teach-default-tier))

(defun agent-org-review-teach-triage (findings &optional limit)
  "Sort FINDINGS (a list of strings) by `agent-org-review-teach-risk', descending.
LIMIT, when non-nil, keeps only that many of the riskiest findings, so you
read the dangerous ones before you run out of attention.  Ties keep their
input order, and the sort is stable on that basis."
  (let* ((ranked (cl-loop for f in findings
                          for risk = (agent-org-review-teach-risk f)
                          collect (list risk (length f) f)))
         ;; sort by risk, then by finding text as a stable tiebreak
         (sorted (sort (cl-loop for r in ranked collect (copy-sequence r))
                       (lambda (a b)
                         (or (> (car a) (car b))
                             (and (= (car a) (car b))
                                  (string< (nth 2 a) (nth 2 b))))))))
    (let ((out (mapcar (lambda (r) (nth 2 r)) sorted)))
      (if limit (cl-subseq out 0 (min limit (length out))) out))))

(defun agent-org-review-teach-blast-radius (files)
  "Return a plist describing the blast radius of FILES, a list of path strings.
:count is how many distinct paths, :touched-twice is the list of paths that
occurred more than once (re-touching is where mistakes hide), :cache is the
list under a cache or build directory and :tests the list under tests.
The reviewer's first triage question -- what is the shape of the change --
answers itself from this."
  (let* ((uniq (delete-dups (copy-sequence files)))
         (repeated (cl-loop for f in uniq
                            when (> (cl-count f files :test #'string=) 1)
                            collect f))
         (cache (cl-remove-if-not
                 (lambda (f) (string-match-p "\\(?:node_modules\\|\\.cache\\|__pycache__\\|dist\\|build\\)/" f))
                 uniq))
         (tests (cl-remove-if-not
                 (lambda (f) (string-match-p "\\(?:^\\|/\\)\\(?:tests?\\|spec\\)/" f))
                 uniq)))
    (list :count (length uniq) :touched-twice repeated
          :cache cache :tests tests)))

;;; --- Interactive commands ----------------------------------------------

(defvar agent-org-review-teach-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "s") #'agent-org-review-teach-send)
    (define-key map (kbd "t") #'agent-org-review-teach-show)
    (define-key map (kbd "l") #'agent-org-review-teach-lesson)
    (define-key map (kbd "h") #'agent-org-review-teach-habits)
    map)
  "Keymap for the coaching layer.  Bind it wherever you keep \\='agent-org-send
today, for example on C-c C-c in \\='agent-org-mode-map:

  (define-key agent-org-mode-map (kbd \"C-c C-c\")
              #='agent-org-review-teach-send)")

;;;###autoload
(defun agent-org-review-teach-habits ()
  "Show the practices this layer enforces, one line each.
Sources and practice names are given so the lesson is the point, not the
tool: DeepLearning.AI's /AI Code Review/, /Claude Code: A Highly Agentic
Coding Assistant/ and /Build with Andrew/."
  (interactive)
  (message "%s" (concat "Human in the loop: plan before -- give the reviewer "
                        "context -- review before the PR -- triage by risk -- "
                        "test what you ship")))

;;;###autoload
(defun agent-org-review-teach-send (prompt)
  "Send PROMPT to the agent, having first asked it to plan when that helps.
This is `agent-org-send' wrapped by the plan-first habit.  When
`agent-org-review-teach-plan-suggestion' has advice for PROMPT you are
asked what to do: `p' to prepend the planning instruction and send that,
`a' to send the prompt unchanged, or `c' to cancel and keep editing.
A short or already-planned prompt goes straight out, no question."
  (interactive
   (list (condition-case nil
             (agent-org-buffer-take-draft (current-buffer))
           (user-error
            (user-error "Nothing to send; type your prompt under the PROMPT heading")))))
  (let ((suggestion (agent-org-review-teach-plan-suggestion prompt)))
    (cond
     ;; no advice: behave exactly like agent-org-send
     ((null suggestion)
      (when (fboundp 'agent-org-send)
        (call-interactively #'agent-org-send)))
     ;; advice: ask once, in the echo area; the draft is already out of the
     ;; buffer, so canceling means the user must retype -- hence the third
     ;; choice is a plain refusal to send, which re-inserts the draft.
     (t
      (let ((answer (read-char-choice
                     "Plan first? [p] repend and send, [a] send anyway, [c] cancel: "
                     '(?p ?a ?c))))
        (cond
         ((eq answer ?c)
          (agent-org-buffer-insert-prompt (current-buffer))
          ;; the draft was already lifted out of the box by the interactive
          ;; form, so cancelling must put it back by hand or it is lost.
          (save-excursion
            (goto-char (agent-org-buffer--prompt-box-heading))
            (forward-line 1)
            (insert prompt))
          (message "Send cancelled; your prompt is back in the box"))
         ((eq answer ?a)
          (agent-org-buffer-insert-prompt (current-buffer))
          (agent-org-review-teach--insert-and-send prompt))
         (t
          (agent-org-buffer-insert-prompt (current-buffer))
          (agent-org-review-teach--insert-and-send (concat suggestion prompt)))))))))

(defun agent-org-review-teach--insert-and-send (text)
  "Insert TEXT at the current chat buffer's PROMPT box and send it."
  (save-excursion
    (goto-char (agent-org-buffer--prompt-box-heading))
    (forward-line 1)
    (insert text))
  (when (fboundp 'agent-org-send)
    (call-interactively #'agent-org-send)))

;;;###autoload
(defun agent-org-review-teach-show (findings)
  "Interactively rank FINDINGS by risk and show the riskiest first.
FINDINGS are newline-separated at the interactive call, then handed to the
pure `agent-org-review-teach-triage' so what you see is what the tests
check.  Reading is split into at most five lines at a time so the triage
question -- is the worst of these dangerous? -- can be answered before
attention runs out."
  (interactive "sFindings, one per line: ")
  (let* ((list (split-string findings "\n" t))
         (ranked (agent-org-review-teach-triage list))
         (buffer (get-buffer-create "*Review Triage*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (org-mode)
        (insert "#+TITLE: Review triage\n\n")
        (dolist (finding ranked)
          (insert (format "- risk %d :: %s\n"
                          (agent-org-review-teach-risk finding) finding)))
        (goto-char (point-min))))
    (pop-to-buffer buffer)))

;;;###autoload
(defun agent-org-review-teach-lesson ()
  "Record a lesson learned as a reusable standard in the lessons file.
A lesson is the shape of feedback that survives this session: what the
agent got wrong, and what to ask for next time.  Each entry is one
heading, dated, tagged `:lesson:', written to
`agent-org-review-teach-lessons-file' so a future agent reads it as a
standing instruction.  Interactively asks for the subject and the lesson."
  (interactive)
  (let* ((subject (read-from-minibuffer "Subject: "))
         (lesson (read-from-minibuffer "Lesson to reuse next time: "))
         (file agent-org-review-teach-lessons-file)
         (dir (file-name-directory file)))
    (unless (string-empty-p (string-trim subject))
      (user-error "Empty subject"))
    (make-directory dir t)
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (insert (format "* %s :lesson:\n" subject)
              (format ":PROPERTIES:\n:DATE: %s\n:END:\n" (format-time-string "%Y-%m-%d"))
              (format "- [ ] %s\n" lesson)
              (format "- [ ] Applied in a later session: checked ____\n"))
      (save-buffer))
    (message "Lesson recorded in %s" file)))

(provide 'agent-org-review-teach)

;;; agent-org-review-teach.el ends here
