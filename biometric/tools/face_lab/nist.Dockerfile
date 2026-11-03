# Development compatibility lane. Final qualification also uses NIST's specified OS image.
FROM --platform=linux/amd64 ubuntu@sha256:f610ab94648195aa356059f5b41d6085c9d4d903c072430cdd1af7bdb646106b
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    binutils ca-certificates cmake file g++-13 libssl-dev ninja-build \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 nistdev
USER nistdev
ENV CXX=g++-13
WORKDIR /work
