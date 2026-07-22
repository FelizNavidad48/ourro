
(defpackage #:ourro.qa.compose
  (:use #:cl)
  (:export #:substitute-placeholders
           #:mission-name
           #:compose-operator-mission))

(in-package #:ourro.qa.compose)

(defun slurp (pathname)
  "Read a whole file as a string (no uiop — this file must load under a bare
`sbcl --script`)."
  (with-open-file (in pathname :direction :input
                               :external-format :utf-8)
    (let ((text (make-string (file-length in))))
      (subseq text 0 (read-sequence text in)))))

(defun substitute-placeholders (template bindings)
  "Replace every {{KEY}} in TEMPLATE using BINDINGS, an alist of
(\"KEY\" . \"value\") pairs. Unknown placeholders are left intact (a loud
artifact in the composed file beats a silent empty string). Values are
inserted literally."
  (let ((out (make-string-output-stream))
        (len (length template))
        (i 0))
    (loop while (< i len)
          do (let ((open (search "{{" template :start2 i)))
               (cond
                 ((null open)
                  (write-string template out :start i)
                  (setf i len))
                 (t
                  (write-string template out :start i :end open)
                  (let ((close (search "}}" template :start2 (+ open 2))))
                    (cond
                      ((null close)          ; dangling {{ — emit and finish
                       (write-string template out :start open)
                       (setf i len))
                      (t
                       (let* ((key (subseq template (+ open 2) close))
                              (hit (assoc key bindings :test #'string=)))
                         (if hit
                             (write-string (cdr hit) out)
                             ;; leave the unknown placeholder visible
                             (write-string template out :start open
                                                        :end (+ close 2))))
                       (setf i (+ close 2)))))))))
    (get-output-stream-string out)))

(defun mission-name (mission-file)
  "The mission's name string — second element of the (mission \"name\" …)
form — or the file's basename when the form doesn't parse."
  (or (ignore-errors
       (with-open-file (in mission-file :direction :input)
         (let ((*read-eval* nil)
               (*package* (find-package :keyword)))
           (let ((form (read in)))
             (and (consp form) (stringp (second form)) (second form))))))
      (pathname-name mission-file)))

(defun compose-operator-mission (&key doctrine-file mission-file output
                                      session subject-work subject-home
                                      findings-dir result-file)
  "Compose the operator ourro's mission file: DOCTRINE-FILE with its
placeholders filled from the per-cycle values, the verbatim MISSION-FILE sexp
embedded at {{MISSION-SEXP}}. Writes OUTPUT and returns its namestring."
  (let* ((template (slurp doctrine-file))
         (mission-text (slurp mission-file))
         (bindings (list (cons "SESSION" session)
                         (cons "SUBJECT-WORK" (namestring subject-work))
                         (cons "SUBJECT-HOME" (namestring subject-home))
                         (cons "FINDINGS-DIR" (namestring findings-dir))
                         (cons "RESULT-FILE" (namestring result-file))
                         (cons "MISSION-NAME" (mission-name mission-file))
                         (cons "MISSION-SEXP" mission-text))))
    (ensure-directories-exist output)
    (with-open-file (out output :direction :output
                                :if-exists :supersede :if-does-not-exist :create)
      (write-string (substitute-placeholders template bindings) out))
    (namestring output)))
