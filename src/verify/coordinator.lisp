
(defpackage #:ourro.verify.coordinator
  (:use #:cl)
  (:import-from #:ourro.util #:iso-time #:ourro-path #:pget)
  (:import-from #:ourro.genome #:gene-capabilities #:parse-gene-source)
  (:export #:verify-source #:verification-wal-path #:runtime-fingerprints
           #:*coordinator-version* #:proof-for-report
           #:encode-report-for-transport #:decode-report-from-transport
           #:authoritative-pass-report-p #:adopt-authoritative-report
           #:containment-status #:effectful-authority-p
           #:*containment-mode-override*))

(in-package #:ourro.verify.coordinator)

(defparameter *coordinator-version* 1)
(defvar *fingerprint-cache* nil)
(defparameter +maximum-fingerprint-cache-entries+ 64)
(defvar *containment-mode-override* :platform
  "Test seam. :PLATFORM uses the reviewed backend inventory; :EFFECTFUL and
:READ-ONLY force a mode for hermetic tests. Production never enables an
effectful mode through an environment variable.")

(defparameter +effectful-capabilities+
  '(:filesystem-write :network :subprocess :llm))

(defun effectful-authority-p (authority)
  (and (intersection authority +effectful-capabilities+) t))

(defun containment-status ()
  "Return the reviewed containment mode and its visible residual-risk reason.

The Linux namespace/seccomp/cgroup backend is not yet implemented in this
tree, so every real platform deliberately reports :READ-ONLY. This is a
release-safe refusal mode, not an optimistic claim that the Lisp child is an
OS sandbox."
  (case *containment-mode-override*
    (:effectful
     (list :mode :effectful :backend :test-override :self-test :passed))
    (:read-only
     (list :mode :read-only :backend :forced-read-only :self-test :not-applicable
           :reason "effectful verification disabled by policy"))
    (t
     (list :mode :read-only
           :backend (cond ((member :linux *features*) :linux-unavailable)
                          ((member :darwin *features*) :macos-read-only)
                          (t :unsupported-read-only))
           :self-test :unavailable
           :reason
           "no reviewed OS filesystem/network/resource containment backend; effectful candidates fail closed"))))

(defun verification-wal-path ()
  (ourro-path "state" "verification.wal"))

(defun source-file-fingerprint (root relatives)
  (let ((entries
          (loop for relative in relatives
                for path = (merge-pathnames relative root)
                collect (list relative
                              (if (probe-file path)
                                  (cached-file-fingerprint path)
                                  :unavailable)))))
    (ourro.txn:canonical-hash entries)))

(defun cached-file-fingerprint (pathname)
  (when (probe-file pathname)
    (let* ((true (truename pathname))
           (key (list (namestring true) (file-write-date true)
                      (with-open-file (in true :direction :input
                                               :element-type '(unsigned-byte 8))
                        (file-length in))))
           (hit (assoc key *fingerprint-cache* :test #'equal)))
      (or (cdr hit)
          (let ((hash (ourro.txn:sha256-file true)))
            (setf *fingerprint-cache*
                  (delete (namestring true) *fingerprint-cache*
                          :test #'string=
                          :key (lambda (entry) (first (car entry)))))
            (push (cons key hash) *fingerprint-cache*)
            (when (> (length *fingerprint-cache*)
                     +maximum-fingerprint-cache-entries+)
              (setf *fingerprint-cache*
                    (subseq *fingerprint-cache* 0
                            +maximum-fingerprint-cache-entries+)))
            hash)))))

(defun runtime-fingerprints ()
  "Fingerprint the executable semantics relevant to a verification verdict."
  (let* ((root (ignore-errors (asdf:system-source-directory "ourro")))
         (base (ourro-path "base.core")))
    (list :coordinator-version *coordinator-version*
          :verifier-version 1
          :lisp-implementation (lisp-implementation-type)
          :lisp-version (lisp-implementation-version)
          :machine (machine-type)
          :compiler-policy '((safety 1) (debug 1) (speed 1) (space 1))
          :kernel-hash
          (if root
              (source-file-fingerprint
               root '("src/kernel/capabilities.lisp"
                      "src/kernel/safe-read.lisp"
                      "src/kernel/walker.lisp"
                      "src/kernel/transaction.lisp"
                      "src/verify/verifier.lisp"
                      "src/verify/coordinator.lisp"))
              :unavailable)
          :base-core-hash (or (cached-file-fingerprint base) :unavailable))))

(defun verification-transition (transaction-id status &rest fields)
  (ourro.txn:append-wal-record
   (verification-wal-path)
   (list* :schema-version 1
          :record-kind :verification-lifecycle
          :transaction-id transaction-id
          :status status
          :time (iso-time)
          fields)))

(defun proof-for-report (report)
  (pget report :verification-artifact))

(defun encode-report-for-transport (report)
  "Encode REPORT as a bounded child-verifier envelope.

The full coordinator report intentionally repeats proof material in convenient
summary fields.  Nesting that report inside the child verdict can therefore
push a legitimate, deeply nested reflex AST over the canonical codec's depth
limit.  The immutable verification artifact is the sole authority needed by
the parent, so transport it as its own canonical document and keep the outer
envelope shallow."
  (let* ((artifact (proof-for-report report))
         (transaction-id (pget report :transaction-id))
         (proof-hash (pget report :proof-hash)))
    (unless (and (ourro.txn:verification-artifact-valid-p artifact)
                 (stringp transaction-id)
                 (stringp proof-hash)
                 (equal transaction-id (pget artifact :transaction-id))
                 (equal proof-hash (pget artifact :proof-hash)))
      (error "cannot transport a non-authoritative verification report"))
    (ourro.txn:canonical-encode
     (list :schema-version 1
           :record-kind :verification-report-envelope
           :transaction-id transaction-id
           :proof-hash proof-hash
           :artifact (ourro.txn:canonical-encode artifact)))))

(defun decode-report-from-transport (encoded)
  "Decode a child-verifier envelope and restore the ordinary report shape.

Both canonical documents retain the codec's independent depth and item limits.
The envelope identifiers must agree with the self-authenticating artifact;
AUTHORITATIVE-PASS-REPORT-P subsequently binds that artifact to the exact
candidate source before adoption."
  (unless (stringp encoded)
    (error "verification report envelope is not a string"))
  (when (> (length encoded) ourro.txn:*max-wal-frame-bytes*)
    (error "verification report envelope exceeds the transport size limit"))
  (let* ((envelope (ourro.txn:canonical-decode encoded))
         (artifact-encoded (and (listp envelope)
                                (pget envelope :artifact))))
    (unless (and (= (pget envelope :schema-version 0) 1)
                 (eq (pget envelope :record-kind)
                     :verification-report-envelope)
                 (stringp (pget envelope :transaction-id))
                 (stringp (pget envelope :proof-hash))
                 (stringp artifact-encoded)
                 (<= (length artifact-encoded)
                     ourro.txn:*max-wal-frame-bytes*))
      (error "invalid verification report envelope"))
    (let* ((artifact (ourro.txn:canonical-decode artifact-encoded))
           (extra (pget artifact :extra)))
      (unless (and (ourro.txn:verification-artifact-valid-p artifact)
                   (equal (pget envelope :transaction-id)
                          (pget artifact :transaction-id))
                   (equal (pget envelope :proof-hash)
                          (pget artifact :proof-hash)))
        (error "verification report envelope does not match its artifact"))
      ;; Rehydrate the report fields used by candidate records, the UI, reflex
      ;; inspection, and proof adoption.  They are derived from the artifact,
      ;; never trusted as duplicate fields in the outer envelope.
      (list :stages (pget artifact :stages)
            :test-report (pget artifact :test-report)
            :containment (pget extra :containment)
            :transaction-id (pget artifact :transaction-id)
            :verification-artifact artifact
            :proof-hash (pget artifact :proof-hash)
            :reflex-proofs (pget extra :reflex-proofs)
            :legacy-automation-semantics
            (pget extra :legacy-automation-semantics)))))

(defun authoritative-pass-report-p (report source)
  "True only when REPORT carries a valid proof for this exact SOURCE."
  (let ((proof (proof-for-report report)))
    (and proof
         (ourro.txn:verification-artifact-valid-p proof)
         (stringp (pget report :transaction-id))
         (string= (pget report :transaction-id)
                  (pget proof :transaction-id))
         (string= (pget proof :source-hash) (ourro.txn:sha256-string source))
         (string= (pget report :proof-hash) (pget proof :proof-hash)))))

(defun adopt-authoritative-report (report source)
  "Adopt a child verifier's proof into the live OURRO_HOME.

Out-of-process verification deliberately runs with a throwaway HOME, so its
artifact file disappears with the sandbox.  The parent validates the embedded
self-hashing artifact against SOURCE, persists it immutably in the live home,
and records one :VERIFIED-EXTERNAL transition before the candidate may be
hot-loaded or sent to the supervisor.  Re-adoption is idempotent."
  (unless (authoritative-pass-report-p report source)
    (error "cannot adopt a non-authoritative verification report"))
  (let* ((artifact (proof-for-report report))
         (transaction-id (pget report :transaction-id))
         (proof-hash (pget report :proof-hash))
         (wal (verification-wal-path)))
    (ourro.txn:persist-verification-artifact artifact)
    (multiple-value-bind (records health) (ourro.txn:recover-wal wal)
      (declare (ignore health))
      (unless (find-if
               (lambda (record)
                 (and (equal transaction-id (pget record :transaction-id))
                      (eq :verified-external (pget record :status))
                      (equal proof-hash (pget record :proof-hash))))
               records)
        (verification-transition
         transaction-id :verified-external
         :proof-hash proof-hash
         :source-hash (pget artifact :source-hash)
         :authority (pget artifact :authority))))
    report))

(defun verify-source (source-text &key transaction-id (persist t))
  "Run SOURCE-TEXT through the full coordinated acceptance path.

Returns (values GENE REPORT). REPORT includes :TRANSACTION-ID,
:VERIFICATION-ARTIFACT, and :PROOF-HASH. When PERSIST is true, the lifecycle is
WAL-recorded and the proof is persisted immutably before success is returned."
  (let ((transaction-id (or transaction-id
                            (ourro.txn:make-transaction-id "verify")))
        (containment (containment-status)))
    (when persist
      (verification-transition transaction-id :prepared
                               :source-hash (ourro.txn:sha256-string source-text)))
    (handler-case
        (let* ((parsed
                 (handler-case (parse-gene-source source-text)
                   (ourro.kernel:verification-failure (failure)
                     (error failure))
                   (error (condition)
                     (error 'ourro.kernel:verification-failure
                            :stage :read
                            :diagnostics (princ-to-string condition)))))
               (authority (gene-capabilities parsed)))
          ;; This check precedes compilation, loading, and test execution. A
          ;; host without the reviewed backend may still verify read-only code
          ;; while reporting that reduced threat model in the proof.
          (when (and (effectful-authority-p authority)
                     (not (eq :effectful (pget containment :mode))))
            (error 'ourro.kernel:verification-failure
                   :stage :containment
                   :diagnostics (pget containment :reason)))
          (multiple-value-bind (gene base-report)
              (ourro.verify:verify-gene-text source-text)
            (let* ((base-verdict-hash
                     (ourro.txn:canonical-hash
                      (list :source-hash (ourro.txn:sha256-string source-text)
                            :stages (pget base-report :stages)
                            :test-report (pget base-report :test-report))))
                   (reflex-versions
                     (handler-case
                         (ourro.reflex.compiler:compile-gene-reflexes
                          gene :base-proof-hash base-verdict-hash)
                       (error (condition)
                         (error 'ourro.kernel:verification-failure
                                :stage :reflex-compile
                                :diagnostics (princ-to-string condition)))))
                   (reflex-proofs
                     (mapcar #'ourro.reflex.model:version-proof reflex-versions))
                   (legacy-semantics
                     (ourro.reflex.compiler:legacy-automation-semantics gene))
                   (stages
                     (append (copy-tree (pget base-report :stages))
                             (when reflex-versions
                               (list (list :reflex-lowering :ok
                                           :count (length reflex-versions)
                                           :proof-hashes
                                           (mapcar (lambda (proof)
                                                     (pget proof :proof-hash))
                                                   reflex-proofs))))
                            (when legacy-semantics
                              (list (list :legacy-automation-classification :ok
                                          :semantics legacy-semantics)))
                             (list (list :containment :ok
                                         :mode (pget containment :mode)
                                         :backend (pget containment :backend)))))
                   (base-report (ourro.util:plist-put
                                 (ourro.util:plist-put base-report :stages stages)
                                 :containment containment))
                   (artifact
                   (ourro.txn:make-verification-artifact
                    :transaction-id transaction-id
                    :source source-text
                    :authority authority
                    :fingerprints (runtime-fingerprints)
                    :stages stages
                    :test-report (pget base-report :test-report)
                    :kind (if reflex-versions :gene-with-reflexes :gene)
                    :extra (list :containment containment
                                 :base-verdict-hash base-verdict-hash
                                 :reflex-proofs reflex-proofs
                                 :legacy-automation-semantics legacy-semantics)))
                 (proof-hash (pget artifact :proof-hash))
                 (report (append base-report
                                 (list :transaction-id transaction-id
                                       :verification-artifact artifact
                                       :proof-hash proof-hash
                                       :reflex-proofs reflex-proofs
                                       :legacy-automation-semantics
                                       legacy-semantics))))
              (when persist
                (ourro.txn:persist-verification-artifact artifact)
                (verification-transition transaction-id :verified
                                         :proof-hash proof-hash
                                         :source-hash (pget artifact :source-hash)
                                         :authority authority
                                         :stages stages
                                         :containment containment))
              (values gene report))))
      (ourro.kernel:verification-failure (failure)
        (when persist
          (verification-transition
           transaction-id :verification-failed
           :source-hash (ourro.txn:sha256-string source-text)
           :stage (ourro.kernel:verification-failure-stage failure)
           :diagnostics
           (ourro.kernel:verification-failure-diagnostics failure)))
        (error failure)))))
