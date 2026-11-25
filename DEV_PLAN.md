# Share 复刻 · 开发计划（v0.8 → v1.0）

> 规则：**接口先取证、再写码**。所有路径来自 `audit/endpoints.txt`（weibo.com 自家 bundle 扒出，244 条）
> 与 `audit/js/` 里的调用点上下文，不接受"猜一个试试"。
>
> 底座（`rust/src/**`、`lib/core/api.dart`、`lib/core/models.dart`、`lib/ui/app_theme.dart`）**由主代理统一维护**，
> 子代理只在自己的模块文件里施工，避免并行改同一文件。

---

## 阶段划分

| 阶段 | 内容 | 交付标准 | 负责 | 状态 |
| :--- | :--- | :--- | :--- | :--- |
| **P0 底座** | 补 `statusLikers` / `searchProfile` / `newFollowers` 三个 FFI，重生成桥接，`api.dart` 备好包装 | `flutter analyze` 0 issue | 主代理 | 完成 |
| **P1 四路并行** | M1 详情页三 Tab / M2 主页搜索+新增粉丝 / M3 消息中心 / M4 发布器 | 各自模块 `analyze` 无错误、无 mock 数据 | 4 个子代理 | 完成 |
| **P2 收口** | 主代理审阅、串行修冲突、全量 `flutter analyze` + `flutter test` | 0 issue / 全测试通过 | 主代理 | 完成 |
| **P3 出包** | 打 v0.8 APK，核验新文案进包 | 两个 ABI 产物 + 签名通过 | 主代理 | 完成 |

### P3 产物

| 包 | 大小 | ABI | 校验 |
| :--- | :--- | :--- | :--- |
| `Share-rebuild-arm64-v0.8.apk` | 26.9 MB | 仅 `arm64-v8a`（5 个 so） | 签名 ok / 文案 8/8 |
| `Share-rebuild-x86_64-v0.8.apk` | 28.9 MB | 仅 `x86_64`（5 个 so） | 签名 ok / 文案 8/8 |

`versionCode=8`、`versionName=0.8.0`，`apksigner verify` 通过。

顺手修掉一个体积/稳定性隐患：`flutter build apk --target-platform android-arm64`
其实**不只打 arm64** —— Gradle 没设 `abiFilters` 时会把依赖里所有 ABI 的 `.so`
一起塞进来。v0.8 首版因此 31.6MB，且 `armeabi-v7a` 那套只有两个库
（缺 `libflutter.so` / `libapp.so`），32 位设备选到就是直接崩。
已在 `android/app/build.gradle.kts` 的 `defaultConfig.ndk` 按 `-Ptarget-platform`
精确裁剪，包缩小 **6MB**。

### P2 实际做了什么（不只是跑测试）

四路并行交付的页面**结构合格但交互闭环断了**。验收时逐个点过去，找出 12 处"点了没反应"：

1. `onMore: () {}` × 4（收藏页 / 通知页 / 用户主页 / 超话页）—— 底栏更多是死按钮
2. `onAvatarTap: () {}` × 3 —— 点头像不跳主页
3. `onLike` 未接 × 5 —— 点赞图标不变、数字不动
4. `onLike` 接错 × 2（`catch (_) {}`，成功失败都没反馈）
5. `onRepost` 未接 × 1
6. 收藏按钮全站：调接口成功但**图标不变**
7. 编辑历史页 `onTapSegment: (_) {}` —— @人/话题点不动
8. 屏蔽关键词弹窗把 `TextEditingController` 建在 `builder` 里 —— 每次重建清空输入且永不释放

修法不是逐处打补丁，而是把 `StatusCard` 改成 `ConsumerStatefulWidget`，让点赞 / 收藏 /
更多 / 头像这四件"任何列表都该有"的事成为**内建兜底**：调用方可以覆盖（feed 列表要同步
整条 item），但漏传不再等于死按钮。另外把「编辑微博」改名「重新编辑」——weibo.com 没有
编辑提交端点，原来的实现是把原文填进发布器，用户会以为在改、实际多发一条。

详见 `GAP_AUDIT.md` 第四节。

---

## P1 模块拆解与文件归属

### M1 · 详情页三 Tab（`StatusDetailActivity` 吸顶 Tab）

- **归属文件**：`lib/ui/detail/status_detail_page.dart`、`lib/ui/detail/repost_list_page.dart`、新增 `lib/ui/detail/likers_list.dart`
- **要点**
  - 吸顶 Tab 栏：转发 / 评论 / 赞，等宽、选中下划线跟随主题色，滚动时贴顶
  - 转发：`api.repostList(id, page:)` → 复用 `StatusCard`
  - 评论：沿用现有评论列表与楼中楼入口
  - 赞：`api.statusLikers(id, page:)` → 用户行（头像 36 / 昵称 14sp / 关注按钮）
  - 底部评论输入框只在「评论」Tab 出现
- **验收**：三个 Tab 都能翻页；空态/错误态显示服务端原话；切 Tab 不丢滚动位置

### M2 · 主页内搜索 + 新增粉丝

- **归属文件**：`lib/ui/profile/user_page.dart`、`lib/ui/profile/profile_page.dart`、新增 `lib/ui/profile/profile_search_page.dart`、`lib/ui/profile/new_followers_page.dart`
- **要点**
  - `user_page` 增加「搜索 TA 的微博」入口 → `api.searchProfile(uid, q, page:)`
  - `profile_page` 增加「新增粉丝」入口 → `api.newFollowers(uid, page:, newFollowerCount:)`
  - 两个新页：空态、下拉刷新、加载更多、错误如实显示
- **验收**：登录态可用；未登录时如实提示"需要登录"，不显示假数据

### M3 · 消息中心 + 未读红点

- **归属文件**：`lib/ui/message/notice_page.dart`、`lib/ui/message/message_page.dart`、`lib/ui/dm/dm_list_page.dart`、`lib/core/notice.dart`、`lib/ui/shell/main_shell.dart`
- **要点**
  - 四类通知（@我 / @我评论 / 收到评论 / 收到赞）共用一套分页，切 Tab 各自独立
  - 底栏「消息」红点：`api.unreadHint()`，有未读才显示数字，无则干净
  - 消息 tab 可见时每 60s 静默刷新未读数；私信会话列表下拉刷新
- **验收**：红点不带假数字；切 tab 不重复请求；页面不可见时不轮询

### M4 · 发布器：可见范围 + 发送选项 + 多图排序

- **归属文件**：`lib/ui/compose/compose_page.dart`、新增 `lib/ui/compose/compose_options_sheet.dart`、`lib/ui/compose/watermark.dart`
- **要点**
  - 可见范围胶囊：公开 / 好友圈 / 仅自己 → 真传给 `publish(visible:)`
  - 发送选项面板对齐 `res/menu/n.xml` 十项；**只把能真做的做真**（图片水印、微博尾巴），
    其余（定时发送 / 快转 / 点评 / 签到 / 投票）置灰并写明"需服务端定时任务，本版本未实现"
  - 多图长按拖动排序
  - 水印用 `dart:ui` Canvas 合成，不引第三方依赖
- **验收**：不新增 pubspec 依赖；置灰项点了给出明确说明而不是静默失败

---

## 后续阶段（不在本批）

| 阶段 | 内容 | 阻塞 |
| :--- | :--- | :--- |
| P4 | WeSync 长连接（`push.weibo.cn:8080`）接进 App，替换轮询 | 需登录态才能验证握手与心跳 |
| P5 | 头条文章页 / 超话签到 / 视频画中画 | — |
| P6 | iOS 构建与真机验收 | **需 macOS** |

## 需要用户提供的（唯一阻塞项）

- **一个登录态的微博 Cookie**：好友圈、赞过、新增粉丝、删除、编辑历史这些只有登录才返回数据。
  现在只能验证"路径对、服务端会报登录失效"，无法验证返回体结构。
