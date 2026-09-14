-- =====================================================================
-- Agenda de verdade, transferencia que nao emudece e funcoes de servico
-- fechadas.
--
-- Contexto (14/09): o medico clicou "presencial", a conversa foi para o
-- passo de agendamento sem medico definido, a IA prometeu ao pai que o
-- horario "esta sendo reservado" (nenhuma consulta foi criada) e se
-- transferiu para a equipe. A mensagem seguinte, com febre e dor de
-- cabeca, ficou sem ninguem: bot calado, status aguardando_medico.
-- =====================================================================


-- 1) Transferencia administrativa (valor, confirmar horario) nao cala a IA.
--    So a transferencia clinica, o pedido de atendente e a emergencia
--    passam a conversa para a equipe e desligam o bot. Na administrativa a
--    conversa fica marcada com atencao e a triagem segue respondendo.
--    O parametro novo tem default: o wa-agent antigo, que chama com quatro
--    argumentos, continua funcionando durante a troca.
drop function if exists public.nx_agent_aplicar(uuid, text, boolean, jsonb);

create or replace function public.nx_agent_aplicar(
  p_conv uuid, p_risco text, p_encaminhar boolean, p_dados jsonb,
  p_manter_bot boolean default false)
returns void language plpgsql security definer set search_path to 'public' as $$
declare
  d jsonb; v_nome text; v_idade text;
  v_calar boolean := p_encaminhar and not coalesce(p_manter_bot, false);
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
    status = case when v_calar then 'aguardando_medico'::conv_status
                  when status = 'nova' then 'em_triagem'::conv_status else status end,
    bot_active = case when v_calar then false else bot_active end,
    attention  = case when p_risco in ('emergencia','muito_urgente') then true
                      when p_encaminhar and not v_calar then true
                      else attention end,
    updated_at = now()
  where id = p_conv;
end $$;


-- 2) "Presencial"/"telemedicina" no painel: a consulta e com o medico que
--    avaliou. Sem isto a conversa entra no agendamento sem professional_id
--    quando a clinica tem mais de um medico, e a agenda nao tem de quem
--    buscar horario.
create or replace function public.nx_conv_route(p_conv uuid, p_modalidade text)
returns text language plpgsql security definer set search_path to 'public' as $$
declare
  cl uuid; v_prof uuid;
  modal text := case when p_modalidade='telemedicina' then 'telemedicina' else 'presencial' end;
begin
  cl := public.nx_conv_clinic(p_conv);
  if cl is null or not public.nx_can_doc(cl) then raise exception 'sem permissão'; end if;
  if public.has_clinic_role(cl, array['medico']::public.user_role[]) then
    v_prof := auth.uid();
  end if;
  update public.conversations
    set bot_ctx = jsonb_build_object('modalidade', modal), bot_state='ag_dia', bot_active=true,
        status='em_triagem', professional_id = coalesce(professional_id, v_prof)
    where id=p_conv;
  insert into public.collected_data(conversation_id,chave,valor,atencao,fonte)
    values(p_conv,'encaminhamento', modal, false, 'medico');
  if modal='telemedicina' then
    return 'O médico avaliou o seu caso e indica um atendimento por *telemedicina* (vídeo). Vamos agendar? Me diga para qual dia (ex.: amanhã, 15/09). Obs.: a teleconsulta é pré-paga — assim que você escolher o horário, eu te envio o link de pagamento e, após confirmado, o link da sala de vídeo.';
  else
    return 'O médico avaliou o seu caso e indica um atendimento *presencial*. Vamos agendar? Me diga para qual dia (ex.: amanhã, 15/09) que eu te mostro os horários livres.';
  end if;
end $$;


-- 3) Funcoes de servico so para service_role. Estavam liberadas para
--    qualquer usuario logado e nenhuma confere a clinica: um usuario de
--    outro consultorio lia o historico de qualquer conversa
--    (nx_agent_contexto), gravava dados e desligava o bot dela
--    (nx_agent_aplicar) e criava consulta na agenda alheia (nx_book_step).
--    O painel nao chama nenhuma delas; so o wa-agent e o orquestrador.
revoke all on function public.nx_agent_aplicar(uuid, text, boolean, jsonb, boolean) from public, anon, authenticated;
revoke all on function public.nx_agent_contexto(uuid)   from public, anon, authenticated;
revoke all on function public.nx_book_step(uuid, text)  from public, anon, authenticated;
revoke all on function public.nx_book_start(uuid)       from public, anon, authenticated;
revoke all on function public.nx_ai_answer(uuid, text)  from public, anon, authenticated;

grant execute on function public.nx_agent_aplicar(uuid, text, boolean, jsonb, boolean) to service_role;
grant execute on function public.nx_agent_contexto(uuid)   to service_role;
grant execute on function public.nx_book_step(uuid, text)  to service_role;
grant execute on function public.nx_book_start(uuid)       to service_role;
grant execute on function public.nx_ai_answer(uuid, text)  to service_role;
