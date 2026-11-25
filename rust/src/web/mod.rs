//! Weibo web API transport layer.
//!
//! - `client`  : cookie-aware HTTP client with Weibo-specific headers
//! - `cookies` : minimal cookie jar + manual import/persistence
//! - `session` : multi-account storage on disk
//! - `api`     : endpoint wrappers (timeline / detail / comments / search ...)

pub mod api;
pub mod client;
pub mod cookies;
pub mod session;
