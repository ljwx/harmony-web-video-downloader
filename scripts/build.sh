#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
DEVECO_APP_PATH="${DEVECO_APP_PATH:-/Applications/DevEco-Studio.app/Contents}"
export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-$DEVECO_APP_PATH/sdk}"
export JAVA_HOME="${JAVA_HOME:-$DEVECO_APP_PATH/jbr}"
export PATH="$DEVECO_APP_PATH/tools/node/bin:$PATH"
exec "$DEVECO_APP_PATH/tools/hvigor/bin/hvigorw" --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap --no-daemon
