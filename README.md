# loQin

Folder layout:

- `index.html` - the whole app (open this one)
- `supabase/setup.sql` - database setup, run in the Supabase SQL Editor
- `vercel.json` - used later when deploying to Vercel

## Test in VS Code
1. File > Open Folder... and choose this `loqin` folder.
2. Install the "Live Server" extension (Ritwick Dey).
3. Right-click `index.html` > "Open with Live Server".
   The app opens at http://127.0.0.1:5500

## Database
Supabase > SQL Editor. For a brand-new project run all of `supabase/setup.sql`.
For an existing project run only the sections you haven't run yet (from the
"ADMIN & MODERATION" banner to the end for the latest update).
After that, make yourself platform admin:
`insert into public.platform_admins (user_id) values ('YOUR-USER-ID');`

## Email login (Supabase settings)
- Authentication > URL Configuration: Site URL = your Vercel address; add the same address under Redirect URLs.
- Authentication > Providers > Email: keep "Confirm email" ON for real users.
- Same page: turn "Secure email change" OFF (so older name-only accounts can add an email).
- Authentication > SMTP Settings: add a real email sender (for example Resend). Supabase's built-in sender only allows a few emails per hour.

## If devices don't see each other's posts, groups or chat
Paste `supabase/health-check.sql` into the Supabase SQL Editor and run it. Anything marked MISSING means
`supabase/setup.sql` has not been fully run. `setup.sql` is safe to run again in full, any number of times.
