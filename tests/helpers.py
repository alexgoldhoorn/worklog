import openpyxl


def book(tmp_path, log_rows, meta=None, clients=None, workday=None):
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "log"
    ws.append(["date", "start", "end", "project", "type", "Client", "Billable", "work_type"])
    for r in log_rows:
        ws.append(r)
    if meta is not None:
        m = wb.create_sheet("meta")
        m.append(["break types"])
        for x in meta:
            m.append([x])
    if clients is not None:
        c = wb.create_sheet("clients")
        c.append(["Abrev", "Name"])
        for x in clients:
            c.append(list(x))
    if workday is not None:
        w = wb.create_sheet("Workday")
        w.append(["year", "week", "year-week", "workdays", "workhours", "sick hours", "comment"])
        for y, wk, wd, hours, sick, com in workday:
            w.append([y, wk, f"{y}-{wk:02d}", wd, hours, sick, com])
    p = tmp_path / "t.xlsx"
    wb.save(p)
    return p


def cal(tmp_path, rows):
    import sqlite3
    p = tmp_path / "wc.db"
    c = sqlite3.connect(p)
    c.execute("CREATE TABLE events (id INTEGER PRIMARY KEY, date TEXT, start TEXT, end TEXT, title TEXT, organizer TEXT DEFAULT '', status TEXT DEFAULT 'confirmed', note TEXT DEFAULT '', source TEXT DEFAULT '', updated_at TEXT)")
    c.executemany("INSERT INTO events(date,start,end,title,status) VALUES (?,?,?,?,?)", rows)
    c.commit()
    c.close()
    return str(p)
