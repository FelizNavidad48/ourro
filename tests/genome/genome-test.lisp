(in-package #:ourro.tests)

(def-suite genome-suite :in ourro)
(in-suite genome-suite)

(defparameter +sample-gene+
  "(defgene tool/greet
     (:generation 1 :parent nil :capabilities () :provenance (:seed t))
   (:doc \"Return a friendly greeting.\")
   (:code
    (deftool greet
        ((name :string \"Who to greet\" :required t))
      (:doc \"Greet NAME.\")
      (:contract (:pre ((stringp name)) :post ((stringp result))))
      (format nil \"hello ~A\" name)))
   (:tests
    (test greet/basic (is (stringp \"ok\")))))")

(test parses-gene
  (let ((gene (ourro.genome:parse-gene-source +sample-gene+)))
    (is (string= "tool/greet" (ourro.genome:gene-name gene)))
    (is (string= "Return a friendly greeting." (ourro.genome:gene-doc gene)))
    (is (= 1 (length (ourro.genome:gene-code-forms gene))))
    (is (= 1 (length (ourro.genome:gene-test-forms gene))))))

(test rejects-non-defgene
  (signals error (ourro.genome:parse-gene-source "(defun foo () 1)")))

(test rejects-unknown-section
  (signals error
    (ourro.genome:parse-gene-source
     "(defgene x (:generation 1) (:bogus 1))")))

(test extracts-definitions
  (let* ((gene (ourro.genome:parse-gene-source +sample-gene+))
         (definitions (ourro.genome:gene-definition-names gene)))
    (is (find :tool definitions :key #'first))))

(test gene-summary-mentions-tool
  (let ((gene (ourro.genome:parse-gene-source +sample-gene+)))
    (is (search "tool" (ourro.genome:gene-summary gene)))))

(test seed-genome-includes-evolution-hud
  ;; The seed genome (loaded by the test harness) ships the evolution HUD gene
  ;; (M7-3): the default chrome is itself a gene.
  (ensure-seed-genome-loaded)
  (is-true (ourro.genome:find-gene "ui/evolution-hud")))
