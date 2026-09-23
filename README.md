<p align="center">
  <img src="docs/assets/mesharc-banner.svg" alt="MeshArc — Your devices. Within reach." width="100%">
</p>

<h1 align="center">MeshArc</h1>

<p align="center"><strong>让鸿蒙设备，连接你的整个数字生活。</strong><br>
为 HarmonyOS NEXT 打造的 Tailscale 社区客户端，连接设备、互传文件、访问远程存储与媒体服务。</p>

<p align="center">
  <a href="https://appgallery.huawei.com/app/detail?id=io.github.tailscaleohos"><img src="https://img.shields.io/badge/AppGallery-获取_MeshArc-2563eb?style=for-the-badge" alt="在华为应用市场获取 MeshArc"></a>
  <a href="https://github.com/flypigJ/Tailscale-OHOS/releases/latest"><img src="https://img.shields.io/badge/GitHub-Release-334155?style=for-the-badge" alt="查看最新 GitHub Release"></a>
  <a href="README.en.md"><img src="https://img.shields.io/badge/Read_in-English-334155?style=for-the-badge" alt="Read in English"></a>
</p>

<p align="center">
  <a href="#features">功能亮点</a> ·
  <a href="#start">开始使用</a> ·
  <a href="#compatibility">兼容与限制</a> ·
  <a href="docs/development.md">开发文档</a> ·
  <a href="https://github.com/flypigJ/Tailscale-OHOS/issues">反馈问题</a>
</p>

---

出门后访问家里的 NAS，把手机上的文件发送到电脑，或打开远程媒体库。MeshArc 将这些常用操作带进鸿蒙原生界面，让你的 HarmonyOS 设备加入已有的 Tailscale 网络（tailnet）。

**MeshArc 是独立的社区项目，并非 Tailscale 官方客户端。** 本仓库保留 `Tailscale-OHOS` 名称，应用名称为 MeshArc。

<a id="features"></a>
## 一次连接，更多可能

| 你想做的事 | MeshArc 提供的能力 |
| --- | --- |
| **访问自己的设备** | 登录 Tailscale，查看设备在线状态、连接路径与延迟，通过 Tailscale IP 访问远程服务。 |
| **使用家中或远端网络** | 选择可用的出口节点，接收已获批准的子网路由，并配置使用出口节点时的局域网访问。 |
| **在设备间传文件** | MeshSend 集成 Taildrop 收发，并提供 LocalSend 服务联动入口；支持传输进度、取消、重试和接收文件管理。 |
| **浏览远程文件** | 在 Taildrive 中访问已共享且已授权的目录，浏览文件并上传、下载；可用操作取决于共享权限。 |
| **打开远程媒体库** | 检测 Jellyfin、Emby、Plex 服务，并将服务器信息交给 HosPlayer；媒体账户在播放器内登录。 |
| **保护本机访问入口** | 应用锁与 Taildrive 文件夹锁使用系统身份验证；它们保护 MeshArc 内的访问入口，不替代远端共享权限。 |
| **享受原生鸿蒙体验** | ArkUI 原生界面、中英文、浅色与深色主题，以及面向手机、平板和 2in1 的自适应布局。 |

功能介绍以本仓库公开源码为依据；应用市场版本、开发分支与历史安装包可能存在差异，请以所安装版本的更新日志为准。

<a id="start"></a>
## 开始使用

### 1. 获取 MeshArc

**[前往华为应用市场 →](https://appgallery.huawei.com/app/detail?id=io.github.tailscaleohos)**

请在应用市场确认你的设备是否支持安装。源码工程的基线为 **HarmonyOS 6.1 / API 23、arm64**；具体上架版本的系统要求以应用市场为准。

[GitHub Releases](https://github.com/flypigJ/Tailscale-OHOS/releases) 同时保留历史构建。其中早期 `0.3.19-release` HAP 使用开发 Provisioning Profile 签名，不是适用于所有设备的通用安装包，也不包含当前源码的全部功能。其他包的安装条件请查看对应 Release Notes。自行编译请阅读[开发指南](docs/development.md)。

### 2. 加入你的网络

1. 在希望访问的电脑、NAS 或服务器上安装并配置 [Tailscale](https://tailscale.com/download)。
2. 打开 MeshArc，使用同一 tailnet 的账户完成浏览器登录。
3. 点击连接并同意 HarmonyOS 的 VPN 授权，等待连接状态就绪。
4. 选择设备，访问服务、发送文件或浏览已经配置好的 Taildrive 共享。

出口节点、子网路由、Taildrop 与 Taildrive 需要对应的远端服务和访问权限；MeshArc 不会替你开放远端服务或修改 tailnet 的访问策略。

<a id="compatibility"></a>
## 兼容与已知限制

| 项目 | 当前说明 |
| --- | --- |
| 系统与设备 | 源码基线为 HarmonyOS 6.1 / API 23，原生库目标为 arm64。模块声明支持手机、平板和 2in1；已记录的网络验证以真机手机为主。 |
| Tailscale 引擎 | 当前固定为 `1.86.5`，与 OpenHarmony Go 1.24 工具链配套。 |
| MagicDNS | 当前未启用；请使用 Tailscale IP，VPN 配置不下发 Tailscale DNS 或搜索域。 |
| 重启恢复 | 不实现开机自启动；设备重启后打开应用，再手动连接 VPN。 |
| 多 VPN | 启动前请断开其他系统 VPN；已有 VPN 可能导致授权或连接失败。 |
| 实况窗 | 尚未提供流量实况窗入口，需获得相应系统资质后再推进。 |
| 后台连接 | 持续改进熄屏、网络切换与长时间运行的稳定性，欢迎附设备型号和系统版本反馈。 |

## 文档与参与

| 入口 | 内容 |
| --- | --- |
| [开发指南](docs/development.md) | 工程结构、环境准备、构建、签名边界和真机检查。 |
| [贡献指南](CONTRIBUTING.md) | 提交问题、改进文档、翻译和贡献代码。 |
| [应用内更新记录](entry/src/main/ets/services/ReleaseChangelog.ets) | 与源码一起维护的分版本中英文更新内容。 |
| [界面设计约定](docs/harmonyos-ui-design-system.md) | 原生布局、材质、交互与多设备适配。 |
| [Taildrop 实现记录](docs/taildrop-technical-plan.md) | 文件传输的数据路径与实现背景。 |
| [HosPlayer 联动协议](docs/hosplayer-integration-prototype.md) | 服务识别、服务器导入与隐私边界。 |

遇到问题时，请先搜索 [Issues](https://github.com/flypigJ/Tailscale-OHOS/issues)，再附上版本、设备、复现步骤和脱敏后的诊断信息。也欢迎帮助完善中英文文案、测试设备兼容性，或提交范围清晰的 Pull Request。

## 致谢与项目关系

感谢 [Tailscale](https://github.com/tailscale/tailscale)、[OpenHarmony Go](https://gitcode.com/openharmony-sig/ohos_golang_go) 和 [LocalSend](https://github.com/localsend/localsend) 提供的基础与参考，以及参与测试和反馈的用户。

Tailscale、HarmonyOS、LocalSend 和 HosPlayer 的名称与商标归各自所有者。第三方依赖遵循各自的许可证；本仓库目前尚未提供项目级 `LICENSE`，请勿将第三方许可证视为本项目整体的授权声明。
