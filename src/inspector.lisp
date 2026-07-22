
(in-package #:ourro.agent)

(defclass evolution-inspector ()
  ((agent :initarg :agent :accessor inspector-agent)
   (items :initarg :items :initform '() :accessor inspector-items
          :documentation "Candidate records (M1-3), newest first.")
   (cursor :initform 0 :accessor inspector-cursor)
   (expanded :initform nil :accessor inspector-expanded
             :documentation "When true, the cursor's row shows its detail.")
   (scroll :initform 0 :accessor inspector-scroll
           :documentation "Index of the first item rendered.")))

(defun make-evolution-inspector (agent)
  (make-instance 'evolution-inspector
                 :agent agent
                 :items (agent-candidates agent)))

(defun inspector-selected (insp)
  (let ((items (inspector-items insp)))
    (and items (nth (inspector-cursor insp) items))))


(defun inspector-status-glyph (record)
  "Return (values glyph style) for RECORD's status. Frozen genes win."
  (let ((name (pget record :gene-name)))
    (cond
      ((and name (ignore-errors (ourro.observe:gene-frozen-p name)))
       (values "❄" :accent))
      (t (case (pget record :status)
           ((:hot-loaded :snapshotted) (values "✓" :success))
           ((:verified :staged) (values "◐" :accent))
           (:rejected (values "✗" :danger))
           (:reverted (values "↩" :warning))
           (:dismissed (values "⨯" :dim))
           (:duplicate (values "≡" :dim))
           (t (values "·" :dim)))))))

(defun inspector-lines-of (text &optional (limit most-positive-fixnum))
  "The first LIMIT non-trailing-empty lines of TEXT."
  (let ((lines (uiop:split-string (string-right-trim '(#\Newline) (or text ""))
                                  :separator '(#\Newline))))
    (subseq lines 0 (min limit (length lines)))))

(defun inspector-intended-name (record)
  "The gene name a candidate meant to install, parsed from its :source, for
records that never got a :gene-name (e.g. a rejected candidate). NIL if the
source is absent or unparseable."
  (let ((src (pget record :source)))
    (when src
      (ignore-errors
       (ourro.genome:gene-name (ourro.genome:parse-gene-source src))))))

(defun inspector-diff-text (record)
  "Render RECORD's structural diff: the gene it installed versus the gene it
overwrote (:previous-source, captured before hot-load in M1-3). A brand-new
gene renders as an addition."
  (let ((current-src (pget record :source))
        (previous-src (pget record :previous-source)))
    (when current-src
      (ignore-errors
       (let* ((current (ourro.genome:parse-gene-source current-src))
              (previous (and previous-src
                             (ourro.genome:parse-gene-source previous-src)))
              (diff (ourro.genome:genome-diff (and previous (list previous))
                                             (list current))))
         (string-right-trim '(#\Newline)
                            (ourro.genome:describe-genome-diff diff)))))))

(defun inspector-evidence (record)
  "Human evidence lines from the pattern that triggered RECORD."
  (let ((evidence (pget (pget record :pattern) :evidence)))
    (loop for e in evidence
          collect (let ((text (pget e :text))
                        (tool (pget e :tool))
                        (ms (pget e :elapsed-ms)))
                    (truncate-string
                     (cond
                       (text (format nil "you said: ~A" text))
                       (tool (format nil "you did: ~A ~@[~A~]~@[ (~Ams)~]"
                                     tool
                                     (let ((a (pget e :args)))
                                       (and a (truncate-string
                                               (princ-to-string a) 50)))
                                     ms))
                       (t (princ-to-string e)))
                     90)))))

(defun inspector-detail-lines (record)
  "The expanded detail block for RECORD (diff · evidence · tests · provenance)."
  (let ((out '()))
    (flet ((emit (style text)
             (push (list (ourro.tui:styled style (format nil "    ~A" text)))
                   out)))
      (let ((diff (inspector-diff-text record)))
        (when diff
          (emit :dim "── structural diff ──")
          (dolist (l (inspector-lines-of diff 12)) (emit :tool l))))
      (let ((evidence (inspector-evidence record)))
        (when evidence
          (emit :dim "── evidence ──")
          (dolist (l evidence) (emit :dim l))))
      (let ((report (pget record :report)))
        (when (and report (plusp (length report)))
          (emit :dim "── tests ──")
          (dolist (l (inspector-lines-of report 8)) (emit :dim l))))
      (let ((diag (pget record :diagnostics)))
        (when (and diag (plusp (length diag)))
          (emit :dim "── diagnostics ──")
          (dolist (l (inspector-lines-of diag 6)) (emit :warning l))))
      (let ((pattern (pget record :pattern)))
        (emit :dim (format nil "pattern ~A · gen ~A · ~A"
                           (or (pget pattern :id) "—")
                           (or (pget record :generation-id) "—")
                           (or (pget record :time) "—")))))
    (nreverse out)))

(defmethod ourro.tui:render-component ((insp evolution-inspector) width)
  (declare (ignore width))
  (let ((out '())
        (items (inspector-items insp))
        (cursor (inspector-cursor insp)))
    (flet ((emit (style text) (push (list (ourro.tui:styled style text)) out)))
      (emit :header
            " evolutions · j/k move · enter detail · u undo · r retry · f freeze/unfreeze · a apply · q close")
      (cond
        ((null items)
         (emit :dim "   (no evolutions yet — keep working and patterns will appear)"))
        (t
         (loop for record in (nthcdr (inspector-scroll insp) items)
               for index from (inspector-scroll insp)
               do (multiple-value-bind (glyph style) (inspector-status-glyph record)
                    (let ((name (or (pget record :gene-name)
                                    (if (eq (pget record :status) :duplicate)
                                        (truncate-string
                                         (or (pget record :diagnostics) "(duplicate)")
                                         70)
                                        (let ((intended (inspector-intended-name record)))
                                          (if intended
                                              (format nil "~A (not installed)" intended)
                                              "(no gene)")))))
                          (util (let ((n (pget record :gene-name)))
                                  (and n (gene-utility-summary n))))
                          (selected (= index cursor)))
                      (emit (if selected :accent style)
                            (format nil " ~A~A ~A~@[  · ~A~]"
                                    (if selected "▸ " "  ")
                                    glyph name util))))
                  (when (and (= index cursor) (inspector-expanded insp))
                    (dolist (dl (inspector-detail-lines record)) (push dl out)))))))
    (nreverse out)))


(defun inspector-page-size (insp)
  (let ((screen (agent-screen (inspector-agent insp))))
    (max 4 (- (if screen (ourro.tui:screen-height screen) 24) 8))))

(defun inspector-follow-cursor (insp)
  "Keep the cursor within the visible window by adjusting SCROLL."
  (let ((page (inspector-page-size insp))
        (cursor (inspector-cursor insp)))
    (cond ((< cursor (inspector-scroll insp))
           (setf (inspector-scroll insp) cursor))
          ((>= cursor (+ (inspector-scroll insp) page))
           (setf (inspector-scroll insp) (max 0 (1+ (- cursor page))))))))

(defun inspector-move (insp delta)
  (let ((n (length (inspector-items insp))))
    (when (plusp n)
      (setf (inspector-cursor insp)
            (max 0 (min (1- n) (+ (inspector-cursor insp) delta)))
            (inspector-expanded insp) nil)
      (inspector-follow-cursor insp))))

(defmethod ourro.tui:overlay-key ((insp evolution-inspector) key)
  "Modal key handling. Returns :close to dismiss, :handled otherwise."
  (let ((agent (inspector-agent insp))
        (record (inspector-selected insp)))
    (case key
      ((#\q :escape) :close)
      ((#\j :down :wheel-down) (inspector-move insp 1) :handled)
      ((#\k :up :wheel-up) (inspector-move insp -1) :handled)
      ((:enter #\Return)
       (setf (inspector-expanded insp) (not (inspector-expanded insp)))
       :handled)
      (#\u (when record (inspector-undo agent record insp)) :handled)
      (#\r (when record (inspector-retry agent record)) :handled)
      (#\f (when record (inspector-freeze agent record)) :handled)
      (#\a (when record (inspector-apply-staged agent record)) :handled)
      (t :handled))))                   ; modal: swallow everything else

(defun inspector-refresh (insp)
  "Re-pull the candidate list after an action mutated it."
  (setf (inspector-items insp) (agent-candidates (inspector-agent insp)))
  (setf (inspector-cursor insp)
        (max 0 (min (inspector-cursor insp)
                    (1- (max 1 (length (inspector-items insp))))))))

(defun inspector-undo (agent record insp)
  "Revert the selected gene (u) — through the same revert table as any gene."
  (let ((name (pget record :gene-name)))
    (cond
      ((null name) (set-ticker agent "nothing to revert on this entry" :style :dim :seconds 4))
      ((member (pget record :status) '(:reverted :rejected))
       (set-ticker agent (format nil "~A is not live" name) :style :dim :seconds 4))
      (t (let ((count (ourro.kernel:revert-gene-definitions name))
               (reverted (plist-put record :status :reverted))
               (id (pget record :id)))
           (ourro.observe:note-gene-revert name)
           ;; Match the live entry by :id, not object identity: the evolver may
           ;; have rebuilt the list with a fresh plist for this same id since the
           ;; overlay opened, leaving the snapshot's RECORD un-EQL to any live
           ;; element — an EQL SUBSTITUTE would then drop the revert (review #3).
           (bt:with-lock-held ((agent-candidates-lock agent))
             (setf (agent-candidates agent)
                   (if id
                       (mapcar (lambda (r)
                                 (if (equal id (pget r :id)) reverted r))
                               (agent-candidates agent))
                       (substitute reverted record (agent-candidates agent)))))
           (ignore-errors
            (append-sexp-line (ourro.evolve:candidate-records-path) reverted))
           (refresh-system-prompt agent)
           (set-ticker agent (format nil "reverted ~A (~A definition~:P undone)"
                                     name count)
                       :style :success :seconds 8)
           (inspector-refresh insp))))))

(defun inspector-retry (agent record)
  "Re-enqueue the pattern with the prior diagnostics as feedback (r)."
  (let ((pattern (pget record :pattern)))
    (cond
      ((null pattern) (set-ticker agent "no pattern to retry" :style :dim :seconds 4))
      (t (ourro.evolve:enqueue-pattern
          (plist-put pattern :retry-feedback (pget record :diagnostics)))
         (update-pending agent)
         (spawn-evolver agent)
         (set-ticker agent "retrying with the prior failure as feedback…"
                     :style :accent :seconds 6)))))

(defun inspector-freeze (agent record)
  "Toggle the selected gene's frozen flag (f): frozen genes are never
auto-retired; pressing f again unfreezes."
  (let ((name (pget record :gene-name)))
    (if name
        (let ((freeze (not (ignore-errors (ourro.observe:gene-frozen-p name)))))
          (ourro.observe:set-gene-frozen name freeze)
          (set-ticker agent
                      (if freeze
                          (format nil "❄ froze ~A — will not auto-retire · f again to unfreeze" name)
                          (format nil "unfroze ~A — auto-retirement applies again" name))
                      :style :accent :seconds 6))
        (set-ticker agent "no gene to freeze on this entry" :style :dim :seconds 4))))

(defun inspector-apply-staged (agent record)
  "Apply a staged (◐ verified, or M14-2 :staged reflex) candidate (a). Delegates
to the shared INSTALL-STAGED-CANDIDATE — the same path the consent ticker's y
key uses — so re-verify + hot-load logic lives in one place."
  (cond
    ((not (member (pget record :status) '(:verified :staged)))
     (set-ticker agent "only staged (◐) candidates can be applied" :style :dim :seconds 5))
    (t (install-staged-candidate agent record))))
