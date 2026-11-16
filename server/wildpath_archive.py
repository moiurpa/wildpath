"""Copy WildPath reports from Supabase into the permanent archive on this computer.

Supabase holds the live reports so the app works while this computer is off.
Each time this runs (every hour, by a schedule on the Mac), it copies every new
report into a SQLite file here. It never changes or deletes anything in
Supabase unless you ask it to with --trim-days.

Settings live outside the repo, in ~/.wildpath/archive.json:
    {"supabase_url": "https://xxxx.supabase.co", "secret_key": "sb_secret_..."}

Run by hand:
    python3 server/wildpath_archive.py              copy new reports
    python3 server/wildpath_archive.py --status     show how many reports are archived
    python3 server/wildpath_archive.py --csv FILE   export the archive as a spreadsheet
    python3 server/wildpath_archive.py --trim-days 365
        also delete reports older than 365 days from Supabase, but only ones
        already safe in the archive (use this only when Supabase gets full)
"""

import argparse
import csv
import json
import sqlite3
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from wildpath_server.sun import period_at  # noqa: E402

SETTINGS = Path.home() / ".wildpath" / "archive.json"
# In the home folder, not Documents or Desktop: macOS blocks scheduled jobs from those.
DEFAULT_DB = Path.home() / "WildPath Archive" / "wildpath-archive.db"
PAGE = 1000

COLUMNS = ["id", "reporter_hash", "species", "lat", "lon", "accuracy_m", "speed_mps", "course_deg",
           "observed_at", "received_at", "source", "confidence", "status", "duplicate_of",
           "month", "period", "cell", "app_version", "still_there_votes", "gone_votes", "cleared_at"]
# Values that can change after a report arrives ("Still there?" answers, camera confirmations).
CHANGING = ["status", "still_there_votes", "gone_votes", "cleared_at"]
NUMERIC = ("lat", "lon", "accuracy_m", "speed_mps", "course_deg", "confidence", "month",
           "still_there_votes", "gone_votes")

SCHEMA = f"""
CREATE TABLE IF NOT EXISTS reports (
    {", ".join(c + (" REAL" if c in NUMERIC else " TEXT") for c in COLUMNS)},
    period_sun  TEXT,      -- dawn/day/dusk/night worked out here from real sunrise and sunset
    archived_at TEXT NOT NULL,
    PRIMARY KEY (id)
);
CREATE INDEX IF NOT EXISTS reports_received ON reports (received_at);
CREATE TABLE IF NOT EXISTS runs (
    ran_at TEXT NOT NULL, copied INTEGER NOT NULL, updated INTEGER NOT NULL, trimmed INTEGER NOT NULL, note TEXT
);
"""


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def load_settings():
    if not SETTINGS.exists():
        sys.exit(f"Missing {SETTINGS}. It needs supabase_url and secret_key.")
    s = json.loads(SETTINGS.read_text())
    return s["supabase_url"].rstrip("/"), s["secret_key"]


class Supabase:
    def __init__(self, url, key):
        self.url, self.key = url, key

    def _request(self, method, path, query):
        full = f"{self.url}/rest/v1/{path}?{urllib.parse.urlencode(query, safe=',.():*')}"
        req = urllib.request.Request(full, method=method, headers={
            "apikey": self.key, "Accept": "application/json", "Prefer": "return=representation"})
        with urllib.request.urlopen(req, timeout=60) as res:
            body = res.read()
            return json.loads(body) if body else []

    def reports_since(self, received_after):
        """Every report received at or after this time, oldest first, in pages."""
        cursor = received_after
        seen = set()
        while True:
            rows = self._request("GET", "reports", {
                "select": ",".join(COLUMNS), "received_at": f"gte.{cursor}",
                "order": "received_at.asc,id.asc", "limit": PAGE})
            fresh = [r for r in rows if r["id"] not in seen]
            yield from fresh
            seen.update(r["id"] for r in fresh)
            if len(rows) < PAGE:
                return
            cursor = rows[-1]["received_at"]
            if not fresh:  # more than a page with the same timestamp; step past it
                return

    def delete_older_than(self, cutoff_iso):
        rows = self._request("DELETE", "reports", {"received_at": f"lt.{cutoff_iso}", "select": "id"})
        return len(rows)


def open_archive(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path)
    db.row_factory = sqlite3.Row
    db.executescript(SCHEMA)
    have = {r["name"] for r in db.execute("PRAGMA table_info(reports)")}
    for c in COLUMNS:  # archives made before a column existed
        if c not in have:
            db.execute(f"ALTER TABLE reports ADD COLUMN {c} {'REAL' if c in NUMERIC else 'TEXT'}")
    return db


def sun_period(row):
    try:
        observed = datetime.fromisoformat(row["observed_at"].replace("Z", "+00:00"))
        return period_at(float(row["lat"]), float(row["lon"]), observed)
    except Exception:
        return None


def copy_new(db, sb):
    last = db.execute("SELECT MAX(received_at) FROM reports").fetchone()[0] or "1970-01-01T00:00:00Z"
    copied = updated = 0
    stamp = now_iso()
    for row in sb.reports_since(last):
        values = [row.get(c) for c in COLUMNS]
        if db.execute("SELECT 1 FROM reports WHERE id = ?", (row["id"],)).fetchone():
            updated += update_changing(db, row)
            continue
        db.execute(f"INSERT INTO reports ({', '.join(COLUMNS)}, period_sun, archived_at) "
                   f"VALUES ({', '.join('?' * (len(COLUMNS) + 2))})", values + [sun_period(row), stamp])
        copied += 1
    db.commit()
    return copied, updated


def update_changing(db, row):
    """Copy values that can change later (status, "Still there?" votes, cleared)."""
    sets = " OR ".join(f"{c} IS NOT ?" for c in CHANGING)
    cur = db.execute(f"UPDATE reports SET {', '.join(c + ' = ?' for c in CHANGING)} WHERE id = ? AND ({sets})",
                     [row.get(c) for c in CHANGING] + [row["id"]] + [row.get(c) for c in CHANGING])
    return cur.rowcount


def refresh_statuses(db, sb, days=14):
    """Pick up later changes (confirmations, "Still there?" answers) for recent reports."""
    since = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    updated = sum(update_changing(db, row) for row in sb.reports_since(since))
    db.commit()
    return updated


def trim(db, sb, days):
    cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    newest = db.execute("SELECT MAX(received_at) FROM reports").fetchone()[0]
    if not newest or newest < cutoff:
        print("Not trimming: the archive is not caught up past the cutoff yet.")
        return 0
    return sb.delete_older_than(cutoff)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", type=Path, default=DEFAULT_DB)
    ap.add_argument("--status", action="store_true")
    ap.add_argument("--csv", type=Path)
    ap.add_argument("--trim-days", type=int)
    args = ap.parse_args()

    db = open_archive(args.db)

    if args.status:
        total = db.execute("SELECT COUNT(*) FROM reports").fetchone()[0]
        last = db.execute("SELECT ran_at, copied, note FROM runs ORDER BY ran_at DESC LIMIT 1").fetchone()
        print(f"Archive: {args.db}")
        print(f"Reports archived: {total}")
        print(f"Last run: {dict(last) if last else 'never'}")
        return

    if args.csv:
        rows = db.execute("SELECT * FROM reports ORDER BY observed_at").fetchall()
        with open(args.csv, "w", newline="") as f:
            w = csv.writer(f)
            cols = [c for c in rows[0].keys() if c != "reporter_hash"] if rows else COLUMNS
            w.writerow(cols)
            for r in rows:
                w.writerow([r[c] for c in cols])
        print(f"Wrote {len(rows)} reports to {args.csv}")
        return

    sb = Supabase(*load_settings())
    try:
        copied, updated = copy_new(db, sb)
        updated += refresh_statuses(db, sb)
        trimmed = trim(db, sb, args.trim_days) if args.trim_days else 0
        note = "ok"
    except Exception as e:  # keep a record of failures, e.g. no internet
        copied = updated = trimmed = 0
        note = f"error: {e}"
    db.execute("INSERT INTO runs VALUES (?, ?, ?, ?, ?)", (now_iso(), copied, updated, trimmed, note))
    db.commit()
    print(f"{now_iso()} copied {copied}, updated {updated}, trimmed {trimmed}, {note}")
    if note != "ok":
        sys.exit(1)


if __name__ == "__main__":
    main()
