;;; test-agent-org-review-teach.el --- Tests for the human-in-the-loop layer -*- lexical-binding: t; -*-

;; These tests cover ONLY the pure helpers of agent-org-review-teach, which
;; is why they can run in batch without an acp session, a network, or a live
;; chat buffer.  The interactive commands wrap those helpers rather than
;; reimplementing them, so a defect in a helper shows up here.

(require 'ert)
(require 'cl-lib)

(add-to-list 'load-path
             (file-name-directory (directory-file-name
                                   (file-name-directory
                                    (or load-file-name buffer-file-name)))))
(require 'agent-org-review-teach)

;;; --- risk -----------------------------------------------------------------

(ert-deftest review-teach-risk-tiers-in-descending-order ()
  "The course's ordering: security outranks correctness outranks requirement."
  (should (= 4 (agent-org-review-teach-risk "security: SQL injection")))
  (should (= 3 (agent-org-review-teach-risk "correctness: off-by-one")))
  (should (= 2 (agent-org-review-teach-risk "requirement: not asked for")))
  (should (= 1 (agent-org-review-teach-risk "style: line too long")))
  (should (> (agent-org-review-teach-risk "security hole")
             (agent-org-review-teach-risk "style nit"))))

(ert-deftest review-teach-risk-unclassified ()
  "Anything with no tier word gets the default, including non-strings."
  (should (= 0 (agent-org-review-teach-risk "unclassifiable remark")))
  (should (= 0 (agent-org-review-teach-risk nil)))
  (should (= 0 (agent-org-review-teach-risk 42)))
  (let ((agent-org-review-teach-default-tier 7))
    (should (= 7 (agent-org-review-teach-risk "no tier here")))))

(ert-deftest review-teach-risk-is-case-insensitive ()
  (should (= 4 (agent-org-review-teach-risk "SECURITY issue"))))

(ert-deftest review-teach-risk-custom-tiers-respected ()
  (let ((agent-org-review-teach-risk-tiers '(("typo" . 9))))
    (should (= 9 (agent-org-review-teach-risk "typo in a comment")))))

;;; --- triage ---------------------------------------------------------------

(ert-deftest review-teach-triage-orders-riskiest-first ()
  (should (equal '("security: a" "correctness: b" "requirement: c" "style: d")
                 (agent-org-review-teach-triage
                  '("style: d" "requirement: c" "security: a" "correctness: b")))))

(ert-deftest review-teach-triage-limit-keeps-riskiest ()
  (should (equal '("security: a" "correctness: b")
                 (agent-org-review-teach-triage
                  '("style: d" "requirement: c" "security: a" "correctness: b") 2))))

(ert-deftest review-teach-triage-limit-larger-than-input-is-safe ()
  (should (equal '("style: only")
                 (agent-org-review-teach-triage '("style: only") 10))))

(ert-deftest review-teach-triage-empty-and-nil ()
  (should (null (agent-org-review-teach-triage nil)))
  (should (equal '() (agent-org-review-teach-triage '()))))

(ert-deftest review-teach-triage-does-not-consume-input ()
  "Sorting must not mutate the caller's list -- a shared list would corrupt
  a later triage of the same findings."
  (let ((findings (list "security: a" "style: b")))
    (agent-org-review-teach-triage findings)
    (should (equal '("security: a" "style: b") findings))))

(ert-deftest review-teach-triage-is-stable-within-a-tier ()
  (should (equal '("security: a" "security: b" "security: c")
                 (agent-org-review-teach-triage
                  '("security: b" "security: a" "security: c")))))

;;; --- blast radius ---------------------------------------------------------

(ert-deftest review-teach-blast-radius-counts-distinct-paths ()
  (should (plist-get (agent-org-review-teach-blast-radius '("a.el" "a.el" "b.el"))
                     :count))
  (should (= 2 (plist-get (agent-org-review-teach-blast-radius
                           '("a.el" "a.el" "b.el")) :count))))

(ert-deftest review-teach-blast-radius-finds-repeated-touches ()
  (should (equal '("a.el")
                 (plist-get (agent-org-review-teach-blast-radius
                             '("a.el" "b.el" "a.el")) :touched-twice))))

(ert-deftest review-teach-blast-radius-spots-cache-and-tests ()
  (let ((r (agent-org-review-teach-blast-radius
            '("src/auth.el" "build/out.js" "node_modules/x/y.js"
              "tests/test-auth.el" "spec/x_spec.rb"))))
    (should (member "build/out.js" (plist-get r :cache)))
    (should (member "node_modules/x/y.js" (plist-get r :cache)))
    (should (member "tests/test-auth.el" (plist-get r :tests)))
    (should (member "spec/x_spec.rb" (plist-get r :tests)))))

(ert-deftest review-teach-blast-radius-does-not-call-source-a-test ()
  "A path merely containing the letters t-e-s-t must not count."
  (should (null (plist-get (agent-org-review-teach-blast-radius '("src/latest.el"))
                           :tests))))

(ert-deftest review-teach-blast-radius-handles-empty ()
  (let ((r (agent-org-review-teach-blast-radius nil)))
    (should (= 0 (plist-get r :count)))
    (should (null (plist-get r :touched-twice)))))

;;; --- plan first -----------------------------------------------------------

(ert-deftest review-teach-plan-suggestion-silent-for-short-prompts ()
  "A short request is a conversation; it must never get the lecture."
  (should-not (agent-org-review-teach-plan-suggestion "fix it"))
  (should-not (agent-org-review-teach-plan-suggestion "")))

(ert-deftest review-teach-plan-suggestion-fires-for-long-code-prompt ()
  (let ((s (agent-org-review-teach-plan-suggestion
            (concat "Refactor the auth module to use JWT. "
                    (make-string 300 ?x)))))
    (should s)
    (should (string-match-p "Plan first" s))
    (should (string-match-p "wait for my go-ahead" s))))

(ert-deftest review-teach-plan-suggestion-silent-when-plan-requested ()
  (should-not (agent-org-review-teach-plan-suggestion
               (concat "please plan how to refactor the auth module, "
                       "then list the steps " (make-string 300 ?x)))))

(ert-deftest review-teach-plan-suggestion-silent-when-test-requested ()
  (should-not (agent-org-review-teach-plan-suggestion
               (concat "implement the JWT login and write tests for it "
                       (make-string 300 ?x)))))

(ert-deftest review-teach-plan-suggestion-silent-without-a-code-verb ()
  (should-not (agent-org-review-teach-plan-suggestion (make-string 300 ?x))))

(ert-deftest review-teach-plan-suggestion-can-be-disabled ()
  (let ((agent-org-review-teach-plan-threshold nil))
    (should-not (agent-org-review-teach-plan-suggestion
                 (concat "refactor everything " (make-string 300 ?x))))))

(ert-deftest review-teach-plan-words-detects-the-prompt-verbs ()
  (should (equal '("refactor")
                 (agent-org-review-teach--code-words
                  "Refactor the parser now please")))
  (should-not (agent-org-review-teach--code-words "what does this do")))

(ert-deftest review-teach-claims-plan-and-test-detectors ()
  (should (agent-org-review-teach--claims-plan-p "give me the plan"))
  (should (agent-org-review-teach--claims-plan-p "first, show me the steps"))
  (should-not (agent-org-review-teach--claims-plan-p "just do it"))
  (should (agent-org-review-teach--claims-test-p "write tests for it"))
  (should (agent-org-review-teach--claims-test-p "verify it works"))
  (should-not (agent-org-review-teach--claims-test-p "never mind")))

;;; --- defaults -------------------------------------------------------------

(ert-deftest review-teach-lessons-file-defaults-under-the-transcripts ()
  "Lessons belong next to the transcripts so the same agent reads both."
  (should (string-match-p "AGENT-LESSONS\\.org\\'"
                          agent-org-review-teach-lessons-file)))

;;; review-teach test group ends here
(provide 'test-agent-org-review-teach)
;;; test-agent-org-review-teach.el ends here
