//! Status Publishing and Repost APIs exposed to Flutter.

use crate::api::timeline_api::get_client;
use crate::parser::status_model::{StatusModel, TimelineResponse};

/// Publishes a new status to Weibo with optional images, POI, and visibility settings.
pub async fn publish_status(
    content: String,
    pic_paths: Vec<String>,
    poi: Option<String>,
    visible_type: i32,
) -> Result<StatusModel, String> {
    let client = get_client()?;
    client
        .publish_status(&content, pic_paths, poi, visible_type)
        .await
        .map_err(|e| e.to_string())
}

/// Fetches status repost timeline.
pub async fn fetch_reposts(
    id: String,
    page: i64,
    count: i64,
) -> Result<TimelineResponse, String> {
    let client = get_client()?;
    client
        .fetch_reposts(&id, page, count)
        .await
        .map_err(|e| e.to_string())
}
