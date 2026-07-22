
(defpackage #:ourro.main
  (:use #:cl #:ourro.util)
  (:export #:main #:boot))

(in-package #:ourro.main)

(defun option (args name)
  (let ((tail (member name args :test #'string=)))
    (and tail (second tail))))

(defun flag (args name)
  (and (member name args :test #'string=) t))

(defun boot (&key generation socket resume visiting)
  "Start the agent (interactive). GENOME is already loaded into the image."
  (when socket (setf (uiop:getenv "OURRO_SOCKET") socket))
  ;; The workspace is OURRO_WORKSPACE if set, else wherever `ourro run` was
  ;; invoked. *WORKSPACE*'s initform captured the cwd of the IMAGE BUILD
  ;; (save-lisp-and-die bakes it in), so without this reset the agent would
  ;; always work in the ourro source tree no matter which repository the
  ;; user launched it from. OURRO_WORKSPACE (mirroring OURRO_HOME) lets a caller
  ;; pin the workspace explicitly and — because it inherits through every
  ;; supervisor→generation spawn — keeps it stable across seamless restarts;
  ;; the QA harness sets it to an isolated sandbox dir so a spawned agent can
  ;; never write into the real checkout via a relative path (F-wsroot). A
  ;; resumed session's handoff :cwd still overrides this later in RESTORE-SESSION.
  (setf ourro.toolkit:*workspace*
        (let ((ws (uiop:getenv "OURRO_WORKSPACE")))
          (if (and ws (plusp (length ws)))
              (uiop:ensure-directory-pathname (uiop:parse-native-namestring ws))
              (uiop:getcwd))))
  ;; Read-only travel (M4-6): a visiting session may only read files and think.
  ;; Lowering the ceiling makes every capability grant this boot issues — the
  ;; per-tool grant and the turn's blanket grant alike — intersect down to this
  ;; set, so a write/subprocess/network tool signals a clean CAPABILITY-VIOLATION
  ;; the model can see and explain, rather than mutating a past generation.
  (when visiting
    (setf ourro.kernel:*capability-ceiling* '(:filesystem-read :llm)))
  ;; Pick the live provider from the environment: OURRO_MODEL's friendly alias
  ;; chooses both the model and its provider (gemini-3.1-pro → Vertex, opus-4-6 →
  ;; Bedrock), OURRO_PROVIDER can force it, and OURRO_PROVIDER=scripted:<path> swaps
  ;; in a deterministic file-backed provider for the T1 QA tier + soak.
  (let* ((provider (ourro.llm:provider-from-env))
         (payload (and resume (ourro.kernel:read-handoff resume)))
         (agent (ourro.agent:make-agent
                 :provider provider
                 :generation (or generation
                                 (format nil "gen-~4,'0D"
                                         (ourro.genome:genome-generation-number)))
                 :mode (if visiting :manual :auto)
                 :visiting visiting
                 :session-id (and payload (pget payload :session-id)))))
    (ourro.agent:run-agent agent :resume-payload payload)))

(defparameter +replay-begin+ "<<<OURRO-REPLAY")
(defparameter +replay-end+ "OURRO-REPLAY>>>")

(defun replay-mode (events-file)
  "Replay the read-only tool calls recorded in EVENTS-FILE against this image
and print the resulting action traces between sentinel lines (PR-11 kernel
gate, M4-5). The supervisor runs this on both the current and candidate images
and compares the delimited blocks; the sentinels wall the traces off from any
boot/library chatter on the combined output stream."
  (handler-case
      (let* ((events (ourro.util:read-sexp-lines events-file))
             (traces (ourro.verify:replay-session events :limit 50)))
        (format t "~&~A~%" +replay-begin+)
        (with-standard-io-syntax
          (let ((*package* (find-package :keyword)))
            (prin1 traces)))
        (format t "~%~A~%" +replay-end+)
        (finish-output)
        (sb-ext:exit :code 0))
    (error (c)
      (format *error-output* "REPLAY-FAIL: ~A~%" c)
      (sb-ext:exit :code 1))))

(defparameter +verify-begin+ "<<<OURRO-VERIFY")
(defparameter +verify-end+ "OURRO-VERIFY>>>")

(defun write-verdict-file (pathname verdict)
  "Write one canonical verdict to the coordinator-owned result channel."
  (ensure-directories-exist pathname)
  (with-open-file (out pathname :direction :output
                                :if-exists :error
                                :if-does-not-exist :create)
    (write-string (ourro.txn:canonical-encode verdict) out)
    (finish-output out)
    (let ((fd (ignore-errors (sb-sys:fd-stream-fd out))))
      (when fd (sb-posix:fsync fd))))
  pathname)

(defun verify-gene-mode (file &key nonce verdict-file verify-home)
  "Run the gauntlet on the gene source in FILE and emit one verdict.

Production supplies VERDICT-FILE, a channel separate from captured candidate
stdout/stderr. The sentinel stdout form remains only as a developer/backward
compatibility seam. The parent runs this child from its own generation image,
exactly its generation's vintage, so compile/test GC contention remains outside
the interactive image.
Always exits 0 with a verdict; exit 1 only on infrastructure failure."
  (when verify-home
    ;; Built images may contain a cached parent OURRO_HOME. The verifier must
    ;; never let that cache point its coordinator WAL at the live installation.
    (setf ourro.util::*ourro-home*
          (uiop:ensure-directory-pathname verify-home)))
  (handler-case
      (let ((source (uiop:read-file-string file)))
        (let ((verdict
                (handler-case
                    (multiple-value-bind (gene report)
                        (ourro.verify.coordinator:verify-source source)
                      (declare (ignore gene))
                      (list :verdict :pass :nonce nonce
                            :report
                            (ourro.verify.coordinator:encode-report-for-transport
                             report)))
                  (ourro.kernel:verification-failure (c)
                    (list :verdict :fail :nonce nonce
                          :stage (ourro.kernel:verification-failure-stage c)
                          :diagnostics (ourro.kernel:verification-failure-diagnostics c)))
                  (error (c)
                    (list :verdict :fail :nonce nonce
                          :diagnostics (princ-to-string c))))))
          (if verdict-file
              (write-verdict-file verdict-file verdict)
              (progn
                (format t "~&~A~%" +verify-begin+)
                (with-standard-io-syntax
                  (let ((*package* (find-package :keyword))) (prin1 verdict)))
                (format t "~%~A~%" +verify-end+)
                (finish-output)))
          (sb-ext:exit :code 0)))
    (error (c)
      (format *error-output* "VERIFY-FAIL: ~A~%" c)
      (sb-ext:exit :code 1))))

(defun main ()
  (let ((args (uiop:command-line-arguments)))
    (handler-case
        (cond
          ((flag args "--smoke")
           (ourro.agent:smoke-test))
          ((option args "--replay")
           (replay-mode (option args "--replay")))
          ((option args "--verify-gene")
           (verify-gene-mode (option args "--verify-gene")
                             :nonce (option args "--verify-nonce")
                             :verdict-file
                             (option args "--verify-verdict-file")
                             :verify-home (option args "--verify-home")))
          (t
           ;; BOOT → RUN-AGENT yields the process exit code: 75 for a
           ;; handoff/travel (the supervisor exec's the next generation), 0 for
           ;; a clean quit. The single sb-ext:exit lives here so PERFORM-HANDOFF
           ;; stays a pure, testable seam (F-travel).
           (let ((code (boot :generation (option args "--generation")
                             :socket (option args "--socket")
                             :resume (option args "--resume")
                             :visiting (flag args "--visiting"))))
             (sb-ext:exit :code (if (integerp code) code 0)))))
      (error (c)
        (ignore-errors
         (format *error-output* "~&[ourro-agent] fatal: ~A~%" c))
        (sb-ext:exit :code 1)))))
