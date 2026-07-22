
(defpackage #:ourro.qa.github
  (:use #:cl)
  (:import-from #:ourro.qa.operator #:sh #:pget #:read-sexp-file #:env)
  (:export #:*gh-runner* #:gh-available-p
           #:finding-issue-title #:finding-issue-body #:finding-labels
           #:existing-issue-number
           #:file-issue-for-finding #:file-issues-for-findings))

(in-package #:ourro.qa.github)

(defvar *gh-runner* nil
  "Test seam: when bound to a function, (funcall it args) replaces running the
real gh binary and must return (values stdout stderr exit-code).")

(defvar *gh-available* :unknown
  "Cached `gh auth status` verdict for this process. Only a POSITIVE verdict is
cached; :unknown/NIL means re-probe (tests rebind both with *GH-RUNNER*).")

(defun run-gh (args)
  (if *gh-runner*
      (funcall *gh-runner* args)
      (sh "gh" args)))

(defun issues-enabled-p ()
  ;; OURRO_QA_GH_ISSUES=0 turns filing off even where gh would work.
  (not (equal (env "OURRO_QA_GH_ISSUES") "0")))

(defun gh-available-p ()
  "gh exists and is authenticated. A positive verdict is cached for the process
— auth doesn't drop mid-loop and `gh auth status` is a network-free local
check. A negative verdict is NOT cached: the conductor is one long-lived
process, so a loop that starts before its GH_TOKEN is in place must pick gh up
on a later cycle rather than never filing again."
  (or (eq *gh-available* t)
      (setf *gh-available*
            (handler-case
                (multiple-value-bind (out err code) (run-gh '("auth" "status"))
                  (declare (ignore out err))
                  (eql code 0))
              (error () nil)))))

(defun finding-id (plist)
  (let ((id (pget plist :id)))
    (typecase id
      (string id)
      (symbol (symbol-name id))
      (t (and id (princ-to-string id))))))

(defun finding-issue-title (plist)
  "\"[QA] F-…: <title>\", title clipped so the whole thing stays scannable in
an issue list."
  (let* ((title (or (pget plist :title) ""))
         (clipped (if (> (length title) 90)
                      (concatenate 'string (subseq title 0 90) "…")
                      title)))
    (format nil "[QA] ~A: ~A" (finding-id plist) clipped)))

(defun sexp-block (value)
  (with-output-to-string (s)
    (format s "~%```lisp~%")
    (let ((*print-pretty* t) (*print-readably* nil) (*print-right-margin* 76)
          (*package* (find-package :ourro.qa.operator)))
      (prin1 value s))
    (format s "~%```~%")))

(defun finding-issue-body (plist)
  "Markdown body from the finding's populated fields; absent fields are
omitted rather than rendered empty."
  (with-output-to-string (s)
    (format s "**Severity:** ~@[~A~]  |  **Area:** ~@[~A~]  |  **Found:** ~@[~A~]~%"
            (pget plist :severity) (pget plist :area) (pget plist :found))
    (let ((title (pget plist :title)))
      (when title (format s "~%~A~%" title)))
    (flet ((section (label value &key sexp)
             (when value
               (format s "~%## ~A~%" label)
               (if (or sexp (not (stringp value)))
                   (write-string (sexp-block value) s)
                   (format s "~%~A~%" value)))))
      (section "Repro" (pget plist :repro))
      (section "Expected" (pget plist :expected))
      (section "Actual" (pget plist :actual))
      (section "Root cause" (pget plist :root-cause))
      (section "Impact" (pget plist :impact))
      (section "Suggested" (pget plist :suggested))
      (section "Evidence" (pget plist :evidence)))
    (format s "~%---~%_Filed by the ourro QA loop from `~A.sexp`._~%"
            (finding-id plist))))

(defun finding-labels (plist)
  "(\"qa-finding\" [\"P1\"] [\"area:tui\"]) — severity/area become labels when
present."
  (append (list "qa-finding")
          (let ((sev (pget plist :severity)))
            (when (keywordp sev) (list (string-upcase (symbol-name sev)))))
          (let ((area (pget plist :area)))
            (when (keywordp area)
              (list (format nil "area:~A"
                            (string-downcase (symbol-name area))))))))


(defparameter *title-prefix* "[QA] "
  "The literal prefix FINDING-ISSUE-TITLE stamps before the finding id.")

(defun title-finding-id (title)
  "The finding id embedded in a '[QA] <id>: <title>' issue title, or NIL when
TITLE isn't one of ours. Used to match exactly on the id rather than by
substring — 'F-x' must not adopt 'F-xyz''s issue."
  (let ((plen (length *title-prefix*)))
    (when (and (>= (length title) plen)
               (string= *title-prefix* title :end2 plen))
      (let ((colon (search ": " title :start2 plen)))
        (when colon (subseq title plen colon))))))

(defun existing-issue-number (id)
  "Search open+closed issue titles for the finding id. gh's --jq keeps this
free of JSON parsing. Matches on the EXACT id parsed out of each candidate
title (not a substring), so 'F-x' never adopts 'F-xyz''s issue number. NIL
when nothing matches (or the search fails)."
  (handler-case
      (multiple-value-bind (out err code)
          (run-gh (append (list "issue" "list" "--state" "all"
                                "--search" (format nil "~S in:title" id)
                                "--json" "number,title"
                                "--jq" ".[] | \"\\(.number)\\t\\(.title)\"")))
        (declare (ignore err))
        (when (eql code 0)
          (loop for line in (ourro.qa.operator::split-lines out)
                for tab = (position #\Tab line)
                when (and tab (equal id (title-finding-id (subseq line (1+ tab)))))
                  do (return (parse-integer line :end tab :junk-allowed t)))))
    (error () nil)))

(defun issue-number-from-url (out)
  "gh issue create prints the new issue's URL; the number is its last path
component."
  (let* ((trimmed (string-trim '(#\Space #\Newline #\Return) out))
         (slash (position #\/ trimmed :from-end t)))
    (and slash (parse-integer trimmed :start (1+ slash) :junk-allowed t))))

(defun record-issue-number (file plist number)
  "Append :issue NUMBER to the finding sexp (tmp + rename, so a concurrent
reader never sees a torn file)."
  (let ((tmp (merge-pathnames (concatenate 'string
                                           (file-namestring file) ".tmp")
                              file)))
    (with-open-file (out tmp :direction :output :external-format :utf-8
                             :if-exists :supersede :if-does-not-exist :create)
      (let ((*print-pretty* t) (*print-readably* nil)
            (*package* (find-package :ourro.qa.operator)))
        (prin1 (append plist (list :issue number)) out)
        (terpri out)))
    (rename-file tmp file)))

(defun create-issue (file plist)
  "gh issue create; on a label-rejection retry once without labels (zero-setup
repos won't have qa-finding/P*/area:* labels yet). Returns the issue number
or NIL."
  (let* ((title (finding-issue-title plist))
         (body (finding-issue-body plist))
         (base (list "issue" "create" "--title" title "--body" body))
         (labels* (loop for l in (finding-labels plist)
                        append (list "--label" l))))
    (multiple-value-bind (out err code) (run-gh (append base labels*))
      (if (eql code 0)
          (issue-number-from-url out)
          ;; Missing labels are the common failure; body/title problems fail
          ;; again and return NIL.
          (multiple-value-bind (out2 err2 code2) (run-gh base)
            (declare (ignore err err2))
            (when (eql code2 0)
              (issue-number-from-url out2)))))))

(defun file-issue-for-finding (file)
  "File one finding as a GitHub issue, deduped. Returns a plist:
(:finding <name> :status :filed|:already-filed|:failed [:issue N])."
  (let* ((name (file-namestring file))
         (plist (first (read-sexp-file file)))
         (id (and plist (finding-id plist))))
    (cond
      ((null plist) (list :finding name :status :failed :error "unreadable"))
      ((null id) (list :finding name :status :failed :error "no :id"))
      ((pget plist :issue)
       (list :finding name :status :already-filed :issue (pget plist :issue)))
      (t
       (let ((existing (existing-issue-number id)))
         (cond
           (existing
            (ignore-errors (record-issue-number file plist existing))
            (list :finding name :status :already-filed :issue existing))
           (t
            (let ((number (create-issue file plist)))
              (cond
                (number
                 (ignore-errors (record-issue-number file plist number))
                 (list :finding name :status :filed :issue number))
                (t (list :finding name :status :failed
                         :error "gh issue create failed")))))))))))

(defun file-issues-for-findings (files)
  "File each finding, best-effort. Skips everything (without error) when
issue-filing is disabled or gh is unavailable. Returns
(:filed (…) :already-filed (…) :failed (…) [:skipped :reason])."
  (cond
    ((not (issues-enabled-p)) (list :skipped :disabled))
    ((not (gh-available-p)) (list :skipped :gh-unavailable))
    (t
     (let ((filed '()) (already '()) (failed '()))
       (dolist (file files)
         (let ((result (handler-case (file-issue-for-finding file)
                         (error (c)
                           (list :finding (file-namestring file)
                                 :status :failed :error (princ-to-string c))))))
           (case (pget result :status)
             (:filed (push result filed))
             (:already-filed (push result already))
             (t (push result failed)))))
       (list :filed (nreverse filed)
             :already-filed (nreverse already)
             :failed (nreverse failed))))))
