(in-package #:ourro.tests)

(def-suite jobs-suite :in ourro)
(in-suite jobs-suite)

(test job-workers-do-not-snapshot-replaceable-journal-collections
  (let ((bindings (let ((ourro.reflex.journal::*journal-path-override* nil))
                    (ourro.jobs::job-thread-bindings))))
    (dolist (symbol '(ourro.reflex.journal::*journal-records*
                      ourro.reflex.journal::*journal-by-id*
                      ourro.reflex.journal::*journal-by-workspace*
                      ourro.reflex.journal::*journal-health*))
      (is-false (assoc symbol bindings)))))


(defmacro with-jobs-home (&body body)
  (let ((home (gensym)))
    `(let* ((,home (uiop:ensure-directory-pathname
                    (merge-pathnames (format nil "ourro-jobs-~A/" (ourro.util:make-id "h"))
                                     (uiop:temporary-directory))))
            (ourro.util::*ourro-home* ,home))
       (ensure-directories-exist (merge-pathnames "state/" ,home))
       (ourro.jobs:reset-jobs)
       (unwind-protect (progn ,@body)
         (ignore-errors (ourro.jobs:kill-all-jobs))
         (ourro.jobs:reset-jobs)
         (ignore-errors
          (uiop:delete-directory-tree ,home :validate (constantly t)))))))

(defun wait-until (pred seconds)
  "Poll PRED until true or SECONDS elapse; T if it became true."
  (let ((deadline (+ (get-universal-time) seconds 1)))
    (loop
      (when (funcall pred) (return t))
      (when (> (get-universal-time) deadline) (return nil))
      (sleep 0.05))))

(defun job-done-p (id)
  (let ((j (ourro.jobs:job-record id)))
    (and j (not (eq (pget j :status) :running)))))

(test jobs-lifecycle-records-exit-code
  (with-jobs-home
    (let ((id (ourro.jobs:start-job "sleep 0.1; echo done")))
      (is (stringp id))
      (is (eq :running (pget (ourro.jobs:job-record id) :status)))
      (is (wait-until (lambda () (job-done-p id)) 5))
      (let ((j (ourro.jobs:job-record id)))
        (is (eq :exited (pget j :status)))
        (is (eql 0 (pget j :exit))))
      ;; stdout was captured to the log
      (is (search "done" (or (ourro.jobs:job-log-tail id) ""))))))

(test jobs-nonzero-exit-code-captured
  (with-jobs-home
    (let ((id (ourro.jobs:start-job "exit 3")))
      (is (wait-until (lambda () (job-done-p id)) 5))
      (is (eql 3 (pget (ourro.jobs:job-record id) :exit))))))

(test jobs-stderr-goes-to-the-log
  ;; A dev server's boot error prints to stderr — it must be captured, not lost.
  (with-jobs-home
    (let ((id (ourro.jobs:start-job "echo boom 1>&2; exit 1")))
      (is (wait-until (lambda () (job-done-p id)) 5))
      (is (search "boom" (or (ourro.jobs:job-log-tail id) ""))))))

(test jobs-status-tail-advances-cursor
  ;; job-status returns only the bytes since the caller last looked — the model
  ;; never re-reads what it has already seen.
  (with-jobs-home
    (let ((id (ourro.jobs:start-job "echo line1; echo line2")))
      (is (wait-until (lambda () (job-done-p id)) 5))
      (let ((first (pget (ourro.jobs:job-status id) :tail)))
        (is (search "line1" first))
        (is (search "line2" first)))
      ;; cursor advanced past EOF → nothing new
      (is (string= "" (pget (ourro.jobs:job-status id) :tail))))))

(test jobs-reattach-live-pid-stays-running
  ;; Re-attach from a synthetic payload: a job whose pid is still alive resumes
  ;; :running (a liveness poller replaces the vanished process-info).
  (with-jobs-home
    (let* ((proc (uiop:launch-program (list "sleep" "3")))
           (pid (uiop:process-info-pid proc)))
      (unwind-protect
           (progn
             (let ((identity (ourro.jobs::process-identity pid))
                   (pgid (ourro.jobs::process-group pid)))
               (ourro.jobs:restore-jobs
                (list (list :id "j7" :command "sleep 3" :pid pid
                            :identity identity :pgid pgid
                          :log "/tmp/nonexistent.log" :started 0
                            :status :running :exit nil))))
             (is (eq :running (pget (ourro.jobs:job-record "j7") :status))))
        (ignore-errors (uiop:terminate-process proc :urgent t))))))

(test jobs-reattach-dead-pid-marked-exited
  (with-jobs-home
    (ourro.jobs:restore-jobs
     (list (list :id "j4" :command "gone" :pid 999999
                 :log "/tmp/nonexistent.log" :started 0
                 :status :running :exit nil)))
    (let ((j (ourro.jobs:job-record "j4")))
      (is (eq :exited (pget j :status)))
      (is (eq :unknown-after-restart (pget j :exit))))))

(test jobs-reattach-rejects-recycled-pid-identity
  (with-jobs-home
    (let* ((pid (sb-posix:getpid))
           (hook-count 0)
           (ourro.jobs:*job-exit-hook*
             (lambda (id job) (declare (ignore id job)) (incf hook-count))))
      (ourro.jobs:restore-jobs
       (list (list :id "j8" :command "not-this-process" :pid pid
                   :identity "stale identity" :pgid pid
                   :log "/tmp/nonexistent.log" :started 0
                   :status :running :exit nil)))
      (is (eq :exited (pget (ourro.jobs:job-record "j8") :status)))
      (is (= 1 hook-count))
      ;; The exit transition is idempotent even if a waiter and poller race.
      (ourro.jobs::mark-exited "j8" :again)
      (is (= 1 hook-count)))))

