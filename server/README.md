# WildPath server

Collects animal reports from the app and serves them back as map pins and
hotspots. Python (FastAPI) with SQLite.

## Run it

```bash
pip install -r requirements.txt
```

```bash
WILDPATH_SALT="pick-a-long-random-secret" uvicorn wildpath_server.main:app --host 0.0.0.0 --port 8000
```

Interactive API docs: http://localhost:8000/docs. Then set `WildPathServerURL`
in `ios/WildPath/Info.plist` to the server's address.

## Test it

```bash
python3 -m pytest -q
```

## API

| Endpoint | What it does |
|---|---|
| `POST /v1/reports` | Upload reports, same shape the app sends. Answers per report: `accepted`, `duplicate`, `rejected` (with a reason) or `already_received`. |
| `GET /v1/reports?bbox=minLon,minLat,maxLon,maxLat&days=30` | Report pins as GeoJSON. Optional `species=deer,raccoon`, `include_unverified=true`. |
| `GET /v1/hotspots?bbox=…` | Grid cells (about 550 m) with at least `min_count` reports. Optional `species`, `months=10,11`, `period=dusk`. |
| `GET /v1/stats` | Totals by animal, month, time of day and source. |

## Rules built in

- **Privacy:** the device ID is stored only as a salted hash. Public endpoints never return who reported.
- **Duplicates:** the same animal (same kind, within 50 m and 6 hours) counts once. "Not sure" matches any animal.
- **Camera reports** stay `unverified` and off the public map until a person reports the same animal, which marks it `confirmed`.
- **Quality checks:** rejects GPS worse than 200 m, times in the future or older than 30 days, and more than 120 reports per device per hour.
- **Dawn, day, dusk, night** are worked out from real sunrise and sunset at each report's location, so this works anywhere, not only Vermont.

## Next steps

- Host it (any small cloud server, or a container platform) behind HTTPS.
- Move to PostgreSQL + PostGIS when reports reach the hundreds of thousands; the tables carry over as they are.
- Add photo uploads, so report photos can train the camera model.
