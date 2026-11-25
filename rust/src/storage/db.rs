//! Thread-safe SQLite Database Manager for Share Weibo.
//!
//! Handles schema creation, PRAGMA optimizations, in-memory testing mode,
//! and synchronized access across asynchronous Tokio tasks.

use std::path::Path;
use std::sync::{Arc, Mutex};
use thiserror::Error;

pub const SCHEMA_SQL: &str = include_str!("schema.sql");

#[derive(Error, Debug)]
pub enum StorageError {
    #[error("Database error: {0}")]
    Rusqlite(#[from] rusqlite::Error),
    #[error("Lock acquisition error")]
    LockError,
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    #[error("Entity not found: {0}")]
    NotFound(String),
    #[error("Serialization error: {0}")]
    Serialization(#[from] serde_json::Error),
    #[error("Storage validation failed: {0}")]
    Validation(String),
}

#[derive(Clone)]
pub struct DatabaseManager {
    conn: Arc<Mutex<rusqlite::Connection>>,
}

impl DatabaseManager {
    /// Opens an in-memory database and executes schema initialization.
    /// Ideal for deterministic, fast unit tests.
    pub fn open_in_memory() -> Result<Self, StorageError> {
        let conn = rusqlite::Connection::open_in_memory()?;
        let db = Self {
            conn: Arc::new(Mutex::new(conn)),
        };
        db.init_pragmas(true)?;
        db.init_schema()?;
        Ok(db)
    }

    /// Opens a persistent SQLite database at the specified file path.
    /// Automatically creates parent directories if they don't exist.
    pub fn open_file<P: AsRef<Path>>(path: P) -> Result<Self, StorageError> {
        let path_ref = path.as_ref();
        if let Some(parent) = path_ref.parent() {
            if !parent.exists() {
                std::fs::create_dir_all(parent)?;
            }
        }

        let conn = rusqlite::Connection::open(path_ref)?;
        let db = Self {
            conn: Arc::new(Mutex::new(conn)),
        };
        db.init_pragmas(false)?;
        db.init_schema()?;
        Ok(db)
    }

    /// Initializes performance and safety PRAGMAs.
    fn init_pragmas(&self, is_memory: bool) -> Result<(), StorageError> {
        let conn = self.conn.lock().map_err(|_| StorageError::LockError)?;
        conn.execute_batch(
            "PRAGMA foreign_keys = ON;
             PRAGMA busy_timeout = 5000;",
        )?;
        if !is_memory {
            conn.execute_batch(
                "PRAGMA journal_mode = WAL;
                 PRAGMA synchronous = NORMAL;",
            )?;
        }
        Ok(())
    }

    /// Executes the 9 core tables DDL script.
    pub fn init_schema(&self) -> Result<(), StorageError> {
        let conn = self.conn.lock().map_err(|_| StorageError::LockError)?;
        conn.execute_batch(SCHEMA_SQL)?;
        Ok(())
    }

    /// Executes a closure with a borrowed connection.
    pub fn with_conn<F, R>(&self, f: F) -> Result<R, StorageError>
    where
        F: FnOnce(&rusqlite::Connection) -> Result<R, StorageError>,
    {
        let conn = self.conn.lock().map_err(|_| StorageError::LockError)?;
        f(&conn)
    }

    /// Executes a closure with a mutable connection.
    pub fn with_conn_mut<F, R>(&self, f: F) -> Result<R, StorageError>
    where
        F: FnOnce(&mut rusqlite::Connection) -> Result<R, StorageError>,
    {
        let mut conn = self.conn.lock().map_err(|_| StorageError::LockError)?;
        f(&mut conn)
    }

    /// Executes an arbitrary SQL command.
    pub fn execute(
        &self,
        sql: &str,
        params: &[&dyn rusqlite::ToSql],
    ) -> Result<usize, StorageError> {
        let conn = self.conn.lock().map_err(|_| StorageError::LockError)?;
        Ok(conn.execute(sql, params)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_in_memory_db_schema_tables() {
        let db = DatabaseManager::open_in_memory().unwrap();
        db.with_conn(|conn| {
            let mut stmt = conn
                .prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;")
                .map_err(StorageError::Rusqlite)?;
            let tables: Vec<String> = stmt
                .query_map([], |row| row.get(0))
                .unwrap()
                .map(|r| r.unwrap())
                .collect();

            assert!(tables.contains(&"USER".to_string()));
            assert!(tables.contains(&"STATUS_DRAFTS".to_string()));
            assert!(tables.contains(&"STATUS_HISTORY".to_string()));
            assert!(tables.contains(&"GROUP_LIST".to_string()));
            assert!(tables.contains(&"GROUP_MEMBER".to_string()));
            assert!(tables.contains(&"FOLLOWER".to_string()));
            assert!(tables.contains(&"BLACK_LIST".to_string()));
            assert!(tables.contains(&"USER_HISTORY".to_string()));
            assert!(tables.contains(&"SHARE_JSON".to_string()));
            Ok(())
        })
        .unwrap();
    }
}
