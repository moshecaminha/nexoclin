-- =====================================================================
-- A IA so e desligada por um humano.
--
-- Regra do produto (14/09): o robo nao se desliga sozinho. Quem para a IA
-- e uma pessoa da equipe, pausando no cockpit (nx_conv_set_bot) ou
-- assumindo o atendimento (nx_conv_advance -> em_atendimento).
--
-- Ate aqui ele se calava sozinho de dois jeitos: gravando bot_active=false
-- ao encaminhar (clinico, emergencia, pedido de atendente) e se calando
-- pelos status que ele mesmo coloca (aguardando_medico ao encaminhar,
-- agendada ao marcar consulta). E o status em_atendimento calava por cima
-- do botao: a equipe clicava "retomar IA" e nada acontecia.
--
-- Conversa finalizada/resolvida nao precisa de trava: mensagem nova abre
-- outra conversa (nx_wa_ingest).
-- =====================================================================


-- 1) Encaminhar move a fila, nunca o bot.
--    p_manter_bot mantem o nome por compatibilidade com o wa-agent v4:
--    hoje significa "administrativo", que so pede atencao e nao mexe na fila.
create or replace function public.nx_agent_aplicar(
  p_conv uuid, p_risco text, p_encaminhar boolean, p_dados jsonb,
  p_manter_bot boolean default false)
returns void language plpgsql security definer set search_path to 'public' as $$
declare
  d jsonb; v_nome text; v_idade text;
  v_fila boolean := p_encaminhar and not coalesce(p_manter_bot, false);
begin
  for d in select * from jsonb_array_elements(coalesce(p_dados,'[]'::jsonb)) loop
    if coalesce(d->>'chave','') = '' or coalesce(d->>'valor','') = '' then continue; end if;
    insert into collected_data(conversation_id, chave, valor, atencao, fonte)
      values (p_conv, d->>'chave', d->>'valor', coalesce((d->>'atencao')::boolean,false), 'ia');
    if d->>'chave' = 'paciente_nome'  then v_nome  := d->>'valor'; end if;
    if d->>'chave' = 'paciente_idade' then v_idade := d->>'valor'; end if;
  end loop;

  update conversations set
    paciente_nome  = coalesce(v_nome,  paciente_nome),
    paciente_idade = coalesce(v_idade, paciente_idade),
    risk   = coalesce(nullif(p_risco,'')::risk_level, risk),
    -- so avanca quem ainda esta na triagem: nao tira do atendimento quem um humano assumiu
    status = case when v_fila and status in ('nova','em_triagem') then 'aguardando_medico'::conv_status
                  when status = 'nova' then 'em_triagem'::conv_status
                  else status end,
    attention  = case when p_risco in ('emergencia','muito_urgente') then true
                      when p_encaminhar then true
                      else attention end,
    updated_at = now()
  where id = p_conv;
end $$;


-- 2) O agente so cala quando um humano desligou. Passa a informar o status,
--    para a IA saber que ja encaminhou e nao recomecar a triagem.
create or replace function public.nx_agent_contexto(p_conv uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v jsonb; v_clinic uuid; v_ativo boolean;
begin
  select clinic_id, bot_active into v_clinic, v_ativo from conversations where id = p_conv;
  if v_clinic is null then return null; end if;

  -- humano pausou ou assumiu
  if v_ativo is false then return jsonb_build_object('ativo', false); end if;

  select jsonb_build_object(
    'ativo', true,
    'status', c.status::text,
    'clinica', (select nome from clinics where id = v_clinic),
    'paciente_nome', c.paciente_nome,
    'paciente_idade', c.paciente_idade,
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


-- 3) Aviso de foto/audio recebido: mesma regra.
create or replace function public.nx_wa_midia_ack(p_conv uuid, p_tipo text)
returns text language plpgsql security definer set search_path to 'public' as $$
declare v_state text; v_active boolean; v_suj text; v_artigo text;
begin
  select bot_state, bot_active into v_state, v_active from conversations where id = p_conv;
  if v_active is false then return null; end if;

  v_artigo := case p_tipo
    when 'image' then 'a foto' when 'video' then 'o vídeo'
    when 'audio' then 'o áudio' when 'document' then 'o arquivo'
    else 'o anexo' end;
  v_suj := coalesce(public.nx_wa_pac(p_conv)->>'sujeito','você');

  return case
    when v_state is null then
      '📎 Recebi '||v_artigo||'! Já anexei ao atendimento.'||chr(10)||chr(10)||
      'Me conta em poucas palavras o que está acontecendo?'
    when v_state in ('exame_qual','doc_qual','receita_qual') then
      '📎 Recebi '||v_artigo||'! Já anexei ao atendimento e a equipe vai avaliar.'
    when v_state = 'sintoma' then
      '📎 Recebi '||v_artigo||'! Já anexei.'||chr(10)||chr(10)||
      'Pode me dizer também, em palavras, qual é o principal sintoma de '||v_suj||'?'
    else
      '📎 Recebi '||v_artigo||'! Já anexei ao atendimento.'||chr(10)||chr(10)||
      'Pode continuar respondendo por aqui.'
  end;
end $$;


-- 4) Rede de recuperacao: reprocessa toda conversa com a IA ligada, e nao so
--    as que estao em triagem. Senao uma mensagem apos encaminhar ou agendar
--    que o isolate perdeu fica sem resposta.
create or replace function public.nx_wa_bot_pendentes()
returns table(conversation_id uuid, clinic_id uuid, telefone text, texto text)
language sql security definer set search_path to 'public' as $$
  with ultima as (
    select distinct on (m.conversation_id)
           m.conversation_id, m.direction, m.body, m.created_at
    from messages m
    order by m.conversation_id, m.created_at desc
  )
  select c.id, c.clinic_id, c.telefone, u.body
  from conversations c
  join ultima u on u.conversation_id = c.id
  where c.bot_active is true
    and c.status not in ('finalizada','resolvida')
    and u.direction = 'in'
    and coalesce(u.body,'') <> ''
    -- espera o caminho normal ter chance antes de reprocessar
    and u.created_at < now() - interval '45 seconds'
    -- nao ressuscita conversa velha
    and u.created_at > now() - interval '2 hours'
    and c.clinic_id is not null
    and exists (select 1 from clinic_whatsapp w
                 where w.clinic_id = c.clinic_id and w.status = 'conectado')
  order by u.created_at
  limit 20;
$$;

revoke all on function public.nx_wa_bot_pendentes() from public, anon, authenticated;
grant execute on function public.nx_wa_bot_pendentes() to service_role;


-- 5) Assumir o atendimento e a acao humana que desliga a IA. Grava no
--    bot_active para o botao do cockpit refletir o que acontece, e para a
--    equipe poder religar a IA mesmo com o atendimento assumido.
create or replace function public.nx_conv_advance(
  p_conv uuid, p_status conv_status, p_risk risk_level, p_assign_me boolean)
returns void language plpgsql security definer set search_path to 'public' as $$
declare cl uuid;
begin
  cl := public.nx_conv_clinic(p_conv);
  if cl is null or not (public.is_member(cl) or public.is_platform_admin()) then raise exception 'sem permissão'; end if;
  update public.conversations set
    status=coalesce(p_status,status),
    risk=coalesce(p_risk,risk),
    assigned_to=case when coalesce(p_assign_me,false) then auth.uid() else assigned_to end,
    bot_active=case when p_status='em_atendimento' then false else bot_active end,
    started_at=case when p_status='em_atendimento' and started_at is null then now() else started_at end,
    ended_at=case when p_status in ('finalizada','resolvida') then now() else ended_at end,
    updated_at=now()
  where id=p_conv;
end $$;


-- 6) Quem ja foi assumido por um humano continua calado. Antes o status
--    em_atendimento calava sozinho; agora quem cala e o bot_active.
update public.conversations set bot_active = false
 where status = 'em_atendimento' and bot_active is true;
