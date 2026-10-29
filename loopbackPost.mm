// loopbackPost (macOS) —— 把本机正在播放的声音实时推给局域网音箱
//
// 参考 Windows 版 loopbackPost（WASAPI loopback）移植：
//   采集：macOS 14.4+ CoreAudio Process Tap（系统内录，不录屏、不装虚拟声卡）
//   编码：s16le 裸 PCM（无 WAV 头）
//   传输：长连接 HTTP PUT，5ms 一块，按块时长打节拍
//   策略：过期丢弃追赶 + 固定节拍不补发 + 水位门控（与 Windows 版一致）
//
// 构建：./build.sh（只需要 Command Line Tools，不需要 Xcode）

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <iostream>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include <arpa/inet.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <termios.h>
#include <unistd.h>

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <AudioToolbox/AudioToolbox.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreAudio/CoreAudio.h>

// ============================================================================
// 1. CoreAudio Process Tap 兼容声明
//
// 本机 SDK（macosx14.0）里没有 CATapDescription.h / AudioHardwareTapping.h，
// 但 CoreAudio.tbd 已经导出了 CATapDescription 类和这两个函数，所以只需自己
// 补上声明即可正常编译链接。常量取值来自 macOS 14.5 SDK 头文件：
//   kAudioTapPropertyUID            = 'tuid'
//   kAudioTapPropertyFormat         = 'tfmt'
//   kAudioTapPropertyDescription    = 'tdsc'
//   kAudioAggregateDevicePropertyTapList = 'tap#'
//   kAudioAggregateDeviceTapListKey      = "taps"
//   kAudioAggregateDeviceTapAutoStartKey = "tapautostart"
//   kAudioSubTapUIDKey                   = "uid"
//   kAudioSubTapDriftCompensationKey     = "drift"
// ============================================================================

__attribute__((availability(macos, introduced=14.4)))
@interface CATapDescription : NSObject
- (instancetype)initStereoGlobalTapButExcludeProcesses:(NSArray*)excluded;
- (instancetype)initMonoGlobalTapButExcludeProcesses:(NSArray*)excluded;
- (instancetype)initStereoMixdownOfProcesses:(NSArray*)processes;
- (instancetype)initMonoMixdownOfProcesses:(NSArray*)processes;
@property(atomic, copy) NSString* name;
@property(atomic, copy) NSUUID* UUID;
@property(atomic, copy) NSArray* processes;
@property(atomic, copy) NSUUID* deviceUID;
@property(atomic, copy) NSArray* streams;
@property(atomic, readwrite, getter=isMono) BOOL mono;
@property(atomic, readwrite, getter=isExclusive) BOOL exclusive;
@property(atomic, readwrite, getter=isMixdown) BOOL mixdown;
@property(atomic, readwrite, getter=isPrivate, setter=setPrivate:) BOOL privateTap;
@property(atomic, readwrite, getter=isMuted) NSInteger muteBehavior;
@end

extern "C" {
OSStatus AudioHardwareCreateProcessTap(CATapDescription* inDescription,
                                       AudioObjectID* outTapID)
    __attribute__((availability(macos, introduced=14.4)));
OSStatus AudioHardwareDestroyProcessTap(AudioObjectID inTapID)
    __attribute__((availability(macos, introduced=14.4)));

// Process Tap 与录屏共用同一个 TCC 权限（屏幕与系统音频录制）。
// 未授权时 tap 依然创建成功、IO 也在跑，但读到的全是静音 —— 必须自查。
bool CGPreflightScreenCaptureAccess(void);
bool CGRequestScreenCaptureAccess(void);
}

static const AudioObjectPropertySelector kLP_TapPropertyUID = 'tuid';
static const AudioObjectPropertySelector kLP_TapPropertyFormat = 'tfmt';
static const AudioObjectPropertySelector kLP_TapPropertyDescription = 'tdsc';
// SDK 14.0 里没有这个常量，值来自 14.5 头文件：PID -> 音频进程对象
static const AudioObjectPropertySelector kLP_TranslatePIDToProcessObject = 'id2p';
static const AudioObjectPropertySelector kLP_AggregateTapList = 'tap#';

static CFStringRef const kLP_AggregateTapListKey = CFSTR("taps");
static CFStringRef const kLP_AggregateTapAutoStartKey = CFSTR("tapautostart");
static CFStringRef const kLP_SubTapUIDKey = CFSTR("uid");
static CFStringRef const kLP_SubTapDriftKey = CFSTR("drift");

// 聚合设备描述字典的键（SDK 里是 const char*，这里统一用 CFString）
static CFStringRef const kLP_AggregateNameKey = CFSTR("name");
static CFStringRef const kLP_AggregateUIDKey = CFSTR("uid");
static CFStringRef const kLP_AggregatePrivateKey = CFSTR("private");
static CFStringRef const kLP_AggregateMainSubDeviceKey = CFSTR("master");
static CFStringRef const kLP_AggregateSubDeviceListKey = CFSTR("subdevices");
static CFStringRef const kLP_AggregateIsStackedKey = CFSTR("stacked");

// ============================================================================
// 2. 常量与全局状态
// ============================================================================

static std::atomic_bool g_stop{false};
static std::atomic_bool g_rebuildRequested{false};
static std::atomic_uint g_volumeUpRequests{0};
static std::atomic_uint g_volumeDownRequests{0};

static constexpr double kBlockedWriteMs = 1.0;

// 与 Windows 版同名同义的可调参数（argv[2]/argv[3]/argv[4] 可改）
static double kDropBacklogMs = 20.0;      // 允许的最大音频年龄
static double kExtraDelayMs = 0.0;        // 额外延迟（抖动缓冲深度）
static double kDropAllBacklogMs = 500.0;  // 队列硬上限（兜底）
static double kEffectiveDropMs = 20.0;

static constexpr double kSendChunkMs = 5.0;

static constexpr int kMaxAutoReconnectAttempts = 3;
static constexpr auto kServiceRetryDelay = std::chrono::seconds(10);
static constexpr auto kCongestionReconnectDelay =
    std::chrono::milliseconds(200);
static constexpr auto kCaptureGateTimeout = std::chrono::milliseconds(3000);
static constexpr auto kCaptureSettleDelay = std::chrono::milliseconds(250);

// 流式上传用哪种成帧方式：
//   false（默认）= 与 WinHTTP 原版一致：声明超大 Content-Length，然后裸流式写
//   true          = Transfer-Encoding: chunked
static bool g_chunked = false;

// 探测模式参数
static std::string g_probeOut;
static double g_probeSeconds = 3.0;

// 只采集指定进程（调试/单进程录制用），0 表示全局
static pid_t g_tapPid = 0;

// 用 AudioQueue 而不是 IOProc 读聚合设备（两条独立路径，便于排查）
static bool g_useAudioQueue = false;

// ============================================================================
// 3. 基础工具：时间 / 日志 / 字符串
// ============================================================================

static mach_timebase_info_data_t g_timebase{};

static void InitTimebase() {
    if (g_timebase.denom == 0)
        mach_timebase_info(&g_timebase);
}

// AudioTimeStamp.mHostTime 与 mach_absolute_time 是同一个时钟。
static uint64_t HostTicksToNs(uint64_t ticks) {
    if (g_timebase.denom == 0)
        InitTimebase();
    return static_cast<uint64_t>(
        static_cast<long double>(ticks) * g_timebase.numer / g_timebase.denom);
}

static uint64_t NowNs() {
    return HostTicksToNs(mach_absolute_time());
}

static uint64_t NsToHostTicks(uint64_t ns) {
    if (g_timebase.denom == 0)
        InitTimebase();
    return static_cast<uint64_t>(static_cast<long double>(ns) *
                                 g_timebase.denom / g_timebase.numer);
}

// 精确等待一段相对时长（比 sleep_for 抖得小）。
// 注意只能传“时长”：steady_clock 的纪元与 mach_absolute_time 不一定一致，
// 直接把 steady_clock 的绝对时间换算成 tick 交给 mach_wait_until 会睡过头。
static void WaitForNs(int64_t durationNs) {
    if (durationNs <= 0)
        return;
    mach_wait_until(mach_absolute_time() +
                    NsToHostTicks(static_cast<uint64_t>(durationNs)));
}

static std::mutex g_logMutex;
static FILE* g_logFile = nullptr;  // 以 app 身份启动（没有终端）时的日志落盘

static void OpenLogFile(const char* path) {
    std::lock_guard<std::mutex> lock(g_logMutex);
    if (!g_logFile)
        g_logFile = std::fopen(path, "a");
}

static void LogLine(const char* fmt, ...) {
    std::lock_guard<std::mutex> lock(g_logMutex);

    va_list ap;
    va_start(ap, fmt);
    vfprintf(stdout, fmt, ap);
    va_end(ap);
    fputc('\n', stdout);
    fflush(stdout);

    if (g_logFile) {
        va_start(ap, fmt);
        vfprintf(g_logFile, fmt, ap);
        va_end(ap);
        fputc('\n', g_logFile);
        fflush(g_logFile);
    }
}

static std::string TrimSpec(const std::string& text) {
    const size_t begin = text.find_first_not_of(" \t\r\n");
    if (begin == std::string::npos)
        return "";
    const size_t end = text.find_last_not_of(" \t\r\n");
    return text.substr(begin, end - begin + 1);
}

static void LowerAscii(std::string& text) {
    for (char& c : text)
        if (c >= 'A' && c <= 'Z')
            c = static_cast<char>(c - 'A' + 'a');
}

// ============================================================================
// 4. URL 解析与构造（对齐 Windows 版 CrackUrl / SetQueryParameter）
// ============================================================================

struct UrlParts {
    std::string host;
    std::string path;  // 包含 query
    uint16_t port = 80;
    bool https = false;
    bool portSpecified = false;
};

// 覆盖式写入 query 参数：已存在则替换，否则追加。
static void SetQueryParameter(std::string& path,
                              const std::string& key,
                              const std::string& value) {
    const size_t question = path.find('?');
    std::string base = question == std::string::npos ? path : path.substr(0, question);
    std::string query =
        question == std::string::npos ? "" : path.substr(question + 1);

    std::vector<std::string> items;
    size_t start = 0;
    while (start <= query.size() && !query.empty()) {
        size_t amp = query.find('&', start);
        if (amp == std::string::npos)
            amp = query.size();
        if (amp > start)
            items.push_back(query.substr(start, amp - start));
        if (amp == query.size())
            break;
        start = amp + 1;
    }

    bool replaced = false;
    const std::string prefix = key + "=";
    for (std::string& item : items) {
        if (item.compare(0, prefix.size(), prefix) == 0) {
            item = prefix + value;
            replaced = true;
        }
    }
    if (!replaced)
        items.push_back(prefix + value);

    std::string rebuilt;
    for (size_t i = 0; i < items.size(); ++i) {
        if (i)
            rebuilt += "&";
        rebuilt += items[i];
    }

    path = rebuilt.empty() ? base : base + "?" + rebuilt;
}

static bool ParseUrl(const std::string& url, UrlParts& out, std::string& err) {
    std::string full = url;
    if (full.compare(0, 4, "http") != 0)
        full = "http://" + full;

    const size_t schemeEnd = full.find("://");
    if (schemeEnd == std::string::npos) {
        err = "缺少 scheme";
        return false;
    }

    std::string scheme = full.substr(0, schemeEnd);
    LowerAscii(scheme);
    if (scheme == "https") {
        out.https = true;
    } else if (scheme != "http") {
        err = "不支持的 scheme: " + scheme;
        return false;
    }

    const size_t authorityBegin = schemeEnd + 3;
    const size_t authorityEnd = full.find_first_of("/?#", authorityBegin);
    std::string authority = full.substr(
        authorityBegin,
        authorityEnd == std::string::npos ? std::string::npos
                                         : authorityEnd - authorityBegin);
    std::string rest =
        authorityEnd == std::string::npos ? "" : full.substr(authorityEnd);

    const size_t userInfoEnd = authority.rfind('@');
    if (userInfoEnd != std::string::npos)
        authority.erase(0, userInfoEnd + 1);

    std::string portText;
    if (!authority.empty() && authority.front() == '[') {
        const size_t hostEnd = authority.find(']');
        if (hostEnd == std::string::npos) {
            err = "IPv6 地址缺少 ]";
            return false;
        }
        out.host = authority.substr(1, hostEnd - 1);
        if (hostEnd + 1 < authority.size() && authority[hostEnd + 1] == ':')
            portText = authority.substr(hostEnd + 2);
    } else {
        const size_t colon = authority.rfind(':');
        if (colon != std::string::npos) {
            out.host = authority.substr(0, colon);
            portText = authority.substr(colon + 1);
        } else {
            out.host = authority;
        }
    }

    if (out.host.empty()) {
        err = "缺少 host";
        return false;
    }

    out.portSpecified = !portText.empty();
    if (out.portSpecified) {
        char* end = nullptr;
        const long value = std::strtol(portText.c_str(), &end, 10);
        if (!end || *end != '\0' || value <= 0 || value > 65535) {
            err = "端口非法: " + portText;
            return false;
        }
        out.port = static_cast<uint16_t>(value);
    } else {
        out.port = out.https ? 443 : 80;
    }

    // 去掉 fragment
    const size_t hash = rest.find('#');
    if (hash != std::string::npos)
        rest.erase(hash);

    if (rest.empty() || rest == "/")
        out.path = "/aplay";
    else if (rest.front() == '?')
        out.path = "/aplay" + rest;
    else
        out.path = rest;

    return true;
}

static bool IsConnectionError(int err) {
    return err == ECONNREFUSED || err == ECONNRESET || err == ETIMEDOUT ||
           err == EHOSTUNREACH || err == ENETUNREACH || err == EPIPE ||
           err == ECONNABORTED;
}

// 端口回退链 80 -> 8080 -> 8880（只在 http、且从未成功连上过时使用）
static bool AdvancePortFallback(UrlParts& parts) {
    if (parts.https)
        return false;

    if (!parts.portSpecified && parts.port == 80) {
        parts.port = 8080;
    } else if (parts.port == 8080) {
        parts.port = 8880;
    } else {
        return false;
    }
    return true;
}

// ============================================================================
// 5. HTTP 客户端（BSD socket）
// ============================================================================

struct WriteStats {
    uint64_t writeCalls = 0;
    uint64_t writeOver1MsCalls = 0;
    double writeMaxMs = 0.0;
    double blockedMs = 0.0;
    int lastErrno = 0;
};

static bool SendAll(int fd, const void* data, size_t bytes, WriteStats& stats) {
    const uint8_t* cursor = static_cast<const uint8_t*>(data);
    size_t remaining = bytes;

    while (remaining > 0) {
        const auto writeStart = std::chrono::steady_clock::now();
        ssize_t written = ::send(fd, cursor, remaining, 0);
        const double writeMs =
            std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - writeStart)
                .count();

        if (written < 0) {
            if (errno == EINTR)
                continue;
            stats.lastErrno = errno;
            return false;
        }
        if (written == 0) {
            stats.lastErrno = EPIPE;
            return false;
        }

        ++stats.writeCalls;
        if (writeMs >= 1.0)
            ++stats.writeOver1MsCalls;
        stats.writeMaxMs = std::max(stats.writeMaxMs, writeMs);
        if (writeMs > kBlockedWriteMs)
            stats.blockedMs += writeMs;

        stats.lastErrno = 0;
        cursor += written;
        remaining -= static_cast<size_t>(written);
    }

    return true;
}

static bool ConnectTcp(const std::string& host,
                       uint16_t port,
                       int timeoutMs,
                       int& fdOut,
                       int& errOut) {
    struct addrinfo hints;
    std::memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;

    char portText[16];
    std::snprintf(portText, sizeof(portText), "%u",
                  static_cast<unsigned>(port));

    struct addrinfo* result = nullptr;
    const int gai = getaddrinfo(host.c_str(), portText, &hints, &result);
    if (gai != 0) {
        errOut = EHOSTUNREACH;
        LogLine("getaddrinfo(%s) failed: %s", host.c_str(), gai_strerror(gai));
        return false;
    }

    int lastError = 0;
    bool connected = false;
    int connectedFd = -1;

    for (struct addrinfo* ai = result; ai && !connected; ai = ai->ai_next) {
        const int fd = ::socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) {
            lastError = errno;
            continue;
        }

        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));

        const int flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);

        int rc = ::connect(fd, ai->ai_addr, ai->ai_addrlen);
        if (rc != 0 && errno == EINPROGRESS) {
            struct pollfd pfd;
            pfd.fd = fd;
            pfd.events = POLLOUT;
            pfd.revents = 0;

            const int polled = poll(&pfd, 1, timeoutMs);
            if (polled > 0) {
                int soError = 0;
                socklen_t soErrorLen = sizeof(soError);
                if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError,
                               &soErrorLen) == 0) {
                    if (soError == 0)
                        rc = 0;
                    else
                        errno = soError;
                }
            } else if (polled == 0) {
                errno = ETIMEDOUT;
            }
        }

        if (rc == 0) {
            fcntl(fd, F_SETFL, flags);

            int nodelay = 1;
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, sizeof(nodelay));

            // 发送缓冲尽量小，避免内核把积压藏起来导致延迟越堆越高。
            int sndBuf = 16 * 1024;
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndBuf, sizeof(sndBuf));

            struct timeval tv;
            tv.tv_sec = 5;
            tv.tv_usec = 0;
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

            connected = true;
            connectedFd = fd;
        } else {
            lastError = errno;
            ::close(fd);
        }
    }

    freeaddrinfo(result);

    if (!connected) {
        errOut = lastError ? lastError : ECONNREFUSED;
        return false;
    }

    fdOut = connectedFd;
    errOut = 0;
    return true;
}

// 一条用于流式 PUT 的长连接。
struct HttpConnection {
    int fd = -1;

    void Close() {
        if (fd >= 0) {
            ::close(fd);
            fd = -1;
        }
    }

    bool Open(const UrlParts& parts, bool chunked, WriteStats& stats) {
        Close();

        int err = 0;
        if (parts.https) {
            LogLine("https 暂不支持（没有 TLS 实现），请使用 http://");
            stats.lastErrno = EPROTONOSUPPORT;
            return false;
        }
        if (!ConnectTcp(parts.host, parts.port, 5000, fd, err)) {
            stats.lastErrno = err;
            LogLine("connect %s:%u failed: %s", parts.host.c_str(),
                    static_cast<unsigned>(parts.port), strerror(err));
            return false;
        }

        std::string hostHeader = parts.host;
        if (parts.port != 80)
            hostHeader += ":" + std::to_string(parts.port);

        std::string request = "PUT " + parts.path + " HTTP/1.1\r\n";
        request += "Host: " + hostHeader + "\r\n";
        request += "User-Agent: workdayAlarmClockGo/1.0\r\n";
        request += "Content-Type: application/octet-stream\r\n";
        request += "Accept: */*\r\n";
        if (chunked) {
            request += "Transfer-Encoding: chunked\r\n";
        } else {
            // 与 WinHTTP 原版完全一致的占位长度：服务端按流式读取。
            request += "Content-Length: 68719476735\r\n";
        }
        request += "Connection: close\r\n";
        request += "\r\n";

        if (!SendAll(fd, request.data(), request.size(), stats)) {
            LogLine("send request header failed: %s", strerror(stats.lastErrno));
            Close();
            return false;
        }

        return true;
    }

    bool WritePcm(const uint8_t* data,
                  size_t bytes,
                  bool chunked,
                  WriteStats& stats) {
        if (fd < 0)
            return false;

        if (chunked) {
            char header[32];
            const int headerLen =
                std::snprintf(header, sizeof(header), "%zx\r\n", bytes);
            if (!SendAll(fd, header, static_cast<size_t>(headerLen), stats))
                return false;
            if (!SendAll(fd, data, bytes, stats))
                return false;
            return SendAll(fd, "\r\n", 2, stats);
        }

        return SendAll(fd, data, bytes, stats);
    }

    bool ReadResponse(int timeoutMs,
                      int& status,
                      std::string& location,
                      std::string& body) {
        status = 0;
        location.clear();
        body.clear();
        if (fd < 0)
            return false;

        std::string raw;
        char buffer[2048];

        const auto deadline =
            std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);

        while (std::chrono::steady_clock::now() < deadline) {
            struct pollfd pfd;
            pfd.fd = fd;
            pfd.events = POLLIN;
            pfd.revents = 0;

            const int polled = poll(&pfd, 1, 100);
            if (polled < 0) {
                if (errno == EINTR)
                    continue;
                break;
            }
            if (polled == 0)
                continue;

            const ssize_t n = recv(fd, buffer, sizeof(buffer), 0);
            if (n <= 0)
                break;
            raw.append(buffer, static_cast<size_t>(n));
            if (raw.find("\r\n\r\n") != std::string::npos)
                break;
        }

        if (raw.empty())
            return false;

        const size_t headerEnd = raw.find("\r\n\r\n");
        const std::string headerBlock =
            headerEnd == std::string::npos ? raw : raw.substr(0, headerEnd);
        if (headerEnd != std::string::npos && headerEnd + 4 < raw.size())
            body = raw.substr(headerEnd + 4);

        const size_t firstLineEnd = headerBlock.find("\r\n");
        const std::string statusLine =
            firstLineEnd == std::string::npos
                ? headerBlock
                : headerBlock.substr(0, firstLineEnd);

        const size_t firstSpace = statusLine.find(' ');
        if (firstSpace != std::string::npos && firstSpace + 4 <= statusLine.size())
            status = std::atoi(statusLine.c_str() + firstSpace + 1);

        std::string lower = headerBlock;
        LowerAscii(lower);
        const size_t locationPos = lower.find("\r\nlocation:");
        if (locationPos != std::string::npos) {
            size_t valueBegin = locationPos + std::strlen("\r\nlocation:");
            while (valueBegin < headerBlock.size() &&
                   (headerBlock[valueBegin] == ' ' ||
                    headerBlock[valueBegin] == '\t'))
                ++valueBegin;
            size_t valueEnd = headerBlock.find("\r\n", valueBegin);
            if (valueEnd == std::string::npos)
                valueEnd = headerBlock.size();
            location = TrimSpec(headerBlock.substr(valueBegin, valueEnd - valueBegin));
        }

        while (!body.empty() && (body.back() == '\r' || body.back() == '\n'))
            body.pop_back();
        if (body.size() > 512)
            body = body.substr(0, 512) + "...";

        return true;
    }
};

// ============================================================================
// 6. CoreAudio Process Tap 采集
// ============================================================================

struct CaptureFormat {
    double sampleRate = 48000.0;
    uint32_t channels = 2;
    bool isFloat = true;
    bool nonInterleaved = false;
};

// 取默认系统输出设备的 UID。
// 关键点：聚合设备必须挂一个真实的输出设备作为主设备/子设备，否则 IO 通路
// 没有时钟源，tap 那边的数据不会被搬进来 —— 回调照跑，但全是 0。
static bool GetDefaultSystemOutputDeviceUID(std::string& uid, std::string& error) {
    AudioObjectPropertyAddress address{kAudioHardwarePropertyDefaultSystemOutputDevice,
                                       kAudioObjectPropertyScopeGlobal,
                                       kAudioObjectPropertyElementMain};
    AudioObjectID deviceID = kAudioObjectUnknown;
    UInt32 size = sizeof(deviceID);

    OSStatus status =
        AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr,
                                   &size, &deviceID);
    if (status != noErr || deviceID == kAudioObjectUnknown) {
        address.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
        status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0,
                                            nullptr, &size, &deviceID);
    }
    if (status != noErr || deviceID == kAudioObjectUnknown) {
        error = "找不到默认输出设备（OSStatus=" + std::to_string(status) + "）";
        return false;
    }

    AudioObjectPropertyAddress uidAddress{kAudioDevicePropertyDeviceUID,
                                          kAudioObjectPropertyScopeGlobal,
                                          kAudioObjectPropertyElementMain};
    CFStringRef deviceUID = nullptr;
    size = sizeof(deviceUID);
    status = AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nullptr, &size,
                                        &deviceUID);
    if (status != noErr || !deviceUID) {
        error = "读取默认输出设备 UID 失败（OSStatus=" + std::to_string(status) + "）";
        return false;
    }

    uid = [(__bridge NSString*)deviceUID UTF8String];
    CFRelease(deviceUID);
    return true;
}

static bool GetTapUID(AudioObjectID tapID, CFStringRef& out) {
    AudioObjectPropertyAddress address{kLP_TapPropertyUID,
                                       kAudioObjectPropertyScopeGlobal,
                                       kAudioObjectPropertyElementMain};
    CFStringRef uid = nullptr;
    UInt32 size = sizeof(uid);
    const OSStatus status =
        AudioObjectGetPropertyData(tapID, &address, 0, nullptr, &size, &uid);
    if (status != noErr || !uid)
        return false;
    out = uid;
    return true;
}

static bool GetTapFormat(AudioObjectID tapID,
                         CaptureFormat& out,
                         AudioStreamBasicDescription& raw) {
    AudioObjectPropertyAddress address{kLP_TapPropertyFormat,
                                       kAudioObjectPropertyScopeGlobal,
                                       kAudioObjectPropertyElementMain};
    UInt32 size = sizeof(raw);
    std::memset(&raw, 0, sizeof(raw));
    const OSStatus status =
        AudioObjectGetPropertyData(tapID, &address, 0, nullptr, &size, &raw);
    if (status != noErr)
        return false;

    out.sampleRate = raw.mSampleRate > 0 ? raw.mSampleRate : 48000.0;
    out.channels = raw.mChannelsPerFrame > 0 ? raw.mChannelsPerFrame : 2;
    out.isFloat = (raw.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    out.nonInterleaved = (raw.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    return true;
}

static void DescribeAsbd(const AudioStreamBasicDescription& asbd) {
    LogLine("  格式: %.0f Hz, %u ch, %u bit%s%s, bytesPerFrame=%u",
            asbd.mSampleRate, static_cast<unsigned>(asbd.mChannelsPerFrame),
            static_cast<unsigned>(asbd.mBitsPerChannel),
            (asbd.mFormatFlags & kAudioFormatFlagIsFloat) ? ", float" : ", int",
            (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved)
                ? ", non-interleaved"
                : ", interleaved",
            static_cast<unsigned>(asbd.mBytesPerFrame));
}

static constexpr uint32_t kMaxChannelBuffers = 32;

static void AQInputCallback(void* userData,
                            AudioQueueRef queue,
                            AudioQueueBufferRef buffer,
                            const AudioTimeStamp* startTime,
                            UInt32 packetCount,
                            const AudioStreamPacketDescription* packets);

// 打印聚合设备的挂载状态，用来判断“没声音”是没挂上 tap 还是没授权。
static void LogAggregateDiagnostics(AudioObjectID aggregateID) {
    // tap 列表（CFArray<CFString>）
    AudioObjectPropertyAddress listAddress{kLP_AggregateTapList,
                                           kAudioObjectPropertyScopeGlobal,
                                           kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    OSStatus status =
        AudioObjectGetPropertyDataSize(aggregateID, &listAddress, 0, nullptr, &size);
    if (status == noErr && size > 0) {
        CFArrayRef list = nullptr;
        status = AudioObjectGetPropertyData(aggregateID, &listAddress, 0, nullptr,
                                            &size, &list);
        if (status == noErr && list) {
            LogLine("  聚合设备已挂 tap: %ld 个",
                    static_cast<long>(CFArrayGetCount(list)));
            CFRelease(list);
        }
    } else {
        LogLine("  聚合设备 tap 列表为空（tap 没挂上）");
    }

    // 活动 sub-tap（AudioObjectID 数组）
    AudioObjectPropertyAddress subAddress{'atap', kAudioObjectPropertyScopeGlobal,
                                          kAudioObjectPropertyElementMain};
    size = 0;
    if (AudioObjectGetPropertyDataSize(aggregateID, &subAddress, 0, nullptr, &size) ==
            noErr &&
        size > 0) {
        std::vector<AudioObjectID> ids(size / sizeof(AudioObjectID));
        if (AudioObjectGetPropertyData(aggregateID, &subAddress, 0, nullptr, &size,
                                       ids.data()) == noErr)
            LogLine("  活动 sub-tap: %zu 个", ids.size());
    } else {
        LogLine("  活动 sub-tap: 0 个（tap 未激活）");
    }

    // 输入流格式
    AudioObjectPropertyAddress formatAddress{kAudioDevicePropertyStreamFormat,
                                             kAudioDevicePropertyScopeInput,
                                             kAudioObjectPropertyElementMain};
    AudioStreamBasicDescription asbd;
    std::memset(&asbd, 0, sizeof(asbd));
    size = sizeof(asbd);
    if (AudioObjectGetPropertyData(aggregateID, &formatAddress, 0, nullptr, &size,
                                   &asbd) == noErr &&
        asbd.mSampleRate > 0) {
        DescribeAsbd(asbd);
    } else {
        LogLine("  聚合设备没有输入流格式（没有输入通道）");
    }
}

// 无锁 SPSC 环形缓冲：写端在 CoreAudio 实时回调里，读端在采集泵线程里。
struct TapRing {
    std::vector<float> samples;         // 交错的 float 采样
    std::vector<uint64_t> frameTimeNs;  // 每帧对应的 host 时间
    uint32_t channels = 0;
    double sampleRate = 48000.0;
    std::atomic<uint64_t> writeFrame{0};
    std::atomic<uint64_t> readFrame{0};
    std::atomic<uint64_t> overflowFrames{0};

    void Allocate(size_t frames, uint32_t channelCount, double rate) {
        channels = channelCount;
        sampleRate = rate > 0 ? rate : 48000.0;
        samples.assign(frames * channelCount, 0.0f);
        frameTimeNs.assign(frames, 0);
        writeFrame.store(0);
        readFrame.store(0);
    }

    size_t CapacityFrames() const {
        return channels == 0 ? 0 : samples.size() / channels;
    }

    // 实时线程调用：零分配、零加锁。
    //   channelBuffers != nullptr：非交错，每个元素一个声道缓冲
    //   interleaved    != nullptr：交错单缓冲
    void Push(const float* const* channelBuffers, uint32_t bufferCount,
              const float* interleaved, uint32_t frames, uint64_t hostNs) {
        if (channels == 0 || frames == 0)
            return;

        const size_t capacity = CapacityFrames();
        const uint64_t write = writeFrame.load(std::memory_order_relaxed);
        const uint64_t read = readFrame.load(std::memory_order_acquire);

        if (write - read + frames > capacity) {
            overflowFrames.fetch_add(frames, std::memory_order_relaxed);
            return;
        }

        for (uint32_t i = 0; i < frames; ++i) {
            const size_t slot = static_cast<size_t>((write + i) % capacity);
            float* dst = &samples[slot * channels];

            if (interleaved) {
                const float* src = interleaved + static_cast<size_t>(i) * channels;
                for (uint32_t c = 0; c < channels; ++c)
                    dst[c] = src[c];
            } else if (channelBuffers && bufferCount > 0) {
                for (uint32_t c = 0; c < channels; ++c) {
                    const float* src =
                        channelBuffers[c < bufferCount ? c : bufferCount - 1];
                    dst[c] = src ? src[i] : 0.0f;
                }
            } else {
                for (uint32_t c = 0; c < channels; ++c)
                    dst[c] = 0.0f;
            }
            frameTimeNs[slot] =
                hostNs + static_cast<uint64_t>(static_cast<double>(i) * 1e9 /
                                               sampleRate);
        }

        writeFrame.store(write + frames, std::memory_order_release);
    }

    size_t Pop(float* dst, size_t maxFrames, uint64_t& hostNs) {
        const uint64_t read = readFrame.load(std::memory_order_relaxed);
        const uint64_t write = writeFrame.load(std::memory_order_acquire);
        if (write <= read || channels == 0)
            return 0;

        const size_t capacity = CapacityFrames();
        const size_t available = static_cast<size_t>(write - read);
        const size_t count = std::min(available, maxFrames);

        hostNs = frameTimeNs[static_cast<size_t>(read % capacity)];

        const size_t start = static_cast<size_t>(read % capacity);
        const size_t firstPart = std::min(count, capacity - start);
        std::memcpy(dst, &samples[start * channels],
                    firstPart * channels * sizeof(float));
        if (count > firstPart) {
            std::memcpy(dst + firstPart * channels, &samples[0],
                        (count - firstPart) * channels * sizeof(float));
        }

        readFrame.store(read + count, std::memory_order_release);
        return count;
    }
};

class TapCapture {
public:
    ~TapCapture() { Close(); }

    bool Open(std::string& error);
    bool Start(std::string& error);
    void Stop();
    void Close();

    const CaptureFormat& format() const { return format_; }
    bool opened() const { return tapID_ != kAudioObjectUnknown; }
    TapRing& ring() { return ring_; }

    // AudioQueue 路径的回调入口（公开给 C 回调函数用）
    void PushAudioQueueBuffer(AudioQueueRef queue,
                              AudioQueueBufferRef buffer,
                              const AudioTimeStamp* startTime);

private:
    static OSStatus IOProcStub(AudioObjectID inDevice,
                               const AudioTimeStamp* inNow,
                               const AudioBufferList* inInputData,
                               const AudioTimeStamp* inInputTime,
                               AudioBufferList* outOutputData,
                               const AudioTimeStamp* inOutputTime,
                               void* inClientData);

    void OnAudio(const AudioBufferList* input, const AudioTimeStamp* inputTime);

    AudioObjectID tapID_ = kAudioObjectUnknown;
    AudioObjectID aggregateID_ = kAudioObjectUnknown;
    AudioDeviceIOProcID ioProcID_ = nullptr;
    bool running_ = false;
    CaptureFormat format_;
    std::vector<const float*> channelPointers_;
    TapRing ring_;

    // AudioQueue 采集（备用路径）
    AudioQueueRef audioQueue_ = nullptr;
    std::string aggregateUID_;
    std::vector<AudioQueueBufferRef> audioQueueBuffers_;
};

OSStatus TapCapture::IOProcStub(AudioObjectID,
                                const AudioTimeStamp*,
                                const AudioBufferList* inInputData,
                                const AudioTimeStamp* inInputTime,
                                AudioBufferList*,
                                const AudioTimeStamp*,
                                void* inClientData) {
    auto* self = static_cast<TapCapture*>(inClientData);
    if (self && inInputData)
        self->OnAudio(inInputData, inInputTime);
    return noErr;
}

void TapCapture::OnAudio(const AudioBufferList* input,
                         const AudioTimeStamp* inputTime) {
    if (!format_.isFloat || input->mNumberBuffers == 0)
        return;

    const bool nonInterleaved = input->mNumberBuffers > 1;

    // 第一次回调打印一次真实布局，用来确认数据到底长什么样。
    static std::atomic_bool loggedOnce{false};
    if (!loggedOnce.exchange(true)) {
        LogLine("首次回调: buffers=%u, buf0.channels=%u, buf0.bytes=%u, buf0.data=%p",
                static_cast<unsigned>(input->mNumberBuffers),
                static_cast<unsigned>(input->mBuffers[0].mNumberChannels),
                static_cast<unsigned>(input->mBuffers[0].mDataByteSize),
                input->mBuffers[0].mData);
        if (input->mNumberBuffers > 1) {
            LogLine("  buf1.channels=%u, buf1.bytes=%u, buf1.data=%p",
                    static_cast<unsigned>(input->mBuffers[1].mNumberChannels),
                    static_cast<unsigned>(input->mBuffers[1].mDataByteSize),
                    input->mBuffers[1].mData);
        }
        if (inputTime)
            LogLine("  时间戳 flags=0x%x hostTime=%llu", inputTime->mFlags,
                    static_cast<unsigned long long>(inputTime->mHostTime));
    }

    uint32_t frames = 0;
    if (nonInterleaved) {
        if (input->mBuffers[0].mDataByteSize == 0)
            return;
        frames = input->mBuffers[0].mDataByteSize / sizeof(float);
    } else {
        const uint32_t bytesPerFrame =
            input->mBuffers[0].mNumberChannels * sizeof(float);
        if (bytesPerFrame == 0)
            return;
        frames = input->mBuffers[0].mDataByteSize / bytesPerFrame;
    }

    if (frames == 0)
        return;

    uint64_t hostNs = 0;
    if (inputTime && (inputTime->mFlags & kAudioTimeStampHostTimeValid))
        hostNs = HostTicksToNs(inputTime->mHostTime);
    if (hostNs == 0)
        hostNs = NowNs();

    if (nonInterleaved) {
        // channelPointers_ 在 Open() 里预分配好，这里只写值，不做内存分配。
        const UInt32 count =
            std::min<UInt32>(input->mNumberBuffers, kMaxChannelBuffers);
        for (UInt32 i = 0; i < count; ++i)
            channelPointers_[i] = static_cast<const float*>(input->mBuffers[i].mData);
        for (UInt32 i = count; i < kMaxChannelBuffers; ++i)
            channelPointers_[i] = nullptr;

        ring_.Push(channelPointers_.data(), count, nullptr, frames, hostNs);
    } else {
        ring_.Push(nullptr, 1,
                   static_cast<const float*>(input->mBuffers[0].mData), frames,
                   hostNs);
    }
}

bool TapCapture::Open(std::string& error) {
    if (@available(macOS 14.4, *)) {
        // 0) 权限自检：没有「屏幕与系统音频录制」授权时，tap 仍会创建成功、
        //    回调也按时触发，但样本全是 0。这是最容易误判成"采集坏了"的坑。
        if (!CGPreflightScreenCaptureAccess()) {
            LogLine("警告: 未获得「屏幕与系统音频录制」权限 —— 采集到的会是全静音。");
            if (CGRequestScreenCaptureAccess()) {
                LogLine("已发出授权请求；请在系统弹窗里点允许，然后重新运行本程序。");
            } else {
                LogLine("请到「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」");
                LogLine("里勾选当前终端（或 loopbackPost），授权后重新运行。");
            }
        }

        // 1) 全局立体声 tap，排除空数组 = 采集除自己以外的全部系统输出。
        CATapDescription* description = nil;
        if (g_tapPid > 0) {
            // 只采某个进程（processes 里要的是音频对象 ID，不是 PID）
            AudioObjectPropertyAddress translateAddress{
                kLP_TranslatePIDToProcessObject, kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain};
            AudioObjectID processObject = kAudioObjectUnknown;
            UInt32 objectSize = sizeof(processObject);
            pid_t pid = g_tapPid;
            const OSStatus translateStatus = AudioObjectGetPropertyData(
                kAudioObjectSystemObject, &translateAddress, sizeof(pid), &pid,
                &objectSize, &processObject);
            if (translateStatus != noErr || processObject == kAudioObjectUnknown) {
                error = "找不到 PID " + std::to_string(pid) + " 对应的音频进程";
                return false;
            }
            LogLine("按进程采集: pid %d -> 音频对象 %u", pid,
                    static_cast<unsigned>(processObject));
            description = [[CATapDescription alloc]
                initStereoMixdownOfProcesses:@[ @(processObject) ]];
        } else {
            description = [[CATapDescription alloc]
                initStereoGlobalTapButExcludeProcesses:@[]];
        }
        if (!description) {
            error = "无法创建 CATapDescription（当前系统不支持 CoreAudio Tap）";
            return false;
        }
        description.name = @"loopbackPost";
        description.UUID = [NSUUID UUID];
        description.muteBehavior = 0;         // CATapUnmuted：原声照常从扬声器播放
        description.privateTap = NO;

        AudioObjectID tapID = kAudioObjectUnknown;
        const OSStatus tapStatus =
            AudioHardwareCreateProcessTap(description, &tapID);
        if (tapStatus != noErr || tapID == kAudioObjectUnknown) {
            error = "创建音频 Tap 失败（OSStatus=" + std::to_string(tapStatus) +
                    "）。需要在「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」"
                    "里允许本程序（或终端）录制系统音频，然后重新运行。";
            return false;
        }
        tapID_ = tapID;

        // 2) 取 tap 的 UID
        CFStringRef tapUID = nullptr;
        if (!GetTapUID(tapID_, tapUID)) {
            error = "读取 tap UID 失败";
            return false;
        }
        const std::string uidText = [(__bridge NSString*)tapUID UTF8String];
        LogLine("CoreAudio Tap 已创建: %s", uidText.c_str());
        LogLine("  description.UUID: %s", [description.UUID.UUIDString UTF8String]);

        // 回读 tap 的真实配置：global tap 必须是 exclusive=1 才能采集"全部进程"，
        // 如果 exclusive=0 而 processes 为空，就变成"什么都不采"，数据自然全是 0。
        {
            AudioObjectPropertyAddress descriptionAddress{
                kLP_TapPropertyDescription, kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain};
            CATapDescription* readback = nil;
            UInt32 descriptionSize = sizeof(readback);
            if (AudioObjectGetPropertyData(tapID_, &descriptionAddress, 0, nullptr,
                                           &descriptionSize, &readback) == noErr &&
                readback) {
                LogLine("  tap 回读: exclusive=%d mono=%d mixdown=%d private=%d mute=%ld processes=%lu",
                        readback.isExclusive ? 1 : 0, readback.isMono ? 1 : 0,
                        readback.isMixdown ? 1 : 0, readback.privateTap ? 1 : 0,
                        static_cast<long>(readback.muteBehavior),
                        static_cast<unsigned long>(readback.processes.count));
            } else {
                LogLine("  tap 配置回读失败");
            }
        }

        // 3) 建聚合设备：真实输出设备作主设备/子设备，tap 作为附加输入。
        //    只挂 tap 而不挂真实设备的聚合设备没有时钟源，IO 会一直输出静音。
        std::string outputUID;
        std::string outputError;
        if (!GetDefaultSystemOutputDeviceUID(outputUID, outputError)) {
            error = "读取默认输出设备失败: " + outputError;
            return false;
        }
        LogLine("  主设备/子设备: %s", outputUID.c_str());

        NSString* aggregateUID = [NSString
            stringWithFormat:@"com.loopbackpost.aggregate.%@",
                             [[NSUUID UUID] UUIDString]];
        NSString* outputUIDString = [NSString stringWithUTF8String:outputUID.c_str()];

        NSDictionary* subDevice = @{
            (__bridge NSString*)kLP_SubTapUIDKey : outputUIDString,
        };
        NSDictionary* tapEntry = @{
            (__bridge NSString*)kLP_SubTapUIDKey : (__bridge NSString*)tapUID,
            (__bridge NSString*)kLP_SubTapDriftKey : @NO,
        };
        NSDictionary* aggregateDescription = @{
            (__bridge NSString*)kLP_AggregateNameKey : @"loopbackPost",
            (__bridge NSString*)kLP_AggregateUIDKey : aggregateUID,
            (__bridge NSString*)kLP_AggregateMainSubDeviceKey : outputUIDString,
            (__bridge NSString*)kLP_AggregatePrivateKey : @YES,
            (__bridge NSString*)kLP_AggregateIsStackedKey : @NO,
            (__bridge NSString*)kLP_AggregateTapAutoStartKey : @YES,
            (__bridge NSString*)kLP_AggregateSubDeviceListKey : @[ subDevice ],
            (__bridge NSString*)kLP_AggregateTapListKey : @[ tapEntry ],
        };

        AudioObjectID aggregateID = kAudioObjectUnknown;
        OSStatus aggregateStatus = AudioHardwareCreateAggregateDevice(
            (__bridge CFDictionaryRef)aggregateDescription, &aggregateID);
        aggregateUID_ = [aggregateUID UTF8String];

        CFRelease(tapUID);

        if (aggregateStatus != noErr || aggregateID == kAudioObjectUnknown) {
            error = "创建聚合设备失败（OSStatus=" +
                    std::to_string(aggregateStatus) + "）";
            return false;
        }
        aggregateID_ = aggregateID;

        LogAggregateDiagnostics(aggregateID_);

        // 4) 取格式
        AudioStreamBasicDescription asbd;
        if (GetTapFormat(tapID_, format_, asbd)) {
            DescribeAsbd(asbd);
        } else {
            LogLine("读取 tap 格式失败，按 48kHz/2ch/float32 处理");
            format_.sampleRate = 48000.0;
            format_.channels = 2;
            format_.isFloat = true;
            format_.nonInterleaved = true;
        }

        if (!format_.isFloat) {
            error = "tap 输出不是 float32（当前是整型），暂不支持";
            return false;
        }

        // 5) 环形缓冲：约 340ms；声道指针数组预分配（实时回调里不能再分配）
        const size_t ringFrames = std::max<size_t>(
            16384, static_cast<size_t>(format_.sampleRate * 0.34));
        ring_.Allocate(ringFrames, format_.channels, format_.sampleRate);
        channelPointers_.assign(kMaxChannelBuffers, nullptr);

        // 6) 只读取 IO 缓冲大小，不强行改小 —— 往聚合设备里硬塞很小的
        //    buffer frame size 有时会让 HAL 对齐不上。
        AudioObjectPropertyAddress bufferAddress{
            kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain};
        UInt32 actualBufferFrames = 0;
        UInt32 actualSize = sizeof(actualBufferFrames);
        if (AudioObjectGetPropertyData(aggregateID_, &bufferAddress, 0, nullptr,
                                       &actualSize, &actualBufferFrames) == noErr) {
            LogLine("  IO 缓冲: %u 帧（约 %.1f ms）",
                    static_cast<unsigned>(actualBufferFrames),
                    actualBufferFrames * 1000.0 / format_.sampleRate);
        }

        // 7) 注册回调。默认走 IOProc；--aq 时改走 AudioQueue（另一条独立路径）。
        if (g_useAudioQueue) {
            AudioStreamBasicDescription aqFormat;
            std::memset(&aqFormat, 0, sizeof(aqFormat));
            aqFormat.mSampleRate = format_.sampleRate;
            aqFormat.mFormatID = kAudioFormatLinearPCM;
            aqFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
            aqFormat.mChannelsPerFrame = format_.channels;
            aqFormat.mBitsPerChannel = 32;
            aqFormat.mFramesPerPacket = 1;
            aqFormat.mBytesPerFrame = format_.channels * sizeof(float);
            aqFormat.mBytesPerPacket = aqFormat.mBytesPerFrame;

            const OSStatus aqStatus =
                AudioQueueNewInput(&aqFormat, &AQInputCallback, this, nullptr,
                                   nullptr, 0, &audioQueue_);
            if (aqStatus != noErr || !audioQueue_) {
                error = "AudioQueueNewInput 失败（OSStatus=" +
                        std::to_string(aqStatus) + "）";
                return false;
            }

            CFStringRef uid = CFStringCreateWithCString(
                nullptr, aggregateUID_.c_str(), kCFStringEncodingUTF8);
            const OSStatus deviceStatus = AudioQueueSetProperty(
                audioQueue_, kAudioQueueProperty_CurrentDevice, &uid, sizeof(uid));
            CFRelease(uid);
            LogLine("  AudioQueue 绑定聚合设备: %s（%d）",
                    deviceStatus == noErr ? "成功" : "失败",
                    static_cast<int>(deviceStatus));

            const UInt32 bufferBytes = aqFormat.mBytesPerFrame * 1024;
            for (int i = 0; i < 4; ++i) {
                AudioQueueBufferRef buffer = nullptr;
                if (AudioQueueAllocateBuffer(audioQueue_, bufferBytes, &buffer) !=
                        noErr ||
                    !buffer)
                    break;
                audioQueueBuffers_.push_back(buffer);
                AudioQueueEnqueueBuffer(audioQueue_, buffer, 0, nullptr);
            }

            return true;
        }

        const OSStatus ioStatus = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID_, aggregateID_,
            dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0),
            ^(const AudioTimeStamp* inNow, const AudioBufferList* inInputData,
              const AudioTimeStamp* inInputTime, AudioBufferList* outOutputData,
              const AudioTimeStamp* inOutputTime) {
                this->OnAudio(inInputData, inInputTime);
            });
        if (ioStatus != noErr || !ioProcID_) {
            error = "AudioDeviceCreateIOProcID 失败（OSStatus=" +
                    std::to_string(ioStatus) + "）";
            return false;
        }

        // 7b) 显式把聚合设备的所有输入流打开给这个 IOProc。
        AudioObjectPropertyAddress streamsAddress{kAudioDevicePropertyStreams,
                                                  kAudioDevicePropertyScopeInput,
                                                  kAudioObjectPropertyElementMain};
        UInt32 streamsSize = 0;
        if (AudioObjectGetPropertyDataSize(aggregateID_, &streamsAddress, 0, nullptr,
                                           &streamsSize) == noErr &&
            streamsSize > 0) {
            const UInt32 streamCount = streamsSize / sizeof(AudioStreamID);
            LogLine("  输入流: %u 个", static_cast<unsigned>(streamCount));

            std::vector<uint8_t> usageStorage(sizeof(AudioHardwareIOProcStreamUsage) +
                                              streamCount * sizeof(UInt32));
            auto* usage =
                reinterpret_cast<AudioHardwareIOProcStreamUsage*>(usageStorage.data());
            usage->mIOProc = reinterpret_cast<void*>(ioProcID_);
            usage->mNumberStreams = streamCount;
            for (UInt32 i = 0; i < streamCount; ++i)
                usage->mStreamIsOn[i] = 1;

            AudioObjectPropertyAddress usageAddress{
                kAudioDevicePropertyIOProcStreamUsage, kAudioDevicePropertyScopeInput,
                kAudioObjectPropertyElementMain};
            const OSStatus usageStatus = AudioObjectSetPropertyData(
                aggregateID_, &usageAddress, 0, nullptr,
                static_cast<UInt32>(usageStorage.size()), usage);
            LogLine("  启用输入流: %s（%d）",
                    usageStatus == noErr ? "成功" : "失败",
                    static_cast<int>(usageStatus));
        } else {
            LogLine("  输入流: 0 个");
        }

        return true;
    }

    error = "CoreAudio Process Tap 需要 macOS 14.4 或更新版本（当前系统过旧）";
    return false;
}

void TapCapture::PushAudioQueueBuffer(AudioQueueRef queue,
                                      AudioQueueBufferRef buffer,
                                      const AudioTimeStamp* startTime) {
    if (buffer && buffer->mAudioDataByteSize > 0 && format_.channels > 0) {
        const uint32_t frames =
            buffer->mAudioDataByteSize / (format_.channels * sizeof(float));
        if (frames > 0) {
            uint64_t hostNs = 0;
            if (startTime && (startTime->mFlags & kAudioTimeStampHostTimeValid))
                hostNs = HostTicksToNs(startTime->mHostTime);
            if (hostNs == 0)
                hostNs = NowNs();

            ring_.Push(nullptr, 1, static_cast<const float*>(buffer->mAudioData),
                       frames, hostNs);
        }
    }

    if (queue && buffer)
        AudioQueueEnqueueBuffer(queue, buffer, 0, nullptr);
}

static void AQInputCallback(void* userData,
                            AudioQueueRef queue,
                            AudioQueueBufferRef buffer,
                            const AudioTimeStamp* startTime,
                            UInt32,
                            const AudioStreamPacketDescription*) {
    auto* self = static_cast<TapCapture*>(userData);
    if (self)
        self->PushAudioQueueBuffer(queue, buffer, startTime);
}

bool TapCapture::Start(std::string& error) {
    if (audioQueue_) {
        const OSStatus status = AudioQueueStart(audioQueue_, nullptr);
        if (status != noErr) {
            error = "AudioQueueStart 失败（OSStatus=" + std::to_string(status) + "）";
            return false;
        }
        running_ = true;
        return true;
    }

    if (running_ || aggregateID_ == kAudioObjectUnknown || !ioProcID_)
        return false;

    const OSStatus status = AudioDeviceStart(aggregateID_, ioProcID_);
    if (status != noErr) {
        error = "AudioDeviceStart 失败（OSStatus=" + std::to_string(status) + "）";
        return false;
    }
    running_ = true;

    AudioObjectPropertyAddress runningAddress{kAudioDevicePropertyDeviceIsRunning,
                                              kAudioObjectPropertyScopeGlobal,
                                              kAudioObjectPropertyElementMain};
    UInt32 isRunning = 0;
    UInt32 runningSize = sizeof(isRunning);
    if (AudioObjectGetPropertyData(aggregateID_, &runningAddress, 0, nullptr,
                                   &runningSize, &isRunning) == noErr)
        LogLine("  聚合设备 running=%u", static_cast<unsigned>(isRunning));

    return true;
}

void TapCapture::Stop() {
    if (audioQueue_ && running_) {
        AudioQueueStop(audioQueue_, true);
        running_ = false;
        return;
    }
    if (running_ && aggregateID_ != kAudioObjectUnknown && ioProcID_) {
        AudioDeviceStop(aggregateID_, ioProcID_);
        running_ = false;
    }
}

void TapCapture::Close() {
    Stop();

    if (audioQueue_) {
        AudioQueueDispose(audioQueue_, true);
        audioQueue_ = nullptr;
        audioQueueBuffers_.clear();
    }

    if (aggregateID_ != kAudioObjectUnknown && ioProcID_) {
        AudioDeviceDestroyIOProcID(aggregateID_, ioProcID_);
        ioProcID_ = nullptr;
    }
    if (aggregateID_ != kAudioObjectUnknown) {
        AudioHardwareDestroyAggregateDevice(aggregateID_);
        aggregateID_ = kAudioObjectUnknown;
    }
    if (tapID_ != kAudioObjectUnknown) {
        if (@available(macOS 14.4, *))
            AudioHardwareDestroyProcessTap(tapID_);
        tapID_ = kAudioObjectUnknown;
    }
}

// ============================================================================
// 7. 每路目标：队列、PCM 管线
// ============================================================================

struct PcmBlock {
    std::vector<uint8_t> data;
    uint64_t hostStartNs = 0;
    uint32_t frames = 0;
    bool hasTimestamp = false;
};

struct PcmQueue {
    std::mutex mutex;
    std::deque<PcmBlock> blocks;
    size_t queuedBytes = 0;
};

enum class ChannelMode { Stereo, Left, Right };

struct DestinationSpec {
    std::string url;
    ChannelMode channelMode = ChannelMode::Stereo;
};

struct Destination {
    std::string url;
    ChannelMode channelMode = ChannelMode::Stereo;
    size_t index = 0;

    PcmQueue queue;

    std::mutex partsMutex;
    UrlParts activeParts;

    std::atomic_bool stop{false};
    std::atomic_bool reconnectRequested{false};
    std::atomic_bool captureReady{false};
    std::atomic_bool captureGaveUp{false};

    bool captureDropActive = false;
    bool queueTrimActive = false;

    uint32_t outChannels = 0;
    double sampleRate = 48000.0;
    size_t sendBytesPerFrame = 0;
    size_t sendChunkBytes = 0;
    double sendBytesPerMs = 0.0;
    size_t maxQueuedBytes = 0;
    size_t targetQueuedBytes = 0;
};

static void ConfigureDestination(Destination& destination,
                                 double sampleRate,
                                 uint32_t sourceChannels) {
    const uint32_t outChannels =
        destination.channelMode == ChannelMode::Stereo ? sourceChannels : 1;

    destination.outChannels = outChannels;
    destination.sampleRate = sampleRate;
    destination.sendBytesPerFrame =
        static_cast<size_t>(outChannels) * sizeof(int16_t);
    destination.sendChunkBytes = std::max<size_t>(
        1, static_cast<size_t>(sampleRate * kSendChunkMs / 1000.0) *
               destination.sendBytesPerFrame);
    destination.sendBytesPerMs =
        sampleRate * static_cast<double>(destination.sendBytesPerFrame) / 1000.0;
    destination.maxQueuedBytes = std::max<size_t>(
        destination.sendChunkBytes * 8,
        static_cast<size_t>(destination.sendBytesPerMs *
                            std::max(kDropAllBacklogMs,
                                     kExtraDelayMs + kSendChunkMs + 100.0)));
    destination.targetQueuedBytes = std::max<size_t>(
        destination.sendChunkBytes,
        static_cast<size_t>(destination.sendBytesPerMs *
                            (kExtraDelayMs + kSendChunkMs)));

    // 把 rate / channels 注入 URL（对齐 Windows 版 BuildAudioUrl）
    UrlParts parts;
    std::string error;
    if (ParseUrl(destination.url, parts, error)) {
        SetQueryParameter(parts.path, "rate",
                          std::to_string(static_cast<long long>(sampleRate)));
        SetQueryParameter(parts.path, "channels",
                          std::to_string(outChannels));
        std::lock_guard<std::mutex> lock(destination.partsMutex);
        destination.activeParts = parts;
    }
}

static bool ParseDestinationSpec(const std::string& text, DestinationSpec& spec) {
    std::string token = TrimSpec(text);
    if (token.empty())
        return false;

    spec.channelMode = ChannelMode::Stereo;

    // 只有前缀没有地址，视为无效项。
    if (token == "L" || token == "R")
        return false;

    if (token.size() >= 2 && token[0] == 'L') {
        spec.channelMode = ChannelMode::Left;
        token.erase(0, 1);
    } else if (token.size() >= 2 && token[0] == 'R') {
        spec.channelMode = ChannelMode::Right;
        token.erase(0, 1);
    }

    token = TrimSpec(token);
    if (token.empty())
        return false;

    spec.url = token;
    return true;
}

static std::vector<DestinationSpec> ParseDestinationSpecs(const std::string& input) {
    std::vector<DestinationSpec> specs;
    size_t start = 0;

    while (start <= input.size()) {
        size_t comma = input.find(',', start);
        if (comma == std::string::npos)
            comma = input.size();

        DestinationSpec spec;
        if (ParseDestinationSpec(input.substr(start, comma - start), spec))
            specs.push_back(std::move(spec));

        if (comma == input.size())
            break;
        start = comma + 1;
    }

    return specs;
}

static int16_t FloatToS16(float value) {
    if (!std::isfinite(value))
        value = 0.0f;

    value = std::clamp(value, -1.0f, 1.0f);

    if (value >= 1.0f)
        return 32767;
    if (value <= -1.0f)
        return -32768;

    long v = std::lround(value * 32768.0f);
    if (v > 32767)
        v = 32767;
    if (v < -32768)
        v = -32768;
    return static_cast<int16_t>(v);
}

// 把从 tap 拿到的交错 float 转成交错 s16le。
static void ConvertToS16(const float* src,
                         uint32_t frames,
                         uint32_t channels,
                         std::vector<int16_t>& out) {
    out.resize(static_cast<size_t>(frames) * channels);
    for (size_t i = 0; i < out.size(); ++i)
        out[i] = FloatToS16(src[i]);
}

// PCM 管线：格式转换 + 声道抽取 + 三级丢失丢弃 + 首块校准的年龄计算。
class PcmPipeline {
public:
    PcmPipeline(double sampleRate, uint32_t sourceChannels)
        : sampleRate_(sampleRate), sourceChannels_(sourceChannels) {}

    void ResetCalibration() {
        offsetValid_.store(false, std::memory_order_relaxed);
    }

    void Process(const float* source,
                 uint32_t frames,
                 uint64_t hostNs,
                 std::vector<std::unique_ptr<Destination>>& destinations) {
        if (frames == 0 || sourceChannels_ == 0)
            return;

        // 全静音自检：没有「系统音频录制」权限时，所有 CoreAudio 调用都返回
        // 成功、回调也照常触发，但数据全是 0。这里主动识别并提示。
        if (!silenceChecked_) {
            monitoredFrames_ += frames;
            for (size_t i = 0; i < static_cast<size_t>(frames) * sourceChannels_; ++i) {
                if (source[i] != 0.0f) {
                    monitoredNonZero_ = true;
                    break;
                }
            }
            if (monitoredNonZero_) {
                silenceChecked_ = true;
            } else if (monitoredFrames_ >= sampleRate_ * 2.0) {
                silenceChecked_ = true;
                LogLine("警告: 已经采了 2 秒，样本全是 0 —— 大概率没拿到「系统音频录制」权限。");
                LogLine("      请用 ./start.sh <地址> 以 app 身份启动（终端里直接跑会被系统静默拒绝）。");
            }
        }

        // tap 的 IO 缓冲可能是 512~1024 帧（10~21ms），一次全塞进队列会让
        // 队列水位一下跳到 20ms 以上、触发过期丢弃。所以按 5ms 切片入队，
        // 与 Windows 版的块粒度保持一致。
        const uint32_t framesPerChunk = static_cast<uint32_t>(
            std::max<double>(1.0, sampleRate_ * kSendChunkMs / 1000.0));

        for (uint32_t offset = 0; offset < frames; offset += framesPerChunk) {
            const uint32_t count = std::min(framesPerChunk, frames - offset);
            const uint64_t chunkHostNs =
                hostNs + static_cast<uint64_t>(static_cast<double>(offset) * 1e9 /
                                               sampleRate_);

            ConvertToS16(source + static_cast<size_t>(offset) * sourceChannels_,
                         count, sourceChannels_, capturePcm_);

            for (auto& destinationPtr : destinations) {
                Destination& destination = *destinationPtr;

                if (destination.channelMode == ChannelMode::Stereo) {
                    Enqueue(destination, capturePcm_.data(), capturePcm_.size(),
                            count, chunkHostNs, true);
                } else {
                    // L/R：只取第一/第二声道，输出单声道。
                    const size_t wanted =
                        destination.channelMode == ChannelMode::Left ? 0 : 1;
                    const size_t channel =
                        std::min<size_t>(wanted, sourceChannels_ - 1);

                    channelPcm_.resize(count);
                    for (uint32_t frame = 0; frame < count; ++frame) {
                        channelPcm_[frame] = capturePcm_[
                            static_cast<size_t>(frame) * sourceChannels_ + channel];
                    }
                    Enqueue(destination, channelPcm_.data(), channelPcm_.size(),
                            count, chunkHostNs, true);
                }
            }
        }

        MaybeLogStats();
    }

private:
    void RecordBlock(uint32_t frames, double ageMs) {
        ++statBlocks_;
        statFrames_ += frames;
        statAgeSum_ += ageMs;
        statAgeMax_ = std::max(statAgeMax_, ageMs);
        statMaxFrames_ = std::max(statMaxFrames_, frames);
    }

    void MaybeLogStats() {
        const auto now = std::chrono::steady_clock::now();
        if (statStart_.time_since_epoch().count() == 0) {
            statStart_ = now;
            return;
        }
        const double elapsed = std::chrono::duration<double>(now - statStart_).count();
        if (elapsed < 5.0)
            return;

        LogLine("[pipeline] blocks %llu (max %u frames); age avg %.1f ms, max %.1f ms; dropped %.0f ms; queue %.1f ms",
                static_cast<unsigned long long>(statBlocks_),
                static_cast<unsigned>(statMaxFrames_),
                statBlocks_ ? statAgeSum_ / static_cast<double>(statBlocks_) : 0.0,
                statAgeMax_, statDroppedMs_, lastQueuedMs_);

        statBlocks_ = 0;
        statAgeSum_ = 0.0;
        statAgeMax_ = 0.0;
        statMaxFrames_ = 0;
        statDroppedMs_ = 0.0;
        statStart_ = now;
    }

private:
    // 把 host 时间戳换算成“这段音频现在有多旧”（毫秒）。
    // 首块校准一次偏移后固定不变，避免反复校准引入抖动。
    double ComputeAgeMs(uint64_t hostStartNs, uint32_t frames) {
        if (sampleRate_ <= 0)
            return 0.0;

        const double nowNs = static_cast<double>(NowNs());
        const double endNs = static_cast<double>(hostStartNs) +
                             static_cast<double>(frames) * 1e9 / sampleRate_;

        if (!offsetValid_.load(std::memory_order_relaxed)) {
            offsetNs_.store(nowNs - endNs, std::memory_order_relaxed);
            offsetValid_.store(true, std::memory_order_release);
        }

        const double offset = offsetNs_.load(std::memory_order_relaxed);
        return (nowNs - offset - endNs) / 1e6;
    }

    void Enqueue(Destination& destination,
                 const int16_t* pcm,
                 size_t sampleCount,
                 uint32_t frames,
                 uint64_t hostStartNs,
                 bool hasTimestamp) {
        if (sampleCount == 0)
            return;

        const uint8_t* bytes = reinterpret_cast<const uint8_t*>(pcm);
        size_t size = sampleCount * sizeof(int16_t);
        uint32_t keepFrames = frames;
        uint64_t keepHostStart = hostStartNs;

        // (a) 入队前：从这段音频开头裁掉超龄部分
        if (hasTimestamp && sampleRate_ > 0) {
            const double ageMs = ComputeAgeMs(hostStartNs, frames);
            RecordBlock(frames, ageMs);
            if (ageMs > kEffectiveDropMs) {
                const double excessMs = ageMs - kEffectiveDropMs;
                const uint64_t dropFrames = static_cast<uint64_t>(
                    std::ceil(excessMs * sampleRate_ / 1000.0));

                if (dropFrames >= frames) {
                    LogLine("[dest %zu] Stale packet (%.0f ms old); dropped entirely.",
                            destination.index + 1, ageMs);
                    return;
                }

                statDroppedMs_ += excessMs;
                const size_t dropBytes = static_cast<size_t>(dropFrames) *
                                         destination.outChannels * sizeof(int16_t);
                bytes += dropBytes;
                size -= dropBytes;
                keepFrames = frames - static_cast<uint32_t>(dropFrames);
                keepHostStart = hostStartNs +
                                static_cast<uint64_t>(static_cast<double>(dropFrames) *
                                                      1e9 / sampleRate_);

                if (!destination.captureDropActive) {
                    LogLine("[dest %zu] Audio %.0f ms old; dropped %.0f ms to catch up.",
                            destination.index + 1, ageMs, excessMs);
                    destination.captureDropActive = true;
                }
            } else if (destination.captureDropActive) {
                LogLine("[dest %zu] Audio age back to normal.",
                        destination.index + 1);
                destination.captureDropActive = false;
            }
        }

        // (b) 入队时：字节水位超限 -> 从队头丢；(c) 入队后：按年龄回扫队头
        double staleDroppedMs = 0.0;
        double frontAgeMs = 0.0;
        {
            std::lock_guard<std::mutex> lock(destination.queue.mutex);

            while (destination.queue.queuedBytes + size > destination.maxQueuedBytes &&
                   !destination.queue.blocks.empty()) {
                destination.queue.queuedBytes -=
                    destination.queue.blocks.front().data.size();
                destination.queue.blocks.pop_front();
            }

            PcmBlock block;
            block.data.assign(bytes, bytes + size);
            block.hostStartNs = keepHostStart;
            block.frames = keepFrames;
            block.hasTimestamp = hasTimestamp;

            destination.queue.queuedBytes += size;
            destination.queue.blocks.push_back(std::move(block));

            if (sampleRate_ > 0 && offsetValid_.load(std::memory_order_relaxed)) {
                const double nowNs = static_cast<double>(NowNs());
                const double offset = offsetNs_.load(std::memory_order_relaxed) ;

                size_t staleDropped = 0;
                while (!destination.queue.blocks.empty() &&
                       destination.queue.blocks.front().hasTimestamp) {
                    const PcmBlock& front = destination.queue.blocks.front();
                    const double endNs =
                        static_cast<double>(front.hostStartNs) +
                        static_cast<double>(front.frames) * 1e9 / sampleRate_;
                    const double frontAgeMs = (nowNs - offset - endNs) / 1e6;
                    if (frontAgeMs <= kEffectiveDropMs)
                        break;

                    staleDropped += front.data.size();
                    destination.queue.queuedBytes -= front.data.size();
                    destination.queue.blocks.pop_front();
                }

                if (staleDropped > 0)
                    staleDroppedMs = static_cast<double>(staleDropped) /
                                     destination.sendBytesPerMs;

                // 丢完之后队头的年龄，用作日志的迟滞判定
                if (!destination.queue.blocks.empty() &&
                    destination.queue.blocks.front().hasTimestamp) {
                    const PcmBlock& front = destination.queue.blocks.front();
                    const double endNs =
                        static_cast<double>(front.hostStartNs) +
                        static_cast<double>(front.frames) * 1e9 / sampleRate_;
                    frontAgeMs = (nowNs - offset - endNs) / 1e6;
                }
            }

            if (destination.sendBytesPerMs > 0.0) {
                lastQueuedMs_ = static_cast<double>(destination.queue.queuedBytes) /
                                destination.sendBytesPerMs;
            }
        }

        statDroppedMs_ += staleDroppedMs;

        // 带迟滞的日志：只在真正开始丢、以及队列明显回到安全水位时才各打一行，
        // 避免在阈值附近反复刷屏。
        if (staleDroppedMs >= 1.0) {
            if (!destination.queueTrimActive) {
                LogLine("[dest %zu] Queue backlog; dropped %.0f ms of stale audio.",
                        destination.index + 1, staleDroppedMs);
                destination.queueTrimActive = true;
            }
        } else if (destination.queueTrimActive &&
                   frontAgeMs < kEffectiveDropMs * 0.6) {
            LogLine("[dest %zu] Queue is fresh again.", destination.index + 1);
            destination.queueTrimActive = false;
        }
    }

    double sampleRate_;
    uint32_t sourceChannels_;
    std::atomic<double> offsetNs_{0.0};
    std::atomic_bool offsetValid_{false};
    std::vector<int16_t> capturePcm_;
    std::vector<int16_t> channelPcm_;

    // 诊断统计（只在泵线程里读写）
    std::chrono::steady_clock::time_point statStart_{};
    uint64_t statBlocks_ = 0;
    uint64_t statFrames_ = 0;
    double statAgeSum_ = 0.0;
    double statAgeMax_ = 0.0;
    uint32_t statMaxFrames_ = 0;
    double statDroppedMs_ = 0.0;
    double lastQueuedMs_ = 0.0;

    // 全静音自检
    bool silenceChecked_ = false;
    bool monitoredNonZero_ = false;
    double monitoredFrames_ = 0.0;
};

static void ClearSendQueue(Destination& destination) {
    std::lock_guard<std::mutex> lock(destination.queue.mutex);
    destination.queue.blocks.clear();
    destination.queue.queuedBytes = 0;
}

// 从队头凑满一块（不足则有多少取多少）。
static std::vector<uint8_t> TakeSendBlock(Destination& destination, size_t budget) {
    std::vector<uint8_t> block;
    std::lock_guard<std::mutex> lock(destination.queue.mutex);

    size_t taken = 0;
    while (taken < budget &&
           !destination.queue.blocks.empty()) {
        PcmBlock& front = destination.queue.blocks.front();
        const size_t need = budget - taken;

        if (front.data.size() <= need) {
            block.insert(block.end(), front.data.begin(), front.data.end());
            taken += front.data.size();
            destination.queue.queuedBytes -= front.data.size();
            destination.queue.blocks.pop_front();
        } else {
            block.insert(block.end(), front.data.begin(), front.data.begin() + need);
            front.data.erase(front.data.begin(), front.data.begin() + need);
            taken += need;
            destination.queue.queuedBytes -= need;
        }
    }

    return block;
}

// ============================================================================
// 8. 每路发送线程
// ============================================================================

static void RunSender(Destination& destination, bool serviceMode) {
    const size_t label = destination.index + 1;

    HttpConnection connection;
    WriteStats stats;

    bool connected = false;
    bool streamConfirmed = false;
    bool hasStreamedSuccessfully = false;
    bool everConnected = false;
    int autoReconnectAttempts = 0;
    bool retryAfterDelay = false;
    bool serviceRetryDelay = false;
    bool shortReconnectDelay = false;
    bool waitingForEnter = false;
    size_t successfulChunks = 0;

    bool streaming = false;
    bool primeAudioSeen = false;
    std::chrono::steady_clock::time_point primeDeadline{};
    std::chrono::steady_clock::time_point nextSendTime{};

    auto lastDiagTime = std::chrono::steady_clock::now();
    size_t diagSentBytes = 0;

    const auto extraDelay = std::chrono::nanoseconds(
        static_cast<long long>(std::llround(kExtraDelayMs * 1000000.0)));

    // 节拍按“这一块实际代表多少音频”算，而不是写死 5ms。
    const double sendIntervalMs =
        destination.sendBytesPerMs > 0.0
            ? static_cast<double>(destination.sendChunkBytes) /
                  destination.sendBytesPerMs
            : kSendChunkMs;
    const auto sendInterval = std::chrono::nanoseconds(
        static_cast<long long>(std::llround(sendIntervalMs * 1000000.0)));

    UrlParts activeParts;
    {
        std::lock_guard<std::mutex> lock(destination.partsMutex);
        activeParts = destination.activeParts;
    }

    const auto publishActiveParts = [&]() {
        std::lock_guard<std::mutex> lock(destination.partsMutex);
        destination.activeParts = activeParts;
    };

    const auto closeHttp = [&]() { connection.Close(); };

    const auto openHttp = [&]() -> bool {
        for (;;) {
            closeHttp();
            WriteStats openStats;

            if (connection.Open(activeParts, g_chunked, openStats))
                return true;

            const int failureError = openStats.lastErrno;

            if (!hasStreamedSuccessfully && !everConnected &&
                IsConnectionError(failureError) && AdvancePortFallback(activeParts)) {
                publishActiveParts();
                LogLine("[dest %zu] Cannot connect; trying port %u.", label,
                        static_cast<unsigned>(activeParts.port));
                continue;
            }

            stats.lastErrno = failureError;
            return false;
        }
    };

    const auto waitFor = [&](std::chrono::milliseconds duration) {
        const auto end = std::chrono::steady_clock::now() + duration;
        while (!g_stop.load() && !destination.stop.load() &&
               !destination.reconnectRequested.load()) {
            if (std::chrono::steady_clock::now() >= end)
                break;
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
        }
    };

    const auto markDisconnected = [&]() {
        connected = false;
        streamConfirmed = false;
        streaming = false;
        primeAudioSeen = false;
    };

    while (!g_stop.load() && !destination.stop.load()) {
        if (destination.reconnectRequested.exchange(false)) {
            closeHttp();
            markDisconnected();
            successfulChunks = 0;
            autoReconnectAttempts = 0;
            retryAfterDelay = false;
            serviceRetryDelay = false;
            shortReconnectDelay = true;
            waitingForEnter = false;
            stats = WriteStats{};
            ClearSendQueue(destination);
            LogLine("[dest %zu] Reconnect requested.", label);
        }

        if (!connected) {
            if (waitingForEnter) {
                while (!g_stop.load() && !destination.stop.load() &&
                       !destination.reconnectRequested.load()) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(50));
                }
                if (g_stop.load() || destination.stop.load())
                    break;
                continue;
            }

            if (serviceRetryDelay) {
                waitFor(std::chrono::duration_cast<std::chrono::milliseconds>(
                    kServiceRetryDelay));
            } else if (retryAfterDelay) {
                waitFor(std::chrono::milliseconds(1000));
            } else if (shortReconnectDelay) {
                waitFor(std::chrono::duration_cast<std::chrono::milliseconds>(
                    kCongestionReconnectDelay));
            }

            if (g_stop.load() || destination.stop.load())
                break;
            if (destination.reconnectRequested.load())
                continue;

            LogLine("[dest %zu] Connecting...", label);

            connected = openHttp();
            retryAfterDelay = false;
            shortReconnectDelay = false;

            if (!connected) {
                ++autoReconnectAttempts;

                if (serviceMode && serviceRetryDelay) {
                    LogLine("[dest %zu] HTTP connect failed; retrying in 10 seconds.",
                            label);
                    retryAfterDelay = false;
                } else if (autoReconnectAttempts < kMaxAutoReconnectAttempts) {
                    LogLine("[dest %zu] HTTP connect failed; retrying in 1 second (attempt %d/%d)...",
                            label, autoReconnectAttempts, kMaxAutoReconnectAttempts);
                    retryAfterDelay = true;
                } else if (serviceMode) {
                    LogLine("[dest %zu] Reconnect failed 3 times; retrying in 10 seconds.",
                            label);
                    serviceRetryDelay = true;
                    retryAfterDelay = false;
                    destination.captureGaveUp.store(true);
                } else {
                    LogLine("[dest %zu] Reconnect failed 3 times; press Enter to retry.",
                            label);
                    waitingForEnter = true;
                    retryAfterDelay = false;
                    destination.captureGaveUp.store(true);
                }

                continue;
            }

            publishActiveParts();
            stats = WriteStats{};
            streamConfirmed = false;
            successfulChunks = 0;
            everConnected = true;
            ClearSendQueue(destination);
            streaming = false;
            primeAudioSeen = false;
            lastDiagTime = std::chrono::steady_clock::now();
            diagSentBytes = 0;

            destination.captureReady.store(true);

            LogLine("[dest %zu] HTTP connected; waiting for audio writes...", label);
        }

        size_t readyBytes = 0;
        {
            std::lock_guard<std::mutex> lock(destination.queue.mutex);
            readyBytes = destination.queue.queuedBytes;
        }

        std::vector<uint8_t> block;

        // 连接成功后的抖动缓冲预填充
        if (connected && !streaming) {
            const auto now = std::chrono::steady_clock::now();

            if (!primeAudioSeen) {
                if (readyBytes >= destination.sendChunkBytes) {
                    primeAudioSeen = true;
                    primeDeadline = now + extraDelay;

                    if (kExtraDelayMs > 0.0) {
                        LogLine("[dest %zu] Audio started; holding %lld ms jitter buffer...",
                                label, static_cast<long long>(kExtraDelayMs));
                    }
                }
            } else if (now >= primeDeadline) {
                if (readyBytes >= destination.sendChunkBytes) {
                    streaming = true;
                    nextSendTime = now;

                    LogLine("[dest %zu] Jitter buffer primed at %.0f ms; streaming in %.0f ms chunks.",
                            label,
                            static_cast<double>(readyBytes) /
                                destination.sendBytesPerMs,
                            kSendChunkMs);
                } else {
                    primeAudioSeen = false;
                }
            }
        }

        if (connected && streaming) {
            const auto now = std::chrono::steady_clock::now();

            // 目标水位 + 固定节拍。
            // 迟到一点点（调度抖动）时保留这点“欠账”让下一拍提前补回来，
            // 否则每一拍都重新对齐会永久损失一个抖动量的发送速率，
            // 队列就会慢慢涨到过期阈值、然后周期性丢音频。
            // 落后超过一拍才重置，避免把积压一次性灌进发送缓冲。
            if (now >= nextSendTime && readyBytes >= destination.targetQueuedBytes) {
                // 队列比目标水位高出两块以上时，这一拍多取一块来追赶。
                // 追赶比“丢弃过期音频”温和：不丢样本，就不会有可听见的断点。
                const bool catchUp =
                    readyBytes >
                    destination.targetQueuedBytes + destination.sendChunkBytes * 2;
                block = TakeSendBlock(destination,
                                      destination.sendChunkBytes * (catchUp ? 2 : 1));

                nextSendTime += sendInterval;
                if (nextSendTime + sendInterval < now)
                    nextSendTime = now;
            }
        }

        if (!block.empty()) {
            if (!connection.WritePcm(block.data(), block.size(), g_chunked, stats)) {
                markDisconnected();
            } else {
                ++successfulChunks;

                if (!streamConfirmed && successfulChunks >= 3) {
                    streamConfirmed = true;
                    hasStreamedSuccessfully = true;
                    autoReconnectAttempts = 0;
                    serviceRetryDelay = false;
                    retryAfterDelay = false;
                    LogLine("[dest %zu] Connected. Audio data flowing.", label);
                }

                diagSentBytes += block.size();
            }
        } else if (connected && streaming) {
            // 睡到下一个节拍点，而不是固定 1ms：
            // 固定粒度睡眠会让实际发送周期比 5ms 略长（发送速率偏低几个百分点），
            // 队列就会慢慢涨到过期阈值，然后每隔一会儿丢一次音频。
            // nextSendTime 是累加的，睡过头会在下一个节拍自动补回来。
            const auto now = std::chrono::steady_clock::now();
            if (now < nextSendTime) {
                WaitForNs(std::chrono::duration_cast<std::chrono::nanoseconds>(
                              nextSendTime - now)
                              .count());
            } else {
                // 节拍已到但水位不足：短等一小会儿，等采集把水位补上。
                std::this_thread::sleep_for(std::chrono::microseconds(500));
            }
        } else {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }

        if (connected) {
            const auto nowDiag = std::chrono::steady_clock::now();
            if (nowDiag - lastDiagTime >= std::chrono::seconds(5)) {
                const double elapsedSec =
                    std::chrono::duration<double>(nowDiag - lastDiagTime).count();

                size_t queuedNow = 0;
                {
                    std::lock_guard<std::mutex> lock(destination.queue.mutex);
                    queuedNow = destination.queue.queuedBytes;
                }

                const double sentMs =
                    static_cast<double>(diagSentBytes) / destination.sendBytesPerMs;
                const double realtimeRatio =
                    elapsedSec > 0.0 ? sentMs / (elapsedSec * 1000.0) : 0.0;

                LogLine("[dest %zu] queued %.0f ms; sent %.0f ms in %.1f s (%.0f%% of realtime); write max %.2f ms over1ms %llu",
                        label,
                        static_cast<double>(queuedNow) / destination.sendBytesPerMs,
                        sentMs, elapsedSec, realtimeRatio * 100.0,
                        stats.writeMaxMs,
                        static_cast<unsigned long long>(stats.writeOver1MsCalls));

                lastDiagTime = nowDiag;
                diagSentBytes = 0;
                stats.writeMaxMs = 0.0;
                stats.writeOver1MsCalls = 0;
                stats.blockedMs = 0.0;
            }
        }

        if (!connected && !g_stop.load() && !destination.stop.load()) {
            int httpStatus = 0;
            std::string responseBody;
            std::string location;
            bool portFallbackApplied = false;

            if (connection.fd >= 0) {
                if (connection.ReadResponse(1500, httpStatus, location, responseBody)) {
                    if (!responseBody.empty()) {
                        LogLine("[dest %zu] HTTP %d %s", label, httpStatus,
                                responseBody.c_str());
                    } else {
                        LogLine("[dest %zu] HTTP %d", label, httpStatus);
                    }

                    if (httpStatus >= 300 && httpStatus < 400) {
                        UrlParts redirected;
                        std::string redirectError;
                        const bool redirectedOk =
                            !location.empty() && ParseUrl(location, redirected, redirectError);

                        if (redirectedOk) {
                            SetQueryParameter(
                                redirected.path, "rate",
                                std::to_string(static_cast<long long>(
                                    destination.sampleRate)));
                            SetQueryParameter(
                                redirected.path, "channels",
                                std::to_string(destination.outChannels));
                            activeParts = redirected;
                            publishActiveParts();
                            LogLine("[dest %zu] Following HTTP redirect to http://%s:%u%s",
                                    label, activeParts.host.c_str(),
                                    static_cast<unsigned>(activeParts.port),
                                    activeParts.path.c_str());
                        } else if (!hasStreamedSuccessfully && !everConnected &&
                                   AdvancePortFallback(activeParts)) {
                            portFallbackApplied = true;
                            publishActiveParts();
                            LogLine("[dest %zu] HTTP redirect detected; trying port %u.",
                                    label, static_cast<unsigned>(activeParts.port));
                        }
                    }
                }
            }

            if (!hasStreamedSuccessfully && !everConnected && !portFallbackApplied &&
                IsConnectionError(stats.lastErrno) && AdvancePortFallback(activeParts)) {
                publishActiveParts();
                LogLine("[dest %zu] connection error; trying port %u.", label,
                        static_cast<unsigned>(activeParts.port));
            }

            closeHttp();
            markDisconnected();
            ++autoReconnectAttempts;

            destination.captureReady.store(false);
            destination.captureGaveUp.store(true);

            if (serviceMode && serviceRetryDelay) {
                LogLine("[dest %zu] Connection interrupted; retrying in 10 seconds.",
                        label);
                retryAfterDelay = false;
                shortReconnectDelay = false;
            } else if (autoReconnectAttempts < kMaxAutoReconnectAttempts) {
                LogLine("[dest %zu] Connection interrupted; retrying in 1 second (attempt %d/%d).",
                        label, autoReconnectAttempts, kMaxAutoReconnectAttempts);
                retryAfterDelay = true;
                shortReconnectDelay = false;
            } else if (serviceMode) {
                LogLine("[dest %zu] Reconnect failed 3 times; retrying automatically in 10 seconds.",
                        label);
                retryAfterDelay = false;
                serviceRetryDelay = true;
                shortReconnectDelay = false;
            } else {
                LogLine("[dest %zu] Reconnect failed 3 times; press Enter to retry.",
                        label);
                retryAfterDelay = false;
                serviceRetryDelay = false;
                shortReconnectDelay = false;
                waitingForEnter = true;
            }
        }
    }

    closeHttp();
}

// ============================================================================
// 9. 音量请求（旁路 HTTP GET，和音频流无关）
// ============================================================================

static bool SendVolumeRequest(const UrlParts& parts, const char* path) {
    if (parts.https)
        return false;

    UrlParts target = parts;
    target.path = path;

    // 8880 只是音频流端口，音箱的音量接口挂在 8080 上。
    const uint16_t streamPort = target.port;
    if (target.port == 8880)
        target.port = 8080;

    int fd = -1;
    int err = 0;

    if (!ConnectTcp(target.host, target.port, 1000, fd, err)) {
        // 兜底：8080 不通时再试音频端口本身
        if (target.port != streamPort) {
            target.port = streamPort;
            if (!ConnectTcp(target.host, target.port, 1000, fd, err))
                return false;
        } else {
            return false;
        }
    }

    std::string hostHeader = target.host;
    if (target.port != 80)
        hostHeader += ":" + std::to_string(target.port);

    std::string request = "GET " + target.path + " HTTP/1.1\r\n";
    request += "Host: " + hostHeader + "\r\n";
    request += "User-Agent: workdayAlarmClockGo/1.0\r\n";
    request += "Connection: close\r\n\r\n";

    WriteStats stats;
    const bool sent = SendAll(fd, request.data(), request.size(), stats);
    ::close(fd);
    return sent;
}

static void RunVolumeThread(std::vector<std::unique_ptr<Destination>>& destinations,
                            std::atomic_bool& stopFlag) {
    while (!g_stop.load() && !stopFlag.load()) {
        const unsigned int up = g_volumeUpRequests.exchange(0);
        const unsigned int down = g_volumeDownRequests.exchange(0);

        for (auto& destinationPtr : destinations) {
            Destination& destination = *destinationPtr;

            UrlParts parts;
            {
                std::lock_guard<std::mutex> lock(destination.partsMutex);
                parts = destination.activeParts;
            }

            for (unsigned int i = 0; i < up; ++i) {
                if (SendVolumeRequest(parts, "/volp"))
                    LogLine("[dest %zu] Volume up.", destination.index + 1);
            }
            for (unsigned int i = 0; i < down; ++i) {
                if (SendVolumeRequest(parts, "/volm"))
                    LogLine("[dest %zu] Volume down.", destination.index + 1);
            }
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
}

// ============================================================================
// 10. 终端输入（termios + 方向键）
// ============================================================================

enum class Key { None, Up, Down, Enter, Quit };

static struct termios g_savedTermios;
static bool g_termiosSaved = false;

static void RestoreTerminal() {
    if (g_termiosSaved) {
        tcsetattr(STDIN_FILENO, TCSANOW, &g_savedTermios);
        g_termiosSaved = false;
    }
}

static bool EnableRawTerminal() {
    if (!isatty(STDIN_FILENO))
        return false;
    if (tcgetattr(STDIN_FILENO, &g_savedTermios) != 0)
        return false;

    struct termios raw = g_savedTermios;
    cfmakeraw(&raw);
    raw.c_oflag = g_savedTermios.c_oflag;  // 保留输出处理
    raw.c_cc[VMIN] = 0;
    raw.c_cc[VTIME] = 0;

    if (tcsetattr(STDIN_FILENO, TCSANOW, &raw) != 0) {
        g_termiosSaved = false;
        return false;
    }

    g_termiosSaved = true;
    std::atexit(RestoreTerminal);
    return true;
}

static Key ReadKey(int timeoutMs) {
    if (!isatty(STDIN_FILENO)) {
        std::this_thread::sleep_for(std::chrono::milliseconds(timeoutMs));
        return Key::None;
    }

    struct pollfd pfd;
    pfd.fd = STDIN_FILENO;
    pfd.events = POLLIN;
    pfd.revents = 0;

    const int polled = poll(&pfd, 1, timeoutMs);
    if (polled <= 0)
        return Key::None;

    unsigned char buffer[16];
    const ssize_t n = read(STDIN_FILENO, buffer, sizeof(buffer));
    if (n <= 0)
        return Key::None;

    Key result = Key::None;
    for (ssize_t i = 0; i < n; ++i) {
        const unsigned char c = buffer[i];

        if (c == 0x03)  // Ctrl+C
            return Key::Quit;

        if (c == 0x1b) {
            if (i + 2 < n && buffer[i + 1] == '[') {
                if (buffer[i + 2] == 'A')
                    result = Key::Up;
                else if (buffer[i + 2] == 'B')
                    result = Key::Down;
                i += 2;
            }
            continue;
        }

        if (c == '\r' || c == '\n')
            result = Key::Enter;
    }

    return result;
}

// ============================================================================
// 11. main
// ============================================================================

// ---- WAV 头（探测模式落盘用，方便直接双击播放验证）----
static void PutLE32(uint8_t* p, uint32_t v) {
    p[0] = static_cast<uint8_t>(v & 0xFF);
    p[1] = static_cast<uint8_t>((v >> 8) & 0xFF);
    p[2] = static_cast<uint8_t>((v >> 16) & 0xFF);
    p[3] = static_cast<uint8_t>((v >> 24) & 0xFF);
}

static void PutLE16(uint8_t* p, uint16_t v) {
    p[0] = static_cast<uint8_t>(v & 0xFF);
    p[1] = static_cast<uint8_t>((v >> 8) & 0xFF);
}

static void WriteWavHeader(FILE* file,
                           uint32_t sampleRate,
                           uint16_t channels,
                           uint32_t dataBytes) {
    uint8_t header[44] = {};
    std::memcpy(header, "RIFF", 4);
    PutLE32(header + 4, 36 + dataBytes);
    std::memcpy(header + 8, "WAVE", 4);
    std::memcpy(header + 12, "fmt ", 4);
    PutLE32(header + 16, 16);
    PutLE16(header + 20, 1);  // PCM
    PutLE16(header + 22, channels);
    PutLE32(header + 24, sampleRate);
    PutLE32(header + 28, sampleRate * channels * 2);
    PutLE16(header + 32, static_cast<uint16_t>(channels * 2));
    PutLE16(header + 34, 16);
    std::memcpy(header + 36, "data", 4);
    PutLE32(header + 40, dataBytes);
    std::fwrite(header, 1, sizeof(header), file);
}

static void FinalizeWavHeader(FILE* file, uint32_t dataBytes) {
    uint8_t sizes[4];
    PutLE32(sizes, 36 + dataBytes);
    std::fseek(file, 4, SEEK_SET);
    std::fwrite(sizes, 1, 4, file);
    PutLE32(sizes, dataBytes);
    std::fseek(file, 40, SEEK_SET);
    std::fwrite(sizes, 1, 4, file);
    std::fseek(file, 0, SEEK_END);
}

static void PrintUsage(const char* program) {
    LogLine("用法: %s <地址>[,<地址>...] [额外延迟ms] [最大音频年龄ms] [队列硬上限ms]",
            program);
    LogLine("");
    LogLine("  地址      http://192.168.1.147:8080/aplay （可省略 http:// 和 /aplay 后缀）");
    LogLine("            多项用半角逗号分隔；地址前加 L 或 R 表示只发左/右声道");
    LogLine("  额外延迟  抖动缓冲深度，默认 0");
    LogLine("  最大年龄  超过这个时长的音频会被丢弃以追赶，默认 20");
    LogLine("  队列上限  兜底硬上限，默认 500");
    LogLine("");
    LogLine("  选项:");
    LogLine("    --chunked      流式上传改用 Transfer-Encoding: chunked");
    LogLine("    --fixed-length 流式上传声明超大 Content-Length（默认，与 Windows 版一致）");
    LogLine("    --probe        只探测采集：打印格式 + 电平表，判断是否采到真实声音");
    LogLine("    --probe-out F  探测时把采到的声音写成 WAV 文件 F（可直接播放验证）");
    LogLine("    --probe-seconds N  探测时长，默认 3 秒");
    LogLine("    --help         显示本帮助");
    LogLine("");
    LogLine("  运行时: ↑/↓ 调音箱音量，回车重连，Ctrl+C 退出");
}

static void InstallHandler(int signalNumber, void (*handler)(int)) {
    struct sigaction action;
    std::memset(&action, 0, sizeof(action));
    action.sa_handler = handler;
    sigemptyset(&action.sa_mask);
    sigaction(signalNumber, &action, nullptr);
}

static void SetupSignalHandlers() {
    signal(SIGPIPE, SIG_IGN);

    InstallHandler(SIGINT, [](int) { g_stop.store(true); });
    InstallHandler(SIGTERM, [](int) { g_stop.store(true); });

    // 以 app 身份启动（没有终端）时，用信号做控制：
    //   kill -HUP  <pid>  重连
    //   kill -USR1 <pid>  音量 +
    //   kill -USR2 <pid>  音量 -
    InstallHandler(SIGHUP, [](int) { g_rebuildRequested.store(true); });
    InstallHandler(SIGUSR1, [](int) { g_volumeUpRequests.fetch_add(1); });
    InstallHandler(SIGUSR2, [](int) { g_volumeDownRequests.fetch_add(1); });
}

static void ApplyThreadTuning() {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
}

// 引擎主体：建采集、起发送线程、门控、主循环。
// CLI 和 GUI 两种入口都调用它（GUI 下在独立线程里跑）。
static int RunPipeline(const std::vector<std::string>& positional,
                       bool probeOnly) {
    const std::string input =
        positional.empty() ? std::string() : positional.front();
    const bool serviceMode = !positional.empty();

    // 参数 2/3/4
    auto parsePositive = [](const std::string& text, double fallback, double clamp) {
        if (text.empty())
            return fallback;
        char* end = nullptr;
        const double value = std::strtod(text.c_str(), &end);
        if (!end || *end != '\0' || !std::isfinite(value) || value < 0.0)
            return fallback;
        return std::min(value, clamp);
    };

    if (positional.size() >= 2)
        kExtraDelayMs = parsePositive(positional[1], 0.0, 60000.0);
    if (positional.size() >= 3)
        kDropBacklogMs = parsePositive(positional[2], 20.0, 60000.0);
    if (positional.size() >= 4)
        kDropAllBacklogMs = parsePositive(positional[3], 500.0, 600000.0);

    kEffectiveDropMs = std::max(kDropBacklogMs, kExtraDelayMs + kSendChunkMs + 10.0);

    std::vector<DestinationSpec> specs;
    {
        specs = ParseDestinationSpecs(input);
        if (specs.empty()) {
            LogLine("没有有效的目标地址。");
            return 1;
        }

        for (const DestinationSpec& spec : specs) {
            UrlParts parts;
            std::string error;
            if (!ParseUrl(spec.url, parts, error)) {
                LogLine("无效地址 %s: %s", spec.url.c_str(), error.c_str());
                return 1;
            }
            if (parts.https) {
                LogLine("注意: %s 是 https，本程序只支持明文 http。",
                        spec.url.c_str());
                return 1;
            }
        }
    }

    EnableRawTerminal();

    if (probeOnly) {
        LogLine("探测模式：创建 tap 并统计 %.0f 秒回调（现在放点音乐）...",
                g_probeSeconds);

        TapCapture capture;
        std::string error;
        if (!capture.Open(error)) {
            LogLine("打开采集失败: %s", error.c_str());
            RestoreTerminal();
            return 1;
        }
        if (!capture.Start(error)) {
            LogLine("启动采集失败: %s", error.c_str());
            RestoreTerminal();
            return 1;
        }

        const uint32_t channels = capture.format().channels;
        const uint32_t sampleRate =
            static_cast<uint32_t>(capture.format().sampleRate);

        FILE* out = nullptr;
        uint32_t outBytes = 0;
        if (!g_probeOut.empty()) {
            out = std::fopen(g_probeOut.c_str(), "wb");
            if (!out) {
                LogLine("打不开输出文件 %s，跳过落盘", g_probeOut.c_str());
            } else {
                WriteWavHeader(out, sampleRate, static_cast<uint16_t>(channels), 0);
                LogLine("把采集到的声音写成 WAV: %s", g_probeOut.c_str());
            }
        }

        std::vector<float> scratch(static_cast<size_t>(2048) * 8);
        std::vector<int16_t> pcm;

        size_t totalFrames = 0;
        size_t nonZeroSamples = 0;
        double peak = 0.0;
        double sumSquares = 0.0;
        uint64_t dropped0 = capture.ring().overflowFrames.load();

        const auto deadline = std::chrono::steady_clock::now() +
                              std::chrono::milliseconds(
                                  static_cast<long long>(g_probeSeconds * 1000.0));

        while (std::chrono::steady_clock::now() < deadline) {
            uint64_t hostNs = 0;
            const size_t frames = capture.ring().Pop(scratch.data(), 2048, hostNs);
            if (frames == 0) {
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
                continue;
            }

            totalFrames += frames;

            const size_t samples = frames * channels;
            for (size_t i = 0; i < samples; ++i) {
                const double v = std::isfinite(scratch[i]) ? scratch[i] : 0.0;
                const double a = std::fabs(v);
                if (a > peak)
                    peak = a;
                if (v != 0.0)
                    ++nonZeroSamples;
                sumSquares += v * v;
            }

            if (out) {
                ConvertToS16(scratch.data(), static_cast<uint32_t>(frames), channels,
                             pcm);
                const size_t bytes = pcm.size() * sizeof(int16_t);
                std::fwrite(pcm.data(), 1, bytes, out);
                outBytes += static_cast<uint32_t>(bytes);
            }
        }

        capture.Close();

        if (out) {
            FinalizeWavHeader(out, outBytes);
            std::fclose(out);
        }

        const double seconds =
            static_cast<double>(totalFrames) / static_cast<double>(sampleRate);
        const double rms =
            totalFrames > 0
                ? std::sqrt(sumSquares /
                            static_cast<double>(totalFrames * channels))
                : 0.0;
        const double peakDb = peak > 0.0 ? 20.0 * std::log10(peak) : -999.0;
        const double rmsDb = rms > 0.0 ? 20.0 * std::log10(rms) : -999.0;

        LogLine("收到 %zu 帧（约 %.0f ms 音频），环形缓冲溢出 %llu 帧",
                totalFrames, seconds * 1000.0,
                static_cast<unsigned long long>(
                    capture.ring().overflowFrames.load() - dropped0));
        LogLine("电平：峰值 %.1f dBFS，RMS %.1f dBFS，非零样本 %zu/%zu（%.1f%%）",
                peakDb, rmsDb, nonZeroSamples, totalFrames * channels,
                totalFrames > 0
                    ? 100.0 * static_cast<double>(nonZeroSamples) /
                          static_cast<double>(totalFrames * channels)
                    : 0.0);

        if (peak <= 0.0) {
            LogLine("==> 采集到的是**全静音**：权限没给，或系统没在出声。");
        } else {
            LogLine("==> 采集正常，能拿到真实声音。");
        }

        // 用 open 启动（没有终端）时，把结论落到文件里方便查看
        if (FILE* report = std::fopen("/tmp/loopbackPost-probe.log", "w")) {
            std::fprintf(report, "frames=%zu\npeak=%.6f\nrms=%.6f\nok=%d\n",
                         totalFrames, peak, rms, peak > 0.0 ? 1 : 0);
            std::fclose(report);
        }

        RestoreTerminal();
        return peak > 0.0 ? 0 : 2;
    }

    std::vector<std::unique_ptr<Destination>> destinations;
    destinations.reserve(specs.size());
    for (size_t i = 0; i < specs.size(); ++i) {
        auto destination = std::make_unique<Destination>();
        destination->url = specs[i].url;
        destination->channelMode = specs[i].channelMode;
        destination->index = i;
        destinations.push_back(std::move(destination));
    }

    LogLine("目标数: %zu，额外延迟 %.0f ms，最大音频年龄 %.0f ms，队列上限 %.0f ms，%s",
            destinations.size(), kExtraDelayMs, kDropBacklogMs, kDropAllBacklogMs,
            g_chunked ? "chunked 上传" : "固定长度流式上传");

    TapCapture capture;
    int exitCode = 0;

    for (;;) {
        // ---- 1) 打开采集（先拿格式，再决定 URL 里的 rate/channels）----
        std::string error;
        for (;;) {
            if (capture.Open(error))
                break;

            LogLine("打开音频采集失败: %s", error.c_str());
            LogLine("1 秒后重试（Ctrl+C 退出）...");
            for (int i = 0; i < 50 && !g_stop.load(); ++i)
                std::this_thread::sleep_for(std::chrono::milliseconds(20));
            if (g_stop.load()) {
                capture.Close();
                RestoreTerminal();
                return 1;
            }
        }

        const CaptureFormat format = capture.format();
        LogLine("采集格式: %.0f Hz / %u 声道 / float32%s", format.sampleRate,
                static_cast<unsigned>(format.channels),
                format.nonInterleaved ? "（非交错）" : "（交错）");

        for (auto& destinationPtr : destinations) {
            ConfigureDestination(*destinationPtr, format.sampleRate, format.channels);
            destinationPtr->captureReady.store(false);
            destinationPtr->captureGaveUp.store(false);
            destinationPtr->reconnectRequested.store(false);
            destinationPtr->stop.store(false);
            destinationPtr->captureDropActive = false;
            destinationPtr->queueTrimActive = false;
            ClearSendQueue(*destinationPtr);
        }

        for (const auto& destinationPtr : destinations) {
            UrlParts parts;
            {
                std::lock_guard<std::mutex> lock(destinationPtr->partsMutex);
                parts = destinationPtr->activeParts;
            }
            LogLine("[dest %zu] -> http://%s:%u%s （%u 声道）",
                    destinationPtr->index + 1, parts.host.c_str(),
                    static_cast<unsigned>(parts.port), parts.path.c_str(),
                    destinationPtr->outChannels);
        }

        // ---- 2) 起发送线程 + 音量线程 ----
        PcmPipeline pipeline(format.sampleRate, format.channels);
        pipeline.ResetCalibration();

        std::atomic_bool volumeStop{false};
        std::atomic_bool captureStop{false};
        std::atomic_bool captureFault{false};
        g_rebuildRequested.store(false);

        std::vector<std::thread> senderThreads;
        senderThreads.reserve(destinations.size());
        for (auto& destinationPtr : destinations) {
            Destination* raw = destinationPtr.get();
            senderThreads.emplace_back([&, raw]() {
                pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
                RunSender(*raw, serviceMode);
            });
        }

        std::thread volumeThread([&]() {
            RunVolumeThread(destinations, volumeStop);
        });

        // 采集泵线程：从 tap 环形缓冲取数据 -> 转 s16 -> 按路入队
        std::thread pumpThread([&]() {
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);

            std::vector<float> scratch(static_cast<size_t>(format.channels) * 2048);

            while (!g_stop.load() && !captureStop.load()) {
                uint64_t hostNs = 0;
                const size_t frames = capture.ring().Pop(scratch.data(), 2048, hostNs);
                if (frames == 0) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));
                    continue;
                }
                pipeline.Process(scratch.data(), static_cast<uint32_t>(frames),
                                 hostNs, destinations);
            }
        });

        // ---- 3) 起跑线门控：全部连上才开采集 ----
        const auto gateDeadline =
            std::chrono::steady_clock::now() + kCaptureGateTimeout;
        bool warnedNoLink = false;
        bool gatePassed = false;

        while (!g_stop.load()) {
            bool allReady = true;
            bool gaveUp = false;
            bool anyReady = false;

            for (const auto& destinationPtr : destinations) {
                if (destinationPtr->captureGaveUp.load())
                    gaveUp = true;
                if (destinationPtr->captureReady.load())
                    anyReady = true;
                else
                    allReady = false;
            }

            if (allReady) {
                gatePassed = true;
                break;
            }

            const bool deadlineReached =
                std::chrono::steady_clock::now() >= gateDeadline;

            // 只要有一路连上，就不该让其余路拖着它没声音。
            if (anyReady && (deadlineReached || gaveUp)) {
                gatePassed = true;
                break;
            }

            // 一路都没连上：继续等，别对着空气采集。
            if (!anyReady && !warnedNoLink) {
                LogLine("等待连接到任意一台音箱（Ctrl+C 退出）...");
                warnedNoLink = true;
            }

            const Key key = ReadKey(20);
            if (key == Key::Quit) {
                g_stop.store(true);
                break;
            }
            if (key == Key::Enter) {
                g_rebuildRequested.store(true);
                break;
            }
            if (key == Key::Up)
                ++g_volumeUpRequests;
            if (key == Key::Down)
                ++g_volumeDownRequests;
        }

        bool rebuild = false;

        if (gatePassed && !g_stop.load()) {
            // 让对端播放器真正就绪，消除初始偏移
            const auto settleDeadline =
                std::chrono::steady_clock::now() + kCaptureSettleDelay;
            while (!g_stop.load() &&
                   std::chrono::steady_clock::now() < settleDeadline) {
                std::this_thread::sleep_for(std::chrono::milliseconds(20));
            }

            if (!capture.Start(error)) {
                LogLine("启动采集失败: %s", error.c_str());
                exitCode = 1;
                g_stop.store(true);
            } else {
                LogLine("开始推送。↑/↓ 调音箱音量，回车重连，Ctrl+C 退出。");
            }
        }

        // ---- 4) 主循环 ----
        while (!g_stop.load() && !g_rebuildRequested.load()) {
            const Key key = ReadKey(20);

            if (key == Key::Quit)
                g_stop.store(true);
            else if (key == Key::Enter)
                g_rebuildRequested.store(true);
            else if (key == Key::Up)
                ++g_volumeUpRequests;
            else if (key == Key::Down)
                ++g_volumeDownRequests;

            if (captureFault.load()) {
                LogLine("音频采集出现故障，退出。");
                exitCode = 1;
                g_stop.store(true);
            }
        }

        // ---- 5) 收尾 ----
        capture.Stop();

        captureStop.store(true);
        volumeStop.store(true);
        for (auto& destinationPtr : destinations)
            destinationPtr->stop.store(true);

        if (pumpThread.joinable())
            pumpThread.join();
        if (volumeThread.joinable())
            volumeThread.join();
        for (std::thread& thread : senderThreads) {
            if (thread.joinable())
                thread.join();
        }

        capture.Close();
        pipeline.ResetCalibration();

        if (g_stop.load())
            break;

        if (g_rebuildRequested.load()) {
            rebuild = true;
            LogLine("重新建立采集与连接...");
        }
        (void)rebuild;
    }

    RestoreTerminal();
    return exitCode;
}


// ============================================================================
// 12. 极简图形界面：菜单栏图标（AppKit，不需要 Xcode / storyboard）
//
// 为什么要有 GUI：系统音频权限只认"以 app 身份启动的 bundle"。
// 双击 app 就能用，比记一串命令省事。
// ============================================================================

static std::vector<std::string> g_guiPositional;

@interface LPDelegate : NSObject <NSApplicationDelegate>
@property(strong) NSStatusItem* statusItem;
@property(strong) NSMenuItem* titleItem;
@end

@implementation LPDelegate

// Cmd+C / Cmd+V / Cmd+A 这些快捷键是靠主菜单分发到 first responder 的。
// 我们是 Accessory（没有菜单栏界面）的 app，如果不装主菜单，
// NSAlert 里那个输入框就没法粘贴 —— 装一个最小的「编辑」菜单即可。
- (void)installMainMenu {
    NSMenu* mainMenu = [[NSMenu alloc] init];

    NSMenuItem* appMenuItem = [[NSMenuItem alloc] init];
    NSMenu* appMenu = [[NSMenu alloc] initWithTitle:@"loopbackPost"];
    NSMenuItem* hideItem = [[NSMenuItem alloc] initWithTitle:@"隐藏"
                                                     action:@selector(hide:)
                                              keyEquivalent:@"h"];
    hideItem.target = NSApp;
    [appMenu addItem:hideItem];
    NSMenuItem* quitItem = [[NSMenuItem alloc] initWithTitle:@"退出 loopbackPost"
                                                      action:@selector(quit:)
                                               keyEquivalent:@"q"];
    quitItem.target = self;
    [appMenu addItem:quitItem];
    appMenuItem.submenu = appMenu;
    [mainMenu addItem:appMenuItem];

    NSMenuItem* editMenuItem = [[NSMenuItem alloc] init];
    NSMenu* editMenu = [[NSMenu alloc] initWithTitle:@"编辑"];
    // target 留空 = 沿响应链找 first responder（也就是输入框）
    [editMenu addItemWithTitle:@"撤销" action:@selector(undo:) keyEquivalent:@"z"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"剪切" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"拷贝" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"粘贴" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"全选" action:@selector(selectAll:) keyEquivalent:@"a"];
    editMenuItem.submenu = editMenu;
    [mainMenu addItem:editMenuItem];

    [NSApp setMainMenu:mainMenu];
}

- (void)buildMenu {
    self.statusItem = [[NSStatusBar systemStatusBar]
        statusItemWithLength:NSVariableStatusItemLength];

    NSImage* icon = [NSImage imageWithSystemSymbolName:@"waveform"
                              accessibilityDescription:@"loopbackPost"];
    if (icon)
        self.statusItem.button.image = icon;
    else
        self.statusItem.button.title = @"♪";

    NSMenu* menu = [[NSMenu alloc] init];

    self.titleItem = [[NSMenuItem alloc] initWithTitle:@"loopbackPost"
                                               action:nil
                                        keyEquivalent:@""];
    [menu addItem:self.titleItem];
    [menu addItem:[NSMenuItem separatorItem]];

    NSArray* titles = @[ @"音量 +", @"音量 −", @"重连" ];
    NSArray* actions = @[ @"volumeUp:", @"volumeDown:", @"reconnect:" ];
    for (NSUInteger i = 0; i < titles.count; ++i) {
        NSMenuItem* item = [[NSMenuItem alloc]
            initWithTitle:titles[i]
                   action:NSSelectorFromString(actions[i])
            keyEquivalent:@""];
        item.target = self;
        [menu addItem:item];
    }

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem* logItem = [[NSMenuItem alloc] initWithTitle:@"查看日志"
                                                     action:@selector(openLog:)
                                              keyEquivalent:@""];
    logItem.target = self;
    [menu addItem:logItem];

    NSMenuItem* quitItem = [[NSMenuItem alloc] initWithTitle:@"退出"
                                                      action:@selector(quit:)
                                               keyEquivalent:@"q"];
    quitItem.target = self;
    [menu addItem:quitItem];

    self.statusItem.menu = menu;
}

- (void)volumeUp:(id)sender {
    g_volumeUpRequests.fetch_add(1);
}

- (void)volumeDown:(id)sender {
    g_volumeDownRequests.fetch_add(1);
}

- (void)reconnect:(id)sender {
    g_rebuildRequested.store(true);
}

- (void)openLog:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:@"/tmp/loopbackPost.log"]];
}

- (void)quit:(id)sender {
    g_stop.store(true);
    [NSApp terminate:nil];
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    [self installMainMenu];
    [self buildMenu];

    if (g_guiPositional.empty()) {
        NSAlert* alert = [[NSAlert alloc] init];
        alert.messageText = @"要推送到哪个音箱？";
        alert.informativeText =
            @"例如 192.168.1.147:8080/aplay\n"
            @"多个地址用半角逗号分隔；地址前加 L / R 表示只发左/右声道单声道。";
        alert.alertStyle = NSAlertStyleInformational;

        NSTextField* field = [[NSTextField alloc]
            initWithFrame:NSMakeRect(0, 0, 400, 24)];
        NSString* saved = [[NSUserDefaults standardUserDefaults]
            stringForKey:@"lastURL"];
        field.stringValue = saved ? saved : @"";
        alert.accessoryView = field;

        [alert addButtonWithTitle:@"开始推送"];
        [alert addButtonWithTitle:@"退出"];

        // 让输入框拿到焦点（顺便确保 Cmd+V 落到它身上）
        [alert.window setInitialFirstResponder:field];
        [alert.window makeFirstResponder:field];

        if ([alert runModal] != NSAlertFirstButtonReturn ||
            field.stringValue.length == 0) {
            [NSApp terminate:nil];
            return;
        }

        [[NSUserDefaults standardUserDefaults] setObject:field.stringValue
                                                  forKey:@"lastURL"];
        g_guiPositional.push_back(field.stringValue.UTF8String);
    }

    self.titleItem.title = [NSString stringWithUTF8String:g_guiPositional.front().c_str()];

    std::vector<std::string> positional = g_guiPositional;
    std::thread([positional]() {
        RunPipeline(positional, false);
        g_stop.store(true);
    }).detach();
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    return NO;
}

@end

int main(int argc, char* argv[]) {
    InitTimebase();
    SetupSignalHandlers();
    ApplyThreadTuning();

    // 以 app 身份启动时没有终端，日志落到文件里
    if (!isatty(STDOUT_FILENO))
        OpenLogFile("/tmp/loopbackPost.log");

    std::vector<std::string> positional;
    bool probeOnly = false;

    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--help" || arg == "-h") {
            PrintUsage(argv[0]);
            return 0;
        }
        if (arg == "--chunked") {
            g_chunked = true;
            continue;
        }
        if (arg == "--fixed-length") {
            g_chunked = false;
            continue;
        }
        if (arg == "--probe") {
            probeOnly = true;
            continue;
        }
        if (arg == "--probe-out" && i + 1 < argc) {
            g_probeOut = argv[++i];
            probeOnly = true;
            continue;
        }
        if (arg == "--aq") {
            g_useAudioQueue = true;
            continue;
        }
        if (arg == "--tap-pid" && i + 1 < argc) {
            g_tapPid = static_cast<pid_t>(std::atoi(argv[++i]));
            continue;
        }
        if (arg == "--probe-seconds" && i + 1 < argc) {
            g_probeSeconds = std::atof(argv[++i]);
            if (g_probeSeconds < 1.0 || g_probeSeconds > 60.0)
                g_probeSeconds = 3.0;
            probeOnly = true;
            continue;
        }
        positional.push_back(arg);
    }

    // 以 app bundle 身份启动（双击 .app）时走菜单栏 GUI。
    // 只有 bundle 身份才拿得到 kTCCServiceAudioCapture 授权。
    if (!probeOnly && !isatty(STDOUT_FILENO) &&
        [[NSBundle mainBundle] bundleIdentifier] != nil) {
        g_guiPositional = positional;
        @autoreleasepool {
            NSApplication* app = [NSApplication sharedApplication];
            [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
            LPDelegate* delegate = [[LPDelegate alloc] init];
            app.delegate = delegate;
            [app run];
            (void)delegate;
        }
        return 0;
    }

    if (!probeOnly && positional.empty()) {
        std::printf("workdayAlarmClockGo URL end with /aplay: ");
        std::fflush(stdout);
        std::string line;
        if (!std::getline(std::cin, line) || TrimSpec(line).empty()) {
            LogLine("没有输入地址，退出。");
            return 1;
        }
        positional.push_back(TrimSpec(line));
    }

    return RunPipeline(positional, probeOnly);
}
