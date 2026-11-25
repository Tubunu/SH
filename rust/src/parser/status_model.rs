//! Strongly typed Weibo Status and Timeline Models.
//!
//! Fully deserializes Weibo 2.0 API JSON responses (`2/statuses/friends/timeline` and CardList).
//! Supports recursive retweeted statuses, pic info structures, and user profiles.

use serde::{Deserialize, Serialize};

/// Pic URL item in `pic_urls` array
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct PicUrlItem {
    pub thumbnail_pic: String,
}

/// Picture detail variant containing dimensions and direct image URL
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct PicVariant {
    pub url: String,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub cut_type: Option<u32>,
    pub type_: Option<String>,
}

/// Comprehensive image information for multi-resolution rendering
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct PicInfo {
    pub pic_id: Option<String>,
    pub thumbnail: Option<PicVariant>,
    pub bmiddle: Option<PicVariant>,
    pub large: Option<PicVariant>,
    pub original: Option<PicVariant>,
}

/// User profile representation in Weibo status
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct UserModel {
    #[serde(default)]
    pub id: i64,
    #[serde(default)]
    pub idstr: String,
    #[serde(default)]
    pub screen_name: String,
    pub name: Option<String>,
    pub province: Option<String>,
    pub city: Option<String>,
    pub location: Option<String>,
    pub description: Option<String>,
    pub url: Option<String>,
    pub profile_image_url: Option<String>,
    pub avatar_large: Option<String>,
    pub avatar_hd: Option<String>,
    pub cover_image_phone: Option<String>,
    pub gender: Option<String>,
    pub followers_count: Option<i32>,
    pub friends_count: Option<i32>,
    pub statuses_count: Option<i32>,
    pub favourites_count: Option<i32>,
    pub created_at: Option<String>,
    #[serde(default)]
    pub following: bool,
    #[serde(default)]
    pub follow_me: bool,
    #[serde(default)]
    pub verified: bool,
    #[serde(default)]
    pub verified_type: i32, // -1: none, 0: yellow V, 2/3: blue V, 220: gold V
    pub verified_reason: Option<String>,
}

/// Weibo status card data model
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct StatusModel {
    #[serde(default)]
    pub id: i64,
    #[serde(default)]
    pub mid: String,
    pub idstr: Option<String>,
    #[serde(default)]
    pub created_at: String,
    #[serde(default)]
    pub text: String,
    pub source: Option<String>,
    #[serde(default)]
    pub favorited: bool,
    #[serde(default)]
    pub truncated: bool,
    pub in_reply_to_status_id: Option<String>,
    pub in_reply_to_user_id: Option<String>,
    pub in_reply_to_screen_name: Option<String>,
    pub thumbnail_pic: Option<String>,
    pub bmiddle_pic: Option<String>,
    pub original_pic: Option<String>,
    pub user: Option<UserModel>,
    pub retweeted_status: Option<Box<StatusModel>>,
    #[serde(default)]
    pub reposts_count: i32,
    #[serde(default)]
    pub comments_count: i32,
    #[serde(default)]
    pub attitudes_count: i32,
    #[serde(default)]
    pub pic_urls: Vec<PicUrlItem>,
    #[serde(default)]
    pub pic_ids: Vec<String>,
    #[serde(rename = "isLongText", default)]
    pub is_long_text: bool,
    #[serde(default)]
    pub liked: bool,
}

impl StatusModel {
    /// Extracts plain text source name from HTML anchor tag (e.g. `<a href="...">iPhone 16 Pro</a>` -> `iPhone 16 Pro`).
    pub fn clean_source(&self) -> String {
        let src = match &self.source {
            Some(s) => s.as_str(),
            None => return String::new(),
        };

        if let Some(start) = src.find('>') {
            if let Some(end) = src[start + 1..].find('<') {
                return src[start + 1..start + 1 + end].trim().to_string();
            }
        }
        src.trim().to_string()
    }

    /// Resolves list of high quality image URLs for the gallery.
    pub fn resolved_pic_urls(&self) -> Vec<String> {
        if !self.pic_urls.is_empty() {
            self.pic_urls
                .iter()
                .map(|p| {
                    // Replace thumbnail with bmiddle or large
                    p.thumbnail_pic.replace("/thumbnail/", "/bmiddle/")
                })
                .collect()
        } else if let Some(orig) = &self.bmiddle_pic {
            vec![orig.clone()]
        } else if let Some(thumb) = &self.thumbnail_pic {
            vec![thumb.clone()]
        } else {
            Vec::new()
        }
    }
}

/// Standard Timeline Response structure
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct TimelineResponse {
    #[serde(default)]
    pub statuses: Vec<StatusModel>,
    pub total_number: Option<u64>,
    pub since_id: Option<String>,
    pub max_id: Option<String>,
    pub hasvisible: Option<bool>,
    pub previous_cursor: Option<i64>,
    pub next_cursor: Option<i64>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_clean_source() {
        let status = StatusModel {
            source: Some("<a href=\"http://weibo.com/\" rel=\"nofollow\">Share 微博</a>".to_string()),
            ..Default::default()
        };
        assert_eq!(status.clean_source(), "Share 微博");

        let status_plain = StatusModel {
            source: Some("来自 iPhone 16 Pro".to_string()),
            ..Default::default()
        };
        assert_eq!(status_plain.clean_source(), "来自 iPhone 16 Pro");
    }

    #[test]
    fn test_deserialize_sample_status() {
        let json_str = r#"{
            "id": 4629471928471928,
            "mid": "KcmHmzxW0",
            "created_at": "Tue Oct 27 10:15:20 +0800 2026",
            "text": "这是一条测试微博，欢迎来到 Share 1:1 重构工程！ #Flutter# #Rust#",
            "source": "<a href=\"http://weibo.com/\">Share 客户端</a>",
            "reposts_count": 12,
            "comments_count": 34,
            "attitudes_count": 56,
            "pic_urls": [
                {"thumbnail_pic": "https://wx1.sinaimg.cn/thumbnail/001.jpg"}
            ],
            "user": {
                "id": 1001,
                "idstr": "1001",
                "screen_name": "截总",
                "verified": true,
                "verified_type": 0
            }
        }"#;

        let status: StatusModel = serde_json::from_str(json_str).unwrap();
        assert_eq!(status.id, 4629471928471928);
        assert_eq!(status.mid, "KcmHmzxW0");
        assert_eq!(status.clean_source(), "Share 客户端");
        assert_eq!(status.reposts_count, 12);
        assert_eq!(status.comments_count, 34);
        assert_eq!(status.attitudes_count, 56);
        assert_eq!(status.user.as_ref().unwrap().screen_name, "截总");
        assert_eq!(
            status.resolved_pic_urls()[0],
            "https://wx1.sinaimg.cn/bmiddle/001.jpg"
        );
    }
}
