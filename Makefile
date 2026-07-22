# ourro — build & run targets. `make` (or `make help`) lists them.
SBCL ?= sbcl
QL   := --eval '(load "~/quicklisp/setup.lisp")'
REG  := --eval '(push (uiop:getcwd) asdf:*central-registry*)'
DEPS := --eval '(ql:quickload (list :bordeaux-threads :dexador :com.inuoe.jzon :fiveam :cl-ppcre) :silent t)'

.PHONY: help build install test dev smoke verify-e2e supervisor clean qa-clean
.DEFAULT_GOAL := help

## Show this help.
help:
	@echo "ourro — a self-evolving Common Lisp coding agent"
	@echo ""
	@echo "  make build       build ourro from the latest source (CLEAN SLATE:"
	@echo "                   fresh image, genome re-seeded from seed-genome/)"
	@echo "  ./bin/ourro       run the agent, continuing with the existing image"
	@echo "  make install     put \`ourro\` on your PATH (~/.local/bin)"
	@echo "  make test        run the full FiveAM suite"
	@echo ""
	@echo "  development:"
	@echo "  make dev         run from source, no supervisor (fast loop)"
	@echo "  make smoke       load from source + compile the genome (CI gate)"
	@echo "  make verify-e2e  headless end-to-end proof against real images (CI gate)"
	@echo "  make clean       remove bin/ourro and *.fasl"
	@echo "  make qa-clean    sweep QA sandboxes (see qa/README.md)"
	@echo ""
	@echo "To rebuild with the latest code while KEEPING everything the agent"
	@echo "has learned: ./bin/ourro init --source-dir . --rebuild"

## Build bin/ourro and initialize $OURRO_HOME from scratch: fresh base core,
## fresh generation image, genome re-seeded from seed-genome/. This is the
## clean-slate build — learned genes are replaced by the seeds (the genome is
## a git repo, so prior generations stay recoverable in its history). To keep
## the evolved genome, use `./bin/ourro init --source-dir . --rebuild` instead.
build: supervisor
	./bin/ourro init --source-dir $(CURDIR) --force

## Build + symlink `ourro` onto your PATH so it runs from any repository.
## Does NOT touch $OURRO_HOME — installing never wipes what the agent learned.
## The workspace is wherever you launch `ourro`; the genome/learning lives in
## the global $OURRO_HOME, so evolution follows you across repositories.
BINDIR ?= $(HOME)/.local/bin
install: supervisor
	mkdir -p $(BINDIR)
	ln -sf $(CURDIR)/bin/ourro $(BINDIR)/ourro
	@echo "installed: $(BINDIR)/ourro → $(CURDIR)/bin/ourro"
	@case ":$$PATH:" in *":$(BINDIR):"*) ;; \
	  *) echo "note: add $(BINDIR) to your PATH";; esac
	@echo "run \`ourro\` from any repository to work there (make build first if \$$OURRO_HOME is uninitialized)."

## Run the full FiveAM suite.
test:
	$(SBCL) --non-interactive $(QL) $(REG) $(DEPS) \
	  --eval '(asdf:load-system "ourro/tests")' \
	  --eval '(asdf:load-system "ourro/supervisor")' \
	  --eval '(ourro.tests::run-all-tests)'

## Run the agent from source (no supervisor; fast dev loop).
dev:
	$(SBCL) --load scripts/dev-run.lisp

## Verify the source loads and the genome compiles.
smoke:
	$(SBCL) --non-interactive $(QL) $(REG) $(DEPS) \
	  --eval '(asdf:load-system "ourro")' \
	  --eval '(ourro.genome:load-genome (merge-pathnames "seed-genome/" (uiop:getcwd)))' \
	  --eval '(ourro.agent:smoke-test)'

## Headless end-to-end verification: builds a throwaway $OURRO_HOME and proves
## the supervised build + kernel-path proof against real images. No LLM.
verify-e2e:
	./scripts/verify-e2e.sh

# --- internals -------------------------------------------------------------

# Build the supervisor binary → bin/ourro (implied by build/install; also the
# Dockerfile's Linux-port build gate).
supervisor:
	$(SBCL) --non-interactive --load scripts/build-supervisor.lisp

clean:
	rm -rf bin/ourro
	find . -name '*.fasl' -delete

# Agent-driven QA — live-only real-workflow missions (qa/README.md).
# Sweep QA sandboxes, stray tmux sessions, and generated reports.
qa-clean:
	-tmux ls 2>/dev/null | grep -oE '^ourro-qa-[^:]+' | xargs -I{} tmux kill-session -t {} 2>/dev/null || true
	rm -rf /tmp/ourro-qa qa/reports
