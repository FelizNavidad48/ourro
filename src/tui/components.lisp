
(in-package #:ourro.tui)

(export '(view render-component overlay-key
          header-pane transcript-pane ticker-pane statusbar-pane input-pane
          make-view view-header view-transcript view-ticker view-statusbar
          view-input view-panes view-overlay
          *keymap* *commands* *reserved-keys*
          bind-key invoke-command keymap-command key-bindable-p
          ;; Evolvable UI surface (M3)
          pane pane-gene pane-visible add-pane remove-pane
          define-status-widget register-status-widget
          *active-view* *status-widgets* *ui-strike-limit*
          refresh-status-widgets status-widget-cells
          transcript-lines transcript-scroll
          ticker-text ticker-style ticker-actions ticker-expires
          statusbar-generation statusbar-repo statusbar-pending statusbar-mode
          statusbar-visiting statusbar-spinner statusbar-activity statusbar-scrolled
          transcript-last-total adjust-scroll-for-append
          input-text input-cursor input-placeholder input-suggestion
          input-history input-history-index input-history-stash
          input-set-text input-insert input-backspace input-delete-forward
          input-delete-word-back input-kill-to-line-end input-clear
          input-move input-line-home input-line-end input-word-move
          input-cursor-line-col input-line-count input-move-line
          set-transcript scroll-transcript
          wrap-text))

(defgeneric render-component (component width)
  (:documentation "Return a list of styled lines for COMPONENT at WIDTH."))

(defgeneric overlay-key (overlay key)
  (:documentation "Handle KEY for a modal OVERLAY (e.g. the evolution
inspector). Return :close to dismiss the overlay, :handled to swallow the key,
or NIL to let it fall through. A modal overlay should swallow everything.")
  (:method (overlay key) (declare (ignore overlay key)) nil))


(defparameter *reserved-keys*
  '(:enter :shift-enter :backspace :alt-backspace :ctrl-w :delete
    :left :right :word-left :word-right :home :end
    :ctrl-k :ctrl-u :tab :escape :ctrl-c :ctrl-d :ctrl-l
    :up :ctrl-p :down :ctrl-n :shift-up :shift-down :page-up :page-down
    :f1 :f2 :f3 :f4 :f5 :f6 :f7 :f8 :f9 :f10 :f11 :f12
    :ctrl-e :ctrl-o)
  "Keys the editor/scroll pipeline (or built-in bindings) already own;
BIND-KEY refuses these. The whole F-row is reserved — terminals, OSes, and
window managers already fight over F-keys, so genes may never claim them.
Bindable chords are :alt-<letter> and unused ctrl chords.")

(defvar *keymap* '()
  "Alist (chord-key . command-keyword). Chords only — never plain characters.")

(defvar *commands* (make-hash-table :test #'eq)
  "command-keyword → 0-arg thunk.")

(defun key-bindable-p (key)
  "A key is bindable only if it is a keyword chord that is not reserved and
not a printable character (characters can never be rebound — they type)."
  (and (keywordp key) (not (member key *reserved-keys*))))

(defun keymap-command (key)
  "The command keyword bound to KEY, or NIL."
  (cdr (assoc key *keymap*)))

(defun invoke-command (command)
  "Invoke COMMAND's thunk if one is registered. Returns T if it ran."
  (let ((thunk (gethash command *commands*)))
    (when thunk (funcall thunk) t)))

(defun bind-key (key command thunk &key gene)
  "Bind chord KEY to COMMAND (a keyword) with THUNK. Signals if KEY is
reserved or a printable character. GENE names the owning gene; when omitted it
is taken from the current gene context. With an owner, a revert-action is
recorded so reverting the gene restores the prior binding."
  (unless (key-bindable-p key)
    (error "Key ~S is reserved or not a bindable chord." key))
  (let ((previous (assoc key *keymap*))
        (owner (or gene (pget ourro.kernel:*current-gene-context* :name))))
    (setf (gethash command *commands*) thunk)
    (setf *keymap* (cons (cons key command)
                         (remove key *keymap* :key #'car)))
    (when owner
      (ourro.kernel:record-revert-action
       owner
       (lambda ()
         (setf *keymap* (remove key *keymap* :key #'car))
         (when previous (setf *keymap* (cons previous *keymap*))))
       :description (format nil "unbind ~S" key)))
    key))


(defclass header-pane ()
  ((statusbar :initarg :statusbar :accessor header-statusbar)))

(defclass statusbar-pane ()
  ((generation :initarg :generation :initform "gen-0001"
               :accessor statusbar-generation)
   (repo :initarg :repo :initform "" :accessor statusbar-repo)
   (pending :initarg :pending :initform 0 :accessor statusbar-pending)
   (mode :initarg :mode :initform :auto :accessor statusbar-mode)
   (visiting :initarg :visiting :initform nil :accessor statusbar-visiting)
   (spinner :initarg :spinner :initform nil :accessor statusbar-spinner)
   (activity :initarg :activity :initform nil :accessor statusbar-activity
             :documentation "Background work notice (e.g. evolution stage).")
   (scrolled :initarg :scrolled :initform 0 :accessor statusbar-scrolled
             :documentation "Rows the transcript is scrolled up from the bottom
(M7-4); rendered as a \" · ↑N\" hint so the user knows they're not at the live
edge. Set by paint-frame from the transcript scroll.")))

(defclass transcript-pane ()
  ((lines :initarg :lines :initform '() :accessor transcript-lines
          :documentation "List of styled lines, oldest first.")
   (scroll :initarg :scroll :initform 0 :accessor transcript-scroll
           :documentation "Rows scrolled up from the bottom.")
   (last-total :initform 0 :accessor transcript-last-total
               :documentation "Line count at the previous paint (M7-4): a
scrolled-up viewport is pinned by adding the growth to SCROLL so appended lines
don't yank it downward.")))

(defclass ticker-pane ()
  ((text :initarg :text :initform nil :accessor ticker-text)
   (style :initarg :style :initform :ticker :accessor ticker-style)
   (actions :initarg :actions :initform nil :accessor ticker-actions)
   (expires :initarg :expires :initform 0 :accessor ticker-expires)))

(defclass input-pane ()
  ((text :initarg :text :initform "" :accessor input-text
         :documentation "The full buffer; may contain newlines.")
   (cursor :initarg :cursor :initform 0 :accessor input-cursor
           :documentation "Index into TEXT, 0..length.")
   (placeholder :initarg :placeholder
                :initform "message ourro…  (/ commands · shift+enter newline)"
                :accessor input-placeholder)
   (suggestion :initarg :suggestion :initform nil :accessor input-suggestion
               :documentation "Ghost completion shown after the cursor;
tab / → accepts it.")
   (history :initform '() :accessor input-history
            :documentation "Previously submitted inputs, newest first.")
   (history-index :initform nil :accessor input-history-index)
   (history-stash :initform "" :accessor input-history-stash)))

(defclass view ()
  ((header :initarg :header :accessor view-header)
   (transcript :initarg :transcript :accessor view-transcript)
   (ticker :initarg :ticker :accessor view-ticker)
   (statusbar :initarg :statusbar :accessor view-statusbar)
   (input :initarg :input :accessor view-input)
   (panes :initarg :panes :initform '() :accessor view-panes
          :documentation "Extra evolved panes, rendered above the ticker.")
   (overlay :initarg :overlay :initform nil :accessor view-overlay
            :documentation "A modal overlay component (e.g. the evolution
inspector) or NIL. When set, paint-frame substitutes the transcript region
with the overlay's clipped lines and handle-key routes keys to OVERLAY-KEY.")))

(defun make-view (&key (repo "") (generation "gen-0001"))
  (let ((statusbar (make-instance 'statusbar-pane :repo repo
                                                  :generation generation)))
    (make-instance 'view
                   :header (make-instance 'header-pane :statusbar statusbar)
                   :transcript (make-instance 'transcript-pane)
                   :ticker (make-instance 'ticker-pane)
                   :statusbar statusbar
                   :input (make-instance 'input-pane))))


(defvar *active-view* nil
  "The live VIEW that ADD-PANE targets and status widgets render into. Set by
run-agent at boot; REBOUND to a throwaway view during verifier staging so a
candidate's load-time ADD-PANE / DEFINE-STATUS-WIDGET can never touch the live
screen (see run-staged-tests).")

(defvar *status-widgets* '()
  "Alist (name . plist) of evolved status-bar widgets. Each plist holds
:fn (0-arg closure → short string), :interval (seconds), :cache (last string),
:next-refresh (universal-time), :gene (owner name or NIL), :strikes.")

(defparameter *ui-strike-limit* 3
  "Consecutive render/refresh errors an evolved widget or pane may accrue
before it is retired and its gene reverted.")

(defvar *ui-lock* (bt:make-recursive-lock "ourro-ui")
  "Guards the evolved-UI state — *status-widgets* and a view's evolved panes.
Gene loads mutate it on worker threads (a propose_gene turn on `ourro-turn`, the
miner on `ourro-turn-boundary`) while paint-frame reads and mutates it on the UI
thread; per D-1 both sides must serialize. Recursive so paint-frame can hold it
across a retirement whose revert closures re-enter the mutators.")

(defmacro with-ui-lock (&body body)
  `(bt:with-recursive-lock-held (*ui-lock*) ,@body))

(defun ui-current-gene ()
  "The name of the gene currently being loaded, or NIL."
  (pget ourro.kernel:*current-gene-context* :name))


(defclass pane ()
  ((gene :initarg :gene :initform (ui-current-gene) :accessor pane-gene
         :documentation "Owning gene name (captured at instantiation), or NIL.")
   (visible :initarg :visible :initform t :accessor pane-visible)
   (strikes :initform 0 :accessor pane-strikes))
  (:documentation "Base class for evolved TUI panes. Subclass it, add a
RENDER-COMPONENT method returning ≤6 styled-span lines (a pure function of
state — no I/O), and ADD-PANE it."))

(defun add-pane (pane &key (view *active-view*))
  "Splice PANE (a PANE instance) into VIEW's evolved-pane list, above the
ticker. Idempotent by object identity. When a gene owns it, record a
revert-action that removes it — so reverting the gene removes the pane."
  (when view
    (with-ui-lock (pushnew pane (view-panes view)))
    (let ((owner (or (pane-gene pane) (ui-current-gene))))
      (when owner
        (ourro.kernel:record-revert-action
         owner
         (lambda ()
           (with-ui-lock (setf (view-panes view) (remove pane (view-panes view)))))
         :description "remove evolved pane"))))
  pane)

(defun remove-pane (pane &key (view *active-view*))
  "Remove PANE from VIEW's evolved-pane list."
  (when view
    (with-ui-lock (setf (view-panes view) (remove pane (view-panes view)))))
  pane)

(defun render-panes (view width)
  "Render each visible evolved pane under the three-strikes guard. Returns
(values lines retirements): a pane that errors contributes no lines (never a
torn frame) and, after *ui-strike-limit* strikes, is queued for retirement."
  (with-ui-lock
    (let ((lines '()) (retire '()))
      (dolist (pane (view-panes view))
        (when (pane-visible pane)
          (handler-case
              (let ((rendered (render-component pane width)))
                (setf (pane-strikes pane) 0)
                (setf lines (append lines rendered)))
            (error (condition)
              (when (>= (incf (pane-strikes pane)) *ui-strike-limit*)
                (push (list :element pane :gene (pane-gene pane)
                            :condition condition)
                      retire))))))
      (values lines retire))))


(defun register-status-widget (name interval fn &key gene)
  "Register (or replace) status widget NAME. FN is a 0-arg closure returning a
short string; it is called at most every INTERVAL seconds. When a gene owns it,
a revert-action removes it. Prefer the DEFINE-STATUS-WIDGET macro."
  (let ((owner (or gene (ui-current-gene))))
    (with-ui-lock
      (setf *status-widgets*
            (cons (cons name (list :fn fn :interval (max 1 interval)
                                   :cache nil :next-refresh 0
                                   :gene owner :strikes 0))
                  (remove name *status-widgets* :key #'car))))
    (when owner
      (ourro.kernel:record-revert-action
       owner
       ;; Owner-checked: if another gene has since re-registered this NAME, the
       ;; live entry is no longer ours, so leave it alone — reverting gene A
       ;; must never delete gene B's same-named widget.
       (lambda ()
         (with-ui-lock
           (let ((entry (assoc name *status-widgets*)))
             (when (and entry (equal owner (getf (cdr entry) :gene)))
               (setf *status-widgets*
                     (remove name *status-widgets* :key #'car))))))
       :description (format nil "remove status widget ~A" name)))
    name))

(defmacro define-status-widget (name (&key (interval 5)) &body body)
  "Register a status-bar widget NAME whose BODY (evaluated with no arguments)
returns a short string, refreshed every INTERVAL seconds. Requires the :ui
capability. Example:
  (define-status-widget clock (:interval 1)
    (format nil \"~A\" (current-time-string)))"
  `(register-status-widget ',name ,interval (lambda () (progn ,@body))))

(defun widget-clean (value)
  "Coerce a widget's return value to a single trimmed line."
  (let ((string (substitute #\Space #\Newline (princ-to-string value))))
    (string-trim '(#\Space #\Tab) string)))

(defun refresh-status-widgets ()
  "Call each due widget's FN under the three-strikes guard and update caches.
Returns a list of retirement plists (:element name :gene g :condition c) for
widgets that struck out. Runs on the UI thread before layout."
  (with-ui-lock
    (let ((now (get-universal-time))
          (retire '()))
      (dolist (entry *status-widgets*)
        (let ((w (cdr entry)))
          (when (>= now (getf w :next-refresh))
            (setf (getf w :next-refresh) (+ now (getf w :interval)))
            (handler-case
                (let ((value (funcall (getf w :fn))))
                  (setf (getf w :cache) (widget-clean value)
                        (getf w :strikes) 0))
              (error (condition)
                ;; Keep the last good cache; count a strike, retire at the limit.
                (when (>= (incf (getf w :strikes)) *ui-strike-limit*)
                  (push (list :element (car entry) :gene (getf w :gene)
                              :condition condition)
                        retire)))))))
      retire)))

(defun status-widget-cells ()
  "Non-empty widget cache strings, registration order (newest first)."
  (with-ui-lock
    (loop for entry in *status-widgets*
          for cache = (getf (cdr entry) :cache)
          when (and cache (plusp (length cache))) collect cache)))


(defun retire-ui-owner (gene condition)
  "Revert the gene that owns a struck-out UI element — its recorded
revert-action removes the element — and surface it via the probation amber
ticker, exactly like a gene that failed on use (PR-6)."
  (ignore-errors (ourro.kernel:revert-gene-definitions gene))
  (let ((hook ourro.kernel:*probation-failure-hook*))
    (when hook (ignore-errors (funcall hook gene condition)))))

(defun process-ui-retirements (retirements view)
  "Retire the queued struck-out elements. Owned elements go through the gene
revert table + amber ticker; ownerless ones are removed directly."
  (with-ui-lock
    (dolist (r retirements)
      (let ((gene (getf r :gene))
            (element (getf r :element)))
        (if gene
            (retire-ui-owner gene (getf r :condition))
            (if (typep element 'pane)
                (when view (setf (view-panes view) (remove element (view-panes view))))
                (setf *status-widgets* (remove element *status-widgets* :key #'car))))))))


(defun input-set-text (input text &key (cursor (length text)))
  (setf (input-text input) text
        (input-cursor input) (min cursor (length text)))
  input)

(defun input-insert (input string)
  "Insert STRING (or a character) at the cursor."
  (let* ((addition (if (characterp string) (string string) string))
         (text (input-text input))
         (cursor (input-cursor input)))
    (setf (input-text input)
          (concatenate 'string (subseq text 0 cursor) addition
                       (subseq text cursor))
          (input-cursor input) (+ cursor (length addition)))))

(defun input-backspace (input)
  (let ((cursor (input-cursor input))
        (text (input-text input)))
    (when (plusp cursor)
      (setf (input-text input)
            (concatenate 'string (subseq text 0 (1- cursor)) (subseq text cursor))
            (input-cursor input) (1- cursor)))))

(defun input-delete-forward (input)
  (let ((cursor (input-cursor input))
        (text (input-text input)))
    (when (< cursor (length text))
      (setf (input-text input)
            (concatenate 'string (subseq text 0 cursor)
                         (subseq text (1+ cursor)))))))

(defun word-boundary-left (text cursor)
  (let ((i cursor))
    (loop while (and (plusp i) (word-separator-p (char text (1- i)))) do (decf i))
    (loop while (and (plusp i) (not (word-separator-p (char text (1- i))))) do (decf i))
    i))

(defun word-boundary-right (text cursor)
  (let ((i cursor) (length (length text)))
    (loop while (and (< i length) (word-separator-p (char text i))) do (incf i))
    (loop while (and (< i length) (not (word-separator-p (char text i)))) do (incf i))
    i))

(defun word-separator-p (char)
  (member char '(#\Space #\Tab #\Newline #\/ #\. #\- #\_)))

(defun input-delete-word-back (input)
  (let* ((text (input-text input))
         (cursor (input-cursor input))
         (start (word-boundary-left text cursor)))
    (when (< start cursor)
      (setf (input-text input)
            (concatenate 'string (subseq text 0 start) (subseq text cursor))
            (input-cursor input) start))))

(defun input-kill-to-line-end (input)
  (let* ((text (input-text input))
         (cursor (input-cursor input))
         (end (or (position #\Newline text :start cursor) (length text)))
         (end (if (= end cursor) (min (1+ end) (length text)) end)))
    (setf (input-text input)
          (concatenate 'string (subseq text 0 cursor) (subseq text end)))))

(defun input-clear (input)
  (setf (input-text input) ""
        (input-cursor input) 0
        (input-suggestion input) nil))

(defun input-move (input delta)
  (setf (input-cursor input)
        (max 0 (min (length (input-text input))
                    (+ (input-cursor input) delta)))))

(defun input-word-move (input direction)
  (let ((text (input-text input))
        (cursor (input-cursor input)))
    (setf (input-cursor input)
          (if (eq direction :left)
              (word-boundary-left text cursor)
              (word-boundary-right text cursor)))))

(defun line-start (text cursor)
  (let ((newline (position #\Newline text :end cursor :from-end t)))
    (if newline (1+ newline) 0)))

(defun line-end (text cursor)
  (or (position #\Newline text :start cursor) (length text)))

(defun input-line-home (input)
  (setf (input-cursor input) (line-start (input-text input) (input-cursor input))))

(defun input-line-end (input)
  (setf (input-cursor input) (line-end (input-text input) (input-cursor input))))

(defun input-cursor-line-col (input)
  "Return (values line-index column) of the cursor within the buffer."
  (let* ((text (input-text input))
         (cursor (input-cursor input))
         (line (count #\Newline text :end cursor))
         (column (- cursor (line-start text cursor))))
    (values line column)))

(defun input-line-count (input)
  (1+ (count #\Newline (input-text input))))

(defun input-move-line (input direction)
  "Move the cursor one line up/down within a multiline buffer, preserving
the column when possible. Returns T if it moved, NIL at a boundary (the
caller then treats up/down as history navigation)."
  (multiple-value-bind (line column) (input-cursor-line-col input)
    (let ((lines (uiop:split-string (input-text input)
                                    :separator '(#\Newline)))
          (target (+ line (if (eq direction :up) -1 1))))
      (when (and (<= 0 target) (< target (input-line-count input)))
        (let ((offset 0))
          (loop for i from 0 below target
                do (incf offset (1+ (length (nth i lines)))))
          (setf (input-cursor input)
                (+ offset (min column (length (nth target lines)))))
          t)))))


(defmethod render-component ((component header-pane) width)
  (let ((statusbar (header-statusbar component)))
    (list (list (styled :header
                        (fit (format nil " ourro · ~A~@[ · ~A~]"
                                     (statusbar-generation statusbar)
                                     (unless (string= "" (statusbar-repo statusbar))
                                       (statusbar-repo statusbar)))
                            (- width 12)))
                (styled :accent
                        (let ((pending (statusbar-pending statusbar)))
                          (fit-right
                           (format nil "~@[⚡~A ~]~A "
                                   (and (plusp pending) pending)
                                   (mode-badge (statusbar-mode statusbar)))
                           12)))))))

(defun mode-badge (mode)
  (case mode (:auto "◆auto") (:manual "◇manual") (:frozen "❄frozen")
        (t (format nil "~A" mode))))

(defmethod render-component ((component statusbar-pane) width)
  (let* ((base (cond ((statusbar-visiting component)
                      (format nil " visiting ~A (read-only)"
                              (statusbar-visiting component)))
                     ((or (statusbar-spinner component)
                          (statusbar-activity component))
                      ;; Join whichever of spinner/activity are present with
                      ;; " · " — never print a raw NIL for the missing one.
                      (format nil " ~{~A~^ · ~}"
                              (remove nil (list (statusbar-spinner component)
                                                (statusbar-activity component)))))
                     (t " ready")))
         ;; Scroll-position hint (M7-4): show how far up the transcript is
         ;; scrolled so the user knows they aren't at the live edge.
         (base (let ((n (statusbar-scrolled component)))
                 (if (and n (plusp n))
                     (concatenate 'string base (format nil " · ↑~A" n))
                     base)))
         ;; Evolved status widgets (M3) render right-aligned; their cached
         ;; strings were refreshed in paint-frame before layout. Cap the widget
         ;; region at half the width so a few long cells can never fully
         ;; displace the base status line (they clip within their half instead).
         (cells (status-widget-cells))
         (raw (if cells (format nil "~{~A~^  ~} " cells) ""))
         (right (if (> (length raw) (floor width 2))
                    (subseq raw 0 (floor width 2))
                    raw)))
    (list (list (styled :status (fit base (max 0 (- width (length right)))))
                (styled :accent right)))))

(defun ticker-action-label (action)
  "The display label of a ticker ACTION: a plain string is shown as-is; a
(key label command) triple (M14-1) shows its LABEL."
  (if (consp action) (second action) action))

(defmethod render-component ((component ticker-pane) width)
  (when (ticker-text component)
    (list (list (styled (ticker-style component)
                       (fit (format nil " ✦ ~A~@[   ~A~]"
                                    (ticker-text component)
                                    (and (ticker-actions component)
                                         (format nil "~{[~A]~^ ~}"
                                                 (mapcar #'ticker-action-label
                                                         (ticker-actions component)))))
                            width))))))

(defmethod render-component ((component transcript-pane) width)
  (declare (ignore width))
  (transcript-lines component))

(defparameter *max-input-lines* 8
  "Most input rows shown at once; taller buffers scroll to keep the cursor
visible.")

(defun input-visible-window (input)
  "Return (values lines start) — the buffer's lines and the index of the
first visible one."
  (let* ((lines (uiop:split-string (input-text input)
                                   :separator '(#\Newline)))
         (count (length lines)))
    (if (<= count *max-input-lines*)
        (values lines 0)
        (multiple-value-bind (cursor-line column) (input-cursor-line-col input)
          (declare (ignore column))
          (let ((start (max 0 (min (- count *max-input-lines*)
                                   (- cursor-line (1- *max-input-lines*))))))
            (values (subseq lines start (min count (+ start *max-input-lines*)))
                    start))))))

(defmethod render-component ((component input-pane) width)
  (let ((text (input-text component)))
    (if (zerop (length text))
        (list (list (styled :accent " ❯ ")
                    (styled :dim (fit (input-placeholder component) (- width 3)))))
        (multiple-value-bind (lines start) (input-visible-window component)
          (multiple-value-bind (cursor-line column) (input-cursor-line-col component)
            (declare (ignore column))
            (let ((suggestion (input-suggestion component)))
              (loop for line in lines
                    for index from start
                    collect (append
                             (list (styled :accent (if (zerop index) " ❯ " "   "))
                                   (styled :input line))
                             (when (and suggestion
                                        (= index cursor-line)
                                        (= (input-cursor component)
                                           (length text)))
                               (list (styled :dim suggestion)))))))))))


(defun adjust-scroll-for-append (scroll delta total height)
  "New transcript scroll after the line count changed by DELTA (M7-4). When the
user is scrolled up (SCROLL>0), pin the visible window by adding the growth so
appended lines don't yank it downward; when pinned to the bottom (SCROLL=0),
stay there. Always clamp to [0, max(0, TOTAL-HEIGHT)] — the clamp also absorbs a
finish-stream shrink that would otherwise leave SCROLL past the new end. Pure."
  (let ((max-scroll (max 0 (- total height))))
    (if (<= scroll 0)
        0
        (min (+ scroll (max 0 delta)) max-scroll))))

(defun pin-transcript-scroll (transcript height)
  "Adjust and store TRANSCRIPT's scroll for appended/removed lines (M7-4),
returning the new scroll. Runs on the UI thread inside paint-frame."
  (let* ((total (length (transcript-lines transcript)))
         (delta (- total (transcript-last-total transcript)))
         (new (adjust-scroll-for-append (transcript-scroll transcript)
                                        delta total height)))
    (setf (transcript-scroll transcript) new
          (transcript-last-total transcript) total)
    new))

(defun paint-frame (screen view &key spinner)
  "Lay out VIEW into SCREEN's height and paint it. Layout, top to bottom:
header (1) · transcript (fills) · evolved panes · ticker (0-1) · status (1)
· input (1..8). The transcript scrolls; the input cursor is placed."
  (let* ((width (screen-width screen))
         (height (screen-height screen))
         (statusbar (view-statusbar view))
         (input-pane (view-input view))
         ;; Refresh evolved status widgets and render evolved panes BEFORE
         ;; layout, each under the three-strikes guard (M3). Struck-out
         ;; elements are retired after the frame is painted, so a broken
         ;; evolved widget degrades gracefully and never tears this frame.
         (widget-retire (refresh-status-widgets)))
    (setf (statusbar-spinner statusbar) spinner)
    (multiple-value-bind (extra pane-retire) (render-panes view width)
    (let* ((header (render-component (view-header view) width))
           (ticker (render-component (view-ticker view) width))
           (input (render-component input-pane width))
           ;; The statusbar always renders exactly one line.
           (chrome (+ (length header) (length extra) (length ticker)
                      1 (length input)))
           (transcript-height (max 1 (- height chrome)))
           (overlay (view-overlay view))
           ;; Pin/clamp the transcript scroll for appended or removed lines
           ;; (M7-4) BEFORE rendering the statusbar, so its "· ↑N" hint reflects
           ;; this frame's scroll rather than the previous frame's. A modal
           ;; overlay owns the region and doesn't move the transcript scroll.
           (scroll (if overlay
                       (transcript-scroll (view-transcript view))
                       (pin-transcript-scroll (view-transcript view)
                                              transcript-height))))
      (setf (statusbar-scrolled statusbar) scroll)
      (let* ((status (render-component statusbar width))
             (visible
               (if overlay
                   ;; Modal: the overlay owns the transcript region. It renders
                   ;; its own clipped/scrolled lines; header/ticker/status/input
                   ;; stay so the frame never fully tears.
                   (clip-lines (render-component overlay width) transcript-height)
                   (window-lines (transcript-lines (view-transcript view))
                                 transcript-height scroll)))
             (lines (append header
                            (pad-lines visible transcript-height)
                            extra ticker status input)))
        (multiple-value-bind (cursor-row cursor-column)
            (input-cursor-screen-position input-pane height (length input))
          (render-lines screen lines
                        :cursor-visible t
                        :cursor-row cursor-row
                        :cursor-column (min cursor-column width)))
        ;; Retire any struck-out widgets/panes now that the frame is painted —
        ;; reverting a gene here can't tear the frame we already drew.
        (process-ui-retirements (append widget-retire pane-retire) view))))))

(defun input-cursor-screen-position (input height input-rows)
  "Screen (row column), 1-based, of the input cursor. The input occupies
the bottom INPUT-ROWS rows of the screen."
  (if (zerop (length (input-text input)))
      (values height 4)
      (multiple-value-bind (lines start) (input-visible-window input)
        (declare (ignore lines))
        (multiple-value-bind (cursor-line column) (input-cursor-line-col input)
          (declare (ignore column))
          ;; Visible cursor column = display width of the text before the cursor
          ;; on its line — char count desyncs the cursor when wide chars precede
          ;; it (M7-2).
          (let* ((text (input-text input))
                 (cursor (input-cursor input))
                 (vis-col (display-width (subseq text (line-start text cursor) cursor))))
            (values (+ (- height input-rows 1) 1
                       (max 0 (min (1- input-rows) (- cursor-line start))) 1)
                    (+ 4 vis-col)))))))

(defun window-lines (lines height scroll)
  "The HEIGHT lines ending SCROLL rows above the bottom of LINES."
  (let* ((total (length lines))
         (end (max 0 (- total scroll)))
         (start (max 0 (- end height))))
    (subseq lines start end)))

(defun clip-lines (lines height)
  "The first HEIGHT lines of LINES (an overlay renders top-aligned)."
  (if (<= (length lines) height)
      lines
      (subseq lines 0 height)))

(defun pad-lines (lines height)
  (let ((count (length lines)))
    (if (>= count height)
        lines
        (append (make-list (- height count) :initial-element '()) lines))))


(defun fit (string width)
  "Truncate or pad STRING to exactly WIDTH visible columns (M7-2), never
splitting a wide character."
  (let ((cols (display-width string)))
    (cond ((= cols width) string)
          ((> cols width)
           (multiple-value-bind (prefix pcols) (take-columns string width)
             ;; Dropping a straddling wide char can leave us one column short.
             (if (< pcols width)
                 (concatenate 'string prefix
                              (make-string (- width pcols) :initial-element #\Space))
                 prefix)))
          (t (concatenate 'string string
                          (make-string (- width cols) :initial-element #\Space))))))

(defun fit-right (string width)
  "Right-align STRING within WIDTH visible columns (M7-2)."
  (let ((cols (display-width string)))
    (if (>= cols width)
        (values (take-columns string width))
        (concatenate 'string
                     (make-string (- width cols) :initial-element #\Space)
                     string))))

(defun wrap-text (text width)
  "Word-wrap TEXT to WIDTH visible columns (M7-2); returns a list of strings."
  (let ((result '()))
    (dolist (raw-line (uiop:split-string text :separator '(#\Newline)))
      (if (<= (display-width raw-line) width)
          (push raw-line result)
          (let ((line "")
                (words (uiop:split-string raw-line :separator '(#\Space))))
            (dolist (word words)
              (cond ((zerop (length line)) (setf line word))
                    ((<= (+ (display-width line) 1 (display-width word)) width)
                     (setf line (concatenate 'string line " " word)))
                    (t (push line result)
                       (setf line word))))
            (push line result))))
    (nreverse result)))
