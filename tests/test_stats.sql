\set ON_ERROR_STOP on
\pset pager off
\set QUIET on

-- =====================================================================
--  Tests — Compteurs d'exploits (migration 08_stats_20260719.sql)
--
--  Même harnais que tests_complets.sql : PostgreSQL local, on pilote
--  auth.uid() via request.jwt.claim.sub. On rejoue une nuit 1 meurtrière
--  (dévoration d'un villageois, voyante qui sonde un loup) puis on clôt la
--  partie, et on vérifie les compteurs de profil_stats. On contrôle enfin
--  qu'un BOT n'a jamais de ligne de stats.
--
--  Pré-requis (voir README + entête) : la base doit contenir le schéma et
--  les migrations 03→08 (hors 06_cron qui exige pg_cron).
-- =====================================================================

-- Base propre à chaque exécution
truncate parties, profils, auth.users, profil_stats cascade;

insert into auth.users (email, raw_user_meta_data)
select 'j' || i || '@test.fr', jsonb_build_object('pseudo', 'Joueur' || i)
from generate_series(1,9) i;

-- Helpers (idempotents : présents aussi dans tests_complets.sql)
create or replace function _uid(p text) returns uuid language sql as
  $$ select id from auth.users where email = p $$;
create or replace function _incarner(p text) returns void language sql as
  $$ select set_config('request.jwt.claim.sub', _uid(p)::text, true)::void $$;

do $$
declare
  v_partie uuid; v_code text; u record;
  v_l1 uuid; v_l2 uuid; v_sorciere uuid; v_voyante uuid; v_cible uuid;
  v_statut statut_partie; v_n int; v_ok int := 0; v_ko int := 0;
begin
  -- ═══════════ Mise en place : 8 humains dans une partie ═══════════
  perform _incarner('j1@test.fr');
  select code, id into v_code, v_partie from creer_partie(12, true);
  for u in select email from auth.users
           where email not in ('j1@test.fr','j9@test.fr') order by email loop
    perform _incarner(u.email);
    perform rejoindre_partie(v_code);
  end loop;

  perform _incarner('j1@test.fr');
  perform demarrer_partie(v_partie);   -- 8 joueurs → cycle 1, nuit

  select user_id into v_l1 from roles_joueurs
   where partie_id = v_partie and camp = 'loups' order by user_id limit 1;
  select user_id into v_l2 from roles_joueurs
   where partie_id = v_partie and camp = 'loups' order by user_id desc limit 1;
  select user_id into v_sorciere from roles_joueurs where partie_id = v_partie and role = 'sorciere';
  select user_id into v_voyante  from roles_joueurs where partie_id = v_partie and role = 'voyante';
  select user_id into v_cible    from roles_joueurs
   where partie_id = v_partie and role = 'villageois' limit 1;

  -- ═══════════ Nuit 1 : les loups dévorent un villageois, ═══════════
  --             la voyante sonde un loup, la sorcière n'agit pas.
  perform set_config('request.jwt.claim.sub', v_l1::text, true);
  perform agir_nuit(v_partie, 'devorer', v_cible, null);
  perform set_config('request.jwt.claim.sub', v_l2::text, true);
  perform agir_nuit(v_partie, 'devorer', v_cible, null);
  perform set_config('request.jwt.claim.sub', v_voyante::text, true);
  perform agir_nuit(v_partie, 'sonder', v_l1, null);
  perform resoudre_phase(v_partie);

  -- 1. La victime est bien morte, dévorée, au cycle 1
  select count(*) into v_n from joueurs_partie where partie_id = v_partie and not vivant;
  if v_n = 1 then v_ok:=v_ok+1; raise notice '  OK   1. Un mort a la premiere nuit';
  else v_ko:=v_ko+1; raise notice '  KO   1. % mort(s) au lieu de 1', v_n; end if;

  -- 2. morts_premiere_nuit compté pour la victime dévorée
  select morts_premiere_nuit into v_n from profil_stats where user_id = v_cible;
  if coalesce(v_n,0) = 1 then v_ok:=v_ok+1; raise notice '  OK   2. morts_premiere_nuit = 1 pour le devore';
  else v_ko:=v_ko+1; raise notice '  KO   2. morts_premiere_nuit = % (attendu 1)', coalesce(v_n,-1); end if;

  -- 3. aubes_survecues compté pour un survivant (la voyante a survécu)
  select aubes_survecues into v_n from profil_stats where user_id = v_voyante;
  if coalesce(v_n,0) = 1 then v_ok:=v_ok+1; raise notice '  OK   3. aubes_survecues = 1 pour un survivant';
  else v_ko:=v_ko+1; raise notice '  KO   3. aubes_survecues = % (attendu 1)', coalesce(v_n,-1); end if;

  -- 3b. Le mort de la nuit n'a PAS d'aube survécue
  select coalesce(aubes_survecues,0) into v_n from profil_stats where user_id = v_cible;
  if coalesce(v_n,0) = 0 then v_ok:=v_ok+1; raise notice '  OK   4. aubes_survecues = 0 pour le mort';
  else v_ko:=v_ko+1; raise notice '  KO   4. Le mort a % aube(s) survecue(s)', v_n; end if;

  -- 4. loups_demasques_voyante compté pour la voyante (elle a sondé un loup)
  select loups_demasques_voyante into v_n from profil_stats where user_id = v_voyante;
  if coalesce(v_n,0) = 1 then v_ok:=v_ok+1; raise notice '  OK   5. loups_demasques_voyante = 1';
  else v_ko:=v_ko+1; raise notice '  KO   5. loups_demasques_voyante = % (attendu 1)', coalesce(v_n,-1); end if;

  -- 5. villageois_devores compté pour un loup vivant
  select villageois_devores into v_n from profil_stats where user_id = v_l1;
  if coalesce(v_n,0) = 1 then v_ok:=v_ok+1; raise notice '  OK   6. villageois_devores = 1 pour un loup';
  else v_ko:=v_ko+1; raise notice '  KO   6. villageois_devores = % (attendu 1)', coalesce(v_n,-1); end if;

  -- ═══════════ Clôture : victoire du village ═══════════
  perform terminer_partie(v_partie, 'village');

  -- 6. parties_jouees +1 pour tous les humains (ici la voyante)
  select parties_jouees into v_n from profil_stats where user_id = v_voyante;
  if coalesce(v_n,0) = 1 then v_ok:=v_ok+1; raise notice '  OK   7. parties_jouees = 1 apres la partie';
  else v_ko:=v_ko+1; raise notice '  KO   7. parties_jouees = % (attendu 1)', coalesce(v_n,-1); end if;

  -- 7. victoires_village +1 pour un joueur du camp village vainqueur
  select victoires_village into v_n from profil_stats where user_id = v_voyante;
  if coalesce(v_n,0) = 1 then v_ok:=v_ok+1; raise notice '  OK   8. victoires_village = 1 (camp vainqueur)';
  else v_ko:=v_ko+1; raise notice '  KO   8. victoires_village = % (attendu 1)', coalesce(v_n,-1); end if;

  -- 7b. les loups (camp perdant) n'ont pas de victoire de village
  select coalesce(victoires_village,0) into v_n from profil_stats where user_id = v_l1;
  if coalesce(v_n,0) = 0 then v_ok:=v_ok+1; raise notice '  OK   9. victoires_village = 0 pour un loup perdant';
  else v_ko:=v_ko+1; raise notice '  KO   9. Un loup a % victoire(s) de village', v_n; end if;

  -- 8. survies_fin_de_partie +1 pour un vivant à la fin
  select survies_fin_de_partie into v_n from profil_stats where user_id = v_voyante;
  if coalesce(v_n,0) = 1 then v_ok:=v_ok+1; raise notice '  OK  10. survies_fin_de_partie = 1 pour un vivant';
  else v_ko:=v_ko+1; raise notice '  KO  10. survies_fin_de_partie = % (attendu 1)', coalesce(v_n,-1); end if;

  -- 8b. le mort ne survit pas à la fin
  select coalesce(survies_fin_de_partie,0) into v_n from profil_stats where user_id = v_cible;
  if coalesce(v_n,0) = 0 then v_ok:=v_ok+1; raise notice '  OK  11. survies_fin_de_partie = 0 pour le mort';
  else v_ko:=v_ko+1; raise notice '  KO  11. Le mort a % survie(s)', v_n; end if;

  -- ═══════════ Filtre bots : un bot n'a JAMAIS de stats ═══════════
  -- j9 n'a jamais joué ; on le marque bot et on tente une écriture directe.
  update profils set est_bot = true where id = _uid('j9@test.fr');
  perform incr_stat(_uid('j9@test.fr'), 'parties_jouees', 1);
  perform incr_stat(_uid('j9@test.fr'), 'aubes_survecues', 3);
  select count(*) into v_n from profil_stats where user_id = _uid('j9@test.fr');
  if v_n = 0 then v_ok:=v_ok+1; raise notice '  OK  12. Aucune ligne de stats pour un bot';
  else v_ko:=v_ko+1; raise notice '  KO  12. Un bot a % ligne(s) de stats', v_n; end if;

  raise notice '';
  raise notice '  ══════  % reussis, % echoues  ══════', v_ok, v_ko;
  if v_ko > 0 then raise exception '% test(s) stats en echec', v_ko; end if;
end $$;
