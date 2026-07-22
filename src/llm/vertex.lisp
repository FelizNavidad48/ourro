
(in-package #:ourro.llm)

(define-condition provider-error (error)
  ((message :initarg :message :reader provider-error-message)
   (status :initarg :status :initform nil :reader provider-error-status)
   (retryable-p :initarg :retryable-p :initform nil
                :reader provider-error-retryable-p)
   (retry-after :initarg :retry-after :initform nil
                :reader provider-error-retry-after
                :documentation "Seconds the server asked us to wait (its
Retry-After header, when it sent one), or NIL. COMPLETE-WITH-RETRY prefers this
over its own backoff so a throttling 429 is honoured on the server's timescale."))
  (:report (lambda (c stream) (format stream "~A" (provider-error-message c)))))

(define-condition configuration-error (provider-error) ()
  (:documentation "A provider could not be built because the environment is
misconfigured — a missing API key or model, a missing GCP project, etc. This is
a user-fixable setup problem, NOT a transient failure or a code defect. The boot
path exits with a distinct code so the supervisor surfaces it and stops, rather
than treating a mis-set env var as a crashing generation and quarantining it
(which would brick the home). Subclasses provider-error, so existing
provider-error handlers still catch it; it is never retryable."))

(defclass provider ()
  ((model :initarg :model :accessor provider-model)))

(defgeneric complete (provider system-prompt messages tools &key on-event)
  (:documentation "Run one model turn. MESSAGES are canonical message
plists; TOOLS are OURRO.TOOLS tool objects (or NIL). ON-EVENT receives
(:kind :delta :text …) events during streaming. Returns an assistant
message plist."))

(defun complete-text (provider system-prompt user-text &key on-event)
  "Convenience for the evolver role: single-shot, no tools, returns the
assistant's text."
  (assistant-text
   (complete provider system-prompt (list (user-message user-text)) nil
             :on-event on-event)))

(defvar *llm-call-context* :foreground
  "Which channel the current model call belongs to (M15-4): :foreground (a user
turn — already costed by RECORD-TURN-USAGE) or :background (evolver, dreamer,
investigator, summarizer). Background workers BIND this to :background so the
call hook can add their spend to the session cost without double-counting the
user turn. Thread-local (a plain special), so each worker's binding is its own.")

(defvar *llm-call-hook* nil
  "Optional (function MODEL ELAPSED-MS USAGE ERROR-P) run after every COMPLETE
call — every model turn, evolver call, and onboarding probe alike, since it is
an :AROUND on the base PROVIDER method (QA-0). USAGE is the returned message's
token-usage plist (or NIL). Zero behaviour when unset; WIRE-OBSERVER installs a
handler that logs an :llm-call event for the QA perf/cost meter. Kept a plain
hook so the LLM layer needs no OBSERVE dependency.")

(defmethod complete :around ((provider provider) system-prompt messages tools
                             &key on-event)
  "Time every model turn and fire *LLM-CALL-HOOK*. Wrapped in IGNORE-ERRORS so a
misbehaving meter can never break a real turn; the hook still fires (with
ERROR-P T) when the underlying COMPLETE signals, so failed/retried calls are
observable too."
  (declare (ignore system-prompt messages tools on-event))
  (let ((start (get-internal-real-time))
        (result nil)
        (error-p t))
    (unwind-protect
         (progn (setf result (call-next-method) error-p nil) result)
      (when *llm-call-hook*
        (ignore-errors
         (funcall *llm-call-hook*
                  (ignore-errors (provider-model provider))
                  (round (* 1000 (- (get-internal-real-time) start))
                         internal-time-units-per-second)
                  (and result (message-usage result))
                  error-p))))))

(defvar *retry-max-attempts* 5
  "Fallback total attempts (first try included) COMPLETE-WITH-RETRY makes when
the config :retry-max-attempts is unset. Five gives roughly a ~1+2+4+8s ride-out
window — enough to sit out a short Bedrock/Vertex throttling burst (429) without
losing the turn. Tests bind this directly; config :retry-max-attempts wins in
production. Raise it (config) if your Bedrock account throttles hard.")

(defvar *retry-backoff-cap* 30
  "Fallback ceiling, in seconds, on any single retry sleep (config
:retry-backoff-cap wins) — so neither a deep exponential step nor a large server
Retry-After can stall the UI for an unbounded time.")

(defun retry-max-attempts ()
  (or (positive-int (ourro.config:setting :retry-max-attempts)) *retry-max-attempts*))

(defun retry-backoff-cap ()
  (or (positive-int (ourro.config:setting :retry-backoff-cap)) *retry-backoff-cap*))

(defun default-retry-backoff (attempt)
  "Exponential backoff with jitter, seconds, for a 1-based ATTEMPT: ~1, 2, 4, 8,
16, each capped at the retry backoff cap."
  (min (retry-backoff-cap) (+ (ash 1 (1- attempt)) (random 1.0))))

(defun retry-sleep-seconds (condition attempt backoff)
  "How long COMPLETE-WITH-RETRY waits before its next attempt: honour a server
Retry-After hint when the provider surfaced one (a throttling 429 sometimes
carries it), capped at the retry backoff cap; otherwise fall back to the BACKOFF
policy for ATTEMPT."
  (let ((hint (and (typep condition 'provider-error)
                   (provider-error-retry-after condition))))
    (if (and (realp hint) (plusp hint))
        (min (retry-backoff-cap) hint)
        (funcall backoff attempt))))

(defun complete-with-retry (provider system-prompt messages tools
                            &key on-event on-retry
                                 (max-attempts (retry-max-attempts))
                                 (backoff #'default-retry-backoff))
  "Like COMPLETE, but transparently retries a *retryable* provider-error
(HTTP 429 / 5xx — see PROVIDER-ERROR-RETRYABLE-P, computed at the boundary
but until now never consumed) with exponential backoff, preferring a server
Retry-After hint when one was sent. ON-RETRY, when given, is called as
(fn next-attempt condition) before each sleep, so a caller can surface
\"provider busy — retrying (2/5)…\". A non-retryable error, or exhausting
MAX-ATTEMPTS, re-signals. The retry policy is trusted code here, not a gene —
the interactive path stays deterministic aside from the sleep."
  (loop for attempt from 1
        do (handler-case
               (return (complete provider system-prompt messages tools
                                 :on-event on-event))
             (provider-error (c)
               (if (and (provider-error-retryable-p c) (< attempt max-attempts))
                   (progn
                     (when on-retry (funcall on-retry (1+ attempt) c))
                     (sleep (retry-sleep-seconds c attempt backoff)))
                   (error c))))))


(defclass vertex-provider (provider)
  ((project :initarg :project :initform nil :accessor vertex-project)
   (api-key :initarg :api-key :initform nil :accessor vertex-api-key
            :documentation "When set, authenticate with x-goog-api-key instead of
an ADC bearer token. Kept only in this transient slot — never serialized to
events or handoff state.")
   (api-flavor :initarg :api-flavor :initform :vertex :accessor vertex-api-flavor
               :documentation "Which API surface an API key targets: :vertex
(aiplatform.googleapis.com express endpoint — the default, for a Vertex key) or
:gemini (generativelanguage.googleapis.com — for an AI Studio / Gemini Developer
API key). Ignored on the ADC path.")
   (location :initarg :location :initform "global" :accessor vertex-location)
   (thinking-level :initarg :thinking-level :initform "LOW"
                   :accessor vertex-thinking-level)
   (max-output-tokens :initarg :max-output-tokens :initform 16384
                      :accessor vertex-max-output-tokens)
   (timeout :initarg :timeout :initform 300 :accessor vertex-timeout)
   (stream-deadline-seconds
    :initarg :stream-deadline-seconds :initform 600
    :accessor vertex-stream-deadline-seconds
    :documentation "Overall wall-clock budget for one streamed model turn. The
dexador :read-timeout is per-socket-read, so a stream that dribbles keep-alive
bytes resets it forever and never bounds total time (F-llmwedge). This caps the
whole read loop; on expiry COMPLETE signals a clear provider-error and the turn
ends instead of hanging. Config override: :max-stream-seconds.")
   (token :initform nil :accessor vertex-token)
   (token-expiry :initform 0 :accessor vertex-token-expiry)
   (token-lock :initform (bt:make-lock "vertex-token")
               :reader vertex-token-lock)))

(defvar *default-provider* nil)

(defun resolve-api-flavor (flavor)
  "Normalize an explicit FLAVOR arg or the OURRO_GEMINI_API env var into :vertex
(the default) or :gemini (the AI Studio / Gemini Developer API surface)."
  (let ((raw (string-downcase
              (or (and flavor (string flavor)) (getenv "OURRO_GEMINI_API") ""))))
    (if (member raw '("gemini" "studio" "aistudio" "ai-studio" "developer"
                      "generativelanguage")
                :test #'string=)
        :gemini
        :vertex)))

(defun parse-positive-int (string)
  "Parse STRING as a positive integer, or NIL if it isn't one — for env vars."
  (and (stringp string)
       (let ((n (ignore-errors (parse-integer (trim string)))))
         (and (integerp n) (plusp n) n))))

(defun positive-int (value)
  "Coerce a config VALUE (already an integer, or a string, or NIL) to a positive
integer, else NIL. Config values arrive parsed, so the integer path is the norm."
  (cond ((and (integerp value) (plusp value)) value)
        ((stringp value) (parse-positive-int value))
        (t nil)))

(defun make-vertex-provider (&key project api-key api-flavor
                                  model location thinking-level max-output-tokens)
  "Build a Vertex provider. An API key (arg or OURRO_VERTEX_API_KEY /
GOOGLE_API_KEY / GEMINI_API_KEY) takes precedence and needs no GCP project or
gcloud at all; otherwise a project is required (arg, OURRO_VERTEX_PROJECT, or the
gcloud default) for the ADC bearer-token path. An API key defaults to the Vertex
express endpoint; set OURRO_GEMINI_API=studio (or :api-flavor :gemini) for an AI
Studio key. The model comes from OURRO_MODEL (the one env knob for model choice);
thinking level, max output tokens, and the stream deadline come from the config
file (:thinking-level / :max-tokens / :max-stream-seconds — see ourro.config), so
they retarget every generation without a code change. An explicit arg still wins
over both, and the model default stays the pro model."
  (flet ((present (s) (and (stringp s) (plusp (length s)) s)))
    (let ((api-key (or (present api-key)
                       (present (getenv "OURRO_VERTEX_API_KEY"))
                       (present (getenv "GOOGLE_API_KEY"))
                       (present (getenv "GEMINI_API_KEY"))))
          (model (or (present model) (present (getenv "OURRO_MODEL"))
                     "gemini-3.1-pro-preview"))
          (location (or (present location) "global"))
          (thinking-level (or (present thinking-level)
                              (present (ourro.config:setting :thinking-level))
                              "LOW"))
          (max-output-tokens (or max-output-tokens
                                 (positive-int (ourro.config:setting :max-tokens))
                                 16384))
          (stream-deadline-seconds
            (or (positive-int (ourro.config:setting :max-stream-seconds)) 600)))
      (make-instance 'vertex-provider
                     :model model :location location
                     :thinking-level thinking-level
                     :max-output-tokens max-output-tokens
                     :stream-deadline-seconds stream-deadline-seconds
                     :api-key api-key
                     :api-flavor (resolve-api-flavor api-flavor)
                     ;; With an API key the key carries the project binding, so
                     ;; we never shell out to gcloud; project stays optional.
                     :project (cond ((present project) project)
                                    ((present (getenv "OURRO_VERTEX_PROJECT"))
                                     (getenv "OURRO_VERTEX_PROJECT"))
                                    (api-key nil)
                                    ((discover-gcloud-project))
                                    (t (error 'configuration-error
                                              :message "No GCP project. Set OURRO_VERTEX_PROJECT or gcloud config, or provide an API key via OURRO_VERTEX_API_KEY.")))))))

(defun configure-default-provider (&rest args)
  (setf *default-provider* (apply #'make-vertex-provider args)))

(defun gcloud (&rest args)
  (handler-case
      (trim (with-output-to-string (out)
              (uiop:run-program (append '("gcloud") args '("--quiet"))
                                :output out :error-output nil)))
    (error (c)
      (error 'provider-error
             :message (format nil "gcloud failed (~A). Run: gcloud auth application-default login" c)))))

(defun discover-gcloud-project ()
  (handler-case
      (let ((value (gcloud "config" "get-value" "project")))
        (unless (or (zerop (length value)) (string= value "(unset)"))
          value))
    (provider-error () nil)))

(defun access-token (provider)
  "ADC access token, cached for 45 minutes."
  (bt:with-lock-held ((vertex-token-lock provider))
    (when (or (null (vertex-token provider))
              (> (get-universal-time) (vertex-token-expiry provider)))
      (setf (vertex-token provider)
            (gcloud "auth" "application-default" "print-access-token")
            (vertex-token-expiry provider)
            (+ (get-universal-time) (* 45 60)))
      (when (zerop (length (vertex-token provider)))
        (setf (vertex-token provider) nil)
        (error 'provider-error
               :message "ADC returned no token. Run: gcloud auth application-default login")))
    (vertex-token provider)))

(defun vertex-host (location)
  "Vertex's global endpoint serves LOCATION \"global\"; every other (regional)
location is served by its own <location>-prefixed host."
  (if (string= location "global")
      "aiplatform.googleapis.com"
      (format nil "~A-aiplatform.googleapis.com" location)))

(defun vertex-request-url (provider)
  "The :streamGenerateContent endpoint. Three routings, all pure (no network),
so the auth-mode selection is unit-testable:
 - API key, :vertex flavor → Vertex's global publisher endpoint (no
   project/location in the path — the key carries the project binding);
 - API key, :gemini flavor → the AI Studio / Gemini Developer API host;
 - ADC → the project/location-scoped Vertex endpoint (regional host when the
   location isn't \"global\")."
  (cond
    ((and (vertex-api-key provider) (eq (vertex-api-flavor provider) :gemini))
     (format nil "https://generativelanguage.googleapis.com/v1beta/models/~A:streamGenerateContent"
             (provider-model provider)))
    ((vertex-api-key provider)
     (format nil "https://aiplatform.googleapis.com/v1/publishers/google/models/~A:streamGenerateContent"
             (provider-model provider)))
    (t
     (format nil "https://~A/v1/projects/~A/locations/~A/publishers/google/models/~A:streamGenerateContent"
             (vertex-host (vertex-location provider))
             (vertex-project provider)
             (vertex-location provider)
             (provider-model provider)))))

(defun vertex-request-headers (provider)
  "Auth + content headers for the request. An API key → x-goog-api-key (no
gcloud, no quota header); otherwise a fresh ADC bearer token plus the
user-project quota header. The ADC branch calls ACCESS-TOKEN (which may shell
out to gcloud); the API-key branch never does."
  (if (vertex-api-key provider)
      `(("x-goog-api-key" . ,(vertex-api-key provider))
        ("Content-Type" . "application/json"))
      `(("Authorization" . ,(format nil "Bearer ~A" (access-token provider)))
        ("x-goog-user-project" . ,(vertex-project provider))
        ("Content-Type" . "application/json"))))


(defun provider-data-part (block)
  "Reparse the raw provider JSON kept on BLOCK, if any."
  (let ((raw (pget block :provider-data)))
    (and raw (stringp raw) (plusp (length raw))
         (ignore-errors (json-decode raw)))))

(defun assistant-block-part (block)
  (or (provider-data-part block)
      (ecase (pget block :type)
        (:text (json-object "text" (pget block :text "")))
        (:thinking nil)
        (:tool-call
         (json-object "functionCall"
                      (json-object "name" (pget block :name)
                                   "args" (json-decode
                                           (or (pget block :args-json) "{}"))))))))

(defun serialize-messages (messages)
  (let ((contents '())
        (pending-tool-parts '()))
    (flet ((flush-tool-parts ()
             (when pending-tool-parts
               (push (json-object "role" "user"
                                  "parts" (arrayify (nreverse pending-tool-parts)))
                     contents)
               (setf pending-tool-parts '()))))
      (dolist (message messages)
        (ecase (message-role message)
          (:user
           (flush-tool-parts)
           (push (json-object
                  "role" "user"
                  "parts" (vector (json-object "text" (message-content message))))
                 contents))
          (:assistant
           (flush-tool-parts)
           (let ((parts (remove nil (mapcar #'assistant-block-part
                                            (message-content message)))))
             (when parts
               (push (json-object "role" "model" "parts" (arrayify parts))
                     contents))))
          (:tool
           (push (json-object
                  "functionResponse"
                  (json-object
                   "name" (pget message :name)
                   "response" (json-object
                               (if (pget message :error-p) "error" "output")
                               (pget message :content ""))))
                 pending-tool-parts))))
      (flush-tool-parts))
    (arrayify (nreverse contents))))

(defun serialize-tool-declarations (tools)
  "TOOLS is a list of (name description parameters-json-schema) triples
provided by OURRO.TOOLS (kept decoupled: the LLM layer knows no tool class)."
  (if tools
      (vector (json-object "functionDeclarations"
                           (arrayify
                            (mapcar (lambda (tool)
                                      (json-object "name" (first tool)
                                                   "description" (second tool)
                                                   "parameters" (third tool)))
                                    tools))))
      #()))


(defun part-to-block (part)
  "Convert a Gemini response part into a canonical block, keeping the raw
JSON for byte-faithful echo."
  (let ((raw (json-encode part))
        (text (json-value part "text"))
        (function-call (json-value part "functionCall")))
    (cond
      (function-call
       (list :type :tool-call
             :id (or (json-value function-call "id") (make-id "call"))
             :name (json-value function-call "name")
             :args-json (json-encode (or (json-value function-call "args")
                                         (json-object)))
             :provider-data raw))
      ((eq (json-value part "thought") t)
       (list :type :thinking :provider-data raw))
      (text
       (list :type :text :text text :provider-data raw))
      (t nil))))

(define-condition stream-deadline-exceeded (error)
  ((seconds :initarg :seconds :initform nil :reader stream-deadline-exceeded-seconds))
  (:report (lambda (c s)
             (format s "stream deadline exceeded~@[ (~A s)~]"
                     (stream-deadline-exceeded-seconds c))))
  (:documentation "Signalled by STREAM-JSON-OBJECTS when DEADLINE passes — a
stream that dribbles bytes never trips the per-read socket timeout, so this is
the only bound on total wall time (F-llmwedge). COMPLETE converts it to a
provider-error."))

(defun stream-json-objects (stream on-object &key deadline deadline-seconds)
  "Extract complete top-level JSON objects from STREAM by brace matching
(Vertex streams a JSON array of chunks) and call ON-OBJECT on each. When
DEADLINE (an internal-real-time instant) is given, abort with
STREAM-DEADLINE-EXCEEDED once the clock passes it — the per-read socket timeout
cannot bound a stream that keeps dribbling keep-alive bytes, so this caps total
wall time. The check runs each time READ-CHAR returns (a dribbling stall still
iterates here), so a stall is caught within one byte-interval of the deadline;
a FULL stall with zero bytes is still bounded by the socket read-timeout."
  (loop with collecting = nil
        with buffer = (make-string-output-stream)
        with depth = 0
        with in-string = nil
        with escaped = nil
        for char = (read-char stream nil nil)
        while char
        do (when (and deadline (> (get-internal-real-time) deadline))
             (error 'stream-deadline-exceeded :seconds deadline-seconds))
           (cond
             (escaped
              (setf escaped nil)
              (when collecting (write-char char buffer)))
             ((and collecting in-string (char= char #\\))
              (setf escaped t)
              (write-char char buffer))
             ((char= char #\")
              (when collecting (write-char char buffer))
              (when collecting (setf in-string (not in-string))))
             (in-string
              (when collecting (write-char char buffer)))
             ((char= char #\{)
              (setf collecting t)
              (write-char char buffer)
              (incf depth))
             ((and collecting (char= char #\}))
              (write-char char buffer)
              (decf depth)
              (when (zerop depth)
                (let ((text (get-output-stream-string buffer)))
                  (setf collecting nil in-string nil)
                  ;; Malformed provider data is a protocol failure. Swallowing
                  ;; it can turn a truncated function call into a successful
                  ;; partial response.
                  (funcall on-object (json-decode text)))))
             (collecting (write-char char buffer)))
        finally
           (when (or collecting in-string (plusp depth))
             (error "Vertex stream ended inside an unfinished JSON object"))))

(defun http-error-body-string (body)
  "Coerce a dexador error body into a readable string. With :want-stream the body
is a live stream (which PRINC-TO-STRING renders uselessly as #<DECODING-STREAM>),
so read it out; an octet vector is decoded, a string passes through. Best-effort:
never signals, so error reporting itself can't fail a turn."
  (handler-case
      (cond
        ((null body) "")
        ((stringp body) body)
        ((streamp body)
         (if (subtypep (stream-element-type body) 'character)
             (with-output-to-string (out)
               (loop for c = (read-char body nil nil) while c do (write-char c out)))
             (with-output-to-string (out)
               (loop for b = (read-byte body nil nil) while b
                     do (write-char (code-char b) out)))))
        ((and (vectorp body) (not (stringp body)))
         (map 'string (lambda (b) (code-char (logand b 255))) body))
        (t (princ-to-string body)))
    (error () (princ-to-string body))))

(defun http-header-value (headers name)
  "Case-insensitive lookup of header NAME in a dexador response-headers object
(a hash-table of lowercased keys, or an alist), or NIL. Best-effort — never
signals, so it is safe to call inside an error handler."
  (handler-case
      (when headers
        (let ((key (string-downcase name)))
          (cond
            ((hash-table-p headers) (gethash key headers))
            ((listp headers)
             (cdr (assoc key headers
                         :test (lambda (a b) (string-equal a (princ-to-string b)))))))))
    (error () nil)))

(defun parse-retry-after (headers)
  "The server's Retry-After (from a dexador response-headers object) as a
positive number of SECONDS, or NIL. Handles the delta-seconds form — the common
shape on a 429; the HTTP-date form is treated as absent so COMPLETE-WITH-RETRY
falls back to its own backoff rather than mis-parsing a date. Never signals."
  (let ((raw (http-header-value headers "retry-after")))
    (when (and raw (or (stringp raw) (realp raw)))
      (let ((n (if (realp raw)
                   raw
                   (ignore-errors (parse-integer (string-trim '(#\Space #\Tab) raw))))))
        (and (realp n) (plusp n) n)))))


(defun effective-thinking-level (provider)
  "The thinkingLevel to send, or NIL to omit thinkingConfig entirely.
`thinkingLevel` is a Gemini-3+ generationConfig field: 2.x/flash models reject
the request with a 400 (\"thinking_level is not supported by this model\"), so
only send it for a gemini-3 model — and never when the level is explicitly off
(config :thinking-level = off/none/\"\"). Keeps cheap-model QA (gemini-2.5-flash) working."
  (let ((level (vertex-thinking-level provider))
        (model (string-downcase (or (provider-model provider) ""))))
    (when (and (stringp level) (plusp (length level))
               (not (member (string-downcase level) '("off" "none" "no" "0")
                            :test #'string=))
               (search "gemini-3" model))
      level)))

(defmethod complete ((provider vertex-provider) system-prompt messages tools
                     &key on-event)
  (ourro.kernel:require-capability :llm 'complete)
  (let* ((generation-config
           (json-object "maxOutputTokens" (vertex-max-output-tokens provider)))
         (thinking (effective-thinking-level provider))
         (request (progn
                    (when thinking
                      (setf (gethash "thinkingConfig" generation-config)
                            (json-object "thinkingLevel" thinking)))
                    (json-object
                     "systemInstruction"
                     (json-object "parts"
                                  (vector (json-object "text" (or system-prompt ""))))
                     "contents" (serialize-messages messages)
                     "generationConfig" generation-config)))
         (declarations (serialize-tool-declarations tools)))
    (when (plusp (length declarations))
      (setf (gethash "tools" request) declarations))
    (let* ((url (vertex-request-url provider))
           (blocks '())
           (accumulated (make-string-output-stream))
           (finish-reason nil)
           (usage nil)
           (deadline-seconds (vertex-stream-deadline-seconds provider))
           (deadline (and deadline-seconds
                          (+ (get-internal-real-time)
                             (* deadline-seconds internal-time-units-per-second)))))
      (handler-case
          (let ((stream (dexador:post
                         url
                         :headers (vertex-request-headers provider)
                         :content (json-encode request)
                         :read-timeout (vertex-timeout provider)
                         :connect-timeout 30
                         :want-stream t
                         :force-binary nil)))
            (unwind-protect
                 (stream-json-objects
                  stream
                  (lambda (chunk)
                    ;; usageMetadata rides the same streamed chunks (cumulative,
                    ;; latest chunk wins) — keep it for the QA cost meter (QA-0).
                    (let ((meta (json-value chunk "usageMetadata")))
                      (when (hash-table-p meta)
                        (setf usage
                              (list :prompt-tokens
                                    (json-value meta "promptTokenCount" 0)
                                    :candidates-tokens
                                    (json-value meta "candidatesTokenCount" 0)
                                    :total-tokens
                                    (json-value meta "totalTokenCount" 0)))))
                    (let ((candidates (json-value chunk "candidates")))
                      (when (and (vectorp candidates) (plusp (length candidates)))
                        (let* ((candidate (aref candidates 0))
                               (content (json-value candidate "content"))
                               (parts (and content (json-value content "parts"))))
                          (setf finish-reason
                                (or (json-value candidate "finishReason")
                                    finish-reason))
                          (when (vectorp parts)
                            (loop for part across parts
                                  for block = (part-to-block part)
                                  when block do
                                    (push block blocks)
                                    (case (pget block :type)
                                      (:text
                                       (write-string (pget block :text "")
                                                     accumulated)
                                       (when on-event
                                         (funcall on-event
                                                  (list :kind :delta
                                                        :text (pget block :text "")))))
                                      (:thinking
                                       (when on-event
                                         (funcall on-event
                                                  (list :kind :thinking)))))))))))
                  :deadline deadline :deadline-seconds deadline-seconds)
              (ignore-errors (close stream))))
        (dexador.error:http-request-failed (condition)
          (let ((status (dexador.error:response-status condition)))
            (error 'provider-error
                   :message (format nil "Vertex AI request failed (~A): ~A"
                                    status
                                    (truncate-string
                                     (http-error-body-string
                                      (dexador.error:response-body condition))
                                     2000))
                   :status status
                   :retry-after (parse-retry-after
                                 (ignore-errors
                                  (dexador.error:response-headers condition)))
                   :retryable-p (or (eql status 429)
                                    (and (integerp status) (>= status 500))))))
        (stream-deadline-exceeded (condition)
          ;; Not retried: a stalled/slow stream would likely stall again and a
          ;; genuinely-long generation would just be re-cut — surface it so the
          ;; turn ends cleanly and the user can decide (F-llmwedge).
          (error 'provider-error
                 :message (format nil "model stream exceeded the ~A s deadline ~
without completing — the provider may be slow or stalled; try again."
                                  (or (stream-deadline-exceeded-seconds condition)
                                      "?"))
                 :retryable-p nil)))
      (unless finish-reason
        (error 'provider-error
               :message "Vertex stream ended without a candidate finishReason"
               :retryable-p t))
      (let ((message (assistant-message (nreverse blocks)
                                        :stop-reason finish-reason
                                        :usage usage)))
        (when on-event
          (funcall on-event (list :kind :done
                                  :text (get-output-stream-string accumulated))))
        message))))


(defclass scripted-provider (provider)
  ((responses :initarg :responses :accessor scripted-responses)
   (requests :initform '() :accessor scripted-provider-requests)
   (loop-p :initarg :loop-p :initform nil :accessor scripted-loop-p
           :documentation "When true, recycle the whole response list once
exhausted instead of signalling — the overnight-soak driver (QA-0/QA-4).")
   (original :initarg :original :initform nil :accessor scripted-original
             :documentation "The full response list, kept for :loop recycling.")
   (stream :initarg :stream :initform nil :accessor scripted-stream
           :documentation "When true, emit word-by-word :delta events before
:done — drives offline streaming demos and the M2-1 tests."))
  (:default-initargs :model "scripted"))

(defun coerce-scripted-response (response)
  "Normalize one scripted RESPONSE spec into an assistant message plist. A bare
string is text; a plist (:text STRING :tool-calls ((:id :name :args-json/:args)…))
becomes a text block plus tool-call blocks (the QA scripted-file shape); an
already-canonical assistant message passes through."
  (cond
    ((stringp response)
     (assistant-message (list (list :type :text :text response))))
    ((and (consp response) (eq (pget response :role) :assistant))
     response)
    ((and (consp response) (keywordp (car response)))
     (let ((text (pget response :text))
           (blocks '()))
       (when (and (stringp text) (plusp (length text)))
         (push (list :type :text :text text) blocks))
       (dolist (call (pget response :tool-calls))
         (push (list :type :tool-call
                     :id (or (pget call :id) (make-id "call"))
                     :name (pget call :name)
                     :args-json (scripted-call-args-json call))
               blocks))
       (assistant-message (nreverse blocks))))
    (t (error 'provider-error
              :message (format nil "unrecognized scripted response spec: ~S"
                               response)))))

(defun scripted-call-args-json (call)
  "The tool-call arguments as a JSON string: an explicit :args-json wins,
otherwise an :args plist is encoded (keys lowercased), otherwise \"{}\"."
  (let ((args-json (pget call :args-json))
        (args (pget call :args)))
    (cond
      ((and (stringp args-json) (plusp (length args-json))) args-json)
      ((consp args)
       (let ((object (make-hash-table :test #'equal)))
         (loop for (k v) on args by #'cddr
               do (setf (gethash (string-downcase (string k)) object) v))
         (json-encode object)))
      (t "{}"))))

(defun make-scripted-provider (responses &key stream loop-p)
  "RESPONSES: list of assistant message plists (or strings, wrapped as
text messages) returned in order. Signals when exhausted (unless LOOP-P, which
recycles). With STREAM, the provider emits the text word-by-word as :delta
events."
  (let ((coerced (mapcar #'coerce-scripted-response responses)))
    (make-instance 'scripted-provider
                   :stream stream
                   :loop-p loop-p
                   :original coerced
                   :responses coerced)))

(defun make-scripted-provider-from-file (path &key stream)
  "Build a scripted provider from a file of response specs (kernel safe-read, no
eval) — the T1 tmux tier's deterministic backend (QA-0). Each top-level form is
a response spec (see COERCE-SCRIPTED-RESPONSE). An optional leading (:loop t)
form makes the provider recycle its responses forever (soak). Signals a
PROVIDER-ERROR if the file is missing or unreadable."
  (let ((forms (handler-case
                   (ourro.kernel:safe-read-forms
                    (uiop:read-file-string path)
                    :package (find-package :keyword))
                 (error (c)
                   (error 'provider-error
                          :message (format nil "cannot read scripted file ~A: ~A"
                                           path c)))))
        (loop-p nil))
    (when (and forms (consp (first forms)) (eq (car (first forms)) :loop))
      (setf loop-p (pget (first forms) :loop)
            forms (rest forms)))
    (make-scripted-provider forms :stream stream :loop-p loop-p)))


(defun stream-words (text on-event)
  "Emit TEXT to ON-EVENT as word-by-word :delta events (space-preserving)."
  (let ((start 0) (length (length text)))
    (loop while (< start length)
          for space = (position #\Space text :start start)
          for end = (if space (1+ space) length)
          do (funcall on-event (list :kind :delta :text (subseq text start end)))
             (setf start end))))

(defmethod complete ((provider scripted-provider) system-prompt messages tools
                     &key on-event)
  (push (list :system system-prompt :messages messages :tools tools)
        (scripted-provider-requests provider))
  ;; Recycle when a :loop provider runs dry, so an overnight soak never
  ;; exhausts its script (QA-0/QA-4).
  (when (and (null (scripted-responses provider))
             (scripted-loop-p provider)
             (scripted-original provider))
    (setf (scripted-responses provider)
          (copy-list (scripted-original provider))))
  (let ((response (pop (scripted-responses provider))))
    (unless response
      (error 'provider-error :message "scripted provider exhausted"))
    (when on-event
      (let ((text (assistant-text response)))
        (when (and (scripted-stream provider) (plusp (length text)))
          (stream-words text on-event))
        (funcall on-event (list :kind :done :text text))))
    response))
