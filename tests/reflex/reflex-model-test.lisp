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

