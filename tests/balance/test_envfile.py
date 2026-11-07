import os

from balance import envfile


def test_parse_skips_comments_strips_quotes_expands_home():
    v = envfile.parse('# c\nA=1\nB="two words"\n\nC=~/x\nnot a line\n')
    assert v == {"A": "1", "B": "two words", "C": os.path.expanduser("~/x")}


def test_load_never_overrides_the_environment(tmp_path, monkeypatch):
    p = tmp_path / "host.env"; p.write_text("WL_T_A=file\nWL_T_B=file\n")
    monkeypatch.setenv("WL_T_A", "env")
    monkeypatch.delenv("WL_T_B", raising=False)
    applied = envfile.load(str(p))
    assert applied == {"WL_T_B": "file"} and os.environ["WL_T_A"] == "env"
    monkeypatch.delenv("WL_T_B")


def test_missing_file_is_fine(tmp_path):
    assert envfile.load(str(tmp_path / "nope.env")) == {}
