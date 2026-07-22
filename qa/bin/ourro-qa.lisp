
(require :sb-posix)

(let ((here (directory-namestring *load-truename*)))
  (handler-bind ((warning #'muffle-warning))
    (load (merge-pathnames "../src/operator.lisp" here))))

(ourro.qa.operator:cli-main (cdr sb-ext:*posix-argv*))
