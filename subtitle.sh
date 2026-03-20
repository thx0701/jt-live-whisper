#!/bin/bash
# 啟動浮動字幕 overlay（可飄在全螢幕上）
cd "$(dirname "$0")"
./subtitle-overlay &
echo "字幕 overlay 已啟動（PID: $!）"
echo "關閉方式: kill $!"
