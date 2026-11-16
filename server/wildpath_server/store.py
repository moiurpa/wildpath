"""SQLite storage for animal reports.

SQLite keeps the prototype to one file with no setup. When report volume
grows, the same tables move to PostgreSQL + PostGIS (see README).
"""

import hashlib
import math
import sqlite3
import threading
from datetime import datetime, timedelta, timezone

from .sun import period_at

SPECIES = {
    "deer", "moose", "bear",
    "raccoon", "skunk", "squirrel", "porcupine", "opossum", "woodchuck",
    "rabbit", "chipmunk", "fox", "coyote", "bobcat", "fisher", "beaver", "otter",
    "turtle", "frog", "salamander", "snake",
    "turkey", "bird", "catOrDog", "unknown",
}
SOURCES = {"carplay", "phone", "siri", "camera", "web"}

# A second report of the same animal: same spot and within a few hours.
DUPLICATE_RADIUS_M = 50
DUPLICATE_WINDOW = timedelta(hours=6)
# Reports per device per hour before the server stops accepting more.
RATE_LIMIT_PER_HOUR = 120
# GPS fixes worse than this can't be placed on the right road.
MAX_ACCURACY_M = 200
MAX_AGE = timedelta(days=30)
MAX_FUTURE = timedelta(minutes=10)
# Grid for hotspot cells: about 550 m x 560 m in Vermont.
CELL_LAT = 0.005
CELL_LON = 0.007

SCHEMA = """
CREATE TABLE IF NOT EXISTS reports (
    id            TEXT PRIMARY KEY,
    reporter_hash TEXT NOT NULL,
    species       TEXT NOT NULL,
    lat           REAL NOT NULL,
    lon           REAL NOT NULL,
    accuracy_m    REAL,
    speed_mps     REAL,
    course_deg    REAL,
    observed_at   TEXT NOT NULL,
    received_at   TEXT NOT NULL,
    source        TEXT NOT NULL,
    confidence    REAL,
    status        TEXT NOT NULL,   -- new | unverified | confirmed | duplicate
    duplicate_of  TEXT,
    month         INTEGER NOT NULL,
    period        TEXT NOT NULL,   -- dawn | day | dusk | night
    cell          TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS reports_latlon ON reports (lat, lon);
CREATE INDEX IF NOT EXISTS reports_cell ON reports (cell);
CREATE INDEX IF NOT EXISTS reports_reporter ON reports (reporter_hash, received_at);
"""

# Statuses that count toward maps and hotspots. Camera reports stay
# "unverified" until a person reports the same animal.
COUNTED = ("new", "confirmed")


def iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(value: str) -> datetime:
    dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def meters_between(lat1, lon1, lat2, lon2) -> float:
    r = 6371000
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def cell_of(lat: float, lon: float) -> str:
    return f"{math.floor(lat / CELL_LAT)}:{math.floor(lon / CELL_LON)}"


class Store:
    def __init__(self, path: str, salt: str):
        self.salt = salt
        self.lock = threading.Lock()
        self.conn = sqlite3.connect(path, check_same_thread=False)
        self.conn.row_factory = sqlite3.Row
        if path != ":memory:":
            self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.executescript(SCHEMA)

    def reporter_hash(self, reporter_id: str) -> str:
        """Store a salted hash, never the device ID itself."""
        return hashlib.sha256((self.salt + reporter_id).encode()).hexdigest()[:32]

    # ---- Writing ----------------------------------------------------------

    def ingest(self, reporter_id: str, reports: list[dict], now: datetime) -> list[dict]:
        rh = self.reporter_hash(reporter_id)
        results = []
        with self.lock, self.conn:
            recent = self.conn.execute(
                "SELECT COUNT(*) FROM reports WHERE reporter_hash = ? AND received_at > ?",
                (rh, iso(now - timedelta(hours=1))),
            ).fetchone()[0]
            for r in reports:
                result = self._ingest_one(rh, r, now, recent)
                if result["status"] in ("accepted", "duplicate"):
                    recent += 1
                results.append(result)
        return results

    def _ingest_one(self, rh: str, r: dict, now: datetime, recent: int) -> dict:
        rid = str(r["id"]).lower()
        if self.conn.execute("SELECT 1 FROM reports WHERE id = ?", (rid,)).fetchone():
            return {"id": rid, "status": "already_received"}

        reason = self._reject_reason(r, now, recent)
        if reason:
            return {"id": rid, "status": "rejected", "reason": reason}

        lat, lon = r["latitude"], r["longitude"]
        observed = r["observedAt"]
        species = r["species"] if r["species"] in SPECIES else "unknown"
        source = r["source"]
        status = "unverified" if source == "camera" else "new"

        duplicate_of = self._find_duplicate(species, lat, lon, observed)
        if duplicate_of:
            original = duplicate_of
            # A person confirming a camera detection upgrades the original.
            if source != "camera" and original["status"] == "unverified":
                self.conn.execute("UPDATE reports SET status = 'confirmed' WHERE id = ?", (original["id"],))
            status = "duplicate"

        self.conn.execute(
            """INSERT INTO reports (id, reporter_hash, species, lat, lon, accuracy_m, speed_mps,
               course_deg, observed_at, received_at, source, confidence, status, duplicate_of,
               month, period, cell) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (rid, rh, species, lat, lon, r.get("horizontalAccuracy"), r.get("speedMetersPerSecond"),
             r.get("courseDegrees"), iso(observed), iso(now), source, r.get("confidence"), status,
             duplicate_of["id"] if duplicate_of else None,
             observed.month, period_at(lat, lon, observed), cell_of(lat, lon)),
        )
        if duplicate_of:
            return {"id": rid, "status": "duplicate", "duplicateOf": duplicate_of["id"]}
        return {"id": rid, "status": "accepted"}

    def _reject_reason(self, r: dict, now: datetime, recent: int):
        if recent >= RATE_LIMIT_PER_HOUR:
            return "too_many_reports"
        if r["source"] not in SOURCES:
            return "unknown_source"
        acc = r.get("horizontalAccuracy")
        if acc is not None and (acc < 0 or acc > MAX_ACCURACY_M):
            return "location_not_accurate_enough"
        observed = r["observedAt"]
        if observed > now + MAX_FUTURE:
            return "observed_in_future"
        if observed < now - MAX_AGE:
            return "too_old"
        return None

    def _find_duplicate(self, species: str, lat: float, lon: float, observed: datetime):
        dlat = DUPLICATE_RADIUS_M / 111_000
        dlon = dlat / max(math.cos(math.radians(lat)), 0.01)
        rows = self.conn.execute(
            """SELECT id, species, lat, lon, status FROM reports
               WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?
                 AND observed_at BETWEEN ? AND ? AND status != 'duplicate'
               ORDER BY observed_at""",
            (lat - dlat, lat + dlat, lon - dlon, lon + dlon,
             iso(observed - DUPLICATE_WINDOW), iso(observed + DUPLICATE_WINDOW)),
        ).fetchall()
        for row in rows:
            same_animal = species == row["species"] or "unknown" in (species, row["species"])
            if same_animal and meters_between(lat, lon, row["lat"], row["lon"]) <= DUPLICATE_RADIUS_M:
                return dict(row)
        return None

    # ---- Reading ----------------------------------------------------------

    def reports_in(self, bbox, since: datetime, species=None, include_unverified=False):
        min_lon, min_lat, max_lon, max_lat = bbox
        statuses = COUNTED + (("unverified",) if include_unverified else ())
        sql = f"""SELECT id, species, lat, lon, observed_at, source, status, period FROM reports
                  WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ? AND observed_at >= ?
                    AND status IN ({",".join("?" * len(statuses))})"""
        args = [min_lat, max_lat, min_lon, max_lon, iso(since), *statuses]
        if species:
            sql += f" AND species IN ({','.join('?' * len(species))})"
            args += species
        sql += " ORDER BY observed_at DESC LIMIT 5000"
        with self.lock:
            return [dict(r) for r in self.conn.execute(sql, args)]

    def hotspots(self, bbox, species=None, months=None, period=None, min_count=2):
        min_lon, min_lat, max_lon, max_lat = bbox
        sql = f"""SELECT cell, species, period, lat, lon FROM reports
                  WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?
                    AND status IN ({",".join("?" * len(COUNTED))})"""
        args = [min_lat, max_lat, min_lon, max_lon, *COUNTED]
        if species:
            sql += f" AND species IN ({','.join('?' * len(species))})"
            args += species
        if months:
            sql += f" AND month IN ({','.join('?' * len(months))})"
            args += months
        if period:
            sql += " AND period = ?"
            args.append(period)
        with self.lock:
            rows = self.conn.execute(sql, args).fetchall()

        cells = {}
        for row in rows:
            c = cells.setdefault(row["cell"], {"count": 0, "lat": 0.0, "lon": 0.0,
                                               "species": {}, "periods": {}})
            c["count"] += 1
            c["lat"] += row["lat"]
            c["lon"] += row["lon"]
            c["species"][row["species"]] = c["species"].get(row["species"], 0) + 1
            c["periods"][row["period"]] = c["periods"].get(row["period"], 0) + 1

        out = []
        for key, c in cells.items():
            if c["count"] < min_count:
                continue
            out.append({
                "cell": key,
                "count": c["count"],
                "center": [round(c["lat"] / c["count"], 5), round(c["lon"] / c["count"], 5)],
                "species": dict(sorted(c["species"].items(), key=lambda kv: -kv[1])),
                "periods": c["periods"],
            })
        out.sort(key=lambda h: -h["count"])
        return out

    def stats(self):
        with self.lock:
            q = lambda sql: [dict(r) for r in self.conn.execute(sql, COUNTED)]
            where = f"WHERE status IN ({','.join('?' * len(COUNTED))})"
            return {
                "total": self.conn.execute(f"SELECT COUNT(*) FROM reports {where}", COUNTED).fetchone()[0],
                "bySpecies": q(f"SELECT species, COUNT(*) AS count FROM reports {where} GROUP BY species ORDER BY count DESC"),
                "byMonth": q(f"SELECT month, COUNT(*) AS count FROM reports {where} GROUP BY month ORDER BY month"),
                "byPeriod": q(f"SELECT period, COUNT(*) AS count FROM reports {where} GROUP BY period"),
                "bySource": q(f"SELECT source, COUNT(*) AS count FROM reports {where} GROUP BY source"),
            }
