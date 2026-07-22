
(in-package #:ourro.kernel)

(defparameter *capability-requirements*
  '((cap/read-file . :filesystem-read)
    (cap/write-file . :filesystem-write)
    (cap/delete-file . :filesystem-write)
    (cap/ensure-directories . :filesystem-write)
    (cap/run-program . :subprocess)
    (cap/launch-program . :subprocess)
    (cap/http-request . :network))
  "Alist of sanctioned effect wrappers to the capability each requires.")

(defparameter *capability-requiring-names*
  '(;; kernel effect wrappers, matched by NAME so a wrapper is caught
    ;; regardless of which package's symbol names it
    ("CAP/READ-FILE" . :filesystem-read)
    ("CAP/WRITE-FILE" . :filesystem-write)
    ("CAP/DELETE-FILE" . :filesystem-write)
    ("CAP/ENSURE-DIRECTORIES" . :filesystem-write)
    ("CAP/RUN-PROGRAM" . :subprocess)
    ("CAP/LAUNCH-PROGRAM" . :subprocess)
    ("CAP/HTTP-REQUEST" . :network)
    ;; higher-level helpers
    ("COMPLETE" . :llm)
    ("COMPLETE-TEXT" . :llm)
    ("LIST-FILES" . :filesystem-read)
    ("SEARCH-FILES" . :filesystem-read)
    ("FILE-INFO" . :filesystem-read)
    ("READ-FILE-NUMBERED" . :filesystem-read)
    ;; observation surface — reading events / registering turn hooks (PR-7)
    ("RECENT-EVENTS" . :observe)
    ("ADD-TURN-HOOK" . :observe)
    ("UTILITY-SUMMARY" . :observe)
    ("CONTEXT-SUMMARY" . :observe)
    ("WORKSPACE-KNOWN-P" . :observe)
    ("REMEMBER-WORKSPACE" . :observe)
    ;; UI surface — panes, status widgets, keybindings (PR-7's UI half, M3)
    ("ADD-PANE" . :ui)
    ("REMOVE-PANE" . :ui)
    ("DEFINE-STATUS-WIDGET" . :ui)
    ("BIND-KEY" . :ui)
    ;; jobs — background subprocesses (M9). Starting/killing a job spawns or
    ;; signals a process (:subprocess); reading status is observe-only.
    ("START-JOB" . :subprocess)
    ("JOB-KILL" . :subprocess)
    ("JOB-STATUS" . :observe)
    ("JOBS-SUMMARY" . :observe)
    ;; reflexes — trigger-driven automation (M13). Registering an automation
    ;; that subscribes to the live event stream is the :automate effect; posting
    ;; a non-interrupting note reads/writes only the observation surface.
    ("DEFINE-AUTOMATION" . :automate)
    ("DEFINE-REFLEX" . :automate)
    ("POST-NOTE" . :observe)
    ;; the intern (M15): a reflex requesting a background read-only mini-turn
    ;; spends the model (:llm); the mini-turn itself is capability-ceilinged.
    ("REQUEST-INVESTIGATION" . :llm))
  "Capability requirements keyed by symbol NAME (package-independent).")

(defparameter *forbidden-symbol-names*
  '(;; evaluation / compilation escape hatches
    "EVAL" "COMPILE" "COMPILE-FILE" "LOAD" "EVAL-WHEN"
    ;; Dynamic invocation and global introspection make a name blacklist
    ;; meaningless: a function can otherwise discover DELETE-FILE at runtime
    ;; without naming it in source.
    "FUNCALL" "APPLY" "APROPOS" "APROPOS-LIST"
    ;; Raw registry invocation is a verifier-only test fixture surface. Live
    ;; gene code enters tools through the agent's version-stable boundary.
    "RUN-TOOL" "FIND-TOOL" "LIST-TOOLS"
    ;; reader / symbol forging
    "READ" "READ-FROM-STRING" "READ-PRESERVING-WHITESPACE" "READ-DELIMITED-LIST"
    "INTERN" "FIND-SYMBOL" "MAKE-SYMBOL" "UNINTERN" "IMPORT" "EXPORT" "SHADOW"
    "SHADOWING-IMPORT" "USE-PACKAGE" "UNUSE-PACKAGE"
    ;; package management
    "MAKE-PACKAGE" "DELETE-PACKAGE" "RENAME-PACKAGE" "IN-PACKAGE" "DEFPACKAGE"
    ;; definition surgery (the revert table is kernel-owned)
    "FDEFINITION" "SYMBOL-FUNCTION" "MACRO-FUNCTION" "COMPILER-MACRO-FUNCTION"
    "SET-MACRO-CHARACTER" "SET-DISPATCH-MACRO-CHARACTER" "COPY-READTABLE"
    "SET-SYNTAX-FROM-CHAR"
    ;; raw filesystem effects (use CAP/* wrappers)
    "OPEN" "WITH-OPEN-FILE" "DELETE-FILE" "RENAME-FILE"
    "ENSURE-DIRECTORIES-EXIST" "DRIBBLE" "ED"
    ;; process / image control
    "QUIT" "EXIT" "ABORT-THREAD" "SAVE-LISP-AND-DIE" "RUN-PROGRAM"
    "LAUNCH-PROGRAM" "RUN-COMMAND"
    ;; nondeterminism: learned behavior must be reproducible machine code
    ;; (PR-13). RANDOM is not even imported into OURRO.API (M5-2); listing it
    ;; here also bars a fully-qualified CL:RANDOM and gives a clear rejection.
    "RANDOM" "MAKE-RANDOM-STATE"
    ;; timers/sleep loops are allowed; SLEEP itself is fine.
    )
  "Symbol names rejected anywhere in a gene body, regardless of package.")

(defparameter *forbidden-package-prefixes*
  '("SB-" "UIOP" "ASDF")
  "Packages whose symbols may not appear in gene code at all.")

(defparameter *kernel-allowed-symbols*
  '(cap/read-file cap/write-file cap/delete-file cap/ensure-directories
    cap/run-program cap/launch-program cap/http-request
    require-capability capability-violation evolved-code-failure
    verification-failure ourro-error)
  "The only OURRO.KERNEL symbols that may appear in gene code.")

(defun symbol-package-name (symbol)
  (let ((package (symbol-package symbol)))
    (and package (package-name package))))

(defun forbidden-package-p (package-name)
  (and package-name
       (some (lambda (prefix)
               (or (string= package-name prefix)
                   (string-prefix-p prefix package-name)))
             *forbidden-package-prefixes*)))

(defun ourro-api-symbol-p (symbol)
  "Whether SYMBOL is deliberately present on the public gene surface."
  (let ((api (find-package :ourro.api)))
    (and api
         (multiple-value-bind (found status)
             (find-symbol (symbol-name symbol) api)
           (and found (eq status :external) (eq found symbol))))))

(defun gene-lexical-package-p (package-name)
  "Whether PACKAGE-NAME is a reader-created home for a gene/scratch binding.

These packages contribute names, not authority: imported operators still have
their defining package and must be the exact symbol re-exported by OURRO.API."
  (and package-name
       (or (string-prefix-p "GEN-CANDIDATE-" package-name)
           (member package-name '("OURRO.GENES" "OURRO-SCRATCH" "OURRO.TESTS")
                   :test #'string=))))

(defun check-atom (symbol capabilities violations &key allow-test-helpers)
  "Check SYMBOL against the rulebooks; push violation plists onto VIOLATIONS."
  ;; Keywords are self-evaluating data, never operators or effect wrappers, so
  ;; the name-based rulebooks (forbidden names, capability wrappers) do not apply
  ;; to them: a trigger pattern's :exit / :load / :search key (M13) is inert
  ;; data, not a call to EXIT / LOAD / SEARCH. (Rulebook 3 — forbidden packages —
  ;; can't hit KEYWORD anyway.)
  (when (keywordp symbol)
    (return-from check-atom violations))
  (let ((name (symbol-name symbol))
        (package-name (symbol-package-name symbol)))
    (cond
      ;; Rulebook 3: forbidden packages.
      ((forbidden-package-p package-name)
       (push (list :symbol symbol
                   :reason (format nil "Symbols from package ~A are not allowed ~
in gene code; use the OURRO.API surface instead." package-name))
             violations))
      ((and (string= package-name "OURRO.KERNEL")
            (not (member symbol *kernel-allowed-symbols*)))
       (push (list :symbol symbol
                   :reason "References OURRO.KERNEL internals; only the exported CAP/* wrappers are allowed.")
             violations))
      ;; Positive product boundary: any package-qualified symbol outside the
      ;; exact public API is forbidden. This is deliberately broader than an
      ;; OURRO.* blacklist: DEXADOR, BT, POSIX, implementation helpers, and a
      ;; newly loaded third-party package must not become an unreviewed escape
      ;; merely because its name was absent from a denylist.
      ((and package-name
            (not (gene-lexical-package-p package-name))
            (not (ourro-api-symbol-p symbol))
            (not (string= package-name "OURRO.API"))
            (not (string= package-name "OURRO.KERNEL")))
       (push (list :symbol symbol
                   :reason (format nil "~A is outside the positive gene package boundary; gene code may name only lexical symbols and exact OURRO.API exports."
                                   symbol))
             violations))
      ;; Rulebook 1: forbidden names.
      ((and (member name *forbidden-symbol-names* :test #'string=)
            (not (and allow-test-helpers
                      (member name '("RUN-TOOL" "FIND-TOOL" "LIST-TOOLS")
                              :test #'string=))))
       (push (list :symbol symbol
                   :reason (format nil "~A is not allowed in gene code~@[; use ~A instead~]."
                                   name (sanctioned-alternative name)))
             violations))
      ;; Rulebook 2: capability requirements (matched by name, so any
      ;; spelling of an effect wrapper is covered).
      (t
       (let ((requirement
               (or (cdr (assoc symbol *capability-requirements*))
                   (cdr (assoc name *capability-requiring-names*
                               :test #'string=)))))
         (when (and requirement (not (member requirement capabilities)))
           (push (list :symbol symbol
                       :capability requirement
                       :reason (format nil "~A requires the ~S capability, which this gene does not declare."
                                       symbol requirement))
                 violations)))))
    violations))

(defun sanctioned-alternative (name)
  (cond ((member name '("OPEN" "WITH-OPEN-FILE") :test #'string=)
         "CAP/READ-FILE or CAP/WRITE-FILE")
        ((string= name "DELETE-FILE") "CAP/DELETE-FILE")
        ((string= name "ENSURE-DIRECTORIES-EXIST") "CAP/ENSURE-DIRECTORIES")
        ((member name '("RUN-PROGRAM" "LAUNCH-PROGRAM" "RUN-COMMAND")
                 :test #'string=)
         "CAP/RUN-PROGRAM")
        (t nil)))

(defun lint-gene-body (forms &key capabilities allow-test-helpers)
  "Scan FORMS (a list of gene code forms). Returns a list of violation
plists; NIL means the lint passed. CAPABILITIES is the gene's declared
capability list."
  (dolist (capability capabilities)
    (unless (capability-p capability)
      (return-from lint-gene-body
        (list (list :reason (format nil "Unknown capability ~S; the valid set is ~S."
                                    capability +all-capabilities+))))))
  (let ((violations '())
        (seen (make-hash-table :test #'eq)))
    (labels ((walk (x)
               (cond ((consp x) (walk (car x)) (walk (cdr x)))
                     ((symbolp x)
                      (unless (or (null x) (gethash x seen))
                        (setf (gethash x seen) t)
                        (setf violations
                              (check-atom x capabilities violations
                                          :allow-test-helpers
                                          allow-test-helpers)))))))
      (mapc #'walk forms))
    (nreverse violations)))

(defun lint-violations (violations)
  "Render VIOLATIONS as diagnostics text for LLM feedback."
  (with-output-to-string (out)
    (dolist (violation violations)
      (format out "~&- ~A~%" (pget violation :reason)))))

(defun effectful-operator-capability (symbol)
  "Return the capability SYMBOL requires, or NIL."
  (cdr (assoc symbol *capability-requirements*)))
