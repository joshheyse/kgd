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
check: build vet test c-check

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

# Build C client library
c-build:
    clang -Wall -Wextra -Werror -pedantic -std=c11 \
      -DMPACK_NODE=0 -DMPACK_EXTENSIONS=0 \
      -c clients/c/kgd.c -o clients/c/kgd.o

# Run clang-tidy and cppcheck on C client
c-lint:
    clang-tidy clients/c/kgd.c -- -std=c11 \
      -DMPACK_NODE=0 -DMPACK_EXTENSIONS=0
    cppcheck --enable=all --error-exitcode=1 \
      --suppress=missingIncludeSystem clients/c/kgd.c

# Run C unit tests with ASan + UBSan
c-test:
    clang -Wall -Wextra -std=c11 -g \
      -DMPACK_NODE=0 -DMPACK_EXTENSIONS=0 \
      -fsanitize=address,undefined -fno-omit-frame-pointer \
      clients/c/mpack.c clients/c/kgd_test.c \
      -o clients/c/kgd_test_bin -lpthread
    clients/c/kgd_test_bin

# Run C tests with thread sanitizer
c-test-tsan:
    clang -Wall -Wextra -std=c11 -g \
      -DMPACK_NODE=0 -DMPACK_EXTENSIONS=0 \
      -fsanitize=thread -fno-omit-frame-pointer \
      clients/c/mpack.c clients/c/kgd_test.c \
      -o clients/c/kgd_test_tsan -lpthread
    clients/c/kgd_test_tsan

# Run C fuzz tests (60s default)
c-fuzz:
    clang -Wall -Wextra -std=c11 -g \
      -DMPACK_NODE=0 -DMPACK_EXTENSIONS=0 \
      -fsanitize=fuzzer,address,undefined -fno-omit-frame-pointer \
      clients/c/mpack.c clients/c/fuzz_msgpack.c \
      -o clients/c/fuzz_bin -lpthread
    mkdir -p clients/c/corpus
    clients/c/fuzz_bin clients/c/corpus -max_total_time=60

# Full C pipeline: lint, build, test
c-check: c-lint c-build c-test

# Run Rust client tests
rust-check:
    cd clients/rust && cargo test && cargo clippy -- -D warnings

# Run Node.js client tests
node-check:
    cd clients/nodejs && npm test

# Run Lua client tests
lua-test:
    cd clients/lua && busted spec/

# Run Zig client tests
zig-check:
    cd clients/zig && zig build test

# Run Swift client tests
swift-check:
    cd clients/swift && swift test

# Run JVM/Kotlin client tests
jvm-check:
    cd clients/jvm && ./gradlew test

# Run .NET client tests
dotnet-check:
    cd clients/dotnet && dotnet test

# Run OCaml client tests
ocaml-check:
    cd clients/ocaml && dune runtest

# Run all client library tests
clients-check: c-check rust-check node-check lua-test zig-check swift-check jvm-check dotnet-check ocaml-check
