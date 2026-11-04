# 构建与验证

2026-11-04 社区候选验证：1,163 项合成检查通过，完整应用类型检查、优化构建和严格签名校验通过。使用 Apple Swift 6.4.2（Swift 5 语言模式）、macOS SDK 26.5、arm64 / macOS 14 部署目标。系统默认 SDK 27.2 在本机缺少 SwiftUI 宏插件，因此本次显式选择兼容 SDK；这不是对任意工具链组合的验证。仍有三处既有钥匙串 API 弃用警告。

## 环境

Apple Silicon Mac，macOS 14 或更高版本；安装 Xcode Command Line Tools 或 Xcode，以及 `node`、`python3`。在原生 arm64 终端中运行测试，避免通过 Rosetta 启动终端。

```sh
xcrun swiftc --version
xcrun --sdk macosx --show-sdk-path
node --version
python3 --version
```

脚本使用当前选定开发工具的 SDK，不硬编码本机 SDK 安装路径。Swift 使用 5 语言模式，部署目标为 `arm64-apple-macosx14.0`。这说明编译目标，不表示每个 macOS 版本都经过运行验收。

如果选定 SDK 与编译器不匹配，SwiftUI 宏插件可能缺失。准备此版本时，本机默认 macOS 27.2 SDK 出现 `SwiftUIMacros` 缺失；兼容的 macOS 26.5 SDK 可编译相关界面。请使用配套的 Xcode / SDK；也可在单次命令中明确选择已经安装且兼容的 SDK：

```sh
DUEBRIDGE_SDK="$(xcrun --sdk macosx26.5 --show-sdk-path)" ./scripts/test.sh all
DUEBRIDGE_SDK="$(xcrun --sdk macosx26.5 --show-sdk-path)" ./scripts/build-app.sh
```

这里的 26.5 是本次环境排查使用的版本示例，不是必装或默认版本；`DUEBRIDGE_SDK` 只改变本次构建所用目录，不改变系统开发工具设置。

## 命令

```sh
./scripts/test.sh all
./scripts/build-app.sh
```

测试包含 ICS 与时间语义、恢复状态、来源身份、平台 payload、采集完整性、请求策略、认证挑战、导航超时、调度协调、写入策略、独立目标列表、读取并发上限及测试用第四适配器契约。`all` 最后对完整应用做类型检查。导航测试在 `build/` 中生成带可控时钟的副本，不修改 `Sources/`。JavaScript 测试执行自有固定脚本和模拟环境，不下载学校代码。

可单独运行一个测试组，例如：

```sh
./scripts/test.sh native-authentication
./scripts/test.sh native-navigation
./scripts/test.sh native-adapter
./scripts/test.sh destination
./scripts/test.sh typecheck
```

脚本中的文件清单是明确列出的；新增源文件时请同步更新 `scripts/source-files.sh` 和相关测试依赖。构建不自动重复执行测试，应先运行上面的测试命令。

## 输出与身份

应用输出为 `build/DueBridge.app`；缓存、测试程序和生成探针也仅写入 `build/`。构建先在临时目录完成，再替换本项目上一次构建的应用。不会安装到 Applications，也不会自动启动。

应用标识为 `org.duebridge.community`，钥匙串服务为 `org.duebridge.community.restart.v1`。社区版以空白设置重新建立目标与登录，不做旧版数据迁移。提醒事项标记和身份算法保留兼容格式；请为社区版选择独立列表，避免两个版本同时管理同一批提醒。

构建使用本地 ad hoc 签名，并验证签名结构；这不等同于 Developer ID 签名、公证或面向其他 Mac 分发的安全验收。重新构建或改变应用位置可能导致系统再次请求权限。

## CI 与验证含义

GitHub Actions 使用 `macos-15`，并在运行前检查 `arm64`。该标签的当前架构以 [GitHub runner 文档](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)为准；架构检查可以阻止标签变化后误跑。CI 运行合成测试并构建应用，不启动应用，不登录学校账号，不发布二进制。

测试通过只能证明相应合成场景和编译检查通过。真实登录、实际提醒事项写入、权限审批、休眠唤醒和系统重启需要单独验证；本次发布没有完成真实账号或重启集成验收。

图标来自项目所有者使用 AI 图像生成工具创作的 DueBridge 视觉素材，包含应用 `.icns` 与展示 PNG，不含学校官方标志。源码包不包含 `.app` 或其他已编译可执行程序。
