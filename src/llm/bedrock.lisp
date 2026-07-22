
(in-package #:ourro.llm)


(defclass bedrock-provider (provider)
  ((api-key :initarg :api-key :initform nil :accessor bedrock-api-key
            :documentation "The Bedrock API key (a bearer token). Kept only in
this transient slot — never serialized to events or handoff state.")
   (region :initarg :region :initform "eu-north-1" :accessor bedrock-region)
   (max-output-tokens :initarg :max-output-tokens :initform 16384
                      :accessor bedrock-max-output-tokens)
   (timeout :initarg :timeout :initform 300 :accessor bedrock-timeout)
   (stream-p :initarg :stream-p :initform t :accessor bedrock-stream-p
             :documentation "Use the ConverseStream endpoint (token-by-token
deltas) with automatic fallback to non-streaming Converse on a decode failure.")
   (stream-deadline-seconds
    :initarg :stream-deadline-seconds :initform 600
    :accessor bedrock-stream-deadline-seconds
    :documentation "Overall wall-clock budget for one streamed turn — the same
F-llmwedge guard the Vertex path uses, checked between event-stream frames.")))

(defun make-bedrock-provider (&key api-key region model max-output-tokens)
  "Build a Bedrock provider. The API key (arg, OURRO_BEDROCK_API_KEY, or the
AWS-standard AWS_BEARER_TOKEN_BEDROCK) is required — there is no other auth path
here. The region is eu-north-1 (config :bedrock-region if you ever need another);
an explicit arg still wins. The model resolves arg → OURRO_MODEL and is required
(no default is baked in, so a stale model id can never be sent silently): set it
to a friendly alias (opus-4-6 / sonnet-4-6) or a raw Bedrock inference-profile id,
e.g. `global.anthropic.claude-opus-4-5-20251101-v1:0`. Max output tokens and the stream deadline
come from the config file (:max-tokens / :max-stream-seconds), the same knobs the
Vertex provider reads."
  (flet ((present (s) (and (stringp s) (plusp (length s)) s)))
    (let ((api-key (or (present api-key)
                       (present (getenv "OURRO_BEDROCK_API_KEY"))
                       (present (getenv "AWS_BEARER_TOKEN_BEDROCK"))))
          (region (or (present region)
                      (present (ourro.config:setting :bedrock-region))
                      "eu-north-1"))
          (model (or (present model) (present (getenv "OURRO_MODEL"))))
          (max-output-tokens (or max-output-tokens
                                 (positive-int (ourro.config:setting :max-tokens))
                                 16384))
          (stream-deadline-seconds
            (or (positive-int (ourro.config:setting :max-stream-seconds)) 600)))
      (unless api-key
        (error 'provider-error
               :message "No Bedrock API key. Set OURRO_BEDROCK_API_KEY (or AWS_BEARER_TOKEN_BEDROCK)."))
      (unless model
        (error 'provider-error
               :message "No Bedrock model. Set OURRO_MODEL to a model alias (opus-4-6 / sonnet-4-6 / haiku-4-5) or a Bedrock inference-profile id (e.g. global.anthropic.claude-opus-4-5-20251101-v1:0)."))
      (make-instance 'bedrock-provider
                     :model model :region region :api-key api-key
                     :max-output-tokens max-output-tokens
                     :stream-deadline-seconds stream-deadline-seconds))))

(defun bedrock-request-url (provider &optional (endpoint "converse"))
  "The regional Bedrock Runtime endpoint for this model — ENDPOINT is \"converse\"
or \"converse-stream\". Pure (no network), so the routing is unit-testable. The
inference-profile id is URL-path data (dots and a -v1 suffix and all), left
un-encoded — Bedrock accepts it."
  (format nil "https://bedrock-runtime.~A.amazonaws.com/model/~A/~A"
          (bedrock-region provider) (provider-model provider) endpoint))

(defun bedrock-request-headers (provider)
  "Auth + content headers: the API key as an Authorization bearer token, JSON
in and out. No SigV4, no aws CLI — the bearer token is the whole story."
  `(("Authorization" . ,(format nil "Bearer ~A" (bedrock-api-key provider)))
    ("Content-Type" . "application/json")
    ("Accept" . "application/json")))


(defun bedrock-assistant-block (block)
  "One canonical assistant block → a Converse content block, or NIL to drop.
An empty text block is dropped too — Converse rejects blank text content."
  (ecase (pget block :type)
    (:text (let ((text (pget block :text "")))
             (when (plusp (length text))
               (json-object "text" text))))
    ;; Thinking isn't echoed — the QA path runs without extended reasoning.
    (:thinking nil)
    (:tool-call
     (json-object "toolUse"
                  (json-object "toolUseId" (pget block :id)
                               "name" (pget block :name)
                               "input" (json-decode
                                        (or (pget block :args-json) "{}")))))))

(defun bedrock-tool-result-block (message)
  "A canonical :tool message → a Converse toolResult content block. The id echoes
the toolUse id (round-tripped through TOOL-CALL-ID), which pairs it with its call.
A legitimately empty tool output becomes \"(no output)\" — Converse rejects blank
text content."
  (json-object "toolResult"
               (json-object
                "toolUseId" (pget message :tool-call-id)
                "content" (vector (json-object
                                   "text" (let ((content (pget message :content)))
                                            (if (and (stringp content)
                                                     (plusp (length content)))
                                                content
                                                "(no output)"))))
                "status" (if (pget message :error-p) "error" "success"))))

(defun bedrock-serialize-messages (messages)
  "Canonical messages → the Converse `messages` array. Converse enforces strict
user/assistant alternation, so ADJACENT same-role turns are merged into one
content array: tool results ride a user turn (per the API), and a user message
that lands right after them — a cancelled tool batch, or a retry after a
provider error that never got an assistant reply — joins that same user turn
instead of opening a consecutive user turn Converse would reject with a
ValidationException. An assistant message whose blocks all drop (e.g. thinking
only) vanishes, and the merge also heals the user/user adjacency that leaves."
  (let ((turns '()))                    ; reversed ("role" . blocks-in-order)
    (flet ((emit (role blocks)
             (when blocks
               (let ((last (first turns)))
                 (if (and last (string= (car last) role))
                     (setf (cdr last) (append (cdr last) blocks))
                     (push (cons role (copy-list blocks)) turns))))))
      (dolist (message messages)
        (ecase (message-role message)
          (:user
           (let ((text (message-content message)))
             (emit "user" (when (and (stringp text) (plusp (length text)))
                            (list (json-object "text" text))))))
          (:assistant
           (emit "assistant" (remove nil (mapcar #'bedrock-assistant-block
                                                 (message-content message)))))
          (:tool
           (emit "user" (list (bedrock-tool-result-block message)))))))
    (arrayify (mapcar (lambda (turn)
                        (json-object "role" (car turn)
                                     "content" (arrayify (cdr turn))))
                      (nreverse turns)))))

(defun bedrock-cache-point ()
  "A Converse cachePoint block — marks the preceding content as a cacheable
prefix (prompt caching v1, M10-3)."
  (json-object "cachePoint" (json-object "type" "default")))

(defun bedrock-serialize-tools (tools)
  "OURRO.TOOLS (name description parameters-json-schema) triples → a Converse
toolConfig (each tool a toolSpec whose inputSchema wraps the JSON Schema). A
trailing cachePoint marks the whole tools block as a cacheable prefix so a
repeated turn re-reads the (large, byte-stable) tool schemas at the cache rate
rather than re-billing them (M10-3)."
  (json-object
   "tools"
   (arrayify (append (mapcar (lambda (tool)
                               (json-object "toolSpec"
                                            (json-object "name" (first tool)
                                                         "description" (second tool)
                                                         "inputSchema"
                                                         (json-object "json" (third tool)))))
                             tools)
                     (list (bedrock-cache-point))))))

(defun bedrock-serialize-request (provider system-prompt messages tools)
  "The full Bedrock Converse request body (a hash table). Pure, so it is
unit-testable without a network call."
  (let ((request (json-object
                  "messages" (bedrock-serialize-messages messages)
                  "inferenceConfig"
                  (json-object "maxTokens" (bedrock-max-output-tokens provider)))))
    (when (and system-prompt (plusp (length system-prompt)))
      ;; A cachePoint after the system text caches the system+tools prefix. The
      ;; system prompt is byte-stable (compose-system-prompt carries no volatile
      ;; state), so it re-reads at the cache rate every turn (M10-3).
      (setf (gethash "system" request)
            (vector (json-object "text" system-prompt) (bedrock-cache-point))))
    (when tools
      (setf (gethash "toolConfig" request) (bedrock-serialize-tools tools)))
    request))


(defun bedrock-part-to-block (part)
  "A Converse response content block → a canonical block, or NIL."
  (cond
    ((json-value part "text")
     (list :type :text :text (json-value part "text")))
    ((json-value part "toolUse")
     (let ((tu (json-value part "toolUse")))
       (list :type :tool-call
             :id (or (json-value tu "toolUseId") (make-id "call"))
             :name (json-value tu "name")
             :args-json (json-encode (or (json-value tu "input") (json-object))))))
    ((json-value part "reasoningContent")
     (list :type :thinking))
    (t nil)))

(defun bedrock-parse-usage (body)
  "Converse usage {inputTokens outputTokens totalTokens} → the canonical
token-usage plist the QA cost meter reads (:prompt/:candidates/:total-tokens)."
  (let ((usage (json-value body "usage")))
    (when (hash-table-p usage)
      (let ((in (or (json-value usage "inputTokens") 0))
            (out (or (json-value usage "outputTokens") 0)))
        (list :prompt-tokens in :candidates-tokens out
              :total-tokens (or (json-value usage "totalTokens") (+ in out))
              ;; Cache hit/write counts feed M11's honest cost meter (M10-3).
              :cache-read-tokens (or (json-value usage "cacheReadInputTokens") 0)
              :cache-write-tokens (or (json-value usage "cacheWriteInputTokens") 0))))))

(defun bedrock-parse-response (body)
  "A decoded Bedrock Converse response → a canonical assistant message. The
content lives at output.message.content; stopReason and usage are top-level."
  (let* ((output (json-value body "output"))
         (msg (and (hash-table-p output) (json-value output "message")))
         (content (and (hash-table-p msg) (json-value msg "content")))
         (blocks (when (vectorp content)
                   (loop for part across content
                         for block = (bedrock-part-to-block part)
                         when block collect block))))
    (assistant-message blocks
                       :stop-reason (or (json-value body "stopReason") "end_turn")
                       :usage (bedrock-parse-usage body))))


(defun bedrock-stream-message-from-events (provider read-bytes on-event)
  "Drive DECODE-EVENTSTREAM over READ-BYTES and assemble a canonical assistant
message. Emits :delta events for streamed text and a final :done."
  (let ((by-index (make-hash-table :test 'eql))  ; index → mutable block plist
        (order '())                               ; indices, first-seen order
        (text-acc (make-string-output-stream))
        (stop-reason nil)
        (usage nil)
        (deadline-seconds (bedrock-stream-deadline-seconds provider)))
    (flet ((block-at (index kind)
             (or (gethash index by-index)
                 (let ((b (list :type kind :text "" :args "" :id nil :name nil)))
                   (setf (gethash index by-index) b)
                   (push index order)
                   b))))
      (decode-eventstream
       read-bytes
       (lambda (event-type payload)
         (when (or (search "Exception" event-type :test #'char-equal)
                   (search "Error" event-type :test #'char-equal))
           (error 'eventstream-decode-error
                  :detail (format nil "Bedrock stream exception ~A: ~A"
                                  event-type payload)))
         (let ((json (json-decode payload)))
           (unless (hash-table-p json)
             (error 'eventstream-decode-error
                    :detail (format nil "Bedrock event ~A has invalid JSON" event-type)))
             (let ((index (or (json-value json "contentBlockIndex") 0)))
               (cond
                 ((string= event-type "contentBlockStart")
                  (let* ((start (json-value json "start"))
                         (tu (and (hash-table-p start) (json-value start "toolUse"))))
                    (when (hash-table-p tu)
                      (let ((b (block-at index :tool-call)))
                        (setf (getf b :id) (or (json-value tu "toolUseId") (make-id "call"))
                              (getf b :name) (json-value tu "name"))
                        (setf (gethash index by-index) b)))))
                 ((string= event-type "contentBlockDelta")
                  (let ((delta (json-value json "delta")))
                    (when (hash-table-p delta)
                      (let ((text (json-value delta "text"))
                            (tu (json-value delta "toolUse")))
                        (when (stringp text)
                          (let ((b (block-at index :text)))
                            (setf (getf b :text) (concatenate 'string (getf b :text) text))
                            (setf (gethash index by-index) b))
                          (write-string text text-acc)
                          (when on-event
                            (funcall on-event (list :kind :delta :text text))))
                        (when (hash-table-p tu)
                          (let ((frag (json-value tu "input"))
                                (b (block-at index :tool-call)))
                            (when (stringp frag)
                              (setf (getf b :args) (concatenate 'string (getf b :args) frag))
                              (setf (gethash index by-index) b))))))))
                 ((string= event-type "messageStop")
                  (setf stop-reason (or (json-value json "stopReason") stop-reason)))
                 ((string= event-type "metadata")
                  (let ((u (json-value json "usage")))
                    (when (hash-table-p u)
                      (let ((in (or (json-value u "inputTokens") 0))
                            (out (or (json-value u "outputTokens") 0)))
                        (setf usage
                              (list :prompt-tokens in :candidates-tokens out
                                    :total-tokens (or (json-value u "totalTokens")
                                                      (+ in out))
                                    :cache-read-tokens (or (json-value u "cacheReadInputTokens") 0)
                                    :cache-write-tokens (or (json-value u "cacheWriteInputTokens") 0)))))))))))
       :deadline (and deadline-seconds
                      (+ (get-internal-real-time)
                         (* deadline-seconds internal-time-units-per-second)))
      :deadline-seconds deadline-seconds)
      (unless stop-reason
        (error 'eventstream-decode-error
               :detail "Bedrock stream ended without messageStop/stopReason"))
      ;; Assemble blocks in contentBlockIndex order.
      (let ((blocks '()))
        (dolist (index (sort (copy-list order) #'<))
          (let* ((b (gethash index by-index))
                 (kind (getf b :type)))
            (cond
              ((and (eq kind :text) (plusp (length (getf b :text))))
               (push (list :type :text :text (getf b :text)) blocks))
              ((eq kind :tool-call)
               (let ((args (let ((a (getf b :args)))
                             (if (plusp (length a)) a "{}"))))
                 (unless (hash-table-p (ignore-errors (json-decode args)))
                   (error 'eventstream-decode-error
                          :detail (format nil "incomplete tool arguments for ~A"
                                          (getf b :name))))
                 (push (list :type :tool-call
                             :id (getf b :id) :name (getf b :name)
                             :args-json args)
                       blocks))))))
        (setf blocks (nreverse blocks))
        (when on-event
          (funcall on-event (list :kind :done :text (get-output-stream-string text-acc))))
        (assistant-message blocks
                           :stop-reason stop-reason
                           :usage usage)))))


(defun bedrock-signal-http-error (provider condition)
  "Turn a dexador HTTP failure into a PROVIDER-ERROR (shared by both endpoints)."
  (let ((status (dexador.error:response-status condition)))
    (error 'provider-error
           :message (format nil "Bedrock request failed (~A): ~A~@[~A~]"
                            status
                            (truncate-string
                             (http-error-body-string
                              (dexador.error:response-body condition))
                             2000)
                            (when (member status '(400 403 404))
                              (format nil "~% hint: this model id was rejected by your account/region. If a fresh build still fails, your account's inference-profile id differs from the built-in one — as a last resort set OURRO_MODEL=<exact id> (list yours with `aws bedrock list-inference-profiles`). Current model: ~A"
                                      (provider-model provider))))
           :status status
           :retry-after (parse-retry-after
                         (ignore-errors (dexador.error:response-headers condition)))
           :retryable-p (or (eql status 429)
                            (and (integerp status) (>= status 500))))))

(defun bedrock-converse (provider request on-event)
  "One non-streaming Converse call. A single :done event stands in for deltas."
  (handler-case
      (let* ((body (dexador:post
                    (bedrock-request-url provider "converse")
                    :headers (bedrock-request-headers provider)
                    :content (json-encode request)
                    :read-timeout (bedrock-timeout provider)
                    :connect-timeout 30
                    :force-binary nil))
             (message (bedrock-parse-response (json-decode body))))
        (when on-event
          (funcall on-event (list :kind :done :text (assistant-text message))))
        message)
    (dexador.error:http-request-failed (condition)
      (bedrock-signal-http-error provider condition))))

(defun bedrock-converse-stream (provider request on-event)
  "One ConverseStream call, decoded from AWS event-stream framing into a
canonical message with token-by-token :delta events."
  (handler-case
      (let ((stream (dexador:post
                     (bedrock-request-url provider "converse-stream")
                     :headers (bedrock-request-headers provider)
                     :content (json-encode request)
                     :read-timeout (bedrock-timeout provider)
                     :connect-timeout 30
                     :want-stream t
                     :force-binary t)))
        (unwind-protect
             ;; Once the stream is open, ANY read-side failure — a socket reset,
             ;; a read-timeout inside read-sequence, a chunked-transfer error —
             ;; must fall back to the non-streaming call, not lose the turn. Map
             ;; such errors to eventstream-decode-error (which COMPLETE's fallback
             ;; catches); let the already-meaningful decode/deadline conditions
             ;; propagate unchanged.
             (handler-case
                 (bedrock-stream-message-from-events
                  provider (make-stream-byte-reader stream) on-event)
               ((or eventstream-decode-error stream-deadline-exceeded) (c)
                 (error c))
               (error (c)
                 (error 'eventstream-decode-error
                        :detail (format nil "stream read failed: ~A" c))))
          (ignore-errors (close stream))))
    (dexador.error:http-request-failed (condition)
      (bedrock-signal-http-error provider condition))))

(defmethod complete ((provider bedrock-provider) system-prompt messages tools
                     &key on-event)
  (ourro.kernel:require-capability :llm 'complete)
  (let ((request (bedrock-serialize-request provider system-prompt messages tools)))
    (if (bedrock-stream-p provider)
        ;; Stream by default; a broken/undecodable stream (but NOT an HTTP error,
        ;; which propagates for retry) falls back to one non-streaming call so a
        ;; decode hiccup never loses a turn (M10-2).
        (handler-case (bedrock-converse-stream provider request on-event)
          ((or eventstream-decode-error stream-deadline-exceeded) (c)
            (declare (ignore c))
            (bedrock-converse provider request on-event)))
        (bedrock-converse provider request on-event))))


(defparameter *model-aliases*
  ;; :context-window (tokens) and :pricing (USD per 1e6 tokens; :in/:out/:cache-read)
  ;; feed M11's context gauge + honest cost meter. Additive keys — readers getf
  ;; and ignore what they don't know. Pricing is approximate/best-effort; the HUD
  ;; simply omits the $ when it is absent.
  '(("gemini-3.5-flash" :provider :vertex  :model "gemini-3.5-flash"
                        :context-window 1000000 :pricing (:in 0.3d0 :out 2.5d0 :cache-read 0.075d0))
    ("gemini-3.1-pro"   :provider :vertex  :model "gemini-3.1-pro-preview"
                        :context-window 1000000 :pricing (:in 2.0d0 :out 12.0d0 :cache-read 0.5d0))
    ;; The alias NAME is just a friendly label you type in OURRO_MODEL — the
    ;; `:model` is the real Bedrock inference-profile id it maps to (verified
    ;; live). The `4-6` and `4-5` names both resolve to the same working id, so
    ;; whichever you type just works; the id is an internal detail.
    ("opus-4-6"         :provider :bedrock :model "global.anthropic.claude-opus-4-5-20251101-v1:0"
                        :context-window 200000 :pricing (:in 5.0d0 :out 25.0d0 :cache-read 0.5d0))
    ("opus-4-5"         :provider :bedrock :model "global.anthropic.claude-opus-4-5-20251101-v1:0"
                        :context-window 200000 :pricing (:in 5.0d0 :out 25.0d0 :cache-read 0.5d0))
    ("opus"             :provider :bedrock :model "global.anthropic.claude-opus-4-5-20251101-v1:0"
                        :context-window 200000 :pricing (:in 5.0d0 :out 25.0d0 :cache-read 0.5d0))
    ("sonnet-4-6"       :provider :bedrock :model "global.anthropic.claude-sonnet-4-5-20250929-v1:0"
                        :context-window 200000 :pricing (:in 3.0d0 :out 15.0d0 :cache-read 0.3d0))
    ("sonnet-4-5"       :provider :bedrock :model "global.anthropic.claude-sonnet-4-5-20250929-v1:0"
                        :context-window 200000 :pricing (:in 3.0d0 :out 15.0d0 :cache-read 0.3d0))
    ("sonnet"           :provider :bedrock :model "global.anthropic.claude-sonnet-4-5-20250929-v1:0"
                        :context-window 200000 :pricing (:in 3.0d0 :out 15.0d0 :cache-read 0.3d0))
    ("haiku-4-5"        :provider :bedrock :model "global.anthropic.claude-haiku-4-5-20251001-v1:0"
                        :context-window 200000 :pricing (:in 1.0d0 :out 5.0d0 :cache-read 0.1d0))
    ("haiku"            :provider :bedrock :model "global.anthropic.claude-haiku-4-5-20251001-v1:0"
                        :context-window 200000 :pricing (:in 1.0d0 :out 5.0d0 :cache-read 0.1d0)))
  "The friendly model menu. Each entry maps an alias the user types (OURRO_MODEL,
QA --model, a scenario :model) to the provider that serves it and that provider's
concrete model / inference-profile id. ONE env var picks a model: OURRO_MODEL=<alias>.
The alias names are stable labels (opus-4-6 / sonnet-4-6 / opus / sonnet …); the
backend id they resolve to is an internal detail, kept correct here so you never
need a per-alias override. Bedrock ids use global inference profiles (verified
live against the eu-north-1 runtime; also valid from any region).")

(defparameter *canonical-model-menu*
  '("gemini-3.5-flash" "gemini-3.1-pro" "opus-4-6" "sonnet-4-6" "haiku-4-5")
  "The models to advertise (the short opus/sonnet/haiku forms are aliases of these).")

(defun available-models ()
  "The list of alias names to advertise, for help text and error messages."
  (copy-list *canonical-model-menu*))

(defun model-alias-entry (name)
  (and (stringp name) (assoc (trim name) *model-aliases* :test #'string-equal)))

(defun model-registry-entry-for-id (id)
  "The registry entry whose backend :model equals ID (a provider stores the
resolved id, not the alias), or NIL."
  (and (stringp id)
       (find id *model-aliases*
             :key (lambda (e) (getf (rest e) :model)) :test #'string-equal)))

(defun model-context-window (id)
  "The context window (tokens) for a backend model ID: the registry value, else
a by-shape fallback — gemini → 1,000,000, anything else (Claude et al.) → 200,000
(M11-1)."
  (let ((entry (model-registry-entry-for-id id)))
    (or (and entry (getf (rest entry) :context-window))
        (if (search "gemini" (string-downcase (or id ""))) 1000000 200000))))

(defun model-pricing (id)
  "USD-per-1e6-tokens pricing plist (:in :out :cache-read) for backend model ID,
or NIL when unknown (the HUD then omits the $)."
  (let ((entry (model-registry-entry-for-id id)))
    (and entry (getf (rest entry) :pricing))))

(defun alias-env-var (alias)
  "\"opus-4-6\" → \"OURRO_MODEL_OPUS_4_6\" — a LAST-RESORT per-alias id override.
The built-in ids are already correct, so this env var is not normally needed."
  (format nil "OURRO_MODEL_~A"
          (map 'string (lambda (c) (if (alphanumericp c) (char-upcase c) #\_)) alias)))

(defun alias-model-id (name)
  "The backend model id for a friendly NAME: a per-alias env override wins, then
the registry's id; a NAME that isn't a known alias passes through unchanged (so a
raw backend id or inference-profile id still works)."
  (let ((entry (model-alias-entry name)))
    (if entry
        (let ((present (lambda (s) (and (stringp s) (plusp (length s)) s))))
          (or (funcall present (getenv (alias-env-var (first entry))))
              (getf (rest entry) :model)))
        name)))

(defun resolve-model (name)
  "→ (values provider-keyword backend-model-id) for a friendly NAME. A known alias
resolves to its (provider, id); an unknown NAME is routed by shape — a `gemini…`
id to :vertex, an `…anthropic…`/`…claude…` id to :bedrock — and anything else
(including NIL) leaves the provider unresolved (NIL) for the caller's default."
  (let ((entry (model-alias-entry name)))
    (cond
      (entry (values (getf (rest entry) :provider) (alias-model-id name)))
      ((null name) (values nil nil))
      (t (let ((low (string-downcase (trim name))))
           (cond
             ((search "gemini" low) (values :vertex name))
             ((some (lambda (needle) (search needle low))
                    '("anthropic" "claude" "opus" "sonnet" "haiku"))
              (values :bedrock name))
             (t (values nil name))))))))


(defun provider-from-env (&key on-missing-live)
  "Select the live provider from the environment. Normally the *model* picks the
provider: OURRO_MODEL is resolved through *MODEL-ALIASES* (opus-4-6 → Bedrock,
gemini-3.1-pro → Vertex, a raw id routed by shape), so one knob chooses both.
OURRO_PROVIDER can still force the choice:
 - OURRO_PROVIDER=scripted:<path> → a deterministic file-backed scripted provider;
 - OURRO_PROVIDER=bedrock / aws / bedrock:<id> → force Bedrock;
 - OURRO_PROVIDER=vertex / gemini / google → force Vertex.
Either way OURRO_MODEL may be a friendly alias or a raw backend id; with neither
set, the config :default-model (opus-4-6 → Bedrock) is used. ON-MISSING-LIVE,
when given, replaces the live default — a seam for offline callers."
  (let* ((spec (getenv "OURRO_PROVIDER"))
         (model (or (and (stringp (getenv "OURRO_MODEL"))
                         (plusp (length (getenv "OURRO_MODEL")))
                         (getenv "OURRO_MODEL"))
                    (ourro.config:setting :default-model "opus-4-6"))))
    (flet ((down (s) (string-downcase (trim s))))
      (cond
        ((and (stringp spec) (eql 0 (search "scripted:" spec)))
         (make-scripted-provider-from-file (subseq spec (length "scripted:"))))
        ((and (stringp spec) (eql 0 (search "bedrock:" spec)))
         (make-bedrock-provider :model (alias-model-id (subseq spec (length "bedrock:")))))
        ((and (stringp spec) (plusp (length spec))
              (member (down spec) '("bedrock" "aws" "aws-bedrock") :test #'string=))
         (make-bedrock-provider :model (alias-model-id model)))
        ((and (stringp spec) (plusp (length spec))
              (member (down spec) '("vertex" "gemini" "google") :test #'string=))
         (make-vertex-provider :model (alias-model-id model)))
        (on-missing-live (funcall on-missing-live))
        (t (multiple-value-bind (provider model-id) (resolve-model model)
             (ecase (or provider :bedrock)
               (:vertex (make-vertex-provider :model model-id))
               (:bedrock (make-bedrock-provider :model model-id)))))))))
