# Deploy CityPulse (Windows + Vercel)

This deploys the **frontend**. CityPulse's real reports, comments, voting and authentication work only once the Supabase schema and RLS setup have successfully completed. Your current app previously reported that `public.civic_issues` was missing, so verify the backend before treating the public deployment as production-ready.

## A. Build and link the project

Open PowerShell in the folder containing `package.json` (the `citypulse` folder), then run:

```powershell
npm.cmd install
npm.cmd run build
npx.cmd vercel login
npx.cmd vercel
```

- `npx.cmd vercel login` opens a browser so you can sign in/create a Vercel account.
- The first `npx.cmd vercel` run will ask to set up a project. Choose your personal scope, create a new project named `citypulse`, use `./` as the project directory, and accept the detected defaults.
- This first deployment can be a preview deployment; configure the environment variables in the next step before publishing production.

## B. Set production environment variables in Vercel

Open the Vercel dashboard, select the `citypulse` project, then go to **Settings → Environment Variables**. Add these for **Production** (Preview is useful too):

| Name | Value |
| --- | --- |
| `VITE_SUPABASE_URL` | `https://ovqeqsnltojctpprrxwu.supabase.co` |
| `VITE_SUPABASE_ANON_KEY` | Your Supabase **publishable** key (or legacy `anon` public key) |
| `VITE_MAP_STYLE_URL` | `https://tiles.openfreemap.org/styles/liberty` |
| `VITE_SITE_URL` | `https://YOUR-ACTUAL-PROJECT.vercel.app` (the public URL Vercel gives you) |

Do **not** add a service-role key or database password. Vite variables are bundled into public browser code; the publishable key is intended for this use, and database security must come from RLS.

## C. Deploy to production

After saving the environment variables, reopen PowerShell in the `citypulse` project folder and run:

```powershell
npx.cmd vercel --prod
```

Or double-click `deploy-vercel.cmd` after the project has been linked and environment variables saved. Vercel prints the public deployment URL when finished.

## D. Update Supabase Auth URLs

In Supabase Dashboard → **Authentication → URL Configuration**:

1. In Vercel **Settings → Environment Variables**, set `VITE_SITE_URL` to the exact production URL Vercel provided, including `https://` and without a trailing slash. Redeploy after changing environment variables.
2. In Supabase **Authentication → URL Configuration**, set **Site URL** to that same production URL.
3. Add the production URL and its app routes to **Redirect URLs**, for example `https://your-real-project.vercel.app/**` (replace with your actual Vercel domain).
4. Keep localhost redirect URLs only for desktop local development (`http://localhost:5173/**` and `http://localhost:5174/**`). A phone opening a localhost confirmation URL will reach the phone itself, not your computer.
5. Use the signup form on the public deployed site after setting the environment variable. Confirmation and password-reset emails will then point at the public site.

Save changes, then test account registration, email confirmation from both desktop and phone, login, password reset and sign-out. Email-confirmation users also need the `20261025000004_auth_profile_provisioning.sql` migration applied so their profile exists even when signup returns no session.

## E. Backend readiness gate

The frontend can deploy even when the database is incomplete, but the site will show fetch errors and protected workflows will fail. You have previously seen `Could not find the table 'public.civic_issues' in the schema cache`, so do not announce CityPulse as fully functional until all migrations have been applied and this query returns `true`:

```sql
select to_regclass('public.civic_issues') is not null as civic_issues_exists;
```

If it returns `false`, the required migration has not installed the table. If it errors, copy the **first complete error message** from Supabase SQL Editor before changing anything else. The live deployment does not automatically apply SQL migrations.

## Build settings

The included `vercel.json` explicitly configures `npm install`, `npm run build`, `dist`, SPA route rewrites, and baseline security headers. The build script now runs Vite's actual CLI cross-platform and fails if Vite is missing; it will not silently copy the unbuilt source HTML into `dist/`.
