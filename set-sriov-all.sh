#!/bin/bash

set -e

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 启用 nullglob 以防止没有匹配文件时把模式当作文件名
shopt -s nullglob

# 遍历同目录下所有 sriov-nic.conf* 文件
for config_file in "$SCRIPT_DIR"/sriov-nic.conf*; do
    if [ -f "$config_file" ]; then
        echo "Found config file: $config_file"
        echo "Executing set-sriov.sh for $config_file..."
        "$SCRIPT_DIR/set-sriov.sh" "$config_file"
    fi
done
