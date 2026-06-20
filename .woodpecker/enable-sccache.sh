#!/bin/sh
# Patches the freshly-cloned upstream llama.cpp CUDA Dockerfile so that C/C++ and
# CUDA compilation is routed through sccache with an S3 backend. This gives us
# fine-grained compile caching across builds, which survives even when Kaniko's
# layer cache misses (e.g. any source change in a new release tag).
#
# We patch the upstream file in place rather than maintaining a fork, keeping us
# at 100% parity with the official Dockerfile apart from the sccache wiring.
#
# Usage: enable-sccache.sh <path-to-cuda.Dockerfile>
set -eu

DF="${1:?usage: enable-sccache.sh <dockerfile>}"

awk '
  # Declare the sccache/S3 build args + env right after the build stage FROM so
  # the sccache server can read its config and credentials from the environment.
  /^FROM .* AS build$/ {
    print
    print ""
    print "# --- sccache integration (injected by llama-release-watcher) ---"
    print "ARG SCCACHE_VERSION=0.16.0"
    print "ARG SCCACHE_BUCKET"
    print "ARG SCCACHE_ENDPOINT"
    print "ARG SCCACHE_REGION=auto"
    print "ARG SCCACHE_S3_USE_SSL=true"
    print "ARG SCCACHE_S3_KEY_PREFIX"
    print "ARG AWS_ACCESS_KEY_ID"
    print "ARG AWS_SECRET_ACCESS_KEY"
    print "ENV SCCACHE_BUCKET=${SCCACHE_BUCKET} \\"
    print "    SCCACHE_ENDPOINT=${SCCACHE_ENDPOINT} \\"
    print "    SCCACHE_REGION=${SCCACHE_REGION} \\"
    print "    SCCACHE_S3_USE_SSL=${SCCACHE_S3_USE_SSL} \\"
    print "    SCCACHE_S3_KEY_PREFIX=${SCCACHE_S3_KEY_PREFIX} \\"
    print "    AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} \\"
    print "    AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}"
    next
  }

  # curl + ca-certificates are needed to download the sccache release tarball.
  /apt-get install -y gcc-14/ {
    sub(/libgomp1/, "libgomp1 curl ca-certificates")
  }

  # Install the sccache binary right after the compiler env is set.
  /^ENV CC=gcc-14/ {
    print
    print ""
    print "RUN curl -fsSL -o /tmp/sccache.tar.gz \\"
    print "      \"https://github.com/mozilla/sccache/releases/download/v${SCCACHE_VERSION}/sccache-v${SCCACHE_VERSION}-x86_64-unknown-linux-musl.tar.gz\" \\"
    print "    && tar -xzf /tmp/sccache.tar.gz -C /tmp \\"
    print "    && install -m0755 \"/tmp/sccache-v${SCCACHE_VERSION}-x86_64-unknown-linux-musl/sccache\" /usr/local/bin/sccache \\"
    print "    && rm -rf /tmp/sccache.tar.gz \"/tmp/sccache-v${SCCACHE_VERSION}-x86_64-unknown-linux-musl\" \\"
    print "    && sccache --version \\"
    print "    && echo \"==> sccache enabled: bucket=${SCCACHE_BUCKET} endpoint=${SCCACHE_ENDPOINT} region=${SCCACHE_REGION} ssl=${SCCACHE_S3_USE_SSL}\""
    next
  }

  # Route C/C++ AND CUDA compilation through sccache. nvcc caching previously
  # broke at the multi-arch fatbinary step with "Could not open input file
  # *.ptx" on sccache 0.10/0.16; the theory is a parallel per-arch temp-file
  # race that the sccache --dryrun decomposition cannot reproduce, so we force
  # nvcc single-threaded (--threads=1) to make it deterministic. If CUDA still
  # breaks, drop the CUDA launcher and CUDA_FLAGS below to cache only C/C++.
  /-DLLAMA_BUILD_TESTS=OFF/ {
    sub(/-DLLAMA_BUILD_TESTS=OFF/, "-DLLAMA_BUILD_TESTS=OFF -DCMAKE_C_COMPILER_LAUNCHER=sccache -DCMAKE_CXX_COMPILER_LAUNCHER=sccache -DCMAKE_CUDA_COMPILER_LAUNCHER=sccache -DCMAKE_CUDA_FLAGS=--threads=1")
  }

  # Print cache hit/miss stats once the build finishes.
  /cmake --build build --config Release/ {
    sub(/$/, " \\")
    print
    print "    && sccache --show-stats"
    next
  }

  { print }
' "$DF" > "$DF.sccache.tmp"

mv "$DF.sccache.tmp" "$DF"
echo "==> Patched $DF for sccache"
