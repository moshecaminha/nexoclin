-- 026 - Pre-anamnese de verdade (secao 8 do documento do cliente).
-- O prefill existia, mas colava as 6 primeiras mensagens cruas do WhatsApp como
-- HDA. A triagem ja guarda tudo estruturado em collected_data - e, desde a 022,
-- marcado por paciente. Agora a Anamnese nasce escrita a partir disso, sem
-- misturar irmaos, e o medico revisa (nada e definitivo ate Finalizar).
-- ADITIVO.

create or replace function public.nx_prt_prefill_anamnese(p_patient uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  cl uuid; conv uuid; dados jsonb; hda text; qp text; ant text; med text; ale text;
  risco text; quando timestamptz; linhas text[] := array[]::text[];
  rotulos text[][] := array[
    ['inicio','Início'], ['padrao','Padrão'], ['intensidade','Intensidade'],
    ['localizacao','Local'], ['febre','Febre'], ['sintomas_associados','Sintomas associados'],
    ['fatores','Fatores'], ['historico_sintoma','Histórico'], ['red_flags','Sinais de alarme'],
    ['convenio','Convênio']
  ];
  i int; v text;
begin
  select clinic_id into cl from public.patients where id=p_patient;
  if cl is null or not (public.is_member(cl) or public.is_platform_admin()) then
    raise exception 'sem permissão';
  end if;

  -- conversa mais recente desta crianca
  select id into conv from public.conversations
   where patient_id=p_patient and status not in ('finalizada','resolvida')
   order by coalesce(updated_at,created_at) desc limit 1;
  if conv is null then
    select id into conv from public.conversations where patient_id=p_patient
     order by coalesce(updated_at,created_at) desc limit 1;
  end if;
  if conv is null then return jsonb_build_object('has',false); end if;

  -- o que a IA coletou DESTA crianca (dado antigo, sem dono, ainda vale)
  select jsonb_object_agg(chave, valor), max(created_at) into dados, quando
    from (
      select distinct on (chave) chave, valor, created_at
        from public.collected_data
       where conversation_id=conv
         and (patient_id is null or patient_id=p_patient)
         and coalesce(valor,'')<>''
       order by chave, created_at desc
    ) d;
  dados := coalesce(dados,'{}'::jsonb);

  qp  := coalesce(dados->>'motivo', dados->>'sintoma_principal');
  med := dados->>'medicacoes_uso';
  ale := dados->>'alergias';
  ant := dados->>'doencas_cronicas';
  select risk::text into risco from public.conversations where id=conv;

  -- HDA montada a partir da triagem, uma linha por informacao
  if coalesce(dados->>'sintoma_principal','')<>'' then
    linhas := linhas || ('Queixa: '||(dados->>'sintoma_principal'));
  end if;
  for i in 1..array_length(rotulos,1) loop
    v := dados->>rotulos[i][1];
    if coalesce(v,'')<>'' then linhas := linhas || (rotulos[i][2]||': '||v); end if;
  end loop;
  if coalesce(dados->>'observacoes','')<>'' then
    linhas := linhas || ('Observações: '||(dados->>'observacoes'));
  end if;

  if array_length(linhas,1) is null then
    -- Sem triagem estruturada, cair no texto cru so e seguro quando a conversa
    -- falou de UMA crianca so. Se houve irmao, nao se herda a queixa do outro.
    if exists (select 1 from public.collected_data d
                where d.conversation_id=conv and d.patient_id is not null
                  and d.patient_id <> p_patient) then
      return jsonb_build_object('has', false, 'conversation_id', conv);
    end if;
    -- sem triagem estruturada: cai para o texto do paciente, como antes
    select body into qp from public.messages
     where conversation_id=conv and direction='in' and coalesce(body,'')<>''
     order by created_at asc limit 1;
    select string_agg(body, E'\n') into hda from (
      select body from public.messages
       where conversation_id=conv and direction='in' and coalesce(body,'')<>''
       order by created_at asc limit 6) t;
  else
    hda := array_to_string(linhas, E'\n');
    if coalesce(risco,'')<>'' then
      hda := hda||E'\n'||'Risco sugerido pela triagem: '||replace(risco,'_',' ');
    end if;
    hda := hda||E'\n\n'||'(Pré-anamnese da triagem por WhatsApp em '
           ||to_char(coalesce(quando,now()) at time zone 'America/Sao_Paulo','DD/MM/YYYY HH24:MI')
           ||' - revise antes de finalizar.)';
  end if;

  return jsonb_build_object(
    'has', (coalesce(qp,'')<>'' or coalesce(hda,'')<>''),
    'qp', qp, 'hda', hda,
    'antecedentes', ant, 'medicacoes', med, 'alergias', ale,
    'risco', risco, 'conversation_id', conv);
end $$;
