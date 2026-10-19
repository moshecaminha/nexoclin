-- WhatsApp oficial pela Zernio (provider = 'zernio').
-- ADITIVO: as conexoes meta_cloud e uazapi continuam como estao.
--
-- clinic_whatsapp para a Zernio:
--   phone_number_id = 'zernio:<accountId>'  (chave de roteamento do webhook)
--   access_token    = accountId da Zernio   (a API key e uma so, da NexoClin)

-- 1) Id da conversa na Zernio por telefone. Texto livre so sai por ele; vem
--    no webhook de cada mensagem do paciente.
create table if not exists public.wa_zernio_conversa (
  account_id             text not null,
  fone_key               text not null,         -- DDD + 8 ultimos digitos
  telefone               text,
  zernio_conversation_id text not null,
  updated_at             timestamptz not null default now(),
  primary key (account_id, fone_key)
);
alter table public.wa_zernio_conversa enable row level security;

-- 2) Estado de uso unico do cadastro: liga a volta da Zernio a clinica que
--    pediu, para ninguem gravar a conta de outro numero na sua clinica.
create table if not exists public.wa_zernio_estado (
  estado    text primary key default replace(gen_random_uuid()::text, '-', ''),
  clinic_id uuid not null references public.clinics(id) on delete cascade,
  modo      text not null default 'coexistencia',
  criado_em timestamptz not null default now()
);
alter table public.wa_zernio_estado enable row level security;


-- 3) API key da Zernio no vault, para os lembretes que saem do banco.
--    So a service_role grava (a wa-signup, na acao "configurar").
create or replace function public.nx_zernio_set_key(p_key text)
returns void language plpgsql security definer set search_path to 'public', 'vault' as $$
declare v uuid;
begin
  select id into v from vault.secrets where name = 'zernio_api_key';
  if v is null then perform vault.create_secret(p_key, 'zernio_api_key');
  else perform vault.update_secret(v, p_key); end if;
end $$;
revoke all on function public.nx_zernio_set_key(text) from public, anon, authenticated;
grant execute on function public.nx_zernio_set_key(text) to service_role;


-- 4) Disparo de template pelo canal da clinica. Devolve o id do pg_net,
--    conferido depois pela nx_wa_check_envios.
create or replace function public.nx_wa_template_post(
  p_provider text, p_phone_number_id text, p_token text,
  p_to text, p_template text, p_params jsonb)
returns bigint language plpgsql security definer set search_path to 'public', 'net' as $$
declare req bigint;
begin
  if p_provider = 'zernio' then
    select net.http_post(
      url := 'https://zernio.com/api/v1/inbox/conversations',
      headers := jsonb_build_object('Content-Type','application/json',
        'Authorization','Bearer '||(select decrypted_secret from vault.decrypted_secrets where name='zernio_api_key')),
      body := jsonb_build_object('accountId', p_token,
        'participantId', regexp_replace(p_to, '\D', '', 'g'),
        'templateName', p_template, 'templateLanguage', 'pt_BR', 'templateParams', p_params)
    ) into req;
  else
    select net.http_post(
      url := 'https://graph.facebook.com/v21.0/'||p_phone_number_id||'/messages',
      headers := jsonb_build_object('Authorization','Bearer '||p_token,'Content-Type','application/json'),
      body := jsonb_build_object('messaging_product','whatsapp','to',p_to,'type','template',
                'template', jsonb_build_object('name',p_template,'language',jsonb_build_object('code','pt_BR'),
                  'components', jsonb_build_array(jsonb_build_object('type','body',
                    'parameters', (select jsonb_agg(jsonb_build_object('type','text','text',x))
                                     from jsonb_array_elements_text(p_params) x)))))
    ) into req;
  end if;
  return req;
end $$;
revoke all on function public.nx_wa_template_post(text,text,text,text,text,jsonb) from public, anon, authenticated;


-- 5) Lembretes e retornos: mesma logica, agora tambem pela Zernio.
create or replace function public.nx_wa_run_reminders()
 returns integer language plpgsql security definer set search_path to 'public', 'net' as $function$
declare r record; tmpl text; params jsonb; which text; sent int := 0;
        data_txt text; hora_txt text; req bigint; corpo text; conv uuid;
begin
  for r in
    select a.*, w.provider as w_provider, w.phone_number_id, w.access_token,
           coalesce(cl.rem_confirmacao,true) as rem_conf,
           coalesce(cl.rem_24h,true) as rem24, coalesce(cl.rem_2h,true) as rem2
    from public.appointments a
    join public.clinic_whatsapp w on w.clinic_id=a.clinic_id and w.status='conectado'
      and coalesce(w.provider,'meta_cloud') in ('meta_cloud','zernio')  -- uazapi nao tem template aprovado
    join public.clinics cl on cl.id=a.clinic_id
    where a.status in ('agendada','confirmada') and coalesce(a.telefone,'')<>''
      and (
        (a.confirmation_sent=false and coalesce(cl.rem_confirmacao,true))
        or (a.reminder_24h_sent=false and coalesce(cl.rem_24h,true) and a.scheduled_at <= now()+interval '24 hours' and a.scheduled_at > now()+interval '2 hours')
        or (a.reminder_2h_sent=false and coalesce(cl.rem_2h,true) and a.scheduled_at <= now()+interval '2 hours' and a.scheduled_at > now())
      )
    limit 50
  loop
    data_txt := to_char(r.scheduled_at at time zone 'America/Sao_Paulo','DD/MM');
    hora_txt := to_char(r.scheduled_at at time zone 'America/Sao_Paulo','HH24:MI');

    if r.confirmation_sent=false and r.rem_conf then
      which:='confirmation'; tmpl:='confirmacao_agendamento';
      params:=jsonb_build_array(coalesce(r.paciente_nome,'paciente'),coalesce(r.profissional_nome,'a equipe'),data_txt,hora_txt);
      corpo := 'Agendamento de '||coalesce(r.paciente_nome,'paciente')||' com '||coalesce(r.profissional_nome,'a equipe')||' em '||data_txt||' as '||hora_txt||'.';
    elsif r.reminder_24h_sent=false and r.rem24 and r.scheduled_at <= now()+interval '24 hours' and r.scheduled_at > now()+interval '2 hours' then
      which:='24h'; tmpl:='lembrete_consulta_24h';
      params:=jsonb_build_array(coalesce(r.paciente_nome,'paciente'),data_txt,hora_txt,coalesce(r.profissional_nome,'a equipe'));
      corpo := 'Lembrete: a consulta de '||coalesce(r.paciente_nome,'paciente')||' e amanha, '||data_txt||' as '||hora_txt||'.';
    elsif r.reminder_2h_sent=false and r.rem2 and r.scheduled_at <= now()+interval '2 hours' and r.scheduled_at > now() then
      which:='2h'; tmpl:='lembrete_consulta_2h';
      params:=jsonb_build_array(coalesce(r.paciente_nome,'paciente'),hora_txt);
      corpo := 'Lembrete: a consulta de '||coalesce(r.paciente_nome,'paciente')||' e hoje as '||hora_txt||'.';
    else
      continue;
    end if;

    -- ja existe disparo pendente deste tipo? nao duplica
    if exists (select 1 from public.wa_envio e
                where e.appointment_id=r.id and e.tipo=which and e.status='pendente') then
      continue;
    end if;

    req := public.nx_wa_template_post(coalesce(r.w_provider,'meta_cloud'), r.phone_number_id, r.access_token,
                                      r.telefone, tmpl, params);

    select id into conv from public.conversations
     where clinic_id=r.clinic_id and nx_fone_key(telefone)=nx_fone_key(r.telefone)
     order by created_at desc limit 1;

    insert into public.wa_envio(clinic_id, appointment_id, conversation_id, tipo, template, telefone, corpo, request_id,
                                tentativas)
      values (r.clinic_id, r.id, conv, which, tmpl, r.telefone, corpo, req,
              1 + (select count(*) from public.wa_envio e where e.appointment_id=r.id and e.tipo=which));
    sent := sent + 1;
  end loop;
  return sent;
end; $function$;

create or replace function public.nx_wa_run_retornos()
 returns integer language plpgsql security definer set search_path to 'public', 'net' as $function$
declare r record; req bigint; sent int := 0; dias int; quanto text; conv uuid;
begin
  for r in
    select distinct on (a.clinic_id, a.telefone)
           a.clinic_id, a.telefone, a.paciente_nome, a.patient_id, a.profissional_nome,
           a.scheduled_at as ultima, w.provider as w_provider, w.phone_number_id, w.access_token, cl.nome as clinica
      from public.appointments a
      join public.clinic_whatsapp w on w.clinic_id=a.clinic_id and w.status='conectado'
      and coalesce(w.provider,'meta_cloud') in ('meta_cloud','zernio')  -- uazapi nao tem template aprovado
      join public.clinics cl on cl.id=a.clinic_id and coalesce(cl.retorno_permite,true)
     where a.status='realizada' and coalesce(a.telefone,'')<>''
       and a.scheduled_at < now() - make_interval(days => public.nx_retorno_dias(a.clinic_id))
       -- nao tem consulta futura
       and not exists (select 1 from public.appointments f
                        where f.clinic_id=a.clinic_id and f.telefone=a.telefone
                          and f.scheduled_at > now() and f.status in ('agendada','confirmada'))
       -- nao foi convidado nos ultimos 90 dias
       and not exists (select 1 from public.wa_envio e
                        where e.clinic_id=a.clinic_id and e.telefone=a.telefone and e.tipo='retorno'
                          and e.created_at > now() - interval '90 days')
     order by a.clinic_id, a.telefone, a.scheduled_at desc
     limit 50
  loop
    dias := (extract(epoch from (now() - r.ultima))/86400)::int;
    quanto := case when dias >= 730 then (dias/365)::text||' anos'
                   when dias >= 365 then 'mais de um ano'
                   when dias >= 60  then (dias/30)::text||' meses'
                   else dias::text||' dias' end;

    req := public.nx_wa_template_post(coalesce(r.w_provider,'meta_cloud'), r.phone_number_id, r.access_token,
             r.telefone, 'retorno_recomendado',
             jsonb_build_array(coalesce(r.paciente_nome,'paciente'), quanto, coalesce(r.profissional_nome,'a equipe')));

    select id into conv from public.conversations
     where clinic_id=r.clinic_id and nx_fone_key(telefone)=nx_fone_key(r.telefone)
     order by created_at desc limit 1;

    insert into public.wa_envio(clinic_id, appointment_id, conversation_id, tipo, template, telefone, corpo, request_id)
      values (r.clinic_id, null, conv, 'retorno', 'retorno_recomendado', r.telefone,
              'Convite de retorno para '||coalesce(r.paciente_nome,'paciente')||' ('||quanto||' desde a ultima consulta).', req);
    sent := sent + 1;
  end loop;
  return sent;
end; $function$;


-- 6) Conferencia dos disparos: a Zernio devolve o wamid em data.messageId.
create or replace function public.nx_wa_check_envios()
 returns jsonb language plpgsql security definer set search_path to 'public', 'net' as $function$
declare e record; resp record; ok boolean; wam text; msg text; conf int := 0; falha int := 0;
begin
  for e in select * from public.wa_envio where status='pendente' and request_id is not null
            and created_at > now() - interval '2 days' order by created_at limit 100
  loop
    select status_code, content, error_msg, timed_out into resp
      from net._http_response where id = e.request_id;

    -- resposta ainda nao chegou (ou ja expirou da tabela do pg_net)
    if not found then
      if e.created_at < now() - interval '30 minutes' then
        update public.wa_envio set status='falhou', erro='sem resposta do pg_net', checado_em=now() where id=e.id;
        falha := falha + 1;
      end if;
      continue;
    end if;

    ok := coalesce(resp.status_code,0) between 200 and 299 and coalesce(resp.timed_out,false) = false;
    if ok then
      begin
        wam := coalesce(resp.content::jsonb -> 'messages' -> 0 ->> 'id',   -- Meta
                        resp.content::jsonb -> 'data' ->> 'messageId');    -- Zernio
      exception when others then wam := null; end;

      update public.wa_envio set status='enviado', wamid=wam, checado_em=now() where id=e.id;

      -- marca no agendamento so agora
      if e.tipo='confirmation' then update public.appointments set confirmation_sent=true where id=e.appointment_id;
      elsif e.tipo='24h'      then update public.appointments set reminder_24h_sent=true where id=e.appointment_id;
      elsif e.tipo='2h'       then update public.appointments set reminder_2h_sent=true where id=e.appointment_id;
      end if;

      -- o que o sistema mandou tem de aparecer na conversa
      if e.conversation_id is not null and coalesce(e.corpo,'')<>'' then
        insert into public.messages(conversation_id, direction, type, body, author, wa_message_id)
          values (e.conversation_id, 'out', 'text', e.corpo, 'sistema', wam)
          on conflict (wa_message_id) where wa_message_id is not null do nothing;
      end if;
      conf := conf + 1;
    else
      msg := coalesce(nullif(resp.error_msg,''), left(coalesce(resp.content,''),400),
                      'status '||coalesce(resp.status_code,0)::text);
      update public.wa_envio set status='falhou', erro=msg, checado_em=now() where id=e.id;
      falha := falha + 1;

      -- esgotou as tentativas: para de tentar e chama a equipe
      if e.tentativas >= 3 then
        if e.tipo='confirmation' then update public.appointments set confirmation_sent=true where id=e.appointment_id;
        elsif e.tipo='24h'      then update public.appointments set reminder_24h_sent=true where id=e.appointment_id;
        elsif e.tipo='2h'       then update public.appointments set reminder_2h_sent=true where id=e.appointment_id;
        end if;
        insert into public.appointment_events(appointment_id, clinic_id, tipo, por, motivo)
          values (e.appointment_id, e.clinic_id, 'lembrete_falhou', 'sistema',
                  'lembrete '||e.tipo||' nao foi aceito pelo WhatsApp apos 3 tentativas: '||left(msg,200));
        if e.conversation_id is not null then
          update public.conversations set attention=true where id=e.conversation_id;
        end if;
      end if;
    end if;
  end loop;
  return jsonb_build_object('enviados', conf, 'falhas', falha);
end; $function$;


-- 7) Desconectar uma conta da Zernio tambem solta o roteamento: o webhook
--    deixa de achar a clinica e as mensagens param de entrar.
create or replace function public.nx_wa_disconnect(p_clinic uuid)
 returns void language plpgsql security definer set search_path to 'public' as $function$
begin
  if not public.nx_can_admin(p_clinic) then raise exception 'sem permissão'; end if;
  update public.clinic_whatsapp set status='desconectado', access_token=null, app_secret=null, connected_at=null,
         phone_number_id = case when provider='zernio' then null else phone_number_id end,
         updated_at=now() where clinic_id=p_clinic;
end; $function$;

-- 8) O card de conexao passa a saber o provedor.
create or replace function public.nx_wa_get(p_clinic uuid)
 returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare w public.clinic_whatsapp; base text := 'https://kzbazzwfdagfhyxuadqp.supabase.co/functions/v1/wa-webhook';
begin
  if not public.nx_can_admin(p_clinic) then raise exception 'sem permissão'; end if;
  select * into w from public.clinic_whatsapp where clinic_id=p_clinic;
  return jsonb_build_object(
    'status', coalesce(w.status,'desconectado'),
    'provider', w.provider,
    'coexistencia', coalesce(w.coexistencia,false),
    'conexao_erro', w.conexao_erro,
    'display_number', w.display_number,
    'phone_number_id', w.phone_number_id,
    'waba_id', w.waba_id,
    'verify_token', w.verify_token,
    'token_mask', case when w.access_token is null then null else '••••'||right(w.access_token,4) end,
    'secret_set', (w.app_secret is not null),
    'connected_at', w.connected_at,
    'webhook_url', base||'?clinic='||p_clinic::text
  );
end; $function$;
