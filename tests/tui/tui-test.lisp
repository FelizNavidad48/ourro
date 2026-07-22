(in-package #:ourro.tests)

(def-suite tui-suite :in ourro)
(in-suite tui-suite)

(test wrap-text-respects-width
  (let ((lines (ourro.tui:wrap-text
                "the quick brown fox jumps over the lazy dog" 15)))
    (is (every (lambda (line) (<= (length line) 15)) lines))
    (is (> (length lines) 1))))

(test view-renders-header
  (let* ((view (ourro.tui:make-view :repo "demo" :generation "gen-0007"))
         (lines (ourro.tui:render-component (ourro.tui:view-header view) 80)))
    (is (= 1 (length lines)))
    (is (search "gen-0007"
                (with-output-to-string (out)
                  (dolist (span (first lines))
                    (write-string (cdr span) out)))))))

(test ticker-shows-when-set
  (let ((ticker (make-instance 'ourro.tui:ticker-pane)))
    (is (null (ourro.tui:render-component ticker 80)))
    (setf (ourro.tui:ticker-text ticker) "learned something")
    (is (= 1 (length (ourro.tui:render-component ticker 80))))))

(test screen-diff-render-does-not-error
  ;; Render to a broadcast stream so no tty is required.
  (let ((ourro.tui::*tty-output* (make-broadcast-stream))
        (screen (ourro.tui:make-screen 40 10))
        (view (ourro.tui:make-view :repo "x")))
    (setf (ourro.tui:transcript-lines (ourro.tui:view-transcript view))
          (list (list (ourro.tui:styled :assistant "hello"))))
    (finishes (ourro.tui:paint-frame screen view))))

(test input-pane-shows-text
  (let ((input (make-instance 'ourro.tui:input-pane :text "hi there")))
    (let ((rendered (ourro.tui:render-component input 40)))
      (is (search "hi there"
                  (with-output-to-string (out)
                    (dolist (span (first rendered))
                      (write-string (cdr span) out))))))))


(defmacro with-key-stream ((string) &body body)
  `(let ((ourro.tui::*tty-input* (make-string-input-stream ,string))
         (ourro.tui::*tty-fd* nil))
     ,@body))

(defun esc-seq (&rest parts)
  (apply #'concatenate 'string (string #\Esc) parts))

(test decode-plain-enter-vs-ctrl-j
  (with-key-stream ((concatenate 'string (string #\Return)
                                 (string (code-char 10))))
    (is (eq :enter (ourro.tui:read-key)))
    (is (eq :shift-enter (ourro.tui:read-key)))))

(test decode-shift-enter-kitty-and-xterm
  ;; kitty / CSI-u encoding
  (with-key-stream ((esc-seq "[13;2u"))
    (is (eq :shift-enter (ourro.tui:read-key))))
  ;; xterm modifyOtherKeys encoding
  (with-key-stream ((esc-seq "[27;2;13~"))
    (is (eq :shift-enter (ourro.tui:read-key)))))

(test decode-arrows-and-word-motion
  (with-key-stream ((concatenate 'string (esc-seq "[A") (esc-seq "[1;5C")))
    (is (eq :up (ourro.tui:read-key)))
    (is (eq :word-right (ourro.tui:read-key)))))

(test decode-ctrl-c-under-modify-other-keys
  ;; With modifyOtherKeys=2, ctrl-c arrives as CSI 27;5;99~ — it must still
  ;; decode to :ctrl-c or the user cannot quit.
  (with-key-stream ((esc-seq "[27;5;99~"))
    (is (eq :ctrl-c (ourro.tui:read-key)))))

(test bracketed-paste-is-one-event
  (with-key-stream ((concatenate 'string
                                 (esc-seq "[200~")
                                 "hello" (string #\Return) "world"
                                 (esc-seq "[201~")))
    (let ((key (ourro.tui:read-key)))
      (is (consp key))
      (is (eq :paste (car key)))
      ;; CR normalized to LF; the paste never auto-submits.
      (is (string= (format nil "hello~%world") (cdr key))))))

(test lone-escape-still-decodes
  (with-key-stream ((string #\Esc))
    (is (eq :escape (ourro.tui:read-key)))))


(test input-editor-cursor-ops
  (let ((input (make-instance 'ourro.tui:input-pane)))
    (ourro.tui:input-insert input "hello")
    (ourro.tui:input-move input -2)
    (ourro.tui:input-insert input "XX")
    (is (string= "helXXlo" (ourro.tui:input-text input)))
    (ourro.tui:input-backspace input)
    (is (string= "helXlo" (ourro.tui:input-text input)))
    (is (= 4 (ourro.tui:input-cursor input)))))

(test input-editor-word-delete
  (let ((input (make-instance 'ourro.tui:input-pane)))
    (ourro.tui:input-insert input "make test now")
    (ourro.tui:input-delete-word-back input)
    (is (string= "make test " (ourro.tui:input-text input)))))

(test input-editor-multiline-motion
  (let ((input (make-instance 'ourro.tui:input-pane)))
    (ourro.tui:input-insert input (format nil "alpha~%beta"))
    (is (= 2 (ourro.tui:input-line-count input)))
    (is-true (ourro.tui:input-move-line input :up))
    (multiple-value-bind (line column) (ourro.tui:input-cursor-line-col input)
      (is (= 0 line))
      (is (= 4 column)))
    (is-false (ourro.tui:input-move-line input :up))))

