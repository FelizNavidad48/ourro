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

