# 构建与验证

2026-11-04 社区候选验证：完整合成检查、应用类型检查、优化构建和严格签名校验通过。首次云端运行发现全天事项测试依赖宿主时区，已改为按 UTC、上海和洛杉矶各自的民用日期构造旧版事项，并验证相邻日期不会误迁移。使用 Apple Swift 6.4.2（Swift 5 语言模式）、macOS SDK 26.5、arm64 / macOS 14 部署目标。系统默认 SDK 27.2 在本机缺少 SwiftUI 宏插件，因此本次显式选择兼容 SDK；这不是对任意工具链组合的验证。仍有三处既有钥匙串 API 弃用警告。

## 环境

Apple Silicon Mac，macOS 14 或更高版本；安装 Xcode Command Line Tools 或 Xcode，以及 `node`、`python3`。在原生 arm64 终端中运行测试，避免通过 Rosetta 启动终端。

```sh
xcrun swiftc --version
xcrun --sdk macosx --show-sdk-path
node --version
python3 --version
```

脚本使用当前选定开发工具的 SDK，不硬编码本机 SDK 安装路径。Swift 使用 5 语言模式，部署目标为 `arm64-apple-macosx14.0`。这说明编译目标，不表示每个 macOS 版本都经过运行验收。

测试默认要求原生 `arm64` 主机。CI 使用 Intel Mac 时显式设置 `DUEBRIDGE_TEST_ARCH=x86_64`，测试程序按 `x86_64-apple-macosx14.0` 编译并原生执行；请求的架构必须与当前进程架构一致，无效或不匹配的值会在调用编译器前报错。此变量只影响测试，应用构建始终使用 ARM 目标。Apple Silicon 上的 Rosetta 测试不能替代默认的 ARM 原生回归。

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

GitHub Actions 默认使用标准 `macos-15-intel`：检查主机为 `x86_64`，运行原生合成测试，然后用相同源码交叉编译 ARM 应用，最后通过 `lipo` 严格校验产物只有 `arm64`。标签和架构以 [GitHub runner 文档](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)为准。CI 不启动应用、不登录学校账号、不发布二进制。

交叉编译不等于 ARM 原生运行验证。Apple Silicon 本机仍应执行 `./scripts/test.sh all`；需要云端 ARM 原生回归时，在 Actions 的 **Run workflow** 中勾选 **native_arm64**，会改用标准 `macos-15` ARM 主机并执行同一套测试和构建。这一路径仍可能受 GitHub ARM 容量影响。默认 Intel 检查不会扩大应用的支持平台，也没有跳过测试。

CI 开始执行工具检查后会记录所选开发工具目录、Xcode、Swift、SDK、Node.js 和 Python 版本。反馈构建问题时可引用这些工具版本，不要上传包含私人账号或订阅的运行资料。

如果任务标红但步骤列表为空，先查看运行页面的 annotations。出现 `The job was not acquired by Runner of type hosted even after multiple attempts` 及 macOS arm64 capacity 提示，表示 GitHub 未能分配运行机器，代码尚未执行；等待资源恢复后，在该运行页选择 **Re-run failed jobs**。检查 [GitHub 服务状态](https://www.githubstatus.com/)也有帮助，但全局状态正常不保证某个机器池立即可用。

如果已有步骤开始执行，按失败步骤查看日志：工具链输出用于定位 SDK/编译器问题，`FAIL` 或编译错误用于定位真实代码问题。不要用跳过合成测试、删除 ARM 产物校验或把失败设为可忽略来消除红色状态。调整运行机器时，应分别验证原生测试架构和应用产物架构。

测试通过只能证明相应合成场景和编译检查通过。同一 MO 修复在本机安装版已有登录及课程、任务预览正常的用户反馈；社区版独立身份首装、实际提醒事项写入、权限审批、休眠唤醒和系统重启仍需要单独验证。

图标来自项目所有者使用 AI 图像生成工具创作的 DueBridge 视觉素材，包含应用 `.icns` 与展示 PNG，不含学校官方标志。源码包不包含 `.app` 或其他已编译可执行程序。
