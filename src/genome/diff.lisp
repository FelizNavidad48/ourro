
(in-package #:ourro.genome)

(export '(gene-summary
          gene-structural-diff
          genome-diff
          describe-genome-diff))

(defun gene-summary (gene)
  "One-line structural summary of GENE."
  (let* ((definitions (gene-definition-names gene))
         (tools (count :tool definitions :key #'first))
         (functions (count :function definitions :key #'first))
         (methods (count :method definitions :key #'first))
         (classes (count :class definitions :key #'first))
         (tests (length (gene-test-forms gene)))
         (caps (gene-capabilities gene)))
    (format nil "~A (~@[~D tool~:P, ~]~@[~D function~:P, ~]~@[~D method~:P, ~]~@[~D class~:P, ~]~D test~:P~@[, caps: ~{~(~A~)~^ ~}~])"
            (gene-name gene)
            (and (plusp tools) tools)
            (and (plusp functions) functions)
            (and (plusp methods) methods)
            (and (plusp classes) classes)
            tests
            caps)))

(defun definition-key (definition)
  (list (first definition)
        (princ-to-string (second definition))))

(defun definitions-with-forms (gene)
  "Pair each extracted definition with its source form."
  (let ((definitions '()))
    (dolist (form (gene-code-forms gene))
      (let ((extracted (gene-definition-names
                        (make-instance 'gene :name (gene-name gene)
                                             :code-forms (list form)))))
        (dolist (definition extracted)
          (push (list (definition-key definition) definition form)
                definitions))))
    (nreverse definitions)))

(defun gene-structural-diff (old-gene new-gene)
  "Compare two versions of a gene. Returns a list of entries:
(:added-definition D) (:removed-definition D) (:changed-definition D)
(:capabilities-changed OLD NEW) (:tests-changed OLD-COUNT NEW-COUNT)."
  (let ((entries '())
        (old-definitions (and old-gene (definitions-with-forms old-gene)))
        (new-definitions (definitions-with-forms new-gene)))
    (dolist (new-entry new-definitions)
      (destructuring-bind (key definition form) new-entry
        (let ((old-entry (assoc key old-definitions :test #'equal)))
          (cond ((null old-entry)
                 (push (list :added-definition definition) entries))
                ((not (equal (third old-entry) form))
                 (push (list :changed-definition definition) entries))))))
    (dolist (old-entry old-definitions)
      (unless (assoc (first old-entry) new-definitions :test #'equal)
        (push (list :removed-definition (second old-entry)) entries)))
    (when (and old-gene
               (not (equal (gene-capabilities old-gene)
                           (gene-capabilities new-gene))))
      (push (list :capabilities-changed
                  (gene-capabilities old-gene)
                  (gene-capabilities new-gene))
            entries))
    (when (and old-gene
               (/= (length (gene-test-forms old-gene))
                   (length (gene-test-forms new-gene))))
      (push (list :tests-changed
                  (length (gene-test-forms old-gene))
                  (length (gene-test-forms new-gene)))
            entries))
    (nreverse entries)))

(defun genome-diff (old-genes new-genes)
  "Diff two genomes (lists of GENEs). Returns
(:added (gene…) :removed (gene…) :changed ((old new entries)…))."
  (let ((old-table (make-hash-table :test #'equal))
        (added '()) (removed '()) (changed '()))
    (dolist (gene old-genes)
      (setf (gethash (gene-name gene) old-table) gene))
    (dolist (gene new-genes)
      (let ((old (gethash (gene-name gene) old-table)))
        (cond ((null old) (push gene added))
              ((not (equal (gene-code-forms old) (gene-code-forms gene)))
               (push (list old gene (gene-structural-diff old gene)) changed))
              (t nil))
        (remhash (gene-name gene) old-table)))
    (maphash (lambda (name gene) (declare (ignore name)) (push gene removed))
             old-table)
    (list :added (nreverse added)
          :removed (nreverse removed)
          :changed (nreverse changed))))

(defun describe-definition (definition)
  (ecase (first definition)
    (:function (format nil "function ~(~A~)" (second definition)))
    (:tool (format nil "tool ~A" (second definition)))
    (:method (format nil "method ~(~A~)~@[ ~(~{~A~^ ~}~)~]"
                     (second definition) (third definition)))
    (:class (format nil "class ~(~A~)" (second definition)))
    (:variable (format nil "variable ~(~A~)" (second definition)))))

(defun describe-genome-diff (diff &key (stream nil))
  "Render a GENOME-DIFF for the inspector."
  (let ((out (or stream (make-string-output-stream))))
    (dolist (gene (pget diff :added))
      (format out "＋ ~A~%" (gene-summary gene)))
    (dolist (gene (pget diff :removed))
      (format out "－ ~A~%" (gene-name gene)))
    (dolist (change (pget diff :changed))
      (destructuring-bind (old new entries) change
        (declare (ignore old))
        (format out "~~ ~A~%" (gene-name new))
        (dolist (entry entries)
          (case (first entry)
            (:added-definition
             (format out "    ＋ ~A~%" (describe-definition (second entry))))
            (:removed-definition
             (format out "    － ~A~%" (describe-definition (second entry))))
            (:changed-definition
             (format out "    ~~ ~A~%" (describe-definition (second entry))))
            (:capabilities-changed
             (format out "    caps: ~(~A~) → ~(~A~)~%"
                     (second entry) (third entry)))
            (:tests-changed
             (format out "    tests: ~A → ~A~%"
                     (second entry) (third entry)))))))
    (if stream nil (get-output-stream-string out))))
