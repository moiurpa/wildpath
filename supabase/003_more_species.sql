-- WildPath: accept more Vermont animals (bobcat, fisher, beaver, otter, wild turkey).
-- Replaces submit_reports with the updated list; run once in the Supabase SQL editor.

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
