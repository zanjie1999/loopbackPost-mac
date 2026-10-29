#!/bin/bash
#
# 冒烟测试：起一个本地假音箱（只收 HTTP PUT，把请求体写进文件），
# 让 loopbackPost 推 DURATION 秒音频，然后校验：
#   1. 请求行是 PUT /aplay?rate=...&channels=... HTTP/1.1
#   2. 收到的裸流字节数 ≈ 采样率 × 声道 × 2 × 秒数（s16le）
#
# 用法：./smoke.sh [秒数]，默认 5 秒
#
set -uo pipefail

cd "$(dirname "$0")"

DURATION="${1:-5}"
PORT="${PORT:-8899}"
PCM="/tmp/loopbackPost-smoke.pcm"
LOG="/tmp/loopbackPost-smoke.log"
REQLINE="/tmp/loopbackPost-smoke.request"

if ! command -v python3 >/dev/null 2>&1; then
    echo "需要 python3 才能跑冒烟测试" >&2
    exit 1
fi

echo "==> 编译"
./build.sh >/dev/null || exit 1

rm -f "$PCM" "$LOG" "$REQLINE" /tmp/loopbackPost-smoke.bytes

echo "==> 起本地假音箱 127.0.0.1:${PORT}"

# 只处理一次请求的假音箱
python3 - "$PORT" "$PCM" "$REQLINE" <<'PY' &
import socketserver, sys, os

port = int(sys.argv[1])
pcm_path = sys.argv[2]
req_path = sys.argv[3]

socketserver.TCPServer.allow_reuse_address = True


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        request_line = self.rfile.readline().decode("latin-1").strip()
        with open(req_path, "w") as f:
            f.write(request_line + "\n")

        headers = []
        while True:
            line = self.rfile.readline().decode("latin-1").strip()
            if not line:
                break
            headers.append(line)
        with open(req_path, "a") as f:
            f.write("\n".join(headers) + "\n")

        total = 0
        with open(pcm_path, "wb") as out:
            while True:
                chunk = self.rfile.read(65536)
                if not chunk:
                    break
                out.write(chunk)
                total += len(chunk)

        with open("/tmp/loopbackPost-smoke.bytes", "w") as f:
            f.write(str(total))

        try:
            self.wfile.write(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK")
        except Exception:
            pass


with socketserver.TCPServer(("127.0.0.1", port), Handler) as server:
    server.handle_request()
PY

SERVER_PID=$!
sleep 0.8

echo "==> 推流 ${DURATION} 秒（以 app 身份启动，否则拿不到系统音频权限）"
LOG="/tmp/loopbackPost.log"
./start.sh "http://127.0.0.1:${PORT}/aplay" >/dev/null || exit 1

sleep "$DURATION"

echo "==> 退出并检查能否干净退出"
./ctl.sh quit >/dev/null 2>&1
for _ in $(seq 1 30); do
    pgrep -f "loopbackPost.app/Contents/MacOS/loopbackPost" >/dev/null || break
    sleep 0.1
done
if pgrep -f "loopbackPost.app/Contents/MacOS/loopbackPost" >/dev/null; then
    echo "FAIL: 退出请求后 3 秒内没有结束"
    pkill -f "loopbackPost.app/Contents/MacOS/loopbackPost"
fi

sleep 0.3
kill "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null

echo "----- loopbackPost 日志 -----"
cat "$LOG"
echo "-----------------------------"

FAIL=0

if [[ ! -s "$REQLINE" ]]; then
    echo "FAIL: 没收到 HTTP 请求"
    exit 1
fi

REQ=$(head -1 "$REQLINE")
echo "请求行: $REQ"

if [[ "$REQ" != PUT\ /aplay* ]]; then
    echo "FAIL: 请求行不是 PUT /aplay..."
    FAIL=1
fi
if [[ "$REQ" != *"rate="* || "$REQ" != *"channels="* ]]; then
    echo "FAIL: URL 里缺少 rate/channels 参数"
    FAIL=1
fi

BYTES=$(cat /tmp/loopbackPost-smoke.bytes 2>/dev/null || echo 0)
RATE=$(printf '%s' "$REQ" | sed -n 's/.*rate=\([0-9]*\).*/\1/p')
CHANNELS=$(printf '%s' "$REQ" | sed -n 's/.*channels=\([0-9]*\).*/\1/p')
RATE=${RATE:-48000}
CHANNELS=${CHANNELS:-2}

# 去掉流式管道预热/网络抖动，按 60% 以上算通过
EXPECTED=$(python3 -c "print(int($RATE*$CHANNELS*2*$DURATION))")
MINIMUM=$(python3 -c "print(int($EXPECTED*0.6))")

echo "收到裸流 $BYTES 字节；预期约 $EXPECTED 字节（${RATE}Hz/${CHANNELS}ch/s16le，${DURATION}s）"

if (( BYTES < MINIMUM )); then
    echo "FAIL: 数据量明显偏少"
    FAIL=1
fi

if (( BYTES % 2 != 0 )); then
    echo "FAIL: 字节数不是 2 的倍数，s16le 帧未对齐"
    FAIL=1
fi

if (( FAIL == 0 )); then
    echo "PASS: 推流正常（落盘样本: ${PCM}）"
else
    exit 1
fi
