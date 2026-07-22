(in-package #:ourro.tests)

(def-suite reflex-model-suite :in ourro)
(in-suite reflex-model-suite)

(defun fixture-reflex-form (&key (version 1) (capabilities '(:observe)))
  `(define-reflex failed-job-briefing
     (:identity (:version ,version :workspace :current
                 :capabilities ,capabilities))
     (:trigger (:kind :job-exit :outcome :error))
     (:guards ())
     (:state (:version 1 :initial-step :notify))
     (:workflow ((:id :notify :activity :notify
                  :input (:text "job failed") :next :done)))
     (:policy (:approval :required :timeout 30))))

(test reflex-model-canonicalizes-and-derives-exact-authority
  (let* ((definition (ourro.reflex.model:definition-from-form
                      (fixture-reflex-form)))
         (first (ourro.reflex.model:canonical-reflex-ir definition))
         (second (ourro.reflex.model:canonical-reflex-ir definition)))
    (is (string= "failed-job-briefing"
                 (ourro.reflex.model:reflex-name definition)))
    (is (equal '(:observe)
               (ourro.reflex.model:derive-capabilities
                (ourro.reflex.model:reflex-workflow definition))))
    (is (equal first second))
    (is (string= (ourro.txn:canonical-hash first)
                 (ourro.txn:canonical-hash second)))))

(test reflex-model-rejects-authority-broadening-and-unknown-steps
  (signals error
    (ourro.reflex.model:definition-from-form
     (fixture-reflex-form :capabilities '(:observe :network))))
  (signals error
    (ourro.reflex.model:definition-from-form
     '(define-reflex bad
        (:identity (:version 1 :capabilities ()))
        (:trigger (:kind :probe))
        (:state (:version 1))
        (:workflow ((:id :one :activity :finish :next :missing)))))))

(test reflex-state-migration-round-trips
  (let ((ourro.reflex.model::*state-migrations* (make-hash-table :test #'equal)))
    (ourro.reflex.model:register-state-migration
     'fixture 1 2
     (lambda (state) (setf (getf state :added) 7) state)
     (lambda (state) (remf state :added) state))
    (let* ((before '(:step :one :count 2))
           (forward (ourro.reflex.model:migrate-reflex-state
                     'fixture before 1 2))
           (reverse (ourro.reflex.model:migrate-reflex-state
                     'fixture forward 2 1)))
      (is (= 7 (getf forward :added)))
      (is (equal before reverse)))))
