
(require :asdf)
(let ((setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file setup) (load setup)))
(pushnew (uiop:getcwd) asdf:*central-registry* :test #'equal)

(funcall (read-from-string "ql:quickload")
         (list :bordeaux-threads :dexador :com.inuoe.jzon :fiveam :cl-ppcre)
         :silent t)
(asdf:load-system "ourro")

(funcall (read-from-string "ourro.genome:load-genome")
         (merge-pathnames "seed-genome/" (uiop:getcwd)))

(let ((agent (funcall (read-from-string "ourro.agent:make-agent")
                      :provider (funcall (read-from-string
                                          "ourro.llm:make-vertex-provider"))
                      :generation "gen-dev")))
  (funcall (read-from-string "ourro.agent:run-agent") agent))
(sb-ext:exit :code 0)
