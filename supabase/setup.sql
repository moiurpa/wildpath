-- WildPath on Supabase: the live, always-on copy of the reports.
-- Your computer keeps the permanent archive (see server/wildpath_archive.py).
--
-- Same rules as the Python server (server/wildpath_server/store.py):
--   * the device ID is stored only as a salted hash; public reads never show who reported
--   * same animal within 50 m and 6 hours counts once ("Not sure" matches any animal)
--   * camera reports stay unverified until a person reports the same animal
--   * rejects GPS worse than 200 m, times in the future or older than 30 days,
--     and more than 120 reports per device per hour
--
-- Phones never touch the table directly. They can only call the three functions
-- at the bottom (submit_reports, reports_in_bbox, hotspots_in_bbox).
-- Run this whole file once in the Supabase SQL editor. Running it again is safe.

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists private.settings (
  id   int primary key default 1 check (id = 1),
  salt text not null
);
insert into private.settings (id, salt)
values (1, replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''))
on conflict (id) do nothing;

create table if not exists public.reports (
  id            uuid primary key,
  reporter_hash text not null,
  species       text not null,
  lat           double precision not null,
  lon           double precision not null,
  accuracy_m    real,
  speed_mps     real,
  course_deg    real,
  observed_at   timestamptz not null,
  received_at   timestamptz not null default now(),
  source        text not null,
  confidence    real,
  status        text not null,        -- new | unverified | confirmed | duplicate
  duplicate_of  uuid,
  month         int  not null,
  period        text not null,        -- dawn | day | dusk | night (from the phone; the archive recomputes it)
  cell          text not null,
  app_version   text
);
create index if not exists reports_latlon   on public.reports (lat, lon);
create index if not exists reports_received on public.reports (received_at);
create index if not exists reports_reporter on public.reports (reporter_hash, received_at);

-- Lock the table: no direct reads or writes from the website's public key.
alter table public.reports enable row level security;
revoke all on public.reports from anon, authenticated;
-- The archive on your computer reads (and, only if asked, trims) with the secret key.
grant select, update, delete on public.reports to service_role;

-- ---- Helpers ------------------------------------------------------------------

create or replace function private.meters_between(lat1 double precision, lon1 double precision,
                                                  lat2 double precision, lon2 double precision)
returns double precision language sql immutable set search_path = '' as $$
  select 2 * 6371000 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2)
    + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2)));
$$;

create or replace function private.check_bbox(min_lon double precision, min_lat double precision,
                                              max_lon double precision, max_lat double precision)
returns void language plpgsql immutable set search_path = '' as $$
begin
  if not (min_lon < max_lon and min_lat < max_lat) then
    raise exception 'bbox min values must be smaller than max values';
  end if;
  if (max_lon - min_lon) * (max_lat - min_lat) > 25 then
    raise exception 'bbox is too large; zoom in to an area about 5 by 5 degrees or smaller';
  end if;
end;
$$;

-- ---- Upload reports ------------------------------------------------------------
-- Same request and answer shape as POST /v1/reports on the Python server.

create or replace function public.submit_reports(reporter_id text, app_version text, reports jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  rh        text;
  recent    int;
  results   jsonb := '[]'::jsonb;
  r         jsonb;
  rid       uuid;
  sp        text;
  src       text;
  la        double precision;
  lo        double precision;
  acc       double precision;
  obs       timestamptz;
  per       text;
  st        text;
  dup       record;
  reason    text;
begin
  if reporter_id is null or length(reporter_id) < 8 or length(reporter_id) > 64 then
    raise exception 'reporter_id must be 8 to 64 characters';
  end if;
  if jsonb_typeof(reports) <> 'array' or jsonb_array_length(reports) > 500 then
    raise exception 'reports must be a list of at most 500';
  end if;

  select encode(sha256(convert_to(s.salt || reporter_id, 'UTF8')), 'hex')
    into rh from private.settings s where s.id = 1;
  rh := left(rh, 32);
  select count(*) into recent from public.reports p
   where p.reporter_hash = rh and p.received_at > now() - interval '1 hour';

  for r in select * from jsonb_array_elements(reports) loop
    begin
      rid := lower(r->>'id')::uuid;
    exception when others then
      results := results || jsonb_build_object('id', r->>'id', 'status', 'rejected', 'reason', 'bad_id');
      continue;
    end;

    if exists (select 1 from public.reports p where p.id = rid) then
      results := results || jsonb_build_object('id', rid, 'status', 'already_received');
      continue;
    end if;

    reason := null;
    begin
      la  := (r->>'latitude')::double precision;
      lo  := (r->>'longitude')::double precision;
      acc := (r->>'horizontalAccuracy')::double precision;
      obs := (r->>'observedAt')::timestamptz;
    exception when others then
      reason := 'bad_values';
    end;
    src := r->>'source';
    sp  := coalesce(r->>'species', 'unknown');
    if sp not in ('deer','moose','bear','raccoon','skunk','squirrel','porcupine','opossum','woodchuck',
                  'rabbit','chipmunk','fox','coyote','bobcat','fisher','beaver','otter','turtle','frog',
                  'salamander','snake','turkey','bird','catOrDog','unknown') then
      sp := 'unknown';
    end if;
    per := r->>'period';
    if per is null or per not in ('dawn','day','dusk','night') then per := 'day'; end if;

    if reason is null then
      if recent >= 120 then reason := 'too_many_reports';
      elsif src is null or src not in ('carplay','phone','siri','camera','web') then reason := 'unknown_source';
      elsif la is null or lo is null or la < -90 or la > 90 or lo < -180 or lo > 180 then reason := 'bad_location';
      elsif acc is not null and (acc < 0 or acc > 200) then reason := 'location_not_accurate_enough';
      elsif obs is null then reason := 'bad_values';
      elsif obs > now() + interval '10 minutes' then reason := 'observed_in_future';
      elsif obs < now() - interval '30 days' then reason := 'too_old';
      end if;
    end if;
    if reason is not null then
      results := results || jsonb_build_object('id', rid, 'status', 'rejected', 'reason', reason);
      continue;
    end if;

    st := case when src = 'camera' then 'unverified' else 'new' end;

    -- Same animal nearby in the last few hours?
    select p.id, p.status into dup from public.reports p
     where p.lat between la - 50.0 / 111000 and la + 50.0 / 111000
       and p.lon between lo - (50.0 / 111000) / greatest(cos(radians(la)), 0.01)
                     and lo + (50.0 / 111000) / greatest(cos(radians(la)), 0.01)
       and p.observed_at between obs - interval '6 hours' and obs + interval '6 hours'
       and p.status <> 'duplicate'
       and (p.species = sp or p.species = 'unknown' or sp = 'unknown')
       and private.meters_between(la, lo, p.lat, p.lon) <= 50
     order by p.observed_at
     limit 1;

    if found then
      if src <> 'camera' and dup.status = 'unverified' then
        update public.reports set status = 'confirmed' where id = dup.id;
      end if;
      st := 'duplicate';
    end if;

    insert into public.reports (id, reporter_hash, species, lat, lon, accuracy_m, speed_mps, course_deg,
                                observed_at, source, confidence, status, duplicate_of, month, period, cell, app_version)
    values (rid, rh, sp, la, lo, acc,
            case when r->>'speedMetersPerSecond' is null then null
                 else least(greatest((r->>'speedMetersPerSecond')::double precision, 0), 100) end,
            (r->>'courseDegrees')::double precision,
            obs, src, (r->>'confidence')::double precision, st,
            case when st = 'duplicate' then dup.id end,
            extract(month from obs at time zone 'UTC')::int, per,
            floor(la / 0.005)::bigint || ':' || floor(lo / 0.007)::bigint,
            left(app_version, 20));
    recent := recent + 1;

    if st = 'duplicate' then
      results := results || jsonb_build_object('id', rid, 'status', 'duplicate', 'duplicateOf', dup.id);
    else
      results := results || jsonb_build_object('id', rid, 'status', 'accepted');
    end if;
  end loop;

  return jsonb_build_object('results', results);
end;
$$;

-- ---- Read report pins ----------------------------------------------------------
-- Same GeoJSON as GET /v1/reports. Never includes who reported.

create or replace function public.reports_in_bbox(min_lon double precision, min_lat double precision,
                                                  max_lon double precision, max_lat double precision,
                                                  days int default 30)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb;
begin
  perform private.check_bbox(min_lon, min_lat, max_lon, max_lat);
  select jsonb_build_object('type', 'FeatureCollection', 'features', coalesce(jsonb_agg(f), '[]'::jsonb))
    into result
    from (
      select jsonb_build_object(
               'type', 'Feature',
               'geometry', jsonb_build_object('type', 'Point',
                           'coordinates', jsonb_build_array(round(p.lon::numeric, 5), round(p.lat::numeric, 5))),
               'properties', jsonb_build_object('id', p.id, 'species', p.species, 'observedAt', p.observed_at,
                                                'source', p.source, 'status', p.status, 'period', p.period)) as f
        from public.reports p
       where p.lat between min_lat and max_lat and p.lon between min_lon and max_lon
         and p.observed_at >= now() - make_interval(days => least(greatest(days, 1), 365))
         and p.status in ('new', 'confirmed')
       order by p.observed_at desc
       limit 5000
    ) x;
  return result;
end;
$$;

-- ---- Hotspots ------------------------------------------------------------------
-- Same shape as GET /v1/hotspots: grid cells (about 550 m) with at least min_count reports.

create or replace function public.hotspots_in_bbox(min_lon double precision, min_lat double precision,
                                                   max_lon double precision, max_lat double precision,
                                                   min_count int default 2)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb;
begin
  perform private.check_bbox(min_lon, min_lat, max_lon, max_lat);
  with r as (
    select p.cell, p.species, p.period, p.lat, p.lon from public.reports p
     where p.lat between min_lat and max_lat and p.lon between min_lon and max_lon
       and p.status in ('new', 'confirmed')
  ), c as (
    select cell, count(*) as n, avg(lat) as la, avg(lon) as lo from r
     group by cell having count(*) >= greatest(min_count, 1)
  ), sp as (
    select cell, jsonb_object_agg(species, n) as j
      from (select cell, species, count(*) as n from r group by cell, species) s group by cell
  ), pe as (
    select cell, jsonb_object_agg(period, n) as j
      from (select cell, period, count(*) as n from r group by cell, period) s group by cell
  )
  select jsonb_build_object('generatedAt', now(), 'cells', coalesce(jsonb_agg(
           jsonb_build_object('cell', c.cell, 'count', c.n,
                              'center', jsonb_build_array(round(c.la::numeric, 5), round(c.lo::numeric, 5)),
                              'species', sp.j, 'periods', pe.j) order by c.n desc), '[]'::jsonb))
    into result
    from c join sp using (cell) join pe using (cell);
  return result;
end;
$$;

-- Only these three functions are open to the website.
revoke all on function public.submit_reports(text, text, jsonb) from public;
revoke all on function public.reports_in_bbox(double precision, double precision, double precision, double precision, int) from public;
revoke all on function public.hotspots_in_bbox(double precision, double precision, double precision, double precision, int) from public;
grant execute on function public.submit_reports(text, text, jsonb) to anon, authenticated;
grant execute on function public.reports_in_bbox(double precision, double precision, double precision, double precision, int) to anon, authenticated;
grant execute on function public.hotspots_in_bbox(double precision, double precision, double precision, double precision, int) to anon, authenticated;
