-- =====================================================================
--  Migration 11 - Reparation encodage des messages de choisir_skin
--
--  Meme cause que la migration 10 : le collage de 09_skins via l'editeur
--  SQL du dashboard a corrompu les accents des messages raise exception
--  (ex. "Mati[mojibake]re verrouill[mojibake]e"). La fonction refusait bien,
--  mais le texte affiche au joueur etait illisible.
--
--  Technique : le RAISE de PL/pgSQL n'accepte PAS les litteraux U&'...'
--  dans sa grammaire (contrairement au SQL normal). On construit donc les
--  accents avec chr() : chr(233)='e accent aigu', chr(232)='e accent grave'.
--  Le fichier reste 100% ASCII, inalterable par copier-coller, et produit
--  les bons accents a l'execution. Redefinition a l'identique (meme logique,
--  meme anti-fuite, meme garde-fou GUC). Aucune autre fonction touchee.
-- =====================================================================

create or replace function choisir_skin(
  p_matiere text, p_gravure text, p_aura text, p_mort text, p_teinte text)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then raise exception '%', 'Non authentifi' || chr(233); end if;

  -- Anti-fuite : jamais d'atelier en pleine partie (statut hors lobby/terminee)
  if exists (
    select 1 from joueurs_partie jp
      join parties p on p.id = jp.partie_id
     where jp.user_id = v_user
       and p.statut not in ('lobby', 'terminee')
  ) then
    raise exception '%', 'Impossible de changer d' || chr(39) || 'apparence en pleine partie';
  end if;

  if not skin_debloque(v_user, 'matiere', p_matiere) then
    raise exception '%', 'Mati' || chr(232) || 're verrouill' || chr(233) || 'e'; end if;
  if not skin_debloque(v_user, 'gravure', p_gravure) then
    raise exception '%', 'Gravure verrouill' || chr(233) || 'e'; end if;
  if not skin_debloque(v_user, 'aura', p_aura) then
    raise exception '%', 'Aura verrouill' || chr(233) || 'e'; end if;
  if not skin_debloque(v_user, 'mort', p_mort) then
    raise exception '%', 'Effet de mort verrouill' || chr(233); end if;
  if not skin_debloque(v_user, 'teinte', p_teinte) then
    raise exception '%', 'Teinte verrouill' || chr(233) || 'e'; end if;

  -- Laissez-passer pour le garde-fou trigger (GUC local, reinitialise en fin de tx)
  perform set_config('loup_garou.skin_ok', '1', true);

  update profils set
    skin_matiere = p_matiere,
    skin_gravure = p_gravure,
    skin_aura    = p_aura,
    skin_mort    = p_mort,
    skin_teinte  = p_teinte
  where id = v_user;
end $$;

grant execute on function choisir_skin(text, text, text, text, text) to authenticated, service_role;
