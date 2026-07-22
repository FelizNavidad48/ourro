
(in-package #:ourro.observe)

(defparameter *correction-max-text* 200
  "Longest user snippet stored on a correction event.")


(defparameter *negation-scanner*
  (cl-ppcre:create-scanner
   "^(no[,.\\s]|not |don'?t |do not |stop |wrong|undo|revert|actually[, ]|wait[, ]|instead)"
   :case-insensitive-mode t))

(defparameter *substitute-scanner*
  (cl-ppcre:create-scanner
   "use\\s+(\\S+)\\s+(?:instead of|not)\\s+(\\S+)"
   :case-insensitive-mode t))

(defun normalize-token (token)
  (string-trim '(#\Space #\Tab #\. #\, #\; #\: #\! #\? #\" #\' #\` #\( #\))
               token))

(defun first-n-words (text n)
  (let ((words (remove "" (cl-ppcre:split "\\s+" (string-downcase (trim text)))
                       :test #'string=)))
    (string-join " " (mapcar #'normalize-token
                             (subseq words 0 (min n (length words)))))))

(defun verbal-negation-p (text)
  (let ((head (subseq text 0 (min 80 (length text)))))
    (and (cl-ppcre:scan *negation-scanner* head) t)))

(defun detect-verbal-correction (text)
  "Classify TEXT as a correction, returning (values class confidence) or NIL.
The sharper `use X (instead of|not) Y` form yields (:substitute \"X|Y\")."
  (when (and (stringp text) (plusp (length (trim text))))
    (multiple-value-bind (match groups)
        (cl-ppcre:scan-to-strings *substitute-scanner* text)
      (cond
        (match
         (values (list :substitute
                       (format nil "~A|~A"
                               (string-downcase (normalize-token (aref groups 0)))
                               (string-downcase (normalize-token (aref groups 1)))))
                 :high))
        ((verbal-negation-p text)
         (values (list :verbal (first-n-words text 6)) :medium))
        (t nil)))))

(defun recent-tool-call-p (&key (within 10))
  "True when any of the last WITHIN events is a tool call — a correction
corrects *something*."
  (find :tool-call (recent-events :limit within)
        :key (lambda (event) (pget event :kind))))

(defun last-tool-name (&key (within 10))
  (let ((call (find :tool-call (recent-events :limit within)
                    :key (lambda (event) (pget event :kind)))))
    (and call (pget call :tool))))

(defun maybe-log-correction (text)
  "Called right after a :user-message is logged: if TEXT reads as a correction
and the user was in fact working (a recent tool call), record it."
  (when (recent-tool-call-p)
    (multiple-value-bind (class confidence) (detect-verbal-correction text)
      (when class
        (log-event :correction
                   :class class
                   :text (truncate-string (trim text) *correction-max-text*)
                   :ref-tool (last-tool-name)
                   :confidence confidence)))))


(defun events->turns (events)
  "Split EVENTS (oldest first) into turns: a list of (user-event tool-events…).
Leading tool calls with no preceding user message are ignored."
  (let ((turns '()) (current nil))
    (dolist (event events (nreverse (mapcar #'nreverse
                                            (if current (cons current turns) turns))))
      (case (pget event :kind)
        (:user-message
         (when current (push current turns))
         (setf current (list event)))
        (:tool-call
         (when current (push event current)))))))

(defun turn-user-text (turn)
  (pget (first turn) :text))             ; user event is first after normalization

(defun turn-tool-calls (turn)
  (remove :user-message turn :key (lambda (e) (pget e :kind))))

(defun tool-arg-value (event key)
  (pget (pget event :args) key))

(defun turn-write-paths (turn)
  "Paths written/edited in TURN (edit_file / write_file :path args)."
  (loop for call in (turn-tool-calls turn)
        when (member (pget call :tool) '("edit_file" "write_file") :test #'equal)
          collect (tool-arg-value call :path)))

(defun path-type (path)
  "The pathname type (extension) of a path string, or the whole string."
  (or (ignore-errors (pathname-type (pathname path))) path))

(defun detect-rework-file (events)
  "Detector 2: this turn edited a path the previous turn also wrote and the
turn opened with a negation → (:rework-file <path-type>)."
  (let* ((turns (last (events->turns events) 2)))
    (when (= (length turns) 2)
      (destructuring-bind (prev this) turns
        (let* ((this-paths (turn-write-paths this))
               (prev-paths (turn-write-paths prev))
               (shared (intersection this-paths prev-paths :test #'equal)))
          (when (and shared (verbal-negation-p (or (turn-user-text this) "")))
            (list :rework-file (path-type (first shared)))))))))

(defun shell-first-word (call)
  (let ((command (tool-arg-value call :command)))
    (and (stringp command)
         (first (remove "" (cl-ppcre:split "\\s+" (trim command))
                        :test #'string=)))))

(defun turn-shell-calls (turn)
  (remove-if-not (lambda (e) (equal (pget e :tool) "shell"))
                 (turn-tool-calls turn)))

(defun detect-command-preference (events)
  "Detector 3: this turn's shell command's first word differs from the
previous turn's, after a negation → (:command-preference <new-first-word>)."
  (let ((turns (last (events->turns events) 2)))
    (when (= (length turns) 2)
      (destructuring-bind (prev this) turns
        (let* ((this-shell (first (turn-shell-calls this)))
               (prev-shell (first (turn-shell-calls prev)))
               (this-word (and this-shell (shell-first-word this-shell)))
               (prev-word (and prev-shell (shell-first-word prev-shell))))
          (when (and this-word prev-word
                     (not (equal this-word prev-word))
                     (verbal-negation-p (or (turn-user-text this) "")))
            (list :command-preference this-word)))))))

(defvar *dream-classify-corrections* t
  "When true, dream mode re-scans recent user messages for corrections that
the interactive path missed (e.g. no tool call was recent at the time). Kept
deterministic — no LLM call — so the interactive path stays LLM-free (PR-13).")

(defun already-logged-correction-p (text)
  (find (truncate-string (trim text) *correction-max-text*)
        (recent-events :kind :correction :limit 200)
        :key (lambda (event) (pget event :text)) :test #'equal))

(defun backfill-corrections (&key (within 20))
  "Dream-time enrichment: classify the last WITHIN user messages and log any
correction not already captured. Returns the number newly logged."
  (when *dream-classify-corrections*
    (let ((logged 0))
      (dolist (event (recent-events :kind :user-message :limit within) logged)
        (let ((text (pget event :text)))
          (multiple-value-bind (class confidence) (detect-verbal-correction text)
            (when (and class (not (already-logged-correction-p text)))
              (log-event :correction :class class
                                     :text (truncate-string (trim text)
                                                            *correction-max-text*)
                                     :confidence confidence)
              (incf logged))))))))

(defun log-turn-corrections (&key (events (recent-events :limit 200)))
  "Run the turn-structural detectors over EVENTS (newest first) and log any
correction found. Called from the agent at turn end."
  (let* ((ordered (reverse events))         ; oldest first for turn splitting
         (text (or (turn-user-text (car (last (events->turns ordered)))) "")))
    ;; If MAYBE-LOG-CORRECTION already captured this same user turn at message
    ;; time (a `use X not Y` / verbal negation), skip the turn-structural
    ;; classes — otherwise one intent lands as two overlapping :correction
    ;; events and the miner proposes competing near-duplicate genes.
    (unless (already-logged-correction-p text)
      (dolist (class (remove nil (list (detect-rework-file ordered)
                                       (detect-command-preference ordered))))
        (log-event :correction
                   :class class
                   :text text
                   :confidence :medium)))))
