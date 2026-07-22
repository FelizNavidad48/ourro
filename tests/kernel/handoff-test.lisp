(in-package #:ourro.tests)

(def-suite handoff-suite :in ourro)
(in-suite handoff-suite)

(test handoff-roundtrips
  (let* ((payload (ourro.kernel:handoff-plist
                   :session-id "s-1"
                   :generation "gen-0005"
                   :conversation (list (ourro.llm:user-message "hello"))
                   :scrollback '(((:assistant "hi")))
                   :input-text "draft"))
         (path (ourro.kernel:write-handoff payload
                                          :directory (uiop:temporary-directory)))
         (back (ourro.kernel:read-handoff path)))
    (is (string= "s-1" (getf back :session-id)))
    (is (string= "gen-0005" (getf back :generation)))
    (is (string= "draft" (getf back :input-text)))
    (is (equal (getf payload :conversation) (getf back :conversation)))
    (ignore-errors (delete-file path))))

(test arrival-survives-handoff-roundtrip
  ;; The arrival descriptor rides in :extra and must read back intact (M2-5).
  (let* ((arrival (list :from "gen-0001" :to "gen-0002"
                        :gene "tool/edit-and-test" :benefit "saves ~40s/use"))
         (payload (ourro.kernel:handoff-plist
                   :generation "gen-0002"
                   :conversation '()
                   :scrollback '()
                   :extra (list :history '() :arrival arrival)))
         (path (ourro.kernel:write-handoff payload
                                          :directory (uiop:temporary-directory)))
         (back (ourro.kernel:read-handoff path)))
    (is (equal arrival (getf (getf back :extra) :arrival)))
    (ignore-errors (delete-file path))))

(test restore-session-shows-arrival-moment
  (let* ((agent (ourro.agent::make-agent
                 :provider (ourro.llm:make-scripted-provider '())))
         (payload (ourro.kernel:handoff-plist
                   :generation "gen-0002"
                   :conversation '()
                   :scrollback '()
                   :extra (list :history '()
                                :arrival (list :from "gen-0001" :to "gen-0002"
                                               :gene "tool/edit-and-test"
                                               :benefit "saves ~40s/use")))))
    (ourro.agent::restore-session agent payload)
    (let ((ticker (ourro.tui:view-ticker (ourro.agent::agent-view agent))))
      (is (search "now running gen-0002" (ourro.tui:ticker-text ticker)))
      (is (search "edit-and-test" (ourro.tui:ticker-text ticker)))
      ;; The ticker's `e explain` affordance is live.
      (is (ourro.tui:ticker-actions ticker)))
    ;; A divider names the transition in the transcript.
    (is (search "evolved: gen-0001 → gen-0002"
                (agent-transcript-text agent)))))

(test freeze-survives-handoff-roundtrip
  ;; A user's /freeze is durable evolution state and must ride the payload
  ;; through a restart (handoff or crash-resume), or a restart silently
  ;; re-enables self-modification the user disabled (F-frzresm).
  (let* ((payload (ourro.kernel:handoff-plist
                   :generation "gen-0002"
                   :conversation '()
                   :scrollback '()
                   :frozen t
                   :extra (list :history '())))
         (path (ourro.kernel:write-handoff payload
                                          :directory (uiop:temporary-directory)))
         (back (ourro.kernel:read-handoff path)))
    (is-true (getf back :frozen))
    (ignore-errors (delete-file path))))

(test restore-session-reapplies-freeze
  ;; Restoring a frozen payload into a fresh (defaults-to-auto) image must set
  ;; the kernel flag, the agent mode, and the statusbar indicator (F-frzresm).
  (let* ((ourro.kernel:*evolution-frozen* nil)
         (agent (ourro.agent::make-agent
                 :provider (ourro.llm:make-scripted-provider '())))
         (payload (ourro.kernel:handoff-plist
                   :generation "gen-0002" :conversation '() :scrollback '()
                   :frozen t :extra (list :history '()))))
    (ourro.agent::restore-session agent payload)
    (is-true ourro.kernel:*evolution-frozen*)
    (is (eq :frozen (ourro.agent::agent-mode agent)))
    (is (eq :frozen (ourro.tui:statusbar-mode
                     (ourro.tui:view-statusbar (ourro.agent::agent-view agent)))))))

(test restore-session-thaws-when-payload-not-frozen
  ;; The mirror case: a non-frozen payload must not leave a stray freeze in
  ;; place. set-evolution-frozen restores both directions idempotently.
  (let* ((ourro.kernel:*evolution-frozen* t)
         (agent (ourro.agent::make-agent
                 :provider (ourro.llm:make-scripted-provider '())))
         (payload (ourro.kernel:handoff-plist
                   :generation "gen-0002" :conversation '() :scrollback '()
                   :frozen nil :extra (list :history '()))))
    (ourro.agent::restore-session agent payload)
    (is-false ourro.kernel:*evolution-frozen*)
    (is (eq :auto (ourro.agent::agent-mode agent)))))

(test restore-session-leaves-a-visiting-session-manual
  ;; A visiting (read-only time-travel) session must keep :manual mode after
  ;; restore: the freeze restoration must not overwrite it (evolution is blocked
  ;; for a visitor regardless, but its statusbar shows the visited generation,
  ;; not a freeze mode). Mirrors checkpoint-session skipping visiting sessions.
  (let* ((ourro.kernel:*evolution-frozen* nil)
         (agent (ourro.agent::make-agent
                 :provider (ourro.llm:make-scripted-provider '())
                 :mode :manual :visiting t))
         (payload (ourro.kernel:handoff-plist
                   :generation "gen-0001" :conversation '() :scrollback '()
                   :frozen nil :extra (list :history '()))))
    (ourro.agent::restore-session agent payload)
    (is (eq :manual (ourro.agent::agent-mode agent)))))


(defmacro with-travel-home ((agent-var conn-var buffer-var) &body body)
  "A headless agent with a stub supervisor connection whose sent frames land in
BUFFER-VAR, inside a throwaway OURRO_HOME so PERFORM-HANDOFF's handoff file has
somewhere to go."
  (let ((home (gensym)))
    `(let* ((,home (uiop:ensure-directory-pathname
                    (merge-pathnames (format nil "ourro-travel-~A/" (ourro.util:make-id "h"))
                                     (uiop:temporary-directory))))
            (ourro.util::*ourro-home* ,home)
            (ourro.tui:*keep-screen-on-exit* nil))
       (ensure-directories-exist (merge-pathnames "state/" ,home))
       (unwind-protect
            (let* ((,agent-var (ourro.agent::make-agent
                                :provider (ourro.llm:make-scripted-provider '())))
                   (,buffer-var (make-string-output-stream))
                   (,conn-var (make-instance 'ourro.kernel::protocol-connection
                                             :socket nil
                                             :stream (make-two-way-stream
                                             (make-string-input-stream
                                              "5
(:ok)
")
                                                      ,buffer-var))))
              (setf (ourro.agent::agent-supervisor ,agent-var) ,conn-var)
              ,@body)
         (ignore-errors
          (uiop:delete-directory-tree ,home :validate (constantly t)))))))

(defun sent-handoff-message (buffer)
  "The :handoff frame PERFORM-HANDOFF wrote into the stub connection's BUFFER."
  (ourro.kernel:protocol-receive
   (make-instance 'ourro.kernel::protocol-connection
                  :socket nil
                  :stream (make-two-way-stream
                           (make-string-input-stream (get-output-stream-string buffer))
                           (make-broadcast-stream)))))

