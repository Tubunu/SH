//! Comment APIs exposed to Flutter.

use crate::api::timeline_api::get_client;
use crate::parser::comment_model::{CommentListResponse, CommentModel};

/// Fetches paginated primary comments for a status.
pub async fn fetch_comments(
    id: String,
    page: i64,
    count: i64,
) -> Result<CommentListResponse, String> {
    let client = get_client()?;
    client
        .fetch_comments(&id, page, count)
        .await
        .map_err(|e| e.to_string())
}

/// Fetches locally cached comments for instant rendering.
pub fn get_cached_comments(id: &str) -> Option<CommentListResponse> {
    let client = get_client().ok()?;
    client.get_cached_comments(id)
}

/// Fetches nested sub-comment / floor replies for a primary comment.
pub async fn fetch_comment_replies(
    cid: String,
    page: i64,
    count: i64,
) -> Result<CommentListResponse, String> {
    let client = get_client()?;
    client
        .fetch_comment_replies(&cid, page, count)
        .await
        .map_err(|e| e.to_string())
}

/// Posts a new comment or replies to an existing comment.
pub async fn post_comment(
    id: String,
    text: String,
    reply_cid: Option<String>,
    is_comment_origin: bool,
) -> Result<CommentModel, String> {
    let client = get_client()?;
    client
        .post_comment(
            &id,
            &text,
            reply_cid.as_deref(),
            is_comment_origin,
        )
        .await
        .map_err(|e| e.to_string())
}
