
(in-package #:ourro.verify)

(export '(record-tool-trace
          replay-tool-trace
          verify-determinism
          replay-session
          compare-traces
          replayable-tool-p
          *replayable-tools*
          kernel-touching-p
          *kernel-symbols*))


(defun record-tool-trace (tool-name args)
  "Run TOOL-NAME with ARGS once and capture (args . result) as a trace."
  (multiple-value-bind (result error-p)
      (ourro.tools:execute-tool-call tool-name args)
    (list :tool tool-name :args args :result result :error-p error-p)))

(defun replay-tool-trace (trace)
  "Re-run the tool call recorded in TRACE; return the fresh result string."
  (ourro.tools:execute-tool-call (pget trace :tool) (pget trace :args)))

(defun verify-determinism (tool-name args &key (runs 10))
  "Run TOOL-NAME with ARGS RUNS times; return (values deterministic-p results).
Deterministic when every run is byte-identical (PR-13 acceptance)."
  (let ((results (loop repeat runs
                       collect (ourro.tools:execute-tool-call tool-name args))))
    (values (every (lambda (r) (string= r (first results))) (rest results))
            results)))


(defun replay-session (events &key (limit 50))
  "Replay the tool calls recorded in EVENTS (as from OURRO.OBSERVE) against the
current image, returning a list of (tool args result) action traces. Only
side-effect-free-ish read tools are replayed; write/subprocess tools are
skipped to avoid re-executing real effects during a replay check."
  (let ((traces '())
        (count 0))
    (dolist (event events (nreverse traces))
      (when (>= count limit) (return (nreverse traces)))
      (when (and (eq (pget event :kind) :tool-call)
                 (replayable-tool-p (pget event :tool)))
        (let* ((tool (pget event :tool))
               (args (plist->hash (pget event :args))))
          (multiple-value-bind (result error-p)
              (ignore-errors (ourro.tools:execute-tool-call tool args))
            (push (list :tool tool :result result :error-p error-p) traces)
            (incf count)))))))

(defparameter *replayable-tools*
  '("read_file" "list_files" "search" "file_info")
  "Tools safe to re-execute during a replay comparison (no external effects).")

(defun replayable-tool-p (name)
  (member name *replayable-tools* :test #'equal))

(defun plist->hash (plist)
  (let ((hash (ourro.llm:json-object)))
    (loop for (key value) on plist by #'cddr
          do (setf (gethash (string-downcase (symbol-name key)) hash) value))
    hash))

(defun compare-traces (baseline candidate)
  "Compare two replay trace lists. Returns (values match-p divergences)."
  (let ((divergences '()))
    (loop for b in baseline
          for c in candidate
          unless (equal (pget b :result) (pget c :result))
            do (push (list :tool (pget b :tool)
                           :baseline (pget b :result)
                           :candidate (pget c :result))
                     divergences))
    (values (null divergences) (nreverse divergences))))


(defparameter *kernel-symbols*
  '("OURRO.KERNEL" "OURRO.SUPERVISOR" "OURRO.VERIFY")
  "Package-name prefixes whose modification requires the hardened path.")

(defun kernel-touching-p (source-text)
  "True when SOURCE-TEXT names any kernel/verifier/supervisor package —
such changes cannot be hot-loaded and must go through a child-process image
build + kernel suite + session replay. Genes never pass this (the walker
rejects the references first); this is the belt-and-braces classifier used
when deciding whether an evolution may take the fast in-image path."
  (some (lambda (prefix)
          (search prefix (string-upcase source-text)))
        *kernel-symbols*))
