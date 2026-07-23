
(in-package #:ourro.tui)

(defparameter *themes*
  '((:light
     (:default        . "38;2;25;15;11;48;2;251;244;230")
     (:header         . "1;38;2;212;9;36;48;2;255;251;241")
     (:dim            . "38;2;79;63;50;48;2;251;244;230")
     (:accent         . "1;38;2;212;9;36;48;2;251;244;230")
     (:user           . "1;38;2;212;9;36;48;2;251;244;230")
     (:assistant      . "38;2;25;15;11;48;2;251;244;230")
     (:tool           . "38;2;15;55;120;48;2;251;244;230")
     (:success        . "1;38;2;0;105;17;48;2;251;244;230")
     (:warning        . "1;38;2;166;78;0;48;2;251;244;230")
     (:danger         . "1;38;2;201;0;0;48;2;251;244;230")
     (:ticker         . "1;38;2;212;9;36;48;2;237;227;210")
     (:status         . "38;2;79;63;50;48;2;237;227;210")
     (:input          . "1;38;2;25;15;11;48;2;255;251;241")
     (:think          . "3;38;2;132;108;90;48;2;251;244;230")
     (:code           . "38;2;244;234;213;48;2;25;15;11")
     (:code-dim       . "38;2;142;124;111;48;2;25;15;11")
     (:lisp-code      . "38;2;25;15;11;48;2;255;251;241")
     (:lisp-code-dim  . "38;2;132;108;90;48;2;255;251;241")
     (:inline-code    . "38;2;15;55;120;48;2;239;231;217")
     (:bold           . "1;38;2;25;15;11;48;2;251;244;230")
     (:syntax-keyword . "38;2;212;9;36;48;2;255;251;241")
     (:syntax-symbol  . "38;2;15;55;120;48;2;255;251;241")
     (:syntax-string  . "38;2;0;105;17;48;2;255;251;241")
     (:syntax-comment . "38;2;132;108;90;48;2;255;251;241")
     (:syntax-paren   . "38;2;86;66;60;48;2;255;251;241"))
    (:dark
     (:default        . "38;2;244;234;213;48;2;18;10;8")
     (:header         . "1;38;2;255;82;100;48;2;36;23;19")
     (:dim            . "38;2;184;167;149;48;2;18;10;8")
     (:accent         . "1;38;2;255;82;100;48;2;18;10;8")
     (:user           . "1;38;2;249;145;0;48;2;18;10;8")
     (:assistant      . "38;2;244;234;213;48;2;18;10;8")
     (:tool           . "38;2;119;168;255;48;2;18;10;8")
     (:success        . "1;38;2;103;200;120;48;2;18;10;8")
     (:warning        . "1;38;2;249;145;0;48;2;18;10;8")
     (:danger         . "1;38;2;255;85;85;48;2;18;10;8")
     (:ticker         . "1;38;2;255;82;100;48;2;51;36;29")
     (:status         . "38;2;184;167;149;48;2;51;36;29")
     (:input          . "1;38;2;244;234;213;48;2;36;23;19")
     (:think          . "3;38;2;169;148;134;48;2;18;10;8")
     (:code           . "38;2;244;234;213;48;2;25;15;11")
     (:code-dim       . "38;2;142;124;111;48;2;25;15;11")
     (:lisp-code      . "38;2;244;234;213;48;2;36;23;19")
     (:lisp-code-dim  . "38;2;169;148;134;48;2;36;23;19")
     (:inline-code    . "38;2;119;168;255;48;2;44;31;25")
     (:bold           . "1;38;2;255;251;241;48;2;18;10;8")
     (:syntax-keyword . "38;2;255;82;100;48;2;36;23;19")
     (:syntax-symbol  . "38;2;119;168;255;48;2;36;23;19")
     (:syntax-string  . "38;2;103;200;120;48;2;36;23;19")
     (:syntax-comment . "38;2;169;148;134;48;2;36;23;19")
     (:syntax-paren   . "38;2;208;189;176;48;2;36;23;19")))
  "Theme name → style keyword/truecolor SGR alist.")

(defparameter *theme* :light)

(defun theme-names () (mapcar #'car *themes*))

(defun current-theme () *theme*)

(defun set-theme (theme)
  "Activate THEME and return its canonical keyword, or NIL when unknown."
  (when (or (stringp theme) (symbolp theme) (characterp theme))
    (let ((entry (find theme *themes* :key #'car
                       :test (lambda (requested available)
                               (string-equal (string requested)
                                             (string available))))))
      (when entry
        (setf *theme* (car entry))))))

(defun active-styles ()
  (cdr (assoc *theme* *themes*)))

(defun sgr (style)
  (format nil "~C[~Am" #\Esc (or (cdr (assoc style (active-styles))) "0")))

(defun sgr-reset () (format nil "~C[0m" #\Esc))

(defun styled (style string) (cons style string))

(defstruct (screen (:constructor %make-screen))
  width height
  (previous (make-array 0 :adjustable t :fill-pointer 0))
  (last-cursor nil))

(defun make-screen (width height)
  (%make-screen :width width :height height))

(defun screen-resize (screen width height)
  (setf (screen-width screen) width
        (screen-height screen) height
        ;; Force a full repaint after resize.
        (fill-pointer (screen-previous screen)) 0
        (screen-last-cursor screen) nil))


(defparameter *zero-width-ranges*
  #(#x0300 #x036F                       ; combining diacritical marks
    #x0483 #x0489                       ; Cyrillic combining
    #x0591 #x05BD #x05BF #x05BF #x05C1 #x05C2 #x05C4 #x05C5 #x05C7 #x05C7
    #x0610 #x061A #x064B #x065F #x0670 #x0670 #x06D6 #x06DC #x06DF #x06E4
    #x0E31 #x0E31 #x0E34 #x0E3A #x0EB1 #x0EB1 #x0EB4 #x0EB9
    #x200B #x200F                       ; ZWSP, ZWNJ, ZWJ, LRM/RLM
    #x202A #x202E #x2060 #x2064         ; bidi/format controls, word joiner
    #xFE00 #xFE0F                       ; variation selectors (incl. emoji VS16)
    #xFE20 #xFE2F)                      ; combining half marks
  "Sorted inclusive [lo hi …] codepoint ranges rendered zero columns wide.")

(defparameter *wide-ranges*
  #(#x1100 #x115F                       ; Hangul Jamo
    #x2329 #x232A                       ; angle brackets
    #x26A1 #x26A1                       ; ⚡ high voltage (the HUD glyph)
    #x2E80 #x303E                       ; CJK radicals … Kangxi … symbols
    #x3041 #x33FF                       ; kana … CJK compatibility
    #x3400 #x4DBF                       ; CJK Ext-A
    #x4E00 #x9FFF                       ; CJK Unified Ideographs
    #xA000 #xA4CF                       ; Yi
    #xA960 #xA97F                       ; Hangul Jamo Ext-A
    #xAC00 #xD7A3                       ; Hangul syllables
    #xF900 #xFAFF                       ; CJK compatibility ideographs
    #xFE10 #xFE19                       ; vertical forms
    #xFE30 #xFE6F                       ; CJK compatibility / small forms
    #xFF00 #xFF60                       ; fullwidth forms
    #xFFE0 #xFFE6                       ; fullwidth signs
    #x1F000 #x1FAFF                     ; emoji / pictograph planes
    #x20000 #x3FFFD)                    ; CJK Ext-B and beyond
  "Sorted inclusive [lo hi …] codepoint ranges rendered two columns wide.")

(defun codepoint-in-ranges-p (code ranges)
  "Binary search: is CODE within one of RANGES' inclusive [lo hi] pairs?"
  (let ((lo 0)
        (hi (1- (/ (length ranges) 2))))
    (loop while (<= lo hi) do
      (let* ((mid (floor (+ lo hi) 2))
             (low (aref ranges (* 2 mid)))
             (high (aref ranges (1+ (* 2 mid)))))
        (cond ((< code low) (setf hi (1- mid)))
              ((> code high) (setf lo (1+ mid)))
              (t (return-from codepoint-in-ranges-p t)))))
    nil))

(defun char-display-width (char)
  "Columns CHAR occupies: 0 (combining/format), 2 (wide/fullwidth/emoji), or 1.
Fast path: everything below U+0300 is an ordinary single-column character."
  (let ((code (char-code char)))
    (cond ((< code #x0300) 1)
          ((codepoint-in-ranges-p code *zero-width-ranges*) 0)
          ((codepoint-in-ranges-p code *wide-ranges*) 2)
          (t 1))))

(defun display-width (string)
  "Visible column width of STRING, summing per-character display widths (M7-2)."
  (let ((width 0))
    (dotimes (i (length string) width)
      (incf width (char-display-width (char string i))))))

(defun take-columns (text width)
  "Return (values prefix columns): the longest prefix of TEXT that fits in
WIDTH columns without splitting a wide character, and its actual column count
(≤ WIDTH). A wide char that would straddle the boundary is dropped entirely."
  (let ((cols 0) (end 0))
    (dotimes (i (length text))
      (let ((w (char-display-width (char text i))))
        (when (> (+ cols w) width) (return))
        (incf cols w)
        (setf end (1+ i))))
    (values (subseq text 0 end) cols)))

(defun render-span (span &optional (base-style :default))
  "Render one (style . string) span with SGR wrapping."
  (if (consp span)
      ;; Reset first so attributes such as bold/italic cannot leak from the
      ;; span, then restore the row surface so code backgrounds remain solid.
      (format nil "~A~A~A~A" (sgr (car span)) (cdr span)
              (sgr-reset) (sgr base-style))
      (princ-to-string span)))

(defparameter *code-row-styles* '(:code :code-dim))

(defparameter *lisp-row-styles*
  '(:lisp-code :lisp-code-dim :syntax-keyword :syntax-symbol :syntax-string
    :syntax-comment :syntax-paren))

(defun line-base-style (line)
  "Code-fence rows keep their code surface across the full terminal width."
  (let ((spans (if (listp line) line (list line))))
    (cond
      ((some (lambda (span)
               (and (consp span) (member (car span) *lisp-row-styles*)))
             spans)
       :lisp-code)
      ((some (lambda (span)
               (and (consp span) (member (car span) *code-row-styles*)))
             spans)
       :code)
      (t :default))))

(defun line-plain-text (line)
  "The unstyled text of a line (list of spans/strings)."
  (with-output-to-string (out)
    (dolist (span (if (listp line) line (list line)))
      (write-string (if (consp span) (cdr span) (princ-to-string span)) out))))

(defun render-line-string (line width)
  "Render LINE (a list of spans) padded/truncated to WIDTH visible columns."
  (let* ((plain (line-plain-text line))
         (visible (display-width plain))
         (base-style (line-base-style line)))
    (cond
      ((> visible width)
       ;; Truncate: re-render spans up to WIDTH plain chars.
       (truncate-styled-line line width))
      (t
       (with-output-to-string (out)
         (write-string (sgr base-style) out)
         (dolist (span (if (listp line) line (list line)))
           (write-string (render-span span base-style) out))
         (loop repeat (- width visible) do (write-char #\Space out))
         (write-string (sgr-reset) out))))))

(defun truncate-styled-line (line width)
  "Re-render LINE's spans up to WIDTH visible columns (M7-2), never splitting a
wide character across the boundary."
  (let ((remaining width)
        (base-style (line-base-style line)))
    (with-output-to-string (out)
      (write-string (sgr base-style) out)
      (dolist (span (if (listp line) line (list line)))
        (when (<= remaining 0) (return))
        (let* ((text (if (consp span) (cdr span) (princ-to-string span)))
               (style (and (consp span) (car span))))
          (multiple-value-bind (prefix cols) (take-columns text remaining)
            (write-string (render-span (if style (styled style prefix) prefix)
                                       base-style)
                          out)
            (decf remaining cols))))
      (write-string (sgr-reset) out))))

(defun render-lines (screen lines &key cursor-row cursor-column
                                       (cursor-visible nil))
  "Paint LINES (a list, top to bottom) to the tty, diffing against the
previous frame. Extra rows are cleared; the screen is padded to height.
A frame with no changed rows and an unmoved cursor emits NOTHING — the
old unconditional hide/show made the cursor visibly blink on every idle
repaint."
  (let* ((width (screen-width screen))
         (height (screen-height screen))
         (rendered (make-array height :initial-element nil))
         (previous (screen-previous screen))
         (dirty nil))
    ;; Materialize exactly HEIGHT rows.
    (loop for i from 0 below height
          for line = (nth i lines)
          do (setf (aref rendered i)
                   (render-line-string (or line '()) width)))
    (loop for i from 0 below height
          for new = (aref rendered i)
          for old = (and (< i (length previous)) (aref previous i))
          unless (equal new old) do (setf dirty t))
    (let ((cursor (list cursor-row cursor-column cursor-visible)))
      (when (or dirty (not (equal cursor (screen-last-cursor screen))))
        (when dirty
          (hide-cursor)
          (loop for i from 0 below height
                for new = (aref rendered i)
                for old = (and (< i (length previous)) (aref previous i))
                unless (equal new old)
                  do (write-tty (format nil "~C[~D;1H~C[2K~A" #\Esc (1+ i) #\Esc new)))
          ;; Save the frame.
          (setf (fill-pointer previous) 0)
          (loop for i from 0 below height
                do (vector-push-extend (aref rendered i) previous)))
        (when (and cursor-visible cursor-row cursor-column)
          (write-tty (format nil "~C[~D;~DH" #\Esc cursor-row cursor-column)))
        (if cursor-visible (show-cursor) (hide-cursor))
        (setf (screen-last-cursor screen) cursor)
        (flush-tty)))))
