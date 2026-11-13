# Windows Microsoft To Do 目标

用户于 2026-11-13 回复「可以试试」，批准上一条提出的独立 To Do 目标方案。此文记录已确认范围和实现选择，不再增加重复确认。

- Windows 11 x64 沿用 BB、智海 MO、学在浙大的采集结果，新增可独立授权和启用的 Microsoft To Do 目标；Outlook 日历与桌面卡片保留独立开关。Mac 本机实现不在本次改动范围，同一微软账户的 To Do 客户端可以查看云端任务。
- 使用已有公开微软应用 ID，按目标分别请求 `Tasks.ReadWrite` 或 `Calendars.ReadWrite`，采用原有个人账户、系统浏览器和本机加密缓存。To Do 账户与日历账户分别绑定，切换一方只撤销该方写入同意。
- 用户确认创建专用「归期 · 课程 DDL」列表，列表和任务均保存归期管理标记。只更新管理范围内的任务，不接管同名个人列表；目标失效或标记冲突时停止并提示。
- 标题为 `【课程】任务`，截止日期为北京时间的自然日，精确截止时刻和可用的来源入口放在详情的归期管理区。更新管理区时保留个人备注，PATCH 不覆盖完成状态、重要程度、用户提醒和子任务。首版不新增自动提醒；已存在的用户提醒保留。
- 重复同步查找稳定任务标记，老师改期更新同一任务；源站暂时缺失时保留已有任务。新建时跳过往日或已取消任务；已有任务可更新为已取消标题，保持用户完成状态。
- POST 前把待确认操作写入当前用户的加密设置。成功或查到已提交任务后清除；超时后查询仍无结果则暂缓重建，用户核对 To Do 后可解除待确认记录。记录含哈希操作键与供本机核对的标题，不上传私人订阅、登录凭据或原始网页。
- 任务本地读取、Outlook 写入和 To Do 写入分别记录成功时间，失败互不阻断。使用同一次来源读取，保留现有北京时间零点、启动/唤醒/联网补查和全局暂停规则。桌面卡片的刷新仍只读，不写入任何云端目标。
- 首版完成状态由 To Do 管理，归期不回写学校，也不因此自动隐藏桌面卡片里的课程截止任务。

验收：合成 HTTP 检查列表归属、分页、重复同步、改期、个人备注和完成状态保留、超时恢复、持久待确认记录、跨账号与暂停取消；设置升级默认不启用 To Do；Windows DPAPI 和 WPF 构建在 CI 验证；用户最后在 Windows 使用个人账户完成真实授权和写入验收。

接口依据：
- https://learn.microsoft.com/en-us/graph/api/todotasklist-post-tasks?view=graph-rest-1.0
- https://learn.microsoft.com/en-us/graph/api/todo-post-lists?view=graph-rest-1.0
- https://learn.microsoft.com/en-us/graph/api/resources/todotask?view=graph-rest-1.0
- https://learn.microsoft.com/en-us/graph/api/singlevaluelegacyextendedproperty-post-singlevalueextendedproperties?view=graph-rest-1.0
