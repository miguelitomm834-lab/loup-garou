-- =====================================================================
--  Migration 03 — Rythme (Chantier #1 du cahier des charges V2)
--
--  Objectif : rendre le rythme des parties plus vif, sans jamais laisser
--  un joueur (ou un bot) figer la table.
--
--   A) passages       : les vivants peuvent réclamer le passage au vote
--                        pendant le jour ; à la majorité stricte, le jour
--                        s'écourte (délai de grâce de 2 s pour l'animation).
--   B) demander_passage: RPC de bascule (toggle) appelée par le client.
--   C) tous_ont_agi    : détecte quand plus personne n'a d'action en attente.
--   D) agir_nuit/voter : résolution anticipée branchée à la fin de chaque RPC.
--   E) duree_phase     : durées revues (nuit 75 s, jour 150 s, vote 45 s).
--
--  Réexécutable : create table if not exists, drop policy if exists,
--  create or replace function, publication realtime gardée par un test.
--
--  Dépendances :
--   - est_membre(uuid)      (schéma initial)
--   - profils.est_bot        (migration 03_bots_20260718.sql) : un bot ne
--     demande jamais le passage et ne bloque jamais tous_ont_agi.
--   - le mécanisme qui lit parties.phase_fin_le et appelle resoudre_phase
--     (hôte / cron) : on ne résout RIEN en direct ici, on avance l'échéance.
-- =====================================================================

-- ---------------------------------------------------------------------
-- A. Table passages — vote de passage au vote pendant le jour
-- ---------------------------------------------------------------------
create table if not exists passages (
  partie_id uuid not null references parties(id) on delete cascade,
  cycle     integer not null,
  user_id   uuid not null references profils(id),
  primary key (partie_id, cycle, user_id)
);

alter table passages enable row level security;

-- Lecture réservée aux membres de la partie (fonction d'aide existante).
-- Aucune policy INSERT/UPDATE/DELETE : tout passe par demander_passage().
drop policy if exists "passages visibles" on passages;
create policy "passages visibles" on passages for select to authenticated
  using (est_membre(partie_id));

-- Diffusion temps réel (idempotent : on n'ajoute que si absent)
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public'
       and tablename = 'passages'
  ) then
    alter publication supabase_realtime add table passages;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- C. tous_ont_agi — plus aucune action humaine en attente ?
-- ---------------------------------------------------------------------
--  Un BOT compte toujours comme « ayant agi » : on ne regarde que les
--  humains vivants, pour ne jamais bloquer la résolution en attendant un
--  bot (les bots jouent au moment de la résolution, cf. migration 03/04).
--
--   nuit  : chaque humain vivant disposant d'un pouvoir ACTIF ce cycle a
--           une ligne dans actions_nuit pour le cycle courant.
--           Pouvoirs actifs : loup_garou (chaque nuit), voyante (chaque
--           nuit), sorciere (si au moins une fiole restante), cupidon
--           (seulement au cycle 1). Villageois et chasseur : pas d'action.
--   vote  : chaque humain vivant a une ligne dans votes pour le cycle.
--   autre : faux (le jour est une discussion libre).
-- ---------------------------------------------------------------------
create or replace function tous_ont_agi(p_partie uuid)
returns boolean language plpgsql security definer stable set search_path = public as $$
declare v_p parties; v_manquants int;
begin
  select * into v_p from parties where id = p_partie;
  if not found then return false; end if;

  if v_p.statut = 'nuit' then
    select count(*) into v_manquants
      from joueurs_partie jp
      join roles_joueurs  r  on r.partie_id = jp.partie_id and r.user_id = jp.user_id
      join profils        pr on pr.id = jp.user_id
     where jp.partie_id = p_partie
       and jp.vivant
       and not pr.est_bot
       and (
            r.role = 'loup_garou'
         or r.role = 'voyante'
         or (r.role = 'sorciere'
             and (r.potion_vie_utilisee = false or r.potion_mort_utilisee = false))
         or (r.role = 'cupidon' and v_p.cycle = 1)
       )
       and not exists (
         select 1 from actions_nuit an
          where an.partie_id = p_partie
            and an.cycle     = v_p.cycle
            and an.acteur_id = jp.user_id
       );
    return v_manquants = 0;

  elsif v_p.statut = 'vote' then
    select count(*) into v_manquants
      from joueurs_partie jp
      join profils        pr on pr.id = jp.user_id
     where jp.partie_id = p_partie
       and jp.vivant
       and not pr.est_bot
       and not exists (
         select 1 from votes v
          where v.partie_id = p_partie
            and v.cycle     = v_p.cycle
            and v.votant_id = jp.user_id
       );
    return v_manquants = 0;
  end if;

  -- 'jour' ou autre : discussion libre, jamais « tout le monde a agi »
  return false;
end $$;

-- ---------------------------------------------------------------------
-- B. demander_passage — bascule (toggle) du vote de passage au vote
-- ---------------------------------------------------------------------
--  Signature client : demander_passage(p_partie uuid) returns void
--  À la majorité STRICTE des humains vivants, on avance l'échéance à
--  now()+2 s (délai de grâce pour l'animation) ; la résolution existante
--  (hôte / cron qui lit phase_fin_le) enchaînera. On ne résout rien ici.
-- ---------------------------------------------------------------------
create or replace function demander_passage(p_partie uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_p parties; v_existe boolean; v_vivants int; v_passages int;
begin
  if auth.uid() is null then raise exception 'Non authentifié'; end if;

  select * into v_p from parties where id = p_partie;
  if not found then raise exception 'Partie introuvable'; end if;
  if v_p.statut <> 'jour' then raise exception 'Ce n''est pas la phase de discussion'; end if;

  if not exists (select 1 from joueurs_partie
                 where partie_id = p_partie and user_id = auth.uid() and vivant)
    then raise exception 'Seuls les joueurs vivants peuvent demander le passage au vote'; end if;

  -- Toggle : présent → on annule ; absent → on demande
  select exists (
    select 1 from passages
     where partie_id = p_partie and cycle = v_p.cycle and user_id = auth.uid()
  ) into v_existe;

  if v_existe then
    delete from passages
     where partie_id = p_partie and cycle = v_p.cycle and user_id = auth.uid();
  else
    insert into passages (partie_id, cycle, user_id)
    values (p_partie, v_p.cycle, auth.uid())
    on conflict (partie_id, cycle, user_id) do nothing;
  end if;

  -- Électorat : humains vivants (un bot ne réclame jamais le passage)
  select count(*) into v_vivants
    from joueurs_partie jp
    join profils pr on pr.id = jp.user_id
   where jp.partie_id = p_partie and jp.vivant and not pr.est_bot;

  select count(*) into v_passages
    from passages
   where partie_id = p_partie and cycle = v_p.cycle;

  -- Majorité stricte : passages > vivants / 2
  if v_vivants > 0 and v_passages * 2 > v_vivants then
    update parties set phase_fin_le = now() + interval '2 seconds' where id = p_partie;
  end if;
end $$;

grant execute on function demander_passage(uuid) to authenticated;
grant execute on function tous_ont_agi(uuid)     to authenticated;

-- ---------------------------------------------------------------------
-- D. Résolution anticipée branchée à la fin de agir_nuit et voter
-- ---------------------------------------------------------------------
--  Corps recopiés fidèlement du schéma existant ; seul ajout : à la fin,
--  si tous_ont_agi est vrai, on rapproche l'échéance (sans jamais la
--  repousser, d'où le least(...)).
-- ---------------------------------------------------------------------

create or replace function agir_nuit(
  p_partie uuid, p_action action_nuit, p_cible uuid, p_cible2 uuid default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_partie parties; v_role role_type; v_r roles_joueurs;
begin
  select * into v_partie from parties where id = p_partie;
  if v_partie.statut <> 'nuit' then raise exception 'Ce n''est pas la nuit'; end if;

  if not exists (select 1 from joueurs_partie
                 where partie_id = p_partie and user_id = auth.uid() and vivant)
    then raise exception 'Tu es mort ou tu n''es pas dans la partie'; end if;

  select * into v_r from roles_joueurs where partie_id = p_partie and user_id = auth.uid();
  v_role := v_r.role;

  -- vérifie que le rôle a le droit de faire cette action
  if not (
       (p_action = 'devorer'    and v_role = 'loup_garou')
    or (p_action = 'sonder'     and v_role = 'voyante')
    or (p_action in ('potion_vie','potion_mort') and v_role = 'sorciere')
    or (p_action = 'lier'       and v_role = 'cupidon' and v_partie.cycle = 1)
  ) then raise exception 'Action non autorisée pour ton rôle'; end if;

  if p_action = 'potion_vie'  and v_r.potion_vie_utilisee  then raise exception 'Potion de vie déjà utilisée'; end if;
  if p_action = 'potion_mort' and v_r.potion_mort_utilisee then raise exception 'Potion de mort déjà utilisée'; end if;

  -- la cible doit être vivante
  if not exists (select 1 from joueurs_partie
                 where partie_id = p_partie and user_id = p_cible and vivant)
    then raise exception 'Cible invalide'; end if;

  insert into actions_nuit (partie_id, cycle, acteur_id, action, cible_id, cible2_id)
  values (p_partie, v_partie.cycle, auth.uid(), p_action, p_cible, p_cible2)
  on conflict (partie_id, cycle, acteur_id, action)
  do update set cible_id = excluded.cible_id, cible2_id = excluded.cible2_id;

  -- Résolution anticipée : si plus aucune action humaine n'est en attente,
  -- on écourte la nuit (sans jamais repousser l'échéance).
  if tous_ont_agi(p_partie) then
    update parties set phase_fin_le = least(phase_fin_le, now() + interval '2 seconds')
     where id = p_partie;
  end if;
end $$;

create or replace function voter(p_partie uuid, p_cible uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_cycle int;
begin
  select cycle into v_cycle from parties where id = p_partie and statut = 'vote';
  if not found then raise exception 'Ce n''est pas l''heure du vote'; end if;

  if not exists (select 1 from joueurs_partie
                 where partie_id = p_partie and user_id = auth.uid() and vivant)
    then raise exception 'Les morts ne votent pas'; end if;

  if not exists (select 1 from joueurs_partie
                 where partie_id = p_partie and user_id = p_cible and vivant)
    then raise exception 'Cible invalide'; end if;

  insert into votes (partie_id, cycle, votant_id, cible_id)
  values (p_partie, v_cycle, auth.uid(), p_cible)
  on conflict (partie_id, cycle, votant_id) do update set cible_id = excluded.cible_id;

  -- Résolution anticipée : APRÈS l'insert du vote, si tout le monde a voté,
  -- on écourte la phase de vote (sans jamais repousser l'échéance).
  if tous_ont_agi(p_partie) then
    update parties set phase_fin_le = least(phase_fin_le, now() + interval '2 seconds')
     where id = p_partie;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- E. Durées revues — nuit 75 s, jour 150 s, vote 45 s, chasseur 30 s
-- ---------------------------------------------------------------------
create or replace function duree_phase(p_phase statut_partie)
returns interval language sql immutable as $$
  select case p_phase
    when 'nuit'     then interval '75 seconds'
    when 'jour'     then interval '150 seconds'
    when 'vote'     then interval '45 seconds'
    when 'chasseur' then interval '30 seconds'
    else null end;
$$;
