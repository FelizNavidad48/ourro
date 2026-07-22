(in-package #:ourro.tests)

(def-suite miner-suite :in ourro)
(in-suite miner-suite)

(defun make-call-event (tool args &optional (elapsed 100))
  (list :kind :tool-call :outcome :ok :tool tool :args args
        :elapsed-ms elapsed :time (ourro.util:iso-time)))

(test mines-repeated-command
  ;; recent-events returns newest first; build a plausible ordering.
  (let ((events (list (make-call-event "test" '(:path "a.py") 500)
                      (make-call-event "test" '(:path "b.py") 500)
                      (make-call-event "test" '(:path "c.py") 500))))
    (let ((patterns (ourro.miner:mine-patterns :events events)))
      (is (find :repeated-command patterns :key (lambda (p) (getf p :kind))))
      (let ((command (find :repeated-command patterns
                           :key (lambda (p) (getf p :kind)))))
        (is (>= (getf command :count) 3))))))

(test mines-repeated-sequence
  ;; edit → test, three times.
  (let ((events (list (make-call-event "edit_file" '(:path "x"))
                      (make-call-event "shell" '(:command "make test"))
                      (make-call-event "edit_file" '(:path "y"))
                      (make-call-event "shell" '(:command "make test"))
                      (make-call-event "edit_file" '(:path "z"))
                      (make-call-event "shell" '(:command "make test")))))
    (let ((patterns (ourro.miner:mine-patterns :events events)))
      (is (find :repeated-sequence patterns
                :key (lambda (p) (getf p :kind)))))))

(test no-pattern-below-threshold
  (let ((events (list (make-call-event "rare" '(:x 1))
                      (make-call-event "rare" '(:x 2)))))
    (is (null (find :repeated-command (ourro.miner:mine-patterns :events events)
                    :key (lambda (p) (getf p :kind)))))))

(test mining-does-not-mix-workspaces
  (let ((events (append
                 (loop repeat 2 collect
                   (append (make-call-event "test" '(:path "x"))
                           '(:workspace "/repo/a/")))
                 (loop repeat 2 collect
                   (append (make-call-event "test" '(:path "x"))
                           '(:workspace "/repo/b/"))))))
    (is (null (find :repeated-command
                    (ourro.miner:mine-patterns :events events)
                    :key (lambda (p) (getf p :kind)))))
    (push (append (make-call-event "test" '(:path "y"))
                  '(:workspace "/repo/a/"))
          events)
    (let ((pattern (find :repeated-command
                         (ourro.miner:mine-patterns :events events)
                         :key (lambda (p) (getf p :kind)))))
      (is (string= "/repo/a/" (getf pattern :workspace)))
      (is (plusp (getf pattern :confidence))))))

(test anti-unification
  (let ((a (ourro.miner:argument-skeleton '(:path "a" :mode "r")))
        (b (ourro.miner:argument-skeleton '(:path "b" :mode "r"))))
    (is (ourro.miner:skeletons-unify-p a b))))
