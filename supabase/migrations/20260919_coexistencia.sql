-- Coexistencia (WhatsApp Business app + Cloud API no mesmo numero).
-- ADITIVO: so acrescenta colunas e funcoes. Nada existente e apagado.

-- 1) Estado da conexao de cada clinica
alter table public.clinic_whatsapp
  add column if not exists coexistencia      boolean not null default false,
  add column if not exists is_on_biz_app     boolean,
  add column if not exists sync_contatos_id  text,          -- request_id da Meta (contatos)
  add column if not exists sync_historico_id text,          -- request_id da Meta (historico)
  add column if not exists sync_em           timestamptz,   -- a Meta da 24h apos conectar
  add column if not exists conexao_erro      text,          -- motivo legivel quando algo falha
  add column if not exists verificado_em     timestamptz;   -- ultima checagem da wa-sweep


-- 2) Eco: mensagem que a equipe mandou pelo app do celular.
--    Grava como saida da equipe e PAUSA a IA: qualquer intervencao humana
--    tira a IA da conversa.
create or replace function public.nx_wa_eco(
  p_phone_number_id text,
  p_to              text,
  p_type            text,
  p_body            text,
  p_wamid           text,
  p_ts              bigint default null,
  p_media_id        text   default null
) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_clinic uuid; v_conv uuid; v_type msg_type;
begin
  select clinic_id into v_clinic
    from clinic_whatsapp where phone_number_id = p_phone_number_id;
  if v_clinic is null then
    insert into webhook_events(event_type, origem, payload)
      values ('whatsapp_eco_sem_clinica','meta_cloud',
              jsonb_build_object('phone_number_id',p_phone_number_id,'to',p_to,'wamid',p_wamid));
    return null;
  end if;

  begin v_type := p_type::msg_type; exception when others then v_type := 'unsupported'; end;

  select id into v_conv
    from conversations
   where clinic_id = v_clinic
     and nx_fone_key(telefone) = nx_fone_key(p_to)
     and status not in ('finalizada','resolvida')
   order by created_at desc limit 1;

  if v_conv is null then
    -- a equipe puxou conversa pelo celular: ja nasce com a IA pausada
    insert into conversations(clinic_id, telefone, canal, status, stage, bot_active)
      values (v_clinic, p_to, 'WhatsApp', 'nova', 'Aguardando atendente', false)
      returning id into v_conv;
  end if;

  insert into messages(conversation_id, direction, type, body, author, wa_message_id, wa_media_id, wa_status, created_at)
    values (v_conv, 'out', v_type, p_body, 'equipe', p_wamid, p_media_id, 'sent',
            coalesce(to_timestamp(nullif(p_ts,0)), now()))
    on conflict (wa_message_id) where wa_message_id is not null do nothing;

  update conversations set bot_active = false, updated_at = now() where id = v_conv;

  return jsonb_build_object('conversation_id', v_conv, 'clinic_id', v_clinic);
end $$;

revoke all on function public.nx_wa_eco(text,text,text,text,text,bigint,text) from public, anon, authenticated;
grant execute on function public.nx_wa_eco(text,text,text,text,text,bigint,text) to service_role;


-- 3) "Assumir" tambem pausa a IA. Mesma funcao da 017, com uma mudanca:
--    bot_active vira false quando o status vai para em_atendimento (como
--    antes) OU quando alguem assume o atendimento (p_assign_me).
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
    bot_active=case when p_status='em_atendimento' or coalesce(p_assign_me,false) then false else bot_active end,
    started_at=case when p_status='em_atendimento' and started_at is null then now() else started_at end,
    ended_at=case when p_status in ('finalizada','resolvida') then now() else ended_at end,
    updated_at=now()
  where id=p_conv;
end $$;
