-- 028 - Lembretes so contam como enviados quando a Meta aceita.
-- A nx_wa_run_reminders disparava por pg_net (que e assincrono) e marcava
-- confirmation_sent/reminder_*_sent na hora, sem olhar a resposta. Se a Meta
-- recusasse - template pausado, janela, numero invalido, token vencido -
-- ninguem ficava sabendo e o paciente nunca recebia o lembrete. Alem disso o
-- envio nao aparecia na conversa: a equipe nao via o que o sistema mandou.
-- Agora cada disparo vira uma linha de fila; um segundo passo le a resposta,
-- registra a mensagem na conversa e so entao marca como enviado. O que falhar
-- e tentado de novo (ate 3 vezes) e, esgotado, chama a equipe.
-- ADITIVO.

create table if not exists public.wa_envio (
  id            uuid primary key default gen_random_uuid(),
  clinic_id     uuid not null,
  appointment_id uuid references public.appointments(id) on delete cascade,
  conversation_id uuid references public.conversations(id) on delete set null,
  tipo          text not null,              -- confirmation | 24h | 2h | vacina | retorno
  template      text not null,
  telefone      text not null,
  corpo         text,                       -- texto legivel, para a conversa
  request_id    bigint,                     -- id do pg_net
  status        text not null default 'pendente',  -- pendente | enviado | falhou
  wamid         text,
  erro          text,
  tentativas    int not null default 1,
  created_at    timestamptz not null default now(),
  checado_em    timestamptz
);

create index if not exists wa_envio_pendente_idx on public.wa_envio(status, created_at);
create index if not exists wa_envio_appt_idx on public.wa_envio(appointment_id, tipo);

alter table public.wa_envio enable row level security;
drop policy if exists wa_envio_leitura on public.wa_envio;
create policy wa_envio_leitura on public.wa_envio for select
  using (public.is_member(clinic_id) or public.is_platform_admin());

-- Dispara os lembretes e registra na fila (nao marca como enviado ainda).
create or replace function public.nx_wa_run_reminders()
returns integer language plpgsql security definer set search_path to 'public', 'net' as $$
declare r record; tmpl text; params jsonb; which text; sent int := 0;
        data_txt text; hora_txt text; req bigint; corpo text; conv uuid;
begin
  for r in
    select a.*, w.phone_number_id, w.access_token,
           coalesce(cl.rem_confirmacao,true) as rem_conf,
           coalesce(cl.rem_24h,true) as rem24, coalesce(cl.rem_2h,true) as rem2
    from public.appointments a
    join public.clinic_whatsapp w on w.clinic_id=a.clinic_id and w.status='conectado'
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

    select net.http_post(
      url := 'https://graph.facebook.com/v21.0/'||r.phone_number_id||'/messages',
      headers := jsonb_build_object('Authorization','Bearer '||r.access_token,'Content-Type','application/json'),
      body := jsonb_build_object('messaging_product','whatsapp','to',r.telefone,'type','template',
                'template', jsonb_build_object('name',tmpl,'language',jsonb_build_object('code','pt_BR'),
                  'components', jsonb_build_array(jsonb_build_object('type','body',
                    'parameters', (select jsonb_agg(jsonb_build_object('type','text','text',x)) from jsonb_array_elements_text(params) x)))))
    ) into req;

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
end; $$;

-- Le a resposta da Meta e fecha o ciclo.
create or replace function public.nx_wa_check_envios()
returns jsonb language plpgsql security definer set search_path to 'public', 'net' as $$
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
        wam := (resp.content::jsonb -> 'messages' -> 0 ->> 'id');
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
                  'lembrete '||e.tipo||' nao foi aceito pela Meta apos 3 tentativas: '||left(msg,200));
        if e.conversation_id is not null then
          update public.conversations set attention=true where id=e.conversation_id;
        end if;
      end if;
    end if;
  end loop;
  return jsonb_build_object('enviados', conf, 'falhas', falha);
end; $$;

-- Quadro para a equipe: o que nao chegou.
create or replace function public.nx_wa_envios_falhos(p_clinic uuid)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'quando', e.created_at, 'tipo', e.tipo, 'paciente', a.paciente_nome,
      'telefone', e.telefone, 'tentativas', e.tentativas, 'erro', e.erro
    ) order by e.created_at desc),'[]'::jsonb)
  from public.wa_envio e left join public.appointments a on a.id=e.appointment_id
  where e.clinic_id=p_clinic and e.status='falhou' and e.created_at > now() - interval '30 days';
$$;

revoke all on function public.nx_wa_check_envios() from public, anon, authenticated;
grant execute on function public.nx_wa_check_envios() to service_role;
grant execute on function public.nx_wa_envios_falhos(uuid) to authenticated, service_role;

-- Roda logo depois do disparo (a rotina de lembretes e a cada 15 min).
select cron.schedule('wa-check-envios', '*/2 * * * *', 'select public.nx_wa_check_envios();')
where not exists (select 1 from cron.job where jobname='wa-check-envios');
