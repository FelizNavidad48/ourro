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

(test markdown-bold-and-inline-code
  (let* ((lines (ourro.tui:markdown-lines "use **pnpm** not `npm` here" 60))
         (styles (md-styles lines)))
    (is (member :bold styles))
    (is (member :inline-code styles))
    (is (search "pnpm" (md-text lines)))
    (is (search "npm" (md-text lines)))))

(test markdown-heading-and-bullet
  (let* ((lines (ourro.tui:markdown-lines
                 (format nil "## Title~%- first~%- second") 60))
         (styles (md-styles lines))
         (text (md-text lines)))
    (is (member :accent styles))
    (is (search "Title" text))
    (is (search "•" text))
    (is (search "first" text))
    (is (search "second" text))))

(test tool-result-echo-line
  (let ((agent (ourro.agent::make-agent
                :provider (ourro.llm:make-scripted-provider '()))))
    (ourro.agent::echo-tool-result agent (format nil "ok done~%(second line)") nil 42)
    (ourro.agent::echo-tool-result agent "kaboom" t 7)
    (let ((text (agent-transcript-text agent)))
      ;; The ↳ line now carries the ring index [N] (M7-5).
      (is (search "ok done" text))
      (is (search "42ms" text))
      (is (null (search "second line" text)))   ; only the first line is echoed
      (is (search "ERROR: kaboom" text)))))
