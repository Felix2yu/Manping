# P0 整改清单

> 来源：产品业务逻辑与交互审查（2026-11-27）中优先级为「高」的 11 项。  
> 行号基于当前工作树（HEAD `main`），修改后需重新定位；文件路径相对仓库根目录。  
> 每项含：现象 → 证据行号 → 影响 → 修复要点 → 验收标准。

## 排期总览

| 编号  | 主题                   | 主要文件                                                                       | 类型      |
| --- | -------------------- | -------------------------------------------------------------------------- | ------- |
| A1  | 代理「测试通过才生效」与实现相反     | ProxySettingsView / AppModel                                               | 行为缺陷    |
| A2  | 写成功后身份校验失败静默返回       | M4CommentModel / VideoInteractionModel / PGCInteractionModel               | 状态一致性   |
| A3  | 「全部已读」可卡在运行中         | MessagesModel / M6MessageOperations                                        | 状态一致性   |
| A4  | 归档只读被清空确认框击穿         | M3HistoryPage                                                              | 权限/边界   |
| A6  | 付费礼物开关打开后仍不可用        | BiliLiveRoutes / LiveInteractionModel / M7Settings                         | 死开关     |
| A7  | bili-history 令牌与测试链路 | WatchHistoryStore / M7SettingsPage                                         | 表单校验/异常 |
| C1  | 导航层无登录判定             | AppModel / Application                                                     | 权限可见性   |
| C2  | 下载记录只增不删             | Downloads / M7DownloadsPage                                                | 闭环缺失    |
| B1  | 匿名错误态无登录引导           | M3CollectionViews / LibraryModel / M4MomentPage / M6MessagePage            | 交互一致性   |
| B2  | 无统一保存反馈层             | M7SettingsPage / AISettingsSections / M8AISettingsView / ProxySettingsView | 反馈缺失    |
| B12 | 账号写操作未经实网验收          | docs/KnownIssues.md / docs/Parity.md                                       | 验收流程    |



---

## A1 代理：文案承诺「测试通过才生效」，实际先落盘后测试且不回滚

- **位置**：`Sources/ManpingApp/ProxySettingsView.swift:62-82`（`applyAndTest`）、`:68`（先 `apply`）、`:73`（后 `test`）、`:169`（UI 文案）；`Sources/ManpingApp/AppModel.swift:1658`（`settings.save(to:)`）、`:1674`（`proxy.apply`）
- **现象**：`applyAndTest()` 先 `await apply(draft, secret)`，内部即写入设置并启动隧道；随后才 `await test()`。测试失败只置 `failure`（`:78`），配置与隧道均不回滚。界面同时显示「测试通过后才会切换到新设置。」（`:169`），与行为相反。
- **影响**：设置 › 网络 › 代理。用户以为填错不会生效，实际已把流量切到错误代理，可能导致全 App 网络不可用且不知情。
- **修复**：二选一。（a）改为对草稿做连通性测试，通过后再 `apply`；（b）保留当前顺序，但失败时回滚到操作前的 settings 快照并重启旧隧道，同时修正文案。
- **验收**：故意填错端口/密码 → 点「应用并测试」→ 设置文件与运行中的隧道保持原值，仅显示失败原因；正确配置 → 测试通过后才切换。

## A2 写操作已成功、身份校验失败后静默返回

- **位置**：`Sources/ManpingApp/M4CommentModel.swift:256`（评论/回复）、`Sources/ManpingCore/VideoInteractionModel.swift:209`（点赞/投币/收藏/三连）、`Sources/ManpingCore/PGCInteractionModel.swift:219`（番剧互动）
- **现象**：`operation(snapshot)` 已成功发出后，再比对身份，`guard ... sameIdentity(...) else { return }` 直接返回。不执行 `success()`、不复位 `busy`、不清 `mutation`，也不给提示。M4 侧身份事件还会触发 `cancel()` 清空草稿（`M4CommentModel.swift:87`）。
- **影响**：评论、视频互动、番剧互动。表现为按钮长期禁用、列表不刷新、草稿消失；用户重试会二次提交（重复评论/重复投币）。
- **修复**：把「请求已写入」与「界面状态是否可确认」分开处理。写入成功后无论身份是否变化都要：复位 `busy`、失效或重拉列表、保留草稿，并提示「已提交，界面状态待刷新」；不要用 `CancellationError` 吞掉已写结果。
- **验收**：写操作进行中切换账号或触发 token 刷新 → 不出现按钮永久禁用、草稿丢失；再次点击不会产生第二条记录。

## A3 「全部已读」异常时卡在运行中

- **位置**：`Sources/ManpingApp/MessagesModel.swift:187`（置 `.running`）、`:199`（`guard valid else { return }`）、`:222`（`finishMarkRead` 只清 completion、不改 `markReadState`）
- **现象**：`valid == false`（身份变化、取消、代际失效）时直接返回，`markReadState` 永久停留 `.running`，按钮一直显示「正在标记」，用户无法重试。
- **影响**：我的 › 消息 › 全部已读。异常后功能锁死。
- **修复**：`valid == false` 时置为 `.partialFailure("操作被中断，可以重试。")` 并清 `markReadTask`；代际已变化时不覆盖新状态。
- **验收**：标记过程中断网/换号 → 按钮恢复可点、提示可重试。
- **复核修正（2026-11-27）**：`M6MessageOperations.swift:103-104` 的 chat `outcomes` 使用本地 `failures` 计数是**有意设计**——`M6MessageTests` 明确断言「枚举不完整 → `unknown`」「新消息到达 → 仍为 `success`」。本轮误改后这两项测试失败，已回滚，该处不改。

## A4 归档视图仍可触发账号历史的清空确认

- **位置**：`Sources/ManpingApp/M3HistoryPage.swift:73`（`confirmationDialog` 挂在 `body`，不区分来源）、`:113`（`if source == .account` 仅用于视图分支）
- **现象**：确认框与动作不区分 `source`。切到「归档」后，账号侧遗留的确认状态仍可被确认执行 `history.confirmInBackground()`，与 README「归档只读」承诺冲突。
- **影响**：我的 › 历史记录 › 归档。只读边界被击穿，存在误删官方历史的风险。
- **修复**：把 `confirmationDialog` 移入 `source == .account` 分支，或在确认动作内再次校验 `source`。
- **验收**：切到「归档」后无任何删除/清空入口，也无法通过残留确认框执行写操作。

## A6 付费礼物是死开关：打开后仍被 gate 拒绝

- **位置**：`Sources/ManpingCore/BiliLiveRoutes.swift:200`（`production` 白名单仅 `sendDanmaku/setDMConfig/like/wearMedal/sendBag`，无 `sendGold`）、`Sources/ManpingApp/LiveInteractionModel.swift:344`（`gate.allows` 失败置 `.closed`）、`Sources/ManpingCore/M7Settings.swift:263`（设置项文案：「默认关闭。打开后可以用电池送礼…」）
- **现象**：设置 › 直播 打开 `liveAllowPaidGifts` 后，送礼仍被 gate 判 `.closed`，功能不可达；但设置项说明与 README 均给出「打开即可用」的预期。
- **影响**：设置 › 直播、直播互动。用户按说明操作仍失败，且错误提示为「暂未开放」，与开关状态矛盾。
- **修复**：未开放期间将该设置项隐藏或置灰并标注「暂未开放」，同步修订说明文案；待 gate 放开后再恢复。不要保留一个无效果的开关。
- **验收**：设置面板不再出现「打开后可以用电池送礼」的可用承诺；或在 `sendGold` 进入白名单后再放开，并有真实回执验证。

## A7 bili-history：令牌逐字符落盘清缓存、非法地址零提示、测试不退避、清缓存无确认

- **位置**：`Sources/ManpingApp/WatchHistoryStore.swift:202-210`（`setTokenDraft` 每字符写加密存储并 `configure`）、`:126`（`configure` 清空 `records/outbox` 等）、`:184`（`noteFailure`）、`:295-311`（`testConnection`，失败仅写 `testStatus`）；`Sources/ManpingApp/M7SettingsPage.swift:387-390`（测试按钮 `disabled(!canConnect)`）、`:402`（清除缓存无确认）
- **现象**：① 输入令牌时每敲一个字符就写盘并 `configure`，触发 `:126` 清空观看状态缓存；② 地址非法时 `canConnect == false`，测试按钮直接禁用，导致 `:297` 的「请先开启同步并填写服务器地址。」永远不可达，用户看不到原因；③ 测试失败不调用 `noteFailure()`，不进入既有退避；④ 清除缓存无二次确认（对比 `:324` 图片缓存有 `confirmationDialog`）。
- **影响**：设置 › 隐私 › bili-history。输入令牌即丢缓存、失败无解释、可反复点测试、误清缓存。
- **修复**：令牌改为显式保存或 500ms 防抖；非法地址给可见错误并允许测试；失败走 `noteFailure()`；清除缓存补确认框。
- **验收**：逐字输入令牌不丢已有缓存；地址非法有明确提示；断网测试后进入退避并显示下次重试时间；清除缓存需二次确认。

## C1 导航层与菜单校验完全没有登录判定

- **位置**：`Sources/ManpingApp/AppModel.swift:786`（`go(to:)`）、`:779`（`visibleDestinations`）；`Sources/ManpingApp/Application.swift:903`（`validateMenuItem`）、`:964`（`goToDestination`）
- **现象**：四处均不检查 `accountMID` / `needsLogin`。匿名时「我的」6 项（动态、收藏、稍后再看、历史、下载、消息）全部可点，只有各 Model 的 `catch` 报「请先登录」。对照：账户弹窗（`ContentView.swift:242`）、Dock 直播项（`Application.swift:61`）反而做了登录判断。
- **影响**：侧边栏「我的」组、前往菜单、⌘/⌥⌘ 快捷键、Dock 菜单。匿名用户点进去只看到报错，无统一登录路径。
- **修复**：抽 `requiresLogin(Destination)`，在 `go(to:)` 与 `validateMenuItem` 统一处理（置灰并给原因，或点击弹登录）；Dock/菜单栏复用同一判断。
- **验收**：未登录时上述入口行为一致——置灰+说明或弹登录，不再直接发请求报错。

## C2 下载记录只增不删，无时间字段

- **位置**：`Sources/ManpingCore/Downloads.swift:5-27`（`DownloadRecord` 无 `createdAt/completedAt`）、`:54`（仅 `save`）、`:76`（仅 `records`，`DownloadStore` 无 `delete/clear`）；`Sources/ManpingApp/M7DownloadsPage.swift:59-69`（仅取消/恢复/补弹幕/Finder）
- **现象**：任务记录写入 SQLite `tasks` 表后无删除路径，随使用无限累积；列表无时间信息，失败原因只有自由文本 `error`。
- **影响**：我的 › 下载。记录不可维护，长期使用后列表膨胀且无法清理。
- **修复**：`DownloadStore` 增加 `delete(id:)` / `clear()`；记录补 `createdAt/completedAt`；行内加删除，页头加清空（带确认）。
- **验收**：删除单条后重启不复活；清空后列表为空；每行显示创建/完成时间。

## B1 匿名错误态只给「重试」，无登录引导

- **位置**：`Sources/ManpingApp/M3CollectionViews.swift:140-142`、`Sources/ManpingApp/LibraryModel.swift:216`、`Sources/ManpingApp/M4MomentPage.swift:124-125`、`Sources/ManpingApp/M6MessagePage.swift:30-31`
- **现象**：四处错误态文案各写各的，前三处 `actionTitle` 固定为「重试」，只有消息页按 `error.contains("登录")` 额外给「登录」按钮。
- **影响**：我的 › 收藏 / 稍后再看 / 历史记录 / 动态 / 消息。匿名用户被引导去反复重试一个必然失败的请求。
- **修复**：抽统一的状态页变体，`needsLogin` 错误渲染「去登录」主按钮与统一文案，四页复用。
- **验收**：匿名进入上述页面均有「登录」按钮，点击打开登录页；文案一致。

## B2 缺少统一的保存/提交反馈层

- **位置**：`Sources/ManpingApp/M7SettingsPage.swift:117-119`（唯一的全局 alert，仅绑 `model.error`）、`Sources/ManpingApp/AISettingsSections.swift:324`（预设保存成功仅 `close()`）、`Sources/ManpingApp/M8AISettingsView.swift:251,254`（`busy` 仅覆盖 AI）、`Sources/ManpingApp/ProxySettingsView.swift:165`（`busy` 只禁用按钮）
- **现象**：成功提示不齐（预设编辑、弹幕规则、控制条、代理均无）；失败一律内联小字；提交中的禁用态覆盖不全，部分表单在请求中仍可编辑。
- **影响**：全部设置与提交流程。用户无法判断是否保存成功，误以为未生效而重复操作。
- **修复**：建统一 `FeedbackCenter`（成功轻提示、失败 alert、可携带重试动作）；表单统一 `busy` 并在请求期间禁用整表单。
- **验收**：任一保存动作都有明确的成功/失败反馈；提交中不可重复点击、不可改字段。

## B12 账号写操作尚未经实网验收

- **位置**：`docs/KnownIssues.md:7`（PGC 互动未真实写）、`:22`（评论发送/回复/点赞、屏蔽词同步仅 fixture）；`docs/Parity.md:21`（点赞/投币/收藏/三连/关注未执行真实写）、`:29`（PGC 互动未真实写）
- **现象**：全部账号写操作只在 fixture 与匿名只读路径验证，未有真实账号写入记录。
- **影响**：全产品写流程。A2/A3/A6 这类问题正是「未实网验收」的典型产物——fixture 不会触发身份失效与真实错误码。
- **修复**：排一次用户在场的最小写操作验收：评论发送+删除、点赞、投币、收藏、三连、关注、消息全部已读、扫码登录、发弹幕；同时覆盖断网与换号两条失败路径。
- **验收**：每条写操作在真实账号完成一次并回读确认；失败路径有可重试的明确提示；验收结果回写 `KnownIssues.md` 与 `Parity.md`。

## 附：视觉验收记录（fixture 截图）

**方法**：`MANPING_SIGN_IDENTITY=- python3 scripts/build_debug_app.py` 重建带源码指纹的 Debug 包，再
`python3 scripts/live_check.py --fixture --in-app-snapshot --wait 6 --pages …` 抓取；截图只落在
`.build/live-private/`，不提交。覆盖 `popular`、`downloads`、`settings:general|ui|network|privacy|ai|playerbar`，
暗色与浅色各一遍。

发现并已修的视觉问题：

1. **访问令牌行错位**：`SecureField(200)` + 「测试连接」共 284pt，超过设置页控件列的 260pt，`LabeledContent` 退化成
   标签在上、控件在下，按钮被推到下一行并贴上「清除缓存」。改为控件列固定 260pt、输入框自适应剩余宽度。
2. **「清空已结束」不像按钮**：工具栏上用 `AppButtonStyle(size: .small)` 时底板几乎不可见，与左侧筛选标签混淆。
   改用 `toolbarActionStyle(.destructive)`，与「历史记录 › 清空」完全一致（红色胶囊 + 垃圾桶图标）。
3. **反馈提示条落位**：设置窗口原先把提示条压在第一个分组标题（同步观看进度）上，主窗口按整窗居中而偏心。
   改为分别挂在内容列（主窗口）与分类标题行（设置窗口）的 overlay 上。
4. 顺带：代理卡文案改成与实现一致（「会先应用新设置再测试；测试不通过会自动恢复原设置。」），
   并修掉失败提示里 `localizedDescription` 自带句号导致的重复标点。

**未能覆盖**（需人工或实网）：匿名错误态（fixture 恒为合成账号，`--skip-auth` 只跳过钥匙串）、代理测试失败后的
回滚（需真实代理服务器）、两处确认框（需点击）、B12 的实网写操作。

**已知工具限制**：`--in-app-snapshot` 的离屏渲染会把代理卡片画成纯白块；同一构建用窗口截图
（`live_check.py` 不带 `--in-app-snapshot`）则正常，属于快照路径缺陷，不是界面问题。
