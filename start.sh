#!/bin/bash
#
# 以 app 身份启动 loopbackPost。
#
# 为什么不能直接 ./loopbackPost：
#   系统音频采集的 TCC 服务是 kTCCServiceAudioCapture，授权时认的是"以 app 身份
#   启动的 bundle"。从终端直接执行 bundle 里的二进制，TCC 以终端为责任进程，
#   会被静默拒绝 —— 所有 CoreAudio 调用返回成功，但每个 buffer 全是 0。
#
# 用法: ./start.sh <地址>[,<地址>...] [额外延迟ms] [最大年龄ms] [队列上限ms]
#
set -euo pipefail

cd "$(dirname "$0")"

if [[ $# -eq 0 ]]; then
    echo "用法: ./start.sh <地址> [额外延迟ms] [最大年龄ms] [队列上限ms]" >&2
    echo "例如: ./start.sh 192.168.1.147:8080/aplay" >&2
    exit 1
fi

: > /tmp/loopbackPost.log
open "$PWD/loopbackPost.app" --args "$@"
sleep 0.6

PID=$(pgrep -f "loopbackPost.app/Contents/MacOS/loopbackPost" | head -1 || true)
if [[ -z "${PID}" ]]; then
    echo "启动失败，检查控制台日志或直接运行 ./loopbackPost.app/Contents/MacOS/loopbackPost 看报错" >&2
    exit 1
fi

echo "已启动 (pid $PID)"
echo "日志:  tail -f /tmp/loopbackPost.log"
echo "控制:  ./ctl.sh up | down | reconnect | quit"
