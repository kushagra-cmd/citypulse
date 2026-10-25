# CityPulse Deployment Guide

For the Windows-first deployment steps, environment variables, Vercel CLI commands and Supabase redirect configuration, follow **[DEPLOY_NOW.md](DEPLOY_NOW.md)**.

## Vercel settings

- Install command: `npm install`
- Build command: `npm run build`
- Output directory: `dist`
- Framework: Vite (detected from `vite.config.ts`)

The repository includes a `vercel.json` with these values and SPA routing rewrites.

## Netlify alternative

The project also includes `netlify.toml` and `public/_redirects`. Set build command to `npm run build`, publish directory to `dist`, and add the same `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`, and `VITE_MAP_STYLE_URL` environment variables in the hosting provider's site settings before building.

## Supabase production configuration

1. Apply the migrations in `supabase/migrations/` in numeric order, ensuring each completes successfully, and then run `supabase/seed.sql` if you want the clearly labeled starter catalog.
2. Do not treat a frontend deployment as backend setup; Vercel will not execute SQL migrations automatically.
3. Confirm `public.civic_issues`, `public.profiles`, `public.issue_votes`, `public.comments`, and `public.schemes` exist before testing core workflows.
4. Configure Supabase Auth **Site URL** and **Redirect URLs** to include the real production deployment domain.
5. Promote a trusted account using the owner-controlled `public.promote_user_to_role` function only after the schema and RLS migrations are installed.

Never put service-role keys, database passwords, or other privileged secrets into any `VITE_*` variable.
