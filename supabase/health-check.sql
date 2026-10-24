-- loQin health check. Paste this whole file into Supabase > SQL Editor and click Run.
-- It only READS. It changes nothing. Look at the "status" column: anything that says MISSING needs fixing.
with need(kind, item, fix) as (values
 ('table','profiles','run setup.sql'),('table','pods','run setup.sql'),('table','pod_members','run setup.sql'),
 ('table','checkins','run setup.sql'),('table','checkin_reactions','run setup.sql'),('table','checkin_comments','run setup.sql'),
 ('table','user_streaks','run setup.sql'),('table','room_nudges','run setup.sql'),
 ('table','posts','run setup.sql'),('table','post_hypes','run setup.sql'),('table','post_comments','run setup.sql'),
 ('table','pod_requests','run setup.sql'),('table','room_messages','run setup.sql'),('table','room_message_reactions','run setup.sql'),
 ('table','reports','run setup.sql'),('table','member_warnings','run setup.sql'),('table','platform_admins','run setup.sql')
), t as (
 select kind, item, fix, case when to_regclass('public.'||item) is not null then 'OK' else 'MISSING' end as status from need
), c(item, tbl, col) as (values
 ('pod_members.handle','pod_members','handle'),('checkins.proof_url','checkins','proof_url'),
 ('pods.approval','pods','approval'),('pods.locked','pods','locked'),('pods.pinned','pods','pinned'),
 ('room_messages.reply_from','room_messages','reply_from'),('posts.category','posts','category')
), cols as (
 select 'column' as kind, item, 'run setup.sql' as fix,
   case when exists (select 1 from information_schema.columns where table_schema='public' and table_name=c.tbl and column_name=c.col) then 'OK' else 'MISSING' end as status from c
), r(tbl) as (values ('checkins'),('posts'),('post_comments'),('room_messages'),('pod_members'),('pod_requests'),('reports')),
 rt as (
 select 'realtime' as kind, tbl as item, 'run setup.sql' as fix,
   case when exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=r.tbl) then 'OK' else 'MISSING' end as status from r
), f(fn) as (values ('submit_report'),('resolve_report'),('set_member_role'),('handle_available'),('is_pod_mod')),
 fs as (
 select 'function' as kind, fn as item, 'run setup.sql' as fix,
   case when exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname=f.fn) then 'OK' else 'MISSING' end as status from f
), b as (
 select 'storage' as kind, 'proof-media bucket' as item, 'run setup.sql' as fix,
   case when exists (select 1 from storage.buckets where id='proof-media') then 'OK' else 'MISSING' end as status
)
select kind, item, status, case when status='OK' then '' else fix end as fix from (
 select * from t union all select * from cols union all select * from rt union all select * from fs union all select * from b
) x order by (status='OK'), kind, item;
