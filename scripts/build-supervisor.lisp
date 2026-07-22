
(require :asdf)
(let ((setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file setup) (load setup)))
(pushnew (uiop:getcwd) asdf:*central-registry* :test #'equal)

(handler-case
    (progn
      (funcall (read-from-string "ql:quickload")
               (list :bordeaux-threads) :silent t)
      (asdf:load-system "ourro/supervisor"))
  (error (c)
    (format *error-output* "~&[supervisor] load failed: ~A~%" c)
    (sb-ext:exit :code 1)))

(let ((output (merge-pathnames "bin/ourro" (uiop:getcwd))))
  (ensure-directories-exist output)
  (sb-ext:save-lisp-and-die
   output
   :executable t
   :compression t
   :save-runtime-options t
   :toplevel (read-from-string "ourro.supervisor:main")))
