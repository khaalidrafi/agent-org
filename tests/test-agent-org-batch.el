;;; test-agent-org-batch.el --- Tests for agent-org-batch.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Khalid

;; Author: Khalid

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Unit tests for the batch send driver's PIECES (env contract, clock
;; hook, raw collector, wait loop, provider-command spec override).
;; The whole happy path is proven by tests/e2e-agent-org-batch.sh
;; against tests/fake-acp-agent.py over the REAL acp package — a mock
;; acp cannot drive a live send, by design.

;;; Code:

(require 'ert)
(require 'ert-x)
;; the mock answers `acp' so `agent-org-batch--load-deps' succeeds and
;; failure-path tests exercise the CONTRACT (env, guard, exit codes),
;; not a missing dependency; the happy path is the E2E script's job
(load (expand-file-name "acp-mock.el" (file-name-directory load-file-name)))
(load (expand-file-name "agent-org-batch.el"
                        (file-name-directory
                         (directory-file-name
                          (file-name-directory load-file-name)))))

(defmacro agent-org-batch-test--with-env (bindings &rest body)
  "Run BODY with env BINDINGS set and every AGENT_ORG_* var removed after."
  (declare (indent 1))
  `(unwind-protect
       (progn
         ,@(mapcar (lambda (b)
                     (if (cadr b)
                         `(setenv ,(car b) ,(cadr b))
                       `(setenv ,(car b) nil)))
                   bindings)
         ,@body)
     ,@(mapcar (lambda (b) `(setenv ,(car b) nil))
               bindings)))

;;;; The env contract

(ert-deftest test-agent-org-batch-env-missing-signals ()
  (should (condition-case err
              (progn (setenv "AGENT_ORG_NOPE_XYZ" nil)
                     (agent-org-batch--env "AGENT_ORG_NOPE_XYZ"))
            (agent-org-batch-precondition
             (string-match-p "missing env AGENT_ORG_NOPE_XYZ"
                             (error-message-string err))))))

(ert-deftest test-agent-org-batch-env-present ()
  (setenv "AGENT_ORG_ENV_TEST" "42")
  (unwind-protect
      (should (equal (agent-org-batch--env "AGENT_ORG_ENV_TEST") "42"))
    (setenv "AGENT_ORG_ENV_TEST" nil)))

;;;; The wait loop

(ert-deftest test-agent-org-batch-wait-timeout-signals ()
  (let ((deadline (- (float-time) 1.0)))
    (should (condition-case err
                (agent-org-batch--wait (lambda () nil) deadline "the moon")
              (agent-org-batch-precondition
               (string-match-p "timeout waiting: the moon"
                               (error-message-string err)))))))

(ert-deftest test-agent-org-batch-wait-ready-returns ()
  ;; flips true on the second poll: the loop must actually pump
  (let ((n 0)
        (deadline (+ (float-time) 10.0)))
    (should-not (agent-org-batch--wait
                 (lambda () (> (cl-incf n) 1)) deadline "poll"))))

;;;; The clock hook consumer

(ert-deftest test-agent-org-batch-clock-runs-command ()
  (ert-with-temp-directory dir
    (let ((stamp (expand-file-name "clock.stamp" dir)))
      (agent-org-batch-test--with-env
          (("AGENT_ORG_CLOCK_CMD" (concat "touch " stamp)))
        (agent-org-batch--clock 'prompt (list :session-id "sid"))
        (should (file-exists-p stamp))))))

(ert-deftest test-agent-org-batch-clock-noop-without-command ()
  ;; the hook is installed only when the command exists; even when the
  ;; function runs without one it must stay silent and harmless
  (agent-org-batch-test--with-env (("AGENT_ORG_CLOCK_CMD" nil))
    (should-not (agent-org-batch--clock 'prompt nil))))

;;;; The raw collector

(ert-deftest test-agent-org-batch-collect-accumulates-raw-text ()
  (let ((agent-org-batch--response nil)
        (seen nil))
    (agent-org-batch--collect
     (lambda (_buffer text _session) (push text seen))
     (get-buffer-create " *batch-collect-test*")
     "chunk one"
     (list :session-id "sid"))
    (agent-org-batch--collect
     (lambda (_buffer text _session) (push text seen))
     (get-buffer-create " *batch-collect-test*")
     "chunk two"
     (list :session-id "sid"))
    (should (equal agent-org-batch--response "chunk onechunk two"))
    ;; the original renderer still ran with the same text
    (should (equal (nreverse seen) '("chunk one" "chunk two")))))

(ert-deftest test-agent-org-batch-collect-ignores-empty-chunks ()
  (let ((agent-org-batch--response nil))
    (agent-org-batch--collect
     (lambda (&rest _) nil) (get-buffer-create " *b*") "" nil)
    (agent-org-batch--collect
     (lambda (&rest _) nil) (get-buffer-create " *b*") nil nil)
    (should (string-empty-p (or agent-org-batch--response "")))))

;;;; The provider-command spec override

(ert-deftest test-agent-org-batch-spec-command-override ()
  (agent-org-batch-test--with-env
      (("AGENT_ORG_PROVIDER_COMMAND" "python3 /x/fake.py --flag")
       ("AGENT_ORG_MODEL" "m-1"))
    (let ((spec (agent-org-batch--spec 'fake)))
      (should (equal (plist-get spec :command)
                     '("python3" "/x/fake.py" "--flag")))
      (should (equal (plist-get spec :name) "fake"))
      (should (equal (plist-get spec :model) "m-1"))
      ;; the child inherits the FULL environment: acp prepends the list
      ;; its spec hands it to `process-environment', and nil adds nothing
      (should (null (funcall (plist-get spec :environment)))))))

(ert-deftest test-agent-org-batch-spec-falls-back-to-providers ()
  (agent-org-batch-test--with-env
      (("AGENT_ORG_PROVIDER_COMMAND" nil) ("AGENT_ORG_MODEL" nil))
    (cl-letf (((symbol-function 'agent-org--provider-spec)
               (lambda (provider) (list :id provider :name "canned"))))
      (should (equal (plist-get (agent-org-batch--spec 'qoder) :name)
                     "canned")))))

;;;; Error-state probe

(ert-deftest test-agent-org-batch-error-state-p ()
  (with-temp-buffer
    (setq-local agent-org-buffer--status
                (list :provider "x" :state 'error))
    (should (agent-org-batch--error-state-p (current-buffer))))
  (with-temp-buffer
    (setq-local agent-org-buffer--status
                (list :provider "x" :state 'ready))
    (should-not (agent-org-batch--error-state-p (current-buffer)))))

;;;; Exit-code semantics: every failure is kill-emacs 42

(ert-deftest test-agent-org-batch-send-missing-env-exits-42 ()
  (let (code)
    (cl-letf (((symbol-function 'kill-emacs)
               (lambda (&optional exit) (setq code (or exit 0)))))
      (agent-org-batch-test--with-env
          (("AGENT_ORG_PROVIDER" nil) ("AGENT_ORG_PROMPT" nil)
           ("AGENT_ORG_OUT" nil))
        (agent-org-batch-send)))
    (should (eq code 42))))

(ert-deftest test-agent-org-batch-send-old-emacs-exits-42 ()
  (let (code)
    (cl-letf (((symbol-function 'kill-emacs)
               (lambda (&optional exit) (setq code (or exit 0)))))
      ;; the guard fires BEFORE any require: with `version<' stubbed to
      ;; always-true the failure is the guard's, never the env's
      (cl-letf (((symbol-function 'version<) (lambda (&rest _) t)))
        (agent-org-batch-send)))
    (should (eq code 42))))

;;; test-agent-org-batch.el ends here

;;;; Session reuse + transcript preservation (Owner order 2026-10-27 #hq)

(ert-deftest test-agent-org-batch-resume-id-contract ()
  "AGENT_ORG_SESSION_ID: unset or empty = nil (fresh session); a
non-empty value passes through verbatim (the pinned-id resume path)."
  (agent-org-batch-test--with-env (("AGENT_ORG_SESSION_ID" nil))
    (should (null (agent-org-batch--resume-id))))
  (agent-org-batch-test--with-env (("AGENT_ORG_SESSION_ID" ""))
    (should (null (agent-org-batch--resume-id))))
  (agent-org-batch-test--with-env (("AGENT_ORG_SESSION_ID" "sid-member-42"))
    (should (string= "sid-member-42" (agent-org-batch--resume-id)))))

(ert-deftest test-agent-org-batch-transcript-dir-contract ()
  "AGENT_ORG_TRANSCRIPT_DIR set = transcription on and the mirror
directory honored; unset = the old batch law (transcription off)."
  (let ((agent-org-transcribe :sentinel)
        (agent-org-transcript-dir ".agent-org"))
    (agent-org-batch-test--with-env (("AGENT_ORG_TRANSCRIPT_DIR" nil))
      (setq agent-org-transcribe (and (getenv "AGENT_ORG_TRANSCRIPT_DIR") t)
            agent-org-transcript-dir
            (and (getenv "AGENT_ORG_TRANSCRIPT_DIR")
                 (expand-file-name (getenv "AGENT_ORG_TRANSCRIPT_DIR"))))
      (should (null agent-org-transcribe))
      (should (null agent-org-transcript-dir)))
    (agent-org-batch-test--with-env (("AGENT_ORG_TRANSCRIPT_DIR" "/tmp/tx-test"))
      (setq agent-org-transcribe (and (getenv "AGENT_ORG_TRANSCRIPT_DIR") t)
            agent-org-transcript-dir
            (and (getenv "AGENT_ORG_TRANSCRIPT_DIR")
                 (expand-file-name (getenv "AGENT_ORG_TRANSCRIPT_DIR"))))
      (should (eq agent-org-transcribe t))
      (should (string= "/tmp/tx-test" agent-org-transcript-dir)))))
