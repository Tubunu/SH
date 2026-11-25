//! Social Data Models: Super Topics, Direct Messages, and Notifications.

use serde::{Deserialize, Serialize};
use crate::parser::status_model::UserModel;

/// Super Topic (超话) Model.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct TopicModel {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub desc: String,
    #[serde(default)]
    pub banner_url: Option<String>,
    #[serde(default)]
    pub avatar_url: Option<String>,
    #[serde(default)]
    pub rank_badge: Option<String>,
    #[serde(default)]
    pub followers_count: i64,
    #[serde(default)]
    pub posts_count: i64,
    #[serde(default)]
    pub is_signed: bool,
    #[serde(default)]
    pub sign_days: i32,
    #[serde(default)]
    pub sign_rank: Option<i32>,
}

/// Super Topic Check-in (打卡签到) Result.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct TopicSignInResult {
    pub success: bool,
    pub sign_days: i32,
    pub rank: i32,
    pub message: String,
}

/// Direct Message Conversation Summary.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct DmConversationModel {
    pub id: String,
    pub peer_uid: String,
    pub peer_name: String,
    #[serde(default)]
    pub peer_avatar: Option<String>,
    #[serde(default)]
    pub last_message: String,
    #[serde(default)]
    pub timestamp: i64,
    #[serde(default)]
    pub unread_count: i32,
    #[serde(default)]
    pub is_group: bool,
}

/// Individual Direct Message Bubble Entry.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct DmMessageModel {
    pub id: i64,
    pub sender_uid: String,
    pub recipient_uid: String,
    pub text: String,
    pub timestamp: i64,
    #[serde(default)]
    pub is_outgoing: bool,
    #[serde(default)]
    pub is_recalled: bool,
}

/// Interactive Notification Entry (@, comments, attitudes).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct NotificationModel {
    pub id: i64,
    /// 0: @我的微博, 1: @我的评论, 2: 收到的评论, 3: 收到的赞
    pub notify_type: i32,
    #[serde(default)]
    pub sender: Option<UserModel>,
    #[serde(default)]
    pub created_at: String,
    #[serde(default)]
    pub action_text: String,
    #[serde(default)]
    pub target_summary: String,
    #[serde(default)]
    pub target_id: Option<i64>,
}
