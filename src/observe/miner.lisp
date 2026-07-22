
(defpackage #:ourro.miner
  (:use #:cl #:ourro.util)
  (:import-from #:ourro.observe #:recent-events)
  (:export #:mine-patterns
           #:*support-threshold*
           #:pattern-id
           #:pattern-signature
           #:pattern-benefit-estimate
           #:argument-skeleton
           #:skeletons-unify-p
           #:mine-reactions
           #:*reaction-window*
           #:skeleton->trigger-args))

(in-package #:ourro.miner)

(defparameter *support-threshold* 3
  "Minimum number of occurrences before a pattern becomes a candidate.")

(defparameter *max-gram* 4)

(defun tool-call-events (events)
  "Extract completed tool-call events, oldest first."
  (nreverse
   (remove-if-not (lambda (event)
                    (and (eq (pget event :kind) :tool-call)
                         (eq (pget event :outcome) :ok)))
                  events)))


(defun argument-skeleton (args)
  "Normalize ARGS (a plist) into a sorted alist of (key . value)."
  (let ((pairs '()))
    (loop for (key value) on args by #'cddr
          do (push (cons key value) pairs))
    (sort pairs #'string< :key (lambda (pair) (princ-to-string (car pair))))))

(defun unify-skeletons (a b)
  "Anti-unify two skeletons; returns the generalization or NIL when the
keys differ."
  (when (equal (mapcar #'car a) (mapcar #'car b))
    (mapcar (lambda (pair-a pair-b)
              (cons (car pair-a)
                    (if (equal (cdr pair-a) (cdr pair-b))
                        (cdr pair-a)
                        :?)))
            a b)))

(defun skeletons-unify-p (a b)
  (not (null (unify-skeletons a b))))


(defun call-signature (event)
  (pget event :tool))

(defun event-elapsed (event)
  (or (pget event :elapsed-ms) 0))

(defun mine-repeated-commands (calls)
  "Same tool, unifiable args, ≥ threshold occurrences."
  (let ((groups (make-hash-table :test #'equal))
        (patterns '()))
    (dolist (call calls)
      (push call (gethash (call-signature call) groups)))
    (maphash
     (lambda (tool group)
       (when (>= (length group) *support-threshold*)
         ;; Anti-unify all argument skeletons in the group.
         (let* ((skeletons (mapcar (lambda (call)
                                     (argument-skeleton (pget call :args)))
                                   group))
                (unified (reduce (lambda (a b) (and a (unify-skeletons a b)))
                                 (rest skeletons)
                                 :initial-value (first skeletons))))
           (when unified
             (push (make-pattern :repeated-command
                                 :tools (list tool)
                                 :skeleton unified
                                 :occurrences group)
                   patterns)))))
     groups)
    patterns))

(defun mine-repeated-sequences (calls)
  "N-grams (2..*MAX-GRAM*) of consecutive tool names repeated ≥ threshold."
  (let ((names (map 'vector #'call-signature calls))
        (patterns '()))
    (loop for n from 2 to *max-gram* do
      (let ((grams (make-hash-table :test #'equal)))
        (loop for i from 0 to (- (length names) n)
              for gram = (coerce (subseq names i (+ i n)) 'list)
              ;; Skip degenerate grams (a single tool repeated is a
              ;; :repeated-command, not a sequence).
              unless (every (lambda (x) (equal x (first gram))) gram)
                do (push i (gethash gram grams)))
        (maphash
         (lambda (gram starts)
           (when (>= (length (non-overlapping starts n)) *support-threshold*)
             (let ((occurrences
                     (mapcar (lambda (start)
                               (subseq calls start (+ start n)))
                             (non-overlapping starts n))))
               (push (make-pattern :repeated-sequence
                                   :tools gram
                                   :occurrences (apply #'append occurrences)
                                   :sequence-count (length occurrences))
                     patterns))))
         grams)))
    patterns))

(defun non-overlapping (starts n)
  "Greedy selection of non-overlapping window starts (STARTS is newest-last
after the push loop reversed them; sort first)."
  (let ((sorted (sort (copy-list starts) #'<))
        (chosen '())
        (next-free 0))
    (dolist (start sorted (nreverse chosen))
      (when (>= start next-free)
        (push start chosen)
        (setf next-free (+ start n))))))

(defun mine-corrections (events)
  "User corrections of the same class repeated ≥ 2 times."
  (let ((corrections (remove-if-not
                      (lambda (event) (eq (pget event :kind) :correction))
                      events))
        (groups (make-hash-table :test #'equal))
        (patterns '()))
    (dolist (correction corrections)
      (push correction (gethash (pget correction :class) groups)))
    (maphash (lambda (class group)
               (when (>= (length group) 2)
                 (push (make-pattern :correction
                                     :correction-class class
                                     :occurrences group)
                       patterns)))
             groups)
    patterns))

(defparameter *slow-tool-median-ms* 2000
  "A (tool, arg-skeleton) group whose median call time exceeds this — with
support ≥ *support-threshold* — is a :slow-tool pattern (M12-6).")

(defun median-elapsed (occurrences)
  "Median :elapsed-ms across OCCURRENCES (0 if none) — robust to the odd slow
outlier, unlike the mean."
  (let ((sorted (sort (mapcar #'event-elapsed occurrences) #'<)))
    (if (null sorted)
        0
        (let ((n (length sorted)))
          (if (oddp n)
              (nth (floor n 2) sorted)
              (round (+ (nth (1- (floor n 2)) sorted) (nth (floor n 2) sorted)) 2))))))

(defun mine-slow-tools (calls)
  "Same tool + argument skeleton whose MEDIAN call time is slow (> ~2s) over
≥ *support-threshold* occurrences — a call that is slow FOR THIS USER, worth a
caching/batching/narrowing gene. Efficiency becomes a mined pattern family, and
the benefit estimate is the measured median, not a guess (M12-6)."
  (let ((groups (make-hash-table :test #'equal))
        (patterns '()))
    (dolist (call calls)
      (push call (gethash (list (call-signature call)
                                (argument-skeleton (pget call :args)))
                          groups)))
    (maphash
     (lambda (key group)
       (when (and (>= (length group) *support-threshold*)
                  (> (median-elapsed group) *slow-tool-median-ms*))
         (push (make-pattern :slow-tool
                             :tools (list (first key))
                             :skeleton (second key)
                             :occurrences group)
               patterns)))
     groups)
    patterns))


(defparameter *reaction-window* 10
  "How many events after a trigger A to scan for the reaction B (roughly two
turns of tool activity).")

(defun reaction-trigger-event-p (event)
  "A is trigger-shaped: an :ok tool call, or a job that exited non-zero."
  (or (and (eq (pget event :kind) :tool-call) (eq (pget event :outcome) :ok))
      (and (eq (pget event :kind) :job-exit)
           (let ((exit (pget event :exit)))
             (not (eql exit 0))))))

(defun reaction-a-key (event)
  "The grouping key for a trigger event A: its tool (or :job-exit)."
  (if (eq (pget event :kind) :job-exit)
      :job-exit
      (pget event :tool)))

(defun skeleton->trigger-args (skeleton)
  "Turn an anti-unified argument SKELETON (alist (key . value-or-:?)) into a
trigger-pattern :args plist keeping only the CONSTANT slots — the varying (:?)
slots are dropped, so the derived trigger matches the stable part."
  (let ((args '()))
    (dolist (pair skeleton)
      (unless (eq (cdr pair) :?)
        (push (car pair) args)
        (push (cdr pair) args)))
    (nreverse args)))

(defun derive-trigger-shape (a-key a-events)
  "The :on pattern data for a group of trigger events A. For job-exit: the
non-zero-exit shape. For a tool: :ok on that tool, plus any argument slots that
are constant across the whole group (anti-unified)."
  (if (eq a-key :job-exit)
      (list :kind :job-exit :exit '(:not 0))
      (let* ((skeletons (mapcar (lambda (e) (argument-skeleton (pget e :args)))
                                a-events))
             (unified (reduce (lambda (x y) (and x (unify-skeletons x y)))
                              (rest skeletons)
                              :initial-value (first skeletons)))
             (args (and unified (skeleton->trigger-args unified))))
        (append (list :kind :tool-call :tool a-key :outcome :ok)
                (when args (list :args args))))))

(defun mine-reactions (events)
  "Mine (A → B) reaction pairs (M14-3): after trigger-shaped A, the first later
tool-call B (within *REACTION-WINDOW* events, and — when A is itself a tool —
a DIFFERENT tool than A). Group by (A-key, B-tool, B-skeleton); ≥ threshold
supported groups become :reaction patterns whose trigger is A's derived shape
and whose action is B, with the measured mean B cost as the benefit to beat."
  (let* ((ordered (coerce (reverse events) 'vector))   ; oldest first
         (n (length ordered))
         (groups (make-hash-table :test #'equal))
         (consumed (make-hash-table))   ; B indices already paired (review F1)
         (patterns '()))
    (loop for i from 0 below n
          for a = (aref ordered i)
          when (reaction-trigger-event-p a) do
            (let ((a-key (reaction-a-key a)))
              (loop for j from (1+ i) to (min (1- n) (+ i *reaction-window*))
                    for b = (aref ordered j)
                    ;; Each B is paired with at most ONE A, so N triggers before a
                    ;; single reaction count as ONE episode, not N — the ≥3
                    ;; threshold means three INDEPENDENT trigger→reaction pairs.
                    when (and (not (gethash j consumed))
                              (eq (pget b :kind) :tool-call)
                              (eq (pget b :outcome) :ok)
                              (or (eq a-key :job-exit)
                                  (not (equal (pget b :tool) a-key))))
                      do (setf (gethash j consumed) t)
                         (push (cons a b)
                               (gethash (list a-key (pget b :tool)
                                              (argument-skeleton (pget b :args)))
                                        groups))
                         (return)))) ; first unconsumed qualifying B only
    (maphash
     (lambda (key pairs)
       (when (>= (length pairs) *support-threshold*)
         (let* ((a-key (first key))
                (a-events (mapcar #'car pairs))
                (b-events (mapcar #'cdr pairs))
                (trigger (derive-trigger-shape a-key a-events)))
           (push (make-pattern :reaction
                               :tools (list (second key))
                               :skeleton (third key)
                               :trigger-shape trigger
                               :reaction-tool (second key)
                               :reaction-skeleton (third key)
                               :occurrences b-events)
                 patterns))))
     groups)
    patterns))

(defun make-pattern (kind &key tools skeleton occurrences correction-class
                               sequence-count trigger-shape reaction-tool
                               reaction-skeleton)
  (let* ((count (or sequence-count (length occurrences)))
         (total-elapsed (reduce #'+ occurrences :key #'event-elapsed
                                                :initial-value 0))
         (mean-elapsed (if occurrences
                           (round total-elapsed (max 1 (length occurrences)))
                           0))
         ;; The cost of one manual occurrence of the pattern — the baseline a
         ;; gene automating it must beat (M1-1). For a repeated command that
         ;; is the mean call cost; for a sequence it is the summed cost of one
         ;; window (occurrences holds every window's events flattened).
         (occurrence-cost (cond
                            ((eq kind :repeated-sequence)
                             (round total-elapsed (max 1 count)))
                            ;; A slow tool's baseline IS its measured median —
                            ;; the honest payback a faster gene must beat (M12-6).
                            ((eq kind :slow-tool) (median-elapsed occurrences))
                            ;; A reaction's baseline is the mean cost of the
                            ;; manual B each firing pre-empts (M14-3 / D-R8).
                            ((eq kind :reaction) mean-elapsed)
                            (t mean-elapsed))))
    (list :id (make-id "pat")
          :kind kind
          :tools tools
          :skeleton skeleton
          :trigger-shape trigger-shape
          :reaction-tool reaction-tool
          :reaction-skeleton reaction-skeleton
          :correction-class correction-class
          :count count
          :mean-elapsed-ms mean-elapsed
          :occurrence-cost-ms occurrence-cost
          ;; frequency × cost — the ranking signal
          :score (* count (max 1 mean-elapsed))
          :evidence (mapcar (lambda (event)
                              (list :time (pget event :time)
                                    :tool (pget event :tool)
                                    :args (pget event :args)
                                    :text (pget event :text)
                                    :elapsed-ms (event-elapsed event)))
                            (last occurrences (min 5 (length occurrences)))))))

(defun pattern-id (pattern) (pget pattern :id))

(defun pattern-signature (pattern)
  "A stable identity for what a pattern IS — kind + tools + argument skeleton
(+ correction class / onboarding gene) — unlike :id, which is a fresh random
token on every mining pass. Two mining passes over overlapping event windows
produce the same signature for the same behavior, so signatures are the dedup
key that stops the evolver re-learning the same tool over and over."
  (let ((*print-pretty* nil))
    (string-downcase
     (prin1-to-string (list (pget pattern :kind)
                            (pget pattern :tools)
                            (pget pattern :skeleton)
                            ;; The trigger shape distinguishes two reactions with
                            ;; the same action but different triggers (M14-3), so
                            ;; the dedup gate never conflates them.
                            (pget pattern :trigger-shape)
                            (pget pattern :correction-class)
                            (pget pattern :gene-name))))))

(defun pattern-benefit-estimate (pattern)
  "Human-readable benefit estimate for the ticker."
  (let ((ms (pget pattern :mean-elapsed-ms 0)))
    (if (plusp ms)
        (format nil "saves ~~~As/use" (max 1 (round ms 1000)))
        "reduces manual steps")))

(defun mine-patterns-in-context (events workspace)
  "Mine one workspace cohort, attaching context and support confidence."
  (let* ((calls (tool-call-events events))
         (patterns (append (mine-repeated-commands calls)
                           (mine-repeated-sequences calls)
                           (mine-slow-tools calls)
                           (mine-reactions events)
                           (mine-corrections events))))
    (mapcar (lambda (pattern)
              (let* ((count (pget pattern :count 0))
                     (confidence (/ count (+ count *support-threshold*))))
                (plist-put
                 (plist-put pattern :workspace workspace)
                 :confidence confidence)))
            patterns)))

(defun mine-patterns (&key (events (recent-events :limit 2000)))
  "Mine EVENTS (newest first) without mixing evidence across workspaces.
Legacy events lacking :WORKSPACE form their own cohort rather than contaminating
the active project's behavior model."
  (let ((groups (make-hash-table :test #'equal))
        (patterns '()))
    (dolist (event events)
      (push event (gethash (or (pget event :workspace) :legacy) groups)))
    (maphash (lambda (workspace cohort)
               (setf patterns
                     (nconc (mine-patterns-in-context (nreverse cohort) workspace)
                            patterns)))
             groups)
    (sort patterns #'> :key (lambda (pattern) (pget pattern :score 0)))))
