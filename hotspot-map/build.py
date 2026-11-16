"""Build the Vermont Wildlife Road Risk map.

Reads Vermont ANR's "VT Wildlife Crossing Value" road segments
(data/vt-wildlife-crossing-value.gpkg), converts them to compact web data,
finds the longest high-value stretches, and writes a single self-contained
index.html from template.html.

Usage:  python3 build.py
Needs:  pip install pyproj shapely
Source: https://s3.us-east-2.amazonaws.com/vtopendata-prd/_Other/BiodiversityEcosystems/vt-wildlife-crossing-value.gpkg
        (listed on the Vermont Open Geodata Portal, geodata.vermont.gov)
"""

import json
import re
import sqlite3
import struct
from pathlib import Path

from pyproj import Transformer
from shapely import wkb

HERE = Path(__file__).parent
GPKG = HERE / "data" / "vt-wildlife-crossing-value.gpkg"
LEAFLET_CSS = HERE / "vendor" / "leaflet-1.9.4.css"
TEMPLATE = HERE / "template.html"
OUT_HTML = HERE / "index.html"
OUT_JSON = HERE / "data" / "segments.json"
# The iPhone app bundles the same road data for hotspot warnings.
APP_JSON = HERE.parent / "ios" / "WildPath" / "Resources" / "hotspot-segments.json"
WEB_JSON = HERE.parent / "web" / "data" / "hotspot-segments.json"

SIMPLIFY_METERS = 12      # drop vertices that move the line less than this
HOTSPOT_MIN_SCORE = 8.5   # stretches at or above this go in the top list
METERS_PER_MILE = 1609.344

# Vermont State Plane (meters) -> GPS lat/lon
to_wgs84 = Transformer.from_crs(32145, 4326, always_xy=True)

ROUTE_RE = re.compile(r"^([IUVS])(\d{3})([A-Z]?)-?(\d{4})?([NSEW]?)(R\d{3}[A-Z]?)?$")


def route_name(code: str) -> str:
    """Turn a VTrans route code like 'U007-0215' into 'US 7'."""
    m = ROUTE_RE.match(code or "")
    if not m:
        return code or "Unknown road"
    kind, num, letter, _town, _dir, ramp = m.groups()
    number = f"{int(num)}{letter}"
    if kind == "I":
        name = f"I-{number}"
    elif kind == "U":
        name = f"US {number}"
    elif kind == "V":
        name = f"VT {number}"
    else:
        return "State-owned road"
    return f"{name} ramp" if ramp else name


def gpkg_to_wkb(blob: bytes) -> bytes:
    """Strip the GeoPackage header to get plain WKB."""
    flags = blob[3]
    envelope_bytes = {0: 0, 1: 32, 2: 48, 3: 48, 4: 64}[(flags >> 1) & 0b111]
    return blob[8 + envelope_bytes:]


def encode_line(coords):
    """Delta-encode lat/lon at 5 decimals (about 1 m) to keep the page small."""
    out, prev_lat, prev_lon = [], 0, 0
    for lon, lat in coords:
        ilat, ilon = round(lat * 1e5), round(lon * 1e5)
        out += [ilat - prev_lat, ilon - prev_lon]
        prev_lat, prev_lon = ilat, ilon
    return out


def main():
    db = sqlite3.connect(GPKG)
    rows = db.execute(
        "SELECT OBJECTID, SHAPE, LR_TWN, F_MM, T_MM, WCV_MASTER FROM Ecologic_WCV_line"
    ).fetchall()

    routes, route_index = [], {}
    segments, raw = [], []
    total_miles = 0.0
    skipped = 0

    for oid, shape, code, f_mm, t_mm, score in rows:
        geom = wkb.loads(gpkg_to_wkb(shape))
        if geom.is_empty:
            skipped += 1
            continue
        miles = geom.length / METERS_PER_MILE
        total_miles += miles
        simple = geom.simplify(SIMPLIFY_METERS, preserve_topology=False)
        parts = list(simple.geoms) if simple.geom_type.startswith("Multi") else [simple]

        name = route_name(code)
        if name not in route_index:
            route_index[name] = len(routes)
            routes.append(name)

        lines = []
        for part in parts:
            xs, ys = zip(*part.coords)
            lons, lats = to_wgs84.transform(xs, ys)
            lines.append(encode_line(zip(lons, lats)))

        segments.append([
            score,
            route_index[name],
            round(f_mm, 2),
            round(t_mm, 2),
            lines,
        ])
        raw.append((code, name, f_mm, t_mm, score, miles, geom))

    # Longest continuous high-value stretches on the same route.
    raw.sort(key=lambda r: (r[0], r[2]))
    stretches, current = [], None
    for code, name, f_mm, t_mm, score, miles, geom in raw:
        if score < HOTSPOT_MIN_SCORE:
            current = None
            continue
        if current and current["code"] == code and abs(current["to"] - f_mm) < 0.02:
            current["to"] = t_mm
            current["miles"] += miles
            current["scores"].append((score, miles))
            current["geoms"].append(geom)
        else:
            current = {"code": code, "name": name, "from": f_mm, "to": t_mm,
                       "miles": miles, "scores": [(score, miles)], "geoms": [geom]}
            stretches.append(current)

    top = []
    for s in sorted(stretches, key=lambda s: s["miles"], reverse=True)[:12]:
        minx = min(g.bounds[0] for g in s["geoms"]); miny = min(g.bounds[1] for g in s["geoms"])
        maxx = max(g.bounds[2] for g in s["geoms"]); maxy = max(g.bounds[3] for g in s["geoms"])
        (w, e), (south, north) = to_wgs84.transform([minx, maxx], [miny, maxy])
        avg = sum(sc * mi for sc, mi in s["scores"]) / max(s["miles"], 1e-9)
        top.append({
            "name": s["name"],
            "fromMM": round(s["from"], 2),
            "toMM": round(s["to"], 2),
            "miles": round(s["miles"], 2),
            "avgScore": round(avg, 2),
            "bounds": [[round(south, 5), round(w, 5)], [round(north, 5), round(e, 5)]],
        })

    scores = [s[0] for s in segments]
    data = {
        "source": "Vermont Agency of Natural Resources, VT Wildlife Crossing Value (Vermont Open Geodata Portal)",
        "segmentCount": len(segments),
        "totalMiles": round(total_miles, 1),
        "scoreMin": min(scores),
        "scoreMax": max(scores),
        "routes": routes,
        "segments": segments,
        "topStretches": top,
    }

    payload = json.dumps(data, separators=(",", ":"))
    OUT_JSON.write_text(payload)
    APP_JSON.write_text(payload)
    WEB_JSON.write_text(payload)

    html = TEMPLATE.read_text()
    html = html.replace("/*__LEAFLET_CSS__*/", LEAFLET_CSS.read_text())
    html = html.replace("/*__DATA__*/null", payload)
    OUT_HTML.write_text(html)

    print(f"skipped {skipped} empty segments")
    print(f"{len(segments)} segments, {total_miles:.0f} road miles, {len(routes)} route names")
    print(f"index.html: {OUT_HTML.stat().st_size / 1e6:.2f} MB")
    for t in top[:5]:
        print("  top:", t["name"], t["fromMM"], "-", t["toMM"], f'{t["miles"]} mi', "avg", t["avgScore"])


if __name__ == "__main__":
    main()
