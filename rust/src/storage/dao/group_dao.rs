//! Data Access Object for `GROUP_LIST` and `GROUP_MEMBER` tables.
//! Manages custom groups, group ordering, visibility flags, and group members.

use rusqlite::{params, Row};

use crate::storage::db::{DatabaseManager, StorageError};
use crate::storage::models::{GroupListEntity, GroupMemberEntity};

pub struct GroupDao<'a> {
    db: &'a DatabaseManager,
}

impl<'a> GroupDao<'a> {
    pub fn new(db: &'a DatabaseManager) -> Self {
        Self { db }
    }

    fn row_to_group(row: &Row) -> rusqlite::Result<GroupListEntity> {
        Ok(GroupListEntity {
            id: row.get(0)?,
            insert_number: row.get(1)?,
            uid: row.get(2)?,
            gid: row.get(3)?,
            title: row.get(4)?,
            name: row.get(5)?,
            description: row.get(6)?,
            count: row.get(7)?,
            type_: row.get(8)?,
            visible: row.get(9)?,
            remind: row.get(10)?,
        })
    }

    fn row_to_member(row: &Row) -> rusqlite::Result<GroupMemberEntity> {
        Ok(GroupMemberEntity {
            id: row.get(0)?,
            uid: row.get(1)?,
            tid: row.get(2)?,
            gid: row.get(3)?,
            name: row.get(4)?,
            gender: row.get(5)?,
            description: row.get(6)?,
            avatar: row.get(7)?,
            verified: row.get(8)?,
            verified_type: row.get(9)?,
            following: row.get(10)?,
            follow_me: row.get(11)?,
            is_group_member: row.get(12)?,
        })
    }

    // ------------------------------------------------------------------------
    // Group List
    // ------------------------------------------------------------------------

    /// Atomically replaces all groups for a user with the provided list.
    pub fn replace_all_groups(
        &self,
        uid: &str,
        groups: &[GroupListEntity],
    ) -> Result<(), StorageError> {
        self.db.with_conn_mut(|conn| {
            let tx = conn.transaction()?;
            tx.execute(
                "DELETE FROM \"GROUP_LIST\" WHERE \"UID\" = ?1;",
                params![uid],
            )?;

            for (idx, g) in groups.iter().enumerate() {
                tx.execute(
                    "INSERT INTO \"GROUP_LIST\" (
                        \"INSERT_NUMBER\", \"UID\", \"GID\", \"TITLE\", \"NAME\",
                        \"DESCRIPTION\", \"COUNT\", \"TYPE\", \"VISIBLE\", \"REMIND\"
                    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10);",
                    params![
                        idx as i32,
                        uid,
                        g.gid,
                        g.title,
                        g.name,
                        g.description,
                        g.count,
                        g.type_,
                        g.visible.unwrap_or(1),
                        g.remind.unwrap_or(0),
                    ],
                )?;
            }

            tx.commit()?;
            Ok(())
        })
    }

    /// Queries groups for a user, optionally filtering for visible ones.
    pub fn get_groups(
        &self,
        uid: &str,
        only_visible: bool,
    ) -> Result<Vec<GroupListEntity>, StorageError> {
        self.db.with_conn(|conn| {
            let sql = if only_visible {
                "SELECT \"_id\", \"INSERT_NUMBER\", \"UID\", \"GID\", \"TITLE\", \"NAME\",
                        \"DESCRIPTION\", \"COUNT\", \"TYPE\", \"VISIBLE\", \"REMIND\"
                 FROM \"GROUP_LIST\"
                 WHERE \"UID\" = ?1 AND \"VISIBLE\" = 1
                 ORDER BY \"INSERT_NUMBER\" ASC;"
            } else {
                "SELECT \"_id\", \"INSERT_NUMBER\", \"UID\", \"GID\", \"TITLE\", \"NAME\",
                        \"DESCRIPTION\", \"COUNT\", \"TYPE\", \"VISIBLE\", \"REMIND\"
                 FROM \"GROUP_LIST\"
                 WHERE \"UID\" = ?1
                 ORDER BY \"INSERT_NUMBER\" ASC;"
            };
            let mut stmt = conn.prepare(sql)?;
            let iter = stmt.query_map(params![uid], |row| Self::row_to_group(row))?;
            let mut list = Vec::new();
            for item in iter {
                list.push(item?);
            }
            Ok(list)
        })
    }

    /// Deletes a specific group.
    pub fn delete_group(&self, uid: &str, gid: &str) -> Result<bool, StorageError> {
        self.db.with_conn(|conn| {
            let affected = conn.execute(
                "DELETE FROM \"GROUP_LIST\" WHERE \"UID\" = ?1 AND \"GID\" = ?2;",
                params![uid, gid],
            )?;
            Ok(affected > 0)
        })
    }

    // ------------------------------------------------------------------------
    // Group Members
    // ------------------------------------------------------------------------

    /// Atomically replaces all members in a group.
    pub fn replace_group_members(
        &self,
        uid: &str,
        gid: &str,
        members: &[GroupMemberEntity],
    ) -> Result<(), StorageError> {
        self.db.with_conn_mut(|conn| {
            let tx = conn.transaction()?;
            tx.execute(
                "DELETE FROM \"GROUP_MEMBER\" WHERE \"UID\" = ?1 AND \"GID\" = ?2;",
                params![uid, gid],
            )?;

            for m in members {
                tx.execute(
                    "INSERT INTO \"GROUP_MEMBER\" (
                        \"UID\", \"TID\", \"GID\", \"NAME\", \"GENDER\",
                        \"DESCRIPTION\", \"AVATAR\", \"VERIFIED\", \"VERIFIED_TYPE\",
                        \"FOLLOWING\", \"FOLLOW_ME\", \"IS_GROUP_MEMBER\"
                    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12);",
                    params![
                        uid,
                        m.tid,
                        gid,
                        m.name,
                        m.gender,
                        m.description,
                        m.avatar,
                        m.verified,
                        m.verified_type,
                        m.following,
                        m.follow_me,
                        m.is_group_member.unwrap_or(1),
                    ],
                )?;
            }

            tx.commit()?;
            Ok(())
        })
    }

    /// Queries members in a group.
    pub fn get_members(
        &self,
        uid: &str,
        gid: &str,
    ) -> Result<Vec<GroupMemberEntity>, StorageError> {
        self.db.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT \"_id\", \"UID\", \"TID\", \"GID\", \"NAME\", \"GENDER\",
                        \"DESCRIPTION\", \"AVATAR\", \"VERIFIED\", \"VERIFIED_TYPE\",
                        \"FOLLOWING\", \"FOLLOW_ME\", \"IS_GROUP_MEMBER\"
                 FROM \"GROUP_MEMBER\"
                 WHERE \"UID\" = ?1 AND \"GID\" = ?2;",
            )?;
            let iter = stmt.query_map(params![uid, gid], |row| Self::row_to_member(row))?;
            let mut list = Vec::new();
            for item in iter {
                list.push(item?);
            }
            Ok(list)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_group_dao_operations() {
        let db = DatabaseManager::open_in_memory().unwrap();
        let dao = GroupDao::new(&db);

        let groups = vec![
            GroupListEntity {
                insert_number: 0,
                uid: "1001001".to_string(),
                gid: "gid_tech".to_string(),
                title: "Tech News".to_string(),
                visible: Some(1),
                ..Default::default()
            },
            GroupListEntity {
                insert_number: 1,
                uid: "1001001".to_string(),
                gid: "gid_hidden".to_string(),
                title: "Secret Group".to_string(),
                visible: Some(0),
                ..Default::default()
            },
        ];

        dao.replace_all_groups("1001001", &groups).unwrap();

        let all = dao.get_groups("1001001", false).unwrap();
        assert_eq!(all.len(), 2);

        let visible_only = dao.get_groups("1001001", true).unwrap();
        assert_eq!(visible_only.len(), 1);
        assert_eq!(visible_only[0].title, "Tech News");
    }
}
