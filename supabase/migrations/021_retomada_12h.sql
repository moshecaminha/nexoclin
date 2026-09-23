-- 021 - Retomada de conversa parada (12h).
-- A nx_wa_ingest reaproveitava qualquer conversa que nao estivesse finalizada,
-- de qualquer data: um "oi" 9 dias depois continuava a triagem antiga, sem
-- consentimento novo e com os sintomas do caso velho. Agora, parada ha mais de
-- 12h, a IA pergunta se e para continuar o assunto anterior ou abrir outro.
-- ADITIVO.

alter table public.conversations
  add column if not exists retomada_em timestamptz;

-- Resumo curto do assunto anterior, para a pergunta de retomada.
create or replace function public.nx_conv_resumo(p_conv uuid)
returns text language plpgsql stable security definer set search_path to 'public' as $$
declare nm text; mot text; quando timestamptz;
begin
  select c.paciente_nome,
         (select d.valor from collected_data d
           where d.conversation_id=c.id and d.chave in ('motivo','sintoma_principal')
           order by d.created_at desc limit 1),
         (select max(m.created_at) from messages m where m.conversation_id=c.id and m.direction='out')
    into nm, mot, quando
   from conversations c where c.id=p_conv;
  return trim(both ' ' from
      coalesce(nullif(nm,''),'o atendimento')
      || coalesce(' ('||nullif(mot,'')||')','')
      || coalesce(', em '||to_char(quando at time zone 'America/Sao_Paulo','DD/MM'),''));
end; $$;

-- Horas desde a ultima mensagem da conversa.
create or replace function public.nx_conv_parada_horas(p_conv uuid)
returns numeric language sql stable security definer set search_path to 'public' as $$
  select extract(epoch from (now() - max(created_at)))/3600 from public.messages where conversation_id=p_conv;
$$;

-- Fecha o assunto anterior e comeca outro, mantendo o historico do antigo.
-- Caso urgente sem retorno do medico NAO some da fila: continua como esta e
-- so abre a conversa nova ao lado.
create or replace function public.nx_conv_nova_do_telefone(p_conv uuid)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare cl uuid; tel text; nome text; nova uuid; risco text; st text;
begin
  select clinic_id, telefone, responsavel_nome, risk::text, status::text
    into cl, tel, nome, risco, st from public.conversations where id=p_conv;
  if cl is null then return null; end if;

  if st in ('nova','em_triagem') or risco in ('nao_urgente','pouco_urgente') then
    update public.conversations
       set status='finalizada', desfecho=coalesce(desfecho,'sem_retorno'),
           bot_state=null, ended_at=now(), updated_at=now()
     where id=p_conv;
  else
    -- urgente aguardando medico: fica na fila, so sai do bot
    update public.conversations set bot_state=null, updated_at=now() where id=p_conv;
  end if;

  insert into public.conversations(clinic_id, telefone, responsavel_nome, canal, status, stage, bot_active)
    values (cl, tel, nome, 'WhatsApp', 'nova', 'Aguardando atendente', true)
    returning id into nova;
  return nova;
end; $$;

-- nx_wa_ingest: marca para perguntar quando a conversa reaberta esta parada ha
-- mais de 12h e ja tem conversa de verdade.
create or replace function public.nx_wa_ingest(
  p_phone_number_id text, p_from text, p_nome text, p_type text, p_body text,
  p_wamid text, p_ts bigint default null, p_payload jsonb default null, p_media_id text default null
) returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_clinic uuid; v_conv uuid; v_type msg_type; v_horas numeric; v_tem boolean; v_st text;
begin
  select clinic_id into v_clinic from clinic_whatsapp where phone_number_id = p_phone_number_id;
  if v_clinic is null then
    insert into webhook_events(event_type, origem, payload)
      values ('whatsapp_sem_clinica','meta_cloud',
              jsonb_build_object('phone_number_id',p_phone_number_id,'msg',p_payload));
    return null;
  end if;

  begin v_type := p_type::msg_type; exception when others then v_type := 'unsupported'; end;

  select id, bot_state into v_conv, v_st
    from conversations
   where clinic_id = v_clinic
     and nx_fone_key(telefone) = nx_fone_key(p_from)
     and status not in ('finalizada','resolvida')
   order by created_at desc limit 1;

  if v_conv is null then
    insert into conversations(clinic_id, telefone, responsavel_nome, canal, status, stage)
      values (v_clinic, p_from, nullif(p_nome,''), 'WhatsApp', 'nova', 'Aguardando atendente')
      returning id into v_conv;
  else
    v_horas := public.nx_conv_parada_horas(v_conv);
    select exists(select 1 from messages m where m.conversation_id=v_conv and m.direction='out') into v_tem;
    if coalesce(v_horas,0) >= 12 and v_tem and coalesce(v_st,'') not in ('retomar','retomar_resp') then
      update conversations set bot_state='retomar', retomada_em=now() where id=v_conv;
    end if;
    update conversations
       set responsavel_nome = coalesce(responsavel_nome, nullif(p_nome,'')), updated_at = now()
     where id = v_conv;
  end if;

  insert into messages(conversation_id, direction, type, body, author, wa_message_id, wa_media_id, created_at)
    values (v_conv, 'in', v_type, p_body, coalesce(nullif(p_nome,''),'paciente'), p_wamid, p_media_id,
            coalesce(to_timestamp(nullif(p_ts,0)), now()))
    on conflict (wa_message_id) where wa_message_id is not null do nothing;

  return jsonb_build_object('conversation_id', v_conv, 'clinic_id', v_clinic);
end $$;

-- Passo da retomada: pergunta e interpreta a resposta.
-- Devolve {texto, conversa} - conversa muda quando a pessoa escolhe assunto novo.
create or replace function public.nx_conv_retomar(p_conv uuid, p_text text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare st text; nova uuid; t text := lower(coalesce(p_text,''));
begin
  select bot_state into st from public.conversations where id=p_conv;

  if st = 'retomar' then
    update public.conversations set bot_state='retomar_resp' where id=p_conv;
    return jsonb_build_object('conversa', p_conv, 'texto',
      'Oi! Da ultima vez falamos sobre *'||public.nx_conv_resumo(p_conv)||'*.'||chr(10)||chr(10)||
      'Quer continuar esse atendimento ou e um assunto novo?'||chr(10)||
      '1) Continuar o anterior'||chr(10)||'2) Assunto novo');
  end if;

  if coalesce(st,'') <> 'retomar_resp' then return null; end if;

  if t ~ '(^|\D)2(\D|$)|assunto novo|outro assunto|novo atendimento|outra coisa|nova consulta|outro filho|outra filha|outra crian' then
    nova := public.nx_conv_nova_do_telefone(p_conv);
    return jsonb_build_object('conversa', nova, 'texto',
      'Certo, vamos comecar um atendimento novo. Me conta o que houve?');
  end if;

  if t ~ '(^|\D)1(\D|$)|continuar|mesmo assunto|isso mesmo|sim\b|anterior' then
    update public.conversations set bot_state=null where id=p_conv;
    return jsonb_build_object('conversa', p_conv, 'texto',
      'Perfeito, seguimos de onde paramos. Como esta a situacao agora?');
  end if;

  -- resposta que nao e 1 nem 2: trata como assunto novo so se nao lembrar nada
  return jsonb_build_object('conversa', p_conv, 'texto',
    'So para eu nao me confundir: responda *1* para continuar o atendimento anterior ou *2* para um assunto novo.');
end; $$;

revoke all on function public.nx_conv_resumo(uuid) from public, anon, authenticated;
revoke all on function public.nx_conv_retomar(uuid,text) from public, anon, authenticated;
revoke all on function public.nx_conv_nova_do_telefone(uuid) from public, anon, authenticated;
grant execute on function public.nx_conv_resumo(uuid) to service_role;
grant execute on function public.nx_conv_retomar(uuid,text) to service_role;
grant execute on function public.nx_conv_nova_do_telefone(uuid) to service_role;
