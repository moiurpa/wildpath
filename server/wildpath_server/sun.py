"""Sunrise and sunset, used to sort every report into dawn, day, dusk or night.

Uses the NOAA approximation (accurate to a few minutes), so it works anywhere,
not only in Vermont. Dawn and dusk are the hour either side of sunrise and sunset.
"""

import math
from datetime import datetime, timedelta

TWILIGHT_MINUTES = 60


def sun_times_utc(lat: float, lon: float, day_of_year: int):
    """Return (sunrise, sunset) in minutes after 00:00 UTC.

    Returns "day" or "night" instead when the sun never sets or never rises
    (far north or south)."""
    g = 2 * math.pi / 365 * (day_of_year - 1)
    eqt = 229.18 * (0.000075 + 0.001868 * math.cos(g) - 0.032077 * math.sin(g)
                    - 0.014615 * math.cos(2 * g) - 0.040849 * math.sin(2 * g))
    decl = (0.006918 - 0.399912 * math.cos(g) + 0.070257 * math.sin(g)
            - 0.006758 * math.cos(2 * g) + 0.000907 * math.sin(2 * g)
            - 0.002697 * math.cos(3 * g) + 0.00148 * math.sin(3 * g))
    lat_r = math.radians(lat)
    cos_ha = (math.cos(math.radians(90.833)) / (math.cos(lat_r) * math.cos(decl))
              - math.tan(lat_r) * math.tan(decl))
    if cos_ha > 1:
        return "night"
    if cos_ha < -1:
        return "day"
    ha = math.degrees(math.acos(cos_ha))
    return 720 - 4 * (lon + ha) - eqt, 720 - 4 * (lon - ha) - eqt


def _signed_diff(a: float, b: float) -> float:
    """Difference a - b in minutes, wrapped into -720..720."""
    return ((a - b + 720) % 1440 + 1440) % 1440 - 720


def period_at(lat: float, lon: float, when_utc: datetime) -> str:
    """Classify a UTC time at a place as dawn, day, dusk or night."""
    # Use the local solar date so evening reports in the Americas use the
    # right day's sunset even though they fall on the next UTC date.
    local_solar = when_utc + timedelta(hours=lon / 15)
    times = sun_times_utc(lat, lon, local_solar.timetuple().tm_yday)
    if isinstance(times, str):
        return times
    rise, set_ = times
    now = when_utc.hour * 60 + when_utc.minute + when_utc.second / 60
    if abs(_signed_diff(now, rise)) <= TWILIGHT_MINUTES:
        return "dawn"
    if abs(_signed_diff(now, set_)) <= TWILIGHT_MINUTES:
        return "dusk"
    if _signed_diff(now, rise) > TWILIGHT_MINUTES and _signed_diff(now, set_) < -TWILIGHT_MINUTES:
        return "day"
    return "night"
