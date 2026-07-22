
(defpackage #:ourro.llm
  (:use #:cl #:ourro.util)
  (:export ;; json helpers
           #:json-object
           #:json-value
           #:json-encode
           #:json-decode
           #:arrayify
           ;; provider protocol (vertex.lisp)
           #:provider
           #:provider-model
           #:complete
           #:complete-text
           #:complete-with-retry
           #:*retry-max-attempts*
           #:*retry-backoff-cap*
           #:retry-max-attempts
           #:retry-backoff-cap
           #:provider-error
           #:configuration-error
           #:provider-error-message
           #:provider-error-retryable-p
           #:provider-error-retry-after
           #:provider-error-status
           #:*llm-call-hook*
           #:*llm-call-context*
           #:vertex-provider
           #:make-vertex-provider
           #:vertex-api-key
           #:vertex-api-flavor
           #:vertex-project
           #:vertex-max-output-tokens
           #:vertex-thinking-level
           #:vertex-request-url
           #:vertex-request-headers
           #:scripted-provider
           #:make-scripted-provider
           #:make-scripted-provider-from-file
           #:scripted-provider-requests
           #:bedrock-provider
           #:make-bedrock-provider
           #:bedrock-request-url
           #:bedrock-request-headers
           #:provider-from-env
           #:resolve-model
           #:available-models
           #:*model-aliases*
           #:model-context-window
           #:model-pricing
           #:message-usage
           #:*default-provider*
           #:configure-default-provider
           ;; canonical message constructors/accessors
           #:user-message
           #:assistant-message
           #:tool-result-message
           #:message-role
           #:message-content
           #:assistant-text
           #:assistant-tool-calls
           #:tool-call-id
           #:tool-call-name
           #:tool-call-args))

(in-package #:ourro.llm)

(defun json-object (&rest keys-and-values)
  "Build an EQUAL hash table from alternating keys and values."
  (let ((object (make-hash-table :test #'equal)))
    (loop for (key value) on keys-and-values by #'cddr
          do (setf (gethash key object) value))
    object))

(defun json-value (object key &optional default)
  (if (hash-table-p object)
      (multiple-value-bind (value present) (gethash key object)
        (if present value default))
      default))

(defun json-encode (value)
  (com.inuoe.jzon:stringify value))

(defun json-decode (string)
  (com.inuoe.jzon:parse string))

(defun arrayify (list)
  (coerce list 'vector))


(defun user-message (text)
  (list :role :user :content text))

(defun assistant-message (blocks &key stop-reason usage)
  (list :role :assistant :content blocks :stop-reason stop-reason :usage usage))

(defun tool-result-message (tool-call-id name content &key error-p)
  (list :role :tool :tool-call-id tool-call-id :name name
        :content content :error-p error-p))

(defun message-role (message) (pget message :role))
(defun message-content (message) (pget message :content))
(defun message-usage (message)
  "Token-usage plist (:prompt-tokens :candidates-tokens :total-tokens) attached
to an assistant message by a provider that reports it, or NIL (QA-0)."
  (pget message :usage))

(defun assistant-text (message)
  (with-output-to-string (out)
    (dolist (block (message-content message))
      (when (eq (pget block :type) :text)
        (write-string (pget block :text "") out)))))

(defun assistant-tool-calls (message)
  (remove-if-not (lambda (block) (eq (pget block :type) :tool-call))
                 (message-content message)))

(defun tool-call-id (block) (pget block :id))
(defun tool-call-name (block) (pget block :name))

(defun tool-call-args (block)
  "Decode the tool call's arguments JSON into a hash table."
  (let ((json (pget block :args-json)))
    (if (and json (plusp (length json)))
        (let ((decoded (json-decode json)))
          (if (hash-table-p decoded) decoded (json-object)))
        (json-object))))
