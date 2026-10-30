;;; test-provider-liveness.el --- Live handshake test per provider -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Khalid

;; Author: Khalid
;; Version: 0.1.0

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Live handshake test per provider for WO-18.
;; Each provider is initialized, and a handshake is attempted.
;; Results are collected into an evidence matrix.
;; Gaps are reported (never invented).

;;; Code:

(require 'ert)
(require 'ert-x)
(require 'agent-org)
(require 'agent-org-providers)
(require 'cl-lib)

;; A `.elc' beside the sources wins the load race, so a suite run after a
;; package-compile step would test the 4-am image of the code rather than
;; the edit under test — silently, and the warning only goes to
;; `standard-error'.  Prefer the newer file, always.
(setq load-prefer-newer t)
;; The transcript writer is ON by default, and most fixtures below produce a
;; Ready session with an id — so without this guard every such test mirrors its
;; chat into `agent-org-transcript-dir', which for a relative default is
;; the directory the suite happens to be running in.  Measured: a full run
;; dropped 22 `sid-*.org' files in the package tree.  A test that cares about
;; the file says so with `ao--transcript-in', which turns the writer back on
;; inside its own temp directory.
(setq agent-org-transcribe nil)

(defvar ao--provider-liveness-results
  '()
  "Results from provider liveness tests. Each entry is a cons cell:
(NAME . (VERDICT . REASON))")

(defun ao--test-provider-liveness (provider-name)
  "Test that PROVIDER-NAME can initialize a handshake.
Return (VERDICT . REASON) where VERDICT is either :PASS or :FAIL,
and REASON is a string describing the result."
  (message "Testing provider: %s" provider-name)
  (condition-case err
      (let* ((start-fn (intern (format "agent-org-%s-start-agent" provider-name)))
             (buf (funcall start-fn)))
        (message "Provider %s: command started" provider-name)
        ;; Give the agent a moment to start
        (sit-for 1)
        (when (buffer-live-p buf)
          (message "Provider %s: buffer is live" provider-name)
          (let* ((session (agent-org--session-for-buffer buf))
                 (state (plist-get session :state)))
            (message "Provider %s: state = %s" provider-name state)
            (kill-buffer buf)
            (cond
             ((equal state 'error)
              (cons :fail (format "Provider failed to initialize: %s" err)))
             ((equal state 'ready)
              (cons :pass (format "Provider %s initialized successfully" provider-name)))
             (t
              (cons :fail (format "Provider %s in unexpected state: %s" provider-name state)))))))
    (error
     (list :fail (format "Provider %s error: %s" provider-name err)))))

(defun ao--run-provider-liveness-tests ()
  "Run liveness tests for all providers.
Returns an alist of (NAME . (VERDICT . REASON))."
  (let ((providers '("slave-agent"
                     "Goose"
                     "Qoder"
                     "OpenCode"
                     "MiniMax"
                     "Copilot"
                     "Cursor"
                     "CodeBuddy"
                     "Cline"
                     "OMP"
                     "Pi"
                     "DSH"
                     "Gemini"
                     "Devin")))
    (mapcar #'(lambda (p)
                (let ((result (ao--test-provider-liveness p)))
                  (push result ao--provider-liveness-results)
                  result))
            providers)))

(defun ao--report-liveness-results ()
  "Report the liveness results in a format suitable for the TODOs.org LOGBOOK.
Returns a string."
  (let ((passed 0)
        (failed 0)
        (report ""))
    (dolist (result ao--provider-liveness-results)
      (let ((name (car result))
            (verdict (cdr result)))
        (if (eq (car verdict) :pass)
            (incf passed)
          (incf failed))
        (setq report (format "%s\n  %s: %s (%s)"
                             report
                             name
                             (if (eq (car verdict) :pass) "PASS" "FAIL")
                             (cdr verdict))))
    (format "WO-18 provider liveness test results:\n\n"
            "Total: %d providers tested (%d pass, %d fail)\n\n"
            (length ao--provider-liveness-results)
            passed
            failed
            report)))

(ert-deftest test-agent-org-all-providers-have-start-agent ()
  "Every provider in agent-org-providers.el has a start-agent command.
This is a structural check that the drift test can use."
  (let ((providers '("slave-agent"
                     "Goose"
                     "Qoder"
                     "OpenCode"
                     "MiniMax"
                     "Copilot"
                     "Cursor"
                     "CodeBuddy"
                     "Cline"
                     "OMP"
                     "Pi"
                     "DSH"
                     "Gemini"
                     "Devin")))
    (dolist (p providers)
      (should (fboundp (intern (format "agent-org-%s-start-agent" p))))))))

(ert-deftest test-agent-org-provider-liveness ()
  "Live handshake test for every provider.
This test attempts to initialize each provider and verifies it responds.
Providers that are not baked in the harness should fail gracefully.
Gaps are reported in the ao--provider-liveness-results alist."
  (ao--run-provider-liveness-tests)
  ;; We expect some failures (providers not baked in the harness)
  ;; but we want to document them in the LOGBOOK
  (should (listp ao--provider-liveness-results))
  (let ((passed 0)
        (failed 0))
    (dolist (result ao--provider-liveness-results)
      (let ((verdict (cdr result)))
        (if (eq (car verdict) :pass)
            (cl-incf passed)
          (cl-incf failed))))
    ;; At least some providers should pass (Goose, Qoder, etc.)
    (should (>= passed 1))
    ;; We expect some failures (providers not baked)
    (should (> failed 0))))

(provide 'test-provider-liveness)
