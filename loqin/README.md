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
