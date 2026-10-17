# frpc-vnc 设计文档

日期：2026-10-17
状态：已确认（方案 A）

## 目标

全平台 VNC 客户端（iOS / Android 为主，兼顾 Windows / macOS / Linux）：

1. **内置 frpc**：应用内完整配置并运行 frpc（服务端配置 + tcp/udp/http/https/stcp/xtcp 代理类型，多配置 Profile 管理，运行状态展示）。
2. **隧道连接 VNC**：frpc 建立隧道后，VNC 引擎连接 frpc 的本地监听端口。
3. **局域网直连**：VNC 引擎直接通过 IP:端口 连接局域网 VNC 服务器。
4. **VNC 能力**：RFB 3.3/3.8，认证 None / VNC 密码 / TLS（security type 18）；编码 Raw / CopyRect / Hextile / Zlib / Tight；剪贴板同步；TightVNC 文件传输；触控优化的查看器 UI。

## 技术选型（方案 A）

- **UI / 业务层**：Flutter（Dart），一套代码覆盖五端。
- **frpc 集成**：
  - 桌面：随应用分发的官方 frpc 二进制，Dart 以子进程方式管理。
  - 移动：Go 桥接模块（`go-bridge/`）封装 frp 官方 client 库，gomobile 编译为 Android `.aar` 与 iOS `.xcframework`，经 platform channel / event channel 调用。
  - 两侧统一抽象为 `FrpcRuntime` 接口：`start(toml) / stop() / status` + 状态事件流。
- **VNC 引擎**：纯 Dart 实现 RFB 协议（不依赖不可靠第三方包），像素解码在独立 isolate 进行；TLS 使用 `SecureSocket`（`onBadCertificate` 可配置校验策略）。
- **配置存储**：Dart 强类型模型 ↔ JSON 持久化；`profileToToml()` / `tomlToProfile()` 双向纯函数与 frpc 原生 TOML 互通，未识别字段保存在 `extra` 原样回写。

## 模块划分

| 模块 | 职责 | 依赖 |
|---|---|---|
| `go-bridge/` | 薄封装 frp client：start/stop/status + 事件回调 | frp 官方库 |
| `lib/models/` | FrpcProfile / ServerConfig / ProxyConfig / VncBookmark | 无 |
| `lib/services/frpc/` | FrpcManager、FrpcRuntime（desktop/mobile 实现）、TOML codec、日志解析 | models |
| `lib/services/vnc/` | RFB 握手/认证/消息、像素解码器（isolate）、输入、剪贴板、文件传输 | 无（纯 Dart） |
| `lib/services/store/` | JSON 持久化（shared_preferences / 文件） | models |
| `lib/ui/` | 连接列表、VNC 查看器、frpc 配置列表/编辑器、运行状态页 | services |
| `test/` | TOML codec、RFB 消息解析、解码器、config store 单元测试 | — |

## 关键设计决策

1. **VNC 与 frpc 完全解耦**：frpc 只负责把远程端口映射到本地端口；VNC 引擎只是 TCP 客户端。"隧道连接"与"局域网直连"是同一条代码路径，仅 host:port 来源不同。
2. **连接闭环**：VNC 连接对话框提供"局域网直连 / 通过 frpc 隧道"两个入口；后者列出所有运行中的 TCP 代理，选中自动填 `127.0.0.1:localPort`。
3. **TOML 互通**：专家用户可在编辑器"TOML 源码"标签页直接编辑/粘贴 frpc.toml，解析失败时报具体错误。
4. **生命周期**：`stopped → starting → running → stopping` 状态机；桌面子进程随父进程退出清理；移动端随 App 进程回收。
5. **像素解码 isolate**：网络读取 + 解码在 worker isolate，主 isolate 仅接收 RGBA 帧并渲染（`ui.Image` / RawImage），保证 UI 不卡顿。

## RFB 协议实现要点

- 握手：支持 RFB 003.003 / 003.007 / 003.008。
- 安全类型：None(1)、VNC 认证(2，DES challenge-response)、TLS(18，TigerVNC/RealVNC 兼容，Dart `SecureSocket` 重握手)。
- 像素格式：协商为客户端首选（32bpp RGBA），支持服务端 bpp 16/32 解码。
- 编码：Raw(0)、CopyRect(1)、Hextile(5)、Zlib(6)、Tight(7，含基本过滤与 JPEG)。
- 交互：FBU 请求（增量矩形 + 全帧请求策略）、输入事件（key/pointer）、剪贴板（ClientCutText/ServerCutText，UTF-8 兼容处理）。
- 文件传输：TightVNC 扩展（client msg 130/131，FileListRequest / FileDownload / FileUpload），查看器工具栏提供上传/下载入口。

## 错误处理

- frpc：启动失败（二进制缺失/端口占用/认证失败）→ 状态页展示最后错误与最近日志；TOML 解析错误逐行提示。
- VNC：连接超时（默认 10s 可配）、认证失败（明确提示密码错误）、协议不兼容（列出服务器支持的 security types）。
- 网络中断：自动断开并回连接页，隧道场景提示检查 frpc 状态。

## 测试策略

- TOML codec：双向转换 + 未识别字段保留 + 各代理类型字段全覆盖。
- RFB：以内存模拟 server socket 做握手/认证/消息解析/各解码器单元测试（构造字节流断言解码结果）。
- Config store：持久化读写往返。
- UI 手工验收：用户最终验收。

## 交付边界

- 移动端 frpc 依赖 gomobile 构建产物；仓库内提供 Go 桥接源码与一键构建脚本（`go-bridge/build.sh`）。若验收机无 gomobile/NDK/Xcode 配置，桌面端可完整运行验收，移动端构建脚本就绪。
- frpc 二进制不入库，提供 `tool/fetch_frpc.sh` 从 GitHub Release 下载各平台官方二进制。
