(in-package #:ourro.tests)


(def-suite qa-operator-suite :in ourro)
(in-suite qa-operator-suite)

(test positionals-collects-message-after-a-flag
  ;; F-arg7f2: `say --session X "msg"` dropped the message because the old
  ;; POSITIONALS stopped at the first --flag. It must skip flag/value pairs
  ;; wherever they sit and still return the message.
  (is (equal '("msg")
             (ourro.qa.operator::positionals '("--session" "X" "msg"))))
  ;; Message-first ordering keeps working too.
  (is (equal '("msg")
             (ourro.qa.operator::positionals '("msg" "--session" "X"))))
  ;; A flag between positionals doesn't swallow a real positional.
  (is (equal '("kill-agent")
             (ourro.qa.operator::positionals '("--session" "X" "kill-agent"))))
  ;; Multi-word message with a flag after it.
  (is (equal '("hello" "world")
             (ourro.qa.operator::positionals
              '("hello" "world" "--timeout" "40")))))

(test positionals-boolean-flags-take-no-value
  ;; A valueless flag must not swallow the following positional — including
  ;; the tolerated legacy no-ops (--allow-live), kept in *boolean-flags* so a
  ;; stale invocation can't eat a real token.
  (is (equal '("kill-agent")
             (ourro.qa.operator::positionals '("--keep-home" "kill-agent"))))
  (is (equal '("payload")
             (ourro.qa.operator::positionals '("--ansi" "payload" "--session" "s"))))
  (is (equal '("payload")
             (ourro.qa.operator::positionals '("--allow-live" "payload")))))

(test normalize-key-covers-chords-and-rejects-unknown
  ;; F-keylit: every ctrl-<letter> chord normalizes (both spellings), named
  ;; keys and f1..f12 map, single chars pass through — and anything else
  ;; returns NIL so op-key refuses it instead of typing it as literal text.
  (is (string= "C-w" (ourro.qa.operator::normalize-key "ctrl-w")))
  (is (string= "C-a" (ourro.qa.operator::normalize-key "ctrl-a")))
  (is (string= "C-e" (ourro.qa.operator::normalize-key "C-e")))
  (is (string= "PageUp" (ourro.qa.operator::normalize-key "pgup")))
  (is (string= "PageDown" (ourro.qa.operator::normalize-key "pagedown")))
  (is (string= "F2" (ourro.qa.operator::normalize-key "f2")))
  (is (string= "F12" (ourro.qa.operator::normalize-key "F12")))
  (is (string= "Escape" (ourro.qa.operator::normalize-key "esc")))
  (is (string= "q" (ourro.qa.operator::normalize-key "q")))
  (is (null (ourro.qa.operator::normalize-key "ctrl-!")))
  (is (null (ourro.qa.operator::normalize-key "f13")))
  (is (null (ourro.qa.operator::normalize-key "bogus-key"))))


(test spawn-rejects-bad-workspace-mission-combos
  (let ((ourro.qa.operator::*exit-nonzero* nil))
    (flet ((try (&rest args)
             ;; EMIT prints the sexp; swallow it and judge the return plist.
             ;; A Vertex model is pinned so an ambient Claude OURRO_MODEL with
             ;; no Bedrock key can't trip the earlier boot-crash guard.
             (let ((out (make-string-output-stream)))
               (let ((*standard-output* out))
                 (apply #'ourro.qa.operator:op-spawn
                        :model "gemini-3.1-pro" args)))))
      ;; A fixture seeds the sandbox workspace; --workspace replaces it.
      (is (search "mutually exclusive"
                  (getf (try :workspace "/tmp/" :fixture "qa/fixtures/tinyrepo")
                        :error)))
      ;; A workspace must already exist — the caller owns that directory.
      (is (search "not found"
                  (getf (try :workspace "/nonexistent-ourro-ws-xyz/") :error)))
      ;; :dev works in the repo by design; pinning a workspace is a mistake.
      (is (search "--command run"
                  (getf (try :workspace "/tmp/" :command :dev) :error)))
      ;; A dangling mission file fails fast, before the expensive init.
      (is (search "not found"
                  (getf (try :mission "/nonexistent-mission-xyz.md") :error)))
      ;; --mission-result alone is meaningless.
      (is (search "requires --mission"
                  (getf (try :mission-result "/tmp/r.sexp") :error))))))


(defun mission-files ()
  (directory (merge-pathnames "qa/missions/*.sexp"
                              (asdf:system-source-directory "ourro"))))

(test mission-bank-is-present-and-varied
  (is-true (>= (length (mission-files)) 5)))

(test missions-are-well-formed-and-iterative
  (dolist (file (mission-files))
    (let* ((forms (ourro.kernel:safe-read-forms
                   (uiop:read-file-string file)
                   :package (find-package :keyword)))
           (form (first forms)))
      (is-true (and (consp form) (eq (first form) :mission))
               "~A: not a (mission …) form" (file-namestring file))
      (is-true (stringp (second form))
               "~A: mission name must be a string" (file-namestring file))
      (let ((plist (cddr form)))
        (dolist (key '(:persona :brief :arc :verify :watch :baseline :wrap-up))
          (is-true (getf plist key)
                   "~A: missing ~S section" (file-namestring file) key))
        ;; The iterative-workflow mandate: a real mission has many beats.
        (is-true (>= (length (getf plist :arc)) 6)
                 "~A: arc has fewer than 6 beats" (file-namestring file))
        ;; A mission that ships a fixture must point at a real directory.
        ;; NOTE: mission files are read in the KEYWORD package, where a bare
        ;; `nil` reads as the truthy :NIL — a fixtureless mission must OMIT
        ;; the :fixture key entirely, and only a string counts as a path.
        (let ((fixture (getf plist :fixture)))
          (is-true (or (null fixture) (stringp fixture))
                   "~A: :fixture must be a string or omitted (a bare nil reads as :NIL here)"
                   (file-namestring file))
          (when (stringp fixture)
            (is-true (uiop:directory-exists-p
                      (merge-pathnames (concatenate 'string fixture "/")
                                       (asdf:system-source-directory "ourro")))
                     "~A: fixture ~A does not exist"
                     (file-namestring file) fixture)))))))
