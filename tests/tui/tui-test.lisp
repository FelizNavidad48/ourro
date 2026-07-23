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

(test chrome-right-segments-keep-the-bar-background
  (let* ((view (ourro.tui:make-view :repo "demo" :generation "gen-0007"))
         (header (first (ourro.tui:render-component
                         (ourro.tui:view-header view) 80)))
         (status (first (ourro.tui:render-component
                         (ourro.tui:view-statusbar view) 80))))
    (is (eq :header (caar (last header))))
    (is (eq :status-accent (caar (last status))))
    (dolist (theme '(:light :dark))
      (unwind-protect
           (progn
             (ourro.tui:set-theme theme)
             (is (search (if (eq theme :light)
                             "48;2;255;251;241"
                             "48;2;36;23;19")
                         (ourro.tui::sgr (caar (last header)))))
             (is (search (if (eq theme :light)
                             "48;2;237;227;210"
                             "48;2;51;36;29")
                         (ourro.tui::sgr (caar (last status))))))
        (ourro.tui:set-theme :dark)))))

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

(test themes-are-truecolor-and-switchable
  (unwind-protect
       (progn
         (is (equal '(:light :dark) (ourro.tui:theme-names)))
         (is (eq :dark (ourro.tui:set-theme "dark")))
         (is (eq :dark (ourro.tui:current-theme)))
         (is (search "38;2;244;234;213"
                     (ourro.tui::sgr :default)))
         (is (null (ourro.tui:set-theme "sepia"))))
    (ourro.tui:set-theme :dark)))

(test span-restores-base-with-a-full-attribute-reset
  (unwind-protect
       (progn
         (ourro.tui:set-theme :light)
         (let ((rendered (ourro.tui::render-span
                          (ourro.tui:styled :bold "bold") :default)))
           (is (search (format nil "bold~A~A"
                               (ourro.tui::sgr-reset)
                               (ourro.tui::sgr :default))
                       rendered))))
    (ourro.tui:set-theme :dark)))

(test dark-lisp-tokens-share-the-row-background
  (unwind-protect
       (progn
         (ourro.tui:set-theme :dark)
         (dolist (style '(:lisp-code :lisp-code-dim :syntax-keyword
                          :syntax-symbol :syntax-string :syntax-comment
                          :syntax-paren))
           (is (search "48;2;36;23;19" (ourro.tui::sgr style)))))
    (ourro.tui:set-theme :dark)))

(test code-row-keeps-inverted-background-through-padding
  (unwind-protect
       (progn
         (ourro.tui:set-theme :light)
         (let ((rendered
                 (ourro.tui::render-line-string
                  (list (ourro.tui:styled :code "$ make test")) 12)))
           (is (search "48;2;25;15;11" rendered))
           (is (= 12 (ourro.tui:display-width (strip-ansi rendered))))))
    (ourro.tui:set-theme :dark)))

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

(test input-pane-renders-multiline
  (let ((input (make-instance 'ourro.tui:input-pane)))
    (ourro.tui:input-insert input (format nil "one~%two"))
    (is (= 2 (length (ourro.tui:render-component input 40))))))

(test slash-command-ghost-suggestion
  (let ((input (make-instance 'ourro.tui:input-pane)))
    (ourro.tui:input-insert input "/he")
    (ourro.agent::update-suggestion input)
    (is (string= "lp" (ourro.tui:input-suggestion input)))
    ;; Tab-accept completes the command.
    (ourro.agent::accept-suggestion input)
    (is (string= "/help" (ourro.tui:input-text input)))))


(defun strip-ansi (string)
  (cl-ppcre:regex-replace-all (format nil "~C\\[[0-9;]*m" #\Esc) string ""))

(test char-display-widths
  (is (= 1 (ourro.tui:char-display-width #\a)))
  (is (= 2 (ourro.tui:char-display-width (code-char #x26A1))))   ; ⚡ high voltage
  (is (= 2 (ourro.tui:char-display-width (code-char #x4E2D))))   ; 中 CJK
  (is (= 0 (ourro.tui:char-display-width (code-char #x0301)))))  ; combining acute

(test display-width-of-mixed-string
  ;; "a中b" = 1 + 2 + 1 = 4 columns from 3 characters.
  (is (= 4 (ourro.tui:display-width (format nil "a~Ab" (code-char #x4E2D)))))
  ;; a base letter plus a combining mark occupies one column.
  (is (= 1 (ourro.tui:display-width (format nil "e~A" (code-char #x0301))))))

(test take-columns-never-splits-wide-char
  (multiple-value-bind (prefix cols)
      (ourro.tui:take-columns (format nil "a~Ab" (code-char #x4E2D)) 2)
    ;; "a" fits (1 col); 中 would reach 3 > 2, so stop — prefix "a", 1 column.
    (is (string= "a" prefix))
    (is (= 1 cols))))

(test fit-pads-and-truncates-by-columns
  ;; Padding a 3-column string into 6 columns yields exactly 6 columns.
  (is (= 6 (ourro.tui:display-width (ourro.tui::fit "abc" 6))))
  ;; Fitting "a中" into 2 columns drops the straddling 中 and pads → "a ".
  (let ((fitted (ourro.tui::fit (format nil "a~A" (code-char #x4E2D)) 2)))
    (is (= 2 (ourro.tui:display-width fitted)))
    (is (string= "a " fitted))))

(test truncate-styled-line-respects-column-budget
  (let* ((wide (format nil "~A~A~A" (code-char #x4E2D)
                       (code-char #x4E2D) (code-char #x4E2D)))
         (line (list (ourro.tui:styled :assistant wide)))
         (visible (strip-ansi (ourro.tui::truncate-styled-line line 3))))
    ;; three wide chars = 6 cols; budget 3 → exactly one 中 (2 cols) fits.
    (is (= 2 (ourro.tui:display-width visible)))))

(test cjk-line-wraps-by-columns
  ;; Space-separated wide chars (each 2 cols) wrapped to width 3 → one per line.
  (let* ((cjk (format nil "~A ~A ~A ~A"
                      (code-char #x4E2D) (code-char #x6587)
                      (code-char #x6D4B) (code-char #x8BD5)))
         (lines (ourro.tui:wrap-text cjk 3)))
    (is (> (length lines) 1))
    (is (every (lambda (l) (<= (ourro.tui:display-width l) 3)) lines))))


(test decode-sgr-mouse-wheel
  (with-key-stream ((esc-seq "[<64;10;5M"))
    (is (eq :wheel-up (ourro.tui:read-key))))
  (with-key-stream ((esc-seq "[<65;10;5M"))
    (is (eq :wheel-down (ourro.tui:read-key))))
  ;; A left-click (button 0) is a no-op :mouse — never :escape.
  (with-key-stream ((esc-seq "[<0;3;4M"))
    (is (eq :mouse (ourro.tui:read-key)))))

(test decode-sgr-mouse-consumes-fully
  ;; The whole SGR sequence is consumed; the following key decodes normally.
  (with-key-stream ((concatenate 'string (esc-seq "[<0;3;4M") "x"))
    (is (eq :mouse (ourro.tui:read-key)))
    (is (eql #\x (ourro.tui:read-key)))))

(test decode-x10-mouse-consumes-three-bytes
  ;; ESC [ M then exactly 3 bytes (button+32, x+32, y+32). Button 64 → wheel-up.
  (with-key-stream ((concatenate 'string (esc-seq "[M")
                                 (string (code-char 96))    ; button 64
                                 (string (code-char 33))    ; x
                                 (string (code-char 33))    ; y
                                 "z"))
    (is (eq :wheel-up (ourro.tui:read-key)))
    (is (eql #\z (ourro.tui:read-key)))))

(test adjust-scroll-pins-and-clamps
  (is (= 0 (ourro.tui:adjust-scroll-for-append 0 5 100 20)))    ; bottom stays bottom
  (is (= 15 (ourro.tui:adjust-scroll-for-append 10 5 100 20)))  ; pin: add the growth
  (is (= 10 (ourro.tui:adjust-scroll-for-append 40 -30 30 20))) ; clamp on shrink
  (is (= 80 (ourro.tui:adjust-scroll-for-append 90 0 100 20)))) ; clamp to max-scroll

(test statusbar-shows-scroll-indicator
  (let ((sb (make-instance 'ourro.tui:statusbar-pane :scrolled 12)))
    (is (search "↑12"
                (with-output-to-string (out)
                  (dolist (span (first (ourro.tui:render-component sb 80)))
                    (write-string (cdr span) out)))))))

(test statusbar-busy-segment-never-prints-nil
  ;; F-worknil regression: spinner with no activity must not render " · NIL";
  ;; activity with no spinner must still render (it was dropped entirely);
  ;; both present join with " · ".
  (flet ((row (sb)
           (with-output-to-string (out)
             (dolist (span (first (ourro.tui:render-component sb 80)))
               (write-string (cdr span) out)))))
    (let ((text (row (make-instance 'ourro.tui:statusbar-pane
                                    :spinner "⠹ working…"))))
      (is (search "working…" text))
      (is (not (search "NIL" text))))
    (is (search "working… · evolving"
                (row (make-instance 'ourro.tui:statusbar-pane
                                    :spinner "⠹ working…"
                                    :activity "evolving"))))
    (is (search "evolving"
                (row (make-instance 'ourro.tui:statusbar-pane
                                    :activity "evolving"))))))

(test end-key-jumps-to-bottom-when-scrolled
  (let* ((agent (ourro.agent::make-agent
                 :provider (ourro.llm:make-scripted-provider '())))
         (input (ourro.tui:view-input (ourro.agent::agent-view agent)))
         (transcript (ourro.tui:view-transcript (ourro.agent::agent-view agent))))
    ;; empty input + scrolled → End jumps to the bottom
    (setf (ourro.tui:transcript-scroll transcript) 8)
    (ourro.agent::handle-editor-key agent input :end)
    (is (= 0 (ourro.tui:transcript-scroll transcript)))
    ;; non-empty input → End moves to line end, leaves the scroll alone
    (setf (ourro.tui:transcript-scroll transcript) 8)
    (ourro.tui:input-insert input "abc")
    (ourro.agent::handle-editor-key agent input :end)
    (is (= 8 (ourro.tui:transcript-scroll transcript)))))
