
(defpackage #:ourro.tests
  (:use #:cl #:fiveam #:ourro.util)
  (:shadow #:run-all-tests)
  (:export #:run-all-tests #:ourro))

(in-package #:ourro.tests)

(def-suite ourro :description "All ourro tests.")

(defun ensure-seed-genome-loaded ()
  "Load the seed genome from the source tree so tool/gene tests have the
built-in tools available (the running test image is not a built agent image)."
  (unless (ourro.genome:list-genes)
    (let ((seed (merge-pathnames
                 "seed-genome/"
                 (asdf:system-source-directory "ourro"))))
      (ourro.genome:load-genome seed))))

(defun run-all-tests ()
  (ensure-seed-genome-loaded)
  ;; Never let a test write into the real ~/.ourro: the utility ledger and
  ;; candidate-record persistence resolve paths under OURRO-HOME (M1-1/M1-3).
  (let ((ourro.util::*ourro-home*
          (or ourro.util::*ourro-home*
              (uiop:ensure-directory-pathname
               (merge-pathnames "ourro-test-home/" (uiop:temporary-directory)))))
        ;; Hermetic settings: never read a stray config.sexp during the suite.
        ;; Tests that need a non-default setting bind it via WITH-SETTINGS.
        (ourro.config::*file-settings* nil))
    (let ((results (run 'ourro)))
      (explain! results)
      (unless (results-status results)
        (uiop:quit 1))
      t)))
