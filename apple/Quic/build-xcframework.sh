#!/bin/zsh
# Builds RemoteCore/Binaries/PeeringQuic.xcframework (iPhone, iOS Simulator, Mac) from this crate. Run after changing the crate or quiche's version.
set -euo pipefail
cd "${0:A:h}"
export IPHONEOS_DEPLOYMENT_TARGET=18.0 MACOSX_DEPLOYMENT_TARGET=14.0
targets=(aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin x86_64-apple-darwin)
for target in $targets; do
    cargo build --release --target $target
done

quiche_dir=$(cargo metadata --format-version 1 | python3 -c 'import json,sys; print(next(p["manifest_path"] for p in json.load(sys.stdin)["packages"] if p["name"] == "quiche").rsplit("/", 1)[0])')
rm -rf build ../RemoteCore/Binaries/PeeringQuic.xcframework
mkdir -p build/include
cp "$quiche_dir/include/quiche.h" include/peering_quic.h include/module.modulemap build/include/

# The Mac host is universal, so its two slices go into one library.
mkdir -p build/macos
lipo -create target/aarch64-apple-darwin/release/libpeering_quic.a target/x86_64-apple-darwin/release/libpeering_quic.a -output build/macos/libpeering_quic.a

arguments=()
for library in target/aarch64-apple-ios/release/libpeering_quic.a target/aarch64-apple-ios-sim/release/libpeering_quic.a build/macos/libpeering_quic.a; do
    arguments+=(-library "$library" -headers build/include)
done
xcodebuild -create-xcframework $arguments -output ../RemoteCore/Binaries/PeeringQuic.xcframework
