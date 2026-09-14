// supabase/functions/wa-agent/index.ts
// Agente de triagem pediatrica (OpenAI), com o sistema na frente.
//
// Ordem de decisao, da mais dura para a mais livre:
//   1. confirmacao de presenca          (vale mesmo com a IA calada)
//   2. bandeira vermelha                (vale SEMPRE, inclusive com humano)
//   3. IA calada -> para aqui
//   4. agendamento, preco, cupom, modalidade, remarcacao  (banco, sem modelo)
//   5. triagem com o modelo
// O modelo nunca informa horario, valor nem reserva: isso vem do banco. E so
// pode SUBIR a gravidade, nunca baixar.
import { createClient } from "npm:@supabase/supabase-js@2";

const sb = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const MODELO = Deno.env.get("WA_AGENT_MODEL") ?? "gpt-4o";

const PESO: Record<string, number> = {
  emergencia: 5, muito_urgente: 4, urgente: 3, pouco_urgente: 2, nao_urgente: 1,
};

const INSTRUCOES = `Você é o atendimento virtual por WhatsApp de uma clínica PEDIÁTRICA no Brasil.

# O que você faz
Acolhe, faz triagem e coleta informações para preparar o caso para o médico.

# O que você NUNCA faz
- Não diagnostica, não prescreve, não indica medicamento nem dose.
- Não interpreta exame.
- Não minimiza sintoma grave ("deve ser só uma virose" é proibido).
- Não insiste depois de duas tentativas sem entender: encaminha para humano.

# Quem está do outro lado
Na maioria das vezes é a MÃE ou o PAI falando de um filho, não o próprio paciente.
Descubra cedo: o atendimento é para a pessoa que escreve ou para outra?
Se for para uma criança, pegue o NOME e a IDADE antes de qualquer triagem clínica —
a idade muda o que é grave. Depois disso, fale sempre do paciente na terceira
pessoa ("a Ana está com febre?"), nunca "você está com febre?".

# Segurança (o mais importante)
Encaminhe para humano IMEDIATAMENTE e classifique como emergencia se houver:
- dificuldade respiratória, peito afundando, respiração muito rápida
- lábios ou rosto arroxeados
- criança muito molinha, difícil de acordar, gemendo
- convulsão
- manchas roxas que não somem ao pressionar
- sangramento intenso, trauma grave
- desidratação (sem urinar há muitas horas, boca seca, sem lágrimas)
- QUALQUER febre em bebê com menos de 3 meses
- recusa total de mamar ou beber

Nesses casos oriente ligar para o SAMU 192 ou ir ao pronto-socorro, avise que
está chamando a equipe, e pare a triagem.

Se houver menção a se machucar, ideação suicida ou desânimo profundo (do
responsável ou do adolescente): acolha, ofereça o CVV 188, não colete sintomas,
e encaminhe para humano na hora.

Se a pessoa pedir para falar com um atendente, encaminhe sem resistir.

# Como escrever
- WhatsApp: frases curtas, tom acolhedor, UMA pergunta por vez.
- Use *negrito* para destacar e quebras de linha para separar. Nada de parágrafo longo.
- Ofereça opções numeradas quando fizer sentido, mas aceite texto livre.
- Não repita o que já perguntou. Não se apresente de novo no meio da conversa.
- Confirme o que entendeu antes de encerrar ("dor de garganta há 2 dias, febre 38").
- Para criança pequena, não pergunte nota de dor de 0 a 10: pergunte comportamento
  (brincando normal / mais quieta / muito abatida).

# O que coletar (use estas chaves exatas em "dados")
tipo_paciente, paciente_nome, paciente_idade, responsavel_nome, motivo,
sintoma_principal, inicio, padrao, intensidade, localizacao, fatores, febre,
sintomas_associados, historico_sintoma, doencas_cronicas, medicacoes_uso,
alergias, red_flags, risco_sugerido, especialidade_sugerida, observacoes,
exame_tipo, medicacao_solicitada, documento_tipo, preferencia, convenio

Só inclua uma chave quando tiver a informação. Não invente.

# Risco
Classifique de forma conservadora — na dúvida, suba o nível.
emergencia | muito_urgente | urgente | pouco_urgente | nao_urgente

# Agenda, valores e reservas
Horários, valores, cupons e reservas são respondidos pelo sistema, não por você.
- Nunca diga que um horário está reservado, marcado ou confirmado.
- Nunca informe valor de consulta.
Se a pessoa pedir isso, diga que vai pedir para a equipe confirmar e marque
tipo_encaminhamento = "administrativo". Isso NÃO encerra a triagem: se ela
voltar a falar de sintoma, continue acolhendo e perguntando.

# Encerramento
Quando tiver o suficiente, avise que encaminhou para a equipe, diga o que esperar,
e marque encaminhar_humano = true e tipo_encaminhamento = "clinico".
Se a pessoa pedir para falar com alguém, use tipo_encaminhamento = "pedido_humano".
Nos demais casos, tipo_encaminhamento = "nenhum".`;

// Structured output: o modelo e obrigado a devolver exatamente este formato.
const FORMATO = {
  type: "json_schema",
  json_schema: {
    name: "triagem",
    strict: true,
    schema: {
      type: "object",
      additionalProperties: false,
      properties: {
        resposta: { type: "string", description: "A mensagem a enviar no WhatsApp." },
        dados: {
          type: "array",
          description: "Informações apuradas nesta mensagem. Vazio se nada novo.",
          items: {
            type: "object",
            additionalProperties: false,
            properties: {
              chave: { type: "string" },
              valor: { type: "string" },
              atencao: { type: "boolean" },
            },
            required: ["chave", "valor", "atencao"],
          },
        },
        risco: {
          type: "string",
          enum: ["emergencia", "muito_urgente", "urgente", "pouco_urgente", "nao_urgente"],
        },
        encaminhar_humano: { type: "boolean" },
        tipo_encaminhamento: {
          type: "string",
          enum: ["nenhum", "clinico", "administrativo", "pedido_humano"],
        },
      },
      required: ["resposta", "dados", "risco", "encaminhar_humano", "tipo_encaminhamento"],
    },
  },
};

const MSG_EMERGENCIA =
  "🚨 Pelo que você descreveu, isso pode ser uma *emergência*.\n\n" +
  "Por favor, ligue *agora* para o SAMU *192* ou vá ao pronto-socorro mais próximo.\n\n" +
  "Já estou avisando a equipe da clínica. 💙";

// Gatilhos da camada do sistema. Estreitos de proposito: "ha quanto tempo" e
// "horario do remedio" sao triagem, nao preco nem agenda.
const RE_DIRETA =
  /(pre[çc]o|valor da consulta|quanto (custa|[ée]|fica|sai)|honor[áa]rio|cupom|desconto|remarc|desmarc|cancelar|teleconsulta|telemedicin|por v[ií]deo|online|presencial)/;
const RE_AGENDAR =
  /(agendar|marcar (uma )?consulta|quero marcar|hor[áa]rios? (livres?|dispon[íi]ve(l|is))|tem vaga)/;

// Cara de resposta a cada passo do agendamento. Se a mae voltou a falar do
// sintoma no meio ("39 de febre"), a triagem responde e o passo fica onde esta.
const RESPONDE_PASSO: Record<string, RegExp> = {
  ag_mod: /(tele|v[ií]deo|online|presencial|^\s*[12]\s*$)/,
  ag_dia: /(amanh|hoje|segunda|ter[çc]a|quarta|quinta|sexta|s[áa]bado|domingo|\b\d{1,2}\/\d{1,2}\b|\bdia \d{1,2}\b)/,
  ag_slot: /^\D{0,12}\d{1,2}\D{0,12}$/,
};

/** Agenda, preco, cupom, modalidade e remarcacao: responde o banco, nao o modelo. */
async function doSistema(conv: string, texto: string, estado: string | null): Promise<string | null> {
  const t = texto.toLowerCase();

  const passo = estado ? RESPONDE_PASSO[estado] : undefined;
  if (passo) {
    if (!passo.test(t)) return null;
    // sem medico definido nao ha agenda de onde tirar horario
    const { data: prof } = await sb.rpc("nx_conv_doctor", { p_conv: conv });
    if (!prof) return null;
    const { data } = await sb.rpc("nx_book_step", { p_conv: conv, p_text: texto });
    return data ?? null;
  }

  if (!RE_DIRETA.test(t) && !RE_AGENDAR.test(t)) return null;
  const { data: ai } = await sb.rpc("nx_ai_answer", { p_conv: conv, p_texto: texto });
  if (ai?.matched && ai.intent !== "agenda") return ai.answer ?? null;
  if (ai?.intent === "agenda" || RE_AGENDAR.test(t)) {
    const { data } = await sb.rpc("nx_book_start", { p_conv: conv });
    return data ?? null;
  }
  return null;
}

/** Decide e responde. Devolve o texto a enviar, ou null se o bot deve calar. */
export async function agente(conv: string, texto: string): Promise<string | null> {
  const t = texto.toLowerCase();

  // 1) Confirmacao de presenca. Vale com a IA calada: depois de agendar a
  //    conversa fica "agendada", e quem so responde "confirmo" precisa de retorno.
  if (/confirm/.test(t) && !/(remarc|desmarc|cancel|n[ãa]o)/.test(t)) {
    const { data: cf } = await sb.rpc("nx_appt_confirmar_paciente", { p_conv: conv });
    if (cf?.ok) {
      return `Perfeito! Sua consulta de ${cf.quando} está confirmada. ✅ Até lá! ` +
        "Se precisar remarcar ou cancelar, é só me avisar por aqui.";
    }
  }

  const { data: conversa } = await sb.from("conversations")
    .select("bot_state, paciente_idade").eq("id", conv).single();
  if (!conversa) return null;

  // 2) Bandeira vermelha. Roda ANTES da checagem de IA ativa: depois de uma
  //    transferencia a IA cala, mas "ele esta convulsionando" nao pode cair
  //    no vazio enquanto ninguem da equipe assumiu.
  const { data: meses } = await sb.rpc("nx_idade_meses", { p: conversa.paciente_idade ?? null });
  const { data: bandeira } = await sb.rpc("nx_wa_has_redflag", { t, p_meses: meses ?? null });
  if (bandeira === true) {
    await sb.rpc("nx_agent_aplicar", {
      p_conv: conv, p_risco: "emergencia", p_encaminhar: true,
      p_dados: [{ chave: "red_flags", valor: texto.slice(0, 160), atencao: true }],
    });
    // ja mandou o alerta e ninguem falou depois: nao repete a cada mensagem
    const { data: ultima } = await sb.from("messages").select("body")
      .eq("conversation_id", conv).eq("direction", "out")
      .order("created_at", { ascending: false }).limit(1).maybeSingle();
    return ultima?.body === MSG_EMERGENCIA ? null : MSG_EMERGENCIA;
  }

  // 3) IA calada: humano assumiu ou a triagem clinica foi encaminhada
  const { data: ctx } = await sb.rpc("nx_agent_contexto", { p_conv: conv });
  if (!ctx || ctx.ativo === false) return null;

  // 4) Sistema
  const sistema = await doSistema(conv, texto, conversa.bot_state ?? null);
  if (sistema) return sistema;

  // 5) Triagem com o modelo

  const chave = Deno.env.get("OPENAI_API_KEY");
  if (!chave) { console.error("agente: OPENAI_API_KEY ausente"); return null; }

  const historico = (ctx.historico ?? [])
    .map((m: any) => ({
      role: m.direction === "in" ? "user" : "assistant",
      content: String(m.body ?? ""),
    }))
    .filter((m: any) => m.content.length > 0);

  const contexto =
    `Clínica: ${ctx.clinica ?? "—"}\n` +
    `Paciente já identificado: ${ctx.paciente_nome ?? "ainda não"}\n` +
    `Idade: ${ctx.paciente_idade ?? "ainda não"}\n` +
    `Já coletado: ${JSON.stringify(ctx.coletado ?? {})}`;

  const r = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${chave}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: MODELO,
      temperature: 0.3,
      max_tokens: 800,
      response_format: FORMATO,
      messages: [
        { role: "system", content: INSTRUCOES },
        { role: "system", content: contexto },
        ...historico,
        { role: "user", content: texto },
      ],
    }),
  });

  const j = await r.json().catch(() => ({}));
  if (!r.ok) { console.error("agente: OpenAI recusou", JSON.stringify(j?.error ?? j)); return null; }

  let saida: {
    resposta: string; dados: any[]; risco: string;
    encaminhar_humano: boolean; tipo_encaminhamento?: string;
  };
  try {
    saida = JSON.parse(j.choices?.[0]?.message?.content ?? "{}");
  } catch {
    console.error("agente: resposta fora do formato"); return null;
  }
  if (!saida?.resposta) { console.error("agente: sem resposta"); return null; }

  // o agente pode SUBIR o risco, nunca baixar abaixo do que ja estava
  const atual = ctx.risco ?? "nao_urgente";
  const risco = (PESO[saida.risco] ?? 1) >= (PESO[atual] ?? 1) ? saida.risco : atual;

  // Administrativo (valor, confirmar horario) avisa a equipe mas nao cala a
  // IA: a pessoa pode voltar a falar do sintoma logo em seguida.
  const administrativo = saida.tipo_encaminhamento === "administrativo" && risco !== "emergencia";
  await sb.rpc("nx_agent_aplicar", {
    p_conv: conv, p_risco: risco,
    p_encaminhar: saida.encaminhar_humano || administrativo || risco === "emergencia",
    p_dados: saida.dados ?? [],
    p_manter_bot: administrativo,
  });

  return saida.resposta;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });

  // Esta funcao roda com verify_jwt desligado (o webhook e o cron precisam
  // chamar sem sessao de usuario). Sem isto, qualquer um que descubra a URL
  // conduz o bot de qualquer conversa.
  const segredo = Deno.env.get("WA_INTERNAL_SECRET");
  if (segredo && req.headers.get("x-nx-internal") !== segredo) {
    return new Response("forbidden", { status: 403 });
  }

  try {
    const { conversation_id, texto } = await req.json();
    if (!conversation_id || !texto) {
      return Response.json({ erro: "conversation_id e texto obrigatórios" }, { status: 400 });
    }
    const r = await agente(conversation_id, texto);
    return Response.json({ ok: true, resposta: r });
  } catch (e) {
    console.error("wa-agent:", e instanceof Error ? e.message : e);
    return Response.json({ erro: String(e) }, { status: 500 });
  }
});
