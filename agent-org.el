;;; agent-org.el --- Org-mode UI for ACP (Agent Client Protocol) agents -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Khalid

;; Author: Khalid
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (acp "0.14.3") (org "9.0"))
;; Keywords: tools, agents, ai, org
;; URL: https://github.com/khaalidrafi/agent-org

;; This file is not part of GNU Emacs.

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

;; `agent-org' is a lightweight, Org-native client for coding agents
;; that speak ACP (Agent Client Protocol).  Unlike `agent-shell', it
;; does not run a hidden comint/terminal buffer: it talks directly to
;; the `acp' package and renders agent output natively as Org
;; headlines, keeping the editor fast and document-centric.
;;
;; Minimal usable flow:
;;
;;   M-x agent-org-start
;;
;; picks a provider (e.g. Goose), opens an Org chat buffer, starts an
;; ACP session, and streams responses straight into it.
;;
;; Status, progress and errors are shown in the chat buffer's
;; header line (the top bar), never in the document body.  See
;; `agent-org-buffer.el' for the status model and
;; `agent-org-providers.el' for adding new agents.

;;; Code:

(require 'cl-lib)
(require 'map)
(require 'seq)
(require 'acp)
(require 'org)
(require 'agent-org-buffer)
(require 'agent-org-providers)
(require 'agent-org-loader)

(defgroup agent-org nil
  "Org-mode UI for ACP coding agents."
  :group 'tools
  :prefix "agent-org-")

;;;; Session registry

(defvar agent-org--sessions nil
  "List of active sessions.
Each entry is a plist:
  :name        - provider id (symbol)
  :client      - acp client alist
  :buffer      - Org chat buffer
  :session-id  - ACP session-id (string, once known)
  :streaming   - non-nil while a turn is streaming")

(defun agent-org--register-session (entry)
  "Add ENTRY to `agent-org--sessions'.
Installs a buffer-local hook so the entry is dropped when its buffer
is killed."
  (push entry agent-org--sessions)
  (when-let* ((buf (plist-get entry :buffer)))
    (with-current-buffer buf
      (add-hook 'kill-buffer-hook #'agent-org--forget-session nil t))))

(defun agent-org--forget-session ()
  "Remove the current buffer's session from `agent-org--sessions'."
  (let ((buf (current-buffer)))
    (setq agent-org--sessions
          (seq-remove (lambda (s) (eq (plist-get s :buffer) buf))
                      agent-org--sessions))))

(defun agent-org--session-for-buffer (buffer)
  "Return the session plist whose :buffer is BUFFER, or nil."
  (seq-find (lambda (s) (eq (plist-get s :buffer) buffer))
            agent-org--sessions))

(defun agent-org--wire-list (value)
  "Return wire array VALUE as a list (JSON arrays arrive as vectors)."
  (cond
   ((vectorp value) (append value nil))
   ((listp value) value)
   (t nil)))

(defun agent-org--model-from-config (config)
  "Return the model-ish current value from configOptions list CONFIG.
Prefer an option with id \"model\", else \"provider\" (what goose
reports), else nil."
  (when-let* ((option
               (or (seq-find (lambda (o) (equal (map-elt o 'id) "model"))
                             config)
                   (seq-find (lambda (o) (equal (map-elt o 'id) "provider"))
                             config))))
    (map-elt option 'currentValue)))

(defun agent-org--session-ready (session sid &optional resp)
  "Mark SESSION live under ACP session id SID and open the input prompt.
RESP is the full session/new response alist when available; its modes
and config options feed the header line and metadata block.  Safe to
call repeatedly: prompt insertion is idempotent and skipped while any
turn is in flight (Goose fires session_info_update mid-turn for title
updates; the send callbacks re-open the prompt afterwards)."
  (setf (plist-get session :session-id) sid)
  (let ((buffer (plist-get session :buffer))
        (modes (and resp (map-elt resp 'modes)))
        (config (and resp (agent-org--wire-list (map-elt resp 'configOptions)))))
    (when modes
      (agent-org-buffer-set-status buffer
        :mode (map-elt modes 'currentModeId)
        :modes-list (agent-org--wire-list (map-elt modes 'availableModes))))
    (when config
      (agent-org-buffer-set-status buffer
        :config config
        :model (agent-org--model-from-config config)))
    (agent-org-loader-finish buffer :session-id sid)
    (agent-org-buffer-refresh-metadata buffer)
    (unless (plist-get session :streaming)
      (agent-org-buffer-insert-prompt buffer))))

;;;; Lifecycle

;;;###autoload
(defun agent-org-start (provider)
  "Start a new ACP session with PROVIDER and open its Org chat buffer.
When called interactively, prompt for the provider."
  (interactive
   (list (intern
          (completing-read
           "Provider: "
           (seq-map (lambda (p) (symbol-name (plist-get p :id)))
                    agent-org-providers)
           nil t))))
  (let* ((provider (if (symbolp provider) provider (intern provider)))
         (spec (seq-find (lambda (p) (eq (plist-get p :id) provider))
                         agent-org-providers))
         (command (and spec (plist-get spec :command)))
         (params (and command (cdr command)))
         (env (and spec (funcall (plist-get spec :environment)))))
    (unless spec
      (user-error "Unknown provider: %S" provider))
    (unless (executable-find (car command))
      (user-error "Command not found: %s" (car command)))
    (let* ((buffer (agent-org-buffer-create (plist-get spec :name)))
           (client (acp-make-client
                    :context-buffer buffer
                    :command (car command)
                    :command-params params
                    :environment-variables env))
           (session (list :name provider
                          :client client
                          :buffer buffer
                          :session-id nil
                          :streaming nil)))
      (agent-org--register-session session)
      (agent-org--subscribe client session)
      (agent-org-buffer-set-session buffer session)
      (switch-to-buffer buffer)
      (agent-org-loader-begin buffer)
      (agent-org--initialize session)
      buffer)))

(defun agent-org--initialize (session)
  "Run ACP initialize handshake then start a session/new for SESSION."
  (let* ((client (plist-get session :client))
         (buffer (plist-get session :buffer))
         (cwd (or (plist-get session :cwd) default-directory)))
    (acp-send-request
     :client client
     :request (acp-make-initialize-request
               :protocol-version 1
               :client-info `((name . "agent-org")
                              (title . "agent-org")
                              (version . "0.1.0"))
               :read-text-file-capability t
               :write-text-file-capability t)
     :buffer buffer
     :on-success (lambda (_resp)
                   (acp-send-request
                    :client client
                    :request (acp-make-session-new-request :cwd cwd)
                    :buffer buffer
                    :on-success (lambda (resp)
                                  (agent-org--session-ready session
                                    (map-elt resp 'sessionId)
                                    resp))
                    :on-failure (lambda (_err msg)
                                  (agent-org-loader-fail buffer
                                    (format "session/new failed: %s" msg)))))
     :on-failure (lambda (_err msg)
                   (agent-org-loader-fail buffer
                     (format "initialize failed: %s" msg))))))

;;;; Event subscription

(defun agent-org--subscribe (client session)
  "Wire CLIENT notifications/requests to SESSION's Org handlers."
  (acp-subscribe-to-notifications
   :client client
   :buffer (plist-get session :buffer)
   :on-notification (lambda (n)
                      (agent-org--on-notification session n)))
  (acp-subscribe-to-requests
   :client client
   :buffer (plist-get session :buffer)
   :on-request (lambda (r)
                 (agent-org--on-request session r)))
  (acp-subscribe-to-errors
   :client client
   :buffer (plist-get session :buffer)
   :on-error (lambda (err)
               (agent-org-buffer-set-status
                (plist-get session :buffer)
                :state 'error
                :message (format "ACP error: %s"
                                 (or (map-elt err 'message)
                                     (map-elt err 'data)
                                     "unknown"))))))

;;;; Notification dispatch

(defun agent-org--chunk-text (content)
  "Extract plain text from an ACP message/thought CONTENT value.
CONTENT may be a text ContentBlock alist or a bare string."
  (cond
   ((stringp content) content)
   ((and (listp content) (map-elt content 'text))
    (map-elt content 'text))))

(defun agent-org--on-notification (session notification)
  "Dispatch one ACP NOTIFICATION for SESSION into the Org buffer.
This is the single, non-recursive notification handler; every update
kind is handled here and nothing is delegated to another handler."
  (let* ((buffer (plist-get session :buffer))
         (method (map-elt notification 'method))
         (params (map-elt notification 'params))
         (update (map-elt params 'update))
         (kind (map-elt update 'sessionUpdate)))
    (when (equal method "session/update")
      (pcase kind
        ("session_info_update"
         (when-let* ((sid (map-elt params 'sessionId)))
           (when-let* ((title (or (map-elt update 'title) (map-elt params 'title))))
             (agent-org-buffer-set-status buffer :title title))
           (agent-org--session-ready session sid)))
        ("agent_message_chunk"
         (agent-org-buffer-set-status buffer :state 'streaming :message nil)
         (when-let* ((text (agent-org--chunk-text (map-elt update 'content))))
           (agent-org-buffer-append-chunk buffer text session)))
        ("agent_thought_chunk"
         (when-let* ((text (agent-org--chunk-text (map-elt update 'content))))
           (agent-org-buffer-append-thought buffer text)))
        ((or "tool_call" "tool_call_update")
         (agent-org-buffer-insert-tool buffer update))
        ("available_commands_update"
         (agent-org-buffer-set-status
          buffer :commands
          (agent-org--wire-list (map-elt update 'availableCommands)))
         (agent-org-buffer-refresh-metadata buffer))
        ("usage_update"
         (agent-org-buffer-set-status buffer
           :used (map-elt update 'used) :size (map-elt update 'size))
         (agent-org-buffer-refresh-metadata buffer))
        ("current_mode_update"
         (agent-org-buffer-set-status buffer
           :mode (map-elt update 'currentModeId))
         (agent-org-buffer-refresh-metadata buffer))
        ("config_option_update"
         (let ((config (agent-org--wire-list (map-elt update 'configOptions))))
           (when config
             (agent-org-buffer-set-status buffer
               :config config :model (agent-org--model-from-config config))
             (agent-org-buffer-refresh-metadata buffer))))
        (_ nil)))))

;;;; Incoming request handling

(defun agent-org--on-request (session request)
  "Handle an incoming ACP REQUEST from the agent (must respond)."
  (let* ((client (plist-get session :client))
         (buffer (plist-get session :buffer))
         (method (map-elt request 'method))
         (req-id (map-elt request 'id))
         (params (map-elt request 'params)))
    (pcase method
      ("fs/read_text_file"
       (let* ((path (map-elt params 'path))
              (expanded (expand-file-name path (plist-get session :cwd))))
         (if (file-readable-p expanded)
             (acp-send-response
              :client client
              :response (acp-make-fs-read-text-file-response
                         :request-id req-id
                         :content (with-temp-buffer
                                    (insert-file-contents expanded)
                                    (buffer-string))))
           (acp-send-response
            :client client
            :response (acp-make-fs-read-text-file-response
                       :request-id req-id
                       :error (acp-make-error
                               :code -32000
                               :message (format "File not readable: %s" path)))))))
      ("fs/write_text_file"
       (let* ((path (map-elt params 'path))
              (content (map-elt params 'content))
              (expanded (expand-file-name path (plist-get session :cwd))))
         (condition-case err
             (progn
               (with-temp-buffer
                 (insert content)
                 (write-region nil nil expanded nil 'silent))
               (acp-send-response
                :client client
                :response (acp-make-fs-write-text-file-response :request-id req-id)))
           (error
            (acp-send-response
             :client client
             :response (acp-make-fs-write-text-file-response
                        :request-id req-id
                        :error (acp-make-error
                                :code -32000
                                :message (format "Write failed: %S" err))))))))
      ("session/request_permission"
       (let ((previous
              ;; copy: plist-put mutates the status list in place
              (copy-sequence (buffer-local-value 'agent-org-buffer--status buffer)))
             (opts (map-elt params 'options)))
         (agent-org-buffer-set-status buffer :state 'awaiting :message "Permission required")
         (unwind-protect
             (condition-case nil
                 (let ((choice (agent-org--prompt-permission opts)))
                   (if (equal choice "cancel")
                       (acp-send-response
                        :client client
                        :response (acp-make-session-request-permission-response
                                   :request-id req-id :cancelled t))
                     (acp-send-response
                      :client client
                      :response (acp-make-session-request-permission-response
                                 :request-id req-id
                                 :option-id (car (split-string choice))))))
               (quit
                (acp-send-response
                 :client client
                 :response (acp-make-session-request-permission-response
                            :request-id req-id :cancelled t))))
           (apply #'agent-org-buffer-set-status buffer previous))))
      (_
       (agent-org-buffer-set-status
        buffer :message (format "Unhandled request: %s" method))))))

(defun agent-org--prompt-permission (options)
  "Prompt the user to pick one OPTION-ID from OPTIONS (alist list).
Returns the chosen option id string, or \"cancel\"."
  (let* ((candidates
          (seq-map (lambda (o) (cons (map-elt o 'label) (map-elt o 'id)))
                   options))
         (choice (completing-read "Allow? "
                                  (append (seq-map #'car candidates)
                                          '("cancel"))
                                  nil t)))
    (if (equal choice "cancel")
        "cancel"
      (or (cdr (assoc choice candidates)) choice))))

;;;; Content blocks

(defun agent-org--make-content-blocks (text)
  "Convert TEXT (a plain string) into a list of ACP ContentBlock alists.
Currently supports plain text blocks only."
  (list `((type . "text")
          (text . ,text))))

;;;; Usage accounting

(defun agent-org--record-usage (buffer resp)
  "Fold token/cost data from PromptResponse RESP into BUFFER's status.
RESP may be nil or lack either field (providers are not required to
report usage); anything missing is simply left untouched."
  (when-let* ((usage (and resp (map-elt resp 'usage)))
              (total (or (map-elt usage 'totalTokens)
                         (and-let* (((map-elt usage 'inputTokens)))
                           (+ (map-elt usage 'inputTokens)
                              (or (map-elt usage 'outputTokens) 0))))))
    (let ((previous (plist-get (buffer-local-value 'agent-org-buffer--status buffer)
                               :tokens)))
      (agent-org-buffer-set-status buffer :tokens (+ total (or previous 0)))))
  (when-let* ((cost (and resp (map-elt resp 'cost)))
              (amount (map-elt cost 'amount)))
    (agent-org-buffer-set-status buffer
      :cost-amount (float amount)
      :cost-currency (or (map-elt cost 'currency) "USD"))))

;;;; Sending

;;;###autoload
(defun agent-org-send ()
  "Send the typed prompt at the end of the chat buffer to the agent."
  (interactive)
  (let* ((buffer (current-buffer))
         (session (agent-org--session-for-buffer buffer)))
    (unless session
      (user-error "Not an agent-org chat buffer"))
    (when (plist-get session :streaming)
      (user-error "Agent is still responding"))
    (unless (plist-get session :session-id)
      (user-error "Session not ready"))
    (let ((text (agent-org-buffer-read-prompt buffer)))
      (with-current-buffer buffer (goto-char (point-max)))
      (let ((client (plist-get session :client))
            (sid (plist-get session :session-id)))
        (setf (plist-get session :streaming) t)
        (agent-org-buffer-set-status buffer :state 'streaming :message "Sending…")
        (acp-send-request
         :client client
         :request (acp-make-session-prompt-request
                   :session-id sid
                   :prompt (agent-org--make-content-blocks text))
         :buffer buffer
         :on-success (lambda (resp)
                       (setf (plist-get session :streaming) nil)
                       (agent-org-buffer-end-agent-turn buffer)
                       (agent-org--record-usage buffer resp)
                       (agent-org-buffer-set-status buffer :state 'ready)
                       (agent-org-buffer-insert-prompt buffer)
                       (agent-org-buffer-refresh-metadata buffer))
         :on-failure (lambda (_err msg)
                       (setf (plist-get session :streaming) nil)
                       (agent-org-buffer-end-agent-turn buffer)
                       (agent-org-buffer-set-status
                        buffer :state 'error :message (format "prompt failed: %s" msg))
                       (agent-org-buffer-insert-prompt buffer)))))))

(provide 'agent-org)
;;; agent-org.el ends here
