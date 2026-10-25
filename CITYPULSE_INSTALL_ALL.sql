-- ============================================================================
-- CITYPULSE ONE-PASTE SUPABASE INSTALLER / REPAIR
-- Run this entire file ONCE in Supabase SQL Editor for the project used by .env.local.
-- It uses the canonical schema from the app's versioned migrations.
-- Incompatible leftovers from earlier repair scripts are renamed to backup tables;
-- no existing table data is dropped. Demo catalog/announcement rows are labelled in seed.sql.
-- ============================================================================

begin;


-- ===== 1/4: CANONICAL TABLES, TYPES, FUNCTIONS, INDEXES, TRIGGERS =====
-- ============================================================================
-- CityPulse — Migration 001: Core Schema, Tables, Constraints, Indexes & Triggers
-- Product: CityPulse ("Your city. Your voice. Your priorities.")
-- Backend: Supabase PostgreSQL
-- ============================================================================

create extension if not exists "pgcrypto";
create extension if not exists "pg_trgm";

-- Repair guard: preserve mismatched tables from earlier partial/alternate setup scripts.
-- Nothing is dropped. Incompatible legacy tables are renamed to citypulse_legacy_*_backup names.
do $citypulse_schema_guard$
declare
  v_table text;
  v_backup text;
  v_i integer;
  v_major_legacy boolean := false;
  v_tables text[] := array[
    'cities','profiles','user_roles','departments','civic_issues','issue_votes',
    'issue_confirmations','comments','issue_status_history','issue_media',
    'issue_watchlists','schemes','scheme_bookmarks','service_directory',
    'utility_services','bill_reminders','city_announcements','notifications',
    'content_reports','issue_live_events'
  ];
begin
  -- A non-canonical root table means related tables may point at incompatible columns/types.
  select
    (to_regclass('public.cities') is not null and not exists (
      select 1 from information_schema.columns where table_schema='public' and table_name='cities' and column_name='name_kn'
    ))
    or (to_regclass('public.profiles') is not null and not exists (
      select 1 from information_schema.columns where table_schema='public' and table_name='profiles' and column_name='accepted_terms_at'
    ))
    or (to_regclass('public.departments') is not null and not exists (
      select 1 from information_schema.columns where table_schema='public' and table_name='departments' and column_name='short_code'
    ))
    or (to_regclass('public.civic_issues') is not null and not exists (
      select 1 from information_schema.columns where table_schema='public' and table_name='civic_issues' and column_name='priority_factors'
    ))
  into v_major_legacy;

  if v_major_legacy then
    foreach v_table in array v_tables loop
      if exists (
        select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
        where n.nspname='public' and c.relname=v_table and c.relkind in ('r','p')
      ) then
        v_i := 1;
        v_backup := 'citypulse_legacy_' || v_table || '_backup';
        while to_regclass(format('public.%I', v_backup)) is not null loop
          v_i := v_i + 1;
          v_backup := 'citypulse_legacy_' || v_table || '_backup_' || v_i::text;
        end loop;
        execute format('alter table public.%I rename to %I', v_table, v_backup);
        raise notice 'Preserved incompatible table public.% as public.%', v_table, v_backup;
      end if;
    end loop;
  elsif to_regclass('public.schemes') is not null and not exists (
    select 1 from information_schema.columns where table_schema='public' and table_name='schemes' and column_name='title_kn'
  ) then
    -- The old helper script created a different `schemes` schema. Archive it rather than drop user data.
    foreach v_table in array array['schemes','scheme_bookmarks'] loop
      if exists (
        select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
        where n.nspname='public' and c.relname=v_table and c.relkind in ('r','p')
      ) then
        v_i := 1;
        v_backup := 'citypulse_legacy_' || v_table || '_backup';
        while to_regclass(format('public.%I', v_backup)) is not null loop
          v_i := v_i + 1;
          v_backup := 'citypulse_legacy_' || v_table || '_backup_' || v_i::text;
        end loop;
        execute format('alter table public.%I rename to %I', v_table, v_backup);
        raise notice 'Preserved incompatible table public.% as public.%', v_table, v_backup;
      end if;
    end loop;
  end if;
end
$citypulse_schema_guard$;

-- ----------------------------------------------------------------------------
-- 1. ENUM TYPES
-- ----------------------------------------------------------------------------
do $$ begin
  create type public.issue_category as enum (
    'roads_potholes',
    'water_supply',
    'electricity_streetlights',
    'garbage_sanitation',
    'drainage_sewage',
    'traffic_signals',
    'public_safety',
    'parks_trees',
    'encroachment',
    'public_transport',
    'noise_pollution',
    'other_civic'
  );
exception when duplicate_object then null;
end $$;

do $$ begin
  create type public.issue_severity as enum (
    'low',
    'medium',
    'high',
    'critical_safety'
  );
exception when duplicate_object then null;
end $$;

do $$ begin
  create type public.issue_status as enum (
    'reported',
    'verified',
    'assigned',
    'in_progress',
    'resolved',
    'community_verified',
    'reopened',
    'rejected_spam'
  );
exception when duplicate_object then null;
end $$;

do $$ begin
  create type public.app_role as enum (
    'citizen',
    'moderator',
    'department_officer',
    'admin'
  );
exception when duplicate_object then null;
end $$;

-- ----------------------------------------------------------------------------
-- 2. CITIES TABLE
-- ----------------------------------------------------------------------------
create table if not exists public.cities (
  id text primary key,
  name text not null,
  name_kn text not null,
  district text not null,
  region text not null default 'Karnataka',
  country text not null default 'India',
  center_latitude double precision not null check (center_latitude between -90 and 90),
  center_longitude double precision not null check (center_longitude between -180 and 180),
  default_zoom integer not null default 12 check (default_zoom between 5 and 18),
  municipal_corporation text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create index if not exists idx_cities_active on public.cities (is_active, region);

-- ----------------------------------------------------------------------------
-- 3. PROFILES TABLE (1:1 with auth.users)
-- Never exposes email publicly. Private preferences are separated via RLS/views.
-- ----------------------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique,
  full_name text not null,
  avatar_url text,
  bio text default '',
  preferred_city_id text references public.cities(id) on delete set null default 'bengaluru',
  preferred_language text not null default 'en' check (preferred_language in ('en', 'kn')),
  accepted_terms_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint username_format_chk check (
    char_length(username) between 3 and 30
    and username ~ '^[a-zA-Z0-9_]+$'
  ),
  constraint full_name_length_chk check (char_length(trim(full_name)) between 2 and 100),
  constraint bio_length_chk check (char_length(coalesce(bio, '')) <= 500)
);

create unique index if not exists idx_profiles_username_lower on public.profiles (lower(username));
create index if not exists idx_profiles_city on public.profiles (preferred_city_id);

-- ----------------------------------------------------------------------------
-- 4. USER ROLES TABLE (Separate from profiles so profile updates NEVER grant admin)
-- ----------------------------------------------------------------------------
create table if not exists public.user_roles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role public.app_role not null default 'citizen',
  assigned_department_id text,
  granted_by uuid references auth.users(id) on delete set null,
  granted_at timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- 5. DEPARTMENTS TABLE
-- ----------------------------------------------------------------------------
create table if not exists public.departments (
  id text primary key,
  city_id text references public.cities(id) on delete cascade,
  name text not null,
  name_kn text not null,
  short_code text not null,
  category_scope text[] not null default '{}',
  official_website text,
  helpline_phone text,
  is_demo_record boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists idx_departments_city on public.departments (city_id);

-- ----------------------------------------------------------------------------
-- 6. CIVIC ISSUES TABLE
-- ----------------------------------------------------------------------------
create table if not exists public.civic_issues (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references public.profiles(id) on delete cascade,
  title text not null check (char_length(trim(title)) between 8 and 180),
  description text not null check (char_length(trim(description)) between 20 and 5000),
  category public.issue_category not null,
  severity public.issue_severity not null default 'medium',
  status public.issue_status not null default 'reported',
  city_id text not null references public.cities(id) on delete restrict,
  locality text not null check (char_length(trim(locality)) between 2 and 120),
  ward text check (ward is null or char_length(trim(ward)) <= 80),
  address text check (address is null or char_length(trim(address)) <= 300),
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  location_precision text not null default 'exact' check (location_precision in ('exact', 'approximate_100m')),
  is_anonymous boolean not null default false,
  assigned_department_id text references public.departments(id) on delete set null,
  official_priority_label text check (official_priority_label in ('routine', 'elevated', 'urgent', 'emergency')),
  priority_score numeric(5,2) not null default 25.00 check (priority_score between 0 and 100),
  priority_factors jsonb not null default '[]'::jsonb,
  upvote_count integer not null default 0 check (upvote_count >= 0),
  confirmation_count integer not null default 0 check (confirmation_count >= 0),
  comment_count integer not null default 0 check (comment_count >= 0),
  last_official_update_at timestamptz,
  last_official_note text,
  resolved_at timestamptz,
  reopened_at timestamptz,
  reopen_count integer not null default 0 check (reopen_count >= 0),
  moderation_state text not null default 'active' check (moderation_state in ('active', 'flagged', 'hidden', 'archived')),
  is_archived boolean not null default false,
  is_demo_record boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_civic_issues_city_status on public.civic_issues (city_id, status, created_at desc);
create index if not exists idx_civic_issues_category on public.civic_issues (city_id, category);
create index if not exists idx_civic_issues_priority on public.civic_issues (city_id, priority_score desc, created_at desc);
create index if not exists idx_civic_issues_upvotes on public.civic_issues (city_id, upvote_count desc);
create index if not exists idx_civic_issues_coords on public.civic_issues (city_id, latitude, longitude);
create index if not exists idx_civic_issues_author on public.civic_issues (author_id, created_at desc);
create index if not exists idx_civic_issues_trgm_title on public.civic_issues using gin (title gin_trgm_ops);

-- ----------------------------------------------------------------------------
-- 7. ISSUE VOTES TABLE (Unique per issue + user)
-- ----------------------------------------------------------------------------
create table if not exists public.issue_votes (
  id uuid primary key default gen_random_uuid(),
  issue_id uuid not null references public.civic_issues(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint uq_issue_votes_issue_user unique (issue_id, user_id)
);

create index if not exists idx_issue_votes_issue on public.issue_votes (issue_id);
create index if not exists idx_issue_votes_user on public.issue_votes (user_id);

-- ----------------------------------------------------------------------------
-- 8. ISSUE CONFIRMATIONS TABLE ("I am affected" — Unique per issue + user)
-- ----------------------------------------------------------------------------
create table if not exists public.issue_confirmations (
  id uuid primary key default gen_random_uuid(),
  issue_id uuid not null references public.civic_issues(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  impact_note text check (impact_note is null or char_length(impact_note) <= 280),
  created_at timestamptz not null default now(),
  constraint uq_issue_confirmations_issue_user unique (issue_id, user_id)
);

create index if not exists idx_issue_confirmations_issue on public.issue_confirmations (issue_id);
create index if not exists idx_issue_confirmations_user on public.issue_confirmations (user_id);

-- ----------------------------------------------------------------------------
-- 9. COMMENTS TABLE (Threaded discussions with English & Kannada Unicode support)
-- ----------------------------------------------------------------------------
create table if not exists public.comments (
  id uuid primary key default gen_random_uuid(),
  issue_id uuid not null references public.civic_issues(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete cascade,
  parent_comment_id uuid references public.comments(id) on delete cascade,
  content text not null check (char_length(trim(content)) between 1 and 2000),
  evidence_url text,
  is_official_response boolean not null default false,
  moderation_state text not null default 'active' check (moderation_state in ('active', 'flagged', 'removed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_comments_issue_created on public.comments (issue_id, created_at asc);
create index if not exists idx_comments_author on public.comments (author_id, created_at desc);

-- ----------------------------------------------------------------------------
-- 10. ISSUE STATUS HISTORY TABLE (Immutable audit trail of status transitions)
-- ----------------------------------------------------------------------------
create table if not exists public.issue_status_history (
  id uuid primary key default gen_random_uuid(),
  issue_id uuid not null references public.civic_issues(id) on delete cascade,
  previous_status public.issue_status,
  new_status public.issue_status not null,
  actor_id uuid references public.profiles(id) on delete set null,
  actor_role public.app_role not null default 'citizen',
  department_id text references public.departments(id) on delete set null,
  note text not null check (char_length(trim(note)) between 3 and 1000),
  evidence_url text,
  created_at timestamptz not null default now()
);

create index if not exists idx_status_history_issue on public.issue_status_history (issue_id, created_at asc);

-- ----------------------------------------------------------------------------
-- 11. ISSUE MEDIA TABLE (References Supabase Storage objects)
-- ----------------------------------------------------------------------------
create table if not exists public.issue_media (
  id uuid primary key default gen_random_uuid(),
  issue_id uuid not null references public.civic_issues(id) on delete cascade,
  uploader_id uuid not null references public.profiles(id) on delete cascade,
  storage_bucket text not null default 'issue-media',
  storage_path text not null,
  public_url text not null,
  mime_type text not null check (mime_type in ('image/jpeg', 'image/png', 'image/webp')),
  file_size_bytes integer not null check (file_size_bytes > 0 and file_size_bytes <= 5242880),
  caption text check (caption is null or char_length(caption) <= 200),
  created_at timestamptz not null default now()
);

create index if not exists idx_issue_media_issue on public.issue_media (issue_id);

-- ----------------------------------------------------------------------------
-- 12. ISSUE WATCHLISTS TABLE (Saved / Followed issues)
-- ----------------------------------------------------------------------------
create table if not exists public.issue_watchlists (
  id uuid primary key default gen_random_uuid(),
  issue_id uuid not null references public.civic_issues(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  notify_on_status_change boolean not null default true,
  created_at timestamptz not null default now(),
  constraint uq_issue_watchlists_issue_user unique (issue_id, user_id)
);

create index if not exists idx_issue_watchlists_user on public.issue_watchlists (user_id, created_at desc);

-- ----------------------------------------------------------------------------
-- 13. SCHEMES & SCHEME BOOKMARKS TABLES
-- ----------------------------------------------------------------------------
create table if not exists public.schemes (
  id text primary key,
  title text not null,
  title_kn text not null,
  category text not null check (category in (
    'education_scholarships',
    'employment',
    'skill_development',
    'housing',
    'healthcare',
    'pensions',
    'agriculture',
    'financial_assistance',
    'women_child_welfare',
    'other_benefits'
  )),
  region_scope text not null default 'Karnataka & National',
  applicable_cities text[] not null default '{all}',
  summary text not null,
  summary_kn text not null,
  eligibility_criteria jsonb not null default '[]'::jsonb,
  eligibility_rules jsonb not null default '{}'::jsonb,
  required_documents text[] not null default '{}',
  application_steps text[] not null default '{}',
  official_source_url text not null,
  official_portal_name text not null,
  last_verified_date date not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create index if not exists idx_schemes_category on public.schemes (category, is_active);

create table if not exists public.scheme_bookmarks (
  id uuid primary key default gen_random_uuid(),
  scheme_id text not null references public.schemes(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  reminder_date date,
  personal_note text check (personal_note is null or char_length(personal_note) <= 300),
  created_at timestamptz not null default now(),
  constraint uq_scheme_bookmarks_user_scheme unique (scheme_id, user_id)
);

-- ----------------------------------------------------------------------------
-- 14. SERVICE DIRECTORY, UTILITY SERVICES & BILL REMINDERS TABLES
-- ----------------------------------------------------------------------------
create table if not exists public.service_directory (
  id text primary key,
  city_id text references public.cities(id) on delete cascade,
  title text not null,
  title_kn text not null,
  category text not null,
  provider_name text not null,
  description text not null,
  instructions text[] not null default '{}',
  official_url text not null,
  helpline text,
  last_verified_date date not null default current_date,
  created_at timestamptz not null default now()
);

create index if not exists idx_service_directory_city on public.service_directory (city_id, category);

create table if not exists public.utility_services (
  id text primary key,
  city_id text not null references public.cities(id) on delete cascade,
  service_type text not null check (service_type in (
    'electricity',
    'water',
    'gas_lpg',
    'property_tax',
    'drainage_sanitation',
    'broadband_telecom',
    'citizen_one_portal'
  )),
  provider_code text not null,
  provider_name text not null,
  provider_name_kn text not null,
  locality_applicability text not null default 'All wards / City-wide',
  official_portal_url text not null,
  instructions text not null,
  helpline_number text,
  created_at timestamptz not null default now()
);

create index if not exists idx_utility_services_city_type on public.utility_services (city_id, service_type);

create table if not exists public.bill_reminders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  utility_service_id text references public.utility_services(id) on delete set null,
  city_id text not null references public.cities(id) on delete cascade,
  title text not null check (char_length(trim(title)) between 2 and 120),
  service_type text not null,
  consumer_reference_label text check (consumer_reference_label is null or char_length(consumer_reference_label) <= 60),
  due_date date not null,
  estimated_amount_inr numeric(10,2) check (estimated_amount_inr is null or estimated_amount_inr >= 0),
  is_paid_simulated boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists idx_bill_reminders_user on public.bill_reminders (user_id, due_date asc);

-- ----------------------------------------------------------------------------
-- 15. CITY ANNOUNCEMENTS TABLE
-- ----------------------------------------------------------------------------
create table if not exists public.city_announcements (
  id uuid primary key default gen_random_uuid(),
  city_id text not null references public.cities(id) on delete cascade,
  category text not null check (category in (
    'road_closure',
    'water_disruption',
    'electricity_maintenance',
    'waste_collection',
    'public_consultation',
    'city_event',
    'infrastructure_maintenance',
    'public_transport'
  )),
  title text not null,
  title_kn text,
  summary text not null,
  summary_kn text,
  locality text not null,
  source_agency text not null,
  source_url text not null,
  is_verified_official boolean not null default true,
  is_demo_announcement boolean not null default true,
  published_at timestamptz not null default now(),
  expires_at timestamptz,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists idx_city_announcements_city on public.city_announcements (city_id, published_at desc);

-- ----------------------------------------------------------------------------
-- 16. NOTIFICATIONS TABLE
-- ----------------------------------------------------------------------------
create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  notification_type text not null check (notification_type in (
    'comment_on_issue',
    'comment_reply',
    'official_status_update',
    'watched_issue_update',
    'issue_resolved',
    'account_notice'
  )),
  title text not null,
  body text not null,
  related_issue_id uuid references public.civic_issues(id) on delete cascade,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists idx_notifications_recipient on public.notifications (recipient_id, is_read, created_at desc);

-- ----------------------------------------------------------------------------
-- 17. CONTENT REPORTS TABLE (Abuse / Spam / Misleading moderation queue)
-- ----------------------------------------------------------------------------
create table if not exists public.content_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  target_type text not null check (target_type in ('issue', 'comment')),
  target_issue_id uuid references public.civic_issues(id) on delete cascade,
  target_comment_id uuid references public.comments(id) on delete cascade,
  reason text not null check (reason in ('spam', 'abusive_language', 'impersonation', 'misleading_info', 'privacy_violation')),
  details text check (details is null or char_length(details) <= 500),
  resolution_status text not null default 'pending' check (resolution_status in ('pending', 'reviewed_actioned', 'dismissed')),
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists idx_content_reports_status on public.content_reports (resolution_status, created_at desc);

-- ----------------------------------------------------------------------------
-- 18. SMART PRIORITY SCORE CALCULATION & TRIGGERS
-- ----------------------------------------------------------------------------
create or replace function public.calculate_issue_priority(
  p_severity public.issue_severity,
  p_category public.issue_category,
  p_upvotes integer,
  p_confirmations integer,
  p_created_at timestamptz,
  p_status public.issue_status
) returns jsonb
language plpgsql
immutable
as $$
declare
  v_severity_pts numeric := 15;
  v_safety_boost numeric := 0;
  v_confirmation_pts numeric := 0;
  v_upvote_pts numeric := 0;
  v_age_pts numeric := 0;
  v_infra_pts numeric := 0;
  v_total numeric := 0;
  v_hours_open numeric := 0;
  v_factors jsonb := '[]'::jsonb;
begin
  if p_status in ('resolved', 'community_verified', 'rejected_spam') then
    return jsonb_build_object(
      'score', 10.0,
      'factors', jsonb_build_array('Resolved or closed')
    );
  end if;

  case p_severity
    when 'critical_safety' then
      v_severity_pts := 38;
      v_safety_boost := 15;
      v_factors := v_factors || jsonb_build_array('Critical safety hazard (+53)');
    when 'high' then
      v_severity_pts := 28;
      v_factors := v_factors || jsonb_build_array('High severity (+28)');
    when 'medium' then
      v_severity_pts := 18;
      v_factors := v_factors || jsonb_build_array('Medium severity (+18)');
    else
      v_severity_pts := 10;
      v_factors := v_factors || jsonb_build_array('Low severity (+10)');
  end case;

  if p_category in ('public_safety', 'water_supply', 'drainage_sewage', 'electricity_streetlights', 'roads_potholes') then
    v_infra_pts := 10;
    v_factors := v_factors || jsonb_build_array('Core public infrastructure impact (+10)');
  else
    v_infra_pts := 5;
  end if;

  v_confirmation_pts := least(20, coalesce(p_confirmations, 0) * 3.5);
  if v_confirmation_pts > 0 then
    v_factors := v_factors || jsonb_build_array(format('%s affected confirmations (+%s)', p_confirmations, round(v_confirmation_pts, 1)));
  end if;

  v_upvote_pts := least(12, coalesce(p_upvotes, 0) * 1.2);
  if v_upvote_pts > 0 then
    v_factors := v_factors || jsonb_build_array(format('%s community upvotes (+%s)', p_upvotes, round(v_upvote_pts, 1)));
  end if;

  v_hours_open := greatest(0, extract(epoch from (now() - coalesce(p_created_at, now()))) / 3600.0);
  v_age_pts := least(10, round((v_hours_open / 24.0) * 1.5, 1));
  if v_age_pts >= 1.5 then
    v_factors := v_factors || jsonb_build_array(format('Unresolved duration factor (+%s)', v_age_pts));
  end if;

  v_total := least(100.0, round(v_severity_pts + v_safety_boost + v_infra_pts + v_confirmation_pts + v_upvote_pts + v_age_pts, 2));

  return jsonb_build_object(
    'score', v_total,
    'factors', v_factors
  );
end;
$$;

-- Trigger to enforce immutable original reporting fields and recompute priority
create or replace function public.trg_civic_issues_before_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_calc jsonb;
  v_is_admin boolean;
begin
  if tg_op = 'UPDATE' then
    -- Never allow changing original author_id or original created_at timestamp
    if new.author_id <> old.author_id then
      raise exception 'Impersonation prohibited: author_id cannot be modified after creation';
    end if;
    if new.created_at <> old.created_at then
      raise exception 'Original report timestamp (created_at) is immutable';
    end if;

    -- Only admins/officers/moderators can transition official status
    if new.status <> old.status or new.assigned_department_id is distinct from old.assigned_department_id or new.last_official_note is distinct from old.last_official_note then
      select exists (
        select 1 from public.user_roles ur
        where ur.user_id = auth.uid()
          and ur.role in ('admin', 'moderator', 'department_officer')
      ) into v_is_admin;

      if not coalesce(v_is_admin, false) and current_setting('role', true) = 'authenticated' then
        raise exception 'Unauthorized: Only authorized administrators or department officers can publish official status transitions';
      end if;
    end if;

    if new.status = 'resolved' and old.status <> 'resolved' then
      new.resolved_at := now();
    elsif new.status = 'reopened' and old.status in ('resolved', 'community_verified') then
      new.reopened_at := now();
      new.reopen_count := coalesce(old.reopen_count, 0) + 1;
    end if;

    new.updated_at := now();
  end if;

  v_calc := public.calculate_issue_priority(
    new.severity,
    new.category,
    new.upvote_count,
    new.confirmation_count,
    new.created_at,
    new.status
  );
  new.priority_score := (v_calc->>'score')::numeric;
  new.priority_factors := v_calc->'factors';

  return new;
end;
$$;

drop trigger if exists trg_civic_issues_before_write on public.civic_issues;
create trigger trg_civic_issues_before_write
before insert or update on public.civic_issues
for each row execute function public.trg_civic_issues_before_write();

-- Trigger to automatically insert initial status history on issue creation
create or replace function public.trg_civic_issues_after_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.issue_status_history (
    issue_id,
    previous_status,
    new_status,
    actor_id,
    actor_role,
    note
  ) values (
    new.id,
    null,
    new.status,
    new.author_id,
    'citizen',
    'Issue reported by citizen on CityPulse.'
  );
  return new;
end;
$$;

drop trigger if exists trg_civic_issues_after_insert on public.civic_issues;
create trigger trg_civic_issues_after_insert
after insert on public.civic_issues
for each row execute function public.trg_civic_issues_after_insert();

-- Trigger to maintain upvote_count on civic_issues
create or replace function public.trg_sync_issue_vote_count()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    update public.civic_issues
       set upvote_count = upvote_count + 1
     where id = new.issue_id;
    return new;
  elsif tg_op = 'DELETE' then
    update public.civic_issues
       set upvote_count = greatest(0, upvote_count - 1)
     where id = old.issue_id;
    return old;
  end if;
  return null;
end;
$$;

drop trigger if exists trg_sync_issue_vote_count on public.issue_votes;
create trigger trg_sync_issue_vote_count
after insert or delete on public.issue_votes
for each row execute function public.trg_sync_issue_vote_count();

-- Trigger to maintain confirmation_count on civic_issues
create or replace function public.trg_sync_issue_confirmation_count()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    update public.civic_issues
       set confirmation_count = confirmation_count + 1
     where id = new.issue_id;
    return new;
  elsif tg_op = 'DELETE' then
    update public.civic_issues
       set confirmation_count = greatest(0, confirmation_count - 1)
     where id = old.issue_id;
    return old;
  end if;
  return null;
end;
$$;

drop trigger if exists trg_sync_issue_confirmation_count on public.issue_confirmations;
create trigger trg_sync_issue_confirmation_count
after insert or delete on public.issue_confirmations
for each row execute function public.trg_sync_issue_confirmation_count();

-- Trigger to maintain comment_count and notify issue author
create or replace function public.trg_sync_comment_count()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_issue_author uuid;
  v_issue_title text;
begin
  if tg_op = 'INSERT' then
    update public.civic_issues
       set comment_count = comment_count + 1
     where id = new.issue_id
     returning author_id, title into v_issue_author, v_issue_title;

    if v_issue_author is not null and v_issue_author <> new.author_id then
      insert into public.notifications (
        recipient_id,
        notification_type,
        title,
        body,
        related_issue_id
      ) values (
        v_issue_author,
        'comment_on_issue',
        'New comment on your civic report',
        format('Someone commented on "%s"', left(v_issue_title, 80)),
        new.issue_id
      );
    end if;
    return new;
  elsif tg_op = 'DELETE' then
    update public.civic_issues
       set comment_count = greatest(0, comment_count - 1)
     where id = old.issue_id;
    return old;
  end if;
  return null;
end;
$$;

drop trigger if exists trg_sync_comment_count on public.comments;
create trigger trg_sync_comment_count
after insert or delete on public.comments
for each row execute function public.trg_sync_comment_count();


-- ===== 2/4: ROW LEVEL SECURITY, LEAST-PRIVILEGE GRANTS, ADMIN RPCS =====
-- ============================================================================
-- CityPulse — Migration 002: Row-Level Security (RLS), Least-Privilege Grants,
-- and Protected Administrative Functions
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. HELPER FUNCTIONS FOR AUTHORIZATION
-- ----------------------------------------------------------------------------
create or replace function public.is_authorized_admin(p_user_id uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.user_roles ur
    where ur.user_id = coalesce(p_user_id, auth.uid())
      and ur.role in ('admin', 'moderator', 'department_officer')
  );
$$;

-- Owner-only server-side procedure to promote a user to admin/officer.
-- Ordinary authenticated users CANNOT execute this function to promote themselves.
create or replace function public.promote_user_to_role(
  p_target_user_id uuid,
  p_new_role public.app_role,
  p_department_id text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Allow execution only by Postgres superuser / service_role or an existing 'admin'
  if current_user not in ('postgres', 'supabase_admin', 'service_role') then
    if not exists (
      select 1 from public.user_roles
      where user_id = auth.uid() and role = 'admin'
    ) then
      raise exception 'Access denied: Only database owners or existing administrators can grant administrative roles';
    end if;
  end if;

  insert into public.user_roles (user_id, role, assigned_department_id, granted_by, granted_at)
  values (p_target_user_id, p_new_role, p_department_id, auth.uid(), now())
  on conflict (user_id)
  do update set
    role = excluded.role,
    assigned_department_id = excluded.assigned_department_id,
    granted_by = excluded.granted_by,
    granted_at = now();
end;
$$;

-- Protected RPC for administrators to transition issue status and record history atomically
create or replace function public.admin_transition_issue_status(
  p_issue_id uuid,
  p_new_status public.issue_status,
  p_note text,
  p_department_id text default null,
  p_evidence_url text default null,
  p_official_priority text default null
)
returns public.civic_issues
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role public.app_role;
  v_old_status public.issue_status;
  v_updated public.civic_issues;
begin
  select role into v_role
  from public.user_roles
  where user_id = auth.uid();

  if v_role is null or v_role not in ('admin', 'moderator', 'department_officer') then
    raise exception 'Unauthorized: Administrator or Department Officer role required to update official status';
  end if;

  select status into v_old_status
  from public.civic_issues
  where id = p_issue_id
  for update;

  if not found then
    raise exception 'Civic issue % not found', p_issue_id;
  end if;

  update public.civic_issues
     set status = p_new_status,
         assigned_department_id = coalesce(p_department_id, assigned_department_id),
         official_priority_label = coalesce(p_official_priority, official_priority_label),
         last_official_update_at = now(),
         last_official_note = p_note,
         resolved_at = case when p_new_status = 'resolved' then now() else resolved_at end,
         reopened_at = case when p_new_status = 'reopened' then now() else reopened_at end,
         reopen_count = case when p_new_status = 'reopened' and v_old_status in ('resolved', 'community_verified') then reopen_count + 1 else reopen_count end,
         updated_at = now()
   where id = p_issue_id
   returning * into v_updated;

  insert into public.issue_status_history (
    issue_id,
    previous_status,
    new_status,
    actor_id,
    actor_role,
    department_id,
    note,
    evidence_url
  ) values (
    p_issue_id,
    v_old_status,
    p_new_status,
    auth.uid(),
    v_role,
    coalesce(p_department_id, v_updated.assigned_department_id),
    p_note,
    p_evidence_url
  );

  -- Notify issue author and watchers
  insert into public.notifications (recipient_id, notification_type, title, body, related_issue_id)
  select distinct uid,
         case when p_new_status = 'resolved' then 'issue_resolved' else 'official_status_update' end,
         format('Official update: %s', replace(p_new_status::text, '_', ' ')),
         left(p_note, 200),
         p_issue_id
    from (
      select v_updated.author_id as uid
      union
      select w.user_id as uid from public.issue_watchlists w where w.issue_id = p_issue_id and w.notify_on_status_change = true
    ) recipients
   where uid <> auth.uid();

  return v_updated;
end;
$$;

-- ----------------------------------------------------------------------------
-- 2. ENABLE ROW LEVEL SECURITY ON ALL TABLES
-- ----------------------------------------------------------------------------
alter table public.cities enable row level security;
alter table public.profiles enable row level security;
alter table public.user_roles enable row level security;
alter table public.departments enable row level security;
alter table public.civic_issues enable row level security;
alter table public.issue_votes enable row level security;
alter table public.issue_confirmations enable row level security;
alter table public.comments enable row level security;
alter table public.issue_status_history enable row level security;
alter table public.issue_media enable row level security;
alter table public.issue_watchlists enable row level security;
alter table public.schemes enable row level security;
alter table public.scheme_bookmarks enable row level security;
alter table public.service_directory enable row level security;
alter table public.utility_services enable row level security;
alter table public.bill_reminders enable row level security;
alter table public.city_announcements enable row level security;
alter table public.notifications enable row level security;
alter table public.content_reports enable row level security;

-- ----------------------------------------------------------------------------
-- 3. RLS POLICIES
-- ----------------------------------------------------------------------------

-- CITIES: Public read, admin write
drop policy if exists "cities_public_read" on public.cities;
create policy "cities_public_read" on public.cities
  for select using (is_active = true or public.is_authorized_admin());

drop policy if exists "cities_admin_write" on public.cities;
create policy "cities_admin_write" on public.cities
  for all to authenticated
  using (public.is_authorized_admin())
  with check (public.is_authorized_admin());

-- PROFILES: Public can read public profile fields; users can insert/update ONLY their own row
drop policy if exists "profiles_public_read" on public.profiles;
create policy "profiles_public_read" on public.profiles
  for select using (true);

drop policy if exists "profiles_self_insert" on public.profiles;
create policy "profiles_self_insert" on public.profiles
  for insert to authenticated
  with check (auth.uid() = id);

drop policy if exists "profiles_self_update" on public.profiles;
create policy "profiles_self_update" on public.profiles
  for update to authenticated
  using (auth.uid() = id)
  with check (auth.uid() = id);

-- USER_ROLES: Users can read roles; NO direct client insert/update/delete allowed
drop policy if exists "user_roles_read" on public.user_roles;
create policy "user_roles_read" on public.user_roles
  for select using (true);

-- Explicitly deny direct client mutations on user_roles (must go through promote_user_to_role)
drop policy if exists "user_roles_no_direct_insert" on public.user_roles;
create policy "user_roles_no_direct_insert" on public.user_roles
  for insert to authenticated
  with check (false);

drop policy if exists "user_roles_no_direct_update" on public.user_roles;
create policy "user_roles_no_direct_update" on public.user_roles
  for update to authenticated
  using (false)
  with check (false);

-- DEPARTMENTS: Public read, admin write
drop policy if exists "departments_public_read" on public.departments;
create policy "departments_public_read" on public.departments
  for select using (true);

drop policy if exists "departments_admin_write" on public.departments;
create policy "departments_admin_write" on public.departments
  for all to authenticated
  using (public.is_authorized_admin())
  with check (public.is_authorized_admin());

-- CIVIC_ISSUES:
-- Public visitors can read active/flagged non-hidden issues
drop policy if exists "civic_issues_public_read" on public.civic_issues;
create policy "civic_issues_public_read" on public.civic_issues
  for select using (
    (moderation_state in ('active', 'flagged') and is_archived = false)
    or author_id = auth.uid()
    or public.is_authorized_admin()
  );

-- Authenticated users can create issues ONLY as themselves (author_id = auth.uid()) and initial status = 'reported'
drop policy if exists "civic_issues_self_insert" on public.civic_issues;
create policy "civic_issues_self_insert" on public.civic_issues
  for insert to authenticated
  with check (
    auth.uid() = author_id
    and status = 'reported'
  );

-- Authors can update their own issue text/details; admins can update status/moderation
drop policy if exists "civic_issues_owner_or_admin_update" on public.civic_issues;
create policy "civic_issues_owner_or_admin_update" on public.civic_issues
  for update to authenticated
  using (auth.uid() = author_id or public.is_authorized_admin())
  with check (auth.uid() = author_id or public.is_authorized_admin());

-- Authors can delete their own unverified reported issue; admins can delete spam
drop policy if exists "civic_issues_owner_or_admin_delete" on public.civic_issues;
create policy "civic_issues_owner_or_admin_delete" on public.civic_issues
  for delete to authenticated
  using ((auth.uid() = author_id and status = 'reported') or public.is_authorized_admin());

-- ISSUE_VOTES: Public read, authenticated users vote/unvote ONLY as themselves
drop policy if exists "issue_votes_public_read" on public.issue_votes;
create policy "issue_votes_public_read" on public.issue_votes
  for select using (true);

drop policy if exists "issue_votes_self_insert" on public.issue_votes;
create policy "issue_votes_self_insert" on public.issue_votes
  for insert to authenticated
  with check (auth.uid() = user_id);

drop policy if exists "issue_votes_self_delete" on public.issue_votes;
create policy "issue_votes_self_delete" on public.issue_votes
  for delete to authenticated
  using (auth.uid() = user_id);

-- ISSUE_CONFIRMATIONS: Public read, authenticated users confirm ONLY as themselves
drop policy if exists "issue_confirmations_public_read" on public.issue_confirmations;
create policy "issue_confirmations_public_read" on public.issue_confirmations
  for select using (true);

drop policy if exists "issue_confirmations_self_insert" on public.issue_confirmations;
create policy "issue_confirmations_self_insert" on public.issue_confirmations
  for insert to authenticated
  with check (auth.uid() = user_id);

drop policy if exists "issue_confirmations_self_delete" on public.issue_confirmations;
create policy "issue_confirmations_self_delete" on public.issue_confirmations
  for delete to authenticated
  using (auth.uid() = user_id);

-- COMMENTS: Public read active comments; authenticated users insert/update/delete ONLY their own
drop policy if exists "comments_public_read" on public.comments;
create policy "comments_public_read" on public.comments
  for select using (moderation_state <> 'removed' or author_id = auth.uid() or public.is_authorized_admin());

drop policy if exists "comments_self_insert" on public.comments;
create policy "comments_self_insert" on public.comments
  for insert to authenticated
  with check (
    auth.uid() = author_id
    and (is_official_response = false or public.is_authorized_admin())
  );

drop policy if exists "comments_self_update" on public.comments;
create policy "comments_self_update" on public.comments
  for update to authenticated
  using (auth.uid() = author_id or public.is_authorized_admin())
  with check (auth.uid() = author_id or public.is_authorized_admin());

drop policy if exists "comments_self_delete" on public.comments;
create policy "comments_self_delete" on public.comments
  for delete to authenticated
  using (auth.uid() = author_id or public.is_authorized_admin());

-- ISSUE_STATUS_HISTORY: Public read; ONLY authorized administrators can insert direct status transitions
drop policy if exists "issue_status_history_public_read" on public.issue_status_history;
create policy "issue_status_history_public_read" on public.issue_status_history
  for select using (true);

drop policy if exists "issue_status_history_admin_insert" on public.issue_status_history;
create policy "issue_status_history_admin_insert" on public.issue_status_history
  for insert to authenticated
  with check (
    public.is_authorized_admin()
    and actor_id = auth.uid()
  );

-- ISSUE_MEDIA: Public read; uploader can insert for their own upload
drop policy if exists "issue_media_public_read" on public.issue_media;
create policy "issue_media_public_read" on public.issue_media
  for select using (true);

drop policy if exists "issue_media_self_insert" on public.issue_media;
create policy "issue_media_self_insert" on public.issue_media
  for insert to authenticated
  with check (auth.uid() = uploader_id);

drop policy if exists "issue_media_self_delete" on public.issue_media;
create policy "issue_media_self_delete" on public.issue_media
  for delete to authenticated
  using (auth.uid() = uploader_id or public.is_authorized_admin());

-- ISSUE_WATCHLISTS: Private to the owning user
drop policy if exists "issue_watchlists_self_all" on public.issue_watchlists;
create policy "issue_watchlists_self_all" on public.issue_watchlists
  for all to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- SCHEMES: Public read; admin write
drop policy if exists "schemes_public_read" on public.schemes;
create policy "schemes_public_read" on public.schemes
  for select using (is_active = true or public.is_authorized_admin());

drop policy if exists "schemes_admin_write" on public.schemes;
create policy "schemes_admin_write" on public.schemes
  for all to authenticated
  using (public.is_authorized_admin())
  with check (public.is_authorized_admin());

-- SCHEME_BOOKMARKS: Private to the owning user
drop policy if exists "scheme_bookmarks_self_all" on public.scheme_bookmarks;
create policy "scheme_bookmarks_self_all" on public.scheme_bookmarks
  for all to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- SERVICE_DIRECTORY & UTILITY_SERVICES: Public read; admin write
drop policy if exists "service_directory_public_read" on public.service_directory;
create policy "service_directory_public_read" on public.service_directory
  for select using (true);

drop policy if exists "utility_services_public_read" on public.utility_services;
create policy "utility_services_public_read" on public.utility_services
  for select using (true);

-- BILL_REMINDERS: Strictly private to the owning user
drop policy if exists "bill_reminders_self_all" on public.bill_reminders;
create policy "bill_reminders_self_all" on public.bill_reminders
  for all to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- CITY_ANNOUNCEMENTS: Public read; admin write
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

-- NOTIFICATIONS: Strictly private to recipient
drop policy if exists "notifications_recipient_select" on public.notifications;
create policy "notifications_recipient_select" on public.notifications
  for select to authenticated
  using (auth.uid() = recipient_id);

drop policy if exists "notifications_recipient_update" on public.notifications;
create policy "notifications_recipient_update" on public.notifications
  for update to authenticated
  using (auth.uid() = recipient_id)
  with check (auth.uid() = recipient_id);

-- CONTENT_REPORTS: Authenticated users can submit; only reporter or admin can view; only admin can update
drop policy if exists "content_reports_self_insert" on public.content_reports;
create policy "content_reports_self_insert" on public.content_reports
  for insert to authenticated
  with check (auth.uid() = reporter_id);

drop policy if exists "content_reports_read" on public.content_reports;
create policy "content_reports_read" on public.content_reports
  for select to authenticated
  using (auth.uid() = reporter_id or public.is_authorized_admin());

drop policy if exists "content_reports_admin_update" on public.content_reports;
create policy "content_reports_admin_update" on public.content_reports
  for update to authenticated
  using (public.is_authorized_admin())
  with check (public.is_authorized_admin());

-- ----------------------------------------------------------------------------
-- 4. EXPLICIT LEAST-PRIVILEGE GRANTS
-- ----------------------------------------------------------------------------
revoke all on all tables in schema public from anon, authenticated;

-- Anon read-only public tables
grant select on
  public.cities,
  public.profiles,
  public.user_roles,
  public.departments,
  public.civic_issues,
  public.issue_votes,
  public.issue_confirmations,
  public.comments,
  public.issue_status_history,
  public.issue_media,
  public.schemes,
  public.service_directory,
  public.utility_services,
  public.city_announcements
to anon;

-- Authenticated user privileges (further restricted by RLS)
grant select on
  public.cities,
  public.profiles,
  public.user_roles,
  public.departments,
  public.civic_issues,
  public.issue_votes,
  public.issue_confirmations,
  public.comments,
  public.issue_status_history,
  public.issue_media,
  public.issue_watchlists,
  public.schemes,
  public.scheme_bookmarks,
  public.service_directory,
  public.utility_services,
  public.bill_reminders,
  public.city_announcements,
  public.notifications,
  public.content_reports
to authenticated;

grant insert, update on public.profiles to authenticated;
grant insert, update, delete on public.civic_issues to authenticated;
grant insert, delete on public.issue_votes to authenticated;
grant insert, delete on public.issue_confirmations to authenticated;
grant insert, update, delete on public.comments to authenticated;
grant insert on public.issue_status_history to authenticated;
grant insert, delete on public.issue_media to authenticated;
grant insert, update, delete on public.issue_watchlists to authenticated;
grant insert, update, delete on public.scheme_bookmarks to authenticated;
grant insert, update, delete on public.bill_reminders to authenticated;
grant insert, update, delete on public.city_announcements to authenticated;
grant update on public.notifications to authenticated;
grant insert, update on public.content_reports to authenticated;

grant execute on function public.calculate_issue_priority to anon, authenticated;
grant execute on function public.is_authorized_admin to anon, authenticated;
grant execute on function public.admin_transition_issue_status to authenticated;
grant execute on function public.promote_user_to_role to authenticated;


-- ===== 3/4: STORAGE BUCKETS AND ACCESS POLICIES =====
-- ============================================================================
-- CityPulse — Migration 003: Supabase Storage Buckets & Upload Security Policies
-- Buckets:
--   1. issue-media (public read, authenticated upload <= 5MB, image MIME types)
--   2. avatars (public read, authenticated upload <= 2MB, image MIME types)
--   3. resolution-evidence (public read, admin/officer upload <= 5MB)
-- ============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('issue-media', 'issue-media', true, 5242880, array['image/jpeg', 'image/png', 'image/webp']),
  ('avatars', 'avatars', true, 2097152, array['image/jpeg', 'image/png', 'image/webp']),
  ('resolution-evidence', 'resolution-evidence', true, 5242880, array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- Public read access for public buckets
drop policy if exists "storage_public_read" on storage.objects;
create policy "storage_public_read" on storage.objects
  for select using (bucket_id in ('issue-media', 'avatars', 'resolution-evidence'));

-- Authenticated users can upload issue media only into their own user-id folder prefix: {auth.uid()}/{filename}
drop policy if exists "issue_media_authenticated_insert" on storage.objects;
create policy "issue_media_authenticated_insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'issue-media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "issue_media_owner_delete" on storage.objects;
create policy "issue_media_owner_delete" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'issue-media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- Authenticated users can upload/replace only their own avatar under {auth.uid()}/{filename}
drop policy if exists "avatars_authenticated_insert" on storage.objects;
create policy "avatars_authenticated_insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "avatars_owner_update" on storage.objects;
create policy "avatars_owner_update" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- Only authorized administrators / officers can upload resolution evidence
drop policy if exists "resolution_evidence_admin_insert" on storage.objects;
create policy "resolution_evidence_admin_insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'resolution-evidence'
    and public.is_authorized_admin()
  );


-- ===== 4/4: CITY/SERVICE/SCHEME CATALOG SEED DATA =====
-- ============================================================================
-- CityPulse — Reproducible Seed Script (supabase/seed.sql)
-- Populates:
--   1. Cities & Towns across Karnataka (with real coordinates)
--   2. Civic Departments (verified & clearly labelled demo metadata)
--   3. Government Schemes (verifiable official sources & Kannada translations)
--   4. Service Directory & City-Specific Utility Providers
--   5. Clearly labelled Demo City Announcements
-- ============================================================================

-- 1. KARNATAKA CITIES & TOWNS
insert into public.cities (id, name, name_kn, district, region, country, center_latitude, center_longitude, default_zoom, municipal_corporation, is_active)
values
  ('bengaluru', 'Bengaluru', 'ಬೆಂಗಳೂರು', 'Bengaluru Urban', 'Karnataka', 'India', 12.9716, 77.5946, 12, 'Bruhat Bengaluru Mahanagara Palike (BBMP)', true),
  ('mysuru', 'Mysuru', 'ಮೈಸೂರು', 'Mysuru', 'Karnataka', 'India', 12.2958, 76.6394, 13, 'Mysuru City Corporation (MCC)', true),
  ('mangaluru', 'Mangaluru', 'ಮಂಗಳೂರು', 'Dakshina Kannada', 'Karnataka', 'India', 12.9141, 74.8560, 13, 'Mangaluru City Corporation (MCC)', true),
  ('hubballi_dharwad', 'Hubballi-Dharwad', 'ಹುಬ್ಬಳ್ಳಿ-ಧಾರವಾಡ', 'Dharwad', 'Karnataka', 'India', 15.3647, 75.1240, 12, 'Hubballi-Dharwad Municipal Corporation (HDMC)', true),
  ('belagavi', 'Belagavi', 'ಬೆಳಗಾವಿ', 'Belagavi', 'Karnataka', 'India', 15.8497, 74.4977, 13, 'Belagavi City Corporation (BCC)', true),
  ('kalaburagi', 'Kalaburagi', 'ಕಲಬುರಗಿ', 'Kalaburagi', 'Karnataka', 'India', 17.3297, 76.8343, 13, 'Kalaburagi Mahanagara Palike (KMP)', true),
  ('davanagere', 'Davanagere', 'ದಾವಣಗೆರೆ', 'Davanagere', 'Karnataka', 'India', 14.4644, 75.9218, 13, 'Davanagere City Corporation (DCC)', true),
  ('shivamogga', 'Shivamogga', 'ಶಿವಮೊಗ್ಗ', 'Shivamogga', 'Karnataka', 'India', 13.9299, 75.5681, 13, 'Shivamogga City Corporation (SCC)', true),
  ('tumakuru', 'Tumakuru', 'ತುಮಕೂರು', 'Tumakuru', 'Karnataka', 'India', 13.3379, 77.1173, 13, 'Tumakuru City Corporation (TCC)', true),
  ('udupi', 'Udupi', 'ಉಡುಪಿ', 'Udupi', 'Karnataka', 'India', 13.3409, 74.7421, 13, 'Udupi City Municipal Council (UCMC)', true)
on conflict (id) do update set
  name = excluded.name,
  name_kn = excluded.name_kn,
  center_latitude = excluded.center_latitude,
  center_longitude = excluded.center_longitude,
  municipal_corporation = excluded.municipal_corporation;

-- 2. DEPARTMENTS
insert into public.departments (id, city_id, name, name_kn, short_code, category_scope, official_website, helpline_phone, is_demo_record)
values
  ('bbmp_roads', 'bengaluru', 'BBMP Road Infrastructure & Pothole Cell', 'ಬಿಬಿಎಂಪಿ ರಸ್ತೆ ಮೂಲಸೌಕರ್ಯ ವಿಭಾಗ', 'BBMP-RI', array['roads_potholes','encroachment'], 'https://site.bbmp.gov.in/', '1533', false),
  ('bwssb_water', 'bengaluru', 'Bangalore Water Supply and Sewerage Board (BWSSB)', 'ಬೆಂಗಳೂರು ನೀರು ಸರಬರಾಜು ಮತ್ತು ಒಳಚರಂಡಿ ಮಂಡಳಿ', 'BWSSB', array['water_supply','drainage_sewage'], 'https://bwssb.karnataka.gov.in/', '1916', false),
  ('bescom_power', 'bengaluru', 'Bangalore Electricity Supply Company (BESCOM)', 'ಬೆಂಗಳೂರು ವಿದ್ಯುತ್ ಸರಬರಾಜು ಕಂಪನಿ (ಬೆಸ್ಕಾಂ)', 'BESCOM', array['electricity_streetlights'], 'https://bescom.karnataka.gov.in/', '1912', false),
  ('bbmp_swm', 'bengaluru', 'Bengaluru Solid Waste Management Ltd (BSWML / BBMP)', 'ಬೆಂಗಳೂರು ಘನತ್ಯಾಜ್ಯ ನಿರ್ವಹಣಾ ವಿಭಾಗ', 'BSWML', array['garbage_sanitation'], 'https://site.bbmp.gov.in/', '1533', false),
  ('btp_traffic', 'bengaluru', 'Bengaluru Traffic Police & Signal Maintenance', 'ಬೆಂಗಳೂರು ಸಂಚಾರ ಪೊಲೀಸ್ ವಿಭಾಗ', 'BTP', array['traffic_signals','public_safety'], 'https://btp.gov.in/', '112', false),
  ('mcc_mysuru_civic', 'mysuru', 'Mysuru City Corporation Engineering & Health Wing', 'ಮೈಸೂರು ಮಹಾನಗರ ಪಾಲಿಕೆ ಇಂಜಿನಿಯರಿಂಗ್ ವಿಭಾಗ', 'MCC-MYS', array['roads_potholes','garbage_sanitation','water_supply','drainage_sewage'], 'https://mysurucity.mrc.gov.in/', '0821-2418800', false),
  ('cesc_mysuru', 'mysuru', 'Chamundeshwari Electricity Supply Corporation (CESC)', 'ಚಾಮುಂಡೇಶ್ವರಿ ವಿದ್ಯುತ್ ಸರಬರಾಜು ನಿಗಮ (ಸೆಸ್ಕ್)', 'CESC', array['electricity_streetlights'], 'https://cescmysore.karnataka.gov.in/', '1912', false),
  ('mcc_mangaluru_civic', 'mangaluru', 'Mangaluru City Corporation Civic Operations', 'ಮಂಗಳೂರು ಮಹಾನಗರ ಪಾಲಿಕೆ ನಾಗರಿಕ ವಿಭಾಗ', 'MCC-MNG', array['roads_potholes','garbage_sanitation','water_supply','drainage_sewage'], 'https://mangalorecity.mrc.gov.in/', '0824-2220306', false),
  ('mescom_power', 'mangaluru', 'Mangalore Electricity Supply Company (MESCOM)', 'ಮಂಗಳೂರು ವಿದ್ಯುತ್ ಸರಬರಾಜು ಕಂಪನಿ (ಮೆಸ್ಕಾಂ)', 'MESCOM', array['electricity_streetlights'], 'https://mescom.karnataka.gov.in/', '1912', false),
  ('hdmc_hubballi', 'hubballi_dharwad', 'Hubballi-Dharwad Municipal Corporation Operations', 'ಹುಬ್ಬಳ್ಳಿ-ಧಾರವಾಡ ಮಹಾನಗರ ಪಾಲಿಕೆ', 'HDMC', array['roads_potholes','garbage_sanitation','water_supply','drainage_sewage'], 'https://hdmc.mrc.gov.in/', '1800-425-7677', false),
  ('hescom_power', 'hubballi_dharwad', 'Hubli Electricity Supply Company (HESCOM)', 'ಹುಬ್ಬಳ್ಳಿ ವಿದ್ಯುತ್ ಸರಬರಾಜು ಕಂಪನಿ (ಹೆಸ್ಕಾಂ)', 'HESCOM', array['electricity_streetlights'], 'https://hescom.karnataka.gov.in/', '1912', false),
  ('gescom_power', 'kalaburagi', 'Gulbarga Electricity Supply Company (GESCOM)', 'ಗುಲ್ಬರ್ಗಾ ವಿದ್ಯುತ್ ಸರಬರಾಜು ಕಂಪನಿ (ಜೆಸ್ಕಾಂ)', 'GESCOM', array['electricity_streetlights'], 'https://gescom.karnataka.gov.in/', '1912', false)
on conflict (id) do nothing;

-- 3. GOVERNMENT SCHEMES (Verified official sources)
insert into public.schemes (
  id, title, title_kn, category, region_scope, applicable_cities,
  summary, summary_kn, eligibility_criteria, eligibility_rules,
  required_documents, application_steps, official_source_url, official_portal_name, last_verified_date, is_active
) values
(
  'gruha_jyothi_ka',
  'Gruha Jyothi Scheme (Free Household Electricity up to 200 Units)',
  'ಗೃಹ ಜ್ಯೋತಿ ಯೋಜನೆ (200 ಯೂನಿಟ್ ವರೆಗೆ ಉಚಿತ ಗೃಹ ವಿದ್ಯುತ್)',
  'financial_assistance',
  'Karnataka State',
  array['all'],
  'Provides subsidy for residential electricity consumers in Karnataka consuming up to 200 units per month based on historical average usage.',
  'ಕರ್ನಾಟಕದ ಗೃಹ ವಿದ್ಯುತ್ ಗ್ರಾಹಕರಿಗೆ ಮಾಸಿಕ ಸರಾಸರಿ ಬಳಕೆಯ ಆಧಾರದ ಮೇಲೆ 200 ಯೂನಿಟ್‌ಗಳವರೆಗೆ ಶೂನ್ಯ ಬಿಲ್ ಸೌಲಭ್ಯ.',
  '["Resident of Karnataka with a valid domestic RR / Account ID with BESCOM, MESCOM, CESC, HESCOM, or GESCOM","Monthly consumption within eligible ceiling up to 200 units","One meter connection per household linked with Aadhaar"]'::jsonb,
  '{"resident_karnataka": true, "max_units": 200}'::jsonb,
  array['Aadhaar Card', 'Electricity Bill / Account ID (RR Number)', 'Rental Agreement or Ownership Proof (if tenant)'],
  array['Open the official Seva Sindhu portal', 'Select Gruha Jyothi registration', 'Link Aadhaar and ESCOM Account ID', 'Submit and download acknowledgement'],
  'https://sevaone.karnataka.gov.in/',
  'Seva Sindhu / SevaOne Karnataka',
  '2026-10-01',
  true
),
(
  'gruha_lakshmi_ka',
  'Gruha Lakshmi Financial Assistance for Women Heads of Households',
  'ಗೃಹ ಲಕ್ಷ್ಮಿ ಯೋಜನೆ (ಕುಟುಂಬದ ಯಜಮಾನಿಗೆ ಮಾಸಿಕ ಆರ್ಥಿಕ ನೆರವು)',
  'women_child_welfare',
  'Karnataka State',
  array['all'],
  'Direct benefit transfer (DBT) financial assistance program supporting women listed as the head of household on Antyodaya, BPL, or APL ration cards in Karnataka.',
  'ಅಂತ್ಯೋದಯ, ಬಿಪಿಎಲ್ ಅಥವಾ ಎಪಿಎಲ್ ಪಡಿತರ ಚೀಟಿಯಲ್ಲಿ ಕುಟುಂಬದ ಯಜಮಾನಿ ಎಂದು ನಮೂದಿಸಲಾದ ಮಹಿಳೆಯರಿಗೆ ನೇರ ನಗದು ವರ್ಗಾವಣೆ ಯೋಜನೆ.',
  '["Woman listed as Head of Family on Antyodaya, BPL, or APL Ration Card in Karnataka","Neither the applicant nor her spouse is an income taxpayer or GST filer","Bank account seeded with Aadhaar for DBT"]'::jsonb,
  '{"gender": "female", "taxpayer": false}'::jsonb,
  array['Ration Card (BPL/APL/Antyodaya)', 'Aadhaar Card of Applicant & Spouse', 'Aadhaar-seeded Bank Passbook'],
  array['Check eligibility criteria on Seva Sindhu or Karnataka One / Bangalore One centre', 'Complete e-KYC with Aadhaar OTP', 'Verify ration card number and DBT bank status'],
  'https://sevaone.karnataka.gov.in/',
  'SevaOne Karnataka Portal',
  '2026-10-01',
  true
),
(
  'yuva_nidhi_ka',
  'Yuva Nidhi Unemployment Allowance & Skill Transition Support',
  'ಯುವ ನಿಧಿ ಯೋಜನೆ (ಪದವೀಧರ ಮತ್ತು ಡಿಪ್ಲೊಮಾ ಧಾರಕರಿಗೆ ನಿರುದ್ಯೋಗ ಭತ್ಯೆ)',
  'employment',
  'Karnataka State',
  array['all'],
  'Temporary monthly allowance and skill-training linkage for eligible unemployed degree and diploma graduates domiciled in Karnataka.',
  'ಕರ್ನಾಟಕದಲ್ಲಿ ವ್ಯಾಸಂಗ ಮಾಡಿದ ಅರ್ಹ ನಿರುದ್ಯೋಗಿ ಪದವೀಧರರು ಮತ್ತು ಡಿಪ್ಲೊಮಾ ಪೂರ್ಣಗೊಳಿಸಿದ ಯುವಜನತೆಗೆ ತಾತ್ಕಾಲಿಕ ಮಾಸಿಕ ಭತ್ಯೆ ಮತ್ತು ಕೌಶಲ್ಯ ತರಬೇತಿ.',
  '["Domicile of Karnataka (studied at least 6 years in Karnataka)","Completed Degree or Diploma and remained unemployed for 6+ months","Not currently enrolled in higher studies or receiving PF/ESI salary"]'::jsonb,
  '{"employment_status": "unemployed", "education": "graduate_or_diploma"}'::jsonb,
  array['Aadhaar Card', 'SSLC / PUC / Degree or Diploma Marks Cards', 'Domicile / Study Certificate', 'Bank Account linked to Aadhaar'],
  array['Register on Seva Sindhu Yuva Nidhi portal', 'Verify NAD / University registration number', 'Submit monthly self-declaration of unemployment status'],
  'https://sevaone.karnataka.gov.in/',
  'SevaOne / Kaushalkar Karnataka',
  '2026-10-01',
  true
),
(
  'ssp_post_matric_ka',
  'State Scholarship Portal (SSP) Post-Matric Scholarships',
  'ರಾಜ್ಯ ವಿದ್ಯಾರ್ಥಿವೇತನ ತಂತ್ರಾಂಶ (SSP) ಮೆಟ್ರಿಕ್ ನಂತರದ ವಿದ್ಯಾರ್ಥಿವೇತನ',
  'education_scholarships',
  'Karnataka State',
  array['all'],
  'Unified scholarship portal for students pursuing PUC, ITI, Diploma, Undergraduate, and Postgraduate courses across Karnataka.',
  'ಕರ್ನಾಟಕದ ವಿದ್ಯಾರ್ಥಿಗಳಿಗೆ ಪಿಯುಸಿ, ಡಿಪ್ಲೊಮಾ, ಪದವಿ ಮತ್ತು ಸ್ನಾತಕೋತ್ತರ ಶಿಕ್ಷಣಕ್ಕಾಗಿ ಏಕೀಕೃತ ವಿದ್ಯಾರ್ಥಿವೇತನ ಸೌಲಭ್ಯ.',
  '["Student domiciled in Karnataka enrolled in recognized post-matric institution","Family annual income within department-prescribed limits","Valid caste and income certificate where applicable"]'::jsonb,
  '{"occupation": "student"}'::jsonb,
  array['SSP Student ID / SATS ID', 'Aadhaar Card', 'Income & Caste Certificate (RD Number)', 'College Fee Receipt & Bonafide Certificate'],
  array['Search and verify scheme rules on myScheme or SSP Portal', 'Create SSP account and complete e-Attestation if applicable', 'Submit online application before department deadline'],
  'https://www.myscheme.gov.in/',
  'myScheme National Portal',
  '2026-10-01',
  true
),
(
  'ayushman_bharat_arogya_karnataka',
  'Ayushman Bharat - Pradhan Mantri Jan Arogya Yojana - Arogya Karnataka (AB-ArK)',
  'ಆಯುಷ್ಮಾನ್ ಭಾರತ್ - ಆರೋಗ್ಯ ಕರ್ನಾಟಕ (AB-ArK)',
  'healthcare',
  'Karnataka & National',
  array['all'],
  'Health assurance coverage providing cashless secondary and tertiary hospitalization treatment at empanelled public and private hospitals.',
  'ಸರ್ಕಾರಿ ಮತ್ತು ನೋಂದಾಯಿತ ಖಾಸಗಿ ಆಸ್ಪತ್ರೆಗಳಲ್ಲಿ ದ್ವಿತೀಯ ಮತ್ತು ತೃತೀಯ ಹಂತದ ವೈದ್ಯಕೀಯ ಚಿಕಿತ್ಸೆಗೆ ಆರೋಗ್ಯ ವಿಮಾ ಸೌಲಭ್ಯ.',
  '["BPL household members eligible for up to Rs 5 lakh coverage per family per year","APL household members eligible for co-payment assistance as per state norms"]'::jsonb,
  '{"category": "healthcare"}'::jsonb,
  array['Aadhaar Card', 'Ration Card (BPL / APL)'],
  array['Verify eligibility on UMANG or official PMJAY portal', 'Generate Ayushman Card at Bangalore One / Karnataka One or Government Hospital Arogya Mitra desk'],
  'https://web.umang.gov.in/',
  'UMANG Official Portal',
  '2026-10-01',
  true
),
(
  'pm_svanidhi_urban',
  'PM SVANidhi Micro-Credit Facility for Urban Street Vendors',
  'ಪಿಎಂ ಸ್ವನಿಧಿ ನಗರ ಬೀದಿಬದಿ ವ್ಯಾಪಾರಿಗಳ ಕಿರು ಸಾಲ ಯೋಜನೆ',
  'skill_development',
  'National (Urban Local Bodies)',
  array['all'],
  'Working-capital collateral-free loan and digital payment incentive scheme for street vendors operating in urban local bodies.',
  'ನಗರ ಸ್ಥಳೀಯ ಸಂಸ್ಥೆಗಳ ವ್ಯಾಪ್ತಿಯಲ್ಲಿ ಕಾರ್ಯನಿರ್ವಹಿಸುವ ಬೀದಿಬದಿ ವ್ಯಾಪಾರಿಗಳಿಗೆ ಅಡಮಾನ ರಹಿತ ಕಾರ್ಯನಿರತ ಬಂಡವಾಳ ಸಾಲ ಮತ್ತು ಡಿಜಿಟಲ್ ಪಾವತಿ ಪ್ರೋತ್ಸಾಹ.',
  '["Street vendor operating in an Urban Local Body (BBMP, MCC, HDMC, etc.)","Hold Certificate of Vending / ID Card or Letter of Recommendation from ULB/TVC"]'::jsonb,
  '{"occupation": "self_employed"}'::jsonb,
  array['Vendor ID Card / Letter of Recommendation', 'Aadhaar Card linked with Mobile Number', 'Bank Account Details'],
  array['Check full scheme rules on myScheme.gov.in', 'Apply online or through ULB Community Organizer'],
  'https://www.myscheme.gov.in/',
  'myScheme.gov.in',
  '2026-10-01',
  true
)
on conflict (id) do nothing;

-- 4. UTILITY SERVICES (Mapped accurately per city so residents are never sent to the wrong municipality)
insert into public.utility_services (
  id, city_id, service_type, provider_code, provider_name, provider_name_kn,
  locality_applicability, official_portal_url, instructions, helpline_number
) values
  ('util_blr_elec', 'bengaluru', 'electricity', 'BESCOM', 'BESCOM (Bangalore Electricity Supply Company)', 'ಬೆಸ್ಕಾಂ (ಬೆಂಗಳೂರು ವಿದ್ಯುತ್ ಸರಬರಾಜು ಕಂಪನಿ)', 'Bengaluru Urban & Rural wards', 'https://bescom.karnataka.gov.in/', 'Keep your 10-digit Account ID (RR No) ready. Verify tariff and due date on the official BESCOM Mithra / Karnataka One portal before paying.', '1912'),
  ('util_blr_water', 'bengaluru', 'water', 'BWSSB', 'BWSSB (Bangalore Water Supply & Sewerage Board)', 'ಬಿಡಬ್ಲ್ಯೂಎಸ್ಎಸ್ಬಿ (ಬೆಂಗಳೂರು ಜಲಮಂಡಳಿ)', 'BBMP core & 110 villages coverage area', 'https://bwssb.karnataka.gov.in/', 'Use your RR Number on the official BWSSB online payment portal to check water and sanitary charges.', '1916'),
  ('util_blr_tax', 'bengaluru', 'property_tax', 'BBMP-TAX', 'BBMP SAS Property Tax Portal', 'ಬಿಬಿಎಂಪಿ ಆಸ್ತಿ ತೆರಿಗೆ ಪೋರ್ಟಲ್', 'All 8 BBMP Zones', 'https://bbmptax.karnataka.gov.in/', 'Enter your 10-digit PID Number or SAS Application Number to view official property tax assessment.', '1533'),
  ('util_blr_one', 'bengaluru', 'citizen_one_portal', 'BLR-ONE', 'Bangalore One Integrated Citizen Services', 'ಬೆಂಗಳೂರು ಒನ್ ನಾಗರಿಕ ಸೇವಾ ಕೇಂದ್ರ', 'Bengaluru City-wide', 'https://www.bangaloreone.gov.in/', 'Integrated portal for utility bills, khata services, and municipal certificates.', '080-49203888'),
  ('util_mys_elec', 'mysuru', 'electricity', 'CESC', 'CESC Mysuru (Chamundeshwari Electricity Supply Corp)', 'ಸೆಸ್ಕ್ ಮೈಸೂರು (ವಿದ್ಯುತ್ ಸರಬರಾಜು ನಿಗಮ)', 'Mysuru, Mandya, Chamarajanagar, Hassan, Kodagu', 'https://cescmysore.karnataka.gov.in/', 'Use your CESC Account ID on the official CESC portal to view monthly billing and outage notices.', '1912'),
  ('util_mys_water', 'mysuru', 'water', 'MCC-VANI', 'Mysuru City Corporation Water & Property Tax Portal', 'ಮೈಸೂರು ಮಹಾನಗರ ಪಾಲಿಕೆ ನೀರು ಮತ್ತು ಆಸ್ತಿ ತೆರಿಗೆ', 'Mysuru City Wards 1–65', 'https://mysurucity.mrc.gov.in/', 'Select Online Services -> Water Charges or Property Tax on the official Mysuru City Corporation portal.', '0821-2418800'),
  ('util_mng_elec', 'mangaluru', 'electricity', 'MESCOM', 'MESCOM (Mangalore Electricity Supply Company)', 'ಮೆಸ್ಕಾಂ (ಮಂಗಳೂರು ವಿದ್ಯುತ್ ಸರಬರಾಜು ಕಂಪನಿ)', 'Dakshina Kannada, Udupi, Shivamogga, Chikkamagaluru', 'https://mescom.karnataka.gov.in/', 'Enter your MESCOM Account ID on the official portal for bill viewing and grievance registration.', '1912'),
  ('util_mng_water', 'mangaluru', 'water', 'MCC-MNG', 'Mangaluru City Corporation Water & Tax Services', 'ಮಂಗಳೂರು ಮಹಾನಗರ ಪಾಲಿಕೆ ಜಲ ಮತ್ತು ತೆರಿಗೆ ಸೇವೆ', 'Mangaluru City Limits', 'https://mangalorecity.mrc.gov.in/', 'Access Mangaluru City Corporation online citizen services for water bill and property tax lookup.', '0824-2220306'),
  ('util_hub_elec', 'hubballi_dharwad', 'electricity', 'HESCOM', 'HESCOM (Hubli Electricity Supply Company)', 'ಹೆಸ್ಕಾಂ (ಹುಬ್ಬಳ್ಳಿ ವಿದ್ಯುತ್ ಸರಬರಾಜು ಕಂಪನಿ)', 'Dharwad, Belagavi, Vijayapura, Bagalkot, Gadag, Haveri, Uttara Kannada', 'https://hescom.karnataka.gov.in/', 'Use your HESCOM Account ID on the official HESCOM consumer portal.', '1912'),
  ('util_hub_tax', 'hubballi_dharwad', 'property_tax', 'HDMC-TAX', 'HDMC Municipal Services & Property Tax', 'ಹುಬ್ಬಳ್ಳಿ-ಧಾರವಾಡ ಮಹಾನಗರ ಪಾಲಿಕೆ ತೆರಿಗೆ ಸೇವೆ', 'Hubballi-Dharwad Twin Cities', 'https://hdmc.mrc.gov.in/', 'Verify your PID / Assessment Number on the official HDMC portal.', '1800-425-7677'),
  ('util_klb_elec', 'kalaburagi', 'electricity', 'GESCOM', 'GESCOM (Gulbarga Electricity Supply Company)', 'ಜೆಸ್ಕಾಂ (ಗುಲ್ಬರ್ಗಾ ವಿದ್ಯುತ್ ಸರಬರಾಜು ಕಂಪನಿ)', 'Kalaburagi, Ballari, Bidar, Koppal, Raichur, Yadgir', 'https://gescom.karnataka.gov.in/', 'Check electricity billing and feeder maintenance via the official GESCOM portal.', '1912'),
  ('util_ka_one', 'mysuru', 'citizen_one_portal', 'KA-ONE', 'Karnataka One Integrated Citizen Portal', 'ಕರ್ನಾಟಕ ಒನ್ ಏಕೀಕೃತ ನಾಗರಿಕ ಪೋರ್ಟಲ್', 'All major Karnataka cities outside Bengaluru', 'https://www.karnatakaone.gov.in/', 'Unified state portal for municipal bills, certificates, and Seva Sindhu services.', '080-49203888')
on conflict (id) do nothing;

-- 5. CLEARLY LABELLED DEMO CITY ANNOUNCEMENTS
insert into public.city_announcements (
  id, city_id, category, title, title_kn, summary, summary_kn,
  locality, source_agency, source_url, is_verified_official, is_demo_announcement, published_at
) values
(
  '00000000-0000-4000-8000-000000000101',
  'bengaluru',
  'water_disruption',
  '[DEMO ANNOUNCEMENT] Scheduled Cauvery Stage IV Pipeline Maintenance Notice',
  '[ಡೆಮೊ ಪ್ರಕಟಣೆ] ಕಾವೇರಿ 4ನೇ ಹಂತದ ಪೈಪ್‌ಲೈನ್ ನಿರ್ವಹಣಾ ಸೂಚನೆ',
  'Sample announcement demonstrating how BWSSB scheduled pumping-station maintenance windows are displayed with locality impact and official link verification.',
  'ಬಿಡಬ್ಲ್ಯೂಎಸ್ಎಸ್ಬಿ ಪಂಪಿಂಗ್ ಸ್ಟೇಷನ್ ನಿರ್ವಹಣಾ ಸಮಯ ಮತ್ತು ಪ್ರದೇಶದ ಮಾಹಿತಿಯನ್ನು ಪ್ರದರ್ಶಿಸುವ ಮಾದರಿ ಪ್ರಕಟಣೆ.',
  'Indiranagar, Domlur & Koramangala',
  'BWSSB Public Relations (Demo Record)',
  'https://bwssb.karnataka.gov.in/',
  true,
  true,
  now() - interval '6 hours'
),
(
  '00000000-0000-4000-8000-000000000102',
  'bengaluru',
  'electricity_maintenance',
  '[DEMO ANNOUNCEMENT] 66/11kV Substation Quarterly Preventive Maintenance',
  '[ಡೆಮೊ ಪ್ರಕಟಣೆ] 66/11 ಕೆವಿ ವಿದ್ಯುತ್ ಉಪಕೇಂದ್ರದ ತ್ರೈಮಾಸಿಕ ನಿರ್ವಹಣೆ',
  'Sample announcement showing how BESCOM feeder maintenance schedules and affected wards appear in the CityPulse updates feed.',
  'ಬೆಸ್ಕಾಂ ವಿದ್ಯುತ್ ನಿರ್ವಹಣಾ ವೇಳಾಪಟ್ಟಿ ಮತ್ತು ಪ್ರಭಾವಿತ ವಾರ್ಡ್‌ಗಳ ಮಾಹಿತಿಯನ್ನು ತೋರಿಸುವ ಮಾದರಿ ಪ್ರಕಟಣೆ.',
  'Jayanagar 4th Block & JP Nagar',
  'BESCOM O&M Division (Demo Record)',
  'https://bescom.karnataka.gov.in/',
  true,
  true,
  now() - interval '14 hours'
),
(
  '00000000-0000-4000-8000-000000000103',
  'mysuru',
  'waste_collection',
  '[DEMO ANNOUNCEMENT] Dry-Waste Segregation & E-Waste Collection Drive',
  '[ಡೆಮೊ ಪ್ರಕಟಣೆ] ಒಣ ಕಸ ವಿಂಗಡಣೆ ಮತ್ತು ಇ-ತ್ಯಾಜ್ಯ ಸಂಗ್ರಹಣಾ ಅಭಿಯಾನ',
  'Sample announcement illustrating MCC Mysuru ward-level dry waste and e-waste collection vehicle schedules.',
  'ಮೈಸೂರು ಮಹಾನಗರ ಪಾಲಿಕೆಯ ವಾರ್ಡ್ ಮಟ್ಟದ ಒಣ ಕಸ ಮತ್ತು ಇ-ತ್ಯಾಜ್ಯ ಸಂಗ್ರಹಣಾ ಅಭಿಯಾನದ ಮಾದರಿ ಪ್ರಕಟಣೆ.',
  'Vijayanagar & Gokulam, Mysuru',
  'Mysuru City Corporation Health Wing (Demo Record)',
  'https://mysurucity.mrc.gov.in/',
  true,
  true,
  now() - interval '1 day'
)
on conflict (id) do nothing;


-- Ask Supabase's REST schema cache to refresh after this transaction commits.
notify pgrst, 'reload schema';
commit;

-- Verification results: every row should show true / non-null.
select required.table_name,
       to_regclass('public.' || required.table_name) is not null as table_exists
from (values
  ('cities'), ('profiles'), ('user_roles'), ('departments'), ('civic_issues'),
  ('issue_votes'), ('issue_confirmations'), ('comments'), ('issue_status_history'),
  ('issue_media'), ('issue_watchlists'), ('schemes'), ('scheme_bookmarks'),
  ('service_directory'), ('utility_services'), ('bill_reminders'),
  ('city_announcements'), ('notifications'), ('content_reports')
) as required(table_name)
order by required.table_name;

-- AUTH PROFILE AUTO-PROVISIONING REPAIR (also available as FIX_AUTHOR_PROFILE_FOREIGN_KEY.sql)
-- Ensures every auth.users row has a corresponding public.profiles row.
create or replace function public.ensure_profile_for_auth_user(p_user_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
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
  select u.* into v_auth_user from auth.users as u where u.id = p_user_id;
  if not found then return; end if;
  if exists (select 1 from public.profiles p where p.id = p_user_id) then
    insert into public.user_roles (user_id) values (p_user_id) on conflict (user_id) do nothing;
    return;
  end if;
  v_id_hex := replace(p_user_id::text, '-', '');
  v_full_name := nullif(btrim(coalesce(v_auth_user.raw_user_meta_data ->> 'full_name', v_auth_user.raw_user_meta_data ->> 'name', split_part(coalesce(v_auth_user.email, ''), '@', 1), '')), '');
  if v_full_name is null or char_length(v_full_name) < 2 then v_full_name := 'Citizen ' || substr(v_id_hex, 1, 8); end if;
  v_full_name := left(v_full_name, 100);
  v_base_username := coalesce(nullif(btrim(v_auth_user.raw_user_meta_data ->> 'username'), ''), nullif(split_part(coalesce(v_auth_user.email, ''), '@', 1), ''), 'citizen');
  v_base_username := btrim(lower(regexp_replace(v_base_username, '[^a-zA-Z0-9_]', '_', 'g')), '_');
  if char_length(v_base_username) < 3 then v_base_username := 'citizen_' || substr(v_id_hex, 1, 8); end if;
  v_base_username := left(v_base_username, 30);
  v_city_id := nullif(v_auth_user.raw_user_meta_data ->> 'preferred_city_id', '');
  if v_city_id is not null and not exists (select 1 from public.cities c where c.id = v_city_id) then v_city_id := null; end if;
  if v_city_id is null and exists (select 1 from public.cities c where c.id = 'bengaluru') then v_city_id := 'bengaluru'; end if;
  v_language := case when v_auth_user.raw_user_meta_data ->> 'preferred_language' = 'kn' then 'kn' else 'en' end;
  loop
    if v_attempt = 0 then v_username := v_base_username;
    elsif v_attempt = 1 then v_username := 'citizen_' || substr(v_id_hex, 1, 22);
    else v_username := 'citizen_' || substr(md5(p_user_id::text || ':' || v_attempt::text), 1, 22);
    end if;
    exit when not exists (select 1 from public.profiles p where lower(p.username) = lower(v_username) and p.id <> p_user_id);
    v_attempt := v_attempt + 1;
    if v_attempt > 25 then raise exception 'Unable to generate a unique CityPulse username for user %', p_user_id; end if;
  end loop;
  insert into public.profiles (id, username, full_name, preferred_city_id, preferred_language, accepted_terms_at)
  values (p_user_id, v_username, v_full_name, v_city_id, v_language, now()) on conflict (id) do nothing;
  insert into public.user_roles (user_id) values (p_user_id) on conflict (user_id) do nothing;
end; $$;
create or replace function public.handle_new_auth_user_profile()
returns trigger language plpgsql security definer set search_path = '' as $$
begin perform public.ensure_profile_for_auth_user(new.id); return new; end; $$;
drop trigger if exists on_auth_user_created_profile on auth.users;
create trigger on_auth_user_created_profile after insert on auth.users for each row execute function public.handle_new_auth_user_profile();
do $$ declare v_user_id uuid; begin
  for v_user_id in select u.id from auth.users u left join public.profiles p on p.id = u.id where p.id is null loop
    perform public.ensure_profile_for_auth_user(v_user_id);
  end loop;
end $$;
revoke all on function public.ensure_profile_for_auth_user(uuid) from public, anon, authenticated;
revoke all on function public.handle_new_auth_user_profile() from public, anon, authenticated;
notify pgrst, 'reload schema';


-- Final idempotent announcement write-policy hardening: only role=admin can manage notices.
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
