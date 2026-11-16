# WildPath

A driving app, built on Google Maps, that maps where animals get hit on the
road, warns drivers when a hotspot is ahead, and lets anyone report a dead
animal by tap, by voice, or automatically with the camera. The app is free;
the hotspot data is what agencies, insurers and map companies would pay for.

| Folder | What it is | Status |
|---|---|---|
| `hotspot-map/` | Vermont Wildlife Road Risk web map | Built and published |
| `server/` | Shared reports database and API | Built, 20 tests passing |
| `ios/` | iPhone app: Google Maps driving view, warnings, CarPlay, Siri, camera detection | Source written, not yet compiled (needs a Mac) |

## Roadmap

1. **Hotspot map.** Done for Vermont state highways.
2. **Hands-free reporting.** CarPlay, Siri and phone reporting written; needs a Mac to build and Apple's CarPlay approval.
3. **Driving view on Google Maps.** Written.
4. **Warnings for hotspots ahead.** Written; logic checked in a simulation on real Vermont roads.
5. **Shared database.** Built and tested; needs hosting.
6. **Camera detection.** Proof of concept written; needs a trained animal model.
7. **Turn-by-turn.** Hands off to Google Maps for now; Google's Navigation SDK later.
8. **Better data.** VTrans traffic and crash records; replace the estimated season and time factors with real report data.
9. **Partners.** Waze for Cities feed, agencies, insurers, then map companies and automakers.

## Rebuild the hotspot data

```bash
pip install pyproj shapely
```

```bash
cd hotspot-map && python3 build.py
```

This updates both the web map and the app's bundled road data.

## Website

`web/` is the web app source. `docs/` is a copy of it that GitHub Pages serves.
After changing `web/`, refresh the copy:

```bash
rm -rf docs && cp -r web docs && touch docs/.nojekyll && rm -f docs/README.md
```
