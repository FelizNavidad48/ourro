(in-package #:ourro.tests)

(def-suite events-suite :in ourro)
(in-suite events-suite)

(test log-and-recall
  (let ((ourro.observe::*recent-events* '())
        (ourro.observe::*event-log-path* nil))
    (ourro.observe:log-event :tool-call :tool "read_file" :args '(:path "x"))
    (ourro.observe:log-event :user-message :text "hi")
    (let ((events (ourro.observe:recent-events :limit 10)))
      (is (= 2 (length events)))
      (is (eq :user-message (getf (first events) :kind))))))

(test redacts-secrets
  (is (string= "«redacted»"
               (ourro.observe:redact-argument "my-api-key-value")))
  (is (string= "safe" (ourro.observe:redact-argument "safe"))))

(test redacts-values-by-sensitive-key
  (let ((ourro.observe::*recent-events* '())
        (ourro.observe::*event-log-path* nil))
    (let ((event (ourro.observe:log-event
                  :probe :args (list :authorization "opaque-value"
                                     :nested (list :token "also-opaque")))))
      (is (string= "«redacted»" (getf (getf event :args) :authorization)))
      (is (string= "«redacted»"
                   (getf (getf (getf event :args) :nested) :token))))))

(test usage-token-counts-survive-redaction
  ;; :…-TOKENS keys are usage COUNTS, not credentials. The "token" needle
  ;; used to redact every :llm-call's usage numbers in events.sexp, silently
  ;; destroying the persisted cost telemetry the QA loop prices from.
  (let ((ourro.observe::*recent-events* '())
        (ourro.observe::*event-log-path* nil))
    (let ((event (ourro.observe:log-event
                  :llm-call :usage (list :prompt-tokens 1200
                                         :candidates-tokens 34
                                         :total-tokens 1234
                                         :cache-read-tokens 1000))))
      (is (= 1200 (getf (getf event :usage) :prompt-tokens)))
      (is (= 34 (getf (getf event :usage) :candidates-tokens)))
      (is (= 1234 (getf (getf event :usage) :total-tokens)))
      (is (= 1000 (getf (getf event :usage) :cache-read-tokens)))
      ;; A real bearer token under a non-count key still redacts.
      (is (string= "«redacted»"
                   (getf (getf (ourro.observe:log-event
                                :probe :args (list :access-token "opaque"))
                               :args)
                         :access-token))))))

(test credential-token-plurals-do-not-bypass-redaction
  (let ((ourro.observe::*recent-events* '())
        (ourro.observe::*event-log-path* nil))
    (let ((args (getf (ourro.observe:log-event
                       :probe :args (list :api-tokens "a" :access-tokens "b"
                                          "session-tokens" "c"))
                      :args)))
      (is (string= "«redacted»" (getf args :api-tokens)))
      (is (string= "«redacted»" (getf args :access-tokens)))
      (is (string= "«redacted»" (getf args "session-tokens"))))))

(test filter-by-kind
  (let ((ourro.observe::*recent-events* '())
        (ourro.observe::*event-log-path* nil))
    (ourro.observe:log-event :tool-call :tool "a")
    (ourro.observe:log-event :user-message :text "b")
    (ourro.observe:log-event :tool-call :tool "c")
    (is (= 2 (length (ourro.observe:recent-events :kind :tool-call))))))

(test timed-event-records-outcome
  (let ((ourro.observe::*recent-events* '())
        (ourro.observe::*event-log-path* nil))
    (ourro.observe:with-timed-event (:probe :label "x")
      (+ 1 1))
    (let ((event (first (ourro.observe:recent-events))))
      (is (eq :ok (getf event :outcome)))
      (is (integerp (getf event :elapsed-ms))))))

(test nested-timed-events-link-to-the-reserved-parent-identity
  (let ((ourro.observe::*recent-events* '())
        (ourro.observe::*event-log-path* nil))
    (ourro.observe:with-timed-event (:parent-operation :label "parent")
      (ourro.observe:with-timed-event (:child-operation :label "child")
        :done))
    (let* ((events (ourro.observe:recent-events :limit 2))
           (parent (find :parent-operation events :key (lambda (event)
                                                        (pget event :kind))))
           (child (find :child-operation events :key (lambda (event)
                                                       (pget event :kind)))))
      (is (string= (pget parent :trace-id) (pget child :trace-id)))
      (is (string= (pget parent :span-id) (pget child :parent-span-id)))
      (is (string= (pget parent :event-id) (pget child :causation-id)))
      (is (not (string= (pget parent :event-id)
                        (pget child :event-id)))))))
