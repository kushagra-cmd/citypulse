-- CityPulse Migration 005: Admin-managed city announcements
-- Apply this migration to an existing project after the base CityPulse schema.
-- Only accounts explicitly assigned the `admin` role may create, edit, or delete notices.

begin;

create table if not exists public.city_announcements (
  id uuid primary key default gen_random_uuid(),
  city_id text not null references public.cities(id) on delete cascade,
  category text not null check (category in (
    'road_closure', 'water_disruption', 'electricity_maintenance', 'waste_collection',
    'public_consultation', 'city_event', 'infrastructure_maintenance', 'public_transport'
  )),
  title text not null,
  title_kn text,
  summary text not null,
  summary_kn text,
  locality text not null,
  source_agency text not null,
  source_url text not null,
  is_verified_official boolean not null default false,
  is_demo_announcement boolean not null default false,
  published_at timestamptz not null default now(),
  expires_at timestamptz,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists idx_city_announcements_city
  on public.city_announcements (city_id, published_at desc);
create index if not exists idx_city_announcements_expiry
  on public.city_announcements (expires_at)
  where expires_at is not null;

alter table public.city_announcements enable row level security;

drop policy if exists "city_announcements_public_read" on public.city_announcements;
create policy "city_announcements_public_read" on public.city_announcements
  for select using (true);

drop policy if exists "city_announcements_admin_write" on public.city_announcements;
create policy "city_announcements_admin_write" on public.city_announcements
  for all to authenticated
  using (exists (
    select 1 from public.user_roles ur
    where ur.user_id = auth.uid() and ur.role = 'admin'
  ))
  with check (exists (
    select 1 from public.user_roles ur
    where ur.user_id = auth.uid() and ur.role = 'admin'
  ));

grant select on public.city_announcements to anon, authenticated;
grant insert, update, delete on public.city_announcements to authenticated;

commit;
notify pgrst, 'reload schema';
