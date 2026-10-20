#!/bin/sh
# Regenerate Go and Swift code from contracts/grpc. Generated files are committed.
# Requires: buf, protoc-gen-go, protoc-gen-go-grpc, and the Swift plugins on PATH:
#   protoc-gen-swift (apple/swift-protobuf 1.39.0)
#   protoc-gen-grpc-swift-2 (grpc/grpc-swift-protobuf 2.5.0)
# Build the Swift plugins with: swift build -c release --product <name>
# Go plugins: buf v1.65.0, protoc-gen-go v1.36.11, protoc-gen-go-grpc v1.6.1.
# CI (.github/workflows/core.yml) regenerates with these versions and fails
# when the committed code differs.
set -eu
cd "$(dirname "$0")/.."
buf lint
buf generate
