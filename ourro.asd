;;;; ourro.asd — system definitions for ourro
;;;;
;;;; Systems:
;;;;   ourro            — the agent (living image, gen N executable)
;;;;   ourro/supervisor — the tiny fixed-point process that owns the ledger
;;;;   ourro/tests      — FiveAM suites for both

(asdf:defsystem "ourro"
  :description "ourro — a self-evolving Common Lisp coding agent."
  :author "ourro"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("bordeaux-threads"
               "dexador"
               "com.inuoe.jzon"
               "fiveam"
               "cl-ppcre"
               (:require "sb-posix")
               (:require "sb-bsd-sockets")
               (:require "sb-introspect"))
  :serial t
  :components
  ((:module "src"
    :serial t
    :components
    ((:file "util")
     ;; Config (settings file) loads right after util — it depends only on
     ;; ourro.util's sexp I/O and paths, and every later module reads it.
     (:file "config")
     (:module "kernel"
      :serial t
      :components
      ((:file "conditions")
       (:file "capabilities")
       (:file "safe-read")
       ;; Gate 0 transaction core: canonical codec + framed WAL shared by the
       ;; agent and supervisor. It depends only on UTIL and safe reader data.
       (:file "transaction")
       (:file "walker")
       (:file "revert")
       (:file "protocol")
       (:file "handoff")
       (:file "selftest")))
     ;; M17: the causal journal extends the transaction codec and loads before
     ;; observation so every legacy event can be durably mirrored into it.
     (:module "reflex"
      :serial t
      :components
      ((:file "model")
       (:file "journal")))
     (:module "observe"
      :serial t
      :components
      ((:file "events")
       (:file "queue")
       (:file "ledger")
       (:file "corrections")
       (:file "miner")))
     (:module "llm"
      :serial t
      :components
      ((:file "json")
       (:file "vertex")
       (:file "eventstream")
       (:file "bedrock")))
     ;; D-2: tui loads before tools/genome so OURRO.API (genome.lisp) can
     ;; import the UI surface (pane, add-pane, define-status-widget, …) for
     ;; UI genes (M3). tui depends only on cl/ourro.util/ourro.kernel/sb-posix.
     (:module "tui"
      :serial t
      :components
      ((:file "term")
       (:file "render")
       (:file "components")
       (:file "markdown")))
     (:module "tools"
      :serial t
      :components
      ((:file "protocol")
       (:file "builtin")))
     ;; Jobs (M9): background subprocesses. Loads after tools (needs
     ;; ourro.toolkit:*workspace*) and before genome so OURRO.API can import the
     ;; job helpers for the tool/jobs seed gene.
     (:file "jobs")
     ;; Reflexes (M13): the automation substrate. Loads after jobs (its dispatch
     ;; and seed sentinel read job state) and before genome so OURRO.API can
     ;; import DEFINE-AUTOMATION / POST-NOTE / FIRE-AUTOMATION-FOR-TEST.
     (:file "automation")
     (:module "genome"
      :serial t
      :components
      ((:file "genome")
       (:file "diff")))
     (:module "verify-base"
      :pathname "verify"
      :serial t
      :components
      ((:file "verifier")))
     ;; M18 lowering/proof sits after the base verifier and before the sole
     ;; post-verifier coordinator, preventing a shorter reflex acceptance path.
     (:module "reflex-post"
      :pathname "reflex"
      :serial t
      :components
      ((:file "proof")
       (:file "compiler")
       (:file "effects")
       (:file "runtime")
       (:file "investigation")
       (:file "briefing")
       (:file "learn")
       (:file "inspector")
       (:file "pilot")))
     (:module "verify-post"
      :pathname "verify"
      :serial t
      :components
      ((:file "coordinator")
       (:file "replay")))
     (:module "evolve"
      :serial t
      :components
      ((:file "prompt")
       (:file "engine")))
     (:file "agent")
     ;; context engine (M11): token accounting + conversation compaction. In
     ;; ourro.agent, loaded after agent so it can reach the agent slots.
     (:file "context")
     ;; The intern (M15): headless read-only investigations. In ourro.agent,
     ;; loaded after agent (uses its tool/provider machinery).
     (:file "investigate")
     (:file "inspector")
     (:file "pager")
     ;; lisp_eval scratchpad (M10-5): a trusted base tool in ourro.agent; loads
     ;; after agent so *agent* + the tool-result ring exist.
     (:file "scratchpad")
     (:file "onboard")
     (:file "main")))))

(asdf:defsystem "ourro/supervisor"
  :description "ourro supervisor — ledger, image builder, crash rollback."
  :license "MIT"
  :depends-on ("bordeaux-threads"
               (:require "sb-bsd-sockets")
               (:require "sb-posix"))
  :serial t
  :components
  ((:module "src"
    :serial t
    :components
    ((:file "util")
     (:module "kernel"
      :serial t
      :components ((:file "conditions")
                   (:file "safe-read")
                   (:file "transaction")
                   (:file "protocol")))
     (:file "supervisor")))))

;;; Agent-driven QA — live-only real-workflow missions (qa/README.md).
;;; Just the tmux operator: it is deliberately standalone (CL + sb-ext +
;;; sb-posix, no ourro deps) so `sbcl --script qa/bin/ourro-qa` loads it in
;;; ~0.3s; this system exists so the test suite can exercise its pure helpers.
;;; The old scripted scenario runner / T0 backend / soak were removed on
;;; purpose — a QA run that doesn't exercise the live LLM measures nothing.
(asdf:defsystem "ourro/qa"
  :description "ourro agent-driven QA: the tmux operator CLI."
  :license "MIT"
  :serial t
  :components
  ((:module "qa/src"
    :serial t
    :components
    ((:file "operator")))
   ;; Cloud QA loop (qa/docs/plan-cloud-qa.md): mission composition for the
   ;; operator ourro instances — same standalone discipline.
   (:module "qa/loop"
    :serial t
    :components
    ((:file "compose")
     (:file "spend")
     (:file "github")
     (:file "conductor")))))

(asdf:defsystem "ourro/tests"
  :description "Test suites for ourro."
  :depends-on ("ourro" "ourro/supervisor" "ourro/qa" "fiveam")
  :serial t
  :components
  ((:module "tests"
    :serial t
    :components
    ((:file "suite")
     (:module "kernel"
      :serial t
      :components ((:file "util-test")
                   (:file "safe-read-test")
                   (:file "transaction-test")
                   (:file "walker-test")
                   (:file "revert-test")
                   (:file "handoff-test")
                   (:file "robustness-test")))
     (:module "reflex"
      :serial t
      :components ((:file "journal-test")
                   (:file "reflex-model-test")
                   (:file "reflex-compiler-test")
                   (:file "reflex-effects-test")
                   (:file "reflex-runtime-test")
                   (:file "reflex-briefing-test")
                   (:file "reflex-learn-test")
                   (:file "reflex-inspector-test")
                   (:file "reflex-pilot-test")
                   (:file "invisible-evolution-test")
                   (:file "automation-test")))
     (:module "observe"
      :serial t
      :components ((:file "events-test")
                   (:file "queue-test")
                   (:file "ledger-test")
                   (:file "corrections-test")
                   (:file "miner-test")))
     (:module "llm"
      :serial t
      :components ((:file "vertex-test")
                   (:file "eventstream-test")))
     (:module "genome"
      :serial t
      :components ((:file "genome-test")
                   (:file "diff-test")))
     (:module "verify"
      :serial t
      :components ((:file "verifier-test")
                   (:file "coordinator-test")
                   (:file "replay-test")))
     (:module "evolve"
      :serial t
      :components ((:file "evolve-test")
                   (:file "records-test")))
     (:module "tui"
      :serial t
      :components ((:file "tui-test")
                   (:file "keymap-test")
                   (:file "markdown-test")
                   (:file "ui-api-test")))
     (:module "tools"
      :serial t
      :components ((:file "tools-test")
                   (:file "parallel-tools-test")))
     (:module "agent"
      :serial t
      :components ((:file "inspector-test")
                   (:file "stream-test")
                   (:file "cancel-test")
                   (:file "pager-test")
                   (:file "help-test")
                   (:file "onboard-test")
                   (:file "scratchpad-test")
                   (:file "context-test")
                   (:file "investigate-test")
                   (:file "jobs-test")))
     (:module "qa"
      :serial t
      :components ((:file "qa-seams-test")
                   (:file "qa-operator-test")
                   (:file "qa-loop-test")
                   (:file "qa-github-test")))
     (:module "supervisor"
      :serial t
      :components ((:file "supervisor-test"))))))
  :perform (asdf:test-op (op c)
             (uiop:symbol-call :ourro.tests :run-all-tests)))
