;;; compat.el --- Test-harness compat for an older Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Khalid

;; Author: Khalid

;;; Commentary:

;; The CI harness runs `emacs -Q --batch' on Emacs 28.2, whose ert-x has no
;; `ert-with-temp-directory' and whose subr.el/cus-edit have no `setopt' —
;; both landed in 29.1.  A suite that dies on a void-function says nothing
;; about the code under test, so both suites load this prelude and get the
;; same job: a temp directory created empty and removed with its contents,
;; and a user option set through its own customize setter.
;;
;; On the Emacs the package declares (29.1+) every form here is a no-op.

;;; Code:

(require 'ert)
(require 'ert-x)

(unless (fboundp 'ert-with-temp-directory)
  (defmacro ert-with-temp-directory (var &rest body)
    "Like the Emacs 29 `ert-with-temp-directory': bind VAR to a fresh
directory, remove it and everything under it on the way out.  VAR is also
accepted in the `(VAR)' spelling the 29 manual shows."
    (declare (indent 1) (debug (sexp body)))
    (let ((symbol (if (consp var) (car var) var)))
      `(let ((,symbol (make-temp-file "ert-dir-" t)))
         (unwind-protect
             (progn ,@body)
           (delete-directory ,symbol t))))))

(unless (fboundp 'setopt)
  (defmacro setopt (symbol value)
    "Like the Emacs 29 `setopt': set SYMBOL to VALUE through its customize
setter, so a value the option's own :type rejects is still refused."
    (declare (indent 1) (debug (sexp form)))
    `(customize-set-variable ',symbol ,value)))

(provide 'agent-org-test-compat)
;;; compat.el ends here
