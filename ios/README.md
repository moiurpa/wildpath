# WildPath iPhone app

A driving app on Google Maps: risky roads are colored on the map, WildPath
speaks warnings when a wildlife hotspot is ahead, and you report a dead animal
with one tap, by voice, or automatically with the camera if you allow it.

> Status: source code only. It was written without a Mac, so it has **not been
> compiled or run yet**. Expect some fixes on the first build.

## Features

| Feature | Where |
|---|---|
| **Drive tab:** Google map that follows the car, risky roads colored, report pins, community hotspots | `Drive/DriveView.swift`, `Drive/GoogleDriveMap.swift` |
| **Warnings ahead:** spoken and on screen, also when another app (Google Maps) is in front | `Drive/HotspotWarner.swift`, `Drive/DriveSession.swift`, `Drive/Speaker.swift` |
| **One-tap reporting:** 20 animals, from deer and moose to raccoons, skunks, squirrels, frogs | `Drive/DriveView.swift`, `UI/ContentView.swift` |
| **CarPlay:** 7 common animals + More, one tap each | `CarPlay/CarPlaySceneDelegate.swift` |
| **Siri:** "Hey Siri, report a raccoon in WildPath" | `Intents/ReportAnimalIntent.swift` |
| **Camera detection** (opt-in): dashboard-mounted phone spots animals and reports them | `Camera/` |
| **Directions:** hands off to the Google Maps app; WildPath keeps warning in the background | `Drive/DriveView.swift` (`DirectionsSheet`) |
| **Shared database:** uploads reports, downloads nearby reports and hotspots | `Core/Uploader.swift`, `Network/ServerClient.swift`, `/server` |

## What you need

- A Mac with Xcode 15 or newer.
- A **Google Maps API key** for the Maps SDK for iOS (Google Cloud console). Restrict it to your bundle ID.
- For a real car: a paid Apple Developer account ($99/year) and Apple's CarPlay approval.

## Set up

```bash
brew install xcodegen
```

```bash
cd ios && xcodegen generate && open WildPath.xcodeproj
```

XcodeGen adds Google's Maps SDK as a Swift package. In Xcode:

1. Signing & Capabilities: choose your Team and change the bundle ID from `com.example.wildpath`.
2. In `WildPath/Info.plist`, set `GoogleMapsAPIKey` to your key.
3. Optional: set `WildPathServerURL` to the server's address (see `/server`). Without it, reports stay on the phone.

## Test in the Simulator

1. Run on an iPhone simulator and allow location.
2. Simulator › Features › Location › **Freeway Drive** fakes a moving car. For Vermont roads, use a GPX file of a Vermont route instead (Xcode › Debug › Simulate Location).
3. Drive tab › **Start drive**. Colored roads, warnings and the report buttons appear.
4. CarPlay: Simulator › I/O › External Displays › CarPlay.

Camera detection needs a real iPhone; the Simulator has no camera.

## How warnings work

- WildPath looks about 45 seconds down the road (600 m to 2 km) in the direction you're driving.
- **Habitat warnings** come from Vermont's Wildlife Crossing Value data, adjusted for the month and time of day. Only "Very high" stretches trigger them, at most every 4 minutes, so drivers don't learn to ignore them.
- **Community warnings** play when other drivers have reported 3 or more animals at a spot ahead.
- A simulation on real Vermont roads gave about one warning every 4 to 5 minutes at dusk in November, and none on a February afternoon.

## Camera detection: privacy and limits

- Off by default; the driver turns it on after reading what it does.
- Frames are analyzed in memory and thrown away. No video or photo is saved or uploaded.
- Only runs while the car moves, two frames a second, and pauses if the phone gets hot.
- Needs the same kind of animal in 2 of 3 frames before reporting.
- **Test version:** it uses Apple's general image recognizer, which will miss most animals on the road. The real version needs a custom model: add `RoadkillDetector.mlmodel` (Create ML › Object Detection, trained on report photos with labels like `raccoon` and `deer`) and the app uses it automatically.

## CarPlay approval

The current CarPlay screen is a "driving task" app (buttons only). Showing the
Google map on CarPlay needs Apple's separate **navigation** approval, which is
harder to get. A draft request is in `docs/carplay-entitlement-request.md`.

## Turn-by-turn directions

For now, Directions opens the Google Maps app, and WildPath keeps running in
the background to speak warnings. The upgrade is Google's Navigation SDK for
iOS, which puts Google's turn-by-turn inside WildPath. It is billed per
destination and Google may require an application first.

## Known limits

- SF Symbols has few wild-animal icons, so most mammals share a paw print.
- Hotspot data covers Vermont state highways only.
- The season and time-of-day factors are estimates until real report data replaces them.
- Background audio and location will need a clear explanation in App Store review.
