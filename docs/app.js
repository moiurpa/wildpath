"use strict";
/* WildPath web app: a live map with your location, one-tap reporting of dead
   animals to the shared database, everyone's reports as pins, risky roads,
   and spoken warnings for hotspots ahead in drive mode. */

const CFG = window.WILDPATH_CONFIG || {};
const VT_CENTER = [44.26, -72.58];

// ---- Animals ---------------------------------------------------------------
const SPECIES = [
  ["deer", "Deer", "🦌", "Large animals"], ["moose", "Moose", "🫎", "Large animals"], ["bear", "Bear", "🐻", "Large animals"],
  ["raccoon", "Raccoon", "🦝", "Small and medium mammals"], ["skunk", "Skunk", "🦨", "Small and medium mammals"],
  ["squirrel", "Squirrel", "🐿️", "Small and medium mammals"], ["porcupine", "Porcupine", "🦔", "Small and medium mammals"],
  ["opossum", "Opossum", "🐀", "Small and medium mammals"], ["woodchuck", "Woodchuck", "🦫", "Small and medium mammals"],
  ["rabbit", "Rabbit", "🐇", "Small and medium mammals"], ["chipmunk", "Chipmunk", "🐿️", "Small and medium mammals"],
  ["fox", "Fox", "🦊", "Small and medium mammals"], ["coyote", "Coyote", "🐺", "Small and medium mammals"],
  ["turtle", "Turtle", "🐢", "Turtles, frogs and snakes"], ["frog", "Frog or toad", "🐸", "Turtles, frogs and snakes"],
  ["salamander", "Salamander", "🦎", "Turtles, frogs and snakes"], ["snake", "Snake", "🐍", "Turtles, frogs and snakes"],
  ["bird", "Bird", "🐦", "Birds"], ["catOrDog", "Cat or dog", "🐈", "Pets"], ["unknown", "Not sure", "❓", "Not sure"],
].map(([id, name, emoji, group]) => ({ id, name, emoji, group }));
const BY_ID = Object.fromEntries(SPECIES.map(s => [s.id, s]));
const QUICK = ["deer", "raccoon", "skunk", "squirrel", "porcupine", "moose", "turtle", "unknown"];
const groupOf = id => (id === "deer" ? "deer" : id === "moose" ? "moose" : "small");
const PIN_COLOR = { deer: "#8a5a2b", moose: "#3b2a20", small: "#7b3fa0" };

// ---- Risk model (same as the iPhone app and the Vermont risk map) -----------
const SEASON = {
  deer: [0.6, 0.5, 0.5, 0.6, 0.9, 1.0, 0.7, 0.7, 0.9, 1.5, 2.0, 1.2],
  moose: [0.5, 0.4, 0.4, 0.6, 1.6, 1.8, 1.2, 0.9, 1.0, 1.1, 0.9, 0.6],
  small: Array(12).fill(1),
};
const TIME = {
  deer: { dawn: 3, day: 1, dusk: 4, night: 2 },
  moose: { dawn: 3, day: 1, dusk: 3, night: 3 },
  small: { dawn: 2, day: 1, dusk: 3, night: 3 },
};
const GROUP_LABEL = { deer: "deer", moose: "moose", small: "small animals" };
const LEVELS = ["Low", "Moderate", "High", "Very high"];
const LEVEL_COLOR = ["#a7b8ad", "#e3b21f", "#df7718", "#c42f1c"];
const LEVEL_WEIGHT = [2, 3, 5, 7];
const PRIORITY = { deer: 3, moose: 2, small: 1 };

function riskValue(score, g, month, period) {
  const base = 0.3 + 0.7 * (score - 5) / 4;
  return base * SEASON[g][month] / Math.max(...SEASON[g]) * TIME[g][period] / Math.max(...Object.values(TIME[g]));
}
const levelOf = v => [0.2, 0.4, 0.7].filter(t => v >= t).length;
function worst(score, month, period) {
  let best = null;
  for (const g of ["deer", "moose", "small"]) {
    const v = riskValue(score, g, month, period);
    if (!best || v > best.v || (v === best.v && PRIORITY[g] > PRIORITY[best.g])) best = { v, g };
  }
  return { level: levelOf(best.v), group: best.g };
}

// Dawn / day / dusk / night from real sunrise and sunset (NOAA approximation).
function periodAt(lat, lon, date = new Date()) {
  const solar = new Date(date.getTime() + lon / 15 * 3600e3);
  const n = Math.floor((Date.UTC(solar.getUTCFullYear(), solar.getUTCMonth(), solar.getUTCDate()) - Date.UTC(solar.getUTCFullYear(), 0, 0)) / 864e5);
  const g = 2 * Math.PI / 365 * (n - 1);
  const eqt = 229.18 * (0.000075 + 0.001868 * Math.cos(g) - 0.032077 * Math.sin(g) - 0.014615 * Math.cos(2 * g) - 0.040849 * Math.sin(2 * g));
  const decl = 0.006918 - 0.399912 * Math.cos(g) + 0.070257 * Math.sin(g) - 0.006758 * Math.cos(2 * g) + 0.000907 * Math.sin(2 * g) - 0.002697 * Math.cos(3 * g) + 0.00148 * Math.sin(3 * g);
  const r = Math.PI / 180;
  const cosHA = Math.cos(90.833 * r) / (Math.cos(lat * r) * Math.cos(decl)) - Math.tan(lat * r) * Math.tan(decl);
  if (cosHA > 1) return "night";
  if (cosHA < -1) return "day";
  const ha = Math.acos(cosHA) / r;
  const rise = 720 - 4 * (lon + ha) - eqt, set = 720 - 4 * (lon - ha) - eqt;
  const now = date.getUTCHours() * 60 + date.getUTCMinutes();
  const d = (a, b) => ((a - b + 720) % 1440 + 1440) % 1440 - 720;
  if (Math.abs(d(now, rise)) <= 60) return "dawn";
  if (Math.abs(d(now, set)) <= 60) return "dusk";
  if (d(now, rise) > 60 && d(now, set) < -60) return "day";
  return "night";
}

// ---- Geometry ---------------------------------------------------------------
const R = Math.PI / 180;
function meters(a, b) {
  const dp = (b[0] - a[0]) * R, dl = (b[1] - a[1]) * R;
  const h = Math.sin(dp / 2) ** 2 + Math.cos(a[0] * R) * Math.cos(b[0] * R) * Math.sin(dl / 2) ** 2;
  return 2 * 6371000 * Math.asin(Math.sqrt(h));
}
function bearing(a, b) {
  const dl = (b[1] - a[1]) * R;
  const y = Math.sin(dl) * Math.cos(b[0] * R);
  const x = Math.cos(a[0] * R) * Math.sin(b[0] * R) - Math.sin(a[0] * R) * Math.cos(b[0] * R) * Math.cos(dl);
  return (Math.atan2(y, x) / R + 360) % 360;
}
const angleDiff = (a, b) => { const d = Math.abs(a - b) % 360; return d > 180 ? 360 - d : d; };
function ago(iso) {
  const s = (Date.now() - new Date(iso).getTime()) / 1000;
  if (s < 90) return "just now";
  if (s < 3600) return `${Math.round(s / 60)} minutes ago`;
  if (s < 86400 * 2) return `${Math.round(s / 3600)} hours ago`;
  return `${Math.round(s / 86400)} days ago`;
}
const esc = s => String(s).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

// ---- Map adapters: Google Maps when a key is set, otherwise OpenStreetMap ---
function leafletMap(el) {
  const map = L.map(el, { zoomControl: false, attributionControl: true }).setView(VT_CENTER, 9);
  L.control.zoom({ position: "topright" }).addTo(map);
  L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
    maxZoom: 19, attribution: '© <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
  }).addTo(map);
  const renderer = L.canvas({ tolerance: 4 });
  return {
    kind: "OpenStreetMap",
    setView: (ll, z) => map.setView(ll, z ?? map.getZoom(), { animate: true }),
    zoom: () => map.getZoom(),
    bounds() { const b = map.getBounds(); return [b.getWest(), b.getSouth(), b.getEast(), b.getNorth()]; },
    polyline(coords, s) {
      const l = L.polyline(coords, { renderer, color: s.color, weight: s.weight, opacity: s.opacity ?? 0.9, interactive: false }).addTo(map);
      return { remove: () => l.remove() };
    },
    marker(ll, { color, size = 8, popup, stroke = "#fff" }) {
      const m = L.circleMarker(ll, { radius: size, color: stroke, weight: 2, fillColor: color, fillOpacity: 1 }).addTo(map);
      if (popup) m.bindPopup(popup);
      return { remove: () => m.remove(), setLatLng: x => m.setLatLng(x), open: () => m.openPopup() };
    },
    circle(ll, radius, s) {
      const c = L.circle(ll, { radius, color: s.color, weight: 1, opacity: s.strokeOpacity ?? 0.5, fillColor: s.color, fillOpacity: s.fillOpacity ?? 0.15, interactive: false }).addTo(map);
      return { remove: () => c.remove(), setLatLng: x => c.setLatLng(x), setRadius: r => c.setRadius(r) };
    },
    onClick: fn => map.on("click", e => fn([e.latlng.lat, e.latlng.lng])),
    onUserMove: fn => map.on("dragstart", fn),
    onMoveEnd: fn => map.on("moveend", fn),
  };
}

function googleMap(el) {
  const toLL = ([lat, lng]) => ({ lat, lng });
  const map = new google.maps.Map(el, {
    center: toLL(VT_CENTER), zoom: 9, mapTypeControl: true, streetViewControl: false,
    fullscreenControl: false, clickableIcons: false, gestureHandling: "greedy",
    mapTypeControlOptions: { position: google.maps.ControlPosition.TOP_RIGHT },
  });
  const info = new google.maps.InfoWindow();
  return {
    kind: "Google Maps",
    setView(ll, z) { map.panTo(toLL(ll)); if (z != null) map.setZoom(z); },
    zoom: () => map.getZoom(),
    bounds() {
      const b = map.getBounds(); if (!b) return null;
      const ne = b.getNorthEast(), sw = b.getSouthWest();
      return [sw.lng(), sw.lat(), ne.lng(), ne.lat()];
    },
    polyline(coords, s) {
      const p = new google.maps.Polyline({ path: coords.map(toLL), strokeColor: s.color, strokeWeight: s.weight, strokeOpacity: s.opacity ?? 0.9, clickable: false, map });
      return { remove: () => p.setMap(null) };
    },
    marker(ll, { color, size = 8, popup, stroke = "#fff" }) {
      const m = new google.maps.Marker({
        position: toLL(ll), map,
        icon: { path: google.maps.SymbolPath.CIRCLE, scale: size, fillColor: color, fillOpacity: 1, strokeColor: stroke, strokeWeight: 2 },
      });
      const open = () => { info.setContent(popup); info.open({ anchor: m, map }); };
      if (popup) m.addListener("click", open);
      return { remove: () => m.setMap(null), setLatLng: x => m.setPosition(toLL(x)), open };
    },
    circle(ll, radius, s) {
      const c = new google.maps.Circle({ center: toLL(ll), radius, map, clickable: false, strokeColor: s.color, strokeOpacity: s.strokeOpacity ?? 0.5, strokeWeight: 1, fillColor: s.color, fillOpacity: s.fillOpacity ?? 0.15 });
      return { remove: () => c.setMap(null), setLatLng: x => c.setCenter(toLL(x)), setRadius: r => c.setRadius(r) };
    },
    onClick: fn => map.addListener("click", e => fn([e.latLng.lat(), e.latLng.lng()])),
    onUserMove: fn => map.addListener("dragstart", fn),
    onMoveEnd: fn => map.addListener("idle", fn),
  };
}

function loadGoogle(key) {
  return new Promise((resolve, reject) => {
    window.__wpGoogleReady = resolve;
    const s = document.createElement("script");
    s.src = `https://maps.googleapis.com/maps/api/js?key=${encodeURIComponent(key)}&callback=__wpGoogleReady&loading=async`;
    s.async = true;
    s.onerror = reject;
    document.head.appendChild(s);
  });
}

// ---- App state ---------------------------------------------------------------
const $ = id => document.getElementById(id);
const store = {
  get(k, fallback) { try { const v = localStorage.getItem(k); return v ? JSON.parse(v) : fallback; } catch { return fallback; } },
  set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch { /* private mode */ } },
};
function reporterId() {
  let id = store.get("wp.reporter", null);
  if (!id) { id = (crypto.randomUUID ? crypto.randomUUID() : String(Math.random()).slice(2) + Date.now()); store.set("wp.reporter", id); }
  return id;
}

const S = {
  map: null, pos: null, prevPos: null, follow: true, driving: false, centeredOnce: false,
  me: null, meAccuracy: null, hotspotLines: [], segments: [], pins: new Map(), community: [], communityShapes: [],
  pickSpecies: null, pickNext: false, voice: store.get("wp.voice", true),
  layers: { hotspots: true, reports: true }, lastWarnKey: null, lastWarnAt: 0, lastWarnPos: null, lastHabitatWarnAt: 0,
  wakeLock: null,
};

// ---- Toast, voice -------------------------------------------------------------
let toastTimer;
function toast(text, ms = 3500) {
  const t = $("toast"); t.textContent = text; t.hidden = false;
  clearTimeout(toastTimer); toastTimer = setTimeout(() => (t.hidden = true), ms);
}
function say(text) {
  if (!S.voice || !("speechSynthesis" in window)) return;
  try { speechSynthesis.cancel(); speechSynthesis.speak(new SpeechSynthesisUtterance(text)); } catch { /* no voice */ }
}

// ---- Location ---------------------------------------------------------------
function startLocation() {
  if (!("geolocation" in navigator)) { setGps("This browser can't share your location", true); return; }
  navigator.geolocation.watchPosition(onPosition, err => {
    if (err.code === err.PERMISSION_DENIED) setGps("Location is off. Allow it in your browser to see where you are.", true);
    else setGps("Can't find your location yet", true);
  }, { enableHighAccuracy: true, maximumAge: 2000, timeout: 20000 });
}
function setGps(text, bad = false) { const c = $("gps-status"); c.textContent = text; c.classList.toggle("bad", bad); }

function onPosition(p) {
  const ll = [p.coords.latitude, p.coords.longitude];
  const now = p.timestamp || Date.now();
  let speed = p.coords.speed, heading = p.coords.heading;
  if (S.pos && (speed == null || heading == null || Number.isNaN(heading))) {
    const dt = (now - S.pos.t) / 1000, dist = meters(S.pos.ll, ll);
    if (dt > 0 && dist > 3) { speed = speed ?? dist / dt; heading = (heading == null || Number.isNaN(heading)) ? bearing(S.pos.ll, ll) : heading; }
  }
  // Ignore impossible speeds from GPS jumps (over about 110 mph).
  if (speed != null && speed > 50) { speed = null; heading = null; }
  S.prevPos = S.pos;
  S.pos = { ll, acc: p.coords.accuracy, speed: speed ?? 0, heading: heading ?? null, t: now };

  if (!S.me) {
    S.meAccuracy = S.map.circle(ll, p.coords.accuracy, { color: "#1a73e8", fillOpacity: 0.12, strokeOpacity: 0.4 });
    S.me = S.map.marker(ll, { color: "#1a73e8", size: 9, popup: "You are here" });
  } else {
    S.me.setLatLng(ll); S.meAccuracy.setLatLng(ll); S.meAccuracy.setRadius(p.coords.accuracy);
  }
  const mph = Math.round((S.pos.speed || 0) * 2.237);
  setGps(`📍 You are here · ±${Math.round(p.coords.accuracy)} m${S.driving && mph > 2 ? ` · ${mph} mph` : ""}`);

  if (!S.centeredOnce) { S.centeredOnce = true; S.map.setView(ll, 15); }
  else if (S.follow && S.driving) S.map.setView(ll, Math.max(S.map.zoom(), 15));
  updateRiskChip();
  if (S.driving) checkWarnings();
}

// ---- Risky roads ------------------------------------------------------------
async function loadSegments() {
  try {
    const data = await (await fetch("data/hotspot-segments.json")).json();
    S.segments = data.segments.map(([score, ri, fmm, tmm, lines]) => {
      let minLat = 90, maxLat = -90, minLon = 180, maxLon = -180;
      const decoded = lines.map(enc => {
        const pts = []; let la = 0, lo = 0;
        for (let i = 0; i < enc.length; i += 2) {
          la += enc[i]; lo += enc[i + 1];
          const p = [la / 1e5, lo / 1e5]; pts.push(p);
          if (p[0] < minLat) minLat = p[0]; if (p[0] > maxLat) maxLat = p[0];
          if (p[1] < minLon) minLon = p[1]; if (p[1] > maxLon) maxLon = p[1];
        }
        return pts;
      });
      return { score, route: data.routes[ri], fmm, tmm, lines: decoded, box: [minLon, minLat, maxLon, maxLat] };
    });
  } catch { S.segments = []; }
  drawHotspots();
}

function nowContext(ll) {
  const c = ll || S.pos?.ll || VT_CENTER;
  return { month: new Date().getMonth(), period: periodAt(c[0], c[1]) };
}

function drawHotspots() {
  S.hotspotLines.forEach(l => l.remove()); S.hotspotLines = [];
  if (!S.layers.hotspots || !S.segments.length) return;
  const b = S.map.bounds(); if (!b) return;
  const zoom = S.map.zoom();
  const { month, period } = nowContext();
  const minLevel = zoom >= 11 ? 1 : 2;
  const padX = (b[2] - b[0]) * 0.1, padY = (b[3] - b[1]) * 0.1;
  let drawn = 0;
  for (const seg of S.segments) {
    if (seg.box[2] < b[0] - padX || seg.box[0] > b[2] + padX || seg.box[3] < b[1] - padY || seg.box[1] > b[3] + padY) continue;
    const { level } = worst(seg.score, month, period);
    if (level < minLevel) continue;
    for (const line of seg.lines) {
      if (line.length < 2) continue;
      S.hotspotLines.push(S.map.polyline(line, { color: LEVEL_COLOR[level], weight: LEVEL_WEIGHT[level], opacity: 0.85 }));
    }
    if (++drawn > 2500) break;
  }
}

function updateRiskChip() {
  const { month, period } = nowContext();
  const g = S.pos ? null : null;
  const top = worst(8, month, period);
  const monthName = new Date().toLocaleString("en-US", { month: "long" });
  $("risk-status").textContent = `${monthName} ${period}: ${LEVELS[top.level].toLowerCase()} risk for ${GROUP_LABEL[top.group]}`;
}

// ---- Reports: load and show pins --------------------------------------------
function reportBbox() {
  const b = S.map.bounds(); if (!b) return null;
  // The server accepts areas up to about 5 x 5 degrees.
  const cx = (b[0] + b[2]) / 2, cy = (b[1] + b[3]) / 2;
  const hw = Math.min((b[2] - b[0]) / 2, 2.4), hh = Math.min((b[3] - b[1]) / 2, 2.4);
  return [cx - hw, cy - hh, cx + hw, cy + hh].map(v => v.toFixed(4)).join(",");
}

async function loadReports() {
  const bbox = reportBbox(); if (!bbox) return;
  try {
    const res = await fetch(`v1/reports?bbox=${bbox}&days=30`);
    if (!res.ok) { enterDemoMode(); return; }
    const geo = await res.json();
    S.hadServer = true;
    const seen = new Set();
    for (const f of geo.features) {
      const id = f.properties.id; seen.add(id);
      if (S.pins.has(id)) continue;
      addPin(id, [f.geometry.coordinates[1], f.geometry.coordinates[0]], f.properties);
    }
    for (const [id, pin] of S.pins) if (!seen.has(id) && !pin.mine) { pin.handle.remove(); S.pins.delete(id); }
    const hs = await (await fetch(`v1/hotspots?bbox=${bbox}&min_count=3`)).json();
    S.community = hs.cells || [];
    S.communityShapes.forEach(s => s.remove());
    S.communityShapes = S.layers.reports ? S.community.map(c => S.map.circle(c.center, 300, { color: "#c42f1c", fillOpacity: 0.16 })) : [];
  } catch { enterDemoMode(); }
}

// With no server (for example the app on a plain website), show sample animals
// and keep new reports on this phone only.
async function enterDemoMode() {
  if (S.demo || S.hadServer) return;
  S.demo = true;
  try {
    const demo = await (await fetch("data/demo-reports.json")).json();
    demo.reports.forEach((r, i) => addPin(`demo-${i}`, [r.latitude, r.longitude],
      { species: r.species, observedAt: new Date(Date.now() - r.minutesAgo * 60000).toISOString() }));
    $("demo-chip").hidden = false;
    $("demo-chip").addEventListener("click", () => { S.follow = false; S.map.setView(demo.center, 14); });
  } catch { /* no sample data */ }
  for (const r of store.get("wp.pending", [])) addPin(r.id.toLowerCase(), [r.latitude, r.longitude], { species: r.species, observedAt: r.observedAt }, true);
}

function addPin(id, ll, props, mine = false) {
  const sp = BY_ID[props.species] || BY_ID.unknown;
  const popup = `<div class="pop-title">${sp.emoji} ${esc(sp.name)}</div><div>Reported ${esc(ago(props.observedAt))}${props.period ? " · " + esc(props.period) : ""}</div>${mine ? "<div><b>Your report</b></div>" : ""}`;
  const handle = S.layers.reports ? S.map.marker(ll, { color: PIN_COLOR[groupOf(sp.id)], size: 7, popup }) : { remove() {} };
  S.pins.set(id, { handle, ll, props, mine });
  return handle;
}

// ---- Reporting ----------------------------------------------------------------
function buildSheet() {
  const btn = s => `<button type="button" class="animal-btn" data-species="${s.id}"><span class="dot" aria-hidden="true">${s.emoji}</span><span>${esc(s.name)}</span></button>`;
  $("quick-grid").innerHTML = QUICK.map(id => btn(BY_ID[id])).join("");
  const groups = [...new Set(SPECIES.map(s => s.group))];
  $("all-list").innerHTML = groups.map(g => `<div class="group-title">${esc(g)}</div><div class="all-grid">${SPECIES.filter(s => s.group === g).map(btn).join("")}</div>`).join("");
  $("report-sheet").addEventListener("click", e => {
    const b = e.target.closest("[data-species]"); if (!b) return;
    $("report-sheet").close();
    chooseLocationFor(b.dataset.species);
  });
  $("pick-on-map").addEventListener("click", () => { S.pickNext = true; $("sheet-where").textContent = "Pick the animal, then tap the map where it is."; });
}

function openReportSheet() {
  S.pickNext = false;
  const fresh = S.pos && Date.now() - S.pos.t < 30000 && S.pos.acc <= 100;
  $("sheet-where").textContent = fresh
    ? `The pin goes where you are now (±${Math.round(S.pos.acc)} m).`
    : "Your location isn't available, so you'll tap the map to place the pin.";
  $("report-sheet").showModal();
}

function chooseLocationFor(species) {
  const fresh = S.pos && Date.now() - S.pos.t < 30000 && S.pos.acc <= 100;
  if (fresh && !S.pickNext) { submitReport(species, S.pos.ll, { acc: S.pos.acc, speed: S.pos.speed, heading: S.pos.heading }); return; }
  S.pickSpecies = species;
  $("pick-text").textContent = `Tap the map where the ${BY_ID[species].name.toLowerCase()} is`;
  $("pick-banner").hidden = false;
}

async function submitReport(species, ll, gps = {}) {
  const report = {
    id: crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random()}`,
    species, latitude: +ll[0].toFixed(6), longitude: +ll[1].toFixed(6),
    horizontalAccuracy: gps.acc ?? null,
    speedMetersPerSecond: gps.speed != null ? Math.max(0, Math.min(100, gps.speed)) : null,
    courseDegrees: gps.heading != null ? gps.heading : null,
    observedAt: new Date().toISOString(), source: "web",
  };
  const name = BY_ID[species].name;
  const handle = addPin(report.id.toLowerCase(), ll, { species, observedAt: report.observedAt }, true);
  try {
    const res = await fetch("v1/reports", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ reporterID: reporterId(), appVersion: "web-0.1", reports: [report] }),
    });
    if (!res.ok) throw new Error(`server ${res.status}`);
    const [result] = (await res.json()).results;
    if (result.status === "accepted") { toast(`${name} reported. Thank you.`); say(`${name} reported.`); }
    else if (result.status === "duplicate") toast(`Someone already reported this ${name.toLowerCase()}. Counted once.`);
    else if (result.status === "rejected") { toast(`Not saved: ${result.reason.replaceAll("_", " ")}.`); handle.remove(); S.pins.delete(report.id.toLowerCase()); }
    else toast(`${name} reported.`);
  } catch {
    const queue = store.get("wp.pending", []); queue.push(report); store.set("wp.pending", queue);
    toast(S.demo ? `${name} added to the demo map (saved on this phone only).`
                 : `${name} saved on this phone. It will upload when you're back online.`);
  }
}

async function flushPending() {
  if (S.demo) return;
  const queue = store.get("wp.pending", []); if (!queue.length) return;
  try {
    const res = await fetch("v1/reports", { method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ reporterID: reporterId(), appVersion: "web-0.1", reports: queue }) });
    if (res.ok) { store.set("wp.pending", []); toast(`${queue.length} saved report${queue.length === 1 ? "" : "s"} uploaded.`); }
  } catch { /* still offline */ }
}

// ---- Warnings ahead (drive mode) --------------------------------------------
function checkWarnings() {
  const p = S.pos; if (!p || p.speed < 6 || p.heading == null || p.acc > 50) return;
  const now = Date.now();
  if (S.lastCheck && now - S.lastCheck < 2000) return;
  S.lastCheck = now;
  const look = Math.min(2000, Math.max(600, p.speed * 45));
  const { month, period } = nowContext(p.ll);
  const ahead = pt => { const d = meters(p.ll, pt); return d >= 80 && d <= look && angleDiff(bearing(p.ll, pt), p.heading) <= 25 ? d : null; };
  let best = null;

  if (now - S.lastHabitatWarnAt >= 240000) {
    const dLat = look / 111000, dLon = dLat / Math.cos(p.ll[0] * R);
    for (const seg of S.segments) {
      if (seg.box[2] < p.ll[1] - dLon || seg.box[0] > p.ll[1] + dLon || seg.box[3] < p.ll[0] - dLat || seg.box[1] > p.ll[0] + dLat) continue;
      const w = worst(seg.score, month, period); if (w.level < 3) continue;
      let near = null;
      for (const line of seg.lines) for (const pt of line) { const d = ahead(pt); if (d != null && (near == null || d < near)) near = d; }
      if (near == null || (best && best.d <= near)) continue;
      best = { key: seg.route, d: near, habitat: true,
        title: `${LEVELS[w.level]} wildlife risk ahead`,
        detail: `${seg.route}, ${(near / 1609.344).toFixed(1)} mi ahead · ${GROUP_LABEL[w.group]}, ${period}`,
        spoken: `Wildlife crossing area ahead on ${seg.route.replace("VT ", "Route ").replace("US ", "U.S. ").replace("I-", "Interstate ")}. Very high risk for ${GROUP_LABEL[w.group]}.` };
    }
  }
  for (const c of S.community) {
    const d = ahead(c.center); if (d == null) continue;
    const top = Object.keys(c.species)[0];
    best = { key: "c" + c.cell, d, habitat: false,
      title: `${c.count} animals reported ahead`,
      detail: `Mostly ${(BY_ID[top]?.name || "animals").toLowerCase()} · ${(d / 1609.344).toFixed(1)} mi ahead`,
      spoken: `Caution. Drivers have reported ${c.count} animals on the road ahead.` };
    break;
  }
  if (!best) return;
  const sameRoad = best.key === S.lastWarnKey && now - S.lastWarnAt < 600000 && S.lastWarnPos && meters(S.lastWarnPos, p.ll) < 3000;
  if (sameRoad) return;
  S.lastWarnKey = best.key; S.lastWarnAt = now; S.lastWarnPos = p.ll;
  if (best.habitat) S.lastHabitatWarnAt = now;
  showWarning(best);
}

let warnTimer;
function showWarning(w) {
  $("warning-title").textContent = w.title;
  $("warning-detail").textContent = w.detail;
  $("warning").hidden = false;
  say(w.spoken);
  clearTimeout(warnTimer); warnTimer = setTimeout(() => ($("warning").hidden = true), 12000);
}

async function setDriving(on) {
  S.driving = on; S.follow = true;
  $("btn-drive").setAttribute("aria-pressed", on);
  if (on) {
    toast("Drive mode on. I'll warn you about wildlife ahead.");
    say("Drive mode on.");
    if (S.pos) S.map.setView(S.pos.ll, 16);
    try { S.wakeLock = await navigator.wakeLock?.request("screen"); } catch { /* not allowed */ }
  } else {
    toast("Drive mode off.");
    $("warning").hidden = true;
    try { await S.wakeLock?.release(); } catch { /* already released */ }
  }
}

// ---- Search -------------------------------------------------------------------
async function search(q) {
  try {
    const res = await fetch(`https://nominatim.openstreetmap.org/search?format=json&limit=1&countrycodes=us&q=${encodeURIComponent(q)}`);
    const [hit] = await res.json();
    if (!hit) { toast(`Couldn't find "${q}".`); return; }
    S.follow = false;
    S.map.setView([+hit.lat, +hit.lon], 13);
  } catch { toast("Search isn't available right now."); }
}

// ---- Start --------------------------------------------------------------------
async function start() {
  let adapter = null;
  if (CFG.googleMapsKey) {
    try { await loadGoogle(CFG.googleMapsKey); adapter = googleMap($("map")); }
    catch { toast("Google Maps didn't load, showing OpenStreetMap instead."); }
  }
  S.map = adapter || leafletMap($("map"));
  window.WildPath = S;  // handy for debugging

  let moveTimer;
  S.map.onMoveEnd(() => { clearTimeout(moveTimer); moveTimer = setTimeout(() => { drawHotspots(); loadReports(); }, 350); });
  S.map.onUserMove(() => { S.follow = false; });
  S.map.onClick(ll => {
    if (!S.pickSpecies) return;
    const sp = S.pickSpecies; S.pickSpecies = null; $("pick-banner").hidden = true;
    submitReport(sp, ll);
  });

  buildSheet();
  $("btn-report").addEventListener("click", openReportSheet);
  $("pick-cancel").addEventListener("click", () => { S.pickSpecies = null; $("pick-banner").hidden = true; });
  $("btn-locate").addEventListener("click", () => {
    S.follow = true;
    if (S.pos) S.map.setView(S.pos.ll, Math.max(S.map.zoom(), 15)); else { toast("Looking for your location…"); startLocation(); }
  });
  $("btn-drive").addEventListener("click", () => setDriving(!S.driving));
  $("btn-layers").addEventListener("click", () => {
    const p = $("layers-panel"); p.hidden = !p.hidden; $("btn-layers").setAttribute("aria-expanded", !p.hidden);
  });
  $("layer-hotspots").addEventListener("change", e => { S.layers.hotspots = e.target.checked; drawHotspots(); });
  $("layer-reports").addEventListener("change", e => {
    S.layers.reports = e.target.checked;
    for (const [id, pin] of S.pins) { pin.handle.remove(); S.pins.delete(id); }
    S.communityShapes.forEach(s => s.remove()); S.communityShapes = [];
    loadReports();
  });
  $("layer-voice").checked = S.voice;
  $("layer-voice").addEventListener("change", e => { S.voice = e.target.checked; store.set("wp.voice", S.voice); });
  $("search").addEventListener("submit", e => { e.preventDefault(); const q = $("search-input").value.trim(); if (q) search(q); });

  updateRiskChip();
  startLocation();
  await loadSegments();
  loadReports();
  flushPending();
  setInterval(loadReports, 30000);
  setInterval(flushPending, 60000);
  setInterval(updateRiskChip, 60000);
  addEventListener("online", flushPending);
}

start();
