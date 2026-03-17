# Build the kgd binary
build:
    go build ./cmd/kgd

# Run all tests
test:
    go test ./...

# Run tests with verbose output
test-v:
    go test -v ./...

# Run go mod tidy
tidy:
    go mod tidy

# Run go vet
vet:
    go vet ./...

# Run the daemon (foreground)
daemon:
    go run ./cmd/kgd serve

# Clean build artifacts
clean:
    rm -f kgd

# Build, vet, and test
check: build vet test

# Test image rendering end-to-end (builds, starts daemon, uploads, places)
test-render: build
    ./scripts/test-render.sh

# Format all Go files
fmt:
    gofmt -w .

# Check formatting without writing
fmt-check:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "$(gofmt -l .)" ]; then
        echo "Files not formatted:"
        gofmt -l .
        exit 1
    fi
