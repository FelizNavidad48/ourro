
(defpackage #:ourro.supervisor
  (:use #:cl #:ourro.util)
  (:import-from #:ourro.kernel
                #:make-protocol-server
                #:protocol-serve
                #:protocol-error)
  (:export #:main
           #:ensure-initialized
           #:supervise
           #:ledger
           #:read-ledger
           #:write-ledger
           #:ledger-current
           #:ledger-generations
           #:generation-record
           #:next-generation-number
           #:build-generation
           #:promote-generation
           #:install-wal-path
           #:install-wal-health
           #:quarantine-generation
           #:latest-good-generation
           #:*spawn-agent-hook*
           #:*build-image-hook*))

(in-package #:ourro.supervisor)


(defun config-path () (ourro-path "config.sexp"))
(defun ledger-path () (ourro-path "ledger.sexp"))
(defun genome-dir () (ourro-path "genome/"))
(defun images-dir () (ourro-path "images/"))
(defun socket-path () (ourro-path "supervisor.sock"))
(defun base-core-path () (ourro-path "base.core"))
(defun checkpoint-path () (ourro-path "state/checkpoint.sexp"))
(defun poisoned-checkpoint-path () (ourro-path "state/checkpoint-poisoned.sexp"))
(defun install-wal-path () (ourro-path "state/install.wal"))

(defun install-wal-health ()
  "Public supervisor health for the durable generation-install journal."
  (ourro.txn:wal-health (install-wal-path)))

(defun supervisor-log (control &rest args)
  "Append one timestamped line to state/supervisor.log. Opens the file directly
rather than printing to *STANDARD-OUTPUT*: the server and build threads do NOT
inherit the main loop's *STANDARD-OUTPUT*→log rebinding (a fresh thread starts
with the global stream), and printing to the real stdout would corrupt the
agent's alt screen. Best-effort — a logging failure must never take down a
supervision thread."
  (ignore-errors
   (with-open-file (log (ourro-path "state/supervisor.log")
                        :direction :output
                        :if-exists :append
                        :if-does-not-exist :create)
     (format log "~&[ourro] ~A ~?~%" (iso-time) control args)
     (finish-output log))))

(defun crash-resume-plan (booted-from-checkpoint checkpoint-present)
  "Decide how a just-crashed generation should resume (M4-1). Pure, so the
policy is unit-tested directly:
  :resume-checkpoint — a checkpoint exists and this boot did not come from one,
  :poison            — the boot that crashed WAS a checkpoint resume, so the
                       checkpoint is presumed poisonous and must be set aside
                       rather than fed back into the crash loop,
  :cold              — nothing to resume."
  (cond (booted-from-checkpoint :poison)
        (checkpoint-present :resume-checkpoint)
        (t :cold)))

(defun read-config ()
  (or (read-sexp-file (config-path))
      (error "ourro is not initialized here (~A). Run: ourro init"
             (ourro-home))))

(defun config-source-dir (config)
  (uiop:ensure-directory-pathname (pget config :source-dir)))

(defun config-sbcl (config)
  (or (pget config :sbcl) "sbcl"))

(defparameter *default-settings-template*
  '(:thinking-level "LOW"
    :max-tokens nil
    :max-stream-seconds 600
    :max-tool-steps 25
    :restart-policy :calm
    :experimental-reflexes nil
    :default-model "opus-4-6"
    :bedrock-region "eu-north-1"
    :retry-max-attempts 5
    :retry-backoff-cap 30)
  "The :settings template `ourro init` seeds into config.sexp so every tunable is
discoverable in one file. Mirror of ourro.config:*default-settings* — keep in
sync with src/config.lisp. Secrets and the model choice stay env vars
(OURRO_BEDROCK_API_KEY / OURRO_VERTEX_API_KEY / OURRO_MODEL); everything else lives
here.")

(defun write-config-preserving-settings (source)
  "Write config.sexp with SOURCE + sbcl, preserving any :settings the user has
already edited (else seeding the default template). So re-running `ourro init`
never clobbers a tuned config."
  (let ((existing (ignore-errors (read-sexp-file (config-path)))))
    (write-sexp-file
     (config-path)
     (list :source-dir (namestring source)
           :sbcl (or (getenv "OURRO_SBCL") "sbcl")
           :settings (or (pget existing :settings)
                         *default-settings-template*)))))


(defvar *ledger-lock* (bt:make-lock "ourro-ledger"))

(defun read-ledger ()
  (read-sexp-file (ledger-path) (list :current nil :generations '())))

(defun write-ledger (ledger)
  (write-sexp-file (ledger-path) ledger))

(defun ledger-current (ledger) (pget ledger :current))
(defun ledger-generations (ledger) (pget ledger :generations))

(defun generation-record (ledger id)
  (find id (ledger-generations ledger)
        :key (lambda (record) (pget record :id))
        :test #'equal))

(defun next-generation-number (ledger)
  (1+ (reduce #'max (ledger-generations ledger)
              :key (lambda (record) (pget record :number 0))
              :initial-value 0)))

(defun generation-id (number)
  (format nil "gen-~4,'0D" number))

(defun update-ledger (function)
  "Apply FUNCTION to the ledger under the lock and persist the result."
  (bt:with-lock-held (*ledger-lock*)
    (let ((ledger (funcall function (read-ledger))))
      (write-ledger ledger)
      ledger)))

(defun add-generation-record (record &key make-current)
  (update-ledger
   (lambda (ledger)
     (let ((generations (append (ledger-generations ledger) (list record))))
       (list :current (if make-current
                          (pget record :id)
                          (ledger-current ledger))
             :generations generations)))))

(defun set-generation-status (id status &key report)
  (update-ledger
   (lambda (ledger)
     (list :current (ledger-current ledger)
           :generations
           (mapcar (lambda (record)
                     (if (equal (pget record :id) id)
                         (let ((updated (plist-put record :status status)))
                           (if report
                               (plist-put updated :report report)
                               updated))
                         record))
                   (ledger-generations ledger))))))

(defun set-current-generation (id)
  (update-ledger
   (lambda (ledger)
     (list :current id :generations (ledger-generations ledger)))))

(defun latest-good-generation (&optional (ledger (read-ledger)))
  "The current generation if good, else the newest :good record."
  (let ((current (generation-record ledger (ledger-current ledger))))
    (if (and current (eq (pget current :status) :good))
        current
        (find :good (reverse (ledger-generations ledger))
              :key (lambda (record) (pget record :status))))))

(defun generation-image-path (record)
  (merge-pathnames (pget record :image) (ourro-home)))


(defparameter *good-images-to-keep* 3
  "How many of the newest :good generations keep their image on disk.")

(defun images-to-keep (ledger)
  "The set of image-relative paths to preserve: the current generation, the
few newest :good ones, and the parent of every quarantined generation (its
rollback target / forensic anchor)."
  (let ((keep '()))
    (flet ((keep! (record)
             (let ((image (and record (pget record :image))))
               (when image (pushnew image keep :test #'equal)))))
      (keep! (generation-record ledger (ledger-current ledger)))
      (let ((goods (sort (remove-if-not
                          (lambda (r) (eq (pget r :status) :good))
                          (copy-list (ledger-generations ledger)))
                         #'> :key (lambda (r) (pget r :number 0)))))
        (dolist (record (subseq goods 0 (min *good-images-to-keep*
                                             (length goods))))
          (keep! record)))
      (dolist (record (ledger-generations ledger))
        (when (eq (pget record :status) :quarantined)
          (keep! (generation-record ledger (pget record :parent))))))
    keep))

(defun prune-images (&optional (ledger (read-ledger)))
  "Delete generation image files not in the keep-set. Ledger records are left
untouched — the genome is truth and any image rebuilds from its commit.
Returns the list of image-relative paths pruned."
  (let ((keep (images-to-keep ledger))
        (pruned '()))
    (dolist (record (ledger-generations ledger) (nreverse pruned))
      (let ((image (pget record :image)))
        (when (and image (not (member image keep :test #'equal)))
          (let ((path (merge-pathnames image (ourro-home))))
            (when (probe-file path)
              (ignore-errors (delete-file path))
              (push image pruned))))))))


(defparameter +replay-begin+ "<<<OURRO-REPLAY"
  "Must match OURRO.MAIN's sentinel; the supervisor doesn't load ourro.main.")
(defparameter +replay-end+ "OURRO-REPLAY>>>")

(defun kernel-source-files ()
  "Deterministic list of files that define the fixed Lisp image/kernel."
  (let* ((source (config-source-dir (read-config)))
         (src (merge-pathnames "src/" source))
         (files '()))
    (labels ((walk (directory)
               (dolist (file (uiop:directory-files directory))
                 (when (string-equal (or (pathname-type file) "") "lisp")
                   (push file files)))
               (dolist (subdir (uiop:subdirectories directory)) (walk subdir))))
      (walk src))
    (dolist (relative '("ourro.asd" "scripts/build-base-core.lisp"
                        "scripts/build-agent-image.lisp"))
      (let ((file (merge-pathnames relative source)))
        (when (probe-file file) (push file files))))
    (sort files #'string< :key #'namestring)))

(defun kernel-source-hash ()
  "Stable FNV-1a content identity over kernel paths and text.
This is a change detector recorded in the ledger, not a security signature."
  (let ((hash #xcbf29ce484222325)
        (prime #x100000001b3)
        (mask #xffffffffffffffff)
        (source (config-source-dir (read-config))))
    (labels ((feed (text)
               (loop for character across text
                     do (setf hash
                              (logand mask
                                      (* (logxor hash (char-code character))
                                         prime))))))
      (dolist (file (kernel-source-files))
        (feed (namestring (enough-namestring file source)))
        (feed (uiop:read-file-string file))))
    (format nil "~16,'0X" hash)))

(defun extract-between (text begin end)
  "The substring of TEXT strictly between the first BEGIN marker and the
following END marker, trimmed, or NIL if either is missing. Walls the trace
block off from any boot/library chatter on the combined output stream."
  (let ((b (search begin text)))
    (when b
      (let* ((from (+ b (length begin)))
             (e (search end text :start2 from)))
        (when e (trim (subseq text from e)))))))

(defun kernel-changed-since-current-p ()
  "True when the current content hash differs from the generation ledger.
Old ledgers without a hash use the timestamp rule for one migration build."
  (let* ((ledger (read-ledger))
         (current (generation-record ledger (ledger-current ledger)))
         (recorded (and current (pget current :kernel-hash)))
         (image (and current (generation-image-path current))))
    (if recorded
        (not (string= recorded (kernel-source-hash)))
        (and image (probe-file image) (probe-file (base-core-path))
             (> (file-write-date (base-core-path)) (file-write-date image))))))

(defun recent-session-event-files (&optional (limit 3))
  "The newest LIMIT sessions/*/events.sexp files, most recent first."
  (let ((files (ignore-errors (directory (ourro-path "sessions/*/events.sexp")))))
    (when files
      (let ((sorted (sort (copy-list files) #'> :key #'file-write-date)))
        (subseq sorted 0 (min limit (length sorted)))))))

(defun replay-output (image events-file)
  "Run IMAGE --replay EVENTS-FILE and return its trace block, or NIL. A short
timeout bounds the reap of an image that predates --replay and boots its TUI
instead (it SIGTTOU-stops on the terminal); a genuine replay of read-only tools
finishes in well under a second."
  (let ((output (run-command
                 (list "env"
                       (format nil "OURRO_HOME=~A" (namestring (ourro-home)))
                       (namestring image) "--replay" (namestring events-file))
                 :timeout 15)))
    (extract-between output +replay-begin+ +replay-end+)))

(defun replay-block-traces (block)
  "Parse a --replay trace BLOCK (the text between the sentinels) into the list
of (:tool … :result … :error-p …) plists MAIN.LISP's REPLAY-MODE prin1'd there.
Returns NIL when it will not read as a single list, so callers can fall back to
raw text comparison. *READ-EVAL* is disabled — this is subprocess output."
  (when block
    (ignore-errors
     (let ((*read-eval* nil)
           (*package* (find-package :keyword)))
       (let ((form (read-from-string block nil nil)))
         (and (listp form) form))))))

(defun trace-divergences (base-traces cand-traces)
  "Pairwise-compare two parsed replay trace lists, returning a list of divergence
plists (:tool :baseline :candidate). Entries are compared *whole* with EQUAL — so
a flipped :error-p counts, matching the strictness of the raw string= this
replaced, not just a differing :result — and a differing length shows up as a
divergence on the surplus/missing entries (one side is NIL). This is the moral
equivalent of OURRO.VERIFY:COMPARE-TRACES, reimplemented here on plain plists so
the supervisor stays free of the verify/tools/llm dependency chain — it is a
deliberately tiny process that never loads the agent."
  (loop for i from 0
        for b = (nth i base-traces)
        for c = (nth i cand-traces)
        while (or b c)
        unless (equal b c)
          collect (list :tool (or (pget b :tool) (pget c :tool))
                        :baseline (pget b :result)
                        :candidate (pget c :result))))

(defun replay-blocks-diverge (base cand)
  "Decide whether a candidate image's read-only trace block CAND diverges from
the current image's BASE — the actual F-4 divergence decision, factored out so
it is unit-tested directly. Returns (values diverge-p report-or-nil): compares
the parsed trace lists pairwise by result (pinpointing the divergent tool and
both values), and falls back to raw string identity when a block will not parse.
A NIL CAND is unavailable evidence and therefore fails closed."
  (if (null cand)
      (values t "candidate replay produced no valid trace block")
      (let ((base-traces (replay-block-traces base))
            (cand-traces (replay-block-traces cand)))
        (if (and base-traces cand-traces)
            (let ((divs (trace-divergences base-traces cand-traces)))
              (values (and divs t)
                      (when divs
                        (format nil "~{~A~^~%~}"
                                (mapcar (lambda (d)
                                          (format nil "  tool ~A: baseline ~S vs candidate ~S"
                                                  (pget d :tool)
                                                  (pget d :baseline)
                                                  (pget d :candidate)))
                                        divs)))))
            ;; One block didn't parse — compare the raw text.
            (values (not (string= base cand)) nil)))))

(defun replay-gate (staging)
  "Replay recent read-only tool calls against the current image and STAGING and
require identical traces when the kernel changed. Missing or malformed evidence
is a build failure, not permission to publish an unverified kernel."
  (handler-case
      (when (kernel-changed-since-current-p)
        (let* ((ledger (read-ledger))
               (current (generation-record ledger (ledger-current ledger)))
               (current-image (and current (generation-image-path current)))
               (sessions (recent-session-event-files 3)))
          (cond
            ((not (and current-image (probe-file current-image) sessions))
             (error 'ourro.kernel:generation-build-failure
                    :message "kernel replay evidence unavailable"
                    :report "kernel changed but no baseline image/session events were available"))
            (t
             (block gate
               (let ((compared 0))
                 (dolist (events sessions)
                   (let ((base (ignore-errors (replay-output current-image events))))
                     (cond
                       ;; No baseline trace block: the current image predates
                       ;; --replay (it booted its TUI and was reaped by the
                       ;; timeout) or errored. A comparison is impossible, so
                       ;; skip the whole gate — one timeout, not one per
                       ;; session. New images DO support --replay, so the gate
                       ;; goes live from the next build onward.
                       ((null base)
                        (error 'ourro.kernel:generation-build-failure
                               :message "kernel replay baseline unavailable"
                               :report (format nil "baseline produced no trace for ~A" events)))
                       (t
                        (let ((cand (ignore-errors (replay-output staging events))))
                          (multiple-value-bind (diverge report)
                              (replay-blocks-diverge base cand)
                            (when diverge
                              (error 'ourro.kernel:generation-build-failure
                                     :message "kernel replay divergence"
                                     :report (format nil "read-only tool traces diverged ~
between the current and candidate images for session ~A~@[~%~A~]"
                                                     (file-namestring events) report))))
                          (incf compared))))))
                 (format t "~&[ourro] replay: 0 divergences across ~A session(s).~%"
                         compared)))))
          (finish-output)))
    (ourro.kernel:generation-build-failure (c) (error c)) ; real divergence blocks
    (error (c)
      (error 'ourro.kernel:generation-build-failure
             :message "kernel replay infrastructure failed"
             :report (princ-to-string c)))))


(defun git (&rest args)
  (run-command (cons "git" args) :directory (genome-dir)))

(defun git-commit-all (message)
  (git "add" "-A")
  ;; Commit may be a no-op when nothing changed; tolerate that.
  (handler-case (git "commit" "-m" message
                     "--author" "ourro <ourro@localhost>")
    (command-failed (c)
      (unless (search "nothing to commit" (command-failed-output c))
        (error c))))
  (trim (git "rev-parse" "HEAD")))

(defun pin-generation-commit (id commit)
  "Tag a generation's genome commit so it stays reachable forever (M5-1). A hard
`/travel` re-root can leave forward commits unreferenced; without a ref, `git
gc` could eventually prune them and defeat rebuild-on-demand. The tag makes
'the genome is truth, rebuildable' actually hold. Non-fatal.

D5: these tags are never deleted, one per generation. That is deliberate and
harmless — they are the reachability roots for forensic `/travel` to any past
generation, they cost a few bytes each in `.git/refs`, and pruning them would
be the very leak this function exists to prevent."
  (ignore-errors (git "tag" "-f" id commit)))


(defun ensure-initialized (&key source-dir force rebuild)
  "Create the ourro home: config, genome repo seeded from the source
tree, ledger, base core, and the gen-0001 image.

FORCE re-seeds the genome and rebuilds everything from scratch (a true clean
slate — learned genes are lost; this is what `make build` uses). REBUILD
forces a from-scratch build of the base core and the current generation's
image (never boots a stale binary) while preserving the evolved genome and
the ledger — `ourro init --source-dir . --rebuild` for a code refresh that
keeps learning. Plain `ourro run` reuses whatever image already exists."
  (let* ((home (ensure-dir (ourro-home)))
         (source (uiop:ensure-directory-pathname
                  (or source-dir
                      (pget (read-sexp-file (config-path)) :source-dir)
                      (error "ourro init requires --source-dir on first run")))))
    (ensure-dir (images-dir))
    (ensure-dir (ourro-path "state/"))
    (ensure-dir (ourro-path "sessions/"))
    (ensure-dir (ourro-path "quarantine/"))
    (write-config-preserving-settings source)
    ;; Seed the genome repo once.
    (when (or force (not (probe-file (merge-pathnames "manifest.sexp"
                                                      (genome-dir)))))
      (ensure-dir (genome-dir))
      (let ((seed (merge-pathnames "seed-genome/" source)))
        (unless (probe-file (merge-pathnames "manifest.sexp" seed))
          (error "No seed genome at ~A" seed))
        ;; cp -R seed/. genome/ copies the *contents* into the genome dir.
        (run-command (list "cp" "-R"
                           (concatenate 'string (namestring seed) ".")
                           (namestring (genome-dir)))))
      (unless (probe-file (merge-pathnames ".git/" (genome-dir)))
        (git "init")
        (git "config" "user.email" "ourro@localhost")
        (git "config" "user.name" "ourro"))
      (git-commit-all "gen-0001: seed genome"))
    ;; Base core + first image.
    (let ((config (read-config)))
      (ensure-base-core config :force (or force rebuild))
      (let ((ledger (read-ledger)))
        (cond
          ;; Fresh home (or forced): seed the ledger and build gen-0001.
          ((or force (null (ledger-generations ledger)))
           (let* ((id (generation-id 1))
                  (image-rel (format nil "images/~A" id))
                  (commit (trim (git "rev-parse" "HEAD"))))
             (pin-generation-commit id commit)   ; keep it rebuildable (M5-1)
             (build-image config (genome-dir)
                          (merge-pathnames image-rel home))
             (write-ledger
              (list :current id
                    :generations
                    (list (list :id id :number 1 :parent nil
                                :commit commit
                                :created (iso-time)
                                :status :good
                                :message "seed genome"
                                :kernel-hash (kernel-source-hash)
                                :image image-rel))))))
          ;; Existing home: if the current generation's image is stale versus
          ;; the (possibly just-rebuilt) base core, rebuild it in place. This
          ;; is what makes a rebuild after a source change pick up the new
          ;; code instead of re-launching an outdated binary.
          (t
           (ensure-current-image-fresh config)
           (ensure-bootable-generation config)))))
    home))

(defun ensure-bootable-generation (config)
  "INIT invariant: an initialized home must end with a bootable (:good)
generation. If none is :good — e.g. the seed was quarantined by a prior
crash/probation cascade and has no good successor, which otherwise leaves the
home bricked with `no good generation to boot` and no way for a plain `ourro
init` to recover — restore the current generation to :good, rebuilding its
image from the working genome if absent. Only heals when the current
generation is the genome tip (so it is rebuildable from the working tree) and
only when nothing else is bootable; a home with any :good generation is left
untouched. Safe: the quarantine described a since-rebuilt binary, and if the
restored image is still broken the supervisor re-quarantines it on the next
failed boot."
  (let ((ledger (read-ledger)))
    (unless (latest-good-generation ledger)
      (let* ((record (generation-record ledger (ledger-current ledger)))
             (head (ignore-errors (trim (git "rev-parse" "HEAD"))))
             (tip-p (and record
                         (or (null (pget record :commit))
                             (equal (pget record :commit) head)))))
        (when (and record tip-p)
          (format t "~&[ourro] ~A was quarantined and no other generation is ~
bootable — restoring it from source…~%"
                  (pget record :id))
          (finish-output)
          (let ((image (generation-image-path record)))
            (unless (probe-file image)
              (build-image config (genome-dir) image)))
          (set-generation-status (pget record :id) :good))))))

(defun ensure-current-image-fresh (config)
  "Rebuild the current generation's image if it is missing or older than the
base core. Keeps the ledger; only refreshes the binary."
  (let* ((ledger (read-ledger))
         (record (generation-record ledger (ledger-current ledger))))
    (when record
      (let* ((image (generation-image-path record))
             (head (ignore-errors (trim (git "rev-parse" "HEAD"))))
             ;; Only safe to rebuild from the working genome when the current
             ;; generation IS the genome tip; otherwise its genome isn't
             ;; checked out and the image stays as originally built.
             (tip-p (or (null (pget record :commit))
                        (equal (pget record :commit) head)))
             (stale (or (not (probe-file image))
                        (and (probe-file (base-core-path))
                             (< (file-write-date image)
                                (file-write-date (base-core-path)))))))
        (when (and stale tip-p)
          (format t "~&[ourro] rebuilding ~A image (source changed)…~%"
                  (pget record :id))
          (finish-output)
          (build-image config (genome-dir) image)
          (let ((hash (kernel-source-hash)))
            (update-ledger
             (lambda (current-ledger)
               (list :current (ledger-current current-ledger)
                     :generations
                     (mapcar (lambda (item)
                               (if (equal (pget item :id) (pget record :id))
                                   (plist-put item :kernel-hash hash)
                                   item))
                             (ledger-generations current-ledger)))))))))))

(defun base-core-stale-p (config)
  (let ((core (probe-file (base-core-path))))
    (or (null core)
        (let ((core-date (file-write-date core))
              (source (config-source-dir config)))
          (some (lambda (path)
                  (> (file-write-date path) core-date))
                (append (uiop:directory-files
                         (merge-pathnames "src/" source) "**/*.lisp")
                        (list (merge-pathnames "ourro.asd" source))))))))

(defun ensure-base-core (config &key force)
  (when (or force (base-core-stale-p config))
    (format t "~&[ourro] building base core (source changed)…~%")
    (finish-output)
    (run-command
     (list (config-sbcl config) "--non-interactive"
           "--load" (namestring (merge-pathnames "scripts/build-base-core.lisp"
                                                 (config-source-dir config))))
     :directory (config-source-dir config))
    (unless (probe-file (base-core-path))
      (error 'ourro.kernel:generation-build-failure
             :message "base core build produced no core file"))))


(defvar *build-image-hook* nil
  "Test seam: when bound, called as (fn genome-dir output-path) instead of
spawning a child SBCL build.")

(defun build-image (config genome-dir output-path)
  "Compile GENOME-DIR into a fresh executable image at OUTPUT-PATH via a
child SBCL running scripts/build-agent-image.lisp on the base core.
Signals GENERATION-BUILD-FAILURE with the child's output on any failure.
Paths reach the build script via the environment (--load takes no args)."
  (when *build-image-hook*
    (return-from build-image
      (funcall *build-image-hook* genome-dir output-path)))
  (let* ((script (merge-pathnames "scripts/build-agent-image.lisp"
                                  (config-source-dir config)))
         (staging (merge-pathnames
                   (format nil "~A.building" (file-namestring output-path))
                   (images-dir)))
         (output
           (handler-case
               (run-command
                (list "env"
                      (format nil "OURRO_BUILD_GENOME=~A" (namestring genome-dir))
                      (format nil "OURRO_BUILD_OUTPUT=~A" (namestring staging))
                      (format nil "OURRO_HOME=~A" (namestring (ourro-home)))
                      (config-sbcl config)
                      "--core" (namestring (base-core-path))
                      "--non-interactive"
                      "--load" (namestring script))
                :directory (config-source-dir config)
                :timeout 600)
             (command-failed (c)
               (error 'ourro.kernel:generation-build-failure
                      :message "image build failed"
                      :report (command-failed-output c))))))
    (declare (ignore output))
    (unless (probe-file staging)
      (error 'ourro.kernel:generation-build-failure
             :message (format nil "image build produced no file at ~A" staging)))
    ;; Smoke boot before installing.
    (handler-case
        (run-command (list "env"
                           (format nil "OURRO_HOME=~A" (namestring (ourro-home)))
                           (namestring staging) "--smoke")
                     :timeout 120)
      (command-failed (c)
        (ignore-errors (delete-file staging))
        (error 'ourro.kernel:generation-build-failure
               :message "smoke boot failed"
               :report (command-failed-output c))))
    ;; PR-11 replay gate (M4-5): only does work when the kernel/base changed.
    ;; A confirmed action-trace divergence deletes the staging image and fails
    ;; the build.
    (handler-case (replay-gate staging)
      (ourro.kernel:generation-build-failure (c)
        (ignore-errors (delete-file staging))
        (error c)))
    ;; Raw rename: CL:RENAME-FILE would merge STAGING's ".building" type into
    ;; the type-less OUTPUT-PATH. sb-posix:rename is a plain syscall.
    (sb-posix:rename (namestring staging) (namestring output-path))
    (run-command (list "chmod" "+x" (namestring output-path)))
    output-path))


(defun worktrees-dir () (ourro-path "state/worktrees/"))

(defun generation-worktree-path (id)
  (uiop:ensure-directory-pathname (merge-pathnames id (worktrees-dir))))

(defun sweep-stale-worktrees ()
  "Remove every leftover directory under state/worktrees/ (D2). A rebuild
(%REBUILD-GENERATION-IMAGE) unwind-protects its own worktree cleanup, but a
SIGKILL or power loss mid-rebuild strands the dir until that same generation
happens to be rebuilt again — nothing else GCs it. Sweeping once at supervise
start (before the first agent spawn, so no rebuild can be in flight and no live
worktree is ever swept) keeps the dir from accumulating orphans. Each removal is
best-effort: detach it from git and delete the tree; a single `git worktree
prune` at the end cleans up git's bookkeeping for all of them at once."
  (dolist (dir (ignore-errors (uiop:subdirectories (worktrees-dir))))
    (ignore-errors (git "worktree" "remove" "--force" (namestring dir)))
    (ignore-errors (uiop:delete-directory-tree dir :validate (constantly t))))
  (ignore-errors (git "worktree" "prune")))

(defun %rebuild-generation-image (config record)
  (let ((commit (pget record :commit))
        (image (generation-image-path record))
        (worktree (generation-worktree-path (pget record :id))))
    (unless commit
      (error "generation ~A has no recorded commit to rebuild from"
             (pget record :id)))
    ;; Clear any stale worktree from an interrupted rebuild, then let git
    ;; create the directory fresh (git worktree add refuses a non-empty path).
    (ignore-errors (git "worktree" "remove" "--force" (namestring worktree)))
    (ignore-errors (uiop:delete-directory-tree worktree :validate (constantly t)))
    (ignore-errors (git "worktree" "prune"))
    (ensure-directories-exist (worktrees-dir))
    (format t "~&[ourro] rebuilding ~A image from commit ~A…~%"
            (pget record :id) (subseq commit 0 (min 10 (length commit))))
    (finish-output)
    (git "worktree" "add" "--detach" (namestring worktree) commit)
    (unwind-protect
         (build-image config worktree image)
      (ignore-errors (git "worktree" "remove" "--force" (namestring worktree)))
      (ignore-errors (uiop:delete-directory-tree worktree
                                                 :validate (constantly t)))
      (ignore-errors (git "worktree" "prune")))))

(defun rebuild-generation-image (config record &optional lock)
  "Rebuild RECORD's image from its genome commit and return the image path.
Signals on failure (no commit recorded, git/build error). When LOCK is given it
is held for the duration: the rebuild's `git worktree` ops mutate the genome
repo, so they must serialize against a concurrent BUILD-GENERATION (which holds
the same lock) to avoid two git processes racing on `.git/index.lock`."
  (if lock
      (bt:with-lock-held (lock) (%rebuild-generation-image config record))
      (%rebuild-generation-image config record)))

(defun ensure-generation-image (config record &optional lock)
  "Return T if RECORD's image file exists, or rebuild it from the genome commit
and return T; NIL if it is missing and cannot be rebuilt. A missing image is no
longer a dead end (M5-1). The cheap present-image path takes no lock; only an
actual rebuild serializes on LOCK (see REBUILD-GENERATION-IMAGE)."
  (cond
    ((and record (probe-file (generation-image-path record))) t)
    ((or (null record) (null (pget record :commit))) nil)
    (t (handler-case (progn (rebuild-generation-image config record lock) t)
         (error (c)
           (format t "~&[ourro] rebuild of ~A failed (~A); not available.~%"
                   (pget record :id) c)
           (finish-output)
           nil)))))

(defun good-generations-newest-first (&optional (ledger (read-ledger)))
  "The ledger's :good generation records, newest first (records append oldest
→ newest, so reverse). A pure ledger read; no image or git side effects."
  (remove-if-not (lambda (record) (eq (pget record :status) :good))
                 (reverse (ledger-generations ledger))))

(defun find-bootable-generation (config supervision preferred &key allow-non-good)
  "Return the first generation whose image exists or can be rebuilt from its
genome commit — PREFERRED first, then every other :good generation newest-first
— or NIL if nothing at all is bootable. Rebuilds serialize on the build lock
(see ENSURE-GENERATION-IMAGE). This is the boot/crash pre-spawn guard (D1): a
preferred image that is missing *and* unrebuildable no longer dooms the
supervisor to exec a nonexistent binary; we fall back to an older generation the
genome can still reconstruct, and only give up when the whole ledger is
unbootable (which the caller turns into a clean fatal exit rather than an
unhandled LAUNCH-PROGRAM crash).

On an *involuntary* boot (cold start, crash reboot) PREFERRED must be :good — a
quarantined/failed record whose image happens to survive on disk must not boot
just because the fallback list is :good-only (F-7). A *deliberate* target (a
/travel handoff, which may legitimately visit a quarantined generation
read-only) is honored via ALLOW-NON-GOOD. A record with no :status is a
directly-supplied one the caller vouches for, so only an explicit non-:good
status disqualifies it."
  (let* ((lock (build-lock supervision))
         (preferred-id (and preferred (pget preferred :id)))
         (preferred
           (and preferred
                (let ((status (pget preferred :status)))
                  (or (null status)
                      (eq status :good)
                      ;; Museum travel may inspect a quarantined historical
                      ;; image read-only. An :ACTIVATION-PENDING proof-gated
                      ;; build is never bootable, even by explicit travel.
                      (and allow-non-good (eq status :quarantined))))
                preferred)))
    (dolist (record (cons preferred
                          (remove preferred-id (good-generations-newest-first)
                                  :key (lambda (r) (pget r :id))
                                  :test #'equal))
                    nil)
      (when (and record (ensure-generation-image config record lock))
        (return record)))))


(defun apply-genome-changes (changes)
  "Apply a list of (:path REL :content STR) / (:path REL :delete t) plists
inside the genome repo. Paths are confined to the repo."
  (dolist (change changes)
    (let* ((rel (pget change :path))
           (path (merge-pathnames rel (genome-dir))))
      (when (or (uiop:absolute-pathname-p rel)
                (search ".." rel))
        (error 'protocol-error
               :message (format nil "genome path escapes repo: ~S" rel)))
      (if (pget change :delete)
          (when (probe-file path) (delete-file path))
          (progn
            (ensure-directories-exist path)
            (with-open-file (out path :direction :output
                                      :if-exists :supersede
                                      :if-does-not-exist :create)
              (write-string (pget change :content "") out)))))))

(defun install-transition (transaction-id status &rest fields)
  (ourro.txn:append-wal-record
   (install-wal-path)
   (list* :schema-version 1
          :record-kind :generation-install
          :transaction-id transaction-id
          :status status
          :time (iso-time)
          fields)))

(defun install-records (&optional transaction-id)
  "Read and crash-tail-repair the install WAL. Interior corruption propagates."
  (multiple-value-bind (records health)
      (ourro.txn:recover-wal (install-wal-path))
    (declare (ignore health))
    (if transaction-id
        (remove-if-not
         (lambda (record)
           (equal transaction-id (pget record :transaction-id)))
         records)
        records)))

(defun install-status-record (records status)
  (find status records :key (lambda (record) (pget record :status))
                       :from-end t))

(defun next-install-generation-number (ledger records)
  "Allocate beyond both the ledger and durable but unfinished reservations."
  (1+ (max (1- (next-generation-number ledger))
           (reduce #'max records :initial-value 0
                   :key (lambda (record) (pget record :number 0))))))

(defun proved-gene-change-p (change source-hash)
  "Whether CHANGE is the one ordinary gene file authorized by SOURCE-HASH."
  (let ((path (pget change :path))
        (content (and (not (pget change :delete)) (pget change :content))))
    (and (stringp path)
         (string-prefix-p "genes/" path)
         (string-suffix-p ".gene" path)
         (not (uiop:absolute-pathname-p path))
         (not (search ".." path))
         (stringp content)
         (string= source-hash (ourro.txn:sha256-string content)))))

(defun expected-manifest-source-with-gene (gene-path)
  "Compute the only manifest update an ordinary proved gene install may carry."
  (let* ((manifest (read-sexp-file (merge-pathnames "manifest.sexp" (genome-dir))
                                    (list :generation 1 :genes '())))
         (genes (copy-list (pget manifest :genes)))
         (new-genes (append genes
                            (unless (member gene-path genes :test #'equal)
                              (list gene-path)))))
    (print-readable-to-string
     (list :generation (1+ (or (pget manifest :generation) 1))
           :genes new-genes))))

(defun proved-install-change-set-p (artifact changes)
  "Authorize the complete normalized install request, not merely one member.

An ordinary proof may install exactly its source file and, optionally, the
deterministic manifest update naming that file. Deletions, a second gene, an
arbitrary manifest, or any other path require a different proof kind."
  (let* ((source-hash (pget artifact :source-hash))
         (gene-changes
           (remove-if-not (lambda (change)
                            (proved-gene-change-p change source-hash))
                          changes)))
    (when (= 1 (length gene-changes))
      (let* ((gene-change (first gene-changes))
             (gene-path (pget gene-change :path))
             (remaining (remove gene-change changes :count 1 :test #'eq)))
        (or (null remaining)
            (and (= 1 (length remaining))
                 (let ((manifest-change (first remaining)))
                   (and (equal "manifest.sexp" (pget manifest-change :path))
                        (not (pget manifest-change :delete))
                        (stringp (pget manifest-change :content))
                        (string= (expected-manifest-source-with-gene gene-path)
                                 (pget manifest-change :content))))))))))

(defun require-install-proof (transaction-id proof-hash changes)
  "Fail closed unless PROOF-HASH authorizes TX and the complete change set."
  (unless (and (stringp transaction-id) (plusp (length transaction-id))
               (stringp proof-hash) (plusp (length proof-hash)))
    (error 'protocol-error
           :message "generation install requires transaction-id and proof-hash"))
  (let ((path (ourro.txn:verification-artifact-path proof-hash)))
    (unless (probe-file path)
      (error 'protocol-error
             :message (format nil "verification proof is not persisted: ~A"
                              proof-hash)))
    (let ((artifact (ourro.txn:read-verification-artifact path)))
      (unless (and (ourro.txn:verification-artifact-valid-p artifact)
                   (equal proof-hash (pget artifact :proof-hash))
                   (equal transaction-id (pget artifact :transaction-id))
                   (proved-install-change-set-p artifact changes))
        (error 'protocol-error
               :message "verification proof does not authorize this complete install change set"))
      artifact)))

(defun build-generation (changes &key message provenance parent
                                     transaction-id proof-hash)
  "The one entry point for creating gen N+1. Returns the new record.

Production installs carry TRANSACTION-ID and PROOF-HASH. They are proof-gated,
write-ahead logged, crash-tail repairable, and idempotent: retrying the same
transaction resumes from its last durable phase and never creates a second
generation. Calls with neither value retain the trusted local/admin seam used
by initialization and focused tests; supplying only one is always rejected."
  (let ((transactional (or transaction-id proof-hash)))
    (when transactional
      (require-install-proof transaction-id proof-hash changes))
    (let* ((config (read-config))
           (ledger (read-ledger))
           (all-records (and transactional (install-records)))
           (records (and transactional
                         (remove-if-not
                          (lambda (record)
                            (equal transaction-id
                                   (pget record :transaction-id)))
                          all-records)))
           (registered (and records
                            (install-status-record records :ledger-registered))))
      ;; A reply may have been lost after the durable install. The exact same
      ;; request returns the original generation rather than allocating N+1.
      (when registered
        (let ((prepared (install-status-record records :prepared)))
          (unless (and (equal proof-hash (pget prepared :proof-hash))
                       (equal (ourro.txn:canonical-hash changes)
                              (pget prepared :changes-hash)))
            (error 'protocol-error
                   :message "transaction id was reused for a different install request")))
        ;; Promotion may have happened after the original reply was lost.  In
        ;; that case return the authoritative live ledger record (now :GOOD),
        ;; not the historical :ACTIVATION-PENDING snapshot embedded in the
        ;; :LEDGER-REGISTERED frame.
        (let* ((registered-record (pget registered :record))
               (live-record
                 (generation-record (read-ledger)
                                    (pget registered-record :id))))
          (return-from build-generation (or live-record registered-record))))
      (let* ((prepared (and records (install-status-record records :prepared)))
             (number (if prepared
                         (pget prepared :number)
                         (if transactional
                             (next-install-generation-number ledger all-records)
                             (next-generation-number ledger))))
             (id (if prepared (pget prepared :generation-id)
                     (generation-id number)))
             (parent-id (if prepared (pget prepared :parent)
                            (or parent (ledger-current ledger))))
             (image-rel (if prepared (pget prepared :image)
                            (format nil "images/~A" id)))
             (previous-commit
               (if prepared (pget prepared :previous-commit)
                   (trim (git "rev-parse" "HEAD"))))
             (changes-hash (ourro.txn:canonical-hash changes))
             (committed (and records
                             (install-status-record records :genome-committed)))
             (image-built (and records
                               (install-status-record records :image-built))))
        (when prepared
          (unless (and (equal proof-hash (pget prepared :proof-hash))
                       (equal changes-hash (pget prepared :changes-hash)))
            (error 'protocol-error
                   :message "transaction id was reused for a different install request")))
        ;; Write intent before the first mutation. The full change-set is kept
        ;; so a supervisor recovery pass has all inputs needed to resume.
        (when (and transactional (null prepared))
          (install-transition
           transaction-id :prepared
           :proof-hash proof-hash :changes-hash changes-hash :changes changes
           :message (or message "evolution") :provenance provenance
           :parent parent-id :previous-commit previous-commit
           :number number :generation-id id :image image-rel))
        (handler-case
            (let ((commit (and committed (pget committed :commit))))
              (unless committed
                ;; A crash after a filesystem write but before the commit/WAL
                ;; is replayed from the recorded pre-install commit.
                (when transactional
                  (git "reset" "--hard" previous-commit)
                  (git "clean" "-fd"))
                (apply-genome-changes changes)
                (setf commit
                      (git-commit-all (format nil "~A: ~A" id
                                              (or message "evolution"))))
                (pin-generation-commit id commit)
                (when transactional
                  (install-transition transaction-id :genome-committed
                                      :proof-hash proof-hash :number number
                                      :generation-id id :commit commit)))
              ;; An earlier failed attempt restores HEAD. Reattach the exact
              ;; pinned genome commit before resuming its image/ledger phases.
              (when (and transactional
                         (not (string= commit (trim (git "rev-parse" "HEAD")))))
                (git "reset" "--hard" commit)
                (git "clean" "-fd"))
              (unless image-built
                (build-image config (genome-dir)
                             (merge-pathnames image-rel (ourro-home)))
                (when transactional
                  (install-transition transaction-id :image-built
                                      :proof-hash proof-hash :number number
                                      :generation-id id :commit commit
                                      :image image-rel)))
              (let* ((existing (generation-record (read-ledger) id))
                     (record
                       (or existing
                           (list :id id :number number :parent parent-id
                                 :commit commit
                                 :created (iso-time)
                                 ;; A proof-gated build is not bootable yet.
                                 ;; The live old image must first graduate the
                                 ;; hot-loaded gene's probation and explicitly
                                 ;; promote this exact transaction.
                                 :status (if transactional
                                             :activation-pending
                                             :good)
                                 :message (or message "evolution")
                                 :provenance provenance
                                 :install-transaction transaction-id
                                 :verification-proof proof-hash
                                 :kernel-hash (kernel-source-hash)
                                 :image image-rel))))
                (when (and existing
                           (not (equal transaction-id
                                       (pget existing :install-transaction))))
                  (error 'protocol-error
                         :message (format nil "generation id collision at ~A" id)))
                (unless existing
                  (add-generation-record record :make-current nil))
                (when transactional
                  (install-transition transaction-id :ledger-registered
                                      :proof-hash proof-hash :number number
                                      :generation-id id :record record))
                (ignore-errors (prune-images))
                record))
          (error (c)
            (when transactional
              (ignore-errors
               (install-transition transaction-id :aborted
                                   :proof-hash proof-hash
                                   :generation-id id
                                   :reason (princ-to-string c))))
            ;; Restore the genome tree to the pre-attempt commit. Durable
            ;; phase records and the pinned commit allow an exact retry.
            (ignore-errors (git "reset" "--hard" previous-commit))
            (ignore-errors (git "clean" "-fd"))
            (error c)))))))

(defun promote-generation (id transaction-id proof-hash)
  "Make an activation-pending generation bootable after live probation.

The exact generation, install transaction, and immutable proof must agree.
Retries are idempotent."
  (let ((record (generation-record (read-ledger) id)))
    (unless (and record
                 (equal transaction-id (pget record :install-transaction))
                 (equal proof-hash (pget record :verification-proof)))
      (error 'protocol-error
             :message "probation promotion does not match the installed generation proof"))
    (let ((artifact-path (ourro.txn:verification-artifact-path proof-hash)))
      (unless (and (probe-file artifact-path)
                   (let ((artifact
                           (ourro.txn:read-verification-artifact artifact-path)))
                     (and (ourro.txn:verification-artifact-valid-p artifact)
                          (equal transaction-id
                                 (pget artifact :transaction-id)))))
        (error 'protocol-error
               :message "probation promotion proof is missing or invalid")))
    (unless (eq :good (pget record :status))
      (unless (eq :activation-pending (pget record :status))
        (error 'protocol-error
               :message (format nil "generation ~A is not activation-pending"
                                id)))
      (set-generation-status id :good)
      (install-transition transaction-id :probation-passed
                          :proof-hash proof-hash :generation-id id))
    (generation-record (read-ledger) id)))


(defun quarantine-generation (id report)
  (set-generation-status id :quarantined)
  (let ((record (generation-record (read-ledger) id)))
    (write-sexp-file (ourro-path "quarantine/" (format nil "~A.sexp" id))
                     (list :id id
                           :quarantined (iso-time)
                           :parent (and record (pget record :parent))
                           :report report))
    ;; Roll the current pointer back to the nearest good ancestor.
    (let* ((ledger (read-ledger))
           (good (or (let ((parent (and record (pget record :parent))))
                       (let ((parent-record (generation-record ledger parent)))
                         (and parent-record
                              (eq (pget parent-record :status) :good)
                              parent-record)))
                     (latest-good-generation ledger))))
      (when good
        (set-current-generation (pget good :id)))
      good)))


(defvar *spawn-agent-hook* nil
  "Test seam: when bound, called as (fn image-path arguments) and must
return a UIOP process-info. Lets tests supervise a stub instead of a
real image.")

(defclass supervision ()
  ((last-heartbeat :initform (get-universal-time) :accessor last-heartbeat)
   (agent-said-hello :initform nil :accessor agent-said-hello)
   (booted-from-checkpoint :initform nil :accessor booted-from-checkpoint
                           :documentation "Did the running boot resume a crash
checkpoint (M4-1)? Set at spawn, cleared by the agent's :checkpoint-superseded
message once a recovered session survives a turn. Read on crash to decide
whether the checkpoint is poison. Lives here — not as a supervise-loop local —
because the server thread (handle-agent-message) must be able to clear it.")
   (restart-timer :initform nil :accessor restart-timer
                  :documentation "GET-INTERNAL-REAL-TIME captured when a
session-restoring respawn (handoff or crash-checkpoint resume) is launched, or
NIL for a cold boot. When the new agent says :hello — by which point
RESTORE-SESSION has already run — the round-trip is measured and logged (PR-5,
M5-3). Same process on both ends, so the monotonic clock is comparable.

D4: accessed unlocked across threads. The supervise loop is the sole writer of
the *armed* value; the server thread only reads it and writes NIL to clear
(NOTE-RESTART-LATENCY, on :hello). Safe by publication: the arming write
happens-before the spawn, which happens-before the agent's :hello, so the reader
always sees the armed value. Worst case under an unlucky interleaving is one
lost or stale latency *measurement* — a diagnostic, never a correctness
invariant — the same publish-before-spawn discipline as AGENT-SAID-HELLO.")
   (last-restart-seconds :initform nil :accessor last-restart-seconds
                         :documentation "The most recent measured
respawn→session-restored latency in seconds (PR-5), for surfacing/testing.")
   (pending-handoff :initform nil :accessor pending-handoff)
   (stopping :initform nil :accessor stopping-p)
   (process :initform nil :accessor agent-process)
   (build-lock :initform (bt:make-lock "ourro-build")
               :reader build-lock
               :documentation "Serializes generation builds: concurrent
builds would race on the genome git repo and the ledger.")))

(defun spawn-agent (record &key resume visiting)
  (let* ((image (generation-image-path record))
         (arguments (append (list "--generation" (pget record :id)
                                  "--socket" (namestring (socket-path)))
                            (when resume (list "--resume" (namestring resume)))
                            (when visiting (list "--visiting")))))
    (if *spawn-agent-hook*
        (funcall *spawn-agent-hook* image arguments)
        (uiop:launch-program (cons (namestring image) arguments)
                             :input :interactive
                             :output :interactive
                             :error-output
                             (namestring (ourro-path "state/agent-stderr.log"))))))

(defun elapsed-seconds (start &optional (now (get-internal-real-time)))
  "Wall-clock seconds between two GET-INTERNAL-REAL-TIME readings (pure)."
  (/ (float (- now start) 1.0d0) internal-time-units-per-second))

(defun session-restoring-respawn-p (resume visiting)
  "True when a respawn carries a session to restore — a handoff or a
crash-checkpoint resume, but not a read-only visit. This is the case the PR-5
restart budget times (M5-3); a cold boot or a visit restores nothing. Pure."
  (and resume (not visiting) t))

(defun note-restart-latency (supervision)
  "If this boot was a session-restoring respawn, measure and log how long the
round-trip to a live, restored session took (PR-5, M5-3). Called on :hello,
after which RESTORE-SESSION has run. Idempotent — clears the timer."
  (let ((start (restart-timer supervision)))
    (when start
      (let ((seconds (elapsed-seconds start)))
        (setf (last-restart-seconds supervision) seconds
              (restart-timer supervision) nil)
        (format t "~&[ourro] session restored in ~,2Fs~@[ (budget 2s: ~A)~].~%"
                seconds (if (<= seconds 2) "ok" "over"))
        (finish-output)))))

(defun handle-agent-message (supervision message connection)
  "Protocol handler. Returns the reply plist or NIL (no reply)."
  (setf (last-heartbeat supervision) (get-universal-time))
  (case (first message)
    (:hello (setf (agent-said-hello supervision) t)
            (note-restart-latency supervision)
            (list :ok))
    (:heartbeat nil)
    ;; A recovered session survived a turn and wrote a fresh checkpoint (M4-1
    ;; review #1). Its resumed state is proven healthy, so stop treating this
    ;; boot's checkpoint as poison — a later, unrelated crash must resume the
    ;; fresh checkpoint rather than discard it.
    (:checkpoint-superseded
     (setf (booted-from-checkpoint supervision) nil)
     nil)
    (:list-generations
     (list :ok :ledger (read-ledger)))
    (:propose-generation
     ;; Build on a worker thread and reply from there. The server loop must
     ;; keep reading heartbeats during the (possibly minutes-long) build —
     ;; a synchronous build here starves LAST-HEARTBEAT and the monitor
     ;; kills a perfectly healthy agent as "hung".
     (let ((payload (rest message)))
       (bt:make-thread
        (lambda ()
          (let ((reply
                  (bt:with-lock-held ((build-lock supervision))
                    (handler-case
                        (let ((record (build-generation
                                       (pget payload :changes)
                                       :message (pget payload :message)
                                       :provenance (pget payload :provenance)
                                       :transaction-id
                                       (pget payload :transaction-id)
                                       :proof-hash
                                       (pget payload :proof-hash))))
                          (list :generation-built :id (pget record :id)))
                      (error (c)
                        (list :build-failed
                              :report (format nil "~A~@[~%~A~]"
                                              c
                                              (and (typep c 'ourro.kernel:generation-build-failure)
                                                   (ourro.kernel:generation-build-failure-report c)))))))))
            (handler-case
                (progn
                  (ourro.kernel:protocol-send connection reply)
                  ;; Reply acknowledgement is a distinct durable phase: a
                  ;; retry after a lost connection can distinguish "installed"
                  ;; from "agent definitely received the result".
                  (when (and (eq (first reply) :generation-built)
                             (pget payload :transaction-id))
                    (install-transition
                     (pget payload :transaction-id) :reply-acknowledged
                     :proof-hash (pget payload :proof-hash)
                     :generation-id (pget (rest reply) :id))))
              ;; A lost reply (F-6) leaves the agent blocked forever on a
              ;; :generation-built it will never read — trace it rather than
              ;; discarding it under a bare IGNORE-ERRORS.
              (error (c)
                (supervisor-log "failed to send ~A reply to agent (~A); ~
it may wait indefinitely for a build result"
                                (first reply) c)))))
        :name "ourro-generation-build"))
     nil)
    (:promote-generation
     (let* ((payload (rest message))
            (record
              (promote-generation
               (pget payload :id)
               (pget payload :transaction-id)
               (pget payload :proof-hash))))
       (list :ok :id (pget record :id) :status (pget record :status))))
    (:handoff
     ;; Durable acceptance precedes agent exit. The reply is the acknowledgement
     ;; that lets the agent retire its crash checkpoint.
     (setf (pending-handoff supervision)
           (list :generation (pget (rest message) :generation)
                 :state-file (pget (rest message) :state-file)
                 :hard (pget (rest message) :hard)
                 :visiting (pget (rest message) :visiting)))
     (list :ok))
    (:make-current
     ;; A calm/manual user quit with a generation built but never booted (the
     ;; restart deferred). Advance the ledger so the next `ourro run` starts it
     ;; (M12-2). A notification — the agent exits right after and reads no reply.
     (let* ((id (pget (rest message) :id))
            (ledger (read-ledger))
            (previous-id (ledger-current ledger))
            (record (and id (generation-record ledger id))))
       (when (and record (eq :good (pget record :status)))
         (let ((transaction-id (pget record :install-transaction)))
           ;; Persist intent before moving the boot pointer.  If the final WAL
           ;; marker fails, restore the previous pointer and surface the error
           ;; instead of silently leaving an unjournalled activation behind.
           (when transaction-id
             (install-transition
              transaction-id :activation-commit-prepared
              :proof-hash (pget record :verification-proof)
              :generation-id id :previous-generation previous-id))
           (set-current-generation id)
           (when transaction-id
             (handler-case
                 (install-transition
                  transaction-id :committed-active
                  :proof-hash (pget record :verification-proof)
                  :generation-id id :previous-generation previous-id)
               (error (c)
                 (ignore-errors (set-current-generation previous-id))
                 (error c)))))))
     nil)
    (:quit
     (setf (stopping-p supervision) t)
     (list :ok))
    (t (list :error :message (format nil "unknown message: ~S" (first message))))))

(defun handle-agent-message-safely (supervision message connection)
  "Contain one request failure so a fail-closed protocol error does not tear
down the agent's long-lived control connection."
  (handler-case
      (handle-agent-message supervision message connection)
    (error (condition)
      (supervisor-log "rejected ~A request: ~A" (first message) condition)
      (list :error :message (princ-to-string condition)))))

(defparameter *heartbeat-timeout* 20
  "Seconds without a heartbeat before the agent is declared hung.")

(defparameter *crash-window* 120
  "Two crashes of one generation within this window trigger quarantine.")

(defun monitor-agent (supervision process)
  "Block until PROCESS exits or hangs. Returns (values exit-code hung-p)."
  (loop
    (unless (uiop:process-alive-p process)
      (return (values (uiop:wait-process process) nil)))
    (when (and (agent-said-hello supervision)
               (> (- (get-universal-time) (last-heartbeat supervision))
                  *heartbeat-timeout*))
      (uiop:terminate-process process :urgent t)
      (uiop:wait-process process)
      (return (values nil t)))
    (sleep 0.25)))

(defun supervise (&key once)
  "The main supervision loop. ONCE limits to a single spawn (tests)."
  (let* ((supervision (make-instance 'supervision))
         (server (make-protocol-server (socket-path)))
         (server-thread
           (bt:make-thread
            (lambda ()
              ;; The control plane is supervised too.  A malformed peer or an
              ;; accept-loop error must not permanently remove heartbeats and
              ;; build/handoff handling while the agent keeps running.
              (loop until (stopping-p supervision)
                    do (let ((active server))
                         (handler-case
                             (protocol-serve
                              active
                              (lambda (message connection)
                                (handle-agent-message-safely supervision message
                                                             connection))
                              :stop-p (lambda () (stopping-p supervision))
                              ;; No connection means no heartbeats can arrive;
                              ;; disarm only the hung check until reconnect.
                              :on-disconnect
                              (lambda ()
                                (setf (agent-said-hello supervision) nil)))
                           (error (c)
                             (unless (stopping-p supervision)
                               (supervisor-log
                                "protocol server failed (~A); recreating control socket"
                                c))))
                         (ignore-errors
                          (sb-bsd-sockets:socket-close active))
                         (ignore-errors (delete-file (socket-path)))
                         (unless (stopping-p supervision)
                           (sleep 0.1)
                           (handler-case
                               (setf server
                                     (make-protocol-server (socket-path)))
                             (error (c)
                               (supervisor-log
                                "control socket recreation failed (~A); retrying"
                                c)
                               (sleep 0.5)))))))
            :name "ourro-supervisor-server"))
         (config (read-config))
         (crashes '())                 ; (generation-id . universal-time)
         (resume nil)
         (resume-is-checkpoint nil)    ; is RESUME the crash checkpoint? (M4-1)
         (visiting nil)
         ;; Did a /travel handoff pick RECORD? Then it is a deliberate target and
         ;; may be non-:good (visiting a quarantined generation is allowed), so
         ;; FIND-BOOTABLE-GENERATION must not reject it (F-7). Cold/crash boots
         ;; leave this nil and always use a :good record.
         (deliberate-target nil)
         ;; Self-heal a home bricked by a prior crash/probation cascade (e.g. the
         ;; seed was quarantined because the API key was mis-set). INIT runs this
         ;; too, but a plain `ourro run` must not dead-end at "no good generation
         ;; to boot" when the genome tip is rebuildable — otherwise the user has
         ;; to re-init to recover. Runs once, before the loop: if the healed
         ;; generation is genuinely broken it re-quarantines on the next boot and
         ;; the crash path fatals cleanly (no infinite un-quarantine loop).
         (record (or (latest-good-generation)
                     (progn (ignore-errors (ensure-bootable-generation config))
                            (latest-good-generation))
                     (error "no good generation to boot"))))
    ;; Reclaim disk from superseded generation images before the first boot
    ;; and after every new one (M4-4).
    (ignore-errors (prune-images))
    ;; GC any worktrees stranded by an interrupted rebuild (D2). Safe here:
    ;; runs before the first agent spawn, and a rebuild only happens in the
    ;; pre-spawn guard or while servicing an agent — neither of which can be in
    ;; flight yet (the server thread is up but has no agent to talk to) — so no
    ;; live worktree is ever swept.
    (ignore-errors (sweep-stale-worktrees))
    (unwind-protect
         (loop
           (setf (last-heartbeat supervision) (get-universal-time)
                 (agent-said-hello supervision) nil
                 (pending-handoff supervision) nil)
           ;; Self-heal a pruned/missing image before spawning it (M5-1): boot
           ;; and post-crash paths rebuild from the genome commit rather than
           ;; exec a file that isn't there. If the preferred generation can be
           ;; neither found nor rebuilt, fall back to an older bootable one
           ;; rather than swallow the failure and exec a nonexistent binary
           ;; (D1); only a wholly unbootable ledger is fatal, and that unwinds
           ;; cleanly through MAIN's handler → "[ourro] fatal:" + exit 70.
           (let ((bootable (find-bootable-generation
                            config supervision record
                            :allow-non-good deliberate-target)))
             (unless bootable
               (error "no generation image exists or can be rebuilt; ~
refusing to spawn"))
             (unless (equal (pget bootable :id) (pget record :id))
               (format t "~&[ourro] ~A image unavailable; booting ~A instead.~%"
                       (pget record :id) (pget bootable :id))
               (finish-output))
             (setf record bootable))
           ;; Consumed for this boot; the branches below re-arm it if the next
           ;; iteration boots a deliberate /travel target.
           (setf deliberate-target nil)
           ;; Time the round-trip when this respawn carries a session to restore
           ;; (handoff or crash-checkpoint resume) — the PR-5 restart budget is
           ;; measured, not assumed (M5-3). A cold boot has nothing to restore.
           (setf (restart-timer supervision)
                 (and (session-restoring-respawn-p resume visiting)
                      (get-internal-real-time)))
           (let ((process (spawn-agent record :resume resume
                                              :visiting visiting)))
             (setf (agent-process supervision) process
                   ;; Latch whether this boot resumed a checkpoint; the agent
                   ;; clears it via :checkpoint-superseded once a turn proves
                   ;; the resumed state healthy (M4-1 review #1).
                   (booted-from-checkpoint supervision) resume-is-checkpoint
                   resume nil
                   resume-is-checkpoint nil
                   visiting nil)
             (multiple-value-bind (code hung-p)
                 (monitor-agent supervision process)
               (cond
                 ;; Clean user quit.
                 ((and (eql code 0) (not hung-p))
                  (return :quit))
                 ;; Handoff into another generation. The :handoff message
                 ;; races the exit code — give the server thread a moment
                 ;; to drain it from the socket before deciding.
                 ((and (eql code 75)
                       (or (pending-handoff supervision)
                           (loop repeat 20
                                 do (sleep 0.1)
                                 when (pending-handoff supervision)
                                   return it)))
                  (let* ((handoff (pending-handoff supervision))
                         (target (generation-record (read-ledger)
                                                    (pget handoff :generation))))
                    (cond
                      ((null target)
                       (format t "~&[ourro] handoff to unknown generation ~A; ~
rebooting current.~%" (pget handoff :generation))
                       (finish-output)
                       (setf resume (pget handoff :state-file)))
                      ;; Its image may have been GC'd (M4-4). Rebuild it from
                      ;; the genome commit on demand (M5-1); only refuse if the
                      ;; rebuild itself fails, rather than spawn a missing binary.
                      ((not (ensure-generation-image
                             config target (build-lock supervision)))
                       (format t "~&[ourro] generation ~A image is missing and ~
could not be rebuilt; rebooting current.~%"
                               (pget handoff :generation))
                       (finish-output)
                       (setf resume (pget handoff :state-file)))
                      (t
                       (setf record target
                             resume (pget handoff :state-file)
                             visiting (pget handoff :visiting)
                             ;; A deliberate target may be quarantined (a
                             ;; read-only visit) — tell the pre-spawn guard to
                             ;; honor it rather than fall back (F-7).
                             deliberate-target t)
                       (when (pget handoff :hard)
                         (set-current-generation (pget target :id)))
                       (unless (pget handoff :visiting)
                         (unless (eq (pget target :status) :quarantined)
                           (set-current-generation (pget target :id))))))))
                 ;; Configuration/environment error (exit 78 = EX_CONFIG): the
                 ;; agent's CODE is fine — the environment is misconfigured
                 ;; (missing API key/model, no GCP project). Re-running can't fix
                 ;; it, and quarantining would brick the home for a mis-set env
                 ;; var. Surface the agent's own message (already in
                 ;; agent-stderr.log) and stop cleanly, WITHOUT counting a crash
                 ;; or quarantining.
                 ((and (eql code 78) (not hung-p))
                  (format t "~&[ourro] ~A could not start: configuration error ~
(see the message above). Nothing was quarantined — fix your environment (e.g. ~
set OURRO_BEDROCK_API_KEY / OURRO_MODEL) and run `ourro` again.~%"
                          (pget record :id))
                  (finish-output)
                  (return :config-error))
                 ;; Crash (or hang): maybe quarantine, then reboot last-good.
                 (t
                  (let ((id (pget record :id))
                        (now (get-universal-time)))
                    (push (cons id now) crashes)
                    (let ((recent (count-if
                                   (lambda (crash)
                                     (and (equal (car crash) id)
                                          (< (- now (cdr crash)) *crash-window*)))
                                   crashes)))
                      (format t "~&[ourro] agent ~A ~A (crash #~A in window).~%"
                              id
                              (if hung-p "hung" (format nil "exited ~A" code))
                              recent)
                      (finish-output)
                      (when (>= recent 2)
                        (quarantine-generation
                         id (list :exit-code code :hung hung-p
                                  :time (iso-time)))
                        (setf crashes (remove id crashes
                                              :key #'car :test #'equal))))
                    (setf record (or (latest-good-generation)
                                     (error "no good generation left")))
                    ;; Crash recovery (M4-1): resume the checkpoint the agent
                    ;; wrote, but at most once. If the boot that just crashed
                    ;; was itself a checkpoint resume, the checkpoint is
                    ;; presumed poisonous and set aside — a bad checkpoint must
                    ;; never drive an infinite crash loop.
                    (let ((cp (checkpoint-path)))
                      (case (crash-resume-plan
                             (booted-from-checkpoint supervision)
                             (and (probe-file cp) t))
                        (:resume-checkpoint
                         (setf resume cp resume-is-checkpoint t)
                         (format t "~&[ourro] resuming session from crash ~
checkpoint.~%"))
                        (:poison
                         (when (probe-file cp)
                           (ignore-errors
                            (sb-posix:rename
                             (namestring cp)
                             (namestring (poisoned-checkpoint-path)))))
                         (format t "~&[ourro] checkpoint resume crashed too — ~
checkpoint set aside; cold boot.~%"))
                        (:cold nil))
                      (finish-output))
                    (sleep 0.5))))
               (when once (return :once)))))
      (setf (stopping-p supervision) t)
      (ignore-errors (sb-bsd-sockets:socket-close server))
      (when (bt:thread-alive-p server-thread)
        (ignore-errors (bt:destroy-thread server-thread)))
      (ignore-errors (bt:join-thread server-thread))
      (ignore-errors (delete-file (socket-path))))))


(defun instance-lock-path () (ourro-path "supervisor.pid"))

(defun process-alive-p (pid)
  (handler-case (progn (sb-posix:kill pid 0) t)
    (sb-posix:syscall-error (c)
      (/= (sb-posix:syscall-errno c) sb-posix:esrch))
    (error () nil)))

(defun acquire-instance-lock ()
  "Claim this OURRO_HOME or error if a live supervisor already owns it.
Returns the lock file path (delete it to release)."
  (let* ((path (instance-lock-path))
         (existing (and (probe-file path)
                        (ignore-errors
                         (parse-integer (trim (uiop:read-file-string path))
                                        :junk-allowed t)))))
    (when (and existing (process-alive-p existing))
      (error "another ourro is already running on ~A (supervisor pid ~A).~%~
Quit it first, or point OURRO_HOME at a different directory for a second instance."
             (ourro-home) existing))
    (with-open-file (out path :direction :output
                              :if-exists :supersede
                              :if-does-not-exist :create)
      (format out "~A~%" (sb-posix:getpid)))
    path))


(defun restore-terminal-after-agent (stream)
  "Undo the agent TUI's terminal state after the agent process died without
running its own teardown (SIGKILL/crash). The agent enters the alternate screen
and hides the cursor (tui:with-raw-terminal) but a killed process never runs
leave-alt-screen, so a supervisor message would land on top of the frozen last
TUI frame and collide with the input-row placeholder (F-crshmsg). Emit the
teardown sequences — leave alt screen, show cursor, reset attrs, disable
bracketed-paste/kitty input — so the message prints on a clean normal-screen
line. A no-op when STREAM isn't a terminal (piped/CI), to avoid spraying escape
codes into a log."
  (when (interactive-stream-p stream)
    (ignore-errors
     ;; ?2004l bracketed-paste off · <u kitty-keys pop · ?1049l leave alt screen
     ;; · ?25h show cursor · 0m reset attrs.
     (format stream "~C[?2004l~C[<u~C[?1049l~C[?25h~C[0m~&"
             #\Esc #\Esc #\Esc #\Esc #\Esc)
     (finish-output stream))))

(defun main ()
  (let ((args (uiop:command-line-arguments)))
    (handler-case
        (cond
          ((equal (first args) "init")
           (let ((source (second (member "--source-dir" args :test #'equal))))
             (ensure-initialized :source-dir source
                                 :force (member "--force" args :test #'equal)
                                 :rebuild (member "--rebuild" args :test #'equal))
             (format t "~&[ourro] initialized at ~A~%" (ourro-home))))
          ((or (null args) (equal (first args) "run"))
           (let ((config (read-config)))
             (ensure-base-core config)
             (let ((lock (acquire-instance-lock)))
               (unwind-protect
                    ;; Once the agent owns the terminal (alt screen), any
                    ;; supervisor print would corrupt it — log to a file.
                    (with-open-file (log (ourro-path "state/supervisor.log")
                                         :direction :output
                                         :if-exists :append
                                         :if-does-not-exist :create)
                      (let ((*standard-output* log)
                            (*error-output* log))
                        (format log "~&[ourro] supervisor start ~A pid ~A~%"
                                (iso-time) (sb-posix:getpid))
                        (finish-output log)
                        (supervise)))
                 (ignore-errors (delete-file lock))))))
          ((equal (first args) "status")
           (let ((ledger (read-ledger)))
             (format t "~&current: ~A~%~{  ~{~A ~A ~A~}~%~}"
                     (ledger-current ledger)
                     (mapcar (lambda (record)
                               (list (pget record :id)
                                     (pget record :status)
                                     (pget record :message)))
                             (ledger-generations ledger)))))
          (t (format t "~&usage: ourro [init --source-dir DIR | run | status]~%")
             (uiop:quit 64)))
      (error (c)
        (restore-terminal-after-agent *error-output*)
        (format *error-output* "~&[ourro] fatal: ~A~%" c)
        (uiop:quit 70)))
    (uiop:quit 0)))
