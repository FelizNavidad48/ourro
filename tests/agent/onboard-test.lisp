
(in-package #:ourro.tests)

(def-suite onboard-suite :in ourro)
(in-suite onboard-suite)

(defmacro with-fixture-repo ((dir &rest files) &body body)
  "Create a temp directory containing FILES (each (name . contents)), bind DIR
to it, run BODY, then delete it."
  `(let ((,dir (uiop:ensure-directory-pathname
                (merge-pathnames (format nil "ourro-repo-~A/" (ourro.util:make-id "r"))
                                 (uiop:temporary-directory)))))
     (ensure-directories-exist ,dir)
     (unwind-protect
          (progn
            ,@(mapcar (lambda (file)
                        `(with-open-file (out (merge-pathnames ,(car file) ,dir)
                                              :direction :output :if-exists :supersede
                                              :if-does-not-exist :create)
                           (write-string ,(cdr file) out)))
                      files)
            ,@body)
       (ignore-errors (uiop:delete-directory-tree ,dir :validate t
                                                       :if-does-not-exist :ignore)))))


(test detect-make-targets-parses
  (let ((targets (ourro.agent::detect-make-targets
                  (format nil "test:~%~a echo hi~%build: test~%.PHONY: all~%lint:~%"
                          #\Tab))))
    (is (member "test" targets :test #'string=))
    (is (member "build" targets :test #'string=))
    (is (member "lint" targets :test #'string=))))

(test probe-makefile-repo
  (with-fixture-repo (dir ("Makefile" . "test:
	echo t
build:
	echo b
lint:
	echo l
"))
    (let ((candidates (ourro.agent::probe-repository dir)))
      (is (= 3 (length candidates)))
      (let ((test (find :test candidates :key (lambda (c) (getf c :role)))))
        (is (equal '("make" "test") (getf test :command)))))))

(test probe-node-repo-uses-lockfile-and-whitelists-scripts
  (with-fixture-repo (dir
                      ("package.json" . "{\"scripts\":{\"test\":\"jest\",\"build\":\"tsc\",\"deploy\":\"scp secrets prod\"}}")
                      ("pnpm-lock.yaml" . "lockfileVersion: 5.4"))
    (let ((candidates (ourro.agent::probe-repository dir)))
      ;; pnpm is chosen from the lockfile.
      (let ((test (find :test candidates :key (lambda (c) (getf c :role))))
            (build (find :build candidates :key (lambda (c) (getf c :role)))))
        (is (equal '("pnpm" "test") (getf test :command)))
        (is (equal '("pnpm" "run" "build") (getf build :command))))
      ;; The free-form "deploy" script is NEVER turned into a command.
      (is (notany (lambda (c) (search "deploy" (getf c :label))) candidates)))))

(test package-json-scripts-parse
  (let ((names (ourro.agent::package-json-scripts
                "{\"scripts\":{\"test\":\"x\",\"lint\":\"y\"}}")))
    (is (member "test" names :test #'string=))
    (is (member "lint" names :test #'string=))))

(test no-markers-no-candidates
  (with-fixture-repo (dir ("README.md" . "hello"))
    (is (null (ourro.agent::probe-repository dir)))))


(test run-probes-records-exit
  (let ((probes (ourro.agent::run-probes
                 (list (list :role :test :command '("true") :label "true" :source "x")
                       (list :role :build :command '("false") :label "false" :source "x")))))
    (is (ourro.agent::green-probe-p (find :test probes :key (lambda (p) (getf p :role)))))
    (is (not (ourro.agent::green-probe-p
              (find :build probes :key (lambda (p) (getf p :role))))))))

(test onboard-patterns-only-green
  (let ((probes (list (list :role :test :command '("true") :label "make test"
                            :source "Makefile" :exit 0 :ms 10 :output-head "3 passed")
                      (list :role :lint :command '("false") :label "make lint"
                            :source "Makefile" :exit 1 :ms 5 :output-head "boom"))))
    (let ((patterns (ourro.agent::onboard-patterns probes)))
      (is (= 1 (length patterns)))
      (is (eq :onboarding (getf (first patterns) :kind)))
      (is (string= "repo/test" (getf (first patterns) :gene-name)))
      (is (equal '("repo_test") (getf (first patterns) :tools))))))


(defparameter +onboard-gene+
  "<gene>
(defgene repo/test
    (:generation 2 :parent nil :capabilities (:subprocess)
     :provenance (:pattern \"onboard\" :model \"scripted\"))
  (:doc \"Run the project test suite and summarize pass/fail counts.\")
  (:code
   (deftool repo-test ()
     (:doc \"Run the repository test suite.\")
     (:contract (:post ((stringp result))))
     (multiple-value-bind (out code) (cap/run-program (list \"true\"))
       (format nil \"exit ~A~%~A\" code out))))
  (:tests
   (test repo-test/parses-count
     (is (= 3 (length (split-lines (format nil \"a~%b~%c\"))))))))
</gene>")

(test onboard-grow-while-frozen-explains-instead-of-growing
  ;; /onboard while evolution is frozen: apply-candidate would reject every
  ;; proposal, so onboard-grow must skip the (LLM-spending) grow loop and say
  ;; WHY, rather than print one cryptic "could not grow <gene>" line per pattern.
  (ensure-seed-genome-loaded)
  (let* ((ourro.kernel:*evolution-frozen* t)
         (agent (ourro.agent::make-agent
                 :provider (ourro.llm:make-scripted-provider '())))
         (probes (list (list :role :test :command '("true") :label "make test"
                             :source "Makefile" :exit 0 :ms 10
                             :output-head "3 passed"))))
    (ourro.agent::onboard-grow agent probes)
    (let ((text (agent-transcript-text agent)))
      (is (search "frozen" text))
      (is (search "unfreeze" text))
      (is (null (search "could not grow" text))))))

(test onboarding-pattern-grows-a-gene
  (ensure-seed-genome-loaded)
  (let* ((provider (ourro.llm:make-scripted-provider (list +onboard-gene+)))
         (pattern (first (ourro.agent::onboard-patterns
                          (list (list :role :test :command '("make" "test")
                                      :label "make test" :source "Makefile"
                                      :exit 0 :ms 8500
                                      :output-head "test session starts
3 passed")))))
         (ourro.evolve:*last-evolution-time* 0)
         (ourro.evolve::*snapshot-hook* nil)
         ;; This unit fixture exercises the effectful onboarding pipeline. Real
         ;; macOS/unsupported hosts remain read-only and fail closed; the
         ;; reviewed Linux backend will replace this test-only seam.
         (ourro.verify.coordinator:*containment-mode-override* :effectful)
         (candidate (ourro.kernel:with-capabilities '(:llm)
                      (ourro.evolve:propose-gene provider pattern))))
    (is (eq :verified (ourro.evolve:candidate-status candidate)))
    (ourro.evolve:apply-candidate candidate :force t :snapshot :none)
    (is-true (ourro.tools:find-tool "repo_test"))
    (ourro.tools:unregister-tool "repo_test")))
