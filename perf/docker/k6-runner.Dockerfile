# Use official k6 image - no custom build needed
ARG K6_IMAGE=grafana/k6:0.49.0
FROM ${K6_IMAGE} AS base

# Workdir where tests will live inside the image
WORKDIR /perf

# Copy perf test suite into the image under /perf
# Expect caller to build from repo root and pass proper build context.
COPY ./perf/k6 ./k6

# Default command prints help; runners/scripts will override with `k6 run ...`
CMD ["k6", "version"]


