
(defpackage #:ourro.reflex.briefing
  (:use #:cl #:ourro.util)
  (:export #:classify-job-failure
           #:collect-job-failure-evidence
           #:fallback-briefing-text
           #:produce-job-failure-briefing
           #:briefing-from-effect-input
           #:find-briefing-by-key
           #:workspace-residue-manifest
           #:+maximum-evidence-log-chars+))

(in-package #:ourro.reflex.briefing)

(defparameter +maximum-evidence-log-chars+ 64000)

(defun split-null-delimited (text)
  (loop with start = 0
        for end = (position (code-char 0) text :start start)
        while end
        when (> end start) collect (subseq text start end)
        do (setf start (1+ end))))

(defun workspace-files (root)
  (labels ((walk (directory)
             (append
              (mapcar (lambda (path)
                        (enough-namestring path root))
                      (or (ignore-errors (uiop:directory-files directory)) '()))
              (mapcan
               (lambda (subdirectory)
                 (let ((name (first (last (pathname-directory subdirectory)))))
                   (unless (string= name ".git") (walk subdirectory))))
               (or (ignore-errors (uiop:subdirectories directory)) '())))))
    (sort (walk root) #'string<)))

(defun git-paths (root arguments)
  (when (probe-file (merge-pathnames ".git/" root))
    (ignore-errors
      (split-null-delimited
       (uiop:run-program
        (append (list "git" "-C" (namestring root)) arguments)
        :output :string :error-output nil :ignore-error-status t)))))

(defun workspace-residue-manifest (workspace)
  "Hash tracked content and enumerate untracked paths around an automated path."
  (let* ((root (uiop:ensure-directory-pathname workspace))
         (tracked-paths (git-paths root '("ls-files" "-z")))
         (git-p (not (null (probe-file (merge-pathnames ".git/" root)))))
         (untracked (if git-p
                        (or (git-paths root '("ls-files" "--others"
                                             "--exclude-standard" "-z"))
                            '())
                        (workspace-files root)))
         (tracked
           (mapcar
            (lambda (relative)
              (let ((path (merge-pathnames relative root)))
                (list relative
                      (if (probe-file path)
                          (ourro.txn:sha256-file path)
                          :missing))))
            (or tracked-paths '())))
         (core (list :workspace (ourro.reflex.journal:normalize-workspace root)
                     :tracked tracked :untracked (sort (copy-list untracked)
                                                       #'string<))))
    (append core (list :manifest-hash (ourro.txn:canonical-hash core)))))

(defun bounded-log (event)
  (let ((text (or (pget event :log) (pget event :log-tail) "")))
    (if (> (length text) +maximum-evidence-log-chars+)
        (subseq text (- (length text) +maximum-evidence-log-chars+))
        text)))

(defun contains-ci-p (needle text)
  (search (string-downcase needle) (string-downcase (or text ""))))

(defun classify-job-failure (event)
  "Classify only evidence-backed failure families; never infer a cause."
  (let* ((log (bounded-log event))
         (lower-log (string-downcase log))
        (exit (pget event :exit)))
    (flet ((has (needle) (search needle lower-log)))
    (cond ((or (pget event :deadline)
               (member exit '(:timeout :deadline) :test #'eq)
               (has "timed out")
               (has "timeout"))
           :timeout)
          ((or (pget event :diagnostic-file)
               (has "compiler error")
               (has "compilation failed")
               (has "compile-file-error"))
           :compiler-failure)
          ((or (pget event :failing-test)
               (has "failed")
               (has "failure"))
           :test-failure)
          (t :nonzero-exit)))))

(defun first-matching-line (text needles)
  (find-if (lambda (line)
             (some (lambda (needle) (contains-ci-p needle line)) needles))
           (split-lines text)))

(defun collect-job-failure-evidence (event)
  "Persist the bounded inputs used by deterministic fallback and investigation."
  (let* ((workspace (pget event :workspace))
         (log (bounded-log event))
         (class (classify-job-failure event))
         (record
           (list :record-kind :failure-evidence :kind :failure-evidence
                 :failure-class class
                 :job (pget event :job) :command (pget event :command)
                 :exit (pget event :exit) :log log
                 :failing-test
                 (or (pget event :failing-test)
                     (and (eq class :test-failure)
                          (first-matching-line log '("failed" "failure"))))
                 :diagnostic-file (pget event :diagnostic-file)
                 :diagnostic-line (pget event :diagnostic-line)
                 :diagnostic-code (pget event :diagnostic-code)
                 :source-hash (pget event :source-hash)
                 :deadline (pget event :deadline)
                 :elapsed-ms (pget event :elapsed-ms)
                 :last-progress (pget event :last-progress)
                 :process-outcome (or (pget event :process-outcome)
                                      (pget event :exit))
                 :changed-files (copy-list (pget event :changed-files))
                 :relevant-tests (copy-list (pget event :relevant-tests))
                 :related-failure-ids (copy-list (pget event :related-failure-ids))
                 :tool-call-ids (copy-list (pget event :tool-call-ids))
                 :turn-id (pget event :turn-id)
                 :generation (pget event :generation)
                 :gene (pget event :gene)
                 :causation-id (pget event :event-id)
                 :time (iso-time) :unix (unix-time))))
    (ourro.reflex.journal:append-record record :workspace workspace)))

(defun fallback-briefing-text (evidence)
  "A complete but deliberately non-speculative model-free briefing."
  (let ((id (pget evidence :event-id)))
    (case (pget evidence :failure-class)
      (:test-failure
       (format nil "Test failure. Command: ~A; exit: ~A; failing evidence: ~A; changed files: ~S. No cause was inferred. [evidence:~A]"
               (pget evidence :command) (pget evidence :exit)
               (or (pget evidence :failing-test) "not present in bounded log")
               (or (pget evidence :changed-files) '()) id))
      (:compiler-failure
       (format nil "Compiler failure. Command: ~A; diagnostic: ~A~@[:~A~]~@[ (~A)~]; source hash: ~A. No cause was inferred. [evidence:~A]"
               (pget evidence :command)
               (or (pget evidence :diagnostic-file) "bounded log")
               (pget evidence :diagnostic-line)
               (pget evidence :diagnostic-code)
               (or (pget evidence :source-hash) "unavailable") id))
      (:timeout
       (format nil "Timeout. Deadline: ~A; elapsed-ms: ~A; last progress: ~A; process outcome: ~A. No cause was inferred. [evidence:~A]"
               (or (pget evidence :deadline) "configured job deadline")
               (or (pget evidence :elapsed-ms) "unavailable")
               (or (pget evidence :last-progress) "unavailable")
               (pget evidence :process-outcome) id))
      (t
       (format nil "Job exited non-zero. Command: ~A; exit: ~A. The bounded evidence did not identify a supported failure class, so no cause was inferred. [evidence:~A]"
               (pget evidence :command) (pget evidence :exit) id)))))

(defun find-briefing-by-key (key workspace)
  (find key (ourro.reflex.journal:query-records :workspace workspace
                                               :kind :job-failure-briefing)
        :key (lambda (record) (pget record :idempotency-key))
        :test #'string=))

(defun investigation-prompt (evidence)
  (format nil "Diagnose this failed local job using only read-only tools and cite the supplied evidence ID in every factual claim. Do not make changes. Evidence: ~S"
          evidence))

(defun answer-cites-evidence-p (answer evidence)
  (let ((text (and (listp answer) (pget answer :text)))
        (identity (pget evidence :event-id)))
    (and (stringp text) (stringp identity) (search identity text))))

(defun produce-job-failure-briefing (event &key investigator idempotency-key
                                                provider model limits cost)
  "Create exactly one durable briefing. INVESTIGATOR receives prompt/evidence.
It may return a string or a plist containing :TEXT/:PROVIDER/:MODEL/:COST."
  (let* ((workspace (pget event :workspace))
         (key (or idempotency-key
                  (ourro.txn:canonical-hash
                   (list :job-failure-briefing (pget event :event-id)))))
         (existing (find-briefing-by-key key workspace)))
    (when existing
      (return-from produce-job-failure-briefing (values existing nil)))
    (let* ((evidence (collect-job-failure-evidence event))
           (fallback (fallback-briefing-text evidence))
           (answer (and investigator
                        (handler-case
                            (funcall investigator (investigation-prompt evidence)
                                     evidence)
                          (error () nil))))
           (answer (if (stringp answer) (list :text answer) answer))
           (citation-valid (answer-cites-evidence-p answer evidence))
           (text (if citation-valid (pget answer :text) fallback))
           (record
             (list :record-kind :briefing :kind :job-failure-briefing
                   :idempotency-key key :job (pget event :job)
                   :failure-class (pget evidence :failure-class)
                   :text text :fallback-used (not citation-valid)
                   :citations-accurate (and citation-valid t)
                   :evidence-ids (list (pget evidence :event-id))
                   :prompt (investigation-prompt evidence)
                   :provider (or (and (listp answer) (pget answer :provider)) provider)
                   :model (or (and (listp answer) (pget answer :model)) model)
                   :cost (or (and (listp answer) (pget answer :cost)) cost)
                   :limits (or (and (listp answer) (pget answer :limits)) limits)
                   :investigation-status (and (listp answer) (pget answer :status))
                   :tool-results (copy-tree (and (listp answer)
                                                 (pget answer :tool-results)))
                   :no-changes-made t
                   :causation-id (pget evidence :event-id)
                   :time (iso-time) :unix (unix-time))))
      (values (ourro.reflex.journal:append-record record :workspace workspace)
              t))))

(defun briefing-from-effect-input (input key &key investigator provider model
                                                   limits cost)
  (let ((event
          (or (pget input :event)
              (let ((id (pget input :event-id))
                    (workspace (pget input :event-workspace)))
                (and id workspace
                     (ourro.reflex.journal:find-record id workspace))))))
    (unless (and event (eq :job-exit (pget event :kind)))
      (error "investigation effect does not contain a job-exit event"))
    (produce-job-failure-briefing
     event :investigator investigator :idempotency-key key
     :provider provider :model model :limits limits :cost cost)))
