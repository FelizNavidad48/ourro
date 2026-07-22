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

