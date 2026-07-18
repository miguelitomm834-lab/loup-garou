-- =====================================================================
--  Migration 03 — Bots aléatoires (V1, sans LLM)
--
--  Des « joueurs-bots » complètent une partie à court d'effectif.
--  Un bot est un joueur NORMAL (mêmes tables, même RLS) dont le profil
--  porte profils.est_bot = true. Personne ne se connecte à ces comptes ;
--  ils préexistent dans auth.users et sont flaggés par marquer_bots().
--
--  Design (imposé) :
--   - la logique des bots vit dans resoudre_phase : chaque bot vivant qui
--     n'a pas agi ce cycle agit JUSTE AVANT la résolution, donc jamais
--     avant que les humains aient eu tout le temps de la phase ;
--   - 3 règles de crédibilité : un loup ne cible jamais un loup ; aucun
--     bot ne vote pour lui-même ; la voyante ne sonde jamais deux fois la
--     même personne ;
--   - un bot n'est jamais hôte ; si l'hôte humain part, la main passe à un
--     autre humain (sinon la partie est supprimée s'il ne reste que des bots).
--
--  L'intelligence (raisonnement / bluff / chat) viendra en V2 par-dessus
--  cette même plomberie, via une Edge Function (jamais côté client).
--
--  Réexécutable sans casser une base déjà migrée.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Marqueur de bot
-- ---------------------------------------------------------------------
alter table profils add column if not exists est_bot boolean not null default false;

-- Flagge comme bots les comptes techniques (bot_XX@loupgarou.test)
create or replace function marquer_bots()
returns integer language plpgsql security definer set search_path = public as $$
declare v_n integer;
begin
  update profils p
     set est_bot = true
    from auth.users u
   where u.id = p.id
     and u.email like 'bot\_%@loupgarou.test'
     and p.est_bot = false;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- ---------------------------------------------------------------------
-- 2. L'hôte complète la partie avec des bots libres (bouton du salon)
--    Un bot est "libre" s'il n'est dans aucune partie non terminée.
-- ---------------------------------------------------------------------
create or replace function remplir_avec_bots(p_partie uuid, p_nb integer)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_partie parties;
  v_place  integer;
  v_ajoutes integer := 0;
  v_bot    record;
begin
  if auth.uid() is null then raise exception 'Non authentifié'; end if;
  select * into v_partie from parties where id = p_partie for update;
  if not found then raise exception 'Partie introuvable'; end if;
  if v_partie.hote_id <> auth.uid() then raise exception 'Seul l''hôte peut ajouter des bots'; end if;
  if v_partie.statut <> 'lobby' then raise exception 'On n''ajoute des bots qu''au salon'; end if;
  if p_nb is null or p_nb < 1 then return 0; end if;

  select coalesce(max(place), 0) into v_place from joueurs_partie where partie_id = p_partie;

  for v_bot in
    select pr.id
      from profils pr
     where pr.est_bot
       and not exists (
         select 1 from joueurs_partie jp
           join parties pp on pp.id = jp.partie_id
          where jp.user_id = pr.id and pp.statut <> 'terminee')
     order by random()
  loop
    exit when v_ajoutes >= p_nb;
    exit when (select count(*) from joueurs_partie where partie_id = p_partie) >= v_partie.max_joueurs;
    v_place := v_place + 1;
    insert into joueurs_partie (partie_id, user_id, place)
    values (p_partie, v_bot.id, v_place)
    on conflict (partie_id, user_id) do nothing;
    v_ajoutes := v_ajoutes + 1;
  end loop;

  return v_ajoutes;
end $$;

-- ---------------------------------------------------------------------
-- 3. Coups des bots (heuristique aléatoire + 3 règles de crédibilité)
--    Appelés depuis resoudre_phase, juste avant la résolution.
-- ---------------------------------------------------------------------

-- Nuit : chaque bot vivant avec un pouvoir agit s'il ne l'a pas déjà fait.
create or replace function bots_jouent_nuit(p_partie uuid, p_cycle integer)
returns void language plpgsql security definer set search_path = public as $$
declare v_bot record; v_cible uuid; v_ids uuid[];
begin
  for v_bot in
    select jp.user_id, rj.role
      from joueurs_partie jp
      join roles_joueurs rj on rj.partie_id = jp.partie_id and rj.user_id = jp.user_id
      join profils pr       on pr.id = jp.user_id
     where jp.partie_id = p_partie and jp.vivant and pr.est_bot
  loop
    if v_bot.role = 'loup_garou' then
      -- Règle : un loup ne cible JAMAIS un loup. Cible déterministe
      -- (plus petite place) pour que les loups convergent sur la victime.
      if not exists (select 1 from actions_nuit
                      where partie_id = p_partie and cycle = p_cycle
                        and acteur_id = v_bot.user_id and action = 'devorer') then
        select jp.user_id into v_cible
          from joueurs_partie jp
          join roles_joueurs rj on rj.partie_id = jp.partie_id and rj.user_id = jp.user_id
         where jp.partie_id = p_partie and jp.vivant and rj.camp <> 'loups'
         order by jp.place limit 1;
        if v_cible is not null then
          insert into actions_nuit (partie_id, cycle, acteur_id, action, cible_id)
          values (p_partie, p_cycle, v_bot.user_id, 'devorer', v_cible)
          on conflict (partie_id, cycle, acteur_id, action) do nothing;
        end if;
      end if;

    elsif v_bot.role = 'voyante' then
      -- Règle : ne sonde jamais deux fois la même personne (ni elle-même).
      if not exists (select 1 from actions_nuit
                      where partie_id = p_partie and cycle = p_cycle
                        and acteur_id = v_bot.user_id and action = 'sonder') then
        select jp.user_id into v_cible
          from joueurs_partie jp
         where jp.partie_id = p_partie and jp.vivant
           and jp.user_id <> v_bot.user_id
           and jp.user_id not in (
             select an.cible_id from actions_nuit an
              where an.partie_id = p_partie and an.acteur_id = v_bot.user_id
                and an.action = 'sonder' and an.cible_id is not null)
         order by random() limit 1;
        if v_cible is not null then
          insert into actions_nuit (partie_id, cycle, acteur_id, action, cible_id)
          values (p_partie, p_cycle, v_bot.user_id, 'sonder', v_cible)
          on conflict (partie_id, cycle, acteur_id, action) do nothing;
        end if;
      end if;

    elsif v_bot.role = 'cupidon' and p_cycle = 1 then
      if not exists (select 1 from actions_nuit
                      where partie_id = p_partie and cycle = 1
                        and acteur_id = v_bot.user_id and action = 'lier') then
        select array_agg(user_id) into v_ids
          from (select jp.user_id from joueurs_partie jp
                 where jp.partie_id = p_partie and jp.vivant
                 order by random() limit 2) t;
        if array_length(v_ids, 1) = 2 then
          insert into actions_nuit (partie_id, cycle, acteur_id, action, cible_id, cible2_id)
          values (p_partie, p_cycle, v_bot.user_id, 'lier', v_ids[1], v_ids[2])
          on conflict (partie_id, cycle, acteur_id, action) do nothing;
        end if;
      end if;

    -- Sorcière : passive en V1 (ne gaspille pas ses potions, ne bloque rien).
    end if;
  end loop;
end $$;

-- Vote : chaque bot vivant vote pour un vivant, jamais pour lui-même.
create or replace function bots_votent(p_partie uuid, p_cycle integer)
returns void language plpgsql security definer set search_path = public as $$
declare v_bot record; v_cible uuid;
begin
  for v_bot in
    select jp.user_id
      from joueurs_partie jp
      join profils pr on pr.id = jp.user_id
     where jp.partie_id = p_partie and jp.vivant and pr.est_bot
  loop
    if not exists (select 1 from votes
                    where partie_id = p_partie and cycle = p_cycle
                      and votant_id = v_bot.user_id) then
      select jp.user_id into v_cible
        from joueurs_partie jp
       where jp.partie_id = p_partie and jp.vivant and jp.user_id <> v_bot.user_id
       order by random() limit 1;
      if v_cible is not null then
        insert into votes (partie_id, cycle, votant_id, cible_id)
        values (p_partie, p_cycle, v_bot.user_id, v_cible)
        on conflict (partie_id, cycle, votant_id) do nothing;
      end if;
    end if;
  end loop;
end $$;

-- Chasseur bot : tire une victime vivante au hasard, puis relance le moteur.
create or replace function bot_tire_chasseur(p_partie uuid, p_bot uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_p parties; v_cible uuid;
begin
  select * into v_p from parties where id = p_partie;
  select jp.user_id into v_cible
    from joueurs_partie jp
   where jp.partie_id = p_partie and jp.vivant and jp.user_id <> p_bot
   order by random() limit 1;
  if v_cible is not null then
    perform tuer_joueur(p_partie, v_cible, 'abattu par le chasseur');
  end if;
  update parties set chasseur_en_attente = null where id = p_partie;
  perform conclure(p_partie, coalesce(v_p.retour_phase, 'jour'));
end $$;

-- ---------------------------------------------------------------------
-- 4. Moteur principal réécrit : identique à la migration 01, mais les
--    bots agissent juste avant chaque résolution.
-- ---------------------------------------------------------------------
create or replace function resoudre_phase(p_partie uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_p parties; v_victime uuid; v_sauvee boolean; v_empoisonne uuid;
  v_lien actions_nuit; v_lynche uuid; v_max int; v_ex_aequo int;
begin
  select * into v_p from parties where id = p_partie for update;
  if not found or v_p.statut in ('lobby','terminee') then return; end if;

  -- ═══ Phase chasseur ═══
  if v_p.statut = 'chasseur' then
    if v_p.chasseur_en_attente is not null then
      -- si le chasseur est un bot, il tire immédiatement
      if exists (select 1 from profils where id = v_p.chasseur_en_attente and est_bot) then
        perform bot_tire_chasseur(p_partie, v_p.chasseur_en_attente);
        return;
      end if;
      -- chasseur humain : on attend son tir, sauf si le temps est écoulé
      if v_p.phase_fin_le is null or now() < v_p.phase_fin_le then return; end if;
      update parties set chasseur_en_attente = null where id = p_partie;
    end if;
    perform conclure(p_partie, coalesce(v_p.retour_phase, 'jour'));
    return;
  end if;

  -- ═══ Nuit ═══
  if v_p.statut = 'nuit' then
    perform bots_jouent_nuit(p_partie, v_p.cycle);   -- bots agissent juste avant la résolution

    if v_p.cycle = 1 then
      select * into v_lien from actions_nuit
       where partie_id = p_partie and cycle = 1 and action = 'lier' limit 1;
      if found and v_lien.cible2_id is not null then
        insert into couples (partie_id, joueur_a, joueur_b)
        values (p_partie, v_lien.cible_id, v_lien.cible2_id)
        on conflict (partie_id) do nothing;
      end if;
    end if;

    select cible_id into v_victime from actions_nuit
     where partie_id = p_partie and cycle = v_p.cycle and action = 'devorer'
     group by cible_id order by count(*) desc, random() limit 1;

    select exists (select 1 from actions_nuit
                   where partie_id = p_partie and cycle = v_p.cycle
                     and action = 'potion_vie' and cible_id = v_victime)
      into v_sauvee;
    if v_sauvee then
      update roles_joueurs set potion_vie_utilisee = true
       where partie_id = p_partie and role = 'sorciere';
      v_victime := null;
    end if;

    select cible_id into v_empoisonne from actions_nuit
     where partie_id = p_partie and cycle = v_p.cycle and action = 'potion_mort' limit 1;
    if v_empoisonne is not null then
      update roles_joueurs set potion_mort_utilisee = true
       where partie_id = p_partie and role = 'sorciere';
    end if;

    perform tuer_joueur(p_partie, v_victime, 'dévoré');
    perform tuer_joueur(p_partie, v_empoisonne, 'empoisonné');
    perform conclure(p_partie, 'jour');
    return;
  end if;

  -- ═══ Jour ═══
  if v_p.statut = 'jour' then
    perform appliquer_phase(p_partie, 'vote');
    return;
  end if;

  -- ═══ Vote ═══
  if v_p.statut = 'vote' then
    perform bots_votent(p_partie, v_p.cycle);        -- bots votent juste avant le dépouillement

    select count(*) into v_max from votes
     where partie_id = p_partie and cycle = v_p.cycle
     group by cible_id order by count(*) desc limit 1;

    if v_max is not null then
      select count(*) into v_ex_aequo from (
        select cible_id from votes
         where partie_id = p_partie and cycle = v_p.cycle
         group by cible_id having count(*) = v_max) t;

      if v_ex_aequo = 1 then
        select cible_id into v_lynche from votes
         where partie_id = p_partie and cycle = v_p.cycle
         group by cible_id having count(*) = v_max;
        perform tuer_joueur(p_partie, v_lynche, 'lynché par le village');
      end if;
    end if;

    perform conclure(p_partie, 'nuit');
    return;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 5. Passation d'hôte : un bot n'est jamais hôte ; si l'hôte humain
--    quitte le salon, la main passe à un autre humain.
-- ---------------------------------------------------------------------
create or replace function quitter_partie(p_partie uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from joueurs_partie
   where partie_id = p_partie and user_id = auth.uid()
     and exists (select 1 from parties where id = p_partie and statut = 'lobby');

  -- si l'hôte est parti, passer la main au plus ancien humain restant
  update parties p
     set hote_id = (
       select jp.user_id from joueurs_partie jp
         join profils pr on pr.id = jp.user_id
        where jp.partie_id = p_partie and not pr.est_bot
        order by jp.place limit 1)
   where p.id = p_partie
     and p.hote_id = auth.uid()
     and exists (select 1 from joueurs_partie jp
                   join profils pr on pr.id = jp.user_id
                  where jp.partie_id = p_partie and not pr.est_bot);

  -- s'il ne reste que des bots (ou personne), supprimer la partie du salon
  delete from parties
   where id = p_partie and statut = 'lobby'
     and not exists (select 1 from joueurs_partie jp
                       join profils pr on pr.id = jp.user_id
                      where jp.partie_id = p_partie and not pr.est_bot);
end $$;

-- ---------------------------------------------------------------------
-- 6. Droits d'exécution (mêmes que les autres RPC)
-- ---------------------------------------------------------------------
grant execute on function marquer_bots()                  to authenticated;
grant execute on function remplir_avec_bots(uuid, integer) to authenticated;
-- helpers internes appelés par resoudre_phase (SECURITY DEFINER) :
grant execute on function bots_jouent_nuit(uuid, integer)  to authenticated;
grant execute on function bots_votent(uuid, integer)       to authenticated;
grant execute on function bot_tire_chasseur(uuid, uuid)    to authenticated;
