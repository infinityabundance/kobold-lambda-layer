# Container sidecar pattern: a tiny image that runs the offline batch decoder over a shared volume.
# The primary container (rehosted COBOL job / modern service) drops fixed-length records + a copybook
# on the shared volume; this sidecar decodes them byte-exactly and emits JSON + a reconciliation
# exit code. (For a request/response sidecar, wrap kobold-batch behind a thin HTTP server.)
FROM rust:1-slim AS build
WORKDIR /src
COPY . .
RUN cargo build --release --bin kobold-batch

FROM debian:stable-slim
COPY --from=build /src/target/release/kobold-batch /usr/local/bin/kobold-batch
# LGPL notice travels with the image (see NOTICE).
COPY NOTICE /usr/share/doc/kobold-lambda-layer/NOTICE
ENTRYPOINT ["/usr/local/bin/kobold-batch"]
