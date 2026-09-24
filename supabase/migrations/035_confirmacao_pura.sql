-- 035 - Confirmacao so vale se for SO confirmacao.
-- No teste: a IA ofereceu segunda (28/09) as 08h e a pessoa respondeu
-- "pode ser a tarde ?". O "pode ser" casou com a confirmacao e a consulta foi
-- marcada as 08h - o oposto do que ela pediu, e sem consentimento real.
--
-- Regra, que vale mesmo depois da reforma do interpretador:
--   1. Mensagem que traz restricao nova (dia, hora, turno) NUNCA e confirmacao.
--      Ou ela casa com um horario ja oferecido, e ai marca esse; ou e pedido
--      novo, e ai reoferece.
--   2. Fora do horizonte da agenda, diz a verdade ("so tenho agenda aberta ate
--      DD/MM") em vez de "nao tenho esse horario".
-- ADITIVO.

-- Ate quando a agenda e procurada (mesmo horizonte do nx_agenda_slots_filtro).
create or replace function public.nx_agenda_horizonte()
returns date language sql stable set search_path to 'public' as $$
  select ((now() at time zone 'America/Sao_Paulo')::date + 21);
$$;

create or replace function public.nx_book_step_agenda(p_conv uuid, p_text text)
returns text language plpgsql security definer set search_path to 'public' as $$
declare st text; ctx jsonb; prof uuid; cl uuid; tel text; nm text; patid uuid; modal text; turno text;
        offers jsonb; o jsonb; n int; aid uuid; sched timestamptz; msg text;
        meds jsonb; m jsonb; qtd int; ped jsonb; esc int; casa int; alvo date;
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
    ped := public.nx_book_pedido(p_text);
    esc := public.nx_book_escolha(p_text, qtd);
    casa := public.nx_book_casa_oferta(offers, ped);

    -- REGRA: quem traz restricao nova nao esta confirmando.
    -- So marca sem um "sim" quando a pessoa nomeou o horario INTEIRO
    -- ("quinta 15h"). Pedido parcial ("a tarde", "quinta") reoferece e pergunta:
    -- 12h ate cabe em "a tarde", mas ninguem disse que aceita as 12h.
    if ped <> '{}'::jsonb then
      esc := null;
      if casa is not null and casa > 0 and ped ? 'hora' and ped ? 'data' then
        esc := casa;                        -- horario inteiro, e esta na mesa
      elsif casa = 0 then
        return 'Nos dois dias tenho esse horario: '||
               public.nx_quando_txt((offers->0->>'data')::date, offers->0->>'hora')||' ou '||
               public.nx_quando_txt((offers->1->>'data')::date, offers->1->>'hora')||'. Qual deles?';
      end if;
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

    -- pedido novo (inclusive o "pode ser a tarde?" do exemplo)
    if ped <> '{}'::jsonb then
      alvo := nullif(ped->>'data','')::date;
      if alvo is not null and alvo > public.nx_agenda_horizonte() then
        return 'A agenda aberta vai ate *'||to_char(public.nx_agenda_horizonte(),'DD/MM')||
               '*, entao ainda nao consigo marcar em '||to_char(alvo,'DD/MM')||
               '. Quer um horario antes disso, ou prefere que a equipe te avise quando abrir?';
      end if;
      -- O pedido novo substitui SO o que ele traz. "pode ser a tarde?" sobre
      -- "segunda dia 28" continua sendo segunda dia 28, agora a tarde - e nao
      -- volta para o comeco da agenda.
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

grant execute on function public.nx_agenda_horizonte() to service_role;
