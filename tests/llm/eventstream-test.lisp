(in-package #:ourro.tests)

(def-suite eventstream-suite :in ourro)
(in-suite eventstream-suite)


(defun put-be-u32 (buf off val)
  (setf (aref buf off) (logand (ash val -24) 255)
        (aref buf (+ off 1)) (logand (ash val -16) 255)
        (aref buf (+ off 2)) (logand (ash val -8) 255)
        (aref buf (+ off 3)) (logand val 255)))

(defun build-es-header (name value)
  "One string-typed (type 7) event-stream header: (u8 name-len)(name)(u8 7)
(u16 value-len)(value)."
  (let* ((nbytes (sb-ext:string-to-octets name))
         (vbytes (sb-ext:string-to-octets value))
         (len (+ 1 (length nbytes) 1 2 (length vbytes)))
         (h (make-array len :element-type '(unsigned-byte 8)))
         (p 0))
    (setf (aref h p) (length nbytes)) (incf p)
    (replace h nbytes :start1 p) (incf p (length nbytes))
    (setf (aref h p) 7) (incf p)
    (setf (aref h p) (logand (ash (length vbytes) -8) 255)) (incf p)
    (setf (aref h p) (logand (length vbytes) 255)) (incf p)
    (replace h vbytes :start1 p)
    h))

(defun build-es-frame (event-type payload-string)
  "A full AWS event-stream frame carrying a single :event-type header."
  (let* ((payload (sb-ext:string-to-octets payload-string :external-format :utf-8))
         (headers (build-es-header ":event-type" event-type))
         (headers-len (length headers))
         (total (+ 12 headers-len (length payload) 4))
         (out (make-array total :element-type '(unsigned-byte 8) :initial-element 0)))
    (put-be-u32 out 0 total)
    (put-be-u32 out 4 headers-len)
    (put-be-u32 out 8 0)                 ; prelude crc — ignored in v1
    (replace out headers :start1 12)
    (replace out payload :start1 (+ 12 headers-len))
    (put-be-u32 out (- total 4) 0)       ; message crc — ignored in v1
    out))

(defun concat-octets (&rest vectors)
  (let* ((len (reduce #'+ vectors :key #'length))
         (out (make-array len :element-type '(unsigned-byte 8)))
         (p 0))
    (dolist (v vectors out)
      (replace out v :start1 p) (incf p (length v)))))

(defun decode-all (octets)
  "Decode OCTETS into a list of (event-type . payload) pairs."
  (let ((events '()))
    (ourro.llm::decode-eventstream
     (ourro.llm::make-vector-byte-reader octets)
     (lambda (type payload) (push (cons type payload) events)))
    (nreverse events)))

(test eventstream-single-frame
  (let* ((frame (build-es-frame "contentBlockDelta"
                                "{\"contentBlockIndex\":0,\"delta\":{\"text\":\"hi\"}}"))
         (events (decode-all frame)))
    (is (= 1 (length events)))
    (is (string= "contentBlockDelta" (car (first events))))
    (is (search "\"text\":\"hi\"" (cdr (first events))))))

(test eventstream-multiple-frames-in-order
  (let* ((bytes (concat-octets
                 (build-es-frame "messageStart" "{}")
                 (build-es-frame "contentBlockDelta"
                                 "{\"contentBlockIndex\":0,\"delta\":{\"text\":\"a\"}}")
                 (build-es-frame "messageStop" "{\"stopReason\":\"end_turn\"}")))
         (events (decode-all bytes)))
    (is (equal '("messageStart" "contentBlockDelta" "messageStop")
               (mapcar #'car events)))))

(test eventstream-header-value-reads-event-type
  ;; The header scanner must skip other value types and still find :event-type.
  (let ((h (concat-octets (build-es-header ":content-type" "application/json")
                          (build-es-header ":event-type" "metadata"))))
    (is (string= "metadata" (ourro.llm::eventstream-header-value h ":event-type")))
    (is (string= "application/json"
                 (ourro.llm::eventstream-header-value h ":content-type")))
    (is (null (ourro.llm::eventstream-header-value h ":nope")))))

(test eventstream-truncated-frame-signals-decode-error
  (let ((frame (build-es-frame "messageStop" "{\"stopReason\":\"end_turn\"}")))
    ;; Drop the last few bytes → the body read comes up short.
    (signals ourro.llm::eventstream-decode-error
      (ourro.llm::decode-eventstream
       (ourro.llm::make-vector-byte-reader (subseq frame 0 (- (length frame) 3)))
       (lambda (type payload) (declare (ignore type payload)))))))


(defun test-bedrock-provider ()
  (make-instance 'ourro.llm::bedrock-provider :model "test" :api-key "x"))

(defun stream-message (frames &optional on-event)
  (ourro.llm::bedrock-stream-message-from-events
   (test-bedrock-provider)
   (ourro.llm::make-vector-byte-reader (apply #'concat-octets frames))
   on-event))

(test bedrock-stream-text-deltas-accumulate
  (let ((deltas '()))
    (let ((msg (stream-message
                (list (build-es-frame "contentBlockDelta"
                                      "{\"contentBlockIndex\":0,\"delta\":{\"text\":\"Hel\"}}")
                      (build-es-frame "contentBlockDelta"
                                      "{\"contentBlockIndex\":0,\"delta\":{\"text\":\"lo\"}}")
                      (build-es-frame "contentBlockStop" "{\"contentBlockIndex\":0}")
                      (build-es-frame "messageStop" "{\"stopReason\":\"end_turn\"}"))
                (lambda (e) (when (eq (pget e :kind) :delta)
                              (push (pget e :text) deltas))))))
      ;; streamed token-by-token
      (is (equal '("Hel" "lo") (nreverse deltas)))
      ;; and assembled into one text block
      (let ((blocks (ourro.llm:message-content msg)))
        (is (= 1 (length blocks)))
        (is (eq :text (pget (first blocks) :type)))
        (is (string= "Hello" (pget (first blocks) :text))))
      (is (string= "end_turn" (pget msg :stop-reason))))))

(test bedrock-stream-tooluse-input-accumulates
  (let ((msg (stream-message
              (list (build-es-frame "contentBlockStart"
                                    "{\"contentBlockIndex\":0,\"start\":{\"toolUse\":{\"toolUseId\":\"tu1\",\"name\":\"read_file\"}}}")
                    (build-es-frame "contentBlockDelta"
                                    "{\"contentBlockIndex\":0,\"delta\":{\"toolUse\":{\"input\":\"{\\\"path\\\":\\\"\"}}}")
                    (build-es-frame "contentBlockDelta"
                                    "{\"contentBlockIndex\":0,\"delta\":{\"toolUse\":{\"input\":\"a.txt\\\"}\"}}}")
                    (build-es-frame "contentBlockStop" "{\"contentBlockIndex\":0}")
                    (build-es-frame "messageStop" "{\"stopReason\":\"tool_use\"}")))))
    (let ((blocks (ourro.llm:message-content msg)))
      (is (= 1 (length blocks)))
      (let ((b (first blocks)))
        (is (eq :tool-call (pget b :type)))
        (is (string= "tu1" (pget b :id)))
        (is (string= "read_file" (pget b :name)))
        (is (string= "{\"path\":\"a.txt\"}" (pget b :args-json)))))
    (is (string= "tool_use" (pget msg :stop-reason)))))

(test bedrock-stream-metadata-usage-parsed
  (let ((msg (stream-message
              (list (build-es-frame "contentBlockDelta"
                                    "{\"contentBlockIndex\":0,\"delta\":{\"text\":\"x\"}}")
                    (build-es-frame "messageStop" "{\"stopReason\":\"end_turn\"}")
                    (build-es-frame "metadata"
                                    "{\"usage\":{\"inputTokens\":10,\"outputTokens\":5,\"totalTokens\":15,\"cacheReadInputTokens\":4}}")))))
    (let ((usage (pget msg :usage)))
      (is (= 10 (pget usage :prompt-tokens)))
      (is (= 5 (pget usage :candidates-tokens)))
      (is (= 15 (pget usage :total-tokens)))
      (is (= 4 (pget usage :cache-read-tokens))))))

(test bedrock-stream-requires-terminal-event
  (signals ourro.llm::eventstream-decode-error
    (stream-message
     (list (build-es-frame "contentBlockDelta"
                           "{\"contentBlockIndex\":0,\"delta\":{\"text\":\"partial\"}}")))))

(test bedrock-stream-rejects-exception-events
  (signals ourro.llm::eventstream-decode-error
    (stream-message
     (list (build-es-frame "modelStreamErrorException"
                           "{\"message\":\"failed\"}")))))
