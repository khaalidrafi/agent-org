;;; agent-org-batch.el --- Headless ACP send through agent-org -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Khalid

;; Author: Khalid
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (acp "0.14.3") (org "9.0"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Owner order 2026-10-26 #hq (R-2-77 endgame): "agent-team.el should
;; DEPEND on agent-org for all ACP agent tasks" and the automation runs
;; "a hook in agent-org at the moment the prompt is sent".  Team CI
;; therefore drives its agent bodies THROUGH agent-org: one
;; `emacs --batch' process spawns the provider's ACP agent, runs the
;; initialize + session/new handshake, sends ONE prompt, collects the
;; raw response chunks and writes them to a file.  A CI send then fires
;; the SAME `agent-org-prompt-send-hook' an interactive Emacs send
;; fires (agent-org.el fires it on both transmit paths), so the CI
;; clock-in lands at the exact prompt-send moment — TIME LAW's
;; "beginning = send time" holds everywhere except web/cloud lanes.
;;
;; All configuration is ENVIRONMENT, so CI never quotes elisp:
;;
;;   AGENT_ORG_PROVIDER    provider id from `agent-org-providers'
;;                         (qoder, goose, opencode, codebuddy, ...)
;;   AGENT_ORG_PROMPT      path of the prompt file (sent trimmed)
;;   AGENT_ORG_OUT         output path for the RAW response text
;;   AGENT_ORG_TIMEOUT     wall seconds for the whole run (default 900)
;;   AGENT_ORG_MODEL       optional model pin overriding the spec's
;;   AGENT_ORG_CLOCK_CMD   optional shell command the send hook runs
;;                         SYNCHRONOUSLY at the exact send moment — the
;;                         CI clock-in twin lives behind this
;;   AGENT_ORG_LOAD_PATH   optional colon-separated dirs prepended to
;;                         `load-path' before acp/agent-org load
;;   AGENT_ORG_PROVIDER_COMMAND  optional raw command line overriding
;;                         the provider spec entirely (tests, probes,
;;                         lanes with non-default argv); the child gets
;;                         the FULL process environment
;;
;; Exit codes: 0 the turn finished and AGENT_ORG_OUT was written; 42
;; for ANY failure (emacs too old, acp/agent-org unloadable, unknown
;; provider or command, no session id in time, send error, turn
;; timeout, empty response).  The caller treats every non-zero exit as
;; "fall back to the direct CLI lane" — the batch path can only ADD a
;; working send, never remove the proven one.
;;
;; Run it like this (paths from a harness image that baked agent-org):
;;
;;   emacs --batch -l /opt/agent-org/agent-org-batch.el \
;;     --eval '(agent-org-batch-send)'
;;
;; The real `acp' package must be on `load-path' (AGENT_ORG_LOAD_PATH
;; or the image bake).  The tests' acp-mock.el must NEVER be reachable
;; from a live send: it can answer constructors, not agents.

;;; Code:

(require 'cl-lib)
(require 'map)

(defconst agent-org-batch--poll-interval 0.25
  "Seconds between state polls while waiting on the agent.")

(defconst agent-org-batch--min-emacs "29.1"
  "Oldest emacs agent-org loads on (its own Package-Requires).")

(define-error 'agent-org-batch-precondition
  "agent-org-batch precondition failed"
  'user-error)

;;;; Declared externals (the file must byte-compile standalone, before
;;;; acp/agent-org are on the load-path — same pattern providers.el uses)

(defvar agent-org-transcribe)
(defvar agent-org-convert-markdown)
(defvar agent-org-prompt-send-hook)
(defvar agent-org-response-error-hook)
(defvar agent-org-buffer--status)

(declare-function acp-shutdown "acp.el" (&key client))
(declare-function agent-org--provider-spec "agent-org.el" (provider))
(declare-function agent-org--open-session "agent-org.el" (spec))
(declare-function agent-org--initialize "agent-org.el" (session &optional next))
(declare-function agent-org--begin-start "agent-org.el" (session resp strategy))
(declare-function agent-org-send-prompt-with-session "agent-org.el" (prompt session))
(declare-function agent-org-loader-begin "agent-org-loader.el" (buffer))
(declare-function agent-org-buffer-append-chunk "agent-org-buffer.el" (buffer text session))

;;;; The prompt-send hook consumer (the CI clock-in)

(defun agent-org-batch--clock (&rest _args)
  "Run AGENT_ORG_CLOCK_CMD synchronously — the exact send moment.
Hook signature: `agent-org-prompt-send-hook' fires with PROMPT and
SESSION (`run-hook-with-args'), so this accepts and ignores both.
Errors are already demoted by `agent-org--run-prompt-send-hook''s
wrapper, so a broken clock can never block a send (the observer
contract)."
  (when-let* ((cmd (getenv "AGENT_ORG_CLOCK_CMD")))
    (let ((rc (shell-command cmd)))
      (message "agent-org-batch: clock rc=%s" rc))))

;;;; The raw-response collector

(defvar agent-org-batch--response nil
  "Raw agent text accumulated across `agent-org-buffer-append-chunk'.")

(defvar agent-org-batch--failed nil
  "Set when `agent-org-response-error-hook' reports a failed turn.")

(defun agent-org-batch--collect (orig buffer text session)
  "Around-advice for `agent-org-buffer-append-chunk'.
Accumulates the RAW chunk text before the buffer renders it — CI
output is the agent's own bytes, not the chat buffer's rendering."
  (when (and text (not (string-empty-p text)))
    (setq agent-org-batch--response
          (concat agent-org-batch--response text)))
  (funcall orig buffer text session))

(defun agent-org-batch--fail (_buffer _session)
  "Record a failed turn for `agent-org-response-error-hook'."
  (setq agent-org-batch--failed t))

;;;; Waiting

(defun agent-org-batch--wait (ready deadline what)
  "Poll READY until non-nil or DEADLINE passes; signal on timeout.
WHAT names what we are waiting for, for the exit message."
  (while (not (funcall ready))
    (when (> (float-time) deadline)
      (signal 'agent-org-batch-precondition
              (list (format "timeout waiting: %s" what))))
    (accept-process-output nil agent-org-batch--poll-interval)
    (sit-for agent-org-batch--poll-interval)))

;;;; Preconditions and loading

(defun agent-org-batch--env (name)
  "Return env var NAME or signal `agent-org-batch-precondition'."
  (or (getenv name)
      (signal 'agent-org-batch-precondition
              (list (format "missing env %s" name)))))

(defun agent-org-batch--load-deps ()
  "Guard the emacs version, wire AGENT_ORG_LOAD_PATH, load the stack.
The REAL acp must load — the test mock never ships in a harness image,
and a mock answering constructors without an agent would hang the send
into its timeout, which still exits 42 and falls back."
  (when (version< emacs-version agent-org-batch--min-emacs)
    (signal 'agent-org-batch-precondition
            (list (format "emacs %s too old (agent-org needs %s)"
                          emacs-version agent-org-batch--min-emacs))))
  (when-let* ((lp (getenv "AGENT_ORG_LOAD_PATH")))
    (dolist (dir (split-string lp ":" t))
      (add-to-list 'load-path (expand-file-name dir) t)))
  (let ((missing
         (cl-loop for feat in '(acp agent-org-buffer agent-org-providers
                              agent-org-loader agent-org)
                  unless (condition-case nil
                             (progn (require feat) t)
                           (error nil))
                  collect feat)))
    (when missing
      (signal 'agent-org-batch-precondition
              (list (format "cannot load: %s"
                            (mapconcat #'symbol-name missing " ")))))))

(defun agent-org-batch--spec (provider)
  "Return the provider SPEC for symbol PROVIDER.
AGENT_ORG_PROVIDER_COMMAND overrides the canned spec entirely: raw
argv for tests, probes and non-default lanes; the child inherits the
FULL process environment (nil :environment = acp passes nothing, and
`make-process' inherits)."
  (if-let* ((cmd (getenv "AGENT_ORG_PROVIDER_COMMAND")))
      (list :id provider
            :name (symbol-name provider)
            :command (split-string cmd)
            :environment (lambda () nil)
            :model (getenv "AGENT_ORG_MODEL"))
    (agent-org--provider-spec provider)))

;;;; The entry point

(defun agent-org-batch-send ()
  "One headless send; see this file's Commentary for the env contract.
Exit code 0 means AGENT_ORG_OUT holds the agent's raw response text;
every other exit is 42 = fall back to the direct CLI lane."
  (condition-case err
      (let ((agent-org-batch--response nil)
            (agent-org-batch--failed nil))
        ;; the batch run is its own transcript owner: no stray sid-*.org
        ;; in the workspace the agent is about to commit
        (setq agent-org-transcribe nil
              ;; CI output is grepped (verdict tokens) — the agent's own
              ;; bytes, not the chat buffer's markdown rendering
              agent-org-convert-markdown nil)
        (agent-org-batch--load-deps)
        (advice-add 'agent-org-buffer-append-chunk
                    :around #'agent-org-batch--collect)
        (add-hook 'agent-org-response-error-hook #'agent-org-batch--fail)
        (when (getenv "AGENT_ORG_CLOCK_CMD")
          (add-hook 'agent-org-prompt-send-hook #'agent-org-batch--clock))
        (let* ((provider
                (intern (agent-org-batch--env "AGENT_ORG_PROVIDER")))
               (prompt-file (agent-org-batch--env "AGENT_ORG_PROMPT"))
               (out-file (agent-org-batch--env "AGENT_ORG_OUT"))
               (deadline
                (+ (float-time)
                   (string-to-number
                    (or (getenv "AGENT_ORG_TIMEOUT") "900"))))
               (prompt
                (string-trim
                 (with-temp-buffer
                   (insert-file-contents-literally prompt-file)
                   (buffer-string))))
               (spec (agent-org-batch--spec provider)))
          ;; the model pin override MUST land BEFORE open-session copies
          ;; the spec's :model into the session's :want-model — the copy
          ;; happens inside `agent-org--open-session'
          (when-let* ((model (getenv "AGENT_ORG_MODEL")))
            (plist-put spec :model model))
          (let* ((session (agent-org--open-session spec))
                 (buffer (plist-get session :buffer)))
          (agent-org-loader-begin buffer)
          (agent-org--initialize session
            (lambda (resp)
              (agent-org--begin-start session resp 'new)))
          (agent-org-batch--wait
           (lambda ()
             (or (plist-get session :session-id)
                 (agent-org-batch--error-state-p buffer)))
           deadline "agent session ready")
          (unless (plist-get session :session-id)
            (signal 'agent-org-batch-precondition
                    (list "agent errored before session ready")))
          (agent-org-send-prompt-with-session prompt session)
          (agent-org-batch--wait
           (lambda ()
             (or (and (null (plist-get session :streaming))
                      (null (plist-get session :turn)))
                 agent-org-batch--failed
                 (agent-org-batch--error-state-p buffer)))
           deadline "agent turn end")
          (unless (and agent-org-batch--response
                       (not (string-empty-p agent-org-batch--response)))
            (signal 'agent-org-batch-precondition
                    (list "empty response")))
          (let ((write-region-inhibit-fsync t))
            (write-region agent-org-batch--response nil out-file
                          nil :quiet))
          (ignore-errors
            (acp-shutdown :client (plist-get session :client)))
          (message "agent-org-batch: response %d chars -> %s"
                   (length agent-org-batch--response) out-file)
          (kill-emacs 0))))
    (agent-org-batch-precondition
     (message "agent-org-batch: %s" (error-message-string err))
     (kill-emacs 42))
    (error
     (message "agent-org-batch: unexpected failure: %s"
              (error-message-string err))
     (kill-emacs 42))))

(defun agent-org-batch--error-state-p (buffer)
  "Non-nil when BUFFER's chat status reached the error state."
  (with-current-buffer buffer
    (eq (plist-get agent-org-buffer--status :state) 'error)))

(provide 'agent-org-batch)
;;; agent-org-batch.el ends here
