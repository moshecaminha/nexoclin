-- 022 - Um prontuario por crianca, mesmo com a mesma mae falando.
-- A conversa aponta para UM paciente. Quando a mae troca de filho no meio
-- ("e o irmao dele tambem esta com tosse"), tudo ficava no prontuario do
-- primeiro. Agora a troca de nome repontua a conversa para a outra crianca,
-- e cada dado coletado fica marcado com o paciente a que pertence.
-- ADITIVO.

alter table public.collected_data
  add column if not exists patient_id uuid references public.patients(id);

create index if not exists collected_data_patient_idx on public.collected_data(patient_id);

-- Troca a crianca da conversa (cria/encontra o prontuario dela).
create or replace function public.nx_conv_trocar_paciente(p_conv uuid, p_nome text)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare atual text; pid uuid;
begin
  select paciente_nome into atual from public.conversations where id=p_conv;
  if coalesce(p_nome,'') = '' then return null; end if;
  if lower(coalesce(atual,'')) = lower(p_nome) then
    return public.nx_wa_conv_register(p_conv);
  end if;
  -- crianca diferente: solta o prontuario anterior e cadastra/acha o desta
  update public.conversations
     set paciente_nome=p_nome, paciente_idade=null, patient_id=null, updated_at=now()
   where id=p_conv;
  pid := public.nx_wa_conv_register(p_conv);
  return pid;
end; $$;

-- A IA aplica o que coletou: cada dado nasce amarrado ao paciente certo.
create or replace function public.nx_agent_aplicar(
  p_conv uuid, p_risco text, p_encaminhar boolean, p_dados jsonb, p_manter_bot boolean default false
) returns void language plpgsql security definer set search_path to 'public' as $$
declare
  d jsonb; v_nome text; v_idade text; v_resp text; v_pid uuid;
  v_fila boolean := p_encaminhar and not coalesce(p_manter_bot, false);
  v_ids uuid[];
begin
  for d in select * from jsonb_array_elements(coalesce(p_dados,'[]'::jsonb)) loop
    if coalesce(d->>'chave','') = '' or coalesce(d->>'valor','') = '' then continue; end if;
    if d->>'chave' = 'paciente_nome'    then v_nome  := d->>'valor'; end if;
    if d->>'chave' = 'paciente_idade'   then v_idade := d->>'valor'; end if;
    if d->>'chave' = 'responsavel_nome' then v_resp  := d->>'valor'; end if;
  end loop;

  update conversations set
    responsavel_nome = coalesce(v_resp, responsavel_nome),
    risk   = coalesce(nullif(p_risco,'')::risk_level, risk),
    status = case when v_fila and status in ('nova','em_triagem') then 'aguardando_medico'::conv_status
                  when status = 'nova' then 'em_triagem'::conv_status
                  else status end,
    attention  = case when p_risco in ('emergencia','muito_urgente') then true
                      when p_encaminhar then true
                      else attention end,
    updated_at = now()
  where id = p_conv;

  -- crianca de quem se fala agora (troca de irmao repontua a conversa)
  if coalesce(v_nome,'') <> '' then
    v_pid := public.nx_conv_trocar_paciente(p_conv, v_nome);
  else
    select patient_id into v_pid from conversations where id=p_conv;
  end if;

  if coalesce(v_idade,'') <> '' then
    update conversations set paciente_idade=v_idade where id=p_conv;
  end if;

  -- agora sim grava os dados, ja marcados com o paciente
  for d in select * from jsonb_array_elements(coalesce(p_dados,'[]'::jsonb)) loop
    if coalesce(d->>'chave','') = '' or coalesce(d->>'valor','') = '' then continue; end if;
    insert into collected_data(conversation_id, patient_id, chave, valor, atencao, fonte)
      values (p_conv, v_pid, d->>'chave', d->>'valor', coalesce((d->>'atencao')::boolean,false), 'ia');
  end loop;

  -- dados antigos da conversa que ainda nao tinham dono ficam com o primeiro paciente
  if v_pid is not null then
    update collected_data set patient_id=v_pid
     where conversation_id=p_conv and patient_id is null;
  end if;
end $$;

-- O que a IA ja coletou DESTA crianca (nao mistura irmaos no contexto).
create or replace function public.nx_agent_contexto(p_conv uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v jsonb; v_clinic uuid; v_ativo boolean; v_pid uuid;
begin
  select clinic_id, bot_active, patient_id into v_clinic, v_ativo, v_pid
    from conversations where id = p_conv;
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
      from collected_data d
      where d.conversation_id = p_conv
        and (v_pid is null or d.patient_id is null or d.patient_id = v_pid)), '{}'::jsonb),
    'historico', coalesce((
      select jsonb_agg(jsonb_build_object('direction', m.direction::text, 'body', m.body)
                       order by m.created_at)
      from (select * from messages where conversation_id = p_conv
            and body is not null and body <> ''
            order by created_at desc limit 24) m), '[]'::jsonb)
  ) into v from conversations c where c.id = p_conv;
  return v;
end $$;

revoke all on function public.nx_conv_trocar_paciente(uuid,text) from public, anon, authenticated;
grant execute on function public.nx_conv_trocar_paciente(uuid,text) to service_role;
