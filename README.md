# CityPulse — Your city. Your voice. Your priorities.

**CityPulse** is a full-stack civic-tech platform where citizens can create accounts, report geo-located city problems, confirm community impact, track official resolution timelines, explore an interactive MapLibre GL JS map, discover verified government schemes, and access city-specific municipal and utility portals.

> **Independent Platform Notice:** CityPulse is an independent community civic-tech platform, not an official government portal. Community posts on CityPulse do not automatically become formal government complaints.

---

## Deploy CityPulse

For the quickest Windows-first deploy using Vercel CLI, follow [`DEPLOY_NOW.md`](DEPLOY_NOW.md). The production hosting configuration is included in `vercel.json`. Note that the frontend can deploy before the backend is ready, but real account and civic-reporting features require the Supabase migrations to complete successfully.

---

## 1. Architecture & Technology Stack

- **Frontend:** React 18, TypeScript, Vite, Tailwind CSS, React Router v6, Lucide React icons, MapLibre GL JS (`maplibre-gl`).
- **Backend & Persistence:** Supabase (PostgreSQL 15+, Supabase Auth, Row-Level Security, Supabase Storage, Supabase Realtime).
- **Interactive Maps:** MapLibre GL JS with OpenFreeMap (`https://tiles.openfreemap.org/styles/liberty`) vector tiles and OpenStreetMap attribution, plus a rate-limited geocoding adapter (`src/lib/geocoding.ts`) with Karnataka locality gazetteer fallback.
- **Core Engines:**
  - `src/lib/priorityEngine.ts`: Transparent 0–100 Smart Civic Priority Engine (severity, critical safety visibility boost, community confirmations, unique upvotes, time unresolved, and public infrastructure impact).
  - `src/lib/duplicateDetection.ts`: Local token Jaccard + character trigram + locality + Haversine coordinate proximity duplicate detector.
  - `src/lib/duration.ts`: Live ticking elapsed-duration calculator derived from immutable PostgreSQL timestamps (`created_at`, `last_official_update_at`, `resolved_at`, `reopened_at`).
  - `src/i18n/translations.ts`: Centralized English (`en`) and Kannada (`kn` / ಕನ್ನಡ) translation dictionary that switches UI labels without modifying user-generated content.

---

## 2. Repository Structure

```text
.
├── .env.example                                         # Public environment variable template
├── package.json                                         # Dependencies and build/test scripts
├── tsconfig.json                                        # Strict TypeScript configuration
├── vite.config.ts                                       # Vite bundler configuration
├── vercel.json / netlify.toml                           # Production SPA deployment configs
├── DEPLOYMENT.md                                        # Step-by-step cloud deployment guide
├── CITYPULSE_ADMIN_ANNOUNCEMENTS_MIGRATION.sql          # One-file migration for an existing Supabase project
├── supabase/
│   ├── config.toml                                      # Supabase CLI local configuration
│   ├── migrations/
│   │   ├── 20261025000001_initial_schema.sql            # All 19 tables, enums, indexes, priority SQL fn & triggers
│   │   ├── 20261025000002_rls_and_grants.sql            # RLS policies, least-privilege grants & admin RPCs
│   │   └── 20261025000003_storage_buckets.sql           # Storage buckets (issue-media, avatars, resolution-evidence)
│   ├── seed.sql                                         # Reproducible Karnataka cities, departments, schemes & utilities
│   └── tests/
│       └── rls_tests.sql                                # SQL test suite verifying all 6 mandatory RLS rules
├── src/
│   ├── types/database.ts                                # Strict database and domain TypeScript interfaces
│   ├── lib/
│   │   ├── supabase.ts                                  # Central Supabase client & service-role key security guard
│   │   ├── api.ts                                       # Typed Supabase queries, mutations, uploads & Realtime
│   │   ├── priorityEngine.ts                            # Smart Civic Priority Engine
│   │   ├── duplicateDetection.ts                        # Text + geo similarity duplicate detector
│   │   ├── duration.ts                                  # Live duration counter & lifecycle calculator
│   │   ├── geocoding.ts                                 # Rate-limited geocoding adapter + Karnataka gazetteer
│   │   └── validation.ts                                # Input & magic-byte image file upload validator
│   ├── i18n/                                            # English & Kannada (ಕನ್ನಡ) translation system
│   ├── context/                                         # AuthContext & CityContext providers
│   ├── components/                                      # Navbar, MapView, LocationPickerMap, IssueCard, AuthGateModal
│   └── pages/                                           # Feed, Map, CreateIssue, IssueDetail, Auth, Profile, Schemes, Services, Updates, Admin & announcement publishing
└── tests/
    ├── run_tests.mjs                                    # Automated unit & domain logic test suite
    └── sql_rls_verifier.py                              # Automated SQL schema, constraint & RLS verifier
```

---

## 3. Complete Setup & Configuration Procedure

### Step 1: Install Dependencies
```bash
npm install
```

### Step 2: Create & Configure Your Supabase Project
1. Create a new project at [https://supabase.com/dashboard](https://supabase.com/dashboard).
2. Copy `.env.example` to `.env.local`:
   ```bash
   cp .env.example .env.local
   ```
3. In your Supabase Dashboard, navigate to **Project Settings → API** and copy:
   - **Project URL** → `VITE_SUPABASE_URL`
   - **Project API Keys (`anon` `public`)** → `VITE_SUPABASE_ANON_KEY`
4. **Security Rule:** Never place your `service_role` secret key or database password in `.env.local` or any `VITE_*` variable. `src/lib/supabase.ts` inspects the JWT role at runtime and blocks `service_role` tokens from running in the browser.

### Step 3: Apply the full database setup (recommended for the current repair)

Because earlier repair attempts may have left a partial schema, use the one-file installer instead of the older helper SQL snippets:

1. Open `CITYPULSE_INSTALL_ALL.sql` from the project root.
2. Copy the entire file and paste it into Supabase Dashboard → **SQL Editor → New query**.
3. Click **Run** once and wait for the query to finish.
4. At the bottom, check the verification result table: all 19 `table_exists` values must be `true`.

The installer applies the canonical versioned migrations, RLS/grants, Storage policies and seed data in the required order. It archives mismatched tables from previous helper scripts as `citypulse_legacy_*_backup` tables rather than dropping them. Do not run the earlier `FIX_SCHEMES_TABLE.sql`, `FIX_ISSUE_CONFIRMATIONS.sql`, or alternate `CITYPULSE_COMPLETE_SETUP.sql` snippets again.

For a brand-new project, you can alternatively use the Supabase CLI migration workflow:
```bash
supabase link --project-ref <your-project-ref>
supabase db push
psql "<your-postgres-connection-string>" -f supabase/seed.sql
```

### Step 4: Configure Authentication & Email Confirmation
1. In the Supabase Dashboard, open **Authentication → Providers → Email**.
2. Enable **Email Provider**. If **Confirm email** is enabled, configure your Site URL (`http://localhost:5173` for local dev or your production domain) and Redirect URLs (`http://localhost:5173/reset-password`, `http://localhost:5173/login`) under **Authentication → URL Configuration**.

### Step 5: Promote an Authorized Administrator
Ordinary profile updates can never grant administrative rights (`user_roles` is a separate table with direct client `INSERT`/`UPDATE` blocked by RLS). To promote a registered user to `admin`, `moderator`, or `department_officer`, run the owner-controlled procedure in the Supabase SQL Editor:
```sql
SELECT public.promote_user_to_role(
  '<user-uuid-from-auth-users>'::uuid,
  'admin'::public.app_role,
  'bbmp_roads'
);
```

### Step 6: Start the Development Server & Run Checks
```bash
# Start local Vite dev server
npm run dev

# Run unit tests + SQL & RLS security verification suite
npm test

# Run production build & security audit
npm run build
```

---

## 4. Verifying Security & RLS Rules

Run the automated test suite at any time:
```bash
npm test
```
Or run the PostgreSQL transactional test script directly against your database:
```bash
psql "<your-postgres-connection-string>" -f supabase/tests/rls_tests.sql
```
This verifies:
1. Users cannot modify other users' profiles.
2. Users cannot vote more than once on an issue (`UNIQUE (issue_id, user_id)`).
3. Users cannot modify another user's issue.
4. Users cannot impersonate another author (`author_id = auth.uid()` RLS check + immutability trigger).
5. Ordinary users cannot publish official status transitions (`admin_transition_issue_status` role verification + RLS).
6. Ordinary users cannot grant themselves administrator access (`user_roles` RLS deny policy + `promote_user_to_role` owner guard).

## Fixing `civic_issues_author_id_fkey` when posting a report

This error means the signed-in ID exists in Supabase Auth but does not yet have a matching row in `public.profiles`. CityPulse now includes `supabase/migrations/20261025000004_auth_profile_provisioning.sql`, which creates profiles for new Auth users and backfills existing users missing profiles. It does not remove the foreign key or weaken RLS.

For an existing Supabase project, open **SQL Editor → New query**, paste the complete contents of `FIX_AUTHOR_PROFILE_FOREIGN_KEY.sql` from the project root, and run it once. It is safe to rerun. A successful run ends with a result listing `auth_user_missing_profile`; it should return zero rows. Then refresh CityPulse and submit the report again. New deployments should apply all migrations in timestamp order.


### Email confirmation on phones

If a confirmation email is created from a local run, its default URL may be `localhost`; opening that link on a phone sends the phone to itself, not your development computer. For production, set `VITE_SITE_URL` to your deployed HTTPS URL in the hosting provider, redeploy, set the same URL as Supabase Auth's Site URL, and allow it under Redirect URLs. Signup and password-reset emails now use `VITE_SITE_URL`. Also apply the auth profile-provisioning migration so users who sign up with email confirmation enabled receive a `public.profiles` row even when Supabase returns no session at signup time.


## Authority / administrator login

CityPulse has a separate **Authority Login** entry in the desktop navigation and mobile menu. It uses the same Supabase Auth email/password identities as the citizen site, then checks the account's server-loaded `user_roles.role`. Only `admin`, `moderator`, and `department_officer` roles are allowed into `/admin`; ordinary citizen accounts are signed back out and shown an access-denied message. The route `/authority-login` is an alias for `/admin-login`.

To provision an authority account, first create and verify the account normally. Then use a trusted project-owner session / Supabase SQL Editor to grant the required role using the project's documented `promote_user_to_role` function, if that migration has been applied. Do not expose the Supabase service-role key in the frontend and do not let users self-assign roles. After provisioning, open the **Authority Login** link and sign in with that account. The admin dashboard's database RLS and administrative status-transition RPC must also be installed for mutations to work.


## Admin-managed city announcements

Accounts with the `admin` role can create, edit, and delete announcements from the Authority Dashboard. Open `/admin`, scroll to **City announcements**, choose a city, fill in the category, English title/details, affected locality, source agency and source URL, and select **Publish announcement**. Kannada title/details and expiry time are optional. The notice appears on `/updates`; expired notices are hidden from the public page but remain visible in the admin list for editing/deletion.

For a Supabase project where the earlier migrations have already been applied, run `CITYPULSE_ADMIN_ANNOUNCEMENTS_MIGRATION.sql` in Supabase SQL Editor. This updates the announcement write policy so only the `admin` role can create, edit, or delete notices; public read remains enabled. For new installs, migration `20261025000005_admin_city_announcements.sql` is included.

Source labels are explicit: demo records are marked as demos, official-source claims appear only when the admin checks the verification option, and unverified source links are displayed as unverified. The website cannot independently authenticate an external agency's source.


## Unified authority dashboard

The `/admin` route is a single authority workspace with two tabs:

- **Resolve complaints**: review the prioritized reports queue, assign a department, change report status, add an official audit note and optional evidence URL, and review community abuse flags. Official transitions are submitted through the protected Supabase RPC and recorded in status history.
- **City announcements**: administrators can create, edit, and delete city notices from the same dashboard. Notices support city selection, category, locality, English/Kannada title and summary, source metadata, official/demo labels, and optional expiration.

Only users whose server-loaded Supabase role is `admin` see the City announcements tab. Department officers and moderators retain their permitted complaint/moderation workflows. Database RLS and the admin mutation functions remain the source of truth; hiding a tab is not used as a security boundary.

