-- CityPulse: repair missing profile rows that cause civic_issues_author_id_fkey failures.
-- Safe to run more than once. Does not remove or weaken any foreign keys or RLS policies.

begin;

-- Validate that this is the expected CityPulse schema before installing the repair.
do $$
begin
  if to_regclass('public.profiles') is null then
    raise exception 'CityPulse prerequisite missing: public.profiles. Apply the main CityPulse schema migration first.';
  end if;
  if to_regclass('public.cities') is null then
    raise exception 'CityPulse prerequisite missing: public.cities. Apply the main CityPulse schema migration first.';
  end if;
  if to_regclass('public.user_roles') is null then
    raise exception 'CityPulse prerequisite missing: public.user_roles. Apply the main CityPulse schema migration first.';
  end if;
end $$;

-- Creates the profile associated with an auth user, deriving valid values from signup metadata.
-- SECURITY DEFINER is needed because this is called by the auth.users trigger and backfill.
create or replace function public.ensure_profile_for_auth_user(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_user auth.users%rowtype;
  v_base_username text;
  v_username text;
  v_full_name text;
  v_city_id text;
  v_language text;
  v_id_hex text;
  v_attempt integer := 0;
begin
  select u.* into v_auth_user
  from auth.users as u
  where u.id = p_user_id;

  if not found then
    return;
  end if;

  -- Don't overwrite an existing profile or account role.
  if exists (select 1 from public.profiles p where p.id = p_user_id) then
    insert into public.user_roles (user_id)
    values (p_user_id)
    on conflict (user_id) do nothing;
    return;
  end if;

  v_id_hex := replace(p_user_id::text, '-', '');

  v_full_name := nullif(btrim(coalesce(
    v_auth_user.raw_user_meta_data ->> 'full_name',
    v_auth_user.raw_user_meta_data ->> 'name',
    split_part(coalesce(v_auth_user.email, ''), '@', 1),
    ''
  )), '');
  if v_full_name is null or char_length(v_full_name) < 2 then
    v_full_name := 'Citizen ' || substr(v_id_hex, 1, 8);
  end if;
  v_full_name := left(v_full_name, 100);

  v_base_username := coalesce(
    nullif(btrim(v_auth_user.raw_user_meta_data ->> 'username'), ''),
    nullif(split_part(coalesce(v_auth_user.email, ''), '@', 1), ''),
    'citizen'
  );
  v_base_username := lower(regexp_replace(v_base_username, '[^a-zA-Z0-9_]', '_', 'g'));
  v_base_username := btrim(v_base_username, '_');
  if char_length(v_base_username) < 3 then
    v_base_username := 'citizen_' || substr(v_id_hex, 1, 8);
  end if;
  v_base_username := left(v_base_username, 30);

  v_city_id := nullif(v_auth_user.raw_user_meta_data ->> 'preferred_city_id', '');
  if v_city_id is not null and not exists (
    select 1 from public.cities c where c.id = v_city_id
  ) then
    v_city_id := null;
  end if;
  if v_city_id is null and exists (
    select 1 from public.cities c where c.id = 'bengaluru'
  ) then
    v_city_id := 'bengaluru';
  end if;

  v_language := case
    when v_auth_user.raw_user_meta_data ->> 'preferred_language' = 'kn' then 'kn'
    else 'en'
  end;

  -- Resolve username collisions without changing another user's profile.
  loop
    if v_attempt = 0 then
      v_username := v_base_username;
    elsif v_attempt = 1 then
      v_username := 'citizen_' || substr(v_id_hex, 1, 22);
    else
      v_username := 'citizen_' || substr(md5(p_user_id::text || ':' || v_attempt::text), 1, 22);
    end if;

    exit when not exists (
      select 1 from public.profiles p where lower(p.username) = lower(v_username) and p.id <> p_user_id
    );

    v_attempt := v_attempt + 1;
    if v_attempt > 25 then
      raise exception 'Unable to generate a unique CityPulse username for user %', p_user_id;
    end if;
  end loop;

  insert into public.profiles (
    id, username, full_name, preferred_city_id, preferred_language, accepted_terms_at
  ) values (
    p_user_id, v_username, v_full_name, v_city_id, v_language, now()
  )
  on conflict (id) do nothing;

  insert into public.user_roles (user_id)
  values (p_user_id)
  on conflict (user_id) do nothing;
end;
$$;

-- Automatically create a profile when a new Supabase Auth account is inserted.
create or replace function public.handle_new_auth_user_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.ensure_profile_for_auth_user(new.id);
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_profile on auth.users;
create trigger on_auth_user_created_profile
after insert on auth.users
for each row execute function public.handle_new_auth_user_profile();

-- Repair already-created accounts whose profile row is missing (including the currently signed-in user).
do $$
declare
  v_user_id uuid;
begin
  for v_user_id in
    select u.id
    from auth.users u
    left join public.profiles p on p.id = u.id
    where p.id is null
  loop
    perform public.ensure_profile_for_auth_user(v_user_id);
  end loop;
end $$;

-- Keep helper functions internal; Auth-trigger calls and SQL owner/backfill can still execute them.
revoke all on function public.ensure_profile_for_auth_user(uuid) from public, anon, authenticated;
revoke all on function public.handle_new_auth_user_profile() from public, anon, authenticated;

commit;

notify pgrst, 'reload schema';

-- Verification: should return 0 rows after the repair.
select u.id as auth_user_missing_profile
from auth.users u
left join public.profiles p on p.id = u.id
where p.id is null;
