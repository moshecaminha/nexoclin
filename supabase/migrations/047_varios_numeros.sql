-- Mais de um WhatsApp por clinica (ex.: o celular do medico e o numero de
-- agendamento da secretaria). O numero que ja existia continua em
-- clinic_whatsapp, como principal: nada do que le de la muda. Os adicionais
-- ficam em clinic_whatsapp_extra. Cada conversa guarda por qual numero entrou
-- (canal_phone_id) e a resposta sai pelo mesmo numero.

create table if not exists public.clinic_whatsapp_extra (
  id               uuid primary key default gen_random_uuid(),
  clinic_id        uuid not null references public.clinics(id) on delete cascade,
  rotulo           text,                       -- "Agendamento", "Secretaria"...
  provider         text not null default 'zernio',
  phone_number_id  text not null unique,       -- "zernio:<accountId>"
  access_token     text,
  api_url          text,
  waba_id          text,
  display_number   text,
  coexistencia     boolean not null default false,
  is_on_biz_app    boolean,
  status           text not null default 'conectado',
  conexao_erro     text,
  verificado_em    timestamptz,
  connected_at     timestamptz default now(),
  numeros_permitidos text[],
  created_at       timestamptz not null default now()
);
alter table public.clinic_whatsapp_extra enable row level security;

-- Todos os numeros, principal e adicionais, num lugar so.
create or replace view public.wa_numeros as
  select clinic_id, null::uuid as extra_id, true as principal, 'Principal'::text as rotulo, provider,
         phone_number_id, access_token, api_url, display_number, coalesce(coexistencia,false) coexistencia,
         status, numeros_permitidos
    from public.clinic_whatsapp where phone_number_id is not null
  union all
  select clinic_id, id, false, coalesce(rotulo,'Adicional'), provider,
         phone_number_id, access_token, api_url, display_number, coexistencia,
         status, numeros_permitidos
    from public.clinic_whatsapp_extra;
revoke all on public.wa_numeros from anon, authenticated;

alter table public.conversations add column if not exists canal_phone_id text;

-- Numero da conversa: o que ela guardou, ou o principal da clinica.
create or replace function public.nx_conv_canal(p_conv uuid)
returns text language sql stable security definer set search_path to 'public' as $$
  select coalesce(c.canal_phone_id, w.phone_number_id)
    from conversations c left join clinic_whatsapp w on w.clinic_id = c.clinic_id
   where c.id = p_conv;
$$;

-- Estado do cadastro pela Zernio: marca quando e um numero adicional.
alter table public.wa_zernio_estado
  add column if not exists adicional boolean not null default false,
  add column if not exists rotulo text;


-- Entrada de mensagem: acha a clinica por qualquer numero dela e a conversa
-- daquele numero.
create or replace function public.nx_wa_ingest(p_phone_number_id text, p_from text, p_nome text, p_type text,
  p_body text, p_wamid text, p_ts bigint DEFAULT NULL::bigint, p_payload jsonb DEFAULT NULL::jsonb,
  p_media_id text DEFAULT NULL::text)
 returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_clinic uuid; v_conv uuid; v_type msg_type; v_horas numeric; v_tem boolean; v_st text; v_princ text;
begin
  select clinic_id into v_clinic from wa_numeros where phone_number_id = p_phone_number_id limit 1;
  if v_clinic is null then
    insert into webhook_events(event_type, origem, payload)
      values ('whatsapp_sem_clinica','meta_cloud',
              jsonb_build_object('phone_number_id',p_phone_number_id,'msg',p_payload));
    return null;
  end if;
  select phone_number_id into v_princ from clinic_whatsapp where clinic_id = v_clinic;

  begin v_type := p_type::msg_type; exception when others then v_type := 'unsupported'; end;

  select id, bot_state into v_conv, v_st
    from conversations
   where clinic_id = v_clinic
     and nx_fone_key(telefone) = nx_fone_key(p_from)
     and coalesce(canal_phone_id, v_princ) = p_phone_number_id
     and status not in ('finalizada','resolvida')
   order by created_at desc limit 1;

  if v_conv is null then
    insert into conversations(clinic_id, telefone, responsavel_nome, canal, status, stage, canal_phone_id)
      values (v_clinic, p_from, nullif(p_nome,''), 'WhatsApp', 'nova', 'Aguardando atendente', p_phone_number_id)
      returning id into v_conv;
  else
    v_horas := public.nx_conv_parada_horas(v_conv);
    select exists(select 1 from messages m where m.conversation_id=v_conv and m.direction='out') into v_tem;
    if coalesce(v_horas,0) >= 12 and v_tem and coalesce(v_st,'') not in ('retomar','retomar_resp') then
      update conversations set bot_state='retomar', retomada_em=now() where id=v_conv;
    end if;
    update conversations
       set responsavel_nome = coalesce(responsavel_nome, nullif(p_nome,'')),
           canal_phone_id = coalesce(canal_phone_id, p_phone_number_id), updated_at = now()
     where id = v_conv;
  end if;

  insert into messages(conversation_id, direction, type, body, author, wa_message_id, wa_media_id, created_at)
    values (v_conv, 'in', v_type, p_body, coalesce(nullif(p_nome,''),'paciente'), p_wamid, p_media_id,
            coalesce(to_timestamp(nullif(p_ts,0)), now()))
    on conflict (wa_message_id) where wa_message_id is not null do nothing;

  return jsonb_build_object('conversation_id', v_conv, 'clinic_id', v_clinic);
end $function$;


-- Mensagem que a equipe mandou pelo celular (coexistencia), no numero certo.
create or replace function public.nx_wa_eco(p_phone_number_id text, p_to text, p_type text, p_body text,
  p_wamid text, p_ts bigint default null, p_media_id text default null)
 returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_clinic uuid; v_conv uuid; v_type msg_type; v_princ text;
begin
  select clinic_id into v_clinic from wa_numeros where phone_number_id = p_phone_number_id limit 1;
  if v_clinic is null then
    insert into webhook_events(event_type, origem, payload)
      values ('whatsapp_eco_sem_clinica','meta_cloud',
              jsonb_build_object('phone_number_id',p_phone_number_id,'to',p_to,'wamid',p_wamid));
    return null;
  end if;
  select phone_number_id into v_princ from clinic_whatsapp where clinic_id = v_clinic;

  begin v_type := p_type::msg_type; exception when others then v_type := 'unsupported'; end;

  select id into v_conv
    from conversations
   where clinic_id = v_clinic
     and nx_fone_key(telefone) = nx_fone_key(p_to)
     and coalesce(canal_phone_id, v_princ) = p_phone_number_id
     and status not in ('finalizada','resolvida')
   order by created_at desc limit 1;

  if v_conv is null then
    insert into conversations(clinic_id, telefone, canal, status, stage, bot_active, canal_phone_id)
      values (v_clinic, p_to, 'WhatsApp', 'nova', 'Aguardando atendente', false, p_phone_number_id)
      returning id into v_conv;
  end if;

  insert into messages(conversation_id, direction, type, body, author, wa_message_id, wa_media_id, wa_status, created_at)
    values (v_conv, 'out', v_type, p_body, 'equipe', p_wamid, p_media_id, 'sent',
            coalesce(to_timestamp(nullif(p_ts,0)), now()))
    on conflict (wa_message_id) where wa_message_id is not null do nothing;

  update conversations set bot_active = false, updated_at = now() where id = v_conv;
  return jsonb_build_object('conversation_id', v_conv, 'clinic_id', v_clinic);
end $$;


-- Comandos #ia/#off e o #encerraratendimento: conversa daquele numero.
create or replace function public.nx_wa_conv_aberta(p_phone_number_id text, p_to text)
returns uuid language sql stable security definer set search_path to 'public' as $$
  select c.id from conversations c
    join wa_numeros n on n.clinic_id = c.clinic_id and n.phone_number_id = p_phone_number_id
   where nx_fone_key(c.telefone) = nx_fone_key(p_to)
     and coalesce(c.canal_phone_id, (select w.phone_number_id from clinic_whatsapp w where w.clinic_id = c.clinic_id))
         = p_phone_number_id
     and c.status not in ('finalizada','resolvida')
   order by c.created_at desc limit 1;
$$;

create or replace function public.nx_wa_comando_ia(p_phone_number_id text, p_to text, p_modo text)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare v_clinic uuid; v_conv uuid; v_paciente boolean := (p_modo = 'paciente');
begin
  select clinic_id into v_clinic from wa_numeros where phone_number_id = p_phone_number_id limit 1;
  if v_clinic is null or nx_fone_key(p_to) is null then return null; end if;

  insert into wa_contato_ia(clinic_id, fone_key, modo)
    values (v_clinic, nx_fone_key(p_to), p_modo)
  on conflict (clinic_id, fone_key) do update set modo = excluded.modo, updated_at = now();

  v_conv := public.nx_wa_conv_aberta(p_phone_number_id, p_to);
  if v_conv is null then
    insert into conversations(clinic_id, telefone, canal, status, bot_active, canal_phone_id)
      values (v_clinic, p_to, 'WhatsApp', 'nova', v_paciente, p_phone_number_id)
      returning id into v_conv;
  end if;

  update conversations set
    bot_active      = v_paciente,
    bot_state       = case when v_paciente then null else bot_state end,
    contexto_tipo   = case when v_paciente then 'paciente' else 'pessoal' end,
    contexto_motivo = case when v_paciente then 'sinalizado pelo médico (#ia)' else 'IA desligada pelo médico (#off)' end,
    updated_at      = now()
  where id = v_conv;
  return v_conv;
end $$;


-- Envio pelo cockpit: o numero e o da conversa.
create or replace function public.nx_wa_can_send(p_conv uuid)
 returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare cl uuid; tel text; pnid text; ult timestamptz;
begin
  select clinic_id, telefone into cl, tel from conversations where id = p_conv;
  if cl is null then raise exception 'conversa não encontrada'; end if;
  if not (public.is_member(cl) or public.is_platform_admin()) then raise exception 'sem permissão'; end if;

  pnid := public.nx_conv_canal(p_conv);

  -- janela de 24h: contada a partir da ULTIMA mensagem recebida do paciente
  select max(created_at) into ult
    from messages where conversation_id = p_conv and direction = 'in';

  return jsonb_build_object(
    'clinic_id', cl,
    'telefone', tel,
    'phone_number_id', pnid,
    'ultima_entrada', ult,
    'janela_aberta', ult is not null and ult > now() - interval '24 hours'
  );
end $function$;


-- Painel: os numeros adicionais da clinica.
create or replace function public.nx_wa_numeros(p_clinic uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public.nx_can_admin(p_clinic) then raise exception 'sem permissão'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', e.id, 'rotulo', e.rotulo, 'display_number', e.display_number, 'status', e.status,
      'coexistencia', e.coexistencia, 'conexao_erro', e.conexao_erro, 'connected_at', e.connected_at)
      order by e.created_at)
    from clinic_whatsapp_extra e where e.clinic_id = p_clinic), '[]'::jsonb);
end $$;

create or replace function public.nx_wa_numero_remover(p_clinic uuid, p_id uuid)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.nx_can_admin(p_clinic) then raise exception 'sem permissão'; end if;
  delete from clinic_whatsapp_extra where id = p_id and clinic_id = p_clinic;
end $$;

revoke all on function public.nx_conv_canal(uuid) from public, anon, authenticated;
grant execute on function public.nx_conv_canal(uuid) to service_role;
grant execute on function public.nx_wa_numeros(uuid) to authenticated;
grant execute on function public.nx_wa_numero_remover(uuid, uuid) to authenticated;
