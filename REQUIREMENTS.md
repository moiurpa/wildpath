# WildPath requirements and status

✅ working and tested · 🟡 built but not tested, or partly done · ❌ not done

Last checked: 16 Nov 2026, on the live site https://moiurpa.github.io/wildpath/ in Chrome (desktop).

## Reporting

| Requirement | Status | Notes |
|---|---|---|
| Report a dead animal | ✅ | Tap the button, pick the animal. |
| Yellow report button in drive mode, "Add a report" sheet with a Dead animal tile (Google Maps style) | ✅ | Checked on the live site in Chrome. Not yet checked on a real phone or in light mode. |
| Pin goes where I am | ✅ | Uses phone GPS. |
| Put the pin somewhere else by tapping the map | ✅ | |
| All animals, not only deer | ✅ | 20 animals: raccoon, skunk, squirrel, porcupine, opossum and more. |
| Same animal reported twice counts once | 🟡 | Works in the server (tests pass). Not live, because the server is not online. |
| Works with no signal, uploads later | 🟡 | Built in the web app; not tested offline. |
| Add a photo to a report | ❌ | Needed to check reports and to train the camera model. |
| "Still there?" check by the next driver | ❌ | Lets drivers confirm or clear a report, like Waze. Improves data quality. |
| Report by voice on the website | ❌ | The iPhone app has Siri code; the website has no voice reporting. |
| Report by voice ("Hey Siri") | 🟡 | iPhone app code only; needs a Mac to build. |
| Report from CarPlay | 🟡 | iPhone app code only; needs a Mac and Apple approval. |
| Camera reports automatically, only if allowed | 🟡 | iPhone app code only; detector is a stand-in until a roadkill model is trained. |
| Report from inside Google Maps / Apple Maps / Waze | ❌ | Only Google and Apple can add that button. |

## Map

| Requirement | Status | Notes |
|---|---|---|
| See where I am | ✅ | Blue dot with accuracy circle. |
| Google Maps as the map | ✅ | Restricted key (Maps JavaScript API, moiurpa.github.io only). Live. |
| Everyone's reports as pins | 🟡 | Works with the server on one computer. On the live site, each phone sees only its own reports plus demo animals. |
| Risky roads colored | ✅ | Vermont state highways. |
| Spots with many reports highlighted | 🟡 | Needs the shared database to be online. |
| Search a town or address | 🟡 | Built; not tested. |
| Animal icons on pins (not plain dots) | ❌ | |

## Warnings and prediction

| Requirement | Status | Notes |
|---|---|---|
| Warn me about hotspots ahead while driving | ✅ | Drive mode, spoken and on screen. Tested on a simulated drive on VT 105. |
| Warning card with distance ("Dead animal reported ahead, 0.3 mi") | ❌ | Current card has no distance. |
| Season and time of day | 🟡 | Works, but uses estimates until real reports replace them. |
| Works anywhere in the country | 🟡 | Reports and dawn/dusk work anywhere; risky-road data is Vermont only. |

## Platform

| Requirement | Status | Notes |
|---|---|---|
| Website online at a permanent address | ✅ | https://moiurpa.github.io/wildpath/ |
| Shared database of reports online | ❌ | Server built (22 tests pass) but not hosted. Options: Oracle free server, Firestore, Supabase. |
| Install on the phone home screen, works offline (PWA) | 🟡 | Live: app icon, manifest and offline support load in Chrome. Not yet installed on a real phone. |
| Phone app | 🟡 | Website works in a phone browser. Native iPhone app written, not built. |
| Turn-by-turn directions | 🟡 | iPhone app hands off to Google Maps; not in the website. |
| Spanish | ❌ | |
| Free app | ✅ | |
| Google spending cap | 🟡 | Daily limit set. $1 budget alert not set yet. |

## Data and business

| Requirement | Status | Notes |
|---|---|---|
| Privacy policy and terms | ❌ | Needed before collecting location data at scale or licensing it. |
| Moderation of reports | ❌ | Only duplicate, GPS and spam checks today. |
| Data export for partners (CSV / GeoJSON) | ❌ | Should follow the federal standard for wildlife carcass data when FHWA publishes the template. |
| Dashboard for agencies (hotspots, trends, species) | ❌ | |
| Real Vermont crash data | ❌ | Request from VTrans and Fish & Wildlife. |
| Sell or license the data | ❌ | Needs real users and data first. |
