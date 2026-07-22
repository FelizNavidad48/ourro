
(in-package #:ourro.kernel)

(defparameter *max-form-depth* 80
  "Maximum nesting depth of a candidate form.")

(defparameter *max-form-atoms* 40000
  "Maximum number of atoms in a candidate form.")

(defun make-safe-readtable ()
  (let ((readtable (copy-readtable nil)))
    ;; *read-eval* nil already errors on #., but remove the reader macro so
    ;; the failure mode is a plain reader error, and strip other surprises.
    (set-dispatch-macro-character
     #\# #\. (lambda (stream char n)
               (declare (ignore stream char n))
               (error "#. is not allowed in candidate forms"))
     readtable)
    (dolist (sub '(#\p #\P))               ; #p pathnames: not needed, remove
      (set-dispatch-macro-character
       #\# sub (lambda (stream char n)
                 (declare (ignore stream char n))
                 (error "#p pathname syntax is not allowed in candidate forms"))
       readtable))
    readtable))

(defun check-form-limits (form)
  (let ((atoms 0))
    (labels ((walk (x depth)
               (when (> depth *max-form-depth*)
                 (error 'unsafe-form-error
                        :diagnostics (format nil "Form exceeds maximum depth ~A"
                                             *max-form-depth*)))
               (cond ((consp x)
                      ;; Guard against improper tails as well.
                      (walk (car x) (1+ depth))
                      (walk (cdr x) depth))
                     (t (incf atoms)
                        (when (> atoms *max-form-atoms*)
                          (error 'unsafe-form-error
                                 :diagnostics
                                 (format nil "Form exceeds maximum size (~A atoms)"
                                         *max-form-atoms*)))))))
      (walk form 0))
    form))

(defun safe-read-form (text &key (package (find-package :ourro.util)))
  "Read exactly one form from TEXT with evaluation disabled, interning new
symbols only into PACKAGE. Signals UNSAFE-FORM-ERROR on any reader error,
trailing junk, or size/depth violation."
  (handler-case
      (with-standard-io-syntax
        (let ((*read-eval* nil)
              (*readtable* (make-safe-readtable))
              (*package* (or (and (packagep package) package)
                             (find-package package)
                             (error "No such package: ~S" package)))
              (*read-default-float-format* 'double-float))
          (with-input-from-string (in text)
            (let ((form (read in)))
              (let ((extra (read in nil :eof)))
                (unless (eq extra :eof)
                  (error 'unsafe-form-error
                         :diagnostics
                         (format nil "Expected exactly one form but found a second: ~
~A" (truncate-string (prin1-to-string extra) 200)))))
              (check-form-limits form)))))
    (unsafe-form-error (c) (error c))
    ((or reader-error end-of-file error) (c)
      (error 'unsafe-form-error
             :diagnostics (format nil "Reader error: ~A" c)))))

(defun safe-read-forms (text &key (package (find-package :ourro.util)))
  "Read all forms from TEXT under the same discipline as SAFE-READ-FORM."
  (handler-case
      (with-standard-io-syntax
        (let ((*read-eval* nil)
              (*readtable* (make-safe-readtable))
              (*package* (or (and (packagep package) package)
                             (find-package package)
                             (error "No such package: ~S" package)))
              (*read-default-float-format* 'double-float))
          (with-input-from-string (in text)
            (loop for form = (read in nil :eof)
                  until (eq form :eof)
                  collect (check-form-limits form)))))
    (unsafe-form-error (c) (error c))
    ((or reader-error end-of-file error) (c)
      (error 'unsafe-form-error
             :diagnostics (format nil "Reader error: ~A" c)))))
