(in-package #:ourro.tests)

(def-suite inspector-suite :in ourro)
(in-suite inspector-suite)

(defun inspector-text (lines)
  "Flatten a list of styled lines (spans) into one string for assertions."
  (with-output-to-string (out)
    (dolist (line lines)
      (dolist (span (if (listp line) line (list line)))
        (write-string (if (consp span) (cdr span) (princ-to-string span)) out))
      (write-char #\Newline out))))

(defun make-headless-agent ()
  (ourro.agent::make-agent :provider (ourro.llm:make-scripted-provider '())))

(test inspector-renders-rows-and-diff
  (ensure-seed-genome-loaded)
  (let* ((agent (make-headless-agent))
         (gene (first (ourro.genome:list-genes)))
         (src (or (ourro.genome:gene-source-text gene)
                  (ourro.genome:render-gene-source gene)))
         (records (list (list :id "r1" :status :hot-loaded
                              :gene-name (ourro.genome:gene-name gene)
                              :source src
                              :pattern (list :id "p1" :evidence nil)
                              :time "2026-07-13")
                        (list :id "r2" :status :rejected
                              :gene-name "tool/broken"
                              :diagnostics "compile failed: boom"
                              :pattern (list :id "p2")
                              :time "2026-07-13"))))
    (setf (ourro.agent::agent-candidates agent) records)
    (let* ((insp (ourro.agent::make-evolution-inspector agent))
           (text (inspector-text (ourro.tui:render-component insp 80))))
      ;; Title row + both gene rows present.
      (is (search "evolutions" text))
      (is (search (ourro.genome:gene-name gene) text))
      (is (search "tool/broken" text))
      ;; Expand the cursor row → the structural diff renders an addition.
      (is (eq :handled (ourro.tui:overlay-key insp :enter)))
      (let ((expanded (inspector-text (ourro.tui:render-component insp 80))))
        (is (search "structural diff" expanded))
        (is (search "＋" expanded))))))

(test inspector-navigation-and-close
  (let ((agent (make-headless-agent)))
    (setf (ourro.agent::agent-candidates agent)
          (list (list :id "a" :status :hot-loaded :gene-name "tool/one"
                      :pattern (list :id "p"))
                (list :id "b" :status :verified :gene-name "tool/two"
                      :pattern (list :id "q"))))
    (let ((insp (ourro.agent::make-evolution-inspector agent)))
      (is (= 0 (ourro.agent::inspector-cursor insp)))
      (is (eq :handled (ourro.tui:overlay-key insp #\j)))
      (is (= 1 (ourro.agent::inspector-cursor insp)))
      (is (eq :handled (ourro.tui:overlay-key insp #\k)))
      (is (= 0 (ourro.agent::inspector-cursor insp)))
      ;; q closes.
      (is (eq :close (ourro.tui:overlay-key insp #\q))))))

