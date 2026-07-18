-- =====================================================================
--  LOUP-GAROU EN LIGNE — Schéma Supabase (MVP 6 rôles, 6 à 12 joueurs)
--  À exécuter tel quel dans Supabase → SQL Editor → New query
--  Principe : le client ne calcule RIEN. Tout passe par des RPC
--  SECURITY DEFINER et les rôles sont verrouillés par RLS.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. ENUMS
-- ---------------------------------------------------------------------
create type statut_partie   as enum ('lobby','nuit','jour','vote','chasseur','terminee');
create type role_type       as enum ('loup_garou','villageois','voyante','sorciere','chasseur','cupidon');
create type camp_type       as enum ('loups','village','solo');
create type action_nuit     as enum ('devorer','sonder','potion_vie','potion_mort','lier');
create type canal_chat      as enum ('village','loups','morts');
create type camp_vainqueur  as enum ('loups','village','amoureux');

-- ---------------------------------------------------------------------
-- 1. TABLES
-- ---------------------------------------------------------------------

-- Profil public, créé automatiquement à l'inscription (voir trigger §5)
create table profils (
  id             uuid primary key references auth.users(id) on delete cascade,
  pseudo         text unique not null check (char_length(pseudo) between 3 and 20),
  avatar         text not null default 'fauve',
  points_lune    integer not null default 0,
  parties_jouees integer not null default 0,
  victoires      integer not null default 0,
  cree_le        timestamptz not null default now()
);

create table parties (
  id             uuid primary key default gen_random_uuid(),
  code           text unique not null check (code ~ '^[0-9]{6}$'),
  hote_id        uuid not null references profils(id) on delete cascade,
  statut         statut_partie not null default 'lobby',
  cycle          integer not null default 0,          -- n° de nuit / de jour
  max_joueurs    integer not null default 12 check (max_joueurs between 6 and 12),
  publique       boolean not null default true,
  phase_fin_le   timestamptz,                          -- deadline de la phase courante
  chasseur_en_attente uuid references profils(id),      -- chasseur mort qui doit tirer
  vainqueur      camp_vainqueur,
  cree_le        timestamptz not null default now(),
  demarree_le    timestamptz,
  terminee_le    timestamptz
);
create index on parties (statut, publique);

create table joueurs_partie (
  id             uuid primary key default gen_random_uuid(),
  partie_id      uuid not null references parties(id) on delete cascade,
  user_id        uuid not null references profils(id) on delete cascade,
  place          integer not null,
  vivant         boolean not null default true,
  capitaine      boolean not null default false,
  mort_au_cycle  integer,
  cause_mort     text,
  rejoint_le     timestamptz not null default now(),
  unique (partie_id, user_id),
  unique (partie_id, place)
);
create index on joueurs_partie (partie_id);

-- Table SECRÈTE : séparée de joueurs_partie pour que le RLS puisse
-- masquer le rôle sans masquer le joueur lui-même.
create table roles_joueurs (
  partie_id            uuid not null,
  user_id              uuid not null,
  role                 role_type not null,
  camp                 camp_type not null,
  potion_vie_utilisee  boolean not null default false,
  potion_mort_utilisee boolean not null default false,
  primary key (partie_id, user_id),
  foreign key (partie_id, user_id)
    references joueurs_partie(partie_id, user_id) on delete cascade
);

-- Le couple de Cupidon : secret, visible seulement des amoureux et de Cupidon
create table couples (
  partie_id uuid primary key references parties(id) on delete cascade,
  joueur_a  uuid not null references profils(id),
  joueur_b  uuid not null references profils(id),
  check (joueur_a <> joueur_b)
);

create table actions_nuit (
  id         uuid primary key default gen_random_uuid(),
  partie_id  uuid not null references parties(id) on delete cascade,
  cycle      integer not null,
  acteur_id  uuid not null references profils(id),
  action     action_nuit not null,
  cible_id   uuid references profils(id),
  cible2_id  uuid references profils(id),          -- 2e cible de Cupidon
  cree_le    timestamptz not null default now(),
  unique (partie_id, cycle, acteur_id, action)
);
create index on actions_nuit (partie_id, cycle);

-- Les votes du jour sont PUBLICS (c'est la règle)
create table votes (
  id         uuid primary key default gen_random_uuid(),
  partie_id  uuid not null references parties(id) on delete cascade,
  cycle      integer not null,
  votant_id  uuid not null references profils(id),
  cible_id   uuid not null references profils(id),
  cree_le    timestamptz not null default now(),
  unique (partie_id, cycle, votant_id)
);
create index on votes (partie_id, cycle);

create table messages (
  id         uuid primary key default gen_random_uuid(),
  partie_id  uuid not null references parties(id) on delete cascade,
  user_id    uuid not null references profils(id),
  canal      canal_chat not null default 'village',
  contenu    text not null check (char_length(contenu) between 1 and 500),
  cree_le    timestamptz not null default now()
);
create index on messages (partie_id, canal, cree_le);

-- ---------------------------------------------------------------------
-- 2. FONCTIONS D'AIDE (SECURITY DEFINER → évitent la récursion RLS)
-- ---------------------------------------------------------------------

create or replace function est_membre(p_partie uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from joueurs_partie
    where partie_id = p_partie and user_id = auth.uid()
  );
$$;

create or replace function est_loup(p_partie uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from roles_joueurs
    where partie_id = p_partie and user_id = auth.uid() and camp = 'loups'
  );
$$;

create or replace function est_mort(p_partie uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from joueurs_partie
    where partie_id = p_partie and user_id = auth.uid() and not vivant
  );
$$;

create or replace function partie_terminee(p_partie uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (select 1 from parties where id = p_partie and statut = 'terminee');
$$;

-- ---------------------------------------------------------------------
-- 3. ROW LEVEL SECURITY
-- ---------------------------------------------------------------------
alter table profils        enable row level security;
alter table parties        enable row level security;
alter table joueurs_partie enable row level security;
alter table roles_joueurs  enable row level security;
alter table couples        enable row level security;
alter table actions_nuit   enable row level security;
alter table votes          enable row level security;
alter table messages       enable row level security;

-- Profils : lisibles par tous (classement), modifiables seulement par soi
create policy "profils lisibles" on profils for select to authenticated using (true);
create policy "profil modifiable par soi" on profils for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- Parties : les lobbys publics sont visibles, sinon il faut être membre
create policy "parties visibles" on parties for select to authenticated
  using (publique and statut = 'lobby' or est_membre(id));

-- Joueurs : visibles par les membres de la partie
create policy "joueurs visibles" on joueurs_partie for select to authenticated
  using (est_membre(partie_id) or exists (
    select 1 from parties p where p.id = partie_id and p.publique and p.statut = 'lobby'
  ));

-- ⚠️ LA POLICY LA PLUS IMPORTANTE DU FICHIER
-- Tu ne vois que ton rôle. Les loups voient leur meute. Tout est révélé en fin de partie.
create policy "roles secrets" on roles_joueurs for select to authenticated
  using (
    user_id = auth.uid()
    or partie_terminee(partie_id)
    or (camp = 'loups' and est_loup(partie_id))
  );

create policy "couple secret" on couples for select to authenticated
  using (
    auth.uid() in (joueur_a, joueur_b)
    or partie_terminee(partie_id)
    or exists (select 1 from roles_joueurs r
               where r.partie_id = couples.partie_id
                 and r.user_id = auth.uid() and r.role = 'cupidon')
  );

-- Actions de nuit : les tiennes, celles de ta meute, tout en fin de partie
create policy "actions nuit visibles" on actions_nuit for select to authenticated
  using (
    acteur_id = auth.uid()
    or partie_terminee(partie_id)
    or (action = 'devorer' and est_loup(partie_id))
  );

-- Votes du jour : publics dans la partie
create policy "votes visibles" on votes for select to authenticated
  using (est_membre(partie_id));

-- Chat : chaque canal a son public
create policy "messages visibles" on messages for select to authenticated
  using (
    est_membre(partie_id) and (
      canal = 'village'
      or (canal = 'loups' and est_loup(partie_id))
      or (canal = 'morts' and est_mort(partie_id))
    )
  );

create policy "envoyer message" on messages for insert to authenticated
  with check (
    user_id = auth.uid() and est_membre(partie_id) and (
      canal = 'village'
      or (canal = 'loups' and est_loup(partie_id))
      or (canal = 'morts' and est_mort(partie_id))
    )
  );

-- Aucune policy INSERT/UPDATE/DELETE ailleurs : tout passe par les RPC ci-dessous.

-- ---------------------------------------------------------------------
-- 4. RPC — LOBBY
-- ---------------------------------------------------------------------

create or replace function creer_partie(p_max integer default 12, p_publique boolean default true)
returns parties language plpgsql security definer set search_path = public as $$
declare v_code text; v_partie parties; v_essais int := 0;
begin
  if auth.uid() is null then raise exception 'Non authentifié'; end if;

  loop
    v_code := lpad(floor(random()*1000000)::text, 6, '0');
    exit when not exists (select 1 from parties where code = v_code and statut <> 'terminee');
    v_essais := v_essais + 1;
    if v_essais > 50 then raise exception 'Impossible de générer un code'; end if;
  end loop;

  insert into parties (code, hote_id, max_joueurs, publique)
  values (v_code, auth.uid(), p_max, p_publique)
  returning * into v_partie;

  insert into joueurs_partie (partie_id, user_id, place) values (v_partie.id, auth.uid(), 1);
  return v_partie;
end $$;

create or replace function rejoindre_partie(p_code text)
returns parties language plpgsql security definer set search_path = public as $$
declare v_partie parties; v_nb int;
begin
  if auth.uid() is null then raise exception 'Non authentifié'; end if;

  select * into v_partie from parties where code = p_code and statut = 'lobby';
  if not found then raise exception 'Partie introuvable ou déjà lancée'; end if;

  if exists (select 1 from joueurs_partie where partie_id = v_partie.id and user_id = auth.uid())
    then return v_partie; end if;

  select count(*) into v_nb from joueurs_partie where partie_id = v_partie.id;
  if v_nb >= v_partie.max_joueurs then raise exception 'Partie complète'; end if;

  insert into joueurs_partie (partie_id, user_id, place) values (v_partie.id, auth.uid(), v_nb + 1);
  return v_partie;
end $$;

create or replace function quitter_partie(p_partie uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from joueurs_partie
  where partie_id = p_partie and user_id = auth.uid()
    and exists (select 1 from parties where id = p_partie and statut = 'lobby');
  delete from parties
  where id = p_partie and statut = 'lobby'
    and not exists (select 1 from joueurs_partie where partie_id = p_partie);
end $$;

-- ---------------------------------------------------------------------
-- 5. RPC — DISTRIBUTION DES RÔLES ET LANCEMENT
-- ---------------------------------------------------------------------
--  Composition : nb_loups = arrondi(n/4)  →  6-7j:2  8-9j:2  10-12j:3
--  Voyante dès 6 · Sorcière dès 7 · Chasseur dès 8 · Cupidon dès 9
-- ---------------------------------------------------------------------

create or replace function demarrer_partie(p_partie uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_partie parties; v_n int; v_loups int; v_roles role_type[]; v_i int := 1; v_j record;
begin
  select * into v_partie from parties where id = p_partie for update;
  if not found then raise exception 'Partie introuvable'; end if;
  if v_partie.hote_id <> auth.uid() then raise exception 'Seul l''hôte peut lancer'; end if;
  if v_partie.statut <> 'lobby' then raise exception 'Partie déjà lancée'; end if;

  select count(*) into v_n from joueurs_partie where partie_id = p_partie;
  if v_n < 6 then raise exception 'Il faut au moins 6 joueurs (actuellement %)', v_n; end if;

  v_loups := greatest(1, round(v_n::numeric / 4)::int);

  v_roles := array_fill('loup_garou'::role_type, array[v_loups]);
  v_roles := v_roles || 'voyante'::role_type;
  if v_n >= 7 then v_roles := v_roles || 'sorciere'::role_type; end if;
  if v_n >= 8 then v_roles := v_roles || 'chasseur'::role_type; end if;
  if v_n >= 9 then v_roles := v_roles || 'cupidon'::role_type;  end if;
  while array_length(v_roles, 1) < v_n loop
    v_roles := v_roles || 'villageois'::role_type;
  end loop;

  -- mélange aléatoire des joueurs, attribution dans l'ordre du tableau
  for v_j in select user_id from joueurs_partie where partie_id = p_partie order by random() loop
    insert into roles_joueurs (partie_id, user_id, role, camp)
    values (p_partie, v_j.user_id, v_roles[v_i],
            case when v_roles[v_i] = 'loup_garou' then 'loups'::camp_type else 'village'::camp_type end);
    v_i := v_i + 1;
  end loop;

  update parties
     set statut = 'nuit', cycle = 1, demarree_le = now(),
         phase_fin_le = now() + interval '90 seconds'
   where id = p_partie;

  update profils set parties_jouees = parties_jouees + 1
   where id in (select user_id from joueurs_partie where partie_id = p_partie);
end $$;

-- ---------------------------------------------------------------------
-- 6. RPC — ACTIONS DE JEU
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
end $$;

create or replace function tirer_chasseur(p_partie uuid, p_cible uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_partie parties;
begin
  select * into v_partie from parties where id = p_partie;
  if v_partie.statut <> 'chasseur' or v_partie.chasseur_en_attente <> auth.uid()
    then raise exception 'Ce n''est pas à toi de tirer'; end if;

  perform tuer_joueur(p_partie, p_cible, 'chasseur');
  update parties set chasseur_en_attente = null where id = p_partie;
  perform resoudre_phase(p_partie);
end $$;

-- ---------------------------------------------------------------------
-- 7. MOTEUR — mort d'un joueur, victoire, machine à états
-- ---------------------------------------------------------------------

-- Tue un joueur, propage à son amoureux, arme le chasseur
create or replace function tuer_joueur(p_partie uuid, p_cible uuid, p_cause text)
returns void language plpgsql security definer set search_path = public as $$
declare v_cycle int; v_role role_type; v_amoureux uuid;
begin
  if p_cible is null then return; end if;
  select cycle into v_cycle from parties where id = p_partie;

  update joueurs_partie
     set vivant = false, mort_au_cycle = v_cycle, cause_mort = p_cause
   where partie_id = p_partie and user_id = p_cible and vivant;
  if not found then return; end if;

  select role into v_role from roles_joueurs where partie_id = p_partie and user_id = p_cible;
  if v_role = 'chasseur' then
    update parties set chasseur_en_attente = p_cible where id = p_partie;
  end if;

  -- chagrin d'amour
  select case when joueur_a = p_cible then joueur_b else joueur_a end
    into v_amoureux
    from couples where partie_id = p_partie and p_cible in (joueur_a, joueur_b);
  if v_amoureux is not null then
    perform tuer_joueur(p_partie, v_amoureux, 'chagrin d''amour');
  end if;
end $$;

create or replace function verifier_victoire(p_partie uuid)
returns camp_vainqueur language plpgsql security definer set search_path = public as $$
declare v_loups int; v_autres int; v_couple couples; v_camps int;
begin
  select count(*) filter (where r.camp = 'loups'),
         count(*) filter (where r.camp <> 'loups')
    into v_loups, v_autres
    from joueurs_partie j join roles_joueurs r
      on r.partie_id = j.partie_id and r.user_id = j.user_id
   where j.partie_id = p_partie and j.vivant;

  -- Les amoureux gagnent s'ils sont les 2 seuls survivants et de camps opposés
  select * into v_couple from couples where partie_id = p_partie;
  if found and (v_loups + v_autres) = 2 then
    select count(distinct r.camp) into v_camps
      from joueurs_partie j join roles_joueurs r
        on r.partie_id = j.partie_id and r.user_id = j.user_id
     where j.partie_id = p_partie and j.vivant
       and j.user_id in (v_couple.joueur_a, v_couple.joueur_b);
    if v_camps = 2 then return 'amoureux'; end if;
  end if;

  if v_loups = 0 then return 'village'; end if;
  if v_loups >= v_autres then return 'loups'; end if;
  return null;
end $$;

-- Le cœur : fait avancer la partie d'une phase à la suivante.
-- Appelée par le client quand phase_fin_le est dépassé, ou par un cron.
create or replace function resoudre_phase(p_partie uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_p parties; v_victime uuid; v_sauvee boolean; v_empoisonne uuid;
  v_lien actions_nuit; v_lynche uuid; v_max int; v_ex_aequo int; v_gagnant camp_vainqueur;
begin
  select * into v_p from parties where id = p_partie for update;
  if v_p.statut = 'terminee' then return; end if;

  -- un chasseur doit tirer avant qu'on continue
  if v_p.chasseur_en_attente is not null then
    update parties set statut = 'chasseur', phase_fin_le = now() + interval '30 seconds'
     where id = p_partie;
    return;
  end if;

  if v_p.statut = 'nuit' then
    -- Cupidon (nuit 1 uniquement)
    if v_p.cycle = 1 then
      select * into v_lien from actions_nuit
       where partie_id = p_partie and cycle = 1 and action = 'lier' limit 1;
      if found and v_lien.cible2_id is not null then
        insert into couples (partie_id, joueur_a, joueur_b)
        values (p_partie, v_lien.cible_id, v_lien.cible2_id)
        on conflict (partie_id) do nothing;
      end if;
    end if;

    -- vote des loups : la cible majoritaire
    select cible_id into v_victime from actions_nuit
     where partie_id = p_partie and cycle = v_p.cycle and action = 'devorer'
     group by cible_id order by count(*) desc, random() limit 1;

    -- potion de vie de la sorcière
    select exists (select 1 from actions_nuit
                   where partie_id = p_partie and cycle = v_p.cycle
                     and action = 'potion_vie' and cible_id = v_victime)
      into v_sauvee;
    if v_sauvee then
      update roles_joueurs set potion_vie_utilisee = true
       where partie_id = p_partie and role = 'sorciere';
      v_victime := null;
    end if;

    -- potion de mort
    select cible_id into v_empoisonne from actions_nuit
     where partie_id = p_partie and cycle = v_p.cycle and action = 'potion_mort' limit 1;
    if v_empoisonne is not null then
      update roles_joueurs set potion_mort_utilisee = true
       where partie_id = p_partie and role = 'sorciere';
    end if;

    perform tuer_joueur(p_partie, v_victime, 'dévoré');
    perform tuer_joueur(p_partie, v_empoisonne, 'empoisonné');

    v_gagnant := verifier_victoire(p_partie);
    if v_gagnant is not null then perform terminer_partie(p_partie, v_gagnant); return; end if;

    update parties set statut = 'jour', phase_fin_le = now() + interval '180 seconds'
     where id = p_partie;

  elsif v_p.statut = 'jour' then
    update parties set statut = 'vote', phase_fin_le = now() + interval '60 seconds'
     where id = p_partie;

  elsif v_p.statut = 'vote' then
    -- majorité stricte, égalité = personne ne meurt
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

    v_gagnant := verifier_victoire(p_partie);
    if v_gagnant is not null then perform terminer_partie(p_partie, v_gagnant); return; end if;

    update parties set statut = 'nuit', cycle = v_p.cycle + 1,
                       phase_fin_le = now() + interval '90 seconds'
     where id = p_partie;
  end if;

  -- si le chasseur vient d'être armé pendant cette résolution
  select * into v_p from parties where id = p_partie;
  if v_p.chasseur_en_attente is not null then
    update parties set statut = 'chasseur', phase_fin_le = now() + interval '30 seconds'
     where id = p_partie;
  end if;
end $$;

create or replace function terminer_partie(p_partie uuid, p_vainqueur camp_vainqueur)
returns void language plpgsql security definer set search_path = public as $$
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
end $$;

-- ---------------------------------------------------------------------
-- 8. TRIGGER — création automatique du profil à l'inscription
-- ---------------------------------------------------------------------
create or replace function gerer_nouvel_utilisateur()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into profils (id, pseudo)
  values (new.id, coalesce(new.raw_user_meta_data->>'pseudo',
                           'Villageois' || substr(new.id::text, 1, 6)));
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function gerer_nouvel_utilisateur();

-- ---------------------------------------------------------------------
-- 9. REALTIME — tables diffusées en direct aux clients
-- ---------------------------------------------------------------------
alter publication supabase_realtime add table parties;
alter publication supabase_realtime add table joueurs_partie;
alter publication supabase_realtime add table messages;
alter publication supabase_realtime add table votes;

-- ---------------------------------------------------------------------
-- 10. VUE — classement de la saison
-- ---------------------------------------------------------------------
create or replace view classement as
  select row_number() over (order by points_lune desc) as rang,
         pseudo, avatar, parties_jouees, victoires, points_lune
    from profils
   where parties_jouees > 0
   order by points_lune desc
   limit 100;

grant select on classement to authenticated, anon;
-- =====================================================================
--  Migration 01 — Correction du blocage après le tir du chasseur
--
--  Problème : resoudre_phase() ne traitait que 'nuit', 'jour' et 'vote'.
--  Quand le chasseur mourait, la partie passait en statut 'chasseur' et
--  plus rien ne la faisait repartir : partie figée définitivement.
--
--  Correction : on mémorise la phase à reprendre dans parties.retour_phase,
--  et toute transition passe désormais par appliquer_phase(), qui détourne
--  automatiquement vers le chasseur quand il y en a un en attente.
-- =====================================================================

alter table parties add column if not exists retour_phase statut_partie;

-- Durée de chaque phase, en un seul endroit
create or replace function duree_phase(p_phase statut_partie)
returns interval language sql immutable as $$
  select case p_phase
    when 'nuit'     then interval '90 seconds'
    when 'jour'     then interval '180 seconds'
    when 'vote'     then interval '60 seconds'
    when 'chasseur' then interval '30 seconds'
    else null end;
$$;

-- Applique une transition. Si un chasseur doit tirer, on l'intercale
-- et on garde en mémoire la phase prévue.
create or replace function appliquer_phase(p_partie uuid, p_phase statut_partie)
returns void language plpgsql security definer set search_path = public as $$
declare v_chasseur uuid;
begin
  select chasseur_en_attente into v_chasseur from parties where id = p_partie;

  if v_chasseur is not null then
    update parties
       set statut = 'chasseur', retour_phase = p_phase,
           phase_fin_le = now() + duree_phase('chasseur')
     where id = p_partie;
    return;
  end if;

  update parties
     set statut = p_phase, retour_phase = null,
         cycle = case when p_phase = 'nuit' then cycle + 1 else cycle end,
         phase_fin_le = now() + duree_phase(p_phase)
   where id = p_partie;
end $$;

-- Vérifie la victoire puis enchaîne, en laissant le chasseur passer avant.
create or replace function conclure(p_partie uuid, p_phase statut_partie)
returns void language plpgsql security definer set search_path = public as $$
declare v_gagnant camp_vainqueur;
begin
  -- un chasseur en attente tire avant qu'on décide de quoi que ce soit
  if exists (select 1 from parties where id = p_partie and chasseur_en_attente is not null) then
    perform appliquer_phase(p_partie, p_phase);
    return;
  end if;

  v_gagnant := verifier_victoire(p_partie);
  if v_gagnant is not null then
    perform terminer_partie(p_partie, v_gagnant);
    return;
  end if;

  perform appliquer_phase(p_partie, p_phase);
end $$;

-- Moteur principal, réécrit
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
      -- il n'a pas encore tiré : on attend, sauf si le temps est écoulé
      if v_p.phase_fin_le is null or now() < v_p.phase_fin_le then return; end if;
      update parties set chasseur_en_attente = null where id = p_partie;
    end if;
    perform conclure(p_partie, coalesce(v_p.retour_phase, 'jour'));
    return;
  end if;

  -- ═══ Nuit ═══
  if v_p.statut = 'nuit' then
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

-- Le tir lui-même : on tue, on désarme, puis on laisse le moteur reprendre
create or replace function tirer_chasseur(p_partie uuid, p_cible uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_partie parties;
begin
  select * into v_partie from parties where id = p_partie;
  if v_partie.statut <> 'chasseur' or v_partie.chasseur_en_attente is distinct from auth.uid()
    then raise exception 'Ce n''est pas à toi de tirer'; end if;

  if not exists (select 1 from joueurs_partie
                 where partie_id = p_partie and user_id = p_cible and vivant)
    then raise exception 'Cible invalide'; end if;

  perform tuer_joueur(p_partie, p_cible, 'abattu par le chasseur');
  update parties set chasseur_en_attente = null where id = p_partie;
  perform conclure(p_partie, coalesce(v_partie.retour_phase, 'jour'));
end $$;
-- =====================================================================
--  Migration 02 — Inscription robuste
--
--  Problème : le trigger d'inscription insérait le pseudo brut. Un pseudo
--  trop court, trop long ou déjà pris faisait échouer toute la création du
--  compte avec une erreur de contrainte illisible côté client.
--
--  Correction : on nettoie le pseudo, et on lève un doublon en suffixant
--  au lieu de refuser l'inscription.
-- =====================================================================

create or replace function gerer_nouvel_utilisateur()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_pseudo text;
  v_base   text;
  v_i      int := 1;
begin
  -- on ne garde que des caractères raisonnables
  v_pseudo := regexp_replace(
                coalesce(new.raw_user_meta_data->>'pseudo', ''),
                '[^A-Za-zÀ-ÿ0-9_\- ]', '', 'g');
  v_pseudo := btrim(v_pseudo);

  -- trop court : on retombe sur un nom de villageois anonyme
  if char_length(v_pseudo) < 3 then
    v_pseudo := 'Villageois' || substr(replace(new.id::text,'-',''), 1, 6);
  end if;

  v_pseudo := substr(v_pseudo, 1, 20);
  v_base   := v_pseudo;

  -- pseudo déjà pris : on suffixe plutôt que de bloquer l'inscription
  while exists (select 1 from profils where pseudo = v_pseudo) loop
    v_i := v_i + 1;
    v_pseudo := substr(v_base, 1, 20 - char_length(v_i::text) - 1) || '_' || v_i;
    if v_i > 999 then
      v_pseudo := 'Villageois' || substr(replace(gen_random_uuid()::text,'-',''), 1, 8);
      exit;
    end if;
  end loop;

  insert into profils (id, pseudo) values (new.id, v_pseudo);
  return new;
end $$;

-- Permet au joueur de changer de pseudo plus tard, avec les mêmes règles
create or replace function changer_pseudo(p_pseudo text)
returns profils language plpgsql security definer set search_path = public as $$
declare v_p text; v_r profils;
begin
  v_p := btrim(regexp_replace(p_pseudo, '[^A-Za-zÀ-ÿ0-9_\- ]', '', 'g'));
  if char_length(v_p) < 3 then raise exception 'Le pseudo fait 3 caractères minimum'; end if;
  if char_length(v_p) > 20 then raise exception 'Le pseudo fait 20 caractères maximum'; end if;
  if exists (select 1 from profils where pseudo = v_p and id <> auth.uid())
    then raise exception 'Ce pseudo est déjà pris'; end if;

  update profils set pseudo = v_p where id = auth.uid() returning * into v_r;
  return v_r;
end $$;
