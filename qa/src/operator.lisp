
(defpackage #:ourro.qa.operator
  (:use #:cl)
  (:export #:*repo-root* #:*qa-root*
           #:cli-main #:emit
           ;; session lifecycle
           #:op-spawn #:op-kill #:resolve-session #:session-home #:session-name
           ;; input
           #:op-say #:op-key #:op-paste
           ;; observation
           #:op-screen #:op-state #:op-events #:op-collect
           ;; synchronization
           #:op-await-idle #:op-await-quiescent #:op-await-generation-change
           #:op-await-event
           ;; chaos
           #:op-chaos
           ;; low-level surfaces (reused by the runner's tmux backend)
           #:tmux #:capture #:qa-status #:read-sexp-file #:pget #:session-event-file
           #:pane-dead-p
           ;; shared helpers for the standalone loop files
           #:env))

(in-package #:ourro.qa.operator)


(defparameter *repo-root*
  (when *load-truename*
    ;; <repo>/qa/src/operator.lisp → up three to <repo>/
    (truename (merge-pathnames "../../" (directory-namestring *load-truename*))))
  "The ourro repository root, captured at load time so subcommands work
regardless of the caller's cwd. Overridable with OURRO_QA_REPO.")

(defparameter *qa-root* #p"/tmp/ourro-qa/"
  "Per-run sandboxes live here; qa-clean sweeps it.")

(defun repo-p (dir)
  "DIR is the ourro repo root iff it holds ourro.asd."
  (and dir (probe-file (merge-pathnames "ourro.asd" dir)) (truename dir)))

(defun asdf-repo-root ()
  "The ourro system source dir, if ASDF is loaded and knows it. Used when
this file was compiled to a fasl in the ASDF cache, so *load-truename* points at
the cache rather than the source tree."
  (when (find-package :asdf)
    (ignore-errors
     (funcall (find-symbol "SYSTEM-SOURCE-DIRECTORY" :asdf) "ourro"))))

(defun find-repo-upward (&optional (start (truename #p"./")))
  "Walk up from START looking for ourro.asd."
  (loop for dir = start then parent
        for parent = (truename (merge-pathnames "../" dir))
        for hit = (repo-p dir)
        when hit do (return hit)
        when (equal (truename dir) parent) do (return nil)))

(defun repo-root ()
  "Resolve the ourro repo root robustly across load modes: OURRO_QA_REPO env,
then ASDF's source dir, then the load-time guess (standalone `sbcl --script`),
then a walk up from cwd."
  (or (let ((e (sb-ext:posix-getenv "OURRO_QA_REPO")))
        (and e (plusp (length e)) (repo-p (pathname (ensure-slash e)))))
      (asdf-repo-root)
      (repo-p *repo-root*)
      (find-repo-upward)
      (truename #p"./")))

(defun ensure-slash (s) (if (char= (char s (1- (length s))) #\/) s (concatenate 'string s "/")))

(defun pget (plist key &optional default)
  (getf plist key default))

(defun now () (get-universal-time))

(defun iso-now ()
  (multiple-value-bind (s m h d mo y) (decode-universal-time (now) 0)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ" y mo d h m s)))

(defun qa-package ()
  "The package all QA files are read and printed in. It uses CL, so a bare NIL
or T in a file (the event log's convention — see src/util.lisp with-sexp-syntax)
reads back as the real boolean, never as a truthy :NIL keyword. Reading in the
KEYWORD package — as this first did — turned the event log's `:usage NIL` into
`:usage :NIL`, which broke the tmux tier's llm-spend accounting."
  (find-package :ourro.qa.operator))

(defun read-sexp-file (path)
  "All top-level forms in PATH (readable sexps), *read-eval* off. NIL if absent.
Torn-final-line tolerant: a partial trailing form (a concurrent writer mid-append)
yields the forms read so far rather than discarding the whole file."
  (when (probe-file path)
    (handler-case
        (with-open-file (in path :direction :input)
          (let ((*read-eval* nil)
                (*package* (qa-package))
                (forms '()))
            (handler-case
                (loop for form = (read in nil :eof)
                      until (eq form :eof)
                      do (push form forms))
              (error () nil))          ; keep whatever parsed before the tear
            (nreverse forms)))
      (error () nil))))

(defun read-first-sexp (path) (first (read-sexp-file path)))

(defun slurp (path)
  (when (probe-file path)
    (with-open-file (in path :direction :input :external-format :utf-8)
      (let ((s (make-string (file-length in))))
        (subseq s 0 (read-sequence s in))))))

(defun sh (program args &key environment (search t))
  "Run PROGRAM with ARGS, capturing stdout+stderr. Returns (values stdout stderr
exit-code). ENVIRONMENT, when given, fully replaces the child env."
  (let ((out (make-string-output-stream))
        (err (make-string-output-stream)))
    (let ((proc (apply #'sb-ext:run-program program args
                       :search search :output out :error err :wait t
                       (when environment (list :environment environment)))))
      (values (get-output-stream-string out)
              (get-output-stream-string err)
              (sb-ext:process-exit-code proc)))))

(defun env (name &optional default)
  "The env var NAME, or DEFAULT when unset or blank. The one blessed reader the
standalone QA files (github.lisp, conductor.lisp) share, so they don't each
carry a private copy."
  (let ((v (sb-ext:posix-getenv name)))
    (if (and v (plusp (length v))) v default)))

(defun env-with (&rest pairs)
  "The current process env plus PAIRS (\"NAME\" \"value\" …) — for child procs."
  (append (loop for (n v) on pairs by #'cddr collect (format nil "~A=~A" n v))
          (sb-ext:posix-environ)))

(defun tmux (&rest args)
  "Run tmux with ARGS. Returns (values stdout stderr exit-code)."
  (sh "tmux" args))

(defun tmux-ok (&rest args)
  (multiple-value-bind (out err code) (apply #'tmux args)
    (declare (ignore out err))
    (eql code 0)))


(defvar *exit-nonzero* nil)

(defun emit (plist &key (ok t))
  "Print a result plist as one readable sexp line; remember a non-ok result."
  (let ((*package* (qa-package)))
    (let ((*print-pretty* nil) (*print-readably* nil))
      (prin1 (list* :ok (and ok t) plist))
      (terpri)
      (finish-output)))
  (unless ok (setf *exit-nonzero* t))
  plist)


(defun sandbox-dir (name) (merge-pathnames (format nil "~A/" name) *qa-root*))
(defun session-file (name) (merge-pathnames "qa-session.sexp" (sandbox-dir name)))

(defun newest-sandbox ()
  "The most recently created sandbox dir under *qa-root*, or NIL."
  (let ((dirs (ignore-errors (directory (merge-pathnames "*/" *qa-root*)))))
    (when dirs
      (first (sort (copy-list dirs) #'> :key #'file-write-date)))))

(defun resolve-session (name)
  "The session plist for NAME, or the newest sandbox when NAME is NIL. Signals a
readable error if none is found."
  (let* ((dir (if name (sandbox-dir name) (newest-sandbox)))
         (record (and dir (read-first-sexp (merge-pathnames "qa-session.sexp" dir)))))
    (unless record
      (error "no QA session found~@[ named ~A~] (spawn one first)" name))
    record))

(defun session-name (session) (pget session :session))
(defun session-home (session) (pathname (ensure-slash (pget session :home))))

(defun session-event-file (session)
  "The active session's events.sexp (newest sessions/ dir under the sandbox)."
  (let* ((home (session-home session))
         (sid (qa-status-field session :session-id))
         (direct (and sid (merge-pathnames
                           (format nil "sessions/~A/events.sexp" sid) home))))
    (or (and direct (probe-file direct) direct)
        (let ((dirs (ignore-errors
                     (directory (merge-pathnames "sessions/*/" home)))))
          (when dirs
            (merge-pathnames "events.sexp"
                             (first (sort (copy-list dirs) #'>
                                          :key #'file-write-date))))))))


(defun qa-status-path (session)
  (merge-pathnames "state/qa-status.sexp" (session-home session)))

(defun qa-status (session)
  "The parsed qa-status heartbeat plist plus derived freshness:
:fresh-p (mtime within 3s) and :stale-seconds. NIL payload when never written."
  (let* ((path (qa-status-path session))
         (payload (read-first-sexp path)))
    (when payload
      (let ((age (- (now) (file-write-date path))))
        (list* :fresh-p (<= age 3) :stale-seconds age payload)))))

(defun qa-status-field (session key &optional default)
  (let ((s (qa-status session))) (if s (pget s key default) default)))


(defun forward-env (name)
  "(\"-e\" \"NAME=value\") when NAME is set in this process's env, else NIL — so a
credential is passed into the pane explicitly (tmux's server env may be stale)
without ever landing in the qa-session record."
  (let ((v (sb-ext:posix-getenv name)))
    (and v (plusp (length v)) (list "-e" (format nil "~A=~A" name v)))))

(defun nonempty-env (name)
  (let ((v (sb-ext:posix-getenv name)))
    (and v (plusp (length v)) v)))

(defun env-present-p (name)
  (and (nonempty-env name) t))

(defparameter *valid-providers* '(:bedrock :aws :aws-bedrock :vertex :gemini :google)
  "The provider forces PROVIDER-FROM-ENV understands — anything else would be
written into OURRO_PROVIDER and silently ignored at boot, so spawn rejects it.")

(defparameter *qa-settings*
  '(:experimental-reflexes t)
  "Settings QA writes into the sandbox's config.sexp on top of the defaults
`ourro init` seeds. QA turns experimental reflex behaviours on so a mission can
observe whether they deliver value autonomously.")

(defun write-qa-config (home)
  "Merge *QA-SETTINGS* into HOME/config.sexp's :settings, which `ourro init` has
already seeded with the default template. A best-effort no-op if the file can't
be read/written — the pane still boots on the defaults."
  (ignore-errors
    (let* ((path (merge-pathnames "config.sexp" home))
           (config (read-first-sexp path)))
      (when (consp config)
        (let* ((settings (copy-list (pget config :settings)))
               (config (copy-list config)))
          (loop for (k v) on *qa-settings* by #'cddr
                do (setf (getf settings k) v))
          (setf (getf config :settings) settings)
          (with-open-file (out path :direction :output :if-exists :supersede
                                    :if-does-not-exist :create)
            (let ((*package* (qa-package)) (*print-pretty* nil))
              (prin1 config out) (terpri out))))))))

(defun bedrock-model-p (model)
  "Will MODEL route to the Bedrock provider? Mirrors RESOLVE-MODEL's shape
routing (this file is standalone — no ourro.llm at CLI time): any Claude-family
name or id, by substring."
  (let ((low (string-downcase (or model ""))))
    (some (lambda (needle) (search needle low))
          '("anthropic" "claude" "opus" "sonnet" "haiku"))))

(defun op-spawn (&key model command size provider fixture workspace
                      mission mission-result)
  "Create a fresh sandbox, init it, and launch `bin/ourro run` (or dev) in a
detached tmux pane with OURRO_QA=1 — always LIVE on the real provider (QA
exists to watch the real model do real work; there is no scripted tier and no
cost gate). MODEL sets OURRO_MODEL (a friendly alias like opus-4-6 /
sonnet-4-6, or a raw id) — the alias selects the provider on its own, so a
Bedrock model just works. When --model is omitted, QA pins sonnet-4-6 (a fast,
cheap daily-driver that avoids the opus rate-limit wall); it deliberately does
NOT forward your ambient OURRO_MODEL, so an opus in your shell never silently
leaks into a QA pane. PROVIDER is an optional force (:bedrock / :vertex →
OURRO_PROVIDER); a forced Vertex spawn defaults to gemini-3.5-flash instead.
Bedrock credentials (OURRO_BEDROCK_API_KEY / AWS_BEARER_TOKEN_BEDROCK) are
forwarded — no-ops when unset; the region is always eu-north-1 (config, not
env). Model tuning (thinking level, max tokens, stream deadline, and the
experimental reflex opt-in) is written into the sandbox's config.sexp. Background
evolution is always enabled; QA enables reflexes so their autonomous value can be
observed. FIXTURE
copies a fixture directory (e.g. qa/fixtures/legacy-inventory) into the
isolated workspace before boot, so a mission starts inside its project.
COMMAND is :run (default) or :dev; SIZE is (W H). Writes qa-session.sexp and
emits it.

Cloud-QA-loop extensions (qa/qa/docs/plan-cloud-qa.md): WORKSPACE pins the pane's
OURRO_WORKSPACE to an existing directory instead of the isolated sandbox
`work/` — how the conductor spawns an operator/engineer ourro whose workspace
is a repo checkout (mutually exclusive with FIXTURE, which seeds the sandbox
workspace). MISSION forwards OURRO_MISSION=<file> so the product auto-submits
the file's contents as the first user message on cold boot; MISSION-RESULT
sets OURRO_MISSION_RESULT (defaulting to <sandbox>/mission-result.sexp when a
mission is given) — the mission text tells the agent to write its result plist
there, and the conductor's done-signal is that file appearing.

The one spawn-time guard besides basic tooling is fail-fast on a
Bedrock-routed model with no Bedrock key in the env — that is a boot-crash
guard, not a cost gate: without it the agent crash-loops at boot with a blank
pane and the sandbox supervisor quarantines a healthy generation."
  (let* ((ts (format nil "~D-~D" (now) (sb-posix:getpid)))
         (name (format nil "ourro-qa-~A" ts))
         (dir (sandbox-dir name))
         (home (merge-pathnames "home/" dir))
         ;; The agent-under-test's WORKSPACE — isolated from the real repo so a
         ;; relative-path file op can never touch the checkout (F-wsroot) —
         ;; unless the caller pins an explicit --workspace (operator/engineer
         ;; ourros in the cloud QA loop work in a real checkout on purpose).
         (work (if workspace
                   (ensure-slash (namestring workspace))
                   (merge-pathnames "work/" dir)))
         (command (or command :run))
         (size (or size '(100 31)))
         (repo (repo-root))
         (ourro (namestring (merge-pathnames "bin/ourro" repo)))
         ;; What will actually route at boot: the explicit model, else the
         ;; pinned QA default (sonnet-4-6, or gemini-3.5-flash under a forced
         ;; Vertex). No ambient-OURRO_MODEL forwarding — a stray opus in the
         ;; operator's shell must never leak into the pane.
         (effective-model (or model
                              (if (member provider '(:vertex :gemini :google))
                                  "gemini-3.5-flash"
                                  "sonnet-4-6"))))
    ;; Guards, checked before the expensive init.
    (when (and provider (not (member provider *valid-providers*)))
      (return-from op-spawn
        (emit (list :error (format nil "unknown --provider ~(~A~) (use bedrock or vertex)"
                                   provider))
              :ok nil)))
    (when (and (not (member provider '(:vertex :gemini :google)))
               (or (member provider '(:bedrock :aws :aws-bedrock))
                   (bedrock-model-p effective-model))
               (not (env-present-p "OURRO_BEDROCK_API_KEY"))
               (not (env-present-p "AWS_BEARER_TOKEN_BEDROCK")))
      (return-from op-spawn
        (emit (list :error (format nil "model ~A routes to Bedrock but no OURRO_BEDROCK_API_KEY / AWS_BEARER_TOKEN_BEDROCK is set — export one first (the pane would crash-loop at boot)"
                                   effective-model))
              :ok nil)))
    (when (and workspace fixture)
      (return-from op-spawn
        (emit '(:error "--workspace and --fixture are mutually exclusive — a fixture seeds the isolated sandbox workspace; --workspace replaces it")
              :ok nil)))
    (when workspace
      (unless (ignore-errors (truename (ensure-slash (namestring workspace))))
        (return-from op-spawn
          (emit (list :error (format nil "workspace dir not found: ~A" workspace))
                :ok nil)))
      (when (eq command :dev)
        (return-from op-spawn
          (emit '(:error "--workspace only applies to --command run (:dev works in the repo by design)")
                :ok nil))))
    (when mission
      (unless (probe-file mission)
        (return-from op-spawn
          (emit (list :error (format nil "mission file not found: ~A" mission))
                :ok nil))))
    (when (and mission-result (not mission))
      (return-from op-spawn
        (emit '(:error "--mission-result requires --mission") :ok nil)))
    ;; The conductor's done-signal: default the result path into the sandbox
    ;; so `op-spawn --mission X` alone yields a pollable completion channel.
    (when (and mission (not mission-result))
      (setf mission-result (namestring (merge-pathnames "mission-result.sexp" dir))))
    ;; Tooling check last among the guards: the pure argument guards above
    ;; stay unit-testable on a box without tmux.
    (let ((tmux-version (nth-value 0 (tmux "-V"))))
      (unless (and tmux-version (search "tmux" tmux-version))
        (return-from op-spawn (emit '(:error "tmux not found — install tmux ≥3.0") :ok nil))))
    (ensure-directories-exist home)
    (ensure-directories-exist work)
    ;; Seed the workspace from a fixture dir (contents, dotfiles included).
    (when fixture
      (let ((src (ignore-errors (truename (ensure-slash (namestring fixture))))))
        (unless src
          (return-from op-spawn
            (emit (list :error (format nil "fixture dir not found: ~A" fixture))
                  :ok nil)))
        (multiple-value-bind (out err code)
            (sh "cp" (list "-R" (concatenate 'string (namestring src) ".")
                           (namestring work)))
          (declare (ignore out))
          (unless (eql code 0)
            (return-from op-spawn
              (emit (list :error "fixture copy failed" :stderr (last-lines err 5))
                    :ok nil))))))
    (unless (probe-file ourro)
      (return-from op-spawn
        (emit (list :error (format nil "bin/ourro not built at ~A — run `make supervisor`" ourro))
              :ok nil)))
    ;; init the sandbox home once (genome repo, ledger, gen-0001 image)
    (multiple-value-bind (out err code)
        (sh ourro (list "init" "--source-dir" (namestring repo))
            :environment (env-with "OURRO_HOME" (namestring home)))
      (declare (ignore out))
      (unless (eql code 0)
        (return-from op-spawn
          (emit (list :error "bin/ourro init failed" :stderr (last-lines err 10))
                :ok nil))))
    ;; Turn on experimental reflexes in the sandbox's config.sexp. Background
    ;; evolution is always enabled.
    (write-qa-config home)
    ;; env for the pane: OURRO_QA=1 always; live provider/model selection
    (let* ((run-cmd (ecase command
                      (:run (format nil "~A run" ourro))
                      (:dev (format nil "cd ~A && make dev" (namestring repo)))))
           (env-flags (append
                       (list "-e" (format nil "OURRO_HOME=~A" (namestring home))
                             "-e" "OURRO_QA=1")
                       ;; Pin the workspace to the isolated sandbox dir so the
                       ;; agent-under-test can't write into the real repo via a
                       ;; relative path (F-wsroot). Only for the supervised :run
                       ;; mode — :dev's `cd <repo> && make dev` intentionally
                       ;; works on the repo. The product honours OURRO_WORKSPACE
                       ;; at boot and it inherits through every restart spawn.
                       (when (eq command :run)
                         (list "-e" (format nil "OURRO_WORKSPACE=~A"
                                            (namestring work))))
                       ;; Mission mode: the product auto-submits the file's
                       ;; contents as the first user message on cold boot and
                       ;; the mission protocol says to write results to
                       ;; OURRO_MISSION_RESULT (qa/qa/docs/plan-cloud-qa.md).
                       (when mission
                         (list "-e" (format nil "OURRO_MISSION=~A"
                                            (namestring (truename mission)))
                               "-e" (format nil "OURRO_MISSION_RESULT=~A"
                                            mission-result)))
                       ;; Model selection: an explicit --model wins; else pin
                       ;; the QA default (sonnet-4-6, or gemini-3.5-flash under
                       ;; a forced Vertex). The ambient OURRO_MODEL is NEVER
                       ;; forwarded — that leak is what silently ran opus and
                       ;; hit the rate-limit wall. Model *tuning* is config now
                       ;; (written into the sandbox config.sexp above), not env.
                       (list "-e" (format nil "OURRO_MODEL=~A" effective-model))
                       (when provider
                         (list "-e" (format nil "OURRO_PROVIDER=~A"
                                            (string-downcase (symbol-name provider)))))
                       ;; Forward Bedrock credentials only (secrets). Region is
                       ;; config (always eu-north-1), never an env passthrough.
                       (forward-env "OURRO_BEDROCK_API_KEY")
                       (forward-env "AWS_BEARER_TOKEN_BEDROCK"))))
      (unless (apply #'tmux-ok
                     (append (list "new-session" "-d" "-s" name
                                   "-x" (princ-to-string (first size))
                                   "-y" (princ-to-string (second size)))
                             ;; Start the pane in the isolated workspace so even
                             ;; the boot-time (uiop:getcwd) fallback lands there,
                             ;; not the repo (F-wsroot). :dev cd's to the repo
                             ;; itself, so pinning it there would be pointless.
                             (when (eq command :run)
                               (list "-c" (namestring work)))
                             env-flags
                             (list run-cmd)))
        (return-from op-spawn
          (emit (list :error "tmux new-session failed") :ok nil)))
      ;; Don't steal a grid row; keep a crashed pane capturable (crash = evidence).
      (tmux "set-option" "-t" name "status" "off")
      (tmux "set-option" "-t" name "remain-on-exit" "on")
      (let ((record (list :session name :home (namestring home) :dir (namestring dir)
                          :tier :live :model model :provider provider
                          :fixture (and fixture (namestring fixture))
                          :workspace (and workspace (namestring work))
                          :mission (and mission (namestring mission))
                          :mission-result mission-result
                          :command command :size size :created (iso-now)
                          :repo (namestring repo))))
        (with-open-file (out (session-file name) :direction :output
                                                 :if-exists :supersede
                                                 :if-does-not-exist :create)
          (let ((*package* (qa-package)) (*print-pretty* nil))
            (prin1 record out) (terpri out)))
        (emit record)))))

(defun last-lines (string n)
  (let ((lines (split-lines string)))
    (format nil "~{~A~^~%~}" (last lines n))))

(defun split-lines (string)
  (loop with start = 0 with out = '()
        for nl = (position #\Newline string :start start)
        do (push (subseq string start (or nl (length string))) out)
           (if nl (setf start (1+ nl)) (return (nreverse out)))))


(defun op-say (session text)
  "Type TEXT as a human would and submit with Enter. Short lines go literally;
long or multiline text goes via bracketed paste (the real product path, which
never auto-submits), then Enter. No trailing backslash (line-continuation)."
  (let ((name (session-name session)))
    (if (or (> (length text) 200) (find #\Newline text))
        (progn
          (tmux "set-buffer" "--" text)
          (tmux "paste-buffer" "-p" "-t" name "-d"))
        (tmux "send-keys" "-t" name "-l" "--" text))
    (tmux "send-keys" "-t" name "Enter")
    (emit (list :said (if (> (length text) 60) (subseq text 0 60) text)))))

(defparameter *key-aliases*
  '(("esc" . "Escape") ("escape" . "Escape")
    ("enter" . "Enter") ("up" . "Up") ("down" . "Down") ("left" . "Left")
    ("right" . "Right") ("pageup" . "PageUp") ("pagedown" . "PageDown")
    ("pgup" . "PageUp") ("pgdn" . "PageDown")
    ("home" . "Home") ("end" . "End") ("tab" . "Tab") ("shift-up" . "S-Up")
    ("shift-down" . "S-Down") ("space" . "Space")
    ("bspace" . "BSpace") ("backspace" . "BSpace")
    ("delete" . "DC") ("del" . "DC") ("insert" . "IC")))

(defun normalize-key (k)
  "Map a friendly key name to its tmux send-keys name, or NIL when the name is
not recognized. Callers must refuse a NIL: an unknown name handed to tmux goes
out as LITERAL text and silently corrupts the input line (F-keylit)."
  (let ((down (string-downcase k)))
    (cond ((cdr (assoc down *key-aliases* :test #'string=)))
          ;; any ctrl-<letter> chord, in either spelling: ctrl-x / c-x
          ((and (= (length down) 6) (string= "ctrl-" (subseq down 0 5))
                (char<= #\a (char down 5) #\z))
           (format nil "C-~C" (char down 5)))
          ((and (= (length down) 3) (string= "c-" (subseq down 0 2))
                (char<= #\a (char down 2) #\z))
           (format nil "C-~C" (char down 2)))
          ;; function keys f1..f12
          ((and (<= 2 (length down) 3) (char= #\f (char down 0))
                (every #'digit-char-p (subseq down 1))
                (<= 1 (parse-integer (subseq down 1)) 12))
           (string-upcase down))
          ;; a single printable character types itself
          ((= (length k) 1) k)
          (t nil))))

(defun op-key (session keys)
  "Send one or more named keys (f2, ctrl-e, escape, up, …) as real terminfo
bytes. Unknown names are refused with exit 1 — tmux would otherwise deliver
them as literal characters, silently corrupting the run (F-keylit)."
  (let ((name (session-name session))
        (bad (remove-if #'normalize-key keys)))
    (if bad
        (emit (list :error (format nil "unknown key~P: ~{~A~^ ~}"
                                   (length bad) bad)
                    :keys nil)
              :ok nil)
        (let ((sent (mapcar #'normalize-key keys)))
          (apply #'tmux "send-keys" "-t" name sent)
          (emit (list :keys sent))))))

(defun op-paste (session text)
  "Bracketed-paste TEXT without submitting (exercises the product paste path)."
  (let ((name (session-name session)))
    (tmux "set-buffer" "--" text)
    (tmux "paste-buffer" "-p" "-t" name "-d")
    (emit (list :pasted (length text)))))


(defun capture (session &key ansi row)
  "The pane grid as a string: plain, or SGR-styled with ANSI. ROW selects one
0-indexed line."
  (let* ((name (session-name session))
         (args (append (list "capture-pane" "-p" "-t" name)
                       (when ansi '("-e")))))
    (multiple-value-bind (out err code) (apply #'tmux args)
      (declare (ignore err code))
      (if row
          (let ((lines (split-lines out)))
            (if (< row (length lines)) (nth row lines) ""))
          out))))

(defun op-screen (session &key ansi row)
  (let ((text (capture session :ansi ansi :row row)))
    (let ((*package* (qa-package)) (*print-pretty* nil))
      (prin1 (list :ok t :screen text)) (terpri) (finish-output))
    text))

(defun op-state (session)
  (let ((status (qa-status session)))
    (emit (or status (list :status nil)) :ok (and status t))))

(defun op-events (session &key since-offset kind)
  "Emit events from the session log past SINCE-OFFSET, optionally filtered by
KIND, plus the new :offset for the next call."
  (let* ((file (session-event-file session))
         (all (and file (read-sexp-file file)))
         (start (or since-offset 0))
         (tail (if (< start (length all)) (nthcdr start all) '()))
         (filtered (if kind
                       (remove kind tail :test-not #'eq
                                          :key (lambda (e) (pget e :kind)))
                       tail)))
    (emit (list :events filtered :offset (length all) :count (length filtered)))))


(defun status-idle-p (session)
  (let ((s (qa-status session)))
    (and s (pget s :fresh-p) (not (pget s :busy)) (eql 0 (pget s :queue)))))

(defun status-quiescent-p (session)
  (let ((s (qa-status session)))
    (and (status-idle-p session) (null (pget s :activity)))))

(defun stable-frame-p (session &key (settle 0.4) (attempts 5))
  "Two captures SETTLE seconds apart identical (> the 250ms idle paint tick)."
  (loop repeat attempts
        for a = (capture session)
        do (sleep settle)
        when (string= a (capture session)) do (return t)
        finally (return nil)))

(defun pane-dead-p (session)
  "True when the session's tmux pane has exited (remain-on-exit keeps the dead
pane around as evidence) or the session is gone entirely. Every await polls
this: a run whose agent died fatally must fail fast, not hang to timeout."
  (multiple-value-bind (out err code)
      (tmux "list-panes" "-t" (session-name session) "-F" "#{pane_dead}")
    (declare (ignore err))
    (or (not (eql code 0))
        (and (search "1" out) t))))

(defun poll-until (predicate &key (timeout 120) (interval 0.25) abort-p)
  "Call PREDICATE every INTERVAL until it returns non-NIL or TIMEOUT elapses.
Returns the predicate's value, NIL on timeout, or :aborted the moment ABORT-P
(when given) returns true. ABORT-P is checked FIRST: a dead pane must never be
outvoted by a heartbeat file that is still mtime-fresh from just before the
death."
  (let ((deadline (+ (now) timeout)))
    (loop
      (when (and abort-p (ignore-errors (funcall abort-p)))
        (return :aborted))
      (let ((value (ignore-errors (funcall predicate))))
        (when value (return value)))
      (when (> (now) deadline) (return nil))
      (sleep interval))))

(defun await-failure-reason (session)
  (if (pane-dead-p session) :pane-dead :timeout))

(defun op-await-idle (session &key (timeout 120))
  "Wait for a fresh, not-busy, empty-queue status, then a stable frame."
  (let ((polled (poll-until (lambda () (status-idle-p session))
                            :timeout timeout
                            :abort-p (lambda () (pane-dead-p session)))))
    (if (and polled (not (eq polled :aborted)) (stable-frame-p session))
        (emit (list :idle t :status (qa-status session)))
        (emit (list :idle nil :reason (await-failure-reason session)
                    :status (qa-status session))
              :ok nil))))

(defun op-await-quiescent (session &key (timeout 120))
  "Like await-idle but also requires :activity nil (evolver/dream finished)."
  (let ((polled (poll-until (lambda () (status-quiescent-p session))
                            :timeout timeout
                            :abort-p (lambda () (pane-dead-p session)))))
    (if (and polled (not (eq polled :aborted)) (stable-frame-p session))
        (emit (list :quiescent t :status (qa-status session)))
        (emit (list :quiescent nil :reason (await-failure-reason session)
                    :status (qa-status session))
              :ok nil))))

(defun op-await-generation-change (session &key from (timeout 30))
  "Wait until qa-status reports a *new process* (a different :pid) — the
seamless-restart / crash-resume signal. We key on :pid, not :tick (a per-image
counter reset to 0 in every fresh generation, so a tick comparison against a
long-running image's high value would never advance across the very restart it
is meant to detect) and NOT unconditionally on :generation: a crash-resume
keeps the same generation, so requiring :generation to change made this blind
to crash-resume (F-genchg). Pass --from <generation> to ALSO require leaving a
specific generation (a deliberate evolution restart); omit it to accept any new
process. Status staleness during the ~2s respawn window is expected; poll
through it."
  (let* ((base-pid (qa-status-field session :pid))
         (result (poll-until
                  (lambda ()
                    (let ((s (qa-status session)))
                      (and s (pget s :pid)
                           (not (eql (pget s :pid) base-pid))
                           (or (null from) (not (equal (pget s :generation) from)))
                           s)))
                  :timeout timeout :interval 0.5
                  :abort-p (lambda () (pane-dead-p session)))))
    (if (and result (not (eq result :aborted)))
        (emit (list :generation-changed t :from from :to (pget result :generation)))
        (emit (list :generation-changed nil :reason (await-failure-reason session)
                    :from from)
              :ok nil))))

(defun op-await-event (session kind &key match (timeout 120) (since-offset 0))
  "Tail the event log from SINCE-OFFSET until an event of KIND (matching every
key/value in MATCH) appears. Emits the event + its offset, or times out."
  (let* ((file (session-event-file session))
         (result
           (poll-until
            (lambda ()
              (let ((events (and file (read-sexp-file file))))
                (loop for e in (nthcdr since-offset events)
                      for i from since-offset
                      when (and (eq (pget e :kind) kind) (plist-subset-p match e))
                        do (return (list :event e :offset i)))))
            :timeout timeout :interval 0.3
            :abort-p (lambda () (pane-dead-p session)))))
    (if (and result (not (eq result :aborted)))
        (emit (list :matched t :event (pget result :event) :offset (pget result :offset)))
        (emit (list :matched nil :reason (await-failure-reason session) :kind kind)
              :ok nil))))

(defun plist-subset-p (needle haystack)
  "Every key/value in NEEDLE present and EQUAL in HAYSTACK."
  (loop for (k v) on needle by #'cddr
        always (equal v (pget haystack k))))


(defun op-chaos (session action &key seconds)
  (ecase action
    (:kill-agent
     (let ((pid (qa-status-field session :pid)))
       (if (and pid (integerp pid))
           (progn (ignore-errors (sb-posix:kill pid sb-posix:sigkill))
                  (emit (list :killed :agent :pid pid)))
           (emit (list :killed nil :reason :no-pid) :ok nil))))
    (:kill-supervisor
     (let ((pid (read-first-sexp (merge-pathnames "state/supervisor.pid"
                                                  (session-home session)))))
       ;; supervisor.pid may be a bare integer line, not a sexp plist
       (let ((n (or (and (integerp pid) pid)
                    (ignore-errors
                     (parse-integer (string-trim '(#\Space #\Newline)
                                                 (slurp (merge-pathnames
                                                         "state/supervisor.pid"
                                                         (session-home session)))))))))
         (if n (progn (ignore-errors (sb-posix:kill n sb-posix:sigkill))
                      (emit (list :killed :supervisor :pid n)))
             (emit (list :killed nil :reason :no-pid) :ok nil)))))
    (:sleep-idle
     (sleep (or seconds 15))
     (emit (list :slept (or seconds 15))))))


(defun op-collect (session &key label)
  "Snapshot the sandbox's observable state into qa/reports/<run>/evidence/<label>/."
  (let* ((repo (repo-root))
         (home (session-home session))
         (run (format nil "~A" (session-name session)))
         (dest (merge-pathnames
                (format nil "qa/reports/~A/evidence/~A/" run (or label "snap"))
                repo)))
    (ensure-directories-exist dest)
    (flet ((dump (name string)
             (with-open-file (out (merge-pathnames name dest) :direction :output
                                  :if-exists :supersede :if-does-not-exist :create)
               (write-string (or string "") out)))
           (copy-from-home (rel out-name)
             (let ((src (merge-pathnames rel home)))
               (when (probe-file src)
                 (let ((s (slurp src)))
                   (when s
                     (with-open-file (out (merge-pathnames out-name dest)
                                          :direction :output :if-exists :supersede
                                          :if-does-not-exist :create)
                       (write-string s out))))))))
      (dump "screen.txt" (capture session))
      (dump "screen.ansi" (capture session :ansi t))
      (dump "qa-status.sexp" (let ((s (qa-status session)))
                               (let ((*package* (qa-package)))
                                 (prin1-to-string s))))
      (copy-from-home "state/agent-output.log" "agent-output.log")
      (copy-from-home "state/supervisor.log" "supervisor.log")
      (copy-from-home "ledger.sexp" "ledger.sexp")
      (copy-from-home "utility.sexp" "utility.sexp")
      (copy-from-home "evolutions.sexp" "evolutions.sexp")
      (let ((ev (session-event-file session)))
        (when ev (copy-from-home (enough-namestring ev home) "events.sexp"))))
    (emit (list :collected (namestring dest)))))


(defun op-kill (session &key keep-home)
  (let ((name (session-name session)))
    (tmux "kill-session" "-t" name)
    (unless keep-home
      (ignore-errors
       (sh "rm" (list "-rf" (namestring (pathname (pget session :dir)))))))
    (emit (list :killed-session name :kept-home (and keep-home t)))))


(defun arg-value (args flag &optional default)
  (let ((tail (member flag args :test #'string=)))
    (if tail (second tail) default)))

(defun has-flag (args flag) (and (member flag args :test #'string=) t))

(defparameter *boolean-flags*
  '("--allow-live" "--allow-expensive" "--ansi" "--keep-home")
  "Flags that take NO value. Every other --flag consumes the following token as
its value; POSITIONALS uses this to skip flag/value pairs wherever they sit.
--allow-live/--allow-expensive are tolerated legacy no-ops (the cost gates were
removed) — kept here so a stale invocation can't swallow a real token.")

(defun flag-token-p (s)
  (and (> (length s) 1) (string= "--" (subseq s 0 2))))

(defun positionals (args)
  "The non-flag tokens of ARGS, in order, regardless of where flags sit. A
--flag not in *BOOLEAN-FLAGS* also swallows the token after it (its value), so
`say --session X \"msg\"` yields (\"msg\") — the message is no longer dropped
when a flag precedes it (F-arg7f2). Quote a message that itself contains a
`--token` as a single argv word so it isn't mistaken for a flag."
  (loop with out = '() with rest = args
        while rest
        for a = (pop rest)
        do (cond ((not (flag-token-p a)) (push a out))
                 ((member a *boolean-flags* :test #'string=)) ; valueless flag
                 (t (pop rest)))                              ; flag + its value
        finally (return (nreverse out))))

(defun parse-plist-arg (string)
  "Parse a --match sexp plist string safely (same package convention as
READ-SEXP-FILE so a NIL in a match compares equal to a NIL in the log)."
  (when (and string (plusp (length string)))
    (let ((*read-eval* nil) (*package* (qa-package)))
      (ignore-errors (read-from-string string)))))

(defun keywordize (s)
  "Intern S as a keyword, tolerating a leading colon (:llm-call and llm-call
both → :LLM-CALL)."
  (let ((name (if (and (plusp (length s)) (char= (char s 0) #\:)) (subseq s 1) s)))
    (intern (string-upcase name) :keyword)))

(defun cli-main (argv)
  "Dispatch a subcommand (ARGV is the raw args after the program name).
Prints one result sexp; exits 0 on ok / 1 otherwise."
  (when (null argv)
    (emit '(:error "usage: ourro-qa <subcommand> [args]") :ok nil)
    (sb-ext:exit :code 1))
  (let* ((sub (first argv))
         (args (rest argv))
         (session-name (arg-value args "--session"))
         (session (unless (member sub '("spawn" "help" "sessions" "issues") :test #'string=)
                    (handler-case (resolve-session session-name)
                      (error (c)
                        (emit (list :error (princ-to-string c)) :ok nil)
                        (sb-ext:exit :code 1))))))
    (handler-case
        (cond
          ((string= sub "spawn")
           (let ((tier (arg-value args "--tier")))
             (if (or (arg-value args "--script")
                     (and tier (not (string-equal tier "live"))))
                 ;; Reject unsupported tiers rather than booting a different mode.
                 (emit '(:error "the scripted/dry tiers were removed — QA is live-only (see qa/README.md); spawn takes --model --provider --fixture --workspace --mission --mission-result --command --size")
                       :ok nil)
                 (op-spawn :model (arg-value args "--model")
                           :provider (let ((p (arg-value args "--provider"))) (and p (keywordize p)))
                           :fixture (arg-value args "--fixture")
                           :workspace (arg-value args "--workspace")
                           :mission (arg-value args "--mission")
                           :mission-result (arg-value args "--mission-result")
                           :command (let ((c (arg-value args "--command"))) (and c (keywordize c)))
                           :size (let ((s (arg-value args "--size")))
                                   (when s (mapcar #'parse-integer
                                                   (split-on s #\x))))))))
          ((string= sub "help") (op-help))
          ((string= sub "sessions") (op-sessions))
          ((string= sub "say")   (op-say session (join (positionals args))))
          ((string= sub "key")   (op-key session (positionals args)))
          ((string= sub "paste") (op-paste session (join (positionals args))))
          ((string= sub "screen")
           (op-screen session :ansi (has-flag args "--ansi")
                              :row (let ((r (arg-value args "--row"))) (and r (parse-integer r)))))
          ((string= sub "state") (op-state session))
          ((string= sub "events")
           (op-events session
                      :since-offset (let ((o (arg-value args "--since-offset"))) (and o (parse-integer o)))
                      :kind (let ((k (arg-value args "--kind"))) (and k (keywordize k)))))
          ((string= sub "await-idle")
           (op-await-idle session :timeout (int-arg args "--timeout" 120)))
          ((string= sub "await-quiescent")
           (op-await-quiescent session :timeout (int-arg args "--timeout" 120)))
          ((string= sub "await-generation-change")
           (op-await-generation-change session :from (arg-value args "--from")
                                               :timeout (int-arg args "--timeout" 30)))
          ((string= sub "await-event")
           (op-await-event session (keywordize (first (positionals args)))
                           :match (parse-plist-arg (arg-value args "--match"))
                           :since-offset (int-arg args "--since-offset" 0)
                           :timeout (int-arg args "--timeout" 120)))
          ((string= sub "chaos")
           (op-chaos session (keywordize (first (positionals args)))
                     :seconds (int-arg args "--seconds" nil)))
          ((string= sub "collect") (op-collect session :label (arg-value args "--label")))
          ((string= sub "issues") (op-issues :dry-run (has-flag args "--dry-run")))
          ((string= sub "kill") (op-kill session :keep-home (has-flag args "--keep-home")))
          (t (emit (list :error (format nil "unknown subcommand: ~A" sub)) :ok nil)))
      (error (c)
        (emit (list :error (princ-to-string c)) :ok nil)))
    (sb-ext:exit :code (if *exit-nonzero* 1 0))))

(defun op-issues (&key dry-run)
  "File GitHub issues (via gh) for every qa/findings/F-*.sexp that has no
:issue back-reference yet. Loads qa/loop/github.lisp lazily — a plain
ourro-qa invocation doesn't carry the loop code."
  (let* ((root (repo-root))
         (findings (sort (directory (merge-pathnames "qa/findings/F-*.sexp" root))
                         #'string< :key #'namestring))
         (pending (remove-if (lambda (f)
                               (pget (read-first-sexp f) :issue))
                             findings)))
    (cond
      (dry-run
       (emit (list :would-file (mapcar #'file-namestring pending))))
      (t
       ;; github.lisp depends on this file (it :import-from's OURRO.QA.OPERATOR),
       ;; so operator cannot reference the github package at compile time — the
       ;; standalone `ourro-qa issues` path loads it on demand. FIND-SYMBOL (not
       ;; INTERN) so a renamed/unexported entry point fails loudly here rather
       ;; than funcalling a freshly-interned symbol with no function.
       (unless (find-package :ourro.qa.github)
         (load (merge-pathnames "qa/loop/github.lisp" root)))
       (let ((fn (find-symbol "FILE-ISSUES-FOR-FINDINGS"
                              (find-package :ourro.qa.github))))
         (unless (and fn (fboundp fn))
           (error "ourro.qa.github:file-issues-for-findings is unavailable"))
         (emit (funcall fn pending)))))))

(defun op-help ()
  (emit (list :subcommands
              '("spawn" "say" "key" "paste" "screen" "state" "events"
                "await-idle" "await-quiescent" "await-generation-change"
                "await-event" "chaos" "collect" "issues" "kill" "sessions" "help")
              :usage "ourro-qa <subcommand> [--session NAME] [flags]"
              :spawn "spawn [--model ALIAS] [--provider bedrock|vertex] [--fixture DIR | --workspace DIR] [--mission FILE [--mission-result FILE]] [--command run|dev] [--size WxH] — always live; missions live in qa/missions/"
              :issues "issues [--dry-run] — file GitHub issues (gh) for findings without an :issue back-reference")))

(defun op-sessions ()
  "List the known sandboxes (newest first) with their tier/home."
  (let ((dirs (ignore-errors (directory (merge-pathnames "*/" *qa-root*)))))
    (emit (list :sessions
                (loop for d in (sort (copy-list (or dirs '())) #'>
                                     :key #'file-write-date)
                      for rec = (read-first-sexp (merge-pathnames "qa-session.sexp" d))
                      when rec collect (list :session (pget rec :session)
                                             :tier (pget rec :tier)
                                             :home (pget rec :home)))))))

(defun int-arg (args flag default)
  (let ((v (arg-value args flag))) (if v (parse-integer v) default)))

(defun join (strings) (format nil "~{~A~^ ~}" strings))

(defun split-on (string char)
  (loop with start = 0 with out = '()
        for pos = (position char string :start start)
        do (push (subseq string start (or pos (length string))) out)
           (if pos (setf start (1+ pos)) (return (nreverse out)))))
