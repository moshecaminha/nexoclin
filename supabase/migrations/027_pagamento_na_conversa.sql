-- 027 - Pagamento na conversa (secao 6 do documento do cliente).
-- A IA marcava a consulta e parava ali: valor e forma de pagamento nunca
-- chegavam ao paciente, e a tabela payments estava zerada. Agora, ao confirmar
-- o horario, o sistema calcula o valor pela tabela do profissional e manda a
-- cobranca do jeito que a clinica configurou (PIX manual ou link automatico).
-- Quem informa valor continua sendo o banco, nunca o modelo.
-- ADITIVO.

-- Valor da consulta pela tabela do profissional (modalidade e, se houver, categoria).
create or replace function public.nx_appt_valor(p_appt uuid)
returns numeric language plpgsql security definer set search_path to 'public' as $$
declare v numeric; prof uuid; modal text; cat text;
begin
  select professional_id, modalidade, categoria, valor into prof, modal, cat, v
    from public.appointments where id=p_appt;
  if v is not null then return v; end if;

  select sp.valor into v from public.service_prices sp
   where sp.professional_id=prof and sp.ativo
     and (modal is null or sp.modalidade=modal)
     and (cat is null or sp.categoria=cat)
   order by (sp.categoria = coalesce(cat,'')) desc, sp.valor
   limit 1;

  if v is not null then
    update public.appointments set valor=v where id=p_appt;
  end if;
  return v;
end; $$;

-- O que dizer ao paciente sobre o pagamento.
-- Devolve {texto, precisa_link, valor}. precisa_link = a Edge Function pay-create
-- e que gera a cobranca (Mercado Pago); o texto vai depois, com o link.
create or replace function public.nx_pagamento_msg(p_appt uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v numeric; cl uuid; modo text; chave text; titular text; modal text; conv uuid; vtxt text;
begin
  select a.clinic_id, a.modalidade, a.conversation_id into cl, modal, conv
    from public.appointments a where a.id=p_appt;
  if cl is null then return jsonb_build_object('texto',null,'precisa_link',false); end if;

  select c.pagamento_modo, c.pix_chave, c.pix_titular into modo, chave, titular
    from public.clinics c where c.id=cl;

  v := public.nx_appt_valor(p_appt);

  -- sem preco cadastrado: nao inventa valor nem promete cobranca
  if v is null then
    if coalesce(modal,'') = 'telemedicina' then
      update public.appointments set pagamento_status='pendente' where id=p_appt;
      update public.conversations set attention=true where id=conv;
      return jsonb_build_object('texto',
        'Sobre o pagamento da teleconsulta, a equipe vai te passar os dados por aqui antes do atendimento. 💙',
        'precisa_link', false, 'valor', null);
    end if;
    return jsonb_build_object('texto',null,'precisa_link',false,'valor',null);
  end if;

  vtxt := 'R$ '||trim(to_char(v,'FM999G999D00'));

  -- Link automatico (Mercado Pago). Hoje so a teleconsulta tem geracao
  -- automatica (gatilho -> pay-telemed, que manda o link sozinho). Para
  -- presencial ainda nao existe essa ponte: avisa a equipe em vez de prometer
  -- um link que ninguem vai gerar.
  if modo in ('link','automatico','mercadopago','pix_automatico') then
    update public.appointments set pagamento_status='pendente' where id=p_appt;
    if coalesce(modal,'') = 'telemedicina' then
      return jsonb_build_object('texto',
        'O valor e *'||vtxt||'*. Vou te mandar o link de pagamento aqui em seguida. 💙',
        'precisa_link', false, 'valor', v, 'valor_txt', vtxt);
    end if;
    update public.conversations set attention=true where id=conv;
    return jsonb_build_object('texto',
      'O valor da consulta e *'||vtxt||'*. A equipe vai te enviar o link de pagamento por aqui. 💙',
      'precisa_link', false, 'valor', v, 'valor_txt', vtxt);
  end if;

  -- PIX manual: usa a mensagem personalizada do consultorio quando existir,
  -- igual ao que a pay-telemed ja faz para teleconsulta.
  if coalesce(chave,'') <> '' then
    update public.appointments set pagamento_status='pendente' where id=p_appt;
    return jsonb_build_object('precisa_link', false, 'valor', v, 'valor_txt', vtxt, 'texto',
      coalesce(
        public.nx_msg(cl, 'pagamento', jsonb_build_object(
          'valor', trim(to_char(v,'FM999G999D00')), 'pix', chave, 'titular', coalesce(titular,''))),
        'O valor da consulta e *'||vtxt||'*.'||chr(10)||
        'Chave PIX: *'||chave||'*'||coalesce(chr(10)||'Titular: '||nullif(titular,''),'')||chr(10)||chr(10)||
        'Depois de pagar, e so *mandar o comprovante aqui* que eu registro. 💙'));
  end if;

  -- modo manual sem chave cadastrada: a equipe resolve, e o paciente sabe disso
  update public.appointments set pagamento_status='pendente' where id=p_appt;
  update public.conversations set attention=true where id=conv;
  return jsonb_build_object('precisa_link', false, 'valor', v, 'valor_txt', vtxt, 'texto',
    'O valor da consulta e *'||vtxt||'*. A equipe vai te enviar os dados para pagamento por aqui. 💙');
end; $$;

-- Comprovante recebido: nao confirma pagamento (quem confere e a equipe),
-- mas registra, marca a conversa e responde a pessoa.
create or replace function public.nx_pagamento_comprovante(p_conv uuid)
returns text language plpgsql security definer set search_path to 'public' as $$
declare aid uuid; cl uuid; v numeric;
begin
  select a.id, a.clinic_id, a.valor into aid, cl, v
    from public.appointments a
   where a.conversation_id=p_conv and a.pagamento_status in ('pendente','comprovante_enviado')
   order by a.scheduled_at limit 1;
  if aid is null then return null; end if;

  update public.appointments set pagamento_status='comprovante_enviado' where id=aid;
  insert into public.appointment_events(appointment_id,clinic_id,tipo,por,motivo)
    values(aid,cl,'pagamento','paciente','comprovante enviado pelo WhatsApp');
  update public.conversations set attention=true where id=p_conv;

  return 'Recebi o comprovante! ✅ A equipe vai conferir e confirmo por aqui. 💙';
end; $$;

revoke all on function public.nx_appt_valor(uuid) from public, anon, authenticated;
revoke all on function public.nx_pagamento_msg(uuid) from public, anon, authenticated;
revoke all on function public.nx_pagamento_comprovante(uuid) from public, anon, authenticated;
grant execute on function public.nx_appt_valor(uuid) to service_role;
grant execute on function public.nx_pagamento_msg(uuid) to service_role;
grant execute on function public.nx_pagamento_comprovante(uuid) to service_role;

-- A confirmacao do agendamento passa a levar a cobranca junto.
create or replace function public.nx_book_confirmacao(p_appt uuid, p_base text)
returns text language plpgsql security definer set search_path to 'public' as $$
declare pg jsonb;
begin
  pg := public.nx_pagamento_msg(p_appt);
  if coalesce(pg->>'texto','') = '' then return p_base; end if;
  return p_base || chr(10) || chr(10) || (pg->>'texto');
end; $$;

-- nx_book_step_agenda: a confirmacao do horario passa pela cobranca.
create or replace function public.nx_book_step_agenda(p_conv uuid, p_text text)
returns text language plpgsql security definer set search_path to 'public' as $$
declare st text; ctx jsonb; prof uuid; cl uuid; tel text; nm text; patid uuid; modal text; turno text;
        offers jsonb; o jsonb; n int; aid uuid; sched timestamptz; msg text;
        meds jsonb; m jsonb; qtd int; ped jsonb;
begin
  select bot_state,bot_ctx,clinic_id,telefone,paciente_nome,patient_id into st,ctx,cl,tel,nm,patid
    from public.conversations where id=p_conv;
  prof := public.nx_conv_doctor(p_conv);
  if st='agenda_pref' then st:='ag_prof'; end if;

  if st='ag_prof' then
    meds := public.nx_book_medicos(cl);
    qtd := jsonb_array_length(meds);
    n := nullif(regexp_replace(coalesce(p_text,''),'\D','','g'),'')::int;
    if (n is not null and n = qtd+1)
       or lower(coalesce(p_text,'')) ~ '(tanto faz|qualquer|indiferente|mais cedo|mais pr[oó]xim|voc[eê] escolhe|n[aã]o tenho prefer)' then
      update public.conversations set bot_ctx=coalesce(ctx,'{}')||jsonb_build_object('sem_pref',true), bot_state='ag_turno' where id=p_conv;
      return 'Certo, vou buscar o horario mais proximo. Voce prefere de *manha* ou a *tarde*?';
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
    ped := public.nx_book_pedido(p_text);
    turno := coalesce(ped->>'turno','qualquer');
    modal := coalesce(ctx->>'modalidade','presencial');
    if prof is null then
      prof := public.nx_book_prof_mais_cedo(cl, modal, turno);
      if prof is not null then perform public.nx_conv_set_doctor(p_conv, prof); end if;
    end if;
    if prof is null then
      update public.conversations set bot_state=null, status='aguardando_medico' where id=p_conv;
      return 'Nao encontrei horarios livres nos proximos dias. Vou pedir para a equipe te retornar com as melhores opcoes, tudo bem? 💙';
    end if;
    update public.conversations set bot_ctx=coalesce(ctx,'{}')||jsonb_build_object('modalidade',modal,'turno',turno)||ped where id=p_conv;
    msg := public.nx_book_ofertar(p_conv, true);
    if msg is null then
      update public.conversations set bot_state=null, status='aguardando_medico' where id=p_conv;
      return 'Nao achei vaga nos proximos dias. Vou pedir para a equipe te retornar, tudo bem? 💙';
    end if;
    return msg;

  elsif st='ag_offer' then
    -- 1) escolheu uma das opcoes oferecidas
    offers := ctx->'offers';
    n := nullif(regexp_replace(coalesce(p_text,''),'\D','','g'),'')::int;
    if n is not null and n between 1 and coalesce(jsonb_array_length(offers),0)
       and length(regexp_replace(coalesce(p_text,''),'\D','','g')) = 1
       and coalesce(p_text,'') !~ '[hH]' then
      o := offers->(n-1);
      modal := coalesce(ctx->>'modalidade','presencial');
      sched := ((o->>'data')||' '||(o->>'hora')||':00')::timestamp at time zone 'America/Sao_Paulo';
      select nome into nm from public.profiles where id=prof;
      aid := public.nx_appt_create_bot(cl, patid, p_conv, (select paciente_nome from public.conversations where id=p_conv), tel, nm, prof, 'Consulta', sched, modal);
      update public.conversations set bot_state=null, status='agendada' where id=p_conv;
      if modal='telemedicina' then
        return public.nx_book_confirmacao(aid, 'Prontinho! Sua *teleconsulta* com '||coalesce(nm,'o profissional')||' ficou para '||public.nx_dia_nome((o->>'dow')::int)||' '||to_char((o->>'data')::date,'DD/MM')||' as '||(o->>'hora')||'. Como e por video, o pagamento e antecipado. 💙');
      end if;
      return public.nx_book_confirmacao(aid, 'Prontinho! ✅ Sua consulta com '||coalesce(nm,'o profissional')||' ficou para '||public.nx_dia_nome((o->>'dow')::int)||' '||to_char((o->>'data')::date,'DD/MM')||' as '||(o->>'hora')||' ('||modal||'). Voce vai receber lembretes por aqui. Se precisar remarcar, e so me avisar. 💙');
    end if;

    -- 2) pediu outras opcoes
    if lower(p_text) ~ '(outro|mais op|outra|diferente|nenhum)' and public.nx_book_pedido(p_text) = '{}'::jsonb then
      msg := public.nx_book_ofertar(p_conv, false);
      return coalesce(msg, 'Por ora nao tenho outros horarios. Quer que a equipe te retorne com mais opcoes?');
    end if;

    -- 3) pediu um horario ou dia especifico ("depois das 15h", "quinta")
    ped := public.nx_book_pedido(p_text);
    if ped <> '{}'::jsonb then
      update public.conversations set bot_ctx=coalesce(ctx,'{}')||ped where id=p_conv;
      msg := public.nx_book_ofertar(p_conv, true);
      return coalesce(msg, 'Nesse horario nao tenho vaga nos proximos dias. Quer tentar outro dia ou prefere que a equipe te retorne?');
    end if;

    -- 4) nao entendi: nunca devolve a conversa para o inicio
    return 'Me diga *1* ou *2*, ou o dia e a hora que voce prefere (por exemplo: "quinta de tarde" ou "depois das 15h").';
  end if;
  return null;
end; $$;

revoke all on function public.nx_book_confirmacao(uuid,text) from public, anon, authenticated;
grant execute on function public.nx_book_confirmacao(uuid,text) to service_role;
