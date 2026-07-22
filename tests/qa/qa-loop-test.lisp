(in-package #:ourro.tests)


(def-suite qa-loop-suite :in ourro)
(in-suite qa-loop-suite)

(test placeholders-substitute-and-unknowns-stay-visible
  (is (string= "drive session s-1 now"
               (ourro.qa.compose:substitute-placeholders
                "drive session {{SESSION}} now"
                '(("SESSION" . "s-1")))))
  ;; Repeated placeholders all substitute.
  (is (string= "a b a"
               (ourro.qa.compose:substitute-placeholders
                "{{X}} b {{X}}" '(("X" . "a")))))
  ;; An unknown placeholder stays visible — a loud artifact in the composed
  ;; mission beats a silent empty string.
  (is (string= "keep {{MYSTERY}} intact"
               (ourro.qa.compose:substitute-placeholders
                "keep {{MYSTERY}} intact" '())))
  ;; A dangling {{ is emitted as-is, not dropped.
  (is (string= "tail {{oops"
               (ourro.qa.compose:substitute-placeholders "tail {{oops" '()))))

(test mission-name-reads-the-form-or-falls-back
  (let ((path (merge-pathnames
               (format nil "qa-loop-mission-~A.sexp" (ourro.util:make-id "m"))
               (uiop:temporary-directory))))
    (with-open-file (out path :direction :output :if-exists :supersede
                              :if-does-not-exist :create)
      (write-string "(mission \"legacy-rescue\" :persona \"ops manager\")" out))
    (is (string= "legacy-rescue" (ourro.qa.compose:mission-name path)))
    ;; Garbage contents → the basename, never an error.
    (with-open-file (out path :direction :output :if-exists :supersede)
      (write-string "((((" out))
    (is (string= (pathname-name path) (ourro.qa.compose:mission-name path)))
    (delete-file path)))


(test spend-pricing-mirrors-the-product-tables
  ;; qa/loop/spend.lisp's *pricing* must match src/llm's *model-aliases*
  ;; :pricing entries (keyed by backend model id). Drift here would silently
  ;; misprice the daily cap on EC2 — fail it in CI instead.
  (dolist (entry ourro.llm::*model-aliases*)
    (let* ((id (getf (rest entry) :model))
           (product (getf (rest entry) :pricing))
           (mirror (ourro.qa.spend:model-pricing id)))
      (is-true mirror "spend.lisp has no pricing for backend id ~A" id)
      (dolist (key '(:in :out :cache-read))
        (is (eql (getf product key) (getf mirror key))
            "pricing drift for ~A ~S: product ~A vs spend ~A"
            id key (getf product key) (getf mirror key))))))

(test spend-usage-cost-matches-the-product-math
  ;; Same usage, same pricing → same USD as the product's own cost meter.
  (let ((usage '(:prompt-tokens 120000 :candidates-tokens 8000
                 :cache-read-tokens 90000))
        (pricing '(:in 2.0d0 :out 12.0d0 :cache-read 0.5d0)))
    (is (= (ourro.agent::turn-cost usage pricing)
           (ourro.qa.spend:usage-cost usage pricing))))
  ;; Missing usage fields cost nothing and don't error.
  (is (= 0.0d0 (ourro.qa.spend:usage-cost nil '(:in 1.0d0 :out 1.0d0))))
  (is (= 0.0d0 (ourro.qa.spend:usage-cost '(:prompt-tokens 5000) nil))))

(test spend-sums-llm-call-events-and-skips-torn-lines
  (let ((path (merge-pathnames
               (format nil "qa-loop-events-~A.sexp" (ourro.util:make-id "e"))
               (uiop:temporary-directory))))
    (with-open-file (out path :direction :output :if-exists :supersede
                              :if-does-not-exist :create)
      (write-line "(:KIND :SESSION-START :SCHEMA 1)" out)
      (write-line "(:KIND :LLM-CALL :MODEL \"gemini-3.1-pro-preview\" :USAGE (:PROMPT-TOKENS 1000000 :CANDIDATES-TOKENS 1000000))" out)
      ;; Errored call with no usage → counted, costs nothing.
      (write-line "(:KIND :LLM-CALL :MODEL \"gemini-3.1-pro-preview\" :USAGE NIL :OUTCOME :ERROR)" out)
      ;; Torn tail write → skipped, not fatal.
      (write-line "(:KIND :LLM-CALL :MODEL \"gem" out)
      ;; A multi-line record (a :user-message whose :TEXT string carries
      ;; literal newlines) leaves junk fragment "lines" — non-plist forms
      ;; like (repeat on timeout) must be SKIPPED, not fed to GETF (the
      ;; malformed-property-list crash that killed the first live cycle).
      (write-line "(:KIND :USER-MESSAGE :TEXT \"mission says:" out)
      (write-line "(repeat on timeout)" out)
      (write-line "always --timeout 90\")" out)
      (write-line "(:a . :b)" out))
    (let ((sum (ourro.qa.spend:sum-events-file path)))
      ;; 1M in at $2 + 1M out at $12.
      (is (= 14.0d0 (getf sum :usd)))
      (is (= 2 (getf sum :calls)))
      (is (= 1000000 (getf sum :in-tokens)))
      (is (= 1000000 (getf sum :out-tokens))))
    (delete-file path)))

(test spend-ledger-appends-and-totals-per-day
  (let ((dir (merge-pathnames
              (format nil "qa-loop-ledger-~A/" (ourro.util:make-id "l"))
              (uiop:temporary-directory))))
    (unwind-protect
         (progn
           (ourro.qa.spend:ledger-append dir '(:cycle 1 :phase :run-operator :usd 1.25d0)
                                        :date "2026-07-18")
           (ourro.qa.spend:ledger-append dir '(:cycle 1 :phase :run-operator :usd 0.75d0)
                                        :date "2026-07-18")
           (ourro.qa.spend:ledger-append dir '(:cycle 2 :phase :run-operator :usd 9.0d0)
                                        :date "2026-07-19")
           (is (= 2.0d0 (ourro.qa.spend:ledger-total dir :date "2026-07-18")))
           (is (= 9.0d0 (ourro.qa.spend:ledger-total dir :date "2026-07-19")))
           ;; A day with no ledger totals zero, not an error.
           (is (= 0.0d0 (ourro.qa.spend:ledger-total dir :date "1999-01-01"))))
      (ignore-errors
       (uiop:delete-directory-tree (uiop:ensure-directory-pathname dir)
                                   :validate (constantly t))))))


(defmacro with-loop-root ((var) &body body)
  "Point OURRO_LOOP_ROOT at a throwaway directory for BODY."
  `(let ((,var (namestring
                (merge-pathnames
                 (format nil "qa-loop-root-~A/" (ourro.util:make-id "r"))
                 (uiop:temporary-directory)))))
     (unwind-protect
          (with-env ("OURRO_LOOP_ROOT" ,var)
            ,@body)
       (ignore-errors
        (uiop:delete-directory-tree (uiop:ensure-directory-pathname ,var)
                                    :validate (constantly t))))))

(test conductor-state-roundtrips-under-loop-root
  (with-loop-root (root)
    (is (null (ourro.qa.conductor:read-state)))
    (ourro.qa.conductor:write-state '(:phase :pick-scenario :cycle 3 :cursor 1))
    (let ((state (ourro.qa.conductor:read-state)))
      (is (eq :pick-scenario (getf state :phase)))
      (is (= 3 (getf state :cycle)))
      (is (= 1 (getf state :cursor))))))

(test conductor-next-mission-round-robins-with-wrap
  ;; Against the real mission bank (all 7 missions' :needs are python3/node
  ;; class tools present on dev machines and in the Docker image).
  (multiple-value-bind (file0 cursor1) (ourro.qa.conductor:next-mission '(:cursor 0))
    (is-true file0)
    (is (= 1 cursor1))
    ;; A cursor past the end wraps instead of erroring.
    (multiple-value-bind (file-wrap cursor-wrap)
        (ourro.qa.conductor:next-mission '(:cursor 9999))
      (is-true file-wrap)
      (is (integerp cursor-wrap)))
    ;; Distinct cursors visit distinct missions.
    (multiple-value-bind (file1) (ourro.qa.conductor:next-mission '(:cursor 1))
      (is (not (equal (namestring file0) (namestring file1)))))))

(test conductor-mission-plist-reads-name-and-fixture
  (let ((plist (ourro.qa.conductor:mission-plist
                (merge-pathnames "qa/missions/legacy-rescue.sexp"
                                 (asdf:system-source-directory "ourro")))))
    (is (string= "legacy-rescue" (getf plist :name)))
    (is (string= "qa/fixtures/legacy-inventory" (getf plist :fixture)))
    (is (equal '("python3") (getf plist :needs)))))

(test conductor-supervise-sees-terminal-states
  (with-loop-root (root)
    (let ((result (merge-pathnames "r.sexp" (pathname root))))
      ;; No result, expired wall clock → :timeout (checked before any tmux
      ;; call, so this needs no live session).
      (is (eq :timeout (ourro.qa.conductor:supervise-mission-session
                        "no-such-session" result :wall-clock -1 :poll 0)))
      ;; Kill switch → :stopped.
      (ensure-directories-exist (ourro.qa.conductor::stop-file))
      (with-open-file (out (ourro.qa.conductor::stop-file)
                           :direction :output :if-does-not-exist :create
                           :if-exists :supersede))
      (is (eq :stopped (ourro.qa.conductor:supervise-mission-session
                        "no-such-session" result :wall-clock 60 :poll 0)))
      (delete-file (ourro.qa.conductor::stop-file))
      ;; Result file present → :done, immediately.
      (ensure-directories-exist result)
      (with-open-file (out result :direction :output :if-does-not-exist :create
                                  :if-exists :supersede)
        (write-line "(:ok t)" out))
      (is (eq :done (ourro.qa.conductor:supervise-mission-session
                     "no-such-session" result :wall-clock 60 :poll 0))))))

(test compose-fills-the-real-operator-doctrine
  ;; End-to-end over the checked-in template: every placeholder the doctrine
  ;; declares gets a value, the mission sexp lands verbatim, and no {{…}}
  ;; survives — a template/compose drift fails here, not mid-cycle on EC2.
  (let* ((root (asdf:system-source-directory "ourro"))
         (doctrine (merge-pathnames "qa/loop/doctrine-operator.md" root))
         (mission (first (directory (merge-pathnames "qa/missions/*.sexp" root))))
         (output (merge-pathnames
                  (format nil "qa-loop-composed-~A.md" (ourro.util:make-id "c"))
                  (uiop:temporary-directory))))
    (ourro.qa.compose:compose-operator-mission
     :doctrine-file doctrine :mission-file mission :output output
     :session "ourro-qa-test-1" :subject-work "/tmp/x/work/"
     :subject-home "/tmp/x/home/" :findings-dir "/tmp/x/findings/"
     :result-file "/tmp/x/result.sexp")
    (let ((text (uiop:read-file-string output)))
      (is (search "ourro-qa-test-1" text))
      (is (search "/tmp/x/result.sexp" text))
      (is (search "(mission" text))
      (is (null (search "{{" text))
          "composed mission still contains an unfilled {{placeholder}}"))
    (delete-file output)))
