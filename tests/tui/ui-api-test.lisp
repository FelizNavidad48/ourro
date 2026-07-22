(in-package #:ourro.tests)

(def-suite ui-api-suite :in ourro)
(in-suite ui-api-suite)


(test walker-demands-ui
  ;; A gene naming ADD-PANE / DEFINE-STATUS-WIDGET without declaring :ui is
  ;; rejected; declaring :ui clears it. Matching is by symbol NAME, so the
  ;; unqualified symbols read here are caught the same as OURRO.API's.
  (let ((body '((define-status-widget clock (:interval 1) "x")
                (add-pane (make-instance 'pane)))))
    (let ((violations (ourro.kernel:lint-gene-body body :capabilities '())))
      (is-true violations)
      (is (search ":UI" (ourro.kernel:lint-violations violations))))
    (is-false (ourro.kernel:lint-gene-body body :capabilities '(:ui)))
    ;; :ui is a valid declarable capability.
    (is-true (ourro.kernel:capability-p :ui))))


(defparameter *staged-ui-gene*
  "(defgene ui/staged-probe
    (:generation 1 :parent nil :capabilities (:ui)
     :provenance (:seed t))
  (:doc \"A trivial status widget used to prove staging isolation.\")
  (:code
   (define-status-widget staged-probe (:interval 1) \"probe\"))
  (:tests
   (test staged-probe/loads (is-true t))))")

(test staged-verification-leaves-live-ui-untouched
  (ensure-seed-genome-loaded)
  (let ((ourro.tui:*status-widgets* '())
        (ourro.tui:*active-view* (ourro.tui:make-view)))
    ;; The gene registers a widget at LOAD time; the gauntlet stages that load
    ;; against throwaway UI state, so the live table stays empty.
    (multiple-value-bind (gene report) (ourro.verify:verify-gene-text *staged-ui-gene*)
      (declare (ignore report))
      (is-true gene))
    (is (null ourro.tui:*status-widgets*))
    (is (null (ourro.tui:view-panes ourro.tui:*active-view*)))))


(test widget-strike-out-reverts-gene
  (let ((ourro.tui:*status-widgets* '())
        (reverted nil)
        (amber nil))
    ;; A widget whose fn always errors, owned by a gene with a revert-action.
    (ourro.kernel:record-revert-action "ui/boom" (lambda () (setf reverted t)))
    (ourro.tui:register-status-widget 'boom 0 (lambda () (error "boom"))
                                     :gene "ui/boom")
    (let ((ourro.kernel:*probation-failure-hook*
            (lambda (gene condition)
              (declare (ignore condition))
              (setf amber gene))))
      (let ((retire nil))
        ;; Force each refresh to be due (interval is floored to 1s), so three
        ;; consecutive refreshes strike the widget out.
        (dotimes (i 3)
          (setf (getf (cdr (assoc 'boom ourro.tui:*status-widgets*)) :next-refresh) 0)
          (setf retire (ourro.tui:refresh-status-widgets)))
        (is-true retire)
        (ourro.tui::process-ui-retirements retire ourro.tui:*active-view*)))
    (is-true reverted)                          ; the gene's revert-action ran
    (is (equal "ui/boom" amber))                ; amber ticker fired for it
    ;; The widget's own revert-action removed it from the live table too.
    (is (null (assoc 'boom ourro.tui:*status-widgets*)))))

(test healthy-widget-caches-and-renders
  (let ((ourro.tui:*status-widgets* '()))
    (ourro.tui:register-status-widget 'greet 5 (lambda () "hi") :gene nil)
    (ourro.tui:refresh-status-widgets)
    (is (member "hi" (ourro.tui:status-widget-cells) :test #'string=))
    ;; A widget returning "" contributes no cell.
    (ourro.tui:register-status-widget 'blank 5 (lambda () "") :gene nil)
    (ourro.tui:refresh-status-widgets)
    (is (member "hi" (ourro.tui:status-widget-cells) :test #'string=))
    (is (= 1 (length (ourro.tui:status-widget-cells))))))

(test widget-revert-is-owner-scoped
  ;; Reverting gene A must not delete gene B's same-named widget (review #2):
  ;; A's revert-action is owner-checked, so a name collision is safe.
  (let ((ourro.tui:*status-widgets* '()))
    (ourro.tui:register-status-widget 'clock 5 (lambda () "A") :gene "ui/a")
    (ourro.tui:register-status-widget 'clock 5 (lambda () "B") :gene "ui/b")
    ;; B's registration evicted A's; the live 'clock is now B's.
    (let ((entry (assoc 'clock ourro.tui:*status-widgets*)))
      (is (equal "ui/b" (getf (cdr entry) :gene))))
    ;; Reverting A leaves B's widget intact (owner mismatch → no-op).
    (ourro.kernel:revert-gene-definitions "ui/a")
    (let ((entry (assoc 'clock ourro.tui:*status-widgets*)))
      (is-true entry)
      (is (equal "ui/b" (getf (cdr entry) :gene))))
    ;; Reverting B removes it (owner matches).
    (ourro.kernel:revert-gene-definitions "ui/b")
    (is (null (assoc 'clock ourro.tui:*status-widgets*)))))


(test pane-render-error-degrades-then-retires
  (eval '(defclass ui-bad-pane (ourro.tui:pane) ()))
  (eval '(defmethod ourro.tui:render-component ((p ui-bad-pane) width)
           (declare (ignore width))
           (error "render boom")))
  (let ((view (ourro.tui:make-view))
        (pane (make-instance 'ui-bad-pane)))
    (ourro.tui:add-pane pane :view view)
    ;; First two frames: no lines (never a torn frame), not yet retired.
    (dotimes (i 2)
      (multiple-value-bind (lines retire) (ourro.tui::render-panes view 40)
        (is (null lines))
        (is (null retire))))
    ;; Third strike queues the pane for retirement.
    (multiple-value-bind (lines retire) (ourro.tui::render-panes view 40)
      (declare (ignore lines))
      (is-true retire))))


(test uifrc-live-instance-migrates
  ;; Define a pane subclass, instantiate it, then redefine the class with a
  ;; new defaulted slot. UPDATE-INSTANCE-FOR-REDEFINED-CLASS migrates the SAME
  ;; object in place on next access — the standard is the demo.
  (eval '(defclass ui-mig-pane (ourro.tui:pane)
           ((a :initform 1 :accessor mig-a))))
  (let ((instance (make-instance 'ui-mig-pane)))
    (is (= 1 (funcall (symbol-function 'mig-a) instance)))
    (eval '(defclass ui-mig-pane (ourro.tui:pane)
             ((a :initform 1 :accessor mig-a)
              (b :initform 42 :accessor mig-b))))
    ;; The same instance now answers the new slot with its initform.
    (is (= 42 (funcall (symbol-function 'mig-b) instance)))
    (is (= 1 (funcall (symbol-function 'mig-a) instance)))
    (is (typep instance 'ourro.tui:pane))))
