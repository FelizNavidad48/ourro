
(defpackage #:ourro.config
  (:use #:cl #:ourro.util)
  (:export #:setting
           #:reload-settings
           #:default-settings
           #:*settings-override*
           #:with-settings))

(in-package #:ourro.config)

(defparameter *default-settings*
  (list :thinking-level "LOW"        ; Gemini-3 thinking budget; "off"/"" disables
        :max-tokens nil              ; NIL → the provider's own default
        :max-stream-seconds 600      ; wall-clock budget for one streamed turn
        :max-tool-steps 25           ; model→tool iterations before a continue prompt
        :restart-policy :calm        ; :calm | :eager | :manual (generation handoff)
        :theme :light                ; :light | :dark
        :experimental-reflexes nil   ; background reflex firing opt-in
        :default-model "opus-4-6"    ; used when no OURRO_MODEL is set
        :bedrock-region "eu-north-1") ; always eu-north-1 unless deliberately changed
  "Built-in defaults for the tunable settings. A key present here documents the
configurable surface — config.sexp only needs the keys it overrides. The retry
knobs (:retry-max-attempts / :retry-backoff-cap) are DELIBERATELY absent: their
defaults live in the exported ourro.llm defvars (so tests can bind them), and
config only overrides when a config.sexp actually sets them.")

(defun default-settings () (copy-list *default-settings*))

(defvar *settings-override* nil
  "A plist of forced settings, highest precedence. The QA harness and tests bind
this (see WITH-SETTINGS) to pin values without touching a file or the process
environment.")

(defvar *file-settings* :unread
  "Memoized :SETTINGS plist read from $OURRO_HOME/config.sexp, or NIL when absent.
:UNREAD until first access; RELOAD-SETTINGS resets it.")

(defun config-path () (ourro-path "config.sexp"))

(defun file-settings ()
  (when (eq *file-settings* :unread)
    (setf *file-settings*
          (ignore-errors (pget (read-sexp-file (config-path)) :settings))))
  *file-settings*)

(defun reload-settings ()
  "Drop the memoized file read so the next SETTING re-reads config.sexp. Call
after (re)writing the config, or at boot in a fresh process."
  (setf *file-settings* :unread))

(defun setting (key &optional default)
  "The effective value of KEY: *SETTINGS-OVERRIDE*, then the config file's
:SETTINGS, then *DEFAULT-SETTINGS*, then DEFAULT. NIL is a real value here — a
key set to NIL wins over a lower-precedence non-NIL, matching a config author's
intent to unset something."
  (let ((cell (member key (append *settings-override* (file-settings)
                                  *default-settings*))))
    (if cell (second cell) default)))

(defmacro with-settings ((&rest key-values) &body body)
  "Bind *SETTINGS-OVERRIDE* so KEY-VALUES (a :key val … plist) win over the file
and defaults for the dynamic extent of BODY. Nests: outer overrides still apply
for keys not named here."
  `(let ((*settings-override* (append (list ,@key-values) *settings-override*)))
     ,@body))
