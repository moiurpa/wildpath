-- WildPath: "Still there?" answers from the next drivers who pass a report.
-- Run once in the Supabase SQL editor after setup.sql. Running it again is safe.
--
-- Rules:
--   * one answer per device per report; the reporter can't answer their own report
--   * "Yes" from another person confirms a camera report
--   * when at least 2 people say "Gone" and they outnumber the "Yes" answers,
--     the report is cleared from the live map (cleared_at is set)
--   * a cleared report still counts for hotspots: the animal was really hit there

alter table public.reports add column if not exists still_there_votes int not null default 0;
alter table public.reports add column if not exists gone_votes        int not null default 0;
alter table public.reports add column if not exists cleared_at        timestamptz;

create table if not exists private.confirmations (
  report_id     uuid not null references public.reports (id) on delete cascade,
  reporter_hash text not null,
  still_there   boolean not null,
  answered_at   timestamptz not null default now(),
  primary key (report_id, reporter_hash)
);
alter table private.confirmations enable row level security;

create or replace function public.confirm_report(reporter_id text, report_id uuid, still_there boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  rh     text;
  rep    record;
  recent int;
  yes_n  int;
  gone_n int;
begin
  if reporter_id is null or length(reporter_id) < 8 or length(reporter_id) > 64 then
    raise exception 'reporter_id must be 8 to 64 characters';
  end if;
  select left(encode(sha256(convert_to(s.salt || reporter_id, 'UTF8')), 'hex'), 32)
    into rh from private.settings s where s.id = 1;

  select p.id, p.reporter_hash, p.status, p.cleared_at into rep from public.reports p where p.id = confirm_report.report_id;
  if not found then return jsonb_build_object('status', 'not_found'); end if;
  if rep.reporter_hash = rh then return jsonb_build_object('status', 'own_report'); end if;

  select count(*) into recent from private.confirmations c
   where c.reporter_hash = rh and c.answered_at > now() - interval '1 hour';
  if recent >= 120 then return jsonb_build_object('status', 'rejected', 'reason', 'too_many_answers'); end if;

  insert into private.confirmations (report_id, reporter_hash, still_there)
  values (confirm_report.report_id, rh, confirm_report.still_there)
  on conflict on constraint confirmations_pkey do update set still_there = excluded.still_there, answered_at = now();

  select count(*) filter (where c.still_there), count(*) filter (where not c.still_there)
    into yes_n, gone_n from private.confirmations c where c.report_id = confirm_report.report_id;

  update public.reports p set
    still_there_votes = yes_n,
    gone_votes = gone_n,
    status = case when confirm_report.still_there and p.status = 'unverified' then 'confirmed' else p.status end,
    cleared_at = case when gone_n >= 2 and gone_n > yes_n then coalesce(p.cleared_at, now())
                      when yes_n >= gone_n then null else p.cleared_at end
   where p.id = confirm_report.report_id;

  return jsonb_build_object('status', 'ok', 'stillThere', yes_n, 'gone', gone_n,
                            'cleared', gone_n >= 2 and gone_n > yes_n);
end;
$$;

revoke all on function public.confirm_report(text, uuid, boolean) from public;
grant execute on function public.confirm_report(text, uuid, boolean) to anon, authenticated;

-- Map pins: hide cleared reports, and show how many drivers confirmed.
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
                                                'source', p.source, 'status', p.status, 'period', p.period,
                                                'stillThere', p.still_there_votes)) as f
        from public.reports p
       where p.lat between min_lat and max_lat and p.lon between min_lon and max_lon
         and p.observed_at >= now() - make_interval(days => least(greatest(days, 1), 365))
         and p.status in ('new', 'confirmed')
         and p.cleared_at is null
       order by p.observed_at desc
       limit 5000
    ) x;
  return result;
end;
$$;
