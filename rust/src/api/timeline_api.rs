//! Timeline Network & Cache APIs exposed to Flutter.

use std::sync::OnceLock;

use crate::api::auth_api::get_session;
use crate::api::storage_api::get_db;
use crate::crypto::ua::DeviceContext;
use crate::net::weibo_client::WeiboClient;
use crate::parser::status_model::TimelineResponse;

static GLOBAL_CLIENT: OnceLock<WeiboClient> = OnceLock::new();

/// Initializes or returns the global WeiboClient instance.
pub fn get_client() -> Result<&'static WeiboClient, String> {
    if let Some(c) = GLOBAL_CLIENT.get() {
        return Ok(c);
    }

    let device = DeviceContext::default();
    let session = get_session().ok().cloned();
    let db = get_db().ok().cloned();

    let client = WeiboClient::new(device, session, db);
    let _ = GLOBAL_CLIENT.set(client);

    GLOBAL_CLIENT
        .get()
        .ok_or_else(|| "Failed to initialize global WeiboClient".to_string())
}

/// Fetches home timeline from remote network with automatic signing.
pub async fn fetch_home_timeline(
    since_id: Option<String>,
    max_id: Option<String>,
    count: Option<u32>,
    page: Option<u32>,
) -> Result<TimelineResponse, String> {
    let client = get_client()?;
    client
        .fetch_home_timeline(
            since_id.as_deref(),
            max_id.as_deref(),
            count,
            page,
        )
        .await
        .map_err(|e| e.to_string())
}

/// Loads cached timeline from local SQLite storage.
pub fn get_cached_timeline(uid: &str) -> Option<TimelineResponse> {
    let client = get_client().ok()?;
    client.get_cached_timeline(uid)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_client_init() {
        assert!(get_client().is_ok());
    }
}
