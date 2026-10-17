# frpc-vnc

支持 frpc 隧道的全平台 VNC 客户端（Flutter）。

## 功能

- **VNC 客户端**
  - RFB 3.3 / 3.7 / 3.8 协议
  - 认证：None / VNC 密码（DES）/ TLS（安全类型 18，TigerVNC/RealVNC 兼容）
  - 编码：Raw / CopyRect / Hextile / Zlib / Tight（含 palette、gradient、JPEG）
  - 剪贴板双向同步、TightVNC 文件传输（x11vnc / TightVNC 服务器）
  - 触控优化：单击点击、长按拖动、双指缩放、粘滞修饰键、Ctrl+Alt+Del
- **frpc 集成**
  - 完整配置 UI：服务端（地址/端口/token/TLS/传输协议/带宽限制）+ tcp/udp/http/https/stcp/xtcp 代理
  - 表单编辑 + TOML 源码双模式，与官方 frpc.toml 格式双向互通（未识别字段无损保留）
  - 多配置 Profile 管理、启动/停止/重启、实时状态与日志
- **两种连接方式**
  - 局域网 IP 直连
  - 通过 frpc 隧道连接（自动列出运行中的 TCP 代理，一键填入本地端口）

## 平台

| 平台 | frpc 实现 | 状态 |
|---|---|---|
| macOS / Windows / Linux | 官方 frpc 二进制（子进程） | ✅ 完整可用 |
| Android | gomobile 桥接库（.aar） | 需先构建 go-bridge |
| iOS | gomobile 桥接库（.xcframework） | 需先构建 go-bridge |

## 本地开发

```bash
# 1. 下载 frpc 二进制（桌面端运行依赖）
./tool/fetch_frpc.sh

# 2. 安装依赖
flutter pub get

# 3. 运行（桌面端）
flutter run -d macos

# 4. 测试
flutter test
```

### 构建移动端 frpc 桥接库

```bash
go install golang.org/x/mobile/cmd/gomobile@latest
gomobile init
cd go-bridge
./build.sh all
# 产物: build/frpcbridge.aar → android/app/libs/
#       build/FrpcBridge.xcframework → ios/Runner (Embed & Sign)
```

### 代码结构

```
lib/
├── models/          # FrpcProfile / ProxyConfig / VncBookmark 数据模型
├── services/
│   ├── frpc/        # TOML 编解码、运行时（桌面子进程/移动 channel）、管理器
│   ├── store/       # JSON 持久化
│   └── vnc/         # RFB 协议引擎（握手/认证/解码器/文件传输）、会话 isolate
└── ui/              # 连接页、frpc 配置编辑器、状态页、VNC 查看器

go-bridge/           # Go 桥接模块（封装 frp client 库，gomobile 编译）
tool/                # fetch_frpc.sh（下载官方二进制）
```

## 自动发版

推 tag 即触发 GitHub Actions 构建 Android APK + macOS/Windows/Linux 桌面包并发布 Release：

```bash
git tag v0.1.0 && git push origin v0.1.0
```

## 设计文档

见 [docs/superpowers/specs/2026-10-17-frpc-vnc-design.md](docs/superpowers/specs/2026-10-17-frpc-vnc-design.md)。
