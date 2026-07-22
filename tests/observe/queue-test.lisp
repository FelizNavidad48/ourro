
(in-package #:ourro.tests)

(def-suite queue-suite :in ourro)
(in-suite queue-suite)

(defun lint-observe (forms &optional capabilities)
  (ourro.kernel:lint-gene-body forms :capabilities capabilities))


(test observe-capability-required
  ;; recent-events / add-turn-hook need :observe.
  (is-true (lint-observe '((defun m () (recent-events :limit 5))) '()))
  (is (null (lint-observe '((defun m () (recent-events :limit 5))) '(:observe))))
  (is-true (lint-observe '((defun m () (add-turn-hook "x" nil))) '()))
  (is (null (lint-observe '((defun m () (add-turn-hook "x" nil))) '(:observe))))
  ;; :observe is a real, declarable capability now.
  (is-true (ourro.kernel:capability-p :observe)))


(test queue-symbols-are-shared
  (is (eq (find-symbol "ENQUEUE-PATTERN" :ourro.evolve)
          (find-symbol "ENQUEUE-PATTERN" :ourro.observe)))
  (is (eq (find-symbol "QUEUE-LENGTH" :ourro.evolve)
          (find-symbol "QUEUE-LENGTH" :ourro.observe))))

(test enqueue-dedupes-by-id
  (let ((ourro.observe:*evolution-queue* '()))
    (ourro.observe:enqueue-pattern (list :id "a" :kind :x))
    (ourro.observe:enqueue-pattern (list :id "a" :kind :x))
    (ourro.observe:enqueue-pattern (list :id "b" :kind :x))
    (is (= 2 (ourro.observe:queue-length)))))


(test turn-hook-enqueues-at-turn-boundary
  (let ((ourro.observe:*evolution-queue* '())
        (ourro.observe:*turn-hooks* '()))
    (ourro.observe:add-turn-hook
     "mini-miner"
     (lambda () (ourro.observe:enqueue-pattern (list :id "mined" :kind :test))))
    (is (= 1 (length ourro.observe:*turn-hooks*)))
    (ourro.observe:run-turn-hooks)
    (is (= 1 (ourro.observe:queue-length)))
    (is (string= "mined" (getf (first ourro.observe:*evolution-queue*) :id)))))

(test add-turn-hook-replaces-same-name
  (let ((ourro.observe:*turn-hooks* '()))
    (ourro.observe:add-turn-hook "h" (lambda () 1))
    (ourro.observe:add-turn-hook "h" (lambda () 2))
    (is (= 1 (length ourro.observe:*turn-hooks*)))))

(test erroring-turn-hook-removed-and-reported
  (let* ((ourro.observe:*turn-hooks* '())
         (fired nil)
         (ourro.observe:*turn-hook-failure-hook*
           (lambda (name condition) (declare (ignore condition)) (setf fired name))))
    (ourro.observe:add-turn-hook "bad" (lambda () (error "boom")))
    (ourro.observe:run-turn-hooks)
    (is (string= "bad" fired))
    (is (null ourro.observe:*turn-hooks*))))


(defparameter +observe-gene+
  "<gene>
(defgene observe/status
    (:generation 2 :parent nil :capabilities (:observe)
     :provenance (:pattern \"pat-observe\" :model \"scripted\"))
  (:doc \"Report how many events are in the recent window — an evolved observer.\")
  (:code
   (deftool observe-status ()
     (:doc \"Return the count of recent events.\")
     (:contract (:post ((stringp result))))
     (format nil \"~A recent events\" (length (recent-events :limit 100)))))
  (:tests
   (test observe-status/returns-string
     (let ((h (make-hash-table :test (quote equal))))
       (is (stringp (run-tool (find-tool \"observe_status\") h)))))))
</gene>")

(test observe-gene-passes-gauntlet
  (ensure-seed-genome-loaded)
  (let ((gene (ourro.verify:verify-gene-text
               (ourro.evolve:extract-gene-block +observe-gene+))))
    (is (string= "observe/status" (ourro.genome:gene-name gene)))
    ;; :observe is honored as a declared capability.
    (is (member :observe (ourro.genome:gene-capabilities gene)))))
