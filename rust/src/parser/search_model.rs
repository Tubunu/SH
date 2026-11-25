use serde::{Deserialize, Serialize};
use crate::parser::status_model::{StatusModel, UserModel};
use crate::parser::social_model::TopicModel;

/// Real-time Hot Search Item (热搜条目)
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct HotSearchItemModel {
    /// 1-based rank position (1..=50)
    pub rank: u32,
    /// Hot search keyword/title
    pub keyword: String,
    /// Optional badge tag: "沸", "热", "新", "商", "荐", etc.
    pub tag: Option<String>,
    /// Search count / popularity heat number
    pub search_num: Option<u64>,
    /// Optional icon URL
    pub icon_url: Option<String>,
    /// Whether this is a pinned top search
    pub is_pinned: bool,
}

/// Search Result Container across tabs
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SearchResultModel {
    pub category: String,
    pub query: String,
    pub page: u32,
    pub has_more: bool,
    pub statuses: Vec<StatusModel>,
    pub users: Vec<UserModel>,
    pub topics: Vec<TopicModel>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_hot_search_item_serialization() {
        let item = HotSearchItemModel {
            rank: 1,
            keyword: "神舟十九号载人飞船发射圆满成功".to_string(),
            tag: Some("沸".to_string()),
            search_num: Some(4982310),
            icon_url: None,
            is_pinned: false,
        };

        let json = serde_json::to_string(&item).unwrap();
        let parsed: HotSearchItemModel = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.rank, 1);
        assert_eq!(parsed.keyword, "神舟十九号载人飞船发射圆满成功");
        assert_eq!(parsed.tag.as_deref(), Some("沸"));
        assert_eq!(parsed.search_num, Some(4982310));
    }

    #[test]
    fn test_search_result_container() {
        let res = SearchResultModel {
            category: "all".to_string(),
            query: "Share微博".to_string(),
            page: 1,
            has_more: true,
            statuses: vec![],
            users: vec![],
            topics: vec![],
        };
        assert_eq!(res.category, "all");
        assert!(res.has_more);
    }
}
