;;; acp-mock.el --- Mock ACP for headless testing -*- lexical-binding: t; -*-
;;; Commentary:
;; Minimal stand-ins for the real `acp' package so the test suite can
;; load `agent-org' without a live agent process.  Only the constructors
;; and subscription entry points referenced by agent-org are stubbed.
;; Load this file explicitly (it claims to provide `acp') before
;; requiring `agent-org'.  It must never live in the package root, or it
;; would shadow the real `acp' in live sessions.
;;; Code:
(provide 'acp)
(defun acp-make-client (&rest _args) nil)
(defun acp-subscribe-to-notifications (&rest _args) nil)
(defun acp-subscribe-to-requests (&rest _args) nil)
(defun acp-subscribe-to-errors (&rest _args) nil)
(defun acp-make-initialize-request (&rest _args) nil)
(defun acp-make-session-new-request (&rest _args) nil)
(defun acp-send-request (&rest _args) nil)
(defun acp-send-response (&rest _args) nil)
(defun acp-make-fs-read-text-file-response (&rest _args) nil)
(defun acp-make-fs-write-text-file-response (&rest _args) nil)
(defun acp-make-error (&rest _args) nil)
(defun acp-make-session-request-permission-response (&rest _args) nil)
(defun acp-make-session-prompt-request (&rest _args) nil)
;;; acp.el ends here
