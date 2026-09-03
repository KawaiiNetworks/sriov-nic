#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

"$TEST_DIR/test-sf-functions.sh"
"$TEST_DIR/test-config-conflict.sh"
"$TEST_DIR/test-manage-sf.sh"
