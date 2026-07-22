
(defpackage #:ourro.txn
  (:use #:cl)
  (:import-from #:ourro.util
                #:ensure-dir #:make-id #:ourro-path #:pget #:plist-put)
  (:import-from #:ourro.kernel #:safe-read-form)
  (:export
   ;; limits / conditions
   #:*max-canonical-depth* #:*max-canonical-items* #:*max-wal-frame-bytes*
   #:canonical-encoding-error
   #:wal-corruption #:wal-corruption-path #:wal-corruption-offset
   #:wal-corruption-reason
   ;; canonical encoding and hashes
   #:canonical-encode #:canonical-decode #:canonical-octets
   #:canonical-hash #:sha256-octets #:sha256-string #:sha256-file
   #:canonical-equal
   ;; WAL
   #:append-wal-record #:append-wal-record-batch #:read-wal #:read-wal-from-offset
   #:recover-wal #:wal-health #:wal-prefix-hash
   #:write-canonical-file
   ;; transaction/proof records
   #:make-transaction-id #:make-verification-artifact
   #:verification-artifact-valid-p #:verification-artifact-path
   #:persist-verification-artifact #:read-verification-artifact
   #:make-lifecycle-attestation #:lifecycle-attestation-valid-p))

(in-package #:ourro.txn)


(defparameter *max-canonical-depth* 80)
(defparameter *max-canonical-items* 100000)
(defparameter *max-wal-frame-bytes* (* 16 1024 1024))
(defparameter +wide-list-threshold+ 32
  "Use the flat :LIST canonical tag above this length. Short lists retain the
original :CONS encoding so existing proof hashes remain valid.")

(define-condition canonical-encoding-error (error)
  ((reason :initarg :reason :reader canonical-encoding-error-reason))
  (:report (lambda (c stream)
             (format stream "Canonical encoding failed: ~A"
                     (canonical-encoding-error-reason c)))))

(define-condition wal-corruption (error)
  ((path :initarg :path :reader wal-corruption-path)
   (offset :initarg :offset :reader wal-corruption-offset)
   (reason :initarg :reason :reader wal-corruption-reason))
  (:report (lambda (c stream)
             (format stream "WAL ~A is corrupt at byte ~D: ~A"
                     (wal-corruption-path c) (wal-corruption-offset c)
                     (wal-corruption-reason c)))))

(defun canonical-error (control &rest args)
  (error 'canonical-encoding-error :reason (apply #'format nil control args)))


(defconstant +u32-mask+ #xffffffff)

(defparameter +sha256-k+
  #(#x428a2f98 #x71374491 #xb5c0fbcf #xe9b5dba5 #x3956c25b #x59f111f1
    #x923f82a4 #xab1c5ed5 #xd807aa98 #x12835b01 #x243185be #x550c7dc3
    #x72be5d74 #x80deb1fe #x9bdc06a7 #xc19bf174 #xe49b69c1 #xefbe4786
    #x0fc19dc6 #x240ca1cc #x2de92c6f #x4a7484aa #x5cb0a9dc #x76f988da
    #x983e5152 #xa831c66d #xb00327c8 #xbf597fc7 #xc6e00bf3 #xd5a79147
    #x06ca6351 #x14292967 #x27b70a85 #x2e1b2138 #x4d2c6dfc #x53380d13
    #x650a7354 #x766a0abb #x81c2c92e #x92722c85 #xa2bfe8a1 #xa81a664b
    #xc24b8b70 #xc76c51a3 #xd192e819 #xd6990624 #xf40e3585 #x106aa070
    #x19a4c116 #x1e376c08 #x2748774c #x34b0bcb5 #x391c0cb3 #x4ed8aa4a
    #x5b9cca4f #x682e6ff3 #x748f82ee #x78a5636f #x84c87814 #x8cc70208
    #x90befffa #xa4506ceb #xbef9a3f7 #xc67178f2))

(declaim (inline u32 rotr32 sha-ch sha-maj sha-big0 sha-big1 sha-small0
                 sha-small1))

(defun u32 (n) (logand n +u32-mask+))
(defun rotr32 (n count)
  (u32 (logior (ash n (- count)) (ash n (- 32 count)))))
(defun sha-ch (x y z) (logxor (logand x y) (logand (lognot x) z)))
(defun sha-maj (x y z)
  (logxor (logand x y) (logand x z) (logand y z)))
(defun sha-big0 (x) (logxor (rotr32 x 2) (rotr32 x 13) (rotr32 x 22)))
(defun sha-big1 (x) (logxor (rotr32 x 6) (rotr32 x 11) (rotr32 x 25)))
(defun sha-small0 (x) (logxor (rotr32 x 7) (rotr32 x 18) (ash x -3)))
(defun sha-small1 (x) (logxor (rotr32 x 17) (rotr32 x 19) (ash x -10)))

(defun sha256-octets (input)
  "Return the lowercase SHA-256 hex digest of an octet vector INPUT."
  (unless (typep input '(vector (unsigned-byte 8)))
    (canonical-error "SHA256-OCTETS requires an octet vector, got ~S"
                     (type-of input)))
  (let* ((length (length input))
         (bit-length (* length 8))
         (padded-length (* 64 (ceiling (+ length 9) 64)))
         (message (make-array padded-length :element-type '(unsigned-byte 8)
                                             :initial-element 0))
         (h (vector #x6a09e667 #xbb67ae85 #x3c6ef372 #xa54ff53a
                    #x510e527f #x9b05688c #x1f83d9ab #x5be0cd19))
         (w (make-array 64 :initial-element 0)))
    (replace message input)
    (setf (aref message length) #x80)
    (dotimes (i 8)
      (setf (aref message (+ (- padded-length 8) i))
            (ldb (byte 8 (* 8 (- 7 i))) bit-length)))
    (loop for base from 0 below padded-length by 64 do
      (dotimes (i 16)
        (let ((at (+ base (* i 4))))
          (setf (aref w i)
                (u32 (logior (ash (aref message at) 24)
                             (ash (aref message (+ at 1)) 16)
                             (ash (aref message (+ at 2)) 8)
                             (aref message (+ at 3)))))))
      (loop for i from 16 below 64 do
        (setf (aref w i)
              (u32 (+ (sha-small1 (aref w (- i 2)))
                      (aref w (- i 7))
                      (sha-small0 (aref w (- i 15)))
                      (aref w (- i 16))))))
      (let ((a (aref h 0)) (b (aref h 1)) (c (aref h 2)) (d (aref h 3))
            (e (aref h 4)) (f (aref h 5)) (g (aref h 6)) (hh (aref h 7)))
        (dotimes (i 64)
          (let* ((t1 (u32 (+ hh (sha-big1 e) (sha-ch e f g)
                              (aref +sha256-k+ i) (aref w i))))
                 (t2 (u32 (+ (sha-big0 a) (sha-maj a b c)))))
            (setf hh g g f f e e (u32 (+ d t1)) d c c b b a
                  a (u32 (+ t1 t2)))))
        (setf (aref h 0) (u32 (+ (aref h 0) a))
              (aref h 1) (u32 (+ (aref h 1) b))
              (aref h 2) (u32 (+ (aref h 2) c))
              (aref h 3) (u32 (+ (aref h 3) d))
              (aref h 4) (u32 (+ (aref h 4) e))
              (aref h 5) (u32 (+ (aref h 5) f))
              (aref h 6) (u32 (+ (aref h 6) g))
              (aref h 7) (u32 (+ (aref h 7) hh)))))
    (string-downcase (format nil "~{~8,'0X~}" (coerce h 'list)))))

(defun sha256-string (string)
  (sha256-octets (sb-ext:string-to-octets string :external-format :utf-8)))

(defun read-file-octets (pathname)
  (with-open-file (in pathname :direction :input
                            :element-type '(unsigned-byte 8))
    (let* ((length (file-length in))
           (bytes (make-array length :element-type '(unsigned-byte 8))))
      (unless (= (read-sequence bytes in) length)
        (error "Short read from ~A" pathname))
      bytes)))

(defun sha256-file (pathname)
  (sha256-octets (read-file-octets pathname)))


(defun canonical-tagged-form (object)
  (let ((items 0)
        (ancestors (make-hash-table :test #'eq)))
    (labels ((visit (value depth)
               (when (> depth *max-canonical-depth*)
                 (canonical-error "value exceeds maximum depth ~D"
                                  *max-canonical-depth*))
               (when (> (incf items) *max-canonical-items*)
                 (canonical-error "value exceeds maximum item count ~D"
                                  *max-canonical-items*))
               (cond
                 ((null value) '(:null))
                 ((eq value t) '(:boolean t))
                 ((stringp value) (list :string value))
                 ((characterp value) (list :character (char-code value)))
                 ((integerp value) (list :integer (write-to-string value :base 10)))
                 ((and (rationalp value) (not (integerp value)))
                  (list :ratio (write-to-string (numerator value) :base 10)
                               (write-to-string (denominator value) :base 10)))
                 ((floatp value)
                  (multiple-value-bind (significand exponent sign)
                      (integer-decode-float value)
                    (list :float (string-upcase (symbol-name (type-of value)))
                                 (write-to-string significand :base 10)
                                 exponent sign)))
                 ((complexp value)
                  (list :complex (visit (realpart value) (1+ depth))
                                 (visit (imagpart value) (1+ depth))))
                 ((symbolp value)
                  (let ((package (symbol-package value)))
                    (unless package
                      (canonical-error "uninterned symbol ~S is forbidden" value))
                    (list :symbol (package-name package) (symbol-name value))))
                 ((pathnamep value)
                  (list :pathname (uiop:native-namestring value)))
                 ((consp value)
                  (when (gethash value ancestors)
                    ;; Never print VALUE here: it is cyclic by definition and
                    ;; a pretty-printer without *PRINT-CIRCLE* would recurse
                    ;; until heap exhaustion while trying to report the error.
                    (canonical-error "cycle detected at cons"))
                  (setf (gethash value ancestors) t)
                  (unwind-protect
                       (let ((length (ignore-errors (list-length value))))
                         ;; A plist or snapshot tail is structurally wide, not
                         ;; deeply nested. Encoding a long proper list as a
                         ;; recursive :CONS chain made the security depth limit
                         ;; reject ordinary journal records. The flat tag keeps
                         ;; depth and width independent while the item/frame
                         ;; limits still bound resource use.
                         (if (and length (> length +wide-list-threshold+))
                             (list :list
                                   (loop for item in value
                                         collect (visit item (1+ depth))))
                             (list :cons (visit (car value) (1+ depth))
                                         (visit (cdr value) (1+ depth)))))
                    (remhash value ancestors)))
                 ((hash-table-p value)
                  (when (gethash value ancestors)
                    (canonical-error "cycle detected at hash table"))
                  (setf (gethash value ancestors) t)
                  (unwind-protect
                       (let ((pairs '()))
                         (maphash
                          (lambda (key item)
                            (let ((encoded-key (visit key (1+ depth))))
                              (push (list (canonical-print-form encoded-key)
                                          encoded-key
                                          (visit item (1+ depth)))
                                    pairs)))
                          value)
                         (list :map
                               (string-upcase
                                (symbol-name
                                 (or (and (symbolp (hash-table-test value))
                                          (hash-table-test value))
                                     'equal)))
                               (mapcar #'cdr
                                       (sort pairs #'string< :key #'car))))
                    (remhash value ancestors)))
                 ((vectorp value)
                  (when (gethash value ancestors)
                    (canonical-error "cycle detected at vector"))
                  (setf (gethash value ancestors) t)
                  (unwind-protect
                       (list :vector
                             (loop for item across value
                                   collect (visit item (1+ depth))))
                    (remhash value ancestors)))
                 (t (canonical-error "unsupported value of type ~S" (type-of value))))))
      (visit object 0))))

(defun canonical-print-form (form)
  (with-standard-io-syntax
    (let ((*package* (find-package :keyword))
          ;; T makes SBCL preserve BASE-STRING's exact array element type via
          ;; implementation-shaped #A syntax. The canonical data model treats
          ;; all strings by character content, so escaped ordinary strings are
          ;; the stable representation.
          (*print-readably* nil)
          (*print-pretty* nil)
          (*print-circle* nil)
          (*read-eval* nil))
      (prin1-to-string form))))

(defun canonical-encode (object)
  "Encode OBJECT as a deterministic, package-explicit tagged S-expression."
  (canonical-print-form (canonical-tagged-form object)))

(defun canonical-octets (object)
  (sb-ext:string-to-octets (canonical-encode object) :external-format :utf-8))

(defun canonical-hash (object)
  (sha256-octets (canonical-octets object)))

(defun parse-decimal-integer (string)
  (handler-case (parse-integer string :radix 10 :junk-allowed nil)
    (error () (canonical-error "invalid canonical integer ~S" string))))

(defun float-prototype (name)
  (cond ((string= name "SHORT-FLOAT") (coerce 0 'short-float))
        ((string= name "SINGLE-FLOAT") (coerce 0 'single-float))
        ((string= name "DOUBLE-FLOAT") (coerce 0 'double-float))
        ((string= name "LONG-FLOAT") (coerce 0 'long-float))
        (t (canonical-error "unknown float type ~S" name))))

(defun decode-symbol (package-name symbol-name)
  (let ((package (or (find-package package-name)
                     (canonical-error "unknown package ~S" package-name))))
    (if (string= package-name "KEYWORD")
        (intern symbol-name package)
        (multiple-value-bind (symbol status) (find-symbol symbol-name package)
          (declare (ignore status))
          (or symbol
              (canonical-error "symbol ~A::~A is not present"
                               package-name symbol-name))))))

(defun canonical-decode (string)
  "Decode one CANONICAL-ENCODE string, rejecting malformed or oversized data."
  (let ((form (handler-case
                  (safe-read-form string :package (find-package :keyword))
                (error (c) (canonical-error "reader rejected value: ~A" c))))
        (items 0))
    (labels ((decode (node depth)
               (when (> depth *max-canonical-depth*)
                 (canonical-error "decoded value exceeds maximum depth"))
               (when (> (incf items) *max-canonical-items*)
                 (canonical-error "decoded value exceeds maximum item count"))
               (unless (and (consp node) (keywordp (first node)))
                 (canonical-error "malformed tagged value ~S" node))
               (case (first node)
                 (:null
                  (unless (= (length node) 1) (canonical-error "malformed :NULL"))
                  nil)
                 (:boolean
                  (unless (equal node '(:boolean t))
                    (canonical-error "malformed :BOOLEAN"))
                  t)
                 (:string
                  (unless (and (= (length node) 2) (stringp (second node)))
                    (canonical-error "malformed :STRING"))
                  (second node))
                 (:character
                  (unless (and (= (length node) 2) (integerp (second node)))
                    (canonical-error "malformed :CHARACTER"))
                  (or (code-char (second node))
                      (canonical-error "invalid character code ~S" (second node))))
                 (:integer
                  (unless (and (= (length node) 2) (stringp (second node)))
                    (canonical-error "malformed :INTEGER"))
                  (parse-decimal-integer (second node)))
                 (:ratio
                  (unless (and (= (length node) 3)
                               (stringp (second node)) (stringp (third node)))
                    (canonical-error "malformed :RATIO"))
                  (/ (parse-decimal-integer (second node))
                     (parse-decimal-integer (third node))))
                 (:float
                  (unless (and (= (length node) 5) (stringp (second node))
                               (stringp (third node)) (integerp (fourth node))
                               (member (fifth node) '(-1 1)))
                    (canonical-error "malformed :FLOAT"))
                  (* (fifth node)
                     (scale-float
                      (float (parse-decimal-integer (third node))
                             (float-prototype (second node)))
                      (fourth node))))
                 (:complex
                  (unless (= (length node) 3) (canonical-error "malformed :COMPLEX"))
                  (complex (decode (second node) (1+ depth))
                           (decode (third node) (1+ depth))))
                 (:symbol
                  (unless (and (= (length node) 3)
                               (stringp (second node)) (stringp (third node)))
                    (canonical-error "malformed :SYMBOL"))
                  (decode-symbol (second node) (third node)))
                 (:pathname
                  (unless (and (= (length node) 2) (stringp (second node)))
                    (canonical-error "malformed :PATHNAME"))
                  (uiop:parse-native-namestring (second node)))
                 (:cons
                  (unless (= (length node) 3) (canonical-error "malformed :CONS"))
                  (cons (decode (second node) (1+ depth))
                        (decode (third node) (1+ depth))))
                 (:list
                  (unless (and (= (length node) 2) (listp (second node)))
                    (canonical-error "malformed :LIST"))
                  (mapcar (lambda (item) (decode item (1+ depth)))
                          (second node)))
                 (:vector
                  (unless (and (= (length node) 2) (listp (second node)))
                    (canonical-error "malformed :VECTOR"))
                  (map 'vector (lambda (item) (decode item (1+ depth)))
                       (second node)))
                 (:map
                  (unless (and (= (length node) 3) (stringp (second node))
                               (listp (third node)))
                    (canonical-error "malformed :MAP"))
                  (let* ((test (cond ((string= (second node) "EQ") #'eq)
                                     ((string= (second node) "EQL") #'eql)
                                     ((string= (second node) "EQUAL") #'equal)
                                     ((string= (second node) "EQUALP") #'equalp)
                                     (t (canonical-error "unsupported map test ~S"
                                                         (second node)))))
                         (table (make-hash-table :test test)))
                    (dolist (pair (third node) table)
                      (unless (and (listp pair) (= (length pair) 2))
                        (canonical-error "malformed map pair ~S" pair))
                      (setf (gethash (decode (first pair) (1+ depth)) table)
                            (decode (second pair) (1+ depth))))))
                 (otherwise (canonical-error "unknown canonical tag ~S"
                                             (first node))))))
      (decode form 0))))

(defun canonical-equal (left right)
  (string= (canonical-encode left) (canonical-encode right)))


(defparameter +wal-magic+ "OURRO-TXN/1")
(defvar *wal-lock-table* (make-hash-table :test #'equal))
(defvar *wal-lock-table-lock* (bt:make-lock "ourro-transaction-wal-lock-table"))

(defun wal-path-lock (pathname)
  "Return the stable lock for PATHNAME without serializing unrelated WALs."
  (let ((key (namestring (merge-pathnames pathname))))
    (bt:with-lock-held (*wal-lock-table-lock*)
      (or (gethash key *wal-lock-table*)
          (setf (gethash key *wal-lock-table*)
                (bt:make-lock (format nil "ourro-wal-~A" key)))))))

(defun string-octets (string)
  (sb-ext:string-to-octets string :external-format :utf-8))

(defun octets-string (octets)
  (handler-case (sb-ext:octets-to-string octets :external-format :utf-8)
    (error (c) (canonical-error "invalid UTF-8 payload: ~A" c))))

(defun fsync-stream (stream)
  #+sbcl
  (let ((fd (ignore-errors (sb-sys:fd-stream-fd stream))))
    (when fd (sb-posix:fsync fd)))
  #-sbcl (declare (ignore stream))
  t)

(defun wal-frame-octets (record)
  (let* ((payload (canonical-octets record))
         (length (length payload)))
    (when (> length *max-wal-frame-bytes*)
      (canonical-error "WAL frame is ~D bytes; maximum is ~D"
                       length *max-wal-frame-bytes*))
    (values (string-octets
             (format nil "~A ~D ~A~%" +wal-magic+ length
                     (sha256-octets payload)))
            payload)))

(defun append-wal-record-batch (pathname records)
  "Append RECORDS under one per-path lock, open, flush, and fsync boundary."
  (when records
    ;; Encode before taking the path lock so independent producers only exclude
    ;; one another during the actual append boundary.
    (let ((frames
            (mapcar (lambda (record)
                      (multiple-value-bind (header payload) (wal-frame-octets record)
                        (cons header payload)))
                    records)))
      (ensure-directories-exist pathname)
      (bt:with-lock-held ((wal-path-lock pathname))
        (with-open-file (out pathname :direction :output
                                      :if-exists :append
                                      :if-does-not-exist :create
                                      :element-type '(unsigned-byte 8))
          (dolist (frame frames)
            (write-sequence (car frame) out)
            (write-sequence (cdr frame) out)
            (write-byte (char-code #\Newline) out))
          (finish-output out)
          (fsync-stream out)))))
  records)

(defun append-wal-record (pathname record)
  "Append RECORD as one byte-length/SHA-256 framed canonical WAL entry."
  (append-wal-record-batch pathname (list record))
  record)

(defun newline-position (octets start)
  (position (char-code #\Newline) octets :start start))

(defun parse-wal-header (header path offset)
  (let ((parts (uiop:split-string header :separator '(#\Space))))
    (unless (= (length parts) 3)
      (error 'wal-corruption :path path :offset offset
                             :reason "malformed frame header"))
    (unless (string= (first parts) +wal-magic+)
      (error 'wal-corruption :path path :offset offset
                             :reason "unknown frame magic/version"))
    (let ((length (ignore-errors (parse-integer (second parts) :junk-allowed nil)))
          (checksum (third parts)))
      (unless (and length (<= 0 length *max-wal-frame-bytes*))
        (error 'wal-corruption :path path :offset offset
                               :reason "invalid or oversized frame length"))
      (unless (and (= (length checksum) 64)
                   (every (lambda (c) (digit-char-p c 16)) checksum))
        (error 'wal-corruption :path path :offset offset
                               :reason "invalid SHA-256 checksum"))
      (values length (string-downcase checksum)))))

(defun read-wal-from-offset (pathname start-offset)
  "Read complete WAL frames beginning at the authenticated frame START-OFFSET.
Return (values RECORDS HEALTH VALID-BYTES), where VALID-BYTES is an absolute
file offset. Callers must authenticate the prefix before trusting an offset.

HEALTH is :OK or :TORN-TAIL. Only a missing/incomplete final header or payload
is a torn tail; checksum, canonical decoding, or any complete malformed frame
signals WAL-CORRUPTION and must put the caller into visible degraded mode."
  (unless (probe-file pathname)
    (if (zerop start-offset)
        (return-from read-wal-from-offset (values '() :ok 0))
        (error 'wal-corruption :path pathname :offset start-offset
                               :reason "tail offset for missing WAL")))
  (with-open-file (stream pathname :direction :input
                                   :element-type '(unsigned-byte 8))
    (let ((total (file-length stream))
          (offset start-offset)
          (records '()))
      (unless (and (integerp start-offset) (<= 0 start-offset total))
        (error 'wal-corruption :path pathname :offset (or start-offset 0)
                               :reason "tail offset is outside WAL"))
      (file-position stream start-offset)
      (loop
        (when (= offset total)
          (return (values (nreverse records) :ok offset)))
        (let ((frame-start offset)
              (header-bytes (make-array 96 :element-type '(unsigned-byte 8)
                                           :adjustable t :fill-pointer 0))
              (complete-header nil))
          (loop for byte = (read-byte stream nil nil)
                while byte do
                  (incf offset)
                  (if (= byte (char-code #\Newline))
                      (progn (setf complete-header t) (return))
                      (vector-push-extend byte header-bytes)))
          (unless complete-header
            (return (values (nreverse records) :torn-tail frame-start)))
          (let ((header (handler-case (octets-string header-bytes)
                          (canonical-encoding-error (condition)
                            (error 'wal-corruption :path pathname
                                                   :offset frame-start
                                                   :reason (princ-to-string condition))))))
            (multiple-value-bind (length checksum)
                (parse-wal-header header pathname frame-start)
              (let* ((payload (make-array length :element-type '(unsigned-byte 8)))
                     (read (read-sequence payload stream)))
                (incf offset read)
                (when (< read length)
                  (return (values (nreverse records) :torn-tail frame-start)))
                (let ((terminator (read-byte stream nil nil)))
                  (unless terminator
                    (return (values (nreverse records) :torn-tail frame-start)))
                  (incf offset)
                  (unless (= terminator (char-code #\Newline))
                    (error 'wal-corruption :path pathname :offset (1- offset)
                                           :reason "frame terminator is not a newline")))
                (unless (string= checksum (sha256-octets payload))
                  (error 'wal-corruption :path pathname :offset frame-start
                                         :reason "frame checksum mismatch"))
                (handler-case
                    (push (canonical-decode (octets-string payload)) records)
                  (error (condition)
                    (error 'wal-corruption :path pathname :offset frame-start
                                           :reason
                                           (format nil "invalid canonical payload: ~A"
                                                   condition))))))))))))

(defun read-wal (pathname)
  "Read and validate PATHNAME from its first frame."
  (read-wal-from-offset pathname 0))

(defun wal-prefix-hash (pathname byte-count)
  "Hash exactly BYTE-COUNT leading WAL bytes for snapshot-offset authentication."
  (unless (and (integerp byte-count) (<= 0 byte-count))
    (canonical-error "invalid WAL prefix length ~S" byte-count))
  (let ((bytes (make-array byte-count :element-type '(unsigned-byte 8))))
    (if (probe-file pathname)
        (with-open-file (stream pathname :direction :input
                                         :element-type '(unsigned-byte 8))
          (unless (and (integerp byte-count)
                       (<= 0 byte-count (file-length stream)))
            (canonical-error "WAL prefix length ~S is outside file length ~D"
                             byte-count (file-length stream)))
          (unless (= byte-count (read-sequence bytes stream))
            (canonical-error "WAL prefix became shorter while reading")))
        (unless (zerop byte-count)
          (canonical-error "WAL prefix length ~S is outside missing file" byte-count)))
    (sha256-octets bytes)))

(defun truncate-file-to (pathname length)
  (with-open-file (stream pathname :direction :io
                                  :if-exists :overwrite
                                  :element-type '(unsigned-byte 8))
    #+sbcl (sb-posix:ftruncate (sb-sys:fd-stream-fd stream) length)
    #-sbcl (error "WAL tail repair is not implemented on this Lisp")
    (finish-output stream)
    (fsync-stream stream)))

(defun recover-wal (pathname)
  "Read PATHNAME and truncate only a provably incomplete final frame."
  (multiple-value-bind (records health valid-bytes) (read-wal pathname)
    (when (eq health :torn-tail)
      (truncate-file-to pathname valid-bytes))
    (values records health)))

(defun wal-health (pathname)
  (handler-case
      (multiple-value-bind (records health valid-bytes) (read-wal pathname)
        (declare (ignore records valid-bytes))
        (list :status health :path (namestring pathname)))
    (wal-corruption (c)
      (list :status :degraded :path (namestring pathname)
            :offset (wal-corruption-offset c)
            :reason (wal-corruption-reason c)))))


(defun make-transaction-id (&optional (kind "txn"))
  (make-id kind))

(defun plist-without (plist key)
  (loop for (k value) on plist by #'cddr
        unless (eq k key) append (list k value)))

(defun make-verification-artifact (&key transaction-id source authority
                                        fingerprints stages test-report
                                        (kind :gene) extra)
  "Construct an immutable, self-hashing verification proof record."
  (let* ((core (list :schema-version 1
                     :record-kind :verification-proof
                     :artifact-kind kind
                     :transaction-id (or transaction-id (make-transaction-id "verify"))
                     :source source
                     :source-hash (sha256-string source)
                     :authority (copy-tree (or authority '()))
                     :fingerprints (copy-tree (or fingerprints '()))
                     :stages (copy-tree (or stages '()))
                     :test-report (or test-report "")
                     :extra (copy-tree (or extra '()))))
         (proof-hash (canonical-hash core)))
    (append core (list :proof-hash proof-hash))))

(defun verification-artifact-valid-p (artifact)
  (and (listp artifact)
       (= (pget artifact :schema-version 0) 1)
       (eq (pget artifact :record-kind) :verification-proof)
       (stringp (pget artifact :proof-hash))
       (stringp (pget artifact :source))
       (string= (pget artifact :source-hash)
                (sha256-string (pget artifact :source)))
       (string= (pget artifact :proof-hash)
                (canonical-hash (plist-without artifact :proof-hash)))))

(defun verification-artifact-path (proof-hash)
  (ourro-path "state" "verification-artifacts"
             (format nil "~A.csexp" proof-hash)))

(defun write-canonical-file (pathname object)
  (ensure-directories-exist pathname)
  (uiop:with-staging-pathname (staging pathname)
    (with-open-file (out staging :direction :output :if-exists :supersede
                                 :if-does-not-exist :create
                                 :element-type '(unsigned-byte 8))
      (write-sequence (canonical-octets object) out)
      (finish-output out)
      (fsync-stream out)))
  pathname)

(defun persist-verification-artifact (artifact)
  "Persist ARTIFACT once. Existing content must be byte-identical."
  (unless (verification-artifact-valid-p artifact)
    (canonical-error "invalid verification artifact"))
  (let ((path (verification-artifact-path (pget artifact :proof-hash))))
    (if (probe-file path)
        (unless (canonical-equal artifact (read-verification-artifact path))
          (canonical-error "immutable artifact collision at ~A" path))
        (write-canonical-file path artifact))
    path))

(defun read-verification-artifact (pathname)
  (canonical-decode
   (sb-ext:octets-to-string (read-file-octets pathname)
                            :external-format :utf-8)))

(defun make-lifecycle-attestation (&key transaction-id version-hash proof-hash
                                        prior-status status actor time generation
                                        reason previous-attestation-hash extra)
  (let* ((core (list :schema-version 1
                     :record-kind :lifecycle-attestation
                     :transaction-id transaction-id
                     :version-hash version-hash
                     :proof-hash proof-hash
                     :prior-status prior-status
                     :status status
                     :actor actor
                     :time time
                     :generation generation
                     :reason reason
                     :previous-attestation-hash previous-attestation-hash
                     :extra (copy-tree (or extra '()))))
         (hash (canonical-hash core)))
    (append core (list :attestation-hash hash))))

(defun lifecycle-attestation-valid-p (attestation)
  (and (listp attestation)
       (= (pget attestation :schema-version 0) 1)
       (eq (pget attestation :record-kind) :lifecycle-attestation)
       (stringp (pget attestation :attestation-hash))
       (string= (pget attestation :attestation-hash)
                (canonical-hash
                 (plist-without attestation :attestation-hash)))))
