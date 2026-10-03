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
;; A client must be a DISTINCT object per session: `agent-org' hands it to
;; `acp-shutdown' when a chat buffer dies, and a test asserting that
;; release cannot tell one `nil' from another.
(defvar acp-mock--client-id 0
  "Counter behind the fake clients `acp-make-client' hands out.")
(defun acp-make-client (&rest _args)
  (list :mock-client (cl-incf acp-mock--client-id)))
(defvar acp-mock-shutdown-clients nil
  "Clients `acp-shutdown' was called with, most recent first.")
(cl-defun acp-shutdown (&key client)
  (push client acp-mock-shutdown-clients))
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
(cl-defun acp-make-session-request-permission-response (&rest _args) nil)
(defun acp-make-session-prompt-request (&rest _args) nil)
(cl-defun acp-make-session-cancel-notification (&key session-id reason)
  `((:method . "session/cancel")
    (:params . ((sessionId . ,session-id)
                ,@(when reason `((reason . ,reason)))))))
(defvar acp-mock-notifications nil
  "Notifications `acp-send-notification' was called with, newest first.
`agent-org-cancel-turn' is fire-and-forget on the wire, so this record
is the only way a test can see the cancel was actually sent.")
(cl-defun acp-send-notification (&key client notification sync)
  (push notification acp-mock-notifications))
;;; acp.el ends here
