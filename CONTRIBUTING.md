# Contributing to MeshArc · 参与贡献

感谢你帮助改进 MeshArc。文档、翻译、设备兼容性反馈和代码贡献都很有价值。

Thank you for helping improve MeshArc. Documentation, translations, device testing and code contributions are all welcome.

## 报告问题 · Report a problem

先搜索 [已有 Issues](https://github.com/flypigJ/Tailscale-OHOS/issues)，确认没有相同问题。新报告请包含：

Search [existing issues](https://github.com/flypigJ/Tailscale-OHOS/issues) first, then include:

- MeshArc 版本和安装来源 / App version and installation source.
- 设备型号与 HarmonyOS 版本 / Device model and HarmonyOS version.
- 复现步骤、预期行为和实际结果 / Steps to reproduce, expected behavior and actual result.
- 是否使用出口节点、子网路由或其他 VPN / Whether exit nodes, subnet routes or another VPN are involved.
- 必要时提供已脱敏的日志或截图 / Redacted diagnostics or screenshots when useful.

请移除认证链接、密钥、令牌、个人账户、设备标识、tailnet 地址、文件路径及签名信息。不要将未脱敏诊断报告直接发到公开 Issue。

Remove authentication URLs, keys, tokens, personal account details, device identifiers, tailnet addresses, file paths and signing information before posting diagnostics publicly.

## 提交改进 · Propose a change

1. 较大的功能先开 Issue 说明使用场景。For larger changes, open an issue describing the use case first.
2. 每个 Pull Request 聚焦一个改进，保留现有协议、持久化格式和用户数据。Keep each pull request focused; preserve existing protocols, persisted formats and user data.
3. 面向用户的文案同时维护中文和英文；首页改动同步更新两份 README。Update both UI languages and keep the Chinese and English READMEs aligned.
4. 在 PR 中说明行为变化和验证结果；未做真机验证时请明确写出。Describe the behavior change and validation; say explicitly when device testing was not performed.

环境准备和真机检查见 [开发指南](docs/development.md)。For setup and device checks, see the [development guide](docs/development.md).

## 可以从哪里开始 · Ways to help

- 改进首次使用、安装限制与故障排查说明 / Improve onboarding, installation notes and troubleshooting.
- 校对中英文表达 / Refine Chinese and English copy.
- 反馈手机、平板和 2in1 的实际体验 / Report real-device behavior across phones, tablets and 2in1 devices.
- 复现并缩小网络切换、传输或布局问题 / Reproduce and narrow down network-transition, transfer or layout issues.

提交前请检查 diff，仅包含与本次改动有关的内容。不要提交生成的构建产物、依赖目录或签名凭据。应用 Release 的版本、更新日志和签名需要遵循开发指南中的独立发布流程。

Check your diff before submitting. Exclude unrelated changes, generated build output, dependency directories and signing credentials. Application releases follow the separate versioning, changelog and signing process in the development guide.
