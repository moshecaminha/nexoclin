-- 036 - O modelo interpreta, o banco decide.
-- Ate aqui a interpretacao da frase era regex em SQL: cada jeito novo de falar
-- virava um defeito, e frase ambigua casava com o ramo errado em silencio.
-- Agora o passo de agendamento aceita o pedido JA ESTRUTURADO (dia, hora,
-- turno, confirmacao, escolha), venha ele do modelo ou da regra antiga.
-- O banco continua dono da decisao: ele valida o que recebeu contra a agenda
-- de verdade e ignora o que nao fecha. O modelo nunca ve horario nem preco.
-- ADITIVO.

-- Registro do que foi entendido, para auditar e virar caso de teste.
create table if not exists public.wa_interp (
  id           uuid primary key default gen_random_uuid(),
  conversation_id uuid references public.conversations(id) on delete cascade,
  texto        text not null,
  estado       text,
  ped          jsonb,
  confirmacao  boolean,
  escolha      int,
  origem       text not null default 'regra',   -- modelo | regra
  resposta     text,
  created_at   timestamptz not null default now()
);
create index if not exists wa_interp_conv_idx on public.wa_interp(conversation_id, created_at desc);
alter table public.wa_interp enable row level security;
drop policy if exists wa_interp_leitura on public.wa_interp;
create policy wa_interp_leitura on public.wa_interp for select
  using (public.is_platform_admin());

-- Valida o que o modelo devolveu. Fora disso, o banco nao obedece.
create or replace function public.nx_ped_valido(p_ped jsonb)
returns jsonb language plpgsql immutable set search_path to 'public' as $$
declare res jsonb := '{}'::jsonb; d date; h text;
begin
  if p_ped is null then return '{}'::jsonb; end if;

  begin
    d := nullif(p_ped->>'data','')::date;
    if d is not null and d >= (now() at time zone 'America/Sao_Paulo')::date - 1 then
      res := res || jsonb_build_object('data', to_char(d,'YYYY-MM-DD'));
    end if;
  exception when others then null; end;

  foreach h in array array['hora','hora_min','hora_max'] loop
    if p_ped->>h ~ '^[0-2][0-9]:[0-5][0-9]$' then
      res := res || jsonb_build_object(h, p_ped->>h);
    end if;
  end loop;

  if p_ped->>'turno' in ('manha','tarde') then
    res := res || jsonb_build_object('turno', p_ped->>'turno');
  end if;
  return res;
end; $$;

-- A versao antiga de 2 argumentos sai de cena: fica so a de 5, com defaults.
drop function if exists public.nx_book_step_agenda(uuid, text);

-- O passo de agendamento passa a aceitar o pedido pronto.
-- Sem ele (p_ped null), usa a leitura por regra, como antes.
create or replace function public.nx_book_step_agenda(
  p_conv uuid, p_text text,
  p_ped jsonb default null, p_conf boolean default null, p_escolha int default null
) returns text language plpgsql security definer set search_path to 'public' as $$
declare st text; ctx jsonb; prof uuid; cl uuid; tel text; nm text; patid uuid; modal text; turno text;
        offers jsonb; o jsonb; n int; aid uuid; sched timestamptz; msg text;
        meds jsonb; m jsonb; qtd int; ped jsonb; esc int; casa int; alvo date; conf boolean;
begin
  select bot_state,bot_ctx,clinic_id,telefone,paciente_nome,patient_id into st,ctx,cl,tel,nm,patid
    from public.conversations where id=p_conv;
  prof := public.nx_conv_doctor(p_conv);
  if st='agenda_pref' then st:='ag_prof'; end if;

  ped := case when p_ped is null then public.nx_book_pedido(p_text)
              else public.nx_ped_valido(p_ped) end;

  if st='ag_prof' then
    meds := public.nx_book_medicos(cl);
    qtd := jsonb_array_length(meds);
    n := nullif(regexp_replace(coalesce(p_text,''),'\D','','g'),'')::int;
    if (n is not null and n = qtd+1)
       or lower(coalesce(p_text,'')) ~ '(tanto faz|qualquer|indiferente|mais cedo|mais pr[oó]xim|voc[eê] escolhe|n[aã]o tenho prefer)' then
      update public.conversations set bot_ctx=coalesce(ctx,'{}')||jsonb_build_object('sem_pref',true), bot_state='ag_turno' where id=p_conv;
      return 'Certo, vou pegar o horario mais proximo. Voce prefere de *manha* ou a *tarde*?';
    end if;
    if n is not null and n between 1 and qtd then
      prof := (meds->(n-1)->>'id')::uuid;
    else
      for m in select * from jsonb_array_elements(meds) loop
        if lower(coalesce(p_text,'')) like '%'||lower(m->>'nome')||'%'
           or lower(coalesce(p_text,'')) like '%'||lower(split_part(m->>'nome',' ',1))||'%' then
          prof := (m->>'id')::uuid; exit;
        end if;
      end loop;
    end if;
    if prof is null then return public.nx_book_pergunta_prof(cl); end if;
    perform public.nx_conv_set_doctor(p_conv, prof);
    return public.nx_book_start(p_conv);

  elsif st='ag_mod' then
    if lower(p_text) ~ '(tele|v[ií]deo|online|2)' then modal:='telemedicina'; else modal:='presencial'; end if;
    update public.conversations set bot_ctx=coalesce(ctx,'{}')||jsonb_build_object('modalidade',modal), bot_state='ag_turno' where id=p_conv;
    return 'Perfeito, '||modal||'. Voce prefere de *manha* ou a *tarde*?';

  elsif st='ag_turno' then
    modal := coalesce(ctx->>'modalidade','presencial');
    turno := coalesce(ped->>'turno', case when ped ? 'hora' or ped ? 'hora_min' then null else 'qualquer' end);

    alvo := nullif(ped->>'data','')::date;
    if alvo is not null and alvo > public.nx_agenda_horizonte() then
      return 'A agenda aberta vai ate *'||to_char(public.nx_agenda_horizonte(),'DD/MM')||
             '*, entao ainda nao consigo marcar em '||to_char(alvo,'DD/MM')||
             '. Quer um horario antes disso, ou prefere que a equipe te avise quando abrir?';
    end if;

    if prof is null then
      prof := public.nx_book_prof_mais_cedo(cl, modal, coalesce(turno,'qualquer'));
      if prof is not null then perform public.nx_conv_set_doctor(p_conv, prof); end if;
    end if;
    if prof is null then
      update public.conversations set bot_state=null, status='aguardando_medico' where id=p_conv;
      return 'Nao encontrei horarios livres nos proximos dias. Vou pedir para a equipe te retornar, tudo bem? 💙';
    end if;
    update public.conversations set
      bot_ctx=coalesce(ctx,'{}')||jsonb_build_object('modalidade',modal)||ped
              ||case when turno is null then '{}'::jsonb else jsonb_build_object('turno',turno) end
     where id=p_conv;
    msg := public.nx_book_ofertar(p_conv, true);
    if msg is null then
      update public.conversations set bot_state=null, status='aguardando_medico' where id=p_conv;
      return 'Nao achei vaga nos proximos dias. Vou pedir para a equipe te retornar, tudo bem? 💙';
    end if;
    return msg;

  elsif st='ag_offer' then
    offers := ctx->'offers';
    qtd := coalesce(jsonb_array_length(offers),0);
    esc := coalesce(p_escolha, public.nx_book_escolha(p_text, qtd));
    conf := coalesce(p_conf, esc is not null);
    casa := public.nx_book_casa_oferta(offers, ped);

    -- REGRA DURA (vale para modelo e para regra):
    -- quem traz restricao nova nao esta confirmando. So marca sem "sim" quando
    -- nomeou o horario inteiro e ele ja estava na mesa.
    if ped <> '{}'::jsonb then
      esc := null;
      if casa is not null and casa > 0 and ped ? 'hora' and ped ? 'data' then
        esc := casa;
      elsif casa = 0 then
        return 'Nos dois dias tenho esse horario: '||
               public.nx_quando_txt((offers->0->>'data')::date, offers->0->>'hora')||' ou '||
               public.nx_quando_txt((offers->1->>'data')::date, offers->1->>'hora')||'. Qual deles?';
      end if;
    elsif conf and esc is null and qtd = 1 then
      esc := 1;                                   -- "sim" limpo, uma opcao na mesa
    end if;

    if esc is not null and esc between 1 and qtd then
      o := offers->(esc-1);
      modal := coalesce(ctx->>'modalidade','presencial');
      sched := ((o->>'data')||' '||(o->>'hora')||':00')::timestamp at time zone 'America/Sao_Paulo';
      nm := public.nx_doc_primeiro_nome(prof);
      aid := public.nx_appt_create_bot(cl, patid, p_conv, (select paciente_nome from public.conversations where id=p_conv), tel,
              (select nome from public.profiles where id=prof), prof, 'Consulta', sched, modal);
      update public.conversations set bot_state=null, status='agendada' where id=p_conv;
      if modal='telemedicina' then
        return public.nx_book_confirmacao(aid, 'Prontinho! Sua *teleconsulta* com '||nm||' ficou para '||
          public.nx_quando_txt((o->>'data')::date, o->>'hora')||'. Como e por video, o pagamento e antecipado. 💙');
      end if;
      return public.nx_book_confirmacao(aid, 'Prontinho! ✅ Consulta com '||nm||' marcada para '||
        public.nx_quando_txt((o->>'data')::date, o->>'hora')||
        '. Vou te lembrar por aqui. Se precisar remarcar, e so falar comigo. 💙');
    end if;

    if ped <> '{}'::jsonb then
      alvo := nullif(ped->>'data','')::date;
      if alvo is not null and alvo > public.nx_agenda_horizonte() then
        return 'A agenda aberta vai ate *'||to_char(public.nx_agenda_horizonte(),'DD/MM')||
               '*, entao ainda nao consigo marcar em '||to_char(alvo,'DD/MM')||
               '. Quer um horario antes disso, ou prefere que a equipe te avise quando abrir?';
      end if;
      update public.conversations set
        bot_ctx = (
          coalesce(ctx,'{}') - 'shown'
          - (case when ped ? 'data' then 'data' else '' end)
          - (case when ped ? 'turno' or ped ? 'hora' then 'turno' else '' end)
          - (case when ped ? 'turno' or ped ? 'hora' or ped ? 'hora_min' then 'hora' else '' end)
          - (case when ped ? 'turno' or ped ? 'hora' then 'hora_min' else '' end)
          - (case when ped ? 'turno' or ped ? 'hora' then 'hora_max' else '' end)
        ) || ped
       where id=p_conv;
      msg := public.nx_book_ofertar(p_conv, true);
      return coalesce(msg, 'Nao tenho vaga nesse horario nos proximos dias. Quer que a equipe te retorne?');
    end if;

    if lower(coalesce(p_text,'')) ~ '(outro|mais op|outra|diferente|nenhum)' then
      msg := public.nx_book_ofertar(p_conv, false);
      return coalesce(msg, 'Por ora nao tenho outros horarios. Quer que a equipe te retorne com mais opcoes?');
    end if;

    if qtd > 1 and (conf or lower(coalesce(p_text,'')) ~ '(sim|pode|serve|ok|beleza|fechado|isso|claro|quero)') then
      return 'Qual dos dois: '||public.nx_quando_txt((offers->0->>'data')::date, offers->0->>'hora')||
             ' ou '||public.nx_quando_txt((offers->1->>'data')::date, offers->1->>'hora')||'?';
    end if;
    if qtd = 1 then
      return 'Desculpe, nao entendi. Posso marcar '||
             public.nx_quando_txt((offers->0->>'data')::date, offers->0->>'hora')||'?';
    end if;
    return 'Desculpe, nao entendi. Prefere '||
           public.nx_quando_txt((offers->0->>'data')::date, offers->0->>'hora')||' ou '||
           public.nx_quando_txt((offers->1->>'data')::date, offers->1->>'hora')||
           '? Se preferir outro dia ou horario, e so dizer.';
  end if;
  return null;
end; $$;

-- Porta de entrada do agente: recebe o entendido, registra e executa.
create or replace function public.nx_book_step_ia(
  p_conv uuid, p_texto text, p_ped jsonb, p_conf boolean, p_escolha int, p_origem text default 'modelo'
) returns text language plpgsql security definer set search_path to 'public' as $$
declare st text; r text;
begin
  select bot_state into st from public.conversations where id=p_conv;
  if st = 'ag_quem' then
    r := public.nx_book_quem_step(p_conv, p_texto);
  else
    r := public.nx_book_step_agenda(p_conv, p_texto, p_ped, p_conf, p_escolha);
  end if;
  insert into public.wa_interp(conversation_id, texto, estado, ped, confirmacao, escolha, origem, resposta)
    values (p_conv, p_texto, st, p_ped, p_conf, p_escolha, coalesce(p_origem,'modelo'), left(coalesce(r,''),400));
  return r;
end; $$;

revoke all on function public.nx_book_step_ia(uuid,text,jsonb,boolean,int,text) from public, anon, authenticated;
grant execute on function public.nx_book_step_ia(uuid,text,jsonb,boolean,int,text) to service_role;
grant execute on function public.nx_ped_valido(jsonb) to service_role;
