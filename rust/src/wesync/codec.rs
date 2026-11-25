//! WeSync binary protocol frame codec and packet parser.
//!
//! WeSync Protocol Frame Format:
//! +----------------+---------------+---------------+------------------+------------------+
//! | Magic (2 B)    | Cmd (2 B)     | Seq (4 B)     | Body Len (4 B)   | Body (N B)       |
//! | 0x77, 0x62      | BigEndian u16 | BigEndian u32 | BigEndian u32    | Payload          |
//! +----------------+---------------+---------------+------------------+------------------+

use serde::{Deserialize, Serialize};
use thiserror::Error;

pub const WESYNC_MAGIC: [u8; 2] = [0x77, 0x62]; // "wb"
pub const HEADER_SIZE: usize = 12;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u16)]
pub enum WeSyncCommand {
    Handshake = 11,
    Auth = 13,
    LoginBindUid = 15,
    Heartbeat = 17,
    ServerPush = 19,
    Disconnect = 20,
    DynamicHeartbeat = 35,
    Unknown(u16),
}

impl From<u16> for WeSyncCommand {
    fn from(val: u16) -> Self {
        match val {
            11 => Self::Handshake,
            13 => Self::Auth,
            15 => Self::LoginBindUid,
            17 => Self::Heartbeat,
            19 => Self::ServerPush,
            20 => Self::Disconnect,
            35 => Self::DynamicHeartbeat,
            other => Self::Unknown(other),
        }
    }
}

impl From<WeSyncCommand> for u16 {
    fn from(cmd: WeSyncCommand) -> Self {
        match cmd {
            WeSyncCommand::Handshake => 11,
            WeSyncCommand::Auth => 13,
            WeSyncCommand::LoginBindUid => 15,
            WeSyncCommand::Heartbeat => 17,
            WeSyncCommand::ServerPush => 19,
            WeSyncCommand::Disconnect => 20,
            WeSyncCommand::DynamicHeartbeat => 35,
            WeSyncCommand::Unknown(c) => c,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WeSyncFrame {
    pub cmd: WeSyncCommand,
    pub seq: u32,
    pub payload: Vec<u8>,
}

#[derive(Error, Debug, PartialEq, Eq)]
pub enum WeSyncError {
    #[error("Buffer too short: expected at least {expected} bytes, got {actual}")]
    BufferTooShort { expected: usize, actual: usize },
    #[error("Invalid magic: expected [0x77, 0x62], got [{0:#04x}, {1:#04x}]")]
    InvalidMagic(u8, u8),
    #[error("Invalid payload length: expected {expected}, actual {actual}")]
    PayloadLengthMismatch { expected: usize, actual: usize },
    #[error("JSON parse error: {0}")]
    JsonParse(String),
}

impl WeSyncFrame {
    /// Creates a new WeSync frame.
    pub fn new(cmd: WeSyncCommand, seq: u32, payload: Vec<u8>) -> Self {
        Self { cmd, seq, payload }
    }

    /// Encodes the frame into raw bytes conforming to the WeSync wire format.
    pub fn encode(&self) -> Vec<u8> {
        let mut buf = Vec::with_capacity(HEADER_SIZE + self.payload.len());
        // 1. Magic
        buf.extend_from_slice(&WESYNC_MAGIC);
        // 2. Cmd
        let cmd_val: u16 = self.cmd.into();
        buf.extend_from_slice(&cmd_val.to_be_bytes());
        // 3. Seq
        buf.extend_from_slice(&self.seq.to_be_bytes());
        // 4. Body Length
        let body_len = self.payload.len() as u32;
        buf.extend_from_slice(&body_len.to_be_bytes());
        // 5. Payload
        buf.extend_from_slice(&self.payload);
        buf
    }

    /// Decodes a frame from raw bytes, returning the parsed frame and consumed byte count.
    pub fn decode(buf: &[u8]) -> Result<(Self, usize), WeSyncError> {
        if buf.len() < HEADER_SIZE {
            return Err(WeSyncError::BufferTooShort {
                expected: HEADER_SIZE,
                actual: buf.len(),
            });
        }

        // Validate Magic
        if buf[0] != WESYNC_MAGIC[0] || buf[1] != WESYNC_MAGIC[1] {
            return Err(WeSyncError::InvalidMagic(buf[0], buf[1]));
        }

        let cmd = u16::from_be_bytes([buf[2], buf[3]]).into();
        let seq = u32::from_be_bytes([buf[4], buf[5], buf[6], buf[7]]);
        let body_len = u32::from_be_bytes([buf[8], buf[9], buf[10], buf[11]]) as usize;

        let total_len = HEADER_SIZE + body_len;
        if buf.len() < total_len {
            return Err(WeSyncError::BufferTooShort {
                expected: total_len,
                actual: buf.len(),
            });
        }

        let payload = buf[HEADER_SIZE..total_len].to_vec();
        Ok((WeSyncFrame { cmd, seq, payload }, total_len))
    }

    /// Attempts to parse MPS JSON push message when cmd is ServerPush (19).
    pub fn parse_push_payload(&self) -> Result<MpsPushPayload, WeSyncError> {
        let text = std::str::from_utf8(&self.payload)
            .map_err(|e| WeSyncError::JsonParse(format!("Invalid UTF-8: {e}")))?;
        serde_json::from_str(text)
            .map_err(|e| WeSyncError::JsonParse(format!("JSON parse error: {e}")))
    }
}

/// MPS JSON Push Message Payload delivered by Cmd 19.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MpsPushPayload {
    /// Push message type ("dm", "notification", "status_sync", etc.)
    #[serde(default)]
    pub msg_type: String,

    /// Unique message/notification ID
    #[serde(default)]
    pub id: i64,

    /// Sender UID
    #[serde(default)]
    pub sender_uid: String,

    /// Sender Nickname
    #[serde(default)]
    pub sender_name: String,

    /// Text content / excerpt
    #[serde(default)]
    pub content: String,

    /// Created timestamp epoch seconds
    #[serde(default)]
    pub timestamp: i64,

    /// Unread count badge if present
    #[serde(default)]
    pub unread_count: Option<i32>,

    /// Extra metadata
    #[serde(default)]
    pub extra: Option<serde_json::Value>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_wesync_encode_decode_roundtrip() {
        let frame = WeSyncFrame::new(
            WeSyncCommand::Heartbeat,
            1001,
            b"PING".to_vec(),
        );

        let encoded = frame.encode();
        assert_eq!(encoded.len(), HEADER_SIZE + 4);
        assert_eq!(&encoded[0..2], &[0x77, 0x62]);
        assert_eq!(u16::from_be_bytes([encoded[2], encoded[3]]), 17);
        assert_eq!(u32::from_be_bytes([encoded[4], encoded[5], encoded[6], encoded[7]]), 1001);
        assert_eq!(u32::from_be_bytes([encoded[8], encoded[9], encoded[10], encoded[11]]), 4);

        let (decoded, consumed) = WeSyncFrame::decode(&encoded).unwrap();
        assert_eq!(consumed, encoded.len());
        assert_eq!(decoded.cmd, WeSyncCommand::Heartbeat);
        assert_eq!(decoded.seq, 1001);
        assert_eq!(decoded.payload, b"PING");
    }

    #[test]
    fn test_wesync_invalid_magic() {
        let buf = vec![0x00, 0x00, 0, 11, 0, 0, 0, 1, 0, 0, 0, 0];
        let err = WeSyncFrame::decode(&buf).unwrap_err();
        assert_eq!(err, WeSyncError::InvalidMagic(0x00, 0x00));
    }

    #[test]
    fn test_wesync_buffer_too_short() {
        let buf = vec![0x77, 0x62, 0, 11];
        let err = WeSyncFrame::decode(&buf).unwrap_err();
        match err {
            WeSyncError::BufferTooShort { expected, actual } => {
                assert_eq!(expected, HEADER_SIZE);
                assert_eq!(actual, 4);
            }
            _ => panic!("Expected BufferTooShort"),
        }
    }

    #[test]
    fn test_mps_json_push_parsing() {
        let json = r#"{
            "msg_type": "dm",
            "id": 987654321,
            "sender_uid": "20001",
            "sender_name": "极客小张",
            "content": "你好，收到新的私信回复！",
            "timestamp": 1720000000,
            "unread_count": 3
        }"#;

        let frame = WeSyncFrame::new(
            WeSyncCommand::ServerPush,
            42,
            json.as_bytes().to_vec(),
        );

        let mps = frame.parse_push_payload().unwrap();
        assert_eq!(mps.msg_type, "dm");
        assert_eq!(mps.id, 987654321);
        assert_eq!(mps.sender_name, "极客小张");
        assert_eq!(mps.content, "你好，收到新的私信回复！");
        assert_eq!(mps.unread_count, Some(3));
    }
}
