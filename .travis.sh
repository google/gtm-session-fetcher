#!/usr/bin/env bash

set -eu

if [[ "$#" -ne 2 ]]; then
  echo "Usage: $0 {iOS|OSX|tvOS|watchOS|swiftpm} {Debug|Release|Both}"
  exit 10
fi

BUILD_MODE="$1"
BUILD_CFG="$2"

# Report then run the build
RunXcodeBuild() {
  echo xcodebuild "$@"
  xcodebuild "$@"
}

# Report then run the build
RunSwift() {
  echo swift "$@"
  swift "$@"
}

# Default to xcodebuild
BUILD_TOOL="xcodebuild"

# Helpers to build up xcodebuild commands
XCODE_CMD_BUILDER=(
  -project Source/GTMSessionFetcherCore.xcodeproj
)
XCODE_ACTIONS=(
  build test
)

case "${BUILD_MODE}" in
  iOS)
    XCODE_CMD_BUILDER+=(
        -scheme "iOS Framework"
        -destination "platform=iOS Simulator,name=iPhone 8,OS=latest"
    )
    ;;
  OSX)
    XCODE_CMD_BUILDER+=(-scheme "OS X Framework")
    ;;
  tvOS)
    XCODE_CMD_BUILDER+=(
        -scheme "tvOS Framework"
        -destination "platform=tvOS Simulator,name=Apple TV,OS=latest"
    )
    ;;
  watchOS)
    XCODE_CMD_BUILDER+=(-scheme "watchOS Framework")
    # XCTest doesn't support watchOS.
    XCODE_ACTIONS=( build )
    ;;
  swiftpm)
    BUILD_TOOL="swift"
    ;;
  *)
    echo "Unknown BUILD_MODE: ${BUILD_MODE}"
    exit 11
    ;;
esac

declare -a CMD_CONFIGS
case "${BUILD_CFG}" in
  Debug|Release)
    CMD_CONFIGS+=("${BUILD_CFG}")
    ;;
  Both)
    CMD_CONFIGS+=("Debug" "Release")
    ;;
  *)
    echo "Unknown BUILD_CFG: ${BUILD_CFG}"
    exit 12
    ;;
esac

# Loop over the command configs (Debug|Release)
for CMD_CONFIG in "${CMD_CONFIGS[@]}"; do
  case "${BUILD_TOOL}" in
    xcodebuild)
      RunXcodeBuild "${XCODE_CMD_BUILDER[@]}" -configuration "${CMD_CONFIG}" "${XCODE_ACTIONS[@]}"
      ;;
    swift)
      LOWER_CMD_CONFIG="$(echo "${CMD_CONFIG}" | tr "[:upper:]" "[:lower:]")"
      RunSwift build --configuration "${LOWER_CMD_CONFIG}"
      RunSwift test --configuration "${LOWER_CMD_CONFIG}"
      ;;
    *)
      echo "Unknown BUILD_TOOL: ${BUILD_TOOL}"
      exit 13
      ;;
  esac
done
