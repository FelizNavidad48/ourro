(in-package #:ourro.tests)


(def-suite robustness-suite :in ourro)
(in-suite robustness-suite)

(defmacro with-temp-home ((&key) &body body)
  "Bind *OURRO-HOME* to a throwaway directory for the duration of BODY."
  (let ((home (gensym)))
    `(let* ((,home (merge-pathnames
                    (format nil "ourro-robust-~A/" (ourro.util:make-id "h"))
                    (uiop:temporary-directory)))
            (ourro.util::*ourro-home* (uiop:ensure-directory-pathname ,home)))
       (ensure-directories-exist ,home)
       (unwind-protect (progn ,@body)
         (ignore-errors
          (uiop:delete-directory-tree (uiop:ensure-directory-pathname ,home)
                                      :validate (constantly t)))))))

(defun make-test-agent ()
  (ourro.agent::make-agent :provider (ourro.llm:make-scripted-provider '())
                          :generation "gen-0007"))


(test checkpoint-roundtrips-and-flags-itself
  ;; CHECKPOINT-SESSION writes the fixed checkpoint; it reads back as a valid
  ;; handoff payload flagged :checkpoint, carrying the conversation and pid.
  (with-temp-home ()
    (let ((agent (make-test-agent)))
      (setf (ourro.agent::agent-conversation agent)
            (list (ourro.llm:user-message "remember me")))
      (ourro.agent::checkpoint-session agent)
      (let ((payload (ourro.kernel:read-handoff (ourro.agent::checkpoint-path))))
        (is-true payload)
        (is-true (getf payload :checkpoint))
        (is (integerp (getf payload :pid)))
        (is (equal (list (ourro.llm:user-message "remember me"))
                   (getf payload :conversation)))))))

(test checkpoint-not-written-while-visiting
  ;; A read-only time-travel session must not clobber the real recovery point.
  (with-temp-home ()
    (let ((agent (make-test-agent)))
      (setf (ourro.agent::agent-visiting agent) t)
      (ourro.agent::checkpoint-session agent)
      (is (null (probe-file (ourro.agent::checkpoint-path)))))))

(test delete-checkpoint-removes-the-file
  (with-temp-home ()
    (let ((agent (make-test-agent)))
      (ourro.agent::checkpoint-session agent)
      (is-true (probe-file (ourro.agent::checkpoint-path)))
      (ourro.agent::delete-checkpoint)
      (is (null (probe-file (ourro.agent::checkpoint-path)))))))

(test restore-session-shows-crash-recovery-ticker
  (let* ((agent (make-test-agent))
         (payload (ourro.kernel:handoff-plist
                   :generation "gen-0007" :conversation '() :scrollback '()
                   :checkpoint t :extra (list :history '()))))
    (ourro.agent::restore-session agent payload)
    (let ((ticker (ourro.tui:view-ticker (ourro.agent::agent-view agent))))
      (is (search "recovered your session"
                  (or (ourro.tui:ticker-text ticker) ""))))))

(test event-log-survives-a-resume     ; F-1
  ;; PR-1's observation stream must keep persisting across a restart. A reborn
  ;; image starts with *EVENT-LOG-PATH* nil (fresh defvar) but a session id
  ;; restored from the handoff. WIRE-OBSERVER must re-open the SAME events file
  ;; so LOG-EVENT keeps appending — before the fix it only called
  ;; START-EVENT-LOG when the id was nil, so the resume path left the path nil
  ;; and silently dropped every post-restart event.
  (with-temp-home ()
    (let ((ourro.observe::*event-log-path* nil)
          (ourro.observe::*session-id* nil)
          (ourro.observe::*recent-events* '()))
      ;; First life: open a fresh log and record one event.
      (let* ((sid (ourro.observe:start-event-log))
             (path (ourro.observe:event-log-path sid)))
        (ourro.observe:log-event :user-message :text "before restart")
        ;; Simulate the reborn image: the path is forgotten, the id is restored
        ;; onto a fresh agent from the handoff.
        (setf ourro.observe::*event-log-path* nil)
        (let ((agent (make-test-agent)))
          (setf (ourro.agent::agent-session-id agent) sid)
          (ourro.agent::wire-observer agent)
          (is (string= sid (ourro.agent::agent-session-id agent)))
          (is-true ourro.observe::*event-log-path*)
          (ourro.observe:log-event :user-message :text "after restart")
          ;; Both events are on disk in the one session file.
          (let ((persisted (ourro.observe:read-events path)))
            (is-true (find "before restart" persisted
                           :key (lambda (e) (getf e :text)) :test #'equal))
            (is-true (find "after restart" persisted
                           :key (lambda (e) (getf e :text)) :test #'equal))))))))


(test recovery-probation-flag-set-only-on-checkpoint-restore
  (with-temp-home ()
    (let ((crash (make-test-agent))
          (clean (make-test-agent)))
      (ourro.agent::restore-session
       crash (ourro.kernel:handoff-plist
              :generation "gen-0007" :conversation '() :scrollback '()
              :checkpoint t :extra (list :history '())))
      (ourro.agent::restore-session
       clean (ourro.kernel:handoff-plist
              :generation "gen-0007" :conversation '() :scrollback '()
              :extra (list :history '())))
      (is-true (ourro.agent::agent-recovered-from-checkpoint crash))
      (is-false (ourro.agent::agent-recovered-from-checkpoint clean)))))

(test note-recovery-proven-clears-probation-and-is-idempotent
  ;; Clears the probation flag (and, with a live supervisor, would send
  ;; :checkpoint-superseded). No connection in the harness, so we observe the
  ;; flag transition; a second call is a harmless no-op, as is one on a boot
  ;; that never recovered.
  (let ((agent (make-test-agent)))
    (setf (ourro.agent::agent-recovered-from-checkpoint agent) t)
    (ourro.agent::note-recovery-proven agent)
    (is-false (ourro.agent::agent-recovered-from-checkpoint agent))
    (ourro.agent::note-recovery-proven agent)
    (is-false (ourro.agent::agent-recovered-from-checkpoint agent))))


(test restore-session-restores-cwd
  (let* ((agent (make-test-agent))
         (dir (uiop:temporary-directory))
         (payload (ourro.kernel:handoff-plist
                   :generation "gen-1" :conversation '() :scrollback '()
                   :cwd dir :extra (list :history '())))
         (saved ourro.toolkit:*workspace*))
    (unwind-protect
         (progn
           (ourro.agent::restore-session agent payload)
           (is (equal (namestring (uiop:ensure-directory-pathname dir))
                      (namestring ourro.toolkit:*workspace*))))
      (setf ourro.toolkit:*workspace* saved))))

(test typeahead-queues-when-busy
  ;; A submission entered mid-turn is queued, not run as a concurrent turn.
  (let ((agent (make-test-agent)))
    (setf (ourro.agent::agent-busy agent) t)
    (ourro.agent::run-submission agent "do this next")
    (is (equal '("do this next") (ourro.agent::agent-pending-submissions agent)))
    ;; Draining pops it FIFO once idle.
    (setf (ourro.agent::agent-busy agent) nil)
    (is (string= "do this next" (ourro.agent::dequeue-submission agent)))
    (is (null (ourro.agent::agent-pending-submissions agent)))))

(test input-during-in-flight-slash-command-queues
  ;; M4-2 review #2: a slow slash command (/onboard) now claims BUSY, so a
  ;; submission entered while it runs queues instead of racing a concurrent
  ;; turn. With BUSY set (the in-flight state), any submission — slash or not —
  ;; goes to the queue.
  (let ((agent (make-test-agent)))
    (setf (ourro.agent::agent-busy agent) t)
    (ourro.agent::run-submission agent "/genome")
    (ourro.agent::run-submission agent "then this")
    (is (equal '("/genome" "then this")
               (ourro.agent::agent-pending-submissions agent)))))


(test checkpoint-worthy-command-predicate
  (is-true (ourro.agent::checkpoint-worthy-command-p "/keep somegene"))
  (is-true (ourro.agent::checkpoint-worthy-command-p "/revert"))
  (is-true (ourro.agent::checkpoint-worthy-command-p "/FREEZE")) ; case-insensitive
  (is-true (ourro.agent::checkpoint-worthy-command-p "/onboard"))
  (is-false (ourro.agent::checkpoint-worthy-command-p "/help"))
  (is-false (ourro.agent::checkpoint-worthy-command-p "/log"))
  (is-false (ourro.agent::checkpoint-worthy-command-p "/genome"))
  (is-false (ourro.agent::checkpoint-worthy-command-p "/tools"))
  (is-false (ourro.agent::checkpoint-worthy-command-p "/evolutions")))

(test pending-submissions-survive-handoff-roundtrip
  (let ((agent (make-test-agent)))
    (setf (ourro.agent::agent-pending-submissions agent) (list "a" "b"))
    (let* ((payload (ourro.agent::session-payload agent))
           (path (ourro.kernel:write-handoff payload
                                            :directory (uiop:temporary-directory)))
           (back (ourro.kernel:read-handoff path))
           (agent2 (make-test-agent)))
      (is (equal '("a" "b") (getf back :pending)))
      (ourro.agent::restore-session agent2 back)
      (is (equal '("a" "b") (ourro.agent::agent-pending-submissions agent2)))
      (ignore-errors (delete-file path)))))


(test kernel-selftest-passes
  ;; The in-image suite that runs at every --smoke boot must be green here too.
  (multiple-value-bind (passed report) (ourro.kernel:run-kernel-selftest)
    (declare (ignorable report))
    (is-true passed)))

(test kernel-locked-p-is-a-boolean-and-unlocked-in-tests
  ;; kernel-locked-p reports whether OURRO.KERNEL is package-locked (M8). The
  ;; test image is deliberately unlocked (only built images lock it), so it must
  ;; report NIL here — and never error, regardless.
  (is (typep (ourro.kernel:kernel-locked-p) 'boolean))
  (is-false (ourro.kernel:kernel-locked-p)))


(test capability-ceiling-blocks-writes-permits-reads
  ;; With the visiting ceiling, a blanket +all-capabilities+ grant collapses to
  ;; read+llm: a write signals a clean CAPABILITY-VIOLATION before touching disk.
  (let ((ourro.kernel:*capability-ceiling* '(:filesystem-read :llm)))
    (ourro.kernel:with-capabilities ourro.kernel:+all-capabilities+
      (is-true (member :filesystem-read ourro.kernel:*active-capabilities*))
      (is-true (member :llm ourro.kernel:*active-capabilities*))
      (is-false (member :filesystem-write ourro.kernel:*active-capabilities*))
      (is-false (member :subprocess ourro.kernel:*active-capabilities*))
      (signals ourro.kernel:capability-violation
        (ourro.kernel:cap/write-file
         (merge-pathnames "nope.txt" (uiop:temporary-directory)) "x")))))

(test capability-ceiling-default-is-transparent
  ;; The default ceiling is the full set, so a normal grant is unchanged.
  (ourro.kernel:with-capabilities '(:filesystem-write :subprocess)
    (is-true (member :filesystem-write ourro.kernel:*active-capabilities*))
    (is-true (member :subprocess ourro.kernel:*active-capabilities*))))

(test nested-capability-grants-only-attenuate
  ;; A no-capability evolved caller cannot regain write authority by nesting a
  ;; broader evolved grant (the same invariant protects nested tool calls).
  (ourro.kernel:with-capabilities '()
    (signals ourro.kernel:capability-violation
      (ourro.kernel:with-attenuated-capabilities ourro.kernel:+all-capabilities+
        (ourro.kernel:require-capability :filesystem-write :probe)))))

(test explicitly-empty-gene-capabilities-stay-empty
  (let ((ourro.tools:*current-gene-context*
          '(:name "test/no-cap" :capabilities ())))
    (eval '(ourro.tools:deftool no-cap-probe ()
             (:doc "No authority.")
             (:contract (:pre () :post ((stringp result))))
             "ok"))
    (unwind-protect
         (is (null (ourro.tools:tool-capabilities
                    (ourro.tools:find-tool "no_cap_probe"))))
      (ourro.tools:unregister-tool "no_cap_probe"))))


(test run-program-returns-when-grandchild-holds-pipe
  ;; A backgrounded child inherits the output pipe and outlives the shell:
  ;; `sleep 15 &` keeps the write end open long after sh exits. Reading must
  ;; stop on child death plus a short quiet grace — not wait for pipe EOF,
  ;; which formerly wedged the shell tool for the grandchild's whole lifetime.
  (ourro.kernel:with-capabilities '(:subprocess)
    (let ((start (get-universal-time)))
      (multiple-value-bind (out code)
          (ourro.kernel:cap/run-program
           (list "/bin/sh" "-c" "sleep 15 & echo started")
           :timeout 60)
        (is (eql 0 code))
        (is (search "started" out))
        (is (< (- (get-universal-time) start) 10))))))
