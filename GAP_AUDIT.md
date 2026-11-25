# Share 1:1 复刻 · 缺口审计（v0.7）

> 口径：以 `decompiled/` 里**可验证的证据**为准（AndroidManifest、`res/layout`、`res/menu`、
> `res/values/*.xml`、weibo.com 自己的前端 bundle），不采信任何未经核对的描述。
>
> 统计：应用自身 Activity **84 个**（Manifest 实测），本轮结束时 Flutter 侧可对应 **26 个**。

---

## 一、本轮（v0.7）做完的事

| 项 | 证据来源 | 说明 |
| :--- | :--- | :--- |
| 侧栏抽屉 | 抽屉 11 项、`drawer_cover_type`/`drawer_menu` 偏好键 | 封面 + 头像 + 昵称 + 关注/粉丝/微博 + 账号切换 + 导航项 + 夜间开关 |
| 首页顶栏 | `allGroups` 分组结构、`feed/{unreadfriend,friend,group}stimeline` | 左头像开抽屉、中间分组 ▾、右发微博/搜索 |
| 分组时间线 | bundle 实测：`gid` 前缀 `10001*`→全部关注、`11000/11001/11002*`→好友圈、其余→分组 | 一个 `feed_timeline(gid)` 打通三种时间线 |
| 卡片底栏 | `res/layout/ke.xml`：`weightSum=8`，2:2:2:1:1，`minHeight=42dp`，图标 `20dp`，间距 `5dp`，数字加粗 | 转发 / 评论 / 赞 / 收藏(可选) / 更多 |
| 卡片版式 | `res/layout/kp.xml` + `kj.xml` + `dimens.xml` | **正文通栏**（左右 16dp），不是缩进到头像右侧；头像 **36dp**、昵称 **14sp**、来源 **11sp**、分割线 **1dp** |
| 更多菜单 | `res/menu/v.xml` 16 项 + 各 `android:visible` | 分享 / 浏览器打开 / 收藏 / 复制 / 屏蔽 / 投诉 / 生成长图 / 保存图片 / 编辑微博 / 编辑历史 / 删除 |
| 屏蔽二级弹窗 | 同上 | 博主 / 关键词 / 来源，写入 `muted_uids` `muted_sources` `block_keywords` |
| 生成长图 | — | 卡片 `RepaintBoundary` 截图 → PNG → 系统分享 |
| 编辑历史页 | `GET /ajax/statuses/editHistory?mid=&page=` | 版本倒序列出 |
| 赞过的微博 | `GET /ajax/statuses/likelist?uid=&page=&with_total=true` | 对应 `PersonalLikedStatusActivity` |
| 关于页 | `SettingAboutActivity` | 版本 / 协议 / 隐私 / 开源许可 |
| 手势 | `direct_repost`、`like_status_long_click` | 双击赞、长按快转、长按快速评论、长按卡片出菜单 |

### 本轮修掉的两个**真 bug**

原实现的两个写接口路径在微博前端里根本不存在，点赞/收藏一直静默失败：

| 功能 | 旧（错） | 现（bundle 实测） |
| :--- | :--- | :--- |
| 点赞 | `POST /ajax/statuses/like` + `type=like` | `POST /ajax/statuses/setLike` / `cancelLike`，body `{id}` |
| 收藏 | `POST /ajax/favorites/create` / `destroy` | `POST /ajax/statuses/createFavorites` / `destoryFavorites`，body `{id}` |

两处现在都会校验响应里的 `ok`，失败时把服务端原话抛给 UI，不再假装成功。

---

## 二、还没做（按用户感知强度排序）

### A. 高频入口，缺了会明显感到"不是原版"

| # | 原版 Activity | 现状 | 需要的接口（已从 bundle 确认存在） |
| :--- | :--- | :--- | :--- |
| 1 | `HotStatusActivity` / `HotPageActivity` | 现在是「热搜榜 + 公开时间线」，缺热门微博榜本体 | `/ajax/feed/hottimeline` 已有，缺榜单聚合与 `hotpage` 结构 |
| 2 | `PersonalStatusSearchActivity` | **v0.8 已补**（`profile_search_page.dart`） | `/ajax/profile/searchblog?uid=&page=&q=` |
| 3 | `MyFollowersActivity`（新增粉丝） | **v0.8 已补**（`new_followers_page.dart`） | `/ajax/friendships/friends?uid=&relate=fans&newFollowerCount=` |
| 4 | `StatusMyBehaviorActivity`（我的赞） | v0.8 已补「赞过的微博」页，缺行为聚合入口 | `/ajax/message/attitudes` |
| 5 | `ArticleActivity`（头条文章） | 长文只走 `status_long_text`，没有文章页版式 | `/ajax/statuses/longtext` |
| 6 | `StatusDetailActivity` 吸顶 Tab | **v0.8 已补**（转发 / 评论 / 赞 三 Tab） | 转发列表 + `likelist` |
| 7 | `StatusPublishActivity` 发送选项 | **v0.8 已补**（`menu/n.xml` 十项，灰项写明原因） | `statuses/schedule/upload`（定时）、`vote/config`（投票） |

### B. 中频 / 独立页面

`MyFriendActivity`（好友圈可经分组切换间接到达，但没有独立页）、`FreshListActivity`（新鲜事）、
`QAActivity`（问答）、`PersonalLikedStatusActivity` 已补、`StatusTopicActivity`、
`TopicStatusSearchActivity`、`CommonSearchActivity`、`CardListActivity`、
`PageDetailActivity` / `PagePopActivity`、`TextDetailActivity`、`NearByActivity`、
`QRCodeScanActivity`（扫一扫）、`MusicPlayerActivity`、`VideoDetailActivity` / `VideoTagActivity`、
`ThemeCustomActivity`（自定义主题色）、`SharePurchaseActivity`、`CalendarFeedActivity`、
`PhotoEditActivity` / `CropImageActivity`（拍完裁剪）、`story.VVSActivity`、
`weibo.InfoPageActivity` / `PermissionCheckActivity`、`GeetestActivity`（极验）、
`GuidanceActivity`（首启引导）、`Launcher1..5`（桌面快捷方式）。

### C. 系统级 / 平台能力

| 项 | 说明 |
| :--- | :--- |
| WeSync 长连接 | `rust/src/wesync/` 有编解码，但**没有接进 App**：私信、通知仍是轮询/手动刷新 |
| 推送 | APNs / FCM 均未接，原版的通知栏常驻、免打扰时段属 Android Service，Flutter 侧需另一套实现 |
| 超话签到 | `/ajax/stopic/curl` 未接 |
| 视频 | 倍速/手势已有，缺画中画、后台播放、清晰度切换（`b0/b2` 数组：超清/高清/标清/流畅/自动） |
| iOS | 工程与 `Info.plist` 已配，但**没有 macOS 无法出 IPA**，Cupertino 返回手势、灵动岛安全区未在真机验证 |

### D. 已确认**不是**缺口（原版也没有 / 描述有误）

- 主题只有 **4 套**（`arrays.xml` → `ax`: 夜间模式 / 绅士蓝 / 小草绿 / 少女粉）+ 3 种夜间
  （夜间黑 / A屏黑 / 夜间蓝）。白皮书里"19 套主题"不成立，现实现 7 个预设已覆盖全集。
- `menu/v.xml` 里 7 项（评论管理 / 编辑历史 / 编辑微博 / 置顶 / 分享范围 / 抽奖 / 删除）
  原生就是 `android:visible="false"`，只在**作者本人**打开时才置为可见 —— 现实现按此规则。
- 卡片更多菜单文案以 `res/values/strings.xml` 为准：是「复制」「屏蔽」「投诉」，
  不是"复制微博链接""屏蔽与过滤""投诉与举报"。

---

## 三、下一批建议（按性价比）

1. 详情页三 Tab（转发/评论/赞）—— 复用已有接口，纯 UI。
2. 主页内搜索微博 `/ajax/profile/searchblog` —— 一个接口一页。
3. 发送选项里能真做的：图片水印、微博尾巴（本地）、定时发送（`schedule/upload`）。
4. WeSync 接进 App，替掉私信的手动刷新。
5. 长文/文章页版式。

---

## 四、v0.8 收口轮：把「点了没反应」全部清掉

四路并行交付后做验收，问题不在页面缺，而在**交互闭环断了**。逐个查出来并修掉：

| 问题 | 数量 | 现象 | 修法 |
| :--- | :--- | :--- | :--- |
| `onMore: () {}` | 4 处（收藏页 / 通知页 / 用户主页 / 超话页） | 底栏"更多"是死按钮 | 删掉空实现，改由 `StatusCard` 内建兜底 |
| `onAvatarTap: () {}` | 3 处（收藏页 / 用户主页 / 超话页） | 点头像不跳主页 | 同上，兜底调 `openUserProfile` |
| `onLike` 未接 | 5 处 | 点赞图标不变、数字不动 | 兜底实现：乐观更新 + 失败回滚 + 报服务端原话 |
| `onLike` 接错 | 2 处（赞过页 / 搜索主页） | 调了接口但 `catch (_) {}`，成功失败都没反馈 | 删掉自写版本，交给兜底 |
| `onRepost` 未接 | 1 处（搜索结果页） | 转发按钮点了没反应 | 补跳详情页 |
| 收藏按钮 | 全站 | 调接口成功但**图标不变**，用户以为没收藏上 | 本地 `_favorited` 覆盖值 + 失败回滚 |
| 编辑历史富文本 | 1 处 | `onTapSegment: (_) {}`，@人/话题点不动 | 接 `openRichSegment` |

设计取舍：`StatusCard` 从 `ConsumerWidget` 改成 `ConsumerStatefulWidget`，把
点赞 / 收藏 / 更多 / 头像这四个"任何列表都该有"的行为做成内建兜底。
调用方仍可覆盖（feed 列表需要同步整条 item），但**漏传不再等于死按钮**。

### 「编辑微博」为什么改名「重新编辑」

原版这个功能走的是 App 私有接口。weibo.com 的 bundle 里只有
`ajax/statuses/checkCanEdit` 和 `ajax/statuses/editHistory`，真正提交编辑是
`window.open(editConfig.scheme)` —— **唤起客户端 App**，网页端没有提交入口。

也就是说我们发不出"编辑"这个请求。原来的实现是把原文填进发布器，用户会以为在改，
实际多发了一条。现改为「重新编辑」并在点击时明确提示会作为新微博发出。
`checkCanEdit` 已确认存在，但没有提交端点，接上也无意义。

### `menu/v.xml` 与原实现的剩余差异（已知，未补）

原版是**两级结构**：一级只有「分享」+「更多」，二级 14 项。现实现拍平成一层。
另有 5 项未实现，按原因分：

| 项 | 原版 visible | 未实现原因 |
| :--- | :--- | :--- |
| 置顶微博 | false | 网页 bundle 无 `setTop` 类端点，App 私有接口 |
| 设置分享范围 | false | 同上 |
| 设置抽奖 | false | 付费抽奖，需资质 |
| 评论管理 | false | 需详情页评论管理视图，成本高 |
| 新鲜事投稿 | **true** | 功能语义不明（`strings` 无对应说明），暂不猜 |

现实现额外有「保存图片」「查看原微博」，原版 menu 里没有（应另有入口），保留不影响。

