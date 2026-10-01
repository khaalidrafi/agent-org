;;; acp-mock.el --- Mock ACP for headless testing -*- lexical-binding: t; -*-
;;; Commentary:
;; Minimal stand-ins for the real `acp' package so the test suite can
;; load `agent-org' without a live agent process.  Only the constructors
;; and subscription entry points referenced by agent-org are stubbed.
;; Load this file explicitly (it claims to provide `acp') before
;; requiring `agent-org'.  It must never live in the package root, or it
;; would shadow the real `acp' in live sessions.
;;; Code:
(require 'cl-lib)
(provide 'acp)
(defun acp-make-client (&rest _args) nil)
(defun acp-subscribe-to-notifications (&rest _args) nil)
(defun acp-subscribe-to-requests (&rest _args) nil)
(defun acp-subscribe-to-errors (&rest _args) nil)
;; Request builders return the same ((:method . "…") (:params . ALIST))
;; shape as the real package, so tests can classify the captured wire
;; with `map-elt'.  `cl-defun' rather than `defun' on purpose: the test
;; suite loads this file as source, and an interpreted `defun' with
;; `&key' does not parse keyword arguments at all.
(defun acp-make-initialize-request (&rest _args)
  `((:method . "initialize")))
(cl-defun acp-make-session-new-request (&key cwd)
  `((:method . "session/new")
    (:params . ((cwd . ,(directory-file-name (expand-file-name cwd)))))))
(cl-defun acp-make-session-load-request (&key session-id cwd)
  `((:method . "session/load")
    (:params . ((sessionId . ,session-id)
                (cwd . ,(directory-file-name (expand-file-name cwd)))))))
(cl-defun acp-make-session-list-request (&key cwd cursor)
  `((:method . "session/list")
    (:params . ,(append `((cwd . ,(directory-file-name (expand-file-name cwd))))
                        ;; the real builder omits the key entirely rather
                        ;; than sending (cursor . nil) on the wire
                        (when cursor (list (cons 'cursor cursor)))))))
(cl-defun acp-make-session-set-config-option-request
    (&key session-id config-id value)
  `((:method . "session/set_config_option")
    (:params . ((sessionId . ,session-id)
                (configId . ,config-id)
                (value . ,value)))))
(defun acp-send-request (&rest _args) nil)
(defun acp-send-response (&rest _args) nil)
(defun acp-make-fs-read-text-file-response (&rest _args) nil)
(defun acp-make-fs-write-text-file-response (&rest _args) nil)
(defun acp-make-error (&rest _args) nil)
(defun acp-make-session-request-permission-response (&rest _args) nil)
(defun acp-make-session-prompt-request (&rest _args) nil)
;;; acp.el ends here
