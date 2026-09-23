# MeshArc 项目审查

## 1. 审查范围与约束

本审查依据以下资料形成：

- 仓库根目录 `AGENTS.md`；
- `mesh-refactor/document-manifest.md`；
- `mesh-refactor/RULE_BATCHES.md`；
- `mesh-refactor/rules/B01.md` 至 `B05.md`；
- 当前工程配置、ArkTS/ArkUI、VPN Extension、C++ Node-API 桥和 Go 后端实现。

未读取原始 HTML，也未扫描 `build/`、`.hvigor/`、`oh_modules/`、
`node_modules/` 或缓存和产物目录。审查阶段没有修改应用代码。

`mesh-refactor/RULE_INDEX.md` 和 `mesh-refactor/RULE_CONFLICTS.md` 在审查时
不存在，因此当前规则索引和冲突结论直接依据 B01-B05 共 105 条规则形成。
在这两个文件恢复并完成交叉核验前，本文件中对 `REQUIRED`、`RECOMMENDED`、
`OPTIONAL` 和 `EXAMPLE` 的归类只能作为暂定结果，不得单独作为修改业务代码的
依据，也不得把推荐架构或示例阈值升级为 Milestone 的硬性门槛。

## 2. 工程现状

### 2.1 工程配置与模块结构

- 工程使用 Stage 模型，当前兼容和目标 SDK 均为 HarmonyOS API 23。
- `module.json5` 声明 `phone`、`tablet`、`2in1` 三类设备。
- 当前只有一个 Entry HAP，其中同时包含：
  - `EntryAbility`；
  - `TailscaleVpnExtensionAbility`；
  - C++ Node-API 桥；
  - Go c-shared Tailscale 后端。
- 尚无 HAR/HSP。代码层虽已有 `components/` 和 `services/`，但没有形成可由
  编译依赖验证的契约边界。新增 Common HAR 是当前项目选择的一种实现方式，
  不是仅凭“当前无 HAR”即可判定的不符合项。
- 当前工作树已有未提交 UI 和响应式相关变更。后续实施必须把这些变更作为
  基线保存，不得覆盖、回退或混入无关修改。

### 2.2 页面路由、页面和组件

- 页面入口只有 `pages/Index`，Home、Transfer、Settings 由 HDS Tabs 组织。
- 没有应用内 `NavPathStack` 页面路由；这与当前单入口产品形态并不冲突。
- 通知冷启动和热启动通过以下 Want 参数进入应用：
  - `taildropOpenInbox`；
  - `taildropNotificationAction`；
  - `taildropNotificationFileName`；
  - `taildropNotificationFileSize`。
- Moonlight 和 HosPlayer 另有既定 Want/URI 参数契约。
- `BridgeStatus.ets` 当前有 10,644 行、84 个 `@State`、77 个 Builder、
  537 个私有方法和 175 处 `fileIo` 引用。它同时承担页面渲染、Native 调用、
  VPN 编排、文件 IPC、Tailsend、账户、诊断、缓存和设置，是当前最主要的
  模块边界问题。
- 已存在一批较小的展示组件，但业务状态和副作用仍主要集中在巨型组件中。

### 2.3 状态管理

- 主要使用 V1 `@Component`、`@State`、`@StorageLink` 和 `@Watch`。
- `AppStorage` 目前只承担通知 Want 到 UI 的进程内转交，键值必须保持兼容。
- Home 布局偏好使用 Preferences 持久化。
- 网络、账户、Tailsend、连接和诊断状态没有各自独立的 ViewModel/Store。
- 定时器、文件 watcher、Native Promise 和 UI 生命周期交织，状态作用域过大，
  难以单元测试和验证并发恢复。

### 2.4 Tailscale 后端交互

- ArkTS 通过 `libtailscale_ohos.so` 调用 C++ Node-API，再进入 Go c-shared 库。
- Go 后端基于 Tailscale 1.86.5 的 tsnet，并使用 HarmonyOS 外部 TUN 适配。
- 已有异步 NAPI 接口，耗时后端调用不会全部阻塞 ArkUI 主线程。
- ArkTS UI、VPN Extension 和 Go 层存在重复 DTO；若改动字段，当前缺少统一
  的编译期契约和 golden fixture 保护。
- Native 日志大部分只保留固定阶段和错误分类，但部分原始启动错误仍可能经
  状态字符串返回 ArkTS，需要统一分类和脱敏。

### 2.5 VPN 状态与生命周期

- VPN Extension 能创建 HarmonyOS VPN TUN，并把描述符交给 Go userspace engine。
- 支持连接、断开、快速重连、后台保活、进程间后端恢复、出口节点、子网路由
  和 LAN Access。
- UI 与 VPN Extension 通过应用私有文件交换命令、配置、状态和快照。
- 已有心跳新鲜度、陈旧 VPN 状态拒绝、后端 handoff 和失败恢复逻辑。
- `EntryAbility` 使用 `dataTransfer` 长时任务维持必要的 VPN 后台行为。
- 当前主要问题不是功能缺失，而是生命周期逻辑散落在 UI、Extension 和文件
  协议中，缺少可独立测试的协调器。

### 2.6 Tailsend

- 已支持文件、媒体和文本发送，接收保存、通知动作、取消、重试、历史、缓存、
  图片/视频预览和系统分享/选择器。
- Go 层对目标、文件基名、绝对路径、符号链接、根目录、普通文件和大小进行
  复核；接收暂存文件使用 `0600` 和原子替换。
- ArkTS Extension 还会再次检查请求形状和路径，形成双边边界验证。
- 当前不足包括：
  - 大量同步文件操作仍在 UI 组件；
  - 权威状态、可再生成缓存和跨进程 IPC 文件没有统一分类；
  - 缓存被系统清理、迁移中断和进程重启的测试不足；
  - Transfer 业务与页面渲染没有独立边界。

### 2.7 自定义后端

- 默认地址为 Tailscale 官方 HTTPS 控制面，也允许用户配置 HTTPS 或 HTTP
  Headscale 地址。
- 地址必须显式确认后才启动后端，不同控制地址使用 URL 哈希隔离状态目录。
- 当前只保存 URL、确认状态和更新时间，不保存用户名、密码、Token 或 API Key。
- HTTP 地址缺少独立的高风险提示和二次确认。
- 已确认后续继续兼容 HTTP，但必须明确提示风险；不得静默升级、重写或拒绝读取
  已有配置。

### 2.8 数据安全

- tsnet 持久状态位于 `filesDir/tailscale`，当前实际上处于应用私有默认 EL2。
- 状态目录按控制地址隔离，保留 Tailscale 原生格式和读写语义。
- 诊断包使用缓存目录，内容为结构化、身份和地址脱敏数据，并有 24 小时清理。
- 诊断事件使用安全 token，且已有条数上限。
- 仍缺少：
  - 对实际数据安全级别和路径的可执行断言；只有验证当前上下文不满足要求时，
    才需要额外初始化或切换；
  - 全量持久化位置和用途清单；
  - 日志/缓存的字节或容量上限；
  - 临时文件统一目录；
  - 安全迁移、失败恢复和敏感字段自动扫描；
  - 未来应用自有秘密的 Asset Store/HUKS 接口边界。
- 安全改造不得改写 tsnet 状态、重新生成设备身份、强制用户登录，或在读取失败
  时用新凭据覆盖旧数据。

### 2.9 主题系统

- 已有 `resources/base` 和 `resources/dark` 同名颜色资源。
- 主体 UI 优先使用系统颜色、Symbol 和 HDS 自适应材质。
- `EntryAbility.onConfigurationUpdate` 会更新状态栏和导航栏文字颜色。
- 部分组件仍含硬编码颜色和中文文案；并非所有语义颜色都已资源化。
- 已确认主题行为保持“仅跟随系统”，不新增手动浅色/深色开关。

### 2.10 响应式布局和窗口适配

- 当前以组件 `onAreaChange` 获取窗口内容宽度。
- 已有 600vp、840vp 断点、最大内容宽度、底部/侧边导航切换，以及部分主从
  和双栏布局。
- 布局判断基于窗口而不是设备型号，方向正确。
- 尚缺：
  - 窄窗、超宽窗和宽矮/窄高窗口下的内容约束与问题证据；320/1440vp 及
    高宽比阈值只是待验证候选；
  - 显示缩放/density 更新；
  - 分屏和 2in1 自由窗矩阵；
  - 布局类别变化且会重建内容时的 List/Scroll 阅读焦点恢复；
  - 统一 `windowSizeChange` 和 `avoidAreaChange` 环境。
- 所有页面目前使用窗口级全屏沉浸，HDS 标题栏承担部分安全区适配；需要在
  2in1 自由窗口和系统标题区进行验证。

### 2.11 资源、权限和系统能力

- 已有英文 base、中文 `zh_CN` 和深色颜色资源。
- manifest 仅请求 Internet、GET_BUNDLE_INFO 和 KEEP_BACKGROUND_RUNNING。
- 文件与媒体选择主要通过系统 picker，不需要宽泛媒体读取权限。
- 没有显式 SysCap 要求/联想能力集审计，也没有为通知、分享、媒体、外部应用
  等可选能力统一使用 `canIUse()`。

### 2.12 构建和测试

- 项目使用既有 `scripts/build.ps1` 完成 Go、C++、ArkTS、HAP 和 artifact 验证。
- 已有 3 个 Go 测试文件，覆盖路由、TUN I/O、Tailsend 校验和部分媒体探测。
- 没有 ArkTS/Hypium 单元测试，也没有统一测试入口。
- 已有 engine、backend、VPN data、exit node 和用户 UI 真机探针。
- 普通 `go test` 不能直接从当前 PATH 执行；后续测试脚本应复用仓库中的
  OpenHarmony Go 工具链和现有 DevEco 发现逻辑。

## 3. 当前符合项

- Stage 模型和 ArkTS 声明式 UI。
- 当前目标设备类型已在 manifest 中声明。
- 单 HAP 符合当前单 UIAbility、核心 VPN Extension 和同沙箱状态恢复需求。
- 响应式判断基于窗口宽度而不是设备型号。
- `GridRow` 与 `GridCol` 配对使用。
- 已实现底部/侧边导航挪移和部分宽屏主从布局。
- 使用 `getMainWindowSync()`，未使用不受系统旋转锁控制的方向策略。
- 已有 base/dark 同名颜色资源、系统 Token、HDS 材质和动态系统栏颜色。
- tsnet 状态位于应用私有 EL2，持久格式未被自定义加密层破坏。
- VPN/Tailsend 边界已有较强的路径、文件和请求校验。
- 诊断包默认排除原始 HiLog、认证数据、身份字段和网络地址。
- VPN Ability 未导出，权限集合相对克制。

## 4. 当前部分符合项

- 已有组件和服务，但未形成可验证的分层与模块依赖。
- 已有多端布局，但只有宽度断点且缺少完整窗口矩阵。
- 已有深色资源，但硬编码颜色和文案仍会造成主题不一致。
- 已有全屏沉浸和 HDS 安全区，但没有统一窗口/避让环境。
- 已有 VPN 恢复机制，但协调逻辑仍分散在 UI、Extension 和文件协议中。
- 已有 Tailsend 安全校验，但缓存、临时文件和 UI 副作用边界不清晰。
- 已有日志脱敏措施，但缺少统一敏感字段分类和自动扫描。
- 默认 `filesDir` 已是 EL2，但缺少实际路径/安全级别断言；显式初始化是否必要
  需由 API 23 和设备验证决定。
- 有 Go 测试和真机探针，但没有 ArkTS 单测、契约 fixture 和统一测试入口。
- M0 新发现的验证约束：OpenHarmony/Unix Go 测试二进制不能在 Windows 主机执行；
  因此统一测试入口必须执行全包交叉编译，并仅运行 Windows 可执行的纯路由测试。

## 5. 当前不符合项

- 公共契约边界缺少可执行的依赖检查；是否使用 Common HAR 属于项目架构选择，
  不能把示例模块形态本身当成合规结果。
- `BridgeStatus.ets` 同时承担 UI、业务、存储、平台和生命周期职责。
- 可选系统能力没有统一 `canIUse()` 和降级行为。
- 没有完整的数据分类、迁移失败恢复和秘密存储边界。
- HTTP 自定义后端没有独立风险警告。

## 6. M1 实施发现（已修复）

- 新增 HAR 首次独立构建时缺少模块级 `common/hvigorfile.ts`；已补齐最小
  `harTasks` 入口，`assembleHar` 返回 0。
- Entry 新增本地 `file:../common` 依赖后，首次完整构建找不到
  `@tailscale/common`；已通过 OHPM 安装本地依赖并提交生成的锁文件，随后
  `scripts/build.ps1` 返回 0。
- M1 静态 suite 的首版反向依赖正则存在 PowerShell 引号转义错误；已修复并由
  `scripts/test.ps1 -Suite M1Common` 返回 0 验证。

## 5. 当前不符合项（续）

- 缺少覆盖实际目标窗口的布局问题清单和验收矩阵；不能据此直接要求高宽比策略。
- 布局类别变化时尚未验证需要重建的列表能否保持阅读焦点。
- 页面组件直接调用 Native、VPN 和文件 API。
- 没有 ArkTS/Hypium 自动测试。

## 7. 不适用项

- wearable、圆屏、小方形屏、车机和 TV 专用 UI。
- 独立 PC 产品 HAP、Feature HAP、HSP 或按需加载。
- 应用主动创建内部左右分屏。
- 折叠屏悬停态专属业务。
- Web 深色模式适配。
- WaterFlow 列数连续性和 Arc 组件规则。
- HarmonyOS 分布式数据安全标签同步；Tailscale/Tailsend 属于网络通信协议。
- 对所有应用文件进行 HUKS 二次加密。

完整逐条结论见 `APPLICABILITY_MATRIX.md`。
