
(defpackage #:ourro.qa.spend
  (:use #:cl)
  (:export #:*pricing*
           #:model-pricing #:usage-cost
           #:sum-events-file #:sum-home
           #:ledger-file #:ledger-append #:ledger-total))

(in-package #:ourro.qa.spend)


(defparameter *pricing*
  ;; backend-model-id → (:in :out :cache-read), USD per 1e6 tokens.
  '(("gemini-3.5-flash"                 :in 0.3d0  :out 2.5d0  :cache-read 0.075d0)
    ("gemini-3.1-pro-preview"           :in 2.0d0  :out 12.0d0 :cache-read 0.5d0)
    ("global.anthropic.claude-opus-4-5-20251101-v1:0"  :in 5.0d0 :out 25.0d0 :cache-read 0.5d0)
    ("global.anthropic.claude-sonnet-4-5-20250929-v1:0" :in 3.0d0 :out 15.0d0 :cache-read 0.3d0)
    ("global.anthropic.claude-haiku-4-5-20251001-v1:0"  :in 1.0d0 :out 5.0d0 :cache-read 0.1d0)))

(defun model-pricing (model-id)
  "Pricing plist for a backend MODEL-ID, or NIL when unknown (unknown-model
calls still count tokens; they just price at 0 — the token count in the
ledger makes the gap visible)."
  (let ((entry (assoc (or model-id "") *pricing* :test #'string-equal)))
    (rest entry)))

(defun usage-count (usage key)
  "A usage field as a number — anything else (missing, or the \"«redacted»\"
strings pre-fix event logs carry) counts as 0 instead of crashing the sum."
  (let ((v (getf usage key)))
    (if (numberp v) v 0)))

(defun usage-cost (usage pricing)
  "USD for one call. Mirrors the product's turn-cost: cache-read tokens are
a discounted subset of the prompt tokens."
  (let ((in (usage-count usage :prompt-tokens))
        (out (usage-count usage :candidates-tokens))
        (cache-read (usage-count usage :cache-read-tokens)))
    (+ (* (/ (max 0 (- in cache-read)) 1000000.0d0) (or (getf pricing :in) 0))
       (* (/ cache-read 1000000.0d0)
          (or (getf pricing :cache-read) (getf pricing :in) 0))
       (* (/ out 1000000.0d0) (or (getf pricing :out) 0)))))


(defun read-plist-lines (pathname)
  "Read PATHNAME as one plist per line, skipping unreadable lines (a torn
tail write must not zero a whole phase's spend). Reads in THIS package (which
uses CL) — never KEYWORD, where the event log's `:usage NIL` would read as
the truthy `:usage :NIL` and break the accounting (the exact bug
operator.lisp's QA-PACKAGE docstring records)."
  (when (probe-file pathname)
    (with-open-file (in pathname :direction :input :external-format :utf-8)
      (loop for line = (read-line in nil nil)
            while line
            for form = (let ((*read-eval* nil)
                             (*package* (find-package :ourro.qa.spend)))
                         (ignore-errors (read-from-string line)))
            ;; Keep only well-formed plists. Event records whose strings
            ;; contain literal newlines (a :user-message carrying a whole
            ;; mission) span several physical lines; the fragments read as
            ;; junk forms like (repeat on timeout) and GETF would error on
            ;; them ("malformed property list") — the crash that killed the
            ;; first live conductor cycle.
            when (plist-p form) collect form))))

(defun plist-p (form)
  (and (consp form)
       (null (cdr (last form)))         ; proper list (a dotted pair reads fine)
       (evenp (length form))
       (loop for key in form by #'cddr always (keywordp key))))

(defun sum-events-file (pathname)
  "Sum the :llm-call events of one events.sexp: (:usd R :calls N :in-tokens N
:out-tokens N :by-model ((model usd) …))."
  (let ((usd 0.0d0) (calls 0) (in-tokens 0) (out-tokens 0)
        (by-model '()))
    (dolist (event (read-plist-lines pathname))
      (when (eq (getf event :kind) :llm-call)
        (incf calls)
        (let* ((usage (getf event :usage))
               (model (getf event :model))
               (cost (usage-cost usage (model-pricing model))))
          (incf usd cost)
          (incf in-tokens (usage-count usage :prompt-tokens))
          (incf out-tokens (usage-count usage :candidates-tokens))
          (let ((hit (assoc model by-model :test #'equal)))
            (if hit
                (incf (second hit) cost)
                (push (list model cost) by-model))))))
    (list :usd usd :calls calls :in-tokens in-tokens :out-tokens out-tokens
          :by-model by-model)))

(defun sum-home (home)
  "Sum every sessions/*/events.sexp under an $OURRO_HOME — one instance's
whole spend, restarts and background context included."
  (let ((usd 0.0d0) (calls 0) (in-tokens 0) (out-tokens 0))
    (dolist (file (directory
                   (merge-pathnames "sessions/*/events.sexp"
                                    (pathname-as-directory home))))
      (let ((sum (sum-events-file file)))
        (incf usd (getf sum :usd))
        (incf calls (getf sum :calls))
        (incf in-tokens (getf sum :in-tokens))
        (incf out-tokens (getf sum :out-tokens))))
    (list :usd usd :calls calls :in-tokens in-tokens :out-tokens out-tokens)))

(defun pathname-as-directory (path)
  (let ((name (namestring path)))
    (if (char= #\/ (char name (1- (length name))))
        (pathname name)
        (pathname (concatenate 'string name "/")))))


(defun utc-date-string (&optional (universal (get-universal-time)))
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time universal 0)
    (declare (ignore sec min hour))
    (format nil "~4,'0D-~2,'0D-~2,'0D" year month day)))

(defun ledger-file (ledger-dir &optional (date (utc-date-string)))
  (merge-pathnames (format nil "~A.sexp" date)
                   (pathname-as-directory ledger-dir)))

(defun ledger-append (ledger-dir entry &key (date (utc-date-string)))
  "Append ENTRY (a plist, e.g. (:cycle N :phase :run-operator :usd R …)) to
the day's ledger file."
  (let ((file (ledger-file ledger-dir date)))
    (ensure-directories-exist file)
    (with-open-file (out file :direction :output :external-format :utf-8
                              :if-exists :append :if-does-not-exist :create)
      (let ((*print-pretty* nil) (*print-readably* nil)
            (*package* (find-package :keyword)))
        (prin1 entry out) (terpri out)))
    file))

(defun ledger-total (ledger-dir &key (date (utc-date-string)))
  "Total :usd recorded for DATE."
  (let ((total 0.0d0))
    (dolist (entry (read-plist-lines (ledger-file ledger-dir date)))
      (incf total (or (getf entry :usd) 0)))
    total))
