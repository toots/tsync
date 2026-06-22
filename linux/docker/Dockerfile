FROM debian:bookworm-slim

ENV OPAMROOTISOK=1

RUN apt-get update && apt-get install -y \
    opam git libfuse3-dev fuse awscli pkg-config \
    libgmp-dev libssl-dev jq curl unzip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

COPY tsync.opam .

RUN opam init --disable-sandboxing -y && \
    opam pin add -ny git+https://github.com/toots/aws-s3.git && \
    opam pin add -ny git+https://github.com/toots/ocamlfuse.git && \
    opam install --deps-only -y . && \
    opam clean -a -c -s

COPY . .

RUN opam install -y . && \
    opam clean -a -c -s

WORKDIR /workspace

RUN echo 'eval $(opam env)' >> /root/.bashrc

CMD ["bash"]
