-- =====================================================================
--  Migration 04 — Bots intelligents par LLM (V2)
--
--  V1 (migration 03) : les bots jouent par heuristique, DANS resoudre_phase,
--  juste avant chaque résolution. Cette V2 ajoute la PLOMBERIE Postgres
--  permettant à une Edge Function (autre agent) de faire RAISONNER, BLUFFER
--  et CHATTER les bots via Claude Haiku, PENDANT la phase (avant la deadline).
--
--  RÈGLE D'OR : les RÈGLES du jeu restent en Postgres. Le LLM ne fait que
--  CHOISIR parmi des coups légaux ; toutes les fonctions ci-dessous VALIDENT.
--
--  Ne casse PAS la V1 : resoudre_phase n'est pas retouché. Si l'Edge Function
--  n'a pas fait jouer un bot à temps, le fallback heuristique de la V1 le fait
--  jouer au moment de la résolution (double insertion neutralisée par les
--  on conflict / vérifications « pas déjà agi »).
--
--  Toutes les fonctions : SECURITY DEFINER, set search_path = public,
--  create or replace, grant execute to authenticated ET service_role.
--  (service_role = la clé utilisée par l'Edge Function côté serveur.)
--
--  Comme un bot n'est jamais connecté (pas d'auth.uid()), ces fonctions
--  reçoivent le bot en paramètre p_bot et NE s'appuient jamais sur auth.uid().
--  Étant SECURITY DEFINER elles contournent le RLS : elles restreignent donc
--  elles-mêmes ce que le bot a le droit de voir/faire, à l'identique des
--  policies de schema_complet.sql.
--
--  Réexécutable sans casser une base déjà migrée.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0a. Filet de sécurité : sur Supabase le rôle service_role existe déjà ;
--     en test local (stub) il peut manquer. On le crée au besoin pour que
--     les grants ci-dessous passent partout. No-op sur Supabase.
-- ---------------------------------------------------------------------
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role; end if;
end $$;

-- ---------------------------------------------------------------------
-- 0b. Plafond de coût LLM par partie
-- ---------------------------------------------------------------------
alter table parties add column if not exists appels_ia integer not null default 0;

-- Incrémente le compteur d'appels LLM de la partie et renvoie la nouvelle
-- valeur. L'Edge Function s'en sert pour ne pas dépasser son budget :
-- elle appelle ceci AVANT chaque appel à Claude et s'arrête si le retour
-- dépasse le plafond qu'elle applique côté serveur.
create or replace function incrementer_appels_ia(p_partie uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare v_n integer;
begin
  update parties
     set appels_ia = appels_ia + 1
   where id = p_partie
  returning appels_ia into v_n;
  if v_n is null then raise exception 'Partie introuvable'; end if;
  return v_n;
end $$;

-- ---------------------------------------------------------------------
-- 1. État visible par un bot (respecte les mêmes limites que le RLS)
-- ---------------------------------------------------------------------
--  Renvoie UNIQUEMENT ce que ce bot a le DROIT de connaître. Ne révèle
--  JAMAIS le rôle des autres joueurs, sauf l'appartenance à la meute pour
--  un loup (comme la policy « roles secrets »).
--
--  Forme du JSON renvoyé (clés en français) — voir rapport pour le détail :
--   {
--     "mon_role":  "voyante" | "loup_garou" | ... ,
--     "mon_camp":  "village" | "loups" | "solo",
--     "vivant":    true,                    -- ce bot est-il en vie ?
--     "vivants":   [ {"place":1,"pseudo":"Alice","user_id":"...","est_bot":false}, ... ],
--     "ma_meute":  [ {"user_id":"...","pseudo":"Bob"}, ... ]  -- clé ABSENTE si pas loup
--     "phase":     {"statut":"nuit","cycle":2},
--     "cycle":     2,
--     "votes":     [ {"votant_pseudo":"Alice","cible_pseudo":"Bob"}, ... ], -- cycle courant
--     "chat":      [ {"pseudo":"Alice","contenu":"...","canal":"village"}, ... ], -- ~20 derniers
--     "mes_actions": [ {"action":"sonder","cible_id":"...","cible2_id":null}, ... ] -- ce cycle
--   }
-- ---------------------------------------------------------------------
create or replace function etat_pour_bot(p_partie uuid, p_bot uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_partie   parties;
  v_role     role_type;
  v_camp     camp_type;
  v_est_loup boolean;
  v_vivant   boolean;
  v_mort     boolean;
  v_res      jsonb;
begin
  select * into v_partie from parties where id = p_partie;
  if not found then raise exception 'Partie introuvable'; end if;

  -- le bot doit être membre de la partie
  select vivant into v_vivant
    from joueurs_partie
   where partie_id = p_partie and user_id = p_bot;
  if not found then raise exception 'Ce joueur n''est pas dans la partie'; end if;
  v_mort := not v_vivant;

  select role, camp into v_role, v_camp
    from roles_joueurs
   where partie_id = p_partie and user_id = p_bot;
  v_est_loup := (v_camp = 'loups');

  v_res := jsonb_build_object(
    'mon_role', v_role,
    'mon_camp', v_camp,
    'vivant',   v_vivant,
    'phase',    jsonb_build_object('statut', v_partie.statut, 'cycle', v_partie.cycle),
    'cycle',    v_partie.cycle
  );

  -- Joueurs vivants (info publique : place, pseudo, user_id, est_bot)
  v_res := v_res || jsonb_build_object('vivants', coalesce((
    select jsonb_agg(jsonb_build_object(
             'place',   jp.place,
             'pseudo',  pr.pseudo,
             'user_id', jp.user_id,
             'est_bot', pr.est_bot) order by jp.place)
      from joueurs_partie jp
      join profils pr on pr.id = jp.user_id
     where jp.partie_id = p_partie and jp.vivant
  ), '[]'::jsonb));

  -- Meute : seulement si le bot est loup (les AUTRES loups, vivants ou morts)
  if v_est_loup then
    v_res := v_res || jsonb_build_object('ma_meute', coalesce((
      select jsonb_agg(jsonb_build_object('user_id', rj.user_id, 'pseudo', pr.pseudo))
        from roles_joueurs rj
        join profils pr on pr.id = rj.user_id
       where rj.partie_id = p_partie and rj.camp = 'loups' and rj.user_id <> p_bot
    ), '[]'::jsonb));
  end if;

  -- Votes PUBLICS du cycle courant (pseudos seulement)
  v_res := v_res || jsonb_build_object('votes', coalesce((
    select jsonb_agg(jsonb_build_object(
             'votant_pseudo', pv.pseudo,
             'cible_pseudo',  pc.pseudo) order by v.cree_le)
      from votes v
      join profils pv on pv.id = v.votant_id
      join profils pc on pc.id = v.cible_id
     where v.partie_id = p_partie and v.cycle = v_partie.cycle
  ), '[]'::jsonb));

  -- Chat visible : 'village' toujours ; 'loups' si loup ; 'morts' si mort.
  -- Les ~20 derniers messages autorisés, rendus en ordre chronologique.
  v_res := v_res || jsonb_build_object('chat', coalesce((
    select jsonb_agg(jsonb_build_object(
             'pseudo',  t.pseudo,
             'contenu', t.contenu,
             'canal',   t.canal) order by t.cree_le)
    from (
      select m.cree_le, pr.pseudo, m.contenu, m.canal
        from messages m
        join profils pr on pr.id = m.user_id
       where m.partie_id = p_partie
         and ( m.canal = 'village'
            or (m.canal = 'loups' and v_est_loup)
            or (m.canal = 'morts' and v_mort) )
       order by m.cree_le desc
       limit 20
    ) t
  ), '[]'::jsonb));

  -- Ses propres actions de nuit déjà posées ce cycle
  v_res := v_res || jsonb_build_object('mes_actions', coalesce((
    select jsonb_agg(jsonb_build_object(
             'action',    an.action,
             'cible_id',  an.cible_id,
             'cible2_id', an.cible2_id) order by an.cree_le)
      from actions_nuit an
     where an.partie_id = p_partie and an.cycle = v_partie.cycle
       and an.acteur_id = p_bot
  ), '[]'::jsonb));

  return v_res;
end $$;

-- ---------------------------------------------------------------------
-- 2. Action de nuit d'un bot (mêmes validations qu'agir_nuit)
-- ---------------------------------------------------------------------
create or replace function bot_agir_nuit(
  p_partie uuid, p_bot uuid, p_action action_nuit,
  p_cible uuid, p_cible2 uuid default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_partie parties; v_role role_type; v_r roles_joueurs;
begin
  -- p_bot doit être un bot
  if not exists (select 1 from profils where id = p_bot and est_bot) then
    raise exception 'Ce joueur n''est pas un bot';
  end if;

  select * into v_partie from parties where id = p_partie;
  if not found then raise exception 'Partie introuvable'; end if;
  if v_partie.statut <> 'nuit' then raise exception 'Ce n''est pas la nuit'; end if;

  -- le bot doit être vivant et dans la partie
  if not exists (select 1 from joueurs_partie
                 where partie_id = p_partie and user_id = p_bot and vivant) then
    raise exception 'Le bot est mort ou n''est pas dans la partie';
  end if;

  select * into v_r from roles_joueurs where partie_id = p_partie and user_id = p_bot;
  v_role := v_r.role;

  -- le rôle a-t-il le droit de faire cette action ? (identique à agir_nuit)
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
                 where partie_id = p_partie and user_id = p_cible and vivant) then
    raise exception 'Cible invalide';
  end if;

  -- Cupidon : la 2e cible est requise, vivante et distincte de la 1re.
  -- (agir_nuit ne le vérifie pas explicitement, mais resoudre_phase ignore
  --  un lien sans cible2 ; on refuse ici pour éviter un coup gaspillé.)
  if p_action = 'lier' then
    if p_cible2 is null then raise exception 'Cupidon doit désigner deux amoureux'; end if;
    if p_cible2 = p_cible then raise exception 'Les deux amoureux doivent être différents'; end if;
    if not exists (select 1 from joueurs_partie
                   where partie_id = p_partie and user_id = p_cible2 and vivant) then
      raise exception 'Deuxième cible invalide';
    end if;
  end if;

  insert into actions_nuit (partie_id, cycle, acteur_id, action, cible_id, cible2_id)
  values (p_partie, v_partie.cycle, p_bot, p_action, p_cible,
          case when p_action = 'lier' then p_cible2 else null end)
  on conflict (partie_id, cycle, acteur_id, action)
  do update set cible_id = excluded.cible_id, cible2_id = excluded.cible2_id;

  return 'ok';
end $$;

-- ---------------------------------------------------------------------
-- 3. Vote d'un bot (mêmes validations que voter)
-- ---------------------------------------------------------------------
create or replace function bot_voter(p_partie uuid, p_bot uuid, p_cible uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_cycle int;
begin
  if not exists (select 1 from profils where id = p_bot and est_bot) then
    raise exception 'Ce joueur n''est pas un bot';
  end if;

  select cycle into v_cycle from parties where id = p_partie and statut = 'vote';
  if not found then raise exception 'Ce n''est pas l''heure du vote'; end if;

  if not exists (select 1 from joueurs_partie
                 where partie_id = p_partie and user_id = p_bot and vivant) then
    raise exception 'Les morts ne votent pas';
  end if;

  if p_cible = p_bot then raise exception 'Un bot ne vote pas pour lui-même'; end if;

  if not exists (select 1 from joueurs_partie
                 where partie_id = p_partie and user_id = p_cible and vivant) then
    raise exception 'Cible invalide';
  end if;

  insert into votes (partie_id, cycle, votant_id, cible_id)
  values (p_partie, v_cycle, p_bot, p_cible)
  on conflict (partie_id, cycle, votant_id) do update set cible_id = excluded.cible_id;

  return 'ok';
end $$;

-- ---------------------------------------------------------------------
-- 4. Message de chat d'un bot (mêmes règles de canal que la policy)
-- ---------------------------------------------------------------------
create or replace function bot_message(
  p_partie uuid, p_bot uuid, p_canal canal_chat, p_contenu text)
returns text language plpgsql security definer set search_path = public as $$
declare v_est_loup boolean; v_mort boolean; v_vivant boolean; v_contenu text;
begin
  if not exists (select 1 from profils where id = p_bot and est_bot) then
    raise exception 'Ce joueur n''est pas un bot';
  end if;

  -- membre de la partie ?
  select vivant into v_vivant
    from joueurs_partie where partie_id = p_partie and user_id = p_bot;
  if not found then raise exception 'Le bot n''est pas dans la partie'; end if;
  v_mort := not v_vivant;

  v_est_loup := exists (select 1 from roles_joueurs
                        where partie_id = p_partie and user_id = p_bot and camp = 'loups');

  -- règles de canal, identiques à la policy « messages »
  if not (
       p_canal = 'village'
    or (p_canal = 'loups' and v_est_loup)
    or (p_canal = 'morts' and v_mort)
  ) then raise exception 'Canal interdit pour ce bot'; end if;

  -- contenu : nettoyage, refus si vide, troncature à 500 caractères
  v_contenu := btrim(coalesce(p_contenu, ''));
  if char_length(v_contenu) = 0 then raise exception 'Message vide'; end if;
  v_contenu := substr(v_contenu, 1, 500);

  insert into messages (partie_id, user_id, canal, contenu)
  values (p_partie, p_bot, p_canal, v_contenu);

  return 'ok';
end $$;

-- ---------------------------------------------------------------------
-- 5. Quels bots l'Edge Function doit-elle faire jouer maintenant ?
-- ---------------------------------------------------------------------
--  Renvoie les bots ayant une action EN ATTENTE pour la phase courante :
--   - nuit     : loup sans 'devorer' ce cycle ; voyante sans 'sonder' ;
--                cupidon (cycle 1) sans 'lier' ; sorcière tant qu'il lui
--                reste au moins une potion disponible ;
--   - vote     : tous les bots vivants sans vote ce cycle ;
--   - chasseur : le chasseur_en_attente s'il est un bot.
--  (villageois : aucune action de nuit → jamais renvoyé la nuit.)
-- ---------------------------------------------------------------------
create or replace function bots_a_faire_jouer(p_partie uuid)
returns table(user_id uuid, role role_type)
language plpgsql security definer set search_path = public as $$
declare v_p parties;
begin
  select * into v_p from parties where id = p_partie;
  if not found then return; end if;

  if v_p.statut = 'nuit' then
    return query
    select jp.user_id, rj.role
      from joueurs_partie jp
      join roles_joueurs rj on rj.partie_id = jp.partie_id and rj.user_id = jp.user_id
      join profils pr        on pr.id = jp.user_id
     where jp.partie_id = p_partie and jp.vivant and pr.est_bot
       and (
            ( rj.role = 'loup_garou'
              and not exists (select 1 from actions_nuit an
                               where an.partie_id = p_partie and an.cycle = v_p.cycle
                                 and an.acteur_id = jp.user_id and an.action = 'devorer') )
         or ( rj.role = 'voyante'
              and not exists (select 1 from actions_nuit an
                               where an.partie_id = p_partie and an.cycle = v_p.cycle
                                 and an.acteur_id = jp.user_id and an.action = 'sonder') )
         or ( rj.role = 'cupidon' and v_p.cycle = 1
              and not exists (select 1 from actions_nuit an
                               where an.partie_id = p_partie and an.cycle = 1
                                 and an.acteur_id = jp.user_id and an.action = 'lier') )
         or ( rj.role = 'sorciere'
              and (not rj.potion_vie_utilisee or not rj.potion_mort_utilisee) )
       );

  elsif v_p.statut = 'vote' then
    return query
    select jp.user_id, rj.role
      from joueurs_partie jp
      join roles_joueurs rj on rj.partie_id = jp.partie_id and rj.user_id = jp.user_id
      join profils pr        on pr.id = jp.user_id
     where jp.partie_id = p_partie and jp.vivant and pr.est_bot
       and not exists (select 1 from votes v
                        where v.partie_id = p_partie and v.cycle = v_p.cycle
                          and v.votant_id = jp.user_id);

  elsif v_p.statut = 'chasseur' then
    return query
    select rj.user_id, rj.role
      from roles_joueurs rj
      join profils pr on pr.id = rj.user_id
     where rj.partie_id = p_partie
       and rj.user_id = v_p.chasseur_en_attente
       and pr.est_bot;
  end if;

  return;
end $$;

-- ---------------------------------------------------------------------
-- 6. Droits d'exécution : authenticated ET service_role
--    (l'Edge Function appelle avec la clé service_role)
-- ---------------------------------------------------------------------
grant execute on function incrementer_appels_ia(uuid)                       to authenticated, service_role;
grant execute on function etat_pour_bot(uuid, uuid)                         to authenticated, service_role;
grant execute on function bot_agir_nuit(uuid, uuid, action_nuit, uuid, uuid) to authenticated, service_role;
grant execute on function bot_voter(uuid, uuid, uuid)                       to authenticated, service_role;
grant execute on function bot_message(uuid, uuid, canal_chat, text)         to authenticated, service_role;
grant execute on function bots_a_faire_jouer(uuid)                          to authenticated, service_role;
