# Share 跨平台复刻（Flutter + Rust）

Share.apk (v3.9.6) 的 Android / iOS 复刻工程。UI 用 Flutter，网络 / 会话 / 缓存放在 Rust 核心里，
通过 flutter_rust_bridge v2 暴露给 Dart。

## 目录

```
share_app/            Flutter 前端
  lib/core/           模型、解析、Rust 绑定封装、会话状态
  lib/ui/             页面（登录、首页、详情、发现、发布、我的）
  lib/src/rust/       flutter_rust_bridge 生成的绑定（勿手改）
  tool/build_rust_android.sh   交叉编译 Rust → jniLibs
  tool/build_apk.sh            一键出包（编译 + 打包 + 改名 + 剔除坏包）
rust/                 Rust 核心
  src/web/            cookie / 会话 / 微博接口封装
  src/api/web_api.rs  暴露给 Flutter 的 FFI 面
  tests/live_web.rs   真实接口联调测试
attic_gemini/         上一版（仅 UI 假数据）留存，不参与编译
```

## 为什么用 Web 接口

原版走 `api.weibo.cn/2/*`，每个请求都要带 `cum` 校验参数，而 `cum` 由 `libwbutil.so` 里的
ARM 汇编（`WeiboApplication.calculateS`）计算，无法在 iOS 复用、也无法离线重放。
因此数据层改用 `weibo.com/ajax/*`：同一份微博数据，只依赖登录 Cookie，跨平台可用。
代价是原版极少数依赖私有参数的接口（如部分高级发送选项）需要单独适配。

## 构建

前置：Flutter 3.47+、Rust 1.8x、Android NDK、`cargo-ndk`、`rustup target add aarch64-linux-android x86_64-linux-android`。

```bash
# 1. 生成 FFI 绑定（改了 rust/src/api 后必跑）
cd share_app && flutter_rust_bridge_codegen generate

# 2. 编译 Rust 到安卓
cd share_app && ./tool/build_rust_android.sh

# 3. 打包（按 ABI 拆分，并自动剔除缺原生库的 v7a 包）
bash tool/build_apk.sh v0.2
```

产物：仓库根目录 `Share-rebuild-arm64-v0.2.apk` / `Share-rebuild-x86_64-v0.2.apk`。

> `armeabi-v7a` 目前没有 Rust 产物（该 target 的 rust-std 在当前镜像 404），所以只分发
> arm64-v8a / x86_64 两个包。

## 测试

```bash
# 真实接口（游客身份，无需账号）
cd rust && cargo test --test live_web -- --ignored --nocapture

# FFI 全链路（Dart -> bridge -> Rust -> 微博）
cd share_app && flutter test test/ffi_smoke_test.dart
```

## 当前状态

已完成（全部接真实接口，`flutter test` 逐项验证）：

| 模块 | 接口 |
|---|---|
| 游客会话 / WebView 登录 / 多账号切换 | `passport.weibo.com/visitor/*`、`m.weibo.cn/api/config` |
| 首页时间线（分页 + 离线缓存） | `/ajax/feed/unreadfriendstimeline` |
| 发现 / 热搜榜 | `/ajax/feed/hottimeline`、`/ajax/side/hotSearch` |
| 微博详情、全文、长文 | `/ajax/statuses/show`、`/ajax/statuses/longtext` |
| 评论、楼中楼、转发列表 | `/ajax/statuses/buildComments`、`/ajax/statuses/repostTimeline` |
| 点赞 / 收藏 / 转发 / 评论 / 发布 | `/ajax/statuses/*`、`/ajax/comments/create` |
| 搜索（微博） | `/ajax/statuses/search` |
| 用户主页（资料 + 关注） | `/ajax/profile/info`、`/ajax/friendships/*` |
| 昵称 → uid（@ 跳转） | `/ajax/side/search` |
| 通知中心四分类 | `/ajax/statuses/mentions`、`/ajax/comments/mentions`、`/ajax/message/cmt`、`/ajax/message/attitudes` |
| 未读红点 | `/ajax/message/unreadHint` |
| 私信会话 / 聊天 / 发送 | `api.weibo.com/webim/2/direct_messages/{conversation,recent_messages,new}.json` |
| 我的收藏 | `/ajax/favorites/all_fav` |
| 超话分类 / 榜单 / 搜索 | `/ajax/stopic/cates`、`/ajax/stopic/list` |
| 图片上传（发带图微博） | `picupload.weibo.com/interface/pic_upload.php` |
| 用户主页 | `/ajax/profile/info`（资料）、`/ajax/statuses/mymblog`（时间线，登录受限） |
| 分组列表（游客可取完整分组树） | `/ajax/feed/allGroups` |
| 表情包（10 类 / 348 个） | `/ajax/statuses/config` |
| 用户搜索 / `@` 联想 / 话题联想 | `/ajax/side/search` |

UI 侧另有：7 套主题（取自 APK `arrays.xml`）、图集、视频播放器、草稿箱、`#话题#` 点击进搜索、
`@昵称` 点击进主页、外链内置浏览器、关注/粉丝页、账号管理。

### v0.6 新增

| 能力 | 说明 |
|---|---|
| 保存图片 / 系统分享 / 长按复制 | 图集页与微博卡片长按出菜单：复制正文、复制链接、分享（`share_plus`）、保存到相册（`gal`）。原图开关读设置项 `save_image_original`，把 `/large/` `/bmiddle/` `/mw690/` 换成 `/original/`。不依赖任何微博接口，游客可用。 |
| 分组管理 + 表情面板 | 底部 FAB「切换分组」改为拉 `/ajax/feed/allGroups` 真实分组（前 6 个）；「分组管理」页列出 默认/我的/订阅/频道/频道推荐 五类；发布页表情面板按 `/ajax/statuses/config` 分类渲染，可连续插入。 |
| 用户搜索 + `@` 联想 | 发现页新增「找人」；发布页输入 `@` 后 280ms 防抖请求联想，选中后把片段替换成 `@昵称 `。 |
| 视频手势 + 自动播放 | 双击播放/暂停、长按 2 倍速、横滑调进度（带时间 HUD）、0.5–2.0 倍速菜单；自动播放读 `auto_play_options`（仅 Wi-Fi / 总是 / 从不），用 `connectivity_plus` 判定网络。 |
| 深链接 | `sinaweibo://detail?mblogid=`、`sinaweibo://userinfo?uid=`、`sinaweibo://browser?url=`（剥壳）、`sinaweibo://search?q=`，以及 `weibo.com/<uid>/<mblogid>`、`/u/<uid>`、`/n/<昵称>`、`m.weibo.cn/detail/<id>`。解析失败或取详情失败时退回内置浏览器。 |

### 设置页（原版 g..q.xml 的 11 个 PreferenceScreen）

`lib/core/settings_spec.dart` 按原版 XML 逐行誊写了 **11 个页面 / 119 行**（key、标题、默认值、
枚举项全同），`lib/ui/settings/pref_page.dart` 用一个渲染器统一绘制 switch / 单选 / 多选 /
SeekBar。当前真实生效 20 项：

| 分类 | 生效项 |
|---|---|
| 流量控制 | 预读模式、首页加载条数、微博图片加载质量、图片上传默认质量 |
| 阅读习惯 | 默认夜间主题、重复点 tab 刷新、私信回车发送 |
| 微博样式 | 字号、行距、头像样式、卡片风格、卡片背景、分割线、左侧留白、名字加粗/跟随主题色、名字图标、选项按钮 |
| 布局样式 | 滑动隐藏底栏、快速拖动、首页 FAB（不显示/切换分组/刷新/发微博）、隐藏热门搜索 |
| 通知设置 | 数字红点提醒类型 |
| 隐私设置 | 关键词屏蔽（本地过滤时间线、搜索、评论） |
| Share实验室 | 内置浏览器夜间注入 |

其余项照原样保存取值并如实在页脚标注「依赖 Android 系统服务 / 本版本仅保存」，不假装生效。

### 已知限制（不伪造）

- **私信**：WebIM 走 Cookie 认证（官方 `pcweibochat` 包里没有任何 `access_token`），但
  游客身份会被服务端拒绝（`error_code 21301`）。页面会把服务端原话显示出来，并提供
  「在网页版私信中打开」作为兜底。真机登录后可验证原生通道。
- **用户微博列表**：微博已对未登录请求关闭 `/ajax/statuses/mymblog`（返回
  「登录状态已失效，请重新登录」），所以未登录时主页只显示资料，时间线区域照实显示该提示。
- **armeabi-v7a**：该 rust target 在当前镜像 404，`tool/build_apk.sh` 会删掉缺 `.so` 的
  v7a 包，只发布 arm64-v8a / x86_64。
- **超话签到 / 原生超话内容流**：`/ajax/profile/topicContent`、`/ajax/stopic/curl` 均要求登录，
  未找到签到接口；详情页改为渲染真实的 `#超话名#` 微博流。
- **关注 / 粉丝列表**：`/ajax/profile/followContent` 对访客返回 `{}`（各种参数组合都试过），
  改为用已持有的会话直接打开 `weibo.com/<uid>/follow|fans`，列表与关注按钮都保持正确。
- **iOS 深链接**：`sinaweibo://` 已写入 `Info.plist` 的 `CFBundleURLTypes`；`http(s)://weibo.com/*`
  在 iOS 上只能靠 Universal Links，而 `apple-app-site-association` 由微博官方托管、不对外开放，
  因此 iOS 端只支持自定义 scheme。另外当前工程用的是 scene-based 模板，
  `SceneDelegate` 的 `openURLContexts` 转发需要在 macOS 上真机验证一次。
- **iOS**：需要 macOS 侧 `rustup target add aarch64-apple-ios` + xcframework + Xcode Run Script，
  本机无法产出。
- 签名使用 debug keystore，仅用于侧载；上架需自行替换。
