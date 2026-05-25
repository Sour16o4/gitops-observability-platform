# ==============================================================================
# STAGE 1: Builder
# ==============================================================================
# Why alpine? Alpine is extremely lightweight and contains minimal overhead, 
# making the build process faster.
FROM golang:1.22-alpine AS builder

# Set working directory inside the builder container
WORKDIR /build

# Copy go.mod and go.sum first to leverage Docker layer caching.
# If these files haven't changed, Docker skips downloading dependencies.
COPY go.mod go.sum ./
RUN go mod download

# Copy the rest of the application source code
COPY main.go ./

# Compile the application.
# Operational parameters explained:
#   CGO_ENABLED=0
#       → Disable dynamically linked C library bindings.
#       → Creates a fully self-contained statically compiled binary.
#       → Allows running in minimal environments (like Alpine or scratch) 
#         without requiring glibc dependencies.
#   GOOS=linux
#       → Target the Linux operating system (since K8s runs Linux nodes).
#   -ldflags="-s -w"
#       → -s: Strips symbol table information (debug symbols).
#       → -w: Strips DWARF debug information.
#       → This significantly reduces binary size (up to 40% reduction), 
#         reducing network transit and container startup times.
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o demo-app main.go

# ==============================================================================
# STAGE 2: Final Run-Time Environment
# ==============================================================================
# Why a new stage? We don't need the Go compiler or dev dependencies in the run-time container.
# Removing the builder tools drops the image size from ~300MB to ~15MB.
# This reduces the image's attack surface (no curl, go compiler, or build-essential to aid exploits).
FROM alpine:3.19

# Set working directory for runtime execution
WORKDIR /app

# Create a non-root group and user.
# Why this matters in production:
# - By default, Docker runs processes inside containers as "root" (UID 0).
# - If an attacker breaks out of the container or exploits a kernel CVE, they automatically
#   gain root access to the underlying host.
# - Running as an unprivileged user (UID 10001) mitigates host escalation threats.
RUN addgroup -g 10001 -S appgroup && \
    adduser -u 10001 -S appuser -G appgroup

# Copy the statically compiled binary from the builder stage.
# Only the binary is carried over, leaving build garbage behind.
COPY --from=builder /build/demo-app .

# Set container permissions to run strictly under our non-root user credentials.
USER 10001:10001

# The application listens on port 8080 by default.
EXPOSE 8080

# Configure environment variables
ENV PORT=8080 \
    GO_ENV=production

# Run the statically compiled Go web server
ENTRYPOINT ["/app/demo-app"]
