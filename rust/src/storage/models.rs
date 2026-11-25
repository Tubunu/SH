//! Strongly typed Rust entities for Share Weibo SQLite persistence.
//! 1:1 mapped to GreenDAO 3 models from Share v3.9.6.

use serde::{Deserialize, Serialize};

/// 1. User Account Entity (`USER` table)
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct UserEntity {
    pub id: Option<i64>,
    pub uid: String,
    pub token: String,
    pub parent_type: i32, // 0-OAuth, 1-Web/Cookie, 2-ThirdParty
    pub gsid: Option<String>,
    pub s_value: Option<String>,
    pub i_value: Option<String>,
    pub parent_json: Option<String>,
    pub refresh_token: Option<String>,
    pub expires_in: Option<i64>, // Milliseconds timestamp
    pub name: Option<String>,
    pub avatar: Option<String>,
    pub gender: Option<String>, // "m", "f", "n"
    pub sign: Option<String>,
    pub cover: Option<String>,
    pub account: Option<String>,
    pub password: Option<String>,
    pub ad_token: Option<String>,
    pub cookie: Option<String>,
    pub extra: Option<String>,
}

/// 2. Status Draft Entity (`STATUS_DRAFTS` table)
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct StatusDraftEntity {
    pub id: Option<i64>,
    pub content: String,
    pub date: i64,
    pub urls: Option<String>, // JSON array of local photo file paths
    pub uid: String,
    pub target_status_json: Option<String>,
    pub target_status_id: Option<String>,
    pub target_comment_id: Option<String>,
    pub target_comment_user_name: Option<String>,
    pub target_comment_content: Option<String>,
    pub assign_group_id_str: Option<String>,
    pub assign_group_type: Option<i32>, // 0-Public, 1-Friends, 2-Self, 3-Group
    pub address: Option<String>,        // POI JSON
    pub publish_timing: Option<i64>,
    pub is_comment_origin: Option<i32>,
    pub status: i32, // 0-draft, 1-sending, 2-failed
    pub is_mention: Option<i32>,
    pub state: Option<i32>,
    pub extra: Option<String>,
    pub type_: Option<i32>, // 0-Original, 1-Repost, 2-Comment, 3-Reply
    pub parent_type: Option<i32>,
}

/// 3. Status History Entity (`STATUS_HISTORY` table)
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct StatusHistoryEntity {
    pub id: Option<i64>,
    pub status_id: String,
    pub username: Option<String>,
    pub total_text: Option<String>,
    pub uid: String,
    pub json: String,
    pub create_at: i64,
}

/// 4. Group List Entity (`GROUP_LIST` table)
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct GroupListEntity {
    pub id: Option<i64>,
    pub insert_number: i32,
    pub uid: String,
    pub gid: String,
    pub title: String,
    pub name: Option<String>,
    pub description: Option<String>,
    pub count: Option<i32>,
    pub type_: Option<i32>,
    pub visible: Option<i32>, // 1-visible, 0-hidden
    pub remind: Option<i32>,  // 1-remind, 0-quiet
}

/// 5. Group Member Entity (`GROUP_MEMBER` table)
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct GroupMemberEntity {
    pub id: Option<i64>,
    pub uid: String,
    pub tid: String, // Target member user UID
    pub gid: String, // Group ID
    pub name: Option<String>,
    pub gender: Option<String>,
    pub description: Option<String>,
    pub avatar: Option<String>,
    pub verified: Option<i32>,
    pub verified_type: Option<i32>,
    pub following: Option<i32>,
    pub follow_me: Option<i32>,
    pub is_group_member: Option<i32>,
}

/// 6. Follower / Contact Entity (`FOLLOWER` table)
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct FollowerEntity {
    pub id: Option<i64>,
    pub uid: String,
    pub tid: String,
    pub name: String,
    pub pinyin_name: Option<String>, // For local rapid @ contact autocompletion
    pub gender: Option<String>,
    pub description: Option<String>,
    pub avatar: Option<String>,
    pub verified: Option<i32>,
    pub verified_type: Option<i32>,
    pub following: Option<i32>,
    pub follow_me: Option<i32>,
}

/// 7. Blacklist / Filter Rule Entity (`BLACK_LIST` table)
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct BlackListEntity {
    pub id: Option<i64>,
    pub key: String, // Target UID, keyword, or tail string
    pub uid: String,
    pub info: Option<String>,
    pub type_: i32,       // 0-User, 1-Keyword, 2-Source (tail)
    pub state: i32,       // 1-Active, 0-Disabled
    pub black_type: i32,  // 1-Hide completely, 2-Fold
}

/// 8. User Search and Visit History Entity (`USER_HISTORY` table)
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct UserHistoryEntity {
    pub id: Option<i64>,
    pub target_uid: String,
    pub target_user_name: String,
    pub target_user_avatar: Option<String>,
    pub uid: String,
    pub json: Option<String>,
    pub visit_count: i64,
    pub create_at: i64,
}

/// 9. Generic Structured JSON Cache Entity (`SHARE_JSON` table)
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct ShareJsonEntity {
    pub model: String, // Cache Key
    pub json: String,  // Cached JSON string
}
