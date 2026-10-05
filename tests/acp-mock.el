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
(defvar acp-mock--instance-count 0
  "Counter mirroring `acp-instance-count', which names traffic buffers.")
(cl-defun acp-make-client (&key command command-params &allow-other-keys)
  ;; The real SHAPE, not just the real keys.  `acp-make-client' returns an
  ;; ALIST of dotted keyword pairs (`(list (cons :process nil) ...)',
  ;; acp.el:90), which `map-elt' reads and `plist-get' does not.  A flat
  ;; plist here would let a `plist-get' reader pass the whole suite and
  ;; answer nil on a live session.
  ;;
  ;; `:command' and `:instance-count' are here for the same reason: acp
  ;; names a client's traffic buffer from those two (acp.el
  ;; `acp--traffic-buffer-name'), so a mock without them would give every
  ;; fake chat ONE log and let a test that should distinguish two chats
  ;; pass anyway.
  (list (cons :mock-client (cl-incf acp-mock--client-id))
        (cons :process nil)
        (cons :command command)
        (cons :command-params command-params)
        (cons :instance-count (cl-incf acp-mock--instance-count))))
(defvar acp-logging-enabled nil
  "Mirrors acp's global switch, consulted when a message arrives.")
(cl-defun acp-traffic-buffer (&key client)
  "Return CLIENT's traffic buffer, named the way acp names it."
  (let ((name (format "*acp-(%s)-%s traffic*"
                      (map-elt client :command)
                      (map-elt client :instance-count))))
    (or (get-buffer name) (get-buffer-create name))))
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
