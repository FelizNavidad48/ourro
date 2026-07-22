
(in-package #:ourro.agent)

(defparameter *onboard-probe-timeout* 90
  "Seconds a single onboarding probe command may run.")

(defparameter *onboard-output-head-lines* 30
  "Lines of a probe's output kept as grounding for the gene's tests.")


(defun onboard-file (name &optional (root ourro.toolkit:*workspace*))
  (probe-file (merge-pathnames name (uiop:ensure-directory-pathname root))))

(defun detect-make-targets (text)
  "Downcased target names declared in a Makefile."
  (let ((targets '()))
    (cl-ppcre:do-register-groups (name)
        ("(?m)^([a-zA-Z][a-zA-Z0-9_-]*):" text)
      (pushnew (string-downcase name) targets :test #'string=))
    (nreverse targets)))

(defun package-json-scripts (text)
  "The script names declared in a package.json's \"scripts\" object."
  (let ((scripts (ourro.llm:json-value (ourro.llm:json-decode text) "scripts"))
        (names '()))
    (when (hash-table-p scripts)
      (maphash (lambda (k v) (declare (ignore v))
                 (push (string-downcase (princ-to-string k)) names))
               scripts))
    names))

(defun detect-node-package-manager (root)
  (cond ((onboard-file "pnpm-lock.yaml" root) "pnpm")
        ((onboard-file "yarn.lock" root) "yarn")
        (t "npm")))

(defun make-candidate (role command source)
  (list :role role :command command
        :label (string-join " " command) :source source))

(defun probe-repository (&optional (root ourro.toolkit:*workspace*))
  "Return whitelisted candidate commands per role (:build :test :lint :smoke) inferred
from the project's marker files. At most one candidate per role (first source
detected wins). Pure reads — nothing is executed here."
  (let ((candidates '()))
    (flet ((add (role command source)
             (unless (find role candidates :key (lambda (c) (pget c :role)))
               (push (make-candidate role command source) candidates))))
      ;; Makefile — the most explicit signal. Each role accepts a few
      ;; conventional target-name aliases (still a fixed `make <target>` shape,
      ;; never a free-form command), so a repo whose Makefile says `all` or
      ;; `check` instead of `build`/`lint` still grows more than repo/test.
      (let ((mk (onboard-file "Makefile" root)))
        (when mk
          (let ((targets (detect-make-targets (uiop:read-file-string mk))))
            (flet ((first-target (names)
                     (find-if (lambda (n) (member n targets :test #'string=))
                              names)))
              (when (member "test" targets :test #'string=)
                (add :test '("make" "test") "Makefile"))
              (let ((build (first-target '("build" "all" "compile"))))
                (when build (add :build (list "make" build) "Makefile")))
              (let ((lint (first-target '("lint" "check" "fmt" "format"))))
                (when lint (add :lint (list "make" lint) "Makefile")))
              (when (member "smoke" targets :test #'string=)
                (add :smoke '("make" "smoke") "Makefile"))))))
      ;; Node — pnpm/yarn/npm scripts (whitelisted names only).
      (when (onboard-file "package.json" root)
        (let ((pm (detect-node-package-manager root))
              (scripts (ignore-errors
                        (package-json-scripts
                         (uiop:read-file-string (onboard-file "package.json" root))))))
          (when (member "test" scripts :test #'string=)
            (add :test (list pm "test") "package.json"))
          (when (member "build" scripts :test #'string=)
            (add :build (list pm "run" "build") "package.json"))
          (when (member "lint" scripts :test #'string=)
            (add :lint (list pm "run" "lint") "package.json"))))
      ;; Rust
      (when (onboard-file "Cargo.toml" root)
        (add :build '("cargo" "build") "Cargo.toml")
        (add :test '("cargo" "test") "Cargo.toml")
        (add :lint '("cargo" "clippy") "Cargo.toml"))
      ;; Python
      (when (or (onboard-file "pyproject.toml" root) (onboard-file "setup.py" root))
        (add :test '("pytest") "python")
        (add :lint '("ruff" "check") "python"))
      ;; Go
      (when (onboard-file "go.mod" root)
        (add :build '("go" "build" "./...") "go.mod")
        (add :test '("go" "test" "./...") "go.mod"))
      ;; Ruby
      (when (onboard-file "Gemfile" root)
        (add :test '("bundle" "exec" "rspec") "Gemfile"))
      ;; Elixir
      (when (onboard-file "mix.exs" root)
        (add :test '("mix" "test") "mix.exs")))
    ;; :build, :test, :lint, :smoke order for a stable summary table.
    (stable-sort (nreverse candidates) #'<
                 :key (lambda (c)
                        (or (position (pget c :role) '(:build :test :lint :smoke))
                            4)))))


(defun output-head (output &optional (lines *onboard-output-head-lines*))
  (let ((split (split-lines (or output ""))))
    (string-join (string #\Newline) (subseq split 0 (min lines (length split))))))

(defun run-probes (candidates &key progress)
  "Run each CANDIDATE command once under a capability + timeout, returning a
probe result plist per candidate. PROGRESS, if given, is called with a short
narration string before each run."
  (loop for candidate in candidates
        for i from 1
        collect
        (let ((command (pget candidate :command)))
          (when progress
            (funcall progress
                     (format nil "onboarding: probing `~A` (~A/~A)…"
                             (pget candidate :label) i (length candidates))))
          (let ((start (get-internal-real-time)))
            (multiple-value-bind (output code)
                (handler-case
                    (ourro.kernel:with-capabilities '(:subprocess :filesystem-read)
                      (ourro.kernel:cap/run-program
                       command :timeout *onboard-probe-timeout*))
                  (error (c) (values (princ-to-string c) -1)))
              (list :role (pget candidate :role)
                    :command command
                    :label (pget candidate :label)
                    :source (pget candidate :source)
                    :exit (or code -1)
                    :ms (round (* 1000 (- (get-internal-real-time) start))
                               internal-time-units-per-second)
                    :output-head (output-head output)))))))

(defun green-probe-p (probe)
  (eql 0 (pget probe :exit)))


(defun role-gene-name (role)
  (format nil "repo/~(~A~)" role))

(defun onboard-patterns (probes)
  "One :onboarding pattern per GREEN probe, carrying the captured command and
output so the evolver can write a gene with hermetic tests over real output."
  (loop for probe in probes
        when (green-probe-p probe)
          collect (list :id (make-id "onboard")
                        :kind :onboarding
                        :category "repo"
                        :role (pget probe :role)
                        :gene-name (role-gene-name (pget probe :role))
                        :command (pget probe :command)
                        :tools (list (substitute #\_ #\/ (role-gene-name (pget probe :role))))
                        :exit (pget probe :exit)
                        :ms (pget probe :ms)
                        :output-head (pget probe :output-head)
                        :count 1
                        :occurrence-cost-ms (pget probe :ms)
                        :evidence (list (list :tool (pget probe :label)
                                              :args nil)))))


(defun grow-onboarding-genes (agent patterns)
  "Propose and apply a gene per onboarding PATTERN, sequentially. Returns the
list of role keywords whose gene now exists in the live registry."
  (dolist (pattern patterns)
    (ourro.kernel:with-capabilities ourro.kernel:+all-capabilities+
      (let ((candidate (ourro.evolve:propose-gene (agent-provider agent) pattern)))
        (when (eq (ourro.evolve:candidate-status candidate) :verified)
          (ourro.evolve:apply-candidate candidate :force t :snapshot :async)))))
  (remove-if-not (lambda (pattern)
                   (ourro.genome:find-gene (pget pattern :gene-name)))
                 patterns))

(defun onboard-toolchain-summary (probes)
  "A short note (for the coder role's context) describing the detected
toolchain and any genes now available."
  (with-output-to-string (out)
    (format out "Repository toolchain (detected during onboarding):~%")
    (dolist (probe probes)
      (format out "  ~(~A~): `~A` (~A, exit ~A)~@[ → tool ~A~]~%"
              (pget probe :role)
              (pget probe :label)
              (pget probe :source)
              (pget probe :exit)
              (and (green-probe-p probe)
                   (ourro.genome:find-gene (role-gene-name (pget probe :role)))
                   (substitute #\_ #\/ (role-gene-name (pget probe :role))))))
    (format out "Prefer these commands and the repo_* tools for building, ~
testing, and linting this project.")))
