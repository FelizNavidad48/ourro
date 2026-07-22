
(in-package #:ourro.agent)

(defclass tool-output-pager ()
  ((agent :initarg :agent :accessor pager-agent)
   (items :initarg :items :initform '() :accessor pager-items
          :documentation "Snapshot of the tool-output ring, newest first.")
   (index :initarg :index :initform 0 :accessor pager-index
          :documentation "Which ring entry is shown.")
   (scroll :initform 0 :accessor pager-scroll
           :documentation "Index of the first result line rendered.")))

(defun make-tool-output-pager (agent &optional n)
  "Open a pager over AGENT's tool-output ring. When N is a result index (the
[N] label on a ↳ line), start on that entry; otherwise start on the newest."
  (let* ((items (agent-tool-results agent))
         (index (or (and n (position n items :key (lambda (e) (pget e :n))
                                     :test #'eql))
                    0)))
    (make-instance 'tool-output-pager :agent agent :items items :index index)))

(defun pager-selected (pager)
  (let ((items (pager-items pager)))
    (and items (nth (pager-index pager) items))))


(defmethod ourro.tui:render-component ((pager tool-output-pager) width)
  (let ((out '())
        (item (pager-selected pager)))
    (flet ((emit (style text) (push (list (ourro.tui:styled style text)) out)))
      (cond
        ((null item)
         (emit :header " tool output · (no tool calls yet) · q close"))
        (t
         (emit :header
               (format nil " tool output [~A/~A] ~A · j/k scroll · [ ] older/newer · q close"
                       (1+ (pager-index pager)) (length (pager-items pager))
                       (pget item :name)))
         (let ((args (pget item :args)))
           (when (and args (plusp (length args)))
             (emit :dim (format nil "   ~A"
                                (truncate-string args (max 1 (- width 4)))))))
         (let* ((result (or (pget item :result) ""))
                (lines (uiop:split-string (string-right-trim '(#\Newline) result)
                                          :separator '(#\Newline)))
                (style (if (pget item :error-p) :danger :code)))
           ;; Render lines from SCROLL onward; the overlay path clips to the
           ;; transcript region, and render-line-string truncates each to WIDTH.
           (loop for line in (nthcdr (pager-scroll pager) lines)
                 do (emit style (format nil "  ~A" line)))))))
    (nreverse out)))


(defun pager-move (pager delta)
  "Walk to an adjacent ring entry (older/newer), resetting the line scroll."
  (let ((n (length (pager-items pager))))
    (when (plusp n)
      (setf (pager-index pager)
            (max 0 (min (1- n) (+ (pager-index pager) delta)))
            (pager-scroll pager) 0))))

(defun pager-result-line-count (pager)
  "Number of result lines in the selected entry (0 if none)."
  (let ((item (pager-selected pager)))
    (if item
        (length (uiop:split-string
                 (string-right-trim '(#\Newline) (or (pget item :result) ""))
                 :separator '(#\Newline)))
        0)))

(defun pager-scroll-by (pager delta)
  "Scroll the result body, clamped to [0, lines-1] so j/wheel past the end
can't scroll into a blank void (M7-5 review #3)."
  (let ((max-scroll (max 0 (1- (pager-result-line-count pager)))))
    (setf (pager-scroll pager)
          (max 0 (min max-scroll (+ (pager-scroll pager) delta))))))

(defmethod ourro.tui:overlay-key ((pager tool-output-pager) key)
  "Modal key handling: q/escape/ctrl-o close; j/k/wheel/pgup/pgdn scroll the
result; [ / ] walk to the older / newer entry."
  (case key
    ((#\q :escape :ctrl-o) :close)
    ((#\j :down :wheel-down) (pager-scroll-by pager 1) :handled)
    ((#\k :up :wheel-up) (pager-scroll-by pager -1) :handled)
    (:page-down (pager-scroll-by pager 10) :handled)
    (:page-up (pager-scroll-by pager -10) :handled)
    (#\] (pager-move pager -1) :handled)   ; newer (toward index 0)
    (#\[ (pager-move pager 1) :handled)    ; older (toward the end)
    (t :handled)))                          ; modal: swallow everything else


(defun open-pager (agent &optional n)
  (setf (ourro.tui:view-overlay (agent-view agent))
        (make-tool-output-pager agent n))
  (enqueue-ui agent '(:kind :dirty)))

(defun toggle-pager (agent)
  "ctrl-o toggles the pager (closing any other overlay first)."
  (if (typep (ourro.tui:view-overlay (agent-view agent)) 'tool-output-pager)
      (close-inspector agent)           ; overlay-agnostic: clears the slot
      (open-pager agent)))

(defun open-job-pager (agent item)
  "Page a single synthesized job-log ITEM through the tool-output pager (/out
j1, M9-4). ITEM is a ring-shaped plist (:n :name :args :result :error-p)."
  (setf (ourro.tui:view-overlay (agent-view agent))
        (make-instance 'tool-output-pager :agent agent :items (list item) :index 0))
  (enqueue-ui agent '(:kind :dirty)))
