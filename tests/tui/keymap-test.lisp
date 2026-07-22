(in-package #:ourro.tests)

(def-suite keymap-suite :in ourro)
(in-suite keymap-suite)


(test decode-ss3-function-keys
  ;; vt100 application mode: ESC O P..S → F1..F4.
  (with-key-stream ((esc-seq "OP"))
    (is (eq :f1 (ourro.tui:read-key))))
  (with-key-stream ((esc-seq "OQ"))
    (is (eq :f2 (ourro.tui:read-key)))))

(test decode-csi-function-keys
  ;; vt220 CSI: 15~ → F5, 24~ → F12 (note the 16/22 gaps).
  (with-key-stream ((esc-seq "[15~"))
    (is (eq :f5 (ourro.tui:read-key))))
  (with-key-stream ((esc-seq "[24~"))
    (is (eq :f12 (ourro.tui:read-key)))))

(test decode-ctrl-e-reaches-keymap
  ;; F-ctrle regression: byte 5 must decode to :ctrl-e so the
  ;; (:ctrl-e . :toggle-inspector) keymap binding can fire — not to :end,
  ;; which starved the binding. End stays reachable via CSI; ctrl-a keeps
  ;; its readline :home meaning.
  (with-key-stream ((string (code-char 5)))
    (is (eq :ctrl-e (ourro.tui:read-key))))
  (with-key-stream ((string (code-char 1)))
    (is (eq :home (ourro.tui:read-key))))
  (with-key-stream ((esc-seq "[F"))
    (is (eq :end (ourro.tui:read-key)))))


(test bind-key-rejects-reserved-and-chars
  ;; A reserved chord and a printable character both refuse — chords only,
  ;; and never a key the editor already owns.
  (signals error (ourro.tui:bind-key :enter :nope (lambda ())))
  (signals error (ourro.tui:bind-key #\a :nope (lambda ())))
  (is-false (ourro.tui:key-bindable-p :f2))   ; F-row: fully reserved
  (is-false (ourro.tui:key-bindable-p :f7))   ; F-row: fully reserved
  (is-true (ourro.tui:key-bindable-p :alt-x)))

(test bind-key-registers-and-runs
  (let ((ran nil)
        (ourro.tui:*keymap* '())
        (ourro.tui:*commands* (make-hash-table :test #'eq)))
    (ourro.tui:bind-key :alt-t :test-cmd (lambda () (setf ran t)))
    (is (eq :test-cmd (ourro.tui:keymap-command :alt-t)))
    (is-true (ourro.tui:invoke-command :test-cmd))
    (is-true ran)))

(test bind-key-gene-binding-reverts
  ;; A gene's keybinding undoes through the SAME revert table as gene code.
  (let ((ourro.tui:*keymap* '())
        (ourro.tui:*commands* (make-hash-table :test #'eq)))
    (ourro.tui:bind-key :alt-g :g-cmd (lambda ()) :gene "tool/keybind-demo")
    (is (eq :g-cmd (ourro.tui:keymap-command :alt-g)))
    (ourro.kernel:revert-gene-definitions "tool/keybind-demo")
    (is (null (ourro.tui:keymap-command :alt-g)))))


(test ticker-key-guarded-by-empty-input
  (let* ((agent (ourro.agent::make-agent
                 :provider (ourro.llm:make-scripted-provider '())))
         (view (ourro.agent::agent-view agent))
         (ticker (ourro.tui:view-ticker view))
         (input (ourro.tui:view-input view)))
    ;; No ticker actions → nothing consumed.
    (is-false (ourro.agent::ticker-key agent input #\e))
    (setf (ourro.tui:ticker-text ticker) "learned edit-and-test"
          ;; (key label command) triples (M14-1): e→explain opens the inspector.
          (ourro.tui:ticker-actions ticker)
          '((#\e "e explain" :explain) (#\u "u undo" :revert)))
    ;; Empty input → `e` consumed and opens the inspector overlay.
    (is-true (ourro.agent::ticker-key agent input #\e))
    (is-true (ourro.tui:view-overlay view))
    ;; Non-empty input → `e` stays an ordinary letter.
    (ourro.tui:input-insert input "hello")
    (is-false (ourro.agent::ticker-key agent input #\e))))

(test overlay-swallows-paste
  ;; A bracketed paste must not leak into the input line hidden behind a modal
  ;; overlay (review #4). handle-key routes the overlay clause before paste.
  (let* ((agent (ourro.agent::make-agent
                 :provider (ourro.llm:make-scripted-provider '())))
         (view (ourro.agent::agent-view agent))
         (input (ourro.tui:view-input view)))
    (ourro.agent::open-inspector agent)
    (is-true (ourro.tui:view-overlay view))
    (ourro.agent::handle-key agent (cons :paste "sneaky text"))
    ;; The paste was swallowed by the modal — the input stays empty.
    (is (zerop (length (ourro.tui:input-text input))))))
