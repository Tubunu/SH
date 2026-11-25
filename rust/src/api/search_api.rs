//! Search API wrappers exposed to Flutter front-end.

use crate::api::timeline_api::get_client;
use crate::parser::search_model::{HotSearchItemModel, SearchResultModel};

/// Fetches real-time Hot Search ranking (1..=50).
pub async fn api_fetch_hot_search() -> Result<Vec<HotSearchItemModel>, String> {
    let client = get_client()?;
    client
        .fetch_hot_search()
        .await
        .map_err(|e| format!("Fetch hot search failed: {e}"))
}

/// Searches Weibo across categories ("all", "user", "status", "pic", "video", "topic").
pub async fn api_search_weibo(
    query: &str,
    category: &str,
    page: u32,
) -> Result<SearchResultModel, String> {
    let client = get_client()?;
    client
        .search_weibo(query, category, page)
        .await
        .map_err(|e| format!("Search failed: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_search_api_uninitialized() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            // When client not initialized, returns clear error
            let res = api_fetch_hot_search().await;
            assert!(res.is_err());
        });
    }
}
