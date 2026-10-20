-- Contexto da conversa para o agente.
--
-- 1) Porteiro: num numero compartilhado (coexistencia / uazapi) a primeira
--    mensagem de cada contato e classificada antes de a IA falar:
--    paciente | pessoal | duvida. Fica gravado para nao reclassificar.
alter table public.conversations
  add column if not exists contexto_tipo   text,
  add column if not exists contexto_motivo text;

-- 2) Historico do agente: quem falou (IA, equipe, sistema) e o que foi
--    mandado em midia (descricao da foto, transcricao do audio, nome do
--    arquivo). Antes a midia sumia do historico e a fala do medico aparecia
--    como se fosse da IA.
create or replace function public.nx_agent_contexto(p_conv uuid)
 returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v jsonb; v_clinic uuid; v_ativo boolean; v_pid uuid;
begin
  select clinic_id, bot_active, patient_id into v_clinic, v_ativo, v_pid
    from conversations where id = p_conv;
  if v_clinic is null then return null; end if;
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
    'quem', public.nx_conv_quem(p_conv),
    'paciente_cadastrado', c.patient_id is not null,
    'paciente_nome', c.paciente_nome,
    'paciente_idade', c.paciente_idade,
    'responsavel_nome', c.responsavel_nome,
    'meses', public.nx_idade_meses(c.paciente_idade),
    'risco', c.risk::text,
    'coletado', coalesce((
      select jsonb_object_agg(d.chave, d.valor)
      from collected_data d
      where d.conversation_id = p_conv
        and (v_pid is null or d.patient_id is null or d.patient_id = v_pid)), '{}'::jsonb),
    'historico', coalesce((
      select jsonb_agg(jsonb_build_object('direction', m.direction::text, 'author', m.author, 'body', m.texto)
                       order by m.created_at)
      from (select created_at, direction, author,
                   coalesce(case when type::text <> 'text' and nullif(transcript,'') is not null
                                 then transcript || coalesce(' Legenda: ' || nullif(nullif(body,''), transcript), '')
                            end,
                            nullif(body,''), nullif(transcript,''),
                            case type::text
                              when 'image' then '[foto]' when 'video' then '[vídeo]'
                              when 'audio' then '[áudio]' when 'document' then '[arquivo]'
                              when 'sticker' then '[figurinha]' else null end) as texto
              from messages where conversation_id = p_conv
             order by created_at desc limit 30) m
      where m.texto is not null), '[]'::jsonb)
  ) into v from conversations c where c.id = p_conv;
  return v;
end $function$;
