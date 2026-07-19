-- =====================================================================
--  Migration 12 - Pierre de sang (Chantier FORGE-B)
--
--  Matiere signature, rarete Maitresse, la plus rare du jeu : elle se
--  merite en gagnant en tant que DERNIER LOUP ENCORE VIVANT.
--
--  1. Nouveau compteur profil_stats.dernier_croc, incremente dans
--     terminer_partie quand le camp loups gagne ET que le joueur est
--     l'unique loup encore en vie a la fin.
--  2. incr_stat : ajout de la colonne a la whitelist (aucun SQL dynamique).
--  3. skin_debloque : la matiere 'sang' se debloque si dernier_croc >= 1.
--
--  Reexecutable : alter add column if not exists + create or replace.
--  terminer_partie et skin_debloque sont RECOPIES a l'identique de leur
--  derniere version (08 / 09) avec le seul ajout necessaire.
-- =====================================================================

alter table profil_stats add column if not exists dernier_croc integer not null default 0;

-- ---------------------------------------------------------------------
-- 1. incr_stat — recopie de 08 + la colonne dernier_croc dans la whitelist
-- ---------------------------------------------------------------------
create or replace function incr_stat(p_user uuid, p_col text, p_n int default 1)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_user is null or p_n = 0 then return; end if;
  if not exists (select 1 from profils where id = p_user and est_bot = false) then return; end if;

  insert into profil_stats (user_id) values (p_user)
  on conflict (user_id) do nothing;

  case p_col
    when 'parties_jouees'
      then update profil_stats set parties_jouees = parties_jouees + p_n where user_id = p_user;
    when 'victoires_village'
      then update profil_stats set victoires_village = victoires_village + p_n where user_id = p_user;
    when 'victoires_loups'
      then update profil_stats set victoires_loups = victoires_loups + p_n where user_id = p_user;
    when 'victoires_amoureux'
      then update profil_stats set victoires_amoureux = victoires_amoureux + p_n where user_id = p_user;
    when 'survies_fin_de_partie'
      then update profil_stats set survies_fin_de_partie = survies_fin_de_partie + p_n where user_id = p_user;
    when 'aubes_survecues'
      then update profil_stats set aubes_survecues = aubes_survecues + p_n where user_id = p_user;
    when 'morts_premiere_nuit'
      then update profil_stats set morts_premiere_nuit = morts_premiere_nuit + p_n where user_id = p_user;
    when 'loups_demasques_voyante'
      then update profil_stats set loups_demasques_voyante = loups_demasques_voyante + p_n where user_id = p_user;
    when 'villageois_devores'
      then update profil_stats set villageois_devores = villageois_devores + p_n where user_id = p_user;
    when 'pendaisons_loup_premier_vote'
      then update profil_stats set pendaisons_loup_premier_vote = pendaisons_loup_premier_vote + p_n where user_id = p_user;
    when 'sauvetages_sorciere'
      then update profil_stats set sauvetages_sorciere = sauvetages_sorciere + p_n where user_id = p_user;
    when 'accusations_survecues'
      then update profil_stats set accusations_survecues = accusations_survecues + p_n where user_id = p_user;
    when 'dernier_croc'
      then update profil_stats set dernier_croc = dernier_croc + p_n where user_id = p_user;
    else
      raise exception 'incr_stat : colonne inconnue %', p_col;
  end case;
end $$;

-- ---------------------------------------------------------------------
-- 2. terminer_partie — recopie de 08 + STAT dernier_croc
-- ---------------------------------------------------------------------
create or replace function terminer_partie(p_partie uuid, p_vainqueur camp_vainqueur)
returns void language plpgsql security definer set search_path = public as $$
declare v_rec record; v_loups_vivants int; v_dernier uuid;
begin
  update parties
     set statut = 'terminee', vainqueur = p_vainqueur,
         terminee_le = now(), phase_fin_le = null
   where id = p_partie;

  -- points de lune : 100 pour les gagnants, 25 de participation
  update profils p set points_lune = p.points_lune + 25
   where p.id in (select user_id from joueurs_partie where partie_id = p_partie);

  update profils p set points_lune = p.points_lune + 75, victoires = p.victoires + 1
   where p.id in (
     select j.user_id from joueurs_partie j
       join roles_joueurs r on r.partie_id = j.partie_id and r.user_id = j.user_id
      where j.partie_id = p_partie
        and case p_vainqueur
              when 'loups'   then r.camp = 'loups'
              when 'village' then r.camp = 'village'
              when 'amoureux' then j.user_id in (
                select unnest(array[joueur_a, joueur_b]) from couples where partie_id = p_partie)
            end
   );

  -- STAT : une partie jouée pour chaque participant (bots ignorés par incr_stat)
  for v_rec in
    select user_id from joueurs_partie where partie_id = p_partie
  loop
    perform incr_stat(v_rec.user_id, 'parties_jouees');
  end loop;

  -- STAT : victoire pour chaque joueur du camp vainqueur
  for v_rec in
    select j.user_id from joueurs_partie j
      join roles_joueurs r on r.partie_id = j.partie_id and r.user_id = j.user_id
     where j.partie_id = p_partie
       and case p_vainqueur
             when 'loups'   then r.camp = 'loups'
             when 'village' then r.camp = 'village'
             when 'amoureux' then j.user_id in (
               select unnest(array[joueur_a, joueur_b]) from couples where partie_id = p_partie)
           end
  loop
    perform incr_stat(v_rec.user_id, case p_vainqueur
      when 'loups'    then 'victoires_loups'
      when 'village'  then 'victoires_village'
      when 'amoureux' then 'victoires_amoureux'
    end);
  end loop;

  -- STAT : survie jusqu'à la fin de partie pour chaque joueur encore vivant
  for v_rec in
    select user_id from joueurs_partie where partie_id = p_partie and vivant
  loop
    perform incr_stat(v_rec.user_id, 'survies_fin_de_partie');
  end loop;

  -- STAT : « le dernier croc » — victoire loups en dernier loup vivant.
  -- On compte les loups encore vivants ; s'il n'en reste qu'UN, c'est lui.
  if p_vainqueur = 'loups' then
    select count(*) into v_loups_vivants
      from joueurs_partie j
      join roles_joueurs r on r.partie_id = j.partie_id and r.user_id = j.user_id
     where j.partie_id = p_partie and j.vivant and r.camp = 'loups';
    if v_loups_vivants = 1 then
      select j.user_id into v_dernier
        from joueurs_partie j
        join roles_joueurs r on r.partie_id = j.partie_id and r.user_id = j.user_id
       where j.partie_id = p_partie and j.vivant and r.camp = 'loups';
      perform incr_stat(v_dernier, 'dernier_croc');
    end if;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 3. skin_debloque — recopie de 09 + la matiere 'sang'
-- ---------------------------------------------------------------------
create or replace function skin_debloque(p_user uuid, p_categorie text, p_valeur text)
returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  s profil_stats%rowtype;
begin
  select * into s from profil_stats where user_id = p_user;

  return case p_categorie

    when 'matiere' then case p_valeur
      when 'granit'     then true
      when 'bois'       then coalesce(s.survies_fin_de_partie, 0) >= 5
      when 'obsidienne' then coalesce(s.victoires_loups, 0)       >= 10
      when 'marbre'     then coalesce(s.victoires_village, 0)      >= 10
      when 'os'         then coalesce(s.morts_premiere_nuit, 0)    >= 3
      when 'sang'       then coalesce(s.dernier_croc, 0)           >= 1
      else false
    end

    when 'gravure' then case
      when p_valeur in ('initiale',
                        'rune_s','rune_b','rune_m','rune_n',
                        'rune_l','rune_r','rune_t','rune_e',
                        'croissant_libre','etoile','feuille','montagne') then true
      when p_valeur = 'croissant' then coalesce(s.aubes_survecues, 0)             >= 15
      when p_valeur = 'oeil'      then coalesce(s.loups_demasques_voyante, 0)     >= 5
      when p_valeur = 'patte'     then coalesce(s.villageois_devores, 0)          >= 20
      when p_valeur = 'gibet'     then coalesce(s.pendaisons_loup_premier_vote,0) >= 1
      when p_valeur = 'coeur'     then coalesce(s.victoires_amoureux, 0)          >= 1
      else false
    end

    when 'aura' then case p_valeur
      when 'aucune'   then true
      when 'braise'   then coalesce(s.parties_jouees, 0)        >= 25
      when 'lucioles' then coalesce(s.sauvetages_sorciere, 0)   >= 5
      when 'brume'    then coalesce(s.accusations_survecues, 0) >= 10
      when 'lune'     then coalesce(s.parties_jouees, 0)        >= 50
      else false
    end

    when 'teinte' then case p_valeur
      when 'os'        then true
      when 'ambre'     then true
      when 'sang_pale' then true
      when 'brume'     then true
      else false
    end

    when 'mort' then case p_valeur
      when 'fissure'    then true
      when 'poussiere'  then coalesce(s.parties_jouees, 0)        >= 10
      when 'mousse'     then coalesce(s.survies_fin_de_partie, 0) >= 10
      when 'brume_mort' then coalesce(s.accusations_survecues, 0) >= 5
      else false
    end

    else false
  end;
end $$;

grant execute on function incr_stat(uuid, text, int)              to authenticated, service_role;
grant execute on function terminer_partie(uuid, camp_vainqueur)   to authenticated, service_role;
grant execute on function skin_debloque(uuid, text, text)         to authenticated, service_role;
