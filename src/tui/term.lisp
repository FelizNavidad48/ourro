
(defpackage #:ourro.tui
  (:use #:cl #:ourro.util)
  (:export ;; term
           #:with-raw-terminal
           #:*keep-screen-on-exit*
           #:*mouse-reporting*
           #:set-mouse-reporting
           #:terminal-size
           #:read-key
           #:wait-input
           #:resize-pending-p
           #:clear-resize-pending
           #:*tty-input*
           #:*tty-output*
           #:write-tty
           #:flush-tty
           #:enter-alt-screen
           #:leave-alt-screen
           #:hide-cursor
           #:show-cursor
           ;; render
           #:screen
           #:make-screen
           #:screen-width
           #:screen-height
           #:screen-resize
           #:render-lines
           #:display-width
           #:char-display-width
           #:take-columns
           #:styled
           #:current-theme
           #:set-theme
           #:theme-names
           ;; components (render.lisp/components.lisp)
           #:paint-frame))

(in-package #:ourro.tui)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(defvar *tty-fd* nil)
(defvar *tty-input* nil)
(defvar *tty-output* nil)
(defvar *saved-termios* nil)

(defun open-tty ()
  "Open /dev/tty fresh. Safe to call after image resume (no stale handles)."
  (setf *tty-fd* (sb-posix:open "/dev/tty" sb-posix:o-rdwr))
  (setf *tty-input* (sb-sys:make-fd-stream *tty-fd*
                                           :input t :output nil
                                           :element-type 'character
                                           :buffering :none
                                           :external-format :utf-8
                                           :name "ourro-tty-in"))
  (setf *tty-output* (sb-sys:make-fd-stream *tty-fd*
                                            :input nil :output t
                                            :element-type 'character
                                            :buffering :full
                                            :external-format :utf-8
                                            :name "ourro-tty-out"))
  *tty-fd*)

(defun close-tty ()
  (ignore-errors (when *tty-output* (finish-output *tty-output*)))
  (ignore-errors (when *tty-input* (close *tty-input*)))
  (ignore-errors (when *tty-output* (close *tty-output*)))
  (setf *tty-input* nil *tty-output* nil *tty-fd* nil))

(defun enter-raw-mode ()
  (let ((termios (sb-posix:tcgetattr *tty-fd*)))
    (setf *saved-termios* (sb-posix:tcgetattr *tty-fd*))
    (setf (sb-posix:termios-lflag termios)
          (logandc2 (sb-posix:termios-lflag termios)
                    (logior sb-posix:icanon sb-posix:echo sb-posix:echoe
                            sb-posix:echok sb-posix:echonl sb-posix:isig
                            sb-posix:iexten)))
    (setf (sb-posix:termios-iflag termios)
          (logandc2 (sb-posix:termios-iflag termios)
                    (logior sb-posix:ignbrk sb-posix:brkint sb-posix:parmrk
                            sb-posix:istrip sb-posix:inlcr sb-posix:igncr
                            sb-posix:icrnl sb-posix:ixon)))
    (let ((cc (sb-posix:termios-cc termios)))
      (setf (aref cc sb-posix:vmin) 0
            (aref cc sb-posix:vtime) 1))     ; 100ms read timeout, non-blocking-ish
    (sb-posix:tcsetattr *tty-fd* sb-posix:tcsanow termios)))

(defun restore-terminal ()
  (when (and *tty-fd* *saved-termios*)
    (ignore-errors
     (sb-posix:tcsetattr *tty-fd* sb-posix:tcsanow *saved-termios*))))

(defun write-tty (string)
  (write-string string *tty-output*))

(defun flush-tty () (finish-output *tty-output*))

(defun enter-alt-screen () (write-tty (format nil "~C[?1049h~C[2J~C[H" #\Esc #\Esc #\Esc)))
(defun leave-alt-screen () (write-tty (format nil "~C[?1049l" #\Esc)))
(defun hide-cursor () (write-tty (format nil "~C[?25l" #\Esc)))
(defun show-cursor () (write-tty (format nil "~C[?25h" #\Esc)))

(defvar *mouse-reporting* nil
  "When true, SGR mouse reporting (?1000h?1006h) is enabled so the wheel can
scroll the transcript. OFF by default: mouse reporting captures every click and
drag, which breaks the terminal's native text selection/copy. Toggle at runtime
with SET-MOUSE-REPORTING (the agent's /mouse command).")

(defun mouse-reporting-sequence (on)
  (if on
      (format nil "~C[?1000h~C[?1006h" #\Esc #\Esc)
      (format nil "~C[?1006l~C[?1000l" #\Esc #\Esc)))

(defun set-mouse-reporting (on)
  "Turn SGR mouse reporting on/off live. Returns the new state."
  (setf *mouse-reporting* (and on t))
  (when *tty-output*
    (write-tty (mouse-reporting-sequence *mouse-reporting*))
    (flush-tty))
  *mouse-reporting*)

(defun enable-input-protocols ()
  ;; Mouse reporting only when *mouse-reporting* is set — see its docstring.
  (write-tty (format nil "~C[?2004h~C[>4;2m~C[>1u" #\Esc #\Esc #\Esc))
  (when *mouse-reporting*
    (write-tty (mouse-reporting-sequence t)))
  (flush-tty))

(defun disable-input-protocols ()
  ;; Always send the mouse-off sequence — harmless when it was never on.
  (write-tty (mouse-reporting-sequence nil))
  (write-tty (format nil "~C[<u~C[>4;0m~C[?2004l" #\Esc #\Esc #\Esc))
  (flush-tty))


(defvar *resize-pending* t)

(defun resize-pending-p () *resize-pending*)
(defun clear-resize-pending () (setf *resize-pending* nil))

(defun install-winch-handler ()
  (ignore-errors
   (sb-sys:enable-interrupt sb-unix:sigwinch
                            (lambda (signal info context)
                              (declare (ignore signal info context))
                              (setf *resize-pending* t)))))

(defun remove-winch-handler ()
  (ignore-errors (sb-sys:enable-interrupt sb-unix:sigwinch :default)))

(defvar *keep-screen-on-exit* nil
  "When true at teardown, WITH-RAW-TERMINAL leaves the alt screen up (last
frame intact, cursor hidden) instead of switching back to the primary buffer.
Set by the agent just before a seamless generation restart: the outgoing
process's final frame stays on screen — prompt and all — until the next
generation repaints over it, so the restart gap never shows a torn/blank
screen with a missing ❯.")

(defmacro with-raw-terminal (() &body body)
  `(progn
     (open-tty)
     (enter-raw-mode)
     (enter-alt-screen)
     (enable-input-protocols)
     (hide-cursor)
     (install-winch-handler)
     (setf *resize-pending* t)
     (unwind-protect (progn ,@body)
       (remove-winch-handler)
       (disable-input-protocols)
       (unless *keep-screen-on-exit*
         (show-cursor)
         (leave-alt-screen))
       (flush-tty)
       (restore-terminal)
       (close-tty))))


(defun terminal-size ()
  "Return (values columns rows), defaulting to 80x24."
  (handler-case
      (let* ((output (with-output-to-string (out)
                       (uiop:run-program '("stty" "size")
                                         :input "/dev/tty"
                                         :output out
                                         :error-output nil)))
             (parts (uiop:split-string (trim output) :separator '(#\Space))))
        (if (= (length parts) 2)
            (values (max 20 (parse-integer (second parts)))
                    (max 6 (parse-integer (first parts))))
            (values 80 24)))
    (error () (values 80 24))))


(defun wait-input (timeout)
  "Block up to TIMEOUT seconds for tty input. Returns true if input is ready."
  (when *tty-fd*
    (handler-case
        (sb-sys:wait-until-fd-usable *tty-fd* :input timeout)
      (error () (progn (sleep (min timeout 0.05)) nil)))))


(defun read-key ()
  "Read one decoded key from the tty, or NIL if none is pending."
  ;; read-char-no-hang returns NIL when no character is ready, and the
  ;; eof-value (:none) only at genuine end of file. Mapping these the wrong
  ;; way makes the idle loop read :eof on its first poll and quit instantly.
  (let ((char (read-char-no-hang *tty-input* nil :none)))
    (cond
      ((null char) nil)                  ; no key ready right now
      ((eq char :none) :eof)             ; tty closed
      ((char= char #\Escape) (decode-escape))
      ((char= char #\Return) :enter)
      ((char= char #\Newline) :shift-enter) ; ctrl-j: universal newline fallback
      ((char= char #\Tab) :tab)
      ((or (char= char #\Rubout) (char= char (code-char 8))) :backspace)
      ((char= char (code-char 127)) :backspace)
      ((< (char-code char) 32)
       ;; Control character: Ctrl-A..Ctrl-Z etc.
       (control-key char))
      (t char))))

(defun control-key (char)
  (let ((code (char-code char)))
    (case code
      ;; ctrl-a keeps its readline Home meaning. ctrl-e must decode to
      ;; :ctrl-e — the keymap binds it to the evolution inspector (F-ctrle);
      ;; mapping byte 5 to :end here made that advertised binding dead code.
      ;; End-of-line remains available via the End key (CSI/SS3 decode).
      (1 :home)
      (3 :ctrl-c) (4 :ctrl-d) (11 :ctrl-k) (12 :ctrl-l) (21 :ctrl-u)
      (23 :ctrl-w) (14 :ctrl-n) (16 :ctrl-p) (18 :ctrl-r)
      (t (intern (format nil "CTRL-~C" (code-char (+ code 64))) :keyword)))))

(defun next-char (&key (grace 0.02))
  "Read the next char of an in-flight escape sequence. Unlike a lone
READ-CHAR-NO-HANG, waits briefly (GRACE seconds) — the bytes of one
keypress can straggle across reads on slow ptys."
  (or (read-char-no-hang *tty-input* nil nil)
      (progn
        (wait-input grace)
        (read-char-no-hang *tty-input* nil nil))))

(defun decode-escape ()
  "Decode what follows an ESC byte: CSI/SS3 sequences, alt-chords, or a
lone ESC keypress (nothing follows)."
  (let ((next (next-char)))
    (cond
      ((not (characterp next)) :escape)  ; lone ESC (nil = no more input)
      ((char= next #\[) (decode-csi))
      ((char= next #\O)
       (let ((code (next-char)))
         (case code
           (#\A :up) (#\B :down) (#\C :right) (#\D :left)
           (#\H :home) (#\F :end)
           ;; SS3 function keys (vt100 application mode): ESC O P..S.
           (#\P :f1) (#\Q :f2) (#\R :f3) (#\S :f4)
           (t :escape))))
      ;; Alt-chords (ESC + char). Meta-enter and meta-backspace get their
      ;; editing meanings; ESC-f/b are the readline word motions.
      ((or (char= next #\Return) (char= next #\Newline)) :shift-enter)
      ((or (char= next #\Rubout) (char= next (code-char 8))) :alt-backspace)
      ((char-equal next #\f) :word-right)
      ((char-equal next #\b) :word-left)
      (t (intern (format nil "ALT-~:@(~C~)" next) :keyword)))))

(defun decode-csi ()
  "Parse a CSI sequence: parameter bytes, then one final byte."
  (let ((params (make-array 8 :element-type 'character
                              :adjustable t :fill-pointer 0)))
    (loop
      (let ((char (next-char)))
        (cond
          ((null char) (return :escape))
          ((or (char<= #\0 char #\9)
               (member char '(#\; #\: #\? #\< #\= #\>)))
           (vector-push-extend char params))
          (t (return (decode-csi-final (coerce params 'string) char))))))))

(defun csi-params (params)
  "Parse \"1;2\" → (1 2). Empty fields become NIL."
  (mapcar (lambda (part) (parse-integer part :junk-allowed t))
          (uiop:split-string params :separator '(#\;))))

(defun decode-sgr-mouse (params)
  "Decode an SGR mouse report's button field (PARAMS is \"<b;x;y\"). The wheel
buttons become :wheel-up / :wheel-down; anything else (a click or drag) is the
no-op :mouse — never :escape, which would clear the input on a stray click."
  (let* ((fields (uiop:split-string (subseq params 1) :separator '(#\;)))
         (button (or (parse-integer (or (first fields) "") :junk-allowed t) 0)))
    (case button
      (64 :wheel-up)
      (65 :wheel-down)
      (t :mouse))))

(defun decode-x10-mouse ()
  "Consume the 3 raw bytes of a legacy X10 mouse report (ESC [ M b x y) so they
never type as garbage, and map the wheel buttons (M7-4)."
  (let ((b (next-char)) (x (next-char)) (y (next-char)))
    (declare (ignore x y))
    (if (characterp b)
        (case (- (char-code b) 32)
          (64 :wheel-up)
          (65 :wheel-down)
          (t :mouse))
        :mouse)))

(defun decode-csi-final (params final)
  ;; SGR mouse: ESC [ < b ; x ; y M/m — the only CSI whose params start with '<'.
  (when (and (plusp (length params)) (char= (char params 0) #\<))
    (return-from decode-csi-final (decode-sgr-mouse params)))
  (let* ((numbers (csi-params params))
         (first (first numbers))
         (modifier (or (second numbers) 1)))
    (case final
      (#\M (decode-x10-mouse))          ; legacy X10 mouse (no SGR)
      (#\A (if (member modifier '(2 4)) :shift-up :up))
      (#\B (if (member modifier '(2 4)) :shift-down :down))
      (#\C (if (member modifier '(3 5 7)) :word-right :right))
      (#\D (if (member modifier '(3 5 7)) :word-left :left))
      (#\H :home) (#\F :end)
      (#\Z :shift-tab)
      (#\u (modified-key (or first 0) modifier))          ; kitty / CSI-u
      (#\~ (case first
             ((1 7) :home)
             ((4 8) :end)
             (3 :delete)
             (5 :page-up)
             (6 :page-down)
             ;; CSI function keys (vt220): 11-15,17-21,23,24 ~ → F1..F12.
             (11 :f1) (12 :f2) (13 :f3) (14 :f4) (15 :f5)
             (17 :f6) (18 :f7) (19 :f8) (20 :f9) (21 :f10)
             (23 :f11) (24 :f12)
             (27 (modified-key (or (third numbers) 0)     ; xterm modifyOtherKeys
                               (or (second numbers) 1)))
             (200 (read-bracketed-paste))
             (t :escape)))
      (t :escape))))

(defun modified-key (code modifier)
  "Resolve a CSI-u / modifyOtherKeys key: CODE is the unicode codepoint,
MODIFIER is 1+bitmask (shift 1, alt 2, ctrl 4)."
  (let ((shift (logbitp 0 (1- modifier)))
        (alt (logbitp 1 (1- modifier)))
        (ctrl (logbitp 2 (1- modifier))))
    (case code
      (13 (if (or shift alt ctrl) :shift-enter :enter))
      (10 :shift-enter)
      (9 (if shift :shift-tab :tab))
      (27 :escape)
      ((8 127) (if alt :alt-backspace :backspace))
      (t (let ((char (and (<= 32 code 1114111) (code-char code))))
           (cond
             ((null char) :escape)
             (ctrl (control-key (code-char (logand (char-code (char-downcase char))
                                                   31))))
             (alt (intern (format nil "ALT-~:@(~C~)" char) :keyword))
             (shift (char-upcase char))
             (t char)))))))

(defparameter *max-paste-chars* 1048576)

(defun read-bracketed-paste ()
  "Collect everything between ESC[200~ and ESC[201~ into one paste event.
Newlines are normalized to LF; other control characters (except tab) are
dropped so a paste can never smuggle escape sequences into the buffer."
  (let ((out (make-string-output-stream))
        (count 0))
    (loop
      (let ((char (next-char :grace 1.0)))
        (cond
          ((null char) (return))                       ; truncated paste
          ((char= char #\Escape)
           (let ((tail (read-paste-terminator)))
             (when (eq tail :end) (return))
             (write-string tail out)))
          (t (write-char char out)
             (when (> (incf count) *max-paste-chars*) (return))))))
    (cons :paste (normalize-paste (get-output-stream-string out)))))

(defun read-paste-terminator ()
  "After ESC inside a paste: either the [201~ terminator (→ :END) or
literal bytes to keep (returned as a string, ESC dropped)."
  (let ((expected "[201~")
        (seen (make-array 5 :element-type 'character :fill-pointer 0)))
    (loop for wanted across expected
          for char = (next-char :grace 0.2)
          do (cond ((null char) (return-from read-paste-terminator
                                  (coerce seen 'string)))
                   ((char= char wanted) (vector-push char seen))
                   (t (vector-push char seen)
                      (return-from read-paste-terminator (coerce seen 'string)))))
    :end))

(defun normalize-paste (text)
  (with-output-to-string (out)
    (loop with length = (length text)
          for i from 0 below length
          for char = (char text i)
          do (cond
               ((char= char #\Return)
                (write-char #\Newline out)
                (when (and (< (1+ i) length)
                           (char= (char text (1+ i)) #\Newline))
                  (incf i)))
               ((char= char #\Newline) (write-char char out))
               ((char= char #\Tab) (write-string "  " out))
               ((< (char-code char) 32))               ; drop other controls
               ((= (char-code char) 127))
               (t (write-char char out))))))
