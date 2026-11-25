//! Strongly-typed Weibo Comment Data Models.
//!
//! Models 1:1 representations of Weibo comment structures from
//! decompiled Share sources (`C5848oo0oOo0O` and `C5847oo0oOo00`).

use serde::{Deserialize, Serialize};
use crate::parser::status_model::UserModel;

/// Represents a single Weibo comment or sub-comment (floor reply).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct CommentModel {
    /// Unique comment ID
    pub id: i64,

    /// Optional root comment ID (for sub-comments / 楼中楼)
    #[serde(default)]
    pub rootid: Option<i64>,

    /// Floor number in the thread (e.g. 1 for #1, 2 for #2)
    #[serde(default)]
    pub floor_number: Option<i64>,

    /// Plain/formatted comment text
    #[serde(default)]
    pub text: String,

    /// Created timestamp string (e.g. "Wed Oct 28 14:20:00 +0800 2026")
    #[serde(default)]
    pub created_at: String,

    /// Cleaned source device string
    #[serde(default)]
    pub source: Option<String>,

    /// Author user model
    #[serde(default)]
    pub user: Option<UserModel>,

    /// Total like count
    #[serde(default, alias = "like_count")]
    pub like_counts: i64,

    /// Whether current user liked this comment
    #[serde(default)]
    pub liked: bool,

    /// Direct parent comment if this is a reply
    #[serde(default)]
    pub reply_comment: Option<Box<CommentModel>>,

    /// Nested sub-comments / 楼中楼 preview list
    #[serde(default, alias = "comments")]
    pub sub_comments: Vec<CommentModel>,

    /// Total number of sub-comments under this comment
    #[serde(default)]
    pub total_number: Option<i64>,

    /// Whether author of the status posted this comment
    #[serde(default)]
    pub is_author: bool,

    /// Whether author of the status liked this comment ("博主赞过")
    #[serde(default, alias = "isLikedByMblogAuthor")]
    pub is_author_liked: bool,

    /// Inline image URLs attached to this comment
    #[serde(default)]
    pub pic_urls: Vec<String>,
}

impl CommentModel {
    /// Returns clean device source by stripping HTML tags.
    pub fn clean_source(&self) -> String {
        match &self.source {
            Some(s) if s.contains('<') => {
                let stripped = s
                    .split('<')
                    .filter_map(|part| part.split_once('>').map(|x| x.1))
                    .collect::<Vec<_>>()
                    .join("");
                if stripped.is_empty() {
                    s.clone()
                } else {
                    stripped
                }
            }
            Some(s) => s.clone(),
            None => String::new(),
        }
    }
}

/// Paginated comment list response from `/2/comments/show` and `/2/comments/build_comments`.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct CommentListResponse {
    /// List of primary comments or sub-comments
    #[serde(default)]
    pub comments: Vec<CommentModel>,

    /// Total comments count
    #[serde(default)]
    pub total_number: i64,

    /// Max ID cursor for pagination
    #[serde(default)]
    pub max_id: Option<i64>,

    /// Since ID cursor
    #[serde(default)]
    pub since_id: Option<i64>,

    /// Root comment object (when querying floor comments)
    #[serde(default, alias = "rootComment")]
    pub root_comment: Option<CommentModel>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_deserialize_comment_with_nested_replies() {
        let json = r#"{
            "total_number": 128,
            "max_id": 4900000002,
            "comments": [
                {
                    "id": 4900000001,
                    "floor_number": 1,
                    "text": "第一条主评：太棒了！",
                    "created_at": "Wed Oct 28 14:20:00 +0800 2026",
                    "source": "<a href=\"http://weibo.com\">来自 iPhone 16 Pro</a>",
                    "like_counts": 42,
                    "liked": true,
                    "isLikedByMblogAuthor": true,
                    "is_author": false,
                    "user": {
                        "id": 10001,
                        "screen_name": "评论博友A",
                        "verified": true,
                        "verified_type": 0
                    },
                    "total_number": 2,
                    "comments": [
                        {
                            "id": 4900000005,
                            "rootid": 4900000001,
                            "text": "回复 @评论博友A: 确实很强！",
                            "created_at": "Wed Oct 28 14:22:00 +0800 2026",
                            "like_counts": 5,
                            "liked": false,
                            "user": {
                                "id": 10002,
                                "screen_name": "二级回复用户B"
                            }
                        }
                    ]
                }
            ]
        }"#;

        let resp: CommentListResponse = serde_json::from_str(json).unwrap();
        assert_eq!(resp.total_number, 128);
        assert_eq!(resp.comments.len(), 1);

        let c = &resp.comments[0];
        assert_eq!(c.id, 4900000001);
        assert_eq!(c.floor_number, Some(1));
        assert_eq!(c.text, "第一条主评：太棒了！");
        assert!(c.liked);
        assert!(c.is_author_liked);
        assert_eq!(c.clean_source(), "来自 iPhone 16 Pro");
        assert_eq!(c.sub_comments.len(), 1);
        assert_eq!(c.sub_comments[0].text, "回复 @评论博友A: 确实很强！");
    }
}
