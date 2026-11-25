//! Social, Topic, Direct Message, and Notification APIs exposed to Flutter.

use crate::api::timeline_api::get_client;
use crate::parser::social_model::{
    DmConversationModel, DmMessageModel, NotificationModel, TopicModel, TopicSignInResult,
};
use crate::parser::status_model::UserModel;
use crate::wesync::WeSyncFrame;

/// Fetches user profile metadata.
pub async fn fetch_user_profile(uid: String) -> Result<UserModel, String> {
    let client = get_client()?;
    client.fetch_user_profile(&uid).await.map_err(|e| e.to_string())
}

/// Follows a user.
pub async fn follow_user(uid: String) -> Result<bool, String> {
    let client = get_client()?;
    client.follow_user(&uid).await.map_err(|e| e.to_string())
}

/// Unfollows a user.
pub async fn unfollow_user(uid: String) -> Result<bool, String> {
    let client = get_client()?;
    client.unfollow_user(&uid).await.map_err(|e| e.to_string())
}

/// Fetches Super Topic (超话) details.
pub async fn fetch_topic_detail(topic_name: String) -> Result<TopicModel, String> {
    let client = get_client()?;
    client.fetch_topic_detail(&topic_name).await.map_err(|e| e.to_string())
}

/// Signs in (打卡签到) to a Super Topic.
pub async fn sign_in_topic(topic_id: String) -> Result<TopicSignInResult, String> {
    let client = get_client()?;
    client.sign_in_topic(&topic_id).await.map_err(|e| e.to_string())
}

/// Fetches active Direct Message conversations.
pub async fn fetch_dm_conversations() -> Result<Vec<DmConversationModel>, String> {
    let client = get_client()?;
    client.fetch_dm_conversations().await.map_err(|e| e.to_string())
}

/// Fetches messages in a Direct Message conversation.
pub async fn fetch_dm_messages(uid: String) -> Result<Vec<DmMessageModel>, String> {
    let client = get_client()?;
    client.fetch_dm_messages(&uid).await.map_err(|e| e.to_string())
}

/// Sends a direct message to a user.
pub async fn send_dm(uid: String, text: String) -> Result<DmMessageModel, String> {
    let client = get_client()?;
    client.send_dm(&uid, &text).await.map_err(|e| e.to_string())
}

/// Fetches notifications by type (0: @微博, 1: @评论, 2: 收到的评论, 3: 收到的赞).
pub async fn fetch_notifications(notify_type: i32) -> Result<Vec<NotificationModel>, String> {
    let client = get_client()?;
    client.fetch_notifications(notify_type).await.map_err(|e| e.to_string())
}

/// Encodes a WeSync binary frame.
pub fn encode_wesync_frame(cmd: u16, seq: u32, payload: Vec<u8>) -> Vec<u8> {
    let frame = WeSyncFrame::new(cmd.into(), seq, payload);
    frame.encode()
}

/// Decodes raw bytes into a WeSync frame.
pub fn decode_wesync_frame(bytes: &[u8]) -> Result<(u16, u32, Vec<u8>), String> {
    let (frame, _) = WeSyncFrame::decode(bytes).map_err(|e| e.to_string())?;
    let cmd_val: u16 = frame.cmd.into();
    Ok((cmd_val, frame.seq, frame.payload))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wesync::WeSyncCommand;

    #[test]
    fn test_wesync_api_bridge() {
        let payload = b"Hello WeSync".to_vec();
        let encoded = encode_wesync_frame(WeSyncCommand::Heartbeat.into(), 100, payload.clone());
        let (cmd, seq, dec_payload) = decode_wesync_frame(&encoded).unwrap();
        assert_eq!(cmd, 17);
        assert_eq!(seq, 100);
        assert_eq!(dec_payload, payload);
    }
}
