
(in-package #:ourro.agent)

(defparameter *compaction-window-fraction* 0.5
  "Stage-1 elision fires once the last prompt exceeds this fraction of the window.")
(defparameter *summarize-window-fraction* 0.7
  "Stage-2 summarization is prepared once the last prompt exceeds this fraction.")
(defparameter *elide-keep-turns* 8
  "Stage-1 keeps the last N user turns' tool results intact; older ones elide.")


(defun agent-model-id (agent)
  (ignore-errors (ourro.llm:provider-model (agent-provider agent))))

(defun agent-context-window (agent)
  (or (ignore-errors (ourro.llm:model-context-window (agent-model-id agent)))
      200000))

(defun turn-cost (usage pricing)
  "USD for one turn from a usage plist and per-1e6-token PRICING. Cache-read
tokens are a discounted subset of the prompt tokens, billed at :cache-read."
  (let ((in (or (pget usage :prompt-tokens) 0))
        (out (or (pget usage :candidates-tokens) 0))
        (cache-read (or (pget usage :cache-read-tokens) 0)))
    (+ (* (/ (max 0 (- in cache-read)) 1000000.0d0) (or (getf pricing :in) 0))
       (* (/ cache-read 1000000.0d0)
          (or (getf pricing :cache-read) (getf pricing :in) 0))
       (* (/ out 1000000.0d0) (or (getf pricing :out) 0)))))

(defun record-turn-usage (agent usage)
  "Consume the usage a model call reported: update the live prompt-token gauge
and, when pricing is known, the running session cost (M11-1)."
  (when usage
    (let ((prompt (or (pget usage :prompt-tokens) 0)))
      (when (plusp prompt) (setf (agent-last-prompt-tokens agent) prompt)))
    (let ((pricing (ignore-errors (ourro.llm:model-pricing (agent-model-id agent)))))
      (when pricing
        (incf (agent-session-cost agent) (turn-cost usage pricing))))))

(defun context-hud-data (agent)
  "The numbers the context/cost HUD renders (M11-4)."
  (let* ((window (agent-context-window agent))
         (tokens (agent-last-prompt-tokens agent))
         (fraction (if (plusp window) (/ tokens (float window 1.0d0)) 0.0d0))
         (pricing (ignore-errors (ourro.llm:model-pricing (agent-model-id agent)))))
    (list :fraction fraction
          :percent (round (* 100 fraction))
          :cost (agent-session-cost agent)
          :cost-known (and pricing t))))


(defun nth-from-last-user-index (conversation n)
  "Index of the Nth-from-last :user message in CONVERSATION, or 0 if there are
fewer than N user messages."
  (let ((users (loop for m in conversation for i from 0
                     when (eq (pget m :role) :user) collect i)))
    (if (>= (length users) n) (nth (- (length users) n) users) 0)))

(defun elide-tool-message (message)
  "Rebuild a :tool MESSAGE with its body replaced by first-line + an elided
marker, KEEPING :tool-call-id and :name (both serializers still emit a
well-formed pair). Returns MESSAGE unchanged if there's nothing to save."
  (let* ((content (or (pget message :content) ""))
         (nl (position #\Newline content))
         (first-line (if nl (subseq content 0 nl) content))
         (saved (- (length content) (length first-line))))
    (if (<= saved 1)
        message
        (list :role :tool
              :tool-call-id (pget message :tool-call-id)
              :name (pget message :name)
              :content (format nil "~A… [~A chars elided]" first-line saved)
              :error-p (pget message :error-p)))))

(defun elide-old-tool-results (conversation &key (keep-turns *elide-keep-turns*))
  "Return (values new-conversation changed-p): a rebuild of CONVERSATION with
:tool bodies older than the last KEEP-TURNS user turns elided (M11-2)."
  (let ((cutoff (nth-from-last-user-index conversation keep-turns))
        (changed nil))
    (values
     (loop for m in conversation for i from 0
           collect (if (and (< i cutoff) (eq (pget m :role) :tool))
                       (let ((e (elide-tool-message m)))
                         (unless (eq e m) (setf changed t))
                         e)
                       m))
     changed)))


(defun message-text (message)
  "A plain-text rendering of one canonical message for summarization."
  (let ((content (pget message :content)))
    (cond ((stringp content) content)
          ((listp content) (ignore-errors (ourro.llm:assistant-text message)))
          (t (princ-to-string content)))))

(defun messages->text (messages)
  (with-output-to-string (out)
    (dolist (m messages)
      (format out "[~A] ~A~%" (pget m :role) (or (message-text m) "")))))

(defun compaction-cut-point (conversation)
  "The exclusive index to summarize UP TO: the last :user boundary at or before
the middle, so no assistant tool-call is split from its :tool replies. 0 when
there's nothing safe to cut."
  (let ((target (floor (length conversation) 2))
        (cut 0))
    (loop for m in conversation for i from 0 below target
          when (eq (pget m :role) :user) do (setf cut i))
    cut))

(defun summarize-messages (agent messages)
  (ourro.llm:complete-text
   (agent-provider agent)
   "Summarize this earlier conversation history into a compact, factual brief ~
that preserves decisions made, file paths touched, and any open threads. Be ~
terse; omit pleasantries."
   (messages->text messages)))

(defun prepare-compaction (agent)
  "Off-turn (turn-boundary worker): when the last prompt crossed 70% of the
window and no summary is already pending, summarize the conversation prefix up
to a safe :user boundary and stash it (with an eq-anchor) for the next
process-turn to apply. The LLM call happens HERE, never on the interactive path."
  (let* ((window (agent-context-window agent))
         (tokens (agent-last-prompt-tokens agent))
         (conversation (agent-conversation agent)))
    (when (and (plusp window)
               (> tokens (* *summarize-window-fraction* window))
               (null (agent-pending-compaction agent))
               (> (length conversation) 6))
      (let ((n (compaction-cut-point conversation)))
        (when (> n 1)
          (let ((summary (ignore-errors
                          (summarize-messages agent (subseq conversation 0 n)))))
            (when (and (stringp summary) (plusp (length summary)))
              (setf (agent-pending-compaction agent)
                    ;; Anchor on the :user message AT the cut (index n, the head
                    ;; of the retained tail), NOT the last summarized message at
                    ;; n-1: n-1 is often a :tool message that stage-1 elision
                    ;; rebuilds between prepare and apply, which would break the
                    ;; eq-anchor and needlessly drop the summary. A :user message
                    ;; is never elided, so its object identity is stable.
                    (list :prefix-n n
                          :anchor (nth n conversation)
                          :summary summary)))))))))

(defun apply-pending-compaction (agent)
  "At process-turn top: splice a prepared summary in place of its prefix IFF the
eq-anchor still matches at position n-1 (the prefix hasn't moved — the
conversation only grew append-only since prepare). A stale summary is dropped,
never spliced (M11-3). Splices as a :user message (satisfies Converse's
first-message-must-be-user; adjacency heals)."
  (let ((plan (agent-pending-compaction agent)))
    (when plan
      (setf (agent-pending-compaction agent) nil)
      (let* ((n (pget plan :prefix-n))
             (conversation (agent-conversation agent)))
        ;; The anchor is the :user message at index n (the retained tail's head);
        ;; if it's still the same object, the summarized prefix [0,n) is unchanged
        ;; (append-only + elision preserves :user identity) and the splice is safe.
        (when (and (integerp n) (> (length conversation) n)
                   (eq (nth n conversation) (pget plan :anchor)))
          (setf (agent-conversation agent)
                (cons (ourro.llm:user-message
                       (format nil "[earlier conversation summarized]~%~A"
                               (pget plan :summary)))
                      (nthcdr n conversation)))
          (ignore-errors
           (ourro.observe:log-event :compaction :stage 2 :summarized-prefix n))
          t)))))


(defun maybe-compact-conversation (agent)
  "Called at the top of process-turn (the sanctioned conversation mutator).
First apply any ready stage-2 summary, then, if the last prompt is past 50% of
the window, run stage-1 tool-result elision."
  (apply-pending-compaction agent)
  (let ((window (agent-context-window agent))
        (tokens (agent-last-prompt-tokens agent)))
    (when (and (plusp window) (> tokens (* *compaction-window-fraction* window)))
      (multiple-value-bind (compacted changed)
          (elide-old-tool-results (agent-conversation agent))
        (when changed
          (setf (agent-conversation agent) compacted)
          (ignore-errors
           (ourro.observe:log-event :compaction :stage 1
                                   :prompt-tokens tokens :window window)))))))
