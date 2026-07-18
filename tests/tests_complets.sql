\set ON_ERROR_STOP on
\pset pager off
\set QUIET on

-- Base propre à chaque exécution
truncate parties, profils, auth.users cascade;

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
  v_l1 uuid; v_l2 uuid; v_sorciere uuid; v_voyante uuid; v_chasseur uuid;
  v_cible uuid; v_statut statut_partie; v_cycle int; v_morts int; v_n int;
  v_ok int := 0; v_ko int := 0;

  procedure_verif text;
begin
  -- ═══════════ 1. Création et remplissage ═══════════
  perform _incarner('j1@test.fr');
  select code, id into v_code, v_partie from creer_partie(12, true);

  for u in select email from auth.users where email <> 'j1@test.fr' order by email loop
    perform _incarner(u.email);
    perform rejoindre_partie(v_code);
  end loop;

  select count(*) into v_n from joueurs_partie where partie_id = v_partie;
  if v_n = 8 then v_ok:=v_ok+1; raise notice '  OK   1. Huit joueurs dans le salon';
  else v_ko:=v_ko+1; raise notice '  KO   1. % joueurs au lieu de 8', v_n; end if;

  -- ═══════════ 2. Refus en dessous de 6 ═══════════
  begin
    perform _incarner('j1@test.fr');
    delete from joueurs_partie where partie_id = v_partie
      and user_id in (select _uid('j6@test.fr'), _uid('j7@test.fr'), _uid('j8@test.fr'));
    perform demarrer_partie(v_partie);
    v_ko:=v_ko+1; raise notice '  KO   2. Partie lancee a 5 joueurs';
  exception when others then
    v_ok:=v_ok+1; raise notice '  OK   2. Lancement refuse en dessous de 6';
  end;

  for u in select email from auth.users
           where email in ('j6@test.fr','j7@test.fr','j8@test.fr') loop
    perform _incarner(u.email);
    perform rejoindre_partie(v_code);
  end loop;

  -- ═══════════ 3. Distribution ═══════════
  perform _incarner('j1@test.fr');
  perform demarrer_partie(v_partie);

  select count(*) into v_n from roles_joueurs
   where partie_id = v_partie and role = 'loup_garou';
  if v_n = 2 then v_ok:=v_ok+1; raise notice '  OK   3. Deux loups pour huit joueurs';
  else v_ko:=v_ko+1; raise notice '  KO   3. % loups au lieu de 2', v_n; end if;

  select count(distinct role) into v_n from roles_joueurs
   where partie_id = v_partie and role in ('voyante','sorciere','chasseur');
  if v_n = 3 then v_ok:=v_ok+1; raise notice '  OK   4. Voyante, sorciere et chasseur presents';
  else v_ko:=v_ko+1; raise notice '  KO   4. Roles uniques manquants (%/3)', v_n; end if;

  select count(*) into v_n from roles_joueurs where partie_id = v_partie;
  if v_n = 8 then v_ok:=v_ok+1; raise notice '  OK   5. Un role par joueur, sans doublon';
  else v_ko:=v_ko+1; raise notice '  KO   5. % roles distribues', v_n; end if;

  select user_id into v_l1 from roles_joueurs
   where partie_id=v_partie and camp='loups' order by user_id limit 1;
  select user_id into v_l2 from roles_joueurs
   where partie_id=v_partie and camp='loups' order by user_id desc limit 1;
  select user_id into v_sorciere from roles_joueurs where partie_id=v_partie and role='sorciere';
  select user_id into v_voyante  from roles_joueurs where partie_id=v_partie and role='voyante';
  select user_id into v_chasseur from roles_joueurs where partie_id=v_partie and role='chasseur';
  select user_id into v_cible    from roles_joueurs
   where partie_id=v_partie and role='villageois' limit 1;

  -- ═══════════ 4. Nuit 1 : la sorciere sauve ═══════════
  perform set_config('request.jwt.claim.sub', v_l1::text, true);
  perform agir_nuit(v_partie,'devorer',v_cible,null);
  perform set_config('request.jwt.claim.sub', v_l2::text, true);
  perform agir_nuit(v_partie,'devorer',v_cible,null);
  perform set_config('request.jwt.claim.sub', v_sorciere::text, true);
  perform agir_nuit(v_partie,'potion_vie',v_cible,null);
  perform resoudre_phase(v_partie);

  select count(*) into v_morts from joueurs_partie where partie_id=v_partie and not vivant;
  select statut into v_statut from parties where id=v_partie;
  if v_morts = 0 and v_statut = 'jour' then
    v_ok:=v_ok+1; raise notice '  OK   6. Potion de vie : la victime survit';
  else v_ko:=v_ko+1; raise notice '  KO   6. % mort(s), phase %', v_morts, v_statut; end if;

  -- ═══════════ 5. Une action de role interdite ═══════════
  begin
    perform set_config('request.jwt.claim.sub', v_cible::text, true);
    perform agir_nuit(v_partie,'devorer',v_l1,null);
    v_ko:=v_ko+1; raise notice '  KO   7. Un villageois a pu devorer';
  exception when others then
    v_ok:=v_ok+1; raise notice '  OK   7. Un villageois ne peut pas devorer';
  end;

  -- ═══════════ 6. Vote : egalite ═══════════
  perform resoudre_phase(v_partie);
  select cycle into v_cycle from parties where id=v_partie;
  perform set_config('request.jwt.claim.sub', v_l1::text, true);
  perform voter(v_partie, v_cible);
  perform set_config('request.jwt.claim.sub', v_l2::text, true);
  perform voter(v_partie, v_voyante);
  perform resoudre_phase(v_partie);

  select count(*) into v_morts from joueurs_partie where partie_id=v_partie and not vivant;
  if v_morts = 0 then v_ok:=v_ok+1; raise notice '  OK   8. Egalite au vote : personne ne meurt';
  else v_ko:=v_ko+1; raise notice '  KO   8. % mort(s) malgre l egalite', v_morts; end if;

  select statut, cycle into v_statut, v_cycle from parties where id=v_partie;
  if v_statut='nuit' and v_cycle=2 then
    v_ok:=v_ok+1; raise notice '  OK   9. Retour a la nuit 2';
  else v_ko:=v_ko+1; raise notice '  KO   9. Phase % cycle %', v_statut, v_cycle; end if;

  -- ═══════════ 7. Potion deja utilisee ═══════════
  begin
    perform set_config('request.jwt.claim.sub', v_sorciere::text, true);
    perform agir_nuit(v_partie,'potion_vie',v_cible,null);
    v_ko:=v_ko+1; raise notice '  KO  10. La potion de vie ressert';
  exception when others then
    v_ok:=v_ok+1; raise notice '  OK  10. Potion de vie epuisee, refusee';
  end;

  -- ═══════════ 8. Nuit 2 : la victime meurt ═══════════
  perform set_config('request.jwt.claim.sub', v_l1::text, true);
  perform agir_nuit(v_partie,'devorer',v_cible,null);
  perform set_config('request.jwt.claim.sub', v_l2::text, true);
  perform agir_nuit(v_partie,'devorer',v_cible,null);
  perform resoudre_phase(v_partie);

  select count(*) into v_morts from joueurs_partie where partie_id=v_partie and not vivant;
  if v_morts = 1 then v_ok:=v_ok+1; raise notice '  OK  11. Sans potion, la victime meurt';
  else v_ko:=v_ko+1; raise notice '  KO  11. % mort(s)', v_morts; end if;

  -- ═══════════ 9. LE CHASSEUR (le bug corrige) ═══════════
  perform tuer_joueur(v_partie, v_chasseur, 'test');
  perform resoudre_phase(v_partie);
  select statut into v_statut from parties where id=v_partie;
  if v_statut = 'chasseur' then
    v_ok:=v_ok+1; raise notice '  OK  12. Mort du chasseur : la partie l attend';
  else v_ko:=v_ko+1; raise notice '  KO  12. Phase % au lieu de chasseur', v_statut; end if;

  perform set_config('request.jwt.claim.sub', v_chasseur::text, true);
  perform tirer_chasseur(v_partie, v_l1);
  select statut into v_statut from parties where id=v_partie;
  if v_statut <> 'chasseur' then
    v_ok:=v_ok+1; raise notice '  OK  13. Apres le tir la partie repart (phase %)', v_statut;
  else v_ko:=v_ko+1; raise notice '  KO  13. PARTIE FIGEE en phase chasseur'; end if;

  if not (select vivant from joueurs_partie where partie_id=v_partie and user_id=v_l1) then
    v_ok:=v_ok+1; raise notice '  OK  14. La cible du chasseur est bien morte';
  else v_ko:=v_ko+1; raise notice '  KO  14. La cible du chasseur a survecu'; end if;

  -- ═══════════ 10. Victoire du village ═══════════
  perform tuer_joueur(v_partie, v_l2, 'test');
  perform resoudre_phase(v_partie);
  select statut, vainqueur::text into v_statut, procedure_verif from parties where id=v_partie;
  if v_statut='terminee' and procedure_verif='village' then
    v_ok:=v_ok+1; raise notice '  OK  15. Dernier loup mort : le village gagne';
  else v_ko:=v_ko+1; raise notice '  KO  15. Phase % vainqueur %', v_statut, procedure_verif; end if;

  -- ═══════════ 11. Les roles sont reveles en fin de partie ═══════════
  perform set_config('request.jwt.claim.sub', v_cible::text, true);
  select count(*) into v_n from roles_joueurs where partie_id=v_partie;
  if v_n = 8 then v_ok:=v_ok+1; raise notice '  OK  16. Fin de partie : tous les roles reveles';
  else v_ko:=v_ko+1; raise notice '  KO  16. % roles visibles au lieu de 8', v_n; end if;

  -- ═══════════ 12. Points attribues ═══════════
  select points_lune into v_n from profils where id = v_cible;
  if v_n > 0 then v_ok:=v_ok+1; raise notice '  OK  17. Points de lune attribues (%)', v_n;
  else v_ko:=v_ko+1; raise notice '  KO  17. Aucun point attribue'; end if;

  raise notice '';
  raise notice '  ══════  % reussis, % echoues  ══════', v_ok, v_ko;
end $$;
