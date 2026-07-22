
(require :asdf)

(let ((setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file setup) (load setup)))

;; Make this repo's systems findable.
(pushnew (uiop:getcwd) asdf:*central-registry* :test #'equal)

(handler-case
    (progn
      (funcall (read-from-string "ql:quickload")
               (list :bordeaux-threads :dexador :com.inuoe.jzon :fiveam :cl-ppcre)
               :silent t)
      (asdf:load-system "ourro")
      (format t "~&[base-core] ourro base loaded.~%"))
  (error (c)
    (format *error-output* "~&[base-core] load failed: ~A~%" c)
    (sb-ext:exit :code 1)))

(let ((output (merge-pathnames ".ourro/base.core"
                               (user-homedir-pathname))))
  (when (uiop:getenv "OURRO_HOME")
    (setf output (merge-pathnames "base.core"
                                  (uiop:ensure-directory-pathname
                                   (uiop:getenv "OURRO_HOME")))))
  (ensure-directories-exist output)
  (format t "~&[base-core] saving ~A~%" output)
  (sb-ext:save-lisp-and-die output :compression t))
