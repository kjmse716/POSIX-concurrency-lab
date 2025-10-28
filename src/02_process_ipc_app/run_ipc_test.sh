#!/bin/bash

# 取得此腳本所在的目錄，確保我們總是在正確的路徑下執行
# This ensures that we always execute the binaries from the correct directory,
# regardless of where this script is called from.
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# 使用絕對路徑來執行 consumer 和 producer
"$DIR/consumer" &
"$DIR/producer"

# 等待背景的 consumer 程式結束
wait