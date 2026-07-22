(in-package #:ourro.tests)

(def-suite investigate-suite :in ourro)
(in-suite investigate-suite)



(test investigation-loops-tools-then-returns-the-diagnosis
  ;; First the model calls a tool, then it produces the diagnosis text.
  (let ((provider (ourro.llm:make-scripted-provider
                   (list (list :text ""
                               :tool-calls (list (list :name "read_file"
                                                       :args (list :path "x"))))
                         "diagnosis: the build broke on a missing dependency"))))
    (let ((text (ourro.agent::run-investigation provider "why did it fail?")))
      (is (search "diagnosis" text)))))

(test headless-investigation-retains-the-bounded-tool-transcript
  (let ((provider (ourro.llm:make-scripted-provider
                   (list (list :text ""
                               :tool-calls (list (list :name "read_file"
                                                       :args (list :path "x"))))
                         "diagnosis [evidence:e1]"))))
    (let ((result (ourro.reflex.investigation:run-investigation
                   provider "why? evidence:e1" :events '((:event-id "e1")))))
      (is (eq :completed (pget result :status)))
      (is (= 1 (length (pget result :tool-results))))
      (is-true (pget result :no-changes-made)))))

(test investigation-halts-at-the-step-cap
  ;; A model that only ever calls tools is stopped by the step cap, not run away.
  (let ((provider (ourro.llm:make-scripted-provider
                   (list (list :text ""
                               :tool-calls (list (list :name "read_file"
                                                       :args (list :path "x")))))
                   :loop-p t)))
    (let ((text (ourro.agent::run-investigation provider "loop?" :max-steps 3)))
      (is (search "step cap" text)))))

(test investigation-clamps-tools-to-read-only
  ;; The ceiling is bound read-only for the duration; it is restored after.
  (let ((provider (ourro.llm:make-scripted-provider (list "done"))))
    (let ((before ourro.kernel:*capability-ceiling*))
      (ourro.agent::run-investigation provider "noop")
      (is (eq before ourro.kernel:*capability-ceiling*)))))

(test investigation-refuses-non-read-only-tools
  ;; A background investigation must not run a subprocess/write/genome-mutating
  ;; tool even if the model calls one — the read-only guard refuses it (HIGH).
  (let ((ourro.tools:*tool-registry* (ourro.tools:copy-tool-registry))
        (ran nil))
    (ourro.tools:register-tool
     (make-instance 'ourro.tools:tool :name "danger_run" :description "d"
                    :capabilities '(:subprocess)
                    :function (lambda (a) (declare (ignore a)) (setf ran t) "ran")))
    ;; not even offered to the model
    (is-false (gethash "danger_run" (ourro.agent::read-only-tool-registry)))
    (let ((provider (ourro.llm:make-scripted-provider
                     (list (list :text ""
                                 :tool-calls (list (list :name "danger_run")))
                           "diagnosis done"))))
      (ourro.agent::run-investigation provider "try danger")
      ;; the guard refused execution — the dangerous tool never ran
      (is-false ran))))

