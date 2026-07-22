(in-package #:ourro.tests)


(def-suite qa-github-suite :in ourro)
(in-suite qa-github-suite)

(defmacro with-gh-stub ((calls-var &rest clauses) &body body)
  "Bind *gh-runner* to a recorder. CALLS-VAR accumulates each gh argv (newest
last). Each clause is (SUBCOMMAND OUT CODE): when (first args) matches
SUBCOMMAND the stub returns (values OUT \"\" CODE); unmatched calls return
empty success."
  `(let ((,calls-var '())
         (ourro.qa.github:*gh-runner* nil)
         (ourro.qa.github::*gh-available* :unknown))
     (setf ourro.qa.github:*gh-runner*
           (lambda (args)
             (setf ,calls-var (append ,calls-var (list args)))
             (cond
               ,@(loop for (sub out code) in clauses
                       collect `((equal (first args) ,sub)
                                 (values ,out "" ,code)))
               (t (values "" "" 0)))))
     ,@body))

(test github-title-includes-id-and-clips-long-titles
  (is (string= "[QA] F-x: broken thing"
               (ourro.qa.github:finding-issue-title
                '(:id "F-x" :title "broken thing"))))
  (let ((title (ourro.qa.github:finding-issue-title
                (list :id "F-long" :title (make-string 200 :initial-element #\a)))))
    (is (< (length title) 120))
    (is-true (search "…" title))))

(test github-body-renders-present-sections-and-omits-absent
  (let ((body (ourro.qa.github:finding-issue-body
               '(:id "F-b" :severity :p2 :area :tui :title "t"
                 :expected "should work" :actual "does not"
                 :repro (:step "ctrl-e")))))
    (is-true (search "## Expected" body))
    (is-true (search "should work" body))
    (is-true (search "## Actual" body))
    (is-true (search "## Repro" body))
    (is-true (search ":STEP" (string-upcase body)))
    (is (null (search "## Root cause" body)))
    (is (null (search "## Evidence" body)))
    (is-true (search "F-b" body))))

(test github-labels-map-severity-and-area
  (is (equal '("qa-finding" "P1" "area:tui")
             (ourro.qa.github:finding-labels '(:severity :p1 :area :tui))))
  ;; No severity/area → just the marker label.
  (is (equal '("qa-finding") (ourro.qa.github:finding-labels '(:id "F-x")))))

(defmacro with-finding-file ((var plist) &body body)
  `(let ((,var (merge-pathnames
                (format nil "F-ghtest-~A.sexp" (ourro.util:make-id "f"))
                (uiop:temporary-directory))))
     (unwind-protect
          (progn
            (with-open-file (out ,var :direction :output
                                      :if-does-not-exist :create
                                      :if-exists :supersede)
              (let ((*package* (find-package :keyword)))
                (prin1 ,plist out)))
            ,@body)
       (ignore-errors (delete-file ,var)))))

(test github-issue-backref-short-circuits-without-calling-gh
  (with-finding-file (file '(:id "F-done" :title "t" :issue 7))
    (with-gh-stub (calls)
      (let ((result (ourro.qa.github:file-issue-for-finding file)))
        (is (eq :already-filed (getf result :status)))
        (is (= 7 (getf result :issue)))
        ;; The back-reference must satisfy dedupe locally — no gh call at all.
        (is (null calls))))))

(test github-create-path-files-and-records-the-issue-number
  (with-finding-file (file '(:id "F-new" :severity :p2 :area :tui :title "t"))
    (with-gh-stub (calls
                   ("auth" "" 0)
                   ("issue" "https://github.com/o/r/issues/42" 0))
      ;; The stub answers both `issue list` (search: no match parses to no
      ;; number) and `issue create` (the URL) — the URL line has no tab, so
      ;; the search miss falls through to create.
      (let ((result (ourro.qa.github:file-issues-for-findings (list file))))
        (is (= 1 (length (getf result :filed))))
        (let ((one (first (getf result :filed))))
          (is (eq :filed (getf one :status)))
          (is (= 42 (getf one :issue))))
        ;; The finding file gained the :issue back-reference…
        (let ((plist (first (ourro.qa.operator:read-sexp-file file))))
          (is (= 42 (getf plist :issue))))
        ;; …so a second run never reaches gh again.
        (let ((before (length calls)))
          (let ((again (ourro.qa.github:file-issues-for-findings (list file))))
            (is (= 1 (length (getf again :already-filed)))))
          ;; Only the (cached) availability check could add calls; create/list
          ;; must not run again.
          (is (= before (length calls))))))))

(test github-unavailable-gh-skips-everything-without-error
  (with-finding-file (file '(:id "F-skip" :title "t"))
    (with-gh-stub (calls ("auth" "" 1))
      (let ((result (ourro.qa.github:file-issues-for-findings (list file))))
        (is (eq :gh-unavailable (getf result :skipped)))
        ;; Only the auth probe ran; nothing was filed.
        (is (= 1 (length calls)))
        ;; The finding file is untouched.
        (let ((plist (first (ourro.qa.operator:read-sexp-file file))))
          (is (null (getf plist :issue))))))))

(test github-unavailable-verdict-is-not-cached-so-a-later-cycle-recovers
  ;; A loop that starts before its GH_TOKEN lands must pick gh up later, not
  ;; wedge on the first failed probe. First probe fails, second succeeds.
  (let ((ourro.qa.github::*gh-available* :unknown)
        (auth-code 1))
    (let ((ourro.qa.github:*gh-runner*
            (lambda (args)
              (if (equal (first args) "auth")
                  (values "" "" auth-code)
                  (values "" "" 0)))))
      (is (null (ourro.qa.github:gh-available-p)))   ; probe #1: unauthed
      (setf auth-code 0)
      (is-true (ourro.qa.github:gh-available-p))      ; probe #2: now authed
      ;; Positive verdict now sticks (no re-probe once available).
      (setf auth-code 1)
      (is-true (ourro.qa.github:gh-available-p)))))

(test github-search-hit-dedupes-and-adopts-the-number
  (with-finding-file (file '(:id "F-seen" :title "t"))
    (with-gh-stub (calls
                   ("auth" "" 0)
                   ("issue" (format nil "31~A[QA] F-seen: t" #\Tab) 0))
      (let ((result (ourro.qa.github:file-issue-for-finding file)))
        (is (eq :already-filed (getf result :status)))
        (is (= 31 (getf result :issue)))
        ;; Adopted into the sexp for O(1) dedupe next time.
        (let ((plist (first (ourro.qa.operator:read-sexp-file file))))
          (is (= 31 (getf plist :issue))))))))

(test github-search-matches-id-exactly-not-by-substring
  ;; Filing F-x while only the longer F-xyz has an issue must NOT adopt
  ;; F-xyz's number — the id is parsed out of each title and compared exactly.
  ;; `issue list` returns the F-xyz line (a substring-only match that must be
  ;; rejected); `issue create` returns the new URL — distinguished on argv[1].
  (with-finding-file (file '(:id "F-x" :title "t"))
    (let ((ourro.qa.github::*gh-available* :unknown))
      (let ((ourro.qa.github:*gh-runner*
              (lambda (args)
                (cond
                  ((equal (first args) "auth") (values "" "" 0))
                  ((and (equal (first args) "issue")
                        (equal (second args) "list"))
                   (values (format nil "31~A[QA] F-xyz: other" #\Tab) "" 0))
                  ((and (equal (first args) "issue")
                        (equal (second args) "create"))
                   (values "https://github.com/o/r/issues/42" "" 0))
                  (t (values "" "" 0))))))
        (let ((result (ourro.qa.github:file-issue-for-finding file)))
          ;; No exact match → a fresh issue is created, not an adoption.
          (is (eq :filed (getf result :status)))
          (is (= 42 (getf result :issue))))))))
