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
const PIN_COLOR = { deer: "#f3d9b1", moose: "#e2cdb8", small: "#e5d6f0" };

// ---- Risk model -------------------------------------------------------------
// Each road's risk comes from model/wildpath_risk.py (data/risk-roads.json): its
// deer, moose and other-wildlife risk relative to the average Vermont road,
// learned from traffic, speed limits and 4,000+ police-reported animal crashes.
// Month and time-of-day factors come from data/vermont-patterns.json (learned
// from the same crashes); the values below are only fallbacks.
const SEASON = {
  deer: [0.6, 0.5, 0.5, 0.6, 0.9, 1.0, 0.7, 0.7, 0.9, 1.5, 2.0, 1.2],
  moose: [0.5, 0.4, 0.4, 0.6, 1.6, 1.8, 1.2, 0.9, 1.0, 1.1, 0.9, 0.6],
  other: Array(12).fill(1),
};
const TIME = {
  deer: { dawn: 3, day: 1, dusk: 4, night: 2 },
  moose: { dawn: 3, day: 1, dusk: 3, night: 3 },
  other: { dawn: 2, day: 1, dusk: 3, night: 3 },
};
const PERIOD_HOURS = { dawn: 2, day: 10, dusk: 2, night: 10 };
const RISK_GROUPS = ["deer", "moose", "other"];
const GROUP_LABEL = { deer: "deer", moose: "moose", other: "wildlife" };
const LEVELS = ["Low", "Moderate", "High", "Very high"];
const LEVEL_COLOR = ["#a7b8ad", "#e3b21f", "#df7718", "#c42f1c"];
const LEVEL_WEIGHT = [2, 3, 5, 7];
let RISK_THRESHOLDS = [2, 4, 8];   // x the average road at an average time
let GROUP_SHARE = { deer: 0.74, moose: 0.04, other: 0.22 };

// How much riskier this month and time of day are than average, per group.
function timeFactor(g, month, period) {
  const s = SEASON[g], t = TIME[g];
  const sMean = s.reduce((x, y) => x + y, 0) / 12;
  const tMean = Object.keys(PERIOD_HOURS).reduce((x, p) => x + t[p] * PERIOD_HOURS[p], 0) / 24;
  return (s[month] / sMean) * (t[period] / tMean);
}
const levelOf = v => RISK_THRESHOLDS.filter(t => v >= t).length;
// Risk of one road now: its relative risk for each group x that group's timing.
function roadRisk(seg, month, period) {
  let v = 0, top = null, topV = -1;
  for (const g of RISK_GROUPS) {
    const x = (seg.rel[g] || 0) * timeFactor(g, month, period);
    v += x; if (x > topV) { topV = x; top = g; }
  }
  return { v, level: levelOf(v), group: top };
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
    marker(ll, { color, size = 8, popup, stroke = "#fff", emoji }) {
      const m = emoji
        ? L.marker(ll, { icon: L.divIcon({ className: "", html: `<div class="pin" style="background:${color}">${emoji}</div>`, iconSize: [30, 30], iconAnchor: [15, 15], popupAnchor: [0, -14] }) }).addTo(map)
        : L.circleMarker(ll, { radius: size, color: stroke, weight: 2, fillColor: color, fillOpacity: 1 }).addTo(map);
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
    marker(ll, { color, size = 8, popup, stroke = "#fff", emoji }) {
      const m = new google.maps.Marker({
        position: toLL(ll), map,
        icon: { path: google.maps.SymbolPath.CIRCLE, scale: emoji ? 15 : size, fillColor: color, fillOpacity: 1, strokeColor: stroke, strokeWeight: 2 },
        label: emoji ? { text: emoji, fontSize: "16px" } : undefined,
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
  pickSpecies: null, pickNext: false, voice: store.get("wp.voice", true), crashCells: [], crashShapes: [], crashInfo: null,
  layers: { hotspots: true, reports: true, crashes: true }, lastWarnKey: null, lastWarnAt: 0, lastWarnPos: null, lastHabitatWarnAt: 0,
  wakeLock: null, asked: new Set(store.get("wp.asked", [])), stillFor: null,
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
  if (S.driving) { checkWarnings(); checkStillThere(); }
}

// ---- "Still there?" -------------------------------------------------------------
// When you drive past a reported animal (within 60 m), ask once whether it's still there.
let stillTimer;
function checkStillThere() {
  const p = S.pos; if (!p || p.acc > 40 || !$("still").hidden) return;
  for (const [id, pin] of S.pins) {
    if (pin.mine || id.startsWith("demo-") || S.asked.has(id)) continue;
    if (meters(p.ll, pin.ll) > 60) continue;
    S.asked.add(id); store.set("wp.asked", [...S.asked].slice(-500));
    const sp = BY_ID[pin.props.species] || BY_ID.unknown;
    S.stillFor = id;
    $("still-icon").textContent = sp.emoji;
    $("still-title").textContent = sp.id === "unknown" ? "Animal reported here" : `${sp.name} reported here`;
    $("still").hidden = false;
    say(`${sp.id === "unknown" ? "Animal" : sp.name} reported here. Still there?`);
    clearTimeout(stillTimer); stillTimer = setTimeout(() => ($("still").hidden = true), 15000);
    return;
  }
}

async function answerStillThere(yes) {
  const id = S.stillFor; $("still").hidden = true; clearTimeout(stillTimer); if (!id) return;
  try {
    const r = await api.confirm(id, yes);
    if (r && r.cleared) { const pin = S.pins.get(id); if (pin) { pin.handle.remove(); S.pins.delete(id); } }
    toast(yes ? "Thanks. Other drivers will be warned." : "Thanks. We'll clear it once others agree.");
  } catch { toast("Thanks. Couldn't send that right now."); }
}

// ---- Risky roads ------------------------------------------------------------
// ---- Real Vermont data: crash history and learned timing -----------------------------
async function loadVermontData() {
  try {
    const p = await (await fetch("data/vermont-patterns.json")).json();
    for (const g of RISK_GROUPS) {
      if (p.season?.[g]?.length === 12) SEASON[g] = p.season[g];
      if (p.period?.[g]) TIME[g] = p.period[g];
    }
  } catch { /* keep the starting values */ }
  drawHotspots(); updateRiskChip();
  try {
    const d = await (await fetch("data/crash-hotspots.json")).json();
    S.crashCells = d.cells || [];
    S.crashInfo = { from: d.from?.slice(0, 4), to: d.to?.slice(0, 4), total: d.totalCrashes };
    drawCrashes();
  } catch { /* no crash data */ }
}

function drawCrashes() {
  S.crashShapes.forEach(s => s.remove()); S.crashShapes = [];
  if (!S.layers.crashes) return;
  S.crashShapes = S.crashCells.map(c => S.map.circle(c.center, Math.min(450, 180 + 20 * c.count),
    { color: "#9a4a00", fillOpacity: Math.min(0.35, 0.08 + 0.02 * c.count), strokeOpacity: 0.6 }));
}

async function loadSegments() {
  try {
    const data = await (await fetch("data/risk-roads.json")).json();
    if (data.thresholds) RISK_THRESHOLDS = data.thresholds;
    if (data.share) GROUP_SHARE = data.share;
    S.segments = data.roads.map(([rDeer, rMoose, rOther, ri, lines]) => {
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
      return { rel: { deer: rDeer, moose: rMoose, other: rOther }, route: data.routes[ri], lines: decoded, box: [minLon, minLat, maxLon, maxLat] };
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
    const { level } = roadRisk(seg, month, period);
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
  // How this month and hour compare with an average time, for animals overall.
  let f = 0, top = "deer", topV = -1;
  for (const g of RISK_GROUPS) {
    const x = GROUP_SHARE[g] * timeFactor(g, month, period);
    f += x; if (x > topV) { topV = x; top = g; }
  }
  const level = [1, 2, 4].filter(t => f >= t).length;
  const monthName = new Date().toLocaleString("en-US", { month: "long" });
  $("risk-status").textContent = `${monthName} ${period}: ${LEVELS[level].toLowerCase()} risk for ${GROUP_LABEL[top]}`;
}

// ---- Shared database ----------------------------------------------------------
// With supabaseUrl and supabaseKey in config.js, reports go to Supabase (always on).
// Without them, the app talks to the Python server at v1/ (same answers).
const SB = CFG.supabaseUrl && CFG.supabaseKey ? { url: CFG.supabaseUrl.replace(/\/$/, ""), key: CFG.supabaseKey } : null;

async function sbRpc(name, args) {
  const res = await fetch(`${SB.url}/rest/v1/rpc/${name}`, {
    method: "POST", headers: { "Content-Type": "application/json", apikey: SB.key }, body: JSON.stringify(args),
  });
  if (!res.ok) throw new Error(`server ${res.status}`);
  return res.json();
}
const bboxArgs = bbox => { const [a, b, c, d] = bbox.split(",").map(Number); return { min_lon: a, min_lat: b, max_lon: c, max_lat: d }; };

const api = {
  async upload(reports) {
    reports = reports.map(r => ({ ...r, period: r.period || periodAt(r.latitude, r.longitude, new Date(r.observedAt)) }));
    if (SB) return sbRpc("submit_reports", { reporter_id: reporterId(), app_version: "web-0.2", reports });
    const res = await fetch("v1/reports", { method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ reporterID: reporterId(), appVersion: "web-0.2", reports }) });
    if (!res.ok) throw new Error(`server ${res.status}`);
    return res.json();
  },
  async reports(bbox, days) {
    if (SB) return sbRpc("reports_in_bbox", { ...bboxArgs(bbox), days });
    const res = await fetch(`v1/reports?bbox=${bbox}&days=${days}`);
    if (!res.ok) throw new Error(`server ${res.status}`);
    return res.json();
  },
  async confirm(reportId, stillThere) {
    if (!SB) return null;
    return sbRpc("confirm_report", { reporter_id: reporterId(), report_id: reportId, still_there: stillThere });
  },
  async hotspots(bbox, minCount) {
    if (SB) return sbRpc("hotspots_in_bbox", { ...bboxArgs(bbox), min_count: minCount });
    const res = await fetch(`v1/hotspots?bbox=${bbox}&min_count=${minCount}`);
    if (!res.ok) throw new Error(`server ${res.status}`);
    return res.json();
  },
};

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
    const geo = await api.reports(bbox, 30);
    S.hadServer = true;
    const seen = new Set();
    for (const f of geo.features) {
      const id = f.properties.id; seen.add(id);
      if (S.pins.has(id)) continue;
      addPin(id, [f.geometry.coordinates[1], f.geometry.coordinates[0]], f.properties);
    }
    for (const [id, pin] of S.pins) if (!seen.has(id) && !pin.mine) { pin.handle.remove(); S.pins.delete(id); }
    const hs = await api.hotspots(bbox, 3);
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
  const handle = S.layers.reports ? S.map.marker(ll, { color: PIN_COLOR[groupOf(sp.id)], size: 7, popup, emoji: sp.emoji }) : { remove() {} };
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

function openAddReport() {
  $("add-report-sheet").showModal();
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
    const [result] = (await api.upload([report])).results;
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
    await api.upload(queue);
    store.set("wp.pending", []); toast(`${queue.length} saved report${queue.length === 1 ? "" : "s"} uploaded.`);
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
      const w = roadRisk(seg, month, period); if (w.level < 3) continue;
      let near = null;
      for (const line of seg.lines) for (const pt of line) { const d = ahead(pt); if (d != null && (near == null || d < near)) near = d; }
      if (near == null || (best && best.d <= near)) continue;
      best = { key: seg.route, d: near, habitat: true,
        title: `${LEVELS[w.level]} wildlife risk ahead`,
        detail: `${seg.route} · ${GROUP_LABEL[w.group]}, ${period}`, dist: fmtDist(near), icon: "!",
        spoken: `Very high risk for ${GROUP_LABEL[w.group]} ahead on ${seg.route.replace(/^VT-/, "Route ").replace(/^US-/, "U.S. ").replace(/^I-/, "Interstate ")}.` };
    }
  }
  for (const c of S.community) {
    const d = ahead(c.center); if (d == null) continue;
    const top = Object.keys(c.species)[0];
    best = { key: "c" + c.cell, d, habitat: false,
      title: `${c.count} animals reported ahead`,
      detail: `Mostly ${(BY_ID[top]?.name || "animals").toLowerCase()}`, dist: fmtDist(d), icon: BY_ID[top]?.emoji || "!",
      spoken: `Caution. Drivers have reported ${c.count} animals on the road ahead.` };
    break;
  }
  // Places with a history of police-reported animal crashes.
  for (const c of S.crashCells) {
    const d = ahead(c.center); if (d == null || (best && !best.habitat && best.d <= d)) continue;
    const top = Object.keys(c.species)[0];
    const name = top === "deer" ? "deer" : top === "moose" ? "moose" : "animal";
    best = { key: "x" + c.cell, d, habitat: false, icon: BY_ID[top]?.emoji || "!", dist: fmtDist(d),
      title: `${c.count} ${name} crashes here since ${c.years?.[0] || 2010}`,
      detail: `Police reports · mostly ${c.darkShare >= 0.6 ? "after dark" : "in daylight"}`,
      spoken: `Caution. ${c.count} ${name} crashes have happened on the road ahead.` };
  }
  // A single animal reported in the last 3 days, ahead on this road.
  for (const [id, pin] of S.pins) {
    if (pin.mine || id.startsWith("demo-") || now - Date.parse(pin.props.observedAt) > 3 * 864e5) continue;
    const d = ahead(pin.ll); if (d == null || (best && !best.habitat && best.d <= d)) continue;
    const sp = BY_ID[pin.props.species] || BY_ID.unknown;
    const name = sp.id === "unknown" ? "Dead animal" : sp.name;
    best = { key: "p" + id, d, habitat: false, icon: sp.emoji, dist: fmtDist(d),
      title: `${name} reported ahead`, detail: `Reported ${ago(pin.props.observedAt)} · slow down`,
      spoken: `${name} reported on the road ahead, ${fmtDist(d, true)}.` };
  }
  if (!best) return;
  const sameRoad = best.key === S.lastWarnKey && now - S.lastWarnAt < 600000 && S.lastWarnPos && meters(S.lastWarnPos, p.ll) < 3000;
  if (sameRoad) return;
  S.lastWarnKey = best.key; S.lastWarnAt = now; S.lastWarnPos = p.ll;
  if (best.habitat) S.lastHabitatWarnAt = now;
  showWarning(best);
}

let warnTimer;
function fmtDist(m, spoken = false) {
  const mi = m / 1609.344;
  if (mi < 0.1) { const ft = Math.max(50, Math.round(m * 3.281 / 50) * 50); return spoken ? `in ${ft} feet` : `${ft} ft`; }
  return spoken ? `in ${mi.toFixed(1)} miles` : `${mi.toFixed(1)} mi`;
}

function showWarning(w) {
  $("warning-title").textContent = w.title;
  $("warning-detail").textContent = w.detail;
  $("warning-dist").textContent = w.dist || "";
  $("warning-icon").textContent = w.icon || "!";
  $("warning").hidden = false;
  say(w.spoken);
  clearTimeout(warnTimer); warnTimer = setTimeout(() => ($("warning").hidden = true), 12000);
}

// ---- Weather alerts for each kind of animal ------------------------------------------
// Same rules as model/wildpath_risk.py (sources there). Weather from Open-Meteo
// (free, no key); the location sent is rounded to about 1 km, and only while
// drive mode is on. Each alert plays at most once a day.
function weatherAlerts(month, w) {
  const out = [], t = w.tempC, dark = w.dark;
  const wet = w.rain3h >= 0.5;
  if (t != null && dark && wet) {
    if (month >= 3 && month <= 5 && t >= 4.4) out.push({ key: "frogs", icon: "🐸",
      title: "Big Night: frogs and salamanders crossing", detail: "Warm spring rain after dark · slow down near ponds and wetlands",
      spoken: "Big night. Frogs and salamanders are crossing roads. Please slow down near wetlands." });
    else if ({ 6: 10, 7: 10, 8: 10, 9: 4.4, 10: 4.4 }[month] <= t) out.push({ key: "frogs", icon: "🐸",
      title: "Rainy night: frogs on the road", detail: "Warm and wet after dark · slow down near ponds, wetlands and streams",
      spoken: "Rainy night. Frogs may be on the road. Please slow down near wetlands." });
  }
  if (t != null && !dark && month >= 5 && month <= 7 && t >= 20 && w.rain24h >= 1) out.push({ key: "turtles", icon: "🐢",
    title: "Turtles crossing to nest today", detail: "Warm day after rain · watch road edges near ponds and rivers",
    spoken: "Warm day after rain. Turtles may be crossing to nest. Watch the road edges near water." });
  if (dark && month >= 5 && month <= 10 && w.tempMax >= 20) out.push({ key: "snakes", icon: "🐍",
    title: "Snakes on warm roads tonight", detail: "Pavement stays warm after a warm day",
    spoken: "Warm evening. Snakes may be lying on the road." });
  if (w.snowCm >= 25) out.push({ key: "deer-snow", icon: "🦌",
    title: "Deep snow: deer using the roads", detail: "Deer travel plowed roads and can get trapped by snowbanks",
    spoken: "Deep snow. Deer may be walking on the road." });
  if (w.snowCm >= 10) out.push({ key: "owls", icon: "🦉",
    title: "Snow cover: owls hunting roadsides", detail: "Owls fly low over road edges · slow down at dusk and night",
    spoken: "Snow on the ground. Owls may fly low across the road." });
  return out;
}

async function checkWeather() {
  const p = S.pos; if (!p || !S.driving) return;
  try {
    const [lat, lon] = p.ll.map(v => v.toFixed(2));
    const res = await fetch(`https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}` +
      "&current=temperature_2m,is_day&hourly=precipitation,snow_depth&past_hours=24&forecast_hours=1" +
      "&daily=temperature_2m_max&forecast_days=1&timezone=auto");
    if (!res.ok) return;
    const d = await res.json();
    const rain = (d.hourly?.precipitation || []).slice(0, 24).map(v => v || 0);
    const snow = (d.hourly?.snow_depth || []).slice(0, 24).filter(v => v != null);
    const w = { tempC: d.current?.temperature_2m, tempMax: d.daily?.temperature_2m_max?.[0], dark: d.current?.is_day === 0,
      rain3h: rain.slice(-3).reduce((s, v) => s + v, 0), rain24h: rain.reduce((s, v) => s + v, 0),
      snowCm: snow.length ? snow[snow.length - 1] * 100 : 0 };
    S.weather = w;
    const today = new Date().toDateString(), done = store.get("wp.weatherWarned", {});
    const alert = weatherAlerts(new Date().getMonth() + 1, w).find(x => done[x.key] !== today);
    if (!alert) return;
    done[alert.key] = today; store.set("wp.weatherWarned", done);
    showWarning({ ...alert, dist: "" });
  } catch { /* no weather right now */ }
}

async function setDriving(on) {
  S.driving = on; S.follow = true;
  $("btn-drive").setAttribute("aria-pressed", on);
  $("app").classList.toggle("driving", on);
  if (on) {
    toast("Drive mode on. I'll warn you about wildlife ahead.");
    setTimeout(checkWeather, 5000);
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
  $("btn-report").addEventListener("click", openAddReport);
  $("btn-report-side").addEventListener("click", openAddReport);
  $("still-yes").addEventListener("click", () => answerStillThere(true));
  $("still-no").addEventListener("click", () => answerStillThere(false));
  $("report-dead-animal").addEventListener("click", () => { $("add-report-sheet").close(); openReportSheet(); });
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
  $("layer-crashes").addEventListener("change", e => { S.layers.crashes = e.target.checked; drawCrashes(); });
  $("layer-voice").checked = S.voice;
  $("layer-voice").addEventListener("change", e => { S.voice = e.target.checked; store.set("wp.voice", S.voice); });
  $("search").addEventListener("submit", e => { e.preventDefault(); const q = $("search-input").value.trim(); if (q) search(q); });

  updateRiskChip();
  startLocation();
  await loadSegments();
  loadVermontData();
  loadReports();
  flushPending();
  setInterval(loadReports, 30000);
  setInterval(checkWeather, 30 * 60000);
  setInterval(flushPending, 60000);
  setInterval(updateRiskChip, 60000);
  addEventListener("online", flushPending);
}

start();

// Let the app be installed on the phone and open with no signal.
if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => navigator.serviceWorker.register("sw.js").catch(() => {}));
}
