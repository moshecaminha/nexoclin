-- 034 - "omarcelo sim" nao pode virar paciente.
-- O nome era gravado do jeito que chegava. Um erro de digitacao com uma palavra
-- solta ("omarcelo sim") criou um segundo prontuario para a mesma crianca, e a
-- lista de filhos passou a oferecer os dois. Agora o nome e limpo antes de
-- salvar e comparado com quem ja existe: parecido demais com um irmao ja
-- cadastrado significa a MESMA crianca, nao uma nova.
-- ADITIVO.

create extension if not exists pg_trgm;
create extension if not exists unaccent;

-- Tira palavra solta, pontuacao e espaco sobrando do que a pessoa digitou.
create or replace function public.nx_nome_limpo(p_texto text)
returns text language plpgsql immutable set search_path to 'public' as $$
declare t text; i int;
begin
  t := btrim(coalesce(p_texto,''));
  t := regexp_replace(t, '[0-9]+\s*(anos?|meses|m[eê]s)?', ' ', 'gi');       -- idade
  t := regexp_replace(t, '[.,;:!?/\\]+', ' ', 'g');
  -- palavras que nao sao nome
  -- duas passadas: palavras vizinhas ("e para o Teo") so caem na segunda,
  -- porque a primeira consome o espaco que separa uma da outra
  for i in 1..2 loop
    t := regexp_replace(t, '(^|\s)(sim|nao|n[aã]o|ok|okay|beleza|blz|isso|certo|obrigad[oa]|'
         ||'por favor|pfv|pff|e|eh|[eé]|o|a|os|as|pra|para|de|do|da|meu|minha|filho|filha|'
         ||'se chama|chama|nome|paciente|crian[cç]a|ele|ela|anos?)(\s|$)', ' ', 'gi');
    t := btrim(regexp_replace(t, '\s+', ' ', 'g'));
  end loop;
  t := btrim(regexp_replace(t, '\s+', ' ', 'g'));
  return nullif(t,'');
end; $$;

-- Esta crianca ja existe para este responsavel/telefone?
-- Compara sem acento, sem caixa, e aceita erro de digitacao.
create or replace function public.nx_paciente_parecido(
  p_clinic uuid, p_resp uuid, p_tel text, p_nome text
) returns uuid language plpgsql stable security definer set search_path to 'public' as $$
declare alvo text := lower(unaccent(btrim(coalesce(p_nome,'')))); achado uuid;
begin
  if alvo = '' then return null; end if;
  select p.id into achado
    from public.patients p
   where p.clinic_id = p_clinic
     and ( (p_resp is not null and p.responsavel_id = p_resp)
        or (p_tel is not null and regexp_replace(coalesce(p.telefone,''),'\D','','g')
                                = regexp_replace(p_tel,'\D','','g')) )
     and ( lower(unaccent(p.nome)) = alvo
        or lower(unaccent(p.nome)) like '%'||alvo||'%'
        or alvo like '%'||lower(unaccent(p.nome))||'%'
        or similarity(lower(unaccent(p.nome)), alvo) >= 0.5 )
   order by (lower(unaccent(p.nome)) = alvo) desc,
            similarity(lower(unaccent(p.nome)), alvo) desc
   limit 1;
  return achado;
end; $$;

-- Cadastro: limpa o nome e reaproveita o prontuario quando for a mesma crianca.
create or replace function public.nx_wa_conv_register(p_conv uuid)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare cl uuid; pid uuid; pnome text; rnome text; tel text; rid uuid;
begin
  select clinic_id, patient_id, paciente_nome, responsavel_nome,
         regexp_replace(coalesce(telefone,''),'\D','','g')
    into cl, pid, pnome, rnome, tel
   from public.conversations where id=p_conv;
  if cl is null then return null; end if;
  if pid is not null then return pid; end if;

  pnome := coalesce(public.nx_nome_limpo(pnome), btrim(coalesce(pnome,'')));
  if coalesce(pnome,'') = '' then return null; end if;

  if tel is not null and length(tel)>=10 then
    select id into rid from public.responsaveis
     where clinic_id=cl and regexp_replace(coalesce(telefone,''),'\D','','g')=tel limit 1;
    if rid is null then
      insert into public.responsaveis(clinic_id,nome,telefone)
        values(cl, nullif(public.nx_nome_limpo(rnome),''), tel) returning id into rid;
    elsif coalesce(rnome,'')<>'' then
      update public.responsaveis set nome=coalesce(nullif(nome,''), public.nx_nome_limpo(rnome)) where id=rid;
    end if;
  end if;

  pid := public.nx_paciente_parecido(cl, rid, tel, pnome);
  if pid is null then
    insert into public.patients(clinic_id,nome,telefone,responsavel_id,origem,access_token)
      values(cl, pnome, tel, rid, 'ia_whatsapp',
             'PT'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12)))
      returning id into pid;
  end if;
  if not exists(select 1 from public.pt_ficha where patient_id=pid) then
    insert into public.pt_ficha(patient_id,clinic_id,responsavel) values(pid,cl,nullif(rnome,''));
  end if;
  update public.conversations c set patient_id=pid,
         paciente_nome=(select p.nome from public.patients p where p.id=pid)
   where c.id=p_conv;
  return pid;
end $$;

-- Troca de crianca: mesma limpeza e mesma comparacao.
create or replace function public.nx_conv_trocar_paciente(p_conv uuid, p_nome text)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare atual text; pid uuid; cl uuid; tel text; rid uuid; v_nome text;
begin
  v_nome := coalesce(public.nx_nome_limpo(p_nome), btrim(coalesce(p_nome,'')));
  if coalesce(v_nome,'') = '' then return null; end if;

  select paciente_nome, clinic_id, regexp_replace(coalesce(telefone,''),'\D','','g')
    into atual, cl, tel from public.conversations where id=p_conv;
  select id into rid from public.responsaveis
   where clinic_id=cl and regexp_replace(coalesce(telefone,''),'\D','','g')=tel limit 1;

  -- mesma crianca de sempre (ou quase): so garante o prontuario
  pid := public.nx_paciente_parecido(cl, rid, tel, v_nome);
  if pid is not null then
    update public.conversations c set paciente_nome=(select p.nome from public.patients p where p.id=pid),
           patient_id=pid, updated_at=now() where c.id=p_conv;
    return pid;
  end if;

  update public.conversations
     set paciente_nome=v_nome, paciente_idade=null, patient_id=null, updated_at=now()
   where id=p_conv;
  return public.nx_wa_conv_register(p_conv);
end; $$;

revoke all on function public.nx_nome_limpo(text) from public, anon, authenticated;
revoke all on function public.nx_paciente_parecido(uuid,uuid,text,text) from public, anon, authenticated;
grant execute on function public.nx_nome_limpo(text) to service_role;
grant execute on function public.nx_paciente_parecido(uuid,uuid,text,text) to service_role;
