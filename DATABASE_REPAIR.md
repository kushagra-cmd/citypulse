# CityPulse database repair (important)

The screenshot error `Could not find the table public.civic_issues in the schema cache` means the main schema hasn't been installed successfully. This is a database setup issue, not a Vite/frontend error.

1. Open your Supabase project matching `VITE_SUPABASE_URL`.
2. Go to **SQL Editor → New query**.
3. Open `CITYPULSE_INSTALL_ALL.sql` in this folder, copy the entire file, paste it into SQL Editor, and click **Run**.
4. At the bottom, confirm all 19 `table_exists` rows say `true`. If any SQL error appears, stop and share the first error.
5. Wait a few seconds for the REST schema cache to refresh, then reload CityPulse with **Ctrl+F5**.

This one-paste installer runs the canonical app migrations, security policies, storage setup and seed catalog in the correct order. Earlier helper scripts used a different `schemes` schema; incompatible leftover app tables are renamed to `citypulse_legacy_*_backup` rather than dropped. It does not delete the old table data.

Do not run the old one-off `FIX_SCHEMES_TABLE.sql`, `FIX_ISSUE_CONFIRMATIONS.sql`, or alternate `CITYPULSE_COMPLETE_SETUP.sql` after this installer.
