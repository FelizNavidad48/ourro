
(in-package #:ourro.tests)

(def-suite records-suite :in ourro)
(in-suite records-suite)

(defmacro with-records-scratch-home (&body body)
  "Run BODY with OURRO-HOME pointed at a fresh temp directory so record and
ledger files never touch the real home."
  (let ((dir (gensym)))
    `(let* ((,dir (uiop:ensure-directory-pathname
                   (merge-pathnames (format nil "ourro-rec-~A/"
                                            (ourro.util:make-id "t"))
                                    (uiop:temporary-directory))))
            (ourro.util::*ourro-home* ,dir))
       (unwind-protect (progn ,@body)
         (ignore-errors (uiop:delete-directory-tree
                         ,dir :validate t :if-does-not-exist :ignore))))))

(test candidate-to-record-captures-fields
  (let ((candidate (make-instance 'ourro.evolve:evolution-candidate
                                  :pattern (list :id "pat-1" :kind :repeated-command))))
    (setf (ourro.evolve:candidate-status candidate) :rejected
          (ourro.evolve:candidate-diagnostics candidate) "compile failed")
    (let ((record (ourro.evolve:candidate->record candidate)))
      (is (string= "pat-1" (getf record :id)))
      (is (eq :rejected (getf record :status)))
      (is (string= "compile failed" (getf record :diagnostics)))
      (is (integerp (getf record :unix))))))

(test record-persists-and-loads-latest-per-id
  (with-records-scratch-home
    (let ((candidate (make-instance 'ourro.evolve:evolution-candidate
                                    :pattern (list :id "pat-2" :kind :repeated-command))))
      ;; Two status changes for the same id: latest (:verified) should win.
      (setf (ourro.evolve:candidate-status candidate) :rejected)
      (ourro.evolve:record-candidate candidate)
      (setf (ourro.evolve:candidate-status candidate) :verified)
      (ourro.evolve:record-candidate candidate))
    (let ((records (ourro.evolve:load-candidate-records)))
      (is (= 1 (length records)))
      (is (eq :verified (getf (first records) :status))))))

(test record-hook-fires
  (with-records-scratch-home
    (let* ((seen '())
           (ourro.evolve:*candidate-record-hook*
             (lambda (record) (push record seen))))
      (let ((candidate (make-instance 'ourro.evolve:evolution-candidate
                                      :pattern (list :id "pat-3" :kind :repeated-command))))
        (setf (ourro.evolve:candidate-status candidate) :error)
        (ourro.evolve:record-candidate candidate))
      (is (= 1 (length seen)))
      (is (string= "pat-3" (getf (first seen) :id))))))

(test shelf-retry-reenqueues-recent-rejections
  (with-records-scratch-home
    (let ((ourro.evolve:*evolution-queue* '()))
      ;; A fresh rejected record → re-enqueued once with retry feedback.
      (ourro.util:append-sexp-line
       (ourro.evolve:candidate-records-path)
       (list :id "pat-fresh" :status :rejected
             :pattern (list :id "pat-fresh" :kind :repeated-command :tools '("x"))
             :diagnostics "walker rejected effect"
             :unix (ourro.util:unix-time)))
      ;; A stale rejected record (3 days old) → left alone.
      (ourro.util:append-sexp-line
       (ourro.evolve:candidate-records-path)
       (list :id "pat-stale" :status :rejected
             :pattern (list :id "pat-stale" :kind :repeated-command :tools '("y"))
             :diagnostics "old"
             :unix (- (ourro.util:unix-time) (* 3 24 60 60))))
      (let ((n (ourro.evolve:retry-shelved-candidates)))
        (is (= 1 n))
        (is (= 1 (ourro.evolve::queue-length)))
        (let ((queued (first ourro.evolve:*evolution-queue*)))
          (is (string= "pat-fresh" (getf queued :id)))
          (is (string= "walker rejected effect" (getf queued :retry-feedback))))))))

(test shelf-retry-runs-once
  (with-records-scratch-home
    (let ((ourro.evolve:*evolution-queue* '()))
      (ourro.util:append-sexp-line
       (ourro.evolve:candidate-records-path)
       (list :id "pat-once" :status :rejected
             :pattern (list :id "pat-once" :kind :repeated-command :tools '("z"))
             :diagnostics "boom" :unix (ourro.util:unix-time)))
      (is (= 1 (ourro.evolve:retry-shelved-candidates)))
      ;; The :retried marker was written back; a second boot re-enqueues nothing.
      (setf ourro.evolve:*evolution-queue* '())
      (is (= 0 (ourro.evolve:retry-shelved-candidates))))))

(test retry-feedback-appears-in-prompt
  (multiple-value-bind (system user)
      (ourro.evolve:assemble-evolution-prompt
       (list :id "pat-fb" :kind :repeated-command :tools '("read_file")
             :count 3 :evidence '() :retry-feedback "missing :post contract"))
    (declare (ignore system))
    (is (search "previous attempt" user))
    (is (search "missing :post contract" user))))
