//! Thin, typed wrappers around the Weibo web endpoints used by the app.

use serde_json::{json, Value};

use super::client::{WebClient, WebError, WebResult, WEIBO_BASE};
use super::session::Account;

const M_BASE: &str = "https://m.weibo.cn";
const PASSPORT_BASE: &str = "https://passport.weibo.com";
/// The WebIM (私信) API lives on the open-platform host, not on weibo.com.
/// Verified from the official `pcweibochat` bundle: it authenticates purely
/// through cookies (`withCredentials: true`, no `access_token` anywhere), so it
/// works on iOS exactly like the rest of the app.
const API_BASE: &str = "https://api.weibo.com";
/// Picture upload host used by the web composer.
const PIC_BASE: &str = "https://picupload.weibo.com";

/// Extracts the JSON object out of a JSONP / callback response body.
fn extract_json(body: &str) -> Option<Value> {
    let start = body.find('{')?;
    let end = body.rfind('}')?;
    if end <= start {
        return None;
    }
    serde_json::from_str(&body[start..=end]).ok()
}

/// Fetches a fresh XSRF token by touching the site root. Weibo only hands it
/// out together with a normal HTML navigation, not on `ajax` calls.
pub async fn refresh_xsrf(client: &WebClient) -> WebResult<()> {
    let response = client
        .get_raw(WEIBO_BASE, WEIBO_BASE)
        .await?;
    // Body is irrelevant, the cookie jar already absorbed Set-Cookie.
    let _ = response;
    Ok(())
}

/// Creates an anonymous ("visitor") session so the app can browse public
/// timelines / search / hot search before the user signs in.
pub async fn guest_login(client: &WebClient) -> WebResult<Account> {
    let fingerprint = json!({
        "os": "1",
        "browser": "Chrome120,0,0,0",
        "fonts": "undefined",
        "screenInfo": "1920*1080*24",
        "plugins": ""
    })
    .to_string();

    let url = format!("{PASSPORT_BASE}/visitor/genvisitor");
    let body = client
        .post_form_raw(
            &url,
            &[
                ("cb".to_string(), "gen_callback".to_string()),
                ("fp".to_string(), fingerprint),
            ],
            PASSPORT_BASE,
        )
        .await?;

    let parsed = extract_json(&body)
        .ok_or_else(|| WebError::parse("无法解析访客票据响应"))?;
    let tid = parsed
        .pointer("/data/tid")
        .and_then(|v| v.as_str())
        .ok_or_else(|| WebError::parse("访客票据缺失"))?;

    let incarnate = format!(
        "{PASSPORT_BASE}/visitor/visitor?a=incarnate&t={tid}&w=2&c=095&gc=&cb=cross_domain&from=weibo&_rand={}",
        js_random()
    );
    let body = client.get_raw(&incarnate, PASSPORT_BASE).await?;
    let parsed = extract_json(&body).ok_or_else(|| WebError::parse("无法解析访客身份响应"))?;

    if let (Some(sub), Some(subp)) = (
        parsed.pointer("/data/sub").and_then(|v| v.as_str()),
        parsed.pointer("/data/subp").and_then(|v| v.as_str()),
    ) {
        client.set_cookie(&format!("SUB={sub}; SUBP={subp}"));
    } else if !client.has_session() {
        return Err(WebError::parse("未能获取访客 Cookie"));
    }

    let _ = refresh_xsrf(client).await;

    Ok(Account {
        uid: String::new(),
        screen_name: "访客".to_string(),
        avatar: String::new(),
        cookie: client.cookie_items(),
        is_guest: true,
    })
}

fn js_random() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(123456);
    format!("0.{nanos}")
}

/// Resolves the account behind the current cookie jar.
/// Uses `m.weibo.cn/api/config`, which reports `data.uid` for logged-in users.
pub async fn fetch_self(client: &WebClient) -> WebResult<Account> {
    let config = client.get(&format!("{M_BASE}/api/config"), M_BASE).await?;
    let login = config
        .pointer("/data/login")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    if !login {
        return Err(WebError::unauthenticated());
    }

    let uid = config
        .pointer("/data/uid")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_string();

    let mut account = Account {
        uid: uid.clone(),
        screen_name: String::new(),
        avatar: String::new(),
        cookie: client.cookie_items(),
        is_guest: false,
    };

    if !uid.is_empty() {
        if let Ok(info) = user_profile(client, &uid).await {
            if let Some(user) = info.pointer("/data/user") {
                account.screen_name = user
                    .get("screen_name")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default()
                    .to_string();
                account.avatar = user
                    .get("avatar_large")
                    .or_else(|| user.get("profile_image_url"))
                    .and_then(|v| v.as_str())
                    .unwrap_or_default()
                    .to_string();
            }
        }
    }

    Ok(account)
}

/// Home timeline of the signed-in user.
/// `max_id`/`since_id` come straight from the previous response for paging.
pub async fn home_timeline(
    client: &WebClient,
    since_id: Option<&str>,
    max_id: Option<&str>,
    count: u32,
) -> WebResult<String> {
    let mut url = format!(
        "{WEIBO_BASE}/ajax/feed/unreadfriendstimeline?refresh=0&count={count}&extparam="
    );
    if let Some(v) = since_id {
        if !v.is_empty() {
            url.push_str(&format!("&since_id={v}"));
        }
    }
    if let Some(v) = max_id {
        if !v.is_empty() {
            url.push_str(&format!("&max_id={v}"));
        }
    }
    let value = client.get(&url, WEIBO_BASE).await?;
    Ok(value.to_string())
}

/// Public "discover" timeline — works for guest sessions too.
pub async fn hot_timeline(
    client: &WebClient,
    max_id: Option<&str>,
    count: u32,
) -> WebResult<String> {
    let max_id = max_id.unwrap_or("0");
    let url = format!(
        "{WEIBO_BASE}/ajax/feed/hottimeline?since_id=0&refresh=0&group_id=102803&containerid=102803&extparam=discover%7Cnew_feed&max_id={max_id}&count={count}"
    );
    let value = client.get(&url, WEIBO_BASE).await?;
    Ok(value.to_string())
}

/// Single status by its `mblogid` (e.g. `Rph1TsL3e`) or numeric id.
pub async fn status_show(client: &WebClient, id: &str) -> WebResult<String> {
    let url = format!("{WEIBO_BASE}/ajax/statuses/show?id={id}");
    let value = client.get(&url, WEIBO_BASE).await?;
    Ok(value.to_string())
}

/// Full body of a "long" status.
pub async fn status_long_text(client: &WebClient, id: &str) -> WebResult<String> {
    let url = format!("{WEIBO_BASE}/ajax/statuses/longtext?id={id}");
    let value = client.get(&url, WEIBO_BASE).await?;
    let text = value
        .pointer("/data/longTextContent")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_string();
    Ok(text)
}

/// First level comments. `flow` 0 = hot, 1 = chronological.
pub async fn comments(
    client: &WebClient,
    status_id: &str,
    uid: &str,
    flow: u32,
    max_id: Option<&str>,
    count: u32,
) -> WebResult<String> {
    let mut url = format!(
        "{WEIBO_BASE}/ajax/statuses/buildComments?is_reload=1&id={status_id}&is_show_bulletin=2&is_mix=0&count={count}&uid={uid}&flow={flow}"
    );
    if let Some(v) = max_id {
        if !v.is_empty() {
            url.push_str(&format!("&max_id={v}"));
        }
    }
    let value = client.get(&url, WEIBO_BASE).await?;
    Ok(value.to_string())
}

/// Replies of a first level comment (楼中楼).
pub async fn comment_replies(
    client: &WebClient,
    comment_id: &str,
    max_id: Option<&str>,
) -> WebResult<String> {
    let mut url = format!(
        "{WEIBO_BASE}/ajax/statuses/buildComments?flow=0&is_reload=1&id={comment_id}&is_show_bulletin=2&is_mix=1&fetch_level=1&count=20"
    );
    if let Some(v) = max_id {
        if !v.is_empty() {
            url.push_str(&format!("&max_id={v}"));
        }
    }
    let value = client.get(&url, WEIBO_BASE).await?;
    Ok(value.to_string())
}

/// Reposts of a status.
pub async fn reposts(client: &WebClient, status_id: &str, page: u32) -> WebResult<String> {
    let url = format!(
        "{WEIBO_BASE}/ajax/statuses/repostTimeline?id={status_id}&page={page}&moduleID=feed"
    );
    let value = client.get(&url, WEIBO_BASE).await?;
    Ok(value.to_string())
}

pub async fn hot_search(client: &WebClient) -> WebResult<String> {
    let value = client.get(&format!("{WEIBO_BASE}/ajax/side/hotSearch"), WEIBO_BASE).await?;
    Ok(value.to_string())
}

pub async fn search(client: &WebClient, keyword: &str, page: u32) -> WebResult<String> {
    let encoded = urlencode(keyword);
    let url = format!(
        "{WEIBO_BASE}/ajax/statuses/search?q={encoded}&count=20&page={page}"
    );
    let value = client.get(&url, WEIBO_BASE).await?;
    Ok(value.to_string())
}

/// Resolves a nickname to a uid.
///
/// `weibo.com/n/<name>` is client-side routed, so there is no 302 to follow;
/// the sidebar suggestion endpoint is the only server-side lookup available and
/// it answers `data.user[0] = { uid, nick }`.
pub async fn resolve_nickname(client: &WebClient, name: &str) -> WebResult<String> {
    let encoded = urlencode(name);
    let url = format!("{WEIBO_BASE}/ajax/side/search?q={encoded}");
    let value = client.get(&url, WEIBO_BASE).await?;
    Ok(value.to_string())
}

pub async fn user_profile(client: &WebClient, uid: &str) -> WebResult<Value> {
    let url = format!("{WEIBO_BASE}/ajax/profile/info?uid={uid}");
    client.get(&url, WEIBO_BASE).await
}

pub async fn user_statuses(
    client: &WebClient,
    uid: &str,
    page: u32,
    feature: u32,
) -> WebResult<String> {
    let url = format!(
        "{WEIBO_BASE}/ajax/statuses/mymblog?uid={uid}&page={page}&feature={feature}"
    );
    let value = client.get(&url, WEIBO_BASE).await?;
    Ok(value.to_string())
}

pub async fn user_albums(client: &WebClient, uid: &str, page: u32) -> WebResult<String> {
    let url = format!(
        "{WEIBO_BASE}/ajax/profile/album?uid={uid}&page={page}&count=12"
    );
    let value = client.get(&url, WEIBO_BASE).await?;
    Ok(value.to_string())
}

/// The signed-in account's favourites — `data[]` holds full status objects.
pub async fn favorites(client: &WebClient, page: u32) -> WebResult<String> {
    let url = format!("{WEIBO_BASE}/ajax/favorites/all_fav?page={page}");
    let value = client.get(&url, &format!("{WEIBO_BASE}/fav")).await?;
    Ok(value.to_string())
}

// ---------------------------------------------------------------------------
// 超话 (super topics)
//
// Discovered in `weibo-pro-next` bundle:
//   /ajax/stopic/cates  -> [{id, name}]  (first entry id 123333 = 最近使用)
//   /ajax/stopic/list   -> {sort_id, keyword, page} -> {data:[...], count}
// The per-topic feed (`/ajax/profile/topicContent`) answers `data:{}` for
// visitors, so the detail page renders status *search* results instead of
// pretending the native feed is available.
// ---------------------------------------------------------------------------

/// 分组列表（`/ajax/feed/allGroups`）。
///
/// 游客态也能拿到完整的分组树：默认分组（全部关注 / 最新微博 / 互相关注 /
/// 原创 / 视频 …）、我的分组（悄悄关注）、订阅分组、我的频道（热门频道带
/// containerid）。分组**时间线**要登录，列表本身不要。
pub async fn groups(client: &WebClient) -> WebResult<String> {
    let url = format!("{WEIBO_BASE}/ajax/feed/allGroups");
    let value = client.get(&url, &format!("{WEIBO_BASE}/")).await?;
    Ok(value.to_string())
}

/// 表情配置（`/ajax/statuses/config`）：10 个分类、348 个表情，含 `phrase`
/// 与 `face.t.sinajs.cn` 的 PNG 地址。
pub async fn emotions(client: &WebClient) -> WebResult<String> {
    let url = format!("{WEIBO_BASE}/ajax/statuses/config");
    let value = client.get(&url, &format!("{WEIBO_BASE}/")).await?;
    Ok(value.to_string())
}

/// 用户 / 话题联想（`/ajax/side/search`）：返回 `user`（精确）、`users`
/// （列表）、`hotquery`（49 条联想词）、`query_relates`。
pub async fn search_users(client: &WebClient, keyword: &str) -> WebResult<String> {
    let url = format!(
        "{WEIBO_BASE}/ajax/side/search?q={}",
        urlencode(keyword)
    );
    let value = client.get(&url, &format!("{WEIBO_BASE}/")).await?;
    Ok(value.to_string())
}

pub async fn stopic_cates(client: &WebClient) -> WebResult<String> {
    let url = format!("{WEIBO_BASE}/ajax/stopic/cates");
    let value = client.get(&url, &format!("{WEIBO_BASE}/topic")).await?;
    Ok(value.to_string())
}

pub async fn stopic_list(
    client: &WebClient,
    sort_id: u32,
    keyword: &str,
    page: u32,
) -> WebResult<String> {
    let mut url = format!("{WEIBO_BASE}/ajax/stopic/list?sort_id={sort_id}&page={page}");
    if !keyword.is_empty() {
        url.push_str(&format!("&keyword={}", urlencode(keyword)));
    }
    let value = client.get(&url, &format!("{WEIBO_BASE}/topic")).await?;
    Ok(value.to_string())
}

// ---------------------------------------------------------------------------
// Message centre (通知中心)
//
// Four independent feeds back the original app's `StatusNotifyActivity`:
//   * 微博提到我        -> /ajax/statuses/mentions   (data.statuses[])
//   * 评论提到我        -> /ajax/comments/mentions   (data.comments[])
//   * 我收到的评论      -> /ajax/message/cmt         (data.comments[] + reply_comment)
//   * 我收到的赞        -> /ajax/message/attitudes   (data.attitudes[])
// All four answer `next_cursor` / `total_number`, and paging is `page=N`.
// ---------------------------------------------------------------------------

pub async fn at_weibo(client: &WebClient, page: u32) -> WebResult<String> {
    let url = format!("{WEIBO_BASE}/ajax/statuses/mentions?page={page}");
    let value = client.get(&url, &format!("{WEIBO_BASE}/at/weibo")).await?;
    Ok(value.to_string())
}

pub async fn at_comments(client: &WebClient, page: u32) -> WebResult<String> {
    let url = format!("{WEIBO_BASE}/ajax/comments/mentions?page={page}");
    let value = client.get(&url, &format!("{WEIBO_BASE}/at/comment")).await?;
    Ok(value.to_string())
}

pub async fn received_comments(client: &WebClient, page: u32) -> WebResult<String> {
    let url = format!("{WEIBO_BASE}/ajax/message/cmt?page={page}");
    let value = client.get(&url, &format!("{WEIBO_BASE}/comment/inbox")).await?;
    Ok(value.to_string())
}

pub async fn received_likes(client: &WebClient, page: u32) -> WebResult<String> {
    let url = format!("{WEIBO_BASE}/ajax/message/attitudes?page={page}");
    let value = client.get(&url, &format!("{WEIBO_BASE}/at/like")).await?;
    Ok(value.to_string())
}

/// Header badges. Returns `data.apps` / `data.groups` plus the DM counters
/// (`page_friends_to_me`, `page_group_to_me`).
pub async fn unread_hint(client: &WebClient) -> WebResult<String> {
    let url = format!("{WEIBO_BASE}/ajax/message/unreadHint");
    let value = client.get(&url, WEIBO_BASE).await?;
    Ok(value.to_string())
}

// ---------------------------------------------------------------------------
// 私信 / Direct messages (WebIM)
//
// Request shapes mirror the official `pcweibochat` client:
//   conversation.json     ?count=N
//   recent_messages.json  ?convert_emoji=1&count=N&uid=<peer>&is_include_group=0[&max_id=]
//   new.json              POST text=<body>&uid=<peer>
// ---------------------------------------------------------------------------

pub async fn dm_conversations(client: &WebClient, count: u32) -> WebResult<String> {
    let url = format!(
        "{API_BASE}/webim/2/direct_messages/conversation.json?count={count}&convert_emoji=1"
    );
    let value = client.get(&url, &format!("{API_BASE}/chat")).await?;
    Ok(value.to_string())
}

pub async fn dm_history(
    client: &WebClient,
    uid: &str,
    max_id: Option<&str>,
    count: u32,
) -> WebResult<String> {
    let mut url = format!(
        "{API_BASE}/webim/2/direct_messages/recent_messages.json?convert_emoji=1&count={count}&uid={uid}&is_include_group=1"
    );
    if let Some(m) = max_id {
        if !m.is_empty() {
            url.push_str(&format!("&max_id={m}"));
        }
    }
    let value = client.get(&url, &format!("{API_BASE}/chat")).await?;
    Ok(value.to_string())
}

pub async fn dm_send(client: &WebClient, uid: &str, text: &str) -> WebResult<String> {
    let url = format!("{API_BASE}/webim/2/direct_messages/new.json");
    let form = vec![
        ("text".to_string(), text.to_string()),
        ("uid".to_string(), uid.to_string()),
    ];
    let value = client
        .post_form(&url, &form, &format!("{API_BASE}/chat"))
        .await?;
    Ok(value.to_string())
}

// ---------------------------------------------------------------------------
// Write operations. The web endpoints expect the `X-XSRF-TOKEN` header, which
// `WebClient` injects automatically from the `XSRF-TOKEN` cookie.
// ---------------------------------------------------------------------------

/// 点赞 / 取消点赞.
///
/// Paths verified against weibo.com's own SPA bundle: it posts
/// `/ajax/statuses/setLike` and `/ajax/statuses/cancelLike` with a bare `{id}`.
/// (An earlier build guessed `/ajax/statuses/like` + `type=like`, which does
/// not exist — every like silently failed.)
pub async fn like(client: &WebClient, status_id: &str, undo: bool) -> WebResult<()> {
    let action = if undo { "cancelLike" } else { "setLike" };
    let url = format!("{WEIBO_BASE}/ajax/statuses/{action}");
    let form = vec![("id".to_string(), status_id.to_string())];
    let value = client
        .post_form(&url, &form, &format!("{WEIBO_BASE}/detail/{status_id}"))
        .await?;
    let ok = value.get("ok").and_then(|v| v.as_i64()).unwrap_or(0);
    if ok <= 0 {
        let msg = value
            .get("msg")
            .or_else(|| value.get("error"))
            .and_then(|v| v.as_str())
            .unwrap_or("点赞失败");
        return Err(WebError::api(msg));
    }
    Ok(())
}

/// 收藏 / 取消收藏 — `/ajax/statuses/createFavorites` /
/// `/ajax/statuses/destoryFavorites` (Weibo's own typo), body `{id}`.
pub async fn favorite(client: &WebClient, status_id: &str, undo: bool) -> WebResult<()> {
    let action = if undo { "destoryFavorites" } else { "createFavorites" };
    let url = format!("{WEIBO_BASE}/ajax/statuses/{action}");
    let form = vec![("id".to_string(), status_id.to_string())];
    let value = client
        .post_form(&url, &form, &format!("{WEIBO_BASE}/detail/{status_id}"))
        .await?;
    let ok = value.get("ok").and_then(|v| v.as_i64()).unwrap_or(0);
    if ok <= 0 {
        let msg = value
            .get("msg")
            .or_else(|| value.get("error"))
            .and_then(|v| v.as_str())
            .unwrap_or("收藏失败");
        return Err(WebError::api(msg));
    }
    Ok(())
}

/// 删除微博 — `POST /ajax/statuses/destroy` with `{id}`.
pub async fn delete_status(client: &WebClient, status_id: &str) -> WebResult<()> {
    let url = format!("{WEIBO_BASE}/ajax/statuses/destroy");
    let form = vec![("id".to_string(), status_id.to_string())];
    let value = client
        .post_form(&url, &form, &format!("{WEIBO_BASE}/detail/{status_id}"))
        .await?;
    let ok = value.get("ok").and_then(|v| v.as_i64()).unwrap_or(0);
    if ok <= 0 {
        let msg = value
            .get("msg")
            .and_then(|v| v.as_str())
            .unwrap_or("删除失败");
        return Err(WebError::api(msg));
    }
    Ok(())
}

/// 编辑历史 — `GET /ajax/statuses/editHistory?mid=&page=`.
pub async fn edit_history(client: &WebClient, mid: &str, page: u32) -> WebResult<String> {
    let url = format!("{WEIBO_BASE}/ajax/statuses/editHistory?mid={mid}&page={page}");
    let value = client
        .get(&url, &format!("{WEIBO_BASE}/detail/{mid}"))
        .await?;
    Ok(value.to_string())
}

/// 翻译 — `GET /ajax/statuses/translate?cid=<idstr>&locale=<lang>`.
pub async fn translate_status(client: &WebClient, idstr: &str, locale: &str) -> WebResult<String> {
    let url = format!("{WEIBO_BASE}/ajax/statuses/translate?cid={idstr}&locale={locale}");
    let value = client
        .get(&url, &format!("{WEIBO_BASE}/detail/{idstr}"))
        .await?;
    Ok(value.to_string())
}

/// 分组时间线.
///
/// One entry point for the three feeds the real client switches between; the
/// endpoint is picked from the `gid` prefix exactly like weibo.com does:
/// `10001*` 全部关注, `11000/11001/11002*` 好友圈, otherwise a custom 分组.
pub async fn feed_timeline(
    client: &WebClient,
    gid: &str,
    since_id: Option<&str>,
    max_id: Option<&str>,
    count: u32,
) -> WebResult<String> {
    let head: String = gid.chars().take(5).collect();
    let endpoint = if head == "10001" {
        "unreadfriendstimeline"
    } else if ["11000", "11001", "11002"].contains(&head.as_str()) {
        "friendstimeline"
    } else {
        "groupstimeline"
    };

    let mut url = format!(
        "{WEIBO_BASE}/ajax/feed/{endpoint}?gid={gid}&refresh=4&count={count}"
    );
    if let Some(v) = since_id.filter(|v| !v.is_empty()) {
        url.push_str(&format!("&since_id={v}"));
    }
    if let Some(v) = max_id.filter(|v| !v.is_empty()) {
        url.push_str(&format!("&max_id={v}"));
    }
    if head != "10001" {
        url.push_str(&format!("&fid={gid}"));
    }

    let value = client.get(&url, WEIBO_BASE).await?;
    Ok(value.to_string())
}

/// 我赞过的微博 — `GET /ajax/statuses/likelist?uid=&page=&with_total=true`.
pub async fn liked_statuses(client: &WebClient, uid: &str, page: u32) -> WebResult<String> {
    let url = format!(
        "{WEIBO_BASE}/ajax/statuses/likelist?uid={uid}&page={page}&with_total=true"
    );
    let value = client.get(&url, &format!("{WEIBO_BASE}/u/{uid}")).await?;
    Ok(value.to_string())
}

/// 谁赞了这条微博 — 详情页「赞」Tab。
/// `GET /ajax/statuses/likeShow?id=&attitude_type=0&attitude_enable=1&page=&count=`
pub async fn status_likers(
    client: &WebClient,
    id: &str,
    page: u32,
    count: u32,
) -> WebResult<String> {
    let url = format!(
        "{WEIBO_BASE}/ajax/statuses/likeShow?id={id}&attitude_type=0&attitude_enable=1&page={page}&count={count}"
    );
    let value = client
        .get(&url, &format!("{WEIBO_BASE}/detail/{id}"))
        .await?;
    Ok(value.to_string())
}

/// 主页内搜索微博 — `GET /ajax/profile/searchblog?uid=&page=&q=`.
pub async fn search_profile(
    client: &WebClient,
    uid: &str,
    q: &str,
    page: u32,
) -> WebResult<String> {
    let url = format!(
        "{WEIBO_BASE}/ajax/profile/searchblog?uid={uid}&page={page}&q={}",
        urlencode(q)
    );
    let value = client.get(&url, &format!("{WEIBO_BASE}/u/{uid}")).await?;
    Ok(value.to_string())
}

/// 新增粉丝 — `GET /ajax/friendships/friends?uid=&page=&count=&type=new_follows&relate=fans`.
pub async fn new_followers(
    client: &WebClient,
    uid: &str,
    page: u32,
    count: u32,
    new_follower_count: u32,
) -> WebResult<String> {
    let url = format!(
        "{WEIBO_BASE}/ajax/friendships/friends?uid={uid}&page={page}&count={count}&type=new_follows&relate=fans&newFollowerCount={new_follower_count}"
    );
    let value = client.get(&url, &format!("{WEIBO_BASE}/u/{uid}")).await?;
    Ok(value.to_string())
}


pub async fn repost(
    client: &WebClient,
    status_id: &str,
    text: &str,
    comment: bool,
) -> WebResult<String> {
    let url = format!("{WEIBO_BASE}/ajax/statuses/repost");
    let form = vec![
        ("id".to_string(), status_id.to_string()),
        ("status".to_string(), text.to_string()),
        ("is_comment".to_string(), if comment { "1" } else { "0" }.to_string()),
        ("_t".to_string(), "0".to_string()),
    ];
    let value = client
        .post_form(&url, &form, &format!("{WEIBO_BASE}/detail/{status_id}"))
        .await?;
    Ok(value.to_string())
}

pub async fn create_comment(client: &WebClient, status_id: &str, text: &str) -> WebResult<String> {
    let url = format!("{WEIBO_BASE}/ajax/comments/create");
    let form = vec![
        ("id".to_string(), status_id.to_string()),
        ("comment".to_string(), text.to_string()),
        ("comment_ori".to_string(), "0".to_string()),
        ("is_repost".to_string(), "0".to_string()),
        ("_t".to_string(), "0".to_string()),
    ];
    let value = client
        .post_form(&url, &form, &format!("{WEIBO_BASE}/detail/{status_id}"))
        .await?;
    Ok(value.to_string())
}

pub async fn publish(
    client: &WebClient,
    text: &str,
    visible: u32,
    pic_ids: &str,
) -> WebResult<String> {
    let url = format!("{WEIBO_BASE}/ajax/statuses/update");
    let form = vec![
        ("status".to_string(), text.to_string()),
        ("visible".to_string(), visible.to_string()),
        ("pics".to_string(), pic_ids.to_string()),
        ("videos".to_string(), String::new()),
        ("_t".to_string(), "0".to_string()),
    ];
    let value = client.post_form(&url, &form, WEIBO_BASE).await?;
    Ok(value.to_string())
}

pub async fn follow(client: &WebClient, uid: &str, undo: bool) -> WebResult<()> {
    let action = if undo { "destroy" } else { "create" };
    let url = format!("{WEIBO_BASE}/ajax/friendships/{action}");
    let form = vec![
        ("uid".to_string(), uid.to_string()),
        ("_t".to_string(), "0".to_string()),
    ];
    client
        .post_form(&url, &form, &format!("{WEIBO_BASE}/u/{uid}"))
        .await?;
    Ok(())
}

/// Uploads one picture and returns the `pid` needed by `publish(pic_ids)`.
///
/// Endpoint and query string are copied from the official web composer:
/// `picupload.weibo.com/interface/pic_upload.php?app=miniblog&s=json&p=1&data=1`.
/// Success is `{"code":"A00006","data":{"pics":[{"pid":"..."}]}}`; the pid is
/// extracted here so callers never have to know that shape.
pub async fn upload_picture(
    client: &WebClient,
    bytes: &[u8],
    filename: &str,
    mime: &str,
) -> WebResult<String> {
    let url = format!(
        "{PIC_BASE}/interface/pic_upload.php?app=miniblog&s=json&p=1&data=1&mime={}&url=weibo.com",
        urlencode(mime)
    );

    let part = reqwest::multipart::Part::bytes(bytes.to_vec())
        .file_name(filename.to_string())
        .mime_str(mime)
        .map_err(|e| WebError::parse(format!("图片类型无法识别：{e}")))?;
    let form = reqwest::multipart::Form::new().part("pic", part);

    let value = client.post_multipart(&url, form, WEIBO_BASE).await?;

    let pid = value
        .pointer("/data/pics/0/pid")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_string();

    if pid.is_empty() {
        let message = value
            .get("message")
            .or_else(|| value.get("code"))
            .and_then(|v| v.as_str())
            .unwrap_or("图片上传失败");
        return Err(WebError::api(message.to_string()));
    }

    Ok(pid)
}

/// Minimal percent-encoding for query values (keeps `A-Za-z0-9-_.~`).
pub fn urlencode(input: &str) -> String {
    let mut out = String::with_capacity(input.len() * 3);
    for byte in input.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*byte as char)
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}
