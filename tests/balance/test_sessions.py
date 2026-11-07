"""Session-time sidecar: where a moved run now starts, read by the model and the coach (plan 2, Task 2)."""
from balance import sessions


def test_write_read_and_time_for(tmp_path):
    assert sessions.read(str(tmp_path)) == {}
    row = sessions.write(str(tmp_path), "2026-11-05|Easy Run", "13:00", "14:00")
    assert row["start"] == "13:00" and row["end"] == "14:00" and row["set_at"]
    times = sessions.read(str(tmp_path))
    assert sessions.time_for(times, "2026-11-05", "Easy Run") == row
    assert sessions.time_for(times, "2026-11-06", "Easy Run") is None
    sessions.write(str(tmp_path), "2026-11-05|Easy Run", "07:30", "08:30")
    assert sessions.time_for(sessions.read(str(tmp_path)), "2026-11-05", "Easy Run")["start"] == "07:30"
    assert not list(tmp_path.glob("*.tmp"))                                   # atomic write leaves no temp file
