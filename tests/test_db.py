from worklog import db


def test_fresh_db_has_schema_and_seeds(conn):
    assert conn.execute("PRAGMA user_version").fetchone()[0] == 4
    assert conn.execute("PRAGMA journal_mode").fetchone()[0] == "wal"
    assert "eat" in db.break_types(conn) and "dev" not in db.break_types(conn)
    assert db.clients(conn)["ACME"]["name"] == "Acme"
    assert db.setting(conn, "default_type") == "dev"
    assert db.setting(conn, "auto_close_time") == "18:00"


def test_block_crud_and_ordering(conn):
    b1 = db.insert_block(conn, db.Block(None, "2026-10-20", "09:00", "10:00", None, "dev", "ACME", True))
    b2 = db.insert_block(conn, db.Block(None, "2026-10-20", "08:00", "09:00", "coffee++", "eat", None, None))
    assert [b.start for b in db.blocks_on(conn, "2026-10-20")] == ["08:00", "09:00"]
    db.update_block(conn, b1, end="11:00", auto_closed=1)
    db.update_block(conn, b1, end="11:30")
    assert db.get_block(conn, b1).auto_closed is False
    db.delete_block(conn, b2)
    assert len(db.blocks_on(conn, "2026-10-20")) == 1


def test_open_block_is_newest_unclosed(conn):
    assert db.open_block(conn) is None
    db.insert_block(conn, db.Block(None, "2026-10-19", "17:00", None, None, "dev", "ACME", True))
    newest = db.insert_block(conn, db.Block(None, "2026-10-20", "09:00", None, None, "dev", "ACME", True))
    assert db.open_block(conn).id == newest


def test_expectations(conn):
    db.set_expectation(conn, db.DayExpectation("2026-10-12", 0, 0, "Festa Nacional", "holiday"))
    assert db.get_expectation(conn, "2026-10-12").reason == "Festa Nacional"
    assert set(db.expectations_between(conn, "2026-10-01", "2026-10-31")) == {"2026-10-12"}
    db.delete_expectation(conn, "2026-10-12")
    assert db.get_expectation(conn, "2026-10-12") is None


def test_connect_twice_is_idempotent(tmp_path):
    p = str(tmp_path / "t.db")
    db.connect(p).close(); c = db.connect(p)
    assert c.execute("select count(*) from break_types").fetchone()[0] == 16


def test_schema_is_v3_with_dismissals(conn):
    assert conn.execute("PRAGMA user_version").fetchone()[0] == 4
    db.dismiss_proposal(conn, "2026-10-20", "09:15", None)
    db.dismiss_proposal(conn, "2026-10-20", "09:15", None)  # idempotent
    assert db.dismissed_on(conn, "2026-10-20") == {("09:15", "")}
    db.undismiss_proposal(conn, "2026-10-20", "09:15", "")
    assert db.dismissed_on(conn, "2026-10-20") == set()


def test_v2_db_upgrades_to_v3(tmp_path):
    p = str(tmp_path / "old.db")
    c = db.connect(p)
    c.execute("DROP TABLE proposal_dismissals")
    c.execute("PRAGMA user_version = 2")
    c.commit()
    c.close()
    c = db.connect(p)
    assert c.execute("PRAGMA user_version").fetchone()[0] == 4
    assert c.execute("SELECT name FROM sqlite_master WHERE name = 'proposal_dismissals'").fetchone() is not None
    c.close()


def test_schema_is_v4_with_pomo_break_type(conn):
    assert conn.execute("PRAGMA user_version").fetchone()[0] == 4
    assert "pomo" in db.break_types(conn)


def test_v3_db_upgrades_to_v4(tmp_path):
    p = str(tmp_path / "old.db")
    c = db.connect(p)
    c.execute("DELETE FROM break_types WHERE name = 'pomo'")
    c.execute("PRAGMA user_version = 3")
    c.commit()
    c.close()
    c = db.connect(p)
    assert c.execute("PRAGMA user_version").fetchone()[0] == 4
    assert "pomo" in db.break_types(c)
    c.close()
