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
;; See `agent-org-providers.el' for adding new agents.

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
  "Add ENTRY to `agent-org--sessions'."
  (push entry agent-org--sessions))

(defun agent-org--session-for-buffer (buffer)
  "Return the session plist whose :buffer is BUFFER, or nil."
  (seq-find (lambda (s) (eq (plist-get s :buffer) buffer))
            agent-org--sessions))

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
         (command (plist-get spec :command))
         (params (plist-get spec :command-params))
         (env (funcall (plist-get spec :environment))))
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
      (agent-org--show-loader)   ;; show progress bar while initializing
      (agent-org--initialize session))))

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
                                  (let ((sid (map-elt resp 'sessionId)))
                                    (setf (plist-get session :session-id) sid)
                                    (agent-org-buffer-insert-system
                                     buffer (format "Session started: %s" sid))))
                    :on-failure (lambda (err msg)
                                  (agent-org-buffer-insert-system
                                   buffer (format "session/new failed: %s %S" msg err)))))
     :on-failure (lambda (err msg)
                   (agent-org-buffer-insert-system
                    buffer (format "initialize failed: %s %S" msg err))))))

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
               (agent-org-buffer-insert-system
                (plist-get session :buffer)
                (format "ACP error: %s"
                        (or (map-elt err 'message)
                            (map-elt err 'data)
                            "unknown"))))))

(when (fboundp 'agent-org--on-notification)
  (defalias 'agent-org--default-on-notification
    (symbol-function 'agent-org--on-notification)))

(defun agent-org--on-notification (session notification)
  "Dispatch notifications through the loader‑aware handler."
  (agent-org--loader-on-notification session notification))


(defun agent-org--on-request (session request)
  "Handle an incoming ACP REQUEST from the agent (must respond)."
  (let* ((client (plist-get session :client))
         (buffer (plist-get session :buffer))
         (method (map-elt request 'method))
         (req-id (map-elt request 'id))
         (params (map-elt request 'params)))
    (pcase method
      ("fs/read_text_file"
       (let* ((path (map-nested-elt params '(path)))
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
       (let* ((path (map-nested-elt params '(path)))
              (content (map-nested-elt params '(content)))
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
       (let ((opts (map-nested-elt params '(options))))
         (agent-org-buffer-insert-system
          buffer (format "Permission requested: %S" (map-elt params 'toolCall)))
         (let ((choice (agent-org--prompt-permission opts)))
           (acp-send-response
            :client client
            :response (acp-make-session-request-permission-response
                       :request-id req-id
                       :option-id (car (split-string choice))
                       :cancelled (equal choice "cancel"))))))
      (_ (agent-org-buffer-insert-system
          buffer (format "Unhandled request: %s" method))))))

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

;;;; Sending

;;;###autoload
(defun agent-org-send ()
  "Send the User prompt under point (or at end) to the active session."
  (interactive)
  (let* ((buffer (current-buffer))
         (session (agent-org--session-for-buffer buffer)))
    (unless session
      (user-error "Not an agent-org chat buffer"))
    (let ((text (agent-org-buffer-read-prompt buffer)))
      (unless (and text (not (string-empty-p (string-trim text))))
        (user-error "Empty prompt"))
      (agent-org-buffer-insert-user buffer text)
      (let ((client (plist-get session :client))
            (sid (plist-get session :session-id)))
        (unless sid
          (user-error "Session not ready"))
        (acp-send-request
         :client client
         :request (acp-make-session-prompt-request
                   :session-id sid
                   :prompt (agent-org--make-content-blocks text))
         :buffer buffer
         :on-failure (lambda (err msg)
                       (agent-org-buffer-insert-system
                        buffer (format "prompt failed: %s %S" msg err))))))))

(provide 'agent-org)
;;; agent-org.el ends here
