\set ON_ERROR_STOP on
\pset pager off
\set QUIET on

-- =====================================================================
--  Tests — Pierre de sang (migration 12_pierre_de_sang_20260719.sql)
--
--  Scenario : 2 loups dans une partie. L'un des loups meurt. Le camp loups
--  gagne. On verifie que dernier_croc = 1 pour le loup survivant (dernier
--  loup vivant) et 0 pour le loup mort, et que skin_debloque('matiere',
--  'sang') suit (true pour le survivant, false pour le mort).
--
--  Pre-requis : schema + migrations 03->12 (hors 06_cron).
-- =====================================================================

truncate parties, profils, auth.users, profil_stats cascade;

insert into auth.users (email, raw_user_meta_data)
select 'j' || i || '@test.fr', jsonb_build_object('pseudo', 'Joueur' || i)
from generate_series(1,8) i;

create or replace function _uid(p text) returns uuid language sql as
  $$ select id from auth.users where email = p $$;
create or replace function _incarner(p text) returns void language sql as
  $$ select set_config('request.jwt.claim.sub', _uid(p)::text, true)::void $$;

do $$
declare
  v_partie uuid; v_code text; u record;
  v_l1 uuid; v_l2 uuid; v_cycle int;
  v_croc_survivant int; v_croc_mort int; v_ok int := 0; v_ko int := 0;
begin
  -- Mise en place : 8 humains
  perform _incarner('j1@test.fr');
  select code, id into v_code, v_partie from creer_partie(12, true);
  for u in select email from auth.users where email <> 'j1@test.fr' order by email loop
    perform _incarner(u.email);
    perform rejoindre_partie(v_code);
  end loop;
  perform _incarner('j1@test.fr');
  perform demarrer_partie(v_partie);

  -- Les deux loups
  select user_id into v_l1 from roles_joueurs
   where partie_id = v_partie and camp = 'loups' order by user_id limit 1;
  select user_id into v_l2 from roles_joueurs
   where partie_id = v_partie and camp = 'loups' order by user_id desc limit 1;

  if v_l1 = v_l2 then
    raise notice '  (partie a un seul loup — on force un second loup pour le test)';
    -- promeut un villageois vivant en loup pour garantir 2 loups distincts
    select user_id into v_l2 from roles_joueurs
     where partie_id = v_partie and camp = 'village' limit 1;
    update roles_joueurs set camp = 'loups', role = 'loup_garou'
     where partie_id = v_partie and user_id = v_l2;
  end if;

  -- Le loup v_l2 meurt (peu importe la cause), v_l1 reste seul loup vivant
  select cycle into v_cycle from parties where id = v_partie;
  perform tuer_joueur(v_partie, v_l2, 'lynché par le village');

  -- Le camp loups gagne
  perform terminer_partie(v_partie, 'loups'::camp_vainqueur);

  -- ═══════════ Vérifications ═══════════
  select coalesce(dernier_croc,0) into v_croc_survivant from profil_stats where user_id = v_l1;
  select coalesce(dernier_croc,0) into v_croc_mort      from profil_stats where user_id = v_l2;

  if v_croc_survivant = 1 then v_ok := v_ok+1; raise notice '  OK   1. dernier_croc = 1 pour le loup survivant';
  else v_ko := v_ko+1; raise notice '  KO   1. dernier_croc survivant = % (attendu 1)', v_croc_survivant; end if;

  if coalesce(v_croc_mort,0) = 0 then v_ok := v_ok+1; raise notice '  OK   2. dernier_croc = 0 pour le loup mort';
  else v_ko := v_ko+1; raise notice '  KO   2. dernier_croc mort = % (attendu 0)', v_croc_mort; end if;

  if skin_debloque(v_l1, 'matiere', 'sang') then v_ok := v_ok+1; raise notice '  OK   3. pierre de sang debloquee pour le survivant';
  else v_ko := v_ko+1; raise notice '  KO   3. pierre de sang NON debloquee pour le survivant'; end if;

  if not skin_debloque(v_l2, 'matiere', 'sang') then v_ok := v_ok+1; raise notice '  OK   4. pierre de sang verrouillee pour le loup mort';
  else v_ko := v_ko+1; raise notice '  KO   4. pierre de sang debloquee a tort pour le loup mort'; end if;

  raise notice '  ---- % reussis, % echoues ----', v_ok, v_ko;
  if v_ko > 0 then raise exception 'Test pierre de sang : % echec(s)', v_ko; end if;
end $$;
