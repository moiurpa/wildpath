"""WildPath API: collects animal reports from the app and serves them back
as map pins and hotspots.

Run:  uvicorn wildpath_server.main:app --reload
Docs: http://localhost:8000/docs
"""

import json
import os
from pathlib import Path
from datetime import datetime, timedelta, timezone
from typing import Literal, Optional
from uuid import UUID

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from .store import Store, iso

PERIODS = ("dawn", "day", "dusk", "night")
# The web app (WildPath/web) is served from the same address as the API.
WEB_DIR = Path(__file__).resolve().parents[2] / "web"


class ReportIn(BaseModel):
    """One report, in the same shape the iPhone app sends."""
    id: UUID
    species: str = Field(max_length=40)
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    horizontalAccuracy: Optional[float] = None
    speedMetersPerSecond: Optional[float] = Field(default=None, ge=0, le=100)
    courseDegrees: Optional[float] = Field(default=None, ge=0, le=360)
    observedAt: datetime
    source: str = Field(max_length=20)
    confidence: Optional[float] = Field(default=None, ge=0, le=1)


class UploadIn(BaseModel):
    reporterID: str = Field(min_length=8, max_length=64)
    appVersion: str = Field(default="unknown", max_length=20)
    reports: list[ReportIn] = Field(max_length=500)


def parse_bbox(bbox: str):
    try:
        min_lon, min_lat, max_lon, max_lat = (float(v) for v in bbox.split(","))
    except ValueError:
        raise HTTPException(400, "bbox must be minLon,minLat,maxLon,maxLat")
    if not (min_lon < max_lon and min_lat < max_lat):
        raise HTTPException(400, "bbox min values must be smaller than max values")
    if (max_lon - min_lon) * (max_lat - min_lat) > 25:
        raise HTTPException(400, "bbox is too large; zoom in to an area about 5 by 5 degrees or smaller")
    return min_lon, min_lat, max_lon, max_lat


def parse_species(species: Optional[str]):
    return [s for s in species.split(",") if s] if species else None


def create_app(db_path: Optional[str] = None, salt: Optional[str] = None, clock=None) -> FastAPI:
    store = Store(db_path or os.environ.get("WILDPATH_DB", "wildpath.db"),
                  salt or os.environ.get("WILDPATH_SALT", "change-me-in-production"))
    now = clock or (lambda: datetime.now(timezone.utc))

    app = FastAPI(title="WildPath API", version="0.1.0",
                  description="Animal-on-road reports and hotspots.")
    app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["GET", "POST"],
                       allow_headers=["Content-Type"])

    @app.get("/health")
    def health():
        return {"ok": True}

    @app.post("/v1/reports")
    def upload(body: UploadIn):
        """Accept a batch of reports. Always answers per report, so the app
        never retries a report the server has already decided on."""
        reports = []
        for r in body.reports:
            d = r.model_dump()
            obs = d["observedAt"]
            d["observedAt"] = obs if obs.tzinfo else obs.replace(tzinfo=timezone.utc)
            reports.append(d)
        return {"results": store.ingest(body.reporterID, reports, now())}

    @app.get("/v1/reports")
    def reports(bbox: str = Query(..., description="minLon,minLat,maxLon,maxLat"),
                days: int = Query(30, ge=1, le=365),
                species: Optional[str] = Query(None, description="Comma-separated, e.g. deer,raccoon"),
                include_unverified: bool = False):
        """Report pins as GeoJSON. Never includes who reported."""
        rows = store.reports_in(parse_bbox(bbox), now() - timedelta(days=days),
                                parse_species(species), include_unverified)
        return {
            "type": "FeatureCollection",
            "features": [{
                "type": "Feature",
                "geometry": {"type": "Point", "coordinates": [round(r["lon"], 5), round(r["lat"], 5)]},
                "properties": {"id": r["id"], "species": r["species"], "observedAt": r["observed_at"],
                               "source": r["source"], "status": r["status"], "period": r["period"]},
            } for r in rows],
        }

    @app.get("/v1/hotspots")
    def hotspots(bbox: str = Query(..., description="minLon,minLat,maxLon,maxLat"),
                 species: Optional[str] = None,
                 months: Optional[str] = Query(None, description="Comma-separated 1-12, e.g. 10,11"),
                 period: Optional[Literal["dawn", "day", "dusk", "night"]] = None,
                 min_count: int = Query(2, ge=1, le=1000)):
        """Grid cells (about 550 m) with at least min_count reports."""
        month_list = None
        if months:
            try:
                month_list = [int(m) for m in months.split(",") if m]
            except ValueError:
                raise HTTPException(400, "months must be numbers 1-12")
            if any(m < 1 or m > 12 for m in month_list):
                raise HTTPException(400, "months must be numbers 1-12")
        cells = store.hotspots(parse_bbox(bbox), parse_species(species), month_list, period, min_count)
        return {"generatedAt": iso(now()), "cells": cells}

    @app.get("/v1/stats")
    def stats():
        return store.stats()

    @app.get("/config.js")
    def config_js():
        """Settings for the web app. GOOGLE_MAPS_KEY turns on Google Maps;
        without it the app uses OpenStreetMap. Restrict the key to this site."""
        cfg = {"googleMapsKey": os.environ.get("GOOGLE_MAPS_KEY", "")}
        return Response(f"window.WILDPATH_CONFIG = {json.dumps(cfg)};",
                        media_type="application/javascript", headers={"Cache-Control": "no-store"})

    if WEB_DIR.is_dir():
        app.mount("/", StaticFiles(directory=WEB_DIR, html=True), name="web")

    return app


app = create_app()
