
(in-package #:ourro.tests)

(def-suite ledger-suite :in ourro)
(in-suite ledger-suite)

(defmacro with-fresh-ledger (&body body)
  `(let ((ourro.observe:*utility-ledger* (make-hash-table :test #'equal))
         (ourro.observe:*gene-measurable-hook* nil))
     ,@body))

(test use-accumulation
  (with-fresh-ledger
    (ourro.observe:note-gene-use "tool/x" 100 nil)
    (ourro.observe:note-gene-use "tool/x" 300 nil)
    (ourro.observe:note-gene-use "tool/x" 200 t)   ; an errored use
    (is (= 2 (ourro.observe:gene-uses "tool/x")))
    (is (= 200 (ourro.observe:gene-mean-ms "tool/x")))
    (let ((u (ourro.observe:gene-utility "tool/x")))
      (is (= 1 (getf u :errors)))
      (is (= 400 (getf u :total-ms)))
      (is (integerp (getf u :first-use)))
      (is (integerp (getf u :last-use))))))

(test savings-formula
  (with-fresh-ledger
    ;; baseline 500ms/occurrence, evolved runs at 200ms mean over 3 uses.
    (ourro.observe:set-gene-baseline "tool/y" 500 "manual edit→test")
    (ourro.observe:note-gene-use "tool/y" 200 nil)
    (ourro.observe:note-gene-use "tool/y" 200 nil)
    (ourro.observe:note-gene-use "tool/y" 200 nil)
    ;; 3 × (500 − 200) = 900ms
    (is (= 900 (ourro.observe:gene-savings-ms "tool/y")))))

(test savings-zero-without-baseline
  (with-fresh-ledger
    (ourro.observe:note-gene-use "tool/z" 50 nil)
    (is (= 0 (ourro.observe:gene-savings-ms "tool/z"))))
  ;; And never negative when the gene is slower than the baseline.
  (with-fresh-ledger
    (ourro.observe:set-gene-baseline "tool/z" 100 nil)
    (ourro.observe:note-gene-use "tool/z" 400 nil)
    (is (= 0 (ourro.observe:gene-savings-ms "tool/z")))))

(test persistence-round-trip
  (uiop:with-temporary-file (:pathname path :type "sexp")
    (with-fresh-ledger
      (ourro.observe:note-gene-use "tool/a" 120 nil)
      (ourro.observe:set-gene-baseline "tool/a" 400 "manual a")
      (ourro.observe:set-gene-frozen "tool/a" t)
      (ourro.observe:save-utility-ledger path))
    (with-fresh-ledger
      (ourro.observe:load-utility-ledger path)
      (is (= 1 (ourro.observe:gene-uses "tool/a")))
      (is (ourro.observe:gene-frozen-p "tool/a"))
      (is (= 400 (getf (ourro.observe:gene-utility "tool/a") :baseline-ms))))))

(test log-event-feeds-ledger
  ;; The instrumented method combination logs :tool-call with :gene; the
  ;; installed hook must record it. Seed-less genes are measured by default.
  (with-fresh-ledger
    (let ((ourro.observe::*recent-events* '())
          (ourro.observe::*event-log-path* nil))
      (ourro.observe:log-event :tool-call :tool "foo" :gene "tool/foo"
                                         :elapsed-ms 42 :outcome :ok)
      (ourro.observe:log-event :tool-call :tool "bar" :gene nil
                                         :elapsed-ms 10 :outcome :ok)
      (is (= 1 (ourro.observe:gene-uses "tool/foo")))
      (is (= 0 (ourro.observe:gene-uses "tool/bar"))))))

(test measurable-hook-excludes
  (with-fresh-ledger
    (let ((ourro.observe:*gene-measurable-hook*
            (lambda (name) (not (string= name "tool/seed")))))
      (ourro.observe:note-gene-use "tool/seed" 100 nil)
      (ourro.observe:note-gene-use "tool/real" 100 nil)
      (is (= 0 (ourro.observe:gene-uses "tool/seed")))
      (is (= 1 (ourro.observe:gene-uses "tool/real"))))))


(test utility-summary-aggregates
  (with-fresh-ledger
    (let ((ourro.observe:*genome-gene-count-fn* (lambda () 9)))
      ;; gene x: baseline 500, three 200ms uses → 900ms saved.
      (ourro.observe:set-gene-baseline "tool/x" 500 nil)
      (ourro.observe:note-gene-use "tool/x" 200 nil)
      (ourro.observe:note-gene-use "tool/x" 200 nil)
      (ourro.observe:note-gene-use "tool/x" 200 nil)
      ;; gene y: no baseline → contributes uses but zero savings.
      (ourro.observe:note-gene-use "tool/y" 100 nil)
      (let ((s (ourro.observe:utility-summary)))
        (is (= 900 (getf s :saved-ms)))
        (is (= 4 (getf s :uses)))
        (is (= 1 (getf s :measured-genes)))
        (is (= 9 (getf s :genes)))))))

(test utility-summary-empty-ledger
  (with-fresh-ledger
    ;; Unwired count fn → :genes NIL (the HUD renders an empty cell).
    (let ((ourro.observe:*genome-gene-count-fn* nil))
      (let ((s (ourro.observe:utility-summary)))
        (is (= 0 (getf s :saved-ms)))
        (is (= 0 (getf s :uses)))
        (is (null (getf s :genes)))))))


(test retirement-predicate
  (with-fresh-ledger
    (flet ((set-entry (name plist)
             (setf (gethash name ourro.observe:*utility-ledger*) plist)))
      ;; ≥2 reverts → retire
      (set-entry "g/reverted"
                 (list :uses 3 :errors 0 :reverts 2 :first-use (ourro.util:unix-time)))
      (is-true (ourro.agent::retirement-reason "g/reverted"))
      ;; errors on most uses (uses≥4, errors>uses/2)
      (set-entry "g/buggy"
                 (list :uses 4 :errors 3 :reverts 0 :first-use (ourro.util:unix-time)))
      (is-true (ourro.agent::retirement-reason "g/buggy"))
      ;; unused and old (created 8 days ago, 0 uses → no :first-use exists).
      ;; The retirement clock for unused genes is :created, not :first-use.
      (set-entry "g/stale"
                 (list :uses 0 :errors 0 :reverts 0
                       :created (- (ourro.util:unix-time) (* 8 24 60 60))))
      (is-true (ourro.agent::retirement-reason "g/stale"))
      ;; healthy → keep
      (set-entry "g/healthy"
                 (list :uses 10 :errors 0 :reverts 0 :first-use (ourro.util:unix-time)))
      (is-false (ourro.agent::retirement-reason "g/healthy"))
      ;; frozen genes are never retired
      (set-entry "g/frozen"
                 (list :uses 3 :errors 0 :reverts 5 :frozen t
                       :first-use (ourro.util:unix-time)))
      (is-false (ourro.agent::retirement-reason "g/frozen")))))

(test manifest-remove-drops-entry
  ;; updated-manifest-source reads the loaded genome manifest and drops the
  ;; removed path, keeping every other gene.
  (ensure-seed-genome-loaded)
  (let* ((source (ourro.agent::updated-manifest-source
                  nil (list "genes/tools/search.gene")))
         (manifest (ourro.util:read-safe-from-string source))
         (genes (getf manifest :genes)))
    (is-false (member "genes/tools/search.gene" genes :test #'string=))
    (is-true (member "genes/tools/read-file.gene" genes :test #'string=))))
