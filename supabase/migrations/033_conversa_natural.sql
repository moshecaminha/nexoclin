-- 033 - Menos "Responda 1 ou 2", mais conversa.
-- A oferta saia como formulario numerado e repetia o nome completo do medico
-- ("Rafael Médico") a cada linha. Agora a IA oferece em frase, usa o primeiro
-- nome e aceita a resposta do jeito que a pessoa fala: "pode ser", "quinta",
-- "as 15h", "a primeira". Quando o que a pessoa diz casa com um horario que ja
-- esta na mesa, marca direto, em vez de reoferecer a mesma coisa.
-- ADITIVO.

-- Primeiro nome do profissional, para a conversa nao ficar formal demais.
create or replace function public.nx_doc_primeiro_nome(p_prof uuid)
returns text language sql stable security definer set search_path to 'public' as $$
  select coalesce(nullif(split_part(btrim(nome),' ',1),''),'o profissional')
    from public.profiles where id=p_prof;
$$;

-- Data e hora em portugues corrido: "quinta, 24/09, as 15h"
create or replace function public.nx_quando_txt(p_data date, p_hora text)
returns text language sql immutable set search_path to 'public' as $$
  select public.nx_dia_nome(extract(dow from p_data)::int)||' ('||to_char(p_data,'DD/MM')||') as '||
         case when right(p_hora,2)='00' then left(p_hora,2)||'h' else replace(p_hora,':','h') end;
$$;

create or replace function public.nx_book_ofertar(p_conv uuid, p_reset_shown boolean default false)
returns text language plpgsql security definer set search_path to 'public' as $$
declare ctx jsonb; prof uuid; nm text; offers jsonb; shown text[]; msg text;
        modal text; turno text; hmin text; hmax text; hora text; alvo date; cabeca text; qtd int;
        a jsonb; b jsonb;
begin
  select bot_ctx, professional_id into ctx, prof from public.conversations where id=p_conv;
  prof := coalesce(prof, public.nx_conv_doctor(p_conv));
  modal := coalesce(ctx->>'modalidade','presencial');
  turno := ctx->>'turno'; hmin := ctx->>'hora_min'; hmax := ctx->>'hora_max'; hora := ctx->>'hora';
  alvo  := nullif(ctx->>'data','')::date;
  nm := public.nx_doc_primeiro_nome(prof);

  offers := public.nx_agenda_slots_filtro(prof, modal, turno,
              case when p_reset_shown then '[]'::jsonb else coalesce(ctx->'shown','[]'::jsonb) end,
              hmin, hmax, alvo, hora);
  cabeca := null;

  if jsonb_array_length(offers)=0 and hora is not null and alvo is not null then
    offers := public.nx_agenda_slots_filtro(prof, modal, null, '[]'::jsonb, hora, null, alvo, null);
    if jsonb_array_length(offers) > 0 then cabeca := 'Nesse dia nao tenho esse horario. '; end if;
  end if;
  if jsonb_array_length(offers)=0 and hora is not null then
    offers := public.nx_agenda_slots_filtro(prof, modal, null, '[]'::jsonb, hora, null, null, null);
    if jsonb_array_length(offers) > 0 then cabeca := 'Nao tenho esse horario. '; end if;
  end if;
  if jsonb_array_length(offers)=0 and (hmin is not null or hmax is not null or turno is not null) then
    offers := public.nx_agenda_slots_filtro(prof, modal, null, '[]'::jsonb, hmin, null, null, null);
    if jsonb_array_length(offers) > 0 then cabeca := 'Nesse horario nao tenho vaga. '; end if;
  end if;
  if jsonb_array_length(offers)=0 then
    offers := public.nx_agenda_slots_filtro(prof, modal, null, '[]'::jsonb, null, null, null, null);
    if jsonb_array_length(offers)=0 then return null; end if;
    cabeca := 'Nao achei vaga no que voce pediu. ';
  end if;

  qtd := jsonb_array_length(offers);
  a := offers->0; b := offers->1;
  shown := array(select jsonb_array_elements_text(coalesce(ctx->'shown','[]'::jsonb)));
  shown := shown || (a->>'data');
  if qtd > 1 then shown := shown || (b->>'data'); end if;

  if qtd = 1 then
    msg := coalesce(cabeca,'')||'Tenho *'||public.nx_quando_txt((a->>'data')::date, a->>'hora')||
           '* com '||nm||'. Serve para voce?';
  else
    msg := coalesce(cabeca,'')||'Posso marcar com '||nm||' *'||
           public.nx_quando_txt((a->>'data')::date, a->>'hora')||'* ou *'||
           public.nx_quando_txt((b->>'data')::date, b->>'hora')||'*. Qual prefere?';
  end if;

  update public.conversations set
    bot_ctx = coalesce(ctx,'{}') || jsonb_build_object('offers',offers,'shown',to_jsonb(shown)),
    bot_state = 'ag_offer'
  where id=p_conv;
  return msg;
end; $$;

-- O que a pessoa pediu casa com alguma opcao ja oferecida?
-- Devolve o indice (1 ou 2), 0 quando casa com mais de uma, null quando nenhuma.
create or replace function public.nx_book_casa_oferta(p_offers jsonb, p_ped jsonb)
returns int language plpgsql immutable set search_path to 'public' as $$
declare i int; o jsonb; achou int := null; n int := 0;
begin
  if p_offers is null or p_ped is null or p_ped = '{}'::jsonb then return null; end if;
  for i in 0..coalesce(jsonb_array_length(p_offers),0)-1 loop
    o := p_offers->i;
    if (p_ped->>'data' is null or p_ped->>'data' = o->>'data')
       and (p_ped->>'hora' is null or p_ped->>'hora' = o->>'hora')
       and (p_ped->>'hora_min' is null or o->>'hora' >= p_ped->>'hora_min')
       and (p_ped->>'hora_max' is null or o->>'hora' <= p_ped->>'hora_max')
       and (p_ped->>'turno' is null
            or (p_ped->>'turno'='manha' and (o->>'hora') < '12:00')
            or (p_ped->>'turno'='tarde' and (o->>'hora') >= '12:00'))
    then n := n + 1; achou := i + 1;
    end if;
  end loop;
  if n = 0 then return null; end if;
  if n > 1 then return 0; end if;
  return achou;
end; $$;

create or replace function public.nx_book_step_agenda(p_conv uuid, p_text text)
returns text language plpgsql security definer set search_path to 'public' as $$
declare st text; ctx jsonb; prof uuid; cl uuid; tel text; nm text; patid uuid; modal text; turno text;
        offers jsonb; o jsonb; n int; aid uuid; sched timestamptz; msg text;
        meds jsonb; m jsonb; qtd int; ped jsonb; esc int; casa int;
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
    ped := public.nx_book_pedido(p_text);
    modal := coalesce(ctx->>'modalidade','presencial');
    turno := coalesce(ped->>'turno', case when ped ? 'hora' or ped ? 'hora_min' then null else 'qualquer' end);
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
    ped := public.nx_book_pedido(p_text);
    esc := public.nx_book_escolha(p_text, qtd);
    casa := public.nx_book_casa_oferta(offers, ped);

    -- "quinta" quando quinta ja esta na mesa: marca, nao reoferece
    if esc is null and casa is not null and casa > 0 then esc := casa; end if;

    -- casou com as duas ("as 15h" e ambas sao 15h): pergunta o dia
    if esc is null and casa = 0 then
      return 'Nos dois dias tenho esse horario: '||
             public.nx_quando_txt((offers->0->>'data')::date, offers->0->>'hora')||' ou '||
             public.nx_quando_txt((offers->1->>'data')::date, offers->1->>'hora')||'. Qual deles?';
    end if;

    if esc is null and ped <> '{}'::jsonb then
      update public.conversations set
        bot_ctx = (coalesce(ctx,'{}') - 'hora' - 'hora_min' - 'hora_max' - 'data' - 'turno' - 'shown') || ped
       where id=p_conv;
      msg := public.nx_book_ofertar(p_conv, true);
      return coalesce(msg, 'Nao tenho vaga nesse horario nos proximos dias. Quer que a equipe te retorne?');
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

    if lower(p_text) ~ '(outro|mais op|outra|diferente|nenhum)' then
      msg := public.nx_book_ofertar(p_conv, false);
      return coalesce(msg, 'Por ora nao tenho outros horarios. Quer que a equipe te retorne com mais opcoes?');
    end if;

    if qtd > 1 and lower(coalesce(p_text,'')) ~ '(sim|pode|serve|ok|beleza|fechado|isso|claro|quero)' then
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

-- A pergunta do profissional tambem usa o primeiro nome.
create or replace function public.nx_book_pergunta_prof(p_clinic uuid)
returns text language plpgsql stable security definer set search_path to 'public' as $$
declare meds jsonb; m jsonb; nomes text[] := array[]::text[]; i int := 0;
begin
  meds := public.nx_book_medicos(p_clinic);
  for m in select * from jsonb_array_elements(meds) loop
    i := i + 1;
    nomes := nomes || (split_part(btrim(m->>'nome'),' ',1));
  end loop;
  if i = 0 then return 'Vou pedir para a equipe te passar os horarios, tudo bem?'; end if;
  if i = 1 then return 'Vamos agendar com '||nomes[1]||'. Voce prefere de *manha* ou a *tarde*?'; end if;
  return 'Voce prefere com *'||array_to_string(nomes[1:i-1], '*, *')||'* ou *'||nomes[i]||
         '*? Se tanto faz, digo o horario mais proximo.';
end; $$;

revoke all on function public.nx_doc_primeiro_nome(uuid) from public, anon, authenticated;
revoke all on function public.nx_book_casa_oferta(jsonb,jsonb) from public, anon, authenticated;
grant execute on function public.nx_doc_primeiro_nome(uuid) to service_role;
grant execute on function public.nx_book_casa_oferta(jsonb,jsonb) to service_role;
grant execute on function public.nx_quando_txt(date,text) to service_role;

-- nx_book_start tambem passa a usar o primeiro nome.
create or replace function public.nx_book_start(p_conv uuid)
returns text language plpgsql security definer set search_path to 'public' as $$
declare prof uuid; cl uuid; nm text; mods jsonb; meds jsonb; pac text; st text;
begin
  select clinic_id, paciente_nome, bot_state into cl, pac, st from public.conversations where id=p_conv;

  if coalesce(pac,'') = '' or lower(pac) in ('paciente','paciente whatsapp') then
    if coalesce(st,'') <> 'ag_quem' then
      update public.conversations set bot_state='ag_quem' where id=p_conv;
    end if;
    return public.nx_book_pergunta_quem(p_conv);
  end if;

  prof := public.nx_conv_doctor(p_conv);
  if prof is null then
    meds := public.nx_book_medicos(cl);
    if jsonb_array_length(meds) = 0 then
      update public.conversations set bot_state=null, status='aguardando_medico' where id=p_conv;
      return 'Ainda nao tenho a agenda deste consultorio aberta por aqui. Vou pedir para a equipe te retornar com os horarios, tudo bem? 💙';
    elsif jsonb_array_length(meds) = 1 then
      prof := (meds->0->>'id')::uuid;
    else
      update public.conversations set bot_state='ag_prof', bot_ctx='{}'::jsonb where id=p_conv;
      return public.nx_book_pergunta_prof(cl);
    end if;
  end if;

  perform public.nx_conv_set_doctor(p_conv, prof);
  nm := public.nx_doc_primeiro_nome(prof);
  mods := public.nx_doc_modalidades(prof);
  if (mods->>'presencial')::boolean and (mods->>'telemedicina')::boolean then
    update public.conversations set bot_state='ag_mod', bot_ctx='{}'::jsonb where id=p_conv;
    return 'Vamos agendar com '||nm||'. Voce prefere *presencial* ou *telemedicina* (video)?';
  else
    update public.conversations set bot_state='ag_turno',
      bot_ctx=jsonb_build_object('modalidade', case when (mods->>'telemedicina')::boolean then 'telemedicina' else 'presencial' end)
     where id=p_conv;
    return 'Vamos agendar com '||nm||'. Voce prefere de *manha* ou a *tarde*?';
  end if;
end; $$;
