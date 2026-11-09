# Windows 版

Windows 11 x64 开发版读取 BB、智海 MO 和学在浙大。归期预览显示课程、截止时间和倒计时，Outlook 的专用日历接收同步后的截止事件。手机使用同一 Microsoft 账户的 Outlook 即可查看。

## 构建与微软授权

在 Windows 安装 .NET 10 SDK 和 Microsoft Edge WebView2 Runtime。在仓库根目录运行合成检查和构建：

```powershell
dotnet run --project Windows/DueBridge.Core.Tests
dotnet run --project Windows/DueBridge.School.Tests
node --test Windows/DueBridge.School.Tests/SchoolBridge.test.cjs
dotnet run --project Windows/DueBridge.Outlook.Tests
dotnet build Windows/DueBridge.Windows
```

部署者在 Microsoft Entra 注册允许个人 Microsoft 账户的公共桌面客户端，在「移动和桌面应用程序」平台配置 `http://localhost` 回调，并配置 Microsoft Graph 的委托权限 `Calendars.ReadWrite`。使用应用程序的公开客户端 ID 构建，登录由系统浏览器完成。 [微软注册说明](https://learn.microsoft.com/en-us/entra/identity-platform/scenario-desktop-app-registration)

```powershell
dotnet publish Windows/DueBridge.Windows -c Release -r win-x64 --self-contained true -p:DueBridgeOutlookClientId=YOUR-PUBLIC-CLIENT-ID -o build/windows
```

打开 `build/windows/DueBridge.exe`，保留目录中的运行文件。构建可先用来检查来源预览。连接 Outlook 需要部署者配置的有效客户端 ID。授权时请选择个人 Microsoft 账户。

## 同步

1. 在 BB 页点击「打开 BB 登录网页」。登录后从 BB 日历复制 Get External Calendar Link，粘贴私人 HTTPS 订阅并读取预览。智海 MO 和学在浙大请先连接浙大校园网，再使用各自的学校窗口登录并返回归期读取预览。
2. 登录 Outlook，确认创建专用日历。核对预览后按来源启用同步。
3. 查看每个来源的上次成功时间。可立即同步或暂停，也可选择随 Windows 登录启动。应用运行期间以北京时间零点为每日检查基准，恢复运行后补查。

BB 订阅和 Microsoft 授权缓存由当前 Windows 用户保护。两套学校网页会话使用各自的本机 WebView2 配置。账号密码在相应的学校或微软页面中输入。Outlook 事件保存课程、任务、日期、来源入口和归期的管理标识。

## 验收

GitHub Windows 检查使用合成数据测试来源与 Outlook 写入，再构建 x64 应用。真实学校登录、回跳、会话恢复、Outlook 授权、手机可见性和重启补查需要在真实 Windows 11 与测试账户上分别验收。
