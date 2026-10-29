# 工作咩闹钟 · macOS 音频推送

把 Mac 正在播放的声音实时推给局域网里的「工作咩闹钟」音箱。系统要求 **macOS 14.4 及以上**。

## 安装

1. 打开 [Releases](../../releases) 页面，下载最新的 `loopbackPost.app.zip`。
2. 解压，把 `loopbackPost.app` 拖进「应用程序」文件夹。
3. 从「应用程序」启动即可。

> 本 app 未做公证签名。若提示「无法打开，因为无法验证开发者」：
> 在 Finder 里**右键 → 打开**，或到「系统设置 → 隐私与安全性」点「仍要打开」。

## 首次运行

1. 弹出「想要录制系统音频」→ 点**允许**（不给权限会一直推送静音）。
2. 填音箱地址，例如 `192.168.1.147:8080/aplay`，会自动记住上次填的。
3. 菜单栏出现 `⌁` 图标，开始推送；菜单里有音量、重连、查看日志、退出。

想换地址：先「退出」，再重新打开。

## 开机自动启动（可选）

先把 app 放到「应用程序」，并手动启动过一次（授权才会记到这个 app 上）。然后在终端粘贴：

```bash
cat > ~/Library/LaunchAgents/com.loopbackpost.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.loopbackpost</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/loopbackPost.app/Contents/MacOS/loopbackPost</string>
        <string>192.168.1.147:8080/aplay</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
</dict>
</plist>
PLIST

launchctl load ~/Library/LaunchAgents/com.loopbackpost.plist
```

地址换成自己的（多个用逗号分隔）。这样启动后不用再填地址；连接失败会自动每 10 秒重试。

关闭自启：

```bash
launchctl unload ~/Library/LaunchAgents/com.loopbackpost.plist
rm ~/Library/LaunchAgents/com.loopbackpost.plist
```

改地址：改 plist 里的 `<string>`，然后 `unload` 再 `load` 一次。

## 常见问题

- **有声音但音箱没声**：确认地址正确、Mac 和音箱在同一局域网，日志见 `/tmp/loopbackPost.log`。
- **完全没有输出**：系统设置 → 隐私与安全性 → 屏幕与系统录音，确认 loopbackPost 已勾选。

## 开发

```bash
./build.sh          # 生成 loopbackPost.app
./start.sh 192.168.1.147:8080/aplay
./ctl.sh up|down|reconnect|quit|status
```
