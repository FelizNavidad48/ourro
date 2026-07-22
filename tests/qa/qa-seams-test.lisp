(in-package #:ourro.tests)


(def-suite qa-seams-suite :in ourro)
(in-suite qa-seams-suite)

(defmacro with-env ((&rest name/value-pairs) &body body)
  "Bind process env vars for BODY, restoring prior values (or clearing) after.
Used to prove the QA env overrides without leaking into other tests."
  (let ((saved (gensym "SAVED")))
    `(let ((,saved (mapcar (lambda (name) (cons name (uiop:getenv name)))
                           ',(loop for (n) on name/value-pairs by #'cddr
                                   collect n))))
       (unwind-protect
            (progn
              ,@(loop for (n v) on name/value-pairs by #'cddr
                      collect `(setf (uiop:getenv ,n) ,v))
              ,@body)
         (dolist (pair ,saved)
           (setf (uiop:getenv (car pair)) (or (cdr pair) "")))))))


(test config-overrides-thinking-and-tokens-model-via-env
  ;; The model is the one thing still chosen by env (OURRO_MODEL); thinking level
  ;; and max tokens are config settings now.
  (with-env ("OURRO_MODEL" "gemini-2.5-flash")
    (ourro.config:with-settings (:thinking-level "HIGH" :max-tokens 4096)
      (let ((provider (ourro.llm:make-vertex-provider :api-key "test-key")))
        (is (string= "gemini-2.5-flash" (ourro.llm:provider-model provider)))
        (is (string= "HIGH" (ourro.llm:vertex-thinking-level provider)))
        (is (= 4096 (ourro.llm:vertex-max-output-tokens provider)))))))

(test explicit-args-beat-config-and-env
  (with-env ("OURRO_MODEL" "gemini-2.5-flash")
    (ourro.config:with-settings (:max-tokens 4096)
      (let ((provider (ourro.llm:make-vertex-provider
                       :api-key "test-key" :model "gemini-3.1-pro-preview"
                       :max-output-tokens 8192)))
        (is (string= "gemini-3.1-pro-preview" (ourro.llm:provider-model provider)))
        (is (= 8192 (ourro.llm:vertex-max-output-tokens provider)))))))

(test model-default-stays-the-pro-model
  ;; No env, no arg → the pro model, so production behaviour is unchanged.
  (with-env ("OURRO_MODEL" "" "OURRO_MAX_TOKENS" "")
    (let ((provider (ourro.llm:make-vertex-provider :api-key "test-key")))
      (is (string= "gemini-3.1-pro-preview" (ourro.llm:provider-model provider)))
      (is (= 16384 (ourro.llm:vertex-max-output-tokens provider))))))

(test max-tokens-ignores-a-garbage-env
  (with-env ("OURRO_MAX_TOKENS" "not-a-number")
    (let ((provider (ourro.llm:make-vertex-provider :api-key "test-key")))
      (is (= 16384 (ourro.llm:vertex-max-output-tokens provider))))))

(test vertex-omits-thinking-level-for-non-gemini3-models
  ;; thinkingLevel is a Gemini-3 field; gemini-2.5-flash 400s on it, so it must
  ;; be omitted for that model but kept for a gemini-3 model.
  (ourro.config:with-settings (:thinking-level "LOW")
    (let ((flash (ourro.llm:make-vertex-provider :api-key "k" :model "gemini-2.5-flash"))
          (pro (ourro.llm:make-vertex-provider :api-key "k" :model "gemini-3.1-pro-preview")))
      (is (null (ourro.llm::effective-thinking-level flash)))
      (is (string= "LOW" (ourro.llm::effective-thinking-level pro))))))

(test vertex-thinking-level-off-omits-it
  (ourro.config:with-settings (:thinking-level "off")
    (let ((pro (ourro.llm:make-vertex-provider :api-key "k" :model "gemini-3.1-pro-preview")))
      (is (null (ourro.llm::effective-thinking-level pro))))))


(defun write-temp-script (contents)
  (let ((path (merge-pathnames (format nil "ourro-script-~A.sexp"
                                       (ourro.util:make-id "s"))
                               (uiop:temporary-directory))))
    (with-open-file (out path :direction :output :if-exists :supersede
                              :if-does-not-exist :create)
      (write-string contents out))
    path))

(test scripted-file-coerces-strings-and-tool-calls
  (let ((path (write-temp-script
               "\"hello there\"
(:text \"reading it\"
 :tool-calls ((:id \"c1\" :name \"list_files\" :args (:pattern \"*\"))))")))
    (unwind-protect
         (let ((provider (ourro.llm:make-scripted-provider-from-file path)))
           (ourro.kernel:with-capabilities '(:llm)
             (is (string= "hello there"
                          (ourro.llm:complete-text provider "sys" "u")))
             (let ((message (ourro.llm:complete provider "sys"
                                               (list (ourro.llm:user-message "u"))
                                               nil)))
               (is (string= "reading it" (ourro.llm:assistant-text message)))
               (let ((calls (ourro.llm:assistant-tool-calls message)))
                 (is (= 1 (length calls)))
                 (is (string= "list_files"
                              (ourro.llm:tool-call-name (first calls))))
                 (is (string= "*"
                              (ourro.llm:json-value
                               (ourro.llm:tool-call-args (first calls))
                               "pattern")))))))
      (ignore-errors (delete-file path)))))

(test scripted-file-loop-recycles-responses
  (let ((path (write-temp-script "(:loop t)
\"one\"
\"two\"")))
    (unwind-protect
         (let ((provider (ourro.llm:make-scripted-provider-from-file path)))
           (ourro.kernel:with-capabilities '(:llm)
             (is (string= "one" (ourro.llm:complete-text provider "s" "u")))
             (is (string= "two" (ourro.llm:complete-text provider "s" "u")))
             ;; Recycled rather than exhausted.
             (is (string= "one" (ourro.llm:complete-text provider "s" "u")))))
      (ignore-errors (delete-file path)))))

(test provider-from-env-selects-scripted
  (let ((path (write-temp-script "\"scripted answer\"")))
    (unwind-protect
         (with-env ("OURRO_PROVIDER" (format nil "scripted:~A" (namestring path)))
           (let ((provider (ourro.llm:provider-from-env)))
             (is (typep provider 'ourro.llm:scripted-provider))
             (ourro.kernel:with-capabilities '(:llm)
               (is (string= "scripted answer"
                            (ourro.llm:complete-text provider "s" "u"))))))
      (ignore-errors (delete-file path)))))


(test bedrock-resolves-key-region-and-model
  ;; Key comes from env (secret), model from OURRO_MODEL, max-tokens from config,
  ;; and the region defaults to eu-north-1 (config, no longer AWS_REGION/env).
  (with-env ("OURRO_BEDROCK_API_KEY" "bedrock-key"
             "OURRO_MODEL" "global.anthropic.claude-opus-4-5-v1:0")
    (ourro.config:with-settings (:max-tokens 8192)
      (let ((provider (ourro.llm:make-bedrock-provider)))
        (is (typep provider 'ourro.llm:bedrock-provider))
        (is (string= "bedrock-key" (ourro.llm::bedrock-api-key provider)))
        (is (string= "eu-north-1" (ourro.llm::bedrock-region provider)))
        (is (string= "global.anthropic.claude-opus-4-5-v1:0"
                     (ourro.llm:provider-model provider)))
        (is (= 8192 (ourro.llm::bedrock-max-output-tokens provider)))))))

(test bedrock-config-region-and-explicit-arg
  ;; The region is eu-north-1 by default; config :bedrock-region can change it,
  ;; and an explicit arg still wins over both.
  (with-env ("OURRO_BEDROCK_API_KEY" "env-key")
    (let ((default (ourro.llm:make-bedrock-provider
                    :model "global.anthropic.claude-sonnet-4-5-v1:0")))
      (is (string= "eu-north-1" (ourro.llm::bedrock-region default))))
    (ourro.config:with-settings (:bedrock-region "us-east-1")
      (let ((cfg (ourro.llm:make-bedrock-provider
                  :model "global.anthropic.claude-sonnet-4-5-v1:0"))
            (arg (ourro.llm:make-bedrock-provider
                  :region "eu-west-1"
                  :model "global.anthropic.claude-sonnet-4-5-v1:0")))
        (is (string= "us-east-1" (ourro.llm::bedrock-region cfg)))
        (is (string= "eu-west-1" (ourro.llm::bedrock-region arg)))))))

(test bedrock-honours-aws-standard-bearer-token-env
  (with-env ("OURRO_BEDROCK_API_KEY" "" "AWS_BEARER_TOKEN_BEDROCK" "aws-std-key")
    (let ((provider (ourro.llm:make-bedrock-provider
                     :model "global.anthropic.claude-opus-4-5-v1:0")))
      (is (string= "aws-std-key" (ourro.llm::bedrock-api-key provider))))))

(test bedrock-errors-without-key-or-model
  (with-env ("OURRO_BEDROCK_API_KEY" "" "AWS_BEARER_TOKEN_BEDROCK" ""
             "OURRO_MODEL" "")
    (signals ourro.llm:provider-error (ourro.llm:make-bedrock-provider)))
  (with-env ("OURRO_BEDROCK_API_KEY" "k" "OURRO_MODEL" "")
    (signals ourro.llm:provider-error (ourro.llm:make-bedrock-provider))))

(test bedrock-url-and-headers-use-bearer-auth
  (let ((provider (ourro.llm:make-bedrock-provider
                   :api-key "secret" :region "eu-north-1"
                   :model "eu.anthropic.claude-opus-4-5-v1")))
    (is (string= "https://bedrock-runtime.eu-north-1.amazonaws.com/model/eu.anthropic.claude-opus-4-5-v1/converse"
                 (ourro.llm:bedrock-request-url provider)))
    (let ((headers (ourro.llm:bedrock-request-headers provider)))
      (is (string= "Bearer secret" (cdr (assoc "Authorization" headers :test #'string=))))
      (is (string= "application/json"
                   (cdr (assoc "Content-Type" headers :test #'string=)))))))

(test bedrock-serializes-converse-request-shape
  ;; System + a user turn + an assistant toolUse + its toolResult → the Converse
  ;; body, with toolResult coalesced into a user turn.
  (let* ((provider (ourro.llm:make-bedrock-provider
                    :api-key "k" :model "m" :max-output-tokens 1234))
         (messages (list (ourro.llm:user-message "read the file")
                         (ourro.llm:assistant-message
                          (list (list :type :text :text "sure")
                                (list :type :tool-call :id "call-1"
                                      :name "read_file" :args-json "{\"path\":\"a.txt\"}")))
                         (ourro.llm:tool-result-message "call-1" "read_file" "file body")))
         (tools (list (list "read_file" "Read a file"
                            (ourro.llm:json-object "type" "object"))))
         (req (ourro.llm::bedrock-serialize-request provider "you are a tester"
                                                   messages tools)))
    (is (= 1234 (ourro.llm:json-value
                 (ourro.llm:json-value req "inferenceConfig") "maxTokens")))
    ;; system is an array: [0] the text block, [1] a cachePoint (M10-3)
    (let ((system (ourro.llm:json-value req "system")))
      (is (string= "you are a tester" (ourro.llm:json-value (aref system 0) "text")))
      (is (= 2 (length system)))
      (is-true (ourro.llm:json-value (aref system 1) "cachePoint")))
    ;; toolConfig.tools[0].toolSpec.{name,inputSchema.json}; a trailing cachePoint
    (let* ((tools-arr (ourro.llm:json-value
                       (ourro.llm:json-value req "toolConfig") "tools"))
           (spec (ourro.llm:json-value (aref tools-arr 0) "toolSpec")))
      (is (= 2 (length tools-arr)))
      (is (string= "read_file" (ourro.llm:json-value spec "name")))
      (is-true (ourro.llm:json-value (ourro.llm:json-value spec "inputSchema") "json"))
      ;; the cachePoint is the last tools entry
      (is-true (ourro.llm:json-value (aref tools-arr 1) "cachePoint")))
    (let ((msgs (ourro.llm:json-value req "messages")))
      ;; user text, assistant (text + toolUse), user (toolResult)
      (is (= 3 (length msgs)))
      (is (string= "read the file"
                   (ourro.llm:json-value
                    (aref (ourro.llm:json-value (aref msgs 0) "content") 0) "text")))
      (let* ((assistant (aref msgs 1))
             (blocks (ourro.llm:json-value assistant "content")))
        (is (string= "assistant" (ourro.llm:json-value assistant "role")))
        (is (string= "sure" (ourro.llm:json-value (aref blocks 0) "text")))
        (let ((tu (ourro.llm:json-value (aref blocks 1) "toolUse")))
          (is (string= "call-1" (ourro.llm:json-value tu "toolUseId")))
          (is (string= "read_file" (ourro.llm:json-value tu "name")))
          (is (string= "a.txt"
                       (ourro.llm:json-value (ourro.llm:json-value tu "input") "path")))))
      (let* ((tool-turn (aref msgs 2))
             (tr (ourro.llm:json-value
                  (aref (ourro.llm:json-value tool-turn "content") 0) "toolResult")))
        (is (string= "user" (ourro.llm:json-value tool-turn "role")))
        (is (string= "call-1" (ourro.llm:json-value tr "toolUseId")))
        (is (string= "success" (ourro.llm:json-value tr "status")))
        (is (string= "file body"
                     (ourro.llm:json-value
                      (aref (ourro.llm:json-value tr "content") 0) "text")))))))

(test bedrock-parses-converse-text-tooluse-and-usage
  (let* ((body (ourro.llm:json-decode
                "{\"output\":{\"message\":{\"role\":\"assistant\",\"content\":[
                    {\"text\":\"hello\"},
                    {\"toolUse\":{\"toolUseId\":\"tu-1\",\"name\":\"list_files\",
                                  \"input\":{\"pattern\":\"*\"}}}]}},
                  \"stopReason\":\"tool_use\",
                  \"usage\":{\"inputTokens\":12,\"outputTokens\":7,\"totalTokens\":19}}"))
         (message (ourro.llm::bedrock-parse-response body)))
    (is (string= "hello" (ourro.llm:assistant-text message)))
    (let ((calls (ourro.llm:assistant-tool-calls message)))
      (is (= 1 (length calls)))
      (is (string= "list_files" (ourro.llm:tool-call-name (first calls))))
      (is (string= "tu-1" (ourro.llm:tool-call-id (first calls)))))
    (let ((usage (ourro.llm:message-usage message)))
      (is (= 12 (getf usage :prompt-tokens)))
      (is (= 7 (getf usage :candidates-tokens)))
      (is (= 19 (getf usage :total-tokens))))))

(test bedrock-merges-adjacent-same-role-turns
  ;; Converse enforces strict user/assistant alternation. A cancelled tool batch
  ;; leaves [assistant(toolUse), tool-results] with the NEXT user text right
  ;; after — the serializer must fold that text into the same user turn as the
  ;; toolResults, not open a consecutive user turn Converse rejects with a
  ;; ValidationException (which would 400 every later turn of the session).
  (let* ((messages (list (ourro.llm:user-message "go")
                         (ourro.llm:assistant-message
                          (list (list :type :tool-call :id "c1" :name "list_files"
                                      :args-json "{}")))
                         (ourro.llm:tool-result-message "c1" "list_files"
                                                       "cancelled by user" :error-p t)
                         (ourro.llm:user-message "are you still there?")))
         (msgs (ourro.llm::bedrock-serialize-messages messages)))
    (is (= 3 (length msgs)))
    (is (equal '("user" "assistant" "user")
               (map 'list (lambda (m) (ourro.llm:json-value m "role")) msgs)))
    (let ((blocks (ourro.llm:json-value (aref msgs 2) "content")))
      (is (= 2 (length blocks)))
      (is-true (ourro.llm:json-value (aref blocks 0) "toolResult"))
      (is (string= "are you still there?"
                   (ourro.llm:json-value (aref blocks 1) "text"))))))

(test bedrock-merges-consecutive-user-messages
  ;; A provider error that never yielded an assistant reply leaves [user, user]:
  ;; both texts must ride ONE user turn.
  (let ((msgs (ourro.llm::bedrock-serialize-messages
               (list (ourro.llm:user-message "first try")
                     (ourro.llm:user-message "second try")))))
    (is (= 1 (length msgs)))
    (is (= 2 (length (ourro.llm:json-value (aref msgs 0) "content"))))))

(test bedrock-drops-blank-blocks-and-heals-adjacency
  ;; An assistant message of only thinking/empty-text blocks vanishes; the merge
  ;; heals the user/user adjacency that leaves. An empty tool output becomes a
  ;; placeholder — Converse rejects blank text content blocks.
  (let ((msgs (ourro.llm::bedrock-serialize-messages
               (list (ourro.llm:user-message "a")
                     (ourro.llm:assistant-message
                      (list (list :type :thinking) (list :type :text :text "")))
                     (ourro.llm:user-message "b")))))
    (is (= 1 (length msgs)))
    (is (= 2 (length (ourro.llm:json-value (aref msgs 0) "content")))))
  (let* ((msgs (ourro.llm::bedrock-serialize-messages
                (list (ourro.llm:user-message "go")
                      (ourro.llm:assistant-message
                       (list (list :type :tool-call :id "c1" :name "t" :args-json "{}")))
                      (ourro.llm:tool-result-message "c1" "t" ""))))
         (tr (ourro.llm:json-value
              (aref (ourro.llm:json-value (aref msgs 2) "content") 0) "toolResult")))
    (is (string= "(no output)"
                 (ourro.llm:json-value
                  (aref (ourro.llm:json-value tr "content") 0) "text")))))

(test provider-from-env-selects-bedrock
  (with-env ("OURRO_PROVIDER" "bedrock" "OURRO_BEDROCK_API_KEY" "k"
             "OURRO_MODEL" "eu.anthropic.claude-opus-4-5-v1")
    (is (typep (ourro.llm:provider-from-env) 'ourro.llm:bedrock-provider)))
  ;; bedrock:<model-id> carries the model in the spec verbatim.
  (with-env ("OURRO_PROVIDER" "bedrock:us.anthropic.claude-sonnet-4-5-v1"
             "OURRO_BEDROCK_API_KEY" "k" "OURRO_MODEL" "")
    (let ((provider (ourro.llm:provider-from-env)))
      (is (typep provider 'ourro.llm:bedrock-provider))
      (is (string= "us.anthropic.claude-sonnet-4-5-v1"
                   (ourro.llm:provider-model provider))))))


(test resolve-model-maps-aliases-to-provider-and-id
  (with-env ("OURRO_MODEL_OPUS_4_5" "" "OURRO_MODEL_SONNET_4_5" ""
             "OURRO_MODEL_GEMINI_3_1_PRO" "" "OURRO_MODEL_GEMINI_3_5_FLASH" "")
    (multiple-value-bind (p id) (ourro.llm:resolve-model "opus-4-5")
      (is (eq :bedrock p))
      (is-true (search "opus-4-5" id)))
    (multiple-value-bind (p id) (ourro.llm:resolve-model "sonnet-4-5")
      (is (eq :bedrock p))
      (is-true (search "sonnet-4-5" id)))
    (multiple-value-bind (p id) (ourro.llm:resolve-model "gemini-3.1-pro")
      (is (eq :vertex p))
      (is (string= "gemini-3.1-pro-preview" id)))
    (multiple-value-bind (p id) (ourro.llm:resolve-model "gemini-3.5-flash")
      (is (eq :vertex p))
      (is (string= "gemini-3.5-flash" id)))))

(test resolve-model-routes-raw-ids-by-shape
  (is (eq :vertex (ourro.llm:resolve-model "gemini-2.5-flash")))
  (is (eq :bedrock (ourro.llm:resolve-model "eu.anthropic.claude-opus-4-5-v1:0")))
  ;; Unknown / nil → provider unresolved, so the caller's default decides.
  (is (null (ourro.llm:resolve-model "something-odd")))
  (is (null (ourro.llm:resolve-model nil))))

(test resolve-model-honours-per-alias-env-override
  ;; The exact Bedrock inference-profile id can be corrected without editing code.
  (with-env ("OURRO_MODEL_OPUS_4_5" "eu.anthropic.claude-opus-4-5-20250930-v1:0")
    (multiple-value-bind (p id) (ourro.llm:resolve-model "opus-4-5")
      (is (eq :bedrock p))
      (is (string= "eu.anthropic.claude-opus-4-5-20250930-v1:0" id)))))

(test available-models-lists-the-menu
  (let ((menu (ourro.llm:available-models)))
    (dolist (m '("opus-4-6" "sonnet-4-6" "gemini-3.1-pro" "gemini-3.5-flash"))
      (is-true (member m menu :test #'string=)))))

(test model-aliases-4-6-and-4-5-names-both-resolve-to-a-working-id
  ;; The user types opus-4-6 / sonnet-4-6 (or the 4-5 names); each is a stable
  ;; label that maps to the real Bedrock inference-profile id. One env var only.
  (with-env ("OURRO_MODEL_OPUS_4_6" "" "OURRO_MODEL_SONNET_4_6" ""
             "OURRO_MODEL_OPUS_4_5" "" "OURRO_MODEL_SONNET_4_5" "")
    (dolist (alias '("opus-4-6" "opus-4-5" "opus"))
      (multiple-value-bind (p id) (ourro.llm:resolve-model alias)
        (is (eq :bedrock p))
        (is (string= "global.anthropic.claude-opus-4-5-20251101-v1:0" id))))
    (dolist (alias '("sonnet-4-6" "sonnet-4-5" "sonnet"))
      (multiple-value-bind (p id) (ourro.llm:resolve-model alias)
        (is (eq :bedrock p))
        (is (string= "global.anthropic.claude-sonnet-4-5-20250929-v1:0" id))))))

(test resolve-model-accepts-short-and-case-insensitive-claude-forms
  ;; A bare `opus` / `sonnet`, any case, and a raw claude id all route to Bedrock
  ;; (the fix for OURRO_MODEL=opus silently falling through to Vertex).
  (with-env ("OURRO_MODEL_OPUS" "" "OURRO_MODEL_SONNET" "")
    (multiple-value-bind (p id) (ourro.llm:resolve-model "opus")
      (is (eq :bedrock p))
      (is (string= "global.anthropic.claude-opus-4-5-20251101-v1:0" id)))
    (is (eq :bedrock (ourro.llm:resolve-model "sonnet")))
    (is (eq :bedrock (ourro.llm:resolve-model "OPUS")))
    (is (eq :bedrock (ourro.llm:resolve-model "us.anthropic.claude-opus-4-5-v1")))))

(test http-error-body-string-reads-streams-and-strings
  ;; A dexador :want-stream error body is a live stream; render it rather than
  ;; #<DECODING-STREAM> so the real provider error is visible.
  (is (string= "{\"message\":\"bad model\"}"
               (ourro.llm::http-error-body-string
                (make-string-input-stream "{\"message\":\"bad model\"}"))))
  (is (string= "" (ourro.llm::http-error-body-string nil)))
  (is (string= "plain error" (ourro.llm::http-error-body-string "plain error"))))

(test provider-from-env-infers-provider-from-model-alias
  ;; opus-4-5 → Bedrock, no OURRO_PROVIDER needed.
  (with-env ("OURRO_PROVIDER" "" "OURRO_MODEL" "opus-4-5"
             "OURRO_BEDROCK_API_KEY" "k" "OURRO_MODEL_OPUS_4_5" "")
    (let ((provider (ourro.llm:provider-from-env)))
      (is (typep provider 'ourro.llm:bedrock-provider))
      (is-true (search "opus-4-5" (ourro.llm:provider-model provider)))))
  ;; gemini-3.1-pro → Vertex, resolved to the concrete preview id.
  (with-env ("OURRO_PROVIDER" "" "OURRO_MODEL" "gemini-3.1-pro"
             "OURRO_VERTEX_API_KEY" "k")
    (let ((provider (ourro.llm:provider-from-env)))
      (is (typep provider 'ourro.llm:vertex-provider))
      (is (string= "gemini-3.1-pro-preview" (ourro.llm:provider-model provider))))))

(test provider-from-env-forced-provider-still-resolves-alias
  ;; OURRO_PROVIDER forces Bedrock; the opus-4-5 alias still maps to the real id.
  (with-env ("OURRO_PROVIDER" "bedrock" "OURRO_MODEL" "opus-4-5"
             "OURRO_BEDROCK_API_KEY" "k" "OURRO_MODEL_OPUS_4_5" "")
    (let ((provider (ourro.llm:provider-from-env)))
      (is (typep provider 'ourro.llm:bedrock-provider))
      (is-true (search "anthropic" (ourro.llm:provider-model provider))))))

(test provider-from-env-defaults-to-bedrock-opus-when-unset
  ;; No OURRO_MODEL, no OURRO_PROVIDER → the config :default-model (opus-4-5 →
  ;; Bedrock). Vertex is no longer the fallback.
  (with-env ("OURRO_PROVIDER" "" "OURRO_MODEL" "" "OURRO_BEDROCK_API_KEY" "k"
             "OURRO_MODEL_OPUS_4_5" "")
    (let ((provider (ourro.llm:provider-from-env)))
      (is (typep provider 'ourro.llm:bedrock-provider))
      (is-true (search "opus-4-5" (ourro.llm:provider-model provider)))))
  ;; config :default-model retargets the no-env default.
  (with-env ("OURRO_PROVIDER" "" "OURRO_MODEL" "" "OURRO_VERTEX_API_KEY" "k")
    (ourro.config:with-settings (:default-model "gemini-3.1-pro")
      (let ((provider (ourro.llm:provider-from-env)))
        (is (typep provider 'ourro.llm:vertex-provider))))))


(test llm-call-hook-fires-with-model-and-outcome
  (let* ((calls '())
         (ourro.llm:*llm-call-hook*
           (lambda (model ms usage error-p)
             (push (list model ms usage error-p) calls))))
    (let ((provider (ourro.llm:make-scripted-provider (list "hi"))))
      (ourro.kernel:with-capabilities '(:llm)
        (ourro.llm:complete-text provider "s" "u")))
    (is (= 1 (length calls)))
    (destructuring-bind (model ms usage error-p) (first calls)
      (declare (ignore usage))
      (is (string= "scripted" model))
      (is (integerp ms))
      (is (null error-p)))))

(test llm-call-hook-fires-error-p-on-failure
  (let* ((calls '())
         (ourro.llm:*llm-call-hook*
           (lambda (model ms usage error-p)
             (declare (ignore model ms usage))
             (push error-p calls))))
    ;; An empty scripted provider signals PROVIDER-ERROR on the first call.
    (let ((provider (ourro.llm:make-scripted-provider '())))
      (ourro.kernel:with-capabilities '(:llm)
        (ignore-errors (ourro.llm:complete-text provider "s" "u"))))
    (is (equal '(t) calls))))

(test message-usage-round-trips
  (let ((message (ourro.llm:assistant-message
                  (list (list :type :text :text "x"))
                  :usage (list :prompt-tokens 10 :candidates-tokens 5
                               :total-tokens 15))))
    (is (= 15 (getf (ourro.llm:message-usage message) :total-tokens)))))


(test qa-status-writes-payload-and-throttles
  (with-temp-home ()
    (let ((agent (make-test-agent))
          (ourro.agent::*qa-status-enabled* t)
          (ourro.agent::*qa-status-tick* 0)
          (ourro.agent::*qa-status-fields* nil)
          (ourro.agent::*qa-status-last-write* 0))
      (ourro.agent::write-qa-status agent)
      (let* ((path (ourro.util:ourro-path "state/qa-status.sexp"))
             (payload (with-open-file (in path :direction :input)
                        (read in))))
        (is (= 1 (getf payload :version)))
        (is (= 1 (getf payload :tick)))
        (is (string= "gen-0007" (getf payload :generation)))
        (is (null (getf payload :busy)))
        (is (eql 0 (getf payload :queue)))
        (is (eq t (getf payload :input-empty))))
      ;; No field changed and <1s elapsed → throttled, tick unchanged.
      (ourro.agent::write-qa-status agent)
      (is (= 1 ourro.agent::*qa-status-tick*))
      ;; A field change forces a fresh write even inside the throttle window.
      (setf (ourro.agent::agent-busy agent) t)
      (ourro.agent::write-qa-status agent)
      (is (= 2 ourro.agent::*qa-status-tick*)))))

(test qa-status-silent-when-disabled
  (with-temp-home ()
    (let ((agent (make-test-agent))
          (ourro.agent::*qa-status-enabled* nil)
          (ourro.agent::*qa-status-tick* 0))
      (ourro.agent::write-qa-status agent)
      (is (= 0 ourro.agent::*qa-status-tick*))
      (is (not (probe-file (ourro.util:ourro-path "state/qa-status.sexp")))))))


(defun write-temp-mission (contents)
  (let ((path (merge-pathnames
               (format nil "mission-~A.md" (ourro.util:make-id "m"))
               (uiop:temporary-directory))))
    (with-open-file (out path :direction :output
                              :if-exists :supersede :if-does-not-exist :create)
      (write-string contents out))
    (namestring path)))

(test mission-submits-once-then-marker-suppresses
  (with-temp-home ()
    (let ((path (write-temp-mission "  run the mission  ")))
      (with-env ("OURRO_MISSION" path)
        (let ((agent (make-test-agent)))
          (is-true (ourro.agent::maybe-submit-mission agent))
          ;; Trimmed contents land as the one pending submission.
          (is (equal '("run the mission")
                     (ourro.agent::agent-pending-submissions agent)))
          (is-true (probe-file (ourro.agent::mission-marker-path))))
        ;; A restarted process (same env, marker present) must not re-submit.
        (let ((again (make-test-agent)))
          (is-false (ourro.agent::maybe-submit-mission again))
          (is (null (ourro.agent::agent-pending-submissions again))))))))

(test mission-ignored-when-unset-missing-or-empty
  (with-temp-home ()
    ;; Env unset/blank → no mission.
    (with-env ("OURRO_MISSION" "")
      (is (null (ourro.agent::mission-text-to-submit))))
    ;; A dangling path must return NIL, not signal — a broken mission must
    ;; never take the agent down at boot.
    (with-env ("OURRO_MISSION" "/nonexistent/mission-file.md")
      (is (null (ourro.agent::mission-text-to-submit))))
    ;; Whitespace-only contents are not a mission.
    (let ((path (write-temp-mission "   ")))
      (with-env ("OURRO_MISSION" path)
        (is (null (ourro.agent::mission-text-to-submit)))))))
