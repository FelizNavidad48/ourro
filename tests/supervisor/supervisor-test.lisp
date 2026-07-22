(in-package #:ourro.tests)

(def-suite supervisor-suite :in ourro)
(in-suite supervisor-suite)


(defmacro with-scratch-home ((&key) &body body)
  (let ((home (gensym)))
    `(let* ((,home (merge-pathnames
                    (format nil "ourro-sup-test-~A/" (ourro.util:make-id "h"))
                    (uiop:temporary-directory)))
            (ourro.util::*ourro-home* (uiop:ensure-directory-pathname ,home)))
       (ensure-directories-exist ,home)
       (unwind-protect (progn ,@body)
         (ignore-errors
          (uiop:delete-directory-tree (uiop:ensure-directory-pathname ,home)
                                      :validate (constantly t)))))))

(test ledger-write-read-roundtrip
  (with-scratch-home ()
    (ourro.supervisor:write-ledger
     (list :current "gen-0001"
           :generations (list (list :id "gen-0001" :number 1 :status :good))))
    (let ((ledger (ourro.supervisor:read-ledger)))
      (is (string= "gen-0001" (ourro.supervisor:ledger-current ledger)))
      (is (= 1 (length (ourro.supervisor:ledger-generations ledger)))))))

(test build-generation-with-stub
  (with-scratch-home ()
    ;; Seed a genome repo + config manually.
    (let ((genome (ourro.util:ourro-path "genome/")))
      (ensure-directories-exist genome)
      (ourro.util:write-sexp-file (merge-pathnames "manifest.sexp" genome)
                                 (list :generation 1 :genes '()))
      (ourro.util:write-sexp-file (ourro.util:ourro-path "config.sexp")
                                 (list :source-dir (namestring (uiop:getcwd))
                                       :sbcl "sbcl"))
      (ourro.supervisor::git "init")
      (ourro.supervisor::git "config" "user.email" "t@t")
      (ourro.supervisor::git "config" "user.name" "t")
      (ourro.supervisor::git-commit-all "gen-0001")
      (ourro.supervisor:write-ledger
       (list :current "gen-0001"
             :generations (list (list :id "gen-0001" :number 1 :parent nil
                                      :status :good :image "images/gen-0001"))))
      ;; Stub the image build so no SBCL child runs.
      (let ((ourro.supervisor:*build-image-hook*
              (lambda (genome-dir output)
                (declare (ignore genome-dir))
                (ensure-directories-exist output)
                (with-open-file (out output :direction :output
                                            :if-exists :supersede)
                  (write-string "stub" out))
                output)))
        (let ((record (ourro.supervisor:build-generation
                       (list (list :path "genes/x.gene" :content "; new gene"))
                       :message "add x")))
          (is (string= "gen-0002" (getf record :id)))
          (is (eq :good (getf record :status)))
          (is (probe-file (merge-pathnames "genes/x.gene" genome))))))))

(test transactional-build-is-proof-gated-durable-and-idempotent
  (with-scratch-home ()
    (let* ((genome (ourro.util:ourro-path "genome/"))
           (source "; transaction-authorized gene")
           (transaction-id "verify-install-1")
           (changes (list (list :path "genes/txn.gene" :content source))))
      (ensure-directories-exist genome)
      (ourro.util:write-sexp-file (merge-pathnames "manifest.sexp" genome)
                                 (list :generation 1 :genes '()))
      (ourro.util:write-sexp-file (ourro.util:ourro-path "config.sexp")
                                 (list :source-dir (namestring (uiop:getcwd))
                                       :sbcl "sbcl"))
      (ourro.supervisor::git "init")
      (ourro.supervisor::git "config" "user.email" "t@t")
      (ourro.supervisor::git "config" "user.name" "t")
      (ourro.supervisor::git-commit-all "gen-0001")
      (ourro.supervisor:write-ledger
       (list :current "gen-0001"
             :generations (list (list :id "gen-0001" :number 1
                                      :status :good
                                      :image "images/gen-0001"))))
      (let* ((artifact
               (ourro.txn:make-verification-artifact
                :transaction-id transaction-id :source source :authority '()
                :fingerprints '(:test t) :stages '((:test :ok))))
             (proof-hash (getf artifact :proof-hash))
             (builds 0)
             (ourro.supervisor:*build-image-hook*
               (lambda (genome-dir output)
                 (declare (ignore genome-dir))
                 (incf builds)
                 (ensure-directories-exist output)
                 (with-open-file (out output :direction :output
                                             :if-exists :supersede)
                   (write-string "stub" out))
                 output)))
        (ourro.txn:persist-verification-artifact artifact)
        (let ((first (ourro.supervisor:build-generation
                      changes :message "install txn"
                      :transaction-id transaction-id :proof-hash proof-hash))
              (second (ourro.supervisor:build-generation
                       changes :message "install txn"
                       :transaction-id transaction-id :proof-hash proof-hash)))
          (is (string= "gen-0002" (getf first :id)))
          (is (equal first second))
          (is (eq :activation-pending (getf first :status)))
          (is (= 1 builds))
          (is (= 2 (length (ourro.supervisor:ledger-generations
                            (ourro.supervisor:read-ledger)))))
          (let ((promoted
                  (ourro.supervisor:promote-generation
                   "gen-0002" transaction-id proof-hash)))
            (is (eq :good (getf promoted :status))))
          (multiple-value-bind (records health)
              (ourro.txn:read-wal (ourro.supervisor:install-wal-path))
            (is (eq :ok health))
            (is (equal '(:prepared :genome-committed :image-built
                         :ledger-registered :probation-passed)
                       (mapcar (lambda (record) (getf record :status))
                               records)))))))))

(test transactional-build-rejects-unproven-content-before-mutation
  (with-scratch-home ()
    (let ((genome (ourro.util:ourro-path "genome/")))
      (ensure-directories-exist genome)
      (ourro.util:write-sexp-file (merge-pathnames "manifest.sexp" genome)
                                 (list :generation 1 :genes '()))
      (ourro.util:write-sexp-file (ourro.util:ourro-path "config.sexp")
                                 (list :source-dir (namestring (uiop:getcwd))
                                       :sbcl "sbcl"))
      (ourro.supervisor::git "init")
      (ourro.supervisor::git "config" "user.email" "t@t")
      (ourro.supervisor::git "config" "user.name" "t")
      (ourro.supervisor::git-commit-all "gen-0001")
      (let* ((artifact
               (ourro.txn:make-verification-artifact
                :transaction-id "verify-install-2" :source "authorized"
                :authority '() :fingerprints '(:test t)
                :stages '((:test :ok))))
             (proof-hash (getf artifact :proof-hash)))
        (ourro.txn:persist-verification-artifact artifact)
        (signals ourro.kernel:protocol-error
          (ourro.supervisor:build-generation
           (list (list :path "genes/x.gene" :content "different"))
           :transaction-id "verify-install-2" :proof-hash proof-hash))
        (is-false (probe-file (merge-pathnames "genes/x.gene" genome)))
        (is-false (probe-file (ourro.supervisor:install-wal-path)))))))

(test transactional-build-rejects-extra-unproved-change-before-mutation
  (with-scratch-home ()
    (let ((genome (ourro.util:ourro-path "genome/")))
      (ensure-directories-exist genome)
      (ourro.util:write-sexp-file (merge-pathnames "manifest.sexp" genome)
                                 (list :generation 1 :genes '()))
      (ourro.util:write-sexp-file (ourro.util:ourro-path "config.sexp")
                                 (list :source-dir (namestring (uiop:getcwd))
                                       :sbcl "sbcl"))
      (ourro.supervisor::git "init")
      (ourro.supervisor::git "config" "user.email" "t@t")
      (ourro.supervisor::git "config" "user.name" "t")
      (ourro.supervisor::git-commit-all "gen-0001")
      (let* ((source "; authorized")
             (transaction-id "verify-install-extra")
             (artifact
               (ourro.txn:make-verification-artifact
                :transaction-id transaction-id :source source :authority '()
                :fingerprints '(:test t) :stages '((:test :ok))))
             (proof-hash (getf artifact :proof-hash)))
        (ourro.txn:persist-verification-artifact artifact)
        (signals ourro.kernel:protocol-error
          (ourro.supervisor:build-generation
           (list (list :path "genes/x.gene" :content source)
                 (list :path "genes/backdoor.gene" :content "; unproved"))
           :transaction-id transaction-id :proof-hash proof-hash))
        (is-false (probe-file (merge-pathnames "genes/x.gene" genome)))
        (is-false (probe-file (merge-pathnames "genes/backdoor.gene" genome)))
        (is-false (probe-file (ourro.supervisor:install-wal-path)))))))

(test quarantine-rolls-back-to-parent
  (with-scratch-home ()
    (ourro.supervisor:write-ledger
     (list :current "gen-0002"
           :generations
           (list (list :id "gen-0001" :number 1 :parent nil :status :good)
                 (list :id "gen-0002" :number 2 :parent "gen-0001" :status :good))))
    (let ((good (ourro.supervisor:quarantine-generation
                 "gen-0002" (list :exit-code 1))))
      (is (string= "gen-0001" (getf good :id)))
      (let ((ledger (ourro.supervisor:read-ledger)))
        (is (string= "gen-0001" (ourro.supervisor:ledger-current ledger)))
        (is (eq :quarantined
                (getf (ourro.supervisor:generation-record ledger "gen-0002")
                      :status)))))))

(test latest-good-skips-quarantined
  (with-scratch-home ()
    (ourro.supervisor:write-ledger
     (list :current "gen-0003"
           :generations
           (list (list :id "gen-0001" :number 1 :status :good)
                 (list :id "gen-0002" :number 2 :status :good)
                 (list :id "gen-0003" :number 3 :status :quarantined))))
    (let ((good (ourro.supervisor:latest-good-generation)))
      (is (string= "gen-0002" (getf good :id))))))

(test init-heals-a-home-whose-only-generation-is-quarantined
  ;; A home whose sole (seed) generation was quarantined has no bootable
  ;; generation; a plain `ourro init` must restore it to :good instead of
  ;; leaving the home bricked with `no good generation to boot`. :commit nil
  ;; makes the current record the genome tip without a git repo.
  (with-scratch-home ()
    (let ((image (merge-pathnames "images/gen-0001" (ourro.util:ourro-home))))
      (ensure-directories-exist image)
      (with-open-file (o image :direction :output :if-exists :supersede)
        (write-string "stub-image" o))
      (ourro.supervisor:write-ledger
       (list :current "gen-0001"
             :generations
             (list (list :id "gen-0001" :number 1 :parent nil :commit nil
                         :status :quarantined :image "images/gen-0001"))))
      (is (null (ourro.supervisor:latest-good-generation)))
      (let* ((built nil)
            (ourro.supervisor:*build-image-hook*
              (lambda (g out) (declare (ignore g out)) (setf built t))))
        (ourro.supervisor::ensure-bootable-generation nil)
        ;; image already present → no rebuild, just the status flip
        (is-false built))
      (let ((good (ourro.supervisor:latest-good-generation)))
        (is (string= "gen-0001" (getf good :id)))
        (is (eq :good (getf good :status)))))))

(test init-rebuilds-a-missing-image-when-healing-bricked-home
  ;; Same recovery, but the quarantined tip's image is gone → it must rebuild
  ;; (via the hook) before marking the generation good.
  (with-scratch-home ()
    (ourro.supervisor:write-ledger
     (list :current "gen-0001"
           :generations
           (list (list :id "gen-0001" :number 1 :parent nil :commit nil
                       :status :quarantined :image "images/gen-0001"))))
    (let* ((built nil)
          (ourro.supervisor:*build-image-hook*
            (lambda (g out)
              (declare (ignore g))
              (setf built t)
              (ensure-directories-exist out)
              (with-open-file (o out :direction :output :if-exists :supersede)
                (write-string "rebuilt" o))
              out)))
      (ourro.supervisor::ensure-bootable-generation nil)
      (is-true built))
    (is (eq :good (getf (ourro.supervisor:latest-good-generation) :status)))))

(test init-leaves-a-healthy-home-untouched
  ;; When a :good generation already exists, healing must be a no-op — it must
  ;; not resurrect a deliberately-quarantined newer generation.
  (with-scratch-home ()
    (ourro.supervisor:write-ledger
     (list :current "gen-0002"
           :generations
           (list (list :id "gen-0001" :number 1 :parent nil :commit nil
                       :status :good :image "images/gen-0001")
                 (list :id "gen-0002" :number 2 :parent "gen-0001" :commit nil
                       :status :quarantined :image "images/gen-0002"))))
    (let* ((built nil)
          (ourro.supervisor:*build-image-hook*
            (lambda (g out) (declare (ignore g out)) (setf built t))))
      (ourro.supervisor::ensure-bootable-generation nil)
      (is-false built))
    (let ((ledger (ourro.supervisor:read-ledger)))
      (is (eq :quarantined
              (getf (ourro.supervisor:generation-record ledger "gen-0002")
                    :status))))))


(test crash-resume-plan-decisions
  ;; No prior checkpoint boot + one present → resume it.
  (is (eq :resume-checkpoint (ourro.supervisor::crash-resume-plan nil t)))
  ;; Nothing to resume → cold boot.
  (is (eq :cold (ourro.supervisor::crash-resume-plan nil nil)))
  ;; The crashed boot WAS a checkpoint resume → poison, don't loop.
  (is (eq :poison (ourro.supervisor::crash-resume-plan t t)))
  (is (eq :poison (ourro.supervisor::crash-resume-plan t nil))))

(test checkpoint-superseded-clears-poison-latch
  ;; M4-1 review #1: the poison latch must not stay set for the life of a
  ;; recovered agent. Once the agent reports :checkpoint-superseded (a turn
  ;; proved the resumed state healthy and wrote a fresh checkpoint), the crash
  ;; decision flips from :poison to :resume-checkpoint — a later unrelated
  ;; crash resumes the fresh session instead of discarding it.
  (let ((sup (make-instance 'ourro.supervisor::supervision)))
    (setf (ourro.supervisor::booted-from-checkpoint sup) t)
    (is (eq :poison (ourro.supervisor::crash-resume-plan
                     (ourro.supervisor::booted-from-checkpoint sup) t)))
    (ourro.supervisor::handle-agent-message sup '(:checkpoint-superseded) nil)
    (is (null (ourro.supervisor::booted-from-checkpoint sup)))
    (is (eq :resume-checkpoint
            (ourro.supervisor::crash-resume-plan
             (ourro.supervisor::booted-from-checkpoint sup) t)))))


(defun touch-image (rel)
  (let ((path (merge-pathnames rel (ourro.util:ourro-home))))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output :if-exists :supersede
                              :if-does-not-exist :create)
      (write-string "img" out))
    path))

(test prune-images-keeps-current-and-newest-good
  (with-scratch-home ()
    (dotimes (i 6) (touch-image (format nil "images/gen-000~A" (1+ i))))
    (ourro.supervisor:write-ledger
     (list :current "gen-0006"
           :generations
           (loop for i from 1 to 6
                 collect (list :id (format nil "gen-000~A" i) :number i
                               :status :good
                               :image (format nil "images/gen-000~A" i)))))
    (let ((pruned (ourro.supervisor::prune-images)))
      ;; Keep current(6) + 3 newest good(6,5,4) → prune 1,2,3.
      (is (= 3 (length pruned)))
      (is-true (probe-file (merge-pathnames "images/gen-0006"
                                            (ourro.util:ourro-home))))
      (is-true (probe-file (merge-pathnames "images/gen-0004"
                                            (ourro.util:ourro-home))))
      (is (null (probe-file (merge-pathnames "images/gen-0001"
                                             (ourro.util:ourro-home)))))
      (is (null (probe-file (merge-pathnames "images/gen-0003"
                                             (ourro.util:ourro-home))))))))

(test prune-images-keeps-quarantine-parent
  (with-scratch-home ()
    (dotimes (i 3) (touch-image (format nil "images/gen-000~A" (1+ i))))
    ;; gen-0003 quarantined; its parent gen-0001 must survive even though it is
    ;; not among the newest good, as a rollback/forensic anchor.
    (ourro.supervisor:write-ledger
     (list :current "gen-0002"
           :generations
           (list (list :id "gen-0001" :number 1 :status :good
                       :image "images/gen-0001")
                 (list :id "gen-0002" :number 2 :status :good
                       :image "images/gen-0002")
                 (list :id "gen-0003" :number 3 :status :quarantined
                       :parent "gen-0001" :image "images/gen-0003"))))
    (let ((keep (ourro.supervisor::images-to-keep (ourro.supervisor:read-ledger))))
      (is-true (member "images/gen-0001" keep :test #'equal)))))


(test replay-block-extraction
  (is (string= "hello"
               (ourro.supervisor::extract-between
                (format nil "boot noise~%~A~%hello~%~A~%more"
                        ourro.supervisor::+replay-begin+
                        ourro.supervisor::+replay-end+)
                ourro.supervisor::+replay-begin+
                ourro.supervisor::+replay-end+)))
  (is (null (ourro.supervisor::extract-between
             "no markers here"
             ourro.supervisor::+replay-begin+
             ourro.supervisor::+replay-end+))))


(test replay-diverge-detects-differing-results
  ;; Same tool, different output → divergence, with a report (from the local
  ;; TRACE-DIVERGENCES) naming the tool and both values — this is what would
  ;; signal GENERATION-BUILD-FAILURE in the gate.
  (multiple-value-bind (diverge report)
      (ourro.supervisor::replay-blocks-diverge
       "((:tool \"list_files\" :result \"a.lisp\" :error-p nil))"
       "((:tool \"list_files\" :result \"b.lisp\" :error-p nil))")
    (is-true diverge)
    (is-true (search "list_files" report))
    (is-true (search "a.lisp" report))
    (is-true (search "b.lisp" report))))

(test replay-agree-on-identical-traces
  (is-false (ourro.supervisor::replay-blocks-diverge
             "((:tool \"list_files\" :result \"same\" :error-p nil))"
             "((:tool \"list_files\" :result \"same\" :error-p nil))")))

(test replay-diverge-on-differing-trace-count
  ;; A candidate that produces more (or fewer) traces than the baseline is a
  ;; divergence too — TRACE-DIVERGENCES walks past the shorter list's end so the
  ;; surplus/missing tail is not silently ignored.
  (is-true (ourro.supervisor::replay-blocks-diverge
            "((:tool \"list_files\" :result \"x\"))"
            "((:tool \"list_files\" :result \"x\") (:tool \"read_file\" :result \"y\"))")))

(test replay-nil-candidate-fails-closed
  (is-true (ourro.supervisor::replay-blocks-diverge
             "((:tool \"list_files\" :result \"x\"))" nil)))

(test replay-falls-back-to-string-compare
  ;; A block that won't parse as a sexp still gets a raw-text comparison.
  (is-true (ourro.supervisor::replay-blocks-diverge "garbage ((( " "other garbage"))
  (is-false (ourro.supervisor::replay-blocks-diverge "same text" "same text")))


(test find-bootable-skips-a-quarantined-preferred
  (with-scratch-home ()
    ;; gen-0002 is quarantined but its image is still present; gen-0001 is good.
    (touch-image "images/gen-0001")
    (touch-image "images/gen-0002")
    (ourro.supervisor:write-ledger
     (list :current "gen-0002"
           :generations
           (list (list :id "gen-0001" :number 1 :status :good :image "images/gen-0001")
                 (list :id "gen-0002" :number 2 :status :quarantined :image "images/gen-0002"))))
    (let* ((sup (make-instance 'ourro.supervisor::supervision))
           (bad (list :id "gen-0002" :number 2 :status :quarantined :image "images/gen-0002"))
           (good (list :id "gen-0001" :number 1 :status :good :image "images/gen-0001")))
      ;; Involuntary boot: a quarantined preferred is rejected → fall back to good.
      (is (string= "gen-0001"
                   (pget (ourro.supervisor::find-bootable-generation nil sup bad) :id)))
      ;; A good preferred is still tried first.
      (is (string= "gen-0001"
                   (pget (ourro.supervisor::find-bootable-generation nil sup good) :id)))
      ;; Deliberate /travel to the quarantined gen: honored, not skipped.
      (is (string= "gen-0002"
                   (pget (ourro.supervisor::find-bootable-generation
                          nil sup bad :allow-non-good t)
                         :id))))))


(defun seed-genome-git-home ()
  "In the current scratch home, seed a git-backed genome repo + config and
return the HEAD commit. Mirrors BUILD-GENERATION-WITH-STUB's setup."
  (let ((genome (ourro.util:ourro-path "genome/")))
    (ensure-directories-exist genome)
    (ourro.util:write-sexp-file (merge-pathnames "manifest.sexp" genome)
                               (list :generation 1 :genes '()))
    (ourro.util:write-sexp-file (ourro.util:ourro-path "config.sexp")
                               (list :source-dir (namestring (uiop:getcwd))
                                     :sbcl "sbcl"))
    (ourro.supervisor::git "init")
    (ourro.supervisor::git "config" "user.email" "t@t")
    (ourro.supervisor::git "config" "user.name" "t")
    (ourro.supervisor::git-commit-all "gen-0001")))

(test ensure-generation-image-present-is-a-noop
  ;; When the image file already exists, no rebuild is attempted (the build
  ;; hook must not fire).
  (with-scratch-home ()
    (touch-image "images/gen-0001")
    (let* ((record (list :id "gen-0001" :commit "deadbeef"
                         :image "images/gen-0001"))
           (fired nil)
           (ourro.supervisor:*build-image-hook*
             (lambda (dir out) (declare (ignore dir out)) (setf fired t))))
      (is-true (ourro.supervisor::ensure-generation-image nil record))
      (is-false fired))))

(test ensure-generation-image-no-commit-returns-nil
  ;; Missing image AND no recorded commit → nothing to rebuild from.
  (with-scratch-home ()
    (let ((record (list :id "gen-0009" :image "images/gen-0009")))
      (is-false (ourro.supervisor::ensure-generation-image nil record)))))

(test rebuild-generation-image-checks-out-commit-and-builds
  ;; A pruned image is rebuilt from the genome commit: the build hook is handed
  ;; a worktree whose HEAD is exactly the record's commit, and the image lands.
  (with-scratch-home ()
    (let* ((commit (seed-genome-git-home))
           (config (ourro.supervisor::read-config))
           (record (list :id "gen-0001" :commit commit
                         :image "images/gen-0001"))
           (seen-commit nil)
           (seen-dir nil)
           (ourro.supervisor:*build-image-hook*
             (lambda (genome-dir output)
               (setf seen-dir genome-dir
                     seen-commit
                     (ourro.util:trim
                      (uiop:run-program
                       (list "git" "-C" (namestring genome-dir)
                             "rev-parse" "HEAD")
                       :output '(:string :stripped t))))
               (ensure-directories-exist output)
               (with-open-file (out output :direction :output
                                           :if-exists :supersede)
                 (write-string "img" out))
               output)))
      ;; Image is absent to begin with.
      (is-false (probe-file (ourro.supervisor::generation-image-path record)))
      (is-true (ourro.supervisor::ensure-generation-image config record))
      ;; Built from a worktree checked out at the record's commit.
      (is (string= commit seen-commit))
      (is-true (search "worktrees" (namestring seen-dir)))
      ;; The image now exists…
      (is-true (probe-file (ourro.supervisor::generation-image-path record)))
      ;; …and the throwaway worktree was cleaned up.
      (is-false (probe-file (ourro.supervisor::generation-worktree-path
                             "gen-0001"))))))


(test elapsed-seconds-is-a-monotonic-difference
  (is (< (abs (- 2.0d0 (ourro.supervisor::elapsed-seconds
                        0 (* 2 internal-time-units-per-second))))
         0.001)))

(test hello-measures-restart-latency-only-for-a-resume
  (let ((sup (make-instance 'ourro.supervisor::supervision)))
    ;; Cold boot: no timer armed → nothing measured.
    (ourro.supervisor::handle-agent-message sup '(:hello) nil)
    (is (null (ourro.supervisor::last-restart-seconds sup)))
    ;; A session-restoring respawn armed the timer ~1s ago; :hello (by which
    ;; point the agent has restored the session) measures and clears it.
    (setf (ourro.supervisor::restart-timer sup)
          (- (get-internal-real-time) internal-time-units-per-second))
    (ourro.supervisor::handle-agent-message sup '(:hello) nil)
    (is (null (ourro.supervisor::restart-timer sup)))
    (let ((seconds (ourro.supervisor::last-restart-seconds sup)))
      (is-true (and seconds (< 0.5 seconds 5.0))))))

(test rejected-control-message-returns-diagnostics-without-killing-the-server
  (with-scratch-home ()
    (ourro.supervisor:write-ledger (list :current nil :generations '()))
    (let* ((sup (make-instance 'ourro.supervisor::supervision))
           (failure (ourro.supervisor::handle-agent-message-safely
                     sup '(:promote-generation :id "missing"
                           :transaction-id "missing" :proof-hash "missing") nil))
           (next (ourro.supervisor::handle-agent-message-safely
                  sup '(:hello) nil)))
      (is (eq :error (first failure)))
      (is (stringp (pget (rest failure) :message)))
      (is (eq :ok (first next))))))

(test session-restoring-respawn-p-distinguishes-resume-cold-visit
  ;; The timer arms only for a real session restore, not a cold boot or a
  ;; read-only visit (M5 review #7).
  (is-true (ourro.supervisor::session-restoring-respawn-p "state.sexp" nil))
  (is-false (ourro.supervisor::session-restoring-respawn-p nil nil))
  (is-false (ourro.supervisor::session-restoring-respawn-p "state.sexp" t)))

(test pin-generation-commit-keeps-the-commit-reachable
  ;; A per-generation tag pins the commit so rebuild-on-demand can't lose it to
  ;; gc (M5 review #5).
  (with-scratch-home ()
    (let ((commit (seed-genome-git-home)))
      (ourro.supervisor::pin-generation-commit "gen-0001" commit)
      (is (string= commit
                   (ourro.util:trim
                    (uiop:run-program
                     (list "git" "-C"
                           (namestring (ourro.util:ourro-path "genome/"))
                           "rev-parse" "gen-0001")
                     :output '(:string :stripped t))))))))


(test find-bootable-generation-refuses-when-nothing-bootable
  ;; The only generation has no image on disk and no commit to rebuild from →
  ;; NIL, which the supervise loop turns into a clean fatal exit rather than an
  ;; unhandled LAUNCH-PROGRAM crash on a missing binary.
  (with-scratch-home ()
    (ourro.supervisor:write-ledger
     (list :current "gen-0001"
           :generations (list (list :id "gen-0001" :number 1 :status :good
                                    :image "images/gen-0001"))))
    (let ((sup (make-instance 'ourro.supervisor::supervision))
          (record (ourro.supervisor::generation-record
                   (ourro.supervisor:read-ledger) "gen-0001")))
      (is (null (ourro.supervisor::find-bootable-generation nil sup record))))))

(test find-bootable-generation-falls-back-to-older-rebuildable
  ;; Preferred gen-0002 has neither an image nor a commit; older good gen-0001
  ;; has a commit, so it rebuilds and becomes the bootable choice.
  (with-scratch-home ()
    (let* ((commit (seed-genome-git-home))
           (config (ourro.supervisor::read-config))
           (sup (make-instance 'ourro.supervisor::supervision))
           (built nil)
           (ourro.supervisor:*build-image-hook*
             (lambda (dir output)
               (declare (ignore dir))
               (setf built t)
               (ensure-directories-exist output)
               (with-open-file (out output :direction :output
                                           :if-exists :supersede)
                 (write-string "img" out))
               output)))
      (ourro.supervisor:write-ledger
       (list :current "gen-0002"
             :generations
             (list (list :id "gen-0001" :number 1 :status :good
                         :commit commit :image "images/gen-0001")
                   (list :id "gen-0002" :number 2 :status :good
                         :image "images/gen-0002"))))
      (let* ((ledger (ourro.supervisor:read-ledger))
             (preferred (ourro.supervisor::generation-record ledger "gen-0002"))
             (bootable (ourro.supervisor::find-bootable-generation
                        config sup preferred)))
        (is (string= "gen-0001" (getf bootable :id)))
        (is-true built)))))

(test find-bootable-generation-uses-present-image-without-rebuild
  ;; A preferred image already on disk is returned as-is; no rebuild is
  ;; attempted (the build hook must not fire).
  (with-scratch-home ()
    (touch-image "images/gen-0001")
    (let ((sup (make-instance 'ourro.supervisor::supervision))
          (fired nil)
          (record (list :id "gen-0001" :commit "deadbeef"
                        :image "images/gen-0001")))
      (let ((ourro.supervisor:*build-image-hook*
              (lambda (dir out) (declare (ignore dir out)) (setf fired t))))
        (let ((bootable (ourro.supervisor::find-bootable-generation
                         nil sup record)))
          (is (string= "gen-0001" (getf bootable :id)))
          (is-false fired))))))


(test sweep-stale-worktrees-empties-the-dir
  (with-scratch-home ()
    (let ((wt (ourro.supervisor::worktrees-dir)))
      (ensure-directories-exist (merge-pathnames "gen-0001/" wt))
      (ensure-directories-exist (merge-pathnames "gen-0002/" wt))
      (with-open-file (o (merge-pathnames "gen-0001/stray" wt)
                         :direction :output :if-exists :supersede
                         :if-does-not-exist :create)
        (write-string "x" o))
      (is (= 2 (length (uiop:subdirectories wt))))
      (ourro.supervisor::sweep-stale-worktrees)
      (is (null (uiop:subdirectories wt))))))


(defun write-minimal-config ()
  (ourro.util:write-sexp-file (ourro.util:ourro-path "config.sexp")
                             (list :source-dir (namestring (uiop:getcwd))
                                   :sbcl "sbcl")))

(test supervise-boots-a-fallback-when-preferred-is-unbootable
  ;; current=gen-0002 has no image and no commit (unbootable); older good
  ;; gen-0001 has an image on disk. The pre-spawn guard must fall back to
  ;; gen-0001 and hand *its* image to the spawn seam — never exec the missing
  ;; gen-0002 binary.
  (with-scratch-home ()
    (write-minimal-config)
    (touch-image "images/gen-0001")
    (ourro.supervisor:write-ledger
     (list :current "gen-0002"
           :generations
           (list (list :id "gen-0001" :number 1 :parent nil :status :good
                       :image "images/gen-0001")
                 (list :id "gen-0002" :number 2 :parent "gen-0001" :status :good
                       :image "images/gen-0002"))))
    (let* ((spawned-image nil)
           (ourro.supervisor:*spawn-agent-hook*
             (lambda (image args)
               (declare (ignore args))
               (setf spawned-image image)
               (uiop:launch-program (list "true")))))
      (ourro.supervisor::supervise :once t)
      (is-true spawned-image)
      (is-true (search "gen-0001" (namestring spawned-image)))
      (is (null (search "gen-0002" (namestring spawned-image)))))))

(test supervise-signals-cleanly-when-nothing-is-bootable
  ;; The one generation has neither an image nor a commit → the guard signals
  ;; rather than spawn a nonexistent binary. The spawn seam must never fire.
  (with-scratch-home ()
    (write-minimal-config)
    (ourro.supervisor:write-ledger
     (list :current "gen-0001"
           :generations (list (list :id "gen-0001" :number 1 :parent nil
                                    :status :good :image "images/gen-0001"))))
    (let* ((spawned nil)
           (ourro.supervisor:*spawn-agent-hook*
             (lambda (image args)
               (declare (ignore image args))
               (setf spawned t)
               (uiop:launch-program (list "true")))))
      (signals error (ourro.supervisor::supervise :once t))
      (is-false spawned))))


(defun arg-value (args name)
  (loop for (a b) on args when (string= a name) return b))

(defun travel-stub-hook (generation &key hard visiting (exit-code 75))
  "A *spawn-agent-hook* emulating an agent that requests a /travel handoff to
GENERATION then exits EXIT-CODE. Connects to the supervisor socket from the
spawn args (as the real agent does), sends the :handoff notification, and
returns a short-lived process exiting EXIT-CODE."
  (lambda (image args)
    (declare (ignore image))
    (let ((socket (arg-value args "--socket")))
      (ignore-errors
       (let ((conn (ourro.kernel:protocol-connect socket)))
         (ourro.kernel:protocol-send
          conn (list :handoff :generation generation
                              :state-file "/tmp/ourro-travel-stub.sexp"
                              :hard hard :visiting visiting))
         ;; Let the server thread drain the frame before the exit-75 branch
         ;; polls PENDING-HANDOFF.
         (sleep 0.1)))
      (uiop:launch-program (list "sh" "-c" (format nil "exit ~D" exit-code))))))

(defun two-generation-ledger ()
  "current=gen-0001; gen-0002 present with an image on disk (a travel target)."
  (write-minimal-config)
  (touch-image "images/gen-0001")
  (touch-image "images/gen-0002")
  (ourro.supervisor:write-ledger
   (list :current "gen-0001"
         :generations
         (list (list :id "gen-0001" :number 1 :parent nil :status :good
                     :image "images/gen-0001")
               (list :id "gen-0002" :number 2 :parent "gen-0001" :status :good
                     :image "images/gen-0002")))))

(test supervise-hard-travel-advances-current-generation
  ;; A hard /travel (re-root) to gen-0002: exit 75 + :handoff :hard t. The
  ;; supervisor must take the handoff branch (return :once, not :quit) AND make
  ;; gen-0002 the current generation.
  (with-scratch-home ()
    (two-generation-ledger)
    (let ((ourro.supervisor:*spawn-agent-hook*
            (travel-stub-hook "gen-0002" :hard t)))
      (is (eq :once (ourro.supervisor::supervise :once t)))
      (is (string= "gen-0002"
                   (ourro.supervisor:ledger-current (ourro.supervisor:read-ledger)))))))

(test supervise-visiting-travel-keeps-current-generation
  ;; A read-only visit to gen-0002: exit 75 + :handoff :visiting t. Handoff
  ;; branch taken (:once), but the current generation is unchanged — visiting
  ;; must not advance the ledger.
  (with-scratch-home ()
    (two-generation-ledger)
    (let ((ourro.supervisor:*spawn-agent-hook*
            (travel-stub-hook "gen-0002" :visiting t)))
      (is (eq :once (ourro.supervisor::supervise :once t)))
      (is (string= "gen-0001"
                   (ourro.supervisor:ledger-current (ourro.supervisor:read-ledger)))))))

(test supervise-exit-0-with-handoff-is-still-a-clean-quit
  ;; The F-travel regression guard: a stub that sends the SAME :handoff but
  ;; exits 0 (what /travel did before the fix) must be read as a clean quit —
  ;; the supervisor returns :quit and the current generation is untouched. This
  ;; is exactly why the agent must exit 75, not 0.
  (with-scratch-home ()
    (two-generation-ledger)
    (let ((ourro.supervisor:*spawn-agent-hook*
            (travel-stub-hook "gen-0002" :hard t :exit-code 0)))
      (is (eq :quit (ourro.supervisor::supervise :once t)))
      (is (string= "gen-0001"
                   (ourro.supervisor:ledger-current (ourro.supervisor:read-ledger)))))))

(test supervise-unknown-travel-target-reboots-current
  ;; /travel to a generation that does not exist: the handoff branch runs but
  ;; the target lookup is NIL, so the supervisor announces "rebooting current"
  ;; and keeps the session alive (returns :once, current unchanged) rather than
  ;; spawning a missing binary.
  (with-scratch-home ()
    (two-generation-ledger)
    (let ((ourro.supervisor:*spawn-agent-hook*
            (travel-stub-hook "gen-9999" :hard t))
          (out (make-string-output-stream)))
      (let ((*standard-output* (make-broadcast-stream *standard-output* out)))
        (is (eq :once (ourro.supervisor::supervise :once t))))
      (is (search "rebooting current" (get-output-stream-string out)))
      (is (string= "gen-0001"
                   (ourro.supervisor:ledger-current (ourro.supervisor:read-ledger)))))))
