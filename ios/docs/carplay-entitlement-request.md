# Draft: CarPlay entitlement request (Driving Task)

Edit before sending, and fill in the bracketed parts.

**App name:** WildPath

**Category:** Driving Task

**Description:**
WildPath lets drivers report a dead or injured animal on the road with a single
tap, so wildlife-vehicle collision hotspots can be mapped and drivers warned.
The CarPlay interface is one grid template with eight large buttons (Deer,
Moose, Raccoon, Skunk, Squirrel, Turtle, Not sure, More animals). "More animals"
opens one grouped list of the remaining animals. Tapping an animal saves
the vehicle's current location and time, then shows a short confirmation alert
that closes on its own. There is no typing, scrolling, browsing or media on the
CarPlay screen.

**Why it helps while driving:**
Animal carcasses are road hazards, and drivers see them at the moment they
pass. Reporting from the phone while driving is unsafe; a single CarPlay tap or
a Siri request is the safe alternative. Reports build a map of collision
hotspots that [state agencies / partners] use to plan fencing and wildlife
crossings and to warn drivers during peak seasons.

**Templates used:** CPGridTemplate (root), CPListTemplate (more animals, one
level deep), CPAlertTemplate (confirmation).

**Data and privacy:** No account. Reports contain species, location, time,
speed and heading, plus a random device ID. [Link to privacy policy]

**Contact / organization:** [Your name or organization]
