
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

