#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REPO=$(CDPATH= cd -- "$ROOT/../.." && pwd)
APP="$REPO/build/host-iphoneos/Build/Products/Release-iphoneos/DeadSpaceLegacy.app"
APP_NAME=DeadSpaceLegacy.app
EXECUTABLE=DeadSpaceLegacy

# Packaging modes:
#
#   (default)                   Fully unsigned. AltStore/Sideloadly/Xcode apply
#                               their own signature and entitlements.
#   --trollstore                Fakesign with the TrollStore entitlements.
#                               TrollStore keeps them when it resigns on
#                               install, and get-task-allow is what makes its
#                               "Enable JIT" option appear. Safe on every
#                               TrollStore-capable device.
#   --chimera                   Fakesign for Chimera/AppSync with permanent
#                               JIT. Intended for this iOS 12 A7 build.
#   --trollstore-permanent-jit  Backwards-compatible alias for --chimera.
MODE=unsigned
OUTPUT=

usage() {
    echo "Usage: $0 [--trollstore | --chimera | --trollstore-permanent-jit] [output.ipa]"
    echo
    echo "  --trollstore                Fakesign so TrollStore can enable JIT"
    echo "                              per launch."
    echo "  --trollstore-permanent-jit  Also embed dynamic-codesigning"
    echo "                              (A11 and older only)."
    echo "  --chimera                   Same permanent-JIT signature, named for"
    echo "                              Chimera + AppSync on iOS 12."
}

while [ $# -gt 0 ]; do
    case "$1" in
        --trollstore)
            MODE=trollstore
            ;;
        --chimera|--trollstore-permanent-jit)
            MODE=permanent
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            if [ -n "$OUTPUT" ]; then
                echo "Unexpected extra argument: $1" >&2
                exit 2
            fi
            OUTPUT=$1
            ;;
    esac
    shift
done

case "$MODE" in
    unsigned)
        ENTITLEMENTS=
        DEFAULT_OUTPUT="$REPO/dist/ApplesauceLegacy-iOS12-unsigned.ipa"
        ;;
    trollstore)
        ENTITLEMENTS="$ROOT/Config/TouchHLEHost-TrollStore.entitlements"
        DEFAULT_OUTPUT="$REPO/dist/ApplesauceLegacy-iOS12-debugger-jit.ipa"
        ;;
    permanent)
        ENTITLEMENTS="$ROOT/Config/TouchHLEHost-TrollStore-PermanentJIT.entitlements"
        DEFAULT_OUTPUT="$REPO/dist/ApplesauceLegacy-iOS12-Chimera.ipa"
        ;;
esac

[ -n "$OUTPUT" ] || OUTPUT="$DEFAULT_OUTPUT"

case "$OUTPUT" in
    /*) ;;
    *) OUTPUT="$PWD/$OUTPUT" ;;
esac

if [ -n "$ENTITLEMENTS" ]; then
    if [ ! -f "$ENTITLEMENTS" ]; then
        echo "Missing entitlements file: $ENTITLEMENTS" >&2
        exit 1
    fi
    if ! command -v ldid >/dev/null 2>&1; then
        echo "Fakesigning needs ldid (brew install ldid)." >&2
        exit 1
    fi
fi

if [ "$MODE" = permanent ]; then
    echo "WARNING: dynamic-codesigning is banned on iOS 15+ with A12 and newer" >&2
    echo "         chips (iPhone XS/XR onwards). The app will crash on launch" >&2
    echo "         there. Use --trollstore on those devices." >&2
fi

if [ ! -d "$APP" ]; then
    echo "Unsigned app not found at $APP" >&2
    echo "Run platform/ios/scripts/build-host.sh iphoneos Release first." >&2
    exit 1
fi

if codesign -dv "$APP" >/dev/null 2>&1; then
    echo "Refusing to package a signed app: $APP" >&2
    echo "Rebuild with platform/ios/scripts/build-host.sh iphoneos Release." >&2
    exit 1
fi

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/applesauce-ipa.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM

mkdir -p "$STAGE/Payload" "$(dirname -- "$OUTPUT")"
ditto "$APP" "$STAGE/Payload/$APP_NAME"
STRIP_TOOL=$(xcrun --find strip)
"$STRIP_TOOL" -S -x "$STAGE/Payload/$APP_NAME/$EXECUTABLE"

if [ -n "$ENTITLEMENTS" ]; then
    find "$STAGE/Payload/$APP_NAME/Frameworks" -type f -print | while IFS= read -r binary; do
        file "$binary" | grep -q 'Mach-O' || continue
        ldid -S "$binary"
    done
    ldid "-S$ENTITLEMENTS" "$STAGE/Payload/$APP_NAME/$EXECUTABLE"
    echo "Fakesigned with entitlements from $ENTITLEMENTS"
fi

(
    cd "$STAGE"
    /usr/bin/zip -qry "$STAGE/Applesauce.ipa" Payload
)
mv -f "$STAGE/Applesauce.ipa" "$OUTPUT"

if [ -n "$ENTITLEMENTS" ]; then
    echo "Created fakesigned IPA: $OUTPUT"
else
    echo "Created unsigned IPA: $OUTPUT"
fi
CHECKSUM="$OUTPUT.sha256"
(
    cd "$(dirname -- "$OUTPUT")"
    shasum -a 256 "$(basename -- "$OUTPUT")" >"$(basename -- "$CHECKSUM")"
)
cat "$CHECKSUM"
echo "Created checksum: $CHECKSUM"
