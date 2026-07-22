(in-package #:ourro.tests)

(def-suite pager-suite :in ourro)
(in-suite pager-suite)

(defun new-pager-agent ()
  (ourro.agent::make-agent :provider (ourro.llm:make-scripted-provider '())))

(defun pager-render-text (pager &optional (width 80))
  (with-output-to-string (out)
    (dolist (line (ourro.tui:render-component pager width))
      (dolist (span (if (listp line) line (list line)))
        (write-string (if (consp span) (cdr span) (princ-to-string span)) out))
      (write-char #\Newline out))))

(test ring-records-and-caps-at-20
  (let ((agent (new-pager-agent)))
    (dotimes (i 25)
      (ourro.agent::record-tool-result
       agent "read_file" (ourro.llm:json-object "path" (format nil "f~A" i))
       (format nil "content ~A" i) nil 5))
    (let ((ring (ourro.agent::agent-tool-results agent)))
      (is (= 20 (length ring)))                                 ; ring capped
      (is (= 25 (ourro.agent::agent-tool-result-count agent)))   ; count monotonic
      (is (= 25 (getf (first ring) :n))))))                     ; newest first

(test pager-renders-selected-result
  (let ((agent (new-pager-agent)))
    (ourro.agent::record-tool-result
     agent "list_files" (ourro.llm:json-object "pattern" "*")
     (format nil "a.txt~%b.txt") nil 3)
    (ourro.agent::record-tool-result
     agent "read_file" (ourro.llm:json-object "path" "a.txt") "hello world" nil 7)
    (let ((text (pager-render-text (ourro.agent::make-tool-output-pager agent))))
      (is (search "read_file" text))       ; newest entry selected
      (is (search "[1/2]" text))
      (is (search "hello world" text)))))

(test pager-key-navigation
  (let ((agent (new-pager-agent)))
    (ourro.agent::record-tool-result agent "t1" (ourro.llm:json-object)
                                    (format nil "one~%uno") nil 1)
    (ourro.agent::record-tool-result agent "t2" (ourro.llm:json-object)
                                    (format nil "two~%dos") nil 1)
    (let ((pager (ourro.agent::make-tool-output-pager agent)))
      (is (= 0 (ourro.agent::pager-index pager)))
      ;; [ walks to the older entry (higher index)
      (is (eq :handled (ourro.tui:overlay-key pager #\[)))
      (is (= 1 (ourro.agent::pager-index pager)))
      ;; ] walks back to the newer one and resets the line scroll
      (ourro.tui:overlay-key pager #\j)
      (is (eq :handled (ourro.tui:overlay-key pager #\])))
      (is (= 0 (ourro.agent::pager-index pager)))
      (is (= 0 (ourro.agent::pager-scroll pager)))
      ;; j scrolls the result body down
      (ourro.tui:overlay-key pager #\j)
      (is (= 1 (ourro.agent::pager-scroll pager)))
      ;; q closes
      (is (eq :close (ourro.tui:overlay-key pager #\q))))))

