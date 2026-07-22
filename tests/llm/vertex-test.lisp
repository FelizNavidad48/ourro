(in-package #:ourro.tests)

(def-suite vertex-suite :in ourro)
(in-suite vertex-suite)

(test json-helpers
  (let ((object (ourro.llm:json-object "a" 1 "b" "two")))
    (is (= 1 (ourro.llm:json-value object "a")))
    (is (string= "two" (ourro.llm:json-value object "b")))
    (is (eq :default (ourro.llm:json-value object "missing" :default)))))

(test message-constructors
  (let ((user (ourro.llm:user-message "hi")))
    (is (eq :user (ourro.llm:message-role user)))
    (is (string= "hi" (ourro.llm:message-content user)))))

(test assistant-text-and-calls
  (let ((message (ourro.llm:assistant-message
                  (list (list :type :text :text "hello ")
                        (list :type :text :text "world")
                        (list :type :tool-call :id "1" :name "read_file"
                              :args-json "{\"path\":\"x\"}")))))
    (is (string= "hello world" (ourro.llm:assistant-text message)))
    (is (= 1 (length (ourro.llm:assistant-tool-calls message))))
    (let ((call (first (ourro.llm:assistant-tool-calls message))))
      (is (string= "read_file" (ourro.llm:tool-call-name call)))
      (is (string= "x" (ourro.llm:json-value (ourro.llm:tool-call-args call)
                                            "path"))))))

(test scripted-provider-returns-in-order
  (let ((provider (ourro.llm:make-scripted-provider
                   (list "first" "second"))))
    (ourro.kernel:with-capabilities '(:llm)
      (is (string= "first" (ourro.llm:complete-text provider "sys" "u")))
      (is (string= "second" (ourro.llm:complete-text provider "sys" "u"))))))

(test complete-requires-llm-capability
  ;; Vertex COMPLETE checks the :llm capability before any network call.
  (let ((provider (make-instance 'ourro.llm:vertex-provider
                                 :model "gemini-3.1-pro-preview"
                                 :project "none")))
    (ourro.kernel:with-capabilities '()
      (signals ourro.kernel:capability-violation
        (ourro.llm:complete provider "s" (list (ourro.llm:user-message "x")) nil)))))


(test api-key-provider-uses-global-endpoint-and-key-header
  (let ((provider (make-instance 'ourro.llm:vertex-provider
                                 :model "gemini-3.1-pro-preview"
                                 :api-key "AIza-test-key")))
    ;; Global publisher endpoint — no project/location in the path.
    (let ((url (ourro.llm:vertex-request-url provider)))
      (is (search "/v1/publishers/google/models/gemini-3.1-pro-preview:streamGenerateContent" url))
      (is-false (search "/projects/" url)))
    ;; x-goog-api-key carries auth; no Authorization / quota header.
    (let ((headers (ourro.llm:vertex-request-headers provider)))
      (is (string= "AIza-test-key" (cdr (assoc "x-goog-api-key" headers :test #'string=))))
      (is-false (assoc "Authorization" headers :test #'string=))
      (is-false (assoc "x-goog-user-project" headers :test #'string=)))))

(test gemini-flavor-api-key-uses-developer-api-host
  ;; An AI Studio / Gemini Developer API key routes to generativelanguage, not
  ;; aiplatform — the x-goog-api-key header is shared with the vertex flavor.
  (let ((provider (make-instance 'ourro.llm:vertex-provider
                                 :model "gemini-3.1-pro-preview"
                                 :api-key "AIza-studio" :api-flavor :gemini)))
    (let ((url (ourro.llm:vertex-request-url provider)))
      (is (search "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-pro-preview:streamGenerateContent"
                  url))
      (is-false (search "aiplatform.googleapis.com" url)))
    (is (string= "AIza-studio"
                 (cdr (assoc "x-goog-api-key" (ourro.llm:vertex-request-headers provider)
                             :test #'string=))))))

(test adc-provider-uses-project-scoped-endpoint
  ;; No api-key → the project/location-scoped endpoint (headers not built here:
  ;; that branch would shell out to gcloud for a token).
  (let ((provider (make-instance 'ourro.llm:vertex-provider
                                 :model "gemini-3.1-pro-preview"
                                 :project "my-proj" :location "us-central1")))
    (is-false (ourro.llm:vertex-api-key provider))
    (let ((url (ourro.llm:vertex-request-url provider)))
      ;; Regional location → regional host (global would keep the bare host).
      (is (search "https://us-central1-aiplatform.googleapis.com/v1/projects/my-proj/locations/us-central1/publishers/google/models/gemini-3.1-pro-preview:streamGenerateContent"
                  url))))
  (let ((global (make-instance 'ourro.llm:vertex-provider
                               :model "m" :project "p" :location "global")))
    (is (search "https://aiplatform.googleapis.com/v1/projects/p/locations/global/"
                (ourro.llm:vertex-request-url global)))))

(test make-vertex-provider-reads-api-key-and-flavor-from-env
  ;; The env-var fallback actually wires through (GEMINI_API_KEY → key,
  ;; OURRO_GEMINI_API → :gemini flavor). Isolate every var the constructor reads
  ;; so an ambient key/project in the CI env can't skew the result; restore all.
  (let* ((vars '("OURRO_VERTEX_API_KEY" "GOOGLE_API_KEY" "GEMINI_API_KEY"
                 "OURRO_GEMINI_API" "OURRO_VERTEX_PROJECT"))
         (saved (mapcar #'uiop:getenv vars)))
    (unwind-protect
         (progn
           (dolist (v vars) (sb-posix:unsetenv v))
           (sb-posix:setenv "GEMINI_API_KEY" "AIza-from-env" 1)
           (sb-posix:setenv "OURRO_GEMINI_API" "studio" 1)
           (let ((provider (ourro.llm:make-vertex-provider)))
             (is (string= "AIza-from-env" (ourro.llm:vertex-api-key provider)))
             (is (eq :gemini (ourro.llm:vertex-api-flavor provider)))
             (is-false (ourro.llm:vertex-project provider))))
      (loop for v in vars for old in saved
            do (if old (sb-posix:setenv v old 1) (sb-posix:unsetenv v))))))

(test make-vertex-provider-with-api-key-needs-no-project
  ;; The whole point: an API key sidesteps gcloud/ADC and needs no project.
  (let ((provider (ourro.llm:make-vertex-provider :api-key "AIza-xyz")))
    (is (string= "AIza-xyz" (ourro.llm:vertex-api-key provider)))
    (is-false (ourro.llm:vertex-project provider))
    (is (search "/v1/publishers/google/models/" (ourro.llm:vertex-request-url provider)))))


(defclass flaky-provider (ourro.llm:provider)
  ((fails-left :initarg :fails-left :accessor flaky-fails-left)
   (retryable :initarg :retryable :initform t :accessor flaky-retryable)
   (attempts :initform 0 :accessor flaky-attempts))
  (:default-initargs :model "flaky"))

(defmethod ourro.llm:complete ((p flaky-provider) system messages tools
                              &key on-event)
  (declare (ignore system messages tools on-event))
  (incf (flaky-attempts p))
  (if (plusp (flaky-fails-left p))
      (progn (decf (flaky-fails-left p))
             (error 'ourro.llm:provider-error :message "429 busy"
                                             :retryable-p (flaky-retryable p)))
      (ourro.llm:assistant-message (list (list :type :text :text "ok")))))

(test retry-succeeds-after-transient-failures
  (let ((p (make-instance 'flaky-provider :fails-left 2))
        (retries '()))
    (let ((result (ourro.llm:complete-with-retry
                   p "s" (list (ourro.llm:user-message "x")) nil
                   :backoff (constantly 0)
                   :on-retry (lambda (n c) (declare (ignore c)) (push n retries)))))
      (is (string= "ok" (ourro.llm:assistant-text result)))
      (is (= 3 (flaky-attempts p)))          ; 2 failures + 1 success
      (is (equal '(2 3) (nreverse retries))))))  ; narrated the upcoming attempt

(test retry-gives-up-after-max-attempts
  (let ((p (make-instance 'flaky-provider :fails-left 10)))
    (signals ourro.llm:provider-error
      (ourro.llm:complete-with-retry p "s" (list (ourro.llm:user-message "x")) nil
                                    :backoff (constantly 0) :max-attempts 3))
    (is (= 3 (flaky-attempts p)))))

(test retry-does-not-retry-non-retryable
  (let ((p (make-instance 'flaky-provider :fails-left 10 :retryable nil)))
    (signals ourro.llm:provider-error
      (ourro.llm:complete-with-retry p "s" (list (ourro.llm:user-message "x")) nil
                                    :backoff (constantly 0)))
    (is (= 1 (flaky-attempts p)))))          ; one shot, no retry


(test parse-retry-after-reads-delta-seconds
  ;; hash-table headers (dexador's usual shape), lowercased keys
  (let ((h (make-hash-table :test 'equal)))
    (setf (gethash "retry-after" h) "7")
    (is (= 7 (ourro.llm::parse-retry-after h))))
  ;; alist headers, mixed-case key looked up case-insensitively
  (is (= 3 (ourro.llm::parse-retry-after '(("Retry-After" . "3")))))
  ;; an already-numeric value passes through
  (is (= 5 (ourro.llm::parse-retry-after '(("retry-after" . 5)))))
  ;; absent / non-numeric / HTTP-date form → NIL (fall back to backoff)
  (is-false (ourro.llm::parse-retry-after '(("content-type" . "application/json"))))
  (is-false (ourro.llm::parse-retry-after
             '(("retry-after" . "Wed, 21 Oct 2026 07:28:00 GMT"))))
  (is-false (ourro.llm::parse-retry-after nil)))

(test retry-sleep-prefers-retry-after-over-backoff
  ;; With a server hint the backoff policy is ignored…
  (let ((c (make-condition 'ourro.llm:provider-error :message "429"
                           :retryable-p t :retry-after 4)))
    (is (= 4 (ourro.llm::retry-sleep-seconds c 1 (constantly 99)))))
  ;; …but never above the cap.
  (let ((ourro.llm:*retry-backoff-cap* 30)
        (c (make-condition 'ourro.llm:provider-error :message "429"
                           :retryable-p t :retry-after 10000)))
    (is (= 30 (ourro.llm::retry-sleep-seconds c 1 (constantly 0)))))
  ;; With no hint it uses the backoff policy for the attempt.
  (let ((c (make-condition 'ourro.llm:provider-error :message "500"
                           :retryable-p t)))
    (is (= 42 (ourro.llm::retry-sleep-seconds c 3 (constantly 42))))))

(test default-backoff-is-capped
  (let ((ourro.llm:*retry-backoff-cap* 5))
    ;; attempt 10 is 2^9 ≈ 512s uncapped; the cap holds every sleep to ≤ 5.
    (is (<= (ourro.llm::default-retry-backoff 10) 5))))

(test retry-max-attempts-default-rides-out-a-longer-throttle
  ;; Four transient 429s in a row (was fatal under the old 3-attempt default)
  ;; now recover on the fifth attempt with the hardened default.
  (let ((p (make-instance 'flaky-provider :fails-left 4)))
    (is (string= "ok" (ourro.llm:assistant-text
                       (ourro.llm:complete-with-retry
                        p "s" (list (ourro.llm:user-message "x")) nil
                        :backoff (constantly 0)))))
    (is (= 5 (flaky-attempts p)))))


(test vertex-provider-has-a-stream-deadline
  ;; The provider carries a positive default budget (env OURRO_MAX_STREAM_SECONDS
  ;; can override it in make-vertex-provider).
  (let ((p (make-instance 'ourro.llm::vertex-provider)))
    (is (integerp (ourro.llm::vertex-stream-deadline-seconds p)))
    (is (plusp (ourro.llm::vertex-stream-deadline-seconds p)))))

(test stream-deadline-aborts-once-passed
  ;; A deadline already in the past trips on the first byte and signals the
  ;; dedicated condition — the bound a dribbling keep-alive stream would defeat.
  (signals ourro.llm::stream-deadline-exceeded
    (ourro.llm::stream-json-objects
     (make-string-input-stream "{\"a\":1}{\"b\":2}")
     (lambda (obj) (declare (ignore obj)))
     :deadline (1- (get-internal-real-time))
     :deadline-seconds 7))
  ;; A far-future deadline (and the default nil) never interferes: both objects
  ;; are delivered normally.
  (let ((seen 0))
    (ourro.llm::stream-json-objects
     (make-string-input-stream "{\"a\":1}{\"b\":2}")
     (lambda (obj) (declare (ignore obj)) (incf seen))
     :deadline (+ (get-internal-real-time)
                  (* 60 internal-time-units-per-second))
     :deadline-seconds 60)
    (is (= 2 seen)))
  (let ((seen 0))
    (ourro.llm::stream-json-objects
     (make-string-input-stream "{\"a\":1}")
     (lambda (obj) (declare (ignore obj)) (incf seen)))
    (is (= 1 seen))))
