
(defpackage #:ourro.reflex.proof
  (:use #:cl #:ourro.util)
  (:export #:make-reflex-proof
           #:reflex-proof-valid-p
           #:reflex-proof-hash))

(in-package #:ourro.reflex.proof)

(defun without-proof-hash (proof)
  (loop for (key value) on proof by #'cddr
        unless (eq key :proof-hash) append (list key value)))

(defun reflex-proof-hash (proof)
  (ourro.txn:canonical-hash (without-proof-hash proof)))

(defun make-reflex-proof (&key definition ir generated-lisp base-proof-hash
                               fingerprints diagnostics replay-cases)
  (let* ((core
           (list :schema-version 1
                 :record-kind :reflex-proof
                 :logical-name (ourro.reflex.model:reflex-name definition)
                 :source-hash
                 ;; Candidate scratch packages are deleted before post-verifier
                 ;; lowering, leaving lexical source symbols uninterned. Hash the
                 ;; retained readable source form; canonical identity lives in IR.
                 (ourro.txn:sha256-string
                  (with-standard-io-syntax
                    (let ((*print-pretty* nil) (*print-circle* nil))
                      (prin1-to-string
                       (ourro.reflex.model:reflex-source-form definition)))))
                 :canonical-ir ir
                 :canonical-ir-hash (ourro.txn:canonical-hash ir)
                 :generated-lisp generated-lisp
                 :generated-lisp-hash (ourro.txn:canonical-hash generated-lisp)
                 :logical-compiled-entry-id
                 (format nil "reflex/~A/~A"
                         (ourro.reflex.model:reflex-name definition)
                         (subseq (ourro.txn:canonical-hash
                                  (list ir fingerprints)) 0 24))
                 :requested-authority
                 (ourro.reflex.model:reflex-capabilities definition)
                 :base-proof-hash base-proof-hash
                 :fingerprints fingerprints
                 :diagnostics diagnostics
                 :replay-cases replay-cases)))
    (append core (list :proof-hash (ourro.txn:canonical-hash core)))))

(defun reflex-proof-valid-p (proof)
  (and (listp proof)
       (eq :reflex-proof (pget proof :record-kind))
       (stringp (pget proof :proof-hash))
       (string= (pget proof :proof-hash) (reflex-proof-hash proof))
       (string= (pget proof :canonical-ir-hash)
                (ourro.txn:canonical-hash (pget proof :canonical-ir)))
       (string= (pget proof :generated-lisp-hash)
                (ourro.txn:canonical-hash (pget proof :generated-lisp)))))
