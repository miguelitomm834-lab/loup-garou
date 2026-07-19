-- =====================================================================
--  Migration 09 — Skins de statue (Chantier #5, partie SQL)
--
--  Objectif : chaque joueur sculpte l'apparence de sa statue au PROFIL
--  (jamais en partie). Cinq axes indépendants, chacun avec un défaut
--  gratuit et des variantes qui se MÉRITENT via les statistiques :
--    - matiere (granit par défaut)
--    - gravure (initiale par défaut)
--    - aura    (aucune  par défaut)
--    - mort    (fissure par défaut)  — l'effet à la mort
--    - teinte  (os      par défaut)
--
--  CONTRAT anti-triche (comme le reste du schéma) :
--    Le client ne décide RIEN. Il ne fait qu'appeler choisir_skin() ;
--    tout déblocage est recalculé côté serveur à partir de profil_stats
--    (migration 08). skin_debloque() est la source de vérité unique.
--
--  ANTI-FUITE : ce fichier ne lit JAMAIS le rôle en cours ni l'état
--  d'une partie en cours pour DÉCIDER d'une apparence. La seule lecture
--  de partie est un garde-fou : on REFUSE de changer d'apparence tant
--  que le joueur est engagé dans une partie de statut autre que
--  'lobby'/'terminee' (les skins se choisissent au calme, au profil).
--
--  HYPOTHÈSE profil_stats (migration 08) : table clé par une colonne
--  `user_id uuid` -> profils(id), à l'image de joueurs_partie / votes /
--  roles_joueurs qui utilisent tous `user_id`. Un joueur sans ligne =
--  tous les compteurs à 0 (coalesce(...,0)).
--
--  ÉCART DOCUMENTÉ — « morts alternatives » : le cahier des charges de
--  référence pour les seuils des effets de mort (poussiere / mousse /
--  brume_mort) était manquant au moment d'écrire ce fichier. On implémente
--  donc des exploits SIMPLES et TRAÇABLES, à réaligner si la spec arrive :
--    poussiere  -> parties_jouees        >= 10
--    mousse     -> survies_fin_de_partie >= 10
--    brume_mort -> accusations_survecues >= 5
--
--  RISQUE RLS traité ici : la policy « profil modifiable par soi »
--  (schema.sql) autorise un joueur à UPDATE sa propre ligne profils,
--  donc à écrire directement ses colonnes skin_* en CONTOURNANT
--  choisir_skin(). Correction ci-dessous (§5) : un trigger BEFORE UPDATE
--  interdit toute mutation des colonnes skin_* qui ne passe pas par
--  choisir_skin() (repéré par un GUC local que seule cette fonction pose).
--
--  Réexécutable (create or replace, add column if not exists, drop
--  trigger if exists). On ne touche AUCUN fichier existant.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Colonnes d'apparence sur profils (défauts gratuits)
-- ---------------------------------------------------------------------
alter table profils add column if not exists skin_matiere text not null default 'granit';
alter table profils add column if not exists skin_gravure text not null default 'initiale';
alter table profils add column if not exists skin_aura    text not null default 'aucune';
alter table profils add column if not exists skin_mort    text not null default 'fissure';
alter table profils add column if not exists skin_teinte  text not null default 'os';

-- ---------------------------------------------------------------------
-- 2. skin_debloque — source de vérité UNIQUE des déblocages
--    Lit profil_stats (un joueur sans ligne = tous compteurs 0).
--    Valeur inconnue dans une catégorie -> false, jamais d'exception.
-- ---------------------------------------------------------------------
create or replace function skin_debloque(p_user uuid, p_categorie text, p_valeur text)
returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  s profil_stats%rowtype;   -- ligne NULL si le joueur n'a pas encore de stats
begin
  select * into s from profil_stats where user_id = p_user;

  return case p_categorie

    when 'matiere' then case p_valeur
      when 'granit'     then true
      when 'bois'       then coalesce(s.survies_fin_de_partie, 0) >= 5
      when 'obsidienne' then coalesce(s.victoires_loups, 0)       >= 10
      when 'marbre'     then coalesce(s.victoires_village, 0)      >= 10
      when 'os'         then coalesce(s.morts_premiere_nuit, 0)    >= 3
      else false
    end

    when 'gravure' then case
      -- gratuit dès le jour un : l'initiale, les 8 runes et 4 motifs libres
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
      -- toutes gratuites (choix libre du jour un)
      when 'os'        then true
      when 'ambre'     then true
      when 'sang_pale' then true
      when 'brume'     then true
      else false
    end

    when 'mort' then case p_valeur
      when 'fissure'    then true
      -- écart documenté (voir en-tête) : exploits simples, à réaligner
      when 'poussiere'  then coalesce(s.parties_jouees, 0)        >= 10
      when 'mousse'     then coalesce(s.survies_fin_de_partie, 0) >= 10
      when 'brume_mort' then coalesce(s.accusations_survecues, 0) >= 5
      else false
    end

    else false
  end;
end $$;

-- ---------------------------------------------------------------------
-- 3. choisir_skin — la SEULE porte d'entrée légitime
--    Refuse toute valeur non débloquée (messages français courts) et
--    tout changement d'apparence en pleine partie (anti-fuite).
-- ---------------------------------------------------------------------
create or replace function choisir_skin(
  p_matiere text, p_gravure text, p_aura text, p_mort text, p_teinte text)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'Non authentifié'; end if;

  -- Anti-fuite : jamais d'atelier en pleine partie (statut hors lobby/terminee)
  if exists (
    select 1 from joueurs_partie jp
      join parties p on p.id = jp.partie_id
     where jp.user_id = v_user
       and p.statut not in ('lobby', 'terminee')
  ) then
    raise exception 'Impossible de changer d''apparence en pleine partie';
  end if;

  if not skin_debloque(v_user, 'matiere', p_matiere) then raise exception 'Matière verrouillée'; end if;
  if not skin_debloque(v_user, 'gravure', p_gravure) then raise exception 'Gravure verrouillée'; end if;
  if not skin_debloque(v_user, 'aura',    p_aura)    then raise exception 'Aura verrouillée';    end if;
  if not skin_debloque(v_user, 'mort',    p_mort)    then raise exception 'Effet de mort verrouillé'; end if;
  if not skin_debloque(v_user, 'teinte',  p_teinte)  then raise exception 'Teinte verrouillée';  end if;

  -- Laissez-passer pour le garde-fou du §5 (GUC local, réinitialisé en fin de tx)
  perform set_config('loup_garou.skin_ok', '1', true);

  update profils set
    skin_matiere = p_matiere,
    skin_gravure = p_gravure,
    skin_aura    = p_aura,
    skin_mort    = p_mort,
    skin_teinte  = p_teinte
  where id = v_user;
end $$;

-- ---------------------------------------------------------------------
-- 4. (rien de plus côté RPC — le client n'appelle que choisir_skin)
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- 5. Garde-fou RLS : les colonnes skin_* ne se changent QUE via
--    choisir_skin(). La policy UPDATE de profils laisse le joueur écrire
--    sa propre ligne ; on bloque donc toute mutation directe des skin_*
--    qui ne pose pas le laissez-passer GUC (que seule choisir_skin pose).
--    Les autres colonnes (pseudo, avatar, points_lune, stats...) restent
--    modifiables normalement — le trigger ne réagit qu'aux skin_*.
-- ---------------------------------------------------------------------
create or replace function _skin_garde_profils()
returns trigger language plpgsql as $$
begin
  if (   new.skin_matiere is distinct from old.skin_matiere
      or new.skin_gravure is distinct from old.skin_gravure
      or new.skin_aura    is distinct from old.skin_aura
      or new.skin_mort    is distinct from old.skin_mort
      or new.skin_teinte  is distinct from old.skin_teinte)
     and coalesce(current_setting('loup_garou.skin_ok', true), '') <> '1'
  then
    raise exception 'Les apparences se changent via choisir_skin()';
  end if;
  return new;
end $$;

drop trigger if exists trg_skin_garde_profils on profils;
create trigger trg_skin_garde_profils
  before update on profils
  for each row execute function _skin_garde_profils();

-- ---------------------------------------------------------------------
-- 6. Droits d'exécution (mêmes conventions que les migrations précédentes)
-- ---------------------------------------------------------------------
grant execute on function skin_debloque(uuid, text, text)              to authenticated, service_role;
grant execute on function choisir_skin(text, text, text, text, text)   to authenticated, service_role;
