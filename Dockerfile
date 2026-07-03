FROM ubuntu:26.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      emacs-nox curl git ca-certificates unzip && \
    rm -rf /var/lib/apt/lists/* && \
    curl -fsSL https://raw.githubusercontent.com/emacs-eask/cli/master/webinstall/install.sh | sh

ENV PATH="/root/.local/bin:$PATH"
