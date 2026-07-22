# ourro cloud QA loop (qa/docs/plan-cloud-qa.md).
#
# One container runs everything: the conductor (qa/bin/ourro-loop) plus the
# subject/operator ourro instances it spawns in tmux panes. The build itself
# is the Linux port's proof: the supervisor build and the full FiveAM suite
# run at image-build time, so an image that builds is an image whose product
# works on this platform (verified green on debian/arm64 — matches Graviton
# EC2).
#
#   docker build -f qa/deploy/Dockerfile -t ourro-loop .
#   docker compose -f qa/deploy/docker-compose.yml up -d
FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    sbcl tmux git gh make curl ca-certificates procps \
    python3 python3-venv nodejs npm \
    && rm -rf /var/lib/apt/lists/*

# Quicklisp + project deps as a cached layer (invalidated only when the dep
# list changes, not on every source edit).
RUN curl -fsSL https://beta.quicklisp.org/quicklisp.lisp -o /tmp/quicklisp.lisp \
    && sbcl --non-interactive --load /tmp/quicklisp.lisp \
        --eval '(quicklisp-quickstart:install)' \
        --eval '(ql:quickload (list :bordeaux-threads :dexador :com.inuoe.jzon :fiveam :cl-ppcre) :silent t)' \
    && rm /tmp/quicklisp.lisp

WORKDIR /ourro
COPY . .

# The build gate: supervisor binary + the full test suite, on Linux.
RUN make supervisor
RUN make test

# Durable loop state (loop-state, ledgers, evidence) lives on a volume;
# missions/fixtures/genome seeds ship with the image.
ENV OURRO_LOOP_ROOT=/data/ourro-loop
VOLUME /data

# git identity for the ourro instances' workspace commits.
RUN git config --global user.email "qa-loop@ourro" \
    && git config --global user.name "ourro QA loop" \
    && git config --global --add safe.directory /ourro

ENTRYPOINT ["qa/deploy/entrypoint.sh"]
CMD ["run"]
