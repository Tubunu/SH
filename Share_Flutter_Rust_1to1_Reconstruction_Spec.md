# Share 第三方微博客户端 1:1 Flutter + Rust 跨平台（Android / iOS）完整重构规范说明书

> **基线版本**：`Share.apk` v3.9.6（Build 925，包名 `com.hengye.share`，SHA-256: `117039ff56d6130d7e75ba7e43411a470358124f99001476f6cd3a1940f07f6c`）  
> **重构目标**：使用 **Rust (`share_core`) + Flutter (`share_app`)** 在 **Android 与 iOS** 双端 1:1 完整复刻原版 Share 的全部界面布局、交互细节、主题系统、设置项（11 个设置页面全量偏好键）、离线表情包、多账号 SQLite 数据库与实时/离线功能。  
> **审计方法**：基于 `rea` MCP、`llvm-objdump` 反汇编（`libwbutil.so`、`libSecShare.so`）、DEX/SMALI 全量反编译源码、`AndroidManifest.xml` 与 `res/` 资源解析，并经 2026 年真实联网协议验证。

---

## 第 1 章 系统总体架构与关键修复结论

### 1.1 双端跨平台架构

```
+-------------------------------------------------------------------+
|                   Flutter UI Layer (share_app)                    |
|  21+1 套主题引擎 | 状态管理 (Riverpod) | 原生桥 (Cookies/Gallery/Media) |
+-------------------------------------------------------------------+
                                 | flutter_rust_bridge (=2.13.0)
                                 v
+-------------------------------------------------------------------+
|                   Rust Core Engine (share_core)                   |
|  crypto/ (libwbutil AES/DES/SHA512 signing + libSecShare RSA)     |
|  auth/   (游客 / 密码+RSA+SMS / 二维码 / Cookie 多账号热切换)       |
|  net/    (双协议引擎: api.weibo.cn/2/* + weibo.com/ajax/*)        |
|  storage/(SQLite GreenDAO 9 表: 账号/草稿/历史/分组/关注/黑名单/缓存)|
|  wesync/ (长连接 12 字节帧协议 + 入口网关调度)                     |
+-------------------------------------------------------------------+
```

### 1.2 双协议网络引擎设计（根治旧 Demo 无法使用的原因）

经对原版 Native 二进制库（`libwbutil.so` arm64-v8a / `libSecShare.so` arm64-v8a）反汇编与 2026 年实网验证：
1. **官方移动端接口 `https://api.weibo.cn/2/*` 当前依然可用**：此前旧版重构之所以请求报错 `errno: -105 (客户端身份校验失败)`，是因为其 `sign.rs` 错误使用了旧版 MD5 `calculateS`，未复刻 `libwbutil.so` 中的 `newCalculateS`（SHA-512）与 `_getparam` (`cum`) 及 `OP.java` 游客初始化 `/2/guest/login`。
2. **本规范采用双协议联合策略**：
   - **主协议 (`api.weibo.cn/2/*`)**：当账号具备移动端 `gsid`（游客 `/2/guest/login`、密码+RSA `/2/account/login`、短信登录、二维码确认或从 `/2/account/getoauth` 换取）时，完整签名（`s`、`cum`、`aid`、`from`、`c`、`wm`、`oldwm`、`v_p`、`wb_version`、`ua`、`X-Validator`）直连 `https://api.weibo.cn/2/*`，覆盖全部原版高级能力（热榜、超话签到/帖子流、长文、问答、分组/成员管理、编辑资料、个人主页多维度、黑名单同步、评论管理、私信等）。
   - **Web 兼容协议 (`weibo.com/ajax/*` + `api.weibo.com/webim/*`)**：当用户通过 WebView Cookie 登录（仅持有 `SUB`/`SUBP`）时，自动保留 `weibo.com/ajax/*` 全套能力，并与 Native 平台桥接直接读取完整 `HttpOnly` Cookie（彻底解决 `webview_flutter_android` 截断含 `=` 的 `SUB` 值导致的登录失效问题）。

---

## 第 2 章 Native 密码学、签名与设备指纹 (`libwbutil.so` / `libSecShare.so` / `OP.java`)

### 2.1 `newCalculateS` 参数签名算法 (`libwbutil.so` @ `0x5850` / `0x9010`)

- **隐藏密钥**：反汇编 `.rodata`（`0x20958..0x20ac0`）及 `g_pStandardSigs` (`"c2d319c4c5a5c7d53e62b5a7704e6c1b"`) 解密（`DES-ECB` 密钥 `"704e6c1b"` + PKCS#5 `\x08*8`）得固定 SALT：
  - `g_pin = "5l0WXnhiY4pJ794KIJ7Rw5F45VXg9sjo"`
  - `g_from = "10B6395010"`（来源 `NB.O00000o0`）
- **签名步骤**：输入 `uid`（未登录或无 uid 传空串 `""`）：
  1. `s1 = lowercase_hex(SHA512(g_pin + uid + g_from))`（128 位十六进制字符）
  2. `s2 = lowercase_hex(SHA512(g_from))`（128 位十六进制字符）
  3. 取索引序列：令 `pos = 0`，循环 8 次：
     - `pos = pos + hex_digit_to_int(s2[pos])`
     - 取 `s1[pos]`
  4. 拼接得到的 8 个字符即为 `s` 参数（当 `uid == ""` 时，固定产出 `"2bfa3d98"`）。

### 2.2 `_getparam` (`cum`) URL 后缀校验算法 (`libwbutil.so`)

对于请求路径 `suffix`（如 `"/2/statuses/unread_hot_timeline"`）：
1. 计算 `d1 = SHA256(suffix_bytes)`（32 字节原始摘要）。
2. 计算偏移 `start = 8 - (d1[0] & 7)`（范围 `1..=8`）。
3. 从 `suffix_bytes` 截取 `key = suffix[start : min(len, start + 8)]`；若长度 `< 8`，用字节 `8 - len(key)` 在末尾补齐至 8 字节（PKCS 风格长度字节填充）。
4. 构造 8 字节明文 `cpdata = suffix[-4:] || suffix[:4]`（若不足按可用字节截取与对齐）。
5. 使用 **DES-ECB**（忽略弱密钥/奇偶校验位）用 `key` 加密 `cpdata` 得 8 字节 `des_out`。
6. 计算 `d2 = UPPERCASE_HEX(SHA256(d1 || des_out))`。
7. 返回子串 `d2[start : start + 8]` 作为查询/表单参数 `cum`。

### 2.3 RSA-1024 密码加密与设备 AID 注册 (`libSecShare.so` & `OP.java`)

- **Share / Weibo 账号密码公钥 (`SAUtils_secP`, `libSecShare.so` `.rodata` `0x1cd2`+`0x1d0f`)**：
  ```
  MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQC46y69c1rmEk6btBLCPgxJkCxdDcAH9k7kBLffgG1KWqUErjdv+aMkEZmBaprEW846YEwBn60gyBih3KU518fL3F+sv2b6xEeOxgjWO+NPgSWmT3q1up95HmmLHlgVwqTKqRUHd8+Tr43D5h+J8T69etX0YNdT5ACvm+Ar0HdarwIDAQAB
  ```
  采用 `RSA/ECB/PKCS1Padding` 按 117 字节分块加密密码原文，输出无换行标准 Base64。
- **设备指纹注册 (`/2/guest/login` in `OP.java`)**：
  - 使用独立 Aid 公钥（`WEIBO_AID_PUBKEY_B64`）：
    ```
    MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDHHM0Fi2Z6+QYKXqFUX2Cy6AaWq3cPi+GSn9oeAwQbPZR75JB7Netm0HtBVVbtPhzT7UO2p1JhFUKWqrqoYuAjkgMVPmA0sFrQohns5EE44Y86XQopD4ZO+dE5KjUZFE6vrPO3rWW3np2BqlgKpjnYZri6TJApmIpGcQg9/G/3zQIDAQAB
    ```
  - 构造 JSON 设备信息对象经 RSA 分块加密后加 `"01"` 前缀拼接成 `mfp` 参数。
  - `checktoken = MD5("/" + did + "/obiew")`。
  - Share 伪装客户端签名包 (`C5904oo0ooooo.java`)：`appkey="7501641714"`, `packagename="com.sina.weibo"`, `key_hash="18da2bf10352443a00a5e046d9fca6bd"`（同时内嵌 `assets/libshare.so` 665B 新浪证书与 `com.weico.international` / `assets/libbb.so` 541B Weico 证书）。
  - 返回 `{ aid, gsid, uid, cookie }`，实测于 2026 年成功下发有效游客凭证并认证 `/2/statuses/unread_hot_timeline`、`/2/profile` 等接口。

### 2.4 公共参数、请求头及异常拦截器 (`UB.java` / `PB.java` / `C3185mA.java` / `C4426oA.java`)

- **公共参数**：
  - `lang=zh_CN`, `networktype=wifi|4g|...`, `c=android`, `from=10B6395010`, `wm=3333_2001`, `oldwm=<按厂商映射>`, `ua=<Manufacturer>-<Model>__weibo__11.6.3__android__android<OS>`, `v_p=89`, `android_id=<16位hex>`, `wb_version=5005`, `skin=default`, `v_f=2`, `aid=<aid>`, `gsid=<gsid>`, `s=<newCalculateS(uid)>`, `cum=<_getparam(path)>`。
  - `oldwm` 厂商映射：`ONEPLUS->14038_0004`, `MEIZU->9848_0009`, `OPPO->9847_0002`, `VIVO->9856_0004`, `SMARTISAN->14010_0013`, `ZUK->20003_0002`, `SONY->9982_90002`, `XIAOMI->20005_0002`, 其余 `3333_1001`。
- **HTTP Headers & 过滤 (`C3185mA.java`)**：
  - `User-Agent`: `<Model>_<OS>_weibo_11.6.3_android`，并将 `<=31` 或 `>=127` 非 ASCII 字符替换为 `'?'`。
  - 自动携带：`X-Sessionid`, `X-Log-Uid`, 以及若服务器下发过响应头 `X-Validator`，客户端缓存并于后续所有请求原样带上 `X-Validator`。
- **风控与异常自动恢复 (`C4426oA.java`)**：
  - 白名单跳过路径：`/2/account/login`, `/2/remind/unread_count`, `/2/remind/unread_count.json`, `/2/direct_messages/public/messages.json`, `/2/register/by_phone`, `/login_sendcode`, `/2/register/sendcode`, `/2/captcha/get`, `/bind_fb`。
  - 当返回 JSON 中 `errno == -1005` 或 `20031` 时触发图形/设备验证码校验并重放原请求；`errno == -200` 自动重试；`errno == 20062` 按 `exception_key` 映射业务异常体。

---

## 第 3 章 身份认证、安全校验与多账号体系

原版支持 **5 种完整认证通道**：
1. **游客冷启动 (`OP.java`)**：首次启动无账号自动申请 `/2/guest/login` 获取 `aid`/`gsid`，可免登录浏览热门微博、超话分类与公开主页。
2. **账号密码登录 (`WeiboWebAuthorizeActivity` + `/2/account/login`)**：
   - 支持用户名/手机号/邮箱 + RSA 加密密码（`SAUtils.securityPsd`），`getcookie=1`。
   - **登录风控安全校验 (`WeiboSafetyVerifyActivity` / `layout/ay.xml`)**：解析服务端返回的 `phone` 与 `phone_list`，发送短信验证码后跳转验证页。
   - **短信验证码二次校验 (`WeiboSmsVerifyActivity` / `layout/b2.xml`)**：接收 `phone`, `password`, `smsLogin`，提交 `phone` + `smscode` / `smsverifycode` + `getcookie=1`，亦支持独立短信免密登录（`account/login_sendcode` + `account/login_smsverify`）。
   - **第三方授权入口 (`ThirdPartyLoginActivity`)**：接收 `appKey`, `uid`, `password`, `cookie` 完成快速或第三方 SSO 登入。
3. **WebView 网页登录 (`WeiboWebAuthorizeActivity` / `layout/bm.xml` + `menu/a.xml`「登录疑问」)**：
   - 加载登录页并允许切换桌面/移动端页（跳转客服帮助 `https://kefu.weibo.com/?entry=client&sinainternalbrowser=topnav&showmenu=1&share_menu=1&lang=zh_CN`）。
   - **关键修复**：Android 使用原生 `android.webkit.CookieManager.getInstance().getCookie(...)`、iOS 使用 `WKWebsiteDataStore.default().httpCookieStore.getAllCookies` 通过平台 MethodChannel `com.hengye.share/cookies` 提取全部 Cookie（含 `HttpOnly` 与包含等号 `=` 的完整 `SUB=`、`SUBP=`、`XSRF-TOKEN=`、`SSOLoginState=`），并同步注入原生网络客户端。
4. **扫码登录 (`QRCodeScanActivity` / `layout/az.xml` + `menu/q.xml`「相册」)**：
   - 扫描相机或从相册解码二维码；若匹配 `https://passport.weibo.cn/signin/qrcode/scan*`，调用 `/2/signin/qrcode/confirm` 完成 PC/网页端确认登录，或识别用户主页二维码（`weibo.cn/qr/`）跳转个人页。
5. **Cookie 导入与多账号管理 (`AccountManageActivity` / `layout/a4.xml`)**：
   - `USER` 表保存多个账号（含 `UID`, `TOKEN`, `PARENT_TYPE (0=OAuth,1=Web,2=3P)`, `GSID`, `COOKIE`, `NAME`, `AVATAR`, `COVER`, `ACCOUNT`, AES-256 加密密码）。
   - 支持一键切换账号并即时重置活跃会话与主页刷新；底部固定栏提供「退出当前账号」（`R.string.qk`）。

---

## 第 4 章 全量网络接口与 WeSync 实时长连接协议

### 4.1 `api.weibo.cn/2/*` 核心接口 (`InterfaceC2935jA`)

| 功能域 | 接口路径与方法 | 关键参数 / 用途说明 |
| :--- | :--- | :--- |
| **认证 / 安全 / 码** | `POST account/login`<br>`POST account/login_sendcode`<br>`POST account/login_smsverify`<br>`GET account/getoauth`<br>`POST captcha/get`<br>`GET device/get` / `device/check`<br>`POST https://passport.weibo.cn/signin/qrcode/confirm` | 账号登录与 Cookie 获取、短信下发/验证、OAuth Token 换取、图文验证码、设备指纹绑定、扫码确认 |
| **时间线** | `GET statuses/unread_friends_timeline`<br>`GET statuses/friends/timeline`<br>`GET groups/timeline`<br>`GET statuses/user_timeline`<br>`GET statuses/unread_hot_timeline`<br>`POST statuses/page_timeline`<br>`GET statuses/video_mixtimeline`<br>`GET profile/statuses`<br>`GET https://top.weibo.cn/weibo/user_timeline` | 关注未读/全量时间线、分组时间线（`gid`）、用户时间线、热门未读流（`group_id`）、CardList 微博流、混合视频流、用户相册/主页流 |
| **微博交互与详情** | `GET statuses/show` / `!/statuses/show_batch`<br>`GET statuses/extend`<br>`GET statuses/repost_timeline` / `hot_repost_timeline`<br>`POST statuses/destroy`<br>`POST statuses/modify_visible`<br>`POST users/set_top_status` / `cancel_top_status`<br>`POST statuses/filter_create` / `!/statuses/filter_center/status/update` | 单条/批量详情、微博长文/扩展信息、转发与热门转发列表、删除、调整可见范围（公开/好友圈/仅自己）、置顶与取消置顶、屏蔽某条/作者 |
| **发博与媒体** | `POST statuses/send`<br>`POST statuses/repost`<br>`POST statuses/modify_weibo`<br>`POST https://upload.api.weibo.com/fileplatform/init.json`<br>`POST https://upload.api.weibo.com/fileplatform/upload.json`<br>`POST http://upload.api.weibo.com/2/mss/upload.json`<br>`GET place/nearby_pois` | 发布（支持图文/POI/定时/点评/投票）、转发、二次编辑、分片大文件与图片/视频初始化与上传（`startloc` 分块）、周边 POI |
| **评论与点赞** | `GET comments/show` / `comments/hot_timeline`<br>`GET comments/build_comments`<br>`GET comments/approval_list` / `approval_update` / `permission_update`<br>`POST comments/create` / `comments/reply`<br>`GET comments/destroy` / `comments/block_and_delete`<br>`GET comments/mentions` / `to_me` / `by_me`<br>`GET like/show` / `like/set_like` / `like/cancel_like` / `like/update` / `like/destroy` / `like/to_me` | 热门/全部评论、楼中楼构建（`flow=0`热度 / `flow=1`时间）、评论精选审核与权限、评论配图（`media`）/弹幕开关、拉黑并删评、消息通知(@评论/收评/发评/收赞/发赞) |
| **用户与关系链** | `GET profile` / `profile/safety`<br>`GET users/relation` / `users/show_batch`<br>`POST users/update` / `POST account/avatar_upload`<br>`POST profile/set/pure/covers`<br>`POST friendships/create` / `destroy`<br>`GET friendships/friends` / `dynamic`<br>`GET friendships/followers_destroy`<br>`POST friendships/remark_update`<br>`POST blocks/create` / `blocks/destroy` | 个人资料卡（含勋章/封面/认证）、关系检测、批量用户、修改昵称签名性别生日、换头像与纯净主页封面、关注/取关/移除粉丝/修改备注/拉黑与取消拉黑 |
| **分组管理** | `GET groups` / `groups/allgroups` / `groups/update_lists`<br>`GET groups/allmembers`<br>`POST groups/create` / `groups/update` / `!/groups/destroy`<br>`POST groups/order`<br>`POST groups/members_add` / `members_destroy` | 分组列表、全部分组与成员、创建/重命名/删除分组、拖拽排序（`groups/order`）、成员批量增删 |
| **收藏、卡片、超话与搜索** | `GET favorites` / `POST favorites/create` / `favorites/destroy`<br>`GET cardlist` / `page` / `infopage`<br>`GET page/get_fragment` / `get_toolbar` / `panel` / `get_search_suggest`<br>`GET container` / `container/get_item`<br>`GET /2/page/button`<br>`GET friendships_pages/create` / `destroy`<br>`GET suggestions/interest_page`<br>`GET statuses/article_show` / `article/link_extend`<br>`GET question/show` / `question/extend` / `question/watch` | 我的收藏、Universal CardList（热门搜索/推荐页/微博搜索/兴趣页/新鲜事）、超话页面与签到(`/2/page/button`)、超话关注/取关、头条文章详情与扩展、微博问答详情与围观 |
| **私信、群聊与通知角标** | `GET direct_messages/user_list`<br>`GET direct_messages/conversation`<br>`POST direct_messages/create`<br>`GET direct_messages/destroy_batch` / `public/messages`<br>`GET !/direct_messages/recent_contacts`<br>`POST direct_messages/block_batch` / `unblock_batch`<br>`GET remind/unread_count` / `remind/set_count`<br>`GET messages/menu_show` / `POST messages/event_create`<br>`GET groupchat/query` / `query_multi` / `query_join_groups`<br>`POST groupchat/create` / `update` / `join` / `apply_join` / `kick` / `quit` / `!/groupchat/destroy`<br>`POST https://api.weibo.com/webim/2/direct_messages/new.json`<br>`POST https://api.weibo.com/webim/groupchat/send_message.json`<br>`POST https://api.weibo.com/groupchat/recall.json` | 1v1 私信（含 WebIM 图片/语音 `msget` / 撤回）、屏蔽/取消屏蔽订阅私信、未读计数读取与清零、公共/群聊会话查询/建群/改名/踢人/退群/解散 |
| **多媒体与工具** | `GET !/multimedia/playback/batch_get` / `multimedia/multidiscovery`<br>`GET video/vplus` / `video/pay_playlist_videos`<br>`GET object/get_songlist`<br>`GET expression/get` / `client/publisher_list`<br>`GET short_url/expand`<br>`GET stories/activity_detail` / `report/spam` | 视频播放地址批量解析（1080P/720P/480P）与相关专辑推荐、音乐歌单、云端表情包与尾巴列表、短链还原、`t.cn` 反劫持与举报 |

### 4.2 OpenAPI (`InterfaceC3018kA`) & Web Ajax (`weibo.com/ajax/*`) 兼容层

- `.json` OpenAPI（当持有 OAuth Token）：`statuses/update.json`, `statuses/upload.json`, `statuses/repost.json`, `statuses/repost_timeline.json`, `comments/show.json`, `comments/mentions.json`, `comments/to_me.json`, `comments/by_me.json`, `remind/unread_count.json`, `direct_messages/user_list.json`, `direct_messages/new.json`, `direct_messages/recall.json`, `direct_messages/public/messages.json`。
- Web Cookie 兼容路由（已存在于 `rust/src/web/api.rs`）：`/ajax/feed/friendstimeline`, `/ajax/feed/groupstimeline`, `/ajax/statuses/hot`, `/ajax/statuses/show`, `/ajax/statuses/longtext`, `/ajax/statuses/buildComments`, `/ajax/statuses/repostTimeline`, `/ajax/statuses/repost`, `/ajax/comments/create`, `/ajax/statuses/update`, `/ajax/statuses/upload`, `/ajax/statuses/destroy`, `/ajax/statuses/setLike` / `cancelLike`, `/ajax/statuses/createFavorites` / `destroyFavorites`, `/ajax/profile/info`, `/ajax/profile/mymblog`, `/ajax/profile/getImageWall`, `/ajax/favorites/all_fav`, `/ajax/feed/allGroups`, `/ajax/config/emoticon`, `/ajax/statuses/hotBand`, `/ajax/statuses/search`, `/ajax/message/*`, WebIM `api.weibo.com/webim/*`。

### 4.3 WeSync 二进制长连接协议 (`wesync/`)

- **隧道与入口网关**：
  - 入口调度：`http://dp.im.weibo.cn/entrance`, `https://dp2.im.weibo.cn/entrance`
  - 隧道节点：`http://api.im.weibo.cn/tunnel`, `http://live.im.weibo.cn/tunnel`, `http://ps.im.weibo.cn/tunnel`, `https://kylin.im.weibo.cn/tunnel`
  - 推送注册：`http://api.weibo.cn/2/push/register`, `http://api.weibo.cn/2/push/switch_user_v3`
- **12 字节大端帧格式**：
  - `Magic (2B)`: `[0x77, 0x62]` (`"wb"`)
  - `Cmd (2B u16 BE)`: `11=Handshake`, `13=Auth`, `15=LoginBindUid`, `17=Heartbeat`, `19=ServerPush`, `20=Disconnect`, `35=DynamicHeartbeat`
  - `Seq (4B u32 BE)` + `BodyLen (4B u32 BE)` + `Payload (N bytes)`

---

## 第 5 章 本地持久化 SQLite 9 大核心表 (GreenDAO 3 1:1 复刻)

与 `Share.apk` 中的 9 张 GreenDAO 表及 `rust/src/storage/schema.sql` 严格一一对应：
1. **`USER`**：`_id PK AI, UID NOT NULL UNIQUE, TOKEN NOT NULL, PARENT_TYPE NOT NULL, GSID, S_VALUE, I_VALUE, PARENT_JSON, REFRESH_TOKEN, EXPIRES_IN, NAME, AVATAR, GENDER, SIGN, COVER, ACCOUNT, PASSWORD, AD_TOKEN, COOKIE, EXTRA`；索引 `IDX_USER_UID`。
2. **`STATUS_DRAFTS`**：`_id PK AI, CONTENT NOT NULL, DATE NOT NULL, URLS, UID NOT NULL, TARGET_STATUS_JSON, TARGET_STATUS_ID, TARGET_COMMENT_ID, TARGET_COMMENT_USER_NAME, TARGET_COMMENT_CONTENT, ASSIGN_GROUP_ID_STR, ASSIGN_GROUP_TYPE, ADDRESS, PUBLISH_TIMING, IS_COMMENT_ORIGIN, STATUS NOT NULL DEFAULT 0, IS_MENTION, STATE, EXTRA, TYPE, PARENT_TYPE`；索引 `IDX_STATUS_DRAFTS_UID`。
3. **`STATUS_HISTORY`**：`_id PK AI, STATUS_ID NOT NULL, USERNAME, TOTAL_TEXT, UID NOT NULL, JSON NOT NULL, CREATE_AT NOT NULL`；唯一索引 `(UID, STATUS_ID)`，时间索引 `(UID, CREATE_AT DESC)`。
4. **`GROUP_LIST`**：`_id PK AI, INSERT_NUMBER NOT NULL, UID NOT NULL, GID NOT NULL, TITLE NOT NULL, NAME, DESCRIPTION, COUNT, TYPE, VISIBLE DEFAULT 1, REMIND DEFAULT 0`；索引 `(UID, INSERT_NUMBER)`。
5. **`GROUP_MEMBER`**：`_id PK AI, UID NOT NULL, TID NOT NULL, GID NOT NULL, NAME, GENDER, DESCRIPTION, AVATAR, VERIFIED, VERIFIED_TYPE, FOLLOWING, FOLLOW_ME, IS_GROUP_MEMBER DEFAULT 1`；索引 `(UID, GID)`。
6. **`FOLLOWER`**：`_id PK AI, UID NOT NULL, TID NOT NULL, NAME NOT NULL, PINYIN_NAME, GENDER, DESCRIPTION, AVATAR, VERIFIED, VERIFIED_TYPE, FOLLOWING, FOLLOW_ME`；唯一索引 `(UID, TID)`，索引 `UID`, `(UID, NAME)`, `(UID, PINYIN_NAME)`，用于 `@` 离线拼音首字母及全拼检索。
7. **`BLACK_LIST`**：`_id PK AI, KEY NOT NULL, UID NOT NULL, INFO, TYPE NOT NULL (0=用户/1=关键词/2=微博尾巴), STATE NOT NULL DEFAULT 1, BLACK_TYPE NOT NULL (1=隐藏/2=折叠)`；索引 `(UID, TYPE)`。
8. **`USER_HISTORY`**：`_id PK AI, TARGET_UID NOT NULL, TARGET_USER_NAME NOT NULL, TARGET_USER_AVATAR, UID NOT NULL, JSON, VISIT_COUNT NOT NULL DEFAULT 1, CREATE_AT NOT NULL`；唯一索引 `(TARGET_UID, UID)`。
9. **`SHARE_JSON`**：`MODEL TEXT PRIMARY KEY NOT NULL, JSON TEXT NOT NULL`（用于首页时间线首屏缓存 `home_timeline_cache_<uid>`、活跃账号 `sys_active_account_uid`、本地尾巴 `publish_source_<uid>` 等）。

---

## 第 6 章 清单组件全表 (`AndroidManifest.xml`) 与跨端映射

原版 `AndroidManifest.xml` 共声明：**29 项权限**、**97 项 Activity / Alias**（其中 **79 个 `com.hengye.share.*` 具体 Activity** + **5 个桌面图标 Alias `Launcher`..`Launcher5`** + **13 个第三方 SDK Activity**）、**15 个 Service**、**11 个 Receiver**、**6 个 Provider**、**4 个应用快捷方式 (`xml/r.xml`)**。

### 6.1 79 个具体业务 Activity 与 5 个 Launcher Alias

| 模块 | 原版 Activity / Alias | Flutter 目标路由 / 组件 |
| :--- | :--- | :--- |
| **启动 / 桌面图标** | `GuidanceActivity`, `Launcher`, `Launcher2`, `Launcher3`, `Launcher4`, `Launcher5` | 启动引导门控 `BootstrapGate` + 应用图标切换服务（Android 动态切换 `Launcher*` component；iOS 使用 alternateAppIcon 或提示） |
| **主壳与核心流** | `StatusActivity` (`singleTask`), `StatusFavoriteActivity`, `StatusTopicActivity` | `MainShell` + `FeedPage` (分组/关注/抽屉/底栏) + `FavoritesPage` + `TopicFeedPage` |
| **SSO 与账号** | `ThirdPartyLoginActivity`, `WeiboVerifiedCodeActivity`, `WeiboWebAuthorizeActivity`, `WeiboSafetyVerifyActivity`, `WeiboSmsVerifyActivity`, `AccountManageActivity` | `LoginPage`（全模式 Tab/Sheet：WebView / 密码 / 短信 / Cookie）+ `SafetyVerifySheet` + `SmsVerifyPage` + `AccountsPage` |
| **微博正文与交互** | `StatusDetailActivity`, `StatusDetail2Activity`, `StatusCommentFloorActivity`, `TextDetailActivity` | `StatusDetailPage`（支持 `status_detail_tab_scroll` 双布局切换）+ `CommentFloorPage` + `TextBoomDialog`（大爆炸分词页） |
| **发博与草稿** | `StatusPublishActivity`, `StatusDraftActivity` (`singleTop`), `AtUserActivity` | `ComposePage`（6 种发布类型）+ `DraftsPage` + `AtUserPickerPage`（本地 `FOLLOWER` 拼音筛选 + 在线联想） |
| **个人与关系链** | `PersonalHomepageActivity`, `PersonalStatusSearchActivity`, `PersonalLikedStatusActivity`, `UserSearchActivity`, `MyFriendActivity`, `EditProfileActivity`, `GroupManageActivity` | `UserPage`（视差顶栏 + `关于`/`微博`/`相册`+动态 Tab）+ `ProfileSearchPage` + `LikedPage` + `UserSearchPage` + `MyFriendPage` + `EditProfilePage` + `GroupManagePage` |
| **发现与热榜** | `HotStatusActivity`, `HotPageActivity`, `HotSearchActivity`, `SearchActivity`, `TopicHomePageActivity`, `MyTopicActivity`, `TopicStatusSearchActivity`, `VideoTagActivity`, `FreshListActivity`, `NearByActivity` (`singleTask`) | `DiscoverPage` + `HotStatusPage` + `HotTopicPage` + `HotSearchPage` + `SearchPage` + `TopicHomePage` + `MyTopicPage` + `TopicStatusSearchPage` + `VideoTagPage` + `FreshListPage` + `NearByPage` |
| **通用 CardList / 资讯** | `CardListActivity`, `FragmentPageActivity`, `BottomTabsActivity`, `PageDetailActivity`, `PagePopActivity`, `InfoPageActivity`, `CalendarFeedActivity` | `CardListPage` + `BottomTabsPage` + `InfoPage` + `CalendarFeedPage` |
| **文章与问答** | `ArticleActivity`, `QAActivity` | `ArticlePage` + `QaPage` |
| **消息与私信** | `StatusNotifyActivity` (`singleTop`), `MyFollowersActivity` (`singleTop`), `StatusMyBehaviorActivity`, `DirectMessageUsersActivity`, `DirectMessageChatActivity` | `MessagePage` + `StatusNotifyPage` (4 Tab) + `NewFollowersPage` + `MyBehaviorPage` (2 Tab) + `DmListPage` + `DmChatPage` |
| **图片、视频与音频** | `GalleryActivity`, `PhotoEditActivity`, `CropImageActivity`, `MediaDispatchActivity`, `MediaPlayerActivity`, `VideoDetailActivity`, `MusicPlayerActivity`, `VVSActivity` | `GalleryPage`（手势拖拽/双击缩放/原图/编辑裁剪/保存）+ `PhotoEditPage` + `VideoDetailPage`（清晰度/专辑/弹幕/PIP 悬浮窗）+ `MediaPlayerPage` + `MusicPlayerPage` + `StoryPage` |
| **主题与设置** | `ThemeListActivity`, `ThemeCustomActivity`, `SettingActivity`, `SettingChildActivity`, `SettingAboutActivity`, `SharePurchaseActivity`, `CommonSearchActivity` | `ThemeListPage` + `ThemeCustomPage` + `SettingsPage` + `PrefChildPage` (`i..q`) + `AboutPage` + `PurchasePage` + `BlacklistManagePage` (`C6634oooooooO`) |
| **路由、浏览器与工具** | `QRCodeScanActivity`, `HttpDispatchActivity`, `TransparentHttpDispatchActivity`, `SchemeDispatchActivity`, `ComposerDispatchActivity`, `WebViewActivity`, `WebViewWeiboActivity`, `TransparentWebViewActivity`, `OpenProductAppActivity`, `PermissionCheckActivity`, `GeetestActivity`, `FragmentActivity`, `FragmentFullScreenActivity`, `FragmentTransparentActivity`, `FullScreenThemeActivity`, `SystemFragmentActivity` | `QrScanPage` + `DeepLinkDispatcher` + `InAppWebPage`（含反劫持与夜间注入）+ 动态容器包装器 |

- **后台服务与快捷方式**：`SharePersistentService`、`StatusPublishService`（图文/转发/评论后台队列与失败重试通知）、`ImageSaveService`（相册保存/高清视频下载通知）、`MediaPlayerService`、`MusicPlayerService`、`PublishTimingStatusBroadcastReceiver`（定时发博闹钟）；以及 4 个桌面 Shortcut：`QRCodeScanActivity`、`StatusPublishActivity`、`StatusActivity(action=hot)`、`SearchActivity`。

---

## 第 7 章 21+1 套主题系统、视觉 Token 与自定义调色器 (`C5361oOoOooO` / `C0465Kk` / `C6962sk`)

### 7.1 主题架构与开关规则 (`C5361oOoOooO.java`)

- 根偏好键：`theme_app`（默认 `"elegant_purple"`，即「淡雅紫」）。
- 列表展示顺位共 **21 行**（`C0465Kk.java`）：
  1. `transparent`（「透明」）
  2. `custom`（「自定义」）
  3. `elegant_purple`（「淡雅紫」，预览圆色 `#666bb3`）
  4. `green`（「小草绿」，`#50bba7`）
  5. `night_blue`（「夜间蓝」，bg `#ff314047` + accent `#208fb9`，标记 `night=true`）
  6. `night`（「夜间黑」，`#ff212121`，`night=true`）
  7. `white`（「今夜白」，bg `#ffffffff` + accent `#15c6b5`，`light=true`）
  8. `light_blue`（「天空蓝」，`#ff638ccc`）
  9. `pink`（「少女粉」，`#fffb7299`）
  10. `grey`（「低调灰」，`#ff607d8b`）
  11. `dark_red`（「暗影红」，`#ffbe3144`）
  12. `blue`（「知乎蓝」，`#ff2196f3`）
  13. `teal`（「水鸭青」，`#ff009688`）
  14. `red`（「姨妈红」，`#ffdb4437`）
  15. `orange`（「伊藤橙」，`#ffff9800`）
  16. `deep_blue`（「绅士蓝」，`#3f51b5`）
  17. `purple`（「基佬紫」，`#ff673ab7`）
  18. `brown`（「古铜棕」，`#9c6d5c`）
  19. `black`（「嘿嘿嘿」，`#ff212121`）
  20. `amoled`（「A屏黑」，`#ff212121`，`night=true`）
  21. `white_blue`（「微博蓝」，bg `#ffffffff` + accent `#5f88ba`，`light=true`）
  - 另内置夜间扩展样式 `night_green_black` (`ShareAppTheme_GreenBlack`)。
- **底部 3 个扩展控制项 (`C0465Kk.java`)**：
  1. `普通主题强调色跟随主题` (`accent_color_theme`，Switch，默认 `false`：开启后非黑/白/夜间主题下 `accentColor = themeColor`，且 `tinged`/`usernameColor` 跟随)
  2. `普通主题标题栏颜色跟随主题` (`tool_bar_color_theme`，Switch，默认 `false`：开启后顶栏与底栏着色使用 `themeColor`，否则普通日间主题默认白底黑字 `#FFFFFF` + `#525252`！）
  3. `夜间主题详细设置`（跳转 `PrivacyFragment` `xml/n` 顶部「默认夜间主题 / 跟随系统 / 自动切换时间 / 图片适配夜间模式」）

### 7.2 全部主题精确 `#AARRGGBB` 颜色 Token 表 (`styles.xml`)

| 主题 Key (`ShareAppTheme_*`) | `theme_color` (主色) | `theme_dark_color` (深主色) | `theme_accent_color` (强调色) | `theme_background_color` (窗底) | `theme_main_background_color` (容器底) | `theme_status_background_color` (卡片底) | `theme_status_retweeted_background_color` (转发区) | `theme_divider_color` | `textColorPrimary` | `textColorSecondary` | `textColorTertiary` |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `elegant_purple` | `#B693AE` | `#666BB3` | `#DDA5AD` | `#FFEEEEEE` | `#FFFFFFFF` | `#FFFDFDFD` | `#FFF0F0F0` | `#FFEEEEEE` | `#FF181818` | `#FF636363` | `#FF939393` |
| `green` | `#50BBA7` | `#309887` | `#E27866` | `#FFEEEEEE` | `#FFFFFFFF` | `#FFFDFDFD` | `#FFF0F0F0` | `#FFEEEEEE` | `#FF181818` | `#FF636363` | `#FF939393` |
| `light_blue` | `#FF638CCC` | `#537BBA` | `#F38393` | `#FFEEEEEE` | `#FFFFFFFF` | `#FFFDFDFD` | `#FFF0F0F0` | `#FFEEEEEE` | `#FF181818` | `#FF636363` | `#FF939393` |
| `pink` | `#FFFB7299` | `#FFD66182` | `#859CA3` | `#FFEEEEEE` | `#FFFFFFFF` | `#FFFDFDFD` | `#FFF0F0F0` | `#FFEEEEEE` | `#FF181818` | `#FF636363` | `#FF939393` |
| `grey` | `#FF607D8B` | `#4C748A` | `#FFF9AA33` | `#FFEEEEEE` | `#FFFFFFFF` | `#FFFDFDFD` | `#FFF0F0F0` | `#FFEEEEEE` | `#FF181818` | `#FF636363` | `#FF939393` |
| `dark_red` | `#FFBE3144` | `#FF872341` | `#FFBE3144` | `#FFEEEEEE` | `#FFFFFFFF` | `#FFFDFDFD` | `#FFF0F0F0` | `#FFEEEEEE` | `#FF181818` | `#FF636363` | `#FF939393` |
| `blue` | `#FF2196F3` | `#FF1976D2` | `#FF916FFF` | `#FFEEEEEE` | `#FFFFFFFF` | `#FFFDFDFD` | `#FFF0F0F0` | `#FFEEEEEE` | `#FF181818` | `#FF636363` | `#FF939393` |
| `teal` | `#FF009688` | `#FF00796B` | `#FFFD5523` | `#FFEEEEEE` | `#FFFFFFFF` | `#FFFDFDFD` | `#FFF0F0F0` | `#FFEEEEEE` | `#FF181818` | `#FF636363` | `#FF939393` |
| `red` | `#FFDB4437` | `#FFC53929` | `#FFDB615B` | `#FFEEEEEE` | `#FFFFFFFF` | `#FFFDFDFD` | `#FFF0F0F0` | `#FFEEEEEE` | `#FF181818` | `#FF636363` | `#FF939393` |
| `orange` | `#FFFF9800` | `#FFF57C00` | `#FFDB7D98` | `#FFEEEEEE` | `#FFFFFFFF` | `#FFFDFDFD` | `#FFF0F0F0` | `#FFEEEEEE` | `#FF181818` | `#FF636363` | `#FF939393` |
| `deep_blue` | `#3F51B5` | `#303F9F` | `#FF4081` | `#FFEEEEEE` | `#FFFFFFFF` | `#FFFDFDFD` | `#FFF0F0F0` | `#FFEEEEEE` | `#FF181818` | `#FF636363` | `#FF939393` |
| `purple` | `#FF673AB7` | `#4925A0` | `#FF0BC4B1` | `#FFEEEEEE` | `#FFFFFFFF` | `#FFFDFDFD` | `#FFF0F0F0` | `#FFEEEEEE` | `#FF181818` | `#FF636363` | `#FF939393` |
| `brown` | `#9C6D5C` | `#A2624F` | `#FF3B4B77` | `#FFEEEEEE` | `#FFFFFFFF` | `#FFFDFDFD` | `#FFF0F0F0` | `#FFEEEEEE` | `#FF181818` | `#FF636363` | `#FF939393` |
| `black` | `#212121` | `#000000` | `#000000` | `#FFEEEEEE` | `#FFFFFFFF` | `#FFFDFDFD` | `#FFF0F0F0` | `#FFEEEEEE` | `#FF181818` | `#FF636363` | `#FF939393` |
| `white` | `#FFFFFFFF` | `#FFFFFFFF` | `#FF009688` *(清单预览 `#15C6B5`)* | `#FFEEEEEE` | `#FFFFFFFF` | `#FFFDFDFD` | `#FFF0F0F0` | `#FFEEEEEE` | `#FF333333` | `#FF636363` | `#FF939393` |
| `white_blue` | `#FFFFFFFF` | `#FFFFFFFF` | `#5F88BA` | `#FFEEEEEE` | `#FFFFFFFF` | `#FFFDFDFD` | `#FFF0F0F0` | `#FFEEEEEE` | `#FF333333` | `#FF636363` | `#FF939393` |
| `night` (`DayNight`) | `#212121` | `#000000` | `#FF009688` | `#FF212121` | `#FF181818` | `#FF303030` | `#FF282828` | `#FF202020` | `#FFFFFFFF` | `#FFCCCCCC` | `#FF888888` |
| `amoled` | `#FF000000` | `#FF000000` | `#FF009688` | `#FF000000` | `#FF000000` | `#FF000000` | `#FF212121` | `#FF202020` | `#FFFFFFFF` | `#FFCCCCCC` | `#FF888888` |
| `night_blue` | `#263238` | `#212C30` | `#208FB9` | `#FF212B30` | `#FF37474F` | `#FF314047` | `#FF2B3940` | `#FF232E33` | `#FFE5E7E8` | `#FFA3ABAE` | `#FF798F97` |
| `night_green_black` | `#00BCD4` | `#00ADB5` | `#FFEEFD54` | `#FF212B30` | `#FF37474F` | `#FF314047` | `#FF2B3940` | `#FF232E33` | `#FFE5E7E8` | `#FFA3ABAE` | `#FF798F97` |
| `transparent` (深字) | `#00000000` | `#FF00796B` | `#FFFD5523` | `#00000000` | `#33FFFFFF` | `#00000000` | `#33FFFFFF` | `#16000000` | `#FFFFFFFF` | `#FFEEEEEE` | `#FFDDDDDD` |
| `transparent` (浅字) | `#00000000` | `#FF00796B` | `#FFFD5523` | `#00000000` | `#33FFFFFF` | `#00000000` | `#11000000` | `#16000000` | `#FF333333` | `#CC000000` | `#FF666666` |

- **自定义主题 (`custom`) 与透明主题编辑器 (`ThemeCustomActivity` / `C6962sk` / `layout/gg.xml` / `menu/x.xml`)**：
  - 自定义主题支持双组颜色：`theme_custom_color` / `theme_custom_accent_color` 与 `theme_custom_style` (`0`=纯白底亮色)，且弹窗采用 **Material ColorChooserDialog (`ViewOnClickListenerC2422cx` + `C2504dx`)**：19 组主色 + 16 组强调色二级色阶网格 + ARGB 四滑块及 6/8 位 Hex 输入框实时双向联动。
  - 透明皮肤编辑器 (`C6962sk`)：顶部 200dp 预览卡片、切换图库选图并按屏幕宽高裁剪、Palette 自动提取图片主题色推荐列、高斯模糊 SeekBar（`blur = 0..25`）与遮罩透明度 SeekBar（`alpha = 0..1`）调节、`theme_transparent_font_color`（「白色(暗色)」/「黑色(亮色)」切换），配置序列化为 JSON 写入 `theme_custom_value`。

---

## 第 8 章 全量页面交互与 UI 详细规格

### 8.1 首页框架、抽屉菜单、底栏与 FAB (`StatusActivity`)

- **双模式底部导航 (`xml/e.xml` vs `xml/d.xml`)**：
  - `hide_hot_tab == false` 时显示 **3 个底栏 Tab**：`首页` (`@id/aey`), `消息` (`@id/aex` 含未读角标红点), `热门/发现` (`@id/aev`)；开启隐藏热门后仅剩 2 个 Tab。
  - `navigation_position == "不显示"` 时彻底隐藏底栏，改由顶部栏/抽屉切换。
  - `navigation_hide_on_scroll`（默认 `true`）控制滚动自动收起/展开底栏；`toolbar_fix_on_scroll`（默认 `false`）控制顶栏滚动锁定；`reselect_tab_refresh`（默认 `true`）控制再次点击当前 Tab 是刷新还是在顶部与上次阅读位置间跳转。
- **可自定义抽屉菜单 (`C2801hc` + `menu_list` JSON + 封面 3 模式)**：
  - 支持左滑/右滑展开控制 (`show_drawer_from_left`)。
  - 头部展示当前登录账号头像、昵称、个性签名、快捷切换账号与开通高级版入口（`layout/hd.xml`），背景支持 3 种封面模式 (`drawer_cover_type`: `1`=跟随主题、`2`=本地自定义裁图 2:1 `2000x1000`、`3`=个人主页封面) 与字体颜色黑/白切换 (`drawer_cover_font_color`)。
  - **12 项可排序与可开关抽屉菜单**（默认全量顺序及标识 Key）：
    1. `comment` - 我的评论和赞 (固定显示或开关控制 -> `StatusMyBehaviorActivity`)
    2. `favorites` - 收藏 (`StatusFavoriteActivity`)
    3. `friend` - 我的关注 (固定显示 -> `MyFriendActivity`)
    4. `topic` - 超话社区 (`MyTopicActivity` / 超话入口)
    5. `nearby` - 附近的微博 (`NearByActivity`)
    6. `history` - 浏览历史 (`STATUS_HISTORY` / `USER_HISTORY`)
    7. `qrcode` - 扫一扫 (`QRCodeScanActivity`)
    8. `more` - 更多 (`FragmentPageActivity` / 发现扩展)
    9. `draft` - 草稿箱 (`StatusDraftActivity`, 固定显示)
    10. `theme` - 主题风格 (`ThemeListActivity`, 固定显示)
    11. `night` - 夜间模式快捷切换 (固定显示)
    12. `setting` - 设置 (`SettingActivity`, 固定显示)
- **首页顶栏 (`menu/a6.xml`)、分组与 FAB**：
  - 顶栏标题点击展开 **分组列表 (`GroupListFragment` / `C6280ooo000O`)**：含「全部关注」「特别关注」「常读」「热门分组」及全部自定义分组；支持弹出网格/列表两种展现 (`group_pop_grid`)，切换时遵循 `auto_refresh_status`。
  - 右侧悬浮按钮 **`AnimatedFloatingActionButton`**：受 `fab_options`（`1`=不显示、`2`=切换分组、`3`=刷新、`4`=发微博 [默认]）与 `show_fab_from_left`（右/左下角位置）控制。
  - 首页右侧滑块 (`fast_scroll_indicator`)；按返回键根据 `home_back` 决定直接退出或双击/后台保留。

### 8.2 微博卡片 (`layout/kp.xml`, `C7036tg`) 与全部交互逻辑

- **卡片外框与间距 (`dimens.xml` & `xml/q.xml`)**：
  - 外边距 16dp (`dimen/bj`)，内嵌 10dp/5dp 分层；受 `show_status_card`（卡片阴影/圆角）、`show_status_card_background`（VIP 头像挂件与卡片封面背景 `feed_cover`）、`show_status_card_divider`（1dp 灰色线条或加高卡片间隔分割线）、`show_status_space`（正文对齐头像右侧，左边保留空白 `40dp + spacing`）、`avatar_style`（正方形/圆角/正圆）、`show_avatar`（隐藏头像/仅隐藏互动头像/Wi-Fi下不隐藏）实时驱动。
- **头部元信息**：
  - 头像 + 微博认证 V 标 + VIP 皇冠标识 (`status_icon_show`) + 博主名（`status_name_theme` 主题色、`status_name_bold` 加粗、`status_origin_name_show` 同时显示备注与原昵称）+ 时间 + `来自 <source>`。
- **正文与富文本引擎**：
  - 字号遵循 `font_size` (`13,14,15,16,17,18,19,20,21,23 pt`，默认 16)；行距额外偏移 `font_spacing_value - 50` px。
  - 自动高亮并支持点击 `#话题#`、`@用户名`（通过 `resolveNickname` / 本地缓存解析跳转）、`http(s)://...` 短链/网页（支持 `browser_https` 长链防劫持展开）以及 `[表情]` 本地 177 个表情高清替换。
  - 长文本支持展开全文 (`/2/statuses/extend`) 与开启翻译 (`status_translation` + 默认语言 `zh/en/ko/ja`)；开启 `text_boom` 时支持长按/弹窗触发大爆炸分词 (`TextDetailActivity`)。
- **媒体与扩展卡槽**：
  - 九宫格图片适配 1 张大图比例、4 张 `2x2`、多图 `3x3`，带 GIF/长图/LivePhoto 角标，受 `download_image_quality`（无图/缩略图/高清/原图/自动/仅Wi-Fi）与 `scroll_idle_load_photo`（滑动停止后加载）控制。
  - 视频卡片支持封面播放、`auto_play_options`（仅Wi-Fi/总是/从不）、专辑入口；头条文章、问答、音乐、超级话题、定位等富卡片直接跳转原生专题页。
  - 转发嵌套区 (`acu`) 采用淡色背景，点击区直达原微博正文。
- **底部交互栏与菜单**：
  - 当 `show_status_options == true` 时显示：`转发`、`评论`、`赞`（含 `like_status_long_click` 长按防误触、红心动画与 `show_like_status_error` 静默/提示切换），可选同步外露收藏按钮（`show_status_collect_btn`）。
  - **详情页与卡片更多操作 (`menu/v.xml` 完整 16 项菜单)**：分享 (`cp`)、在浏览器中打开 (`c9`)、收藏 (`bd`)、复制 (`bi`)、屏蔽 (`ba`)、投诉 (`ck`)、生成长图 (`bk`)、评论管理 (`be`)、编辑历史 (`bv`)、编辑微博 (`bw`)、置顶微博 (`cw`)、设置分享范围 (`cn`)、设置抽奖 (`bz`)、新鲜事投稿 (`bx`)、删除 (`bp`)。

### 8.3 微博正文详情页 (`StatusDetailActivity` / `StatusDetail2Activity`) & 楼中楼 (`StatusCommentFloorActivity`)

- **双布局切换 (`status_detail_tab_scroll`)**：
  - 模式 A (`layout/b6.xml` 默认)：单一 RecyclerView（头部嵌入 `layout/kp` 原微博卡 + 吸顶 `转发 / 评论 / 赞` 计数栏 `layout/ba.xml` + 当前列表）。
  - 模式 B (`layout/b7.xml`)：`ScrollableHeaderLayout` 嵌套 `ViewPager` 支持左右滑动切换转发/评论/赞三大 Tab。
- **评论排序、审核与回复**：
  - 支持切换按热度 (`flow=0` / `comments/hot_timeline`) 与按时间 (`flow=1` / `comments/show`)，若作者本人发出评论可弹出「开启/关闭评论精选」；支持评论点赞、带图评论渲染与下载 (`show_comment_photo_options`)、拉黑并删除 (`comments/block_and_delete`)。
  - 点击评论条目或楼中楼入口进入 `StatusCommentFloorActivity`（`menu/u.xml`：回复评论），按 `comment_sort_by_time`（默认按热度，少时按时间）排序。
  - 底部快速评论输入框支持同时转发 (`rt=1`)、直接唤起 `StatusPublishActivity` 全功能回复与表情面板。

### 8.4 发博器 (`StatusPublishActivity`)、草稿箱 (`StatusDraftActivity`) 与媒体上传 (`C5746oo0Oo0o`)

- **6 种创作模式**：1-发新微博 (`sendweibo`/`compose`)、2-转发 (`repost`)、3-评论 (`comment`)、4-回复评论 (`reply`)、5-点评评分 (`rating`)、6-超话/城市/问答回复 (`supertopic`/`citytopic`/`qa`)；另支持编辑已发微博 (`statuses/modify_weibo`)。
- **顶部/菜单功能 (`menu/n.xml`)**：选择账号 (`ab1`)、发送选项菜单含：**定时发送** (`a84`) / **取消定时** (`a85`)、**图片水印** (`a87`: 跟随设置/右下/居中/图心/不显示)、**微博尾巴** (`a83`: 按 UID 读取 `C2934j` 与 `publish_source_<uid>`)、**快转** (`lp`: 开启 `direct_repost` 时可用)、**点评** (`a82`)、**签到** (`a81`)、**投票** (`a86`)。
- **工具栏**：选图（最多 18 张 + 相机拍摄 + 图片裁剪编辑 `CropImageActivity`/`PhotoEditActivity` + 原图/压缩选择 `photo_upload_quality`）、视频选择与分片上传 (`fileplatform/init.json` + `upload.json`)、`@好友` (`AtUserActivity` 读取本地 `FOLLOWER` 拼音表 + 在线联想)、`#话题#` 插入、离线 174 表情 + 396 Emoji + 颜文字多标签表情面板、定位 POI 选择 (`place/nearby_pois`)、可见范围切换（公开/好友圈/仅自己可见/指定分组）。
- **草稿箱 (`StatusDraftActivity` + `menu/w.xml` 「清空草稿箱」)**：支持手动保存草稿、后台发送失败自动留存与点击重试（`StatusPublishService`），列表显示类型角标、媒体缩略图与定时时间。

### 8.5 个人主页、资料编辑与关系管理 (`PersonalHomepageActivity` / `EditProfileActivity` / `MyFriendActivity` / `GroupManageActivity`)

- **个人主页 (`layout/ap.xml` + `o0OO000O`)**：
  - 视差可折叠顶部封面 + 头像 + 性别 + 认证说明（「微博认证：…」）+ 关注数/粉丝数/微博数/赞数快捷入口 + 关注/取关/互关状态按钮 + 快捷私信按钮 + 勋章栏 (`layout/h6`)。
  - 主体默认 **3 大基础 Tab**：「关于」(资料卡与常用信息)、「微博(%s)」(支持全部/原创/图片/视频筛选)、「相册」(`107803<uid>` 瀑布流网格)；并根据接口返回的 `tabsInfo` 动态挂载额外频道 Tab（`video`、`cardlist`、`headline`、`mini_video`）。
  - 右上角菜单 (`menu/m.xml`) 共 **9 项**：搜索微博 (`PersonalStatusSearchActivity`)、编辑资料 (`EditProfileActivity`)、编辑分组 (`GroupManageActivity`)、分享用户、移除粉丝、一键拉黑/取消拉黑、举报用户、屏蔽此人、添加到桌面快捷方式。
  - 若为他人主页显示右下 FAB 快捷进入对方微博时间线；若访问他人主页，自动累计 `USER_HISTORY` 访问次数（用于「经常访问」排序，受 `hide_often_visit` 控制）。
- **编辑资料 (`EditProfileActivity` + `menu/h.xml`「更新」)**：修改头像 (`account/avatar_upload`)、昵称、简介、性别、生日、地点与封面图，保存实时回写本地账号表。
- **我的好友 & 分组管理 (`MyFriendActivity` / `GroupManageActivity`)**：查看关注/粉丝/推荐人列表、搜索好友 (`UserSearchActivity`)、新建/重命名/删除分组、调整分组排序 (`groups/order`) 与管理分组成员。

### 8.6 超话、发现、热门微博与通用搜索 (`TopicHomePageActivity` / `HotStatusActivity` / `HotPageActivity` / `HotSearchActivity` / `SearchActivity`)

- **超话主页 (`TopicHomePageActivity` / `layout/bh.xml` + `C3070kl` + `menu/z.xml`)**：
  - 顶部带高斯模糊封面的超话信息卡（等级、主持人、阅读/帖子/粉丝数）、**关注/取关超话 (`friendships_pages/create|destroy`)** 与 **超话打卡签到 (`/2/page/button`)** 交互按钮。
  - 内嵌多频道 Tab 列表（按服务端 `navigator` 动态生成帖子流、精华、视频等，支持 `feed`/`soul`/`video` 自动置前），右上方提供超话内搜索 (`TopicStatusSearchActivity`)、分享、投诉、添加到桌面，右下角提供带当前超话前缀发博 FAB。
- **发现与热门页**：
  - `HotStatusActivity` (`layout/be.xml`)：多分类横向 Tab（推荐/榜单/娱乐/体育等），卡片支持 `hot_status_comment_preview`（显示精选热评预览）。
  - `HotPageActivity` (`layout/b0.xml` + `menu/r.xml`)：超话分类大厅 + 榜单列表与搜索。
  - `HotSearchActivity` (`layout/be.xml`)：微博热搜榜 1..50 名（带热/新/爆标签与热度值）+ 榜单分栏，`hot_search_tag` 控制查看历史记录。
  - `SearchActivity` (`layout/b0.xml` + `C5963ooO0OO00` CardList 引擎)：支持输入实时热搜联想词 (`page/get_search_suggest`)、多维度搜索切换（综合/用户/微博/图片/视频/话题）、以及从微博详情/个人页跳转到单人微博检索 (`type=7&uid=...` / `gid=...`)。
- **新鲜事、视频标签与周边 (`FreshListActivity` / `VideoTagActivity` / `NearByActivity`)**：全部原生复用 `CardList` / 分栏引擎；`NearByActivity` (`layout/ao.xml`) 结合地理定位拉取周边动态与附近用户。

### 8.7 头条文章与微博问答 (`ArticleActivity` / `QAActivity`)

- **头条文章 (`ArticleActivity` / `layout/a5.xml` + `menu/b.xml`)**：调用 `statuses/article_show` 解析封面图、标题、导语、作者信息、正文富文本段落/配图混排（支持原生字体大小调节 `font_article_size` 默认 20，点击图片进大图相册 `GalleryActivity`）及文末互动评论流。
- **微博问答 (`QAActivity` / `Z.java` + `menu/b.xml`)**：调用 `question/show` 与 `question/watch` 渲染问题、悬赏状态、回答者身份与长回答图文混排，底部可一键围观或用浏览器打开。

### 8.8 消息中心与新版私信 (`StatusNotifyActivity` / `StatusMyBehaviorActivity` / `DirectMessage*`)

- **通知中心 (`StatusNotifyActivity` / `layout/be.xml`)**：4 个固定 Tab：`@我的微博` (`STATUS_AT_ME`)、`@我的评论` (`COMMENT_AT_ME`)、`收到的评论` (`COMMENT_TO_ME`)、`收到的赞` (`LIKE_TO_ME`)，支持原位快捷回复评论、跳转正文、清除未读数 (`remind/set_count`)。
- **我的互动 (`StatusMyBehaviorActivity`)**：2 个 Tab：`我发出的评论` (`COMMENT_BY_ME`)、`我赞过的` (`LIKE_BY_ME`)；另有独立粉丝提醒页 `MyFollowersActivity`（新粉丝列表与一键回关）。
- **私信列表与聊天 (`DirectMessageUsersActivity` / `DirectMessageChatActivity`)**：
  - 列表页支持未读/群聊/订阅消息整合，受 `remind_dm_subscribe_ignore` 控制屏蔽订阅号私信，提供订阅屏蔽管理入口与批量删除对话 (`direct_messages/destroy_batch`)。
  - 聊天页支持 **新版气泡模式 (`new_dm_2_mode`)** 与经典模式、回车发送 (`direct_message_enter`)、发送文本/表情/图片（WebIM upload）、语音播放 (`msget`)、撤回消息 (`direct_messages/recall.json`) 与群聊信息/成员排序 (`menu/a4.xml`: 按字母/活跃度/加群时间/最后发言时间)/踢人/退群。

### 8.9 相册浏览、视频播放器、悬浮窗与音乐 (`GalleryActivity` / `VideoDetailActivity` / `MediaPlayerActivity` / `MusicPlayerActivity`)

- **高清相册 (`GalleryActivity` / `ViewOnLongClickListenerC2072Yl` / `layout/f6.xml` + `menu/a9.xml`)**：
  - 支持左右滑动翻页（展示原博多图 `1/9` 计数与长图/GIF/LivePhoto 处理）、双击/双指缩放、单击返回 (`click_photo_back`)、向下/向上拖拽渐隐背景返回 (`drag_photo_back`)、查看/下载原图与实时体积显示、`big_image_improve` 超清采样增强、查看图片 EXIF/直达对应微博详情、调用 `ImageSaveService` 保存至指定目录 (`save_photo_path` & `same_photo_name` 防重命名覆盖)、以及长按弹出操作菜单（保存/原图/编辑/裁剪 `CropImageActivity`/二维码识别 `QRCodeScanActivity`/分享）。
- **视频详情与播放器 (`VideoDetailActivity` / `ViewOnClickListenerC6470oooOOoOo` / `MediaPlayerActivity`)**：
  - 自动/手动多清晰度切换 (`video_play_quality`: 超清 1080P / 高清 720P / 标清 480P / 流畅 / 自动) 并调用 `!/multimedia/playback/batch_get` 解析直链。
  - 手势控制亮度和音量、左右滑动进度（受 `video_controller_hide` 禁用控制）、全屏横屏适配 (`auto_fullscreen_video`)、自动关闭 (`auto_close_video`)。
  - **专辑连播与弹幕 (`video_play_list` / `auto_play_next_video`)**：详情下方展示相关视频推荐列表 + 微博评论 Tab，支持发送弹幕评论（`comment_with_danmu=1`）；开启 `floating_video` 时支持应用内小窗/画中画边刷微博边看视频（关闭按钮左/右侧可配置 `show_video_close_from_left`）。
- **微博音乐播放器 (`MusicPlayerActivity` / `layout/am.xml`)**：支持专辑封面旋转动画、`ViewPager` 歌词滚动同步、进度条拖拽与后台播放服务。

### 8.10 隐私黑名单与文本大爆炸 (`CommonSearchActivity` / `C6634oooooooO` / `TextDetailActivity`)

- **黑名单与关键词过滤 (`C6634oooooooO` / `layout/hw.xml` + `menu/d.xml`)**：
  - 集成 3 大过滤维度：`TYPE=0` 用户黑名单（含自动从微博卡片「屏蔽」与个人主页「拉黑」联动）、`TYPE=1` 关键词屏蔽（支持正则与全文/用户名范围匹配）、`TYPE=2` 微博来源（小尾巴）屏蔽。
  - 每条规则独立控制启用开关 (`STATE`) 与生效方式 (`BLACK_TYPE`: `1`=完全隐藏、`2`=折叠为可展开提示条)。
  - 支持多选删除、清空全部，以及通过 `menu/d.xml` 「备份」实现 `.share_backup` 本地文件完整**导出与覆盖导入屏蔽词库**。
- **文本大爆炸 (`TextDetailActivity` / `layout/bg.xml`)**：将整条微博按语义中文分词拆分为流式点击块，支持划选连续多个词组一键复制或直接发起微博搜索。

---

## 第 9 章 全量 37 个原生菜单 (`res/menu/*.xml`) 对照表

| 菜单文件 | 归属页面 / 组件 | 包含菜单项与动作 |
| :--- | :--- | :--- |
| `menu/a.xml` | `WeiboWebAuthorizeActivity` | `cg`: 登录疑问 |
| `menu/a0.xml` | 好友发现/推荐 | `c7`: 新的好友 |
| `menu/a1.xml` | `InAppWebView` (`C6968sn`) | `c6`: 更多 -> `ci`: 刷新 / `bi`: 复制链接 / `cp`: 分享链接 / `c8`: 在浏览器中打开 |
| `menu/a2.xml` | 通用占位底部 Tab | `ca`..`ce` 动态 Tab 槽位 |
| `menu/a3.xml` | UCrop 裁剪页 | `kg`/`kh` 旋转, `kd` 翻转 (`ke`水平/`kf`垂直), `kc` 确认裁剪 |
| `menu/a4.xml` | 群聊成员 (`AbstractC2185ada`) | `bm` 移除 / `c0` 管理 / `cq` 排序 (`cs`按字母/`cr`活跃度/`ct`加群时间/`cu`最后发言时间) |
| `menu/a5.xml` | 通用动态菜单 | `at` / `au` 动态动作槽 |
| `menu/a6.xml` | **`StatusActivity` 首页** | `cf`: 发微博 / `co`: 搜索 |
| `menu/a7.xml` | `ThemeList` (`C0465Kk`) 等 | `at` 动态确认/保存槽 |
| `menu/a8.xml` | 通用确认页 (`C0189Bh`) | `bf`: 确定 |
| `menu/a9.xml` | **`GalleryActivity` 相册子页** | `c6`: 更多 -> `bq`: 微博详情 / `cm`: 保存到手机 |
| `menu/a_.xml` | 图片自定义裁剪 (`Tja`) | `a41`: 裁剪 / `a42` 辅助槽 |
| `menu/b.xml` | **文章 / 问答 (`Article` / `QA`)** | `acs`: 选项 -> `c9`: 浏览器打开 / `c_`: 微博打开 / `az`: 调整字体 / `bd`: 收藏 / `cp`: 分享 |
| `menu/c.xml` | 图片编辑多选页 (`C1886Sm`) | `bf`: 确定 |
| `menu/d.xml` | **黑名单与关键词过滤 (`C6634oooooooO`)** | `co`: 搜索 / `b2`: 备份(导出/导入) / `ay`: 新增 / `bn`: 清空所有 / `bm`: 删除 |
| `menu/e.xml` | **CardList / FreshList 专题页** | `cp`: 分享 / `c9`: 在浏览器中打开 |
| `menu/f.xml` | 多账号/辅助选号 (`C0649O000oo00`) | `ab1`: 选择账号 / `ay`: 新增 / `bm`: 删除 |
| `menu/g.xml` | 通用更多入口 | `c6`: 更多 |
| `menu/h.xml` | **`EditProfileActivity` 编辑资料** | `cy`: 更新 |
| `menu/i.xml` | **分组管理 (`GroupManageActivity`)** | `bj`: 新建分组 |
| `menu/j.xml` | **其他设置 / 实验室 (`O00O0000`)** | `cg`: 问题 / `bm`: 清除 / `co`: 搜索 |
| `menu/l.xml` | 图片挑选 | `bc`: 选择更多图片 |
| `menu/m.xml` | **`PersonalHomepageActivity` 主页** | `a4q`: 更多 -> 搜索微博/编辑资料/编辑分组/分享用户/移除粉丝/一键拉黑/举报用户/屏蔽此人/添加到桌面 |
| `menu/n.xml` | **`StatusPublishActivity` 发博** | `ab1`选号 / `act`发送选项(定时发送/取消定时/图片水印/微博尾巴/快转/点评/签到/投票) |
| `menu/o.xml` | **`SharePurchaseActivity` 高级版** | `cg`: 帮助/疑问 |
| `menu/p.xml` | **抽屉菜单调整 (`C2801hc`) / 尾巴** | `cl`: 保存 |
| `menu/q.xml` | **`QRCodeScanActivity` 扫一扫** | `b0`: 相册选取 |
| `menu/r.xml` | **`HotPageActivity` 热门话题** | `co`: 搜索 |
| `menu/s.xml` | `FragmentPageActivity` | `cp`: 分享 |
| `menu/t.xml` | 通用帮助页 | `cg`: 帮助 |
| `menu/u.xml` | **`StatusCommentFloorActivity`** | `cj`: 回复评论 |
| `menu/v.xml` | **`StatusDetailActivity` 微博正文** | `cp`: 分享 / `c6`: 更多（浏览器打开/收藏/复制/屏蔽/投诉/生成长图/评论管理/编辑历史/编辑微博/置顶微博/设置分享范围/设置抽奖/新鲜事投稿/删除） |
| `menu/w.xml` | **`StatusDraftActivity` 草稿箱** | `bm`: 清空草稿箱 |
| `menu/x.xml` | **`ThemeCustomActivity` 透明主题** | `b1`: 使用 |
| `menu/y.xml` | 实验室实验列表 | `cg`: 问题 / `bs`: 时间线 |
| `menu/z.xml` | **`TopicHomePageActivity` 超话** | `a4q`: 更多 -> 搜索/分享/投诉/取消关注/添加到桌面 |

---

## 第 10 章 全部 11 个设置页 (`xml/g..q`) 与偏好 Key 1:1 明细表

1. **根设置首页 (`xml/g.xml` -> `SettingFragment` `C2031Xb`)**：
   - 常规设置：基本设置 (`xml/i`)、流量控制 (`xml/j`)、音效管理 (`xml/p`)、通知设置 (`xml/l`)、隐私设置 (`xml/n`)
   - 显示设置：阅读习惯 (`xml/o`)、微博样式 (`xml/q`)、布局样式 (`xml/k`)
   - 其他：Share 高级版 (`SharePurchaseActivity`)、Share 实验室 (`xml/m`)、关于 (`xml/h`)、分享 Share。
2. **关于页 (`xml/h.xml` -> `SettingAboutFragment` `C0512Mb`)**：
   - `download_update_auto` (Wi-Fi 自动下安装包, `true`) / `rate` (评分) / `check_update` (检查更新) / `history_version` (历史版本) / `version_code` (连点 3 次开启隐藏功能) / `user_guide` (使用手册) / `donate_to_developer` (支付宝/微信收款码/PayPal 捐赠) / `user_and_privacy` (用户协议和隐私政策)。
3. **基本设置 (`xml/i.xml` -> `BasicSettingFragment` `C1904Tb`)**：
   - `home_back` (`false`, 首页按返回直接退出不留后台)
   - `swipe_back` (`"3"`, `1=右滑 / 2=左滑 / 3=左右滑 / 4=禁用`)
   - `language` (`"1"`, `1=跟随系统 / 2=简体中文 / 3=繁体中文 / 4=English`)
   - `orientation_new` (`"1"`, `1=竖屏 / 2=横屏`)
   - `ic_launcher` (`Launcher`, `Launcher2`, `Launcher3`, `Launcher4`, `Launcher5` 切换桌面图标)
   - `same_photo_name` (`false`, 保存以时间戳命名防覆盖)
   - `save_photo_path` / `save_video_path` (保存目录选择)
   - `click_photo_back` (`true`, 单击大图返回)
   - `drag_photo_back` (`true`, 拖拽大图返回)
   - `clear_photo_cache` (统计磁盘大小并一键清理图片缓存)
   - `internal_app_browser` (`true`, 关闭弹窗提示会影响微博网页认证能力)
   - `custom_tabs_ui` (`true`, 依赖 `internal_app_browser == false`)
4. **流量控制 (`xml/j.xml` -> `DataFlowFragment` `C3302nc`)**：
   - `preread` (`true`, 预读模式提前加载下一页)
   - `load_status_count` (`"1"`, `1=自动(20~30) / 2=30条 / 3=50条 / 4=88条 / 5=100条`)
   - `auto_play_options` (`"3"`, `1=仅Wi-Fi / 2=总是 / 3=从不`)
   - `video_play_quality` (`"3"`, `1=超清 / 2=高清 / 3=标清 / 4=流畅 / 5=自动`)
   - `save_image_original` (`false`, 保存图片默认原图)
   - `show_avatar` (MultiSelect, `1=微博头像 / 2=评论转发赞头像 / 3=Wi-Fi下不隐藏`)
   - `download_image_quality` (`"5"`, `1=无图 / 2=缩略图 / 3=高清图 / 4=原图 / 5=自动 / 6=仅Wi-Fi加载`)
   - `show_comment_photo_options` (`"1"`, `1=跟随微博 / 2=仅Wi-Fi / 3=从不`)
   - `photo_upload_quality` (`"2"`, `1=压缩 / 2=原图 / 3=自动`)
5. **布局样式 (`xml/k.xml` -> `LayoutStyleFragment` `C2718gc`)**：
   - `drawer_menu` (`C2801hc` 菜单显隐与拖拽排序)、`drawer_cover_type` (1/2/3)、`drawer_cover_font_color`
   - `navigation_position` (`"2"`, `2=底栏 / 3=不显示`，对应 `array/a5` + `array/a6`)
   - `navigation_hide_on_scroll` (`true`)、`toolbar_fix_on_scroll` (`false`)、`flat_status_bar` (`true`)、`navigation_theme_color` (`true`)
   - `show_drawer_from_left` (`true`)、`show_fab_from_left` (`false`)、`fast_scroll_indicator` (`true`)、`show_video_close_from_left` (`false`)
   - `fab_options` (`"4"`, `1=不显示 / 2=切换分组 / 3=刷新 / 4=发微博`)
   - `hide_hot_tab` (`false`)、`hide_hot_search` (`false`)、`hide_often_visit` (`false`)、`hide_share_friend_list` (`false`)
6. **通知设置 (`xml/l.xml` -> `NotifyFragment` `C3219mc`)**：
   - `notify_open` (`true`)、`notify_oreo` (系统通知通道设置)、`app_persistent` (`false`, 常驻后台服务 `SharePersistentService`)
   - `remind_dm_subscribe_ignore` (`false`)、`remind_dm_subscribe_manage` (订阅屏蔽名单管理)
   - `special_follow_remind` (`false`)、`remind_notify_type` (`['评论','@我','私信','新粉丝','点赞']` 全选默认值)、`remind_unread_type` (`['评论','@我','点赞']`)、`remind_by_vibration` (`true`)、`remind_by_lights` (`true`)
7. **其他与实验室 (`xml/m.xml` -> `O00O0000`)**：
   - `privacy_common`、`blacklist`、`black_content`、`block_status`、`repost_direct`、`recently_visit`
8. **隐私设置 (`xml/n.xml` -> `PrivacyFragment` `C6864rc`)**：
   - `night_theme` (`"3"`, `1=夜间黑 night / 2=A屏黑 amoled / 3=夜间蓝 night_blue`)、`auto_night_mode_follow_system` (`false`)、`auto_night_mode` (`true`)、`auto_night_mode_duration` (自定义起止时段)、`night_shade_mode` (`false`, 图片变暗护眼)
   - `read_verse_order` (`false`, 逆序阅读)
   - `like_status_long_click` (`false`, 长按触发点赞)、`show_like_status_error` (`false`, 显式报错开关)、`show_recommend_status` (`true`, 显示好友赞/打赏动态)
   - `video_play_list` (`true`, 专辑模式)、`auto_fullscreen_video` (`false`)、`floating_video` (`false`)、`floating_video_move` (`false`)、`video_controller_hide` (`false`)、`auto_close_video` (`false`)
   - `start_refresh_status` (`false`, 启动自动刷新)、`auto_refresh_status` (`false`, 切换分组自动刷新)、`reselect_tab_refresh` (`true`)
   - `hot_status_comment_preview` (`true`)、`comment_floor` (`true`)、`comment_sort_by_time` (`false`)
   - `scroll_idle_load_photo` (`false`)、`direct_repost` (`true`)、`direct_message_enter` (`false`)、`hot_search_tag` (`false`)
9. **阅读习惯 (`xml/o.xml` -> `ReadHabitFragment` `C7028tc`)**：
   - `navigation_anim` (`false`)、`text_boom` (`true`)、`http_dns` (`false`)、`video_dns` (`false`)
   - `status_translation` (`false`)、`status_translation_default` (`"2"` `en`, 支持 `zh/en/ko/ja`)
   - `status_detail_tab_scroll` (`false`)、`browser_https` (`true`)、`webview_night` (`true`)、`big_image_improve` (`false`)、`new_dm_2_mode` (`true`)
10. **音效管理 (`xml/p.xml` -> `SoundFragment` `C7196vc`)**：
    - `sound_off` (`false`)、`ringtone_type` (`1=首页有新微博 / 2=未读通知 / 3=视频下载成功`)、`ringtone_notify_oreo`、`vibration_on` (`true`)、`vibration_feedback` (`true`)
11. **微博样式 (`xml/q.xml` -> `StatusStyleFragment` `C7526zc` 顶部实时预览微博卡)**：
    - `publish_source`、`font_size` (`"16"`)、`font_spacing_value` (`50`, 偏移 `-50`)、`show_status_card_background` (`false`)、`avatar_style` (`"3"` 圆形)、`show_status_card` (`true`)、`status_icon_show` (`true`)、`show_status_options` (`true`)、`show_status_collect_btn` (`false`)、`show_status_space` (`false`)、`status_name_theme` (`false`)、`status_name_bold` (`true`)、`status_origin_name_show` (`false`)、`show_status_card_divider` (`false`)

---

## 第 11 章 离线表情包与富文本引擎规格

1. **原版内嵌图片表情 (`C0234Cx.java`)**：
   - 共 **248 条**映射记录（**174 个默认展示简体表情** + **74 个兼容匹配的繁体/别名**，如 `[可憐]->[可怜]`、`[抱抱_旧]->[抱抱]`），对应 `decompiled/resources/res/drawable*/` 下 **177 个唯一本地图像文件**（零缺失）。
   - 全量打包进入 Flutter `share_app/assets/emoticons/`，在发布页表情面板与正文/评论/私信 `WidgetSpan` 中实现**零网络依赖、离线瞬时高清渲染**；服务端下发的云端表情（`/ajax/config/emoticon` 或 `expression/get`）作为扩展分组补充展示。
2. **Unicode Emoji 与颜文字**：
   - 原版 `arrays.xml` `array/ai` 内置 **396 个标准 Unicode Emoji** 码点，在表情面板独立分类提供点击插入。
3. **富文本与短链展开**：
   - 统一解析 HTML 标签与纯文本 token：`[表情名]`、`#话题#` / `#超话[超话]#`、`@昵称`、`http(s)://...`、`t.cn`、`sinaweibo://...`；当开启 `browser_https` 时对短链优先用 Rust `short_url/expand` 或 HEAD 解析安全目标后再打开，避免广告劫持。

---

## 第 12 章 Android / iOS 双端原生适配与构建交付清单

| 适配领域 | Android 实现规范 | iOS 实现规范 |
| :--- | :--- | :--- |
| **Rust 核心编译** | NDK 28 `aarch64-linux-android` / `armv7-linux-androideabi` / `x86_64-linux-android` 生成 `libshare_core.so` | CocoaPods / Xcode `aarch64-apple-ios` & `aarch64-apple-ios-sim` / `x86_64-apple-ios` `staticlib` (`libshare_core.a`)，确保零 Android 系统调用与 TLS 使用 `rustls-tls` |
| **WebView 全量 Cookie 捕获 (`com.hengye.share/cookies`)** | `MainActivity.kt` 注册 `MethodChannel`，调用 `android.webkit.CookieManager.getInstance().getCookie(url)` 获取未截断的完整 `SUB`/`SUBP` | `AppDelegate.swift` 注册同名 `MethodChannel`，通过 `WKWebsiteDataStore.default().httpCookieStore.getAllCookies` 过滤微博域名并拼接完整 Cookie Header |
| **手势返回 (`swipe_back`)** | 遵循设置项支持左/右/双向边缘滑动返回与全局禁用 | iOS 保留原生边缘滑动手势并与 Flutter 路由 `CupertinoPageRoute` / 自定义滑返手势对齐 |
| **媒体保存与权限 (`Info.plist` / `AndroidManifest.xml`)** | Android Q+ 分区存储 / `MediaStore` + 相册通知 (`ImageSaveService`) | `NSPhotoLibraryUsageDescription`、`NSPhotoLibraryAddUsageDescription`、`NSCameraUsageDescription`、`NSMicrophoneUsageDescription`、`NSLocationWhenInUseUsageDescription` |
| **应用图标切换 (`ic_launcher`)** | 5 个 `activity-alias` (`Launcher`..`Launcher5`) 动态启用/禁用 | 使用 `UIApplication.shared.setAlternateIconName`（及优雅提示降级） |
| **深色/透明主题状态栏适配** | `SystemUiOverlayStyle` + `flat_status_bar` + 虚拟导航栏跟随主题色 | 匹配状态栏亮/暗文本样式、SafeArea 顶部与底部 Home Indicator 全透叠加透明背景图 |
