#!/bin/sh
# Regenerate Go and Swift code from contracts/grpc. Generated files are committed.
# Requires: buf, protoc-gen-go, protoc-gen-go-grpc, and the Swift plugins on PATH:
#   protoc-gen-swift (apple/swift-protobuf 1.39.0)
#   protoc-gen-grpc-swift-2 (grpc/grpc-swift-protobuf 2.5.0)
# Build the Swift plugins with: swift build -c release --product <name>
set -eu
cd "$(dirname "$0")/.."
buf lint
buf generate
