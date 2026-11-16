# WildPath requirements and status

✅ working and tested · 🟡 built but not tested, or partly done · ❌ not done

## Reporting

| Requirement | Status | Notes |
|---|---|---|
| Report a dead animal | ✅ | Web app: tap the button, pick the animal. Tested. |
| Pin goes where I am | ✅ | Uses phone GPS. Tested. |
| Put the pin somewhere else by tapping the map | ✅ | Tested. |
| All animals, not only deer | ✅ | 20 animals: raccoon, skunk, squirrel, porcupine, opossum and more. |
| Same animal reported twice counts once | ✅ | Tested with two phones. |
| Works with no signal, uploads later | 🟡 | Built in the web app; not tested offline. |
| Report by voice ("Hey Siri") | 🟡 | iPhone app code only; needs a Mac to build. |
| Report from CarPlay | 🟡 | iPhone app code only; needs a Mac and Apple approval. |
| Camera reports automatically, only if allowed | 🟡 | iPhone app code only; detector is a stand-in until a roadkill model is trained. |
| Report from inside Google Maps / Apple Maps / Waze | ❌ | Only Google and Apple can add that button. |

## Map

| Requirement | Status | Notes |
|---|---|---|
| See where I am | ✅ | Blue dot with accuracy circle. Tested. |
| Streets, roads and town names | ✅ | OpenStreetMap map. Tested. |
| Google Maps as the map | 🟡 | Built in: set GOOGLE_MAPS_KEY on the server. Not tested (needs your key). |
| Everyone's reports as pins | ✅ | Tested with two phones. |
| Risky roads colored | ✅ | Vermont state highways. |
| Spots with many reports highlighted | ✅ | Red circles where 3+ animals were reported. |
| Search a town or address | 🟡 | Built; not tested. |

## Warnings and prediction

| Requirement | Status | Notes |
|---|---|---|
| Warn me about hotspots ahead while driving | ✅ | Web app drive mode, spoken and on screen. Tested on a simulated drive on VT 105. |
| Season and time of day | 🟡 | Works, but uses estimates until real reports replace them. |
| Works anywhere in the country | 🟡 | Reports and dawn/dusk work anywhere; risky-road data is Vermont only. |

## Platform

| Requirement | Status | Notes |
|---|---|---|
| Shared database of reports | ✅ | Server with 22 passing tests. |
| Phone app | 🟡 | Web app works in a phone browser. Native iPhone app written, not built. |
| Turn-by-turn directions | 🟡 | iPhone app hands off to Google Maps; not in the web app yet. |
| Online at a permanent address | ❌ | Runs only in this session for now. Needs hosting. |
| Free app | ✅ | Planned as free. |
| Sell the data to companies | ❌ | Needs real users and data first. |
