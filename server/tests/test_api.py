import uuid
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from wildpath_server.main import create_app
from wildpath_server.store import RATE_LIMIT_PER_HOUR
from wildpath_server.sun import period_at

NOW = datetime(2026, 11, 16, 22, 0, tzinfo=timezone.utc)  # about 5 pm in Vermont
VT_BBOX = "-73.5,42.7,-71.4,45.1"
# A spot on VT 105, Vermont
LAT, LON = 44.9100, -72.2000


@pytest.fixture
def client():
    return TestClient(create_app(db_path=":memory:", salt="test", clock=lambda: NOW))


def report(**overrides):
    r = {
        "id": str(uuid.uuid4()).upper(),  # the iPhone app sends upper-case UUIDs
        "species": "raccoon",
        "latitude": LAT,
        "longitude": LON,
        "horizontalAccuracy": 8.0,
        "speedMetersPerSecond": 22.0,
        "courseDegrees": 90.0,
        "observedAt": (NOW - timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": "carplay",
        "uploaded": False,  # the app sends this; the server ignores it
    }
    r.update(overrides)
    return r


def upload(client, *reports, reporter="device-0001"):
    res = client.post("/v1/reports", json={"reporterID": reporter, "appVersion": "0.1.0",
                                           "reports": list(reports)})
    assert res.status_code == 200, res.text
    return res.json()["results"]


def test_accepts_a_report_and_serves_it_as_a_pin(client):
    [result] = upload(client, report())
    assert result["status"] == "accepted"
    pins = client.get("/v1/reports", params={"bbox": VT_BBOX}).json()["features"]
    assert len(pins) == 1
    props = pins[0]["properties"]
    assert props["species"] == "raccoon"
    assert props["period"] == "dusk"
    assert "reporter" not in str(pins[0]).lower()


def test_same_report_sent_twice_is_not_counted_twice(client):
    r = report()
    upload(client, r)
    [again] = upload(client, r)
    assert again["status"] == "already_received"


def test_second_driver_reporting_same_animal_is_a_duplicate(client):
    upload(client, report(), reporter="device-aaaa1")
    [second] = upload(client, report(latitude=LAT + 0.0002), reporter="device-bbbb2")  # ~22 m away
    assert second["status"] == "duplicate"
    pins = client.get("/v1/reports", params={"bbox": VT_BBOX}).json()["features"]
    assert len(pins) == 1


def test_different_animal_nearby_is_not_a_duplicate(client):
    upload(client, report(species="raccoon"))
    [second] = upload(client, report(species="skunk"), reporter="device-bbbb2")
    assert second["status"] == "accepted"


def test_camera_report_is_hidden_until_a_person_confirms_it(client):
    upload(client, report(source="camera", confidence=0.82, species="deer"))
    params = {"bbox": VT_BBOX}
    assert client.get("/v1/reports", params=params).json()["features"] == []
    shown = client.get("/v1/reports", params={**params, "include_unverified": True}).json()["features"]
    assert shown[0]["properties"]["status"] == "unverified"

    upload(client, report(species="deer"), reporter="device-person")
    [pin] = client.get("/v1/reports", params=params).json()["features"]
    assert pin["properties"]["status"] == "confirmed"


@pytest.mark.parametrize("change,reason", [
    ({"horizontalAccuracy": 900.0}, "location_not_accurate_enough"),
    ({"observedAt": "2026-12-01T00:00:00Z"}, "observed_in_future"),
    ({"observedAt": "2026-09-01T00:00:00Z"}, "too_old"),
    ({"source": "email"}, "unknown_source"),
])
def test_rejects_bad_reports_with_a_reason(client, change, reason):
    [result] = upload(client, report(**change))
    assert result == {"id": result["id"], "status": "rejected", "reason": reason}


def test_unknown_species_is_stored_as_not_sure(client):
    upload(client, report(species="smallMammal"))
    [pin] = client.get("/v1/reports", params={"bbox": VT_BBOX}).json()["features"]
    assert pin["properties"]["species"] == "unknown"


def test_invalid_coordinates_are_refused(client):
    res = client.post("/v1/reports", json={"reporterID": "device-0001",
                                           "reports": [report(latitude=123.0)]})
    assert res.status_code == 422


def test_rate_limit_per_device(client):
    batch = [report(latitude=LAT + i * 0.01) for i in range(RATE_LIMIT_PER_HOUR + 3)]
    results = upload(client, *batch)
    statuses = [r["status"] for r in results]
    assert statuses.count("accepted") == RATE_LIMIT_PER_HOUR
    assert statuses[-1] == "rejected"
    assert results[-1]["reason"] == "too_many_reports"


def test_hotspots_group_reports_into_cells(client):
    # Three separate animals on one stretch (more than 50 m apart, so not duplicates)
    upload(client,
           report(species="raccoon", latitude=LAT, longitude=LON),
           report(species="skunk", latitude=LAT + 0.0010, longitude=LON),
           report(species="raccoon", latitude=LAT + 0.0020, longitude=LON + 0.0010))
    # One lone report far away
    upload(client, report(latitude=43.5, longitude=-72.9), reporter="device-other")

    cells = client.get("/v1/hotspots", params={"bbox": VT_BBOX}).json()["cells"]
    assert len(cells) == 1
    hot = cells[0]
    assert hot["count"] == 3
    assert hot["species"] == {"raccoon": 2, "skunk": 1}
    assert hot["periods"] == {"dusk": 3}

    filtered = client.get("/v1/hotspots", params={"bbox": VT_BBOX, "species": "skunk", "min_count": 1}).json()
    assert [c["count"] for c in filtered["cells"]] == [1]
    assert client.get("/v1/hotspots", params={"bbox": VT_BBOX, "months": "6"}).json()["cells"] == []


def test_bbox_is_validated(client):
    assert client.get("/v1/reports", params={"bbox": "nonsense"}).status_code == 400
    assert client.get("/v1/reports", params={"bbox": "-130,20,-60,50"}).status_code == 400


def test_stats(client):
    upload(client, report(species="raccoon"), report(species="deer", latitude=LAT + 0.01))
    stats = client.get("/v1/stats").json()
    assert stats["total"] == 2
    assert {s["species"] for s in stats["bySpecies"]} == {"raccoon", "deer"}


@pytest.mark.parametrize("utc,expected", [
    ("2026-11-16T17:00:00", "day"),    # noon in Vermont
    ("2026-11-16T21:30:00", "dusk"),   # sunset is about 4:25 pm
    ("2026-11-17T05:00:00", "night"),  # midnight
    ("2026-11-16T11:50:00", "dawn"),   # sunrise is about 6:45 am
    ("2026-06-21T00:45:00", "dusk"),   # June sunset falls on the next UTC day
])
def test_periods_in_vermont(utc, expected):
    when = datetime.fromisoformat(utc).replace(tzinfo=timezone.utc)
    assert period_at(44.0, -72.7, when) == expected


def test_serves_the_web_app_and_its_config(client):
    page = client.get("/")
    assert page.status_code == 200 and "Report a dead animal" in page.text
    assert client.get("/config.js").text.startswith("window.WILDPATH_CONFIG")
    assert client.get("/data/hotspot-segments.json").status_code == 200


def test_accepts_reports_from_the_web_app(client):
    [result] = upload(client, report(source="web", horizontalAccuracy=None, speedMetersPerSecond=None, courseDegrees=None))
    assert result["status"] == "accepted"
