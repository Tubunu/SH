//! Data Access Object for `FOLLOWER` table.
//! Manages local follower & following directory for instant `@` mentions search.

use rusqlite::{params, Row};

use crate::storage::db::{DatabaseManager, StorageError};
use crate::storage::models::FollowerEntity;

pub struct FollowerDao<'a> {
    db: &'a DatabaseManager,
}

impl<'a> FollowerDao<'a> {
    pub fn new(db: &'a DatabaseManager) -> Self {
        Self { db }
    }

    fn row_to_entity(row: &Row) -> rusqlite::Result<FollowerEntity> {
        Ok(FollowerEntity {
            id: row.get(0)?,
            uid: row.get(1)?,
            tid: row.get(2)?,
            name: row.get(3)?,
            pinyin_name: row.get(4)?,
            gender: row.get(5)?,
            description: row.get(6)?,
            avatar: row.get(7)?,
            verified: row.get(8)?,
            verified_type: row.get(9)?,
            following: row.get(10)?,
            follow_me: row.get(11)?,
        })
    }

    /// Batch inserts or updates follower records with idempotency.
    pub fn insert_or_replace_batch(
        &self,
        uid: &str,
        followers: &[FollowerEntity],
    ) -> Result<(), StorageError> {
        self.db.with_conn_mut(|conn| {
            let tx = conn.transaction()?;
            for f in followers {
                tx.execute(
                    "INSERT OR REPLACE INTO \"FOLLOWER\" (
                        \"UID\", \"TID\", \"NAME\", \"PINYIN_NAME\", \"GENDER\",
                        \"DESCRIPTION\", \"AVATAR\", \"VERIFIED\", \"VERIFIED_TYPE\",
                        \"FOLLOWING\", \"FOLLOW_ME\"
                    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11);",
                    params![
                        uid,
                        f.tid,
                        f.name,
                        f.pinyin_name,
                        f.gender,
                        f.description,
                        f.avatar,
                        f.verified,
                        f.verified_type,
                        f.following,
                        f.follow_me,
                    ],
                )?;
            }
            tx.commit()?;
            Ok(())
        })
    }

    /// Searches followers by name or pinyin prefix (used in publisher `@` mention popups).
    pub fn search_by_query(
        &self,
        uid: &str,
        query: &str,
        limit: usize,
    ) -> Result<Vec<FollowerEntity>, StorageError> {
        let pattern = format!("%{}%", query);
        self.db.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT \"_id\", \"UID\", \"TID\", \"NAME\", \"PINYIN_NAME\", \"GENDER\",
                        \"DESCRIPTION\", \"AVATAR\", \"VERIFIED\", \"VERIFIED_TYPE\",
                        \"FOLLOWING\", \"FOLLOW_ME\"
                 FROM \"FOLLOWER\"
                 WHERE \"UID\" = ?1 AND (\"NAME\" LIKE ?2 OR \"PINYIN_NAME\" LIKE ?2)
                 ORDER BY \"FOLLOWING\" DESC, \"NAME\" ASC
                 LIMIT ?3;",
            )?;
            let iter = stmt.query_map(params![uid, pattern, limit], |row| {
                Self::row_to_entity(row)
            })?;
            let mut list = Vec::new();
            for item in iter {
                list.push(item?);
            }
            Ok(list)
        })
    }

    /// Lists followers with limit.
    pub fn list_all(&self, uid: &str, limit: usize) -> Result<Vec<FollowerEntity>, StorageError> {
        self.db.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT \"_id\", \"UID\", \"TID\", \"NAME\", \"PINYIN_NAME\", \"GENDER\",
                        \"DESCRIPTION\", \"AVATAR\", \"VERIFIED\", \"VERIFIED_TYPE\",
                        \"FOLLOWING\", \"FOLLOW_ME\"
                 FROM \"FOLLOWER\"
                 WHERE \"UID\" = ?1
                 ORDER BY \"NAME\" ASC
                 LIMIT ?2;",
            )?;
            let iter = stmt.query_map(params![uid, limit], |row| Self::row_to_entity(row))?;
            let mut list = Vec::new();
            for item in iter {
                list.push(item?);
            }
            Ok(list)
        })
    }

    /// Clears all followers for a user.
    pub fn clear_all(&self, uid: &str) -> Result<usize, StorageError> {
        self.db.with_conn(|conn| {
            let affected = conn.execute("DELETE FROM \"FOLLOWER\" WHERE \"UID\" = ?1;", params![uid])?;
            Ok(affected)
        })
    }

    /// Counts followers for a user.
    pub fn count(&self, uid: &str) -> Result<usize, StorageError> {
        self.db.with_conn(|conn| {
            let count: usize = conn.query_row(
                "SELECT COUNT(*) FROM \"FOLLOWER\" WHERE \"UID\" = ?1;",
                params![uid],
                |r| r.get(0),
            )?;
            Ok(count)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_follower_search() {
        let db = DatabaseManager::open_in_memory().unwrap();
        let dao = FollowerDao::new(&db);

        let list = vec![
            FollowerEntity {
                uid: "1001001".to_string(),
                tid: "2001".to_string(),
                name: "张三".to_string(),
                pinyin_name: Some("zhangsan".to_string()),
                following: Some(1),
                ..Default::default()
            },
            FollowerEntity {
                uid: "1001001".to_string(),
                tid: "2002".to_string(),
                name: "李四".to_string(),
                pinyin_name: Some("lisi".to_string()),
                following: Some(1),
                ..Default::default()
            },
        ];

        dao.insert_or_replace_batch("1001001", &list).unwrap();
        assert_eq!(dao.count("1001001").unwrap(), 2);

        // Verify idempotency with duplicate batch insertion
        dao.insert_or_replace_batch("1001001", &list).unwrap();
        assert_eq!(dao.count("1001001").unwrap(), 2);

        // Search by Chinese name
        let res_cn = dao.search_by_query("1001001", "张", 10).unwrap();
        assert_eq!(res_cn.len(), 1);
        assert_eq!(res_cn[0].tid, "2001");

        // Search by Pinyin
        let res_py = dao.search_by_query("1001001", "li", 10).unwrap();
        assert_eq!(res_py.len(), 1);
        assert_eq!(res_py[0].tid, "2002");
    }
}
