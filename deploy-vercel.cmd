@echo off
setlocal
cd /d "%~dp0"
echo ============================================================
echo CityPulse production deploy (Vercel)
echo ============================================================
echo Before continuing, ensure the Vercel project is linked and
 echo VITE_SUPABASE_URL, VITE_SUPABASE_ANON_KEY, and VITE_MAP_STYLE_URL
 echo are configured in Vercel Project Settings ^> Environment Variables.
echo.
call npm.cmd run build
if errorlevel 1 (
  echo Build failed. Fix the errors above before deploying.
  pause
  exit /b 1
)
echo.
echo Starting production deployment...
call npx.cmd vercel --prod
if errorlevel 1 (
  echo Deployment failed. Review the Vercel CLI output above.
  pause
  exit /b 1
)
echo.
echo Deployment command completed. Test the URL printed by Vercel.
pause
