
(defpackage #:ourro.qa.conductor
  (:use #:cl)
  (:import-from #:ourro.qa.operator
                #:op-spawn #:op-say #:op-kill #:op-collect
                #:read-sexp-file #:pget #:env)
  (:export #:run #:run-one-cycle #:loop-root #:read-state #:write-state
           #:next-mission #:mission-plist #:read-finding
           #:supervise-mission-session #:*max-continue-nudges*))

(in-package #:ourro.qa.conductor)


(defun loop-root ()
  "Durable loop state lives here (EBS-mounted /data in production)."
  (pathname (concatenate 'string
                         (env "OURRO_LOOP_ROOT" "/tmp/ourro-loop") "/")))

(defun repo-root ()
  (pathname (concatenate 'string
                         (env "OURRO_LOOP_REPO"
                              (namestring (ourro.qa.operator::repo-root)))
                         "/")))

(defun daily-cap-usd ()
  (let ((v (env "OURRO_LOOP_DAILY_USD")))
    (and v (ignore-errors (read-from-string v nil nil)))))

(defun loop-model ()
  "Default: Claude Sonnet on Bedrock (the sonnet-4-6 alias) — a fast, cheap
daily-driver that keeps the loop well clear of the opus rate-limit wall (the
opus default was what threw 429s and blew the daily cap mid-mission). Needs
OURRO_BEDROCK_API_KEY / AWS_BEARER_TOKEN_BEDROCK in the env — op-spawn fails fast
without one. Override per-deployment with OURRO_LOOP_MODEL (e.g. opus-4-6, or
gemini-3.1-pro → Vertex)."
  (env "OURRO_LOOP_MODEL" "sonnet-4-6"))

(defun stop-file () (merge-pathnames "STOP" (loop-root)))
(defun state-file () (merge-pathnames "loop-state.sexp" (loop-root)))
(defun log-file () (merge-pathnames "loop-log.sexp" (loop-root)))
(defun ledger-dir () (merge-pathnames "ledger/" (loop-root)))

(defun operator-wall-clock-seconds ()
  "Hard ceiling (seconds) on one operator mission run before it is reaped as
:TIMEOUT. THIS is the '90-minute limit' — it lives only in the cloud QA loop,
not the product. 90 min by default; override with OURRO_LOOP_OPERATOR_MINUTES."
  (let ((v (env "OURRO_LOOP_OPERATOR_MINUTES")))
    (* 60 (or (and v (ignore-errors (parse-integer v :junk-allowed t))) 90))))

(defvar *operator-wall-clock-seconds* nil
  "Test override for OPERATOR-WALL-CLOCK-SECONDS; NIL → the configured value.")
(defparameter *max-continue-nudges* 50
  "How many turn-cap 'continue' nudges one mission run may consume.")
(defparameter *poll-seconds* 20)


(defun write-plist-file (path plist)
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :external-format :utf-8
                            :if-exists :supersede :if-does-not-exist :create)
    (let ((*print-pretty* nil) (*print-readably* nil)
          (*package* (find-package :ourro.qa.conductor)))
      (prin1 plist out) (terpri out))))

(defun read-state ()
  (first (read-sexp-file (state-file))))

(defun write-state (state)
  (write-plist-file (state-file) state)
  state)

(defun log-entry (&rest plist)
  "Append one event line to loop-log.sexp and echo it to stdout."
  (let ((entry (append (list :time (ourro.qa.operator::iso-now)) plist)))
    (ensure-directories-exist (log-file))
    (with-open-file (out (log-file) :direction :output :external-format :utf-8
                                    :if-exists :append :if-does-not-exist :create)
      (let ((*print-pretty* nil) (*print-readably* nil)
            (*package* (find-package :ourro.qa.conductor)))
        (prin1 entry out) (terpri out)))
    (format t "~&[loop] ~S~%" entry)
    (finish-output)
    entry))


(defun mission-files ()
  (sort (directory (merge-pathnames "qa/missions/*.sexp" (repo-root)))
        #'string< :key #'namestring))

(defun mission-plist (file)
  "The (mission \"name\" . plist) body. Read in a CL-using package so an
omitted :fixture stays NIL (the keyword-package :NIL gotcha)."
  (let ((form (first (read-sexp-file file))))
    (when (and (consp form) (stringp (second form)))
      (list* :name (second form) (cddr form)))))

(defun tool-available-p (name)
  ;; Through /bin/sh: `command` is a shell builtin — macOS happens to ship a
  ;; real /usr/bin/command binary, Debian does not (found by the Docker
  ;; build's in-container test run).
  (multiple-value-bind (out err code)
      (ourro.qa.operator::sh
       "/bin/sh" (list "-c" (format nil "command -v ~A" name)))
    (declare (ignore out err))
    (eql code 0)))

(defun mission-runnable-p (file)
  "Every :needs tool must exist on this host."
  (let ((plist (mission-plist file)))
    (and plist
         (every (lambda (tool) (and (stringp tool) (tool-available-p tool)))
                (pget plist :needs)))))

(defun next-mission (state)
  "Round-robin over the runnable mission bank, resuming from the state's
cursor. Returns (values file new-cursor) or NIL when none are runnable."
  (let* ((files (remove-if-not #'mission-runnable-p (mission-files)))
         (n (length files)))
    (when (plusp n)
      (let ((cursor (mod (or (pget state :cursor) 0) n)))
        (values (nth cursor files) (mod (1+ cursor) n))))))


(defun today-spend () (ourro.qa.spend:ledger-total (ledger-dir)))

(defun over-daily-cap-p ()
  (let ((cap (daily-cap-usd)))
    (and cap (>= (today-spend) cap))))

(defun seconds-until-utc-midnight ()
  (multiple-value-bind (sec min hour) (decode-universal-time (get-universal-time) 0)
    (max 60 (- 86400 (+ sec (* 60 min) (* 3600 hour))))))

(defun pause-until-tomorrow ()
  (log-entry :phase :paused :spent (today-spend) :cap (daily-cap-usd))
  (loop while (over-daily-cap-p)
        do (loop repeat (ceiling (seconds-until-utc-midnight) 60)
                 do (when (probe-file (stop-file))
                      (return-from pause-until-tomorrow nil))
                    (sleep 60))))


(defun pane-shows-turn-cap-p (session)
  (let ((screen (nth-value 0 (ourro.qa.operator::tmux
                              "capture-pane" "-p" "-t" session))))
    (and screen (search "say \"continue\" to keep going" screen) t)))

(defun session-busy-p (session-name)
  (let* ((session (ourro.qa.operator:resolve-session session-name))
         (status (first (read-sexp-file
                         (merge-pathnames "state/qa-status.sexp"
                                          (ourro.qa.operator:session-home session))))))
    (and status (pget status :busy) t)))

(defun supervise-mission-session (session-name result-file
                                  &key (wall-clock (or *operator-wall-clock-seconds*
                                                       (operator-wall-clock-seconds)))
                                       (max-nudges *max-continue-nudges*)
                                       (poll *poll-seconds*))
  "Wait for a mission-mode ourro to finish: result file (:done), pane death
(:died), wall clock (:timeout), or the kill switch (:stopped). Nudges the
session past its own turn caps with 'continue', at most MAX-NUDGES times."
  (let ((deadline (+ (get-universal-time) wall-clock))
        (nudges 0))
    (loop
      (cond
        ((probe-file result-file) (return (values :done nudges)))
        ((probe-file (stop-file)) (return (values :stopped nudges)))
        ((> (get-universal-time) deadline) (return (values :timeout nudges)))
        ((ourro.qa.operator::pane-dead-p
          (ourro.qa.operator:resolve-session session-name))
         (return (values :died nudges)))
        ((and (pane-shows-turn-cap-p session-name)
              (not (session-busy-p session-name)))
         (cond ((>= nudges max-nudges) (return (values :nudge-cap nudges)))
               (t (incf nudges)
                  (log-entry :phase :nudge :session session-name :count nudges)
                  (op-say (ourro.qa.operator:resolve-session session-name)
                          "continue")))))
      (sleep poll))))


(defun findings-dir () (merge-pathnames "qa/findings/" (repo-root)))

(defun read-finding (file)
  (first (read-sexp-file file)))

(defun list-findings ()
  (sort (mapcar #'file-namestring (directory (merge-pathnames "F-*.sexp" (findings-dir))))
        #'string<))

(defun cycle-dir (cycle)
  (merge-pathnames (format nil "cycles/~4,'0D/" cycle) (loop-root)))

(defun record-phase-spend (cycle phase homes)
  "Price PHASE from the instances' event logs and append to the daily ledger.
Spend is telemetry, not control flow: any error here logs and prices 0 rather
than killing the cycle (the first live cycle died exactly this way)."
  (handler-case
      (let ((usd 0.0d0) (in 0) (out 0))
        (dolist (home homes)
          (let ((sum (ourro.qa.spend:sum-home home)))
            (incf usd (getf sum :usd))
            (incf in (getf sum :in-tokens))
            (incf out (getf sum :out-tokens))))
        (ourro.qa.spend:ledger-append (ledger-dir)
                                     (list :cycle cycle :phase phase :usd usd
                                           :in-tokens in :out-tokens out))
        usd)
    (error (c)
      (log-entry :cycle cycle :phase phase :spend-error (princ-to-string c))
      0.0d0)))

(defun run-one-cycle (state)
  "Run one full v1 cycle from STATE; returns the state for the next cycle.
Each phase persists itself before acting."
  (let* ((cycle (1+ (or (pget state :cycle) 0))))
    ;; :pick-scenario
    (write-state (list :phase :pick-scenario :cycle cycle
                       :cursor (pget state :cursor)))
    (multiple-value-bind (mission-file new-cursor) (next-mission state)
      (unless mission-file
        (log-entry :cycle cycle :phase :pick-scenario :error "no runnable missions")
        (return-from run-one-cycle (list :cycle cycle :cursor 0)))
      (let* ((mission (mission-plist mission-file))
             (name (pget mission :name))
             (fixture (let ((f (pget mission :fixture)))
                        (and (stringp f)
                             (namestring (merge-pathnames
                                          (concatenate 'string f "/")
                                          (repo-root)))))))
        (log-entry :cycle cycle :phase :pick-scenario :mission name)
        ;; :spawn-subject
        (write-state (list :phase :spawn-subject :cycle cycle :cursor new-cursor
                           :mission name))
        (let ((subject (op-spawn :model (loop-model) :fixture fixture)))
          (unless (pget subject :session)
            (log-entry :cycle cycle :phase :spawn-subject :error subject)
            (return-from run-one-cycle (list :cycle cycle :cursor new-cursor)))
          (let* ((subject-session (pget subject :session))
                 (result-file (merge-pathnames "operator-result.sexp"
                                               (cycle-dir cycle)))
                 (composed (merge-pathnames "operator-mission.md"
                                            (cycle-dir cycle)))
                 (findings-before (list-findings)))
            (ensure-directories-exist result-file)
            ;; :run-operator
            (write-state (list :phase :run-operator :cycle cycle :cursor new-cursor
                               :mission name :subject subject-session))
            (ourro.qa.compose:compose-operator-mission
             :doctrine-file (merge-pathnames "qa/loop/doctrine-operator.md" (repo-root))
             :mission-file mission-file
             :output composed
             :session subject-session
             :subject-work (pget subject :dir)
             :subject-home (pget subject :home)
             :findings-dir (findings-dir)
             :result-file result-file)
            (let ((operator (op-spawn :model (loop-model)
                                      :workspace (namestring (repo-root))
                                      :mission (namestring composed)
                                      :mission-result (namestring result-file))))
              (unless (pget operator :session)
                (log-entry :cycle cycle :phase :run-operator :error operator)
                (op-kill (ourro.qa.operator:resolve-session subject-session))
                (return-from run-one-cycle (list :cycle cycle :cursor new-cursor)))
              (let ((operator-session (pget operator :session)))
                (multiple-value-bind (outcome nudges)
                    (supervise-mission-session operator-session result-file)
                  (log-entry :cycle cycle :phase :run-operator :outcome outcome
                             :nudges nudges)
                  ;; :harvest-findings — evidence, spend, teardown, result.
                  (write-state (list :phase :harvest-findings :cycle cycle
                                     :cursor new-cursor :mission name
                                     :subject subject-session
                                     :operator operator-session))
                  (ignore-errors
                   (op-collect (ourro.qa.operator:resolve-session subject-session)
                               :label (format nil "cycle-~4,'0D" cycle)))
                  (record-phase-spend cycle :run-operator
                                      (list (pget subject :home)
                                            (pget operator :home)))
                  (let* ((result (first (read-sexp-file result-file)))
                         (new-findings (set-difference (list-findings)
                                                       findings-before
                                                       :test #'string=))
                         (beats (and result (pget result :beats-completed)))
                         (arc-length (length (pget mission :arc)))
                         ;; Doctrine says every beat, every time; an early
                         ;; finish without :aborted is an invalid run — a
                         ;; quality signal the log must carry.
                         (short-run (and (integerp beats)
                                         (< beats arc-length)
                                         (not (pget result :aborted)))))
                    (log-entry :cycle cycle :phase :harvest-findings
                               :outcome outcome
                               :result-ok (and result (pget result :ok))
                               :beats beats :arc arc-length
                               :short-run short-run
                               :new-findings new-findings)
                    (ignore-errors
                     (op-kill (ourro.qa.operator:resolve-session operator-session)))
                    (ignore-errors
                     (op-kill (ourro.qa.operator:resolve-session subject-session)))
                    ;; New findings surface as GitHub issues (best-effort:
                    ;; a missing/unauthed gh must never kill the loop).
                    (when new-findings
                      (let ((gh (ourro.qa.github:file-issues-for-findings
                                 (mapcar (lambda (n)
                                           (merge-pathnames n (findings-dir)))
                                         new-findings))))
                        (log-entry :cycle cycle :phase :file-issues :result gh)))
                    (list :cycle cycle :cursor new-cursor
                          :last-mission name :last-outcome outcome
                          :last-findings new-findings)))))))))))

(defun run (&key once)
  "The loop. Checks the kill switch and the daily cap between cycles; ONCE
runs a single cycle (smoke/verification)."
  (ensure-directories-exist (state-file))
  (loop
    (when (probe-file (stop-file))
      (log-entry :phase :halted :reason :stop-file)
      (return :halted))
    (when (over-daily-cap-p)
      (pause-until-tomorrow)
      (when (probe-file (stop-file))
        (log-entry :phase :halted :reason :stop-file)
        (return :halted)))
    (let ((state (or (read-state) '(:cycle 0 :cursor 0))))
      (write-state (run-one-cycle state)))
    (when once (return :once))))
