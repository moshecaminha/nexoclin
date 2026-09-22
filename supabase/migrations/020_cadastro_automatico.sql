-- 020 - Identificacao pelo telefone e cadastro automatico no prontuario.
-- O documento do cliente (secao 1 da maquina de estados) pede: reconhecer o
-- responsavel pelo telefone, mostrar os filhos, e cadastrar o paciente assim
-- que o nome da crianca aparece. nx_wa_conv_register ja existia e nao era
-- chamada por ninguem. nx_resp_by_phone exige sessao de usuario (is_member),
-- entao nao serve para a IA - aqui vai a versao interna.
-- ADITIVO.

-- 1) Filhos do responsavel, sem exigir sessao de usuario (a IA roda como service_role).
create or replace function public.nx_resp_children_bot(p_resp uuid)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', pa.id, 'nome', pa.nome,
           'nascimento', (select f.data_nascimento from public.pt_ficha f where f.patient_id=pa.id)
         ) order by pa.nome),'[]'::jsonb)
  from public.patients pa where pa.responsavel_id = p_resp;
$$;

-- 2) Quem e este telefone nesta clinica: responsavel + filhos ja cadastrados.
create or replace function public.nx_conv_quem(p_conv uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare cl uuid; tel text; rid uuid; rnome text;
begin
  select clinic_id, regexp_replace(coalesce(telefone,''),'\D','','g') into cl, tel
    from public.conversations where id=p_conv;
  if cl is null or length(coalesce(tel,'')) < 10 then return jsonb_build_object('encontrado',false); end if;
  select id, nome into rid, rnome from public.responsaveis
   where clinic_id=cl and regexp_replace(coalesce(telefone,''),'\D','','g')=tel limit 1;
  if rid is null then return jsonb_build_object('encontrado',false); end if;
  return jsonb_build_object('encontrado',true,'responsavel_id',rid,'responsavel_nome',rnome,
                            'criancas', public.nx_resp_children_bot(rid));
end; $$;

-- 3) Cadastro automatico: chamado pela propria nx_agent_aplicar assim que a IA
--    descobre o nome da crianca. Cria responsavel + paciente + ficha e amarra a
--    conversa ao prontuario. Marca quem foi cadastrado pela IA.
alter table public.patients add column if not exists origem text;

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

  if tel is not null and length(tel)>=10 then
    select id into rid from public.responsaveis
     where clinic_id=cl and regexp_replace(coalesce(telefone,''),'\D','','g')=tel limit 1;
    if rid is null then
      insert into public.responsaveis(clinic_id,nome,telefone)
        values(cl, nullif(rnome,''), tel) returning id into rid;
    elsif coalesce(rnome,'')<>'' then
      update public.responsaveis set nome=coalesce(nullif(nome,''),rnome) where id=rid;
    end if;
  end if;

  if coalesce(pnome,'')='' then return null; end if;   -- sem nome da crianca nao cadastra

  select id into pid from public.patients
   where clinic_id=cl and lower(nome)=lower(pnome) and (rid is null or responsavel_id=rid) limit 1;
  if pid is null then
    insert into public.patients(clinic_id,nome,telefone,responsavel_id,origem,access_token)
      values(cl, pnome, tel, rid, 'ia_whatsapp',
             'PT'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12)))
      returning id into pid;
  end if;
  if not exists(select 1 from public.pt_ficha where patient_id=pid) then
    insert into public.pt_ficha(patient_id,clinic_id,responsavel) values(pid,cl,nullif(rnome,''));
  end if;
  update public.conversations set patient_id=pid where id=p_conv;
  return pid;
end $$;

-- 4) A IA aplica o que coletou -> cadastra na hora.
create or replace function public.nx_agent_aplicar(
  p_conv uuid, p_risco text, p_encaminhar boolean, p_dados jsonb, p_manter_bot boolean default false
) returns void language plpgsql security definer set search_path to 'public' as $$
declare
  d jsonb; v_nome text; v_idade text; v_resp text;
  v_fila boolean := p_encaminhar and not coalesce(p_manter_bot, false);
begin
  for d in select * from jsonb_array_elements(coalesce(p_dados,'[]'::jsonb)) loop
    if coalesce(d->>'chave','') = '' or coalesce(d->>'valor','') = '' then continue; end if;
    insert into collected_data(conversation_id, chave, valor, atencao, fonte)
      values (p_conv, d->>'chave', d->>'valor', coalesce((d->>'atencao')::boolean,false), 'ia');
    if d->>'chave' = 'paciente_nome'    then v_nome  := d->>'valor'; end if;
    if d->>'chave' = 'paciente_idade'   then v_idade := d->>'valor'; end if;
    if d->>'chave' = 'responsavel_nome' then v_resp  := d->>'valor'; end if;
  end loop;

  update conversations set
    paciente_nome    = coalesce(v_nome,  paciente_nome),
    paciente_idade   = coalesce(v_idade, paciente_idade),
    responsavel_nome = coalesce(v_resp,  responsavel_nome),
    risk   = coalesce(nullif(p_risco,'')::risk_level, risk),
    status = case when v_fila and status in ('nova','em_triagem') then 'aguardando_medico'::conv_status
                  when status = 'nova' then 'em_triagem'::conv_status
                  else status end,
    attention  = case when p_risco in ('emergencia','muito_urgente') then true
                      when p_encaminhar then true
                      else attention end,
    updated_at = now()
  where id = p_conv;

  -- cadastro automatico assim que da para identificar a crianca
  if coalesce(v_nome,'') <> '' then perform public.nx_wa_conv_register(p_conv); end if;
end $$;

-- 5) O contexto da IA passa a saber quem e a familia.
create or replace function public.nx_agent_contexto(p_conv uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v jsonb; v_clinic uuid; v_ativo boolean;
begin
  select clinic_id, bot_active into v_clinic, v_ativo from conversations where id = p_conv;
  if v_clinic is null then return null; end if;
  if v_ativo is false then return jsonb_build_object('ativo', false); end if;

  select jsonb_build_object(
    'ativo', true,
    'status', c.status::text,
    'modo', public.nx_conv_modo(p_conv),
    'consentiu', c.consent_at is not null
                 or exists (select 1 from collected_data d
                             where d.conversation_id = p_conv and d.chave = 'consentimento'),
    'ia_ja_falou', exists (select 1 from messages m
                            where m.conversation_id = p_conv and m.direction = 'out'
                              and m.author = 'assistente'),
    'clinica', (select nome from clinics where id = v_clinic),
    'quem', public.nx_conv_quem(p_conv),
    'paciente_cadastrado', c.patient_id is not null,
    'paciente_nome', c.paciente_nome,
    'paciente_idade', c.paciente_idade,
    'responsavel_nome', c.responsavel_nome,
    'meses', public.nx_idade_meses(c.paciente_idade),
    'risco', c.risk::text,
    'coletado', coalesce((
      select jsonb_object_agg(d.chave, d.valor)
      from collected_data d where d.conversation_id = p_conv), '{}'::jsonb),
    'historico', coalesce((
      select jsonb_agg(jsonb_build_object('direction', m.direction::text, 'body', m.body)
                       order by m.created_at)
      from (select * from messages where conversation_id = p_conv
            and body is not null and body <> ''
            order by created_at desc limit 24) m), '[]'::jsonb)
  ) into v from conversations c where c.id = p_conv;
  return v;
end $$;

revoke all on function public.nx_resp_children_bot(uuid) from public, anon, authenticated;
revoke all on function public.nx_conv_quem(uuid) from public, anon, authenticated;
grant execute on function public.nx_resp_children_bot(uuid) to service_role;
grant execute on function public.nx_conv_quem(uuid) to service_role;
