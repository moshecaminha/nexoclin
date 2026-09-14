-- =====================================================================
-- Duas comunicacoes e consentimento.
--
-- Pedido do cliente (14/09):
--   - pediatrica: fala com o RESPONSAVEL sobre a crianca;
--   - geral: fala com o proprio paciente, no roteiro de clinica geral;
--   - consentimento LGPD antes de coletar dado de saude (Art. 11).
--
-- O modo sai, nesta ordem:
--   1. da especialidade do medico da conversa;
--   2. do publico-alvo da clinica (texto livre no cadastro);
--   3. pediatrico se todos os medicos ativos da clinica forem pediatras;
--   4. geral.
-- No modo geral, se a pessoa disser que e para uma crianca, a propria IA
-- passa a falar com o responsavel.
-- =====================================================================


create or replace function public.nx_conv_modo(p_conv uuid)
returns text language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_clinic uuid; v_prof uuid; v_esp text; v_pub text; n_med int; n_ped int;
begin
  select clinic_id into v_clinic from conversations where id = p_conv;
  if v_clinic is null then return 'geral'; end if;

  v_prof := public.nx_conv_doctor(p_conv);
  if v_prof is not null then
    select especialidade into v_esp from profiles where id = v_prof;
    if coalesce(trim(v_esp), '') <> '' then
      return case when v_esp ~* 'pediatr' then 'pediatria' else 'geral' end;
    end if;
  end if;

  select publico_alvo into v_pub from clinics where id = v_clinic;
  if coalesce(trim(v_pub), '') <> '' then
    return case
      when v_pub ~* '(pediatr|crian|infant|beb[eê]|adolesc)'
       and v_pub !~* '(adult|idos|geral|todas as idades|fam[ií]lia)' then 'pediatria'
      else 'geral' end;
  end if;

  select count(*), count(*) filter (where p.especialidade ~* 'pediatr')
    into n_med, n_ped
    from memberships m join profiles p on p.id = m.user_id
   where m.clinic_id = v_clinic and m.ativo and m.role = 'medico';
  return case when n_med > 0 and n_med = n_ped then 'pediatria' else 'geral' end;
end $$;


-- Registra a resposta ao consentimento. Aceite grava consent_at; recusa
-- (pedir atendente) nao grava nada de saude.
create or replace function public.nx_agent_consentir(p_conv uuid)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  update conversations set consent_at = coalesce(consent_at, now()), updated_at = now()
   where id = p_conv;
  insert into collected_data(conversation_id, chave, valor, atencao, fonte)
    select p_conv, 'consentimento', 'sim', false, 'ia'
     where not exists (select 1 from collected_data
                        where conversation_id = p_conv and chave = 'consentimento');
end $$;


-- Contexto do agente: acrescenta o modo, se ja consentiu e se a IA ja falou
-- nesta conversa (conversa que ja estava em andamento nao recebe o
-- consentimento no meio).
create or replace function public.nx_agent_contexto(p_conv uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v jsonb; v_clinic uuid; v_ativo boolean;
begin
  select clinic_id, bot_active into v_clinic, v_ativo from conversations where id = p_conv;
  if v_clinic is null then return null; end if;

  -- humano pausou ou assumiu
  if v_ativo is false then return jsonb_build_object('ativo', false); end if;

  select jsonb_build_object(
    'ativo', true,
    'status', c.status::text,
    'modo', public.nx_conv_modo(p_conv),
    'consentiu', c.consent_at is not null
                 or exists (select 1 from collected_data d
                             where d.conversation_id = p_conv and d.chave = 'consentimento'),
    'ia_ja_falou', exists (select 1 from messages m
                            where m.conversation_id = p_conv and m.direction = 'out'
                              and m.author = 'assistente'),
    'clinica', (select nome from clinics where id = v_clinic),
    'paciente_nome', c.paciente_nome,
    'paciente_idade', c.paciente_idade,
    'meses', public.nx_idade_meses(c.paciente_idade),
    'risco', c.risk::text,
    'coletado', coalesce((
      select jsonb_object_agg(d.chave, d.valor)
      from collected_data d where d.conversation_id = p_conv), '{}'::jsonb),
    'historico', coalesce((
      select jsonb_agg(jsonb_build_object('direction', m.direction::text, 'body', m.body)
                       order by m.created_at)
      from (select * from messages where conversation_id = p_conv
            and body is not null and body <> ''
            order by created_at desc limit 24) m), '[]'::jsonb)
  ) into v from conversations c where c.id = p_conv;
  return v;
end $$;


revoke all on function public.nx_conv_modo(uuid)       from public, anon, authenticated;
revoke all on function public.nx_agent_consentir(uuid) from public, anon, authenticated;
grant execute on function public.nx_conv_modo(uuid)       to service_role;
grant execute on function public.nx_agent_consentir(uuid) to service_role;
