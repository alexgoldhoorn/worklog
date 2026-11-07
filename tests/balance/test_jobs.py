"""The job runners start without any host integration and degrade to warnings."""
from datetime import date

from balance.jobs import gate as gate_job


def test_gate_dry_run_on_an_empty_store(tmp_path):
    v = gate_job.run(date(2026, 11, 4), dry_run=False, state_dir=str(tmp_path / "state"), db_path=str(tmp_path / "b.db"))
    assert v.as_dict()["date"] == "2026-11-04"
    assert (tmp_path / "state" / "gate.json").exists()
