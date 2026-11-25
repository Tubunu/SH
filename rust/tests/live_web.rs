//! Live smoke test against the real Weibo web API.
//!
//! Run with: `cargo test --test live_web -- --ignored --nocapture`
//! Requires network access; it uses an anonymous visitor session so no account
//! credentials are needed.

use share_core::web::api;
use share_core::web::client::WebClient;

#[tokio::test]
#[ignore]
async fn guest_session_can_read_public_timeline() {
    let client = WebClient::new();
    let account = api::guest_login(&client)
        .await
        .expect("guest login should succeed");
    assert!(client.has_session(), "visitor login must install SUB cookie");
    println!("guest cookie count = {}", account.cookie.len());

    let raw = api::hot_timeline(&client, None, 10)
        .await
        .expect("hot timeline should return data");
    let json: serde_json::Value = serde_json::from_str(&raw).unwrap();
    let statuses = json
        .get("statuses")
        .and_then(|v| v.as_array())
        .expect("statuses array");
    assert!(!statuses.is_empty(), "timeline should not be empty");
    println!("fetched {} statuses", statuses.len());

    let first = &statuses[0];
    let mblogid = first
        .get("mblogid")
        .and_then(|v| v.as_str())
        .expect("mblogid");
    let text = first
        .get("text_raw")
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    println!("first post [{mblogid}]: {text:.40}");

    let detail = api::status_show(&client, mblogid)
        .await
        .expect("detail should load");
    let detail_json: serde_json::Value = serde_json::from_str(&detail).unwrap();
    assert_eq!(
        detail_json.get("mblogid").and_then(|v| v.as_str()),
        Some(mblogid)
    );
}

#[tokio::test]
#[ignore]
async fn guest_session_can_read_comments_and_hot_search() {
    let client = WebClient::new();
    api::guest_login(&client).await.expect("guest login");

    let raw = api::hot_timeline(&client, None, 10).await.expect("timeline");
    let json: serde_json::Value = serde_json::from_str(&raw).unwrap();
    let status = &json["statuses"][0];
    let id = status["id"].to_string();
    let uid = status["user"]["id"].to_string();
    let id = id.trim_matches('"').to_string();
    let uid = uid.trim_matches('"').to_string();

    let comments = api::comments(&client, &id, &uid, 0, None, 20)
        .await
        .expect("comments should load");
    let comments_json: serde_json::Value = serde_json::from_str(&comments).unwrap();
    println!(
        "comments total = {:?}",
        comments_json.get("total_number").and_then(|v| v.as_i64())
    );

    let hot = api::hot_search(&client).await.expect("hot search");
    let hot_json: serde_json::Value = serde_json::from_str(&hot).unwrap();
    let realtime = hot_json
        .pointer("/data/realtime")
        .and_then(|v| v.as_array())
        .expect("realtime array");
    assert!(!realtime.is_empty());
    println!(
        "hot search #1 = {}",
        realtime[0].get("word").and_then(|v| v.as_str()).unwrap_or("")
    );
}
