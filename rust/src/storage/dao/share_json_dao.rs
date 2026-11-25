//! Data Access Object for `SHARE_JSON` table.
//! Universal key-value structured cache for feeds, topics, cardlists, and user profiles.

use rusqlite::params;

use crate::storage::db::{DatabaseManager, StorageError};

pub struct ShareJsonDao<'a> {
    db: &'a DatabaseManager,
}

impl<'a> ShareJsonDao<'a> {
    pub fn new(db: &'a DatabaseManager) -> Self {
        Self { db }
    }

    /// Stores or replaces a JSON cache item under the given model key.
    pub fn put(&self, model: &str, json: &str) -> Result<(), StorageError> {
        self.db.with_conn(|conn| {
            conn.execute(
                "INSERT INTO \"SHARE_JSON\" (\"MODEL\", \"JSON\") VALUES (?1, ?2)
                 ON CONFLICT(\"MODEL\") DO UPDATE SET \"JSON\" = excluded.\"JSON\";",
                params![model, json],
            )?;
            Ok(())
        })
    }

    /// Retrieves cached JSON content by model key.
    pub fn get(&self, model: &str) -> Result<Option<String>, StorageError> {
        self.db.with_conn(|conn| {
            let mut stmt = conn.prepare("SELECT \"JSON\" FROM \"SHARE_JSON\" WHERE \"MODEL\" = ?1 LIMIT 1;")?;
            let mut rows = stmt.query(params![model])?;
            if let Some(row) = rows.next()? {
                let json: String = row.get(0)?;
                Ok(Some(json))
            } else {
                Ok(None)
            }
        })
    }

    /// Deletes a cache entry by model key.
    pub fn delete(&self, model: &str) -> Result<bool, StorageError> {
        self.db.with_conn(|conn| {
            let affected = conn.execute("DELETE FROM \"SHARE_JSON\" WHERE \"MODEL\" = ?1;", params![model])?;
            Ok(affected > 0)
        })
    }

    /// Deletes all cache entries matching a key prefix.
    pub fn delete_by_prefix(&self, prefix: &str) -> Result<usize, StorageError> {
        let pattern = format!("{}%", prefix);
        self.db.with_conn(|conn| {
            let affected = conn.execute(
                "DELETE FROM \"SHARE_JSON\" WHERE \"MODEL\" LIKE ?1;",
                params![pattern],
            )?;
            Ok(affected)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_share_json_cache() {
        let db = DatabaseManager::open_in_memory().unwrap();
        let dao = ShareJsonDao::new(&db);

        assert!(dao.get("feed_cache_1001").unwrap().is_none());

        dao.put("feed_cache_1001", "{\"statuses\":[1,2,3]}").unwrap();
        let fetched = dao.get("feed_cache_1001").unwrap().unwrap();
        assert_eq!(fetched, "{\"statuses\":[1,2,3]}");

        // Overwrite
        dao.put("feed_cache_1001", "{\"statuses\":[4,5,6]}").unwrap();
        let overwritten = dao.get("feed_cache_1001").unwrap().unwrap();
        assert_eq!(overwritten, "{\"statuses\":[4,5,6]}");

        // Delete
        assert!(dao.delete("feed_cache_1001").unwrap());
        assert!(dao.get("feed_cache_1001").unwrap().is_none());
    }
}
