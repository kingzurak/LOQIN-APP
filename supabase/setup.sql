-- Run once in Supabase > SQL Editor. Skip any part your `profiles` table already has.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  handle text unique not null,
  niche text, tz text, gender text, pod_pref text,
  state jsonb,
  updated_at timestamptz default now()
);
alter table public.profiles enable row level security;
create policy "read own profile"   on public.profiles for select using (auth.uid() = id);
create policy "insert own profile" on public.profiles for insert with check (auth.uid() = id);
create policy "update own profile" on public.profiles for update using (auth.uid() = id);
-- Auth > Providers > Email: turn OFF "Confirm email" (loQin signs up with a name and password, no email box).

-- ===== Groups (step 2) =====
create table if not exists public.pods (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  niche text,
  max_members int default 8,
  invite_code text unique not null,
  owner_id uuid references auth.users(id) on delete cascade,
  approval boolean default false,
  locked boolean default false,
  pinned text,
  created_at timestamptz default now()
);
create table if not exists public.pod_members (
  pod_id uuid references public.pods(id) on delete cascade,
  user_id uuid references auth.users(id) on delete cascade,
  role text default 'member',
  joined_at timestamptz default now(),
  primary key (pod_id, user_id)
);
alter table public.pods enable row level security;
alter table public.pod_members enable row level security;
-- anyone signed in can look a group up by its code (needed to join); only the owner edits it
create policy "pods readable"      on public.pods for select using (true);
create policy "pods insert own"    on public.pods for insert with check (auth.uid() = owner_id);
create policy "pods update owner"  on public.pods for update using (auth.uid() = owner_id);
create policy "pods delete owner"  on public.pods for delete using (auth.uid() = owner_id);
create policy "members readable"   on public.pod_members for select using (true);
create policy "join as yourself"   on public.pod_members for insert with check (auth.uid() = user_id);
create policy "leave as yourself"  on public.pod_members for delete using (auth.uid() = user_id);
-- NOTE: profiles.state holds each user's full app data, so profiles stay private to their owner.
-- Until you add a public view of handles, a joiner sees the admin as "Admin" in the preview.

-- ===== Lock-ins (step 3) =====
create table if not exists public.checkins (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  pod_id uuid not null references public.pods(id) on delete cascade,
  day date not null,
  handle text,
  note text default '',
  link text default '',
  has_photo boolean default false,
  has_video boolean default false,
  streak int default 0,
  updated_at timestamptz default now(),
  unique (user_id, pod_id, day)
);
alter table public.checkins enable row level security;
-- members of a group can see each other's lock-ins; you can only write your own, in groups you belong to
create policy "members read checkins" on public.checkins for select
  using (exists (select 1 from public.pod_members m where m.pod_id = checkins.pod_id and m.user_id = auth.uid()));
create policy "write own checkin" on public.checkins for insert
  with check (auth.uid() = user_id and exists (select 1 from public.pod_members m where m.pod_id = checkins.pod_id and m.user_id = auth.uid()));
create policy "update own checkin" on public.checkins for update using (auth.uid() = user_id);
-- live updates across devices (optional; the app also refreshes every 30 seconds)
alter publication supabase_realtime add table public.checkins;

-- ===== Proof uploads (step 4) =====
alter table public.checkins add column if not exists proof_url text;
-- Storage: create a PUBLIC bucket named proof-media (Storage > New bucket > Public), then:
create policy "upload own proof" on storage.objects for insert to authenticated
  with check (bucket_id = 'proof-media' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "read proof media" on storage.objects for select using (bucket_id = 'proof-media');

-- ===== Comments & reactions (step 5) =====
-- 1. Reactions
CREATE TABLE IF NOT EXISTS public.checkin_reactions (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    checkin_id UUID NOT NULL REFERENCES public.checkins(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    emoji TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(checkin_id, user_id, emoji)
);
CREATE INDEX IF NOT EXISTS idx_checkin_reactions_checkin ON public.checkin_reactions(checkin_id);
ALTER TABLE public.checkin_reactions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Authenticated users can view reactions" ON public.checkin_reactions FOR SELECT TO authenticated USING (true);
CREATE POLICY "Users can add their own reactions" ON public.checkin_reactions FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can remove their own reactions" ON public.checkin_reactions FOR DELETE TO authenticated USING (auth.uid() = user_id);

-- 2. Comments
CREATE TABLE IF NOT EXISTS public.checkin_comments (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    checkin_id UUID NOT NULL REFERENCES public.checkins(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    content TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_checkin_comments_checkin ON public.checkin_comments(checkin_id, created_at ASC);
ALTER TABLE public.checkin_comments ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Authenticated users can view comments" ON public.checkin_comments FOR SELECT TO authenticated USING (true);
CREATE POLICY "Users can post comments" ON public.checkin_comments FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can delete their own comments" ON public.checkin_comments FOR DELETE TO authenticated USING (auth.uid() = user_id);

-- 3. Extras the app uses
-- shows the commenter's @name (profiles are private, so the name is stored with the comment)
ALTER TABLE public.checkin_comments ADD COLUMN IF NOT EXISTS handle TEXT;
-- live updates across devices (optional; the app also refreshes every 30 seconds)
ALTER PUBLICATION supabase_realtime ADD TABLE public.checkin_reactions;
ALTER PUBLICATION supabase_realtime ADD TABLE public.checkin_comments;


-- =====================================================================
-- MILESTONE 5: STREAKS + MISSED LOCK-IN NUDGES
-- Safe to run more than once.
-- =====================================================================

-- 1) Streak metrics, one row per user
create table if not exists public.user_streaks (
  user_id           uuid primary key references auth.users(id) on delete cascade,
  current_streak    int  not null default 0,
  longest_streak    int  not null default 0,
  last_checkin_date date,
  updated_at        timestamptz not null default now()
);
alter table public.user_streaks enable row level security;

drop policy if exists "streaks_select_self_or_podmates" on public.user_streaks;
create policy "streaks_select_self_or_podmates" on public.user_streaks for select to authenticated
using (
  user_id = auth.uid()
  or exists (
    select 1 from public.pod_members a
    join public.pod_members b on b.pod_id = a.pod_id
    where a.user_id = auth.uid() and b.user_id = user_streaks.user_id
  )
);
drop policy if exists "streaks_insert_own" on public.user_streaks;
create policy "streaks_insert_own" on public.user_streaks for insert to authenticated
with check (user_id = auth.uid());
drop policy if exists "streaks_update_own" on public.user_streaks;
create policy "streaks_update_own" on public.user_streaks for update to authenticated
using (user_id = auth.uid()) with check (user_id = auth.uid());

-- 2) Keep streaks current whenever a lock-in is saved (works even if the app is closed)
create or replace function public.sync_user_streak() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.user_streaks as s (user_id, current_streak, longest_streak, last_checkin_date, updated_at)
  values (new.user_id, coalesce(new.streak,0), coalesce(new.streak,0), new.day::date, now())
  on conflict (user_id) do update set
    current_streak    = case when new.day::date >= coalesce(s.last_checkin_date, new.day::date)
                             then coalesce(new.streak,0) else s.current_streak end,
    longest_streak    = greatest(s.longest_streak, coalesce(new.streak,0)),
    last_checkin_date = greatest(coalesce(s.last_checkin_date, new.day::date), new.day::date),
    updated_at        = now();
  return new;
end $$;

drop trigger if exists trg_sync_user_streak on public.checkins;
create trigger trg_sync_user_streak after insert or update on public.checkins
for each row execute function public.sync_user_streak();

-- 3) Reset streaks of people who missed a whole day.
-- Call it daily (Supabase Dashboard > Database > Cron, or pg_cron). The app also
-- honours skip passes and rest days locally, so people using those are re-synced
-- by the app the next time they open it.
create or replace function public.reset_missed_streaks() returns void
language sql security definer set search_path = public as $$
  update public.user_streaks
     set current_streak = 0, updated_at = now()
   where current_streak > 0
     and (last_checkin_date is null or last_checkin_date < current_date - 1);
$$;
-- Example (optional): select cron.schedule('loqin-reset-streaks', '5 0 * * *', 'select public.reset_missed_streaks()');

-- 4) Nudges sent between room members
create table if not exists public.room_nudges (
  id          uuid primary key default gen_random_uuid(),
  pod_id      uuid not null references public.pods(id) on delete cascade,
  from_user   uuid not null references auth.users(id) on delete cascade,
  to_user     uuid not null references auth.users(id) on delete cascade,
  from_handle text,
  to_handle   text,
  day         date not null,
  created_at  timestamptz not null default now(),
  unique (pod_id, from_user, to_user, day)
);
create index if not exists room_nudges_pod_day_idx on public.room_nudges (pod_id, day);
alter table public.room_nudges enable row level security;

drop policy if exists "nudges_select_pod_members" on public.room_nudges;
create policy "nudges_select_pod_members" on public.room_nudges for select to authenticated
using (exists (select 1 from public.pod_members m where m.pod_id = room_nudges.pod_id and m.user_id = auth.uid()));

drop policy if exists "nudges_insert_pod_members" on public.room_nudges;
create policy "nudges_insert_pod_members" on public.room_nudges for insert to authenticated
with check (
  from_user = auth.uid()
  and exists (select 1 from public.pod_members m where m.pod_id = room_nudges.pod_id and m.user_id = auth.uid())
  and exists (select 1 from public.pod_members m where m.pod_id = room_nudges.pod_id and m.user_id = room_nudges.to_user)
);

-- 5) Realtime so nudges and streaks reach online members instantly
do $$ begin
  begin alter publication supabase_realtime add table public.room_nudges; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.user_streaks; exception when duplicate_object then null; end;
end $$;

-- 6) Let teammates see who is in the room (needed to nudge people who have not locked in yet)
alter table public.pod_members add column if not exists handle text;
update public.pod_members pm set handle = p.handle from public.profiles p where p.id = pm.user_id and pm.handle is null;
drop policy if exists "update own membership" on public.pod_members;
create policy "update own membership" on public.pod_members for update to authenticated
using (user_id = auth.uid()) with check (user_id = auth.uid());


-- =====================================================================
-- MILESTONE 6 PART 1: ANALYTICS (heatmap, personal stats, room health)
-- The app calculates these itself; this section only makes them fast.
-- =====================================================================
create index if not exists checkins_user_day_idx on public.checkins (user_id, day desc);
create index if not exists checkins_pod_day_idx  on public.checkins (pod_id, day);
create index if not exists pod_members_pod_idx   on public.pod_members (pod_id);

-- Optional helper: a room's lock-in rate over the last p_days finished days.
-- Runs with the caller's permissions, so people only see rooms they belong to.
-- Example: select * from public.room_lockin_rate('<pod id>', 7);
create or replace function public.room_lockin_rate(p_pod uuid, p_days int default 7)
returns table(days_counted int, lockins int, expected int, rate numeric)
language sql stable security invoker set search_path = public as $$
  with d as (
    select g::date as day from generate_series(current_date - p_days, current_date - 1, interval '1 day') g
  ),
  exp as (
    select d.day, count(m.user_id)::int as n
    from d left join public.pod_members m on m.pod_id = p_pod and m.joined_at::date <= d.day
    group by d.day
  ),
  got as (
    select c.day, count(distinct c.user_id)::int as n
    from public.checkins c
    where c.pod_id = p_pod and c.day >= current_date - p_days and c.day < current_date
    group by c.day
  )
  select count(*)::int,
         coalesce(sum(least(coalesce(g.n,0), e.n)),0)::int,
         coalesce(sum(e.n),0)::int,
         case when sum(e.n) > 0 then round(100.0 * sum(least(coalesce(g.n,0), e.n)) / sum(e.n), 1) else 0 end
  from exp e left join got g using (day);
$$;


-- =====================================================================
-- PUBLIC FEED (real posts, hype, comments, reports) -- REQUIRED
-- The app reads and writes these tables. Without them the Public Feed
-- stays empty. Safe to run more than once.
-- =====================================================================
alter table public.profiles add column if not exists avatar_url text;
alter table public.profiles add column if not exists bio text;

create table if not exists public.posts (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  handle      text,
  content     text not null default '',
  category    text,
  proof_url   text,
  has_photo   boolean not null default false,
  has_video   boolean not null default false,
  streak      int not null default 0,
  is_verified boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists posts_created_idx on public.posts (created_at desc);
create index if not exists posts_user_idx    on public.posts (user_id);

create table if not exists public.post_hypes (
  post_id    uuid not null references public.posts(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  emoji      text not null,
  handle     text,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id, emoji)
);

create table if not exists public.post_comments (
  id         uuid primary key default gen_random_uuid(),
  post_id    uuid not null references public.posts(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  handle     text,
  content    text not null,
  created_at timestamptz not null default now()
);
create index if not exists post_comments_post_idx on public.post_comments (post_id, created_at);

create table if not exists public.post_reports (
  id          uuid primary key default gen_random_uuid(),
  post_id     uuid not null references public.posts(id) on delete cascade,
  reporter_id uuid not null references auth.users(id) on delete cascade,
  reason      text,
  created_at  timestamptz not null default now(),
  unique (post_id, reporter_id)
);

alter table public.posts         enable row level security;
alter table public.post_hypes    enable row level security;
alter table public.post_comments enable row level security;
alter table public.post_reports  enable row level security;

-- Everyone can read the feed; only signed-in people write, and only as themselves
drop policy if exists "posts public read" on public.posts;
create policy "posts public read"   on public.posts for select using (true);
drop policy if exists "posts insert own" on public.posts;
create policy "posts insert own"    on public.posts for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists "posts update own" on public.posts;
create policy "posts update own"    on public.posts for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "posts delete own" on public.posts;
create policy "posts delete own"    on public.posts for delete to authenticated using (auth.uid() = user_id);

drop policy if exists "hypes public read" on public.post_hypes;
create policy "hypes public read"   on public.post_hypes for select using (true);
drop policy if exists "hypes insert own" on public.post_hypes;
create policy "hypes insert own"    on public.post_hypes for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists "hypes delete own" on public.post_hypes;
create policy "hypes delete own"    on public.post_hypes for delete to authenticated using (auth.uid() = user_id);

drop policy if exists "pcomments public read" on public.post_comments;
create policy "pcomments public read" on public.post_comments for select using (true);
drop policy if exists "pcomments insert own" on public.post_comments;
create policy "pcomments insert own"  on public.post_comments for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists "pcomments delete own" on public.post_comments;
create policy "pcomments delete own"  on public.post_comments for delete to authenticated using (auth.uid() = user_id);

-- Reports are private: you can file one and see your own, nobody else's
drop policy if exists "reports insert own" on public.post_reports;
create policy "reports insert own"  on public.post_reports for insert to authenticated with check (auth.uid() = reporter_id);
drop policy if exists "reports read own" on public.post_reports;
create policy "reports read own"    on public.post_reports for select to authenticated using (auth.uid() = reporter_id);

-- Live updates for the feed
do $$ begin
  begin alter publication supabase_realtime add table public.posts;         exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.post_hypes;    exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.post_comments; exception when duplicate_object then null; end;
end $$;


-- =====================================================================
-- REAL JOIN REQUESTS + SAFER MEMBERSHIP RULES -- REQUIRED
-- Replaces the old "anyone can insert themselves into any group" rule.
-- Now: you can join directly only if the group is open, not full and does
-- not need approval. Otherwise you send a request and the admin decides.
-- =====================================================================
create table if not exists public.pod_requests (
  id         uuid primary key default gen_random_uuid(),
  pod_id     uuid not null references public.pods(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  handle     text,
  note       text,
  created_at timestamptz not null default now(),
  unique (pod_id, user_id)
);
alter table public.pod_requests enable row level security;

drop policy if exists "requests insert own" on public.pod_requests;
create policy "requests insert own" on public.pod_requests for insert to authenticated
with check (
  user_id = auth.uid()
  and exists (select 1 from public.pods p where p.id = pod_id and not p.locked)
);
drop policy if exists "requests read own or admin" on public.pod_requests;
create policy "requests read own or admin" on public.pod_requests for select to authenticated
using (user_id = auth.uid() or exists (select 1 from public.pods p where p.id = pod_id and p.owner_id = auth.uid()));
drop policy if exists "requests delete own or admin" on public.pod_requests;
create policy "requests delete own or admin" on public.pod_requests for delete to authenticated
using (user_id = auth.uid() or exists (select 1 from public.pods p where p.id = pod_id and p.owner_id = auth.uid()));

-- Joining: the admin can add anyone; everyone else only into an open, non-full, no-approval group
drop policy if exists "join as yourself" on public.pod_members;
drop policy if exists "join open groups or owner adds" on public.pod_members;
create policy "join open groups or owner adds" on public.pod_members for insert to authenticated
with check (
  exists (select 1 from public.pods p where p.id = pod_id and p.owner_id = auth.uid())
  or (
    user_id = auth.uid()
    and exists (
      select 1 from public.pods p
      where p.id = pod_id and not p.locked and not p.approval
        and (select count(*) from public.pod_members m where m.pod_id = p.id) < p.max_members
    )
  )
);
-- Admin can remove members (leaving yourself is already allowed by "leave as yourself")
drop policy if exists "owner removes members" on public.pod_members;
create policy "owner removes members" on public.pod_members for delete to authenticated
using (exists (select 1 from public.pods p where p.id = pod_id and p.owner_id = auth.uid()));

do $$ begin
  begin alter publication supabase_realtime add table public.pod_requests; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.pod_members;  exception when duplicate_object then null; end;
end $$;


-- =====================================================================
-- GROUP CHAT (real messages between members) -- REQUIRED
-- =====================================================================
create table if not exists public.room_messages (
  id         uuid primary key default gen_random_uuid(),
  pod_id     uuid not null references public.pods(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  handle     text,
  content    text not null default '',
  reply_from text,
  reply_text text,
  edited     boolean not null default false,
  deleted    boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists room_messages_pod_idx on public.room_messages (pod_id, created_at desc);

create table if not exists public.room_message_reactions (
  message_id uuid not null references public.room_messages(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  emoji      text not null,
  handle     text,
  created_at timestamptz not null default now(),
  primary key (message_id, user_id, emoji)
);

alter table public.room_messages          enable row level security;
alter table public.room_message_reactions enable row level security;

-- Only members of a group can read or write its chat
drop policy if exists "chat read members" on public.room_messages;
create policy "chat read members" on public.room_messages for select to authenticated
using (exists (select 1 from public.pod_members m where m.pod_id = room_messages.pod_id and m.user_id = auth.uid()));
drop policy if exists "chat send as member" on public.room_messages;
create policy "chat send as member" on public.room_messages for insert to authenticated
with check (user_id = auth.uid() and exists (select 1 from public.pod_members m where m.pod_id = room_messages.pod_id and m.user_id = auth.uid()));
drop policy if exists "chat edit own" on public.room_messages;
create policy "chat edit own" on public.room_messages for update to authenticated
using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "chat rx read members" on public.room_message_reactions;
create policy "chat rx read members" on public.room_message_reactions for select to authenticated
using (exists (select 1 from public.room_messages r join public.pod_members m on m.pod_id = r.pod_id where r.id = message_id and m.user_id = auth.uid()));
drop policy if exists "chat rx add own" on public.room_message_reactions;
create policy "chat rx add own" on public.room_message_reactions for insert to authenticated
with check (user_id = auth.uid() and exists (select 1 from public.room_messages r join public.pod_members m on m.pod_id = r.pod_id where r.id = message_id and m.user_id = auth.uid()));
drop policy if exists "chat rx remove own" on public.room_message_reactions;
create policy "chat rx remove own" on public.room_message_reactions for delete to authenticated
using (user_id = auth.uid());

do $$ begin
  begin alter publication supabase_realtime add table public.room_messages;          exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.room_message_reactions; exception when duplicate_object then null; end;
end $$;


-- =====================================================================
-- ADMIN & MODERATION (run this whole section once in the Supabase SQL Editor)
-- =====================================================================


-- =====================================================================
-- ADMIN & MODERATION -- REQUIRED
-- Reports, warnings, moderator role, and safe functions to file and
-- resolve reports. Group reports are visible ONLY to that group's owner
-- and moderators. Public Feed reports are visible ONLY to platform admins
-- (you). Safe to run more than once.
-- =====================================================================

-- 1) Platform admins (you). Add yourself in step 8 of the instructions.
create table if not exists public.platform_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.platform_admins enable row level security;
drop policy if exists "platform admin sees self" on public.platform_admins;
create policy "platform admin sees self" on public.platform_admins for select to authenticated
using (user_id = auth.uid());
revoke insert, update, delete on public.platform_admins from anon, authenticated;

-- 2) Small helper checks used by the security rules
create or replace function public.is_platform_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.platform_admins where user_id = auth.uid());
$$;
create or replace function public.is_pod_owner(p_pod uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_pod is not null and exists (select 1 from public.pods where id = p_pod and owner_id = auth.uid());
$$;
create or replace function public.is_pod_mod(p_pod uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_pod is not null and (
    exists (select 1 from public.pods where id = p_pod and owner_id = auth.uid())
    or exists (select 1 from public.pod_members where pod_id = p_pod and user_id = auth.uid() and role in ('owner', 'moderator'))
  );
$$;

-- 3) Close the role loopholes on pod_members
--    a) Joining by yourself can only ever make you a plain 'member'
drop policy if exists "join open groups or owner adds" on public.pod_members;
create policy "join open groups or owner adds" on public.pod_members for insert to authenticated
with check (
  exists (select 1 from public.pods p where p.id = pod_id and p.owner_id = auth.uid())
  or (
    user_id = auth.uid()
    and role = 'member'
    and exists (
      select 1 from public.pods p
      where p.id = pod_id and not p.locked and not p.approval
        and (select count(*) from public.pod_members m where m.pod_id = p.id) < p.max_members
    )
  )
);
--    b) Nobody can change their own role by editing their membership row
create or replace function public.guard_pod_member_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.pod_id is distinct from old.pod_id or new.user_id is distinct from old.user_id then
    raise exception 'You cannot move a membership to another group or person';
  end if;
  if new.role is distinct from old.role and auth.uid() is not null then
    if not exists (select 1 from public.pods where id = old.pod_id and owner_id = auth.uid()) then
      raise exception 'Only the group owner can change roles';
    end if;
    if old.role = 'owner' or new.role = 'owner' then
      raise exception 'The owner role cannot be changed';
    end if;
    if new.role not in ('member', 'moderator') then
      raise exception 'Invalid role';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_guard_pod_member_update on public.pod_members;
create trigger trg_guard_pod_member_update before update on public.pod_members
for each row execute function public.guard_pod_member_update();

-- 4) Reports
create table if not exists public.reports (
  id                uuid primary key default gen_random_uuid(),
  pod_id            uuid references public.pods(id) on delete cascade,
  target_type       text not null check (target_type in ('message', 'checkin', 'post', 'member')),
  target_id         uuid not null,
  target_user_id    uuid references auth.users(id) on delete set null,
  target_handle     text,
  reporter_id       uuid not null references auth.users(id) on delete cascade,
  reporter_handle   text,
  reason            text not null default 'Something else',
  details           text,
  snapshot          text,
  status            text not null default 'pending' check (status in ('pending', 'reviewed', 'dismissed', 'action_taken')),
  resolution        text check (resolution in ('reviewed', 'dismissed', 'content_deleted', 'warned', 'member_removed')),
  resolution_note   text,
  resolved_by       uuid references auth.users(id) on delete set null,
  resolved_by_handle text,
  resolved_at       timestamptz,
  created_at        timestamptz not null default now(),
  unique (reporter_id, target_type, target_id),
  check ((target_type = 'post') = (pod_id is null))
);
create index if not exists reports_pod_status_idx on public.reports (pod_id, status, created_at desc);
create index if not exists reports_post_status_idx on public.reports (status, created_at desc) where pod_id is null;
alter table public.reports enable row level security;
drop policy if exists "reports read" on public.reports;
create policy "reports read" on public.reports for select to authenticated
using (
  reporter_id = auth.uid()
  or (pod_id is not null and public.is_pod_mod(pod_id))
  or (pod_id is null and public.is_platform_admin())
);
-- No insert / update / delete rules on purpose: reports are only created and resolved
-- through the two functions below, which check everything on the server.
revoke insert, update, delete on public.reports from anon, authenticated;

-- 5) Warnings
create table if not exists public.member_warnings (
  id            uuid primary key default gen_random_uuid(),
  pod_id        uuid references public.pods(id) on delete cascade,
  user_id       uuid not null references auth.users(id) on delete cascade,
  report_id     uuid references public.reports(id) on delete set null,
  issued_by     uuid references auth.users(id) on delete set null,
  issuer_handle text,
  message       text not null,
  created_at    timestamptz not null default now()
);
create index if not exists member_warnings_user_idx on public.member_warnings (user_id, created_at desc);
alter table public.member_warnings enable row level security;
drop policy if exists "warnings read" on public.member_warnings;
create policy "warnings read" on public.member_warnings for select to authenticated
using (user_id = auth.uid() or (pod_id is not null and public.is_pod_mod(pod_id)) or (pod_id is null and public.is_platform_admin()));
revoke insert, update, delete on public.member_warnings from anon, authenticated;

-- 6) File a report. The server looks up who wrote the content and saves a copy of it,
--    so reports cannot be forged and still make sense after the content is deleted.
create or replace function public.submit_report(p_type text, p_target uuid, p_pod uuid, p_reason text, p_details text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  my_handle text;
  v_pod uuid; v_user uuid; v_handle text; v_snap text;
  rid uuid;
begin
  if me is null then raise exception 'Please sign in first'; end if;
  if p_type not in ('message', 'checkin', 'post', 'member') then raise exception 'Unknown report type'; end if;
  select handle into my_handle from public.profiles where id = me;

  if p_type = 'message' then
    select pod_id, user_id, handle, case when deleted then '' else content end
      into v_pod, v_user, v_handle, v_snap from public.room_messages where id = p_target;
    if not found then raise exception 'That message no longer exists'; end if;
  elsif p_type = 'checkin' then
    select pod_id, user_id, handle, trim(concat_ws(' ', nullif(note, ''), nullif(link, ''), nullif(proof_url, '')))
      into v_pod, v_user, v_handle, v_snap from public.checkins where id = p_target;
    if not found then raise exception 'That lock-in no longer exists'; end if;
  elsif p_type = 'post' then
    select null::uuid, user_id, handle, trim(concat_ws(' ', nullif(content, ''), nullif(proof_url, '')))
      into v_pod, v_user, v_handle, v_snap from public.posts where id = p_target;
    if not found then raise exception 'That post no longer exists'; end if;
  else
    if p_pod is null then raise exception 'A group is needed to report a member'; end if;
    v_pod := p_pod; v_user := p_target;
    select handle into v_handle from public.pod_members where pod_id = p_pod and user_id = p_target;
    if not found then raise exception 'That person is not in this group'; end if;
    v_snap := null;
  end if;

  if v_user = me then raise exception 'You cannot report yourself'; end if;
  if v_pod is not null and not exists (select 1 from public.pod_members where pod_id = v_pod and user_id = me) then
    raise exception 'You can only report things in groups you belong to';
  end if;

  insert into public.reports (pod_id, target_type, target_id, target_user_id, target_handle, reporter_id, reporter_handle, reason, details, snapshot)
  values (v_pod, p_type, p_target, v_user, v_handle, me, my_handle,
          left(coalesce(nullif(trim(p_reason), ''), 'Something else'), 60), left(p_details, 500), left(v_snap, 500))
  on conflict (reporter_id, target_type, target_id) do nothing
  returning id into rid;
  if rid is null then
    select id into rid from public.reports where reporter_id = me and target_type = p_type and target_id = p_target;
  end if;
  return rid;
end $$;

-- 7) Resolve a report (the only way a report's status can change)
create or replace function public.resolve_report(p_report uuid, p_action text, p_note text default null)
returns public.reports language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  my_handle text;
  r public.reports;
  tgt_role text;
  new_status text; new_resolution text;
begin
  if me is null then raise exception 'Please sign in first'; end if;
  select * into r from public.reports where id = p_report for update;
  if not found then raise exception 'Report not found'; end if;

  if r.pod_id is not null then
    if not public.is_pod_mod(r.pod_id) then raise exception 'Only this group''s admin or moderators can resolve this report'; end if;
  else
    if not public.is_platform_admin() then raise exception 'Only platform admins can resolve Public Feed reports'; end if;
  end if;
  if r.target_user_id = me then raise exception 'This report is about you, so another admin has to handle it'; end if;
  if r.status in ('dismissed', 'action_taken') then raise exception 'This report is already closed'; end if;
  select handle into my_handle from public.profiles where id = me;

  if p_action = 'review' then
    new_status := 'reviewed'; new_resolution := 'reviewed';
  elsif p_action = 'dismiss' then
    new_status := 'dismissed'; new_resolution := 'dismissed';
  elsif p_action = 'delete_content' then
    if r.target_type = 'message' then
      update public.room_messages set deleted = true, content = '' where id = r.target_id;
    elsif r.target_type = 'checkin' then
      update public.checkins set note = '', link = '', proof_url = null, has_photo = false, has_video = false where id = r.target_id;
    elsif r.target_type = 'post' then
      delete from public.posts where id = r.target_id;
    else
      raise exception 'A member report has no content to delete';
    end if;
    new_status := 'action_taken'; new_resolution := 'content_deleted';
  elsif p_action = 'warn' then
    if r.target_user_id is null then raise exception 'That account no longer exists'; end if;
    insert into public.member_warnings (pod_id, user_id, report_id, issued_by, issuer_handle, message)
    values (r.pod_id, r.target_user_id, r.id, me, my_handle, left(coalesce(nullif(trim(p_note), ''), 'Please follow the group rules.'), 300));
    new_status := 'action_taken'; new_resolution := 'warned';
  elsif p_action = 'remove_member' then
    if r.pod_id is null then raise exception 'Members can only be removed from a group'; end if;
    select role into tgt_role from public.pod_members where pod_id = r.pod_id and user_id = r.target_user_id;
    if tgt_role is null then raise exception 'That person is no longer in the group'; end if;
    if tgt_role = 'owner' then raise exception 'The group owner cannot be removed'; end if;
    if tgt_role = 'moderator' and not public.is_pod_owner(r.pod_id) then raise exception 'Only the owner can remove a moderator'; end if;
    delete from public.pod_members where pod_id = r.pod_id and user_id = r.target_user_id;
    new_status := 'action_taken'; new_resolution := 'member_removed';
  else
    raise exception 'Unknown action';
  end if;

  update public.reports
     set status = new_status, resolution = new_resolution, resolution_note = left(p_note, 300),
         resolved_by = me, resolved_by_handle = my_handle, resolved_at = now()
   where id = p_report
   returning * into r;
  return r;
end $$;

-- 8) The owner makes someone a moderator (or takes it back)
create or replace function public.set_member_role(p_pod uuid, p_user uuid, p_role text) returns void
language plpgsql security definer set search_path = public as $$
declare cur text;
begin
  if not public.is_pod_owner(p_pod) then raise exception 'Only the group owner can change roles'; end if;
  if p_role not in ('member', 'moderator') then raise exception 'Invalid role'; end if;
  select role into cur from public.pod_members where pod_id = p_pod and user_id = p_user;
  if cur is null then raise exception 'That person is not in the group'; end if;
  if cur = 'owner' then raise exception 'The owner role cannot be changed'; end if;
  update public.pod_members set role = p_role where pod_id = p_pod and user_id = p_user;
end $$;

-- 9) Only signed-in people may call these functions
revoke all on function public.submit_report(text, uuid, uuid, text, text) from public, anon;
revoke all on function public.resolve_report(uuid, text, text) from public, anon;
revoke all on function public.set_member_role(uuid, uuid, text) from public, anon;
grant execute on function public.submit_report(text, uuid, uuid, text, text) to authenticated;
grant execute on function public.resolve_report(uuid, text, text) to authenticated;
grant execute on function public.set_member_role(uuid, uuid, text) to authenticated;

-- 10) Live updates
do $$ begin
  begin alter publication supabase_realtime add table public.reports;         exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.member_warnings; exception when duplicate_object then null; end;
end $$;
