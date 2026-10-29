#!/bin/bash
#
# 控制后台运行的 loopbackPost（app 模式没有终端，用信号代替按键）。
#
#   ./ctl.sh up          音量 +      (相当于 ↑)
#   ./ctl.sh down        音量 -      (相当于 ↓)
#   ./ctl.sh reconnect   重连        (相当于回车)
#   ./ctl.sh quit        退出        (相当于 Ctrl+C)
#   ./ctl.sh status      看状态和最近日志
#
set -uo pipefail

cd "$(dirname "$0")"

PID=$(pgrep -f "loopbackPost.app/Contents/MacOS/loopbackPost" | head -1 || true)

if [[ -z "${PID}" ]]; then
    echo "没有在运行（先 ./start.sh <地址>）" >&2
    exit 1
fi

case "${1:-status}" in
    up)
        kill -USR1 "$PID" && echo "音量 +"
        ;;
    down)
        kill -USR2 "$PID" && echo "音量 -"
        ;;
    reconnect)
        kill -HUP "$PID" && echo "已请求重连"
        ;;
    quit)
        kill -TERM "$PID" && echo "已退出"
        ;;
    status)
        echo "pid $PID"
        echo "--- 最近日志 ---"
        tail -n 20 /tmp/loopbackPost.log 2>/dev/null
        ;;
    *)
        echo "用法: ./ctl.sh up | down | reconnect | quit | status" >&2
        exit 1
        ;;
esac
