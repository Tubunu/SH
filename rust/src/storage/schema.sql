-- Share Weibo SQLite Schema (9 Core Tables)
-- 1:1 mapped to GreenDAO 3 models from Share v3.9.6

-- 1. 用户账号表 (支持多账号切换、Token与Cookie持久化)
CREATE TABLE IF NOT EXISTS "USER" (
    "_id" INTEGER PRIMARY KEY AUTOINCREMENT,
    "UID" TEXT NOT NULL UNIQUE,
    "TOKEN" TEXT NOT NULL,
    "PARENT_TYPE" INTEGER NOT NULL,          -- 账号类型: 0-OAuth, 1-Web/Cookie, 2-第三方
    "GSID" TEXT,                             -- 微博接口全局 Session ID
    "S_VALUE" TEXT,                          -- 签名加密密钥
    "I_VALUE" TEXT,                          -- 设备特征值
    "PARENT_JSON" TEXT,                      -- 用户个人详细 Profile JSON 备份
    "REFRESH_TOKEN" TEXT,
    "EXPIRES_IN" INTEGER,                    -- Token 过期毫秒时间戳
    "NAME" TEXT,                             -- 昵称
    "AVATAR" TEXT,                           -- 头像 URL
    "GENDER" TEXT,                           -- 性别: m/f/n
    "SIGN" TEXT,                             -- 个性签名
    "COVER" TEXT,                            -- 个人主页封面图 URL
    "ACCOUNT" TEXT,                          -- 登录用户名/手机号/邮箱
    "PASSWORD" TEXT,                         -- 密码 (AES-256 加密保存)
    "AD_TOKEN" TEXT,
    "COOKIE" TEXT,                           -- SUB/SUBP 网页 Cookie 字符串
    "EXTRA" TEXT                             -- 扩展元数据 JSON
);

CREATE INDEX IF NOT EXISTS "IDX_USER_UID" ON "USER" ("UID");

-- 2. 微博草稿箱表
CREATE TABLE IF NOT EXISTS "STATUS_DRAFTS" (
    "_id" INTEGER PRIMARY KEY AUTOINCREMENT,
    "CONTENT" TEXT NOT NULL,                 -- 正文内容
    "DATE" INTEGER NOT NULL,                 -- 保存时间戳
    "URLS" TEXT,                             -- 选中的多图本地文件路径 JSON 列表 (最大 18 张)
    "UID" TEXT NOT NULL,                     -- 发起账号 UID
    "TARGET_STATUS_JSON" TEXT,               -- 若为转发，所引用的原微博 JSON
    "TARGET_STATUS_ID" TEXT,                 -- 转发/评论的目标微博 ID
    "TARGET_COMMENT_ID" TEXT,                -- 回复的目标评论 ID
    "TARGET_COMMENT_USER_NAME" TEXT,         -- 回复目标作者名称
    "TARGET_COMMENT_CONTENT" TEXT,           -- 回复目标评论片段
    "ASSIGN_GROUP_ID_STR" TEXT,              -- 定向发布的微博分组 GID
    "ASSIGN_GROUP_TYPE" INTEGER,             -- 公开范围类型: 0-公开, 1-好友圈, 2-仅自己, 3-指定分组
    "ADDRESS" TEXT,                          -- 定位 POI 名称及经纬度 JSON
    "PUBLISH_TIMING" INTEGER,                -- 定时发布时间戳
    "IS_COMMENT_ORIGIN" INTEGER,             -- 转发时是否同时评论原博
    "STATUS" INTEGER NOT NULL DEFAULT 0,     -- 状态: 0-草稿, 1-正在发送, 2-发送失败
    "IS_MENTION" INTEGER,                    -- 是否含有 @
    "STATE" INTEGER,
    "EXTRA" TEXT,
    "TYPE" INTEGER,                          -- 0-原创微博, 1-转发, 2-评论, 3-回复评论
    "PARENT_TYPE" INTEGER
);

CREATE INDEX IF NOT EXISTS "IDX_STATUS_DRAFTS_UID" ON "STATUS_DRAFTS" ("UID");

-- 3. 微博浏览历史表
CREATE TABLE IF NOT EXISTS "STATUS_HISTORY" (
    "_id" INTEGER PRIMARY KEY AUTOINCREMENT,
    "STATUS_ID" TEXT NOT NULL,               -- 微博 ID
    "USERNAME" TEXT,                         -- 博主名称
    "TOTAL_TEXT" TEXT,                       -- 正文摘要
    "UID" TEXT NOT NULL,                     -- 浏览账号 UID
    "JSON" TEXT NOT NULL,                    -- 微博完整数据备份
    "CREATE_AT" INTEGER NOT NULL             -- 浏览时间戳
);

CREATE INDEX IF NOT EXISTS "IDX_STATUS_HISTORY_UID_CREATE" ON "STATUS_HISTORY" ("UID", "CREATE_AT" DESC);
CREATE UNIQUE INDEX IF NOT EXISTS "IDX_STATUS_HISTORY_UID_STATUS" ON "STATUS_HISTORY" ("UID", "STATUS_ID");

-- 4. 微博分组列表表
CREATE TABLE IF NOT EXISTS "GROUP_LIST" (
    "_id" INTEGER PRIMARY KEY AUTOINCREMENT,
    "INSERT_NUMBER" INTEGER NOT NULL,        -- 排序索引
    "UID" TEXT NOT NULL,                     -- 所属用户 UID
    "GID" TEXT NOT NULL,                     -- 分组 ID
    "TITLE" TEXT NOT NULL,                   -- 分组标题 (如"常读", "特别关注")
    "NAME" TEXT,
    "DESCRIPTION" TEXT,
    "COUNT" INTEGER,                         -- 组内成员数
    "TYPE" INTEGER,
    "VISIBLE" INTEGER DEFAULT 1,             -- 是否在顶部/抽屉显示
    "REMIND" INTEGER DEFAULT 0               -- 是否开启组更新提醒
);

CREATE INDEX IF NOT EXISTS "IDX_GROUP_LIST_UID" ON "GROUP_LIST" ("UID", "INSERT_NUMBER");

-- 5. 分组成员映射表
CREATE TABLE IF NOT EXISTS "GROUP_MEMBER" (
    "_id" INTEGER PRIMARY KEY AUTOINCREMENT,
    "UID" TEXT NOT NULL,                     -- 用户 UID
    "TID" TEXT NOT NULL,                     -- 成员目标 UID
    "GID" TEXT NOT NULL,                     -- 所在分组 GID
    "NAME" TEXT,
    "GENDER" TEXT,
    "DESCRIPTION" TEXT,
    "AVATAR" TEXT,
    "VERIFIED" INTEGER,
    "VERIFIED_TYPE" INTEGER,
    "FOLLOWING" INTEGER,
    "FOLLOW_ME" INTEGER,
    "IS_GROUP_MEMBER" INTEGER DEFAULT 1
);

CREATE INDEX IF NOT EXISTS "IDX_GROUP_MEMBER_GID" ON "GROUP_MEMBER" ("UID", "GID");

-- 6. 粉丝与关注本地名录表 (用于 @ 快速匹配检索)
CREATE TABLE IF NOT EXISTS "FOLLOWER" (
    "_id" INTEGER PRIMARY KEY AUTOINCREMENT,
    "UID" TEXT NOT NULL,
    "TID" TEXT NOT NULL,
    "NAME" TEXT NOT NULL,
    "PINYIN_NAME" TEXT,                      -- 汉字拼音索引，用于本地拼音快速联想
    "GENDER" TEXT,
    "DESCRIPTION" TEXT,
    "AVATAR" TEXT,
    "VERIFIED" INTEGER,
    "VERIFIED_TYPE" INTEGER,
    "FOLLOWING" INTEGER,
    "FOLLOW_ME" INTEGER
);

CREATE INDEX IF NOT EXISTS "IDX_FOLLOWER_UID" ON "FOLLOWER" ("UID");
CREATE UNIQUE INDEX IF NOT EXISTS "IDX_FOLLOWER_UID_TID" ON "FOLLOWER" ("UID", "TID");
CREATE INDEX IF NOT EXISTS "IDX_FOLLOWER_NAME" ON "FOLLOWER" ("UID", "NAME");
CREATE INDEX IF NOT EXISTS "IDX_FOLLOWER_PINYIN" ON "FOLLOWER" ("UID", "PINYIN_NAME");

-- 7. 屏蔽与黑名单规则表
CREATE TABLE IF NOT EXISTS "BLACK_LIST" (
    "_id" INTEGER PRIMARY KEY AUTOINCREMENT,
    "KEY" TEXT NOT NULL,                     -- 屏蔽目标: UID、关键词或小尾巴文本
    "UID" TEXT NOT NULL,                     -- 作用账号 UID
    "INFO" TEXT,                             -- 额外说明 (如博主昵称)
    "TYPE" INTEGER NOT NULL,                 -- 0-用户黑名单, 1-关键词屏蔽, 2-微博来源(小尾巴)屏蔽
    "STATE" INTEGER NOT NULL DEFAULT 1,      -- 状态: 1-启用, 0-停用
    "BLACK_TYPE" INTEGER NOT NULL            -- 屏蔽策略: 1-全隐藏, 2-折叠显示
);

CREATE INDEX IF NOT EXISTS "IDX_BLACK_LIST_UID" ON "BLACK_LIST" ("UID", "TYPE");

-- 8. 用户常访与搜索历史表
CREATE TABLE IF NOT EXISTS "USER_HISTORY" (
    "_id" INTEGER PRIMARY KEY AUTOINCREMENT,
    "TARGET_UID" TEXT NOT NULL,
    "TARGET_USER_NAME" TEXT NOT NULL,
    "TARGET_USER_AVATAR" TEXT,
    "UID" TEXT NOT NULL,
    "JSON" TEXT,
    "VISIT_COUNT" INTEGER NOT NULL DEFAULT 1,-- 访问频次加权
    "CREATE_AT" INTEGER NOT NULL             -- 最后访问时间
);

CREATE INDEX IF NOT EXISTS "IDX_USER_HISTORY_UID" ON "USER_HISTORY" ("UID", "CREATE_AT" DESC);
CREATE UNIQUE INDEX IF NOT EXISTS "IDX_USER_HISTORY_TARGET_UID" ON "USER_HISTORY" ("TARGET_UID", "UID");

-- 9. 通用结构化缓存表
CREATE TABLE IF NOT EXISTS "SHARE_JSON" (
    "MODEL" TEXT PRIMARY KEY,                -- 键名 (如 "home_timeline_cache_uid")
    "JSON" TEXT NOT NULL                     -- 缓存内容
);
