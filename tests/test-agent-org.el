;;; test-agent-org.el --- Tests for agent-org -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Khalid

;; Author: Khalid
;; Version: 0.1.0

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Unit tests for the Org chat buffer, the header-line status model and
;; the ACP notification dispatcher.  Run headless against the mock acp
;; in tests/acp-mock.el, which must be loaded before `agent-org'.

;;; Code:

(require 'ert)
;; `ert-with-temp-directory' — the transcript tests are the first here to
;; touch the disk, and that macro lives in ert-x, not ert.
(require 'ert-x)
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
(load (expand-file-name "acp-mock.el" (file-name-directory load-file-name)))
;; The package root, captured NOW: `load-file-name' is bound only while this file
;; is being loaded, so a test that runs later (ert-run-tests-batch) sees it nil
;; and cannot resolve the generated autoloads file through it.  Reading that file
;; is the point — see `test-agent-org-every-provider-has-a-start-agent-command'.
(defvar ao--package-root
  (file-name-directory (directory-file-name (file-name-directory load-file-name)))
  "Directory of the package sources, resolved while `load-file-name' is bound.")
(require 'agent-org)
(require 'agent-org-buffer)
(require 'agent-org-loader)
(require 'agent-org-providers)
;; Arc 6 made `headings' the package's DEFAULT activity style, and the great
;; majority of the render tests below were written against the drawer shape they
;; describe: one `:tool:' board per run, a folded `:thinking:', prose under a
;; `Model: ' prefix line.  Rather than edit forty fixtures to bind the style
;; they implicitly assumed, the suite pins the ONE global the tests read, and
;; every test that cares about a shape states it -- either through this default
;; or with its own `let'.  The default the USER gets is pinned the other way, by
;; `test-agent-org-headings-is-the-default-activity-style'.  Set AFTER the
;; requires: a `defcustom' re-sets its own default when its file loads, so the
;; same line above them would be silently thrown away.
(setq agent-org-activity-style 'drawers)

;;;; Provider registry

(ert-deftest test-agent-org-slave-agent-provider-present ()
  "slave-agent is registered as the first provider: it is the agent this
package was written around.
The command is `slave-acp', a standalone console script, NOT `slave acp'.
That distinction is load-bearing and invisible from the outside: the
script serves ACP on stdio without loading the CLI and without
provisioning dependencies at launch, which is what a package-manager
install (Guix) needs an editor spawn to do.  It pins no model because the
agent reads its own ~/.slave/config.yaml."
  (let ((slave (agent-org--provider-spec 'slave-agent)))
    (should (equal (plist-get slave :name) "slave-agent"))
    (should (equal (plist-get slave :command) '("slave-acp")))
    (should-not (plist-get slave :model))
    (should (equal (plist-get slave :environment)
                   #'agent-org-slave-agent-environment))))

(ert-deftest test-agent-org-slave-agent-start-opens-slave-agent ()
  "The named entry point opens slave-agent, not another provider.
Caught by the same copy-paste that made the drift test necessary: a
`agent-org-slave-agent-start-agent' that starts the wrong agent passes
`test-agent-org-every-provider-has-a-start-agent-command'."
  (ao--capture-wire
    (let ((buf (agent-org-slave-agent-start-agent)))
      (should (buffer-live-p buf))
      (should (eq 'slave-agent (plist-get (agent-org--session-for-buffer buf) :name)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-slave-agent-environment-passes-home-only ()
  "No secret crosses into the agent's environment from Emacs.
slave-agent loads ~/.slave/.env itself; the one thing Emacs may legitimately
steer is which profile's state dir the session binds, via `SLAVE_HOME'.
Exporting anything else would be a second source of truth for a credential."
  (let ((process-environment '("SLAVE_HOME=")))
    (should-not (agent-org-slave-agent-environment)))
  (let ((process-environment '("SLAVE_HOME=/tmp/slave-profile")))
    (should (equal (agent-org-slave-agent-environment)
                   '("SLAVE_HOME=/tmp/slave-profile")))))

(ert-deftest test-agent-org-goose-provider-present ()
  "Goose provider is registered with required fields."
  (let ((goose (seq-find (lambda (p) (eq (plist-get p :id) 'goose))
                         agent-org-providers)))
    (should goose)
    (should (equal (plist-get goose :name) "Goose"))
    (should (equal (plist-get goose :command) '("goose" "acp")))
    (should (fboundp (plist-get goose :environment)))))

(ert-deftest test-agent-org-opencode-provider-present ()
  "OpenCode is registered as the ACP host, with no pinned model.
OpenCode is one server fronting many vendors' models, so a session opens
on its shared default until the user picks one (`agent-org-set-session-model') or
a provider entry pins one."
  (let ((opencode (agent-org--provider-spec 'opencode)))
    (should (equal (plist-get opencode :name) "OpenCode"))
    (should (equal (plist-get opencode :command) '("opencode" "acp")))
    (should-not (plist-get opencode :model))
    (should (fboundp (plist-get opencode :environment)))))

(ert-deftest test-agent-org-minimax-provider-present ()
  "MiniMax Code is its OWN agent: `mcode acp', not OpenCode in disguise.
MiniMax Code and OpenCode are different products; only OpenCode needs a
pinned model because it serves many vendors.  `mcode' is MiniMax's own
CLI, so a MiniMax session must spawn it and pin nothing — its default
model is already a MiniMax model."
  (let ((minimax (agent-org--provider-spec 'minimax)))
    (should (equal (plist-get minimax :name) "MiniMax"))
    (should (equal (plist-get minimax :command) '("mcode" "acp")))
    (should-not (equal (plist-get minimax :command)
                       (plist-get (agent-org--provider-spec 'opencode)
                                  :command)))
    (should-not (plist-get minimax :model))
    (should (equal (plist-get minimax :environment)
                   #'agent-org-mcode-environment))))

(ert-deftest test-agent-org-copilot-provider-present ()
  "GitHub Copilot is its OWN ACP agent: `copilot --acp'.
Copilot CLI speaks ACP (public preview) and keeps its own login, so — like
MiniMax Code — it pins nothing (its default model is already the right one)
and only passes a headless COPILOT_GITHUB_TOKEN through when present."
  (let ((copilot (agent-org--provider-spec 'copilot)))
    (should (equal (plist-get copilot :name) "Copilot"))
    (should (equal (plist-get copilot :command) '("copilot" "--acp")))
    (should-not (plist-get copilot :model))
    (should (equal (plist-get copilot :environment)
                   #'agent-org-copilot-environment))))

(ert-deftest test-agent-org-cursor-provider-present ()
  "Cursor's CLI binary is `agent', with ACP a subcommand: `agent acp'.
A reader would guess `cursor acp'; it is not — the command mirrors
agent-shell's `agent-shell-cursor-acp-command'.  Auth defaults to an
external `agent login' (no ACP authenticate request, unlike agent-shell's
optional cursor_login flow, which agent-org does not drive), so the entry
pins no model."
  (let ((cursor (agent-org--provider-spec 'cursor)))
    (should (equal (plist-get cursor :name) "Cursor"))
    (should (equal (plist-get cursor :command) '("agent" "acp")))
    (should-not (plist-get cursor :model))
    (should (equal (plist-get cursor :environment)
                   #'agent-org-cursor-environment))))

(ert-deftest test-agent-org-codebuddy-provider-present ()
  "CodeBuddy is its own CLI agent: `codebuddy --acp'.
Login is kept by the CLI itself, so nothing is exported by default."
  (let ((codebuddy (agent-org--provider-spec 'codebuddy)))
    (should (equal (plist-get codebuddy :name) "CodeBuddy"))
    (should (equal (plist-get codebuddy :command) '("codebuddy" "--acp")))
    (should-not (plist-get codebuddy :model))
    (should (equal (plist-get codebuddy :environment)
                   #'agent-org-codebuddy-environment))))

(ert-deftest test-agent-org-copilot-cursor-codebuddy-pass-only-what-they-need ()
  "Three providers, three credential stories, and all three are pass-through or
nothing.  Copilot exports nothing unless a headless COPILOT_GITHUB_TOKEN is
already in the environment; Cursor prefers CURSOR_API_KEY and falls back to
CURSOR_AUTH_TOKEN, both passed through rather than fetched; CodeBuddy exports
NOTHING, ever, because its login lives in the CLI.  The point of the three
assertions is the same: no provider of this package reads a credential store
of its own, so Emacs never becomes a second source of truth for a secret."
  (let ((process-environment '("COPILOT_GITHUB_TOKEN="
                                "CURSOR_API_KEY="
                                "CURSOR_AUTH_TOKEN=")))
    (should-not (agent-org-copilot-environment))
    (should-not (agent-org-cursor-environment))
    (should-not (agent-org-codebuddy-environment)))
  (let ((process-environment '("COPILOT_GITHUB_TOKEN=ghp_headless"
                                "CURSOR_API_KEY=key-123"
                                "CURSOR_AUTH_TOKEN=token-456")))
    (should (equal (agent-org-copilot-environment)
                   '("COPILOT_GITHUB_TOKEN=ghp_headless")))
    ;; the PREFERRED variable wins, and only one of the two crosses
    (should (equal (agent-org-cursor-environment) '("CURSOR_API_KEY=key-123"))))
  ;; the FALLBACK token is used only when the preferred one is absent
  (let ((process-environment '("CURSOR_API_KEY=" "CURSOR_AUTH_TOKEN=token-456")))
    (should (equal (agent-org-cursor-environment)
                   '("CURSOR_AUTH_TOKEN=token-456"))))
  ;; CodeBuddy has no environment function body to fall back on: its login is
  ;; the CLI's, so the answer is nil whatever the environment says
  (let ((process-environment '("CODEBUDDY_TOKEN=whatever")))
    (should-not (agent-org-codebuddy-environment))))

(ert-deftest test-agent-org-cline-provider-present ()
  "Cline is its own CLI agent: `cline --acp', login kept by the CLI.
Cline's terminal CLI speaks ACP over `--acp' — the command mirrors
agent-shell's `agent-shell-cline-acp-command'.  It keeps its own credential
store, so (like CodeBuddy) nothing is exported by default and no model is
pinned: Cline is a single product, not a server fronting many models."
  (let ((cline (agent-org--provider-spec 'cline)))
    (should (equal (plist-get cline :name) "Cline"))
    (should (equal (plist-get cline :command) '("cline" "--acp")))
    (should-not (plist-get cline :model))
    (should (equal (plist-get cline :environment)
                   #'agent-org-cline-environment))))

(ert-deftest test-agent-org-cline-start-opens-cline ()
  "The per-provider command opens Cline, not another agent.
`test-agent-org-every-provider-has-a-start-agent-command' only proves a
`agent-org-cline-start-agent' exists; this proves it starts the Cline
session, catching a copy-pasted command baked with the wrong id.  Mirrors
`test-agent-org-goose-start-agent-opens-goose'.  Under the mock there is no
live process, so the kill hook stays silent."
  (ao--capture-wire
    (let ((buf (agent-org-cline-start-agent)))
      (should (buffer-live-p buf))
      (should (eq 'cline (plist-get (agent-org--session-for-buffer buf) :name)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-copilot-cursor-codebuddy-start-open-themselves ()
  "Each new per-provider command is the same thin call with its id baked in.
The drift test already proves one `agent-org-<id>-start-agent' exists for
every registered id; this proves each actually opens ITS OWN session, so a
copy-pasted command that starts the wrong agent is caught.  Under the mock
there is no live process, so the kill hook stays silent."
  (ao--capture-wire
    (dolist (pair '((copilot . agent-org-copilot-start-agent)
                    (cursor . agent-org-cursor-start-agent)
                    (codebuddy . agent-org-codebuddy-start-agent)))
      (let ((buf (funcall (cdr pair))))
        (should (buffer-live-p buf))
        (should (eq (car pair)
                    (plist-get (agent-org--session-for-buffer buf) :name)))
        (kill-buffer buf)))))

;;;; Harness-body parity (WO-16: omp, pi, dsh)

(ert-deftest test-agent-org-omp-provider-present ()
  "OMP (oh-my-pi) is its own ACP agent: `omp acp', nothing pinned.
Command shape is the one omp.sh/docs/acp recommends for client config
(\"`omp --mode acp' is equivalent, but `omp acp' is the recommended
spelling\"), transport stdio.  It fronts many providers but resolves its
own default from ~/.omp/agent/config.yml, so a pin would fight the
agent's config; `PI_*' credentials are environment fallbacks to omp's
stored login, which is why the env function exports nothing unless asked.
Confirmed against the LIVE server in this image (2026-10-28, an
`initialize' over stdin): agentInfo omp 18.13.3, loadSession t and
sessionCapabilities (list, fork, resume, close)."
  (let ((omp (agent-org--provider-spec 'omp)))
    (should (equal (plist-get omp :name) "OMP"))
    (should (equal (plist-get omp :command) '("omp" "acp")))
    (should-not (plist-get omp :model))
    (should (equal (plist-get omp :environment)
                   #'agent-org-omp-environment))))

(ert-deftest test-agent-org-pi-provider-present ()
  "Pi has NO native ACP server: the `pi-acp' adapter is the command.
github.com/svkozak/pi-acp speaks ACP JSON-RPC over stdio and spawns
`pi --mode rpc' itself, so agent-org talks to the adapter binary and
never to `pi' directly (install: npm install -g pi-acp).  Model choice
belongs to pi's own config, and the adapter documents limits an ACP
client must respect: no fs/* or terminal/* delegation, and MCP servers
are accepted but not wired through to pi."
  (let ((pi (agent-org--provider-spec 'pi)))
    (should (equal (plist-get pi :name) "Pi"))
    (should (equal (plist-get pi :command) '("pi-acp")))
    (should-not (plist-get pi :model))
    (should (equal (plist-get pi :environment)
                   #'agent-org-pi-environment))))

(ert-deftest test-agent-org-dsh-provider-present ()
  "DSH (DeepSeek Harness) serves ACP as a PROFILE, not a flag or bin.
apps/cli/README (deepseek-ai/deepseek-harness) lists
\"`dsh --profile acp' — Serve automation clients over ACP stdio until
disconnect\", and states \"SDK and ACP are profiles, not separate public
bins\" — so `dsh acp' would be an invented shape.  It advertises the
`model' config option (session/set_config_option), so a pin is possible
but the harness default route is the honest start.
Confirmed against the LIVE server in this image (2026-10-28, an
`initialize' over stdin): agentInfo \"deepseek-harness-acp\",
sessionCapabilities (close, list, resume) and NO loadSession key at all —
which is exactly what `agent-org--supports-load-p' reads via
`map-nested-elt', so the absent key and a nil value take the same branch."
  (let ((dsh (agent-org--provider-spec 'dsh)))
    (should (equal (plist-get dsh :name) "DSH"))
    (should (equal (plist-get dsh :command) '("dsh" "--profile" "acp")))
    (should-not (plist-get dsh :model))
    (should (equal (plist-get dsh :environment)
                   #'agent-org-dsh-environment))))

(ert-deftest test-agent-org-every-harness-body-is-a-provider ()
  "The agent-team-ci harness image is the roster this package must cover.
ci/docker/harness/Dockerfile installs each body and FATAL-checks it with
`--version`; a body with no provider entry is an agent the team cannot
open from Emacs.  The roster below is transcribed from that Dockerfile
(Owner order 2026-10-28: 10 bodies baked, 7 supported) rather than read
from ci/ at run time, because the submodule is optional in a checkout
and the landing gate must not turn red over a missing `ci/' directory.
slave-agent is excluded: it is this package's own agent, never baked."
  (let ((harness-body-to-provider
         '(("opencode" . opencode) ("goose" . goose) ("qoder" . qoder)
           ("codebuddy" . codebuddy) ("pi" . pi) ("dsh" . dsh)
           ("mcode" . minimax) ("agent" . cursor) ("copilot" . copilot)
           ("omp" . omp)))
        (registered (mapcar (lambda (p) (plist-get p :id))
                            agent-org-providers)))
    (dolist (pair harness-body-to-provider)
      (should (plist-get (agent-org--provider-spec (cdr pair)) :id)))
    ;; ONE direction of parity only: an entry the harness does not bake is
    ;; fine (slave-agent is our own agent, Cline is a real ACP CLI that just
    ;; is not in the image), so never assert the total count — a future body
    ;; would break the suite for no reason.  What must never happen is a
    ;; baked body with no entry, and `set-difference' names it in the failure.
    (should (= 10 (length harness-body-to-provider)))
    (should (null (seq-difference (mapcar #'cdr harness-body-to-provider)
                                  registered)))))

(ert-deftest test-agent-org-harness-bodies-pass-only-what-they-need ()
  "Three credential stories, all pass-through-or-nothing (Secret Law).
Pi resolves its own provider keys and is configured outside Emacs, so
its function returns nil EVEN with keys in the environment: forwarding
them would make Emacs a second source of truth.  DSH keeps
$DSH_HOME/.credentials.yaml, so only DSH_HOME (the state dir this
session binds) and the documented DEEPSEEK_API_KEY fallback
(llm-deepseek-api-key: \"apiKeyEnv defaults to DEEPSEEK_API_KEY\") cross.
OMP resolves PI_* env names against its stored login; only the profile
selectors OMP_PROFILE / PI_CONFIG_DIR are forwarded, because an Emacs
chat legitimately chooses WHICH omp profile owns the session."
  ;; a blank is ABSENT, not a value: forwarding "VAR=" would override the
  ;; agent's own credential resolution with nothing
  (let ((process-environment '("DEEPSEEK_API_KEY=" "DSH_HOME="
                                "OMP_PROFILE=" "PI_CONFIG_DIR=")))
    (should-not (agent-org-pi-environment))
    (should-not (agent-org-dsh-environment))
    (should-not (agent-org-omp-environment)))
  (let ((process-environment '("PI_ANTHROPIC_API_KEY=whatever"
                                "MINIMAX_API_KEY=whatever"
                                "PI_SLOW_MODEL=anthropic/x")))
    (should-not (agent-org-pi-environment)))
  (let ((process-environment '("DSH_HOME=/tmp/dsh-profile"
                                "DEEPSEEK_API_KEY=sk-deep")))
    (should (equal (agent-org-dsh-environment)
                   '("DSH_HOME=/tmp/dsh-profile"
                     "DEEPSEEK_API_KEY=sk-deep"))))
  (let ((process-environment '("OMP_PROFILE=ci" "PI_CONFIG_DIR=/tmp/omp")))
    (should (equal (agent-org-omp-environment)
                   '("OMP_PROFILE=ci" "PI_CONFIG_DIR=/tmp/omp")))))

(ert-deftest test-agent-org-omp-pi-dsh-start-open-themselves ()
  "Each new entry point opens ITS OWN session, not a copy-pasted id.
The drift test proves an `agent-org-<id>-start-agent' exists per
registered id; this proves the id baked into the call is the right one."
  (ao--capture-wire
    (dolist (pair '((omp . agent-org-omp-start-agent)
                    (pi . agent-org-pi-start-agent)
                    (dsh . agent-org-dsh-start-agent)))
      (let ((buf (funcall (cdr pair))))
        (should (buffer-live-p buf))
        (should (eq (car pair)
                    (plist-get (agent-org--session-for-buffer buf) :name)))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-unloadable-provider-starts-fresh-not-broken ()
  "A body that answers no session/load must not block starting a chat.
packages/acp/acp/README: DSH omits `session/load' from its automation
surface (list, resume and close only), and the pi-acp adapter keeps its
own mapping file rather than the harness history.  So `agent-org-start'
degrades to `session/new' at the capability gate (agent-org.el:1362) and
`agent-org-resume-session' reports the missing support instead of
hanging on a request that will never answer."
  (should-not (agent-org--supports-load-p
               `((agentCapabilities . ((loadSession . nil))))))
  (should (agent-org--supports-load-p
           `((agentCapabilities . ((loadSession . t))))))
  ;; `loadSession' is a boolean, so truthiness is right THERE, but the
  ;; session-capability map names each support with an EMPTY object, so
  ;; `agent-org--lists-sessions-p' must test presence with `assq' — an
  ;; advertised `list' would read false under a truthiness rule.
  (should (agent-org--lists-sessions-p
           '((agentCapabilities . ((sessionCapabilities . ((list . ()))))))))
  (should-not (agent-org--lists-sessions-p
               '((agentCapabilities . ((sessionCapabilities . ())))))))

(ert-deftest test-agent-org-resume-on-no-load-body-reports-by-name ()
  "DSH is the first wired body that really walks the no-`session/load' path.
Measured IN the harness image (dsh 0.2.1-rc.2, `@deepseek-ai/dsh-acp'
README): the automation surface answers `session/list', `session/resume'
and `session/close', and `session/load', modes, commands, plans,
terminals and client filesystem operations are `omitted or rejected'.
Before WO-16 that branch of `agent-org-resume-session' was theory, so pin
its user-facing half (agent-org.el:1600): the header line names the
provider, and NO list/load request goes out to an agent that cannot
answer it — a hanging request is how a resume used to eat the buffer."
  (ao--capture-wire
    (let ((buf (agent-org-resume-session 'dsh "s-1")))
      (ao--drive "initialize" '((agentCapabilities . ((loadSession . nil)))))
      (let ((status (buffer-local-value 'agent-org-buffer--status buf)))
        (should (eq 'error (plist-get status :state)))
        (should (equal "DSH does not support session/load"
                       (plist-get status :message))))
      (should-not (ao--sent-get "session/list"))
      (should-not (ao--sent-get "session/load"))
      (kill-buffer buf))))

;;;; Buffer creation

(defconst ao--name-dir "/tmp/ao-proj/"
  "Fixed `default-directory' for the buffer-name tests.
A name carries the project — the last directory component of the cwd the
buffer was created in — so tests that assert an exact name bind this
instead of inheriting whatever directory the suite was launched
from.  The directory need not exist: nothing here touches the disk.")

(ert-deftest test-agent-org-buffer-create ()
  "Creates an org-mode buffer with agent-org-mode, typeable, and status."
  (let ((default-directory ao--name-dir))
    (let ((buf (agent-org-buffer-create "test")))
      (with-current-buffer buf
        (should buf)
        (should (buffer-live-p buf))
        (should (string-prefix-p "test:ao-proj" (buffer-name buf)))
        (should (derived-mode-p 'org-mode))
        (should-not buffer-read-only)
        (should-not (bound-and-true-p cursor-intangible-mode))
        (should (bound-and-true-p agent-org-mode))
        (should (equal (plist-get agent-org-buffer--status :state) 'starting))
        (should header-line-format))
      (kill-buffer buf))))

;;;; Buffer names: <agent>:<project> [id]

(ert-deftest test-agent-org-buffer-name-carries-project ()
  "The agent's name leads, and the project follows the colon.
`Qoder:agent-org [sid]' is the shape the user asked for by name: the
harness first, because that is what a person scans for, and the last
directory component of the cwd after the colon, because that is what
tells a chat of ~/proj-a from a chat of ~/proj-b (measured live: two
sessions in two projects produced two switcher rows identical but for
their UUIDs until the project entered the name).  The creation name
already wears both — a buffer is findable from the handshake, not only
after the agent answers."
  (let ((default-directory ao--name-dir))
    (let ((buf (agent-org-buffer-create "qoder")))
      (should (string-prefix-p "qoder:ao-proj" (buffer-name buf)))
      (agent-org-buffer-set-status buf :session-id "sid-prj")
      (should (equal "qoder:ao-proj [sid-prj]" (buffer-name buf)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-buffer-name-wears-the-agent-not-the-title ()
  "A session title never enters the buffer name.
`Qoder' says which harness answers; the agent's own title says what the
chat is ABOUT, and the user asked for the first: \"Buffer names are
showing session names in place of agent names.\"  The title is not lost —
it is the `#+TITLE:' of the buffer and of its transcript — it just is not
the buffer's name.  (This fixture's agent reports \"Initial Session
Title\" on `session/new', which used to rename the buffer.)"
  (let ((default-directory ao--name-dir))
    (let* ((pair (ao--make-test-session "nametest"))
           (buf (car pair))
           (session (cdr pair)))
      (setf (plist-get session :session-id) nil)
      (agent-org--session-ready session "sid-x" (ao--fake-session-new-resp))
      (should (equal "nametest:ao-proj [sid-x]" (buffer-name buf)))
      (should (equal "Initial Session Title"
                     (plist-get (buffer-local-value 'agent-org-buffer--status buf)
                                :title)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-buffer-name-wears-the-provider-with-no-title ()
  "A session whose agent titles nothing is named the same as one that did.
There is no fallback any more: the provider is the name, so the two cases
cannot diverge — which is what makes an agent that never sends
`session_info_update' (goose) read like one that does."
  (let ((default-directory ao--name-dir))
    (let ((buf (agent-org-buffer-create "standin")))
      (agent-org-buffer-set-status buf :session-id "sid-9")
      (should (equal "standin:ao-proj [sid-9]" (buffer-name buf)))
      (agent-org-buffer-set-status buf :title "Something the agent wrote")
      (should (equal "standin:ao-proj [sid-9]" (buffer-name buf)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-buffer-name-ignores-a-late-title ()
  "A title arriving mid-conversation does not rename the buffer.
qoder titles a session after the first turn, and a chat whose name changes
under the user mid-read is worse than a name that never described the
topic: `C-x b' windows, isearch and a window's `buffer-name' in a mode
line all follow the buffer, not the session."
  (let ((default-directory ao--name-dir))
    (let* ((pair (ao--make-test-session "latetitle"))
           (buf (car pair)))
      (agent-org-buffer-set-status buf :session-id "sid-l")
      (should (equal "latetitle:ao-proj [sid-l]" (buffer-name buf)))
      (agent-org-buffer-set-status buf :title "Refactor the parser")
      (should (equal "latetitle:ao-proj [sid-l]" (buffer-name buf)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-buffer-name-keeps-a-multiline-title-out ()
  "Agent free text cannot reach the name at all, so it cannot break it.
The name used to be built from a title and needed the one-line label
filter to survive it; now no agent text enters the name, which is the
stronger guarantee — a 200-character title with newlines in it leaves the
name exactly as the provider and project made it.  The filter still
matters for `#+TITLE:' and the turn heading, which DO carry agent text."
  (let ((default-directory ao--name-dir))
    (let ((buf (agent-org-buffer-create "multiline"))
          (long (concat "First line\n" (make-string 200 ?x) "\ntrailing")))
      (agent-org-buffer-set-status buf :session-id "sid-m" :title long)
      (with-current-buffer buf
        (should-not (string-match-p "\n" (buffer-name)))
        (should (equal "multiline:ao-proj [sid-m]" (buffer-name))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-buffer-name-does-not-accumulate-suffixes ()
  "Re-announcing the same facts is not a rename.
`generate-new-buffer-name' counts OUR OWN buffer when it already wears
that name, so an unconditional rename would walk
`Qoder:agent-org [s]<2><3><4>' over a session's lifetime — every status
update, of which a turn sends dozens."
  (let ((default-directory ao--name-dir))
    (let* ((pair (ao--make-test-session "churn"))
           (buf (car pair)))
      (dotimes (_ 5)
        (agent-org-buffer-set-status buf :session-id "sid-c"
          :title "Same Title")
        (agent-org-buffer-set-status buf :used 100 :size 200 :state 'streaming)
        (agent-org-buffer-set-status buf :state 'ready))
      (should (equal "churn:ao-proj [sid-c]" (buffer-name buf)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-buffer-names-stay-unique-per-session ()
  "Two chats of one harness in one project: the id separates them.
Same provider, same project, so before an id exists the wanted name
collides — and a collision must produce a live, distinct buffer rather
than clobbering the other.  Once both ids are in, the names are exact
again, which is the point of putting the id in the name."
  (let ((default-directory ao--name-dir))
    (let* ((a (ao--make-test-session "qoder"))
           (b (ao--make-test-session "qoder"))
           (bufa (car a))
           (bufb (car b)))
      ;; created in the same project with the same provider: the second
      ;; wanted name is taken, so it is uniquified, and it stays alive
      (should (equal "qoder:ao-proj" (buffer-name bufa)))
      (should (equal "qoder:ao-proj<2>" (buffer-name bufb)))
      (agent-org-buffer-set-status bufa :session-id "sid-1")
      (agent-org-buffer-set-status bufb :session-id "sid-2")
      (should (equal "qoder:ao-proj [sid-1]" (buffer-name bufa)))
      (should (equal "qoder:ao-proj [sid-2]" (buffer-name bufb)))
      (kill-buffer bufa)
      (kill-buffer bufb))))

(ert-deftest test-agent-org-buffer-name-wears-no-star-delimiters ()
  "The name is the chat, not an internal Emacs buffer.
`*agent-org: …*' is the Emacs convention for a buffer that is not a file,
but it is noise in `C-x b', in the switcher and in a mode line that
repeats it, and the user's asked-for shape has no delimiters in it.  So
nothing in the name is decorative: no leading `agent-org: ', no stars."
  (let ((default-directory ao--name-dir))
    (let ((buf (agent-org-buffer-create "plain")))
      (should-not (string-match-p "\\*" (buffer-name buf)))
      (should-not (string-prefix-p "agent-org" (buffer-name buf)))
      (kill-buffer buf))))

;;;; Session registry

(ert-deftest test-agent-org--session-for-buffer ()
  "Returns session plist for the registered buffer."
  (let* ((buf (agent-org-buffer-create "registry-test"))
         (entry (list :name 'test :client nil :buffer buf :session-id nil :streaming nil)))
    (agent-org--register-session entry)
    (should (eq (plist-get (agent-org--session-for-buffer buf) :buffer) buf))
    (kill-buffer buf)))

;;;; Header-line status (the "top bar")

(ert-deftest test-agent-org-status-never-pollutes-buffer ()
  "Status updates change the header line; the session id lands in the body.
The id used to ride the header-line `[sid]' segment; it now belongs to
the document as a `:ID:' property in the top PROPERTIES drawer, so the
top bar stays a status bar and the id is copyable/readable in the
transcript.  The header must not repeat it."
  (let ((buf (agent-org-buffer-create "status")))
    (agent-org-buffer-set-status buf :state 'ready :message "Ready" :session-id "abc123")
    (agent-org-buffer-refresh-metadata buf)
    (with-current-buffer buf
      ;; the id lands in the body as a drawer property
      (should (string-match-p "^:ID: abc123$" (buffer-string)))
      (should-not (string-match-p "^\\* " (buffer-string)))
      (should-not (string-match-p "System" (buffer-string)))
      (should-not (string-match-p "begin_comment" (buffer-string)))
      ;; status is reflected in the header-line model
      (should (equal (plist-get agent-org-buffer--status :state) 'ready))
      (should (equal (plist-get agent-org-buffer--status :session-id) "abc123"))
      ;; but the header line no longer carries the id
      (let ((rendered (agent-org-buffer--render-header-line)))
        (should (string-match-p "Ready" rendered))
        (should-not (string-match-p "abc123" rendered))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-status-error-renders-error-label ()
  "An error state renders an Error label in the header line."
  (let ((buf (agent-org-buffer-create "err")))
    (agent-org-buffer-set-status buf :state 'error :message "boom")
    (with-current-buffer buf
      (should (string-match-p "Error" (agent-org-buffer--render-header-line)))
      (should (string-match-p "boom" (agent-org-buffer--render-header-line))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-status-note-rides-the-ready-label ()
  "`:note' is the one thing allowed to qualify a Ready state.  A bare
`:message' cannot do the job: for `starting'/`ready' the segment renders
the state LABEL and nothing else (CONVENTIONS.md §6), which is why a
listing that timed out was reported only in the echo area and read as
\"the prompt never happens\".  The note rides AFTER the label, so the
state stays readable, and it is still exactly one segment."
  (let ((buf (agent-org-buffer-create "note")))
    (with-current-buffer buf
      (agent-org-buffer-set-status buf :state 'ready)
      (should (equal "Ready" (car (agent-org-buffer--status-segment
                                   agent-org-buffer--status))))
      (agent-org-buffer-set-status buf :note "new session (listing timed out)")
      (let ((segment (car (agent-org-buffer--status-segment
                           agent-org-buffer--status))))
        (should (string-prefix-p "Ready" segment))
        (should (string-match-p "listing timed out" segment))
        ;; one segment, one line
        (should-not (string-match-p "\n" segment)))
      ;; an error still wins: a note must not dilute a real failure
      (agent-org-buffer-set-status buf :state 'error :message "boom")
      (should (equal "Error: boom" (car (agent-org-buffer--status-segment
                                         agent-org-buffer--status))))
      ;; and the note is gone once cleared, not left as trailing noise
      (agent-org-buffer-set-status buf :state 'ready :note nil)
      (should (equal "Ready" (car (agent-org-buffer--status-segment
                                   agent-org-buffer--status)))))
    (kill-buffer buf)))

;;;; Streaming (the hot path)

(ert-deftest test-agent-org-buffer-streaming-lifecycle ()
  "Append-chunk starts an Agent turn; end-turn clears the streaming flag.
The streaming contract is LINE-granular and append-only: a chunk still
arriving (no newline yet) is held in `--md-fragment' and never written, and
the line lands flush under the answer prefix the instant its newline
arrives.  (The quote-block era wrote every chunk raw the moment it came,
which is what made the buffer hold each line twice once conversion joined.)"
  (let* ((buf (agent-org-buffer-create "stream"))
         (session (list :name 'test :buffer buf)))
    (with-current-buffer buf
      (should-not agent-org-buffer--streaming-p))
    (agent-org-buffer-append-chunk buf "Hello " session)
    (with-current-buffer buf
      (should agent-org-buffer--streaming-p)
      (should (string-match-p "\\* Agent" (buffer-string)))
      ;; still arriving: no newline, so nothing has landed in the body yet
      (should-not (string-match-p "Hello" (buffer-string))))
    (agent-org-buffer-append-chunk buf "world\n" session)
    (with-current-buffer buf
      ;; the joined line is finished now, and it is appended flush — one space
      ;; of indent was the quote-block body rule, not the prefix rule
      (should (string-match-p "^Hello world$" (buffer-string))))
    (agent-org-buffer-end-agent-turn buf)
    (with-current-buffer buf
      (should-not agent-org-buffer--streaming-p))
    (kill-buffer buf)))

;;;; Notification dispatch (single, non-recursive handler)

(ert-deftest test-agent-org-on-notification-routes-status-not-buffer ()
  "Message chunks go to the body; lifecycle goes to the header line."
  (let* ((buf (agent-org-buffer-create "dispatch"))
         (session (list :name 'test :client nil :buffer buf
                        :session-id nil :streaming t)))
    ;; agent message chunk -> body + streaming status.  The line carries its
    ;; newline so it is FINISHED: a chunk still arriving is held by the
    ;; line-granular converter and would not have landed yet (see
    ;; `test-agent-org-buffer-streaming-lifecycle').
    (agent-org--on-notification
     session
     `((method . "session/update")
       (params . ((update . ((sessionUpdate . "agent_message_chunk")
                             (content . ((type . "text") (text . "hi there\n")))))))))
    (with-current-buffer buf
      (should (string-match-p "hi there" (buffer-string)))
      (should (equal (plist-get agent-org-buffer--status :state) 'streaming))
      ;; no diagnostic text ever lands in the body
      (should-not (string-match-p "ACP error" (buffer-string)))
      (should-not (string-match-p "Session started" (buffer-string))))
    ;; session_info_update -> ready status + session id captured; the only
    ;; body addition is the auto-managed top metadata block
    (agent-org--on-notification
     session
     `((method . "session/update")
       (params . ((sessionId . "sess-9")
                  (update . ((sessionUpdate . "session_info_update")))))))
    (with-current-buffer buf
      (should (equal (plist-get session :session-id) "sess-9"))
      (should (equal (plist-get agent-org-buffer--status :state) 'ready))
      (should (string-match-p ":ID: +sess-9" (buffer-string)))
      ;; no status labels ever land in the body
      (should-not (string-match-p "Ready\\|Starting\\|Connecting" (buffer-string))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-on-notification-is-not-recursive ()
  "The dispatcher handles a notification exactly once (no self-recursion)."
  (let* ((buf (agent-org-buffer-create "recur"))
         (session (list :name 'test :client nil :buffer buf
                        :session-id nil :streaming t))
         (calls 0))
    (cl-letf (((symbol-function 'agent-org-buffer-append-chunk)
               (lambda (&rest _) (cl-incf calls))))
      (agent-org--on-notification
       session
       `((method . "session/update")
         (params . ((update . ((sessionUpdate . "agent_message_chunk")
                               (content . ((text . "x"))))))))))
    (should (= calls 1))
    (kill-buffer buf)))

(ert-deftest test-agent-org-idle-session-drops-agent-content ()
  "Without a live prompt (session :streaming nil), chunk/thought/tool
updates never touch the body: a fresh session cannot fill itself with
Agent turns, thinking or tool calls nobody asked for."
  (let* ((buf (agent-org-buffer-create "idle"))
         (session (list :name 'test :client nil :buffer buf :session-id nil)))
    (dolist (update (list
                     '((sessionUpdate . "agent_message_chunk")
                       (content . ((type . "text") (text . "unasked"))))
                     '((sessionUpdate . "agent_thought_chunk")
                       (content . ((type . "text") (text . "Thinking..."))))
                     '((sessionUpdate . "tool_call")
                       (toolCallId . "tcX") (title . "shell"))))
      (agent-org--on-notification
       session `((method . "session/update")
                 (params ((update . ,update))))))
    (with-current-buffer buf
      (should-not (string-match-p "Agent\\|:thinking:\\|unasked\\|Thinking\\|shell"
                                  (buffer-string))))
    (kill-buffer buf)))

;;;; Thought chunks

(ert-deftest test-agent-org-streaming-never-toggles-font-lock ()
  "A streaming turn must not switch `font-lock-mode' off and back on.
The old per-turn toggle blanked every Org color while a turn ran and
re-rendered the whole buffer on finish.  Font-lock now stays as the user
set it: the value is identical before and after a full streamed turn, so
colors never vanish mid-turn.  In batch font-lock is off, so this cannot
assert it turns *on* -- the invariant is that we never touch it."
  (let ((buf (agent-org-buffer-create "flive")))
    (let ((before (with-current-buffer buf font-lock-mode)))
      (agent-org-buffer-start-agent-turn buf nil)
      (with-current-buffer buf
        (should (eq font-lock-mode before)))
      (agent-org-buffer-append-chunk buf "some answer" nil)
      (with-current-buffer buf
        (should (eq font-lock-mode before)))
      (agent-org-buffer-end-agent-turn buf)
      (with-current-buffer buf
        (should (eq font-lock-mode before))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-buffer-thought ()
  "Thought chunks are written into a single well-formed :thinking: drawer."
  (let ((buf (agent-org-buffer-create "think")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-thought buf "reasoning one")
    (agent-org-buffer-append-thought buf "reasoning two")
    (with-current-buffer buf
      (should (string-match-p ":thinking:" (buffer-string)))
      (should (string-match-p "reasoning one" (buffer-string)))
      (should (string-match-p "reasoning two" (buffer-string)))
      ;; exactly one closing marker despite two appends
      (goto-char (point-min))
      (let ((n 0))
        (while (search-forward ":end:" nil t) (cl-incf n))
        (should (= n 1))))
    (kill-buffer buf)))

;;;; Tool calls in a :tool: drawer

(ert-deftest test-agent-org-buffer-tool-insert ()
  "A tool call is one line of the turn's `:tool:` drawer.
Status maps POSITIONALLY onto the tool keyword set (the unfinished words take
pending then in_progress, the done words take completed then failed), and the
keyword is the line's first word so the state reads the same here as it did on a
heading.  With the set the user ordered -- `RUNNING | EXECUTED FAILED' -- both
running states read RUNNING.  User orders: \"Tool calls should be inside :tool:
drawers.\", then \"RUNNING | EXECUTED\" for tool calls.
Org forbids headlines inside drawers (info \"(org) Drawers\"), so the
calls became DRAWER LINES, and the turn's headings belong to the
conversation alone: `**' is gone."
  (let ((buf (agent-org-buffer-create "tool")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool buf '((title . "read_file")
                                        (toolCallId . "tc1")
                                        (status . "in_progress")))
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (string-match-p "^  - RUNNING read_file$" text))
      (should (string-match-p "^:tool:$" text))
      (should (= 1 (ao--count-occurrences text "^:tool:$")))
      (should-not (string-match-p "^\\*\\* " text))
      ;; under the Agent heading, and closed: marker, line, :end:
      (should (apply #'ao--ordered text
                     (list "* Agent" ":tool:" "  - RUNNING read_file" ":end:"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-line-drops-raw-id ()
  "The visible line carries keyword and title only, never the id.
`toolCallId' is the agent's bookkeeping: the update finds its entry in
`agent-org-buffer--tools' under that id, so printing the id on the line
only adds wire noise a reader never asked for (the user's complaint:
tool-call ids should be stripped).  Nothing on disk or in the buffer may
still carry it after an update redraws the drawer."
  (let ((buf (agent-org-buffer-create "toohide")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool buf '((title . "shell")
                                        (toolCallId . "tc-hide-1")
                                        (status . "pending")))
    (agent-org-buffer-insert-tool buf '((toolCallId . "tc-hide-1")
                                        (status . "completed")))
    (let ((text (with-current-buffer buf (buffer-string))))
      (should-not (string-match-p "tc-hide-1" text))
      (should (string-match-p "^  - EXECUTED shell$" text))
      ;; the redraw replaced the line rather than adding one
      (should (= 1 (ao--count-occurrences text "^  - "))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-updates-rewrite-their-line-in-place ()
  "tool_call_update for a known id rewrites its line's keyword/title;
new ids append their own line, in the order the agent made the calls."
  (let ((buf (agent-org-buffer-create "toolup")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool buf '((title . "shell") (toolCallId . "tc1")
                                        (status . "pending")))
    (should (with-current-buffer buf
              (string-match-p "^  - RUNNING shell$" (buffer-string))))
    ;; update without a title must not downgrade it to "tool"
    (agent-org-buffer-insert-tool buf '((toolCallId . "tc1") (status . "completed")))
    (agent-org-buffer-insert-tool buf '((toolCallId . "tc2")))
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (= 2 (ao--count-occurrences text "^  - ")))
      (should (= 1 (ao--count-occurrences text "^  - EXECUTED shell$")))
      (should-not (string-match-p "TODO shell" text))
      (should (string-match-p "^  - RUNNING tool$" text))
      (should (apply #'ao--ordered text (list "  - EXECUTED shell" "  - RUNNING tool"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-line-flattens-multiline-title ()
  "A tool title is agent text, never a line of its own.  Live qoder
replays shell calls whose title is the whole command: several lines,
hundreds of characters.  Verbatim, one drawer entry would become several
lines and the redraw could not tell them from calls it did not make.  So
the label is flattened and truncated; the id in `agent-org-buffer--tools'
still tells two calls apart."
  (let ((buf (agent-org-buffer-create "toollong"))
        (long (concat "ls -la\n" (make-string 300 ?x) "\nsecond line")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool buf `((title . ,long)
                                        (toolCallId . "tc1")
                                        (status . "pending")))
    (agent-org-buffer-insert-tool buf '((title . "probe")
                                        (toolCallId . "tc2")
                                        (status . "pending")))
    (with-current-buffer buf
      ;; exactly ONE heading in the turn -- the Agent heading -- and two
      ;; drawer lines: nothing spilled out of the line it belongs to
      (should (= 1 (ao--count-occurrences (buffer-string) "^\\*+ ")))
      (should (= 2 (ao--count-occurrences (buffer-string) "^  - ")))
      (should (string-match-p "^  - RUNNING ls -la" (buffer-string)))
      (should-not (string-match-p "^second line$" (buffer-string)))
      ;; cut, not merely re-wrapped
      (should-not (string-match-p (make-string 300 ?x) (buffer-string))))
    ;; and the pending→done rewrite still replaces one clean line
    (agent-org-buffer-insert-tool buf '((toolCallId . "tc1")
                                        (status . "completed")))
    (with-current-buffer buf
      (should (= 1 (ao--count-occurrences (buffer-string) "^\\*+ ")))
      (should (= 2 (ao--count-occurrences (buffer-string) "^  - ")))
      (should (string-match-p "^  - EXECUTED ls -la" (buffer-string)))
      (should-not (string-match-p "TODO ls" (buffer-string))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-drawer-survives-later-thought-chunk ()
  "A thought arriving AFTER a tool call re-renders the whole
:thinking: drawer, and must not delete the turn's tool lines with it.
Live qoder thinks between tool calls, so this is the normal streaming
shape of a turn — and the reason the two drawers are drawn by the same
redraw primitive, bounded to the turn, rather than by a marker per call
(the old bug: a heading placed at a drawer match's END landed INSIDE the
drawer, and the next thought chunk erased every call but the last)."
  (let ((buf (agent-org-buffer-create "toolthought")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool buf '((toolCallId . "tc1") (title . "one")
                                        (status . "pending")))
    (agent-org-buffer-append-thought buf "thinking\n")
    (agent-org-buffer-insert-tool buf '((toolCallId . "tc2") (title . "two")
                                        (status . "in_progress")))
    (agent-org-buffer-append-thought buf "more thinking\n")
    (agent-org-buffer-insert-tool buf '((toolCallId . "tc2") (title . "two")
                                        (status . "completed")))
    (agent-org-buffer-append-thought buf "end of it\n")
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (= 2 (ao--count-occurrences text "^  - ")))
      (should (= 1 (ao--count-occurrences text "^:tool:$")))
      (should (= 1 (ao--count-occurrences text "^:thinking:$")))
      (should (string-match-p "^  - RUNNING one$" text))
      (should (string-match-p "^  - EXECUTED two$" text))
      ;; the thought drawer still holds every chunk, in order
      (should (apply #'ao--ordered text
                     (list "thinking" "more thinking" "end of it"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-drawer-is-open-and-thinking-folded ()
  "Progress is visible; thinking is not.
A folded tool drawer is a chat that looks idle while the agent shells and
edits, which is the one thing a user wants to see.  Extended thinking is
the opposite: long, and noise.  So the same redraw primitive takes the
fold choice per drawer, and the two differ."
  (let ((buf (agent-org-buffer-create "toolfold")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool buf '((toolCallId . "tc1") (title . "shell")
                                        (status . "pending")))
    (agent-org-buffer-append-thought buf "a very long thought\n")
    (with-current-buffer buf
      (should-not (invisible-p
                   (save-excursion (goto-char (point-min))
                                   (re-search-forward "^  - RUNNING shell$")
                                   (point))))
      (should (invisible-p
               (save-excursion (goto-char (point-min))
                               (re-search-forward "^ a very long thought$")
                               (point)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-chat-buffer-refuses-orgs-startup-drawer-fold ()
  "Org's startup fold is off in a chat: WE decide which drawer is open.
`org-cycle-set-startup-visibility' -- what `org-mode' runs and what
`C-c C-k' with a prefix runs -- ends with
`(when org-cycle-hide-drawer-startup (org-cycle-hide-drawers (quote all)))'
(org-cycle.el:643), so one visibility cycle re-folds every board the
package just opened.  A default that an unrelated subsystem can take away
is not a default, so the variable goes buffer-local NIL here and stays t
for every other Org buffer."
  (let ((buf (agent-org-buffer-create "startfold")))
    (with-current-buffer buf
      (should-not org-hide-drawer-startup)
      (should (default-value 'org-hide-drawer-startup)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-board-opens-when-the-agent-adds-to-it ()
  "A board the agent is still writing to is never left collapsed.
Org re-hides drawers in the paths that are not gated by
`org-hide-drawer-startup' (a subtree move runs
`org-clean-visibility-after-subtree-move', org.el:7089), and any of them
can fold a turn's board behind the user.  The next tool update expands it:
the board is the live activity view, so a fold that is not the user's own
TAB on the heading does not survive new activity.  A `:thinking:' drawer
keeps the fold it has, because the package never re-folds what the user
opened.

WHICH board is opened is the newer half of the rule: the thought between the
two calls seals the first one (`agent-org-buffer--seal-tool-board'), so the
second call opens a NEW drawer at the end of the turn and the sealed one stays
folded.  Expanding live activity and preserving history are both wanted, and
with two boards they are no longer the same board."
  (let ((buf (agent-org-buffer-create "reopen")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool buf '((toolCallId . "tc1") (title . "shell")
                                         (status . "completed")))
    (agent-org-buffer-append-thought buf "a long thought\n")
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (org-cycle-hide-drawers 'all))
      ;; the premise: Org really did fold this turn's drawers
      (should (invisible-p (save-excursion (goto-char (point-min))
                                           (re-search-forward "^  - EXECUTED shell$")
                                           (point))))
      (agent-org-buffer-insert-tool buf '((toolCallId . "tc2") (title . "tree")
                                          (status . "pending")))
      ;; the live board is open again: this call is what the agent is doing now
      (should-not (invisible-p (save-excursion (goto-char (point-min))
                                               (re-search-forward "^  - RUNNING tree$")
                                               (point))))
      ;; the sealed board keeps the fold it was given -- it is history now, and
      ;; a user who wants it back presses TAB on it like any other drawer
      (should (invisible-p (save-excursion (goto-char (point-min))
                                           (re-search-forward "^  - EXECUTED shell$")
                                           (point))))
      (should (= 2 (ao--count-occurrences (buffer-string) "^:tool:$")))
      ;; thinking is not the activity view: the fold it was given stays
      (should (invisible-p (save-excursion (goto-char (point-min))
                                           (re-search-forward "^ a long thought$")
                                           (point)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-state-resets-per-turn ()
  "A new Agent turn gets its own drawer; old ids re-appear fresh."
  (let ((buf (agent-org-buffer-create "toolturn")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool buf '((title . "shell") (toolCallId . "tcA")))
    (agent-org-buffer-end-agent-turn buf)
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool buf '((title . "tree") (toolCallId . "tcB")))
    ;; a reused id (harness may echo an old call) must not merge into
    ;; the previous turn's drawer
    (agent-org-buffer-insert-tool buf '((title . "shell") (toolCallId . "tcA")
                                        (status . "completed")))
    (with-current-buffer buf
      (should (= 2 (ao--count-occurrences (buffer-string) "^:tool:$")))
      ;; the lines carry no number, so what separates the two turns' `shell'
      ;; calls is their keyword -- and each turn owns its own drawer
      (should (= 1 (ao--count-occurrences (buffer-string) "^  - RUNNING shell$")))
      (should (= 1 (ao--count-occurrences (buffer-string) "^  - EXECUTED shell$")))
      (should (= 1 (ao--count-occurrences (buffer-string) "^  - RUNNING tree$")))
      ;; a merged turn would hold two lines, not three
      (should (= 3 (ao--count-occurrences (buffer-string) "^  - "))))
    (kill-buffer buf)))

;;;; Tool-call output, under its own line in the turn's ONE `:tool:' drawer

(defun ao--tool-text-block (text)
  "One ACP `content' item carrying TEXT, in the shape the wire sends.
The union is {type: \"content\", content: <ContentBlock>}, and a JSON
array parses to a VECTOR (`:object-type 'alist' turns objects into alists
of DOTTED pairs, arrays into nothing else), so a fixture with a list, or
with the inner block wrapped in one more pair of parens, tests a shape no
agent sends.  The same shape agent-shell's own tests pin."
  `((content . [((type . "content")
                 (content (type . "text") (text . ,text)))])))

(ert-deftest test-agent-org-tool-output-keeps-every-line-under-its-call ()
  "A multi-line result stays ONE item: every line at the content column.
User order: \"Tool call outputs belong to the same TODO headings.\"  The
board line and what the call printed are now the same item, so the indent is
the only thing that keeps line two from being read as line one's successor
call -- four columns, which is the item's content column this drawer uses
(`test-agent-org-tool-drawer-is-one-list-to-org' asks the parser about it).
A body line at column 2 would be a NEW item of the list, not a continuation."
  (let ((buf (agent-org-buffer-create "out1")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "tc1") (title . "shell") (status . "completed")
           ,@(ao--tool-text-block "total 42\ndrwxr-xr-x  khalid")))
    (let ((text (with-current-buffer buf (buffer-string))))
      ;; the status line reads keyword + title, and nothing numbers it
      (should (string-match-p "^  - EXECUTED shell$" text))
      (should (string-match-p "^    total 42$" text))
      (should (string-match-p "^    drwxr-xr-x  khalid$" text))
      ;; marker, item, body, closer -- all of it INSIDE the one drawer
      (should (apply #'ao--ordered text
                     (list ":tool:" "  - EXECUTED shell" "    total 42"
                           "    drwxr-xr-x  khalid" ":END:"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-board-lines-carry-no-number ()
  "Nothing on a tool line is a number: `- KEYWORD TITLE', full stop.
The `N.' existed only as the index into a per-call output drawer, and with
one drawer whose items ARE the calls an index is meaningless -- a call is
named by its title, and its output is right under it.
A number would also be a lie after a resume: replay rebuilds the record from
the updates the agent sends, and nothing guarantees the same count."
  (let ((buf (agent-org-buffer-create "ononum")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "tc1") (title . "one") (status . "pending")))
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "tc2") (title . "two") (status . "completed")))
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (= 1 (ao--count-occurrences text "^  - RUNNING one$")))
      (should (= 1 (ao--count-occurrences text "^  - EXECUTED two$")))
      (should-not (string-match-p "^- [A-Z]+ [0-9]+\\." text)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-output-falls-back-to-raw-output ()
  "No `content' blocks: `rawOutput.formatted_output' is the output.
Codex reports terminal output that way and leaves `content' empty, so
reading only the spec's field renders a completed shell call blank
(agent-shell does the same, for the same reason).  `rawOutput' itself is
agent-defined free JSON."
  (let ((buf (agent-org-buffer-create "outraw")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "tc1") (title . "ls") (status . "completed")
           (rawOutput . ((formatted_output . "stdout line\nstderr line\n")))))
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (= 1 (ao--count-occurrences text "^:tool:$")))
      (should (string-match-p "^    stdout line$" text))
      (should (string-match-p "^    stderr line$" text)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-output-ignores-a-non-string-raw-output ()
  "A `formatted_output' that is not text is no output at all.
`rawOutput' is whatever the agent felt like sending -- a number, an
object, a vector.  Printing `42' as if it were a shell result would be a
lie, and an item with an empty body is noise under a board that is meant to
be read at a glance, so the call gets its line and nothing else."
  (let ((buf (agent-org-buffer-create "outrawnum")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "tc1") (title . "ls") (status . "completed")
           (rawOutput . ((formatted_output . 42)))))
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (= 1 (ao--count-occurrences text "^  - EXECUTED ls$")))
      (should-not (string-match-p "^    " text))
      (should-not (string-match-p "42" text)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-output-names-a-block-it-cannot-render ()
  "Content we have no surface for is NAMED, never silently dropped.
agent-shell's rule, kept verbatim so a reader of either tool sees the same
hint: `[unsupported content: TYPE]'."
  (let ((buf (agent-org-buffer-create "outvid")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "tc1") (title . "screenshot") (status . "completed")
           (content . [((type . "content")
                        (content (type . "video") (uri . "file:///v.mp4")))])))
    (with-current-buffer buf
      (should (string-match-p "\\[unsupported content: video\\]"
                              (buffer-string))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-output-diff-block-shows-the-file-and-text ()
  "A `diff' block says which file and what it now holds.
ACP's second ToolCallContent shape is {type: \"diff\", path, newText}; an
agent editing a file reports the change this way, and \"edited
~/.bashrc\" with no body is the least useful sentence in the chat."
  (let ((buf (agent-org-buffer-create "outdiff")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "tc1") (title . "edit") (status . "completed")
           (content . [((type . "diff") (path . "/home/khalid/x.org")
                        (newText . "* new\n"))])))
    (with-current-buffer buf
      (let ((text (buffer-string)))
        (should (= 1 (ao--count-occurrences text "^:tool:$")))
        (should (string-match-p "^    diff /home/khalid/x.org$" text))
        (should (string-match-p "^    \\* new$" text))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-output-update-rewrites-its-body-in-place ()
  "A second update for the same call replaces its body, never adds one.
`tool_call_update' patches: the same id arrives again with a longer
output, then with the final one.  One call, one ITEM -- the rule the board
already followed for its line now covers the body too, because line and body
are the same item of the same drawer."
  (let ((buf (agent-org-buffer-create "outrepl")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "tc1") (title . "shell") (status . "in_progress")
           ,@(ao--tool-text-block "partial 42")))
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "tc1") (status . "completed")
           ,@(ao--tool-text-block "final 43")))
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (= 1 (ao--count-occurrences text "^:tool:$")))
      (should (= 1 (ao--count-occurrences text "^:end:$")))
      ;; the call is named ONCE, and it is a board line, not a second item
      (should (= 1 (ao--count-occurrences text "^  - EXECUTED shell$")))
      (should (= 1 (ao--count-occurrences text "^    final 43$")))
      (should-not (string-match-p "partial 42" text)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-output-travels-with-the-open-board ()
  "Output is visible, because it now shares the drawer that shows progress.
The bodies used to sit in a folded `:tool-output:' drawer -- agent-shell's
default (`agent-shell-tool-use-expand-by-default' nil) -- so that a turn of
six `cat's did not bury the reply.  Merging them into the board trades that
quiet for one place to read: ONE drawer, ONE fold state, and `:tool:' is
born OPEN because what the agent is doing now is what the user came to
watch.  The fold is still the affordance for a long body -- TAB on the turn,
and the whole board including its output folds away at once."
  (let ((buf (agent-org-buffer-create "outfold")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "tc1") (title . "shell") (status . "completed")
           ,@(ao--tool-text-block "a very long output")))
    (with-current-buffer buf
      (dolist (pattern (list "^  - EXECUTED shell$" "^    a very long output$"))
        (should-not (invisible-p
                     (save-excursion (goto-char (point-min))
                                     (re-search-forward pattern)
                                     (point))))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-output-cannot-break-the-drawer ()
  "Agent output is free text and may contain Org structure.  A line that
is `* heading' at column 0 ENDS the drawer for the parser (measured: the
whole `:tool:' drawer vanishes from `org-element-parse-buffer' and two
headlines appear), and a line that is `:END:' closes it early -- including
the lowercase and indented forms, which Org also accepts.  Tool output is
filed as-is in a drawer, and this agent reads Org files for a living, so
both shapes arrive routinely.  Hence: indent every line, and double the
colon of a bare `:END:'.  The body stays verbatim-readible, and the drawer
stays a drawer.  Since the output shares the BOARD with these lines, one more
escape rides on top of the guard's own space: the four-column indent that
makes the text an item's content rather than a sibling call."
  (let ((buf (agent-org-buffer-create "outhostile")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "tc1") (title . "read") (status . "completed")
           ,@(ao--tool-text-block
              "* a headline\nplain\n  :END:\n:PROPERTIES:\n:ID: x\n:END:")))
    (let ((text (with-current-buffer buf (buffer-string))))
      ;; one headline in the whole buffer: the turn's own
      (should (= 1 (ao--count-occurrences text "^\\*+ ")))
      (should (= 1 (ao--count-occurrences text "^:tool:$")))
      ;; the escaped forms, at the item's content column, plus the real closer
      (should (string-match-p "^    \\* a headline$" text))
      (should (string-match-p "^    ::END:$" text))
      ;; and the parser agrees: it sees the drawer, and no headline grew
      (with-current-buffer buf
        (let ((drawers nil) (heads 0))
          (org-element-map (org-element-parse-buffer) '(drawer headline)
            (lambda (e)
              (if (eq (car e) 'drawer)
                  (push (org-element-property :drawer-name e) drawers)
                (cl-incf heads))))
          (should (member "tool" drawers))
          (should (= 1 heads)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-thinking-drawer-survives-a-headline-line ()
  "The same guard covers `:thinking:', which has always had the hazard.
Extended thinking is markdown-flavoured prose: `* ' bullets and `:END:'
are normal characters in it.  One primitive protects every drawer the
stream writes, so a thought can no longer dissolve the drawer around it."
  (let ((buf (agent-org-buffer-create "thinhostile")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-thought buf "plan:\n* do this\n:END:\n")
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (= 1 (ao--count-occurrences text "^:thinking:$")))
      (should (= 1 (ao--count-occurrences text "^\\*+ ")))
      (should (string-match-p "^ ::END:$" text))
      (should (string-match-p "^ \\* do this$" text)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-output-skips-a-call-with-nothing-to-show ()
  "Every call gets a line; only calls that printed get a body.
Three calls, output on the third: the board has three items and exactly one
body line -- a call with nothing to say costs no blank indent, so the drawer
stays readable as a list of what happened rather than a list with holes."
  (let ((buf (agent-org-buffer-create "outnum")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool buf '((toolCallId . "a") (title . "one")
                                        (status . "pending")))
    (agent-org-buffer-insert-tool buf '((toolCallId . "b") (title . "two")
                                        (status . "pending")))
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "c") (title . "three") (status . "completed")
           ,@(ao--tool-text-block "third output")))
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (= 1 (ao--count-occurrences text "^:tool:$")))
      (should (= 1 (ao--count-occurrences text "^    \\S-")))
      (should (= 3 (ao--count-occurrences text "^  - ")))
      (should (string-match-p "^    third output$" text))
      (should (apply #'ao--ordered text
                     (list "  - RUNNING one" "  - RUNNING two" "  - EXECUTED three"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-output-is-this-turns-only ()
  "Each Agent turn owns its board, bodies included.
`agent-org-buffer--redraw-drawer' bounds its search to the current turn and
`agent-org-buffer--tools' is reset per turn, so turn two's output cannot
overwrite turn one's -- the per-turn reset
`test-agent-org-tool-state-resets-per-turn' pins for the lines, pinned here
for the bodies they carry, which now live in the same drawer and so need a
stronger check: two drawers, each holding its own turn's text."
  (let ((buf (agent-org-buffer-create "outturn")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "tcA") (title . "one") (status . "completed")
           ,@(ao--tool-text-block "first turn text")))
    (agent-org-buffer-end-agent-turn buf)
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "tcB") (title . "two") (status . "completed")
           ,@(ao--tool-text-block "second turn text")))
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (= 2 (ao--count-occurrences text "^:tool:$")))
      (should (= 2 (ao--count-occurrences text "^    \\S-")))
      (should (apply #'ao--ordered text
                     (list "  - EXECUTED one" "    first turn text"
                           "  - EXECUTED two" "    second turn text"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-call-with-no-content-gets-no-body ()
  "A call that never reports output costs the chat nothing.
`tool_call' arrives with a title and a status only -- the common case for
a call still running -- and its item is the one line.  An empty body would
be a blank indent under a keyword the reader is still waiting on."
  (let ((buf (agent-org-buffer-create "outnone")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool buf '((toolCallId . "tc1") (title . "ls")
                                        (status . "pending")))
    (agent-org-buffer-insert-tool buf '((toolCallId . "tc1") (status . "completed")))
    (with-current-buffer buf
      (let ((text (buffer-string)))
        (should (= 1 (ao--count-occurrences text "^:tool:$")))
        (should (= 1 (ao--count-occurrences text "^  - EXECUTED ls$")))
        (should-not (string-match-p "^    \\S-" text))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-output-sits-under-its-own-board-line ()
  "The output belongs to its call's TODO line, in the turn's ONE `:tool:' drawer.
The user's order, twice over: \"Tool call outputs belong to the same TODO
headings\", and before it \"Consecutive tool calls belong to a single
drawer.\"  A separate `:tool-output:' drawer was the first cut; it made a
reader scan the board then hunt the same title in a second drawer, and a
call's state and its result lived two places at once.  One drawer now holds
the line and, indented under it, what the call printed.  The list is
indented TWO columns and its body four, which is the shape the parser
accepts inside a drawer: measured with `org-element-parse-buffer' on a
buffer whose turn already has a headline, a col-0 item with a 2-column body
reported no list at all, while the indented form reports ONE plain-list with
two items and the drawer intact."
  (let ((buf (agent-org-buffer-create "join1")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "tc1") (title . "shell") (status . "completed")
           ,@(ao--tool-text-block "total 42")))
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (string-match-p "^  - EXECUTED shell$" text))
      (should (string-match-p "^    total 42$" text))
      ;; one drawer for both, and the second one is GONE
      (should (= 1 (ao--count-occurrences text "^:tool:$")))
      (should-not (string-match-p "^:tool-output:$" text))
      (should (apply #'ao--ordered text
                     (list ":tool:" "  - EXECUTED shell" "    total 42"
                           ":END:"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-drawer-is-one-list-to-org ()
  "The parser reads the merged board as ONE drawer holding ONE list of items.
This is the assertion that says the merge is legal Org and not merely
well-aligned text: an indented body stays inside its item, the drawer
survives `org-element-parse-buffer', and the turn keeps its ONE heading."
  (let ((buf (agent-org-buffer-create "join2")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "tc1") (title . "ls") (status . "completed")
           ,@(ao--tool-text-block "first body")))
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "tc2") (title . "pwd") (status . "completed")
           ,@(ao--tool-text-block "second body")))
    (should (apply #'ao--ordered
                   (with-current-buffer buf (buffer-string))
                   (list "  - EXECUTED ls" "    first body"
                         "  - EXECUTED pwd" "    second body")))
    (with-current-buffer buf
      (let ((drawers '()) (heads 0) (items 0) (lists 0))
        (org-element-map (org-element-parse-buffer)
            '(drawer headline item plain-list)
          (lambda (e)
            (cond ((eq (car e) 'drawer)
                   (push (org-element-property :drawer-name e) drawers))
                  ((eq (car e) 'headline) (cl-incf heads))
                  ((eq (car e) 'item) (cl-incf items))
                  ((eq (car e) 'plain-list) (cl-incf lists)))))
        (should (equal '("tool") (delete-dups drawers)))
        (should (= 1 heads))
        (should (= 1 lists))
        ;; two calls, two items: the bodies are their contents
        (should (= 2 items))))
    (kill-buffer buf)))

(defun ao--tool-drawer-bodies (text)
  "The body of every `:tool:' drawer in TEXT, in buffer order.
A drawer is the region between a `:tool:' line and the next `:end:' line, which
is how Org itself delimits one (info \"(org) Drawers\").  Reading the bodies out
of TEXT rather than off the buffer is what lets a test ask WHICH drawer a call
landed in -- the question `test-agent-org-tool-output-is-this-turns-only' asks
by counting markers, which cannot tell two same-worded calls apart."
  (let ((rest text) (bodies '()))
    (while (string-match "^:tool:$" rest)
      (let ((body-start (match-end 0)))
        (if (string-match "^:end:$" rest body-start)
            (progn
              (push (substring rest body-start (match-beginning 0)) bodies)
              (setq rest (substring rest (match-end 0))))
          (setq rest nil))))
    (nreverse bodies)))

(ert-deftest test-agent-org-tool-board-opens-a-new-drawer-after-activity ()
  "A tool call after the agent has spoken or thought opens a NEW `:tool:' drawer.
The user's order: \"Activity order MUST be kept.  New :tool: calls should always
appear at the end of response, not a previous drawer.\"  Before this the board
was created once per turn and every later call was repainted into it, so a call
made after the agent had moved on was displayed ABOVE the words and thoughts
that came before it -- the transcript read the turn backwards.  What separates
two runs of calls is any NON-tool activity, which is the user's own earlier
rule: \"The order of tool call and response/thinking separates them.  Activity
order gets precedence.\"

So the turn keeps ONE record (`agent-org-buffer--tools', in call order) and the
drawer is a WINDOW on it: thinking or a reply seals the open drawer, and the
next call starts a fresh one below everything written since.  Each drawer holds
only the calls that ran while it was the live one."
  (let ((buf (agent-org-buffer-create "act1")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "tc1") (title . "first") (status . "completed")
           ,@(ao--tool-text-block "first body")))
    (agent-org-buffer-append-thought buf "weighing the options")
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "tc2") (title . "second") (status . "completed")
           ,@(ao--tool-text-block "second body")))
    (let* ((text (with-current-buffer buf (buffer-string)))
           (bodies (ao--tool-drawer-bodies text)))
      (should (= 2 (length bodies)))
      ;; each drawer holds exactly its own call, body included
      (should (string-match-p "EXECUTED first" (car bodies)))
      (should (string-match-p "first body" (car bodies)))
      (should-not (string-match-p "second" (car bodies)))
      (should (string-match-p "EXECUTED second" (cadr bodies)))
      (should (string-match-p "second body" (cadr bodies)))
      (should-not (string-match-p "first" (cadr bodies)))
      ;; and the new drawer sits at the END of the turn, below the thought
      (should (apply #'ao--ordered text
                     (list "EXECUTED first" "weighing the options"
                           "EXECUTED second"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-board-reply-joins-the-live-drawer ()
  "Reply text does NOT split a run of calls: prose cannot sit between drawers.
This test pinned the opposite until the user's 2026-10-09 order: \"There CAN'T be
another :tool: drawer right after a :tool: drawer.  Consecutive tool calls belong
to the same drawer.\"  Read that together with the architecture this file's own
older docstring spelled out -- a turn's reply is written at the end of the ANSWER
text, which is always ABOVE every block of the turn -- and sealing on a reply
chunk could only ever produce two `:tool:' drawers TOUCHING, the prose stranded
above both.  That is the spam the order names, so a reply chunk seals nothing.

What DOES split a run is a block of the other kind: a thinking drawer is real
content laid down below the board, so the next board lands below it
(`test-agent-org-tool-board-opens-a-new-drawer-after-activity', and
`test-agent-org-no-adjacent-tool-drawers' pins the adjacency rule directly)."
  (let ((buf (agent-org-buffer-create "act2")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "tc1") (title . "ls") (status . "completed")
           ,@(ao--tool-text-block "a.org")))
    (agent-org-buffer-append-chunk buf "now I will check the tests" nil)
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "tc2") (title . "grep") (status . "completed")
           ,@(ao--tool-text-block "b.org")))
    (let* ((text (with-current-buffer buf (buffer-string)))
           (bodies (ao--tool-drawer-bodies text)))
      (should (= 1 (length bodies)))
      (should (string-match-p "EXECUTED ls" (car bodies)))
      (should (string-match-p "a.org" (car bodies)))
      (should (string-match-p "EXECUTED grep" (car bodies)))
      (should (string-match-p "b.org" (car bodies)))
      (should (apply #'ao--ordered text
                     (list "now I will check the tests" "EXECUTED ls"
                           "EXECUTED grep"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-unfinished-call-is-not-sealed-away ()
  "A call that is still running keeps the live drawer, so its completion is seen.
This is the trap the window has to avoid: `in_progress' and `pending' calls WILL
report again, usually after the agent has said or thought something in between.
Sealing past one would take it out of the drawer the reader is watching, and the
`completed' update that follows would have no drawer to render in -- the call
would stay TODO for the rest of the turn.  So the seal waits for the whole live
run to be terminal, which is also why this turn keeps ONE drawer despite three
interleaved thoughts."
  (let ((buf (agent-org-buffer-create "act5")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "tc1") (title . "one") (status . "in_progress")))
    (agent-org-buffer-append-thought buf "hmm")
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "tc1") (title . "one") (status . "completed")))
    (let* ((text (with-current-buffer buf (buffer-string)))
           (bodies (ao--tool-drawer-bodies text)))
      (should (= 1 (length bodies)))
      (should (string-match-p "EXECUTED one" (car bodies)))
      ;; the completion was painted in the SAME drawer the call started in
      (should-not (string-match-p "TODO one" text)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-consecutive-tool-calls-share-one-drawer ()
  "Consecutive calls keep ONE drawer -- activity order must not overshoot.
The user's other order: \"Consecutive tool calls belong to a single drawer.\"  A
fix that opened a drawer per CALL would satisfy the previous test and break
this one, and the transcript would grow a drawer per tool call: the exact noise
\"Consecutive tool calls belong to a single drawer\" was given to stop."
  (let ((buf (agent-org-buffer-create "act3")))
    (agent-org-buffer-start-agent-turn buf nil)
    (dolist (id '("tc1" "tc2" "tc3"))
      (agent-org-buffer-insert-tool
       buf `((toolCallId . ,id) (title . ,id) (status . "completed"))))
    (let ((bodies (ao--tool-drawer-bodies (with-current-buffer buf (buffer-string)))))
      (should (= 1 (length bodies)))
      (should (string-match-p "EXECUTED tc1" (car bodies)))
      (should (string-match-p "EXECUTED tc2" (car bodies)))
      (should (string-match-p "EXECUTED tc3" (car bodies))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-activity-before-any-call-opens-no-empty-drawer ()
  "Thinking before the first call must not leave an empty `:tool:' drawer behind.
Sealing an EMPTY window is a no-op, and this is where that rule is visible: the
agent usually thinks before its first tool call, so sealing on thought and then
opening on the next call must produce ONE drawer -- the call's -- at the end of
the turn.  A seal that started a new group unconditionally would put an empty
`:tool:'/`\\n:END:' pair above it."
  (let ((buf (agent-org-buffer-create "act4")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-thought buf "planning the first command")
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "tc1") (title . "only") (status . "completed")))
    (let ((bodies (ao--tool-drawer-bodies (with-current-buffer buf (buffer-string)))))
      (should (= 1 (length bodies)))
      (should (string-match-p "EXECUTED only" (car bodies)))
      (should-not (string-match-p "^\\s-*$\\s-*" (car bodies))))
    (kill-buffer buf)))

(defun ao--todo-set-matches-the-options (buffer)
  "Return non-nil when BUFFER's live keywords are exactly the five sets.
Takes the buffer because `org-todo-keywords-1' is a buffer-local derived once by
`agent-org-buffer--install-todo-keywords': read from another buffer it answers
about a buffer that never had one, which is how an earlier draft of this helper
failed its own tests.  `org-todo-keywords-1' also drops the `|' that separates a
sequence's unfinished words from its done ones, hence the bars removed here."
  (with-current-buffer buffer
    (equal org-todo-keywords-1
           ;; `remove', never `delete': `apply #'append' shares the LAST list's
           ;; spine with the option variable itself, so a destructive removal of
           ;; the bar edited `agent-org-plan-todo-keywords' in place and every
           ;; test after it saw a set with no separator (measured).
           (remove "|" (apply #'append
                              (mapcar #'cdr
                                      (agent-org-buffer--todo-keyword-sets)))))))

(ert-deftest test-agent-org-tool-keywords-are-running-executed-failed ()
  "The board's vocabulary is the user's: RUNNING, EXECUTED, FAILED.
The set is `RUNNING | EXECUTED FAILED' -- ONE unfinished word, so ACP's `pending'
and `in_progress' both read RUNNING, and the distinction the retired ONGOING gave
is gone by the user's ordering.  The words are POSITIONAL (`agent-org-buffer--tool-keyword'):
a customized set with two unfinished words gets the second one for `in_progress',
so no renderer hardcodes a word and renaming the set renames the board.
The DOING/DONE/CANCELLED triad is gone -- and `DONE' with it, which in a file
that declares EXECUTED as its done state would be a keyword the file does not
know.  Asserted together with the buffer's keyword set, because a board line
carrying a word the buffer does not know is text pretending to be a state -- and
since the sets are installed buffer-locally from the option lists there is no
`#+TODO:' line anywhere to carry them (see
`test-agent-org-metadata-installs-five-disjoint-todo-sets')."
  (let ((buf (agent-org-buffer-create "kw3")))
    (agent-org-buffer-start-agent-turn buf nil)
    (dolist (pair '(("pending" . "RUNNING")
                    ("in_progress" . "RUNNING")
                    ("completed" . "EXECUTED")
                    ("failed" . "FAILED")))
      (should (equal (cdr pair)
                     (agent-org-buffer--tool-keyword (car pair)))))
    ;; the positional rule, on a set that has room for it
    (let ((agent-org-tool-todo-keywords
           '("QUEUED" "RUNNING" "|" "EXECUTED" "BROKEN")))
      (should (equal (agent-org-buffer--tool-keyword "pending") "QUEUED"))
      (should (equal (agent-org-buffer--tool-keyword "in_progress") "RUNNING"))
      (should (equal (agent-org-buffer--tool-keyword "completed") "EXECUTED"))
      (should (equal (agent-org-buffer--tool-keyword "failed") "BROKEN")))
    (dolist (pair '(("tc1" . "pending") ("tc2" . "in_progress")
                    ("tc3" . "completed") ("tc4" . "failed")))
      (agent-org-buffer-insert-tool buf `((toolCallId . ,(car pair))
                                          (title . ,(car pair))
                                          (status . ,(cdr pair)))))
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (= 1 (ao--count-occurrences text "^  - RUNNING tc1$")))
      (should (= 1 (ao--count-occurrences text "^  - RUNNING tc2$")))
      (should (= 1 (ao--count-occurrences text "^  - EXECUTED tc3$")))
      (should (= 1 (ao--count-occurrences text "^  - FAILED tc4$")))
      (should-not (string-match-p "^  - \\(TODO\\|DOING\\|DONE\\|ONGOING\\|COMPLETE\\|CANCELLED\\) " text))
      ;; and the buffer KNOWS these words as states without declaring them in
      ;; the file: the option lists are installed buffer-locally, so
      ;; RUNNING/EXECUTED/FAILED resolve per headline and no `#+TODO:' line
      ;; exists to be out of date with them
      (should (ao--todo-set-matches-the-options buf))
      (dolist (word '("RUNNING" "EXECUTED" "FAILED"))
        (should (member word (buffer-local-value 'org-todo-keywords-1 buf)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-drawer-redraws-once-per-change ()
  "One board means one redraw guard: an update that changes nothing paints nothing.
With the bodies inside the board, a status-only update would otherwise
rewrite and re-protect every byte the turn's calls ever printed -- the cost
`test-agent-org-one-drawer-board-redraw-cost' measures.  So `:shown' moved from
per-entry to the whole rendered board (`agent-org-buffer--tools-shown'):
the guard asks whether the DRAWER would come out the same, which is exactly
what it must not do twice."
  (let ((buf (agent-org-buffer-create "guard4"))
        (paints 0)
        (orig (symbol-function 'agent-org-buffer--redraw-drawer)))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "tc1") (title . "shell") (status . "completed")
           ,@(ao--tool-text-block "total 42")))
    (cl-letf (((symbol-function 'agent-org-buffer--redraw-drawer)
               (lambda (buffer name lines &optional fold fresh)
                 (cl-incf paints)
                 (funcall orig buffer name lines fold fresh))))
      ;; identical re-delivery: same title, same status, same output
      (agent-org-buffer-insert-tool
       buf `((toolCallId . "tc1") (title . "shell") (status . "completed")
             ,@(ao--tool-text-block "total 42")))
      (should (= 0 paints))
      ;; a keyword change IS a change, and it repaints the ONE drawer
      (agent-org-buffer-insert-tool buf '((toolCallId . "tc1") (status . "failed")))
      (should (= 1 paints)))
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (= 1 (ao--count-occurrences text "^:tool:$")))
      (should (= 1 (ao--count-occurrences text "^    total 42$")))
      (should (string-match-p "^  - FAILED shell$" text)))
    ;; the guard is per turn, not global: turn two starts empty
    (agent-org-buffer-end-agent-turn buf)
    (agent-org-buffer-start-agent-turn buf nil)
    (should (null (buffer-local-value 'agent-org-buffer--tools-shown buf)))
    (kill-buffer buf)))

;;;; Prompt protection helpers

(ert-deftest test-agent-org-buffer-insert-prompt-twice ()
  "insert-prompt adds one box; repeats -- streaming included -- are no-ops.
The box is persistent (agent-shell's model): streaming cannot stack a
second one, because the open box IS the type-ahead while the turn runs."
  (let ((buf (agent-org-buffer-create "prompt")))
    (with-current-buffer buf
      (agent-org-buffer-insert-prompt buf)
      (should (= 1 (ao--count-substrings "* PROMPT")))
      (should (get-text-property (point-min) 'read-only)) ; heading frozen
      (should (agent-org-buffer--open-prompt-p)) ; body typeable
      (agent-org-buffer-insert-prompt buf)
      (should (= 1 (ao--count-substrings "* PROMPT"))) ; idempotent
      (setq agent-org-buffer--streaming-p t)
      (agent-org-buffer-insert-prompt buf)
      (should (= 1 (ao--count-substrings "* PROMPT")))) ; the box streams with us
    (kill-buffer buf)))

(ert-deftest test-agent-org-buffer-take-draft-empties-box-stays-open ()
  "take-draft returns the typed text and leaves the box open and empty.
Sending no longer consumes the prompt heading: the draft is taken out of
a box that stays at the buffer end, ready for the next message."
  (let ((buf (agent-org-buffer-create "freeze")))
    (with-current-buffer buf
      (agent-org-buffer-insert-prompt buf)
      ;; simulate typing with real self-insert-command
      (ao--type "Hello agent")
      (should (equal (agent-org-buffer-take-draft buf) "Hello agent"))
      (should (= 1 (ao--count-substrings "* PROMPT"))) ; no new box, no lost one
      (should (agent-org-buffer--open-prompt-p))     ; still typeable
      (should-not (string-match-p "Hello agent" (buffer-string)))
      ;; the heading stays frozen...
      (should (get-text-property (point-min) 'read-only))
      ;; ...and typing fresh text must not inherit the freeze: the
      ;; heading's own newlines stay read-only, rear-nonsticky is what
      ;; keeps a typed draft typeable (open-prompt-p above proves it)
      )
    (kill-buffer buf)))

(ert-deftest test-agent-org-buffer-take-draft-rejects-blank ()
  "A whitespace-only draft is an error, and the text stays put."
  (let ((buf (agent-org-buffer-create "blank")))
    (with-current-buffer buf
      (agent-org-buffer-insert-prompt buf)
      (ao--type "   ")
      (should-error (agent-org-buffer-take-draft buf) :type 'user-error)
      (should (string-suffix-p "   " (buffer-string))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-frozen-history-is-navigable ()
  "Frozen text takes the cursor; only editing it is refused."
  (let ((buf (agent-org-buffer-create "nav")))
    (with-current-buffer buf
      (agent-org-buffer-insert-prompt buf)
      (agent-org-buffer-append-chunk buf "streamed" (list :buffer buf))
      (goto-char (point-min))
      (should (eq ?# (following-char))) ; cursor stays where put
      (let ((before (buffer-string)))
        (should-error
         (let ((last-command-event ?x))
           (funcall #'self-insert-command 1))
         :type 'text-read-only)
        (should (= (point) (point-min)))
        ;; the refused keystroke changed nothing — comparing the whole buffer
        ;; beats searching for "x", which case-fold-search would match against
        ;; the `X' in the quote block's `#+ATTR_TEXINFO' line
        (should (equal before (buffer-string)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-insert-prompt-escapes-frozen-point ()
  "With point trapped on frozen text, opening a box takes point to it.
The box-free state this reconstructs is a replay mid-paint: turns render
at `point-max' until the session is ready and the type-ahead box opens."
  (let ((buf (agent-org-buffer-create "escape")))
    (with-current-buffer buf
      (agent-org-buffer-begin-exchange buf "Hi")
      (agent-org-buffer-append-chunk buf "Hello" (list :buffer buf))
      (agent-org-buffer-end-agent-turn buf)
      (goto-char (point-min))
      (should (get-text-property (point) 'read-only)) ; trapped
      (agent-org-buffer-insert-prompt buf)
      (should (agent-org-buffer--open-prompt-p))
      (should (= (point) (point-max)))) ; rescued into the box
    (kill-buffer buf)))

;;;; Session registry cleanup

(ert-deftest test-agent-org-buffer-kill-unregisters-session ()
  "Killing a chat buffer drops its entry from `agent-org--sessions'."
  (let* ((buf (agent-org-buffer-create "killme"))
         (entry (list :name 'test :client nil :buffer buf)))
    (agent-org--register-session entry)
    (should (agent-org--session-for-buffer buf))
    (kill-buffer buf)
    (should-not (agent-org--session-for-buffer buf))))

;;;; Mode line: `which-function-mode' must survive our read-only text

(ert-deftest test-agent-org-which-function-answers-property-free ()
  "The heading handed to `which-function' carries no text properties.
`which-func-format' shows whatever `which-function' returns, and it shows
it by APPLYING a face: `(:propertize which-func-current …)'.  Applying a
property to text that carries `read-only' is a modification, so Emacs
signals `text-read-only' -- inside `format-mode-line'.  doom-modeline builds
its whole right-hand side in one such call, so one read-only heading blanks
the entire bar (the user's \"doom-modeline is still blank!\").  Org's own
`add-log-current-defun-function' answers with `buffer-substring', which
copies properties: in a chat buffer that string is our protected heading
line, `read-only' and all."
  (let ((buf (agent-org-buffer-create "whichfunc")))
    (with-current-buffer buf
      (agent-org-buffer-insert-prompt buf)
      (should (functionp add-log-current-defun-function))
      ;; Aim at a SENT exchange: its heading carries question text.  At the
      ;; bare `* PROMPT' box heading the property-free answer is legitimately
      ;; NIL -- `PROMPT' is a real TODO keyword
      ;; (`agent-org-buffer--prompt-word'), `org-get-heading' strips it, and
      ;; the empty remainder is dropped by `--which-function'.  A test that
      ;; demanded a string from the box would be testing the strip away.
      (agent-org-buffer-begin-exchange buf "how do I check the mode line")
      (save-excursion
        (goto-char (point-min))
        (re-search-forward "^\\* PROMPT how do I check the mode line$")
        (let ((name (funcall add-log-current-defun-function)))
          (should (equal "how do I check the mode line" name))
          (should-not (get-text-property 0 'read-only name))
          ;; and it is genuinely faceable: this is the call that used to
          ;; raise `text-read-only' during mode-line construction
          (should
           (not (condition-case nil
                    (progn (add-face-text-property 0 (length name) 'mode-line t name)
                           nil)
                  (error t)))))
      ;; the protection itself is untouched: only the copy is clean, so
      ;; the heading is still untypeable
      (save-excursion
        (goto-char (point-min))
        (re-search-forward "^\\* PROMPT how do I check the mode line$")
        (should (get-text-property (point) 'read-only)))))
    ;; and turning the mode off gives the buffer back Org's own answer
    (with-current-buffer buf
      (agent-org-mode -1)
      (should-not (local-variable-p 'add-log-current-defun-function)))
    (kill-buffer buf)))

;;;; Header-line lifecycle

(ert-deftest test-agent-org-mode-disable-clears-header-line ()
  "Disabling `agent-org-mode' restores the buffer's original header line."
  (let ((buf (agent-org-buffer-create "hl")))
    (with-current-buffer buf
      (should header-line-format)
      (agent-org-mode -1)
      (should-not header-line-format))
    (kill-buffer buf)))

(ert-deftest test-agent-org-status-falls-back-to-message ()
  "With `agent-org-use-header-line' nil, set-status reports via message."
  (let* ((agent-org-use-header-line nil)
         (buf (agent-org-buffer-create "fb"))
         (seen nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) seen))))
      (with-current-buffer buf
        (should-not header-line-format)
        (agent-org-buffer-set-status buf :state 'ready :message "Ready")))
    (should (seq-some (lambda (m) (string-match-p "Ready" m)) seen))
    (kill-buffer buf)))

;;;; Thinking drawer scoping

(ert-deftest test-agent-org-thinking-drawer-stays-in-current-turn ()
  "Each Agent turn gets its own :thinking: drawer; no cross-turn bleed."
  (let ((buf (agent-org-buffer-create "turns")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-thought buf "first")
    (agent-org-buffer-end-agent-turn buf)
    (agent-org-buffer-begin-exchange buf "next question")
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-thought buf "second")
    (with-current-buffer buf
      (goto-char (point-min))
      (let ((n 0))
        (while (search-forward ":thinking:" nil t) (cl-incf n))
        (should (= n 2)))
      (goto-char (point-min))
      (let ((m 0))
        ;; Pair each `:thinking:' with the closer that follows it.  A bare
        ;; count of `:end:' would also count the `:PROPERTIES:' and
        ;; `:LOGBOOK:' drawers an exchange heading now files and closes
        ;; (AGENTS.md §22), which are not the drawers this test is about.
        (while (search-forward ":thinking:" nil t)
          (cl-incf m)
          (should (search-forward ":end:" nil t)))
        (should (= m 2))))
    (kill-buffer buf)))

;;;; Permission cancellation

(ert-deftest test-agent-org-permission-quit-sends-cancelled ()
  "Quitting the permission prompt responds with :cancelled and restores status."
  (let* ((buf (agent-org-buffer-create "perm"))
         (session (list :name 'test :client nil :buffer buf :session-id "s"))
         (made nil)
         (sent 0))
    (cl-letf (((symbol-function 'agent-org--ask-permission)
               (lambda (_opts) (signal 'quit nil)))
              ((symbol-function 'acp-make-session-request-permission-response)
               (lambda (&rest kw) (push kw made) kw))
              ((symbol-function 'acp-send-response)
               (lambda (&rest _args) (cl-incf sent))))
      (agent-org--on-request
       session
       `((method . "session/request_permission")
         (id . 7)
         (params . ((options) (toolCall)))))
      (should (= sent 1))
      (let ((kw (car made)))
        (should (plist-get kw :cancelled))
        (should-not (plist-member kw :option-id))))
    ;; status returns to the pre-request snapshot, not a hardcoded state
    (with-current-buffer buf
      (should (eq 'starting (plist-get agent-org-buffer--status :state))))
    (kill-buffer buf)))

;;;; Permission prompt: real ACP option shape

(defun ao--permission-request (options)
  "A `session/request_permission' carrying OPTIONS, shaped as the wire sends it.
A permission is always about a tool call, which is what OpenCode and
MiniMax actually send."
  `((method . "session/request_permission")
    (id . 7)
    (params . ((options . ,options)
               (toolCall . ((toolCallId . "t1")
                            (title . "run ls")
                            (status . "pending")))))))

(ert-deftest test-agent-org-permission-prompt-offers-option-names ()
  "The prompt lists each option's `name' and answers with its `optionId'.

A PermissionOption is (optionId, name, kind); the first reader here asked
for `label' and `id', keys no agent ever sends, so both reads answered
nil and the dialog was one `nil' candidate beside our own Cancel.
COMPLETING-READ is stubbed, NOT the prompter: stubbing the prompter is
how that shipped with a green suite."
  (let* ((buf (agent-org-buffer-create "perm-names"))
         (session (list :name 'test :client nil :buffer buf :session-id "s"))
         (collection nil)
         (made nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt coll &rest _args)
                 (setq collection coll)
                 "Allow once"))
              ((symbol-function 'acp-make-session-request-permission-response)
               (lambda (&rest kw) (push kw made) kw))
              ((symbol-function 'acp-send-response)
               (lambda (&rest _args) nil)))
      (agent-org--on-request
       session
       (ao--permission-request
        `(((optionId . "allow_once") (name . "Allow once") (kind . "allow_once"))
          ((optionId . "reject_once") (name . "Reject once") (kind . "reject_once")))))
      (should (equal '("Allow once" "Reject once" "Cancel") collection))
      (should-not (seq-contains-p collection nil))
      (let ((kw (car made)))
        (should (equal "allow_once" (plist-get kw :option-id)))
        (should-not (plist-member kw :cancelled)))
      ;; the awaiting status belongs to the request, not the answer
      (with-current-buffer buf
        (should (eq 'starting (plist-get agent-org-buffer--status :state)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-permission-cancel-entry-sends-cancelled ()
  "The Cancel entry answers `cancelled' -- and never a nil option id."
  (let* ((buf (agent-org-buffer-create "perm-cancel"))
         (session (list :name 'test :client nil :buffer buf :session-id "s"))
         (made nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt _coll &rest _args) "Cancel"))
              ((symbol-function 'acp-make-session-request-permission-response)
               (lambda (&rest kw) (push kw made) kw))
              ((symbol-function 'acp-send-response)
               (lambda (&rest _args) nil)))
      (agent-org--on-request
       session
       (ao--permission-request
        `(((optionId . "allow_once") (name . "Allow once") (kind . "allow_once")))))
      (let ((kw (car made)))
        (should (plist-get kw :cancelled))
        (should-not (plist-member kw :option-id))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-permission-option-without-name-shows-its-id ()
  "An option carrying no `name' still reads as something: its `optionId'.
An agent is not obliged to name its options; a blank candidate is not an
answer a person can pick."
  (let* ((buf (agent-org-buffer-create "perm-noname"))
         (session (list :name 'test :client nil :buffer buf :session-id "s"))
         (collection nil)
         (made nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt coll &rest _args)
                 (setq collection coll)
                 (car coll)))
              ((symbol-function 'acp-make-session-request-permission-response)
               (lambda (&rest kw) (push kw made) kw))
              ((symbol-function 'acp-send-response)
               (lambda (&rest _args) nil)))
      (agent-org--on-request
       session
       (ao--permission-request
        `(((optionId . "approve-3") (kind . "allow_once")))))
      (should (equal '("approve-3" "Cancel") collection))
      (should (equal "approve-3" (plist-get (car made) :option-id))))
    (kill-buffer buf)))

(defun ao--count-substrings (substring)
  "Number of literal occurrences of SUBSTRING in the current buffer.
`how-many' in Emacs 30 lacks the REGEXP-P argument, so count directly."
  (save-excursion
    (goto-char (point-min))
    (let ((n 0))
      (while (search-forward substring nil t)
        (cl-incf n))
      n)))

;;;; Live-prompt send flow

(defun ao--make-test-session (name)
  "Create a chat buffer named for NAME with a registered ready session.
Returns (BUFFER . SESSION).  The plist carries every key
`agent-org--open-session' installs: `setf' on `plist-get' mutates in
place only when the key already exists, so a session missing
`:loading'/`:replay' would silently ignore the resume tests' setup."
  (let* ((buf (agent-org-buffer-create name))
         (session (list :name 'test :client nil :buffer buf
                        :session-id "sid-test" :streaming nil :turn nil
                        :loading nil :replay nil :replay-timer nil
                        :replay-session-id nil :replay-response nil
                        :replay-deadline nil :pending-prompts nil
                        :lists-sessions nil :title-seeked nil)))
    (agent-org--register-session session)
    (agent-org-buffer-set-session buf session)
    (cons buf session)))

(defun ao--type (text)
  "Simulate typing TEXT with real `self-insert-command' at point."
  (dolist (ch (append text nil))
    (let ((last-command-event ch))
      (funcall #'self-insert-command 1))))

(ert-deftest test-agent-org-send-echoes-the-prompt-as-its-heading-above-a-persistent-box ()
  "Sending freezes the draft into its own heading above the box; the box
survives the send open and empty, so the next prompt is typeable at once
(agent-shell's persistent-prompt UX).  The sent question is no longer body
text under a generic `* PROMPT': it IS the heading now."
  (let* ((pair (ao--make-test-session "send"))
         (buf (car pair))
         (session (cdr pair)))
    (cl-letf (((symbol-function 'acp-send-request) (lambda (&rest _args) nil)))
      (with-current-buffer buf
        (agent-org-buffer-insert-prompt buf)
        (ao--type "Hi")
        (agent-org-send)
        (should (= 1 (ao--count-substrings "* PROMPT"))) ; only the box remains
        ;; the sent question IS the heading, wearing the header line's state
        ;; word: the turn is streaming, so `RESPONDING' mirrors it there
        (should (= 1 (ao--count-substrings "* RESPONDING Hi")))
        (should (agent-org-buffer--open-prompt-p))     ; box still typeable
        (should (eq 'streaming (plist-get agent-org-buffer--status :state)))
        (should (plist-get session :streaming))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-draft-survives-streaming-renders ()
  "Text typed into the box mid-turn is never rendered over.
The invariant the anchor exists for: every streaming insert lands BEFORE
the box, pushing it down instead of scribbling into the draft."
  (let ((buf (agent-org-buffer-create "typed-ahead")))
    (with-current-buffer buf
      (agent-org-buffer-insert-prompt buf)
      ;; a turn streams while the user is mid-sentence in the box
      (ao--type "next prompt")
      (let ((draft-marker (copy-marker (point))))
        (agent-org-buffer-append-chunk buf "thinking aloud " (list :buffer buf))
        (agent-org-buffer-append-thought buf "a thought")
        (agent-org-buffer-insert-tool buf '((title . "shell") (toolCallId . "t1")))
        (agent-org-buffer-end-agent-turn buf)
        ;; the draft is intact, still typeable, and point never moved
        ;; (the box ends at the heading's OWN newline: the draft sits on the
        ;; line directly under `* PROMPT', with no blank line between)
        (should (string-match-p "\\* PROMPT\nnext prompt" (buffer-string)))
        (should (= (marker-position draft-marker) (point)))
        (should (agent-org-buffer--open-prompt-p))
        ;; and the turn rendered strictly above the box, in render order:
        ;; the thought drawer came first, the tool drawer after it
        (should (apply #'ao--ordered (buffer-string)
                       (list "* Agent" "thinking aloud"
                             ":thinking:" ":tool:" "  - RUNNING shell"
                             "next prompt")))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-prompt-box-body-is-typeable-right-under-the-heading ()
  "The box's typeable line is the ONE directly under `* PROMPT'.
The live complaint that pins this shape: /\"The prompt area MUSTN'T be
read-only, I can only add text two lines below the heading.\"/  The box used
to end with a blank line after its heading, so the first keystroke at
`point-max' landed two lines below, while the line directly under the
heading inherited the frozen prefix's `read-only' through the newline in
front of it.  The settled box ends at the heading's OWN newline
(`agent-org-buffer-insert-prompt'), and that newline carries
`rear-nonsticky' so typing after it is accepted.  Four things pinned
together: the source's own reader sees an open box, the buffer ends exactly
`* PROMPT' + newline with nothing more, typing at `point-max' -- the line
directly under the heading -- is accepted and lands there, and the heading
line itself stays frozen."
  (let ((buf (agent-org-buffer-create "box-typeable")))
    (with-current-buffer buf
      (agent-org-buffer-insert-prompt buf)
      ;; (a) the reader that every boundary uses agrees the box is open
      (should (agent-org-buffer--open-prompt-p))
      ;; (b) the box ends at the heading's OWN newline: no blank line, so a
      ;; strict byte comparison, not a match that a stale blank would pass
      (save-excursion
        (goto-char (point-max))
        (org-back-to-heading t)
        (should (string= "* PROMPT\n"
                         (buffer-substring-no-properties (point) (point-max)))))
      ;; (c) the line directly under the heading IS `point-max' here, and
      ;; typing there is accepted -- measured with a trial insert, not by
      ;; reading properties, which is where the stickiness bug hid
      (should (ao--insertable-p (point-max)))
      (goto-char (point-max))
      (let ((inhibit-read-only nil))
        (ao--type "right under"))
      (should (string-suffix-p "* PROMPT\nright under" (buffer-string)))
      ;; (d) the heading line itself is still frozen: typing inside the
      ;; word is refused, so the body became typeable without un-freezing
      ;; what a render anchors to
      (save-excursion
        (goto-char (point-min))
        (re-search-forward "^\\* PROMPT$")
        (should-not (ao--insertable-p (+ (line-beginning-position) 2)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-nothing-below-the-separator-is-read-only ()
  "Every byte at or below the separator is typeable, rule line included.
THE user's order, twice, in capitals: /\"EVERYTHING below the separator
MUSTN'T be read-only\"/.  The box's frozen prefix used to run from the
separator all the way to the heading, so the horizontal rule
(`agent-org-buffer--box-rule') and the blank line after it were frozen
text too -- measured in the live chat: positions 426001 and onward, every
one of them `read-only t'.  The freeze is now the HEADING'S OWN bytes
and nothing more, while the rule keeps the property the tests pin on it:
it still sits ABOVE `--render-end', so no turn can glue itself between
rule and box, and it still never reaches the transcript.
The three claims a cursor can check in the buffer, in the order they
appear: the last frozen character of the whole buffer is the heading's
own newline, the byte at the rule's first hyphen accepts a trial insert,
and so does the blank line between rule and heading."
  (let ((buf (agent-org-buffer-create "sep-typeable")))
    (with-current-buffer buf
      (agent-org-buffer-insert-prompt buf)
      (save-excursion
        (goto-char (point-min))
        (re-search-forward "^-\\{5,\\}$" nil t)
        (let ((rule (line-beginning-position)))
          ;; (a) the rule line itself takes a keystroke
          (should (ao--insertable-p rule))
          ;; (b) and so does the blank line between the rule and the box
          (should (ao--insertable-p (1+ rule)))
          ;; (c) the last frozen byte in the buffer is the heading's own
          ;; trailing newline -- the freeze starts there for EVERYTHING above
          ;; it (the metadata block stays frozen) and stops there for
          ;; everything below it (the rule and the separator above are typeable)
          (let ((frozen nil))
            (save-excursion
              (goto-char (point-min))
              (while (not (eobp))
                (when (get-text-property (point) 'read-only)
                  (setq frozen (point)))
                (forward-char 1)))
            (should (equal frozen
                           (save-excursion
                             (goto-char (agent-org-buffer--prompt-box-heading))
                             (line-end-position)))))
          ;; (d) and the heading underneath it is still frozen: the rule
          ;; became typeable without un-freezing what a render anchors to
          (should-not (ao--insertable-p (save-excursion
                                          (goto-char (point-max))
                                          (line-beginning-position 0)))))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-a-draft-containing-headings-still-sends ()
  "A prompt that CONTAINS a headline is still a prompt.
THE report: /\"Can't use headings inside prompts\"/.  A person writes a
multi-line ask with a star bullet list — `* auth', `* db' — and in Org a `*'
at column 0 is a level-1 HEADLINE, so the draft's own lines became headings of
the chat.  The box was then found by walking back from `point-max' to the
nearest heading, which is whichever bullet was typed LAST, so
`agent-org-buffer--open-prompt-p' answered nil and every send died with
/Nothing to send; type your prompt under the PROMPT heading/ — the same
symptom the queue-region work had, from a different cause.
So: the box is found from its OWN anchor (`--prompt-anchor'), never from the
bottom of the buffer, and the draft is everything after the heading's line.
Four things pinned: the reader still sees an open box, `take-draft' returns
the whole text INCLUDING the star lines, the box survives the send with no
draft left in it, and the sent exchange renders as ONE headline."
  (let ((buf (agent-org-buffer-create "draft-headings")))
    (with-current-buffer buf
      (agent-org-buffer-insert-prompt buf)
      (goto-char (point-max))
      (let ((inhibit-read-only nil))
        (ao--type "Please refactor two modules:\n* auth\n* db\n"))
      ;; (a) the box is still a box even though the user typed headings in it
      (should (agent-org-buffer--open-prompt-p))
      ;; (b) and its whole text, bullets included, comes back
      (should (equal (agent-org-buffer-take-draft buf)
                     "Please refactor two modules:\n* auth\n* db"))
      ;; (c) the box is still open and EMPTY: no bullet survived the send
      (should (agent-org-buffer--open-prompt-p))
      (should (string-suffix-p "* PROMPT\n" (buffer-string)))
      ;; (d) and rendering the same text as a sent exchange makes ONE new
      ;; headline: the exchange, plus the box that was already there.  The
      ;; bullets must not appear as headings of their own.
      (agent-org-buffer-begin-exchange buf "Please refactor:\n* auth\n* db")
      (let ((heads ()))
        (save-excursion
          (goto-char (point-min))
          (while (re-search-forward "^\\*+ .*" nil t)
            (push (string-trim (match-string 0)) heads)))
        (should (equal (nreverse heads)
                       '("* PROMPT Please refactor:" "* PROMPT")))))))

(ert-deftest test-agent-org-draft-takes-a-first-line-that-looks-like-markup ()
  "A draft whose FIRST line is a cookie or a drawer line is not swallowed.
`take-draft' used to start reading at `org-end-of-meta-data', which skips
exactly the lines a person might paste first (`#+TITLE: ...', a `:PROPERTIES:'
drawer).  The box writes no metadata under its heading, so the draft begins on
the line after it and nothing of the user's text can be mistaken for furniture."
  (let ((buf (agent-org-buffer-create "draft-cookie")))
    (with-current-buffer buf
      (agent-org-buffer-insert-prompt buf)
      (goto-char (point-max))
      (let ((inhibit-read-only nil))
        (ao--type "#+TITLE: notes about the refactor\n"))
      (should (agent-org-buffer--open-prompt-p))
      (should (equal (agent-org-buffer-take-draft buf)
                     "#+TITLE: notes about the refactor"))
      (should (agent-org-buffer--open-prompt-p)))))

(ert-deftest test-agent-org-send-callback-keeps-the-same-box ()
  "Ending the turn (success callback) does not stack a second box: the
type-ahead box was never consumed, so the buffer ends the turn with the
one it started with."
  (let* ((pair (ao--make-test-session "reopen"))
         (buf (car pair))
         (captured nil))
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest kw) (setq captured kw))))
      (with-current-buffer buf
        (agent-org-buffer-insert-prompt buf)
        (ao--type "Hi")
        (agent-org-send)
        (funcall (plist-get captured :on-success) nil)
        (should (= 1 (ao--count-substrings "* PROMPT"))) ; the box, not a second one
        (should (agent-org-buffer--open-prompt-p))
        (should (eq 'ready (plist-get agent-org-buffer--status :state)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-send-rejects-empty-prompt ()
  "An empty live prompt is an error; nothing is sent."
  (let ((buf (car (ao--make-test-session "empty"))))
    (with-current-buffer buf
      (agent-org-buffer-insert-prompt buf)
      (should-error (agent-org-send) :type 'user-error)
      (should (= 1 (ao--count-substrings "* PROMPT"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-send-rejects-when-no-open-prompt ()
  "If the buffer does not end in an open prompt, send explains why."
  (let ((buf (car (ao--make-test-session "noprompt"))))
    (with-current-buffer buf
      (agent-org-buffer-begin-exchange buf "already sent")
      (should-error (agent-org-send) :type 'user-error))
    (kill-buffer buf)))

(ert-deftest test-agent-org-send-rejects-while-streaming ()
  "With the queue option off, the streaming guard rejects sends."
  (let* ((pair (ao--make-test-session "busy"))
         (session (cdr pair))
         (agent-org-queue-when-busy nil))
    (setf (plist-get session :streaming) t)
    (should-error (with-current-buffer (car pair) (agent-org-send))
                  :type 'user-error)
    (should-not (plist-get session :pending-prompts))
    (kill-buffer (car pair))))

;;;; Prompt queue (submitting while the agent is still responding)

(defun ao--sent-texts (sent)
  "The prompt texts of captured send requests in SENT, oldest first.
Pairs with the `acp-make-session-prompt-request' stub used by the queue
tests, which hands back the :prompt argument verbatim: a list of the
plain alists `agent-org--make-content-blocks' builds."
  (mapcar (lambda (kw) (map-elt (car (plist-get kw :request)) 'text))
          (reverse sent)))

(ert-deftest test-agent-org-send-queues-while-streaming ()
  "A send while the agent responds takes the buffer draft and waits.
Nothing goes on the wire, the queue keeps FIFO order, and the header
message grows a pending count -- all without touching the minibuffer:
type-ahead, like a TUI agent."
  (let* ((pair (ao--make-test-session "q-enq"))
         (buf (car pair))
         (session (cdr pair))
         (sent nil))
    (setf (plist-get session :streaming) t)
    (with-current-buffer buf
      (agent-org-buffer-insert-prompt buf)
      (agent-org-buffer-set-status buf :state 'streaming :message "Sending…")
      (ao--type "queued one")
      (cl-letf (((symbol-function 'acp-send-request)
                 (lambda (&rest kw) (push kw sent))))
        (agent-org-send))
      (should (equal (list "queued one")
                     (plist-get session :pending-prompts)))
      (should (null sent))
      (should (plist-get session :streaming))
      (should (agent-org-buffer--open-prompt-p)) ; box stays, ready for more
      (should (string-match-p "1 queued"
                              (plist-get agent-org-buffer--status :message))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-queue-drains-in-order-on-success ()
  "Every successful turn end sends the next queued prompt, FIFO.
The drained text is rendered as its own exchange heading above the
still-open type-ahead box before it goes on the wire; the queue
empties, the box never had to be reopened, and a draft typed while the
drained turn streams is untouched."
  (let* ((pair (ao--make-test-session "q-drain"))
         (buf (car pair))
         (session (cdr pair))
         (sent nil))
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest kw) (push kw sent)))
              ((symbol-function 'acp-make-session-prompt-request)
               (lambda (&rest a) (plist-get a :prompt))))
      (with-current-buffer buf
        (agent-org-buffer-insert-prompt buf)
        (ao--type "one")
        (agent-org-send)                       ; real turn
        (ao--type "two")
        (agent-org-send)                       ; queues "two"
        (ao--type "three")
        (agent-org-send))                      ; queues "three"
      (should (equal '("two" "three") (plist-get session :pending-prompts)))
      (should (= 1 (length sent)))
      ;; turn "one" succeeds: "two" is rendered and sent, queue shrinks
      (funcall (plist-get (nth 0 sent) :on-success) nil)
      (should (equal '("one" "two") (ao--sent-texts sent)))
      (should (equal '("three") (plist-get session :pending-prompts)))
      (should (plist-get session :streaming))
      (with-current-buffer buf
        ;; the drained prompt is an exchange now, and its turn is streaming:
        ;; the heading wears the header line's state word, `RESPONDING'
        (should (string-match-p "^\\* RESPONDING two$" (buffer-string))))
      ;; turn "two" succeeds: "three" goes out
      (funcall (plist-get (car sent) :on-success) nil)
      (should (equal '("one" "two" "three") (ao--sent-texts sent)))
      (should-not (plist-get session :pending-prompts))
      ;; turn "three" succeeds: nothing left, the one box is still there
      (funcall (plist-get (car sent) :on-success) nil)
      (should (= 3 (length sent)))
      (should-not (plist-get session :streaming))
      (with-current-buffer buf
        (should (agent-org-buffer--open-prompt-p))
        ;; three exchange headings and ONE persistent box.  The words show
        ;; the state each heading was left in: "one" was drained straight into
        ;; the next turn, so its mirror never saw a Ready between the two and
        ;; it stayed `RESPONDING'; "two" and "three" ended their turns before
        ;; the next state and mirror `RESPONDED'.  (Whether a turn billed by a
        ;; later drain should shut its word is a design question -- the word
        ;; mirrors the header line, and the header line never went Ready.)
        (should (= 1 (ao--count-substrings "* PROMPT")))
        (should (= 1 (ao--count-substrings "* RESPONDING one")))
        (should (= 1 (ao--count-substrings "* RESPONDED two")))
        (should (= 1 (ao--count-substrings "* RESPONDED three")))
        (should (eq 'ready (plist-get agent-org-buffer--status :state)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-drain-keeps-fresh-draft ()
  "A draft typed while the drained turn runs is never swallowed by it.
The drained prompt renders above the box and the box keeps its own text:
this is where agent-shell sets the draft aside, and here the persistent
box makes that unnecessary -- but it has to stay true."
  (let* ((pair (ao--make-test-session "q-draft"))
         (buf (car pair))
         (session (cdr pair))
         (sent nil))
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest kw) (push kw sent)))
              ((symbol-function 'acp-make-session-prompt-request)
               (lambda (&rest a) (plist-get a :prompt))))
      (with-current-buffer buf
        (agent-org-buffer-insert-prompt buf)
        (ao--type "one")
        (agent-org-send)
        (ao--type "queued")
        (agent-org-send)                    ; queues "queued"
        (ao--type "untouched")              ; fresh draft, nothing sent
        (funcall (plist-get (car sent) :on-success) nil))
      (should (equal '("one" "queued") (ao--sent-texts sent)))
      (with-current-buffer buf
        ;; the drained prompt streams as an exchange, its heading wearing the
        ;; state word; the box keeps the fresh draft on its own line
        (should (string-match-p "^\\* RESPONDING queued$" (buffer-string)))
        (should (string-match-p "\\* PROMPT\nuntouched" (buffer-string)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-queue-survives-failed-turn ()
  "A failed turn does not drain: nothing hammers a dead agent.
The queue keeps its prompts in order so the user can look at the error
before deciding; the box was never consumed, so there is nothing to
reopen."
  (let* ((pair (ao--make-test-session "q-fail"))
         (buf (car pair))
         (session (cdr pair))
         (sent nil))
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest kw) (push kw sent)))
              ((symbol-function 'acp-make-session-prompt-request)
               (lambda (&rest a) (plist-get a :prompt))))
      (with-current-buffer buf
        (agent-org-buffer-insert-prompt buf)
        (ao--type "one")
        (agent-org-send)
        (ao--type "spare")
        (agent-org-send))                   ; queues "spare"
      (funcall (plist-get (car sent) :on-failure) nil "boom")
      (should (equal '("spare") (plist-get session :pending-prompts)))
      (should (= 1 (length sent)))
      (with-current-buffer buf
        (should (eq 'error (plist-get agent-org-buffer--status :state)))))
    (kill-buffer buf)))

;;;; The queue, edited where it is read: `* TODO' at the buffer end

(defun ao--queued (prompts)
  "A test session whose queue is PROMPTS, with the entries rendered.
Returns (CHAT . SESSION).  The refresh is the real one, so the entries and the
transcript both stand where a live enqueue would leave them -- these tests are
about the shape the user edits, not about a renderer called directly."
  (let* ((pair (ao--make-test-session "queue"))
         (chat (car pair))
         (session (cdr pair)))
    (setf (plist-get session :pending-prompts) prompts)
    (agent-org--queue-refresh session chat)
    (cons chat session)))

(defun ao--queue-headings ()
  "This chat buffer's queue entry headlines, as strings, top to bottom."
  (with-current-buffer (current-buffer)
    (mapcar (lambda (at)
              (save-excursion (goto-char at) (buffer-substring-no-properties
                                              (point) (line-end-position))))
            (agent-org-buffer--queue-headlines))))

(defun ao--insertable-p (position)
  "Non-nil when typing at POSITION would be accepted.
THE user's complaint, measured: \"I can't even delete as it says read-only.\"  A
`text-read-only' signal from a plain `insert' at a position is exactly what the
keyboard would do there, so this is the honest test of an editable region -- not
a question about which characters carry the property, which is where the bug
actually lives (stickiness on a character OUTSIDE the region refusing a typing
INSIDE it).  POSITION is resolved in the current buffer; the trial character is
removed again so the caller's layout is untouched."
  (condition-case nil
      (let ((inhibit-read-only nil)
            (buffer-undo-list t))
        (save-excursion
          (goto-char position)
          (insert "Q")
          (delete-region (1- (point)) (point))
          t))
    (text-read-only nil)))

(ert-deftest test-agent-org-queue-head-wears-next-and-the-rest-wait ()
  "The FIRST waiting prompt is `* NEXT', every one behind it `* WAIT'.
The user's words for a queue, and they say the one thing the reader cannot
otherwise see at a glance: which prompt goes out when the turn ends.  Because
the word now carries POSITION, every edit that changes the order MUST restate
the words -- a `* NEXT' sitting third would promise a place in the send order it
no longer has -- and that restating is `agent-org-buffer-queue-restate', which
this pins alongside the render.

NEXT and WAIT are BOTH UNFINISHED keywords: measured on Org 9.7.11, a set
written `(\"NEXT\" \"WAIT\" \"|\")' answers `org-done-keywords' = (\"WAIT\"), so a
queue set of its own would paint the waiting prompts as DONE.  They therefore
ride in the prompt set's unfinished half, after PROMPT/RESPONDING/IDLE, which
keeps every positional index
`agent-org-buffer--prompt-keyword-for-state' reads.

A bare `* TODO' is still READ: it is what queues written before this vocabulary
hold, and a dropped prompt is lost work, not a cosmetic miss."
  (let ((pair (ao--queued '("one" "two" "three"))))
    (with-current-buffer (car pair)
      (should (equal '("* NEXT one" "* WAIT two" "* WAIT three")
                     (ao--queue-headings)))
      ;; both words are unfinished states of THIS buffer's installation, so
      ;; neither reads as a completed item and `C-c C-t' cycles inside the set
      (should (member "NEXT" org-not-done-keywords))
      (should (member "WAIT" org-not-done-keywords))
      (should-not (member "WAIT" org-done-keywords))
      ;; exactly one entry says NEXT, and it is the first
      (should (= 1 (seq-count (lambda (line) (string-prefix-p "* NEXT " line))
                              (ao--queue-headings))))
      ;; and what the page says round-trips through the reader
      (should (equal '("one" "two" "three") (agent-org-buffer-queue-parse nil))))
    (kill-buffer (car pair)))
  (dolist (pair '(("* NEXT current head" . "current head")
                  ("* WAIT current rest" . "current rest")
                  ("* PROMPT retired one-word" . "retired one-word")
                  ("* TODO legacy todo" . "legacy todo")))
    (should (equal (list (cdr pair))
                   (agent-org-buffer--queue-parse-text
                    (concat (car pair) "\n"))))))

(ert-deftest test-agent-org-queue-entries-sit-at-the-buffer-bottom ()
  "The waiting prompts are `* NEXT'/`* WAIT' headings between the last exchange
and the live `* PROMPT' box -- not in a drawer at the top, and not after the box.
The user asked for them at the bottom and for the box to stay the last
thing they type in, so the order is exchange, then entries, then box."
  (let* ((pair (ao--make-test-session "q-place"))
         (buf (car pair)))
    (unwind-protect
        (with-current-buffer buf
          (agent-org-buffer-insert-prompt buf)
          (setf (plist-get (cdr pair) :pending-prompts) '("first" "second"))
          (agent-org--queue-refresh (cdr pair) buf)
          (let ((text (buffer-string)))
            (should (apply #'ao--ordered text
                           (list "* NEXT first" "* WAIT second" "* PROMPT")))
            (should (string-match-p "^\\* NEXT first$" text))
            (should (string-match-p "^\\* WAIT second$" text))
            ;; and the words are the buffer's own states, installed from the
            ;; option lists rather than a `#+TODO:' line in the file
            (should (member "NEXT" org-not-done-keywords))
            (should-not (string-match-p "^#\\+TODO:" text))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-queue-round-trips-every-entry ()
  "Render then parse: each waiting prompt comes back byte-identical.
The renderer puts ONE space in front of every body line, so a prompt whose
own line begins with `*' cannot become a headline of the chat and be read as
a boundary; the parser removes exactly that one space again.  An entry is
everything from its headline to the next, so a prompt keeps its blank lines."
  (let* ((prompts (list "plain one"
                        "two\nlines\n  indented\n* star at column 0"
                        ":END: here\n\nand a blank line above"))
         (pair (ao--queued prompts)))
    (with-current-buffer (car pair)
      (should (equal prompts (agent-org-buffer-queue-parse nil)))
      ;; and only the entries are entries: three prompts, three headlines,
      ;; even though one of them is about Org drawers
      (should (= 3 (length (agent-org-buffer--queue-headlines)))))
    (kill-buffer (car pair))))

(ert-deftest test-agent-org-queue-reads-retired-words-and-writes-next-wait ()
  "A PROMPT/TODO file from before this vocabulary still gives up its prompts.
Yesterday's queue is the user's own text: losing a prompt because the word on it
changed is not a migration, it is a deletion.  So the READER takes every spelling
the package has shipped and the WRITER uses only NEXT/WAIT -- which means an old
file converges the first time its queue is redrawn, with no migration pass and no
version stamp to check."
  (let ((old (concat agent-org-buffer--queue-note-text
                     "* PROMPT finish the tests\n"
                     "* TODO then check the build\n second line\n")))
    (should (equal '("finish the tests" "then check the build\nsecond line")
                   (agent-org-buffer--queue-parse-text old)))
    ;; and re-rendering what that file held cannot write the retired words back
    (let ((pair (ao--queued (agent-org-buffer--queue-parse-text old))))
      (with-current-buffer (car pair)
        (should (equal '("* NEXT finish the tests" "* WAIT then check the build")
                       (ao--queue-headings))))
      (kill-buffer (car pair)))))

(ert-deftest test-agent-org-queue-parse-is-confined-to-the-region ()
  "Only queue keywords are entries, and only inside the region.
An agent's answer can contain anything, and a turn's own heading is the user's
prompt: neither may be read as a queued prompt, or a resume would send the
conversation back at the agent."
  (let* ((pair (ao--make-test-session "q-region"))
         (buf (car pair)))
    (unwind-protect
        (with-current-buffer buf
          (agent-org-buffer-insert-prompt buf)
          (setf (plist-get (cdr pair) :pending-prompts) '("waiting"))
          (agent-org--queue-refresh (cdr pair) buf)
          (agent-org-buffer-begin-exchange buf "a question about * TODO text")
          (agent-org-buffer-insert-tool
           buf '((toolCallId . "t1") (title . "run * TODO now") (status . "pending")))
          (should (equal '("waiting") (agent-org-buffer-queue-parse nil))))
      (kill-buffer (car pair)))))

(ert-deftest test-agent-org-queue-move-restates-the-words-for-the-new-order ()
  "M-DOWN moves an entry, and the words FOLLOW it.
The keyword now says WHERE a prompt sits in the send order -- NEXT for the one
that goes out first, WAIT for the rest -- so a move that left the words alone
would leave a `* NEXT' heading sitting second, promising to be the next prompt
out while another one really is.  `agent-org-buffer-queue-restate' is what keeps
that from ever being on the page: the WORDS are derived from position and
rewritten after the move, while the prompts themselves come back byte-identical,
so nothing the user typed is touched."
  (let ((pair (ao--queued '("one" "two" "three"))))
    (with-current-buffer (car pair)
      (should (equal '("* NEXT one" "* WAIT two" "* WAIT three")
                     (ao--queue-headings)))
      (goto-char (point-min))
      (search-forward "* NEXT one")
      (agent-org-buffer-queue-move-down)
      (should (equal '("two" "one" "three") (agent-org-buffer-queue-parse nil)))
      (should (equal '("* NEXT two" "* WAIT one" "* WAIT three")
                     (ao--queue-headings)))
      ;; moving the LAST entry up puts NEXT on whatever is left at the bottom
      (goto-char (point-min))
      (search-forward "* WAIT three")
      (agent-org-buffer-queue-move-up)
      (should (equal '("two" "three" "one") (agent-org-buffer-queue-parse nil)))
      (should (equal '("* NEXT two" "* WAIT three" "* WAIT one")
                     (ao--queue-headings)))
      ;; and the words agree with the order in every state: one NEXT, at the top
      (should (equal "two" (car (agent-org-buffer-queue-parse nil))))
      (should (string-prefix-p "* NEXT " (car (ao--queue-headings)))))
    (kill-buffer (car pair))))

(ert-deftest test-agent-org-queue-move-is-refused-outside-the-region ()
  "M-UP in the CONVERSATION is still the blocker: a chat body is not re-orderable.
The narrowing is by point, not a lifted block, so the conversation's heading
boundaries -- what locates every turn -- stay untouchable."
  (let ((pair (ao--queued '("one" "two"))))
    (with-current-buffer (car pair)
      (goto-char (point-min))
      (should-error (agent-org-buffer-queue-move-up) :type 'user-error)
      ;; the command form too: point is not in the region, so it refuses
      (goto-char (point-min))
      (should-error (agent-org-buffer-queue-move-up) :type 'user-error))
    (kill-buffer (car pair))))

(ert-deftest test-agent-org-queue-add-makes-a-slot-at-the-bottom ()
  "C-c a a appends a blank entry at the bottom and lands point in it.
A blank entry is dropped on parse, so composing one cannot send a blank -- and
appending it last needs no restating: the word it wears is the position word
for `not the next one', which is exactly where a bottom slot sits."
  (let ((pair (ao--queued '("one"))))
    (with-current-buffer (car pair)
      (agent-org-buffer-queue-add)
      (should (equal '("* NEXT one" "* WAIT ") (ao--queue-headings)))
      (should (equal '("one") (agent-org-buffer-queue-parse nil)))
      ;; typing into the slot makes it an entry, still last
      (end-of-line)
      (insert "another")
      (should (equal '("one" "another") (agent-org-buffer-queue-parse nil))))
    (kill-buffer (car pair))))

(ert-deftest test-agent-org-queue-kill-removes-one-entry ()
  "C-c a d kills the entry at point and the rest keep their order.
Killing the MIDDLE entry changes no position: the head still says NEXT and the
one behind it still says WAIT, so nothing has to be re-stated."
  (let ((pair (ao--queued '("one" "two" "three"))))
    (with-current-buffer (car pair)
      (goto-char (point-min))
      (search-forward "* WAIT two")
      (agent-org-buffer-queue-kill)
      (should (equal '("one" "three") (agent-org-buffer-queue-parse nil)))
      (should (equal '("* NEXT one" "* WAIT three") (ao--queue-headings))))
    (kill-buffer (car pair))))

(ert-deftest test-agent-org-queue-kill-of-the-last-entry-keeps-the-box ()
  "C-c a d on the BOTTOM entry stops at the region, not at `point-max'.
The entries are level-1 headings and so is the `* PROMPT' box, so the last
entry's subtree as Org sees it ran to the end of the buffer: the kill took
`kill-region' through the frozen box and answered `text-read-only' -- the prompt
stayed, and the draft typed below it was in the way of the attempt.  A move down
from the same entry went further and pushed the prompt BELOW the box, off the
region and so off the page."
  (let* ((pair (ao--make-test-session "q-kill-last"))
         (buf (car pair)))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (agent-org-buffer-insert-prompt buf)
            (goto-char (point-max))
            (insert "MY DRAFT"))
          (setf (plist-get (cdr pair) :pending-prompts) '("one" "two"))
          (agent-org--queue-refresh (cdr pair) buf)
          (with-current-buffer buf
            (goto-char (car (last (agent-org-buffer--queue-headlines))))
            (agent-org-buffer-queue-kill)
            (should (equal '("one") (agent-org-buffer-queue-parse nil)))
            (should (agent-org-buffer--open-prompt-p))
            (should (string-suffix-p "MY DRAFT"
                                     (buffer-substring-no-properties
                                      (point-min) (point-max))))
            ;; the region still ends where the box begins
            (should (<= (cdr (agent-org-buffer--queue-region))
                        (agent-org-buffer--live-mark
                         agent-org-buffer--prompt-anchor)))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-queue-refresh-is-idempotent ()
  "Re-rendering the same queue leaves one copy of every entry.
The region is delete-then-insert between two markers, so a refresh at a turn
boundary cannot append a second `* NEXT one' -- the failure mode a reader would
see as a prompt sent twice."
  (let* ((pair (ao--queued '("one" "two")))
         (chat (car pair))
         (session (cdr pair)))
    (dotimes (_ 3)
      (agent-org--queue-refresh session chat))
    (with-current-buffer chat
      (should (equal '("one" "two") (agent-org-buffer-queue-parse nil)))
      (should (= 1 (ao--count-occurrences (buffer-string) "^\\* NEXT one$"))))
    (kill-buffer chat)))

(ert-deftest test-agent-org-queue-refresh-never-lands-after-the-box ()
  "The entries stay ABOVE the live box, even when a queue arrives mid-turn.
`--render-end' answers with the queue's own start marker, so a turn rendered
while a queue waits lands above the queue and the box stays last."
  (let* ((pair (ao--make-test-session "q-anchor"))
         (buf (car pair))
         (session (cdr pair)))
    (unwind-protect
        (with-current-buffer buf
          (agent-org-buffer-insert-prompt buf)
          (setf (plist-get session :pending-prompts) '("waiting"))
          (agent-org--queue-refresh session buf)
          ;; the user typed a draft, and a turn renders above the queue
          (goto-char (point-max))
          (insert "draft")
          (agent-org-buffer-append-thought buf "thinking")
          (should (apply #'ao--ordered (buffer-string)
                         (list "* NEXT waiting" "* PROMPT"))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-queue-drain-leaves-the-rest-waiting ()
  "When a queued prompt goes out, the one behind it BECOMES the head.
The word carries the position: the survivor was `WAIT' and must be re-stated
as `* NEXT' -- the prompt that goes out when this turn ends -- because a
drifted word is a lie about the send order, not a harmless label.  That is
the cost of positional words, and the restating is what a drain owes the page."
  (let* ((pair (ao--make-test-session "q-drain-word"))
         (buf (car pair))
         (session (cdr pair))
         (sent nil))
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest kw) (push kw sent)))
              ((symbol-function 'acp-make-session-prompt-request)
               (lambda (&rest a) (plist-get a :prompt))))
      (setf (plist-get session :pending-prompts) '("first" "second"))
      (agent-org--queue-refresh session buf)
      (with-current-buffer buf
        (agent-org-buffer-insert-prompt buf)
        (agent-org--drain-queue session buf)
        (should (equal '("second") (agent-org-buffer-queue-parse nil)))
        (should (equal '("* NEXT second") (ao--queue-headings)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-queue-refresh-never-undoes-a-move ()
  "A re-order survives the next refresh, because the BASELINE is what moves.
The obvious fix --- re-state `--queue-shown' after a move so the region looks
touched --- is the bug: then the region reads as unedited again and the next
refresh paints the session's old order straight back over the user's gesture."
  (let* ((pair (ao--queued '("one" "two")))
         (chat (car pair))
         (session (cdr pair)))
    (with-current-buffer chat
      (goto-char (point-min))
      (search-forward "* NEXT one")
      (agent-org-buffer-queue-move-down)
      (should (equal '("two" "one") (agent-org-buffer-queue-parse nil)))
    ;; a refresh with a queue the session still thinks is the old one
    (agent-org--queue-refresh session chat)
    (with-current-buffer chat
      (should (equal '("two" "one") (agent-org-buffer-queue-parse nil)))
      ;; the move RE-STATED the positional words: what waits first now says
      ;; NEXT, and the prompt pushed behind it says WAIT
      (should (equal '("* NEXT two" "* WAIT one") (ao--queue-headings))))
    ;; and applying is what makes the session agree
    (with-current-buffer chat
      (agent-org-queue-apply))
    (should (equal '("two" "one") (plist-get session :pending-prompts)))
    (kill-buffer chat))))

(ert-deftest test-agent-org-queue-refresh-keeps-a-fresh-slot ()
  "A blank `* NEXT' slot in an EMPTY queue is not clobbered by a refresh.
The parser drops a blank entry, so a guard that compared parsed lists would
call this region untouched --- and a prompt queued a moment later would delete
the half-typed prompt in it.  The guard compares raw TEXT for exactly this.

The arrival still has to SHOW: it goes on the end of the region -- behind the
slot the user is typing in, wearing the word for its position (WAIT: the slot
he is composing in still goes first) -- and the half-typed words stay where
the user left them."
  (let* ((pair (ao--make-test-session "q-slot"))
         (buf (car pair)))
    (unwind-protect
        (with-current-buffer buf
          (agent-org-queue-edit)
          (should (equal '("* NEXT ") (ao--queue-headings)))
          (insert "half-typed")
          ;; the session gains a prompt while the slot is being typed
          (setf (plist-get (cdr pair) :pending-prompts) '("from the box"))
          (agent-org--queue-refresh (cdr pair) buf)
          (should (equal '("half-typed" "from the box")
                         (agent-org-buffer-queue-parse buf)))
          (should (equal '("* NEXT half-typed" "* WAIT from the box")
                         (ao--queue-headings))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-queue-refresh-leaves-an-edit-alone ()
  "A queue that changes while the user is editing is NOT repainted over him.
The region is the user's text: a drain that arrives mid-edit would otherwise
delete a half-typed prompt.  So a repaint happens only while the region still
reads as what was last written into it."
  (let* ((pair (ao--queued '("one" "two")))
         (chat (car pair))
         (session (cdr pair)))
    (with-current-buffer chat
      (goto-char (point-min))
      (search-forward "* NEXT one")
      (end-of-line)
      (insert " -- edited"))
    ;; the session's list moved on while the user was typing
    (setf (plist-get session :pending-prompts) '("two"))
    (agent-org--queue-refresh session chat)
    (with-current-buffer chat
      (should (equal '("one -- edited" "two")
                     (agent-org-buffer-queue-parse nil)))
      (should (string-match-p "^\\* NEXT one -- edited$" (buffer-string))))
    (kill-buffer chat)))

(ert-deftest test-agent-org-drain-reaps-the-sent-entry-from-a-dirty-region ()
  "A prompt the agent took off an EDITED queue leaves the page as well.
The live complaint: \"Prompt queue is not updating automatically.\"  The edit
guard (`agent-org-buffer-refresh-queue') is right to stop a REPAINT deleting the
user's words -- but it stopped the DRAINED entry from disappearing too, so a
chat he had reordered or edited went on showing a prompt the agent had already
answered, and `--queue-shown' kept its stale text forever (which then made
`--queue-minus' swallow any later prompt with the same words).

What gets reaped is only an entry whose text is STILL exactly what this package
painted -- the entry the user touched is his and stays, which is what
`test-agent-org-queue-refresh-leaves-an-edit-alone' already pins."
  (let* ((pair (ao--make-test-session "q-reap"))
         (buf (car pair))
         (session (cdr pair))
         (sent nil))
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest kw) (push kw sent)))
              ((symbol-function 'acp-make-session-prompt-request)
               (lambda (&rest a) (plist-get a :prompt))))
      (with-current-buffer buf
        (agent-org-buffer-insert-prompt buf))
      (setf (plist-get session :pending-prompts) '("two" "three"))
      (agent-org--queue-refresh session buf)
      (with-current-buffer buf
        ;; he edits the LAST entry: from here the region is his text
        (goto-char (point-min))
        (search-forward "three")
        (end-of-line)
        (insert " -- his words")
        (should-not (agent-org-buffer--queue-pristine-p)))
      ;; the turn ends: "two" goes out, the session keeps ("three")
      (agent-org--drain-queue session buf)
      (should (equal '("three") (plist-get session :pending-prompts)))
      (with-current-buffer buf
        (should (equal '("three -- his words")
                       (agent-org-buffer-queue-parse nil)))
        (should-not (member "two" agent-org-buffer--queue-shown))
        (should (string-match-p "three -- his words" (buffer-string)))
        ;; the drained prompt is an EXCHANGE above the region now, not an entry
        ;; in it -- matched on a heading line ending in its words, because which
        ;; state word it wears is the exchange heading's own business (§19)
        (should (save-excursion
                  (goto-char (point-min))
                  (re-search-forward "^[*] .*two$"
                                     (car (agent-org-buffer--queue-region)) t)))
        (should (agent-org-buffer--open-prompt-p)))
      (should (apply #'ao--ordered (with-current-buffer buf (buffer-string))
                     (list "two" "three -- his words" "\\* PROMPT"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-drain-clears-a-dirty-region-when-the-queue-empties ()
  "Draining the last prompt of an EDITED queue leaves no region behind.
A touch is a touch, so the region goes dirty and the old append-only refresh
could never take its entries back: the drained prompts stayed on the page -- and
their texts stayed in `--queue-shown', which then made every later refresh
compare against a baseline that no longer existed -- after the session held
nothing.  Both go now, and the region goes with them, so a chat that has drained
its last prompt has no queue block in its transcript at all.

The reap also gives the region BACK: once the entries it painted are gone, what
is left is byte-for-byte what the renderer wrote, so the ordinary repaints
resume without the user having to restore anything."
  (let* ((pair (ao--make-test-session "q-clear"))
         (buf (car pair))
         (session (cdr pair))
         (sent nil))
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest kw) (push kw sent)))
              ((symbol-function 'acp-make-session-prompt-request)
               (lambda (&rest a) (plist-get a :prompt))))
      (with-current-buffer buf
        (agent-org-buffer-insert-prompt buf))
      (setf (plist-get session :pending-prompts) '("two" "three"))
      (agent-org--queue-refresh session buf)
      (with-current-buffer buf
        ;; a stray space at the end of a heading: the region is HIS now, but
        ;; every prompt on it is still word-for-word what was painted
        (goto-char (point-min))
        (search-forward "two")
        (end-of-line)
        (insert " ")
        (should-not (agent-org-buffer--queue-pristine-p))
        (should (equal '("two" "three") (agent-org-buffer-queue-parse nil))))
      (agent-org--drain-queue session buf)     ; "two" out, ("three") left
      (with-current-buffer buf
        (should (equal '("three") (agent-org-buffer-queue-parse nil)))
        (should (agent-org-buffer--queue-pristine-p)))
      (agent-org--drain-queue session buf)     ; "three" out, nothing left
      (should (equal '("two" "three") (ao--sent-texts sent)))
      (should-not (plist-get session :pending-prompts))
      (with-current-buffer buf
        (should-not (agent-org-buffer-queue-p))
        (should-not agent-org-buffer--queue-shown)
        (should (= 0 (ao--count-substrings "Prompts waiting to be sent")))
        (should (agent-org-buffer--open-prompt-p))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-queue-refresh-drops-a-region-holding-nothing ()
  "A region with no entries in it is not shown, even when it still has a border.
The residue the live bug leaves behind: entries deleted by hand, the preamble
comments and the hyphen rule still on the page, the session's queue empty, and
`--queue-shown' still naming prompts that were answered long ago.  The next
refresh now clears it instead of going on appending to it -- which is also what
makes a chat that has just drained its last prompt lose the block from its
transcript.

A blank slot he is typing into is NOT that region: it has a headline, and his
half-typed prompt is worth more than a tidy buffer."
  (let* ((pair (ao--queued '("one" "two")))
         (chat (car pair))
         (session (cdr pair)))
    (with-current-buffer chat
      ;; he deletes both entries by hand, leaving the preamble standing
      (dolist (at (reverse (agent-org-buffer--queue-headlines)))
        (delete-region at (save-excursion (goto-char at)
                                          (line-beginning-position 2))))
      (should-not (agent-org-buffer-queue-parse nil))
      (should (string-match-p "Prompts waiting to be sent" (buffer-string)))
      (setf (plist-get session :pending-prompts) nil)
      (agent-org--queue-refresh session chat)
      (should-not (agent-org-buffer-queue-p))
      (should-not agent-org-buffer--queue-shown)
      (should-not (string-match-p "Prompts waiting to be sent" (buffer-string))))
    (kill-buffer chat)))

;;;; The rule line above the `* PROMPT' box: ALWAYS, not only with a queue
;;
;; User order (2026-10-11): "The separator above user prompt heading should
;; ALWAYS show, not when a prompt is queued."  The border used to belong to the
;; QUEUE REGION's preamble, so a chat with nothing waiting ended in a bare
;; `* PROMPT' glued to the last exchange.  The box now owns its own rule, inside
;; its frozen prefix and above its anchor, so it can never be typed over and no
;; render can land between the rule and the heading.

(defun ao--rule-count (string)
  "How many Org horizontal rules (a line of 5+ hyphens) STRING holds."
  (ao--count-occurrences string "^-\\{5,\\}$"))

(ert-deftest test-agent-org-user-box-carries-its-rule-with-nothing-queued ()
  "An empty queue still shows the border above the box.
Three things ride on the box owning the rule rather than the queue
region: it is FROZEN like the heading (a decoration is not a thing to
type over), it sits ABOVE the render anchor (so a streaming turn cannot
glue itself between rule and box), and it is below the mirror end (so it
never reaches the transcript, which is the conversation)."
  (let ((buf (agent-org-buffer-create "baserule")))
    (agent-org-buffer-insert-prompt buf)
    (with-current-buffer buf
      (let ((body (buffer-substring-no-properties (point-min) (point-max))))
        (should (= 1 (ao--rule-count body)))
        (should (apply #'ao--ordered body (list "^-\\{5,\\}$" "^\\* PROMPT$"))))
      (save-excursion
        (goto-char (point-min))
        (re-search-forward "^-\\{5,\\}$")
        (let ((rule (match-beginning 0)))
          ;; the rule is TYPEABLE now (2026-10-13, user order):
          ;; \"EVERYTHING below the separator MUSTN'T be read-only\".  What it
          ;; keeps is its POSITION: the anchor is at or above the rule, so
          ;; `--render-end' is too
          (should (ao--insertable-p rule))
          (should (<= (agent-org-buffer--render-end) rule))
          ;; and the mirrored conversation (point-min..render end) has no rule
          (should-not (string-match-p "^-\\{5,\\}$"
                                      (buffer-substring-no-properties
                                       (point-min) (agent-org-buffer--render-end)))))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-inserting-the-prompt-twice-adds-one-rule ()
  "The box is idempotent about its border, as it already is about its heading.
Every turn boundary calls `agent-org-buffer-insert-prompt', and the queue
refresh calls it after clearing a region, so a rule counted twice is a
page full of rules."
  (let ((buf (agent-org-buffer-create "tworule")))
    (agent-org-buffer-insert-prompt buf)
    (agent-org-buffer-insert-prompt buf)
    (with-current-buffer buf
      (should (agent-org-buffer--open-prompt-p))
      (should (= 1 (ao--rule-count (buffer-substring-no-properties (point-min) (point-max)))))
      (should (= 1 (ao--count-occurrences (buffer-string) "^\\* PROMPT$"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-a-turn-renders-above-the-boxs-own-rule ()
  "The rule stays glued to the heading while an answer streams.
The failure this pins is the one the anchor exists to stop: a chunk
inserted at the render end would land /below/ the rule and split the
border from the box it belongs to."
  (let* ((pair (ao--make-test-session "renderule"))
         (buf (car pair))
         (session (cdr pair)))
    (agent-org-buffer-insert-prompt buf)
    (agent-org-buffer-start-agent-turn buf session)
    (agent-org-buffer-append-chunk buf "Paris.\n" session)
    (with-current-buffer buf
      (should (apply #'ao--ordered (buffer-string)
                    (list "Paris" "^-\\{5,\\}$" "^\\* PROMPT$")))
      ;; still exactly one rule, still one blank line between it and the box
      (should (= 1 (ao--rule-count (buffer-substring-no-properties
                                    (point-min) (point-max)))))
      (should (string-match-p "^-\\{5,\\}\n\n\\* PROMPT$" (buffer-string))))
    (agent-org-buffer-end-agent-turn buf)
    (kill-buffer buf)))

(ert-deftest test-agent-org-queue-region-and-the-box-each-own-a-rule ()
  "With prompts waiting there are TWO borders, and the box's is the last.
The region's rule is the border against the read-only conversation above
it (the order that asked for it), and the box's is the one above the
heading he types in -- the two are different borders with different
jobs, and the queue's own preamble must not be the only way to see one.
The region also keeps its comments, and the box stays the last thing."
  (let* ((pair (ao--queued '("one" "two")))
         (chat (car pair))
         (session (cdr pair)))
    ;; the live order is box first (it arrives with Ready) and region painted
    ;; above it afterwards; `ao--queued' has no box, so open one and re-refresh
    (agent-org-buffer-insert-prompt chat)
    (agent-org--queue-refresh session chat)
    (with-current-buffer chat
      (let ((body (buffer-substring-no-properties (point-min) (point-max))))
        (should (= 2 (ao--rule-count body)))
        (should (apply #'ao--ordered body
                       (list "^-\\{5,\\}$"
                             "# Prompts waiting to be sent"
                             "^\\* NEXT one$"
                             "^-\\{5,\\}$"
                             "^\\* PROMPT$")))
        ;; the box's rule is the LAST rule on the page, and it is the box's
        ;; own: nothing at all sits between it and the heading
        (should (apply #'ao--ordered (buffer-string)
                       (list "^-\\{5,\\}$" "^\\* PROMPT$" "\\'")))
        (should (= 2 (ao--rule-count (buffer-substring-no-properties
                                      (point-min) (point-max)))))))
    (kill-buffer chat)))

(ert-deftest test-agent-org-queue-shows-every-prompt-that-arrives-mid-edit ()
  "The header says N queued, so the page shows N entries -- always.
The live bug the user reported: \"All prompts in queue are not showing at the
bottom.  Only one shows, but the header line says 3 queued.\"  The count and the
entries are two projections of the SAME list, and the edit guard
(`agent-org-buffer--queue-shown') stopped the entries being painted while the
region was dirty, so a chat the user was typing in silently displayed fewer
prompts than it held.  Arrivals now APPEND: the guard still protects his words
from a rewrite, and nothing he can be told about is invisible.

Three things this pins: every arrival shows, a re-ordered/edited entry is NOT
rewritten, and an arrival already on the page is never duplicated by the next
refresh."
  (let* ((pair (ao--queued '("one" "two")))
         (chat (car pair))
         (session (cdr pair)))
    (with-current-buffer chat
      ;; the user is in the middle of editing the first entry
      (goto-char (point-min))
      (search-forward "* NEXT one")
      (end-of-line)
      (insert " -- mine"))
    ;; a third prompt arrives from the live box while the region is dirty
    (agent-org--queue-enqueue session chat "three")
    (with-current-buffer chat
      (should (equal '("* NEXT one -- mine" "* WAIT two" "* WAIT three")
                     (ao--queue-headings)))
      (should (equal '("one -- mine" "two" "three")
                     (agent-org-buffer-queue-parse nil)))
      ;; and the header's count agrees with what is on the page
      (should (= 3 (length (plist-get (buffer-local-value
                                       'agent-org-buffer--status chat)
                                      :queued))))
      ;; a refresh with the SAME list adds nothing (idempotent, no duplicates)
      (agent-org--queue-refresh session chat)
      (agent-org--queue-refresh session chat)
      (should (equal '("* NEXT one -- mine" "* WAIT two" "* WAIT three")
                     (ao--queue-headings)))
      ;; a prompt the user DELETED stays deleted -- it is not an arrival
      (goto-char (point-min))
      (search-forward "* WAIT two")
      (agent-org-buffer-queue-kill)
      (agent-org--queue-enqueue session chat "four")
      (should (equal '("one -- mine" "three" "four")
                     (agent-org-buffer-queue-parse nil))))
    (kill-buffer chat)))

(ert-deftest test-agent-org-queue-enqueue-queues-from-the-minibuffer ()
  "Port of `agent-shell-prompt-queue': queue without leaving where you are.
It ALWAYS queues, idle or not -- the verb that asks for an answer now is
`agent-org-send', and one whose behaviour depends on the agent's mood is a coin
toss in muscle memory.  A blank answer is refused rather than queued."
  (let* ((pair (ao--make-test-session "q-enq"))
         (chat (car pair))
         (session (cdr pair)))
    (unwind-protect
        (with-current-buffer chat
          (agent-org-buffer-insert-prompt chat)
          (goto-char (point-min))
          (agent-org-queue-enqueue "from the command")
          (should (equal '("from the command")
                         (plist-get session :pending-prompts)))
          (should (equal '("* NEXT from the command") (ao--queue-headings)))
          ;; and it did not drag point to the bottom of the chat to do it
          (should (= 1 (line-number-at-pos)))
          (should-error (agent-org-queue-enqueue "   ") :type 'user-error)
          (should (equal '("from the command")
                         (plist-get session :pending-prompts))))
      (kill-buffer chat))))

(ert-deftest test-agent-org-queue-remove-takes-the-numbered-entry-everywhere ()
  "Port of `agent-shell-prompt-queue-remove': 1-based, confirmed, BOTH halves.
The number is the queue's order, and the removal has to reach the session's
list AND the page: a region the user has edited is never repainted from the
list, so a removal that only touched the list would leave the prompt sitting at
the bottom of the chat and put it back on the queue at the next apply."
  (let* ((pair (ao--queued '("one" "two" "three")))
         (chat (car pair))
         (session (cdr pair)))
    (unwind-protect
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
          (with-current-buffer chat
            (agent-org-queue-remove "2"))
          (should (equal '("one" "three") (plist-get session :pending-prompts)))
          (with-current-buffer chat
            (should (equal '("* NEXT one" "* WAIT three") (ao--queue-headings))))
          ;; declining says so and deletes nothing
          (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
            (with-current-buffer chat
              (should-error (agent-org-queue-remove "1") :type 'user-error)))
          (should (equal '("one" "three") (plist-get session :pending-prompts)))
          ;; the picker is offered the numbers and an ALL choice
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (prompt collection &rest args)
                       (should (string-match-p "1-2" prompt))
                       (should (member "Remove all (2)" collection))
                       "2")))
            (with-current-buffer chat
              (agent-org-queue-remove))
            (should (equal '("one") (plist-get session :pending-prompts)))))
      (kill-buffer chat))))

(ert-deftest test-agent-org-queue-remove-all-leaves-no-trace ()
  "`all' empties the queue in the session, on the page and in the header.
The page is the case that needs asserting: the region is DIRTY as soon as the
user has typed in it, and a dirty region is only ever appended to -- so an empty
session list would otherwise keep showing entries that no longer exist."
  (let* ((pair (ao--queued '("one" "two")))
         (chat (car pair))
         (session (cdr pair)))
    (unwind-protect
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
          (with-current-buffer chat
            (agent-org-queue-remove "all"))
          (should (null (plist-get session :pending-prompts)))
          (with-current-buffer chat
            (should-not (agent-org-buffer-queue-p))
            (should (equal '() (ao--queue-headings)))
            (should-not (plist-get (buffer-local-value
                                    'agent-org-buffer--status chat)
                                   :queued))))
      (kill-buffer chat))))

(ert-deftest test-agent-org-queue-list-numbers-prompts-for-removal ()
  "Port of agent-shell's queue DISPLAY, as a command of its own.
The entries sit at the bottom of a long chat, so \"what is still queued?\" must
not cost an end-of-buffer -- and the numbers printed here are exactly the ones
`agent-org-queue-remove' asks for."
  (let* ((pair (ao--queued '("first prompt" "second one\nwith its own body")))
         (chat (car pair)))
    (unwind-protect
        (with-current-buffer chat
          ;; recorded inline: `ao--capture-messages' is defined further down this
          ;; file and an ert-deftest is macro-expanded as it is LOADed, so a test
          ;; placed before it cannot use the macro.
          (let ((seen nil))
            (cl-letf (((symbol-function 'message)
                       (lambda (format-string &rest args)
                         (push (apply #'format format-string args) seen))))
              (agent-org-queue-list)
              (should (equal 1 (length seen)))
              (should (string-match-p " 1: first prompt" (car seen)))
              (should (string-match-p " 2: second one" (car seen)))
              ;; a multi-line prompt is shown as ONE line, and counted once
              (should (string-match-p "2 queued" (car seen)))
              (should-not (string-match-p "own body" (car seen)))))
          (agent-org-queue--set (cdr pair) chat nil)
          (let ((seen nil))
            (cl-letf (((symbol-function 'message)
                       (lambda (format-string &rest args)
                         (push (apply #'format format-string args) seen))))
              (agent-org-queue-list)
              (should (equal "[agent-org] nothing queued" (car seen))))))
      (kill-buffer chat))))

(ert-deftest test-agent-org-queue-apply-drops-what-the-agent-already-sent ()
  "A prompt that went out mid-edit is removed BY TEXT on apply.
By position it would be wrong twice over: the user may have moved that entry
anywhere, and the drain took the front of the SESSION's list."
  (let* ((pair (ao--queued '("one" "two")))
         (chat (car pair))
         (session (cdr pair)))
    (with-current-buffer chat
      ;; the agent answers, so "one" goes out and the queue holds "two"
      (setf (plist-get session :pending-prompts) '("two"))
      (agent-org-buffer-begin-exchange chat "one")
      (agent-org--queue-note chat 'agent-org-buffer--queue-sent "one")
      ;; and the region still shows both, with the user's re-ordering
      (goto-char (point-min))
      (search-forward "* WAIT two")
      (agent-org-buffer-queue-move-up))
    (with-current-buffer chat
      (agent-org-queue-apply))
    ;; the entry the user moved UP is still the prompt the agent took, so the
    ;; queue is what is left: one prompt, and it is the one that waited
    (should (equal '("two") (plist-get session :pending-prompts)))
    (kill-buffer chat)))

(ert-deftest test-agent-org-queue-apply-keeps-what-arrived-mid-edit ()
  "A prompt typed into the box mid-edit is on the page and applied ONCE.
It used to be invisible until the apply, which is why the apply had to keep a
separate note of arrivals and put them back at the end.  The region now shows
every arrival (`agent-org-buffer-refresh-queue'), so the region alone is the
queue and a second copy from a note would be a duplicate send."
  (let* ((pair (ao--queued '("one")))
         (chat (car pair))
         (session (cdr pair)))
    (with-current-buffer chat
      (goto-char (point-min))
      (search-forward "* NEXT one")
      (end-of-line)
      (insert " -- edited"))
    ;; the real path: the box gets a prompt while the region is being edited
    (agent-org--queue-enqueue session chat "fresh")
    (with-current-buffer chat
      ;; the arrival is APPENDED below the user's text and wears the word for
      ;; the position it took: it is no longer the head, the edited entry is
      (should (member "* WAIT fresh" (ao--queue-headings)))
      (agent-org-queue-apply))
    (should (equal '("one -- edited" "fresh") (plist-get session :pending-prompts)))
    (kill-buffer chat)))

(ert-deftest test-agent-org-queue-edit-goes-to-the-entries ()
  "C-c a q puts point on the waiting prompts, and makes one when there are none.
An empty queue is not an error and not a no-op: a blank `* NEXT' slot is where
the next thing to ask gets written, and it is dropped on apply if left empty."
  (let* ((pair (ao--make-test-session "q-edit"))
         (buf (car pair)))
    (unwind-protect
        (with-current-buffer buf
          (should-not (agent-org-buffer-queue-p buf))
          (agent-org-queue-edit)
          (should (agent-org-buffer-queue-p buf))
          (should (equal '("* NEXT ") (ao--queue-headings)))
          ;; a second call does not stack regions
          (agent-org-queue-edit)
          (should (equal '("* NEXT ") (ao--queue-headings))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-queue-edit-refuses-a-non-chat-buffer ()
  "`agent-org-queue-edit' in a buffer with no session says so."
  (with-temp-buffer
    (should-error (agent-org-queue-edit) :type 'user-error)))

(ert-deftest test-agent-org-queue-note-uses-org-comments-under-a-rule ()
  "The region's preamble is Org `#' comments below a rule line, never `;;'.
The user's correction: \"Org uses =#= for comments, not =;=.  Fix queue
comment.\"  `;;' is what a Lisp or shell buffer would use; in Org a line
starting that way is ordinary TEXT, so it renders as part of the document -- and
because the queue is mirrored into every transcript, it put a fake paragraph at
the bottom of every conversation file the user shares.

The RULE line above it is his other order: \"ensure the portion for prompt queue
has clear border against the read-only portion of the buffer above\".  Org makes
a line of five or more hyphens a horizontal rule on export (info \"(org)
Horizontal rules\"), so the border is real markup and not a decoration the
parser would trip over.

The block is pinned together with its reader: `agent-org-buffer-transcript-queue'
finds the mirrored block by quoting THIS text, so the two cannot drift."
  (let ((pair (ao--queued '("one"))))
    (with-current-buffer (car pair)
      (let ((lines (split-string (agent-org-buffer--queue-region-text)
                                 "\n" t)))
        ;; a rule line first, then comment lines, then the entries
        (should (string-match-p "\\`-\\{5,\\}\\'" (car lines)))
        (dolist (line (cdr lines))
          (cond ((string-prefix-p "# " line) nil)
                ((string-match-p "\\`\\* \\(NEXT\\|WAIT\\|PROMPT\\|TODO\\) " line)
                 (should (string-prefix-p "* NEXT one" line)))
                (t (signal 'ert-test-failed
                           (list 'queue-line-neither-rule-nor-comment line)))))
        (should-not (string-match-p "^;;" (agent-org-buffer--queue-region-text)))))
    (kill-buffer (car pair))))

(ert-deftest test-agent-org-queue-region-is-typeable-at-every-position ()
  "The queue stays editable: at its first char, its last, and BETWEEN them.
THE bug the user reported -- \"I can't even delete as it says read-only\" -- and
the mechanism is not a property ON the region at all, so no reading of the
region's own text would have found it.  Emacs spreads properties across an
insertion from the character on EACH side of it: the char before sticks through
unless it says `rear-nonsticky', the char after sticks if it says
`front-sticky'.  Both of the region's neighbours are frozen text -- the
conversation above and the `* PROMPT' box below -- and both were leaking
`read-only' INTO the queue: the box's first char, at exactly `--queue-end',
refused typing on the region's last line, and the line above `--queue-start'
refused it on the region's first line.  So the guarantee is asserted at the four
positions a user actually types at, in the real layout -- a rendered turn above
and a live box below -- rather than as a claim about properties."
  (let* ((pair (ao--make-test-session "q-editable"))
         (buf (car pair))
         (session (cdr pair)))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (agent-org-buffer-insert-prompt buf)
            (setf (plist-get session :pending-prompts) '("first" "second"))
            (agent-org--queue-refresh session buf)
            ;; a turn rendered AFTER the region exists is the case that matters:
            ;; it goes in above `--render-end' == `--queue-start' and freezes up
            ;; to that position, which is where the region's first char is
            (agent-org-buffer-begin-exchange buf "a question")
            (agent-org-buffer-append-chunk buf "an answer" session)
            (let* ((region (agent-org-buffer--queue-region))
                   (spots (agent-org-buffer--queue-headlines)))
              (should (> (length spots) 1))
              ;; the region's first byte, the last entry's own line, and every
              ;; line in between -- NOT at `(cdr region)', which is the first
              ;; character of the `* PROMPT' box and is frozen on purpose
              (should (ao--insertable-p (car region)))
              (should (ao--insertable-p (1- (cdr region))))
              (dolist (at spots)
                (goto-char at)
                (should (ao--insertable-p (line-end-position)))
                (forward-line 1)
                ;; the last entry's NEXT line is the box's heading, and the two
                ;; sides of that edge are both the guarantee: typeable anywhere
                ;; inside the region, refused exactly at its end
                (if (< (point) (cdr region))
                    (should (ao--insertable-p (point)))
                  (should (= (point) (cdr region)))
                  (should-not (ao--insertable-p (point)))))
              ;; the box below is still open and still typeable where it should be
              (should (agent-org-buffer--open-prompt-p))))
          ;; and the freeze the region sits between is REAL: INSIDE the box's own
          ;; heading typing is still refused, so making the queue editable is a
          ;; border and not a shutdown of the protection model.  Not asserted at
          ;; the box's FIRST char, which is the queue's last position and is
          ;; exactly where the user must be able to type.
          (with-current-buffer buf
            (goto-char (point-min))
            (re-search-forward "^\\* PROMPT$")
            (should-not (ao--insertable-p (+ (line-beginning-position) 2)))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-queue-restore-repaints-over-the-edit-guard ()
  "M-x agent-org-queue-restore makes the page say what the SESSION says.
The edit guard is deliberately stubborn -- a refresh never repaints text the user
touched, because a repaint mid-word would delete a half-typed prompt -- and that
is exactly how a stale entry survives: he re-orders or deletes by hand, the
session keeps its own list, and the region now promises a queue that is not the
queue.  Restore is the ONE path allowed to override the guard, which is why it
has to be a command he asks for and never something that happens to his text.

It also has to re-mirror: the transcript is written from the buffer at turn
boundaries, so a restored region that left the old words in the file would put
the stale prompt back on the page at the next resume."
  (let* ((pair (ao--queued '("real one" "real two")))
         (buf (car pair))
         (session (cdr pair)))
    (unwind-protect
        (with-current-buffer buf
          ;; the user's mess: a stale prompt above the real ones, edited so no
          ;; automatic refresh will touch it.  INSIDE the region, not at its
          ;; first byte: both markers are rear-advancing, so an insert exactly
          ;; at `--queue-start' lands ABOVE the region and leaves it pristine.
          (let ((inhibit-read-only t))
            (goto-char (car (agent-org-buffer--queue-headlines)))
            (insert "* WAIT stale thing\n"))
          (should-not (agent-org-buffer--queue-pristine-p))
          (should (equal '("stale thing" "real one" "real two")
                         (agent-org-buffer-queue-parse nil)))
          ;; an automatic refresh refuses to overrule him -- that is the guard,
          ;; and restore is what replaces it
          (agent-org--queue-refresh session buf)
          (should (equal '("stale thing" "real one" "real two")
                         (agent-org-buffer-queue-parse nil)))
          (agent-org-queue-restore)
          (should (equal '("real one" "real two")
                         (agent-org-buffer-queue-parse nil)))
          (should (equal '("* NEXT real one" "* WAIT real two")
                         (ao--queue-headings)))
          (should (agent-org-buffer--queue-pristine-p)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-queue-restore-rejects-a-buffer-with-no-queue ()
  "`agent-org-queue-restore' in a non-chat buffer says so rather than painting.
The same discipline as `agent-org-queue-edit': a command that rewrites a region
must refuse where it has no region to rewrite."
  (with-temp-buffer
    (should-error (agent-org-queue-restore) :type 'user-error)))

(ert-deftest test-agent-org-queue-prepend-puts-a-prompt-at-the-front ()
  "C-c a n queues a prompt as the NEXT one out, ahead of what already waits.
What separates this from `agent-org-queue-enqueue' is the POSITION, and the
position is the whole feature: the queue drains head-first, so a prompt that has
to be answered before the two already waiting has to go in FRONT of them -- and
after a cancel, when nothing drains by itself, it is the prompt
`agent-org-queue-resume' will send.  Asserted on the session's own list, because
`agent-org-queue--set' is the only writer and the page is a mirror of it."
  (let* ((pair (ao--queued '("later" "last")))
         (buf (car pair))
         (session (cdr pair)))
    (unwind-protect
        (let ((sent nil))
          (cl-letf (((symbol-function 'acp-send-request)
                     (lambda (&rest kw) (push kw sent))))
            (with-current-buffer buf
              (agent-org-queue-prepend "cut to the chase"))
            ;; front of the SESSION's list, and the page says so
            (should (equal '("cut to the chase" "later" "last")
                           (plist-get session :pending-prompts)))
            (should (= 0 (length sent)))
            (with-current-buffer buf
              (should (equal '("* NEXT cut to the chase"
                               "* WAIT later"
                               "* WAIT last")
                             (ao--queue-headings)))))
          ;; an empty prompt is refused the way the queue refuses everything blank
          (should-error (with-current-buffer buf
                          (agent-org-queue-prepend "  "))
                        :type 'user-error))
      (kill-buffer buf))))

(ert-deftest test-agent-org-interrupt-and-send-cancels-then-sends ()
  "C-c a i stops the running turn and puts the new prompt on the wire, in one
gesture.  The two commands the user otherwise chains by hand -- and chaining them
LOSES the prompt: `agent-org-cancel-turn' closes the turn and re-opens the live
`* PROMPT' box, so a draft he was typing beside the running turn is not what a
following `agent-org-send' reads (by then the box is empty, or holds whatever he
typed since).  So the text is taken FIRST, the cancel fires, and the prompt goes
out as its own exchange.

Cancel-then-send is also the ONLY way an interrupting prompt reaches the agent:
`agent-org-cancel-turn' deliberately releases nothing that was queued (the user's
order after a live cancel fired a whole queue at once), so the prompt that must
be answered NOW cannot ride on the drain."
  (let* ((pair (ao--make-test-session "interrupt"))
         (buf (car pair))
         (session (cdr pair))
         (sent nil)
         (acp-mock-notifications nil))
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest kw) (push kw sent)))
              ((symbol-function 'acp-make-session-prompt-request)
               (lambda (&rest a) (plist-get a :prompt))))
      (with-current-buffer buf
        (agent-org-buffer-insert-prompt buf)
        (ao--type "long task")
        (agent-org-send))
      (should (= 1 (length sent)))
      (should (plist-get session :streaming))
      (with-current-buffer buf
        (goto-char (point-max))
        (ao--type "stop, do this instead")
        (agent-org-interrupt-and-send))
      ;; the running turn was cancelled over the wire...
      (should (seq-find (lambda (n) (equal "session/cancel" (map-elt n ':method)))
                        acp-mock-notifications))
      ;; ...and exactly one new prompt request went out, no drain
      (should (= 2 (length sent)))
      (with-current-buffer buf
        ;; the interrupting prompt is an exchange of its own, once: the box's
        ;; draft was consumed by the send, not copied into it
        (should (= 1 (ao--count-substrings "stop, do this instead")))
        ;; the interrupted turn keeps its own heading: two exchanges, one box
        (should (= 1 (ao--count-substrings "long task")))
        (should (= 1 (ao--count-substrings "* PROMPT"))))
      ;; idle: the same keys do not cancel anything, they just send
      (funcall (plist-get (car sent) :on-success) nil)
      (with-current-buffer buf
        (goto-char (point-max))
        (ao--type "now the next one")
        (agent-org-interrupt-and-send)
        (should (= 3 (length sent)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-queue-keys-are-bound-in-the-chat ()
  "One pager, one surface: every queue command is bound in the chat itself.
Every one of them sits under the `C-c a' prefix, the only `C-c C-<letter>'
slot Org leaves free -- see `test-agent-org-mode-map-shadows-no-org-binding'.

This test used to assert the OPPOSITE for `agent-org-queue-remove': when the
region became the editor, a number-picker that \"could only delete\" looked like
a second surface for one queue.  The user's order to port agent-shell's basic
queue commands settled it the other way, and the reason is real: point is not
always on the entry you want gone, and `C-c a d' cannot reach one you cannot
see.  `agent-org-queue-view' and `agent-org-queue-mode' stay gone -- a whole
buffer for a list the chat already shows."
  (should (eq #'agent-org-send
              (lookup-key agent-org-mode-map (kbd "C-c a s"))))
  (should (eq #'agent-org-queue-edit
              (lookup-key agent-org-mode-map (kbd "C-c a q"))))
  (should (eq #'agent-org-buffer-queue-add
              (lookup-key agent-org-mode-map (kbd "C-c a a"))))
  (should (eq #'agent-org-buffer-queue-kill
              (lookup-key agent-org-mode-map (kbd "C-c a d"))))
  ;; agent-shell's three basic verbs, ported (agent-shell-prompt-queue.el:346,
  ;; :385 and its queue display at :99/:128)
  (should (eq #'agent-org-queue-enqueue
              (lookup-key agent-org-mode-map (kbd "C-c a e"))))
  (should (eq #'agent-org-queue-remove
              (lookup-key agent-org-mode-map (kbd "C-c a x"))))
  (should (eq #'agent-org-queue-list
              (lookup-key agent-org-mode-map (kbd "C-c a v"))))
  (should (eq #'agent-org-queue-resume
              (lookup-key agent-org-mode-map (kbd "C-c a r"))))
  ;; the three the user ordered on top of those: put one in FRONT (n = NEXT),
  ;; stop the agent and send in one go (i), and repair a region he has messed up
  ;; (shift-Q on the same key as the goto, since restore is what `q' should have
  ;; shown him)
  (should (eq #'agent-org-queue-prepend
              (lookup-key agent-org-mode-map (kbd "C-c a n"))))
  (should (eq #'agent-org-interrupt-and-send
              (lookup-key agent-org-mode-map (kbd "C-c a i"))))
  (should (eq #'agent-org-queue-restore
              (lookup-key agent-org-mode-map (kbd "C-c a Q"))))
  ;; `[(meta up)]' and not `(kbd "M-UP")': the kbd parser wants ONE character
  ;; after a modifier, so it raises at LOAD time on the two-letter "UP"
  (should (eq #'agent-org-buffer-queue-move-up
              (lookup-key agent-org-mode-map [(meta up)])))
  (should (eq #'agent-org-buffer-queue-move-down
              (lookup-key agent-org-mode-map [(meta down)])))
  (should (fboundp 'agent-org-queue-remove))
  (should-not (fboundp 'agent-org-queue-view))
  (should-not (fboundp 'agent-org-queue-mode)))

(defun ao--keymap-paths (keymap &optional prefix)
  "Every full key sequence KEYMAP binds, as a list of vectors.
Depth-first, so a prefix map is reported as its CHILDREN -- the vector
`[C-c a s]', which is the form a collision check needs, rather than the
prefix nobody can name."
  (let ((paths (list)))
    (map-keymap (lambda (k def)
                  (let ((path (vconcat prefix (vector k))))
                    (if (keymapp def)
                        (setq paths (append (ao--keymap-paths def path) paths))
                      (push path paths))))
                keymap)
    (nreverse paths)))

(defun ao--agent-org-bindings ()
  "Every (KEY-VECTOR . COMMAND) agent-org binds, across both keymaps.
The mode map and the monitor map, because the monitor is an Org buffer too and
its keys are subject to the same rule."
  (append
   (mapcar (lambda (p) (cons p (lookup-key agent-org-mode-map p)))
           (ao--keymap-paths agent-org-mode-map))
   (mapcar (lambda (p) (cons p (lookup-key agent-org-resource-monitor-map p)))
           (ao--keymap-paths agent-org-resource-monitor-map))))

(ert-deftest test-agent-org-mode-map-shadows-no-org-binding ()
  "No agent-org COMMAND sits on a key Org already uses.
Measured against a fully loaded `org-mode-map' (Org 9.7.11): `C-c C-c' is
`org-ctrl-c-ctrl-c', `C-c C-m' PARSES as `C-c RET' = `org-ctrl-c-ret', and
`C-c C-q' / -r / -k / -l / -a / -d' are tags, reveal, kill-note, link, attach
and deadline -- so every one of the eight chords the package used to bind stole
an Org command.  The worst was `C-c C-c' itself: in a chat it ate
`org-ctrl-c-ctrl-c', and that is the only gesture Org offers for refreshing a
clocktable or editing a block -- both of which a chat buffer contains.
So the package's own keys live under ONE prefix Org leaves free (`C-c a'), and
this test is the drift guard: if Org ever claims that slot too, this fails here
rather than in the user's fingers.

The deliberate exceptions are the STRUCTURAL guards -- keys Org binds to
commands that write through `read-only' text properties and so would corrupt a
heading boundary mid-stream.  Taking those over is the point, so they are
asserted to sit on a real Org binding rather than excused from the rule.
`C-c C-c' joins them since 2026-10-14, but it is a WRAP and not a steal:
`agent-org-ctrl-c-ctrl-c' delegates to `org-ctrl-c-ctrl-c' everywhere except a
CLOCK line, where Org's own handler would delete the seconds from our stamps.
So the chord still refreshes a clocktable and edits a block; the guard-keys list
is what lets the drift guard see that this one Org command is taken on purpose.

The lookup asks for a COMMAND, not merely a non-nil answer: `C-c' resolves to
a keymap, so `lookup-key' reports every longer `C-c C-<letter>' sequence as a
PREFIX -- the integer 2, `two events were not needed' -- whether or not Org
binds it.  Only a function is a stolen command."
  (let* ((guard-keys (list (kbd "M-RET") [(meta left)] [(meta right)]
                           [(meta up)] [(meta down)]
                           [(shift up)] [(shift down)]
                           (kbd "C-c C-c") (kbd "C-c C-t") (kbd "C-c -")))
         ;; compared by DESCRIPTION, because `map-keymap' hands back a function
         ;; key as the SYMBOL `M-down' while the vector literal reads as an
         ;; integer -- equal would call the same key two different things
         (guards (mapcar #'key-description guard-keys))
         ;; `vconcat', because `read-kbd-macro' answers with a STRING when
         ;; every event fits in a character, and the paths above are vectors
         (prefix (vconcat (kbd "C-c a"))))
    (dolist (pair (ao--agent-org-bindings))
      (let* ((path (car pair))
             (cmd (cdr pair))
             (binding (lookup-key org-mode-map path))
             (in-org (and (symbolp binding) (commandp binding) binding)))
        ;; every entry names a command (a bare prefix left in the map is a bug)
        (should cmd)
        (if (member (key-description path) guards)
            (should in-org)
          (should-not in-org)
          ;; and a non-guard key is one of OURS, so it must hang under the
          ;; one free prefix -- the scheme, not just the absence of clashes
          (unless (eq cmd #'quit-window)
            (should (equal prefix (seq-take path 2)))))))
    ;; the premise of the whole scheme, asserted rather than trusted
    (should-not (commandp (lookup-key org-mode-map (kbd "C-c a")))))
  ;; the eight chords the package used to bind ARE Org commands: the rule is
  ;; measured, not remembered
  (dolist (key (list (kbd "C-c C-c") (kbd "C-c C-k") (kbd "C-c C-l")
                     (kbd "C-c C-a") (kbd "C-c C-d") (kbd "C-c C-q")
                     (kbd "C-c C-t") (kbd "C-c -")))
    (should (commandp (lookup-key org-mode-map key)))))

(ert-deftest test-agent-org-reload-rebinds-a-live-chat ()
  "A hot load reaches the buffers that were open BEFORE it.
The workflow AGENTS.md prescribes is `emacsclient -e (load …)'.  Two things make
that silently fail on a keymap: `defvar' leaves an already-bound symbol alone,
and `minor-mode-map-alist' holds the keymap OBJECT a buffer activated on -- so
re-setting the variable to a fresh map changes the FILE and not the EDITOR.
Measured on the live session: the reloaded map still answered `C-c C-c' with
`agent-org-send' and went on eating `org-ctrl-c-ctrl-c' after the source had
given that chord back to Org.  `agent-org-buffer--build-mode-map' therefore
fills the one existing object.  This test corrupts the live map the way the old
build had it, reloads the source, and reads the keys back THROUGH a chat that
was open the whole time."
  (let ((buf (car (ao--make-test-session "reload-map"))))
    (unwind-protect
        (with-current-buffer buf
          (define-key agent-org-mode-map (kbd "C-c C-c") #'agent-org-send)
          (define-key agent-org-mode-map (kbd "C-c a") nil)
          ;; the bug, reproduced: the chat answers Org's chord itself.
          (should (eq #'agent-org-send (key-binding (kbd "C-c C-c"))))
          (load (expand-file-name "agent-org-buffer.el" ao--package-root) nil t)
          ;; …and the same buffer now gives the chord to OUR wrapper (which
          ;; delegates to `org-ctrl-c-ctrl-c' off a CLOCK line), without the
          ;; mode being turned off and on again.
          (should (eq #'agent-org-ctrl-c-ctrl-c (key-binding (kbd "C-c C-c"))))
          (should (eq #'agent-org-send (key-binding (kbd "C-c a s"))))
          (should (eq #'agent-org-cancel-turn (key-binding (kbd "C-c a k")))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-queue-entries-appear-and-go-with-the-queue ()
  "Waiting prompts are SHOWN as headlines, and an empty queue leaves nothing.
A queue that appears mid-turn is news the user must see without a TAB; one
that drains must not leave a `* NEXT'/`* WAIT' headline behind, because a
stale heading reads as a prompt nobody sent — and the transcript mirrors what
the buffer shows."
  (let* ((pair (ao--make-test-session "q-fold"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :pending-prompts) (list "waiting one"))
    (agent-org--queue-refresh session buf)
    (with-current-buffer buf
      (goto-char (point-min))
      (should (re-search-forward "^\\* NEXT waiting one$" nil t)))
    (setf (plist-get session :pending-prompts) nil)
    (agent-org--queue-refresh session buf)
    (with-current-buffer buf
      (should-not (string-match-p agent-org-buffer--queue-headline-re
                                  (buffer-string)))
      (should-not (string-match-p
                   (regexp-quote agent-org-buffer--queue-note-text)
                   (buffer-string))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-queue-mirrors-every-waiting-prompt ()
  "No cap on the queue: 55 waiting prompts are 55 entries and 55 prompts back.
The reference drawers may end in `… (+N more)' and nothing is lost, because the
agent can always be asked again; the queue IS the record the transcript
mirrors, so a truncation there destroys a prompt the user paid for.  Asserted
through the file rather than by counting lines: the resume path is the one that
must not lose the fifty-fifth."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (let* ((pair (ao--make-test-session "q-cap"))
             (buf (car pair))
             (session (cdr pair))
             (prompts (cl-loop for i from 1 to 55 collect (format "prompt %d" i))))
        ;; the writer keys on the BUFFER's status id, which in a live chat
        ;; arrives with an update; `ao--make-test-session' binds the session
        ;; plist but not the status, so install the id here the way a real
        ;; `session_info_update' would, or there is no file to mirror into
        (agent-org-buffer-set-status buf :session-id (plist-get session :session-id))
        (setf (plist-get session :pending-prompts) prompts)
        (agent-org--queue-refresh session buf)
        (with-current-buffer buf
          (should (= 55 (length (agent-org-buffer-queue-parse buf))))
          (should-not (string-match-p "more)" (buffer-string)))
          (should (equal prompts
                         (agent-org-buffer-transcript-queue
                          (plist-get session :session-id)))))
        (kill-buffer buf)))))

;;;; Interrupt (cancel a running turn)

(ert-deftest test-agent-org-cancel-turn-notifies-and-frees-buffer ()
  "Cancel sends `session/cancel' for the live session and ends the turn
locally — the buffer goes Ready with a cancelled note and a fresh prompt,
without waiting for the agent to answer."
  (let* ((pair (ao--make-test-session "cancel"))
         (buf (car pair))
         (session (cdr pair))
         (sent nil)
         (acp-mock-notifications nil))
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest kw) (push kw sent)))
              ((symbol-function 'acp-make-session-prompt-request)
               (lambda (&rest a) (plist-get a :prompt))))
      (with-current-buffer buf
        (agent-org-buffer-insert-prompt buf)
        (ao--type "long task")
        (agent-org-send)
        (agent-org-cancel-turn))
      (let ((note (car acp-mock-notifications)))
        (should (= 1 (length acp-mock-notifications)))
        (should (equal "session/cancel" (map-elt note ':method)))
        (should (equal "sid-test"
                       (map-elt (map-elt note ':params) 'sessionId))))
      (should-not (plist-get session :streaming))
      (with-current-buffer buf
        (should (eq 'ready (plist-get agent-org-buffer--status :state)))
        (should (equal "turn cancelled"
                       (plist-get agent-org-buffer--status :note)))
        (should (agent-org-buffer--open-prompt-p))
        (should (= 1 (ao--count-substrings "* PROMPT"))))
      ;; the agent's late (cancelled) answer must not re-close the turn,
      ;; drain twice, or insert another prompt
      (funcall (plist-get (car sent) :on-success) nil)
      (should (= 1 (length sent)))
      (with-current-buffer buf
        (should (= 1 (ao--count-substrings "* PROMPT"))))
      (funcall (plist-get (car sent) :on-failure) nil "late failure")
      (with-current-buffer buf
        (should (= 1 (ao--count-substrings "* PROMPT")))
        (should (eq 'ready (plist-get agent-org-buffer--status :state)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-cancel-turn-keeps-the-queue-waiting ()
  "A cancelled turn releases NOTHING that was waiting behind it.
The user's order, after a live cancel fired every queued prompt at once:
\"Cancelling turn should never resume queue.\"  The prompts were queued to
join a conversation the user has just stopped; sending the first of them is a
turn the user never asked for, and each one that answers fires the next, so a
single cancel emptied the whole queue in seconds.

So cancel closes the cancelled turn and leaves `:pending-prompts' exactly as
it was: still in the session, still as `* NEXT'/`* WAIT' headlines in the
buffer, still in the transcript file.  `agent-org-queue-resume' is the only way one goes out,
besides a later turn ending successfully."
  (let* ((pair (ao--make-test-session "cancel-q"))
         (buf (car pair))
         (session (cdr pair))
         (sent nil)
         (acp-mock-notifications nil))
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest kw) (push kw sent)))
              ((symbol-function 'acp-make-session-prompt-request)
               (lambda (&rest a) (plist-get a :prompt))))
      (with-current-buffer buf
        (agent-org-buffer-insert-prompt buf)
        (ao--type "running")
        (agent-org-send)                      ; goes on the wire
        (ao--type "next")
        (agent-org-send)                      ; queues "next"
        (ao--type "last")
        (agent-org-send))                     ; queues "last"
      (let ((before (length sent)))
        (with-current-buffer buf
          (agent-org-cancel-turn)
          ;; no new request: the cancel is a notification, and the only one
          (should (= before (length sent)))
          (should-not (plist-get session :streaming))
          (should (equal '("next" "last") (plist-get session :pending-prompts)))
          ;; the buffer is usable again, and says so in the body: no heading
          ;; for a prompt that was never sent -- an exchange for "next" would
          ;; wear a state word, never the positional WAIT/NEXT of an entry
          (should (agent-org-buffer--open-prompt-p))
          (should-not (string-match-p "^\\* \\(PROMPT\\|RESPONDING\\|RESPONDED\\) next$"
                                      (buffer-string)))
          ;; and the waiting prompts are still where the user can read them,
          ;; wearing their positions: "next" is the head, "last" waits behind
          (should (string-match-p "^\\* NEXT next$" (buffer-string)))
          (should (string-match-p "^\\* WAIT last$" (buffer-string))))
        ;; the cancelled turn's late answer must not drain it either
        (funcall (plist-get (car sent) :on-success) nil)
        (should (= before (length sent)))
        (should (equal '("next" "last") (plist-get session :pending-prompts)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-queue-resume-sends-one-and-leaves-the-rest ()
  "`agent-org-queue-resume' is the way back after a cancel: ONE prompt goes
out, FIFO, and the rest keep waiting — the queue then drains by itself at each
successful turn end, as it always did.
Port of `agent-shell-prompt-queue-resume' (agent-shell-prompt-queue.el:370)."
  (let* ((pair (ao--make-test-session "q-resume"))
         (buf (car pair))
         (session (cdr pair))
         (sent nil))
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest kw) (push kw sent)))
              ((symbol-function 'acp-make-session-prompt-request)
               (lambda (&rest a) (plist-get a :prompt))))
      (setf (plist-get session :pending-prompts) (list "one" "two"))
      (with-current-buffer buf
        (agent-org-queue-resume)
        (should (equal '("one") (ao--sent-texts sent)))
        (should (equal '("two") (plist-get session :pending-prompts)))
        ;; the resumed prompt is an exchange now; this stub client never
        ;; raised a streaming status, so its heading still wears the word a
        ;; sent-but-unanswered prompt gets: `PROMPT'
        (should (string-match-p "^\\* PROMPT one$" (buffer-string)))
        ;; the survivor is the head of the queue again, so its word says NEXT
        (should (string-match-p "^\\* NEXT two$" (buffer-string)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-queue-resume-while-busy-sends-nothing ()
  "A turn already running owns the queue: resuming mid-turn would put a
second prompt on the wire beside it.  agent-shell says so in the echo area
rather than erroring, because the user's own prompts drain the queue the
moment the turn ends.  (`agent-shell-prompt-queue-resume':381.)"
  (let* ((pair (ao--make-test-session "q-busy"))
         (buf (car pair))
         (session (cdr pair))
         (sent nil))
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest kw) (push kw sent))))
      (setf (plist-get session :pending-prompts) (list "one"))
      (setf (plist-get session :streaming) t)
      (with-current-buffer buf
        (agent-org-queue-resume)
        (should-not sent)
        (should (equal '("one") (plist-get session :pending-prompts)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-queue-resume-on-an-empty-queue-rejects ()
  "Nothing waiting is a `user-error', not a silent success: the command is
how a person gets a prompt they thought was queued, and an empty queue is the
answer they need to see."
  (let ((buf (car (ao--make-test-session "q-empty"))))
    (with-current-buffer buf
      (should-error (agent-org-queue-resume) :type 'user-error))
    (kill-buffer buf)))

(ert-deftest test-agent-org-queue-resume-is-bound ()
  "Every queue command is reachable by a key as well as by `M-x': the queue
is read in the middle of a turn, when typing `M-x' costs the thread of it."
  (should (equal #'agent-org-queue-resume
                 (lookup-key agent-org-mode-map (kbd "C-c a r")))))

(ert-deftest test-agent-org-cancel-turn-rejects-when-idle ()
  "Nothing streaming, nothing to cancel."
  (let ((buf (car (ao--make-test-session "cancel-idle"))))
    (with-current-buffer buf
      (should-error (agent-org-cancel-turn) :type 'user-error))
    (kill-buffer buf)))

(ert-deftest test-agent-org-cancel-turn-sends-nothing-until-ready ()
  "No session id means no turn can be cancelled on the wire."
  (let* ((pair (ao--make-test-session "cancel-none"))
         (buf (car pair))
         (session (cdr pair))
         (acp-mock-notifications nil))
    (setf (plist-get session :session-id) nil)
    (setf (plist-get session :streaming) t)
    (with-current-buffer buf
      (should-error (agent-org-cancel-turn) :type 'user-error)
      (should-not acp-mock-notifications))
    (kill-buffer buf)))

;;;; Reload (restart the same session, agent-shell's `agent-shell-reload')

(ert-deftest test-agent-org-reload-replays-same-session-through-resume ()
  "Reload kills the chat with its agent and re-loads the same id: the
transcript is re-rendered from the agent's history, not kept from before.
The old buffer must be gone first, or `agent-org--session-open-p' would
redirect the load to it instead of replaying."
  (ao--capture-wire
    (let* ((buf (agent-org-resume-session 'qoder "sid-rel"))
           (session (agent-org--session-for-buffer buf)))
      (ao--drive "initialize" ao--fake-init-resp)
      (ao--drive "session/load" '((sessionId . "sid-rel")))
      (ao--settle)
      (with-current-buffer buf
        (should (equal "sid-rel"
                       (plist-get agent-org-buffer--status :session-id))))
      (let ((new (with-current-buffer buf (agent-org-reload))))
        (should-not (buffer-live-p buf))
        (should (buffer-live-p new))
        (should-not (eq new buf))
        ;; the resume handshake restarts from scratch on a new client
        (should (equal (caar ao--sent) "initialize"))
        (let ((nsession (agent-org--session-for-buffer new)))
          (should nsession)
          (should-not (plist-get nsession :session-id)))
        (ao--drive "initialize" ao--fake-init-resp)
        (let ((load (ao--sent-get "session/load")))
          (should load)
          (should (equal "sid-rel"
                         (map-elt (map-elt (plist-get load :request)
                                           ':params)
                                  'sessionId))))
        (ao--drive "session/load" '((sessionId . "sid-rel")))
        (ao--settle)
        (with-current-buffer new
          (should (equal "sid-rel"
                         (plist-get agent-org-buffer--status :session-id)))
          (should (agent-org-buffer--open-prompt-p)))
        (kill-buffer new)))))

(ert-deftest test-agent-org-reload-refuses-while-loading ()
  "A replay in flight owns the buffer; reload waits."
  (let* ((pair (ao--make-test-session "rel-load"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :loading) t)
    (with-current-buffer buf
      (should-error (agent-org-reload) :type 'user-error)
      (should (buffer-live-p buf)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-reload-rejects-unopened-session ()
  "No :session-id yet — there is nothing to reload into."
  (let* ((pair (ao--make-test-session "rel-none"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :session-id) nil)
    (with-current-buffer buf
      (should-error (agent-org-reload) :type 'user-error)
      (should (buffer-live-p buf)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-reload-asks-before-killing-a-live-turn ()
  "Streaming: `y-or-n-p' decides.  \"no\" leaves the chat untouched;
\"yes\" reloads anyway, and the queue goes with the killed buffer."
  (let* ((pair (ao--make-test-session "rel-busy"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :streaming) t)
    ;; reload hands the session's provider to `agent-org-resume-session',
    ;; which needs a real spec; the fixture's `test' has none
    (setf (plist-get session :name) 'qoder)
    (setf (plist-get session :pending-prompts) (list "queued"))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
      (with-current-buffer buf
        (should-error (agent-org-reload) :type 'user-error)
        (should (buffer-live-p buf))
        (should (equal '("queued") (plist-get session :pending-prompts)))))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
              ((symbol-function 'acp-send-request) (lambda (&rest _) nil))
              ((symbol-function 'acp-make-client) (lambda (&rest _) nil))
              ((symbol-function 'acp-subscribe-to-notifications)
               (lambda (&rest _) nil))
              ((symbol-function 'acp-subscribe-to-requests)
               (lambda (&rest _) nil))
              ((symbol-function 'acp-subscribe-to-errors)
               (lambda (&rest _) nil))
              ((symbol-function 'executable-find) (lambda (&rest _) t)))
      (with-current-buffer buf
        (let ((new (agent-org-reload)))
          (should-not (buffer-live-p buf))
          (should (buffer-live-p new))
          ;; the queue lived on the killed session entry; the new one is clean
          (should-not (plist-get (agent-org--session-for-buffer new)
                                 :pending-prompts))
          (kill-buffer new))))))

(ert-deftest test-agent-org-session-ready-inserts-prompt-once ()
  "`agent-org--session-ready' is idempotent across repeated session updates."
  (let* ((pair (ao--make-test-session "ready"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :session-id) nil)
    (agent-org--session-ready session "sid-1")
    (agent-org--session-ready session "sid-1")
    (with-current-buffer buf
      (should (= 1 (ao--count-substrings "* PROMPT")))
      (should (equal "sid-1" (plist-get session :session-id)))
      (should (eq 'ready (plist-get agent-org-buffer--status :state))))
    ;; A mid-turn session_info_update must not slip a prompt in.
    (with-current-buffer buf
      (agent-org-buffer--protect (point-min) (point-max)) ; as send freezes it
      (setf (plist-get session :streaming) t)
      (agent-org--session-ready session "sid-1")
      (should (= 1 (ao--count-substrings "* PROMPT"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-programmatic-text-is-protected ()
  "Agent chunks and tool drawer lines carry the read-only property."
  (let ((buf (agent-org-buffer-create "props")))
    (with-current-buffer buf
      (agent-org-buffer-insert-prompt buf)
      ;; the chunk carries its newline so the line is FINISHED and lands: an
      ;; arriving line is held by the line-granular converter (see
      ;; `test-agent-org-buffer-streaming-lifecycle'), and held text is not yet
      ;; in the buffer to be read-protected
      (agent-org-buffer-append-chunk buf "streamed\n" (list :buffer buf))
      (should (save-excursion
                (goto-char (point-min))
                (and (search-forward "streamed" nil t)
                     (get-text-property (match-beginning 0) 'read-only))))
      (agent-org-buffer-insert-tool buf '((title . "read_file") (toolCallId . "tc")))
      (should (save-excursion
                (goto-char (point-min))
                (and (re-search-forward "^  - RUNNING read_file$" nil t)
                     (get-text-property (match-beginning 0) 'read-only))))
      ;; the drawer's own marker line too: a `:tool:' the user could edit
      ;; is a drawer that leaks into the next redraw
      (should (save-excursion
                (goto-char (point-min))
                (and (re-search-forward "^:tool:$" nil t)
                     (get-text-property (match-beginning 0) 'read-only)))))
    (kill-buffer buf)))

;;;; Header-line model (agent-shell style, single status segment)

(defun ao--count-occurrences (string regexp)
  "Number of REGEXP matches in STRING."
  (with-temp-buffer
    (insert string)
    (save-excursion
      (goto-char (point-min))
      (let ((n 0))
        (while (re-search-forward regexp nil t)
          (cl-incf n))
        n))))

(ert-deftest test-agent-org-header-status-not-duplicated ()
  "State label and placeholder message never render twice."
  (let ((buf (agent-org-buffer-create "dup")))
    (agent-org-buffer-set-status buf :state 'ready :message "Ready" :session-id "s1")
    (with-current-buffer buf
      (should (= 1 (ao--count-occurrences
                    (agent-org-buffer--render-header-line) "Ready"))))
    (agent-org-buffer-set-status buf :state 'starting :message "Connecting…")
    (with-current-buffer buf
      (let ((r (agent-org-buffer--render-header-line)))
        (should (string-match-p "Starting" r))
        (should-not (string-match-p "Connecting" r))))
    (agent-org-buffer-set-status buf :state 'streaming :message "Sending…")
    (with-current-buffer buf
      (let ((r (agent-org-buffer--render-header-line)))
        (should (string-match-p "Sending…" r))
        (should-not (string-match-p "Streaming" r))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-header-format-number-compact ()
  "Compact token formatting matches agent-shell (k/m/b suffixes)."
  (should (equal (agent-org-buffer--format-number-compact 42) "42"))
  (should (equal (agent-org-buffer--format-number-compact 1000) "1k"))
  (should (equal (agent-org-buffer--format-number-compact 128000) "128k"))
  (should (equal (agent-org-buffer--format-number-compact 2000000) "2m")))

(ert-deftest test-agent-org-header-context-and-cost ()
  "Context and cost segments render from usage fields."
  (let ((buf (agent-org-buffer-create "usage")))
    (agent-org-buffer-set-status buf :used 90000 :size 128000
                                 :cost-amount 0.4237 :cost-currency "USD")
    (with-current-buffer buf
      (let ((r (agent-org-buffer--render-header-line)))
        (should (string-match-p "90k/128k" r))
        (should (string-match-p "\\$0\\.43" r))))
    (agent-org-buffer-set-status buf :used nil :size nil
                                 :cost-amount nil :cost-currency nil)
    (with-current-buffer buf
      (let ((r (agent-org-buffer--render-header-line)))
        (should-not (string-match-p "/" r))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-header-shows-model-mode-project ()
  "Model, mode and project segments appear in agent-shell order."
  (let ((buf (agent-org-buffer-create "fields")))
    (agent-org-buffer-set-status buf :model "gomodel" :mode "auto")
    (with-current-buffer buf
      (let ((r (agent-org-buffer--render-header-line)))
        (should (string-match-p "gomodel" r))
        (should (string-match-p "auto" r))
        (should (string-match-p "➤" r))
        ;; order: provider before model before mode
        (should (< (string-match-p "fields" r)
                   (string-match-p "gomodel" r)
                   (string-match-p "auto" r)))))
    (kill-buffer buf)))

;;;; The permission mode: the agent's NAME on the bar, not the wire id
;;
;; User order (2026-10-11): "Permission mode name should reflect what the agent
;; calls it, e.g. for Qoder, not `yolo', but `Bypass Permissions' should show in
;; header line."  ACP mode objects carry `id' (what a request would send back)
;; and `name' (what the agent calls it in its own UI), exactly like a config
;; option carries `value' and `name' -- so this mirrors the :model/:model-name
;; pair, and the id stays the fallback for an agent that reports a mode it does
;; not name.

(defun ao--qoder-modes-resp ()
  "A Qoder-shaped session/new response: ids and names that DIFFER.
The canned goose session uses the same string for both, which is why it
cannot catch a reader that asks for the wrong field."
  `((sessionId . "sid-q")
    (modes . ((currentModeId . "yolo")
              (availableModes .
               [((id . "default") (name . "Default"))
                ((id . "yolo") (name . "Bypass Permissions"))
                ((id . "accept") (name . "Accept Edits"))])))))

(ert-deftest test-agent-org-header-shows-the-mode-name-not-its-id ()
  "`Bypass Permissions' rides the bar; `yolo' is the wire id, not the label.
Set through the real path (`agent-org--session-ready' with an agent that
names its modes) so a reader that asks the status for `:mode' alone fails
here rather than in a live Qoder chat."
  (let* ((pair (ao--make-test-session "qoder"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :session-id) nil)
    (agent-org--session-ready session "sid-q" (ao--qoder-modes-resp))
    (with-current-buffer buf
      (let ((r (agent-org-buffer--render-header-line)))
        (should (string-match-p "Bypass Permissions" r))
        (should-not (string-match-p "\\byolo\\b" r))
        ;; the id is still the status's own fact: the bar renders a label FROM
        ;; it, so a future mode-setting verb has the wire value to send.
        (should (equal "yolo" (plist-get agent-org-buffer--status :mode)))
        ;; and the body keeps both spellings where there is room for them
        (should (string-match-p "^:Mode: +Bypass Permissions" (buffer-string)))
        (should (string-match-p "Bypass Permissions (id: yolo)" (buffer-string)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-mode-name-falls-back-to-the-id ()
  "An id the agent advertises no name for still shows something.
Goose-style lists can name a mode only for some entries, and
`currentModeId' can point outside the list entirely; a bar that dropped
the field then would read as \"no mode\"."
  (should (equal "Bypass Permissions"
                 (agent-org--mode-name
                  [((id . "yolo") (name . "Bypass Permissions"))] "yolo")))
  (should (equal "yolo" (agent-org--mode-name [] "yolo")))
  ;; no `name' on the matching entry: the id is all the agent told us
  (should (equal "plan" (agent-org--mode-name [((id . "plan"))] "plan")))
  (should (equal "no-mode" (agent-org--mode-name nil "no-mode"))))


(ert-deftest test-agent-org-current-mode-update-carries-the-name ()
  "A mid-session `current_mode_update' re-labels the bar from the stored list.
The notification carries ONLY `currentModeId' -- the list came with
session/new -- so the reader must look the name up in the status it
already holds, which is where `:modes-list' lives for exactly this."
  (let* ((pair (ao--make-test-session "modeup"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :session-id) nil)
    (agent-org--session-ready session "sid-q" (ao--qoder-modes-resp))
    (agent-org--on-notification
     session
     `((method . "session/update")
       (params . ((update . ((sessionUpdate . "current_mode_update")
                             (currentModeId . "accept")))))))
    (with-current-buffer buf
      (let ((r (agent-org-buffer--render-header-line)))
        (should (string-match-p "Accept Edits" r))
        (should-not (string-match-p "Bypass Permissions" r))
        (should (equal "accept" (plist-get agent-org-buffer--status :mode)))))
    (kill-buffer buf)))

;;;; Org session-metadata block

(defun ao--fake-session-new-resp ()
  "Canned goose-shaped session/new response alist."
  `((sessionId . "sid-x")
    (title . "Initial Session Title")
    (modes . ((currentModeId . "auto")
              (availableModes .
               [((id . "auto") (name . "auto")
                 (description . "Automatically approve tool calls"))
                ((id . "chat") (name . "chat")
                 (description . "Chat only, no tool calls"))])))
    (configOptions .
     [((id . "provider") (name . "Provider") (type . "select")
       (currentValue . "gomodel"))])))

(ert-deftest test-agent-org-metadata-section-on-ready ()
  "session-ready with a full response builds the top metadata block."
  (let* ((pair (ao--make-test-session "meta"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :session-id) nil)
    (agent-org--session-ready session "sid-x" (ao--fake-session-new-resp))
    (with-current-buffer buf
      (should (string-match-p "\\`:PROPERTIES:" (buffer-string)))
      ;; no heading is used for metadata; conversation owns `* ' lines
      (should-not (string-match-p "Session info" (buffer-string)))
      (should (string-match-p "^:ID: +sid-x" (buffer-string)))
      ;; the id is a drawer property, not a keyword line and not on the
      ;; header bar; inside the drawer it sits between Provider and Mode
      (should-not (string-match-p "^#\\+ID:" (buffer-string)))
      (should (apply #'ao--ordered (buffer-string)
                     (list ":PROPERTIES:" ":Provider:" ":ID:" ":Mode:")))
      (should (string-match-p "^:Mode: +auto" (buffer-string)))
      (should (string-match-p "^:Model: +gomodel" (buffer-string)))
      (should (string-match-p "^#\\+TITLE: " (buffer-string)))
      (should (string-match-p "^:MODES:" (buffer-string)))
      (should (string-match-p "chat (id: chat) — Chat only" (buffer-string)))
      (should (string-match-p "^:CONFIG:" (buffer-string)))
      (should (string-match-p "Provider — gomodel" (buffer-string)))
      ;; block ends with a blank line, the box's own rule, then the box
      (should (string-match-p ":END:\n\n-----+\n\n\\* PROMPT" (buffer-string)))
      ;; metadata is frozen and the live prompt still ends the buffer
      (should (get-text-property (point-min) 'read-only))
      (should (agent-org-buffer--open-prompt-p))
      (save-excursion
        (goto-char (point-max))
        (org-back-to-heading t)
        ;; NOT `(org-get-heading t t t t)': `PROMPT' is a real TODO keyword,
        ;; so that reader STRIPS it and answers "" on the bare box heading.
        ;; The source's own reader compares the heading line's bytes, and the
        ;; test uses it plus the raw line.
        (should (equal "* PROMPT"
                       (buffer-substring-no-properties
                        (line-beginning-position) (line-end-position))))
        (should (agent-org-buffer--open-prompt-p))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-title-initializes-from-session-new-response ()
  "A title in the session/new response lands in `#+TITLE:' verbatim —
the harness's own session title, with no provider prefix."
  (let* ((pair (ao--make-test-session "title-init"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :session-id) nil)
    (agent-org--session-ready session "sid-t1" (ao--fake-session-new-resp))
    (with-current-buffer buf
      (should (string-match-p "^#\\+TITLE: Initial Session Title$"
                              (buffer-string)))
      (should (= 1 (ao--count-occurrences (buffer-string) "#\\+TITLE:")))
      (should (equal "Initial Session Title"
                     (plist-get agent-org-buffer--status :title))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-title-falls-back-to-provider-until-set ()
  "Before the harness reports a title, `#+TITLE:' shows the provider
name alone; the fallback disappears once a title arrives."
  (let* ((pair (ao--make-test-session "title-fb"))
         (buf (car pair)))
    (with-current-buffer buf
      (should (string-match-p "^#\\+TITLE: title-fb$" (buffer-string))))
    (agent-org-buffer-set-status buf :title "Real Harness Title")
    (agent-org-buffer-refresh-metadata buf)
    (with-current-buffer buf
      (should (string-match-p "^#\\+TITLE: Real Harness Title$" (buffer-string)))
      (should-not (string-match-p "^#\\+TITLE: title-fb$" (buffer-string)))
      (should (= 1 (ao--count-occurrences (buffer-string) "#\\+TITLE:"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-title-updates-from-session-info-update ()
  "Mid-session `session_info_update' notifications rename `#+TITLE:'
and keep the buffer consistent (one title line, no duplicates)."
  (let* ((pair (ao--make-test-session "title-upd"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :session-id) nil)
    (agent-org--session-ready session "sid-t2" (ao--fake-session-new-resp))
    (with-current-buffer buf
      (should (string-match-p "^#\\+TITLE: Initial Session Title$"
                              (buffer-string))))
    ;; the agent renames the session; title rides inside the update
    (agent-org--on-notification
     session
     `((method . "session/update")
       (params . ((sessionId . "sid-t2")
                  (update . ((sessionUpdate . "session_info_update")
                             (title . "Renamed by agent")))))))
    (with-current-buffer buf
      (should (string-match-p "^#\\+TITLE: Renamed by agent$" (buffer-string)))
      (should (= 1 (ao--count-occurrences (buffer-string) "#\\+TITLE:"))))
    ;; title may also ride directly on params (other ACP clients)
    (agent-org--on-notification
     session
     `((method . "session/update")
       (params . ((sessionId . "sid-t2")
                  (title . "Params title")
                  (update . ((sessionUpdate . "session_info_update")))))))
    (with-current-buffer buf
      (should (string-match-p "^#\\+TITLE: Params title$" (buffer-string)))
      (should (= 1 (ao--count-occurrences (buffer-string) "#\\+TITLE:"))))
    (kill-buffer buf)))

;;;; Title sync from session/list (agents that never push it)

(ert-deftest test-agent-org-title-fetched-from-list-after-first-turn ()
  "Qoder never sends `session_info_update', but it does list titles in
`session/list'.  After the first successful turn -- the turn is what
gives a fresh session a title worth reading -- agent-org asks the
directory once and lands the title in `#+TITLE:'."
  (ao--capture-wire
   (let* ((pair (ao--make-test-session "tsync"))
          (buf (car pair))
          (session (cdr pair)))
     ;; the stock mock hands back nil for a prompt request, which would
     ;; land in the wire capture under method nil; give it the real shape
     (cl-letf (((symbol-function 'acp-make-session-prompt-request)
                (lambda (&rest a)
                  `((:method . "session/prompt")
                    (:params . ((sessionId . ,(plist-get a :session-id))
                                (prompt . ,(plist-get a :prompt))))))))
     (setf (plist-get session :lists-sessions) t)
     (with-current-buffer buf
       (agent-org-buffer-insert-prompt buf)
       (ao--type "Review the request")
       (agent-org-send)
       (ao--drive "session/prompt" nil)
       (should (ao--sent-get "session/list"))
       (ao--drive "session/list"
                  (ao--list-resp (list (list "sid-other" "Other" (ao--today))
                                       (list "sid-test" "Review request"
                                             (ao--today)))))
       (should (equal "Review request"
                      (plist-get agent-org-buffer--status :title)))
       (should (string-match-p "^#\\+TITLE: Review request$"
                               (buffer-string)))))
     (kill-buffer buf))))

(ert-deftest test-agent-org-title-not-sought-without-list-capability ()
  "An agent that does not advertise `list' is never asked for a title:
Goose hangs on `session/list', so the lookup is capability-gated."
  (ao--capture-wire
   (let* ((pair (ao--make-test-session "tnolist"))
          (buf (car pair)))
     (cl-letf (((symbol-function 'acp-make-session-prompt-request)
                (lambda (&rest a)
                  `((:method . "session/prompt")
                    (:params . ((sessionId . ,(plist-get a :session-id))
                                (prompt . ,(plist-get a :prompt))))))))
       (with-current-buffer buf
         (agent-org-buffer-insert-prompt buf)
         (ao--type "hi")
         (agent-org-send)
         (ao--drive "session/prompt" nil)
         (should-not (ao--sent-get "session/list"))))
     (kill-buffer buf))))

(ert-deftest test-agent-org-title-not-sought-when-already-known ()
  "A title that arrived by itself (session/new response or a pushed
`session_info_update') wins: no list request, no clobbering."
  (ao--capture-wire
   (let* ((pair (ao--make-test-session "tknown"))
          (buf (car pair))
          (session (cdr pair)))
     (cl-letf (((symbol-function 'acp-make-session-prompt-request)
                (lambda (&rest a)
                  `((:method . "session/prompt")
                    (:params . ((sessionId . ,(plist-get a :session-id))
                                (prompt . ,(plist-get a :prompt))))))))
       (setf (plist-get session :lists-sessions) t)
       (with-current-buffer buf
         (agent-org-buffer-set-status buf :title "Pushed Title")
         (agent-org-buffer-insert-prompt buf)
         (ao--type "hi")
         (agent-org-send)
         (ao--drive "session/prompt" nil)
         (should-not (ao--sent-get "session/list"))
         (should (equal "Pushed Title"
                        (plist-get agent-org-buffer--status :title)))))
     (kill-buffer buf))))

(ert-deftest test-agent-org-title-looked-up-only-once ()
  "`:title-seeked' makes the sync a one-shot: the second turn does not
page the directory again, even when the first lookup came back empty."
  (ao--capture-wire
   (let* ((pair (ao--make-test-session "tonce"))
          (buf (car pair))
          (session (cdr pair)))
     (cl-letf (((symbol-function 'acp-make-session-prompt-request)
                (lambda (&rest a)
                  `((:method . "session/prompt")
                    (:params . ((sessionId . ,(plist-get a :session-id))
                                (prompt . ,(plist-get a :prompt))))))))
       (setf (plist-get session :lists-sessions) t)
       (with-current-buffer buf
         (agent-org-buffer-insert-prompt buf)
         (ao--type "one")
         (agent-org-send)
         (ao--drive "session/prompt" nil)
         (ao--drive "session/list" (ao--list-resp nil))
         (agent-org-buffer-insert-prompt buf)
         (ao--type "two")
         (agent-org-send)
         (ao--drive "session/prompt" nil)
         (should (= 1 (length (ao--list-pages))))))
     (kill-buffer buf))))

(defun ao--drawer-folded-p (name)
  "Non-nil when the drawer NAME body in the current buffer is hidden."
  (save-excursion
    (goto-char (point-min))
    (and (re-search-forward (format "^:%s:" name) nil t)
         (progn (forward-line 1)
                (invisible-p (point))))))

(ert-deftest test-agent-org-metadata-folded-by-default ()
  "Every metadata drawer starts folded; the TITLE line stays visible."
  (let* ((pair (ao--make-test-session "fold"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :session-id) nil)
    (agent-org--session-ready session "sid-x" (ao--fake-session-new-resp))
    (with-current-buffer buf
      (should (ao--drawer-folded-p "PROPERTIES"))
      (should (ao--drawer-folded-p "MODES"))
      (should (ao--drawer-folded-p "CONFIG"))
      (should-not (string-match-p ":VISIBILITY:" (buffer-string)))
      ;; the TITLE keyword line is always visible
      (should (save-excursion
                (goto-char (point-min))
                (re-search-forward "^#\\+TITLE:")
                (not (invisible-p (match-beginning 0)))))
      ;; the folded content is still there, and the prompt stays open
      (should (string-match-p ":MODES:" (buffer-string)))
      (should (agent-org-buffer--open-prompt-p))
      (agent-org--session-ready session "sid-x" (ao--fake-session-new-resp))
      (should (ao--drawer-folded-p "MODES")))
    (kill-buffer buf)))

(ert-deftest test-agent-org-metadata-keeps-user-expanded-state ()
  "Refreshing a drawer the user opened does not re-fold it."
  (let* ((pair (ao--make-test-session "unfold"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :session-id) nil)
    (agent-org--session-ready session "sid-x" (ao--fake-session-new-resp))
    (with-current-buffer buf
      (should (ao--drawer-folded-p "MODES"))
      (save-excursion
        (goto-char (point-min))
        (re-search-forward "^:MODES:")
        (org-fold-hide-drawer-toggle))
      (agent-org-buffer-refresh-metadata buf)
      (should-not (ao--drawer-folded-p "MODES"))
      (should (ao--drawer-folded-p "CONFIG"))
      ;; still a single block
      (should (= 1 (ao--count-occurrences (buffer-string) "^:MODES:"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-metadata-refresh-idempotent ()
  "Repeated ready/notification updates never duplicate the block."
  (let* ((pair (ao--make-test-session "meta2"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :session-id) nil)
    (agent-org--session-ready session "sid-x" (ao--fake-session-new-resp))
    (agent-org--session-ready session "sid-x" (ao--fake-session-new-resp))
    (agent-org--on-notification
     session
     `((method . "session/update")
       (params . ((update . ((sessionUpdate . "available_commands_update")
                             (availableCommands .
                              [((name . "compact")
                                (description . "Compact the conversation"))
                               ((name . "status")
                                (description . "Show session status"))])))))))
    (with-current-buffer buf
      (should (= 1 (ao--count-substrings ":MODES:")))
      (should (= 1 (ao--count-substrings "#+TITLE:")))
      (should (= 1 (ao--count-substrings "* PROMPT")))
      (should (string-match-p ":COMMANDS:" (buffer-string)))
      (should (string-match-p "/compact — Compact the conversation"
                              (buffer-string))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-metadata-usage-update ()
  "usage_update feeds header and the Context property line."
  (let* ((pair (ao--make-test-session "usage2"))
         (buf (car pair))
         (session (cdr pair)))
    (agent-org--on-notification
     session
     `((method . "session/update")
       (params . ((update . ((sessionUpdate . "usage_update")
                             (used . 12000) (size . 128000)))))))
    (with-current-buffer buf
      (should (equal 12000 (plist-get agent-org-buffer--status :used)))
      (should (string-match-p "12k/128k"
                              (agent-org-buffer--render-header-line)))
      (should (string-match-p "^:Context: +12k/128k" (buffer-string))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-send-records-usage-cost ()
  "PromptResponse usage/cost land in the status model and header."
  (let* ((pair (ao--make-test-session "cost"))
         (buf (car pair))
         (captured nil))
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest kw) (setq captured kw))))
      (with-current-buffer buf
        (agent-org-buffer-insert-prompt buf)
        (ao--type "Hi")
        (agent-org-send)
        (funcall (plist-get captured :on-success)
                 '((usage (totalTokens . 500))
                   (cost (amount . 0.4237) (currency . "USD"))))
        (should (= 500 (plist-get agent-org-buffer--status :tokens)))
        (should (string-match-p "\\$0\\.43"
                                (agent-org-buffer--render-header-line)))
        ;; nil response (as other tests send) stays safe
        (agent-org-buffer-insert-prompt buf)
        (ao--type "Hi again")
        (agent-org-send)
        (funcall (plist-get captured :on-success) nil)
        (should (= 500 (plist-get agent-org-buffer--status :tokens)))))
    (kill-buffer buf)))

;;;; Tool keyword setup & mode-line hygiene

(ert-deftest test-agent-org-metadata-installs-five-disjoint-todo-sets ()
  "The chat buffer has FIVE keyword sets and no `#+TODO:' line anywhere.
The user's own five: prompts, thinking, writing, tool calls, plan items -- each
its own sequence, none sharing a word.  Disjointness is the property asserted
here, not a nicety: a word owned by two sets resolves to the FIRST owner, which
is how a bare `TODO' used to mean \"queued prompt\" and, with the prompt set no
longer starting with TODO, would otherwise mean \"plan item\".
The words come from the five option lists installed buffer-locally, never from a
setup line the renderer would have to keep in sync (§3, and the order contract
in `agent-org-buffer--todo-keyword-sets')."
  (let* ((pair (ao--make-test-session "kw"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :session-id) nil)
    (agent-org--session-ready session "sid-k" (ao--fake-session-new-resp))
    (with-current-buffer buf
      ;; no setup line anywhere: the metadata block carries TITLE only
      (should (= 0 (ao--count-occurrences (buffer-string) "^#\\+TODO:")))
      ;; the live set is the five sets, in the order that resolves a shared word
      (should (ao--todo-set-matches-the-options buf))
      (should (equal '("PROMPT" "RESPONDING" "IDLE" "NEXT" "WAIT" "|"
                       "RESPONDED" "CANCELLED" "ERROR")
                     agent-org-prompt-todo-keywords))
      ;; NEXT/WAIT ride in the prompt set's UNFINISHED half rather than a set of
      ;; their own because that is the only spelling that works: measured on Org
      ;; 9.7.11, `("NEXT" "WAIT" "|")' answers `org-done-keywords' = ("WAIT"), so
      ;; a queue set would render every waiting prompt but the first as DONE.
      ;; Positions 0-2 stay what `--prompt-keyword-for-state' reads.
      (should (equal '("NEXT" "WAIT") agent-org-buffer--queue-keywords))
      (should (equal '("THINKING" "|" "THOUGHT")
                     agent-org-thinking-todo-keywords))
      (should (equal '("WRITING" "|" "WROTE")
                     agent-org-response-todo-keywords))
      (should (equal '("RUNNING" "|" "EXECUTED" "FAILED")
                     agent-org-tool-todo-keywords))
      (should (equal '("TODO" "WORKING" "|" "DONE")
                     agent-org-plan-todo-keywords))
      (dolist (word '("PROMPT" "RESPONDING" "IDLE" "NEXT" "WAIT"
                      "RESPONDED" "CANCELLED" "ERROR"
                      "THINKING" "THOUGHT" "WRITING" "WROTE"
                      "RUNNING" "EXECUTED" "FAILED" "TODO" "WORKING" "DONE"))
        (should (member word org-todo-keywords-1)))
      ;; the multi-set form flattens every sequence's OWN two halves into the two
      ;; lists Org cycles over, in set order
      (should (equal '("PROMPT" "RESPONDING" "IDLE" "NEXT" "WAIT" "THINKING"
                       "WRITING" "RUNNING" "TODO" "WORKING")
                     org-not-done-keywords))
      (should (equal '("RESPONDED" "CANCELLED" "ERROR" "THOUGHT" "WROTE"
                       "EXECUTED" "FAILED" "DONE")
                     org-done-keywords))
      ;; DISJOINT: no word is both unfinished and done, and no word is in two sets
      (should-not (seq-intersection org-done-keywords org-not-done-keywords))
      (should (= (length org-todo-keywords-1)
                 (+ (length org-not-done-keywords) (length org-done-keywords))))
      ;; and none of this reaches outside an agent-org buffer
      (should-not (member "RESPONDING" (default-value 'org-todo-keywords-1))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-prompt-heading-mirrors-the-header-line-status ()
  "The exchange heading's ONE word is the header line's state, in the prompt set.
\"prompt TODO keywords should reflect the status indicator in header line\" -- so
the same `agent-org-buffer-set-status' call that repaints the bar is the only
writer of the heading's word, and the two can never disagree.  streaming →
RESPONDING, awaiting (a permission request: waiting on YOU) → IDLE, ready →
RESPONDED, a cancelled turn → CANCELLED, error → ERROR.

starting and loading write NOTHING: before a prompt exists there is no heading
to wear a word, and a restore is not an answer.  The prompt's own first word
(PROMPT) is put there by `agent-org-buffer-begin-exchange', which is also why a
send that dies before its first chunk still carries a state.
The heading's TEXT and everything under it stay byte-identical -- one word on
one line is the whole edit."
  (let ((buf (agent-org-buffer-create "statuskw")))
    (agent-org-buffer-begin-exchange buf "Do it?")
    (agent-org-buffer-append-chunk buf "the answer\n" nil)
    (with-current-buffer buf
      (should (string-match-p "^\\* PROMPT Do it\\?$" (buffer-string)))
      (dolist (step '((streaming . "RESPONDING")
                      (awaiting . "IDLE")
                      (ready . "RESPONDED")
                      (error . "ERROR")))
        (agent-org-buffer-set-status buf :state (car step))
        (should (string-match-p (format "^\\* %s Do it\\?$" (cdr step))
                                (buffer-string)))
        ;; the body is untouched by a word swap: the answer line is still there
        (should (string-match-p "^the answer$" (buffer-string))))
      ;; CANCELLED is the one state that shares a `:state' with success, so the
      ;; NOTE decides it -- and through the shared constant, not a string typed
      ;; twice (agent-org.el's cancel site uses the same one)
      (agent-org-buffer-set-status buf :state 'ready
                                   :note agent-org-buffer--cancel-note)
      (should (string-match-p "^\\* CANCELLED Do it\\?$" (buffer-string)))
      ;; and the states that say nothing, say nothing
      (let ((before (buffer-string)))
        (agent-org-buffer-set-status buf :state 'starting)
        (agent-org-buffer-set-status buf :state 'loading)
        (should (equal before (buffer-string)))))
    (kill-buffer buf))
  ;; the mapping is POSITIONAL: rename the set and the states follow, so no
  ;; renderer carries the user's vocabulary as a literal
  (let ((agent-org-prompt-todo-keywords
         '("ASKED" "ANSWERING" "PAUSED" "|" "ANSWERED" "ABORTED" "BROKE")))
    (should (equal (agent-org-buffer--prompt-keyword-for-state 'streaming nil)
                   "ANSWERING"))
    (should (equal (agent-org-buffer--prompt-keyword-for-state 'awaiting nil)
                   "PAUSED"))
    (should (equal (agent-org-buffer--prompt-keyword-for-state 'ready nil)
                   "ANSWERED"))
    (should (equal (agent-org-buffer--prompt-keyword-for-state
                    'ready agent-org-buffer--cancel-note)
                   "ABORTED"))
    (should (equal (agent-org-buffer--prompt-keyword-for-state 'error nil)
                   "BROKE"))
    (should (equal (agent-org-buffer--prompt-keyword-for-state 'loading nil)
                   nil))
    (should (equal (agent-org-buffer--prompt-keyword-for-state 'starting nil)
                   nil))))

(ert-deftest test-agent-org-prompt-keyword-writer-is-a-no-op-without-a-prompt ()
  "A status change with no exchange open touches nothing and never errors.
Two real shapes: a fresh chat that has only just started (`starting', then
`loading' -- no heading exists yet), and an ORPHAN turn, where restored history
carries agent updates that no user message precedes.  An orphan's heading is
`* Agent', which is not a prompt and never had one to answer, so it wears no
state word at all -- the flag `--begin-exchange' raises is what tells the writer
that the heading in front of it is the user's question."
  (let ((buf (agent-org-buffer-create "statuskw-none")))
    ;; no exchange: every state is a no-op, and the buffer stays exactly as
    ;; created (the metadata block only, no stray word)
    (let ((before (with-current-buffer buf (buffer-string))))
      (dolist (state '(starting loading streaming ready error awaiting))
        (agent-org-buffer-set-status buf :state state))
      (should (equal before (with-current-buffer buf (buffer-string)))))
    ;; an orphan turn: a heading exists, but it is not a prompt
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-thought buf "weighing it")
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (string-match-p "^\\* Agent$" text))
      (should-not (string-match-p "^\\* \\(RESPONDING\\|PROMPT\\) Agent$" text)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-prompt-keyword-writer-preserves-global-match-data ()
  "The heading writer saves the match data, because a live scan may be resting on it.
Documented gotcha in this file: a helper calling `string-match' clobbers the
global match data a scan is built on, and the damage shows up minutes later in
whichever code reads `match-string' after the callback that moved it.  The
status writer runs INSIDE ACP notification callbacks, so it is exactly the
helper that must not leave its own match data behind."
  (let ((buf (agent-org-buffer-create "statuskw-md"))
        (scan (get-buffer-create " ao-md-scan")))
    (unwind-protect
        (progn
          (agent-org-buffer-begin-exchange buf "Do it?")
          (with-current-buffer scan
            (erase-buffer)
            (insert "the needle here\n")
            (goto-char (point-min))
            (re-search-forward "needle")
            (should (equal "needle" (match-string 0)))
            (let ((from (match-beginning 0)) (to (match-end 0)))
              ;; the interrupting write, in ANOTHER buffer -- the exact shape an
              ;; ACP notification callback has while a scan is in flight
              (agent-org-buffer-set-status buf :state 'streaming)
              ;; positions AND the buffer they belong to: `match-string' reads
              ;; from the scan, not from the chat it interrupted
              (should (equal (list from to)
                             (list (match-beginning 0) (match-end 0))))
              (should (equal "needle" (match-string 0)))))
          ;; and the write itself happened
          (should (string-match-p "^\\* RESPONDING Do it\\?$"
                                  (with-current-buffer buf (buffer-string)))))
      (kill-buffer buf)
      (kill-buffer scan))))

(ert-deftest test-agent-org-end-of-turn-settles-the-exchange-heading ()
  "A finished exchange reads RESPONDED even when no status event wrote it.
Replay is the case that proves the rule: restored history runs through the SAME
rendering primitives but no per-turn `:state 'streaming' / 'ready' calls, so if
only `set-status' wrote words every restored prompt would sit there claiming to
still be waiting.  `agent-org-buffer-end-agent-turn' is a turn boundary in both
paths, so it settles the heading itself and `set-status' only OVERLAYS the
in-flight states on a live turn."
  (let ((buf (agent-org-buffer-create "statuskw-settle")))
    (agent-org-buffer-begin-exchange buf "Capital?")
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-chunk buf "Paris.\n" nil)
    (agent-org-buffer-end-agent-turn buf)
    (with-current-buffer buf
      (should (string-match-p "^\\* RESPONDED Capital\\?$" (buffer-string))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-transcript-visit-installs-todo-sets ()
  "A transcript opened with `find-file' gets the same three sets.
There is no `#+TODO:' line in the FILE to read any more, so a mirror visited in
another buffer would start with Org's default set and every `** EXECUTED ls'
headline on screen would read as plain text.  The hook that fixes it must also
stay a no-op for any other file -- a hook calling `org-mode' unconditionally
would hijack every visit (see the test after this one)."
  (let* ((dir (locate-user-emacs-file "agent-org-test-transcripts/"))
         ;; a transcript is judged by its directory, so binding the option to
         ;; this one makes everything inside it a mirror
         (agent-org-transcript-dir (file-name-as-directory dir))
         (file (concat dir "sid-kw.org"))
         (agent-org-transcribe nil)
         buffer)
    (make-directory dir t)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "#+TITLE: mirror\n\n* RESPONDED a question\n\n"
                    "** EXECUTED ls\n"))
          (setq buffer (find-file file))
          (with-current-buffer buffer
            (should (derived-mode-p 'org-mode))
            (should (ao--todo-set-matches-the-options buffer))
            ;; the mirror is read-only as it always was
            (should buffer-read-only)
            (save-excursion
              (goto-char (point-min))
              (re-search-forward "^\\*\\* ")
              (should (equal "EXECUTED" (org-get-todo-state))))))
      (when (buffer-live-p buffer)
        (set-buffer-modified-p nil)
        (kill-buffer buffer))
      (delete-directory dir t))))

(ert-deftest test-agent-org-find-file-hook-leaves-non-transcripts-alone ()
  "The transcript hook changes nothing about an ordinary Org file.
One string comparison decides it: a file outside the transcript directory keeps
Org's default keyword set and stays writable, so binding this hook cannot stop
a person opening the notes file they keep next to their chats."
  (let* ((dir (locate-user-emacs-file "agent-org-test-plain/"))
         (file (concat dir "notes.org"))
         (agent-org-transcribe nil)
         buffer)
    (make-directory dir t)
    (unwind-protect
        (progn
          (with-temp-file file (insert "* TODO an ordinary note\n"))
          (setq buffer (find-file file))
          (with-current-buffer buffer
            (should-not (member "RESPONDING" org-todo-keywords-1))
            (should-not buffer-read-only)))
      (when (buffer-live-p buffer)
        (set-buffer-modified-p nil)
        (kill-buffer buffer))
      (delete-file file)
      (delete-directory dir t))))

(ert-deftest test-agent-org-leaves-mode-line-alone ()
  "The chat buffer's mode line carries no agent-org lighter and no
mode-line construct is mutated: all status lives in the header line."
  (let ((buf (agent-org-buffer-create "ml")))
    (with-current-buffer buf
      (should (null (assq 'agent-org-mode minor-mode-alist)))
      (agent-org-buffer-set-status buf :state 'ready :message "Ready")
      (should (equal (default-value 'mode-line-format) mode-line-format)))
    (kill-buffer buf)))

;;;; Resume (qoder provider, session/list -> session/load replay)

(defun ao--update-notif (update)
  "Wrap an update alist UPDATE as a session/update notification."
  `((method . "session/update")
    (params . ((update . ,update)))))

(defun ao--ordered (string &rest patterns)
  "Non-nil when PATTERNS all match STRING in the given order."
  (let ((from 0) (ok t))
    (dolist (p patterns ok)
      (if (string-match p string from)
          (setq from (match-end 0))
        (setq ok nil)))))

(ert-deftest test-agent-org-qoder-provider-registered ()
  "Qoder ships as a provider: `qoder --acp', env token passthrough."
  (let ((qoder (seq-find (lambda (p) (eq (plist-get p :id) 'qoder))
                         agent-org-providers)))
    (should qoder)
    (should (equal (plist-get qoder :name) "Qoder"))
    (should (equal (plist-get qoder :command) '("qoder" "--acp")))
    (should (fboundp (plist-get qoder :environment)))
    ;; the personal access token rides through when set...
    (should (equal (let ((process-environment
                          (cons "QODER_PERSONAL_ACCESS_TOKEN=tok"
                                process-environment)))
                     (funcall (plist-get qoder :environment)))
                   '("QODER_PERSONAL_ACCESS_TOKEN=tok")))
    ;; ...and is simply absent when not
    (should (equal (let ((process-environment
                          (seq-remove (lambda (e)
                                        (string-prefix-p
                                         "QODER_PERSONAL_ACCESS_TOKEN=" e))
                                      process-environment)))
                     (funcall (plist-get qoder :environment)))
                   nil))))

(ert-deftest test-agent-org-default-provider-resolves-spec ()
  "`agent-org-default-provider' names the provider resume uses without
a prefix argument; `agent-org--provider-spec' validates ids."
  (should (boundp 'agent-org-default-provider))
  (should (member agent-org-default-provider '(goose qoder)))
  (should (equal (plist-get (agent-org--provider-spec 'qoder) :name) "Qoder"))
  (should (equal (plist-get (agent-org--provider-spec 'goose) :command)
                 '("goose" "acp")))
  (should-error (agent-org--provider-spec 'nope) :type 'user-error))

(ert-deftest test-agent-org-session-candidates-from-list-resp ()
  "session/list responses map to (DISPLAY . ID) pairs, newest first;
untitled sessions still get an entry."
  (let* ((resp `((sessions . [((sessionId . "s1") (title . "Alpha")
                               (updatedAt . "2026-09-01"))
                              ((sessionId . "s2") (updatedAt . "2026-09-02"))])))
         (cands (agent-org--session-candidates resp)))
    (should (= 2 (length cands)))
    (should (equal (cdr (car cands)) "s2"))
    (should (equal (cdr (nth 1 cands)) "s1"))
    (should (string-match-p "Alpha" (car (nth 1 cands))))
    (should (equal (agent-org--session-candidates '((sessions . []))) nil))))

(ert-deftest test-agent-org-session-candidates-title-is-one-short-line ()
  "Live qoder puts the whole first prompt — thousands of characters
over many lines — in a session's `title', so the raw value would flood
the completion list and break the candidate lines.  DISPLAY must be one
short line that still carries the id, and an ordinary title must
survive untouched.  The line also spends `agent-org-buffer--label-width'
on the title and then adds the recency date, so the whole thing is
bounded by label width + date + id rather than by 80.  The gaps below are
` +' not two spaces: columns are padded to the batch's widest row, which
is what `test-agent-org-session-candidates-align-in-columns' pins."
  (let* ((blob (concat "Resume all sessions paused with errors!\n"
                       (make-string 3000 ?x) "\nlast line"))
         (resp `((sessions . [((sessionId . "big") (title . ,blob)
                               (updatedAt . "2026-09-02"))
                              ((sessionId . "small") (title . "Short one")
                               (updatedAt . "2026-09-01"))])))
         (cands (agent-org--session-candidates resp))
         (display (lambda (id)
                    (car (seq-find (lambda (c) (equal (cdr c) id)) cands)))))
    (let ((big (funcall display "big")))
      (should-not (string-match-p "\n" big))
      (should (< (length big)
                 (+ agent-org-buffer--label-width 30)))
      (should (string-match-p "\\[big\\]\\'" big))
      (should (string-match-p "Resume all sessions" big))
      (should (string-match-p "…" big)))
    (should (string-match "\\`Short one +Sep 01, [0-9][0-9]:[0-9][0-9] +\\[small\\]\\'"
                          (funcall display "small")))))

(ert-deftest test-agent-org-read-session-id-single-or-error ()
  "One listed session needs no prompt; an empty list errors out."
  (should (equal (agent-org--read-session-id
                  `((sessions . [((sessionId . "solo") (title . "Only"))])))
                 "solo"))
  (should-error (agent-org--read-session-id '((sessions . [])))
                :type 'user-error))

(ert-deftest test-agent-org-loading-buffers-replay-without-rendering ()
  "While a session/load is in flight, conversational updates are
buffered onto :replay and NEVER painted: the history renders in one
batched pass when the load response arrives."
  (let* ((pair (ao--make-test-session "loadbuf"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :loading) t)
    (dolist (update (list
                     '((sessionUpdate . "user_message_chunk")
                       (content . ((type . "text") (text . "Q1"))))
                     '((sessionUpdate . "agent_message_chunk")
                       (content . ((type . "text") (text . "A1"))))
                     '((sessionUpdate . "tool_call")
                       (toolCallId . "t1") (title . "shell") (status . "pending"))
                     '((sessionUpdate . "agent_thought_chunk")
                       (content . ((type . "text") (text . "hmm"))))))
      (agent-org--on-notification session (ao--update-notif update)))
    (with-current-buffer buf
      (should (= 4 (length (plist-get session :replay))))
      (should-not (string-match-p "^\\* PROMPT\\|^\\* Agent\\|Q1\\|A1\\|shell"
                                  (buffer-string))))
    ;; a session_info_update mid-load sets the id but must NOT open a
    ;; prompt: the buffer isn't interactive until the load lands
    (agent-org--on-notification
     session `((method . "session/update")
               (params . ((sessionId . "sid-l")
                          (update . ((sessionUpdate . "session_info_update")))))))
    (should (equal (plist-get session :session-id) "sid-l"))
    (with-current-buffer buf
      (should-not (string-match-p "^\\* PROMPT$" (buffer-string))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-render-replay-builds-history ()
  "The batched replay paints one heading per question, its answer under the
model/`Agent' prefix, the tool drawer and the thinking drawer in history
order, closes all turns, and leaves font-lock alone."
  (let* ((pair (ao--make-test-session "replay"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :loading) t)
    (dolist (update (list
                     '((sessionUpdate . "user_message_chunk")
                       (content . ((type . "text") (text . "Hello "))))
                     '((sessionUpdate . "user_message_chunk")
                       (content . ((type . "text") (text . "world"))))
                     '((sessionUpdate . "agent_message_chunk")
                       (content . ((type . "text") (text . "Answer"))))
                     '((sessionUpdate . "tool_call")
                       (toolCallId . "t1") (title . "shell") (status . "completed"))
                     '((sessionUpdate . "agent_thought_chunk")
                       (content . ((type . "text") (text . "thinking hard"))))
                     '((sessionUpdate . "user_message_chunk")
                       (content . ((type . "text") (text . "Next question"))))))
      (agent-org--on-notification session (ao--update-notif update)))
    (let ((font-lock-was (with-current-buffer buf font-lock-mode)))
      (agent-org--render-replay session)
      (with-current-buffer buf
        (let ((s (buffer-string)))
          ;; the two user chunks collapse into ONE heading with joined text,
          ;; and the answer carries no heading of its own — it streams under
          ;; the prefix (no model on this replay session, so the word is Agent)
          (should (= 1 (ao--count-occurrences s "^\\* RESPONDED Hello world$")))
          (should (= 1 (ao--count-occurrences s "^\\* RESPONDED Next question$")))
          (should (= 0 (ao--count-occurrences s "^\\* Agent$")))
          (should (= 1 (ao--count-occurrences s "^Agent: $")))
          (should (= 1 (ao--count-occurrences s "^Answer$")))
          (should (apply #'ao--ordered s
                         (list "Hello world" "Answer"
                               "^  - EXECUTED shell$"
                               "thinking hard" "Next question")))
          (should (string-match-p "^:thinking:$" s))
          (should (string-match-p "^:tool:$" s)))
        (should-not agent-org-buffer--streaming-p)
        ;; A replay never suppresses font-lock (see
        ;; `test-agent-org-replay-never-touches-font-lock'): the paint pass leaves
        ;; the buffer's own state exactly as it found it.  Batch Emacs can never
        ;; enable font-lock, so this reads as nil in both cases -- what is pinned is
        ;; that the replay changed nothing.
        (should (eq font-lock-mode font-lock-was))
        (should (null (plist-get session :replay)))))
    (kill-buffer buf)))

;;;; A chat buffer gets its colors when it is SHOWN

(ert-deftest test-agent-org-chat-buffer-asks-for-font-lock-when-displayed ()
  "A chat buffer must ask for font-lock at display time, not at creation.
`font-lock-mode' cannot be enabled in a buffer NO window is showing: measured in
a live Emacs, `(font-lock-mode 1)' in a hidden buffer leaves the variable nil
with no error and no trace, and so does `turn-on-font-lock'.  Chat buffers are
created hidden (`agent-org-buffer-create' is called from a handshake callback),
so the ambient `global-font-lock-mode' can never reach them and they open with
no Org colors at all.  `agent-org-mode' therefore adds
`agent-org-buffer--ensure-font-lock' to this buffer's
`window-configuration-change-hook', which Emacs runs with the buffer current
when it first appears in a window.

Batch Emacs is the hidden case, so the stub plays the part of a displayed
buffer: it records the request and sets the variable, which is what a window
would have made Emacs do."
  (let ((b (agent-org-buffer-create "flshow"))
        (asked nil))
    (unwind-protect
        (cl-letf (((symbol-function 'font-lock-mode)
                   (lambda (&optional arg)
                     (push arg asked)
                     (when arg (setq-local font-lock-mode t))))
                  ((symbol-function 'font-lock-flush)
                   (lambda (&rest _) nil)))
          (with-current-buffer b
            ;; the premise: creation left it off, exactly as a live hidden buffer
            (should-not font-lock-mode)
            ;; the mode really did install itself on THIS buffer's display hook
            (should (memq #'agent-org-buffer--ensure-font-lock
                          (symbol-value 'window-configuration-change-hook)))
            ;; Emacs' own display path: the buffer-local hook, buffer current
            (run-hooks 'window-configuration-change-hook)
            (should font-lock-mode)
            (should (memq 1 asked))
            ;; and asking again costs nothing: it is an `unless', not a toggle
            (let ((before (length asked)))
              (run-hooks 'window-configuration-change-hook)
              (should (equal before (length asked))))))
      (kill-buffer b))))

;;;; A failed replay must not cost the buffer its colors

(ert-deftest test-agent-org-replay-never-touches-font-lock-even-when-the-paint-errors ()
  "No render path may switch font-lock off, because its OFF is restorable and
its ON is not: in a live Emacs `(font-lock-mode 1)' in a buffer no window is
showing does nothing at all.  So a replay that suppressed font-lock and restored
it afterwards lost the chat's colors forever whenever the resume painted into a
background buffer -- the user's second \"colors gone again!\" -- and an error in
the middle lost them even in a shown one.

The whole suppression is therefore gone: a replay leaves `font-lock-mode'
untouched and only flushes.  The honest batch pin is the SEQUENCE of calls: the
paint may not call `font-lock-mode' at all, not even to put it back."
  (let* ((pair (ao--make-test-session "flerr"))
         (buf (car pair))
         (session (cdr pair))
         (raised nil)
         (errored nil)
         (calls nil))
    (with-current-buffer buf
      ;; the premise: this buffer's colors are ON before the replay
      (setq-local font-lock-mode t))
    (setf (plist-get session :loading) t)
    (setf (plist-get session :replay)
          (list (ao--update-notif
                 '((sessionUpdate . "agent_message_chunk")
                   (content . ((type . "text") (text . "boom-proof")))))))
    (cl-letf (((symbol-function 'agent-org--buffer-update)
               (lambda (&rest _)
                 (setq raised t)
                 (signal 'error '("paint boom"))))
              ((symbol-function 'font-lock-mode)
               (lambda (&optional arg) (push (list 'mode arg) calls)))
              ((symbol-function 'font-lock-flush)
               (lambda (&rest a) (push (cons 'flush a) calls)))
              ((symbol-function 'agent-org--progress-stop)
               (lambda (&rest _) (push 'stop calls))))
      (condition-case nil
          (agent-org--render-replay session)
        (error (setq errored t))))
    (should raised)                    ; the paint really did raise
    (should errored)                   ; …and the error propagated to acp
    (with-current-buffer buf
      ;; CAR-SAFE, not CAR: the stop marker is pushed as the bare symbol
      ;; `stop', and `car' (or `assq') over that element errors.
      (should (null (seq-filter (lambda (c) (eq (car-safe c) 'mode)) calls)))
      (should font-lock-mode)          ; nothing could have taken it away
      (should (seq-filter (lambda (c) (eq (car-safe c) 'flush)) calls))
      (should (memq 'stop calls)))     ; the Restoring report cannot leak
    (kill-buffer buf)))

;;;; Resume end-to-end (drives the async chain with a capturing mock)
(defvar ao--sent nil
  "Requests captured by the resume wire mock, newest first.
Each entry is (METHOD :REQUEST REQUEST :on-success CALLBACK).")

(defun ao--sent-get (method)
  "The most recent captured entry for METHOD, or nil."
  (cdr (assoc method ao--sent)))

(defun ao--drive (method resp)
  "Fail unless METHOD was sent, then run its on-success with RESP."
  (let ((entry (ao--sent-get method)))
    (should entry)
    (funcall (plist-get entry :on-success) resp)))

(defvar ao--timer nil
  "Armed (FUNCTION . ARGS) of the pending timer inside `ao--capture-wire'.")

(defvar ao--list-timer nil
  "Armed (FUNCTION . ARGS) of the pending session/list timeout.
Goose advertises the `list' capability and then never answers it, so a
test that means \"the agent stayed silent\" fires this one.")

(defvar ao--armings 0
  "How many times `run-at-time' was called inside `ao--capture-wire'.
Tests assert on this to see a deferred render re-armed by late input.")

(defun ao--settle ()
  "Fire the pending timer, the way the event loop would after a delay.
Resume defers its batched render until the replayed updates stop
arriving; tests must not sleep on a real timer, so `ao--capture-wire'
captures `run-at-time' here and the test decides when quiet has come."
  (when ao--timer
    (apply #'funcall ao--timer)
    (setq ao--timer nil)))

(defun ao--collection (collection)
  "The plain candidate list behind a `completing-read' COLLECTION.
agent-org hands `completing-read' a FUNCTION rather than a list so it can
carry completion metadata (pinned order); a test that wants to look at the
candidates has to ask the collection for them, which is exactly what the
completion UI does.  ACTION `t' is the documented \"give me every
completion\" — `all' is not an action at all (`complete-with-action'
answers it with nil), which is how this test first went silently green."
  (if (functionp collection)
      (funcall collection "" nil t)
    collection))

(defun ao--time-out ()
  "Fire the pending session/list timeout, as a silent agent would allow."
  (when ao--list-timer
    (apply #'funcall ao--list-timer)
    (setq ao--list-timer nil)))

(defun ao--list-pages ()
  "Params of every captured `session/list' request, oldest page first.
Pagination tests read the `cursor' out of the second entry to see that
the continuation the agent offered was actually followed."
  (seq-map (lambda (entry)
             (map-elt (plist-get (cdr entry) :request) ':params))
           (reverse (seq-filter (lambda (pair) (equal (car pair) "session/list"))
                                ao--sent))))

(defmacro ao--capture-wire (&rest body)
  "Run BODY with `acp-send-request' capturing requests to `ao--sent'.
Lets a test pump the resume handshake synchronously, driving each
response callback the way the process filter would.  Timers are
captured too (see `ao--settle'), because nothing here may block on
real time."
  `(let ((ao--sent nil) (ao--timer nil) (ao--list-timer nil) (ao--armings 0))
     (cl-letf (((symbol-function 'acp-send-request)
                ;; `&rest' then plist reads: an interpreted `&key' lambda
                ;; does not parse keywords at all, so the cl-letf'd
                ;; function would be called with the raw plist as
                ;; positional args.
                (lambda (&rest kw)
                  (let ((request (plist-get kw :request)))
                    (push (cons (map-elt request ':method)
                                (list :request request
                                      :on-success (plist-get kw :on-success)
                                      :on-failure (plist-get kw :on-failure)))
                          ao--sent))))
               ((symbol-function 'executable-find) (lambda (&rest _) t))
               ;; (run-at-time SECONDS REPEAT FUNCTION &rest ARGS).  Org
               ;; arms its own timers when a chat buffer is created, so
               ;; only the timers agent-org owns are captured and counted.
               ((symbol-function 'run-at-time)
                (lambda (&rest args)
                  (cond
                   ((eq (nth 2 args) 'agent-org--finish-replay)
                    (cl-incf ao--armings)
                    (setq ao--timer (cons (nth 2 args) (nthcdr 3 args)))))
                  (when (eq (nth 2 args) 'agent-org--list-timeout)
                    (setq ao--list-timer (cons (nth 2 args) (nthcdr 3 args))))
                  (list :captured-timer)))
               ((symbol-function 'cancel-timer) (lambda (&rest _) nil)))
       ,@body)))

(defconst ao--fake-init-resp
  '((agentCapabilities . ((loadSession . t)
                          (sessionCapabilities . ((list) (close) (delete))))))
  "Initialize response advertising load + list.")

(ert-deftest test-agent-org-resume-end-to-end-with-explicit-id ()
  "initialize -> session/load -> updates buffered -> batched render ->
ready + open prompt.  An explicit SESSION-ID skips session/list."
  (ao--capture-wire
    (let* ((buf (agent-org-resume-session 'qoder "sid-r"))
           (session (agent-org--session-for-buffer buf)))
      (should session)
      (should (eq (plist-get session :name) 'qoder))
      (should (equal (caar ao--sent) "initialize"))
      (ao--drive "initialize" ao--fake-init-resp)
      (should (equal (caar ao--sent) "session/load"))
      (should-not (ao--sent-get "session/list"))
      (let ((request (plist-get (ao--sent-get "session/load") :request)))
        (should (equal (map-elt (map-elt request ':params) 'sessionId)
                       "sid-r")))
      ;; while the load is in flight the header says Restoring and
      ;; replay updates never touch the body
      (with-current-buffer buf
        (should (equal (plist-get agent-org-buffer--status :state)
                       'loading))
        (should (string-match-p "Restoring"
                                (agent-org-buffer--render-header-line))))
      (dolist (update (list
                       '((sessionUpdate . "user_message_chunk")
                         (content . ((type . "text") (text . "Old question"))))
                       '((sessionUpdate . "agent_message_chunk")
                         (content . ((type . "text") (text . "Old answer"))))))
        (agent-org--on-notification session (ao--update-notif update)))
      (with-current-buffer buf
        (should-not (string-match-p "Old question" (buffer-string))))
      ;; the load response alone must not render: the agent is still
      ;; talking.  Quiet is what paints the history once and flips live.
      (ao--drive "session/load" '((sessionId . "sid-r")))
      (should (plist-get session :loading))
      (ao--settle)
      (with-current-buffer buf
        (should (string-match-p "Old question" (buffer-string)))
        (should (string-match-p "Old answer" (buffer-string)))
        (should (apply #'ao--ordered (buffer-string)
                       (list "Old question" "Old answer")))
        (should (equal (plist-get agent-org-buffer--status :state)
                       'ready))
        (should (agent-org-buffer--open-prompt-p)))
      (should (null (plist-get session :loading)))
      (should-not (plist-get session :streaming))
      (kill-buffer buf))))

(ert-deftest test-agent-org-resume-queries-list-when-no-id ()
  "Without an explicit id, resume lists sessions and loads the chosen
one (a single listing is auto-selected, no prompt)."
  (ao--capture-wire
    (let* ((buf (agent-org-resume-session 'qoder nil))
           (session (agent-org--session-for-buffer buf)))
      (ao--drive "initialize" ao--fake-init-resp)
      (should (equal (caar ao--sent) "session/list"))
      (ao--drive "session/list"
                 `((sessions . [((sessionId . "solo-1")
                                 (title . "Solo chat")
                                 (updatedAt . "2026-09-29T04:00:00Z"))])))
      (let ((request (plist-get (ao--sent-get "session/load") :request)))
        (should request)
        ;; ACP requests are alists of (:key . value) pairs, not plists:
        ;; read them with `map-elt', never `plist-get'.
        (should (equal (map-elt (map-elt request ':params) 'sessionId)
                       "solo-1")))
      (ao--drive "session/load" '((sessionId . "solo-1")))
      (ao--settle)
      (with-current-buffer buf
        (should (equal (plist-get agent-org-buffer--status :state)
                       'ready))
        (should (equal (plist-get session :session-id) "solo-1")))
      (kill-buffer buf))))

(ert-deftest test-agent-org-replay-renders-updates-arriving-after-response ()
  "The ACP spec says history arrives before the session/load response,
but live qoder answers first and streams the replay right after.  The
response must therefore NOT be the flush point: late updates stay
buffered, each one re-arms the quiet-period render, and the whole
history — before and after the response — lands in one pass."
  (ao--capture-wire
    (let ((buf (agent-org-resume-session 'qoder "sid-late")))
      (let ((session (agent-org--session-for-buffer buf)))
        (ao--drive "initialize" ao--fake-init-resp)
        (agent-org--on-notification
         session (ao--update-notif
                  '((sessionUpdate . "user_message_chunk")
                    (content . ((type . "text") (text . "Old question"))))))
        (ao--drive "session/load" '((sessionId . "sid-late")))
        (should (= 1 ao--armings))
        (with-current-buffer buf
          (should (equal 'loading (plist-get agent-org-buffer--status :state)))
          (should-not (string-match-p "Old question" (buffer-string))))
        ;; history that lands after the response is still buffered, and
        ;; pushes the render back rather than being dropped
        (agent-org--on-notification
         session (ao--update-notif
                  '((sessionUpdate . "agent_message_chunk")
                    (content . ((type . "text") (text . "Old answer"))))))
        (should (= 2 ao--armings))
        (should (= 2 (length (plist-get session :replay))))
        (with-current-buffer buf
          (should-not (string-match-p "Old answer" (buffer-string))))
        ;; quiet: one batched render, then live
        (ao--settle)
        (with-current-buffer buf
          (should (apply #'ao--ordered (buffer-string)
                         (list "Old question" "Old answer")))
          (should (equal 'ready (plist-get agent-org-buffer--status :state)))
          (should (agent-org-buffer--open-prompt-p)))
        (should (null (plist-get session :loading)))
        (should (null (plist-get session :replay)))
        (should (null (plist-get session :replay-timer)))
        (should (equal "sid-late" (plist-get session :session-id)))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-replay-paints-every-tool-call-of-a-turn ()
  "A replayed turn keeps the same shape as a typed one: one heading wearing
the question, its answer streaming under the model/`Agent' prefix, one
`:tool:' drawer line per distinct toolCallId, thoughts folded in their own
drawer, and an update rewriting its own line instead of adding a second.
Live qoder replayed 4 tool calls but the buffer showed 1 heading, so this
pins the whole turn down at once."
  (ao--capture-wire
    (let ((buf (agent-org-resume-session 'qoder "sid-tools")))
      (let ((session (agent-org--session-for-buffer buf)))
        (ao--drive "initialize" ao--fake-init-resp)
        (ao--drive "session/load" '((sessionId . "sid-tools")))
        (dolist (update
                 (list '((sessionUpdate . "user_message_chunk")
                         (content . ((type . "text") (text . "Do things"))))
                       '((sessionUpdate . "agent_thought_chunk")
                         (content . ((type . "text") (text . "plan"))))
                       '((sessionUpdate . "agent_message_chunk")
                         (content . ((type . "text") (text . "working"))))
                       '((sessionUpdate . "tool_call")
                         (toolCallId . "t1") (title . "read a") (status . "pending"))
                       '((sessionUpdate . "agent_thought_chunk")
                         (content . ((type . "text") (text . "more"))))
                       '((sessionUpdate . "tool_call")
                         (toolCallId . "t2") (title . "read b") (status . "pending"))
                       '((sessionUpdate . "agent_thought_chunk")
                         (content . ((type . "text") (text . "even more"))))
                       '((sessionUpdate . "tool_call")
                         (toolCallId . "t3") (title . "read c") (status . "pending"))
                       '((sessionUpdate . "agent_thought_chunk")
                         (content . ((type . "text") (text . "last"))))
                       '((sessionUpdate . "tool_call")
                         (toolCallId . "t4") (title . "read d") (status . "pending"))
                       ;; t1 finishes: rewrites its line, never a fifth one
                       '((sessionUpdate . "tool_call_update")
                         (toolCallId . "t1") (status . "completed"))))
          (agent-org--on-notification session (ao--update-notif update)))
        (should (= 11 (length (plist-get session :replay))))
        ;; armed once by the load response, then pushed back as long as
        ;; updates keep coming
        (should (> ao--armings 1))
        (ao--settle)
        (let ((text (with-current-buffer buf (buffer-string))))
          (should (string-match-p "Do things" text))
          (should (equal 1 (ao--count-occurrences text "^\\* RESPONDED Do things$")))
          (should (equal 1 (ao--count-occurrences text "^Agent: $")))
          (should (equal 1 (ao--count-occurrences text "^working$")))
          (should (= 0 (ao--count-occurrences text "^#\\+begin_quote$")))
          (should (equal 4 (ao--count-occurrences text "^  - ")))
          ;; the completed call was rewritten in place, the others stayed
          ;; pending
          (should (equal 1 (ao--count-occurrences text "^  - EXECUTED read a$")))
          (should (equal 3 (ao--count-occurrences text "^  - RUNNING ")))
          (should (equal 1 (ao--count-occurrences text "^:tool:$")))
          ;; TWO thinking drawers here, not four, and the reason is the rule
          ;; that keeps an unfinished call on the board the user is watching:
          ;; `agent-org-buffer--seal-tool-board' refuses to advance past a call
          ;; that is still `pending', so this board stays live and takes every
          ;; later call, and the thoughts between them keep appending to the
          ;; run whose drawer was opened after the first call.  What the
          ;; FOUR-idea would buy (a drawer per run) is exactly what it costs --
          ;; the completion of a sealed call would have nowhere to render and
          ;; the call would freeze at TODO.  `headings', the style the user
          ;; actually gets, keys a part by toolCallId instead of by window, so
          ;; it keeps strict arrival order AND repaints a late status in place;
          ;; see `test-agent-org-headings-orders-every-part-of-the-response'.
          (should (equal 2 (ao--count-occurrences text "^:thinking:$")))
          (should (equal 'ready
                         (with-current-buffer buf
                           (plist-get agent-org-buffer--status :state)))))
        ;; Every thought body holds thought text only: the run is rewritten
        ;; wholesale by the next chunk of its OWN drawer, so a tool line that
        ;; landed in it would vanish (that was the old bug, with headings placed
        ;; at the drawer match's END).
        (let ((bodies (with-current-buffer buf
                        (ao--drawer-bodies (buffer-string) "thinking"))))
          (should (= 2 (length bodies)))
          (should (string-match-p "plan" (nth 0 bodies)))
          (dolist (bit (list "more" "even more" "last"))
            (should (string-match-p bit (nth 1 bodies))))
          (should (= 0 (ao--count-occurrences
                        (mapconcat #'identity bodies "") "^  - "))))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-replay-settle-cap-stops-pushback ()
  "An agent that never pauses between replayed turns must not hold a
buffer in Restoring forever: past `agent-org-replay-settle-cap' the
armed render is left to fire instead of being pushed back again, and
the updates it buffers are still not dropped."
  (ao--capture-wire
    (let ((buf (agent-org-resume-session 'qoder "sid-cap")))
      (let ((session (agent-org--session-for-buffer buf)))
        (ao--drive "initialize" ao--fake-init-resp)
        (ao--drive "session/load" '((sessionId . "sid-cap")))
        (should (= 1 ao--armings))
        ;; a clock past `agent-org-replay-settle-cap', whatever the epoch
        (cl-letf (((symbol-function 'float-time) (lambda () 1e15)))
          (agent-org--on-notification
           session (ao--update-notif
                    '((sessionUpdate . "agent_message_chunk")
                      (content . ((type . "text") (text . "late"))))))
          (should (= 1 ao--armings)))
        (should (= 1 (length (plist-get session :replay))))
        (ao--settle)
        (with-current-buffer buf
          (should (string-match-p "late" (buffer-string)))
          (should (equal 'ready (plist-get agent-org-buffer--status :state))))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-metadata-refresh-skips-unchanged ()
  "A refresh whose rendered block is byte-identical is a no-op.
`usage_update' arrives many times per turn; rebuilding the block each time
re-protects the region and re-folds every drawer, which is what a slow
machine cannot afford.  The parse count is the pin, and it is now ZERO: the
TODO keyword sets come from `org-todo-keywords' installed once per buffer
(`agent-org-buffer--install-todo-keywords'), so no rebuild has anything to
re-read -- the reparse this test used to count went away with the
`#+TODO:' line, for BOTH lite and full sessions."
  (let ((buf (agent-org-buffer-create "skip"))
        (parses 0))
    (cl-letf (((symbol-function 'org-set-regexps-and-options)
               (lambda (&rest _args) (cl-incf parses))))
      (agent-org-buffer-refresh-metadata buf)
      (should (= 0 parses))
      (let ((text (with-current-buffer buf (buffer-string))))
        (agent-org-buffer-refresh-metadata buf)
        (should (= 0 parses))
        (with-current-buffer buf (should (equal text (buffer-string))))
        (agent-org-buffer-set-status buf :used 1000 :size 2000)
        (agent-org-buffer-refresh-metadata buf)
        (should (= 0 parses))
        (with-current-buffer buf
          (should (string-match-p ":Context: 1k/2k (50%)"
                                  (buffer-string))))
        ;; and the sets survived every rebuild: a rebuild that RESET the
        ;; keywords would show up here, not in a parse counter
        (with-current-buffer buf
          (should (member "RESPONDING" org-todo-keywords-1))
          (should (member "EXECUTED" org-todo-keywords-1)))))
    (kill-buffer buf)))

;;;; Model selection (MiniMax over the OpenCode ACP host)

(defun ao--config-resp (current values &optional session-id)
  "A session response whose configOptions offer a single `model' option.
CURRENT is its currentValue; VALUES the options offered, as
\(VALUE . NAME) pairs, and SESSION-ID the session they belong to.  Both
`session/new' and `session/load' answer this way, and so does
`session/set_config_option' with the new set.  Vectors because the wire
decodes JSON arrays as vectors, and `name' because that is what OpenCode
calls the label field here."
  `((sessionId . ,(or session-id "sid-new"))
    (configOptions .
     [((id . "model") (name . "Model") (type . "select")
       (currentValue . ,current)
       (options . ,(vconcat
                    (seq-map (lambda (pair)
                               `((value . ,(car pair)) (name . ,(cdr pair))))
                             values))))])))

(defun ao--sent-count (method)
  "How many requests for METHOD the capture saw."
  (seq-count (lambda (entry) (string= (car entry) method)) ao--sent))

(defun ao--set-model-params ()
  "The params alist of the last session/set_config_option request."
  (map-elt (plist-get (ao--sent-get "session/set_config_option") ':request)
           ':params))

(defconst ao--pin-model "minimax/MiniMax-M3"
  "Model id the pinning tests make a provider want.  It is what MiniMax
Code's own config (`defaultModel' in ~/.minimax/config.yaml) calls a
MiniMax model, so the fake agents in these tests advertise it as if they
were a host that fronts many models.")

(defmacro ao--with-pinned-provider (&rest body)
  "Run BODY with the MiniMax provider entry given a `:model' pin.
No shipped provider pins anything now that MiniMax Code runs its own
`mcode acp' (`agent-org-providers.el'), but a many-model host such as
OpenCode still needs the pin path, so it stays covered against an entry
that in real use would not carry `:model'."
  `(let ((agent-org-providers
          (cons (plist-put (copy-sequence (agent-org--provider-spec 'minimax))
                           :model ao--pin-model)
                ;; the let's own initializer still sees the plain entry
                (seq-remove (lambda (p) (eq (plist-get p :id) 'minimax))
                            agent-org-providers))))
     ,@body))

(ert-deftest test-agent-org-pinned-model-start-sends-the-request ()
  "A provider that pins a model sends session/set_config_option for it.
This is the many-model-host case: OpenCode answers a fresh session with a
shared default (seen live: gomodel/aa-coding), so a pin is what makes the
provider mean the model it names.  `agent-org-session-strategy' is bound
to `new' because these tests drive `session/new' straight off
`initialize', and the default `prompt' lists the directory's older
sessions before there is any `session/new' to drive."
  (ao--capture-wire
    (ao--with-pinned-provider
      (let* ((agent-org-session-strategy 'new)
             (buf (agent-org-start 'minimax))
             (pinned ao--pin-model))
        (ao--drive "initialize" ao--fake-init-resp)
        (ao--drive "session/new"
                   (ao--config-resp "gomodel/aa-coding"
                    (list (cons "opencode/minimax-m2.5"
                                "OpenCode Zen/MiniMax-M2.5")
                          (cons pinned "OpenCode Zen/MiniMax"))))
        (let ((params (ao--set-model-params)))
          (should params)
          (should (equal (map-elt params 'configId) "model"))
          (should (equal (map-elt params 'value) pinned))
          (should (equal (map-elt params 'sessionId) "sid-new")))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-pinned-model-resume-sends-the-request ()
  "A resumed session of a pinning provider gets the pin too: `session/load'
answers with configOptions just like `session/new', and the replay flush
goes through the same ready path."
  (ao--capture-wire
    (ao--with-pinned-provider
      (let* ((buf (agent-org-resume-session 'minimax "sid-min"))
             (pinned ao--pin-model))
        (ao--drive "initialize" ao--fake-init-resp)
        (ao--drive "session/load" (ao--config-resp "opencode/minimax-m2.5"
                                                  (list (cons pinned "MiniMax"))
                                                  "sid-min"))
        (ao--settle)
        (let ((params (ao--set-model-params)))
          (should (equal (map-elt params 'value) pinned))
          ;; the pin must follow the session that was loaded, not the id
          ;; the request was made with before the replay flushed
          (should (equal (map-elt params 'sessionId) "sid-min")))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-pinned-model-already-current-is-not-resent ()
  "When the agent already reports the wanted model, say nothing on the wire.
Sending a no-op set_config_option would be one more round trip on a
process that is slow to answer."
  (ao--capture-wire
    (ao--with-pinned-provider
      (let* ((agent-org-session-strategy 'new)
             (buf (agent-org-start 'minimax))
             (pinned ao--pin-model))
        (ao--drive "initialize" ao--fake-init-resp)
        (ao--drive "session/new" (ao--config-resp pinned (list (cons pinned "MiniMax"))))
        (should (zerop (ao--sent-count "session/set_config_option")))
        ;; the session is usable regardless
        (with-current-buffer buf
          (should (equal 'ready (plist-get agent-org-buffer--status :state)))
          (should (equal pinned (plist-get agent-org-buffer--status :model))))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-pinned-model-not-offered-is-reported ()
  "A model the agent does not list is never sent, only reported.
OpenCode renames its catalog from release to release, so a pinned id can
go stale; failing the request would leave the header showing an error for
a session that works fine on another model.  The report is an echo-area
message because the Ready segment hides a bare status message."
  (ao--capture-wire
    (ao--with-pinned-provider
      (let* ((agent-org-session-strategy 'new)
             (buf (agent-org-start 'minimax))
             (seen nil))
        (cl-letf (((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (push (apply #'format fmt args) seen))))
          (ao--drive "initialize" ao--fake-init-resp)
          (ao--drive "session/new"
                     (ao--config-resp "gomodel/aa-coding"
                      (list (cons "opencode/minimax-m2.5"
                                  "OpenCode Zen/MiniMax-M2.5")))))
        (should (zerop (ao--sent-count "session/set_config_option")))
        (should (seq-some (lambda (m) (string-match-p "minimax" m)) seen))
        (with-current-buffer buf
          (should (equal 'ready (plist-get agent-org-buffer--status :state)))
          ;; the header keeps showing what the agent actually runs
          (should (equal "gomodel/aa-coding"
                         (plist-get agent-org-buffer--status :model))))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-pinned-model-applied-exactly-once ()
  "The pin survives repeated ready calls (mid-turn updates re-enter it).
Otherwise every `session_info_update' would re-send the same request."
  (ao--capture-wire
    (ao--with-pinned-provider
      (let* ((agent-org-session-strategy 'new)
             (buf (agent-org-start 'minimax)))
        (ao--drive "initialize" ao--fake-init-resp)
        (dotimes (_ 3)
          (ao--drive "session/new"
                     (ao--config-resp "gomodel/aa-coding"
                      (list (cons ao--pin-model "MiniMax")))))
        (should (= 1 (ao--sent-count "session/set_config_option")))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-minimax-start-pins-nothing ()
  "A MiniMax Code session asks the agent for no model at all.
`mcode' is MiniMax's own agent, so its own default model is the right
one; pinning would fight `defaultModel' in its config.  This guards the
old OpenCode-shaped design — MiniMax as a pinned model inside
`opencode acp' — from creeping back."
  (ao--capture-wire
    (let* ((agent-org-session-strategy 'new)
           (buf (agent-org-start 'minimax)))
      (ao--drive "initialize" ao--fake-init-resp)
      (ao--drive "session/new"
                 (ao--config-resp "minimax/MiniMax-M3"
                  (list (cons "minimax/MiniMax-M3" "MiniMax M3")
                        (cons "minimax/MiniMax-M2.7" "MiniMax M2.7"))))
      (should (zerop (ao--sent-count "session/set_config_option")))
      (with-current-buffer buf
        (should (equal 'ready (plist-get agent-org-buffer--status :state)))
        (should (equal "minimax/MiniMax-M3"
                       (plist-get agent-org-buffer--status :model))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-set-session-model-switches-and-updates-header ()
  "Choosing a model sends the request and re-reads the header from the
response, so what the top bar shows is what the agent agreed to."
  (ao--capture-wire
    (let* ((agent-org-session-strategy 'new)
           (buf (agent-org-start 'qoder)))
      (ao--drive "initialize" ao--fake-init-resp)
      (ao--drive "session/new"
                 (ao--config-resp "qmodel"
                  (list (cons "qmodel" "QModel")
                        (cons "qmodel-large" "QModel Large"))))
      (with-current-buffer buf (agent-org-set-session-model "qmodel-large"))
      (let ((params (ao--set-model-params)))
        (should (equal (map-elt params 'configId) "model"))
        (should (equal (map-elt params 'value) "qmodel-large")))
      (ao--drive "session/set_config_option"
                 (ao--config-resp "qmodel-large"
                  (list (cons "qmodel" "QModel")
                        (cons "qmodel-large" "QModel Large"))))
      (with-current-buffer buf
        (should (equal "qmodel-large"
                       (plist-get agent-org-buffer--status :model)))
        (should (string-match-p "QModel Large"
                                (agent-org-buffer--render-header-line))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-set-session-model-rejects-unadvertised-model ()
  "A lisp caller cannot smuggle an id the agent never offered.
The check that keeps the interactive path honest is the same one that
matters when lisp calls in."
  (ao--capture-wire
    (let* ((agent-org-session-strategy 'new)
           (buf (agent-org-start 'qoder)))
      (ao--drive "initialize" ao--fake-init-resp)
      (ao--drive "session/new" (ao--config-resp "qmodel" (list (cons "qmodel" "QModel"))))
      (should-error (with-current-buffer buf
                      (agent-org-set-session-model "gpt-99"))
                    :type 'user-error)
      (should (zerop (ao--sent-count "session/set_config_option")))
      (kill-buffer buf))))

(ert-deftest test-agent-org-set-session-model-rejects-non-chat-buffer ()
  "Outside a chat buffer there is no session to reconfigure."
  (with-temp-buffer
    (should-error (agent-org-set-session-model "m") :type 'user-error)))

(ert-deftest test-agent-org-model-option-prefers-model-over-provider ()
  "When an agent advertises both, the MODEL option is the one we drive.
Goose names its provider choice \"provider\" and its model choice
\"model\", and it has been observed to list the provider option first.
`agent-org--model-option' that accepted either id by list order returned
that provider option, so `agent-org-set-session-model' completed over
providers instead of models.  The option with id \"model\" must win no
matter its position; \"provider\" is only the fallback for an agent that
offers no \"model\" option at all."
  (let ((goose `(((id . "provider") (currentValue . "ollama")
                 (options . [((value . "ollama") (name . "Ollama"))]))
                ((id . "model") (currentValue . "gpt-4o")
                 (options . [((value . "gpt-4o") (name . "GPT-4o"))
                             ((value . "llama3") (name . "Llama 3"))])))))
    (should (equal "model" (map-elt (agent-org--model-option goose) 'id)))
    ;; the model menu is built from THIS option's values, so it lists
    ;; models, never the provider names
    (should (equal '("gpt-4o" "llama3") (agent-org--model-values goose)))
    (should (equal "GPT-4o" (agent-org--model-name goose))))
  ;; an agent that offers ONLY a provider option still resolves to it, so
  ;; the older single-provider goose keeps working
  (let ((provider-only `(((id . "provider") (currentValue . "ollama")
                          (options . [((value . "ollama"))])))))
    (should (equal "provider" (map-elt (agent-org--model-option provider-only) 'id)))
    (should (equal '("ollama") (agent-org--model-values provider-only))))
  (should-not (agent-org--model-option `(((id . "mode"))))))

;;;; Model NAME in the header line (the id is still what the wire wants)

(ert-deftest test-agent-org-header-shows-model-name-not-id ()
  "The top bar labels the model the way the agent labels it.
An id such as `minimax/MiniMax-M3' is a wire value: it is what
`session/set_config_option' must be sent, and `agent-org--model-values'
checks against it — but a human reading a status bar wants \"MiniMax M3\".
So the display comes from the advertised option's `name' while `:model'
keeps the id, because a header that could not tell the two apart could not
be trusted to show the model actually in force."
  (ao--capture-wire
    (let* ((agent-org-session-strategy 'new)
           (buf (agent-org-start 'qoder)))
      (ao--drive "initialize" ao--fake-init-resp)
      (ao--drive "session/new"
                 (ao--config-resp "qmodel-large"
                  (list (cons "qmodel" "QModel")
                        (cons "qmodel-large" "QModel Large"))))
      (with-current-buffer buf
        (let ((header (agent-org-buffer--render-header-line)))
          (should (string-match-p "QModel Large" header))
          (should-not (string-match-p "qmodel-large" header))
          (should (equal "qmodel-large"
                         (plist-get agent-org-buffer--status :model)))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-header-model-name-falls-back-to-id ()
  "A current model the agent does not name is still shown.
Agents can report a `currentValue' outside their own advertised list (the
catalog moves between releases); showing nothing there would read as
\"no model\", which is a worse lie than the id."
  (ao--capture-wire
    (let* ((agent-org-session-strategy 'new)
           (buf (agent-org-start 'qoder)))
      (ao--drive "initialize" ao--fake-init-resp)
      (ao--drive "session/new"
                 (ao--config-resp "ghost-model" (list (cons "qmodel" "QModel"))))
      (with-current-buffer buf
        (let ((header (agent-org-buffer--render-header-line)))
          (should (string-match-p "ghost-model" header))
          (should (equal "ghost-model"
                         (plist-get agent-org-buffer--status :model)))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-metadata-model-line-uses-name ()
  "The metadata block labels the model like the header does.
Two renderings of one fact that disagree is how a user starts distrusting
both, so `:Model:' is the name and the id stays on the wire."
  (ao--capture-wire
    (let* ((agent-org-session-strategy 'new)
           (buf (agent-org-start 'qoder)))
      (ao--drive "initialize" ao--fake-init-resp)
      (ao--drive "session/new"
                 (ao--config-resp "qmodel-large"
                  (list (cons "qmodel-large" "QModel Large"))))
      (with-current-buffer buf
        (should (string-match-p "^:Model: +QModel Large" (buffer-string)))
        (should-not (string-match-p "^:Model: +qmodel-large" (buffer-string))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-config-drawer-shows-model-label ()
  "The CONFIG drawer labels the current value the way the header does.
The drawer used to print `currentValue' verbatim, so the same buffer
said \"QModel Large\" in the header and \"qmodel-large\" two lines
below — two renderings of one fact that disagree.  The id returns only
as the fallback for a value the agent advertises no label for."
  (let* ((pair (ao--make-test-session "configlabel"))
         (buf (car pair))
         (session (cdr pair)))
    (setf (plist-get session :session-id) nil)
    (agent-org--session-ready
     session "sid-x"
     (ao--config-resp "qmodel-large"
                      (list (cons "qmodel" "QModel")
                            (cons "qmodel-large" "QModel Large"))))
    (with-current-buffer buf
      (should (string-match-p "^Model — QModel Large$" (buffer-string)))
      (should-not (string-match-p "^Model — qmodel-large$" (buffer-string))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-model-name-prettifies-unadvertised-current ()
  "No advertised label does not mean no name: the id is still cleaned.
`agent-org--model-name' used to answer nil for a `currentValue' outside
the catalog, which left the full wire id — \"minimax/MiniMax-M3\" — as
the only thing a status line could show.  Dropping the provider path is
what the id itself can be made to say without inventing a label."
  (should (equal "MiniMax-M3"
                 (agent-org--model-name
                  (list (list `(id . "model") `(name . "Model")
                              `(currentValue . "minimax/MiniMax-M3")
                              (cons 'options
                                    (vector (list `(value . "other")
                                                  `(name . "Other")))))))))
  (should (equal "ghost-model"
                 (agent-org--model-name
                  (list (list `(id . "model") `(currentValue . "ghost-model"))))))
  (should-not (agent-org--model-name (list (list `(id . "model"))))))

(ert-deftest test-agent-org-model-name-follows-a-switch ()
  "After `agent-org-set-session-model' the bar shows the NEW model's name.
The switch response is the agent's own last word on configOptions, so the
label is re-read from it rather than remembered from the choice."
  (ao--capture-wire
    (let* ((agent-org-session-strategy 'new)
           (buf (agent-org-start 'qoder)))
      (ao--drive "initialize" ao--fake-init-resp)
      (ao--drive "session/new"
                 (ao--config-resp "qmodel"
                  (list (cons "qmodel" "QModel")
                        (cons "qmodel-large" "QModel Large"))))
      (with-current-buffer buf (agent-org-set-session-model "qmodel-large"))
      (ao--drive "session/set_config_option"
                 (ao--config-resp "qmodel-large"
                  (list (cons "qmodel" "QModel")
                        (cons "qmodel-large" "QModel Large"))))
      (with-current-buffer buf
        (should (string-match-p "QModel Large"
                                (agent-org-buffer--render-header-line)))
        (should-not (string-match-p "qmodel-large"
                                    (agent-org-buffer--render-header-line))))
      (kill-buffer buf))))

(defun ao--chat-on-model (id name &optional session-id)
  "A Ready chat buffer whose agent advertises model ID, labelled NAME.
Built through the real `agent-org-start' path inside `ao--capture-wire', so
the status a quote's author reads is the status a live session has — the
point of this helper is that no test hand-writes `:model-name'.  NAME nil
is an agent reporting a value it never named, which is the id-fallback case.
ID nil is an agent advertising no model option at all (Goose answers with
no `configOptions' of this shape), which is the no-model case.  SESSION-ID
defaults to the wire's own \"sid-new\"; the transcript tests pass their
own, because the id is what names their file.  Caller kills the buffer."
  (let ((agent-org-session-strategy 'new))
    (let ((buf (agent-org-start 'qoder)))
      (ao--drive "initialize" ao--fake-init-resp)
      (ao--drive "session/new"
                 (if id
                     (ao--config-resp id (and name (list (cons id name)))
                                      session-id)
                   `((sessionId . ,(or session-id "sid-new"))
                     (configOptions . []))))
      buf)))

(ert-deftest test-agent-org-prefix-wears-the-id-when-nothing-names-it ()
  "An agent that reports a value but no label gets the value on the prefix.
`agent-org--ingest-config' stores the advertised `name' in `:model-name' and
falls back to the wire id when the agent names nothing, so a prefix built
from the display shows an id there — the same rule the header line follows (a
bar that drops the model field reads as \"no model\"), and an id is a clue
where the generic word is not.  Agents rename their catalog between
releases, so this is the case that keeps a transcript honest when the label
disappears."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "ghost-model" nil)))
      (with-current-buffer buf
        (should (equal "ghost-model"
                       (plist-get agent-org-buffer--status :model)))
        (agent-org-buffer-start-agent-turn buf (agent-org-buffer--session))
        (goto-char (point-min))
        (should (re-search-forward "^ghost-model: $" nil t)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-prefix-flattens-a-multiline-model-name ()
  "A model label is agent free text, so it cannot break the prefix line.
`agent-org-buffer--label' is the gate every agent-supplied string passes
before it lands on a one-line context; a config option named \"A\\nB\" must
produce ONE prefix line, not a prefix and a stray paragraph that Org would
read as the answer's body with a lost structure."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel-large" "QModel\nLarge  with\n\n  spaces")))
      (with-current-buffer buf
        (agent-org-buffer-start-agent-turn buf (agent-org-buffer--session))
        (goto-char (point-min))
        (should (re-search-forward
                 (concat "^"
                         (agent-org-buffer--label
                          "QModel\nLarge  with\n\n  spaces")
                         ": $")
                 nil t))
        (should-not (re-search-forward "^[ \t]*Large" nil t)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-replay-paints-the-model-it-was-told ()
  "Restored history is attributed to the model known NOW, which is all the wire says.
`session/load' replays chunks with no model attached to any of them, so a
resumed transcript cannot claim per-turn models it never learned — this test
states what the replay really does, through the same primitive a live turn
uses, instead of pretending it remembers.  It is also the guard that naming
the quote's author did not break the restored-history path, which paints
hundreds of chunks in one synchronous run.  Two agent chunks with no question
before them are one orphan turn: a `* Agent' heading and ONE quote block whose
`:author' is the model the client currently knows."
  (let* ((pair (ao--make-test-session "replay-model"))
         (buf (car pair))
         (session (cdr pair)))
    (agent-org-buffer-set-status buf :model "qfmodel" :model-name "Qwen3.8-Flash")
    (setf (plist-get session :loading) t)
    (dolist (update (list
                     '((sessionUpdate . "agent_message_chunk")
                       (content . ((type . "text")
                                   (text . "Answered before the restart"))))
                     '((sessionUpdate . "agent_message_chunk")
                       (content . ((type . "text") (text . " and after."))))))
      (agent-org--on-notification session (ao--update-notif update)))
    (agent-org--render-replay session)
    (with-current-buffer buf
      (let ((s (buffer-string)))
        (should (= 1 (ao--count-occurrences
                      s "^Qwen3\\.8-Flash: $")))
        (should (= 1 (ao--count-occurrences s "^\\* Agent$")))))
    (kill-buffer buf)))

;;;; Command names, following agent-shell

(ert-deftest test-agent-org-session-command-names-match-agent-shell ()
  "Session-level commands borrow agent-shell's names.
agent-shell says `agent-shell-resume-session' and
`agent-shell-set-session-model' — the object of the verb is the session,
because one buffer's agent can be reconfigured in several ways (model,
mode, thought level, any config option).  The old short names are gone
rather than kept as aliases, so each action has exactly one name to
find in M-x."
  (dolist (name '(agent-org-start
                  agent-org-send
                  agent-org-resume-session
                  agent-org-set-session-model))
    (should (commandp name)))
  (dolist (gone '(agent-org-resume agent-org-set-model))
    (should-not (fboundp gone))))

(ert-deftest test-agent-org-every-provider-has-a-start-agent-command ()
  "Every registered provider has an `agent-org-<id>-start-agent', AND an
autoload cookie for it.
That is how agent-shell exposes its agents: one named entry point per
provider (`agent-shell-goose-start-agent'), so M-x completion on the
package prefix lists the choices instead of hiding them behind one
command that prompts.

The AUTOLOAD half is the one that bites, and it is here because a command
can exist in the source and still be unreachable: `agent-org-autoloads.el'
is GENERATED, and a provider added after the last generation has a command
that `(commandp)' happily reports as present --- because this suite loads
agent-org-providers itself, while a fresh install has not.  Measured twice on
this list: `agent-org-copilot-start-agent' and friends shipped without
cookies, and then `agent-org-slave-agent-start-agent' --- the package's own
primary agent --- did the same.  Nothing else in the suite can see it: no test
runs against a pristine load path, so the cookie is pinned here by READING the
generated file, the one artifact a user actually loads."
  (dolist (spec agent-org-providers)
    (let ((name (intern (format "agent-org-%s-start-agent"
                                (plist-get spec :id)))))
      (should (commandp name))))
  (let ((cookies (let ((case-fold-search nil))
                   (with-temp-buffer
                     (insert-file-contents
                      (expand-file-name "agent-org-autoloads.el"
                                        ao--package-root))
                     (goto-char (point-min))
                     (let (found)
                       (while (re-search-forward "(autoload '\\(agent-org-[a-z-]*\\)" nil t)
                         (push (intern (match-string 1)) found))
                       found)))))
    (dolist (spec agent-org-providers)
      (should (memq (intern (format "agent-org-%s-start-agent"
                                    (plist-get spec :id)))
                    cookies)))))

(ert-deftest test-agent-org-goose-start-agent-opens-goose ()
  "The per-provider command is a thin call with the id baked in: right
session, same buffer, nothing invented.  It must not grow its own
handshake, or the two entry paths would drift."
  (ao--capture-wire
    (let ((buf (agent-org-goose-start-agent)))
      (should (buffer-live-p buf))
      (should (eq 'goose (plist-get (agent-org--session-for-buffer buf) :name)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-failure-text-is-the-agents-own-sentence ()
  "A JSON-RPC error is reported by its message, not dumped whole.
Live opencode answered a prompt with -32603 and the header line got the
entire (:object …) (:json …) pair — hundreds of characters replacing the
Ready segment.  `agent-org--failure-text' is the one channel every
:on-failure callback uses now."
  (should (equal "Upstream request failed: Insufficient account funds"
                 (agent-org--failure-text
                  '((:object (jsonrpc . "2.0") (id . 4)
                             (error (code . -32603)
                                    (message . "Upstream request failed: Insufficient account funds")
                                    (data (service . "session")
                                          (errorName . "APIError"))))
                    (:json . "{\"jsonrpc\":\"2.0\",\"id\":4}")))))
  (should (equal "plain sentence" (agent-org--failure-text "plain sentence")))
  ;; an error carrying no message still reports something
  (should (string-match-p "404" (agent-org--failure-text '((:json . "404 not found"))))))

;;;; Session strategy: starting a chat offers the directory's older sessions

(defun ao--list-resp (sessions &optional next-cursor)
  "A `session/list' response for SESSIONS, plus a NEXT-CURSOR page token.
Each element of SESSIONS is (ID TITLE STAMP); a nil TITLE or STAMP is
left off the wire entirely, because agents really do omit them."
  (let ((body `((sessions . ,(vconcat
                              (seq-map (lambda (s)
                                         (append `((sessionId . ,(nth 0 s)))
                                                 (when (nth 1 s)
                                                   (list (cons 'title (nth 1 s))))
                                                 (when (nth 2 s)
                                                   (list (cons 'updatedAt (nth 2 s))))))
                                       sessions))))))
    (if next-cursor
        (append body (list (cons 'nextCursor next-cursor)))
      body)))

(defun ao--today ()
  "An ISO-8601 stamp for the current local instant, as an agent would send it."
  (format-time-string "%Y-%m-%dT%H:%M:%S%z"))

(defmacro ao--pick (id &rest body)
  "Run BODY answering every prompt by choosing the candidate for session ID.
A `completing-read' stand-in: the candidate labels carry a recency date
the test must not hard-code, so the choice is matched on the bracketed
id, which is the part that actually selects a session."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'completing-read)
              (lambda (_prompt collection &rest _)
                (seq-find (lambda (c)
                            (string-match-p (regexp-quote (format "[%s]" ,id)) c))
                          (ao--collection collection)))))
     ,@body))

(defvar ao--prompted-with nil
  "Collections the `ao--never-prompt' stand-in was handed, newest first.")

(defmacro ao--never-prompt (&rest body)
  "Run BODY failing loudly if anything prompts, recording what it offered."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'completing-read)
              (lambda (_prompt collection &rest _)
                (push collection ao--prompted-with)
                (error "this strategy must not prompt"))))
     ,@body))

(defmacro ao--cancel (&rest body)
  "Run BODY with every prompt answered the way ESC does: a quit signal.
This is how a test says \"the user changed their mind at the session
choice\", which is the case that used to leave a chat buffer stranded."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'completing-read)
              (lambda (&rest _) (signal 'quit nil))))
     ,@body))

(defvar ao--messages nil
  "What `message' was handed inside `ao--capture-messages', newest first.
A formatted string, or nil for the echo area being CLEARED — which is
what closing a progress report leaves behind, and the reason the
recorder cannot just `format' every call: `format' rejects a nil
argument, real Emacs accepts `(message nil)'.")

(defmacro ao--capture-messages (&rest body)
  "Run BODY recording every echo-area `message' call into `ao--messages'.
The header line hides a bare `:message' while Ready, and some notes (the
listing timeout, a cancel) are deliberately echo-area only — so the echo
area is a channel tests have to watch, not just the buffer.  Assert on it
INSIDE BODY: the binding is gone once the macro's last form has run."
  (declare (indent 0))
  `(let ((ao--messages nil))
     (cl-letf (((symbol-function 'message)
                (lambda (format-string &rest args)
                  (push (if format-string
                            (apply #'format format-string args)
                          nil)
                        ao--messages))))
       ,@body)))

(ert-deftest test-agent-org-session-strategy-is-a-named-choice ()
  "The three strategies are the whole vocabulary, and a typo says so.
`agent-shell-session-strategy' is what this copies; the validator exists
because a config value that silently did nothing would be
indistinguishable from the fast path.

`latest' is the DEFAULT (the user's order of 2026-10-13: /\"Add session
strategy that will automatically open latest session, but will prompt like
before with C-u.  This will be default.\"/): opening a chat in a directory
you have been working in means going back to the chat you were in, and the
listing the chooser needs is one round trip the fast path should not pay for
every time.  `C-u' then reaches the chooser, which is what the default used
to be."
  (should (equal agent-org-session-strategy 'latest))
  (dolist (value '(new latest prompt))
    (should-not (agent-org--validate-session-strategy value))
    (setopt agent-org-session-strategy value)
    (should (eq (default-value 'agent-org-session-strategy) value)))
  (should-error (setopt agent-org-session-strategy 'bogus) :type 'user-error)
  (setopt agent-org-session-strategy 'latest))

(ert-deftest test-agent-org-start-strategy-new-never-lists ()
  "`new' is the fast path: no session/list round trip, no silence timer.
On a 4 GB machine every extra request to a slow agent is seconds of
\"Starting\" for nothing, so a strategy that cannot use the listing must
not ask for it."
  (let ((agent-org-session-strategy 'new))
    (ao--capture-wire
      (let ((buf (agent-org-start 'qoder)))
        (ao--drive "initialize" ao--fake-init-resp)
        (should (ao--sent-get "session/new"))
        (should-not (ao--sent-get "session/list"))
        (should-not ao--list-timer)
        (kill-buffer buf)))))

(ert-deftest test-agent-org-start-prefix-arg-reaches-the-prompt ()
  "C-u on the interactive command overrides `agent-org-session-strategy'.
The user order of 2026-10-13 makes `latest' the default and asks that /\"C-u
prompt like before\"/: one keypress says \"let me choose\", and the choosing
path is the listing, so this asserts exactly the request a `prompt' strategy
makes -- `session/list' -- while `latest' would have picked without asking."
  (ao--capture-wire
    (let ((current-prefix-arg '(4))
          (agent-org-session-strategy 'latest))
      (cl-letf (((symbol-function 'agent-org--read-provider)
                 (lambda () 'qoder)))
        (call-interactively 'agent-org-start)))
    (ao--drive "initialize" ao--fake-init-resp)
    (should (equal (caar ao--sent) "session/list"))
    (should-not (ao--sent-get "session/new"))
    (kill-buffer (current-buffer))))

(ert-deftest test-agent-org-start-double-prefix-forces-a-new-session ()
  "C-u C-u forces `new': the fast path stays reachable from the keyboard.
With `latest' as the default and one prefix spent on the chooser, `new'
would otherwise be a value only for the config file -- and its point is
exactly the call you want to make WITHOUT a listing round trip.  The chooser
still offers `New session' first, so a plain RET at `C-u' gets the same
answer one keystroke later."
  (ao--capture-wire
    (let ((current-prefix-arg '(16))
          (agent-org-session-strategy 'prompt))
      (cl-letf (((symbol-function 'agent-org--read-provider)
                 (lambda () 'qoder)))
        (call-interactively 'agent-org-start)))
    (ao--drive "initialize" ao--fake-init-resp)
    (should (ao--sent-get "session/new"))
    (should-not (ao--sent-get "session/list"))
    (kill-buffer (current-buffer))))

(ert-deftest test-agent-org-start-default-opens-the-latest-chat-unasked ()
  "The DEFAULT opens this directory's most recent session, asking nothing.
THE user order (2026-10-13): /\"Add session strategy that will automatically
open latest session, but will prompt like before with C-u.  This will be
default.\"/  Nothing is bound here, so this is the only test that pins what a
bare `M-x agent-org-start' does: one listing, newest by `updatedAt', straight
to `session/load' -- no `completing-read' in the way (which
`ao--never-prompt' turns into a failure), and no `session/new'."
  (ao--capture-wire
    (let ((buf (agent-org-start 'qoder)))
      (ao--never-prompt
        (ao--drive "initialize" ao--fake-init-resp)
        (ao--drive
         "session/list"
         (ao--list-resp
          `(("s-old" "Older chat" "2026-09-02T10:00:00+0000")
            ("s-new" "Newest chat" ,(ao--today))))))
      (let ((params (map-elt (plist-get (ao--sent-get "session/load") ':request)
                             ':params)))
        (should (equal (map-elt params 'sessionId) "s-new")))
      (should-not (ao--sent-get "session/new"))
      (kill-buffer buf))))

(ert-deftest test-agent-org-start-prompts-with-the-directory-sessions ()
  "Starting a chat with the `prompt' strategy means asking the agent what
this directory already holds, offering that list, and loading what was
chosen instead of opening a blank session.  `C-u M-x agent-org-start'
reaches this path; the shipped default is `latest', so the strategy is
bound here rather than inherited."
  (let ((agent-org-session-strategy 'prompt))
    (ao--capture-wire
      (let ((buf (agent-org-start 'qoder)))
        (ao--drive "initialize" ao--fake-init-resp)
        (should (equal (caar ao--sent) "session/list"))
        (should-not (ao--sent-get "session/new"))
        (ao--pick "s-old"
          (ao--drive "session/list"
                     (ao--list-resp
                      `(("s-new" "Newest chat" ,(ao--today))
                        ("s-old" "Older chat" "2026-09-02T10:00:00+0000")))))
        (let ((params (map-elt (plist-get (ao--sent-get "session/load") ':request)
                               ':params)))
          (should (equal (map-elt params 'sessionId) "s-old")))
        (should-not (ao--sent-get "session/new"))
        (ao--drive "session/load" '((sessionId . "s-old")))
        (ao--settle)
        (with-current-buffer buf
          (should (equal (plist-get agent-org-buffer--status :session-id) "s-old"))
          (should (equal 'ready (plist-get agent-org-buffer--status :state))))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-start-prompt-offers-new-session-too ()
  "The list the agent returns is not a trap: \"New session\" is a choice,
and the first one, so a plain Enter keeps the old behaviour.  A prompt
that could only resume would make `agent-org-start' the wrong command to
reach for."
  (let ((agent-org-session-strategy 'prompt)
        (ao--prompted-with nil))
    (ao--capture-wire
      (let ((buf (agent-org-start 'qoder)))
        (ao--drive "initialize" ao--fake-init-resp)
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt collection &rest _)
                     (push collection ao--prompted-with)
                     (car (ao--collection collection)))))
          (ao--drive
           "session/list"
           (ao--list-resp `(("s1" "One chat" ,(ao--today))
                            ("s2" "Two chat" "2026-09-02T10:00:00+0000")))))
        (let ((choices (ao--collection (seq-first ao--prompted-with))))
          (should (= 3 (length choices)))
          (should (equal (car choices) agent-org-new-session-label)))
        (should (ao--sent-get "session/new"))
        (should-not (ao--sent-get "session/load"))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-start-strategy-latest-loads-newest-unasked ()
  "`latest' picks the newest session with no prompt at all, and wire
order is not recency order: agents may answer in any order, so this
sorts on `updatedAt' and falls back to `createdAt', which live goose
sends on sessions it never touched."
  (ao--capture-wire
    (let* ((agent-org-session-strategy 'latest)
           (buf (agent-org-start 'qoder)))
      (ao--never-prompt
        (ao--drive "initialize" ao--fake-init-resp)
        (ao--drive
         "session/list"
         `((sessions . [((sessionId . "s-mid") (title . "Mid")
                         (updatedAt . "2026-09-10T10:00:00+0000"))
                        ((sessionId . "s-old") (title . "Old")
                         (updatedAt . "2026-09-02T10:00:00+0000"))
                        ((sessionId . "s-born") (title . "Born, never touched")
                         (createdAt . "2026-09-20T09:00:00+0000"))])))
      (let ((params (map-elt (plist-get (ao--sent-get "session/load") ':request)
                             ':params)))
        (should (equal (map-elt params 'sessionId) "s-born")))
      (kill-buffer buf)))))

(ert-deftest test-agent-org-start-reads-the-strategy-at-command-time ()
  "The strategy is decided when the command runs, not when the agent answers.
A callback that re-reads the variable follows whatever is bound by the
time the handshake lands: a lisp caller's `let' around
`agent-org-start' is silently ignored, and so is any future
buffer-local.  This is not hypothetical — a live probe that bound `new'
around `agent-org-start' still went and asked a real qoder for its
directory listing, because the binding was gone by the time
`initialize' answered."
  (ao--capture-wire
    (let ((buf (let ((agent-org-session-strategy 'new))
                  (agent-org-start 'qoder))))
      ;; `buf' was returned from inside the binding, which has now exited
      (ao--drive "initialize" ao--fake-init-resp)
      (should (ao--sent-get "session/new"))
      (should-not (ao--sent-get "session/list"))
      (kill-buffer buf))))

(ert-deftest test-agent-org-start-carries-latest-into-the-chooser ()
  "The strategy the command read still decides after the round trip.
The chooser runs on the `session/list' response, which is two callbacks
downstream of the command, so the decision has to travel with the
session rather than be looked up again."
  (ao--capture-wire
    (let ((buf (let ((agent-org-session-strategy 'latest))
                  (agent-org-start 'qoder))))
      (ao--never-prompt
        (ao--drive "initialize" ao--fake-init-resp)
        (ao--drive "session/list"
                   (ao--list-resp `(("s-new" "Newest" ,(ao--today))
                                    ("s-old" "Older"
                                     "2026-09-02T10:00:00+0000")))))
      (let ((params (map-elt (plist-get (ao--sent-get "session/load") ':request)
                             ':params)))
        (should (equal (map-elt params 'sessionId) "s-new")))
      (kill-buffer buf))))

(ert-deftest test-agent-org-start-without-list-capability-just-starts ()
  "An agent that cannot list, or cannot load, gets no listing request.
`prompt' and `latest' both need session/list plus session/load; on an
agent advertising neither, the strategy degrades to `new' instead of
failing a session the user never asked to resume."
  (let ((agent-org-session-strategy 'prompt))
    (ao--capture-wire
      (let ((buf (agent-org-start 'opencode)))
        (ao--drive "initialize" '((agentCapabilities . ((loadSession . nil)))))
        (should (ao--sent-get "session/new"))
        (should-not (ao--sent-get "session/list"))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-session-list-follows-cursors ()
  "Older sessions live past the first page, so `nextCursor' is followed
until the agent stops offering one.  \"Lists the older sessions\" is not
true of a package that reads one page and calls it the list."
  (ao--capture-wire
    (let* ((agent-org-session-strategy 'latest)
           (buf (agent-org-start 'qoder)))
      (ao--never-prompt
        (ao--drive "initialize" ao--fake-init-resp)
        (ao--drive "session/list"
                   (ao--list-resp `(("s-p1" "Page one" "2026-09-01T10:00:00+0000"))
                                  "cursor-2"))
        (should (= 2 (ao--sent-count "session/list")))
        (should (equal (map-elt (nth 1 (ao--list-pages)) 'cursor) "cursor-2"))
        (should-not (map-elt (nth 0 (ao--list-pages)) 'cursor))
        (ao--drive "session/list"
                   (ao--list-resp `(("s-p2" "Page two, the older one" ,(ao--today))))))
      (let ((params (map-elt (plist-get (ao--sent-get "session/load") ':request)
                             ':params)))
        (should (equal (map-elt params 'sessionId) "s-p2")))
      (kill-buffer buf))))

(ert-deftest test-agent-org-session-list-page-limit-stops-paging ()
  "`agent-org-session-list-page-limit' bounds the requests and says
nothing when it truncates: on a slow agent the limit exists precisely to
stop waiting."
  (ao--capture-wire
    (let* ((agent-org-session-list-page-limit 1)
           (agent-org-session-strategy 'latest)
           (buf (agent-org-start 'qoder)))
      (ao--never-prompt
        (ao--drive "initialize" ao--fake-init-resp)
        (ao--drive "session/list"
                   (ao--list-resp
                    `(("s-p1" "Page one" ,(ao--today))
                      ("s-x" "Also page one" "2026-01-01T10:00:00+0000"))
                    "cursor-2"))
        (should (= 1 (ao--sent-count "session/list"))))
      (let ((params (map-elt (plist-get (ao--sent-get "session/load") ':request)
                             ':params)))
        (should (equal (map-elt params 'sessionId) "s-p1")))
      (kill-buffer buf))))

(ert-deftest test-agent-org-session-list-repeated-cursor-falls-back ()
  "An agent handing back the cursor it was just sent would page forever.
Two requests is enough: give up on the listing and start a new session,
because a broken session/list must not block a chat nobody wanted to
resume."
  (ao--capture-wire
    (let* ((agent-org-session-strategy 'prompt)
           (buf (agent-org-start 'qoder)))
      (ao--drive "initialize" ao--fake-init-resp)
      (ao--drive "session/list" (ao--list-resp `(("s1" "One" ,(ao--today))) "same"))
      (ao--never-prompt
        (ao--drive "session/list" (ao--list-resp `(("s2" "Two" ,(ao--today))) "same"))
        (should (= 2 (ao--sent-count "session/list")))
        (should (= 1 (ao--sent-count "session/new")))
        (should-not (ao--sent-get "session/load")))
      (kill-buffer buf))))

(ert-deftest test-agent-org-silent-agent-list-falls-back-to-new ()
  "Goose advertises `list' and never answers it — documented live.  With
`prompt' as the default, silence must cost one timeout, not the session:
after `agent-org-session-list-timeout' the start proceeds as a plain new
session, and an answer arriving afterwards is ignored."
  (ao--capture-wire
    (let ((buf (agent-org-start 'goose)))
      (ao--drive "initialize" ao--fake-init-resp)
      (should (ao--sent-get "session/list"))
      (should ao--list-timer)
      (ao--time-out)
      (should (= 1 (ao--sent-count "session/new")))
      (should-not (ao--sent-get "session/load"))
      ;; the agent finally speaks; what it offers is moot — the new
      ;; session is already opening
      (ao--never-prompt
        (ao--drive "session/list" (ao--list-resp `(("late" "Too late" ,(ao--today))))))
      (ao--drive "session/new" (ao--config-resp "model-x" '(("model-x" . "X"))))
      (should (= 1 (ao--sent-count "session/new")))
      (should-not (ao--sent-get "session/load"))
      (with-current-buffer buf
        (should (equal 'ready (plist-get agent-org-buffer--status :state))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-killing-the-chat-buffer-shuts-the-agent-down ()
  "Killing a chat buffer releases its agent PROCESS, not just its registry
entry.  Found live: `agent-org--sessions' held one session while nine
`qoder --acp' children were still running (~100 MB each, on a 4 GB box),
because `agent-org--forget-session' dropped the entry and left the `acp'
client — and therefore the process it spawned — alive."
  (ao--capture-wire
    (let ((acp-mock-shutdown-clients nil)
          (agent-org-session-strategy 'prompt))
      (let* ((buf (agent-org-start 'qoder))
             (client (plist-get (agent-org--session-for-buffer buf) :client)))
        (should client)
        ;; `prompt' asks before anything is opened, so a start with nothing
        ;; to resume still has to settle the listing first.
        (ao--never-prompt
          (ao--drive "initialize" ao--fake-init-resp))
        (ao--drive "session/list" (ao--list-resp nil))
        (ao--drive "session/new" '((sessionId . "s-keep")))
        (should (= 1 (length agent-org--sessions)))
        (kill-buffer buf)
        (should-not (agent-org--session-for-buffer buf))
        (should-not (memq buf (buffer-list)))
        (should (equal (list client) acp-mock-shutdown-clients))))))

;;;; Killing a chat buffer asks first, because an agent is running

(defun ao--chat-buffer-with-agent ()
  "A chat buffer whose session holds a live agent process.
Returns (BUFFER . PROCESS).  The process is a real `sleep': what is under
test is \"is there a live process to ask about\", and a stub object would
let the test pass on something that cannot be live."
  (let* ((pair (ao--make-test-session "killer"))
         (buf (car pair))
         (session (cdr pair))
         (proc (start-process "ao-test-agent" nil
                             (executable-find "sleep") "120")))
    (setf (plist-get session :client)
          (list (cons :mock-client 99) (cons :process proc)))
    (cons buf proc)))

(defmacro ao--answers-kill (&rest body)
  "Run BODY answering every kill prompt NO, recording the prompts.
Returns (ANSWER-LIST . PROMPT-TEXTS) — the prompts recorded, so a test
can assert the wording as well as the refusal."
  (declare (indent 0))
  `(let ((ao--prompts nil))
     (cl-letf (((symbol-function 'yes-or-no-p)
                (lambda (prompt &rest _)
                  (push prompt ao--prompts)
                  nil)))
       ,@body)
     (nreverse ao--prompts)))

(defmacro ao--agrees-to-kill (&rest body)
  "Run BODY answering every kill prompt YES, recording the prompts."
  (declare (indent 0))
  `(let ((ao--prompts nil))
     (cl-letf (((symbol-function 'yes-or-no-p)
                (lambda (prompt &rest _)
                  (push prompt ao--prompts)
                  t)))
       ,@body)
     (nreverse ao--prompts)))

(ert-deftest test-agent-org-kill-of-chat-buffer-with-agent-asks ()
  "Killing a chat buffer whose agent runs asks, like Emacs asks about
process buffers.  `acp' starts the agent with `:noquery t' and no
`:buffer', so Emacs' own `process-kill-buffer-query-function' can never
see it: without a query of ours, `M-x kill-buffer' silently dropped a
running agent — and the answer NO has to leave the buffer, its session
and its process all still there."
  (let* ((pair (ao--chat-buffer-with-agent))
         (buf (car pair))
         (proc (cdr pair)))
    (unwind-protect
        (let ((prompts (ao--answers-kill (kill-buffer buf))))
          (should (= 1 (length prompts)))
          (should (buffer-live-p buf))
          (should (agent-org--session-for-buffer buf))
          (should (process-live-p proc)))
      (delete-process proc)
      (kill-buffer buf))))

(ert-deftest test-agent-org-kill-query-wording-names-the-process ()
  "The prompt says WHICH process, in Emacs' own words.
`Process <name> is running; kill it? ' is what `kill-buffer' asks about
a shell or compile buffer; borrowing the sentence is what makes the
question feel like it belongs to Emacs rather than to a package."
  (let* ((pair (ao--chat-buffer-with-agent))
         (buf (car pair))
         (proc (cdr pair)))
    (unwind-protect
        (let ((prompts (ao--answers-kill (kill-buffer buf))))
          (should (= 1 (length prompts)))
          (should (string-match-p "\\`Process .* is running; kill it\\? \\'"
                                  (car prompts)))
          (should (string-match-p "ao-test-agent" (car prompts))))
      (delete-process proc)
      (kill-buffer buf))))

(ert-deftest test-agent-org-kill-query-yes-kills-and-releases-the-agent ()
  "YES kills the buffer AND shuts the agent down: the query is a question,
not a second release path — `agent-org--forget-session' on
`kill-buffer-hook' is still what deletes the process."
  (let* ((acp-mock-shutdown-clients nil)
         (pair (ao--chat-buffer-with-agent))
         (buf (car pair))
         (proc (cdr pair))
         (client (plist-get (agent-org--session-for-buffer buf) :client)))
    (let ((prompts (ao--agrees-to-kill (kill-buffer buf))))
      (should (= 1 (length prompts)))
      (should-not (buffer-live-p buf))
      (should-not (agent-org--session-for-buffer buf))
      (should (equal (list client) acp-mock-shutdown-clients)))))

(ert-deftest test-agent-org-kill-query-stays-silent-without-a-live-agent ()
  "No live process, no question.  A Ready buffer whose agent died
mid-conversation must still be killable in one keystroke, and every
buffer with `:client' nil — which is what the offline suite builds —
would otherwise hang batch tests on a prompt they cannot answer."
  (let* ((buf (agent-org-buffer-create "quiet"))
         (session (list :name 'test :client nil :buffer buf
                        :session-id "sid-q" :streaming nil
                        :loading nil :replay nil :replay-timer nil
                        :replay-session-id nil :replay-response nil
                        :replay-deadline nil)))
    (agent-org--register-session session)
    (agent-org-buffer-set-session buf session)
    (let ((prompts (ao--answers-kill (kill-buffer buf))))
      (should (zerop (length prompts)))
      (should-not (buffer-live-p buf)))))

(ert-deftest test-agent-org-kill-query-ignores-a-dead-process ()
  "A process object that has already exited is not a reason to ask.
`process-live-p' is the predicate, not `processp': the child of an agent
that crashed still sits on the client plist until the buffer is killed."
  (let* ((pair (ao--chat-buffer-with-agent))
         (buf (car pair))
         (proc (cdr pair)))
    (delete-process proc)
    (let ((prompts (ao--answers-kill (kill-buffer buf))))
      (should (zerop (length prompts)))
      (should-not (buffer-live-p buf)))))

(ert-deftest test-agent-org-own-cancels-kill-without-asking ()
  "The kill agent-org performs on ITS OWN behalf is never a question.
`agent-org--cancel-open' releases a half-open buffer when the user quits
the chooser, and `agent-org--show-open-instead' kills the buffer this
command just opened when the chosen session turns out to be live in
another window.  Both already have a running agent process attached, so
an un-bypassed query would ask the user about a buffer they never
asked to kill — in the middle of a response callback."
  (let* ((pair (ao--chat-buffer-with-agent))
         (buf (car pair))
         (proc (cdr pair))
         (session (agent-org--session-for-buffer buf)))
    (unwind-protect
        (progn
          (let ((prompts (ao--answers-kill (agent-org--cancel-open session))))
            (should (zerop (length prompts))))
          (should-not (buffer-live-p buf))
          ;; the cancel killed the buffer, so the second path gets a fresh one
          (let* ((other (ao--chat-buffer-with-agent))
                 (other-buf (car other))
                 (other-proc (cdr other))
                 (ours (ao--chat-buffer-with-agent))
                 (ours-buf (car ours)))
            (unwind-protect
                (let ((prompts (ao--answers-kill
                                 (agent-org--show-open-instead
                                  (agent-org--session-for-buffer ours-buf)
                                  other-buf))))
                  (should (zerop (length prompts)))
                  (should-not (buffer-live-p ours-buf))
                  (should (buffer-live-p other-buf)))
              (when (process-live-p other-proc)
                (delete-process other-proc))
              (when (buffer-live-p other-buf)
                (kill-buffer other-buf))
              (when (buffer-live-p ours-buf)
                (delete-process (cdr ours))
                (kill-buffer ours-buf)))))
      (when (process-live-p proc)
        (delete-process proc))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest test-agent-org-kill-query-is-buffer-local ()
  "The question belongs to chat buffers only.  `kill-buffer-query-functions'
is a global hook, so a chat buffer must not make an ordinary buffer ask
about a process it has never seen."
  (let ((buf (generate-new-buffer " *ao-plain-kill*")))
    (let ((prompts (ao--answers-kill (kill-buffer buf))))
      (should (zerop (length prompts))))
    (should-not (buffer-live-p buf))))

(ert-deftest test-agent-org-kill-query-is-registered-not-global ()
  "The query is installed per buffer by the registry, never on the global
hook — a package that adds itself to `kill-buffer-query-functions'
globally has to keep its answer correct for every buffer in Emacs."
  (should-not (memq 'agent-org--kill-query kill-buffer-query-functions))
  (let ((buf (agent-org-buffer-create "hooked")))
    (agent-org--register-session
     (list :name 'test :client nil :buffer buf :session-id nil
           :streaming nil :loading nil :replay nil :replay-timer nil
           :replay-session-id nil :replay-response nil :replay-deadline nil))
    (should (memq 'agent-org--kill-query
                  (buffer-local-value 'kill-buffer-query-functions buf)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-killing-during-a-listing-cancels-the-timeout ()
  "A buffer killed while a `session/list' is in flight must not go on to
open a session: `agent-org--forget-session' unarms the timeout, and
`agent-org--list-timeout' refuses to act on a dead buffer.  The behaviour
is what gets asserted, because `cancel-timer' is stubbed out inside
`ao--capture-wire' — firing the stored timer is how the test says \"the
deadline arrived\", and a session opened into a killed buffer is the bug."
  (ao--capture-wire
    (let ((acp-mock-shutdown-clients nil))
      (let ((buf (agent-org-start 'goose)))
        (ao--drive "initialize" ao--fake-init-resp)
        (should (ao--sent-get "session/list"))
        (should ao--list-timer)
        (kill-buffer buf)
        (ao--time-out)
        (should-not (ao--sent-get "session/new"))
        (should (= 1 (length acp-mock-shutdown-clients)))))))

(ert-deftest test-agent-org-cancelling-the-start-prompt-kills-the-chat-buffer ()
  "ESC at the session choice must clean up after itself.  `completing-read'
signals `quit', which escapes into the acp response callback — and acp
wraps every callback in `condition-case-unless-debug', so the quit is
SWALLOWED: the buffer stayed open on \"Starting\" with its agent process
running and no way to prompt.  Cancelling now kills the buffer, which is
what releases the agent (`agent-org--forget-session' -> `acp-shutdown'),
and says so in the echo area."
  (let ((agent-org-session-strategy 'prompt))
    (ao--capture-wire
      (let ((acp-mock-shutdown-clients nil)
            (buf (agent-org-start 'qoder)))
        (ao--drive "initialize" ao--fake-init-resp)
        (should (ao--sent-get "session/list"))
        (ao--capture-messages
          (ao--cancel
            (ao--drive "session/list"
                       (ao--list-resp `(("s1" "One chat" ,(ao--today))
                                        ("s2" "Two chat"
                                         "2026-09-02T10:00:00+0000")))))
          (should (seq-some (lambda (m) (string-match-p "cancel" m)) ao--messages)))
        (should-not (buffer-live-p buf))
        (should-not (agent-org--session-for-buffer buf))
        ;; nothing was opened in the buffer that is no longer there
        (should-not (ao--sent-get "session/new"))
        (should-not (ao--sent-get "session/load"))
        (should (= 1 (length acp-mock-shutdown-clients)))))))

(ert-deftest test-agent-org-cancelling-the-resume-prompt-kills-the-chat-buffer ()
  "The same cleanup on `agent-org-resume-session', which prompts through
`agent-org--read-session-id' rather than `agent-org--read-start-choice'.
Two candidates, because one is auto-selected without asking and would
never reach the bug."
  (ao--capture-wire
    (let ((acp-mock-shutdown-clients nil)
          (buf (agent-org-resume-session 'qoder nil)))
      (ao--drive "initialize" ao--fake-init-resp)
      (should (ao--sent-get "session/list"))
      (ao--capture-messages
        (ao--cancel
          (ao--drive "session/list"
                     (ao--list-resp `(("s1" "One chat" ,(ao--today))
                                      ("s2" "Two chat"
                                       "2026-09-02T10:00:00+0000")))))
        (should (seq-some (lambda (m) (string-match-p "cancel" m)) ao--messages)))
      (should-not (buffer-live-p buf))
      (should-not (agent-org--session-for-buffer buf))
      (should-not (ao--sent-get "session/load"))
      (should (= 1 (length acp-mock-shutdown-clients))))))

(ert-deftest test-agent-org-start-silent-listing-says-why-on-the-header ()
  "A listing that never answers must not degrade in silence.  The echo
area note exists but is easy to miss — and after `session/new' the header
says plain Ready, so the first the user hears of the fallback is that the
prompt they configured never came.  The reason now sits on the Ready
segment."
  (ao--capture-wire
    (let ((buf (agent-org-start 'goose)))
      (ao--drive "initialize" ao--fake-init-resp)
      (should ao--list-timer)
      (ao--time-out)
      (ao--drive "session/new" '((sessionId . "s-t")))
      (with-current-buffer buf
        (should (equal 'ready (plist-get agent-org-buffer--status :state)))
        (should (string-match-p "timed out"
                                (plist-get agent-org-buffer--status :note)))
        (should (string-match-p "timed out"
                                (car (agent-org-buffer--status-segment
                                      agent-org-buffer--status)))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-start-failed-listing-says-why-on-the-header ()
  "Same channel for an agent that answers `session/list' with an error:
the failure text is the diagnostic, so it goes on the header too, short
and on one line however much the agent wrote."
  (ao--capture-wire
    (let ((buf (agent-org-start 'qoder)))
      (ao--drive "initialize" ao--fake-init-resp)
      (let ((entry (ao--sent-get "session/list")))
        (should entry)
        (funcall (plist-get entry :on-failure)
                 nil '((:object (error (code . -32603)
                                        (message . "boom"))) (:json . "{}"))))
      (ao--drive "session/new" '((sessionId . "s-f")))
      (with-current-buffer buf
        (should (equal 'ready (plist-get agent-org-buffer--status :state)))
        (let ((note (plist-get agent-org-buffer--status :note)))
          (should (string-match-p "boom" note))
          (should-not (string-match-p "\n" note))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-session-candidates-align-in-columns ()
  "Two chats whose titles differ wildly in length must still put their
dates in the same column, or the list reads as a ragged paragraph and the
one thing you scan for — recency — never lines up.  The id stays at the
end, because it is what actually selects."
  (let* ((stamp "2026-09-28T10:22:00+0000")
         (resp (list (cons 'sessions
                           (vector (list (cons 'sessionId "s-a")
                                         (cons 'title "Short")
                                         (cons 'updatedAt stamp))
                                   (list (cons 'sessionId "s-b")
                                         (cons 'title
                                           "A far longer opening prompt than the other one")
                                         (cons 'updatedAt stamp))))))
         (labels (seq-map #'car (agent-org--session-candidates resp))))
    (should (= 2 (length labels)))
    ;; titles carry no digits here, so the first digit is the date column
    (let ((cols (seq-map (lambda (l) (string-match-p "[0-9]" l)) labels)))
      (should (= 2 (length cols)))
      (should (apply #'equal cols)))
    (dolist (label labels)
      (should (string-match-p "\\[s-[ab]\\]\\'" label)))))

(ert-deftest test-agent-org-candidate-columns-align-by-display-width ()
  "A CJK title takes two display columns per character, so padding by
character COUNT leaves its date hanging a dozen columns early — and
`string-pad' pads by character count, which is how this was first got
wrong.  What has to be equal across rows is the width of everything
before the id, because that is what a completion UI lines up."
  (let* ((resp (list (cons 'sessions
                           (vector (list (cons 'sessionId "cjk")
                                         (cons 'title "日本語のタイトルです")
                                         (cons 'updatedAt "2026-09-28T10:22:00+0000"))
                                   (list (cons 'sessionId "lat")
                                         (cons 'title "Reconcile the failing ERT suite")
                                         (cons 'updatedAt "2026-09-27T10:22:00+0000"))))))
         (labels (seq-map #'car (agent-org--session-candidates resp))))
    (should (= 2 (length labels)))
    (should (apply #'equal
                   (seq-map (lambda (l)
                              (string-width (substring l 0 (string-match-p "\\[" l))))
                            labels)))))

(ert-deftest test-agent-org-collection-pins-our-order ()
  "The candidate order IS information (newest first, `New session' on
top), and a completion UI is free to re-sort a plain list collection.
Handing over a function with `display-sort-function' set to `identity' is
how agent-shell keeps its own ordering; without it a two-year-old chat can
land on top of the list you are about to choose from."
  (let ((agent-org-session-strategy 'prompt)
        (ao--prompted-with nil))
    (ao--capture-wire
      (let ((buf (agent-org-start 'qoder)))
        (ao--drive "initialize" ao--fake-init-resp)
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt collection &rest _)
                     (push collection ao--prompted-with)
                     (car (ao--collection collection)))))
          (ao--drive
           "session/list"
           (ao--list-resp `(("s1" "One chat" ,(ao--today))
                            ("s2" "Two chat" "2026-09-02T10:00:00+0000")))))
        (let ((collection (seq-first ao--prompted-with)))
          (should (functionp collection))
          (let ((metadata (funcall collection "" nil 'metadata)))
            (should (eq (cdr (assq 'display-sort-function (cdr metadata)))
                        #'identity)))
          ;; asking it for everything returns OUR order, `New session' first
          (let ((choices (ao--collection collection)))
            (should (= 3 (length choices)))
            (should (equal (car choices) agent-org-new-session-label))
            (should (string-match-p "\\[s1\\]\\'" (nth 1 choices)))
            (should (string-match-p "\\[s2\\]\\'" (nth 2 choices)))))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-candidates-mark-an-already-open-session ()
  "A `session/list' of this directory includes chats this Emacs already
has open.  Nothing on the candidate says so, so choosing one loads the
same ACP session a second time: two clients, two buffers, one history.
The open rows say `(open)', and the marker is part of the title column
it is measured with, so adding it cannot push the dates out of line."
  (let* ((open-buffer (generate-new-buffer " *ao-open-test*"))
         (agent-org--sessions (list (list :buffer open-buffer
                                          :session-id "s-live")))
         (resp (list (cons 'sessions
                           (vector (list (cons 'sessionId "s-live")
                                         (cons 'title "Already open chat")
                                         (cons 'updatedAt "2026-09-28T10:22:00+0000"))
                                   (list (cons 'sessionId "s-shut")
                                         (cons 'title "Closed chat")
                                         (cons 'updatedAt "2026-09-27T10:22:00+0000"))))))
         (cands (agent-org--session-candidates resp))
         (labels (seq-map #'car cands)))
    (should (string-match-p "(open)" (nth 0 labels)))
    (should-not (string-match-p "(open)" (nth 1 labels)))
    (should (apply #'equal
                   (seq-map (lambda (l) (string-width (substring l 0 (string-match-p "\\[" l))))
                            labels)))
    ;; the marker is display only: what selects is still the id
    (should (equal (cdr (nth 0 cands)) "s-live"))
    (kill-buffer open-buffer)))

(ert-deftest test-agent-org-dead-buffer-does-not-mark-a-session-open ()
  "The registry is dropped by a kill-hook, but a hook that has not run
yet leaves a session pointing at a dead buffer.  Offering to switch to
that buffer would be worse than the double load: the choice would do
nothing."
  (let* ((gone (generate-new-buffer " *ao-gone-test*"))
         (agent-org--sessions (list (list :buffer gone :session-id "s-dead"))))
    (kill-buffer gone)
    (should-not (agent-org--session-open-p "s-dead"))))

(ert-deftest test-agent-org-choosing-an-open-session-shows-its-buffer ()
  "Choosing an open chat must raise the buffer that has it and send
nothing: no `session/load' (a second client on the same session id), and
no `session/new' either.  The half-open buffer this command created is
killed, which is what releases the agent process spawned for it
(`agent-org--forget-session')."
  (let* ((open (generate-new-buffer " *ao-open-choice*"))
         (agent-org--sessions (list (list :buffer open :session-id "s-live")))
         (acp-mock-shutdown-clients nil))
    (ao--capture-wire
      (let ((buf (agent-org-start 'qoder)))
        (ao--drive "initialize" ao--fake-init-resp)
        (ao--pick "s-live"
          (ao--drive "session/list"
                     (ao--list-resp `(("s-live" "Already open" ,(ao--today))))))
        (should-not (ao--sent-get "session/load"))
        (should-not (ao--sent-get "session/new"))
        (should-not (buffer-live-p buf))
        (should (eq (window-buffer (selected-window)) open))
        (should (= 1 (length acp-mock-shutdown-clients)))
        (kill-buffer open)))))

(ert-deftest test-agent-org-session-label-shows-when-it-last-spoke ()
  "A candidate for an older session is only usable if you can tell its
age: today, yesterday, this year's date, or a dated year.  The id stays
last, because it is what actually selects the session."
  (let* ((today (format-time-string "%Y-%m-%dT%H:%M:%S+0600" nil
                                   "Asia/Dhaka"))
         (yesterday (format-time-string "%Y-%m-%dT12:00:00+0600"
                                        (time-subtract (current-time)
                                                       (days-to-time 1))
                                        "Asia/Dhaka"))
         (resp `((sessions . [((sessionId . "t") (title . "Today one")
                               (updatedAt . ,today))
                              ((sessionId . "y") (title . "Yesterday one")
                               (updatedAt . ,yesterday))
                              ((sessionId . "old") (title . "Ancient")
                               (updatedAt . "2024-03-05T12:00:00+0600"))
                              ((sessionId . "none") (title . "No stamp"))])))
         (labels (seq-map #'car (agent-org--session-candidates resp))))
    (should (string-match-p "Today, [0-9][0-9]:[0-9][0-9]" (nth 0 labels)))
    (should (string-match-p "Yesterday, " (nth 1 labels)))
    (should (string-match-p "Mar 05, 2024" (nth 2 labels)))
    (should-not (string-match-p "[0-9][0-9]:[0-9][0-9]" (nth 3 labels)))
    (dolist (label labels)
      (should (string-match-p "\\[[a-z]+\\]\\'" label))
      (should-not (string-match-p "\n" label)))))

(ert-deftest test-agent-org-resume-uses-the-paged-listing-too ()
  "Resume and start share the pager, because two renderers would drift;
the single-candidate shortcut stays resume's own."
  (ao--capture-wire
    (let ((buf (agent-org-resume-session 'qoder nil)))
      (ao--drive "initialize" ao--fake-init-resp)
      (ao--pick "s-p2"
        (ao--drive "session/list"
                   (ao--list-resp `(("s-p1" "Page one" ,(ao--today))) "cursor-2"))
        (ao--drive "session/list"
                   (ao--list-resp `(("s-p2" "Page two"
                                     "2026-09-01T10:00:00+0000")))))
      (let ((params (map-elt (plist-get (ao--sent-get "session/load") ':request)
                             ':params)))
        (should (equal (map-elt params 'sessionId) "s-p2")))
      (should (= 2 (ao--sent-count "session/list")))
      (kill-buffer buf))))

;;;; Switching between open chat buffers (agent-shell's `agent-shell-switch-buffer')
;;
;; `C-x b' can already find a chat by name, but a name is one long string:
;; three qoder chats differ only in a title buried in the middle of it.  The
;; switcher's job is the ROW — label, live state, id — in columns you can
;; scan, which is exactly what the session listing already builds, so these
;; tests pin the reuse rather than a second formatter.

(defun ao--two-chats ()
  "Two registered chats, both Ready, with distinct ids and harnesses.
Returns ((BUFFER-1 . SESSION-1) . (BUFFER-2 . SESSION-2)).  The fixture
`ao--make-test-session' gives both the same id and leaves the brand-new
buffer on `starting', so this pins both facts: a switcher that lists two
identical rows is the bug this section exists to prevent, and the state
column is what the tests below read.

`agent-org--sessions' is global and other suites leave their chat buffers
alive, so a caller that counts rows must bind it nil around the whole
body — that is the test's job, not this helper's, because the binding has
to outlive the registration."
  (let ((one (ao--make-test-session "qoder"))
        (two (ao--make-test-session "goose")))
    (setf (plist-get (cdr one) :session-id) "sid-one")
    (setf (plist-get (cdr two) :session-id) "sid-two")
    ;; distinct PROVIDERS, not distinct titles: a row's label is the agent
    ;; and the project, so two chats of one harness in one project would
    ;; give this section two identical rows to compare and no way to tell
    ;; which row is which.  The titles are still set — they are what the
    ;; `#+TITLE:' of each chat is made of, and a test that reads them from
    ;; the name is the bug this fixture used to hide.
    (agent-org-buffer-set-status (car one) :title "Fix the login bug"
                                 :session-id "sid-one" :state 'ready)
    (agent-org-buffer-set-status (car two) :title "Rewrite the loader"
                                 :session-id "sid-two" :state 'ready)
    (cons one two)))

(defun ao--dim-column (row)
  "The display-column offset of ROW's first DIMMED character, or nil.
`agent-org--session-display' leaves the title undecorated and puts the
`shadow' face on everything after it, so the first propertized character
IS the start of the date/status column — a measure that survives the
padding, unlike a search for the separator's spaces."
  (let ((i (next-single-property-change 0 'face row)))
    (and i (string-width (substring row 0 i)))))

(defmacro ao--isolated-registry (&rest body)
  "Run BODY with an empty session registry.
`agent-org--sessions' is global, and several earlier suites leave their
chat buffers alive, so a test that counts switcher rows would otherwise
count strangers — and a stranger's title is whatever the last test left
there, which is how a column assertion goes red for no reason."
  (declare (indent 0))
  `(let ((agent-org--sessions nil))
     ,@body))

(ert-deftest test-agent-org-switch-candidates-offer-every-open-chat ()
  "Every live chat buffer is a row, and the row's value is the BUFFER.
The cdr must be the buffer object, not its name: a name is what an agent
can rename out from under the registry, and choosing a chat by string
would then switch to nothing."
  (ao--isolated-registry
    (let* ((pair (ao--two-chats))
           (one (car pair))
           (two (cdr pair))
           (choices (agent-org--switch-candidates)))
      (should (= 2 (length choices)))
      (should (equal (mapcar #'cdr choices) (list (car two) (car one))))
      (should (string-prefix-p "goose:" (car (nth 0 choices))))
      (should (string-match-p "\\[sid-two\\]\\'" (car (nth 0 choices))))
      (should (string-prefix-p "qoder:" (car (nth 1 choices))))
      (kill-buffer (car one))
      (kill-buffer (car two)))))

(ert-deftest test-agent-org-switch-candidates-wear-the-provider-and-project ()
  "A chat that has been titled nothing still gets a readable row, and it
gets the SAME row shape as one that has: the label is the provider and the
project, so there is no fallback path left to test.  The project directory
comes from `agent-org-buffer-create', which knows the cwd from the moment
the buffer exists, and the id from `session/new' — which is what makes a
title-less agent (goose advertises none) indistinguishable in shape from
one that titles everything (qoder)."
  (ao--isolated-registry
    (let* ((pair (ao--make-test-session "untitled"))
           (choices (agent-org--switch-candidates))
           (project (file-name-nondirectory
                     (directory-file-name default-directory))))
      (should (= 1 (length choices)))
      (should (string-prefix-p (format "untitled:%s" project)
                               (car (nth 0 choices))))
      (should (string-match-p "\\[sid-test\\]\\'" (car (nth 0 choices))))
      (kill-buffer (car pair)))))

(ert-deftest test-agent-org-switch-candidates-label-the-chat-not-its-topic ()
  "A row's label is the agent and the project, never the session title.
The switcher shares `agent-org-buffer--chat-label' with the buffer name
deliberately, so a fix that stopped the title entering the NAME must not
leave it entering the ROW — one chat, one label, and the user's complaint
was that the label described the topic instead of the harness."
  (ao--isolated-registry
    (let* ((pair (ao--two-chats))
           (one (car pair))
           (two (cdr pair)))
      (agent-org-buffer-set-status (car one) :project "org-docs")
      (agent-org-buffer-set-status (car two) :project "agent-org")
      (let ((choices (agent-org--switch-candidates)))
        ;; row 0 is `two', row 1 is `one' (registry order)
        (should (string-prefix-p "goose:agent-org" (car (nth 0 choices))))
        (should (string-prefix-p "qoder:org-docs" (car (nth 1 choices))))
        (should-not (string-match-p "loader" (car (nth 0 choices))))
        (should-not (string-match-p "login" (car (nth 1 choices))))
        ;; The shared builder, checked against the row rather than trusted:
        ;; this is what makes the assertion above survive a rename of the
        ;; buffer-name rules.
        (dolist (row choices)
          (should (string-prefix-p
                   (agent-org-buffer--chat-label
                    (buffer-local-value 'agent-org-buffer--status (cdr row)))
                   (car row))))
        (kill-buffer (car one))
        (kill-buffer (car two))))))

(ert-deftest test-agent-org-switch-candidates-show-the-state-the-bar-shows ()
  "The status column is the header line's own vocabulary.
Two words for one state (\"Ready\" on the bar, \"ready\" in the list) is
how a UI teaches you not to trust it, so the column comes from
`agent-org-buffer--state-label'."
  (ao--isolated-registry
    (let* ((pair (ao--two-chats))
           (one (car pair))
           (two (cdr pair)))
      (with-current-buffer (car two)
        (agent-org-buffer-set-status (car two) :state 'streaming))
      (let ((choices (agent-org--switch-candidates)))
        (should (string-match-p "Streaming" (car (nth 0 choices))))
        (should (string-match-p "Ready" (car (nth 1 choices)))))
      (kill-buffer (car one))
      (kill-buffer (car two)))))

(ert-deftest test-agent-org-switch-candidates-align-their-columns ()
  "The status column starts at the same display width in every row.
Measured the way the session listing measures: `string-width', so a CJK
label pads like a Latin one.  Ragged rows are the whole reason a chat list
is read by scanning down one column instead of reading across.

The column's start is ROW's first dimmed character, and NOT its first run
of two spaces: the short label is padded with spaces and the separator is
spaces too, so on a padded row the first double space sits somewhere
INSIDE the padding — counting to it measures where the padding happened to
begin, which is why this assertion read (18 47) while the rows, printed,
were identical 65-column strings."
  (ao--isolated-registry
    (let* ((pair (ao--two-chats))
           (one (car pair))
           (two (cdr pair)))
      ;; row 0 is `two' (registry order) and keeps its short label, so a
      ;; shared column start proves the SHORT row was padded to the long one.
      ;; The long half of the pair is the PROVIDER, because that is the only
      ;; part of the label an agent can make long now a title never enters it.
      (agent-org-buffer-set-status (car one) :provider
                                   "a harness whose name runs on for very long indeed")
      (let ((labels (mapcar #'car (agent-org--switch-candidates))))
        (should (= 2 (length labels)))
        (should (apply #'equal (seq-map #'ao--dim-column labels)))
        ;; Equal total width too: the ids are the same length here, so the two
        ;; rows can only line up if the SHORT label was padded out to the
        ;; long one rather than the long one being cut down.
        (should (apply #'equal (seq-map #'string-width labels)))))))

(ert-deftest test-agent-org-switch-candidates-drop-a-killed-chat ()
  "A buffer that is gone is not offered, even if its entry is still in
`agent-org--sessions' — the registry is a stack of plists, and a plist
outlives its window until the kill-hook runs."
  (ao--isolated-registry
    (let* ((pair (ao--two-chats))
           (one (car pair))
           (two (cdr pair)))
      (kill-buffer (car two))
      (let ((choices (agent-org--switch-candidates)))
        (should (= 1 (length choices)))
        (should (equal (list (car one)) (mapcar #'cdr choices))))
      (kill-buffer (car one)))))

(ert-deftest test-agent-org-switch-buffer-switches-to-the-chosen-chat ()
  "The command reads a row and lands on that buffer, not on the other one."
  (ao--isolated-registry
    (let* ((pair (ao--two-chats))
           (one (car pair))
           (two (cdr pair)))
      (with-current-buffer (car one)
        (ao--pick "sid-two"
          (agent-org-switch-buffer))
        (should (eq (car two) (current-buffer))))
      (kill-buffer (car one))
      (kill-buffer (car two)))))

(ert-deftest test-agent-org-switch-buffer-with-nothing-open-signals ()
  "No chats, no minibuffer: a `user-error', not an empty completion.
Same shape as every other agent-org entry point — the user gets a reason
in the echo area, and nothing to cancel."
  (let ((completing-read-called nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) (setq completing-read-called t) "")))
      (should-error (agent-org-switch-buffer) :type 'user-error)
      (should-not completing-read-called))))

(ert-deftest test-agent-org-switch-buffer-pins-registry-order ()
  "The collection is a function that refuses the UI's re-sorting.
Registry order is newest-chat-first, which is the order a person switching
between chats wants; a plain list would be handed back alphabetically by
title and that information would be lost at the last step.  Same machinery
as the session chooser, so it must keep behaving the same."
  (ao--isolated-registry
    (let* ((pair (ao--two-chats))
           (one (car pair))
           (two (cdr pair))
           (collection nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt coll &rest _)
                   (setq collection coll)
                   (car (ao--collection coll)))))
        (agent-org-switch-buffer))
      (should (functionp collection))
      (let ((metadata (funcall collection "" nil 'metadata)))
        (should (eq (cdr (assq 'display-sort-function (cdr metadata)))
                    #'identity)))
      (should (equal (list (car two) (car one))
                     (mapcar #'cdr (agent-org--switch-candidates))))
      (kill-buffer (car one))
      (kill-buffer (car two)))))

(ert-deftest test-agent-org-switch-buffer-name-matches-agent-shell ()
  "The switcher borrows agent-shell's command name, not a synonym.
`agent-shell-switch-buffer' is what its users already type in M-x;
`agent-org-go-to-session' or `agent-org-select-buffer' would be a second
vocabulary for one action."
  (should (commandp 'agent-org-switch-buffer)))

;;;; Progress reporting while a session loads
;;
;; Two windows in agent-org are actually slow: fetching the directory's
;; older chats, and replaying one of them.  Both are now reported with
;; Emacs's own progress reporter in the echo area, which bounds its own
;; redisplays; the phase before them (the handshake) stays header-only,
;; because there is nothing to count and no events to step on.

(ert-deftest test-agent-org-progress-arms-no-timer ()
  "The report is stepped by the events that happen, never by a clock.
`agent-shell-active-message-show' animates its reporter with
`run-at-time' at 0.1s — ten wakeups a second, of which Emacs will
display at most five (`make-progress-reporter''s own MIN-TIME default is
0.2s), and which go on firing while the agent says nothing at all.  On a
Celeron that is the cost of a decoration: here a replay chunk or a
listing page IS the tick, so an idle agent costs zero."
  (let ((armings 0)
        (session (list :buffer nil :progress nil)))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (&rest _) (cl-incf armings) nil)))
      (agent-org--progress-start session "Restoring session history")
      (agent-org--progress-step session)
      (agent-org--progress-step session)
      (agent-org--progress-stop session))
    (should (= 0 armings))
    (should-not (plist-get session :progress))))

(ert-deftest test-agent-org-progress-throttles-the-echo-area ()
  "Stepping is cheap; displaying is not, so the interval bounds displays.
`progress-reporter-update' documents itself as relatively inexpensive:
it does nothing when the change since the last report is too small or
insufficient time has passed.  `agent-org-progress-min-time' is that
interval, and these two runs are the difference between a call and a
redisplay of a growing Org buffer: 20 steps an hour apart cost ONE
echo-area line — the one the report paints when it is created — while
the same 20 steps with the interval pinned to 0 show every one of them.
A slow machine raises the variable; the default is Emacs's own 0.2s."
  (let ((session (list :buffer nil :progress nil)))
    (ao--capture-messages
      (let ((agent-org-progress-min-time 3600))
        (agent-org--progress-start session "Restoring" :total 100)
        (dotimes (i 20) (agent-org--progress-step session (* (1+ i) 5))))
      ;; one line: the one the report painted when it was created
      (should (= 1 (length (remq nil ao--messages)))))
    (let ((session (list :buffer nil :progress nil)))
      (ao--capture-messages
        (let ((agent-org-progress-min-time 0))
          (agent-org--progress-start session "Restoring" :total 100)
          (dotimes (i 20) (agent-org--progress-step session (* (1+ i) 5))))
        ;; creation plus one per step, i.e. nothing suppressed
        (should (>= (length (remq nil ao--messages)) 20))))))

(ert-deftest test-agent-org-progress-replaces-the-reporter-it-starts-over ()
  "One session, one echo-area line: starting closes what was open.
The listing report and the replay report are consecutive phases of the
same `agent-org-start', so a second live reporter would mean two owners
of one line — and the older one would keep stepping a message nobody is
waiting for.  Only what is displayed AFTER the replacement matters here:
creating a report paints its line immediately, so the first phase is
entitled to the echo area while it is the phase you are in."
  (let ((session (list :buffer nil :progress nil)))
    (ao--capture-messages
      (let ((agent-org-progress-min-time 0))
        (agent-org--progress-start session "Listing sessions")
        (agent-org--progress-step session "12 so far")
        (let ((before (length ao--messages)))
          (agent-org--progress-start session "Restoring session history")
          (agent-org--progress-step session)
          ;; `ao--messages' is newest first, so the lines the replacement
          ;; produced are the ones in front of what was already there.
          (let ((fresh (seq-take ao--messages (- (length ao--messages) before))))
            (should fresh)
            (should-not (seq-filter (lambda (m) (and m (string-match-p "Listing" m)))
                                    fresh))
            (should (seq-filter (lambda (m) (and m (string-match-p "Restoring" m)))
                                fresh))
            (should (plist-get session :progress))))))))

(ert-deftest test-agent-org-progress-stop-clears-rather-than-says-done ()
  "Closing a report frees the echo area instead of printing `...done'.
`progress-reporter-done' exists to announce a task whose result you
cannot otherwise see; both of our phases produce something visible (the
chooser opens, the history is in the buffer), and the header line already
carries the state.  agent-shell calls done and then `(message nil)'
back-to-back, so its `done' line is a redisplay nobody reads — the one
cost we can simply not pay."
  (let ((session (list :buffer nil :progress nil)))
    (ao--capture-messages
      (let ((agent-org-progress-min-time 0))
        (agent-org--progress-start session "Restoring session history")
        (agent-org--progress-step session)
        (agent-org--progress-stop session))
      (should-not (plist-get session :progress))
      (should (null (car ao--messages)))
      (should-not (seq-filter (lambda (m) (and m (string-match-p "done" m)))
                              ao--messages)))))

(ert-deftest test-agent-org-listing-reports-and-clears-before-the-prompt ()
  "Fetching the older chats is reported, and the report is closed before
the chooser opens.
The header says `Connecting…' for the whole window between the handshake
and a live session — true, but not specific: this wait is the listing.
After it the user is reading candidates, so a progress line still
blinking over the minibuffer would be noise at exactly the wrong moment."
  (ao--capture-wire
    (let* ((agent-org-progress-min-time 0)
           (agent-org-session-strategy 'prompt)
           (at-prompt nil)
           (buf (agent-org-start 'qoder))
           (session (agent-org--session-for-buffer buf)))
      (ao--drive "initialize" ao--fake-init-resp)
      (should (plist-get session :progress))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (push (list :live (plist-get session :progress)
                               :latest (car ao--messages))
                         at-prompt)
                   (seq-find (lambda (c) (string-match-p "\\[s-new\\]" c))
                             (ao--collection collection)))))
        (ao--capture-messages
          (ao--drive "session/list"
                     (ao--list-resp `(("s-new" "Newest chat" ,(ao--today))
                                      ("s-old" "Older chat"
                                       "2026-09-01T10:00:00+0000"))))
          (should (= 1 (length at-prompt)))
          (should-not (plist-get (car at-prompt) :live))
          (should (null (plist-get (car at-prompt) :latest)))
          (should (seq-filter (lambda (m) (and m (string-match-p "Listing sessions" m)))
                              ao--messages)))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-listing-pages-step-the-report ()
  "Every page of a paged listing ticks the report, and says how many it has.
A directory with hundreds of chats is fetched over several requests; the
count in the report is the difference between \"working\" and \"hung\" on
a machine where one agent process already owns the CPU.
Both counts come from ONE report, because the continuation leaves it
running: the numbers climb rather than restarting, which is the only way
a paged listing reads as progress.  The report this test ends with is the
replay's, not the listing's — `latest' chose a session and
`agent-org--progress-start' handed the line over."
  (ao--capture-wire
    (let* ((agent-org-progress-min-time 0)
           (agent-org-session-strategy 'latest)
           (buf (agent-org-start 'qoder))
           (session (agent-org--session-for-buffer buf)))
      (ao--drive "initialize" ao--fake-init-resp)
      (ao--capture-messages
        (ao--drive "session/list"
                   (ao--list-resp `(("s-p1" "Page one" ,(ao--today))) "cursor-2"))
        (ao--drive "session/list"
                   (ao--list-resp `(("s-p2" "Page two"
                                     "2026-09-01T10:00:00+0000"))))
        (dolist (count '("1 so far" "2 so far"))
          (should (seq-filter (lambda (m) (and m (string-match-p count m)))
                              ao--messages)))
        (should (plist-get session :progress)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-replay-reports-as-history-arrives ()
  "`session/load' is the wait a user feels, so the echo area moves with it.
While the replay streams the buffer is not interactive and the header
cannot say how much has landed — a 200-turn restore looked identical to a
hung one.  Each buffered update steps the report, which is what makes a
spinner animate without any timer running."
  (ao--capture-wire
    (let* ((agent-org-progress-min-time 0)
           (buf (agent-org-resume-session 'qoder "sid-p"))
           (session (agent-org--session-for-buffer buf)))
      (ao--drive "initialize" ao--fake-init-resp)
      (should (plist-get session :progress))
      (ao--capture-messages
        (dolist (update (list
                         '((sessionUpdate . "user_message_chunk")
                           (content . ((type . "text") (text . "Old question"))))
                         '((sessionUpdate . "agent_message_chunk")
                           (content . ((type . "text") (text . "Old answer"))))))
          (agent-org--on-notification session (ao--update-notif update)))
        (should (>= (length (seq-filter (lambda (m)
                                          (and m (string-match-p "Restoring session history" m)))
                                        ao--messages))
                    2))
        (ao--drive "session/load" '((sessionId . "sid-p")))
        (ao--settle)
        (should-not (plist-get session :progress))
        (should (null (car ao--messages))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-painting-history-reports-a-percentage ()
  "The paint pass reports a fraction of the buffered updates.
This is the part that costs the machine real time — hundreds of Org
insertions in one synchronous run — and it is the only phase with a
denominator, since the buffered replay is counted by then.  A spinner
here would say \"busy\"; a percentage says how far to go."
  (ao--capture-wire
    (let* ((agent-org-progress-min-time 0)
           (buf (agent-org-resume-session 'qoder "sid-pct"))
           (session (agent-org--session-for-buffer buf)))
      (ao--drive "initialize" ao--fake-init-resp)
      (dolist (n '(1 2 3 4))
        (agent-org--on-notification
         session
         (ao--update-notif
          `((sessionUpdate . "agent_message_chunk")
            (content . ((type . "text") (text . ,(format "Turn %s" n))))))))
      (ao--drive "session/load" '((sessionId . "sid-pct")))
      (ao--capture-messages
        (ao--settle)
        (should (seq-filter (lambda (m)
                              (and m (string-match-p "[0-9]+%" m)))
                            ao--messages))
        (should-not (plist-get session :progress)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-killing-a-loading-buffer-clears-the-report ()
  "A restore abandoned by killing the chat buffer leaves no line behind.
`agent-org--forget-session' already owns every other exit of a loading
session — its timers, its agent process, its registry entry — and the
echo area is the fourth: without this the killed buffer's spinner kept
redrawing a line under whatever the user opened next."
  (ao--capture-wire
    (let* ((agent-org-progress-min-time 0)
           (buf (agent-org-resume-session 'qoder "sid-k"))
           (session (agent-org--session-for-buffer buf)))
      (ao--drive "initialize" ao--fake-init-resp)
      (should (plist-get session :progress))
      (ao--capture-messages
        (kill-buffer buf)
        (should-not (plist-get session :progress))
        (should (null (car ao--messages)))))))

(ert-deftest test-agent-org-failed-load-clears-the-report ()
  "A `session/load' that fails ends the report silently.
The header carries the error (`:state 'error' renders its message), so
the echo area's job is to get out of the way — no `...done', no spinner,
and nothing left that would cover the diagnostic."
  (ao--capture-wire
    (let* ((agent-org-progress-min-time 0)
           (buf (agent-org-resume-session 'qoder "sid-f"))
           (session (agent-org--session-for-buffer buf)))
      (ao--drive "initialize" ao--fake-init-resp)
      (ao--capture-messages
        (let ((entry (ao--sent-get "session/load")))
          (should entry)
          (funcall (plist-get entry :on-failure)
                   nil '((:object (error (code . -32603)
                                         (message . "boom"))) (:json . "{}"))))
        (should-not (plist-get session :progress))
        (should (null (car ao--messages))))
      (kill-buffer buf))))

;;;; One Org transcript file per session
;;
;; User order (TODOs.org): "By default, keep a single Org transcript file to map
;; to a session and regularly update it."  agent-shell appends each arriving
;; chunk to a markdown file; here the chat body IS already an Org document, so
;; the file is a MIRROR of its frozen part, rewritten at the turn boundaries.
;; Three consequences, and each has a test below:
;;  - one renderer, not two (a second paint path always drifts from the first);
;;  - a tool heading that went TODO -> DONE appears ONCE, as DONE, which an
;;    append log cannot express;
;;  - the cost is a couple of whole-file writes per TURN, never one per chunk.

(defmacro ao--transcript-in (dir &rest body)
  "Run BODY with transcription ON, writing into DIR.
The feature has exactly two knobs and every writer test wants both:
`agent-org-transcribe' on, and a directory that is not the real one under
`user-emacs-directory' where the user's own transcripts live."
  (declare (indent 1))
  `(let ((agent-org-transcribe t)
         (agent-org-transcript-dir ,dir))
     ,@body))

(defun ao--transcript-files (dir)
  "Every `.org' name in DIR, sorted.  How these tests count files.
`directory-files' answers \".\" and \"..\" too, and a transcript directory
holds nothing else, so the suffix filter is the whole assertion."
  (sort (seq-filter (lambda (f) (string-suffix-p ".org" f))
                    (directory-files dir))
        #'string<))

(defun ao--transcript-text (dir session-id)
  "The text SESSION-ID's transcript holds in DIR.
The path is built with `agent-org-buffer--transcript-name' as plumbing; the
name's SHAPE is pinned against a literal string by
`test-agent-org-transcript-file-is-named-for-the-session-id', so nothing
here is circular."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name (agent-org-buffer--transcript-name session-id) dir))
    (buffer-string)))

(defvar ao--writes nil
  "How many `.org' writes `ao--counting-writes' has swallowed.")

(defmacro ao--counting-writes (&rest body)
  "Run BODY with `write-region' swallowed and counted in `ao--writes'.
Only a `.org' target counts: `write-region' has other callers, and what is
being measured here is what the transcript writer does."
  (declare (indent 0))
  `(let ((ao--writes 0))
     (cl-letf (((symbol-function 'write-region)
                (lambda (start end filename &optional append visit &rest _)
                  (when (and (stringp filename) (string-suffix-p ".org" filename))
                    (cl-incf ao--writes)))))
       ,@body)))

(ert-deftest test-agent-org-transcript-file-is-named-for-the-session-id ()
  "A session's transcript is one file, named by its ACP id.
The id is the only fact that survives a rename, a title change and a
restart, so it is what maps a file to a session.  A chat with no turn yet
still gets the file: it carries the =:PROPERTIES:= drawer — including that
same id as Org's =:ID:=, which is what makes the transcript an
=id:=-linkable document — and the first thing in it is the header, not a
conversation."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (ao--capture-wire
        (let ((buf (ao--chat-on-model "qmodel-large" "QModel Large" "sid-42")))
          (should (equal '("sid-42.org") (ao--transcript-files temp-dir)))
          (let ((text (ao--transcript-text temp-dir "sid-42")))
            (should (string-match-p "^:ID: sid-42$" text))
            (should (string-match-p "^#\\+TITLE: " text))
            ;; the live type-ahead box is not conversation yet
            (should-not (string-match-p "^\\* PROMPT$" text)))
          (kill-buffer buf))))))

(ert-deftest test-agent-org-transcript-holds-a-completed-turn ()
  "One turn, on disk, in the order it happened: prompt, answer, tool, thought.
Twenty chunks stream an answer and the file holds one copy of it — the
transcript is written from the buffer at the turn boundary, so however the
agent split its reply, the document is the reply."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (ao--capture-wire
        (let* ((buf (ao--chat-on-model "qmodel-large" "QModel Large" "sid-turn"))
               (session (agent-org--session-for-buffer buf))
               (sent nil))
          (cl-letf (((symbol-function 'acp-send-request)
                     (lambda (&rest kw) (push kw sent)))
                    ((symbol-function 'acp-make-session-prompt-request)
                     (lambda (&rest a) (plist-get a :prompt))))
            (with-current-buffer buf
              (ao--type "align the columns")
              (agent-org-send))
            (dotimes (_ 20)
              (agent-org--on-notification
               session (ao--update-notif
                        '((sessionUpdate . "agent_message_chunk")
                          (content . ((type . "text") (text . "tok ")))))))
            (agent-org--on-notification
             session (ao--update-notif
                      '((sessionUpdate . "agent_thought_chunk")
                        (content . ((type . "text") (text . "reasoning here"))))))
            (agent-org--on-notification
             session (ao--update-notif
                      '((sessionUpdate . "tool_call")
                        (toolCallId . "t1") (title . "grep -rn foo")
                        (status . "pending"))))
            (funcall (plist-get (car sent) :on-success) nil)
            (let ((text (ao--transcript-text temp-dir "sid-turn")))
              (should (apply #'ao--ordered text
                             (list "^:ID: sid-turn$"
                                   "^\\* RESPONDED align the columns$"
                                   "^QModel Large: $"
                                   "tok tok"
                                   "^:thinking:$" "reasoning here"
                                   "^:tool:$" "^  - RUNNING grep -rn foo$")))
              (kill-buffer buf))))))))

(ert-deftest test-agent-org-transcript-tool-line-gets-rewritten ()
  "A tool that finished appears as EXECUTED once — no RUNNING line above it.
This is the test that says \"mirror, not append log\": a per-chunk append can
only add, so an in-place state change would leave the superseded line in the
file forever.  Here the buffer already redrew the `:tool:' drawer from the
stored status and the file simply agrees with the buffer."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (ao--capture-wire
        (let* ((buf (ao--chat-on-model "qmodel-large" "QModel Large" "sid-tool"))
               (session (agent-org--session-for-buffer buf))
               (sent nil))
          (cl-letf (((symbol-function 'acp-send-request)
                     (lambda (&rest kw) (push kw sent)))
                    ((symbol-function 'acp-make-session-prompt-request)
                     (lambda (&rest a) (plist-get a :prompt))))
            (with-current-buffer buf
              (ao--type "run it")
              (agent-org-send))
            (dolist (status '("pending" "in_progress" "completed"))
              (agent-org--on-notification
               session (ao--update-notif
                        `((sessionUpdate . "tool_call_update")
                          (toolCallId . "t1") (title . "run tests")
                          (status . ,status)))))
            (funcall (plist-get (car sent) :on-success) nil)
            (let ((text (ao--transcript-text temp-dir "sid-tool")))
              (should (= 1 (ao--count-occurrences text "^  - EXECUTED run tests$")))
              (should (= 0 (ao--count-occurrences text "^  - \\(TODO\\|ONGOING\\) run tests$")))
              (kill-buffer buf))))))))

(ert-deftest test-agent-org-transcript-files-tool-output-under-its-line ()
  "What the tool printed is part of the record, so it reaches the file.
The transcript mirrors the buffer, and the output is now an item of the
BOARD itself -- which is the cheap way to get durable tool output: no second
writer, no second format, and one drawer holds both the state and the result
in the chat and in the file an hour later."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (ao--capture-wire
        (let* ((buf (ao--chat-on-model "qmodel-large" "QModel Large" "sid-out"))
               (session (agent-org--session-for-buffer buf))
               (sent nil))
          (cl-letf (((symbol-function 'acp-send-request)
                     (lambda (&rest kw) (push kw sent)))
                    ((symbol-function 'acp-make-session-prompt-request)
                     (lambda (&rest a) (plist-get a :prompt))))
            (with-current-buffer buf
              (ao--type "show me the tree")
              (agent-org-send))
            (agent-org--on-notification
             session (ao--update-notif
                      `((sessionUpdate . "tool_call_update")
                        (toolCallId . "t1") (title . "ls -R") (status . "completed")
                        ,@(ao--tool-text-block "agent-org.el\nTODOs.org"))))
            (funcall (plist-get (car sent) :on-success) nil)
            (let ((text (ao--transcript-text temp-dir "sid-out")))
              (should (= 1 (ao--count-occurrences text "^:tool:$")))
              (should (= 1 (ao--count-occurrences text "^  - EXECUTED ls -R$")))
              (should (string-match-p "^    agent-org.el$" text))
              (should (string-match-p "^    TODOs.org$" text))
              (kill-buffer buf))))))))

(ert-deftest test-agent-org-transcript-is-one-file-for-the-whole-session ()
  "Three turns, one file: the transcript maps to the SESSION, not to a turn.
A chat that spawned a file per answer would be a pile of fragments nobody
reads again, and `agent-org-reload' — which replays the same id through a
new buffer — lands on the same file for the same reason."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (ao--capture-wire
        (let* ((buf (ao--chat-on-model "qmodel-large" "QModel Large" "sid-multi"))
               (sent nil))
          (cl-letf (((symbol-function 'acp-send-request)
                     (lambda (&rest kw) (push kw sent)))
                    ((symbol-function 'acp-make-session-prompt-request)
                     (lambda (&rest a) (plist-get a :prompt))))
            (dolist (prompt '("first" "second" "third"))
              (with-current-buffer buf
                (ao--type prompt)
                (agent-org-send)
                (agent-org-buffer-append-chunk
                 buf (format "answer to %s" prompt)
                 (agent-org--session-for-buffer buf))
                (funcall (plist-get (car sent) :on-success) nil)))
            (should (equal '("sid-multi.org") (ao--transcript-files temp-dir)))
            (let ((text (ao--transcript-text temp-dir "sid-multi")))
              (should (apply #'ao--ordered text
                             (list "first" "answer to first"
                                   "second" "answer to second"
                                   "third" "answer to third")))
              ;; three exchange headings, one per prompt (the type-ahead box is
              ;; below the render end and never mirrored)
              (should (= 3 (ao--count-occurrences text "^\\* ")))
              (kill-buffer buf))))))))

(ert-deftest test-agent-org-transcript-leaves-the-unsent-draft-out ()
  "What the user has typed but not sent never reaches the file.
The boundary between the two is `agent-org-buffer--render-end' — the same
marker that keeps a streaming turn from scribbling over a draft — so the
transcript is the conversation and a half-written thought stays in the
buffer.  A late title push is the boundary here: it re-marks the session
ready while a draft is live, which is exactly when the two could mix."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (ao--capture-wire
        (let* ((sid "sid-draft")
               (buf (ao--chat-on-model "qmodel-large" "QModel Large" sid))
               (session (agent-org--session-for-buffer buf))
               (sent nil))
          (cl-letf (((symbol-function 'acp-send-request)
                     (lambda (&rest kw) (push kw sent)))
                    ((symbol-function 'acp-make-session-prompt-request)
                     (lambda (&rest a) (plist-get a :prompt))))
            (with-current-buffer buf
              (ao--type "sent prompt")
              (agent-org-send)
              (funcall (plist-get (car sent) :on-success) nil)
              (ao--type "half a thought, still typing"))
            ;; a params-level sessionId is what the handler gates on: no
            ;; id, no ready pass, no boundary to test
            (agent-org--on-notification
             session
             `((method . "session/update")
               (params . ((sessionId . ,sid)
                          (update . ((sessionUpdate . "session_info_update")
                                     (title . "Renamed by the agent")))))))
            (let ((text (ao--transcript-text temp-dir "sid-draft")))
              (should (string-match-p "sent prompt" text))
              (should-not (string-match-p "half a thought" text))
              ;; and the metadata did catch up, in the same pass
              (should (string-match-p "^#\\+TITLE: Renamed by the agent$" text))
              (kill-buffer buf))))))))

(ert-deftest test-agent-org-transcript-paints-a-restored-session ()
  "A resumed chat is on disk without anyone sending a prompt into it.
Restoring is the case where a per-turn write would never fire: the history
arrives in one replay pass and the user may read it and close Emacs.
`agent-org--finish-replay' ends in `agent-org--session-ready', which is a
boundary, so the mirror is written once the history has landed."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (ao--capture-wire
        (let ((buf (agent-org-resume-session 'qoder "sid-restored")))
          (let ((session (agent-org--session-for-buffer buf)))
            (ao--drive "initialize" ao--fake-init-resp)
            (dolist (update (list
                             '((sessionUpdate . "user_message_chunk")
                               (content . ((type . "text") (text . "Old question"))))
                             '((sessionUpdate . "agent_message_chunk")
                               (content . ((type . "text") (text . "Old answer"))))))
              (agent-org--on-notification session (ao--update-notif update)))
            (ao--drive "session/load" '((sessionId . "sid-restored")))
            (ao--settle)
            (should (equal '("sid-restored.org") (ao--transcript-files temp-dir)))
            (let ((text (ao--transcript-text temp-dir "sid-restored")))
              (should (apply #'ao--ordered text (list "Old question" "Old answer"))))
            (kill-buffer buf)))))))

(ert-deftest test-agent-org-transcript-writes-nothing-when-turned-off ()
  "`agent-org-transcribe' nil means no file appears, at all.
The default is on, so this is the opt-out the user's wording asks for
(\"BY DEFAULT, keep a single Org transcript file\") honoured in the other
direction: someone whose transcripts are their own org files under version
control must be able to turn the writer off without patching it out."
  (ert-with-temp-directory temp-dir
    (let ((agent-org-transcribe nil)
          (agent-org-transcript-dir temp-dir))
      (ao--capture-wire
        (let* ((buf (ao--chat-on-model "qmodel-large" "QModel Large" "sid-off"))
               (sent nil))
          (cl-letf (((symbol-function 'acp-send-request)
                     (lambda (&rest kw) (push kw sent)))
                    ((symbol-function 'acp-make-session-prompt-request)
                     (lambda (&rest a) (plist-get a :prompt))))
            (with-current-buffer buf
              (ao--type "quiet")
              (agent-org-send)
              (funcall (plist-get (car sent) :on-success) nil))
          (should (null (ao--transcript-files temp-dir)))
          ;; the chat itself works exactly the same way
          (with-current-buffer buf
            (should (string-match-p "quiet" (buffer-string))))
          (kill-buffer buf)))))))

(ert-deftest test-agent-org-transcript-costs-writes-per-turn-not-per-chunk ()
  "One turn costs two whole-file writes: the send and the turn end.
This is the overhead claim on a 4 GB machine.  Twenty streaming chunks and a
thought add NOTHING, because the writer is called at boundaries and not from
the render path — which is also why a slow disk cannot stall a stream."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (ao--capture-wire
        (let* ((buf (ao--chat-on-model "qmodel-large" "QModel Large" "sid-cost"))
               (session (agent-org--session-for-buffer buf))
               (sent nil))
          (cl-letf (((symbol-function 'acp-send-request)
                     (lambda (&rest kw) (push kw sent)))
                    ((symbol-function 'acp-make-session-prompt-request)
                     (lambda (&rest a) (plist-get a :prompt))))
            ;; the fixture's own ready boundary already wrote once; count
            ;; the turn from here
            (ao--counting-writes
              (with-current-buffer buf
                (ao--type "cost me nothing")
                (agent-org-send))
              (dotimes (_ 20)
                (agent-org--on-notification
                 session (ao--update-notif
                          '((sessionUpdate . "agent_message_chunk")
                            (content . ((type . "text") (text . "chunk ")))))))
              (agent-org--on-notification
               session (ao--update-notif
                        '((sessionUpdate . "agent_thought_chunk")
                          (content . ((type . "text") (text . "think"))))))
              (funcall (plist-get (car sent) :on-success) nil)
              (should (= 2 ao--writes)))
          (kill-buffer buf)))))))

(ert-deftest test-agent-org-transcript-skips-an-unchanged-body ()
  "The same text is never written twice.
A boundary can fire with nothing new — a repeated title, a second ready
call — and the write is a whole-file `write-region', so the cheap guard is
to compare against what was last put there.  It also keeps the file's mtime
honest: an untouched transcript must not look like it was edited."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (let* ((pair (ao--make-test-session "unchanged"))
             (buf (car pair)))
        (agent-org-buffer-set-status buf :session-id "sid-same" :state 'ready)
        (agent-org-buffer-refresh-metadata buf)
        (ao--counting-writes
          (agent-org-buffer-transcribe buf)
          (should (= 1 ao--writes))
          (agent-org-buffer-transcribe buf)
          (should (= 1 ao--writes))
          ;; and one change is enough to make the next boundary real
          (agent-org-buffer-begin-exchange buf "a new turn")
          (agent-org-buffer-transcribe buf)
          (should (= 2 ao--writes)))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-transcript-force-rewrites-an-unchanged-body ()
  "FORCE ignores the two skips an ordinary boundary honours.
They exist to save a whole-file write — the unchanged-body cache and lite
mode — but a SYNC is not a boundary, it is the user asking the file to catch
up NOW, so both are bypassed.  The file is deleted under a warm cache to show
the cache check is skipped, then lite mode is set to show its gate is too.
`agent-org-transcribe' nil is NOT overridden (see the off test): FORCE asks
the mirror to catch up, not to override the decision to keep no files."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (let* ((pair (ao--make-test-session "force"))
             (buf (car pair))
             (file (expand-file-name "sid-force.org" temp-dir)))
        (agent-org-buffer-set-status buf :session-id "sid-force" :state 'ready)
        (agent-org-buffer-refresh-metadata buf)
        (agent-org-buffer-transcribe buf)        ; writes and warms the cache
        (should (file-exists-p file))
        ;; unchanged body, warm cache: an ordinary call skips the rewrite
        (delete-file file)
        (agent-org-buffer-transcribe buf)
        (should-not (file-exists-p file))
        ;; FORCE rewrites it even though nothing changed
        (agent-org-buffer-transcribe buf t)
        (should (file-exists-p file))
        ;; lite with an empty queue: an ordinary call writes nothing at all
        (delete-file file)
        (with-current-buffer buf (setq agent-org-buffer--lite 'on))
        (agent-org-buffer-transcribe buf)
        (should-not (file-exists-p file))
        ;; FORCE writes even in lite mode
        (agent-org-buffer-transcribe buf t)
        (should (file-exists-p file))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-transcript-sync-rewrites-the-file-with-the-current-rendering ()
  "`agent-org-transcript-sync' re-mirrors NOW, no turn required.
This is the feature's reason to exist: a status the CURRENT build renders but
that the file predates.  Change `:title' without touching a boundary, then
run the command — it refreshes the metadata and force-writes, so the file
carries the new title.  The metadata is NOT refreshed by hand first: that is
what proves the command itself does it."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (let* ((pair (ao--make-test-session "sync"))
             (buf (car pair)))
        (agent-org-buffer-set-status buf :session-id "sid-sync" :state 'ready
                                     :title "First")
        (agent-org-buffer-refresh-metadata buf)
        (agent-org-buffer-transcribe buf)
        (should (string-match-p "^#\\+TITLE: First$"
                                (ao--transcript-text temp-dir "sid-sync")))
        ;; the title changes with no turn and no boundary call
        (agent-org-buffer-set-status buf :title "Second")
        (with-current-buffer buf (agent-org-transcript-sync))
        (let ((text (ao--transcript-text temp-dir "sid-sync")))
          (should (string-match-p "^#\\+TITLE: Second$" text))
          (should-not (string-match-p "^#\\+TITLE: First$" text)))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-transcript-sync-prefix-covers-every-open-chat ()
  "A prefix arg makes sync iterate every live chat, not just this buffer.
Two sessions, both files deleted, ONE prefixed call from a buffer that is not
a chat at all, both files back — which also proves the `C-u' form reads the
registry rather than the current buffer."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (let (bufs)
        (dolist (sid '("sid-all-1" "sid-all-2"))
          (let* ((pair (ao--make-test-session sid))
                 (buf (car pair))
                 (file (expand-file-name (concat sid ".org") temp-dir)))
            (agent-org-buffer-set-status buf :session-id sid :state 'ready)
            (agent-org-buffer-refresh-metadata buf)
            (agent-org-buffer-transcribe buf)
            (should (file-exists-p file))
            (delete-file file)
            (push buf bufs)))
        (with-temp-buffer (agent-org-transcript-sync t))
        (dolist (sid '("sid-all-1" "sid-all-2"))
          (should (file-exists-p (expand-file-name (concat sid ".org") temp-dir))))
        (dolist (b bufs) (kill-buffer b))))))

(ert-deftest test-agent-org-transcript-sync-refuses-when-transcription-is-off ()
  "Sync says so instead of silently doing nothing when files are off.
`agent-org-transcribe' nil is the opt-out; FORCE overrides the cache and lite
skips, never this.  A silent success would read as \"the transcript updated\"
when no transcript exists to update."
  (ert-with-temp-directory temp-dir
    (let ((agent-org-transcribe nil)
          (agent-org-transcript-dir temp-dir))
      (let* ((pair (ao--make-test-session "off-sync"))
             (buf (car pair)))
        (agent-org-buffer-set-status buf :session-id "sid-nooff" :state 'ready)
        (should-error (with-current-buffer buf (agent-org-transcript-sync))
                      :type 'user-error)
        (should (null (ao--transcript-files temp-dir)))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-transcript-id-sterilized ()
  "A session id is agent text, and it never gets to choose where a file lands.
Qoder issues UUIDs and Goose issues timestamps, but the id arrives over the
wire and becomes a file name, so every separator becomes a dash:
\"../../etc/passwd\" writes INSIDE the transcript directory, not outside it.
Without this the writer is a path-traversal primitive handed to whatever
server the user pointed Emacs at."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (ao--capture-wire
        (let ((buf (ao--chat-on-model "qmodel-large" "QModel Large"
                                      "../../evil")))
          (should (= 1 (length (ao--transcript-files temp-dir))))
          (should-not (string-match-p "/" (car (ao--transcript-files temp-dir))))
          ;; nothing escaped the directory
          (should-not (file-exists-p (expand-file-name "evil.org"
                                                       (file-name-directory
                                                        (directory-file-name temp-dir)))))
          (kill-buffer buf))))))

(ert-deftest test-agent-org-transcript-dir-default-is-a-project-dot-directory ()
  "The default is the RELATIVE name `.agent-org', not a path under ~/.emacs.d.
User order: \"Transcripts should live under a project's .agent-org/.\"  A
chat's own directory is the one place its transcript is found without a
search, the same reason a project keeps its own README — and a relative
default is what makes it so, because `expand-file-name' resolves it against
the buffer's `default-directory', which is the session cwd.  An absolute
value is still honoured (see the test below), so one global pool is a
setting away."
  (should (equal agent-org-transcript-dir ".agent-org"))
  (should-not (file-name-absolute-p agent-org-transcript-dir)))

(ert-deftest test-agent-org-transcript-lands-in-the-chats-own-project ()
  "A chat of ~/proj writes ~/proj/.agent-org/<sid>.org.
The whole point of the relative default, so it is asserted against a real
directory rather than against a computed string: the file must be THERE,
under the project, after the handshake that names the session.  A project
keeps its own transcript the way it keeps its own README."
  (ert-with-temp-directory project
    (let ((agent-org-transcribe t)
          (agent-org-transcript-dir ".agent-org")
          (default-directory (file-name-as-directory project)))
      (ao--capture-wire
        (let ((buf (ao--chat-on-model "qmodel-large" "QModel Large"
                                      "sid-proj")))
          (let ((in-project (expand-file-name ".agent-org" project)))
            (should (file-directory-p in-project))
            (should (equal '("sid-proj.org") (ao--transcript-files in-project))))
          (kill-buffer buf))))))

(ert-deftest test-agent-org-two-projects-keep-their-own-transcripts ()
  "Two chats, two projects, two directories.
One pool named by id makes a transcript impossible to find without knowing
which chat produced it; the project directory is the index.  Both buffers
are Ready with the same model, so only the cwd distinguishes them."
  (ert-with-temp-directory proj-a
    (ert-with-temp-directory proj-b
      (let ((agent-org-transcribe t)
            (agent-org-transcript-dir ".agent-org"))
        (ao--capture-wire
          (let* ((default-directory (file-name-as-directory proj-a))
                 (buf-a (ao--chat-on-model "qmodel-large" "QModel Large" "sid-a"))
                 (default-directory (file-name-as-directory proj-b))
                 (buf-b (ao--chat-on-model "qmodel-large" "QModel Large" "sid-b")))
            (should (equal '("sid-a.org")
                           (ao--transcript-files (expand-file-name ".agent-org" proj-a))))
            (should (equal '("sid-b.org")
                           (ao--transcript-files (expand-file-name ".agent-org" proj-b))))
            (kill-buffer buf-a)
            (kill-buffer buf-b)))))))

(ert-deftest test-agent-org-transcript-honours-an-absolute-directory-option ()
  "An absolute setting is a global pool, and the code must not join it twice.
`(expand-file-name \"/srv/t\" \"/proj/\")' answers \"/srv/t\" — the property
this test pins, because the same line of code resolves both cases and the
one that reads like a bug (`why is a path being expanded?') is what makes a
relative setting work."
  (ert-with-temp-directory project
    (ert-with-temp-directory pool
      (let ((agent-org-transcribe t)
            (agent-org-transcript-dir (file-name-as-directory pool))
            (default-directory (file-name-as-directory project)))
        (ao--capture-wire
          (let ((buf (ao--chat-on-model "qmodel-large" "QModel Large" "sid-abs")))
            (should (equal '("sid-abs.org") (ao--transcript-files pool)))
            (should-not (file-exists-p (expand-file-name ".agent-org" project)))
            (kill-buffer buf)))))))

(ert-deftest test-agent-org-transcript-failure-never-breaks-a-turn ()
  "An unwritable directory is a note in the echo area, not a broken chat.
The transcript is a convenience; the conversation is the feature.  Here the
path is under a regular FILE, so no directory can be created at all and
every write fails — and the turn must still stream, close and go Ready
exactly as it would with transcription off."
  (ert-with-temp-directory temp-dir
    (let ((blocker (expand-file-name "blocker" temp-dir)))
      (write-region "not a directory\n" nil blocker)
      (ao--transcript-in (expand-file-name "transcripts" blocker)
        (ao--capture-wire
          (let* ((buf (ao--chat-on-model "qmodel-large" "QModel Large" "sid-fail"))
                 (session (agent-org--session-for-buffer buf))
                 (sent nil))
            (cl-letf (((symbol-function 'acp-send-request)
                       (lambda (&rest kw) (push kw sent)))
                      ((symbol-function 'acp-make-session-prompt-request)
                       (lambda (&rest a) (plist-get a :prompt))))
              (with-current-buffer buf
                (ao--type "still works")
                (agent-org-send)
                (agent-org-buffer-append-chunk buf "the answer arrived" session)
                (funcall (plist-get (car sent) :on-success) nil))
            (should-not (plist-get session :streaming))
            (with-current-buffer buf
              (should (eq 'ready (plist-get agent-org-buffer--status :state)))
              (should (string-match-p "the answer arrived" (buffer-string))))
            (kill-buffer buf))))))))

(ert-deftest test-agent-org-transcript-flushes-when-the-buffer-is-killed ()
  "Killing a chat mid-turn still puts that turn on disk.
The turn end is a boundary and a kill is not, so without the kill hook the
last answer of every session — the one the user stopped reading — would be
the one missing from the file.  `agent-org--forget-session' writes before it
releases the agent."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (ao--capture-wire
        (let* ((buf (ao--chat-on-model "qmodel-large" "QModel Large" "sid-kill"))
               (session (agent-org--session-for-buffer buf))
               (sent nil))
          (cl-letf (((symbol-function 'acp-send-request)
                     (lambda (&rest kw) (push kw sent)))
                    ((symbol-function 'acp-make-session-prompt-request)
                     (lambda (&rest a) (plist-get a :prompt))))
            (with-current-buffer buf
              (ao--type "interrupted chat")
              (agent-org-send)
              (agent-org-buffer-append-chunk buf "partial answer" session))
            ;; no on-success: the buffer dies with the turn still open
            (should-not (string-match-p "partial answer"
                                        (ao--transcript-text temp-dir "sid-kill")))
            (kill-buffer buf)
            (should (string-match-p "partial answer"
                                    (ao--transcript-text temp-dir "sid-kill")))
            (should-not (agent-org--session-for-buffer buf))))))))

;;;; Transcript to messages: the cross-agent parser (tracker #183)

;; The port of a conversation into ANOTHER agent's session file starts here:
;; the transcript must be confirmed synced, then read as plain messages.  Both
;; halves are pinned below against the real renderer, so no test hand-writes a
;; transcript shape the package does not actually produce.

(defun ao--transcript-path (dir session-id)
  "Where SESSION-ID's transcript lives in DIR.  Plumbing for the parser tests."
  (expand-file-name (agent-org-buffer--transcript-name session-id) dir))

(defmacro ao--transcript-in-headings (dir &rest body)
  "Run BODY transcribing into DIR in the activity style the USER ships with.
The suite pins `agent-org-activity-style' to `drawers' globally (see this
file's header) because most render fixtures were written against it, while
`headings' is the shipped default — and the only shape a transcript can be
parsed back out of, because it is the only one that gives an answer a `**
WROTE' part of its own.  A parser test that ran in `drawers' would be testing
the fallback documented in `agent-org-buffer--transcript-messages-parse'."
  (declare (indent 1))
  `(let ((agent-org-activity-style 'headings))
     (ao--transcript-in ,dir ,@body)))

(ert-deftest test-agent-org-transcript-synced-p-reads-the-file-not-the-cache ()
  "\"Is the transcript current?\" is a question about the FILE.
`agent-org-buffer--transcript-cache' is our memory of what we wrote, and it
stays truthful while a person edits the file behind our back — which is
exactly the state a cross-agent conversion must not silently build on.  So:
a forced mirror is synced, a hand-edited file is not, a missing file is not,
and a turn that is still streaming is not."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in-headings temp-dir
      (ao--capture-wire
        (let* ((sid "sid-sync")
               (buf (ao--chat-on-model "qmodel-large" "QModel Large" sid))
               (session (agent-org--session-for-buffer buf))
               (file (ao--transcript-path temp-dir sid)))
          ;; the mirror and the sync test must agree on ONE definition
          (with-current-buffer buf (agent-org-buffer-transcribe buf t))
          (should (agent-org-buffer-transcript-synced-p buf))
          ;; a person rewrote the file: our cache still says the old text
          (with-temp-file file (insert "someone else's transcript\n"))
          (should-not (agent-org-buffer-transcript-synced-p buf))
          ;; the forced re-mirror is what the convert command calls
          (with-current-buffer buf (agent-org-buffer-transcribe buf t))
          (should (agent-org-buffer-transcript-synced-p buf))
          ;; a turn mid-flight is on the page and not yet in the file
          (agent-org-buffer-append-chunk buf "still arriving" session)
          (should-not (agent-org-buffer-transcript-synced-p buf))
          (with-current-buffer buf (agent-org-buffer-transcribe buf t))
          (should (agent-org-buffer-transcript-synced-p buf))
          ;; and no file at all is \"not synced\", never an error
          (delete-file file)
          (should-not (agent-org-buffer-transcript-synced-p buf))
          (kill-buffer buf))))))

(ert-deftest test-agent-org-transcript-messages-are-prompts-then-answers ()
  "The parser answers the conversation, oldest first, one pair per exchange.
This is the contract the two session writers build on: alternating :role
\"user\"/:role \"assistant\" plists with :text, and nothing else — no tool
noise, no drawer furniture, no invented reply for a turn that said nothing."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in-headings temp-dir
      (ao--capture-wire
        (let* ((sid "sid-order")
               (buf (ao--chat-on-model "qmodel-large" "QModel Large" sid))
               (sent nil))
          (cl-letf (((symbol-function 'acp-send-request)
                     (lambda (&rest kw) (push kw sent)))
                    ((symbol-function 'acp-make-session-prompt-request)
                     (lambda (&rest a) (plist-get a :prompt))))
            (dolist (prompt '("first" "second" "third"))
              (with-current-buffer buf
                (ao--type prompt)
                (agent-org-send)
                (agent-org-buffer-append-chunk
                 buf (format "answer to %s" prompt)
                 (agent-org--session-for-buffer buf))
                (funcall (plist-get (car sent) :on-success) nil)))
            (should
             (equal '((:role "user" :text "first")
                      (:role "assistant" :text "answer to first")
                      (:role "user" :text "second")
                      (:role "assistant" :text "answer to second")
                      (:role "user" :text "third")
                      (:role "assistant" :text "answer to third"))
                    (agent-org-buffer-transcript-messages
                     (ao--transcript-path temp-dir sid))))
            (kill-buffer buf)))))))

(ert-deftest test-agent-org-transcript-messages-leave-out-thoughts-tools-and-furniture ()
  "Only what the agent SAID is a message.  A thinking run, a tool call and its
output are the agent's working, not its answer, and the transcript's own
furniture — property and logbook drawers, the metadata block, the queue
block — is not conversation at all.  A queued prompt most of all: it was
never sent, so it belongs to no message until it is."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in-headings temp-dir
      (ao--capture-wire
        (let* ((sid "sid-clean")
               (buf (ao--chat-on-model "qmodel-large" "QModel Large" sid))
               (session (agent-org--session-for-buffer buf))
               (sent nil))
          (cl-letf (((symbol-function 'acp-send-request)
                     (lambda (&rest kw) (push kw sent)))
                    ((symbol-function 'acp-make-session-prompt-request)
                     (lambda (&rest a) (plist-get a :prompt))))
            (with-current-buffer buf
              (ao--type "explain the plan")
              (agent-org-send))
            (agent-org--on-notification
             session (ao--update-notif
                      '((sessionUpdate . "agent_thought_chunk")
                        (content . ((type . "text") (text . "private reasoning"))))))
            (agent-org--on-notification
             session (ao--update-notif
                      '((sessionUpdate . "agent_message_chunk")
                        (content . ((type . "text") (text . "the plan is short"))))))
            (agent-org--on-notification
             session (ao--update-notif
                      `((sessionUpdate . "tool_call_update")
                        (toolCallId . "t1") (title . "ls -R") (status . "completed")
                        ,@(ao--tool-text-block "secrets.org"))))
            (funcall (plist-get (car sent) :on-success) nil)
            (agent-org--queue-enqueue session buf "a prompt still waiting")
            (let ((messages (agent-org-buffer-transcript-messages
                             (ao--transcript-path temp-dir sid))))
              (should (equal '((:role "user" :text "explain the plan")
                               (:role "assistant" :text "the plan is short"))
                             messages))
              ;; and the excluded text is really in the file it skipped
              (let ((text (ao--transcript-text temp-dir sid)))
                (dolist (needle '("private reasoning" "ls -R" "secrets.org"
                                  "a prompt still waiting" ":LOGBOOK:" "RESPONSE:"))
                  (should (string-match-p (regexp-quote needle) text))))
              (kill-buffer buf))))))))

(ert-deftest test-agent-org-transcript-messages-restore-a-multi-line-prompt ()
  "A question that spanned lines comes back spanning lines.
The first line became the heading and the rest sit under it, so the parser
must put them back in order — and a blank line the USER typed (a paragraph
break) must survive the one blank line the renderer always leaves above the
continuation."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in-headings temp-dir
      (ao--capture-wire
        (let* ((sid "sid-lines")
               (buf (ao--chat-on-model "qmodel-large" "QModel Large" sid))
               (sent nil))
          (cl-letf (((symbol-function 'acp-send-request)
                     (lambda (&rest kw) (push kw sent)))
                    ((symbol-function 'acp-make-session-prompt-request)
                     (lambda (&rest a) (plist-get a :prompt))))
            (with-current-buffer buf
              (ao--type "the summary\nfirst paragraph\n\nsecond paragraph")
              (agent-org-send)
              (agent-org-buffer-append-chunk
               buf "one\ntwo" (agent-org--session-for-buffer buf))
              (funcall (plist-get (car sent) :on-success) nil))
            (should
             (equal '((:role "user"
                      :text "the summary\nfirst paragraph\n\nsecond paragraph")
                      (:role "assistant" :text "one\ntwo"))
                    (agent-org-buffer-transcript-messages
                     (ao--transcript-path temp-dir sid))))
            (kill-buffer buf)))))))

(ert-deftest test-agent-org-transcript-messages-invent-nothing-from-the-prompt-box ()
  "The type-ahead box is an input control and never a message.
Its heading is `* PROMPT' with no text of its own, and a draft under it is
the user's work in progress — not sent, not answered.  A conversion that
invented a message from it would resend a half-typed thought to the next
agent as if it had already been asked."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in-headings temp-dir
      (ao--capture-wire
        (let* ((sid "sid-box")
               (buf (ao--chat-on-model "qmodel-large" "QModel Large" sid))
               (sent nil))
          (cl-letf (((symbol-function 'acp-send-request)
                     (lambda (&rest kw) (push kw sent)))
                    ((symbol-function 'acp-make-session-prompt-request)
                     (lambda (&rest a) (plist-get a :prompt))))
            (with-current-buffer buf
              (ao--type "asked and answered")
              (agent-org-send)
              (agent-org-buffer-append-chunk
               buf "the reply" (agent-org--session-for-buffer buf))
              (funcall (plist-get (car sent) :on-success) nil)
              (ao--type "half a thought, still typing"))
            (with-current-buffer buf (agent-org-buffer-transcribe buf t))
            (should (equal '((:role "user" :text "asked and answered")
                             (:role "assistant" :text "the reply"))
                           (agent-org-buffer-transcript-messages
                            (ao--transcript-path temp-dir sid))))
            (kill-buffer buf)))))))

(ert-deftest test-agent-org-transcript-headline-reads-only-our-keywords ()
  "A keyword is stripped only when this package could have written it.
`* RESPONDED do it' is an exchange; `* auth' and `* IMPORTANT note' are the
user's own headings whose first word is part of the question, and a bare
`* PROMPT' is the box with no text.  The lists are read positionally, never
through `org-element', so a transcript parsed under built-in Org 9.7 and ELPA
Org 9.8 answers the same (AGENTS.md: the version-skew trap)."
  (should (equal '(1 "RESPONDED" "do it")
                 (agent-org-buffer--transcript-headline "* RESPONDED do it")))
  (should (equal '(1 nil "auth")
                 (agent-org-buffer--transcript-headline "* auth")))
  (should (equal '(1 nil "IMPORTANT note")
                 (agent-org-buffer--transcript-headline "* IMPORTANT note")))
  (should (equal '(2 "WROTE" "QModel Large")
                 (agent-org-buffer--transcript-headline "** WROTE QModel Large")))
  (should (equal '(1 "PROMPT" "")
                 (agent-org-buffer--transcript-headline "* PROMPT")))
  (should (equal '(1 "PROMPT" "do it later")
                 (agent-org-buffer--transcript-headline "* PROMPT do it later")))
  (should-not (agent-org-buffer--transcript-headline " first line of an answer"))
  (should-not (agent-org-buffer--transcript-headline "not a headline"))
  ;; classification: exchange, queue, or nothing
  (should (eq 'exchange
              (agent-org-buffer--transcript-entry-state "RESPONDED")))
  (should (eq 'queue (agent-org-buffer--transcript-entry-state "NEXT")))
  (should (eq 'queue (agent-org-buffer--transcript-entry-state "WAIT")))
  (should-not (agent-org-buffer--transcript-entry-state "PROMPT"))
  (should-not (agent-org-buffer--transcript-entry-state nil))
  (should (eq 'answer (agent-org-buffer--transcript-part-kind "WRITING")))
  (should (eq 'answer (agent-org-buffer--transcript-part-kind "WROTE")))
  (should (eq 'skip (agent-org-buffer--transcript-part-kind "THOUGHT")))
  (should (eq 'skip (agent-org-buffer--transcript-part-kind "EXECUTED"))))

;;;; Wire traffic

(defun ao--client-for (session command)
  "Give SESSION a mock client spawned for COMMAND, as `agent-org--open-session' would.
`ao--make-test-session' leaves `:client' nil — most tests never send
anything — so a test about the client's own entourage (its traffic buffer)
installs one after the fact."
  (let ((client (acp-make-client :command command :command-params '("acp"))))
    (setf (plist-get session :client) client)
    client))

(ert-deftest test-agent-org-show-traffic-demands-a-chat ()
  "M-x agent-org-show-traffic in a buffer with no agent is a refusal.
The alternative — an empty log buffer — reads as \"the agent sent
nothing\", which is a claim about the wire and would be false: no wire
belongs to that buffer at all."
  (with-temp-buffer
    (should-error (agent-org-show-traffic) :type 'user-error)))

(ert-deftest test-agent-org-show-traffic-needs-a-live-client ()
  "A chat whose agent is gone has no log to open.
`:client' is nil for a session that never finished spawning and for one
released by `agent-org--kill-session', and the buffer outlives both — the
command must say so rather than conjure a buffer for a client that no
longer exists."
  (let* ((pair (ao--make-test-session "noclient"))
         (buf (car pair)))
    (should-not (agent-org--traffic-buffer (cdr pair)))
    (should-error (agent-org-show-traffic buf) :type 'user-error)
    (kill-buffer buf)))

(ert-deftest test-agent-org-show-traffic-names-the-switch-when-empty ()
  "An empty log says why it is empty, because the cause is a setting.
acp consults `acp-logging-enabled' per message, so a chat opened before
logging was on keeps answering normally while its log stays at zero
bytes — the reader must be told to turn `agent-org-log-traffic' on and
restart, not left to conclude the agent is silent."
  (let ((acp-logging-enabled nil)
        (agent-org-log-traffic nil))
    (let* ((pair (ao--make-test-session "quiet"))
           (buf (car pair)))
      (ao--client-for (cdr pair) "quiet-agent")
      (let ((msg (condition-case err
                     (progn (agent-org-show-traffic buf) nil)
                   (user-error (error-message-string err)))))
        (should (string-match-p "agent-org-log-traffic" msg)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-show-traffic-opens-this-chats-log ()
  "The command lands in the traffic buffer belonging to THIS chat.
One buffer per client, named for its command and instance count; a turn
logged on another chat's client must not appear here, or the reader is
checking a wire they did not ask about."
  (let ((acp-logging-enabled t))
    (let* ((pair (ao--make-test-session "logged"))
           (buf (car pair))
           (client (ao--client-for (cdr pair) "logged-agent")))
      (with-current-buffer (acp-traffic-buffer :client client)
        (let ((inhibit-read-only t))
          (insert "12:00:00.000 → request      session/prompt\n")))
      (agent-org-show-traffic buf)
      (should (eq (current-buffer) (acp-traffic-buffer :client client)))
      (should (search-forward "session/prompt" nil t))
      (kill-buffer buf))))

;;;; Queued prompts: on disk, and back on resume

(defmacro ao--wire-prompt-texts (&rest body)
  "Run BODY with `acp-make-session-prompt-request' building a real-shaped request.
`tests/acp-mock.el' answers NIL for it, and `ao--capture-wire' keys its
capture on the request's =:method= — so a drained prompt would be captured
under NIL and be invisible to `ao--sent-get'.  This is the shape the real
acp package sends: a method plus =:params= carrying the prompt blocks."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'acp-make-session-prompt-request)
              (lambda (&rest kw)
                `((:method . "session/prompt")
                  (:params . ((sessionId . ,(plist-get kw :session-id))
                              (prompt . ,(plist-get kw :prompt))))))))
     ,@body))

(defun ao--sent-prompt-texts ()
  "The text of every `session/prompt' captured in `ao--sent', oldest first.
The capture keys on the request's =:method=, which is why the prompt
request needs `ao--wire-prompt-texts': the mock's builder answers NIL, and
a NIL request would be captured under NIL — a drained prompt the test
could not see."
  (mapcar (lambda (entry)
            (let ((params (map-elt (plist-get (cdr entry) :request) ':params)))
              (map-elt (car (map-elt params 'prompt)) 'text)))
          (reverse (seq-filter (lambda (entry)
                                 (equal (car entry) "session/prompt"))
                               ao--sent))))

(ert-deftest test-agent-org-queue-has-no-drawer-in-the-metadata-block ()
  "The metadata block renders no `:QUEUE:' drawer, whatever the queue holds.
Waiting prompts are `* TODO' headlines at the bottom of the chat
(`agent-org-buffer-render-queue'), and the transcript mirrors that block.  A
second rendering of the same list is two formats that can drift apart and two
places for a drained prompt to survive, which is how a resume re-sends a turn
the agent already answered.  Asserted both ways: the block says nothing about
the queue, and the headlines say everything."
  (let ((rendered (agent-org-buffer--render-metadata
                   (list :provider "Qoder" :session-id "s-meta"
                         :queued (list "first" "second")))))
    ;; anchored on the drawer's own shape: a bare "QUEUE" would also match the
    ;; id line, which is how this assertion first failed for the wrong reason
    (should-not (string-match-p "^:QUEUE:" rendered))
    (should (equal '("first" "second")
                   (agent-org-buffer--queue-parse-text
                    (agent-org-buffer-render-queue '("first" "second")))))))

(ert-deftest test-agent-org-queue-headline-round-trip-is-lossless ()
  "A prompt written as queue headlines reads back as itself.
The region IS the record now, so its renderer and its reader have to cover
every case the old one-escaped-line-per-prompt escaper did: a multi-line
draft, an inner blank line, a prompt that starts with `*', a bare `:END:', a
backslash.  One thing is NOT preserved, and the test says so rather than
hiding it: whitespace padded around the WHOLE prompt, which a headline cannot
carry — `agent-org-send' strips it before queueing anyway.  Two prompts render
as two entries and stay two prompts, oldest first."
  (dolist (text (list "one line"
                      "two\nlines"
                      "a backslash \\ and a newline\nhere"
                      ":END:\n- not a drawer end"
                      "* starts like a headline\nsecond line"
                      "inner\n\nblank line"))
    (should (equal (list text)
                   (agent-org-buffer--queue-parse-text
                    (agent-org-buffer-render-queue (list text))))))
  ;; the slot a user is about to type in renders as no entry and parses as nil
  (should-not (agent-org-buffer--queue-parse-text
               (agent-org-buffer-render-queue '("")))))

(ert-deftest test-agent-org-metadata-drawer-arrives-folded-and-stays-opened ()
  "Every remaining metadata drawer is reference, so there is ONE fold default.
The split existed because QUEUE held the user's own work and had to be visible
the moment it appeared; the queue is headlines in the chat now and the drawer
is gone, so what is left is what the agent can be asked for again — folded,
and a TAB costs a look.  What still governs is the user: open COMMANDS by hand,
change the status, and it stays open
(`agent-org-buffer-refresh-metadata' remembers per name)."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel-large" "QModel Large" "sid-fold")))
      (with-current-buffer buf
        (agent-org-buffer-set-status
         buf :commands (list `((name . "help") (description . "show help"))))
        (agent-org-buffer-refresh-metadata buf)
        (should (invisible-p
                 (save-excursion (goto-char (point-min))
                                 (re-search-forward "^/help")
                                 (point)))))
      ;; open it by hand, then change the block: the user's choice survives
      (with-current-buffer buf
        (save-excursion
          (goto-char (point-min))
          (re-search-forward "^:COMMANDS:")
          (org-fold-hide-drawer-toggle))
        (agent-org-buffer-set-status
         buf :config (list `((name . "Model") (currentValue . "qmodel-large"))))
        (agent-org-buffer-refresh-metadata buf)
        (should-not (invisible-p
                     (save-excursion (goto-char (point-min))
                                     (re-search-forward "^/help")
                                     (point)))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-transcript-queue-reads-its-own-block-only ()
  "The reader takes the mirrored queue block, and no conversation headline.
A transcript is ONE file holding both kinds of `* ' line, and a `* TODO' that
belongs to the conversation is not a waiting prompt — reading it would enqueue
a turn the user never queued and spend tokens on it at the next resume.  So the
block is found by the preamble the renderer writes, which no conversation line
is, and only what follows the LAST such preamble counts."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (let ((buf (agent-org-buffer-create "qr")))
        (with-current-buffer buf
          (agent-org-buffer-set-status buf :session-id "sid-qr")
          (let ((file (agent-org-buffer--transcript-file "sid-qr")))
            (make-directory (file-name-directory file) t)
            (with-temp-buffer
              (insert "* PROMPT\n\nWhat the agent was really asked.\n\n"
                      "* TODO a heading inside the conversation\n\n"
                      agent-org-buffer--queue-note-text
                      "* TODO keep me\n"
                      "* TODO keep too\n second line\n")
              (write-region nil nil file nil 'silent))
            (should (equal '("keep me" "keep too\nsecond line")
                           (agent-org-buffer-transcript-queue "sid-qr")))))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-queued-prompt-reaches-the-file-mid-turn ()
  "Queuing writes the transcript: a quit must not swallow the prompt.
The mirror is otherwise a turn-boundary writer, and a queued prompt that
never reaches a boundary — the user quits Emacs, or the agent dies — is
exactly the text the user would most want back.  So the queue's own
mutations are boundaries of their own.
This is also the test that pins the READ ordering: the file on disk is the
only copy of the queue, because the resumed buffer has none."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (ao--capture-wire
        (let* ((buf (ao--chat-on-model "qmodel-large" "QModel Large" "sid-mid"))
               (session (agent-org--session-for-buffer buf))
               (sent nil))
          (cl-letf (((symbol-function 'acp-send-request)
                     (lambda (&rest kw) (push kw sent)))
                    ((symbol-function 'acp-make-session-prompt-request)
                     (lambda (&rest a) (plist-get a :prompt))))
            (with-current-buffer buf
              (ao--type "turn one")
              (agent-org-send))                       ; streaming, no answer yet
            (with-current-buffer buf
              (ao--type "wait for me\nplease")
              (agent-org-send))                       ; queues it
            (should (equal '("wait for me\nplease")
                           (plist-get session :pending-prompts)))
            (let ((text (ao--transcript-text temp-dir "sid-mid")))
              (should (string-match-p "^\\* NEXT wait for me\n please$"
                                      text))
              ;; read back the way resume does, from the file alone
              (should (equal (list "wait for me\nplease")
                             (with-current-buffer buf
                               (agent-org-buffer-transcript-queue "sid-mid"))))))
          (kill-buffer buf))))))

(ert-deftest test-agent-org-queue-block-clears-when-the-prompt-is-sent ()
  "A drained prompt leaves the transcript's queue block, so resume never
sends it twice.
The file is the queue's only durable copy: if a sent prompt stayed
listed, the next resume would re-send a turn the agent already answered.
Draining therefore re-mirrors, and an empty queue leaves no block at all
rather than a preamble with nothing under it."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (ao--capture-wire
        (let* ((buf (ao--chat-on-model "qmodel-large" "QModel Large" "sid-drain"))
               (session (agent-org--session-for-buffer buf))
               (sent nil))
          (cl-letf (((symbol-function 'acp-send-request)
                     (lambda (&rest kw) (push kw sent)))
                    ((symbol-function 'acp-make-session-prompt-request)
                     (lambda (&rest a) (plist-get a :prompt))))
            (with-current-buffer buf
              (ao--type "turn one")
              (agent-org-send))
            (with-current-buffer buf
              (ao--type "queued")
              (agent-org-send))
            ;; turn one answers: "queued" goes on the wire and the queue empties
            (funcall (plist-get (car (last sent)) :on-success) nil)
            (should (null (plist-get session :pending-prompts)))
            (with-current-buffer buf
              ;; the drained prompt is conversation now: headed with the
              ;; streaming state word, and gone from the region holding it
              (should (string-match-p "^\\* RESPONDING queued$" (buffer-string)))
              (should-not (string-match-p
                           (regexp-quote agent-org-buffer--queue-note-text)
                           (buffer-string))))
            (should-not (string-match-p
                         (regexp-quote agent-org-buffer--queue-note-text)
                         (ao--transcript-text temp-dir "sid-drain")))
            (should-not (with-current-buffer buf
                          (agent-org-buffer-transcript-queue "sid-drain"))))
          (kill-buffer buf))))))

(ert-deftest test-agent-org-resume-reloads-the-queued-prompts-without-sending ()
  "Resume brings back what the last session had queued, in order, UNSent.
User order: \"Save queued prompts to transcripts and reload them on
resume.\"  The prompts were never sent, so the agent's own replay cannot
contain them — only our transcript can.  Restoring them and immediately
firing the first on the wire would spend tokens the user has not, on
seeing the restored list, chosen to re-approve (task #104): the flush
point RESTORES the whole queue into `:pending-prompts' and repaints the
region and drawer, and sends nothing.  The user then drains by applying
the region, or the first real turn end does."
  (ert-with-temp-directory temp-dir
    (with-temp-file
        (expand-file-name (agent-org-buffer--transcript-name "sid-rest")
                          temp-dir)
      (insert ":PROPERTIES:\n:ID: sid-rest\n:END:\n"
              ;; an OLD transcript, retired `#+TODO:' vocabulary and all: the
              ;; file on disk is whatever a previous session wrote, and resume
              ;; must read its queue without caring
              "#+TITLE: Before\n#+TODO: TODO DOING | DONE CANCELLED\n\n"
              agent-org-buffer--queue-note-text
              "* NEXT finish the tests\n"
              "* WAIT then run org-check\n"))
    ;; Transcription is ON deliberately: `agent-org--session-ready' mirrors
    ;; the freshly replayed buffer — which has no queue in it — over this
    ;; file, so the test only passes if the queue was read BEFORE that write.
    (ao--transcript-in temp-dir
      (ao--capture-wire
        (let* ((buf (agent-org-resume-session 'qoder "sid-rest"))
               (session (agent-org--session-for-buffer buf)))
          (ao--drive "initialize" ao--fake-init-resp)
          (ao--drive "session/load" '((sessionId . "sid-rest")))
          (ao--wire-prompt-texts
            (ao--settle))
          ;; Nothing fires on arrival: the queue is restored for review.
          (should (null (ao--sent-prompt-texts)))
          ;; BOTH prompts come back, in the order they were parked.
          (should (equal '("finish the tests" "then run org-check")
                         (plist-get session :pending-prompts)))
          (with-current-buffer buf
            ;; each restored prompt shows as a positional queue entry, in
            ;; order: the head says NEXT, the one behind it says WAIT
            (should (string-match-p "^\\* NEXT finish the tests$"
                                    (buffer-string)))
            (should (string-match-p "^\\* WAIT then run org-check$"
                                    (buffer-string)))
            ;; and the buffer's own queue mirror carries both.  The header
            ;; count is deliberately NOT asserted: " (N queued)" only rides a
            ;; `:message' while streaming/loading, and a resumed session is
            ;; Ready, where the state label hides a bare message (the count
            ;; would show once the user applies the region and a turn runs).
            (should (equal '("finish the tests" "then run org-check")
                           (plist-get (buffer-local-value 'agent-org-buffer--status
                                                          buf)
                                      :queued))))
          (kill-buffer buf))))))

(ert-deftest test-agent-org-resume-without-a-queue-block-sends-nothing ()
  "A transcript with no queue block restores an empty queue: no phantom turn.
Most resumes have nothing waiting, and one invented from a stale file
would spend tokens the user never asked for.  Absent block, absent
`session/prompt'."
  (ert-with-temp-directory temp-dir
    (let ((agent-org-transcript-dir temp-dir)
          (agent-org-transcribe nil))
      (with-temp-file
          (expand-file-name (agent-org-buffer--transcript-name "sid-none")
                            temp-dir)
        (insert ":PROPERTIES:\n:ID: sid-none\n:END:\n#+TITLE: Quiet\n"))
      (ao--capture-wire
        (let* ((buf (agent-org-resume-session 'qoder "sid-none"))
               (session (agent-org--session-for-buffer buf)))
          (ao--drive "initialize" ao--fake-init-resp)
          (ao--drive "session/load" '((sessionId . "sid-none")))
          (ao--wire-prompt-texts (ao--settle))
          (should (null (plist-get session :pending-prompts)))
          (should (null (ao--sent-prompt-texts)))
          (should-not (plist-get (buffer-local-value 'agent-org-buffer--status buf)
                                 :queued))
          (kill-buffer buf))))))

(ert-deftest test-agent-org-resume-without-a-transcript-file-just-loads ()
  "No file, no error: the transcript is a convenience, not a dependency.
A session resumed with `agent-org-transcribe' off, or one that predates
the feature, has nothing to read — and a resume that failed on a missing
file would be a regression for every user who never queued a prompt."
  (ert-with-temp-directory temp-dir
    (let ((agent-org-transcript-dir
           (expand-file-name "nope/" temp-dir))
          (agent-org-transcribe nil))
      (ao--capture-wire
        (let ((buf (agent-org-resume-session 'qoder "sid-absent")))
          (ao--drive "initialize" ao--fake-init-resp)
          (ao--drive "session/load" '((sessionId . "sid-absent")))
          (ao--wire-prompt-texts (ao--settle))
          (should (equal 'ready
                         (plist-get (buffer-local-value
                                     'agent-org-buffer--status buf)
                                    :state)))
          (kill-buffer buf))))))

;;;; Markdown -> Org in the reply body

(defun ao--md (line &optional src-p)
  "Org line that `agent-org-buffer--markdown-line' makes of LINE.
The SRC-P return value is dropped: these tests ask what a reader sees."
  (car (agent-org-buffer--markdown-line line src-p)))

(ert-deftest test-agent-org-markdown-headings-become-bold-inside-a-quote ()
  "A Markdown ATX heading cannot be an Org headline inside the reply's quote.
The answer now lives in a `#+begin_quote' block and a headline of ANY level
ends one — the parser stops the block at the star and everything the agent
said after it leaves its own answer.  It cannot be shifted a level down
either, since level 1 is the conversation's own level (the exchange heading).
So the words are kept and the size is lost: `# Title' -> `*Title*'.  `#' at
column 0 is an Org COMMENT, so doing nothing would hide the heading from every
export instead."
  (should (equal "*Ship it*" (ao--md "# Ship it")))
  (should (equal "*Plan*" (ao--md "## Plan")))
  (should (equal "*Deep*" (ao--md "###### Deep")))
  ;; a heading with inline markup keeps it, converted inside the bold
  (should (equal "*see =x=*" (ao--md "# see `x`")))
  ;; no space after the hashes is not a markdown heading (and `#' stays a comment)
  (should (equal "#hashtag" (ao--md "#hashtag")))
  ;; an indented heading is a code-ish line, not a heading in either syntax
  (should (equal "  ## not a heading" (ao--md "  ## not a heading"))))

(ert-deftest test-agent-org-markdown-star-bullets-become-dashes ()
  "`* item' is a level-1 HEADLINE in Org, not a bullet.
Measured with `org-element-parse-buffer': two `* item' lines report two
headlines and no list -- so an agent's ordinary bullet list would shred the
turn around it.  `- ' is the bullet both syntaxes agree on."
  (should (equal "- item" (ao--md "* item")))
  (should (equal "- a\n- b" (concat (ao--md "* a") "\n" (ao--md "* b"))))
  (should (equal "  - nested" (ao--md "  * nested")))
  ;; already-Org bullets, ordered lists and checkboxes are left alone
  (should (equal "- keep" (ao--md "- keep")))
  (should (equal "+ keep" (ao--md "+ keep")))
  (should (equal "1. keep" (ao--md "1. keep")))
  (should (equal "- [ ] todo" (ao--md "- [ ] todo"))))

(ert-deftest test-agent-org-markdown-emphasis-becomes-org-markup ()
  "One star means italic in Org and bold in Markdown, so `**' must go first.
The pass is single-scan, not two rewrites: converting `**b**' to `*b*' and
then running the `*i*' rule over the RESULT would italicise the bold.
Backquoted code becomes `=' verbatim (Org's own inline-code marker), and
underscores are never touched -- `foo_bar_baz' is an identifier, and a
second pass over it would print it as emphasis."
  (should (equal "*bold* text" (ao--md "**bold** text")))
  (should (equal "/emph/ here" (ao--md "*emph* here")))
  (should (equal "a =b= c" (ao--md "a `b` c")))
  (should (equal "*a* /b/ =c=" (ao--md "**a** *b* `c`")))
  (should (equal "snake_case_stays" (ao--md "snake_case_stays")))
  (should (equal "** not emphasis" (ao--md "** not emphasis"))))

(ert-deftest test-agent-org-markdown-link-becomes-org-link ()
  "Brackets first, description second: `[[URL][TEXT]]'.
Org's own syntax, in the order the org-syntax reference pins -- a Markdown
link left alone exports as text plus a bare autolink."
  (should (equal "[[https://x.org][docs]]" (ao--md "[docs](https://x.org)")))
  (should (equal "see [[file:a.el][a]] now" (ao--md "see [a](file:a.el) now"))))

(ert-deftest test-agent-org-markdown-fence-becomes-a-src-block ()
  "The fence line and its SRC-P flag travel together.
A fenced block is the one place where markdown markup is TEXT, so the state
flag decides which lines get converted at all -- and inside the block the
`#' and `*' rules must not fire (an Org comment marker or a headline in the
middle of a code sample would corrupt the sample).  `#+end_src' is emitted
for the closing fence, whatever language the opening one named."
  (let ((open (agent-org-buffer--markdown-line "```sh" nil)))
    (should (equal "#+begin_src sh" (car open)))
    (should (equal t (cdr open)))
    (let ((body (agent-org-buffer--markdown-line "# a shell comment" (cdr open))))
      (should (equal "# a shell comment" (car body)))
      (should (equal t (cdr body))))
    (let ((close (agent-org-buffer--markdown-line "```" (cdr open))))
      (should (equal "#+end_src" (car close)))
      (should (equal nil (cdr close))))))

(ert-deftest test-agent-org-markdown-table-rule-becomes-org-columns ()
  "Markdown's alignment rule is not Org's separator row.
Measured with `org-export-string-as': `|---|---|' after a header does give a
`thead', but `|:--|:-:|--:|' does not -- the table loses its header and the
rule exports as a data row (`--:' becomes an em-dash).  So every rule line
becomes Org's own writer shape `|---+---|', which has no colons to misread."
  (should (equal "|---+---|" (ao--md "|---|---|")))
  (should (equal "|---+---+---|" (ao--md "|:--|:-:|--:|")))
  (should (equal "| a | b |" (ao--md "| a | b |"))))

(ert-deftest test-agent-org-markdown-horizontal-rule-stays-inert ()
  "`---' under a paragraph is a HEADLINE in Org.
Org reads `Some text' + `---' as one level-2 heading, so markdown's
divider would swallow the sentence above it.  One space of indent takes
that reading away (a headline must start at column 0) and still reads as a
divider in the buffer."
  (should (equal " ---" (ao--md "---")))
  (should (equal " ***" (ao--md "***")))
  (should (equal " -----  " (ao--md "-----  "))))

(ert-deftest test-agent-org-markdown-conversion-off-leaves-text-verbatim ()
  "The switch is the way out: nil and the agent's markup bytes land as sent.
Verbatim is a rendering sentence, not a licence to break the exchange, so the
ONE structural guard still applies: a `*' at column 0 is a headline and would
end the answer's own exchange, so `* item' takes a space.  But a `#' line is
neither a headline nor a drawer keyword, so with the quote block gone it is
left flush — the agent's `#' is never rewritten to a bold and its stars on a
non-headline line survive untouched."
  (let ((agent-org-convert-markdown nil)
        (buf (agent-org-buffer-create "mdoff")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-chunk buf "# Title\n* item\n" nil)
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (string-match-p "^# Title$" text))
      (should (string-match-p "^ \\* item$" text)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-markdown-streaming-writes-every-line-once ()
  "A finished line is appended exactly once; the arriving line is held.
The earlier shape rewrote a PROVISIONAL last line on every chunk, so a partial
`**bold' sat on screen and the next chunk deleted and re-inserted it.  That is
the back-and-forth the user rejected (\"I can't go back and forth to read what
the agent said\"): append-only means nothing already written ever moves, which
is only possible at LINE granularity.  So the still-arriving line is kept in
`--md-fragment' and converted once when its newline lands — `**bold' split
across two chunks still converts, because the JOINED line is what is converted.
Nothing is written twice."
  (let ((buf (agent-org-buffer-create "mdsplit")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-chunk buf "say **bold" nil)
    (with-current-buffer buf
      ;; still arriving: no newline yet, so the line is held, not half-shown
      (should-not (string-match-p "bold" (buffer-string))))
    (agent-org-buffer-append-chunk buf "** alpha\n" nil)
    (with-current-buffer buf
      (should (string-match-p "^say \\*bold\\* alpha$" (buffer-string)))
      (should-not (string-match-p "\\*\\*bold\\*\\*" (buffer-string)))
      ;; APPENDED once, never rewritten: exactly one copy of each word
      (should (equal 1 (ao--count-substrings "say")))
      (should (equal 1 (ao--count-substrings "alpha"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-markdown-two-emphasis-runs-terminate ()
  "A line with TWO markup runs converts and does not hang the scan.
The helpers read the global match data after calling `string-match' themselves,
which is how `**bold** *emph*' made `agent-org-buffer--md-inline' advance to a
position BEHIND the match it had just consumed and rescan it forever.  Asserted
as a conversion result, because the bug's other symptom was an Emacs that never
came back."
  (should (equal "*bold* /emph/ done"
                 (ao--md "**bold** *emph* done")))
  (should (equal "*a* b *c*" (ao--md "**a** b **c**")))
  ;; and arithmetic stars still survive the scan whole
  (should (equal "2*3*4 plus 5*6*7" (ao--md "2*3*4 plus 5*6*7"))))

(ert-deftest test-agent-org-markdown-turn-end-flushes-the-last-line ()
  "Nothing may be held when the turn closes, and an open fence must close.
The final line of a reply usually arrives with no trailing newline, so the
line-granular converter is still holding it; the turn boundary must flush that
fragment or the last line is lost.  And a `#+begin_src' left open swallows
everything after it in the buffer AND in the transcript, which is the one
corruption this feature must never cause."
  (let ((buf (agent-org-buffer-create "mdflush")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-chunk buf "## Tail" nil)
    (with-current-buffer buf
      ;; still arriving: `## Tail' has no newline, so it is not in the body yet
      (should-not (string-match-p "Tail" (buffer-string))))
    (agent-org-buffer-end-agent-turn buf)
    ;; `##' is a markdown heading, which in a reply becomes the bold `*Tail*'
    ;; (a column-0 headline would end the exchange).  `*Tail*' has no space
    ;; after the star, so it is emphasis, not a headline: it stays flush.
    (should (string-match-p "^\\*Tail\\*$"
                            (with-current-buffer buf (buffer-string))))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-chunk buf "```sh\nls" nil)
    (agent-org-buffer-end-agent-turn buf)
    (let ((text (with-current-buffer buf (buffer-string))))
      ;; `\\+' because in an Emacs regexp `+' is an interval operator, so
      ;; "^#\\+begin" asks for one-or-more hashes and never matches the keyword.
      ;; The fence lines are flush: a `#+begin_src' needs column 0 to open a
      ;; real source block (an indent would make it a paragraph), and a code
      ;; sample must keep its own `#' and `*' lines verbatim.
      (should (string-match-p "^#\\+begin_src sh$" text))
      (should (string-match-p "^#\\+end_src$" text))
      (with-current-buffer buf
        (should (org-element-map (org-element-parse-buffer) 'src-block
                  (lambda (e) t) nil 'first-match))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-markdown-chunks-after-a-newline-still-write ()
  "A chunk that ENDS a line must not leave the converter holding a dead marker.
The line a chunk completes is the last thing the provisional region held, so
the next chunk looks for its marker to rewrite it -- and a marker detached with
`set-marker' but still stored in the variable answers `markerp' t and
`marker-position' nil, which reaches `goto-char' as nil.  Reproduced by feeding
three chunks in order, because two is not enough to hit it: the crash happens on
the chunk AFTER the one that ended a line."
  (let ((buf (agent-org-buffer-create "mdthree")))
    (agent-org-buffer-start-agent-turn buf nil)
    (dolist (chunk (list "first " "line\nsecond " "line\nthird"))
      (agent-org-buffer-append-chunk buf chunk nil))
    (agent-org-buffer-end-agent-turn buf)
    (with-current-buffer buf
      (should (string-match-p "first line" (buffer-string)))
      (should (string-match-p "second line" (buffer-string)))
      (should (string-match-p "third" (buffer-string)))
      ;; and the lines are in the order they arrived, one copy each ("line"
      ;; appears twice: once in "first line", once in "second line")
      (should (equal 2 (ao--count-substrings "line"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-markdown-chunk-ending-with-newline-starts-a-new-line ()
  "A chunk that ENDS on a newline must not glue the next chunk onto that line.
Tokenizer stops land ON newlines constantly, so `say this\n' is an ordinary
chunk.  `split-string' drops the empty string after a trailing separator, which
makes an all-complete chunk look like one whose last line is still arriving --
and since the stored fragment is what the next chunk is concatenated to, the
newline vanished and `next that' joined `say this' as one line.  Asserted on the
buffer rather than on the fragment variable, because what a reader sees is the
contract."
  (let ((buf (agent-org-buffer-create "mdglue")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-chunk buf "say this\n" nil)
    (agent-org-buffer-append-chunk buf "next that\n" nil)
    ;; a heading arriving as its own chunk is the same case, and the one a user
    ;; would notice: a line of stars welded to the prose above it is not a
    ;; heading at all
    (agent-org-buffer-append-chunk buf "# Heading" nil)
    (agent-org-buffer-end-agent-turn buf)
    (with-current-buffer buf
      (should (string-match-p "^say this$" (buffer-string)))
      (should (string-match-p "^next that$" (buffer-string)))
      (should (string-match-p "^\\*Heading\\*$" (buffer-string)))
      (should-not (string-match-p "thisnext" (buffer-string))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-markdown-converts-the-user-prompt-too ()
  "Both sides of the conversation are Org text to a reader.  The prompt is
one whole message, so its lines convert as it becomes the exchange heading
and its body, and the agent still receives the markdown the user typed -- the
conversion is rendering, never the wire.  `# Asking' cannot stay a headline
(the conversation owns level 1), so it renders as the bold the reply's own
headings use; `* please' is a bullet, which converts to `- please' and reads
flush -- the one-space guard is only for the lines that would re-shape the
exchange (a column-0 `*' headline or a drawer keyword), not an ordinary list."
  (let ((buf (agent-org-buffer-create "mduser")))
    (agent-org-buffer-begin-exchange buf "# Asking\n* please")
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (string-match-p "^\\* PROMPT \\*Asking\\*$" text))
      (should (string-match-p "^- please$" text))
      (should-not (string-match-p "^# Asking$" text))
      (should-not (string-match-p "^\\* please$" text)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-markdown-converted-text-is-still-frozen ()
  "Rewriting the text must not lose the read-only property.  Every render
site protects the region it inserted; the converter changes what is inserted,
not where or under what property."
  (let ((buf (agent-org-buffer-create "mdfrozen")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-chunk buf "# H\n**b**\n" nil)
    (agent-org-buffer-end-agent-turn buf)
    (with-current-buffer buf
      (goto-char (point-min))
      (should (re-search-forward "^\\*H\\*$" nil t))
      (should (get-text-property (match-beginning 0) 'read-only)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-one-drawer-board-redraw-cost ()
  "One drawer for the lines AND the bodies means each new call rewrites the
earlier ones, so the shape has to be measured, not assumed.  This is a heavy
ordinary turn: 20 calls, 40 output lines each, every update arriving with
content -- so the board is redrawn 20 times over a body that grows to 800
lines, each redraw a delete, an insert and the read-only protection of the
result.  Printed with a loose ceiling on purpose: if this ever reaches
seconds on this machine, the drawer must grow APPEND-ONLY instead, and
`agent-org-buffer--tool-board-body' is the one place that builds it."
  (let* ((buf (agent-org-buffer-create "outcost"))
         (body (let ((out ""))
                 (dotimes (_ 40)
                   (setq out (concat out "output line of a real tool result\n")))
                 out))
         (start (float-time)))
    (agent-org-buffer-start-agent-turn buf nil)
    (dotimes (i 20)
      (agent-org-buffer-insert-tool
       buf `((toolCallId . ,(format "tc%d" i))
             (title . ,(format "call %d" i)) (status . "completed")
             ,@(ao--tool-text-block body))))
    (let ((elapsed (- (float-time) start)))
      (princ (format "\ntool board: 20 calls x 40 lines in %.1f ms (%.1f ms per redraw)\n"
                     (* elapsed 1000) (/ (* elapsed 1000) 20.0)))
      (should (< elapsed 3.0)))
    (with-current-buffer buf
      (should (= 1 (ao--count-occurrences (buffer-string) "^:tool:$")))
      (should (= 20 (ao--count-occurrences (buffer-string) "^  - EXECUTED "))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-markdown-conversion-cost-per-line ()
  "The overhead the porting note asked to measure, printed and pinned as a ceiling.
A reply is tens of lines and a replay is thousands, all painted in one
synchronous pass on a 4 GB machine -- if this ever cost more than about a
millisecond per line the switch should default off rather than make the user
wait.  Measured here (Celeron, spinning disk): 115 us per markup-DENSE line,
and plain prose is several times cheaper, so a 50-line answer is ~2 ms and a
2000-line replay ~230 ms -- against the 3-15 ms a transcript boundary write
already costs (CONVENTIONS.md §14).  The ceiling is loose on purpose (a flaky
bound is worse than none) and the printed numbers are the report."
  (let* ((dense "**bold** *emph* and `code` see [docs](https://x.org)\n")
         (plain "The quick brown fox jumps over the lazy dog, for scale.\n")
         (n 400))
    (dolist (spec (list (cons "dense" dense) (cons "plain" plain)))
      (let* ((text (let ((out ""))
                     (dotimes (_ n) (setq out (concat out (cdr spec))))
                     out))
             (lines (length (split-string text "\n" t)))
             (start (float-time)))
        (agent-org-buffer--markdown-convert text)
        (let ((elapsed (- (float-time) start)))
          (princ (format "\nmarkdown->org %s: %d lines in %.1f ms (%.1f us/line)\n"
                         (car spec) lines (* elapsed 1000)
                         (/ (* elapsed 1000000) lines)))
          (should (< elapsed 1.0)))))))

;;;; The agent learns which model, session and agent it is

(defun ao--all-prompt-blocks ()
  "Every `session/prompt' captured by `ao--capture-wire', oldest first.
Each entry is the list of content blocks as the wire would carry them, so
a test can see the user's own block and the client's context block apart.
Needs `ao--wire-prompt-texts': the mock's request builder answers NIL, and
a NIL request would be captured under NIL and be invisible here."
  (mapcar (lambda (entry)
            (append (map-elt (map-elt (plist-get (cdr entry) :request) ':params)
                             'prompt)
                    nil))
          (reverse (seq-filter (lambda (entry)
                                 (equal (car entry) "session/prompt"))
                               ao--sent))))

(defun ao--sent-blocks (sent)
  "The content blocks of every prompt in SENT, oldest first.
The `cl-letf' idiom the queue tests use (a stubbed
`acp-make-session-prompt-request' that hands back its `:prompt' argument),
so this is the same view `ao--all-prompt-blocks' gives the
`ao--capture-wire' idiom."
  (mapcar (lambda (kw) (plist-get kw :request)) (reverse sent)))

(ert-deftest test-agent-org-send-appends-a-context-block-after-the-users-words ()
  "The prompt is two text blocks: the user's words, then the client's facts.
The user's block stays EXACTLY what was typed — this is the one place the
client adds to the wire, and it adds beside the request rather than inside
it, so an agent quoting the question quotes the person.  Appending LAST is
also what keeps every existing reader of the first block honest."
  (let ((sent nil))
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest kw) (push kw sent)))
              ((symbol-function 'acp-make-session-prompt-request)
               (lambda (&rest a) (plist-get a :prompt))))
      (let ((pair (ao--make-test-session "ctx-first"))
            (agent-org-send-session-context t))
        (with-current-buffer (car pair)
          (agent-org-buffer-insert-prompt (car pair))
          (ao--type "What is a monad?")
          (agent-org-send))
        (let ((blocks (car (ao--sent-blocks sent))))
          (should (= 2 (length blocks)))
          (should (equal "What is a monad?" (map-elt (car blocks) 'text)))
          (should (equal "text" (map-elt (cadr blocks) 'type)))
          (should (string-prefix-p "<agent-org-context>"
                                   (map-elt (cadr blocks) 'text)))
          (should (string-suffix-p "</agent-org-context>\n"
                                   (map-elt (cadr blocks) 'text))))
        (kill-buffer (car pair))))))

(ert-deftest test-agent-org-context-block-names-the-agent-model-and-session-id ()
  "The block carries the three facts, in the form the agent can quote back.
An agent asked \"which model are you?\" answers from its own idea of the
default, which is wrong the moment the client has selected another model
through `session/set_config_option' — the whole reason OpenCode-fronted
MiniMax exists.  Both the label and the id go: the label is what a person
reads, the id is what a commit trailer or a config request needs, and the
agent cannot derive one from the other.
The exact text is the spec here, because a format an agent has to guess at
is a format it will misquote."
  (ao--capture-wire
    (ao--wire-prompt-texts
      (let ((agent-org-send-session-context t)
            (buf (ao--chat-on-model "minimax/MiniMax-M3" "MiniMax M3"
                                    "7c1f-abc")))
        (with-current-buffer buf
          (agent-org-buffer-insert-prompt buf)
          (ao--type "hi")
          (agent-org-send))
        (should (equal (map-elt (cadr (car (ao--all-prompt-blocks))) 'text)
                       (concat
                        "<agent-org-context>\n"
                        "Client metadata about this connection,"
                        " not part of the user's request.\n"
                        "agent: Qoder (qoder)\n"
                        "model: MiniMax M3 (minimax/MiniMax-M3)\n"
                        "session: 7c1f-abc\n"
                        "</agent-org-context>\n")))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-context-block-follows-a-model-change ()
  "The block is built per turn, because the middle fact can change mid-session.
`C-c a m' is a normal thing to do between two questions; a block computed
once at session start would tell the agent a model that stopped being true
turn one ago, which is worse than saying nothing."
  (ao--capture-wire
    (ao--wire-prompt-texts
      ;; Not `ao--chat-on-model': it advertises ONE model, and a switch needs
      ;; both ids in the option list, because `agent-org-set-session-model'
      ;; rejects an id the agent never offered.
      (let* ((agent-org-send-session-context t)
             (agent-org-session-strategy 'new)
             (models (list (cons "qmodel" "QModel")
                           (cons "qmodel-large" "QModel Large")))
             (buf (agent-org-start 'qoder)))
        (ao--drive "initialize" ao--fake-init-resp)
        (ao--drive "session/new" (ao--config-resp "qmodel" models "sid-ctx"))
        (with-current-buffer buf
          (agent-org-buffer-insert-prompt buf)
          (ao--type "first")
          (agent-org-send))
        ;; the turn must END before the second prompt: a streaming session
        ;; queues it, and a queued prompt drains with its own turn, its own
        ;; block — which is a different test
        (ao--drive "session/prompt" nil)
        (with-current-buffer buf (agent-org-set-session-model "qmodel-large"))
        (ao--drive "session/set_config_option"
                   (ao--config-resp "qmodel-large" models "sid-ctx"))
        (with-current-buffer buf
          (agent-org-buffer-insert-prompt buf)
          (ao--type "second")
          (agent-org-send))
        (let ((blocks (ao--all-prompt-blocks)))
          (should (= 2 (length blocks)))
          (should (string-match-p "model: QModel (qmodel)"
                                  (map-elt (cadr (car blocks)) 'text)))
          (should (string-match-p "model: QModel Large (qmodel-large)"
                                  (map-elt (cadr (nth 1 blocks)) 'text)))
          (should (equal "second" (map-elt (car (nth 1 blocks)) 'text))))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-context-block-alerts-a-model-that-inherited-a-transcript ()
  "The turn a model CHANGED gets told the earlier turns are not its work.
A harness hands the new model the whole conversation and no fact about who
wrote it, so it answers \"I did that\" about another model's turns — and, for
this package's own use, an agent that does not know it was switched under it
will keep reasoning as if the earlier mistakes were its own.  The alert names
BOTH models in the same `NAME (ID)' spelling as the fact line, and rides the
block that turn only.
Asserted through the real two-turn path (`C-c a m' between questions), because
the memory of the previous model is buffer state and a unit call could not
show it being written and read."
  (ao--capture-wire
    (ao--wire-prompt-texts
      (let* ((agent-org-send-session-context t)
             (agent-org-session-strategy 'new)
             (models (list (cons "qmodel" "QModel")
                           (cons "qmodel-large" "QModel Large")))
             (buf (agent-org-start 'qoder)))
        (ao--drive "initialize" ao--fake-init-resp)
        (ao--drive "session/new" (ao--config-resp "qmodel" models "sid-ctx"))
        (with-current-buffer buf
          (agent-org-buffer-insert-prompt buf)
          (ao--type "first")
          (agent-org-send))
        (ao--drive "session/prompt" nil)
        (with-current-buffer buf (agent-org-set-session-model "qmodel-large"))
        (ao--drive "session/set_config_option"
                   (ao--config-resp "qmodel-large" models "sid-ctx"))
        (with-current-buffer buf
          (agent-org-buffer-insert-prompt buf)
          (ao--type "second")
          (agent-org-send))
        (let ((first (map-elt (cadr (car (ao--all-prompt-blocks))) 'text))
              (second (map-elt (cadr (nth 1 (ao--all-prompt-blocks))) 'text)))
          ;; turn one has no previous model to be told about
          (should-not (string-match-p "model change:" first))
          (should (string-match-p
                   (concat "model change: this turn runs on QModel Large"
                           " [(]qmodel-large[)]; the turn before ran on"
                           " QModel [(]qmodel[)]")
                   second))
          ;; and it says what to do with the information
          (should (string-match-p "not its work\\|that model's work, not yours"
                                  second))
          ;; the alert is a line of its own, at the END: the three facts keep
          ;; the quoted order they always had.  The block's LAST line is the
          ;; closing delimiter, so "at the END" means the line just before it.
          (let ((lines (split-string second "\n" t)))
            (should (equal "</agent-org-context>" (car (last lines))))
            (should (string-prefix-p "model change:" (car (last (butlast lines)))))
            (should (equal '("agent: Qoder (qoder)"
                             "model: QModel Large (qmodel-large)"
                             "session: sid-ctx")
                           (seq-take (cdr (cdr lines)) 3)))))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-context-block-alerts-once-per-model-change ()
  "One switch, one alert.  The turn AFTER a change runs on the same model as
the changed turn, so saying it again would tell the model its own last answer
was somebody else's work.  This is the pin for
`agent-org--last-context-model' being WRITTEN by the block builder, not just
read: a builder that never recorded would alert on every turn of the rest of
the session.  (A plist key was the first attempt and it is a trap — see that
variable's docstring for why this is buffer state.)"
  (ao--capture-wire
    (ao--wire-prompt-texts
      (let* ((agent-org-send-session-context t)
             (agent-org-session-strategy 'new)
             (models (list (cons "qmodel" "QModel")
                           (cons "qmodel-large" "QModel Large")))
             (buf (agent-org-start 'qoder)))
        (ao--drive "initialize" ao--fake-init-resp)
        (ao--drive "session/new" (ao--config-resp "qmodel" models "sid-once"))
        (dotimes (n 3)
          (with-current-buffer buf
            (agent-org-buffer-insert-prompt buf)
            (ao--type (format "turn %d" n))
            (agent-org-send))
          (ao--drive "session/prompt" nil)
          (when (= n 0)
            (with-current-buffer buf (agent-org-set-session-model "qmodel-large"))
            (ao--drive "session/set_config_option"
                       (ao--config-resp "qmodel-large" models "sid-once"))))
        (let ((ctxs (mapcar (lambda (blocks)
                              (map-elt (cadr blocks) 'text))
                            (ao--all-prompt-blocks))))
          (should (= 3 (length ctxs)))
          (should-not (string-match-p "model change:" (car ctxs)))
          (should (string-match-p "model change:" (cadr ctxs)))
          (should-not (string-match-p "model change:" (nth 2 ctxs))))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-context-block-never-alerts-a-model-it-never-knew ()
  "A model that only becomes known on turn two is not a CHANGE.
The first turns of a session run before the agent has reported any config, and
goose never reports one of this shape at all: an alert built on \"before:
nothing, now: MiniMax\" would tell the agent it replaced a model the client
never named — the same lie a `model: nil' line is, in the other direction.
So an unknown previous model arms nothing, and the block only ever states
models it was told."
  (let ((sent nil))
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest kw) (push kw sent)))
              ((symbol-function 'acp-make-session-prompt-request)
               (lambda (&rest a) (plist-get a :prompt))))
      (let ((pair (ao--make-test-session "ctx-late"))
            (agent-org-send-session-context t))
        (let ((buf (car pair)))
          (with-current-buffer buf
            (agent-org-buffer-insert-prompt buf)
            (ao--type "no model yet")
            (agent-org-send))
          ;; the turn has to END, or the next prompt is queued rather than
          ;; sent, and a queued prompt is a different test
          (funcall (plist-get (car sent) :on-success) nil)
          (with-current-buffer buf
            (agent-org-buffer-set-status buf :model "m1" :model-name "Model One")
            (agent-org-buffer-insert-prompt buf)
            (ao--type "model arrives")
            (agent-org-send))
          (funcall (plist-get (car sent) :on-success) nil)
          (let ((ctxs (mapcar (lambda (blocks)
                                (let ((ctx (map-elt (cadr blocks) 'text)))
                                  (and (stringp ctx) ctx)))
                              (ao--sent-blocks sent))))
            (should (= 2 (length ctxs)))
            (should (string-match-p "session: sid-test" (car ctxs)))
            (should-not (string-match-p "model change:" (car ctxs)))
            (should (string-match-p "model: Model One (m1)" (nth 1 ctxs)))
            (should-not (string-match-p "model change:" (nth 1 ctxs))))
          (kill-buffer buf))))))

(ert-deftest test-agent-org-model-change-compares-ids-not-labels ()
  "A harness RENAMING a model is not the client SWITCHING one.
`:model' is the wire id and `:model-name' the agent's own label, and a config
update can bring a new label for the same id (the reason both are stored, per
`agent-org--ingest-config').  Alerting there would tell a model it took over
from itself.  The pure comparison is pinned directly, because making a real
session relabel its current model needs a host that lies about its own option
list."
  (should (agent-org--model-change-fact (cons "m1" "Model One")
                                       (cons "m2" "Model Two")))
  (should-not (agent-org--model-change-fact (cons "m1" "Model One")
                                           (cons "m1" "Model One Renamed")))
  ;; same label, different id IS a change: two MiniMax runs on different
  ;; endpoints, where the readable name happens to collide
  (should (agent-org--model-change-fact (cons "minimax/a" "MiniMax M3")
                                       (cons "minimax/b" "MiniMax M3")))
  ;; nothing known on either side, on either side: no alert, no error
  (should-not (agent-org--model-change-fact nil (cons "m1" "Model One")))
  (should-not (agent-org--model-change-fact (cons "m1" "Model One") nil))
  (should-not (agent-org--model-change-fact (cons "m1" "One") (cons "m1" "One")))
  ;; a label-only provider (goose spells id and name with one word) still
  ;; compares, and still says both names when they differ
  (let ((alert (agent-org--model-change-fact (cons nil "alpha") (cons nil "beta"))))
    (should alert)
    (should (string-match-p "runs on beta; the turn before ran on alpha" alert))))

(ert-deftest test-agent-org-context-block-can-be-switched-off ()
  "nil sends only what the user typed.
The documented rule is that the agent receives the user's text unchanged;
this is the escape hatch that keeps that sentence true for a person who
does not want the client speaking for them, and the proof that the block
is an addition and not a rewrite of the draft."
  (let ((sent nil))
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest kw) (push kw sent)))
              ((symbol-function 'acp-make-session-prompt-request)
               (lambda (&rest a) (plist-get a :prompt))))
      (let ((pair (ao--make-test-session "ctx-off"))
            (agent-org-send-session-context nil))
        (with-current-buffer (car pair)
          (agent-org-buffer-insert-prompt (car pair))
          (ao--type "just me")
          (agent-org-send))
        (let ((blocks (car (ao--sent-blocks sent))))
          (should (= 1 (length blocks)))
          (should (equal "just me" (map-elt (car blocks) 'text))))
        (kill-buffer (car pair))))))

(ert-deftest test-agent-org-context-block-drops-the-model-line-without-a-model ()
  "An agent that advertises no model option gets a block with no model line.
Goose reports no `configOptions' of this shape; a `model: nil' line would
be the agent told something false, and \"unknown\" is not a model.  The
other two facts are still worth having, so the block goes anyway."
  (let ((sent nil))
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest kw) (push kw sent)))
              ((symbol-function 'acp-make-session-prompt-request)
               (lambda (&rest a) (plist-get a :prompt))))
      (let ((pair (ao--make-test-session "ctx-nomodel"))
            (agent-org-send-session-context t))
        (with-current-buffer (car pair)
          (agent-org-buffer-insert-prompt (car pair))
          (ao--type "hello")
          (agent-org-send))
        (let ((ctx (map-elt (cadr (car (ao--sent-blocks sent))) 'text)))
          ;; `^' in an Elisp regexp is the string's start, not the line's, so
          ;; the check is on the lines themselves.
          (should-not (seq-some (lambda (line) (string-prefix-p "model:" line))
                                (split-string ctx "\n" t)))
          (should (string-match-p "session: sid-test" ctx))
          ;; the label is the buffer's own provider name — this fixture was
          ;; created with "ctx-nomodel" rather than started, so that is what
          ;; a person would read on its header line — and the id in brackets
          ;; is the session's, which is the point of sending both
          (should (string-match-p "agent: ctx-nomodel (test)" ctx))
          ;; five lines, not six: the absent fact leaves no gap
          (should (= 5 (length (split-string ctx "\n" t)))))
        (kill-buffer (car pair))))))

(ert-deftest test-agent-org-drained-prompt-carries-the-same-context-block ()
  "A prompt that waited its turn is sent through the same door, so it
carries the same facts.  `agent-org--send-turn' is the single choke point
for typed and drained prompts alike; a context block built in
`agent-org-send' instead would go out on the first question of a session
and never again, which is exactly the turn a re-ordered queue makes most
different."
  (let ((sent nil))
    (cl-letf (((symbol-function 'acp-send-request)
               (lambda (&rest kw) (push kw sent)))
              ((symbol-function 'acp-make-session-prompt-request)
               (lambda (&rest a) (plist-get a :prompt))))
      (let* ((pair (ao--make-test-session "ctx-drain"))
             (buf (car pair))
             (session (cdr pair))
             (agent-org-send-session-context t))
        (setf (plist-get session :streaming) t)
        (with-current-buffer buf
          (agent-org-buffer-set-status buf :state 'streaming :message "Sending…")
          (agent-org-buffer-insert-prompt buf)
          (ao--type "queued one")
          (agent-org-send))                       ; queued: no send yet
        (should (= 0 (length sent)))
        (setf (plist-get session :streaming) nil)
        (agent-org--drain-queue session buf)
        (let ((blocks (car (ao--sent-blocks sent))))
          (should (equal "queued one" (map-elt (car blocks) 'text)))
          (should (string-match-p "session: sid-test"
                                  (map-elt (cadr blocks) 'text))))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-context-block-flattens-an-agent-supplied-label ()
  "A model label is agent text, and agent text can contain newlines.
One newline inside the block is a line the reading code — and the agent
quoting it back — has to guess about, so each value goes on exactly one
line.  Flattening must not TRUNCATE: a half-model-name on the wire is the
lie this block exists to prevent, and the standing rule is never to trust
a harness label to be short (AGENTS.md)."
  (ao--capture-wire
    (ao--wire-prompt-texts
      (let* ((agent-org-send-session-context t)
             (long (make-string 80 ?x))
             (buf (ao--chat-on-model "m\n2" (format "Big\nModel %s" long)
                                    "sid-flat")))
        (with-current-buffer buf
          (agent-org-buffer-insert-prompt buf)
          (ao--type "hi")
          (agent-org-send))
        (let ((ctx (map-elt (cadr (car (ao--all-prompt-blocks))) 'text)))
          (should (equal 6 (length (split-string ctx "\n" t))))
          ;; one line, so the whole value sits between "model: " and the
          ;; closing tag with no break in it
          (should (equal 1 (length (seq-filter (lambda (line) (string-prefix-p "model:" line))
                                               (split-string ctx "\n" t)))))
          (should (string-match-p (concat "model: Big Model " long
                                          " (m 2)")
                                  ctx))
          ;; the id is flattened too, and it is still there in full: the
          ;; agent may need to name it in a request
          (should-not (string-match-p "m\n2" ctx))
          (should-not (string-match-p "Big\n" ctx))
          (should-not (string-match-p "…" ctx)))
        (kill-buffer buf)))))

;;;; One heading per exchange: the prompt is the heading, the answer a quote

(defun ao--quote-blocks ()
  "Every quote block in the current buffer, as (BEGIN END TEXT).
The parser is the only witness that matters here: a `* ' line inside
`#+begin_quote' does not stay in the block (measured: the parser ENDS the
block, makes a headline, and the answer falls out of its fold), so a test
that only greps the text would pass on a broken turn.  Call it with the chat
buffer current."
  (let ((data (org-element-parse-buffer)))
    (org-element-map data 'quote-block
      (lambda (q)
        (list (org-element-property :begin q)
              (org-element-property :end q)
              (buffer-substring-no-properties
               (org-element-property :begin q)
               (org-element-property :end q)))))))

(defun ao--send-one (prompt)
  "Type PROMPT in this buffer's box and send it through the real `agent-org-send'.
The box is created first, because that is the state a live chat is in: a
test that types without a box is testing the error path.  Leaves the
session streaming, so the caller decides how the turn ends."
  (agent-org-buffer-insert-prompt (current-buffer))
  (ao--type prompt)
  (agent-org-send))

(ert-deftest test-agent-org-exchange-heading-wears-the-prompt ()
  "ONE heading per prompt/response pair, and its text IS the prompt.
User order: \"From now on, there will be ONE heading for each
prompt/response pair.  The heading will contain the prompt.\"  So the sent
question is no longer echoed under a `* PROMPT' heading: it becomes the
heading itself, and the exchange has exactly one.  The type-ahead box keeps
its `* PROMPT' heading because it is an input control, not a pair."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (ao--send-one "What is the capital of France?")
        ;; `ao--send-one' leaves the turn streaming, and the heading mirrors
        ;; the header line's state: `RESPONDING' for the duration of the turn
        (should (equal 1 (ao--count-occurrences (buffer-string)
                                               "^\\* RESPONDING What is the capital of France\\?$")))
        (should (equal 1 (ao--count-occurrences (buffer-string) "^\\* PROMPT$")))
        ;; and nothing of the question is left as body text under a heading:
        ;; the heading is the record
        (should-not (string-match-p "\nWhat is the capital" (buffer-string))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-answer-streams-under-a-model-name-prefix ()
  "The reply lands under one prefix line naming the model that answered.
User order (the quote-block one, then its successor): \"the response should
be contained in an Org quote block, with the narrator/author as the model
name\", then \"no more quote blocks, just a prefix\".  So the attribution that
`#+ATTR_TEXINFO: :author NAME' used to carry now rides on the line that
introduces the answer -- `Model name: ' -- and the text streams below it.  The
heading above is the question, written once by `agent-org-buffer-begin-exchange';
this prefix line is written once when the answer starts, so a later `C-c a m'
renames the NEXT answer and cannot rewrite an older one."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (ao--send-one "Capital?")
        (agent-org-buffer-append-chunk buf "Paris.\n" (agent-org-buffer--session))
        (agent-org-buffer-end-agent-turn buf)
        (should (apply #'ao--ordered (buffer-string)
                       (list "^\\* RESPONDED Capital\\?$"
                             "^QModel: $"
                             "Paris\\."
                             "^\\* PROMPT$")))
        ;; the answer is flush prose under the prefix, with no quote furniture
        ;; left anywhere in the buffer
        (should-not (string-match-p "begin_quote" (buffer-string)))
        (should-not (string-match-p "ATTR_TEXINFO" (buffer-string))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-answer-appends-in-order-at-every-moment-of-a-turn ()
  "Streaming APPENDS each chunk under the last, at every instant of a turn.
This is the invariant the user's \"texts will be appended as received\" order
demands, and the one the quote block used to guarantee by writing above its
`#+end_quote'.  With the block gone the guarantee is the answer's insertion
marker: every chunk lands below the prose already written and above anything
drawn at the boundary, so the buffer is valid Org WHILE the agent talks (no
open block to swallow a drawer or the type-ahead box) and a reader never has
to jump around to follow the reply.  Asserted mid-turn, with a chunk still to
come, and again at the boundary."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (ao--send-one "Talk")
        (agent-org-buffer-append-chunk buf "Half a sent" (agent-org-buffer--session))
        ;; the prefix line is there and no block is left open; the arriving
        ;; line is still the converter's fragment (no newline yet) so it is not
        ;; asserted in the buffer at this instant
        (should (string-match-p "^QModel: $" (buffer-string)))
        (agent-org-buffer-append-chunk buf "ence.\nSecond line.\n"
                                       (agent-org-buffer--session))
        ;; the two halves joined on ONE line and the next line followed BELOW
        ;; it, in arrival order -- ordinary prose stays flush, so the guard
        ;; indent no longer applies to a plain line
        (should (string-match-p "Half a sentence\\.\nSecond line"
                                (buffer-string)))
        (agent-org-buffer-end-agent-turn buf)
        (should (apply #'ao--ordered (buffer-string)
                       (list "^QModel: $" "Half a sentence" "Second line"
                             "^\\* PROMPT$"))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-reply-cannot-open-a-structure-of-its-own ()
  "A reply that QUOTES Org markup is still only prose under the prefix.
With the quote block gone there is nothing for the agent's text to CLOSE, but
the structural hazard it was written against remains: a `*' at column 0 is a
HEADLINE that would end the exchange.  `agent-org-buffer--response-safe-lines'
indents exactly those lines, and a `#+end_quote' line is inert because there is
no block to end -- so every chunk, hostile or not, stays in the one exchange and
the following chunk still lands under the same prefix."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (ao--send-one "Quote this")
        (agent-org-buffer-append-chunk buf "#+end_quote\nstill inside\n"
                                       (agent-org-buffer--session))
        (should (string-match-p "still inside" (buffer-string)))
        (should (string-match-p "#\\+end_quote" (buffer-string)))
        ;; and the chunk after the hostile line still lands under the prefix
        (agent-org-buffer-append-chunk buf "and more.\n"
                                       (agent-org-buffer--session))
        (should (apply #'ao--ordered (buffer-string)
                       (list "^QModel: $" "#\\+end_quote" "still inside"
                             "and more")))
        ;; the exchange is still ONE heading plus the type-ahead box -- the
        ;; agent's markup invented no structure
        (should (equal 2 (ao--count-occurrences (buffer-string) "^\\* ")))
        (agent-org-buffer-end-agent-turn buf))
      (kill-buffer buf))))

(ert-deftest test-agent-org-verbatim-reply-cannot-split-the-exchange ()
  "With conversion off, agent text is still inert under the prefix.
`agent-org-convert-markdown' nil means the agent's bytes land verbatim, and
Markdown `* item' is a `* ' line at column 0 — which the parser turns into a
HEADLINE that cuts the exchange in two (measured: two headlines, answer
scattered).  The guard indents exactly those would-be headline lines, which
keeps them inert and keeps the turn ONE heading plus the type-ahead box."
  (ao--capture-wire
    (let ((agent-org-convert-markdown nil)
          (buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (ao--send-one "Raw please")
        (agent-org-buffer-append-chunk buf "* one\n* two\n"
                                       (agent-org-buffer--session))
        ;; the stars are indented, so neither is a column-0 headline: the only
        ;; `*' at column 0 is the exchange heading and the box
        (should (equal 2 (ao--count-occurrences (buffer-string) "^\\* ")))
        (should (string-match-p "^ \\* one$" (buffer-string)))
        (should (string-match-p "^ \\* two$" (buffer-string)))
        (agent-org-buffer-end-agent-turn buf))
      (kill-buffer buf))))

(ert-deftest test-agent-org-activity-lands-in-arrival-order-under-an-exchange ()
  "Position in the exchange is NOTIFICATION ORDER, exactly like agent-shell.
The user's order: \"Keep the activity order just like agent-shell\", reinforced
by \"texts will be appended as received\".  In agent-shell every
`session/update' branch calls the same fragment placer
(`agent-shell-ui--update-fragment', agent-shell-ui.el:327), so the buffer order
IS arrival order.  With the quote block gone the same guarantee holds a
sharper way: the answer's OWN text streams under its prefix in the order it
arrives, and the `:thinking:' and `:tool:' drawers -- which are repainted
kind-boards, not fragments -- are always drawn BELOW the prose.  An answer can
therefore never be stranded under the reasoning that preceded it.

The reply is one run of prose under one prefix (§1), and no drawer can land
inside it: every would-be headline line of the answer is guarded by
`agent-org-buffer--response-safe-lines', so a `:thinking:' or `:tool:' at
column 0 is never the reply's own text -- which is what makes searching the
turn region for a drawer safe."
  (ao--capture-wire
    (let ((agent-org-activity-style 'drawers))
      (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (let ((session (agent-org-buffer--session)))
          (agent-org-buffer-begin-exchange buf "Do it")
          (agent-org-buffer-append-thought buf "hmm\n")
          (agent-org-buffer-insert-tool buf '((title . "read_file")
                                             (toolCallId . "t1")
                                             (status . "pending")))
          (agent-org-buffer-append-chunk buf "the answer\n" session)
          ;; and the activity KEEPS going after the answer started
          (agent-org-buffer-append-thought buf " then more\n")
          (agent-org-buffer-insert-tool buf '((title . "shell")
                                             (toolCallId . "t2")
                                             (status . "completed")))
          (agent-org-buffer-end-agent-turn buf)
          (let ((text (buffer-string)))
            ;; heading, then answer under its prefix, then the blocks of the
            ;; turn in the order they happened: thought, board, thought again
            (should (apply #'ao--ordered text
                           (list "^\\* RESPONDED Do it$"
                                 "^QModel: $" "the answer"
                                 "^:thinking:$" "hmm"
                                 "^:tool:$" "  - RUNNING read_file" "  - EXECUTED shell"
                                 "^:thinking:$" "then more")))
            ;; ONE thinking drawer PER RUN: the board drawn under the first
            ;; thought ended that run, so "then more" opens a second one below
            ;; it instead of being painted back into the one above
            (should (equal 2 (ao--count-occurrences text "^:thinking:$")))
            ;; and the two tool calls still share ONE board: a call joining a
            ;; run that is still live does not open a second drawer
            (should (equal 1 (ao--count-occurrences text "^:tool:$")))
            (should (equal 1 (ao--count-occurrences text "^  - EXECUTED shell$")))
            ;; no quote furniture anywhere now that the block is gone
            (should-not (string-match-p "begin_quote" text))))
        (kill-buffer buf))))))

(ert-deftest test-agent-org-drawers-land-below-the-answer ()
  "The turn keeps one order: answer prose, then thinking, then tools.
`:thinking:' and `:tool:' are drawn at the end of the turn region, below the
answer -- and the answer's OWN `:thinking:' line must never be mistaken for the
drawer.  Without a quote block to make it inert, that is the guard's job:
`agent-org-buffer--response-safe-lines' indents a column-0 `:NAME:' line, so it
reads as the text it is while `--redraw-drawer', which searches the region
TEXTUALLY, finds only the real drawer it drew below the prose (measured before
the guard: the redraw grabbed the fake opener and its `:end:' search ran off the
end of the buffer)."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (let ((session (agent-org-buffer--session)))
          (ao--send-one "Do it")
          (agent-org-buffer-append-chunk buf "start\n:thinking:\nfake\n" session)
          (agent-org-buffer-append-thought buf "a real thought" )
          (agent-org-buffer-insert-tool buf '((title . "shell") (toolCallId . "t1")))
          (agent-org-buffer-append-chunk buf "more answer\n" session)
          (agent-org-buffer-end-agent-turn buf)
          ;; the fake marker survives as the answer's own text, indented one
          ;; space so it is not a drawer keyword any more
          (should (string-match-p "^ :thinking:$" (buffer-string)))
          ;; both answer lines are under the prefix, in arrival order
          (should (apply #'ao--ordered (buffer-string)
                         (list "^QModel: $" "start" " :thinking:" "fake"
                               "more answer")))
          ;; and the REAL drawers are below the answer, in kind order
          (should (apply #'ao--ordered (buffer-string)
                         (list "more answer" "^:thinking:$" "a real thought"
                               "^:tool:$" "  - RUNNING shell")))
          (should (equal 1 (ao--count-occurrences (buffer-string) "^:thinking:$")))
          (should (equal 1 (ao--count-occurrences (buffer-string) "^ a real thought$")))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-markdown-heading-in-a-reply-becomes-a-bold-line ()
  "A Markdown heading cannot be an Org headline in the answer, so it is bold.
`agent-org-buffer--md-structure' shifts `# Title' down rather than leaving it
as an Org COMMENT (which vanishes from every export), and an answer line that
starts at column 0 with a star would become a HEADLINE that splits the exchange
in two.  Org has no heading in ordinary prose, so the closest rendering that
survives is the text bold on its line -- `*Setup*', which is safe because a
headline needs a space after the stars.  Asserted under the prefix, flush."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (ao--send-one "Write docs")
        (agent-org-buffer-append-chunk buf "# Setup\nbody text\n"
                                       (agent-org-buffer--session))
        (agent-org-buffer-end-agent-turn buf)
        (should (string-match-p "^\\*Setup\\*$" (buffer-string)))
        (should (apply #'ao--ordered (buffer-string)
                       (list "^QModel: $" "^\\*Setup\\*$" "body text")))
        (should-not (string-match-p "^\\*\\* Setup$" (buffer-string))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-multi-line-prompt-keeps-its-rest-under-the-heading ()
  "A heading is one line, so a multi-line prompt keeps its other lines as body.
The first line is the heading because that is what a person scans; the rest
stays in the exchange, because the prompt is the user's own words and a
record that quietly dropped lines 2..n is worse than a long heading.  Those
lines are guarded the same way the answer is: a `*' at column 0 in the second
line would otherwise cut the exchange in two.  The prompt goes in through
`agent-org-buffer-begin-exchange' rather than the box, because typing a `*' at
column 0 makes an Org headline IN THE BOX and the box stops being a box — a
separate, older property of a live prompt buffer, and not what this test is
about."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (agent-org-buffer-begin-exchange buf
          "Summarise this\n* bullet not a heading\nlast line")
        (should (equal 1 (ao--count-occurrences (buffer-string)
                                                "^\\* PROMPT Summarise this$")))
        ;; the Markdown bullet became an Org dash (the echo converts like the
        ;; reply does); a `- item' at column 0 is a list, not a headline, so it
        ;; needs no guard indent and cannot split the exchange in two
        (should (string-match-p "^- bullet not a heading" (buffer-string)))
        (should (string-match-p "last line" (buffer-string)))
        ;; one heading for the exchange plus the box, and nothing the paste made
        (should (equal 2 (ao--count-occurrences (buffer-string) "^\\* "))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-two-exchanges-name-their-own-authors ()
  "A model switch authors the next answer's prefix, never the last one.
The prefix line is baked when the answer starts, so two replies from two
models stand in the transcript with two different names and no per-turn
map is needed: the line IS the record.  Asserting the older one survives
unchanged is the regression this could otherwise introduce, because a later
pass that re-derived the name from the CURRENT status would silently
rewrite history."
  (ao--capture-wire
    (let* ((buf (ao--chat-on-model "qmodel" "QModel"))
           (session (with-current-buffer buf (agent-org-buffer--session))))
      (with-current-buffer buf
        (agent-org-buffer-begin-exchange buf "First question")
        (agent-org-buffer-append-chunk buf "One.\n" session)
        (agent-org-buffer-end-agent-turn buf)
        (agent-org-buffer-set-status buf :model "qmodel-large"
                                     :model-name "QModel Large")
        (agent-org-buffer-begin-exchange buf "Second question")
        (agent-org-buffer-append-chunk buf "Two.\n" session)
        (agent-org-buffer-end-agent-turn buf)
        (should (equal 1 (ao--count-occurrences (buffer-string)
                                                "^QModel: $")))
        (should (equal 1 (ao--count-occurrences (buffer-string)
                                                "^QModel Large: $")))
        (should (apply #'ao--ordered (buffer-string)
                       (list "First question" "^QModel: $" "One\\."
                             "Second question" "^QModel Large: $" "Two\\."))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-prefix-falls-back-to-agent-without-a-model ()
  "No model reported is not a prefix line that says nothing.
Goose can answer with no `model' config option in its response at all, and a
prefix naming nobody is worse than a plain word — so the word stays
\"Agent\", which is what the heading used to say in the same case."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model nil nil)))
      (with-current-buffer buf
        (agent-org-buffer-begin-exchange buf "Hello")
        (agent-org-buffer-append-chunk buf "Hi.\n" (agent-org-buffer--session))
        (agent-org-buffer-end-agent-turn buf)
        (should (equal 1 (ao--count-occurrences (buffer-string)
                                                "^Agent: $"))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-prefix-option-off-keeps-the-word-agent ()
  "`agent-org-response-prefix' nil is the stable word.
A model name on the answer is a claim about the agent's catalog in the
middle of the user's notes; someone keeping transcripts across a provider
switch will want the stable word instead, and that preference must be
reachable without patching."
  (ao--capture-wire
    (let ((agent-org-response-prefix nil)
          (buf (ao--chat-on-model "qmodel-large" "QModel Large")))
      (with-current-buffer buf
        (agent-org-buffer-begin-exchange buf "Hello")
        (agent-org-buffer-append-chunk buf "Hi.\n" (agent-org-buffer--session))
        (agent-org-buffer-end-agent-turn buf)
        (should (equal 1 (ao--count-occurrences (buffer-string)
                                                "^Agent: $")))
        (should-not (string-match-p "^QModel" (buffer-string))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-orphan-agent-chunk-gets-a-heading-of-its-own ()
  "An answer with no question in front of it is still valid Org.
`session/load' history can carry agent updates that no `user_message_chunk'
precedes, and a chunk cannot be dropped because there is no heading to put it
under: the fallback word names the turn the way the old heading did."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model nil nil)))
      (with-current-buffer buf
        (agent-org-buffer-append-chunk buf "Unsolicited.\n"
                                       (agent-org-buffer--session))
        (agent-org-buffer-end-agent-turn buf)
        (should (equal 1 (ao--count-occurrences (buffer-string) "^\\* Agent$")))
        (should (equal 1 (ao--count-occurrences (buffer-string) "^Agent: $")))
        (should (string-match-p "Unsolicited" (buffer-string))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-turn-with-no-answer-text-keeps-no-prefix-line ()
  "A tool-only exchange is its heading plus its board, and nothing else.
`agent-org-buffer-start-agent-turn' writes the prefix line BEFORE the first
chunk, because a chunk may never arrive: an agent that only ran tools, or one
that hit its token limit, would otherwise leave a lonely `Agent:' line in the
user's notes -- an attribution to nobody, the same noise an empty quote block
was.  So `agent-org-buffer--drop-empty-response' removes the prefix line at the
turn boundary when no answer text ever landed.

The guard is the flag, not the buffer: `agent-org-buffer--answer-written-p'
records directly whether any prose was appended.  A blank line at the marker is
NO test for emptiness -- once the marker has advanced past real text and a
drawer has been drawn below it, that gap reads blank on a turn that said
something too, and deleting there would eat the drawer's `:thinking:' opener
(the corruption this shape produced).  Only the prefix line goes.

And the answer marker must be detached with it: it is what
`agent-org-buffer--text-end' reads, so a stale one would put the next
exchange's answer at a deleted position."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (let ((session (agent-org-buffer--session)))
          (agent-org-buffer-begin-exchange buf "Run the tests")
          (agent-org-buffer-start-agent-turn buf session)
          (agent-org-buffer-insert-tool buf '((title . "shell")
                                             (toolCallId . "t1")
                                             (status . "completed")))
          (agent-org-buffer-end-agent-turn buf)
          ;; the lonely prefix line is gone, and so is the answer marker
          (should-not (string-match-p "^QModel: $" (buffer-string)))
          (should-not (string-match-p "^Agent: $" (buffer-string)))
          ;; the exchange itself survives, board and all: the turn ended, so
          ;; its heading wears the done word of the prompt set
          (should (equal 1 (ao--count-occurrences (buffer-string)
                                                 "^\\* RESPONDED Run the tests$")))
          (should (string-match-p "^:tool:$" (buffer-string)))
          ;; the next exchange, which DOES get an answer, keeps its prefix and
          ;; its text -- the dropped marker did not strand it
          (agent-org-buffer-begin-exchange buf "And now explain")
          (agent-org-buffer-append-chunk buf "Because I ran them.\n" session)
          (agent-org-buffer-end-agent-turn buf)
          (should (apply #'ao--ordered (buffer-string)
                         (list "And now explain" "^QModel: $"
                               "Because I ran them")))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-replay-paints-the-same-exchange-shape ()
  "A restored chat is headed by its questions and its answers stream under
the model/`Agent' prefix.  Replay carries the prompt: `session/load' sends
`user_message_chunk' updates, which is what the heading is built from — so a
restored transcript reads exactly like a live one, and the same primitives do
both (no second renderer).  An agent chunk arriving BEFORE any user chunk is
the orphan case, and it gets the fallback heading rather than eating the next
question."
  (ao--capture-wire
    (let ((buf (agent-org-resume-session 'qoder "sid-exch")))
      (let ((session (agent-org--session-for-buffer buf)))
        (ao--drive "initialize" ao--fake-init-resp)
        (ao--drive "session/load" '((sessionId . "sid-exch")))
        (dolist (update
                 (list '((sessionUpdate . "agent_message_chunk")
                         (content . ((type . "text") (text . "Orphan answer.\n"))))
                       '((sessionUpdate . "user_message_chunk")
                         (content . ((type . "text") (text . "Why?"))))
                       '((sessionUpdate . "agent_message_chunk")
                         (content . ((type . "text") (text . "Because.\n"))))))
          (agent-org--on-notification session (ao--update-notif update)))
        (ao--settle)
        (with-current-buffer buf
          ;; two answers, so two prefix lines: the orphan's and the one that
          ;; answers "Why?"  The question itself is a heading, never a prefix,
          ;; and no quote furniture survives the move off quote blocks.
          (should (equal 2 (ao--count-occurrences (buffer-string) "^Agent: $")))
          (should (equal 0 (ao--count-occurrences (buffer-string) "^#\\+begin_quote$")))
          (should (equal 1 (ao--count-occurrences (buffer-string) "^\\* Agent$")))
          ;; a restored turn is a CLOSED one: the replay ends Ready and the
          ;; heading mirrors that state word, `RESPONDED'
          (should (equal 1 (ao--count-occurrences (buffer-string) "^\\* RESPONDED Why\\?$")))
          (should (apply #'ao--ordered (buffer-string)
                         (list "^\\* Agent$" "Orphan answer"
                               "^\\* RESPONDED Why\\?$" "^Agent: $" "Because")))))
      (kill-buffer buf))))


;;;; Per-exchange response clock: CLOCK: line + :RESPONSE: property
;;
;; User order (TODOs.org): "Each heading will be clocked, too, to derive the
;; total response time of the agent since the prompt were sent."  The settled
;; shape: a canonical `CLOCK:' line (the form `org-clock-in' writes, so a
;; person editing it by hand gets Org's own machinery) inside the exchange's
;; `:LOGBOOK:' drawer, plus a `:RESPONSE:' property with the EXACT seconds —
;; the minute-granular range says what Org sees, the property says what was
;; measured.  Started when the prompt goes out (the stamp is taken by
;; `agent-org-buffer-begin-exchange'), closed at the turn boundary; replayed
;; exchanges carry no clock rather than a false one, and a completed clock line
;; must never be mistaken for a running one (`agent-org-buffer--turn-start'
;; only feeds OUR writer, never `org-clock').

(defun ao--rewind-turn-start (seconds)
  "Claim the open turn in the current buffer began SECONDS ago.
The clock records wall time and a test cannot wait for a minute to pass; the
seam is the buffer-local start stamp itself, which only the turn boundary
reads.  The `=>' DURATION is minute-granular (that is the half Org parses
nothing else in), so pick a multiple of 60 in tests and it is deterministic
whatever second the suite runs in; the STAMPS and the property carry the exact
seconds."
  (setq agent-org-buffer--turn-start
        (time-subtract (current-time) (seconds-to-time seconds))))

(defun ao--clock-line-p (string)
  "Non-nil when STRING contains our canonical closed CLOCK line.
Two bracketed SECOND-precise timestamps joined by `--' and a minute-granular
`=>' duration, so any tool that reads clocks (org-clock-collect, a person's
grep) finds ours.  The STAMPS carry seconds on purpose (user order 2026-10-14:
\"Seconds no longer showing up in clock timestamps\"): a second-precise stamp
still parses as one `clock' node and still sums — measured on Org 9.7.11 AND
9.8.10 — so the transcript, which is a plain Org file and draws no overlay,
shows the seconds.  The DURATION stays minute-granular, because a duration
carrying seconds is the half that yields zero `clock' nodes; the exact whole
seconds still ride in `:RESPONSE:' and `agent-org-clock-display' still puts
them on screen in a live chat (test-agent-org-clock-display-org-rounds-our-
seconds-away)."
  (string-match-p
   "^CLOCK: \\[20[0-9][0-9]-[0-9][0-9]-[0-9][0-9] [A-Za-z]+ [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\\]--\\[.+\\] => +[0-9]+:[0-9][0-9]$"
   string))

(defun ao--count-nodes (type)
  "How many TYPE nodes the parser sees in the current buffer.
`org-element-count' is newer than the Org this package ships against, and
the count here is the assertion that STRUCTURE survived: a drawer that
stops being a drawer, or a `*' line that splits a heading, changes what the
parser reports while the text still reads fine to the eye."
  (let ((n 0))
    (org-element-map (org-element-parse-buffer) type
      (lambda (_) (cl-incf n)))
    n))

(ert-deftest test-agent-org-typed-exchange-gets-a-response-clock ()
  "A prompt typed into a live chat leaves a clock under its heading.
Asserted through ORG'S OWN reader, not a grep: `org-entry-get' answering
\"4500\" is proof the `:PROPERTIES:' drawer sits directly below the heading
where Org looks, and `org-element' counting one `clock' node is proof the
range is the canonical form rather than a comment that merely looks like
one.  A second boundary call must not write a second clock: the stamp is
consumed when the line goes in.

4500 s = 75 minutes exactly, a multiple of a minute, so the `=>  1:15'
duration the writer computes from the minute-truncated stamps is the same
whatever second the suite runs in; the exact count lives in the property."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (ao--send-one "Capital?")
        (ao--rewind-turn-start 4500)
        (agent-org-buffer-append-chunk buf "Paris.\n" (agent-org-buffer--session))
        (agent-org-buffer-end-agent-turn buf)
        (should (ao--clock-line-p (buffer-string)))
        (should (string-match-p " =>  1:15$" (buffer-string)))
        ;; heading, its drawer, its logbook, then the answer as before
        (should (apply #'ao--ordered (buffer-string)
                       (list "^\\* RESPONDED Capital\\?$"
                             "^:PROPERTIES:$" ":RESPONSE: 4500$" "^:END:$"
                             "^:LOGBOOK:$" "^CLOCK: \\[" "^:END:$"
                             "^QModel: $" "^Paris\\.$")))
        ;; Org's own property reader finds it at the heading
        (save-excursion
          (goto-char (point-min))
          (re-search-forward "^\\* RESPONDED Capital\\?$")
          (should (equal "4500" (org-entry-get (point) "RESPONSE"))))
        ;; the range is a genuine Org CLOCK node, not a line that only LOOKS
        ;; like one — `org-clock-parse-clock-line' is gone in this Org, and
        ;; `org-element' is the parser every clock tool (collet, a person's
        ;; agenda) reads through, so counting its `clock' nodes is the proof
        (should (equal 1 (ao--count-nodes 'clock)))
        ;; and the buffer still parses as ONE headline for the exchange
        (should (equal 2 (ao--count-nodes 'headline)))
        ;; a second close (a late callback after the boundary) adds no clock
        (agent-org-buffer-end-agent-turn buf)
        (should (equal 1 (ao--count-occurrences (buffer-string) "^CLOCK: "))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-clock-stamps-carry-seconds ()
  "Our CLOCK stamps carry SECONDS, so the transcript shows them.
User order 2026-10-14: \"Seconds no longer showing up in clock timestamps.\"  A
live chat draws the seconds in an overlay built from `:RESPONSE:', but the
transcript is a plain Org file that draws no overlay -- the STAMPS are the only
place the seconds can show there.  Safe by measurement: a second-precise STAMP
still parses as one `clock' node and still sums (Org 9.7.11 AND 9.8.10), so only
the `=>' DURATION has to stay minute-granular."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (ao--send-one "Capital?")
        (ao--rewind-turn-start 45)
        (agent-org-buffer-append-chunk buf "Paris.\n" (agent-org-buffer--session))
        (agent-org-buffer-end-agent-turn buf)
        (let ((text (buffer-string)))
          ;; BOTH stamps carry HH:MM:SS -- the whole point of the change
          (should (string-match-p
                   (concat "^CLOCK: \\[[0-9-]+ [A-Za-z]+ "
                           "[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\\]--"
                           "\\[[0-9-]+ [A-Za-z]+ "
                           "[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\\] =>")
                   text))
          ;; the exact seconds still ride in the property beside it
          (should (string-match-p "^:RESPONSE: 45$" text))
          ;; and Org still reads exactly one clock node from the line
          (should (= 1 (ao--count-nodes 'clock)))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-ctrl-c-ctrl-c-keeps-clock-seconds ()
  "Our `C-c C-c' refreshes a CLOCK line's duration without eating its seconds.
Org's own handler (`org-clock-update-time-maybe', reached from
`org-ctrl-c-ctrl-c') re-parses the stamps through `org-parse-time-string' --
which DROPS seconds -- and rewrites them in `org-time-stamp-formats'
(minute-granular); measured on Org 9.7.11, a `[00:30:12]--[00:30:57]' line came
back `[00:30]--[00:30]'.  User order 2026-10-14: \"We also need our own C-c C-c,
which won't delete seconds from CLOCK line\".  The duration here is deliberately
WRONG (`0:00' for a 135 s range) so the recompute is visible: it becomes `0:02'
while the stamps -- and the seconds -- are untouched.  Off a CLOCK line the
command IS `org-ctrl-c-ctrl-c', which the stub at the end pins."
  (with-temp-buffer
    (org-mode)
    (insert "* R\n:PROPERTIES:\n:RESPONSE: 135\n:END:\n:LOGBOOK:\n"
            "CLOCK: [2026-10-14 Wed 00:30:12]--[2026-10-14 Wed 00:32:27] =>  0:00\n"
            ":END:\n\n- not a clock\n")
    (goto-char (point-min))
    (re-search-forward "^CLOCK: ")
    (agent-org-ctrl-c-ctrl-c)
    (should (equal "CLOCK: [2026-10-14 Wed 00:30:12]--[2026-10-14 Wed 00:32:27] =>  0:02"
                   (buffer-substring-no-properties (line-beginning-position)
                                                   (line-end-position))))
    ;; off a CLOCK line it delegates to Org, unchanged
    (let ((called nil))
      (cl-letf (((symbol-function 'org-ctrl-c-ctrl-c)
                 (lambda () (interactive) (setq called t))))
        (goto-char (point-max))
        (forward-line -1)
        (agent-org-ctrl-c-ctrl-c)
        (should called)))))

(ert-deftest test-agent-org-clock-lines-never-print-a-negative-range ()
  "A START after `now' — a clock step, an NTP jump, a fall-back across DST —
must not write `=>  0:-43' into a transcript.  Found by fuzzing the writer over
20k random turns: every past start agreed with its own stamps (the duration is
computed FROM them), a future one was the single shape that came out negative —
and Org reads no such clock, so the line would look like a range and be invisible
to every clock tool.  The range is clamped at zero; the property keeps the exact
seconds, which are clamped the same way."
  (let ((lines (agent-org-buffer--clock-lines
                (time-add (current-time) (seconds-to-time 2600)) "RESPONSE")))
    (should (ao--clock-line-p lines))
    (should (string-match-p " =>  0:00$" lines))
    (should-not (string-match-p "=>  -" lines))
    (should (string-match-p "^:RESPONSE: 0$" lines))))

(ert-deftest test-agent-org-each-exchange-gets-its-own-clock ()
  "Two exchanges, two clocks — and the first is untouched by the second.
The stamp is TURN state like the tool board: each `begin-exchange' takes a
fresh one and each boundary spends it, so a close can never attribute one
turn's elapsed time to another heading.

`ao--send-one' leaves the SESSION streaming (only the wire's turn-end
callback clears it), so between the two exchanges the test clears
`:streaming' exactly as that callback would — otherwise the second prompt
would be QUEUED behind a turn the buffer had already closed.  Both rewinds
are whole minutes, so each `CLOCK:' duration is deterministic whatever
second the suite runs in; a sub-minute answer would honestly round to
`0:00' with the true seconds only in the property."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (ao--send-one "First?")
        (ao--rewind-turn-start 4500)
        (agent-org-buffer-append-chunk buf "One.\n" (agent-org-buffer--session))
        (agent-org-buffer-end-agent-turn buf)
        (setf (plist-get (agent-org-buffer--session) :streaming) nil)
        (ao--send-one "Second?")
        (ao--rewind-turn-start 3600)
        (agent-org-buffer-append-chunk buf "Two.\n" (agent-org-buffer--session))
        (agent-org-buffer-end-agent-turn buf)
        (should (equal 2 (ao--count-occurrences (buffer-string) "^CLOCK: ")))
        (should (equal 1 (ao--count-occurrences (buffer-string)
                                                ":RESPONSE: 4500$")))
        (should (equal 1 (ao--count-occurrences (buffer-string)
                                                ":RESPONSE: 3600$")))
        ;; the first exchange keeps its own numbers, in its own place
        (should (apply #'ao--ordered (buffer-string)
                       (list "^\\* RESPONDED First\\?$" ":RESPONSE: 4500$"
                             "^CLOCK: \\[" " =>  1:15$"
                             "One"
                             "^\\* RESPONDED Second\\?$" ":RESPONSE: 3600$"
                             "^CLOCK: \\[" " =>  1:00$"
                             "Two"))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-replayed-exchanges-carry-no-clock ()
  "A restored session has no timing to invent, so it gets no clock.
User order behind the whole feature is \"the total response time of the
agent SINCE THE PROMPT WERE SENT\" — a replay carries neither moment, and a
clock computed from `session/load' wall time would be a fabricated
measurement filed under real ones.  The exchanges still render identically
(that is the replay test above); only the clock is withheld."
  (ao--capture-wire
    (let ((buf (agent-org-resume-session 'qoder "sid-clock")))
      (let ((session (agent-org--session-for-buffer buf)))
        (ao--drive "initialize" ao--fake-init-resp)
        (ao--drive "session/load" '((sessionId . "sid-clock")))
        (dolist (update
                 (list '((sessionUpdate . "user_message_chunk")
                         (content . ((type . "text") (text . "Asked"))))
                       '((sessionUpdate . "agent_message_chunk")
                         (content . ((type . "text") (text . "Answered.\n"))))))
          (agent-org--on-notification session (ao--update-notif update)))
        (ao--settle)
        (with-current-buffer buf
          ;; the exchange is there...
          (should (equal 1 (ao--count-occurrences (buffer-string)
                                                  "^\\* RESPONDED Asked$")))
          ;; ...and no clock or RESPONSE property anywhere in it
          (should-not (string-match-p "^CLOCK: " (buffer-string)))
          (should-not (string-match-p ":RESPONSE:" (buffer-string)))
          (should-not (string-match-p "^:LOGBOOK:$" (buffer-string)))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-response-clock-does-not-block-org-clocking ()
  "Our completed clocks leave Org's own clock machinery free.
User order: \"Your clocking MUSTN'T block user's Org clocking.  You should
make separate commands for response clocking based on Org's clocking code.\"
The separation is by FORM, not by hooking around Org: we never call
`org-clock-in', and a COMPLETED `CLOCK:' line (start AND end AND duration)
is not the state `org-clock' hunts for — an unfinished one
(`CLOCK: [start]' with no `--') would be, making every chat look like a
running clock after `org-clock-load' and refusing the user their own.
Proved on the transcript copy (the file is where a person actually
clocks): entering and leaving a real clock on a clocked exchange adds
Org's line and changes nothing ours, and `org-clock-is-active' stays nil
before and after for as long as we only ever wrote closed ranges.
(`org-clock-current-task' no longer exists in this Org; `org-clock-is-active'
is the supported predicate for \"is the one global running-clock slot taken\".)"
  (require 'org-clock)
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (ao--send-one "Capital?")
        (ao--rewind-turn-start 4500)
        (agent-org-buffer-append-chunk buf "Paris.\n" (agent-org-buffer--session))
        (agent-org-buffer-end-agent-turn buf)
        (let ((text (buffer-substring-no-properties (point-min) (point-max))))
          (with-temp-buffer
            (org-mode)
            ;; no persist file, no clock left running in the batch session:
            ;; org-clock's state is GLOBAL, so a leaked running clock here
            ;; would be exactly the blocking this test must not itself cause
            (let ((org-clock-persist nil))
              (unwind-protect
                  (progn
                    (insert text)
                    ;; a closed clock is not a running one
                    (should-not (org-clock-is-active))
                    (goto-char (point-min))
                    (re-search-forward "^\\* RESPONDED Capital\\?$")
                    (org-clock-in)
                    (should (org-clock-is-active))
                    (org-clock-out)
                    (should-not (org-clock-is-active))
                    ;; ours survived untouched, and Org added its own range
                    (should (equal "4500"
                                   (save-excursion
                                     (goto-char (point-min))
                                     (re-search-forward "^\\* RESPONDED Capital\\?$")
                                     (org-entry-get (point) "RESPONSE"))))
                    (should (string-match-p ":RESPONSE: 4500$" (buffer-string)))
                    (should (>= (ao--count-nodes 'clock) 2)))
                (when (org-clock-is-active) (org-clock-cancel))))))
        (kill-buffer buf)))))

(defun ao--open-clock-count (&optional string)
  "Number of OPEN `CLOCK:' lines in STRING (this buffer by default).
An open line is Org's `CLOCK: [start]' with no `--' range: what a running
activity wears (see `agent-org-buffer--clock-open-lines') and the one shape a
turn boundary must never leave behind."
  (ao--count-occurrences (or string (buffer-string)) "^CLOCK: \\[[^]]*\\]$"))

(ert-deftest test-agent-org-exchange-opens-its-clock-under-the-heading ()
  "While the agent is still answering, the exchange shows a RUNNING clock.
User order (2026-10-11): \"You shouldn't insert the whole `CLOCK:' in the end.
Start by adding the beginning timestamp.  Then, add the ending time with
duration in the end.\"  So `agent-org-buffer-begin-exchange' files the block the
moment the heading exists, in Org's own open form, and the boundary rewrites
those two lines instead of laying a drawer over text that has moved since.
The property reads 0 because the measurement is not over: the seconds arrive
with the close, and Org's own reader sees one real `clock' node either way."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (ao--send-one "Capital?")
        (should (apply #'ao--ordered (buffer-string)
                       (list "^\\* \\(?:PROMPT\\|RESPONDING\\) Capital\\?$"
                             "^:PROPERTIES:$"
                             "^:RESPONSE: 0$"
                             "^:END:$"
                             "^:LOGBOOK:$"
                             "^CLOCK: \\["
                             "^:END:$")))
        (should (= 1 (ao--open-clock-count)))
        (should (= 0 (ao--count-occurrences (buffer-string)
                                            "^CLOCK: \\[.*\\]--")))
        (should (= 1 (ao--count-nodes 'clock))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-turn-boundary-completes-the-open-clock-line ()
  "Closing a turn SHUTS the line it opened -- one drawer, one clock, same stamp.
The whole point of writing the beginning early is that the close is an edit in
place: the stamp the user watched while the agent worked is still the stamp the
range opens with, no second `:PROPERTIES:' appears under the heading, and Org
parses exactly one `clock' node for the exchange.  A second clock on one heading
is not a cosmetic problem -- every Org total bills it twice.
Idempotence is the other half of the order: re-running the completion on a block
that is already shut answers nil and changes no byte, because the search finds an
open line or nothing at all."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (ao--send-one "Capital?")
        (let ((stamp (save-excursion
                       (goto-char (point-min))
                       (re-search-forward "^CLOCK: \\(\\[[^]]*\\]\\)$" nil t)
                       (match-string 1))))
          (should stamp)
          (agent-org-buffer-append-chunk buf "Paris.\n"
                                         (agent-org-buffer--session))
          (agent-org-buffer-end-agent-turn buf)
          ;; the open line is gone, replaced in place by the closed range that
          ;; BEGINS with the very stamp that was written at the heading.  Every
          ;; count below is taken over the EXCHANGE SUBTREE, because the buffer
          ;; also carries the auto-managed metadata block at its top, which has
          ;; a `:PROPERTIES:' drawer of its own.
          (let ((sub (save-excursion
                       (goto-char (point-min))
                       (re-search-forward "^\\* .*Capital\\?$")
                       (buffer-substring-no-properties (line-beginning-position)
                                                       (point-max)))))
            (should (= 0 (ao--open-clock-count sub)))
            (should (= 1 (ao--count-occurrences sub "^CLOCK: ")))
            (should (= 1 (ao--count-occurrences sub "^:LOGBOOK:$")))
            (should (= 1 (ao--count-occurrences sub "^:PROPERTIES:$")))
            ;; TWO closers, one per drawer: `:PROPERTIES:' and `:LOGBOOK:'
            (should (= 2 (ao--count-occurrences sub "^:END:$"))))
          (should (string-match-p (concat "^CLOCK: " (regexp-quote stamp)
                                          "--\\[.*\\] =>  [0-9]+:[0-9][0-9]$")
                                  (buffer-string)))
          (should (= 1 (ao--count-nodes 'clock)))
          ;; and a completion attempted against the shut block edits NOTHING
          (let ((before (buffer-string))
                (inhibit-read-only t))
            (save-excursion
              (goto-char (point-min))
              (re-search-forward "^\\* .*Capital\\?$")
              (forward-line 1)
              (should-not (agent-org-buffer--clock-complete
                           (current-time)
                           agent-org-clock--exchange-property)))
            (should (equal before (buffer-string))))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-open-clock-does-not-block-org-clocking ()
  "AN OPEN `CLOCK:' is still not a running Org clock -- the measurement.
Section 22 refused open lines for years on the belief that `org-clock-load'
would adopt one, making every chat look like a clock the user had started and
`org-clock-in' refuse to run.  That belief is tested here so the claim stays
earned: with an open line in the buffer `org-clock-is-active' is nil,
`org-clock-sum' counts the open line as zero minutes, `org-clock-in' on the
exchange heading succeeds, and `org-clock-out' files Org's own range next to
ours.  The user's order that started this -- \"Your clocking MUSTN'T block
user's Org clocking\" -- is what all four assertions are about.
`org-clock-persist' nil keeps the batch session from leaving a clock running
for the next test, which would be the very blocking this test forbids."
  (require 'org-clock)
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (ao--send-one "Capital?")
        (let ((text (buffer-substring-no-properties (point-min) (point-max))))
          (with-temp-buffer
            (org-mode)
            (let ((org-clock-persist nil))
              (unwind-protect
                  (progn
                    (insert text)
                    (should (= 1 (ao--open-clock-count)))
                    (should-not (org-clock-is-active))
                    ;; our open line counts as nothing in Org's own arithmetic
                    (should (= 0 (org-clock-sum (point-min) (point-max)
                                                #'always)))
                    (goto-char (point-min))
                    (re-search-forward "^\\* \\(?:PROMPT\\|RESPONDING\\) Capital\\?$")
                    (org-clock-in)
                    (should (org-clock-is-active))
                    (org-clock-out)
                    (should-not (org-clock-is-active))
                    ;; ours is untouched, and Org filed its own range beside it
                    (should (= 1 (ao--open-clock-count)))
                    (should (>= (ao--count-nodes 'clock) 2)))
                (when (org-clock-is-active) (org-clock-cancel)))))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-part-opens-its-clock-while-it-streams ()
  "A part of an answer is clocked from the moment its heading appears.
The exchange is not the only activity the user asked to see measured: under
`agent-org-activity-style' `headings' a thought, a call and the prose each get
their own block, and all three of them open it early and shut it at the same
boundary the exchange does.  Asserted both ways round: mid-turn the part's
`:SECONDS:' is 0 on an open line; after the turn every part heading carries a
closed range and no open line survives anywhere."
  (let ((agent-org-activity-style 'headings)
        (buf (agent-org-buffer-create "partopen")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-thought buf "weighing it")
    (with-current-buffer buf
      (should (apply #'ao--ordered (buffer-string)
                     (list "^\\*\\* \\(?:THOUGHT\\|PONDERRING\\|THINKING\\) Thinking$"
                           "^:PROPERTIES:$"
                           "^:SECONDS: 0$"
                           "^:END:$"
                           "^:LOGBOOK:$"
                           "^CLOCK: \\["
                           "^:END:$")))
      (should (= 1 (ao--open-clock-count))))
    (agent-org-buffer-end-agent-turn buf)
    (with-current-buffer buf
      (should (= 0 (ao--open-clock-count)))
      (should (= 1 (ao--count-occurrences (buffer-string) "^CLOCK: ")))
      (should (ao--clock-line-p (buffer-string)))
      (should (= 1 (ao--count-nodes 'clock))))
    (kill-buffer buf)))


;;;; Clock display: the `org-clock-display' fork, with the seconds Org throws away
;;
;; User order (2026-10-11): "Also fork org-clock-display command and enable it by
;; default which will show total clocked time with seconds in headings."  The
;; fork is arithmetic, not taste, and the first test below measures it: a
;; 45-second answer is `0:00' in Org's own clock report and `0:00:45' here.  The
;; SECONDS themselves come from `:RESPONSE:', not from the `CLOCK:' line — that
;; line stays in the minute shape Org 9.7.11 parses, because a stamp or duration
;; with seconds in it yields zero `clock' nodes and would hide every exchange
;; from `org-clock-sum', a clocktable and `org-clock-load'.  What the rest of the
;; section pins is the two things that make this safe to leave ON by default in a
;; chat: the totals are OVERLAYS, so the buffer's bytes -- the transcript mirror,
;; the queue parse, every repaint marker -- are untouched, and the numbers come
;; from the seconds §22 already files rather than from a fabrication.

(defun ao--clock-overlays ()
  "This buffer's clock-display strings, in the order their headings sit.
Filtered by `category', so a test asserts on OUR overlays and not on whatever
else is decorating the buffer (an isearch lazy highlight is one of them, and
`org-clock-display' itself is another -- the two are allowed to coexist)."
  (mapcar (lambda (o) (overlay-get o 'display))
          (ao--clock-overlay-positions)))

(defun ao--clock-overlay-positions ()
  "This buffer's clock-display OVERLAYS, in the order their headings sit.
The overlays themselves, sorted by position -- for a test that needs to know
where the total sits as well as what it says (the right-alignment shape).
`ao--clock-overlays' is the display-text sugar over this."
  (let ((found nil))
    (dolist (o (overlays-in (point-min) (point-max)))
      (when (eq (overlay-get o 'category) agent-org-clock--overlay-category)
        (push (cons (overlay-start o) o) found)))
    (mapcar #'cdr (sort found (lambda (a b) (< (car a) (car b)))))))

(defun ao--clock-exchange-heading ()
  "The headline text of this chat's first level-1 heading -- past the stars.
Read from the buffer rather than hard-coded, because the keyword the renderer
gave the turn is not these tests' business: `* PROMPT' while the answer runs,
`* RESPONDED' once it is filed, and a part heading is level 2 so it never
matches here.  The stars are not part of it for the same reason
`agent-org-clock--overlay-text' does not cover them: the overlay starts past
the stars, so the stars are not in the display."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "^\\*+ " nil t)
      (buffer-substring-no-properties (point) (line-end-position)))))

(defun ao--clock-string (heading column seconds)
  "The `display' string a heading with SECONDS of clocked time must show.
The right-aligned shape `agent-org-clock--overlay-text' builds -- headline
text, `?'-padding up to the column where Org's own clock display puts its
duration, ` H:MM:SS ' -- so a test can say what it expects without repeating
the padding arithmetic.  Written as a helper rather than inline so every
assertion uses the ONE definition of the shape.

HEADING is the headline TEXT, not the whole line: the stars are outside the
overlay, so the stars are outside the expected display.  COLUMN is where that
text starts -- 2 for a level-1 `* ' heading -- because the padding is measured
from there, exactly as `org-clock-put-overlay' measures it at its own overlay
start: `60 - COLUMN - (string-width HEADING)' dots puts the duration at column
60, so a deeper heading pads FEWER dots and its duration still lands on 60."
  (concat heading
          (make-string (max 0 (- 60 column (string-width heading))) ?\u00b7)
          (format " %s " (agent-org-clock--format seconds))))

(ert-deftest test-agent-org-clock-format-shows-seconds ()
  "The duration is H:MM:SS, built from SECONDS and never from minutes.
`org-duration-from-minutes' is the Org route and it takes a MINUTES argument —
which is precisely where the precision dies — so this formatter is the whole
display vocabulary and is pinned here in the abstract: 45 is `0:00:45', not
`0:00', and a negative range prints zeros rather than a minus sign inside a
heading."
  (should (equal "0:00:00" (agent-org-clock--format 0)))
  (should (equal "0:00:45" (agent-org-clock--format 45)))
  (should (equal "0:01:00" (agent-org-clock--format 60)))
  (should (equal "0:59:59" (agent-org-clock--format 3599)))
  (should (equal "1:01:01" (agent-org-clock--format 3661)))
  (should (equal "2:02:02" (agent-org-clock--format 7322)))
  (should (equal "0:00:00" (agent-org-clock--format -5))))

(ert-deftest test-agent-org-clock-display-org-rounds-our-seconds-away ()
  "THE reason for the fork, measured in the suite: Org's own sum of a 45-second
clock in this buffer is 0 MINUTES, while our display of the same heading reads
`0:00:45'.  If a future Org starts counting seconds, the first assertion fails
loudly here instead of the fork quietly becoming redundant."
  (require 'org-clock)
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (ao--send-one "Capital?")
        (ao--rewind-turn-start 45)
        (agent-org-buffer-append-chunk buf "Paris.\n" (agent-org-buffer--session))
        (agent-org-buffer-end-agent-turn buf)
        (should (equal "45" (save-excursion
                              (goto-char (point-min))
                              (re-search-forward "^\\* \\(?:PROMPT\\|RESPONDED\\) Capital\\?$")
                              (org-entry-get nil "RESPONSE"))))
        ;; Org's arithmetic, on our own buffer, in minutes: 45 s is nothing.
        (should (= 0 (org-clock-sum (point-min) (point-max) #'always)))
        ;; ours, on the same heading: the seconds survive.
        (should (member (ao--clock-string (ao--clock-exchange-heading) 2 45)
                                   (ao--clock-overlays))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-clock-display-is-on-in-a-new-chat ()
  "A chat opens with the display enabled, and the option is what seeds it.
`agent-org-clock-display-default' is read once, in `agent-org-mode', and the
mode is BUFFER-local: a global minor mode would decorate the headings of files
this package does not own, which is the difference between \"on by default\" and
\"on everywhere\"."
  (should agent-org-clock-display-default)
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (should agent-org-clock-display-mode))
      ;; an ordinary Org buffer is untouched by a chat's default
      (with-temp-buffer
        (org-mode)
        (should-not agent-org-clock-display-mode))
      (kill-buffer buf))))

(ert-deftest test-agent-org-clock-display-never-touches-the-buffers-bytes ()
  "The transcript is a mirror of the buffer, so a display must not add TEXT.
Overlays are why this can be on by default: `buffer-substring-no-properties' --
what `agent-org-buffer-transcribe' writes, what the queue parser reads, what
every repaint marker bounds -- sees the same bytes with the totals drawn and
without them.  Asserted both ways: the copy is unchanged, and no total appears
in it."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (ao--send-one "Capital?")
        (ao--rewind-turn-start 45)
        (agent-org-buffer-append-chunk buf "Paris.\n" (agent-org-buffer--session))
        (agent-org-buffer-end-agent-turn buf)
        (let ((with-display (buffer-substring-no-properties (point-min) (point-max))))
          (should (ao--clock-overlays))
          (should-not (string-match-p " \\[0:00:45\\]" with-display))
          (agent-org-clock-display-mode -1)
          (should-not (ao--clock-overlays))
          (should (equal with-display
                         (buffer-substring-no-properties (point-min) (point-max))))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-clock-display-aligns-the-total-right-like-org ()
  "The total sits at the RIGHT of the heading, the way `org-clock-display' does.
THE user order (2026-10-13): /\"Your clock display overlay isn't looking like
Org's.  The clock should be right aligned in the heading.\"/  The measurement
is a `display' overlay over the heading line's text, not an `after-string'
at its end: Org's own `org-clock-put-overlay' (org-clock.el) builds headline
+ `?'-padding to column 60 + ` %9s ' in the `org-clock-overlay' face, and a
fork that aims to look like Org has to use the same shape or the numbers
have nothing in common but the word.

So this test pins five things, and the first is the one that fails until the
draw is rewritten: the overlay SPANS the heading's text but starts PAST the
stars -- a zero-width `after-string' covers no position (which is how the old
left-aligned ` [0:00:45]' worked) and one over the WHOLE line would show the
stars unfaced, because an overlay REPLACES what it covers -- the `display'
text ends with the duration in the form ` 0:00:12 ', the padding between
headline and duration is all `?' (Org's middle dot; a run of plain spaces
would collapse the alignment the moment a heading is short), that padding is
EXACTLY what column 60 has left once the heading's own columns are spent, and
the `display' string STARTS with the heading's own text so the heading itself
is still on screen."
  (with-temp-buffer
    (org-mode)
    (insert "* Someone's own clock\n:LOGBOOK:\nCLOCK: [2026-10-11 Sun 10:00:00]--[2026-10-11 Sun 10:00:12] =>  0:00:12\n:END:\nsome body text\n")
    (agent-org-clock-display-mode 1)
    (let* ((ov (car (ao--clock-overlay-positions)))
           (bol (save-excursion (goto-char (point-min))
                                (line-beginning-position)))
           (eol (save-excursion (goto-char (point-min))
                                (line-end-position)))
           ;; where the overlay begins: past the stars, exactly where
           ;; `agent-org-clock--draw' starts it and `org-clock-put-overlay'
           ;; starts its own
           (text-beg (save-excursion (goto-char bol)
                                     (looking-at "[*]+ ")
                                     (match-end 0)))
           (disp (overlay-get ov 'display))
           ;; the heading's own bytes: what the display must begin with
           (text (buffer-substring-no-properties text-beg eol)))
      (should ov)
      ;; (a) the overlay spans the heading's TEXT, not a zero-width point
      (should (= (overlay-start ov) text-beg))
      (should (= (overlay-end ov) eol))
      ;; (b) the stars are outside it, so they are outside the display: the
      ;; display replaces the text after them, and covering a `*' would show
      ;; it as plain text with no `org-level-1' face
      (should-not (string-prefix-p "*" disp))
      ;; (c) the heading's own bytes are the prefix of what is displayed
      (should (string-prefix-p text disp))
      ;; (d) the duration is the LAST thing, in Org's padded shape
      (should (string-suffix-p " 0:00:12 " disp))
      (let ((pad (substring-no-properties
                  disp (length text)
                  (- (length disp) (length " 0:00:12 ")))))
        ;; the padding char, by CODEPOINT: a `?' in the source would be the
        ;; regexp optional operator and silently match nothing
        (should (string-match-p "\\`\u00b7+\\'" pad))
        (should (string-match-p "\\`[[:multibyte:]]+\\'" pad))
        ;; and it is exactly the remainder of column 60: the duration starts
        ;; where Org's own does, so this headline's 20 columns plus the 2 of
        ;; `* ' leave 60 - 22 dots for the rest
        (should (= 60 (+ 2 (length text) (length pad)))))
      ;; (e) the duration wears Org's own clock face, not ours
      (let ((face (get-text-property (1- (length disp)) 'face disp)))
        (should (eq face 'org-clock-overlay))))))

(ert-deftest test-agent-org-clock-display-keeps-the-queue-and-transcript-clean ()
  "The right-alignment is still an overlay, so the bytes the mirror and the queue
parser read are unchanged.  This is the same measurement as the
`never-touches-the-buffers-bytes' test, repeated for the `display' shape because
a `display' that instead replaced a heading's text would break both at once and
the alignment fix is exactly where that mistake would creep in."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (ao--send-one "Capital?")
        (ao--rewind-turn-start 45)
        (agent-org-buffer-append-chunk buf "Paris.\n" (agent-org-buffer--session))
        (agent-org-buffer-end-agent-turn buf)
        (let ((before (buffer-substring-no-properties (point-min) (point-max))))
          (should (ao--clock-overlay-positions))
          (should (equal before
                         (buffer-substring-no-properties (point-min) (point-max))))
          (should-not (string-match-p "0:00:45" before))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-clock-display-reads-a-clock-the-user-filed ()
  "A hand-written CLOSED `CLOCK:' range with no `:RESPONSE:' still shows up, to
THE SECOND.  §22's rule is that our recording must never block the user's own
Org clocking; the display follows it by summing the heading's LOGBOOK when there
is no property -- and an OPEN range stays invisible, because a running clock is
the user's and an invented end would be a number that changes on its own.
Twelve seconds is the assertion that matters: `org-parse-time-string' in Org
9.7.11 answers (0 0 10 …) for a `:SS' stamp, so a range that Org itself reads as
zero must be read here by `agent-org-clock--stamp-time' instead."
  (with-temp-buffer
    (org-mode)
    (insert "* Someone's own clock\n:LOGBOOK:\nCLOCK: [2026-10-11 Sun 10:00:00]--[2026-10-11 Sun 10:00:12] =>  0:00:12\n:END:\nsome body text\n")
    (agent-org-clock-display-mode 1)
    (should (equal (list (ao--clock-string "Someone's own clock" 2 12))
                   (ao--clock-overlays)))
    (erase-buffer)
    (insert "* A running clock\n:LOGBOOK:\nCLOCK: [2026-10-11 Sun 10:00:00]\n:END:\n")
    (agent-org-clock--draw)
    (should-not (ao--clock-overlays))
    ;; Org's OWN stamp shape (minute only, as `org-clock-in' writes it) still
    ;; reads correctly through the fallback in `agent-org-clock--stamp-time'
    (erase-buffer)
    (insert "* A minute clock\n:LOGBOOK:\nCLOCK: [2026-10-11 Sun 10:00]--[2026-10-11 Sun 10:05] =>  0:05\n:END:\n")
    (agent-org-clock--draw)
    (should (equal (list (ao--clock-string "A minute clock" 2 300))
                   (ao--clock-overlays)))))

(ert-deftest test-agent-org-clock-display-total-counts-exchanges-not-parts ()
  "The reported total is the sum of level-1 headings, never parts on top.
A turn's thinking and tool parts each clock their own seconds INSIDE the
exchange's `:RESPONSE:', so adding both would bill the user for the same time
twice; each part heading still shows its own number.  Parts only exist under
`agent-org-activity-style' `headings' — the suite's global binding is `drawers',
where a thought is a drawer and no second heading is clocked at all."
  (let ((agent-org-activity-style 'headings))
    (ao--capture-wire
      (let ((buf (ao--chat-on-model "qmodel" "QModel")))
        (with-current-buffer buf
          (ao--send-one "Capital?")
          (ao--rewind-turn-start 45)
          (agent-org-buffer-append-thought buf "Recalling…\n")
          (agent-org-buffer-append-chunk buf "Paris.\n" (agent-org-buffer--session))
          (agent-org-buffer-end-agent-turn buf)
          (let ((strings (ao--clock-overlays)))
            ;; more than one heading decorated: the exchange and its parts
            (should (> (length strings) 1))
            (should (member (ao--clock-string (ao--clock-exchange-heading) 2 45)
                             strings))
            (should (= 45 (cdr agent-org-clock--last-counts)))))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-clock-display-skipped-in-lite-mode ()
  "Lite mode refuses the per-boundary pass, so a lite chat shows no totals.
The display recomputes the buffer once per turn, which is exactly the kind of
work §19 exists to decline; the mode variable stays on (it is the user's choice,
not lite's), so turning lite off brings the numbers back with the next boundary."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (setq agent-org-buffer--lite 'on)
        (ao--send-one "Capital?")
        (ao--rewind-turn-start 45)
        (agent-org-buffer-append-chunk buf "Paris.\n" (agent-org-buffer--session))
        (agent-org-buffer-end-agent-turn buf)
        ;; the seconds were filed, only the display was declined
        (should (string-match-p ":RESPONSE: 45" (buffer-string)))
        (should-not (ao--clock-overlays))
        (agent-org-clock--draw)
        (should (member (ao--clock-string (ao--clock-exchange-heading) 2 45)
                                   (ao--clock-overlays))))
      (kill-buffer buf))))

(ert-deftest test-agent-org-clock-display-toggles-and-prefix-arg-forces-off ()
  "The command is the way out of a display that is on by default.
No argument toggles; a prefix argument means OFF, which is the shape §6 asks of
a command whose default is on -- the gesture the user presses when the totals are
noise must never be the one that adds them."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (ao--send-one "Capital?")
        (ao--rewind-turn-start 45)
        (agent-org-buffer-append-chunk buf "Paris.\n" (agent-org-buffer--session))
        (agent-org-buffer-end-agent-turn buf)
        (should agent-org-clock-display-mode)
        (agent-org-clock-display nil)                  ; off
        (should-not agent-org-clock-display-mode)
        (should-not (ao--clock-overlays))
        (agent-org-clock-display nil)                  ; on again, redrawn
        (should agent-org-clock-display-mode)
        (should (member (ao--clock-string (ao--clock-exchange-heading) 2 45)
                                   (ao--clock-overlays)))
        (agent-org-clock-display t)                    ; C-u: force off
        (should-not agent-org-clock-display-mode)
        (should-not (ao--clock-overlays)))
      (kill-buffer buf))))

(ert-deftest test-agent-org-clock-display-key-hangs-under-the-prefix ()
  "C-c a c reaches the fork, and no Org command is in its way.
`test-agent-org-mode-map-shadows-no-org-binding' walks the whole map; this pins
the one key a user needs for a feature that is on by default."
  (should (eq #'agent-org-clock-display
              (lookup-key agent-org-mode-map (kbd "C-c a c")))))

;;;; Sticky prompt headings: the exchange you are reading stays at the top
;;
;; User order (2026-10-13): "Add feature to stick prompt headings to the top as
;; buffer is scrolled down.  They will be contained in one line and truncated
;; when scrolled down."  Emacs 30.2 has no native sticky line — `sticky' in the
;; manuals is either a text-property (rear/front-nonsticky) or a frame parameter
;; — so this is a `window-scroll-functions' hook feeding an extra header-line
;; row, which is why the tests call the builder with an explicit TOP: the
;; position a window's top edge has is the whole input the feature needs.

(defmacro ao--sticky-buffer (mode &rest body)
  "Run BODY in a two-exchange fixture buffer, a chat when MODE.
A macro because the fixture is a TEMPORARY buffer: a function returning it hands
back a buffer `with-temp-buffer' has already killed, and every assertion then
runs in a dead buffer -- which is how this helper first went red.
MODE non-nil puts the buffer in `agent-org-mode', which the hook tests need; the
builder itself is a pure function of buffer text and a window position, so its
tests want no mode, no wire and no process.
The body is 40 lines long precisely so a window top can land INSIDE the first
exchange, which is the only state a pin exists for."
  (declare (indent 1))
  `(with-temp-buffer
     (org-mode)
     (when ,mode (agent-org-mode 1))
     (insert "#+TITLE: Sticky\n"
             "* RESPONDED Capital?\n:PROPERTIES:\n:RESPONSE: 45\n:END:\n")
     (dotimes (n 40)
       (insert (format "answer line %d\n" (1+ n))))
     (insert "* RESPONDED Weather?\n:PROPERTIES:\n:RESPONSE: 12\n:END:\nsunny\n")
     ,@body))

(defun ao--sticky-top (needle)
  "Buffer position of NEEDLE's line start, in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (search-forward needle)
    (line-beginning-position)))

(defun ao--sticky-text (line)
  "The property-free text of a pinned heading LINE, for `equal' assertions.
The builder faces the row it returns -- a header line has to look like a heading
-- and `equal' on strings compares text properties too, so a test that wants the
WORDS would fail for the wrong reason."
  (when line (substring-no-properties line)))

(ert-deftest test-agent-org-sticky-pins-the-prompt-whose-body-is-on-screen ()
  "Scrolled into an answer, its own prompt is what belongs at the top.
One heading per exchange (§1) means the question is the heading — so while you
read 40 lines of an answer, the buffer says nothing about what was asked.  The
pin is that heading line, verbatim."
  (ao--sticky-buffer nil
    (should (equal "* RESPONDED Capital?"
                   (ao--sticky-text
                    (agent-org-buffer--sticky-heading-at
                     (ao--sticky-top "answer line") 80))))
    (should (equal "* RESPONDED Weather?"
                   (ao--sticky-text
                    (agent-org-buffer--sticky-heading-at
                     (ao--sticky-top "sunny") 80))))))

(ert-deftest test-agent-org-sticky-stays-away-while-the-heading-is-visible ()
  "Two cases have nothing to pin, and both are the common ones.
TOP on the heading line itself: it is already on the page, and a second copy of
it is noise.  TOP above the first heading — the metadata block (§2) — where no
prompt has been scrolled past yet.  A sticky row that appears when there is
nothing above is the failure mode this rule exists to prevent."
  (ao--sticky-buffer nil
    (should-not (agent-org-buffer--sticky-heading-at
                 (ao--sticky-top "* RESPONDED Weather?") 80))
    (should-not (agent-org-buffer--sticky-heading-at (point-min) 80))))

(ert-deftest test-agent-org-sticky-is-one-line-and-truncated-to-the-window ()
  "\"Contained in one line and truncated when scrolled down\" is the order, and
a header-line row that WRAPS would push the status row off the bar.  The width
argument is the window's body width in the live path; here it is 40, so a
hundred-column prompt must come back as at most 40 columns, on one line, with
the ellipsis marking that there is more."
  (let ((long (make-string 120 ?q)))
    (ao--sticky-buffer nil
      (erase-buffer)
      (insert "* RESPONDED " long "\n\nbody text\n")
      (let ((line (agent-org-buffer--sticky-heading-at
                   (ao--sticky-top "body text") 40)))
        (should line)
        (should (= 1 (length (split-string line "\n" t))))
        (should (<= (string-width line) 40))
        (should (string-suffix-p agent-org-sticky-heading-ellipsis line))
        ;; a heading that fits is NOT decorated: an ellipsis on a short prompt
        ;; would say "there is more" when the whole thing is on the bar
        (let ((short (agent-org-buffer--sticky-heading-at
                      (ao--sticky-top "body text") 300)))
          (should-not (string-suffix-p agent-org-sticky-heading-ellipsis short))
          (should (string-prefix-p "* RESPONDED " short)))))))

(ert-deftest test-agent-org-sticky-pins-the-exchange-and-not-its-part ()
  "Parts are level-2 headings and the pin is the level-1 one.  A part's heading
(`** ONGOING fetch' etc.) changes every few seconds while the agent works; the
prompt does not, and the prompt is the fact worth holding still."
  (ao--sticky-buffer nil
    (save-excursion
      (goto-char (point-min))
      (re-search-forward "^\\* RESPONDED Capital?")
      (end-of-line)
      (insert "\n** COMPLETE fetch\n  - ran ls\n"))
    (should (equal "* RESPONDED Capital?"
                   (ao--sticky-text
                    (agent-org-buffer--sticky-heading-at
                     (ao--sticky-top "ran ls") 80))))))

(ert-deftest test-agent-org-sticky-searches-at-column-zero-only ()
  "An indented `*' is text, not a heading, and the search must know that.
§3.2 is the reason a plain column-0 search is sound in a chat: every
agent-supplied line is indented one space, so a `*' can never start a line
inside an answer.  This pins the other half — that OUR builder does not
rediscover a heading where Org sees none."
  (ao--sticky-buffer nil
    (save-excursion
      (goto-char (point-min))
      (re-search-forward "^\\* RESPONDED Capital?")
      (end-of-line)
      (insert "\n * RESPONDED Faked?\n"))
    (should (equal "* RESPONDED Capital?"
                   (ao--sticky-text
                    (agent-org-buffer--sticky-heading-at
                     (ao--sticky-top "* RESPONDED Faked?") 80))))))

(ert-deftest test-agent-org-sticky-builder-moves-nothing ()
  "The builder is called from a redisplay hook, so it may not touch the buffer.
Point is the user's, the bytes are the transcript's mirror (§14), and a hook
that wrote text would corrupt it: everything here runs inside
`save-excursion' over a read-only search, which is what this asserts."
  (ao--sticky-buffer nil
    (goto-char (point-min))
    (re-search-forward "answer line")
    (let ((pt (point))
          (bytes (buffer-substring-no-properties (point-min) (point-max))))
      (agent-org-buffer--sticky-heading-at (ao--sticky-top "sunny") 80)
      (should (= pt (point)))
      (should (equal bytes
                     (buffer-substring-no-properties (point-min)
                                                     (point-max)))))))

(ert-deftest test-agent-org-sticky-mode-installs-the-scroll-hook-buffer-locally ()
  "The hook is a chat's, not every Org file's.
`window-scroll-functions' runs on every window of every buffer, so a global
entry would search for headlines in the user's notes; the 4th argument makes it
buffer-local, and turning the mode off has to take it back out or a dead chat's
function keeps running in whatever buffer inherits the hook.  A plain `org-mode'
buffer is the control: no entry at all."
  (ao--sticky-buffer t
    (should agent-org-mode)
    (should (local-variable-p 'window-scroll-functions))
    (should (memq #'agent-org-buffer--sticky-update window-scroll-functions))
    (agent-org-mode -1)
    (should-not (memq #'agent-org-buffer--sticky-update
                      window-scroll-functions)))
  (with-temp-buffer
    (org-mode)
    (should-not (memq #'agent-org-buffer--sticky-update
                      window-scroll-functions))))

(ert-deftest test-agent-org-sticky-update-writes-the-pin-and-the-option-deletes-it ()
  "The hook's whole job: one buffer-local string for the header row to show.
`agent-org-sticky-heading' nil must CLEAR a pin that is already up — an option
that only stops NEW pins leaves a stale prompt sitting on the bar of every chat
you already scrolled, which reads as the setting doing nothing."
  (ao--sticky-buffer t
    (agent-org-buffer--sticky-update (selected-window)
                                     (ao--sticky-top "sunny"))
    (should (equal "* RESPONDED Weather?"
                   (ao--sticky-text agent-org-buffer--sticky-heading)))
    (let ((agent-org-sticky-heading nil))
      (agent-org-buffer--sticky-update (selected-window)
                                       (ao--sticky-top "sunny"))
      (should-not agent-org-buffer--sticky-heading))))

(ert-deftest test-agent-org-sticky-adds-a-row-below-the-status-line ()
  "The status row is untouched: §6's ONE status string, with the pin under it.
A second row is allowed precisely because it is not a status — it is a heading
the buffer already has, shown where the user cannot see it.  Asserted as an
exact equality on the first row, because the concatenation of the two is exactly
where a stray separator or a dropped status field would appear."
  (ao--sticky-buffer t
    (should-not (string-match-p "\n" (agent-org-buffer--render-header-lines)))
    (setq agent-org-buffer--sticky-heading "* RESPONDED Capital?")
    (let ((lines (split-string (agent-org-buffer--render-header-lines) "\n")))
      (should (= 2 (length lines)))
      (should (equal (ao--sticky-text (agent-org-buffer--render-header-line))
                     (ao--sticky-text (car lines))))
      (should (equal "* RESPONDED Capital?" (ao--sticky-text (cadr lines)))))))

(ert-deftest test-agent-org-sticky-is-on-by-default-and-settable ()
  "The feature the user asked for arrives when the package loads, and a
boolean option is the way out.  `setopt' validates it as a boolean so a typo in
the init file fails there rather than silently disabling the row."
  (should (eq t (default-value 'agent-org-sticky-heading)))
  (should (eq 'boolean (get 'agent-org-sticky-heading 'custom-type)))
  (setopt agent-org-sticky-heading nil)
  (should-not (default-value 'agent-org-sticky-heading))
  (setopt agent-org-sticky-heading t))

(ert-deftest test-agent-org-sticky-pins-a-real-exchange-in-a-real-chat ()
  "The builder over a buffer the package itself rendered, not a hand-made one.
`ao--send-one' goes through the real send path, so the heading it pins is the
one `agent-org-buffer-begin-exchange' wrote — keyword, drawer and all.  The
quote block is the body to scroll under, which also proves the pin survives the
`#+begin_quote' furniture it passes on the way."
  (ao--capture-wire
    (let ((buf (ao--chat-on-model "qmodel" "QModel")))
      (with-current-buffer buf
        (ao--send-one "Capital?")
        (agent-org-buffer-append-chunk buf "Paris.\n"
                                       (agent-org-buffer--session))
        (agent-org-buffer-end-agent-turn buf)
        (let* ((bytes (buffer-substring-no-properties (point-min) (point-max)))
               (top (ao--sticky-top "Paris"))
               (pin (agent-org-buffer--sticky-heading-at top 200)))
          (should (and pin (string-match-p "Capital\\?" pin)))
          (should (string-match-p "\\`\\* \\(?:PROMPT\\|RESPONDED\\) Capital\\?\\'"
                                  (ao--sticky-text pin)))
          ;; the same builder, from the hook, lands in the variable the header
          ;; row reads — the two halves of the feature are wired together
          (agent-org-buffer--sticky-update (selected-window) top)
          (should (equal (ao--sticky-text pin)
                         (ao--sticky-text agent-org-buffer--sticky-heading)))
          (should (equal bytes
                         (buffer-substring-no-properties (point-min)
                                                         (point-max))))))
      (kill-buffer buf))))

;;;; Lite mode: the minimum resources, scoped per session or globally
;;
;; User order (TODOs.org): "Add a resource monitor for each session", and "a lite
;; mode which will use absolute minimum resources with per-session/global
;; scoping".  Lite mode is three gates, and none of them is a rendering change:
;; the transcript write (unless a queue is waiting), undo recording, and the
;; whole-buffer Org reparse on every metadata rebuild.  What it does NOT do is
;; stated in `agent-org-lite-mode', because a "lite" mode that switched off
;; font-lock or dropped the agent's reasoning would be a different package.

(defun ao--lite-chat (&optional name)
  "A chat buffer whose session scope starts at `inherit'.
Created directly rather than through `ao--make-test-session', whose session
plist is fixed: the scope is a BUFFER-LOCAL variable, so a fresh buffer is all
this needs."
  (let ((buf (agent-org-buffer-create (or name "lite"))))
    (with-current-buffer buf
      (setq agent-org-buffer--lite 'inherit))
    buf))

(ert-deftest test-agent-org-lite-follows-the-global-setting ()
  "With no scope of its own, a session follows `agent-org-lite-mode'.
The default scope is `inherit' precisely so that flipping the global variable
is a complete answer for the common case of \"make every chat cheap\", with no
per-session bookkeeping to unwind."
  (let ((buf (ao--lite-chat "follow")))
    (with-current-buffer buf
      (let ((agent-org-lite-mode nil))
        (should-not (agent-org-lite-p)))
      (let ((agent-org-lite-mode t))
        (should (agent-org-lite-p))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-lite-session-scope-overrides-the-global ()
  "`on' and `off' pin one session against the global setting, in both directions.
This is the per-session/global scoping the user asked for: the one chat filling
the disk goes lite while the rest stay full, and a global setting of t does not
force itself on a chat that has opted out."
  (let ((buf (ao--lite-chat "scoped")))
    (with-current-buffer buf
      (let ((agent-org-lite-mode nil))
        (setq agent-org-buffer--lite 'on)
        (should (agent-org-lite-p))
        (setq agent-org-buffer--lite 'off)
        (should-not (agent-org-lite-p)))
      (let ((agent-org-lite-mode t))
        (should-not (agent-org-lite-p))
        (setq agent-org-buffer--lite 'on)
        (should (agent-org-lite-p))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-lite-toggle-cycles-the-scope-and-pins-undo ()
  "C-c a l cycles inherit -> on -> off -> inherit, and undo follows the result.
Three states because \"follow the global setting\" has to be reachable again: a
binary toggle would strand a session in an override forever.  Undo recording is
the resource the mode owns outright, so the toggle owns it: a session that
becomes lite stops accumulating undo entries in the same command that says so."
  (let ((buf (ao--lite-chat "cycle")))
    (with-current-buffer buf
      (let ((agent-org-lite-mode nil)
            (inhibit-message t))
        (should (eq agent-org-buffer--lite 'inherit))
        (agent-org-lite-mode-toggle)
        (should (eq agent-org-buffer--lite 'on))
        (should-not buffer-undo-list)
        (agent-org-lite-mode-toggle)
        (should (eq agent-org-buffer--lite 'off))
        (should buffer-undo-list)
        (agent-org-lite-mode-toggle)
        (should (eq agent-org-buffer--lite 'inherit))
        (should buffer-undo-list)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-lite-toggle-with-a-prefix-moves-the-global ()
  "C-u C-c a l flips `agent-org-lite-mode' and leaves every session scope alone.
A session that pinned its own scope must not be dragged along by a global
change, or the per-session setting would be a claim rather than a scope."
  (let ((buf (ao--lite-chat "global")))
    (with-current-buffer buf
      (let ((agent-org-lite-mode nil)
            (inhibit-message t))
        (agent-org-lite-mode-toggle t)
        (should agent-org-lite-mode)
        (should (eq agent-org-buffer--lite 'inherit))
        ;; and now it resolves through the global setting, which moved
        (should (agent-org-lite-p))
        (agent-org-lite-mode-toggle t)
        (should-not agent-org-lite-mode)
        (should-not (agent-org-lite-p))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-lite-word-reads-the-scope ()
  "The monitor's MODE column: Lite, Full, a dot for no scope of its own.
One word per state in one function, because the monitor and the toggle both want
to say the same thing about a session and two spellings of it would drift."
  (let ((buf (ao--lite-chat "word")))
    (with-current-buffer buf
      (should (equal (agent-org-buffer--lite-word buf) "·"))
      (setq agent-org-buffer--lite 'on)
      (should (equal (agent-org-buffer--lite-word buf) "Lite"))
      (setq agent-org-buffer--lite 'off)
      (should (equal (agent-org-buffer--lite-word buf) "Full")))
    (kill-buffer buf)
    ;; a dead buffer has no scope, which is also a dot
    (should (equal (agent-org-buffer--lite-word buf) "·"))))

(ert-deftest test-agent-org-lite-property-line-is-only-there-when-lite ()
  "The metadata block says `:Lite: yes' for a lite session and nothing when full.
A transcript is a record, and how it was being recorded is a fact about it.  The
renderer takes the scope as an ARGUMENT because it is a pure function of the
status plist: reading a buffer-local variable inside it would answer for
whichever buffer happened to be current."
  (let ((status (list :provider "Qoder" :session-id "s-lite")))
    (should-not (string-match-p ":Lite:"
                                (agent-org-buffer--render-metadata status)))
    (should (string-match-p ":Lite: yes"
                            (agent-org-buffer--render-metadata status t)))
    ;; and it does not move the property out of the PROPERTIES drawer
    (should (string-match-p ":Cost: \$0\.00\n:Lite: yes\n:END:"
                            (agent-org-buffer--render-metadata status t)))))

(ert-deftest test-agent-org-lite-transcript-writes-nothing-while-the-queue-is-empty ()
  "A lite session stops writing its transcript once nothing is waiting.
The mirror is history the agent itself can replay, and it is a whole-file write
of 3-15 ms at every turn boundary on a machine that is already struggling; a
queued prompt is NOT replayable, so the mode spends the write on exactly that."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (let ((buf (agent-org-buffer-create "lite-nofile")))
        (with-current-buffer buf
          (setq agent-org-buffer--lite 'on)
          (agent-org-buffer-set-status buf :session-id "s-lite-write")
          (agent-org-buffer-begin-exchange buf "a question")
          (ao--counting-writes
            (agent-org-buffer-transcribe buf)
            (should (= 0 ao--writes))))
        (kill-buffer buf))
      ;; a full session, same fixture, does write
      (let ((buf (agent-org-buffer-create "full-file")))
        (with-current-buffer buf
          (agent-org-buffer-set-status buf :session-id "s-full-write")
          (agent-org-buffer-begin-exchange buf "a question")
          (ao--counting-writes
            (agent-org-buffer-transcribe buf)
            (should (= 1 ao--writes))))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-lite-still-records-a-queued-prompt ()
  "Lite writes the transcript WHILE a prompt is queued, and resume reads it back.
The one thing that exists nowhere else: a queued prompt was never sent, so it is
in no `session/load' replay, in no `* PROMPT' heading and in no agent memory.  Lite
mode spends the write on exactly that and stops the moment the queue empties --
which is why the rule is \"a non-empty queue\", not \"never\"."
  (ert-with-temp-directory temp-dir
    (ao--transcript-in temp-dir
      (let ((buf (agent-org-buffer-create "lite-queue")))
        (with-current-buffer buf
          (setq agent-org-buffer--lite 'on)
          (agent-org-buffer-set-status buf :session-id "s-lite-queue")
          (agent-org-buffer-set-status buf :queued '("first" "second"))
          ;; the queue block is appended to the mirror from the session's
          ;; list, so the status alone is enough for the file to carry it --
          ;; which is what `agent-org--queue-refresh' does on a live enqueue
          (agent-org-buffer-refresh-metadata buf)
          (agent-org-buffer-transcribe buf)
          (should (equal (ao--transcript-files temp-dir)
                         '("s-lite-queue.org")))
          (should (equal (agent-org-buffer-transcript-queue "s-lite-queue")
                         '("first" "second")))
          ;; drained: the file stops being rewritten
          (agent-org-buffer-set-status buf :queued nil)
          (ao--counting-writes
            (agent-org-buffer-transcribe buf)
            (should (= 0 ao--writes))))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-lite-undo-switch-follows-the-scope ()
  "A lite session stops recording undo; a full one records.
The switch is `buffer-undo-list' itself, and the switch is what this package
owns.  Both fixtures reach their scope through the real command, so the switch
is moved by the same code that moves for a person.

The RECORDS are deliberately not asserted, and the reason is worth writing
down: undo records are flushed to the buffer at a command boundary, so a batch
Emacs (no command loop) answers differently from a live one -- measured here:
typing with the switch nil leaves one record in the buffer, and typing with it
t leaves none, which is the opposite of what a session does.  A test pinning
that would be pinning batch Emacs, not this package.  The saving it buys is
the switch being off for the whole life of the chat."
  (dolist (scope '(on off))
    (let ((buf (agent-org-buffer-create (format "undo-%s" scope))))
      (unwind-protect
          (with-current-buffer buf
            (let ((inhibit-message t))
              (agent-org-lite-mode-toggle)    ; inherit -> on
              (when (eq scope 'off)
                (agent-org-lite-mode-toggle))) ; on -> off
            (should (eq (if (eq scope 'on) 'on 'off)
                        agent-org-buffer--lite))
            (should (eq (not (eq scope 'on))
                        (agent-org-buffer--record-undo-p)))
            (should (eq (not (eq scope 'on)) buffer-undo-list))
            ;; and the switch is still off after the buffer has been used
            (agent-org-buffer-insert-prompt buf)
            (ao--type "a draft")
            (should (string-match-p "a draft" (buffer-string)))
            (should (eq (not (eq scope 'on)) (agent-org-buffer--record-undo-p))))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-todo-keywords-cost-no-reparse-in-either-scope ()
  "Lite and full alike: rebuilding the metadata block parses nothing.
The scope used to matter here because the block carried a `#+TODO:' line and
loading it meant `org-set-regexps-and-options' -- a re-read of the WHOLE
buffer, so lite parsed once per buffer and full once per rebuild.  The sets
now come from `org-todo-keywords' (see
`agent-org-buffer--install-todo-keywords'), so the saving is not a lite
optimisation any more: it is the default shape, and this pins that NEITHER
scope reparses.
The other half is the interactive path: an edited option list reaches a live
chat only through `agent-org-refresh-todo-keywords', which is the one
remaining caller and runs exactly one recompute."
  (dolist (scope (list 'on 'off))
    (let ((buf (agent-org-buffer-create (format "reparse-%s" scope)))
          (parses 0))
      (with-current-buffer buf
        (setq agent-org-buffer--lite scope)
        (cl-letf (((symbol-function 'org-set-regexps-and-options)
                   (lambda (&optional _) (cl-incf parses))))
          (agent-org-buffer-refresh-metadata buf)
          (agent-org-buffer-set-status buf :used 10 :size 100)
          (agent-org-buffer-refresh-metadata buf)
          (agent-org-buffer-set-status buf :used 20 :size 100)
          (agent-org-buffer-refresh-metadata buf))
        (should (= 0 parses)))
      (kill-buffer buf)))
  (let ((buf (agent-org-buffer-create "refresh"))
        (parses 0))
    (with-current-buffer buf
      ;; the COUNT is pinned under a stub, which is the only way to see a
      ;; recompute -- and the stub is also why the keyword checks below it
      ;; cannot run inside it: a stubbed derive call derives nothing
      (cl-letf (((symbol-function 'org-set-regexps-and-options)
                 (lambda (&optional _) (cl-incf parses))))
        (agent-org-refresh-todo-keywords)
        (should (= 1 parses))
        (let ((agent-org-tool-todo-keywords
               '("WAITING" "BUSY" "|" "FINISHED" "BROKEN")))
          (agent-org-refresh-todo-keywords)
          (should (= 2 parses))))
      ;; and the real path: an edited option list reaches a live chat through
      ;; the refresh, one call re-deriving the buffer's own set
      (let ((agent-org-tool-todo-keywords
             '("WAITING" "BUSY" "|" "FINISHED" "BROKEN")))
        (should-not (member "BUSY" org-todo-keywords-1))
        (agent-org-refresh-todo-keywords)
        (should (equal '("WAITING" "BUSY" "|" "FINISHED" "BROKEN")
                       agent-org-tool-todo-keywords))
        (should (member "BUSY" org-todo-keywords-1))
        (should (member "FINISHED" org-todo-keywords-1))
        (should (ao--todo-set-matches-the-options buf)))
      ;; back to the option's real value, and a stale buffer would still be
      ;; holding RUNNING until somebody refreshed it again
      (agent-org-refresh-todo-keywords)
      (should-not (member "BUSY" org-todo-keywords-1)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-lite-skipping-the-reparse-keeps-the-keywords-live ()
  "After the skip the file's own keyword set is still parsed: RESPONDING is a keyword.
The optimisation is only safe because the set is already live; if a lite
session's prompt words stopped being keywords, the saving would be a corruption.
Org's own parser answers it, which is how this suite settles Org questions."
  (let ((pair (ao--queued '("a waiting prompt"))))
    (with-current-buffer (car pair)
      (let ((agent-org-buffer--lite 'on))
        ;; a real rebuild with the real reparse first, then the skipped ones
        (agent-org-buffer-refresh-metadata (car pair))
        (agent-org-buffer-set-status (car pair) :used 10 :size 100)
        (agent-org-buffer-refresh-metadata (car pair))
        (agent-org-buffer-set-status (car pair) :used 20 :size 100)
        (agent-org-buffer-refresh-metadata (car pair)))
      ;; read them HERE, with the chat current: `org-todo-keywords-1' is a
      ;; buffer-local of the file that declared it, so asking from anywhere
      ;; else asks about a buffer that never had one
      (should (member "RESPONDING" org-todo-keywords-1))
      (should (member "IDLE" org-todo-keywords-1))
      ;; and Org agrees at the heading that uses one of them: the queue entry
      ;; reads as a real TODO state, not as text that starts with the word.
      ;; The PROPERTY name is still "TODO" whatever the word is -- that is how
      ;; Org spells "the keyword of this headline".
      (goto-char (point-min))
      (should (re-search-forward "^\\* NEXT a waiting prompt$" nil t))
      (should (equal (org-entry-get nil "TODO") "NEXT")))
    (kill-buffer (car pair))))

;;;; The resource monitor: what each session costs this machine
;;
;; A separate Org buffer of tables, never a header-line segment: the bar carries
;; exactly one status string (CONVENTIONS.md 6), and a redraw on a timer in every
;; open chat would be the load the monitor exists to report.

(ert-deftest test-agent-org-proc-status-kb-parses-a-proc-status-line ()
  "`VmRSS' is read as KIB out of a `/proc' status body.
Pure parsing, so the shape of a kernel file is pinned without depending on any
particular process: `55628' KIB is 55628000 bytes, and a body without the field
is nil rather than zero."
  (let ((body "Name:\temacs\nVmPeak:\t  123456 kB\nVmRSS:\t   55628 kB\nThreads:\t3\n"))
    (should (= 55628 (agent-org--status-kb body "VmRSS")))
    (should (= 123456 (agent-org--status-kb body "VmPeak")))
    (should-not (agent-org--status-kb body "VmNope"))))

(ert-deftest test-agent-org-proc-cpu-ticks-counts-from-after-the-process-name ()
  "CPU ticks are read past the `comm' field, whatever the process is called.
`(Web Content)' is a real Linux process name, and a naive split of the whole
line would read its two spaces as two fields -- shifting every number while
reporting no error at all.  So the counting starts after the last `) '."
  (let ((plain "(sleep) S 1 2 3 4 5 6 7 8 9 10 100 20 0 0"))
    ;; after comm, utime is the twelfth field and stime the thirteenth
    (should (= 120 (agent-org--stat-cpu-ticks plain))))
  (let* ((spaced "(Web Content) S 1 2 3 4 5 6 7 8 9 10 100 20 0 0")
         ;; the same line read the naive way: two spaces INSIDE the comm shift
         ;; every field, so the reader reports some other pair of numbers and no
         ;; error at all.  The difference is the whole reason for the guard.
         (naive (split-string spaced " " t))
         (naive-sum (+ (string-to-number (nth 11 naive))
                       (string-to-number (nth 12 naive)))))
    (should (= 120 (agent-org--stat-cpu-ticks spaced)))
    (should-not (= 120 naive-sum)))
  (should-not (agent-org--stat-cpu-ticks "no parens here")))

(ert-deftest test-agent-org-parse-load-takes-three-numbers ()
  "Only the three averages; the process split and last pid are not load."
  ;; floats, because /proc writes them as decimals: 8.51 is not 8
  (should (equal '(1.0 5.0 15.0) (agent-org--parse-load "1.00 5.00 15.00 8/330 20744\n")))
  (should (equal '(0.12 0.24 0.48) (agent-org--parse-load "0.12 0.24 0.48 2/9 123")))
  (should-not (agent-org--parse-load "")))

(ert-deftest test-agent-org-bytes-reads-short-and-an-absent-measurement-as-different ()
  "98 MB and 1.4 GB, and an em-dash for nothing at all.
Zero is a claim and nil is an absence: a crashed agent process is not a small
one, so a missing RSS must not print as `0 B'."
  (should (equal "0 B" (agent-org--bytes 0)))
  (should (equal "512 B" (agent-org--bytes 512)))
  (should (equal "2 kB" (agent-org--bytes 2048)))
  (should (equal "1.0 MB" (agent-org--bytes 1048576)))
  (should (equal "98.0 MB" (agent-org--bytes (* 98 1024 1024))))
  (should (equal "1.4 GB" (agent-org--bytes 1474838528)))
  (should (equal "—" (agent-org--bytes nil))))

(ert-deftest test-agent-org-cpu-rate-needs-two-samples-and-honours-the-interval ()
  "A rate from consecutive samples; nil for a first sample, a zero interval, or a
pid that was reused (ticks going backwards).  Above 100% is ordinary: it means
the agent is running on more than one core."
  (let ((now (float-time)))
    ;; 100 ticks over 2 s at 100 Hz = 50% of one core
    (should (= 50.0 (agent-org--cpu-rate (cons 100 now)
                                         (list :ticks 200 :at (+ now 2.0)))))
    ;; twice the ticks in the same time is twice the CPU
    (should (= 100.0 (agent-org--cpu-rate (cons 100 now)
                                          (list :ticks 300 :at (+ now 2.0)))))
    (should-not (agent-org--cpu-rate nil (list :ticks 200 :at (+ now 2.0))))
    (should-not (agent-org--cpu-rate (cons 100 now)
                                      (list :ticks 200 :at now)))
    ;; a reused pid: fewer ticks than last time is not a rate
    (should-not (agent-org--cpu-rate (cons 300 now)
                                      (list :ticks 200 :at (+ now 2.0))))
    ;; no process means no measurement
    (should-not (agent-org--cpu-rate (cons 100 now)
                                      (list :ticks nil :at (+ now 2.0))))))

(ert-deftest test-agent-org-resource-table-is-a-table-to-org ()
  "The monitor renders a real Org table, separator row and all.
`org-element-parse-buffer' is the judge, which is how the rest of this suite
settles Org questions: a block of text that LOOKS like a table is not one, and
without the `|---+---|' line the parser reports no table at all."
(with-temp-buffer
    (insert (agent-org--resource-table
             '("Session" "State")
             '(("qoder:proj" "Ready") ("goose:proj" "Streaming"))))
    (org-mode)
    (goto-char (point-min))
    (should (re-search-forward "^[|] Session [|] State [|]$" nil t))
    (should (re-search-forward "^[|] --- \\+ --- [|]$" nil t))
    (let ((tables 0) (rows 0) (heads 0))
      ;; counted as ELEMENTS, not as lines: Org gives one `table-row' per line
      ;; the table owns, separator included, so four rows is a header, a
      ;; separator and two sessions
      (org-element-map (org-element-parse-buffer) '(table)
        (lambda (_e) (cl-incf tables)))
      (org-element-map (org-element-parse-buffer) '(table-row)
        (lambda (_e) (cl-incf rows)))
      (should (= 1 tables))
      (should (= 4 rows))
      ;; and nothing on those lines is mistaken for a headline or a drawer
      (org-element-map (org-element-parse-buffer) '(headline drawer)
        (lambda (_e) (cl-incf heads)))
      (should (= 0 heads)))))

(ert-deftest test-agent-org-resource-monitor-lists-every-open-session ()
  "One row per registered session, plus the machine totals above them.
The monitor's whole job is the comparison between chats, so a session with no
row is a session whose resources cannot be compared; the machine table counts
sessions and agents separately because a chat whose agent died is still an open
chat."
  (let ((default-directory ao--name-dir))
    (let* ((one (ao--make-test-session "mon1"))
           (two (ao--make-test-session "mon2"))
           (buf (agent-org-resource-monitor)))
      (unwind-protect
          (with-current-buffer buf
            (let ((text (buffer-string)))
              (should (string-match-p "^\\* Machine$" text))
              (should (string-match-p "^\\* Sessions$" text))
              (should (string-match-p "mon1:ao-proj" text))
              (should (string-match-p "mon2:ao-proj" text))
              ;; one row per session, no more
              (should (= 2 (ao--count-occurrences text "^[|] mon[12]:ao-proj")))))
        (kill-buffer buf))
      (kill-buffer (car one))
      (kill-buffer (car two)))))

(ert-deftest test-agent-org-resource-monitor-scope-prefix-shows-one-session ()
  "A prefix argument narrows the monitor to the session it was called from.
\"Just mine\" is the reading when one chat is suspected, and scoping it on the
MONITOR rather than on the caller is what keeps a later refresh from widening
it: the scope is recorded on the monitor buffer."
  (let ((default-directory ao--name-dir))
    (let* ((one (ao--make-test-session "scoped1"))
           (two (ao--make-test-session "scoped2"))
           (buf nil))
      (unwind-protect
          (with-current-buffer (car one)
            (setq buf (agent-org-resource-monitor t))
            (with-current-buffer buf
              (let ((text (buffer-string)))
                (should (string-match-p "scoped1:ao-proj" text))
                (should-not (string-match-p "scoped2:ao-proj" text)))))
        (when (buffer-live-p buf) (kill-buffer buf))
        (kill-buffer (car one))
        (kill-buffer (car two))))))

(ert-deftest test-agent-org-resource-monitor-shows-the-scope-and-the-undo-it-removed ()
  "A lite session's row says Lite, and says its buffer records no undo.
The two features are one story: the monitor is how a person SEES what the toggle
did, and the undo column is a resource it actually removed.  A monitor showing
only the scope would be asking to be taken on trust."
  (let ((default-directory ao--name-dir))
    (let* ((pair (ao--make-test-session "shown-lite"))
           (buf (car pair))
           (mon nil))
      (with-current-buffer buf
        (setq agent-org-buffer--lite 'on)
        (setq buffer-undo-list nil))
      (unwind-protect
          (progn
            (with-current-buffer buf
              (setq mon (agent-org-resource-monitor t)))
            (with-current-buffer mon
              (let ((text (buffer-string)))
                (should (string-match-p "[|] Lite [|]" text))
                (should (string-match-p " no-undo [|]" text)))))
        (when (buffer-live-p mon) (kill-buffer mon))
        (kill-buffer buf)))))

(ert-deftest test-agent-org-resource-monitor-repaint-is-idempotent ()
  "Redrawing the monitor replaces its body instead of stacking copies.
Same rule as a chat's metadata block: the paint deletes up to the first heading
and reinserts, so a refresh that runs three times leaves one Machine table and
one row per session.  A monitor that appended would be unreadable in a minute."
  (let ((default-directory ao--name-dir))
    (let* ((pair (ao--make-test-session "idem"))
           (mon (agent-org-resource-monitor)))
      (unwind-protect
          (with-current-buffer mon
            (dotimes (_ 3) (agent-org-resource-refresh))
            (let ((text (buffer-string)))
              (should (= 1 (ao--count-occurrences text "^\\* Machine$")))
              (should (= 1 (ao--count-occurrences text "^\\* Sessions$")))
              (should (= 1 (ao--count-occurrences text "^[|] Session [|]")))
              (should (= 1 (ao--count-occurrences text "idem:ao-proj")))))
        (kill-buffer mon)
        (kill-buffer (car pair))))))

(ert-deftest test-agent-org-resource-monitor-reads-a-live-agent-process ()
  "The agent column names the process the session really spawned.
`acp' keeps it under `:process' as an alist KEY, so this is also the check that
the monitor reads the client the way the kill query does -- `plist-get' would
answer nil here and every row would print an em-dash.  The row therefore
carries a real RSS in KIB from `/proc', which is the measurement the whole
monitor exists to show."
  ;; the process is spawned OUTSIDE the fixture's `default-directory':
  ;; `ao--name-dir' is a name that need not exist (no other test here touches
  ;; the disk) and `make-process' chdirs into `default-directory'
  (let ((proc (make-process :name "ao-monitor-proc"
                            :command (list "sleep" "30"))))
    (let ((default-directory ao--name-dir))
      (let* ((buffer (agent-org-buffer-create "agent-col"))
             (session (list :name 'test :buffer buffer :session-id "s-proc"
                            :client (list (cons :process proc))
                            :streaming nil :pending-prompts nil))
             (mon nil))
        (unwind-protect
            (progn
              (agent-org--register-session session)
              (agent-org-buffer-set-session buffer session)
              (with-current-buffer buffer
                (setq mon (agent-org-resource-monitor t)))
              (with-current-buffer mon
                (let* ((text (buffer-string))
                       ;; the row is SESSION | STATE | MODE | AGENT | CPU | RSS ...
                       (row (car (seq-filter (lambda (line)
                                               (string-match-p "ao-monitor-proc" line))
                                             (split-string text "\n" t))))
                       (cells (split-string row "|" t)))
                  (should row)
                  ;; splitting on `|' with OMIT-NILS drops the empty fields the
                  ;; leading and trailing bars leave, so cell 3 is the AGENT
                  ;; column of the header SESSION STATE MODE AGENT CPU RSS ...
                  ;; and the AGENT cell is Emacs's NAME for the process -- what
                  ;; `list-processes' prints, which for a live session is acp's
                  ;; own name and not the binary on disk
                  (should (equal " ao-monitor-proc " (nth 3 cells)))
                  ;; the CPU cell is a dash on a FIRST sample (a rate needs
                  ;; two), and the RSS cell is a real measurement from /proc
                  (should (equal " — " (nth 4 cells)))
                  (should-not (equal " — " (nth 5 cells)))
                  (should (string-match-p "MB\\| B\\|KB" (nth 5 cells))))))
          ;; the agent goes FIRST, and that is what the real kill path asks
          ;; about: a live child puts `agent-org--kill-query' on the hook, and
          ;; a batch Emacs answers that question with EOF -- which would leave
          ;; the registry holding a session this test never cleaned up.  A
          ;; dead child needs no consent, so the buffer kill is silent.
          (delete-process proc)
          (when (buffer-live-p mon) (kill-buffer mon))
          (kill-buffer buffer))))
    (when (process-live-p proc) (delete-process proc))))

(ert-deftest test-agent-org-resource-monitor-timer-follows-display ()
  "The refresh timer is armed while the monitor is displayed and dropped when it is not.
This is the resource promise the feature rests on: the one repeating timer this
package runs is armed by display and disarmed by hiding, so a forgotten monitor
window costs a loaded machine nothing.

Display is REAL here, not stubbed.  A batch Emacs has a frame and a window
(measured), so `agent-org-resource-monitor' genuinely shows its buffer and
genuinely arms a timer -- the fixture then switches the window away and asks
again.  The timer function itself is counted rather than left to fire, because a
0.01 s repeat left armed would wake Emacs inside a later test."
  (let ((default-directory ao--name-dir))
    (let* ((pair (ao--make-test-session "display"))
           (armed 0)
           (buf nil)
           (scratch (get-buffer-create " ao-scratch ")))
      (let ((agent-org-resource-refresh-interval 0.01))
        (with-current-buffer (car pair)
          (setq buf (agent-org-resource-monitor)))
        (unwind-protect
            (progn
              ;; shown: the timer is live
              (should (agent-org--resource-displayed-p))
              (should agent-org--resource-timer)
              ;; hide it the way a person would: another buffer in EVERY
              ;; window showing it -- `display-buffer' opens a window of its
              ;; own rather than replacing the selected one, so switching the
              ;; selected window away is not enough
              (dolist (w (get-buffer-window-list buf nil t))
                (set-window-buffer w scratch))
              (should-not (agent-org--resource-displayed-p))
              (cl-letf (((symbol-function 'run-at-time)
                         (lambda (&rest _) (cl-incf armed) 'timer)))
                (agent-org--resource-retimer)
                (should (= 0 armed))
                (should-not agent-org--resource-timer))
              ;; and shown again, it comes back
              (set-window-buffer (get-buffer-window scratch) buf)
              (cl-letf (((symbol-function 'run-at-time)
                         (lambda (&rest _) (cl-incf armed) 'timer)))
                (agent-org--resource-retimer)
                (should (= 1 armed))
                (setq agent-org--resource-timer nil)))
          (when (buffer-live-p buf) (kill-buffer buf))
          (kill-buffer scratch)))
      (kill-buffer (car pair)))))

(ert-deftest test-agent-org-resource-monitor-timer-dies-with-its-buffer ()
  "Releasing the monitor cancels its timer, once.
The buffer IS the justification for the timer, so a timer outliving it is a
wakeup that samples nothing -- the same rule `agent-org--forget-session'
follows for an agent process."
  (let ((cancelled 0))
    (let ((agent-org--resource-timer 'fake-timer))
      (cl-letf (((symbol-function 'cancel-timer)
                 (lambda (&rest _) (cl-incf cancelled))))
        (with-temp-buffer
          (agent-org-resource-monitor-mode 1)
          (agent-org--forget-monitor)
          (should-not agent-org--resource-timer)
          (should (= 1 cancelled))
          ;; idempotent: a second release has nothing to cancel
          (agent-org--forget-monitor)
          (should (= 1 cancelled)))))))

(ert-deftest test-agent-org-resource-monitor-refresh-needs-a-monitor ()
  "`agent-org-resource-refresh' with no monitor open does nothing at all.
A refresh that opened one would surprise a person who typed it in the wrong
buffer, and the command is also how the monitor is read in a batch Emacs."
  (when (get-buffer "*agent-org resources*")
    (kill-buffer (get-buffer "*agent-org resources*")))
  (should-not (agent-org-resource-refresh))
  (should-not (get-buffer "*agent-org resources*")))

(ert-deftest test-agent-org-copy-session-id-kills-the-id ()
  "The id a header line shows is the id a shell needs, verbatim.
`kill-new' rather than `kill-ring-save' of a region: there is no region,
and the value comes from the session plist — the same record the buffer
name and the transcript file are addressed by, so a copy that read the
header string instead could pick up the project suffix and paste an id
that resolves to nothing."
  (let ((kill-ring nil)
        (kill-ring-yank-pointer nil)
        (pair (ao--make-test-session "copyid")))
    (with-current-buffer (car pair)
      (agent-org-copy-session-id)
      (should (equal '("sid-test") kill-ring)))
    (kill-buffer (car pair))))

(ert-deftest test-agent-org-copy-session-id-refuses-before-the-handshake ()
  "No id yet is a refusal, not a copy of nil or of the previous kill.
A chat is usable before `session/new' answers, so this path is reached
in the first second of every chat; silently copying the stale thing that
happens to be next on the ring is how a wrong id gets pasted with
confidence."
  (let ((kill-ring '("stale-value"))
        (pair (ao--make-test-session "nocopy")))
    (setf (plist-get (cdr pair) :session-id) nil)
    (with-current-buffer (car pair)
      (should-error (agent-org-copy-session-id) :type 'user-error)
      (should (equal '("stale-value") kill-ring)))
    (kill-buffer (car pair))))

;;;; The clock report: reading the clocks a transcript already files
;;
;; The first item of the worg brainstorm (`TODOs.org', "Reporting over the
;; clocks/cost we already write -- highest value, lowest cost").  Every
;; exchange already files an exact `:RESPONSE:' in seconds and a CLOSED
;; `CLOCK:' range, and nothing reads either.  A report is a pure read of that
;; data, scoped to one project's `.agent-org/'.
;;
;; The shared guardrail those ideas state is what most of these tests are
;; about: a report must never enter Org's clock MACHINERY.  `org-clock-in'
;; owns one global running-clock slot for the whole Emacs, so a feature that
;; occupied it would block the user's own clocking -- the exact failure the
;; drawer shape was chosen to avoid.

(defmacro ao--report-in (dir &rest body)
  "Run BODY with `agent-org-transcript-dir' bound to DIR.
The report has one input, a directory; binding it is the whole setup, and
DIR is absolute because a test that read the user's real `.agent-org/'
would be a test that reports the user's chats."
  (declare (indent 1))
  `(let ((agent-org-transcript-dir (file-name-as-directory ,dir)))
     ,@body))

(defun ao--report-transcript (dir name title provider model turns)
  "Write DIR/NAME.org in the exact shape a transcript has, and return its path.
TURNS is a list of (SECONDS . START-MINUTE), one per exchange, and each
becomes the two records the report reads, where
`agent-org-buffer--close-response-clock' writes them: a `:RESPONSE:'
property in the drawer directly under the heading, and a closed `CLOCK:'
range in the `:LOGBOOK:' under that.  One minute per exchange is what makes
the minute column predictable."
  (let ((file (expand-file-name (concat name ".org") dir)))
    (with-temp-file file
      (insert (format ":PROPERTIES:\n:Provider: %s\n:ID: %s\n:Model: %s\n:Tokens: %d\n:END:\n#+TITLE: %s\n\n"
                      provider name model (* 100 (length turns)) title))
      (cl-loop for (seconds . minute) in turns
               do (insert (format "* prompt\n:PROPERTIES:\n:RESPONSE: %d\n:END:\n:LOGBOOK:\nCLOCK: [2026-10-07 Wed 09:%02d]--[2026-10-07 Wed 09:%02d] =>  0:01\n:END:\n\n"
                                  seconds minute (1+ minute)))))
    file))

(ert-deftest test-agent-org-clock-report-tables-the-clocks-a-project-files ()
  "The report adds up what the transcripts already say, both ways.
Seconds come from the `:RESPONSE:' properties -- exact, which a
minute-granular `CLOCK:' range cannot be -- and the minutes come from Org's
own clocktable over the closed ranges.  Both are in one buffer because they
are the same measurement at two precisions: a person reads the seconds to
compare two chats and the table to see the day."
  (ert-with-temp-directory dir
    (ao--report-transcript dir "sid-a" "Chat A" "Qoder" "Qwen3.8-Flash"
                           '((30 . 0) (90 . 1)))
    (ao--report-transcript dir "sid-b" "Chat B" "Goose" "DeepSeek-V3" '((60 . 5)))
    (let ((buffer (ao--report-in dir (agent-org-clock-report))))
      (unwind-protect
          (with-current-buffer buffer
            (should (derived-mode-p 'org-mode))
            ;; per chat: 30+90 = 0:02:00 and 60 = 0:01:00, whole project 180.
            ;; Rows are sorted by MODEL (DeepSeek-V3 before Qwen3.8-Flash), so
            ;; these are PRESENCE checks, each from the top, not a walk in the
            ;; order they happen to render.
            (should (progn (goto-char (point-min))
                           (search-forward "Qwen3.8-Flash" nil t)))
            (should (progn (goto-char (point-min))
                           (search-forward "0:02:00" nil t)))
            (should (progn (goto-char (point-min))
                           (search-forward "0:01:00" nil t)))
            (should (progn (goto-char (point-min))
                           (search-forward "0:03:00" nil t)))
            ;; the chat's own row carries its title, provider, model and turn
            ;; count, together on one line
            (should (progn (goto-char (point-min))
                           (re-search-forward "| Chat B +| Goose +| DeepSeek-V3 +| 1 +| 0:01:00" nil t)))
            ;; Org's own sum of the closed ranges: three exchanges, one
            ;; minute each, emphasized exactly as clocktable writes a total
            (should (progn (goto-char (point-min)) (search-forward "*Total time*")))
            (should (progn (goto-char (point-min)) (search-forward "*0:03*"))))
        (kill-buffer buffer)))))

(ert-deftest test-agent-org-clock-report-reads-one-projects-directory-only ()
  "Scope is the project's transcript directory, never the user's agenda.
`agent-org-transcript-dir' is RELATIVE by default and resolves against
`default-directory' exactly as the writer resolves it, so one project's
report cannot drag in another project's chats -- and it must not do so
through `org-agenda-files' either, which is a global list of a person's own
choosing that has nothing to do with this repo.  The agenda file here is
planted as a transcript in a directory the report is NOT pointed at."
  (ert-with-temp-directory root
    (let ((project (expand-file-name "project" root))
          (elsewhere (expand-file-name "elsewhere" root)))
      (make-directory project)
      (make-directory elsewhere)
      (ao--report-transcript project "sid-in" "Inside The Project" "Qoder" "M-In" '((30 . 0)))
      (ao--report-transcript elsewhere "sid-out" "Outside The Project" "Goose" "M-Out" '((60 . 1)))
      (make-directory (expand-file-name ".agent-org" project) t)
      (rename-file (expand-file-name "sid-in.org" project)
                   (expand-file-name ".agent-org/sid-in.org" project))
      ;; `let*', not `let': a plain `let' evaluates every init form in the
      ;; OUTER environment, so `(agent-org-clock-report)' would run BEFORE
      ;; `default-directory' and `agent-org-transcript-dir' were bound
      ;; and read the real repo's `.agent-org' instead of this project's.
      (let* ((org-agenda-files (list (expand-file-name "sid-out.org" elsewhere)))
             (default-directory (file-name-as-directory project))
             (agent-org-transcript-dir ".agent-org")
             (buffer (agent-org-clock-report)))
        (unwind-protect
            (with-current-buffer buffer
              (should (search-forward "Inside The Project" nil t))
              (should-not (progn (goto-char (point-min))
                                 (re-search-forward "Outside The Project" nil t))))
          (kill-buffer buffer))))))

(ert-deftest test-agent-org-clock-report-never-enters-org-clock-machinery ()
  "The guardrail, enforced: a report READS clocks and never RUNS one.
`org-clock-in', `org-clock-out' and `org-clock-load' are bound to counters
and must not fire; and no `org-clock-' variable may end the call holding a
different value, which is the broad form of the same rule.  Org keeps ONE
running clock for the whole Emacs, so a feature that touched this machinery
would steal the user's clocking slot out from under him -- and the clock
ranges a transcript files are supposed to be read-only evidence of work
already done."
  (ert-with-temp-directory dir
    (ao--report-transcript dir "sid-a" "Chat A" "Qoder" "M" '((30 . 0)))
    (let ((hits 0) (buffer nil) (clock-vars nil))
      ;; org-clock must be LOADED before the snapshot: with its autoloads
      ;; still cold every one of its variables reads as nil here, and would
      ;; then "change" to its ordinary default when the report loads it
      (require 'org-clock)
      ;; `all-completions' may hand the predicate a STRING or, on some
      ;; Emacs, the interned SYMBOL itself; `boundp'/`symbol-value'/`facep'
      ;; want a symbol, `intern' wants a string — so normalise to a symbol
      ;; first.  Snapshot AFTER `require' so a cold autoload never
      ;; masquerades as a change.
      (setq clock-vars
            (mapcar (lambda (name)
                      (let ((sym (if (symbolp name) name (intern name))))
                        (cons sym (and (boundp sym) (symbol-value sym)))))
                    (all-completions "org-clock-" obarray
                                     (lambda (name)
                                       (let ((sym (if (symbolp name) name (intern name))))
                                         (and (boundp sym) (not (facep sym))))))))
      (cl-letf (((symbol-function 'org-clock-in)
                 (lambda (&rest _) (cl-incf hits)))
                ((symbol-function 'org-clock-out)
                 (lambda (&rest _) (cl-incf hits)))
                ((symbol-function 'org-clock-load)
                 (lambda (&rest _) (cl-incf hits))))
        (setq buffer (ao--report-in dir (agent-org-clock-report))))
      (unwind-protect
          (progn
            (should (= 0 hits))
            ;; a running clock parks these markers INSIDE the clocked heading's
            ;; buffer; `require' initialises them as detached markers (a non-nil
            ;; object that points at no buffer), so "no clock is running" is
            ;; "the marker is in no buffer", NOT "the marker is nil".
            (should-not (and (markerp org-clock-marker)
                             (marker-buffer org-clock-marker)))
            (should-not (and (markerp org-clock-hd-marker)
                             (marker-buffer org-clock-hd-marker)))
            (dolist (pair clock-vars)
              (should (equal (cdr pair)
                             (and (boundp (car pair)) (symbol-value (car pair)))))))
        (when buffer (kill-buffer buffer))))))

(ert-deftest test-agent-org-clock-report-prefix-arg-answers-one-chat ()
  "A prefix argument narrows the report to the chat under point.
The question a person asks while a turn runs is \"is this the slow one\",
and a table of every chat in the project does not answer it.  Called where
there is no session there is nothing to narrow to, and the project reading
is the honest answer -- the rule `agent-org-resource-monitor' already
follows."
  (ert-with-temp-directory dir
    (ao--report-transcript dir "sid-test" "This Chat" "Qoder" "M-A" '((30 . 0)))
    (ao--report-transcript dir "sid-other" "Another Chat" "Goose" "M-B" '((60 . 1)))
    (let ((pair (ao--make-test-session "one-chat-report"))
          (buffer nil))
      (unwind-protect
          (progn
            (setq buffer (with-current-buffer (car pair)
                           (ao--report-in dir (agent-org-clock-report t))))
            (with-current-buffer buffer
              (should (search-forward "This Chat" nil t))
              (should-not (progn (goto-char (point-min))
                                 (re-search-forward "Another Chat" nil t))))
            (kill-buffer buffer)
            ;; the same chat buffer without the prefix arg: the whole project
            (setq buffer (with-current-buffer (car pair)
                           (ao--report-in dir (agent-org-clock-report))))
            (with-current-buffer buffer
              (should (search-forward "This Chat" nil t))
              (should (search-forward "Another Chat" nil t))))
        (when buffer (kill-buffer buffer))
        (kill-buffer (car pair))))))

(ert-deftest test-agent-org-clock-report-with-nothing-to-read-says-so ()
  "An empty transcript directory is a message, not an empty buffer.
A table of nothing reads as a report of zero work, which is a different
claim -- and the first two days of a project, or any project with
`agent-org-transcribe' off, hit exactly this path."
  (ert-with-temp-directory dir
    (ao--report-in dir
      (should-error (agent-org-clock-report) :type 'user-error))))

;;;; Activity blocks: order, no adjacent duplicates, and the two container options
;;
;; One message, four orders, all pinned here:
;;   "the thinking drawer is above tool ones and being updated in place.  You
;;    CAN have multiple thinking drawers."
;;   "There CAN'T be another :tool: drawer right after a :tool: drawer.
;;    Consecutive tool calls belong to the same drawer."
;;   "Add options for not to wrap tool calls with :tool: drawers."
;;   "Add another option to use TODO headings instead of drawers.  In this case,
;;    we'll also use TODO heading for responses."

(defun ao--drawer-bodies (text name)
  "The body of every :NAME: drawer in TEXT, in buffer order.
`ao--tool-drawer-bodies' does this for `:tool:' only; the thinking half of the
order needs the same question asked of `:thinking:' -- WHICH drawer did this
thought land in -- so the helper is general and that one stays as it is."
  (let ((rest text) (bodies '())
        (open (format "^:%s:$" name)))
    (while (string-match open rest)
      (let ((body-start (match-end 0)))
        (if (string-match "^:end:$" rest body-start)
            (progn
              (push (substring rest body-start (match-beginning 0)) bodies)
              (setq rest (substring rest (match-end 0))))
          (setq rest nil))))
    (nreverse bodies)))

(ert-deftest test-agent-org-thought-below-a-new-board-opens-a-second-drawer ()
  "A thinking run that lands below a fresh board gets its OWN drawer.
The shape this replaces: one `:thinking:' drawer per turn, found by searching the
turn and repainted in place.  Every thought of a long turn therefore piled into
the FIRST drawer, which sat ABOVE every board drawn after it -- so the transcript
read \"the agent thought everything, then did everything\", whatever happened in
between, and the drawer grew without end.

A thought now reuses its drawer only while nothing has been drawn BELOW it; once
a new board has landed under the run, the next chunk starts a second drawer and
a second segment of accumulated text."
  (let ((buf (agent-org-buffer-create "thinks2")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "t1") (title . "one") (status . "completed")))
    (agent-org-buffer-append-thought buf "first thought")
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "t2") (title . "two") (status . "completed")))
    (agent-org-buffer-append-thought buf "second thought")
    (agent-org-buffer-append-thought buf "still the second")
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (= 2 (ao--count-occurrences text "^:tool:$")))
      (should (= 2 (ao--count-occurrences text "^:thinking:$")))
      ;; the whole turn reads in the order the agent produced it.  The two
      ;; chunks of the second run are a TEXT STREAM, not two lines: the wire
      ;; splits thought mid-sentence, so the drawer holds what the agent said
      ;; ("second thoughtstill the second") and the assertions are substrings
      ;; with no invented line break.
      (should (apply #'ao--ordered text
                     (list "^:tool:$" "  - EXECUTED one$"
                           "^:thinking:$" " first thought"
                           "^:tool:$" "  - EXECUTED two$"
                           "^:thinking:$" " second thought"
                           "still the second")))
      ;; and the first drawer was NOT updated in place: it holds its own run only
      (let ((bodies (ao--drawer-bodies text "thinking")))
        (should (= 2 (length bodies)))
        (should (string-match-p "first thought" (car bodies)))
        (should-not (string-match-p "second" (car bodies)))
        (should (string-match-p "second thought" (cadr bodies)))
        (should-not (string-match-p "first" (cadr bodies)))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-no-adjacent-tool-drawers ()
  "Two `:tool:' drawers never sit next to each other.
The user's rule is structural, not cosmetic: \"There CAN'T be another :tool:
drawer right after a :tool: drawer.\"  A drawer is opened at the END of the turn,
so the only way two of the same kind touch is a seal that fired while nothing
was written between the two runs -- and a REPLY CHUNK writes at the end of the
answer text, which is always ABOVE every block of the turn (that is what keeps
one answer readable in one place instead of scattered between boards).  Prose
therefore separates nothing: only a block of the OTHER kind does."
  (let ((buf (agent-org-buffer-create "adjacent")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "t1") (title . "ls") (status . "completed")))
    (agent-org-buffer-append-chunk buf "now the tests" nil)
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "t2") (title . "grep") (status . "completed")))
    (agent-org-buffer-append-chunk buf "and one more" nil)
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "t3") (title . "tree") (status . "completed")))
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (= 1 (ao--count-occurrences text "^:tool:$")))
      (should (= 1 (length (ao--tool-drawer-bodies text))))
      (should (apply #'ao--ordered text
                     (list "now the tests" "and one more"
                           "^:tool:$" "  - EXECUTED ls"
                           "  - EXECUTED grep" "  - EXECUTED tree"))))
    (kill-buffer buf)))

(defun ao--part-body (buffer key)
  "The text of part KEY's body in BUFFER, between its own two markers.
The white-box view of the one thing the ordering fix is about: a part's region
must stop where the NEXT part begins.  Read through the markers rather than by
grep, because the failure this pins is the region itself growing past the part
(it did: every marker was rear-grazing, so `:body-end' slid to the bottom of the
turn and the next repaint deleted the answer that had arrived since)."
  (with-current-buffer buffer
    (let ((beg (agent-org-buffer--part-mark key :body-beg))
          (end (agent-org-buffer--part-mark key :body-end)))
      (when (and beg end) (buffer-substring-no-properties beg end)))))

(ert-deftest test-agent-org-headings-is-the-default-activity-style ()
  "The value `agent-org-activity-style' SHIPS with is `headings'.
\"By default, we'll use TODO subheadings for EACH part of the response\" -- so
this is the user's order, recorded as a test, and it is the only thing standing
between that order and an accident.  The suite pins the style to `drawers' at
load (line above `require'), because 60 older tests were written against the
drawer board; a pin that wide means nothing in the suite would notice a flipped
default.  Read from the `standard-value', never from the live symbol, which this
very file overrides."
  (should (equal 'headings
                 (eval (car (get 'agent-org-activity-style
                                 'standard-value))))))

(ert-deftest test-agent-org-headings-keeps-a-parts-region-inside-itself ()
  "Opening a part below another does not grow the one above it.
The invariant the whole ordering scheme rests on: `:body-end' is where this
part's text ends, and it must still be there after a later part has been
inserted.  `copy-marker' is `(copy-marker MARKER &optional INSERTION-TYPE)', so
the natural-looking `(copy-marker POS BUFFER)' silently makes the marker
rear-grazing instead of naming its buffer -- and every body then swallowed
everything below it (measured, and the reason an earlier draft of the ordering
fix changed nothing its tests were run against).
Asserted on a CALL rather than a thought: a closed thought's cell is dropped by
design (`--finish-part' forgets it, because nothing ever rewrites a closed
thought), so only a call's markers are still live to be measured."
  (let ((agent-org-activity-style 'headings)
        (buf (agent-org-buffer-create "headregion")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "t1") (title . "ls") (status . "in_progress")
           ,@(ao--tool-text-block "a.org")))
    ;; the call's body is its own output and nothing else -- measured right
    ;; after the two later arrivals, so a marker that slid would show up as
    ;; this string growing instead of as a lost line somewhere else
    (agent-org-buffer-append-chunk buf "the answer\n" nil)
    (with-current-buffer buf
      ;; t1's region ends exactly where the next heading begins: the parts abut,
      ;; they do not overlap
      (should (equal " a.org\n" (ao--part-body buf "tool:t1")))
      (should (string-match-p
              "^\\*\\* WRITING "
              (buffer-substring-no-properties
               (agent-org-buffer--part-mark "tool:t1" :body-end)
               (point-max)))))
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "t2") (title . "cat") (status . "in_progress")
           ,@(ao--tool-text-block "b.org")))
    (should (equal " a.org\n" (ao--part-body buf "tool:t1")))
    (should (equal " b.org\n" (ao--part-body buf "tool:t2")))
    ;; the prose has no cell to measure any more (a closed thought or stretch of
    ;; answer is forgotten by design, because nothing rewrites one) so it is
    ;; read off the buffer: the block from its own heading to the next one,
    ;; which holds its clock furniture and its line and NOTHING else
    (with-current-buffer buf
      (let ((section
             (save-excursion
               (goto-char (point-min))
               (re-search-forward "^\\*\\* WROTE")
               (beginning-of-line)
               (buffer-substring-no-properties
                (point)
                (progn
                  (forward-line 1)
                  (if (re-search-forward "^\\*\\* " nil t)
                      (line-beginning-position)
                    (point-max)))))))
        (should (string-match-p "^the answer$" section))
        (should (= 1 (ao--count-occurrences section "^\\*\\* ")))
        ;; the call that came after it kept its own output, not the prose
        (should (string-match-p " b.org$" (buffer-substring-no-properties
                                           (point-min) (point-max))))))
    (let ((text-before (with-current-buffer buf (buffer-string))))
      ;; completing t1 rewrites inside its own region only
      (agent-org-buffer-insert-tool
       buf '((toolCallId . "t1") (title . "ls") (status . "completed")))
      (should (equal " a.org\n" (ao--part-body buf "tool:t1")))
      (with-current-buffer buf
        (should (string-match-p "^\\*\\* EXECUTED ls$" (buffer-string)))
        (should (= 1 (ao--count-occurrences (buffer-string)
                                            "^\\*\\* .* ls$")))
        (should (string-match-p "^the answer$" (buffer-string)))
        (should (string-match-p " b.org$" (buffer-string)))
        ;; the only text the repaint changed is t1's heading word
        (should (= (length text-before)
                   (+ (length (buffer-string))
                      (- (length "RUNNING") (length "EXECUTED")))))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-headings-orders-every-part-of-the-response ()
  "Thought, call, answer, call's result, more answer -- in THAT order, whole.
The user's complaint this feature exists for: \"URGENTLY, fix response order.  I
still need to scroll up to see what the agent said last!!\"  So the assertion is
about the READER's eye: the bottom of the turn is the newest thing the agent did,
and nothing that already appeared disappears when a later part repaints.  The
second `insert-tool' is the hazard -- a completed call rewrites its own heading
in place, which is what used to delete the prose between the two reports.
Asserted on the finished buffer, because a mid-turn shape the boundary then
corrects is not what the user reads."
  (let ((agent-org-activity-style 'headings)
        (buf (agent-org-buffer-create "headorder")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-thought buf "weighing it")
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "t1") (title . "ls") (status . "in_progress")
           ,@(ao--tool-text-block "a.org")))
    (agent-org-buffer-append-chunk buf "the answer\nsecond line\n" nil)
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "t1") (title . "ls") (status . "completed")))
    (agent-org-buffer-append-chunk buf "and more\n" nil)
    (agent-org-buffer-end-agent-turn buf)
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (apply #'ao--ordered text
                     (list "^\\*\\* THOUGHT Thinking$" " weighing it$"
                           "^\\*\\* EXECUTED ls$" " a.org$"
                           "^\\*\\* WROTE Agent$"
                           "^the answer$" "^second line$" "^and more$")))
      ;; one heading per part: the call reported twice, the answer streamed
      ;; twice, and neither produced a second block
      (should (= 1 (ao--count-occurrences text "^\\*\\* .* ls$")))
      (should (= 1 (ao--count-occurrences text "^\\*\\* WROTE ")))
      (should (= 3 (ao--count-occurrences text "^\\*\\* ")))
      ;; nothing that had arrived was lost on the way
      (dolist (bit (list " weighing it" " a.org" "the answer"
                        "second line" "and more"))
        (should (string-match-p (regexp-quote bit) text)))
      ;; and the answer really is the LAST block -- the point of the whole order
      (should (string-match-p "^and more\n\\'" text)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-headings-keeps-a-call-that-printed-nothing ()
  "A tool call with no output is still something the agent DID, and it must
not vanish when the next activity arrives.
The wire sends `tool_call' (pending, title only, no content) and the completion
later, so a call's part is EMPTY at the moment the agent thinks of something
else.  `agent-org-buffer--finish-part' deletes an empty part -- right for prose
and thought, where no text means nothing was said -- and that deletion took the
call's headline with it, dropped its cell, and left the later `completed' update
nowhere to land: the call reappeared at the BOTTOM of the turn (out of arrival
order) and the repaint ate the next call's heading.  Measured live-shaped replay:
4 calls, 2 headings.
So a tool part is never deleted: it keeps its headline wearing the wire's word,
its clock, and its place in the order."
  (let ((agent-org-activity-style 'headings)
        (buf (agent-org-buffer-create "callnooutput")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "t1") (title . "read a") (status . "pending")))
    (agent-org-buffer-append-thought buf "more thinking")
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "t2") (title . "read b") (status . "pending")))
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "t1") (title . "read a") (status . "completed")))
    (agent-org-buffer-append-chunk buf "the answer\n" nil)
    (agent-org-buffer-end-agent-turn buf)
    (let ((text (with-current-buffer buf (buffer-string))))
      ;; every part is on the page, in the order it arrived: the FIRST call
      ;; stays the FIRST block even though it reported again at the end
      (should (apply #'ao--ordered text
                     (list "^\\*\\* EXECUTED read a$"
                           "^\\*\\* THOUGHT Thinking$" " more thinking$"
                           "^\\*\\* RUNNING read b$"
                           "^\\*\\* WROTE Agent$" "^the answer$")))
      (should (= 4 (ao--count-occurrences text "^\\*\\* ")))
      (dolist (label (list "read a" "read b"))
        (should (= 1 (ao--count-occurrences text (format "^\\*\\* .* %s$" label)))))
      ;; and every part keeps its measurement.  The empty call is the hazard
      ;; twice over: it must survive the interrupt, and its clock -- filed at the
      ;; body's START, because a `:PROPERTIES:' drawer has to sit directly under
      ;; the heading -- must survive the repaint that follows, which deletes
      ;; between the two body markers.
      (should (= 4 (ao--count-occurrences text "^:SECONDS:")))
      (should (= 4 (ao--count-occurrences text "^CLOCK:"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-headings-joins-thought-chunks-into-one-line ()
  "A thinking run reads as the agent's text stream, not one line per chunk.
The wire splits a thought wherever its tokens land -- \"the agent \" then
\"thinks twice\" -- and a plain append that closed every chunk with a newline
would render that as two lines of fragments.  So the body's LAST line is
provisional: the next chunk replaces that one line with the merged text, which
keeps a sentence whole AND stays visible while it arrives -- holding text back
until its newline would leave the user reading an empty heading."
  (let ((agent-org-activity-style 'headings)
        (buf (agent-org-buffer-create "headglue")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-thought buf "the agent ")
    (with-current-buffer buf
      ;; shown at once, as the line it will become -- without its trailing
      ;; space, which `--drawer-safe-lines' trims off the PAGE while
      ;; `agent-org-buffer--thought-tail' keeps the real text for the merge)
      (should (string-match-p "^ the agent$" (buffer-string))))
    (agent-org-buffer-append-thought buf "thinks twice\nthen again\n")
    (agent-org-buffer-append-thought buf "a trailing fragment")
    (agent-org-buffer-end-agent-turn buf)
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (apply #'ao--ordered text
                     (list "^\\*\\* THOUGHT Thinking$"
                           " the agent thinks twice$" " then again$"
                           " a trailing fragment$")))
      ;; the shape of the defect: a chunk opening its own line
      (should-not (string-match-p "^ thinks" text))
      ;; and the provisional line was REPLACED, not left beside its successor
      (should (= 1 (ao--count-occurrences text "the agent"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-headings-splits-a-stream-at-its-last-newline ()
  "The pure rule a streamed part appends by, pinned on its own.
`agent-org-buffer--split-stream' answers (COMPLETE . TAIL): text up to the last
newline is safe to put on the page, everything after it is still arriving.  Four
cases the render path cannot separate cheaply -- a mid-word chunk, a chunk that
closes a line, one that closes two, and a held run that never gets a newline."
  (should (equal (cons "" "the agent ")
                 (agent-org-buffer--split-stream "" "the agent ")))
  (should (equal (cons "the agent thinks" "")
                 (agent-org-buffer--split-stream "the agent " "thinks\n")))
  (should (equal (cons "one\ntwo" "thr")
                 (agent-org-buffer--split-stream "one\n" "two\nthr")))
  (should (equal (cons "" "still one line")
                 (agent-org-buffer--split-stream "still " "one line"))))

(ert-deftest test-agent-org-headings-parts-wear-their-own-set-words ()
  "A thought opens THINKING and settles THOUGHT, prose WRITING→WROTE, a call
RUNNING→EXECUTED -- each part reads its OWN set, never the prompt set's words.
\"we'll use TODO subheadings for EACH part of the response\" plus the five sets
the user ordered: the shared `** TODO' vocabulary made a thinking run
indistinguishable from a queued prompt, so the word on a part heading now says
what KIND of activity it is as well as whether it finished.

Asserted twice: once on the default words at each end of a part's life (the open
word while it is live, the settle word after the boundary), and once with every
set renamed, which is what proves the renderers are POSITIONAL.  A hardcoded
\"WROTE\" here would still pass phase one and fail phase two.
Renamed words are not states the buffer knows (its regexps were derived at
creation), so this reads the buffer's TEXT -- the shape of the line the user
sees -- rather than `org-get-todo-state'."
  (let ((agent-org-activity-style 'headings)
        (buf (agent-org-buffer-create "headsets")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-thought buf "weighing it")
    (with-current-buffer buf
      (should (string-match-p "^\\*\\* THINKING Thinking$" (buffer-string))))
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "t1") (title . "ls") (status . "in_progress")))
    (with-current-buffer buf
      (should (string-match-p "^\\*\\* RUNNING ls$" (buffer-string))))
    (agent-org-buffer-append-chunk buf "the answer\n" nil)
    (with-current-buffer buf
      (should (string-match-p "^\\*\\* WRITING Agent$" (buffer-string))))
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "t1") (title . "ls") (status . "completed")))
    (agent-org-buffer-end-agent-turn buf)
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (apply #'ao--ordered text
                     (list "^\\*\\* THOUGHT Thinking$"
                           "^\\*\\* EXECUTED ls$"
                           "^\\*\\* WROTE Agent$")))
      ;; the retired vocabulary is gone from every surface of the body
      (dolist (old '("ONGOING" "COMPLETE" "RESPONDED"))
        (should-not (string-match-p (concat "^\\*\\* " old) text)))))
  ;; PHASE TWO: rename every set, and the parts follow -- no renderer owns a word
  (let ((agent-org-activity-style 'headings)
        (agent-org-thinking-todo-keywords '("PONDERING" "|" "PONDERED"))
        (agent-org-response-todo-keywords '("TYPING" "|" "TYPED"))
        (agent-org-tool-todo-keywords '("QUEUED" "RUNNING" "|" "EXECUTED" "BROKEN"))
        (buf (agent-org-buffer-create "headsets2")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-thought buf "weighing it")
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "t1") (title . "ls") (status . "pending")))
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "t1") (title . "ls") (status . "in_progress")))
    (agent-org-buffer-append-chunk buf "the answer\n" nil)
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "t1") (title . "ls") (status . "failed")))
    (agent-org-buffer-end-agent-turn buf)
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (apply #'ao--ordered text
                     (list "^\\*\\* PONDERED Thinking$"
                           "^\\*\\* BROKEN ls$"
                           "^\\*\\* TYPED Agent$")))
      ;; the FIRST unfinished word of the renamed tool set opens the call and its
      ;; SECOND is what `in_progress' wears -- the positional rule, on a set with
      ;; room for it; and the second DONE word is what a failure gets
      (should (= 1 (ao--count-occurrences text "BROKEN ls")))
      (should (= 1 (ao--count-occurrences text "^\\*\\* TYPED Agent$")))
      (should (= 1 (ao--count-occurrences text "^\\*\\* PONDERED Thinking$"))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-headings-clocks-every-part ()
  "Each part of a turn gets its OWN clock, and Org's reader sees all of them.
\"each of them should be clocked\" -- so the measurement is keyed off the
activity, not off the exchange: a thinking run that ran 70 s before a call is
readable as 70 s even though the whole turn took minutes.  Asserted through
`org-entry-get' at each heading (proof the `:PROPERTIES:' drawer sits directly
under the heading Org looks at) and by counting `clock' parse nodes (proof the
range is the canonical form, not a line that merely resembles one).
Three parts, three CLOCK lines: the turn here was opened with
`start-agent-turn' rather than a typed prompt, so `--close-response-clock' has no
`--turn-start' to spend and files no exchange clock -- which the second half of
this test checks by going through a real exchange instead."
  (let ((agent-org-activity-style 'headings)
        (buf (agent-org-buffer-create "headclock")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-thought buf "weighing it")
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "t1") (title . "ls") (status . "completed")
           ,@(ao--tool-text-block "a.org")))
    (agent-org-buffer-append-chunk buf "the answer\n" nil)
    (agent-org-buffer-end-agent-turn buf)
    (with-current-buffer buf
      (dolist (heading (list "^\\*\\* THOUGHT Thinking$"
                             "^\\*\\* EXECUTED ls$"
                             "^\\*\\* WROTE Agent$"))
        (save-excursion
          (goto-char (point-min))
          (should (re-search-forward heading nil t))
          (should (org-entry-get (point) "SECONDS"))))
      (should (= 3 (ao--count-occurrences (buffer-string) "^CLOCK: ")))
      (should (= 3 (ao--count-nodes 'clock)))
      ;; a part's clock is CLOSED, so `org-clock-load' can never mistake a chat
      ;; for a running clock (AGENTS.md §22)
      (should-not (string-match-p "^CLOCK: \\[.*\\]--$" (buffer-string))))
    (kill-buffer buf))
  (let ((agent-org-activity-style 'headings))
    (ao--capture-wire
      (let ((chat (ao--chat-on-model "qmodel" "QModel")))
        ;; the same turn through a real exchange: the prompt heading carries the
        ;; turn's clock and the parts carry their own, so a clock table reads
        ;; both levels of the same measurement
        (with-current-buffer chat
          (ao--send-one "Capital?")
          (ao--rewind-turn-start 4500)
          (agent-org-buffer-append-thought chat "weighing it")
          (agent-org-buffer-append-chunk chat "Paris.\n"
                                         (agent-org-buffer--session))
          (agent-org-buffer-end-agent-turn chat)
          ;; the exchange's own clock plus one per part (thought and answer --
          ;; no call in this turn)
          (should (= 3 (ao--count-occurrences (buffer-string) "^CLOCK: ")))
          (save-excursion
            (goto-char (point-min))
            (re-search-forward "^\\* RESPONDED Capital\\?$")
            (should (equal "4500" (org-entry-get (point) "RESPONSE"))))
          ;; the exchange, its thought, its answer, and the type-ahead box that
          ;; is always last: four real headlines
          (should (equal 4 (ao--count-nodes 'headline))))
        (kill-buffer chat)))))

(ert-deftest test-agent-org-headings-replay-files-no-part-clock ()
  "A restored turn renders its parts but invents no timings.
`agent-org-buffer--record-clock-p' is the one gate, and it is bound nil for the
replay: a restored conversation has no clock to recover, and a fabricated
`CLOCK:' among the user's real ones corrupts every clock table that reads the
file.  The parts themselves still arrive in order -- the same primitives render
both, which is the rule against a second replay renderer."
  (let ((agent-org-activity-style 'headings)
        (agent-org-buffer--record-clock-p nil)
        (buf (agent-org-buffer-create "headnoreplay")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-thought buf "weighing it")
    (agent-org-buffer-append-chunk buf "the answer\n" nil)
    (agent-org-buffer-end-agent-turn buf)
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (apply #'ao--ordered text
                     (list "^\\*\\* THOUGHT Thinking$" " weighing it$"
                           "^\\*\\* WROTE Agent$" "^the answer$")))
      (should-not (string-match-p "^CLOCK: " text))
      (should-not (string-match-p "^:SECONDS: " text)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-headings-keeps-structure-org-reads ()
  "A part turn parses as the headings it is, not as one flattened section.
The drawer-era hazard (a `*' at column 0 ending a block) has a part-era shape:
prose is flush-left by design here (see `agent-org-buffer--response-safe-lines')
while a thought's and a call's bodies are indented one column, so a wrong
assumption about either shows up as the parser losing a headline.  Counted
through `org-element': four headlines for three parts under one exchange."
  (let ((agent-org-activity-style 'headings)
        (buf (agent-org-buffer-create "headstruct")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-append-thought buf "weighing it")
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "t1") (title . "ls") (status . "completed")
           ,@(ao--tool-text-block "a.org")))
    (agent-org-buffer-append-chunk buf "the answer\n" nil)
    (agent-org-buffer-end-agent-turn buf)
    (with-current-buffer buf
      (should (= 4 (ao--count-nodes 'headline))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-activity-style-none-wraps-nothing ()
  "With `agent-org-activity-style' `none' the turn's body holds bare list items.
The option the user asked for: \"Add options for not to wrap tool calls with
:tool: drawers.\"  Nothing to open, nothing to fold: every call is a line of the
turn, its output under it, and a thinking run is a labelled paragraph.  The
record and the redraw guard are unchanged, so a status update still rewrites the
ONE line rather than adding another."
  (let ((agent-org-activity-style 'none)
        (buf (agent-org-buffer-create "bare")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "t1") (title . "ls") (status . "completed")
           ,@(ao--tool-text-block "a.org")))
    (agent-org-buffer-append-thought buf "weighing it")
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "t2") (title . "grep") (status . "pending")))
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "t2") (title . "grep") (status . "completed")))
    (let ((text (with-current-buffer buf (buffer-string))))
      (should-not (string-match-p "^:tool:$\\|^:thinking:$" text))
      (should (= 2 (ao--count-occurrences text "^- ")))
      (should (string-match-p "^- EXECUTED ls$" text))
      (should (string-match-p "^- EXECUTED grep$" text))
      (should-not (string-match-p "^- RUNNING grep$" text))
      (should (= 1 (ao--count-occurrences text "^  a.org$")))
      (should (string-match-p "^Thinking:$" text))
      (should (string-match-p "^ weighing it$" text)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-activity-style-headings-uses-todo-headlines ()
  "With `agent-org-activity-style' `headings' a call IS a TODO headline.
\"it shouldn't be lists, but TODO headings\" -- and the reason this is an option
rather than a fix is that Org forbids a headline inside a drawer (info
\"(org) Drawers\"): a call can be a `**' or it can be in a `:tool:' drawer, never
both.  Folding is Org's own subtree fold from then on, which is why this mode
needs no drawer code at all (see
`test-agent-org-activity-style-headings-folds-with-org-cycle')."
  (let ((agent-org-activity-style 'headings)
        (buf (agent-org-buffer-create "heads")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "t1") (title . "ls") (status . "in_progress")
           ,@(ao--tool-text-block "a.org")))
    (agent-org-buffer-append-thought buf "weighing it")
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "t1") (title . "ls") (status . "completed")))
    (let ((text (with-current-buffer buf (buffer-string))))
      (should-not (string-match-p "^:tool:$\\|^:thinking:$" text))
      (should (string-match-p "^\\*\\* THINKING Thinking$" text))
      (should (string-match-p "^ weighing it$" text))
      ;; the call's own keyword moved in place: no second headline for t1
      (should (string-match-p "^\\*\\* EXECUTED ls$" text))
      (should-not (string-match-p "^\\*\\* RUNNING ls$" text))
      (should (= 1 (ao--count-occurrences text "^\\*\\* EXECUTED ls$")))
      (should (string-match-p "^ a.org$" text))
      ;; and the words are REAL keywords: the three sets are installed in this
      ;; buffer, so `EXECUTED' here is a state, not text.  There is no `#+TODO:'
      ;; line to assert any more -- arc 3 put the sets in `org-todo-keywords'
      ;; buffer-locally, which is what `ao--todo-set-matches-the-options' reads.
      (should (ao--todo-set-matches-the-options buf)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-activity-style-headings-makes-the-response-a-heading ()
  "In headings mode the answer opens with a TODO headline and closes as done.
The user's condition on the option: \"In this case, we'll also use TODO heading
for responses.\"  So the prefix line that reads `MiniMax M3: ' in every other
mode reads `** WRITING MiniMax M3' here, and `agent-org-buffer-end-agent-turn'
settles it to WROTE -- the answer's own state, in the same vocabulary the
prompt headings use.

A turn that answered with tools only keeps no such headline: the empty response
is dropped before the boundary, exactly as in the other modes."
  (let ((agent-org-activity-style 'headings)
        (buf (agent-org-buffer-create "headresp")))
    (agent-org-buffer-start-agent-turn buf nil)
    ;; the newline is part of the assertion: the converter appends at LINE
    ;; granularity (`agent-org-buffer--markdown-receive'), so a chunk still
    ;; arriving is held in the fragment and the heading is the only answer
    ;; furniture in the buffer yet -- a chunk with no newline tests the flush,
    ;; not the heading
    (agent-org-buffer-append-chunk buf "here is the fix\n" nil)
    (with-current-buffer buf
      (should (string-match-p "^\\*\\* WRITING " (buffer-string)))
      (should (string-match-p "here is the fix" (buffer-string))))
    (agent-org-buffer-end-agent-turn buf)
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (string-match-p "^\\*\\* WROTE " text))
      (should-not (string-match-p "^\\*\\* WRITING " text))
      ;; the prose is still the answer node's body, not a stray heading
      (should (apply #'ao--ordered text (list "^\\*\\* WROTE " "here is the fix"))))
    (kill-buffer buf))
  (let ((agent-org-activity-style 'headings)
        (buf (agent-org-buffer-create "headtoolonly")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "t1") (title . "ls") (status . "completed")))
    (agent-org-buffer-end-agent-turn buf)
    (let ((text (with-current-buffer buf (buffer-string))))
      ;; a turn whose only activity was a call opens NO answer part at all
      (should-not (string-match-p "^\\*\\* WRIT" text))
      (should (string-match-p "^\\*\\* EXECUTED ls$" text)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-activity-style-headings-folds-with-org-cycle ()
  "Folding in headings mode is Org's own: no drawer machinery is involved.
\"Org's folding functions and variables should be enough for us to handle
default folding behavior.\"  A call's output is the body of its headline, so TAB
on that headline hides it the way it hides any subtree -- which is the whole
folding story in this mode, and why it ships with no fold code of its own."
  (let ((agent-org-activity-style 'headings)
        (buf (agent-org-buffer-create "headfold")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf `((toolCallId . "t1") (title . "ls") (status . "completed")
           ,@(ao--tool-text-block "a.org")))
    (with-current-buffer buf
      (let ((out (save-excursion (goto-char (point-min))
                                 (re-search-forward "^ a.org$")
                                 (point))))
        (should-not (invisible-p out))
        (goto-char (point-min))
        (re-search-forward "^\\*\\* EXECUTED ls$")
        (org-cycle)
        (should (invisible-p out))))
    (kill-buffer buf)))

(provide 'test-agent-org)
;;; test-agent-org.el ends here

(ert-deftest test-agent-org-tool-board-folds-consecutive-same-calls ()
  "Consecutive calls of one title and one status fold into one item
carrying the count — `- COMPLETE run tests (x3)' — with every call's
output kept beneath it, in call order (user ruling 2026-10-21,
TODOs.org §Tool-call grouping).  The record is untouched: one entry per
toolCallId, folding is rendering."
  (let ((buf (agent-org-buffer-create "toolfold")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "a1") (title . "run tests") (status . "completed")
           (rawOutput . ((formatted_output . "first run ok\n")))))
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "a2") (title . "run tests") (status . "completed")
           (rawOutput . ((formatted_output . "second run ok\n")))))
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "a3") (title . "run tests") (status . "completed")
           (rawOutput . ((formatted_output . "third run ok\n")))))
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "b1") (title . "lint") (status . "completed")))
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (= 1 (ao--count-occurrences
                    text "^  - EXECUTED run tests [(]x3[)]$")))
      (should (= 1 (ao--count-occurrences text "^  - EXECUTED lint$")))
      ;; all three bodies survive the fold, call order preserved
      (should (string-match-p "^    first run ok$" text))
      (should (string-match-p "^    second run ok$" text))
      (should (string-match-p "^    third run ok$" text))
      (should (< (string-match "first run ok" text)
                 (string-match "second run ok" text)
                 (string-match "third run ok" text))))
    (kill-buffer buf)))

(ert-deftest test-agent-org-tool-board-does-not-fold-across-status ()
  "A RUNNING call never folds into COMPLETED ones of the same title:
the keyword is the item's state, and a folded state would lie about
every member.  Two calls that share a title but not a status stay two
items, even back to back."
  (let ((buf (agent-org-buffer-create "toolnofold")))
    (agent-org-buffer-start-agent-turn buf nil)
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "a1") (title . "run tests")
           (status . "completed")))
    (agent-org-buffer-insert-tool
     buf '((toolCallId . "a2") (title . "run tests")
           (status . "running")))
    (let ((text (with-current-buffer buf (buffer-string))))
      (should (= 1 (ao--count-occurrences text "^  - EXECUTED run tests$")))
      (should (= 1 (ao--count-occurrences text "^  - RUNNING run tests$")))
      (should-not (string-match-p "(x2)" text)))
    (kill-buffer buf)))

(ert-deftest test-agent-org-model-candidates-clean-bare-ids ()
  "An option without a `name' shows its id minus the provider path:
`minimax/MiniMax-M3' reads \"MiniMax-M3\".  The menu's contract is that
the user never completes over bare ids, and the wire value stays the
cdr so the request still sends what the agent advertised."
  (let ((candidates (agent-org--model-candidates
                     '((id . "model")
                       (options . [((value . "minimax/MiniMax-M3")
                                    (name . "MiniMax M3"))
                                   ((value . "zai/glm-4.7-flash"))])))))
    (should (equal candidates
                   '(("MiniMax M3" . "minimax/MiniMax-M3")
                     ("glm-4.7-flash" . "zai/glm-4.7-flash"))))))
(ert-deftest test-agent-org-sources-carry-no-secret-guard-shape ()
  "No tracked file may contain a substring the CI secret guard would redact.
The guard (.github/scripts/secret-guard.sh) applies its GENERIC alternation
with `sed -E' UNANCHORED, so an ordinary identifier — anything spelled
\"...pt-\" followed by eight alphanumerics — is a match, and branch mode
rewrites the WHOLE of every file in the branch diff before amend-committing
it, AFTER the seat ran the gate.  A redacted `defcustom' line is \"Junk in
args\" and a redacted docstring is \"docstring wider than 80 characters\", so
the landing gate goes red and finalize undoes the merge (measured 2026-10-28:
85 lines over 11 files, four seats' work lost in transit).
The pattern is READ from the script rather than restated here, so anchoring
it upstream keeps this green — an anchored pattern matches no identifier."
  (let ((script (expand-file-name ".github/scripts/secret-guard.sh"
                                  ao--package-root))
        (pattern nil)
        (tracked nil)
        (bad '()))
    (skip-unless (and (file-exists-p script) (executable-find "grep")))
    (setq pattern
          (with-temp-buffer
            (insert-file-contents script)
            (when (search-forward "GENERIC='" nil t)
              (string-remove-suffix "'"
                                     (buffer-substring-no-properties
                                      (point) (line-end-position))))))
    (skip-unless (and pattern (> (length pattern) 0)))
    (setq tracked
          (with-temp-buffer
            (let ((default-directory ao--package-root))
              (call-process "git" nil t nil "ls-files" "-z"))
            (split-string (buffer-string) "\0" t)))
    (skip-unless tracked)
    (dolist (f tracked)
      (let ((path (expand-file-name f ao--package-root)))
        (when (and (file-regular-p path)
                   (= 0 (call-process "grep" nil nil nil
                                      "-q" "-E" "-e" pattern "--" path)))
          (push f bad))))
    (when bad (message "secret-guard would redact: %S" (nreverse bad)))
    (should (null bad))))
