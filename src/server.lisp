;;;; server.lisp
;;;;
;;;; Author: Eric Peterson
;;;;
;;;; Lisp mimic of the python JSON RPC Server.

;;
;; Suppose you've written some collection of functions, like
;;
;; (defun my-first-function (&keys (argA valA) (argB valB) ...)
;;   ...)
;; (defun my-second-function (&keys (arg1 val1) (arg2 val2) ...)
;;   ...)
;; ...
;;
;; and you want to build a compute resource that other remote processes can
;; access.  You're in luck!  This file will help you set up an RPCQ server
;; process that administers access to your favorite collection of functions.
;;
;; The primary method involved is START-SERVER, which amounts to the main loop
;; of the server.  In addition to the usual server-y parameters (listening
;; endpoint, number of worker threads, time limits, ...), it takes a
;; DISPATCH-TABLE, which is populated with the list of functions you wish to
;; service for RPC clients.
;;
;; We may set up an RPC server (at the default endpoint, with the default number
;; of workers, with the default time limit ) that delivers on the function calls
;; defined above using the following snippet:
;;
;; (let ((dt (make-dispatch-table)))
;;   (dispatch-table-add-handler dt 'my-first-function)
;;   (dispatch-table-add-handler dt 'my-second-function)
;;   ...
;;   (dispatch-table-add-handler dt 'my-nth-function)
;;   (start-server :dispatch-table dt))
;;
;; Whenever the server receives an RPC call from a client, it browses its
;; dispatch table, retrieves the corresponding function (or signals failure to
;; the client), evaluates the function with the client-supplied parameters,
;; and replies with the result.
;;
;; NOTE: Both the arguments and the return value of functions in the dispatch
;; table must either be JSONifiable Lisp types (numbers, strings, lists, hashes)
;; or they must be RPCQ objects defined (on both the client and the server
;; process) via DEFMESSAGE.
;;

(in-package #:rpcq)

(defstruct server-auth-config
  "Holds the ZeroMQ Curve configuration for a server socket."
  (server-secret-key (error "Must provide SERVER-SECRET-KEY") :type string :read-only t))

(deftype dispatch-table ()
  'hash-table)

(defun make-dispatch-table ()
  "Make an empty DISPATCH-TABLE, suitable for use with DISPATCH-TABLE-ADD-HANDLER and START-SERVER."
  (make-hash-table :test #'equal))

(defun dispatch-table-add-handler (dispatch-table f
                                   &key
                                     (name (string f)))
  "Add a function F to DISPATCH-TABLE, for use by an RPCQ server.  The function F is expected to take only keyword arguments.

By default, a symbol passed in for F will be automatically converted into the name of F used in the dispatch table.  To manually specify a name (or to provide a name for a non-symbol value of F), use the keyword argument :NAME."
  (check-type name string)
  (unless (global-function-p f)
    (warn "The symbol ~S doesn't name a global function." f))
  (setf (gethash (sanitize-name name) dispatch-table) f)
  nil)


(defun %pull-raw-request (receiver)
  "Pulls a ZMQ request over the RECEIVER socket.  Returns a VALUES triple:

* IDENTITY-FRAME: array of (UNSIGNED-BYTE 8) that describes the intended recipient of a reply to this request.
* NULL-FRAME?:    boolean indicating whether the recipient expects an additional null frame after the identity frame. (This is the case for REQ-type clients.)
* PAYLOAD:        array of (UNSIGNED-BYTE 8) that houses the raw request."
  ;; ZeroMQ requests come in one of two flavors:
  ;;
  ;;   (1) identity frame, null frame, data frame
  ;;   (2) identity frame, data frame
  ;;
  ;; whichever we get, we also have to reply in the same way, so we track the
  ;; format in addition to the data.
  (let (identity)
    (pzmq:with-message msg
      (pzmq:msg-recv msg receiver)
      (setf identity (unpack-foreign-msg-to-bytes msg)))
    (assert (pzmq:getsockopt receiver :rcvmore))
    (pzmq:with-message msg
      (pzmq:msg-recv msg receiver)
      (cond
        ((pzmq:getsockopt receiver :rcvmore)
         (assert (zerop (pzmq:msg-size msg)))
         (pzmq:with-message msg
           (assert (not (pzmq:getsockopt receiver :rcvmore)))
           (values
            identity
            t
            (unpack-foreign-msg-to-bytes msg))))
        (t
         (values
          identity
          nil
          (unpack-foreign-msg-to-bytes msg)))))))

(defun %push-raw-request (socket identity null-frame? payload)
  "Pushes a ZMQ reply onto SOCKET.  Takes the following values:

* IDENTITY:    array of (UNSIGNED-BYTE 8) that describes the inteded recipient of the reply.  Copy this from the matching %PULL-RAW-REQUEST.
* NULL-FRAME?: boolean indicating whether the recipient expects an additional null frame after the identity frame. Copy this from the matching %PULL-RAW-REQUEST.
* PAYLOAD:     array of (UNSIGNED-BYTE 8) that houses the raw reply."
  ;; transmit messages
  (cffi:with-foreign-objects ((foreign-identity ':uint8 (length identity))
                              (foreign-payload ':uint8 (length payload)))
    (dotimes (j (length identity))
      (setf (cffi:mem-aref foreign-identity ':uint8 j)
            (aref identity j)))
    (dotimes (j (length payload))
      (setf (cffi:mem-aref foreign-payload ':uint8 j)
            (aref payload j)))
    (pzmq:send socket foreign-identity :len (length identity) :sndmore t)
    (when null-frame?
      (pzmq:send socket "" :len 0 :sndmore t))
    (pzmq:send socket foreign-payload :len (length payload) :sndmore nil))
  nil)


(define-condition not-an-rpcrequest (simple-error)
  ((object :initarg :object :reader not-an-rpcrequest-object))
  (:documentation "While listening for an RPC call, the server received malformed information.")
  (:report (lambda (condition stream)
             (format stream "Received bad object as inbound RPC request:~%~a~&"
                     (not-an-rpcrequest-object condition)))))

(define-condition unknown-rpc-method (simple-error)
  ((method-name :initarg :method-name :reader unknown-rpc-method-name))
  (:documentation "The server received an RPC request for a method it does not recognize.")
  (:report (lambda (condition stream)
             (format stream "Received request for method \"~a\", which is not known to us."
                     (unknown-rpc-method-name condition)))))


(cl-syslog:define-structured-data-id |rigetti@0000| ()
  |methodName|
  |requestID|
  |wallTime|
  |error|)


(defun log-completion-message (logger request reply start-time)
  (macrolet ((log-it (priority control &rest args)
               `(cl-syslog:rfc-log
                    (logger ,priority ,control ,@args)
                  (:msgid "LOG0002")
                  (|rigetti@0000|
                   |methodName| (|RPCRequest-method| request)
                   |requestID| (|RPCRequest-id| request)
                   |wallTime| (format nil "~f" (/ (- (get-internal-real-time) start-time)
                                                  internal-time-units-per-second))
                   |error| ,(if (<= (cl-syslog:get-priority priority)
                                    (cl-syslog:get-priority ':err))
                                "true"
                                "false")))))
    (etypecase reply
      (|RPCReply|
       (log-it :info "Requested ~a completed" (|RPCRequest-method| request)))
      (|RPCError|
       (log-it :err "Request ~a error: ~a" (|RPCRequest-id| request) (|RPCError-error| reply))))))


(defvar *warnings*)
(setf (documentation '*warnings* 'variable)
      "An adjustable array of |RPCWarning|s that correspond to WARNINGs signaled during the dynamic extent of %PROCESS-RAW-REQUEST.

These warnings are included in the RPC response that is returned to the caller.

*WARNINGS* is unbound in the global environment.")

(defun %process-request (request dispatch-table timeout debug)
  "Process the given |RPCRequest| REQUEST and return either an |RPCReply| or an |RPCError|."
  (flet ((error-processor (c h)
           (declare (ignore h))
           ;; this is where error handlers go for errors where we can reply to the client
           (return-from %process-request
             (typecase c
               (unknown-rpc-method
                (make-instance '|RPCError|
                               :|id| (|RPCRequest-id| request)
                               :|error| (format nil "Method named \"~a\" is unknown."
                                                (|RPCRequest-method| request))
                               :|warnings| *warnings*))
               (bt:timeout
                (make-instance '|RPCError|
                               :|id| (|RPCRequest-id| request)
                               :|error| (format nil "Execution timed out.  Note: time limit: ~a seconds." timeout)
                               :|warnings| *warnings*))
               (otherwise
                (make-instance '|RPCError|
                               :|id| (|RPCRequest-id| request)
                               :|error| (format nil "Unhandled error in host program:~%~a" c)
                               :|warnings| *warnings*))))))
    (let ((#+sbcl sb-ext:*invoke-debugger-hook*
           #-sbcl *debugger-hook* #'error-processor)
          (kwargs-as-plist
            (loop :for key :being :the :hash-keys :of (|RPCRequest-params| request)
                    :using (hash-value val)
                  :unless (string= "*args" key)
                    :append (list (str->lisp-keyword key) val)))
          (positional-args (gethash "*args" (|RPCRequest-params| request)))
          (f (gethash (|RPCRequest-method| request) dispatch-table)))
      (unless f
        (error 'unknown-rpc-method :method-name (|RPCRequest-method| request)))
      (flet ((apply-handler ()
               (handler-bind
                   ((error (lambda (c)
                             (when debug
                               (finish-output *error-output*)
                               (trivial-backtrace:print-backtrace c :output *error-output*)))))
                 (apply f (concatenate 'list positional-args kwargs-as-plist)))))
        (let* ((client-timeout (|RPCRequest-client_timeout| request))
               ;; TODO A timeout of NIL is supposed to signal an
               ;; indefinite timeout. The same is signalled by 0,
               ;; which leads to the extra logic below and means
               ;; subtle bugs may creep in.  Can we be strict about
               ;; NIL vs 0?  I mean just look at this mess.
               (timeout (if (and client-timeout
                                 (or (null timeout)
                                     (zerop timeout)
                                     (> timeout client-timeout)))
                            client-timeout
                            timeout))
               (result (if timeout
                           (bt:with-timeout (timeout)
                             (apply-handler))
                           (apply-handler))))
          (make-instance '|RPCReply|
                         :|id| (|RPCRequest-id| request)
                         :|result| result
                         :|warnings| *warnings*))))))

(defun %process-raw-request (receiver dispatch-table logger timeout debug)
  "Read a raw request from RECEIVER, then handle it and write the result."
  (let ((*warnings* (make-array 0 :adjustable t :fill-pointer 0))
        request start-time identity empty-frame raw-request)
    (handler-bind
        ((warning (lambda (c) (vector-push-extend
                               (make-instance '|RPCWarning|
                                              :|body| (princ-to-string c)
                                              :|kind| (princ-to-string (type-of c)))
                               *warnings*))))
      (handler-bind
          ((error (lambda (c)
                    ;; we can't even reply to the client. log the error and return.
                    (cl-syslog:format-log logger ':err "Threw generic error before RPC call:~%~a" c)
                    (return-from %process-raw-request))))
        (setf (values identity empty-frame raw-request) (%pull-raw-request receiver)
              start-time (get-internal-real-time)
              request (deserialize raw-request))
        (unless (typep request '|RPCRequest|)
          (error 'not-an-rpcrequest :object request)))

      (cl-syslog:format-log logger ':info
                            "Request ~a received for ~a"
                            (|RPCRequest-id| request)
                            (|RPCRequest-method| request))

      (let ((reply (%process-request request dispatch-table timeout debug)))
        (log-completion-message logger request reply start-time)
        (handler-case
            (%push-raw-request receiver identity empty-frame (serialize reply))
          (error (c)
            (cl-syslog:format-log logger ':err
                                  "Threw generic error after RPC call, during reply encoding:~%~a" c)))))))


(defun %rpc-server-thread-worker (&key
                                    dispatch-table
                                    logger
                                    timeout
                                    debug
                                    pool-address)
  "The thread body for an RPCQ server.  Responds to RPCQ requests which match entries in DISPATCH-TABLE and writes log entries to LOGGER.

DISPATCH-TABLE and LOGGER are both required arguments.  TIMEOUT is of type (OR NULL (REAL 0)), with NIL signaling no timeout.  This timeout can be overridden by a shorter client-side timeout, provided by the RPCRequest object (see |RPCRequest-client_timeout|)."
  (pzmq:with-socket receiver :dealer
    (pzmq:connect receiver pool-address)
    (loop (%process-raw-request receiver dispatch-table logger timeout debug))))

(defun start-server (&key
                       dispatch-table
                       auth-config
                       (listen-addresses (list "tcp://*:5555"))
                       (thread-count 5)
                       (logger (make-instance 'cl-syslog:rfc5424-logger
                                              :log-writer (cl-syslog:null-log-writer)))
                       timeout
                       debug)
  "Main loop of an RPCQ server.

Argument descriptions:
 * DISPATCH-TABLE, of type DISPATCH-TABLE, registers the valid methods to which the server will respond.
 * AUTH-CONFIG is the SERVER-AUTH-CONFIG specifying keys for socket encryption.
 * LISTEN-ADDRESSES is a list of strings, each of which is a valid ZMQ interface address that the server will listen on.
 * THREAD-COUNT is a positive integer of the number of worker threads that the server will spawn to service requests.
 * LOGGER is the stream to which the worker threads will write debug information.  This stream is also forwarded to the RPC functions as *DEBUG-IO*.
 * TIMEOUT, of type (OR NULL (REAL 0)), sets the maximum duration that a thread will be allowed to work for before it is forcefully terminated.  A TIMEOUT value of NIL signals that no thread will ever be terminated for taking too long.  This timeout can be overridden by a shorter client-side timeout, provided by the RPCRequest object (see |RPCRequest-client_timeout|)."
  (check-type dispatch-table dispatch-table)
  (check-type logger cl-syslog:rfc5424-logger)
  (check-type thread-count (integer 1))
  (check-type timeout (or null (real 0)))
  (check-type debug boolean)
  (check-type listen-addresses list)
  (let ((pool-address (format nil "inproc://~a" (uuid:make-v4-uuid))))
    (cl-syslog:format-log logger ':info "Spawning server at ~a .~%" listen-addresses)
    (pzmq:with-sockets ((clients :router) (workers :dealer))
      ;; Configuring the server secret key here enables encryption on the socket and allows clients
      ;; to authenticate the server. However, this server is not currently authenticating connected
      ;; client keys. In order to do, we'd need to implement that authentication ourselves on top of
      ;; the ZeroMQ Authentication Protocol (ZAP) (unless such support is added to PZMQ).
      ;;
      ;; https://rfc.zeromq.org/spec/27/
      (when auth-config
        (pzmq:setsockopt clients :curve-server t)
        (pzmq:setsockopt clients :curve-secretkey (server-auth-config-server-secret-key auth-config)))
      (dolist (address listen-addresses)
        (pzmq:bind clients address))
      (pzmq:bind workers pool-address)
      (let ((thread-pool nil))
        (unwind-protect
             (progn
               (dotimes (j thread-count)
                 (push (bt:make-thread (lambda () (%rpc-server-thread-worker
                                                   :dispatch-table dispatch-table
                                                   :logger logger
                                                   :timeout timeout
                                                   :debug debug
                                                   :pool-address pool-address))
                                       :name (format nil "RPC-server-thread-~a" j))
                       thread-pool))
               (pzmq:device :queue clients workers))
          (mapc #'bt:destroy-thread thread-pool))))))
