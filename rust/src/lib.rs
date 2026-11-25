//! Share Weibo Rust Core Engine.
//!
//! Owns the transport / session / cache layer that powers the Flutter client:
//! cookie authentication, Weibo web API access, multi-account persistence and
//! offline timeline caching.

pub mod api;
pub mod auth;
pub mod crypto;
pub mod net;
pub mod parser;
pub mod storage;
pub mod web;
pub mod wesync;

mod frb_generated;

// Re-export core types and high-level APIs
pub use api::*;
pub use auth::{AccountState, AccountType, SessionManager, TokenBundle, UserAccount};
pub use net::{NetError, WeiboClient};
pub use parser::{
    CommentListResponse, CommentModel, DmConversationModel, DmMessageModel, NotificationModel,
    PicInfo, PicUrlItem, PicVariant, StatusModel, TimelineResponse, TopicModel, TopicSignInResult,
    UserModel,
};
pub use storage::{DatabaseManager, StorageError};
pub use wesync::{
    MpsPushPayload, WeSyncCommand, WeSyncError, WeSyncFrame, HEADER_SIZE, WESYNC_MAGIC,
};
