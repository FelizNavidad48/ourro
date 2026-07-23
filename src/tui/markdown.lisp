
(in-package #:ourro.tui)

(export '(markdown-lines wrap-spans))

(defun parse-inline (text default-style)
  "Parse **bold** and `inline code` in TEXT into a list of (style . string)
spans; unmarked runs get DEFAULT-STYLE."
  (let ((spans '())
        (i 0)
        (n (length text))
        (buf (make-string-output-stream)))
    (flet ((flush (style)
             (let ((s (get-output-stream-string buf)))
               (when (plusp (length s)) (push (cons style s) spans)))))
      (loop while (< i n) do
        (let ((c (char text i)))
          (cond
            ;; `inline code`
            ((char= c #\`)
             (let ((end (position #\` text :start (1+ i))))
               (cond (end
                      (flush default-style)
                      (push (cons :inline-code (subseq text (1+ i) end)) spans)
                      (setf i (1+ end)))
                     (t (write-char c buf) (incf i)))))
            ;; **bold**
            ((and (char= c #\*) (< (1+ i) n) (char= (char text (1+ i)) #\*))
             (let ((end (search "**" text :start2 (+ i 2))))
               (cond (end
                      (flush default-style)
                      (push (cons :bold (subseq text (+ i 2) end)) spans)
                      (setf i (+ end 2)))
                     (t (write-char c buf) (incf i)))))
            (t (write-char c buf) (incf i)))))
      (flush default-style))
    (nreverse spans)))

(defun span-words (spans)
  "Flatten SPANS into (style . word) tokens, splitting on spaces."
  (loop for (style . text) in spans
        append (loop for word in (uiop:split-string text :separator '(#\Space))
                     when (plusp (length word))
                       collect (cons style word))))

(defun wrap-spans (spans width &key (indent 1) (hang 1))
  "Word-wrap styled SPANS to WIDTH, preserving per-word styles. INDENT columns
lead the first line, HANG columns lead continuation lines. Returns a list of
lines, each a list of (style . string) spans."
  (let ((words (span-words spans))
        (lines '())
        (current '())
        (col 0))
    (flet ((newline ()
             (push (nreverse current) lines)
             (setf current '() col 0))
           (pad (n) (when (plusp n)
                      (push (cons :assistant (make-string n :initial-element #\Space))
                            current)
                      (incf col n))))
      (pad indent)
      (dolist (tok words)
        (let* ((style (car tok)) (word (cdr tok)) (wlen (display-width word))
               (margin (if lines hang indent)))
          (when (and (> col margin) (> (+ col 1 wlen) width))
            (newline) (pad hang)
            (setf margin hang))
          (when (> col margin)
            (push (cons :assistant " ") current) (incf col))
          (push (cons style word) current)
          (incf col wlen)))
      (when current (newline)))
    (nreverse lines)))

(defun fit-code (text width)
  "Truncate (never wrap) a code line to WIDTH visible columns (M7-2)."
  (if (> (display-width text) width) (values (take-columns text width)) text))

(defun lisp-language-p (language)
  (member (string-downcase language)
          '("lisp" "common-lisp" "commonlisp" "cl" "sbcl")
          :test #'string=))

(defun lisp-delimiter-p (char)
  (or (member char '(#\( #\) #\[ #\] #\{ #\} #\" #\;))
      (member char '(#\Space #\Tab #\Newline #\Return))))

(defun highlight-lisp-line (text)
  "Lex one display line into palette-backed Lisp syntax spans."
  (let ((spans '())
        (i 0)
        (n (length text)))
    (labels ((emit (style start end)
               (when (< start end)
                 (push (styled style (subseq text start end)) spans)))
             (scan-string ()
               (let ((start i) (escaped nil))
                 (incf i)
                 (loop while (< i n) do
                   (let ((char (char text i)))
                     (incf i)
                     (cond
                       (escaped (setf escaped nil))
                       ((char= char #\\) (setf escaped t))
                       ((char= char #\") (return)))))
                 (emit :syntax-string start i)))
             (scan-token ()
               (let ((start i))
                 (loop while (and (< i n)
                                  (not (lisp-delimiter-p (char text i))))
                       do (incf i))
                 (let ((token (subseq text start i)))
                   (emit (cond
                           ((and (plusp (length token))
                                 (char= (char token 0) #\:))
                            :syntax-keyword)
                           ((every (lambda (char)
                                     (or (digit-char-p char)
                                         (find char "+-./")))
                                   token)
                            :lisp-code)
                           (t :syntax-symbol))
                         start i)))))
      (loop while (< i n) do
        (let ((char (char text i)))
          (cond
            ((char= char #\;)
             (emit :syntax-comment i n)
             (setf i n))
            ((char= char #\") (scan-string))
            ((find char "()[]{}")
             (emit :syntax-paren i (1+ i))
             (incf i))
            ((member char '(#\Space #\Tab #\Newline #\Return))
             (let ((start i))
               (loop while (and (< i n)
                                (member (char text i)
                                        '(#\Space #\Tab #\Newline #\Return)))
                     do (incf i))
               (emit :lisp-code start i)))
            (t (scan-token)))))
      (nreverse spans))))

(defun markdown-lines (text width)
  "Render markdown TEXT to styled transcript lines at WIDTH columns."
  (let ((out '())
        (in-code nil)
        (code-language "")
        (w (max 8 width)))
    (dolist (raw (uiop:split-string text :separator '(#\Newline)))
      (let ((trimmed (string-left-trim '(#\Space #\Tab) raw)))
        (cond
          ;; Fence toggles code mode.
          ((and (>= (length trimmed) 3) (string= "```" (subseq trimmed 0 3)))
           (cond
             ((not in-code)
              (setf in-code t)
              (let ((lang (string-trim '(#\Space) (subseq trimmed 3))))
                (setf code-language lang)
                (when (plusp (length lang))
                  (push (list (styled (if (lisp-language-p lang)
                                          :lisp-code-dim
                                          :code-dim)
                                      (format nil "  ~A" lang)))
                        out))))
             (t (setf in-code nil code-language ""))))
          (in-code
           (let ((line (format nil "  ~A" (fit-code raw (- w 2)))))
             (push (if (lisp-language-p code-language)
                       (highlight-lisp-line line)
                       (list (styled :code line)))
                   out)))
          ((zerop (length trimmed))
           (push '() out))              ; blank line
          ;; Heading.
          ((char= (char trimmed 0) #\#)
           (let ((h (string-left-trim '(#\# #\Space) trimmed)))
             (dolist (l (wrap-spans (list (cons :accent h)) w :indent 1 :hang 1))
               (push l out))))
          ;; Bullet.
          ((and (>= (length trimmed) 2)
                (member (char trimmed 0) '(#\- #\*))
                (char= (char trimmed 1) #\Space))
           (dolist (l (wrap-spans (cons (cons :accent "•")
                                        (parse-inline (subseq trimmed 2) :assistant))
                                  w :indent 1 :hang 3))
             (push l out)))
          ;; Paragraph.
          (t (dolist (l (wrap-spans (parse-inline trimmed :assistant)
                                    w :indent 1 :hang 1))
               (push l out))))))
    (nreverse out)))
