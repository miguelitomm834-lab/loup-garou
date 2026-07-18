\set ON_ERROR_STOP on
\set QUIET on
truncate parties, profils, auth.users cascade;
insert into auth.users (email, raw_user_meta_data)
select 'j'||i||'@t.fr', jsonb_build_object('pseudo','Joueur'||i) from generate_series(1,9) i;

do $$
declare v_partie uuid; v_code text; u record; v_cupidon uuid; v_loup uuid;
        v_vil uuid; v_autre uuid; v_statut statut_partie; v_v text; v_ok int:=0; v_ko int:=0;
begin
  perform _incarner('j1@t.fr');
  select code, id into v_code, v_partie from creer_partie(12,true);
  for u in select email from auth.users where email<>'j1@t.fr' order by email loop
    perform _incarner(u.email); perform rejoindre_partie(v_code);
  end loop;
  perform _incarner('j1@t.fr');
  perform demarrer_partie(v_partie);

  select user_id into v_cupidon from roles_joueurs where partie_id=v_partie and role='cupidon';
  if v_cupidon is not null then v_ok:=v_ok+1; raise notice '  OK  18. Cupidon apparait a 9 joueurs';
  else v_ko:=v_ko+1; raise notice '  KO  18. Pas de Cupidon a 9 joueurs'; end if;

  select user_id into v_loup from roles_joueurs where partie_id=v_partie and camp='loups' limit 1;
  select user_id into v_vil  from roles_joueurs
    where partie_id=v_partie and camp='village' and user_id<>v_cupidon limit 1;

  -- Cupidon lie un loup et un villageois
  perform set_config('request.jwt.claim.sub', v_cupidon::text, true);
  perform agir_nuit(v_partie,'lier',v_loup,v_vil);
  perform resoudre_phase(v_partie);

  if exists (select 1 from couples where partie_id=v_partie) then
    v_ok:=v_ok+1; raise notice '  OK  19. Le couple est forme';
  else v_ko:=v_ko+1; raise notice '  KO  19. Aucun couple cree'; end if;

  -- Chagrin d'amour : tuer le loup doit tuer son amoureuse
  perform tuer_joueur(v_partie, v_loup, 'test');
  if not (select vivant from joueurs_partie where partie_id=v_partie and user_id=v_vil) then
    v_ok:=v_ok+1; raise notice '  OK  20. Chagrin d amour : l autre suit dans la tombe';
  else v_ko:=v_ko+1; raise notice '  KO  20. L amoureux survit'; end if;

  raise notice '  ---- % reussis, % echoues ----', v_ok, v_ko;
end $$;
