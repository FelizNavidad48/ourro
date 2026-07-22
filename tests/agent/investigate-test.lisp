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

(test investigation-admits-read-only-observation-tools-and-confines-absolute-reads
  (let* ((workspace-a
           (uiop:ensure-directory-pathname
            (merge-pathnames (format nil "ourro-investigation-a-~A/" (make-id "w"))
                             (uiop:temporary-directory))))
         (workspace-b
           (uiop:ensure-directory-pathname
            (merge-pathnames (format nil "ourro-investigation-b-~A/" (make-id "w"))
                             (uiop:temporary-directory))))
         (secret (merge-pathnames "secret.txt" workspace-b))
         (ourro.tools:*tool-registry* (ourro.tools:make-tool-registry)))
    (ensure-directories-exist (merge-pathnames "sentinel" workspace-a))
    (ensure-directories-exist secret)
    (unwind-protect
         (progn
           (with-open-file (out secret :direction :output :if-exists :supersede
                                      :if-does-not-exist :create)
             (write-line "cross-workspace-secret" out))
           (ourro.tools:register-tool
            (make-instance 'ourro.tools:tool
                           :name "read_file" :description "bounded read"
                           :capabilities '(:filesystem-read)
                           :function
                           (lambda (args)
                             (ourro.kernel:cap/read-file
                              (gethash "path" args)))))
           (ourro.tools:register-tool
            (make-instance 'ourro.tools:tool
                           :name "job_status" :description "job observer"
                           :capabilities '(:observe)
                           :function (lambda (args)
                                       (declare (ignore args)) "should not run")))
           (let ((registry
                   (ourro.reflex.investigation:read-only-tool-registry)))
             (is-true (gethash "read_file" registry))
             ;; Capability-derived admission retains gene-grown observation
             ;; tools instead of silently reducing investigations to three
             ;; hard-coded built-ins.
             (is-true (gethash "job_status" registry)))
           (let* ((arguments
                    (let ((table (make-hash-table :test #'equal)))
                      (setf (gethash "path" table) (namestring secret))
                      table))
                  (provider
                    (ourro.llm:make-scripted-provider
                     (list (list :text ""
                                 :tool-calls
                                 (list (list :name "read_file"
                                             :args arguments)))
                           "read was refused [evidence:e1]")))
                  (result
                    (ourro.reflex.investigation:run-investigation
                     provider "inspect evidence:e1"
                     :events (list (list :event-id "e1"
                                         :workspace (namestring workspace-a)))
                     :workspace workspace-a))
                  (tool-result (first (pget result :tool-results))))
             (is-true (pget tool-result :error))
             (is (search "ERROR" (pget tool-result :result)))
             (is-false (search "cross-workspace-secret"
                               (pget tool-result :result)))))
      (ignore-errors (uiop:delete-directory-tree workspace-a
                                                  :validate (constantly t)))
      (ignore-errors (uiop:delete-directory-tree workspace-b
                                                  :validate (constantly t))))))


(test request-investigation-enqueues-and-drains-via-hook
  (with-clean-reflexes
    (let* ((seen nil)
           (ourro.automation:*investigation-hook*
             (lambda (prompt &key events title)
               (declare (ignore events title)) (setf seen prompt))))
      (is-true (ourro.automation:request-investigation "diagnose the failure"
                                                      :title "t"))
      (is (= 1 (ourro.automation:pending-investigation-count)))
      (ourro.automation:drain-investigations)
      (is (string= "diagnose the failure" seen))
      (is (zerop (ourro.automation:pending-investigation-count))))))

(test request-investigation-respects-the-queue-cap
  (with-clean-reflexes
    (let ((ourro.automation::*investigation-queue-cap* 2))
      (is-true (ourro.automation:request-investigation "a"))
      (is-true (ourro.automation:request-investigation "b"))
      ;; third is dropped (cap 2)
      (is-false (ourro.automation:request-investigation "c"))
      (is (= 2 (ourro.automation:pending-investigation-count))))))


(defun brief-agent ()
  (ourro.agent::make-agent :provider (ourro.llm:make-scripted-provider '())))

(test briefing-ring-numbers-and-find
  (let ((agent (brief-agent)))
    (let ((n1 (ourro.agent::add-briefing agent "t1" "text one"))
          (n2 (ourro.agent::add-briefing agent "t2" "text two")))
      (is (= 1 n1))
      (is (= 2 n2))
      (is (string= "text two" (pget (ourro.agent::find-briefing agent 2) :text)))
      (is (string= "t1" (pget (ourro.agent::find-briefing agent 1) :title)))
      (is (null (ourro.agent::find-briefing agent 99))))))

(test briefing-ring-caps-at-ten-but-numbers-stay-monotonic
  (let ((agent (brief-agent)))
    (dotimes (i 15) (ourro.agent::add-briefing agent (format nil "t~A" i) "x"))
    (is (= 10 (length (ourro.agent::agent-briefings agent))))
    (is (= 15 (ourro.agent::agent-briefing-count agent)))
    ;; oldest rolled off, newest kept
    (is (null (ourro.agent::find-briefing agent 1)))
    (is-true (ourro.agent::find-briefing agent 15))))

(test condense-briefing-truncates-long-text-only
  (let ((long (format nil "a~%b~%c~%d~%e~%f")))
    (is (search "…" (ourro.agent::condense-briefing long 3)))
    ;; short text passes through unchanged
    (is (string= "short" (ourro.agent::condense-briefing "short" 3)))))
