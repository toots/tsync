FROM debian:bookworm-slim

ENV OPAMROOTISOK=1

RUN apt-get update && apt-get install -y \
    opam git libfuse3-dev fuse awscli pkg-config \
    libgmp-dev libssl-dev jq curl unzip libxxhash-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

COPY opam/ .

# Init opam with no default switch (--bare), then create a local switch.
# opam reads tsync.opam's OCaml constraint (>= 5.5.0) to select the compiler.
RUN opam init --bare --disable-sandboxing -y && \
    opam switch create . --no-install -y

# Make all subsequent RUN commands use this local switch
ENV OPAMSWITCH=/src

RUN opam pin add -ny git+https://github.com/toots/aws-s3.git && \
    opam pin add -ny git+https://github.com/toots/ocamlfuse.git && \
    opam install --deps-only -y . && \
    opam clean -a -c -s

COPY . .

RUN opam install -y . && \
    opam clean -a -c -s

WORKDIR /workspace

RUN echo 'eval $(opam env --switch=/src)' >> /root/.bashrc

CMD ["bash"]
