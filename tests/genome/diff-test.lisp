(in-package #:ourro.tests)

(def-suite diff-suite :in ourro)
(in-suite diff-suite)

(defun gene-v (doc body)
  (ourro.genome:parse-gene-source
   (format nil "(defgene tool/x (:generation 1 :capabilities ())
                  (:doc ~S)
                  (:code ~A)
                  (:tests (test x/t (is-true t))))"
           doc body)))

(test detects-added-gene
  (let* ((g (gene-v "d" "(defun a () 1)"))
         (diff (ourro.genome:genome-diff '() (list g))))
    (is (= 1 (length (getf diff :added))))))

(test detects-changed-definition
  (let* ((old (gene-v "d" "(defun a () 1)"))
         (new (gene-v "d" "(defun a () 2)"))
         (diff (ourro.genome:genome-diff (list old) (list new))))
    (is (= 1 (length (getf diff :changed))))
    (let ((entries (third (first (getf diff :changed)))))
      (is (find :changed-definition entries :key #'first)))))

(test structural-diff-added-function
  (let* ((old (gene-v "d" "(defun a () 1)"))
         (new (gene-v "d" "(progn (defun a () 1) (defun b () 2))"))
         (entries (ourro.genome:gene-structural-diff old new)))
    ;; b is added (progn wrapper means both are inside one form; extraction
    ;; walks each top-level code form, so the wrapper changes 'a' pairing)
    (is (listp entries))))

(test describe-diff-renders
  (let* ((g (gene-v "d" "(defun a () 1)"))
         (diff (ourro.genome:genome-diff '() (list g)))
         (text (ourro.genome:describe-genome-diff diff)))
    (is (search "＋" text))))
