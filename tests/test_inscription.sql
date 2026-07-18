\set QUIET on
do $$
declare v_p text; v_id uuid; v_ok int:=0; v_ko int:=0;
begin
  insert into auth.users(email, raw_user_meta_data) values ('a@t.fr','{"pseudo":"Al"}') returning id into v_id;
  select pseudo into v_p from profils where id=v_id;
  if v_p like 'Villageois%' then v_ok:=v_ok+1; raise notice '  OK  21. Pseudo trop court : compte cree (%)', v_p;
  else v_ko:=v_ko+1; raise notice '  KO  21. %', v_p; end if;

  insert into auth.users(email, raw_user_meta_data) values ('b@t.fr','{"pseudo":"Joueur1"}') returning id into v_id;
  select pseudo into v_p from profils where id=v_id;
  if v_p = 'Joueur1_2' then v_ok:=v_ok+1; raise notice '  OK  22. Pseudo pris : suffixe auto (%)', v_p;
  else v_ko:=v_ko+1; raise notice '  KO  22. % au lieu de Joueur1_2', v_p; end if;

  insert into auth.users(email, raw_user_meta_data) values ('c@t.fr','{"pseudo":"<script>alert(1)</script>"}') returning id into v_id;
  select pseudo into v_p from profils where id=v_id;
  if v_p !~ '[<>()]' then v_ok:=v_ok+1; raise notice '  OK  23. Injection nettoyee (%)', v_p;
  else v_ko:=v_ko+1; raise notice '  KO  23. Caracteres dangereux : %', v_p; end if;

  insert into auth.users(email) values ('d@t.fr') returning id into v_id;
  select pseudo into v_p from profils where id=v_id;
  if v_p is not null then v_ok:=v_ok+1; raise notice '  OK  24. Sans pseudo : nom attribue (%)', v_p;
  else v_ko:=v_ko+1; raise notice '  KO  24. Aucun profil cree'; end if;
  raise notice '  ---- % reussis, % echoues ----', v_ok, v_ko;
end $$;
