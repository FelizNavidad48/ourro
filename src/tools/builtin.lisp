
(defpackage #:ourro.toolkit
  (:use #:cl #:ourro.util)
  (:import-from #:ourro.kernel #:require-capability)
  (:export #:*workspace*
           #:workspace-path
           #:display-path
           #:list-files
           #:search-files
           #:file-info
           #:read-file-numbered
           #:apply-text-edit
           #:edit-ambiguity
           #:clamp-output
           #:count-occurrences))

(in-package #:ourro.toolkit)

(defvar *workspace* (uiop:getcwd)
  "The directory the agent is working in (the user's repo).")

(defun workspace-path (path)
  "Resolve PATH (absolute or workspace-relative) to a pathname."
  (let ((pathname (uiop:parse-native-namestring path)))
    (if (uiop:absolute-pathname-p pathname)
        pathname
        (merge-pathnames pathname (uiop:ensure-directory-pathname *workspace*)))))

(defun display-path (pathname)
  "Render PATHNAME relative to the workspace when possible."
  (let ((full (namestring pathname))
        (root (namestring (uiop:ensure-directory-pathname *workspace*))))
    (if (string-prefix-p root full)
        (subseq full (length root))
        full)))

(defparameter *ignored-directories*
  '(".git" "node_modules" ".ourro" "target" "dist" ".svn" ".hg"
    "__pycache__" ".venv" "venv"))

(defun list-files (&key (root *workspace*) pattern (limit 500))
  "Recursively list files under ROOT whose name matches PATTERN (a
substring or shell-ish glob where * matches anything). Returns namestrings
relative to the workspace, sorted, capped at LIMIT."
  (require-capability :filesystem-read 'list-files)
  (let ((results '())
        (count 0)
        (matcher (and pattern (glob-matcher pattern))))
    (labels ((walk (directory)
               (when (>= count limit) (return-from walk))
               (dolist (file (ignore-errors
                              (uiop:directory-files directory)))
                 (when (>= count limit) (return-from walk))
                 (let ((name (display-path file)))
                   (when (or (null matcher) (funcall matcher name))
                     (push name results)
                     (incf count))))
               (dolist (sub (ignore-errors
                             (uiop:subdirectories directory)))
                 (let ((dirname (first (last (pathname-directory sub)))))
                   (unless (member dirname *ignored-directories* :test #'equal)
                     (walk sub))))))
      (walk (uiop:ensure-directory-pathname root)))
    (sort results #'string<)))

(defun glob-matcher (pattern)
  "Compile a simple glob (supports * and ?) into a predicate on strings."
  (let ((regex (with-output-to-string (out)
                 (loop for char across pattern
                       do (case char
                            (#\* (write-string ".*" out))
                            (#\? (write-string "." out))
                            (t (write-string (cl-ppcre:quote-meta-chars
                                              (string char))
                                             out)))))))
    (let ((scanner (cl-ppcre:create-scanner regex :case-insensitive-mode t)))
      (lambda (string) (and (cl-ppcre:scan scanner string) t)))))

(defun search-files (regex &key (root *workspace*) file-pattern
                                (max-matches 200))
  "Search file contents under ROOT for REGEX. Returns a formatted result
string: path:line: text, capped at MAX-MATCHES."
  (require-capability :filesystem-read 'search-files)
  (let ((scanner (cl-ppcre:create-scanner regex))
        (files (list-files :root root :pattern file-pattern :limit 2000))
        (matches 0))
    (with-output-to-string (out)
      (dolist (relative files)
        (when (>= matches max-matches) (return))
        (let ((path (workspace-path relative)))
          (when (probably-text-file-p path)
            (handler-case
                (with-open-file (in path :direction :input
                                        :external-format :utf-8)
                  (loop for line = (read-line in nil nil)
                        for number from 1
                        while (and line (< matches max-matches))
                        when (cl-ppcre:scan scanner line)
                          do (incf matches)
                             (format out "~A:~A: ~A~%" relative number
                                     (truncate-string line 300))))
              (error () nil)))))
      (when (zerop matches)
        (write-string "No matches." out)))))

(defun probably-text-file-p (path)
  (let ((type (string-downcase (or (pathname-type path) ""))))
    (not (member type '("png" "jpg" "jpeg" "gif" "pdf" "zip" "gz" "tar"
                        "ico" "woff" "woff2" "ttf" "eot" "core" "fasl"
                        "dylib" "so" "o" "a" "wasm" "class" "jar")
                 :test #'equal))))

(defun file-info (path)
  (require-capability :filesystem-read 'file-info)
  (let ((pathname (workspace-path path)))
    (if (probe-file pathname)
        (list :exists t
              :size (with-open-file (in pathname :element-type '(unsigned-byte 8))
                      (file-length in))
              :directory (and (uiop:directory-exists-p pathname) t))
        (list :exists nil))))

(defun read-file-numbered (path &key (offset 1) (limit 2000))
  "Read PATH and return it with line numbers (cat -n style), starting at
line OFFSET, at most LIMIT lines."
  (require-capability :filesystem-read 'read-file-numbered)
  (with-open-file (in (workspace-path path) :direction :input
                                            :external-format :utf-8)
    (with-output-to-string (out)
      (loop repeat (1- offset) do (unless (read-line in nil nil) (return)))
      (loop for line = (read-line in nil nil)
            for number from offset
            while (and line (< (- number offset) limit))
            do (format out "~6D→~A~%" number (truncate-string line 500))))))

(defun count-occurrences (needle haystack)
  (loop with start = 0
        with count = 0
        for position = (search needle haystack :start2 start)
        while position
        do (incf count) (setf start (1+ position))
        finally (return count)))

(define-condition edit-ambiguity (error)
  ((occurrences :initarg :occurrences :reader edit-ambiguity-occurrences))
  (:report (lambda (c stream)
             (format stream "old_string matched ~A times; it must match exactly once. Add surrounding context to disambiguate."
                     (edit-ambiguity-occurrences c)))))

(defun apply-text-edit (content old-string new-string &key replace-all)
  "Replace OLD-STRING with NEW-STRING in CONTENT. Unless REPLACE-ALL,
OLD-STRING must occur exactly once. Returns the new content."
  (let ((count (count-occurrences old-string content)))
    (cond ((zerop count)
           (error "old_string not found in file"))
          ((and (> count 1) (not replace-all))
           (error 'edit-ambiguity :occurrences count))
          (t
           ;; Literal replacement, no regex semantics in either string.
           (with-output-to-string (out)
             (loop with start = 0
                   for position = (search old-string content :start2 start)
                   while position
                   do (write-string content out :start start :end position)
                      (write-string new-string out)
                      (setf start (+ position (length old-string)))
                   finally (write-string content out :start start)))))))

(defun clamp-output (string &key (max-chars 30000) (label "output"))
  "Truncate STRING for the model with an explicit truncation marker."
  (if (<= (length string) max-chars)
      string
      (format nil "~A~%… [~A truncated: ~A of ~A chars shown]"
              (subseq string 0 max-chars) label max-chars (length string))))
