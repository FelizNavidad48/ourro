(in-package #:ourro.tests)

(def-suite markdown-suite :in ourro)
(in-suite markdown-suite)

(defun md-styles (lines)
  (remove-duplicates
   (loop for line in lines
         append (loop for span in line when (consp span) collect (car span)))))

(defun md-text (lines)
  (with-output-to-string (out)
    (dolist (line lines)
      (dolist (span line)
        (write-string (if (consp span) (cdr span) (princ-to-string span)) out))
      (write-char #\Newline out))))

(defun line-visible-width (line)
  (reduce #'+ line :key (lambda (s) (length (if (consp s) (cdr s) s)))
                   :initial-value 0))

(test markdown-paragraph-wraps-to-width
  (let ((lines (ourro.tui:markdown-lines
                "the quick brown fox jumps over the lazy dog again and again" 20)))
    (is (> (length lines) 1))
    (is (every (lambda (line) (<= (line-visible-width line) 20)) lines))))

(test markdown-code-fence-not-wrapped
  (let* ((text (format nil "before~%```lisp~%(defun very-long-line-that-exceeds (the width limit keeps going))~%```~%after"))
         (lines (ourro.tui:markdown-lines text 30))
         (styles (md-styles lines)))
    (is (member :code styles))
    (is (member :dim styles))            ; language tag on the opening fence
    ;; Code is kept verbatim (truncated, never wrapped into separate words).
    (is (search "(defun very-long-line" (md-text lines)))))

