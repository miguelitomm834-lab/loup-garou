-- Reproduit l'environnement Supabase pour tester le schéma en local
create schema if not exists auth;

create table auth.users (
  id uuid primary key default gen_random_uuid(),
  email text unique,
  raw_user_meta_data jsonb default '{}'::jsonb
);

-- auth.uid() lit une variable de session qu'on pilotera dans les tests
create or replace function auth.uid() returns uuid
language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated; end if;
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon; end if;
end $$;

drop publication if exists supabase_realtime;
create publication supabase_realtime;
