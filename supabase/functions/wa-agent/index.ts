// supabase/functions/wa-agent/index.ts
// Agente de triagem pediatrica (OpenAI).
// MAS mantem um piso deterministico: as bandeiras vermelhas por palavra-chave
// rodam ANTES do modelo e, se disparam, o modelo nem e consultado. O agente so
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

# Encerramento
Quando tiver o suficiente, avise que encaminhou para a equipe, diga o que esperar,
e marque encaminhar_humano = true.`;

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
      },
      required: ["resposta", "dados", "risco", "encaminhar_humano"],
    },
  },
};

const MSG_EMERGENCIA =
  "🚨 Pelo que você descreveu, isso pode ser uma *emergência*.\n\n" +
  "Por favor, ligue *agora* para o SAMU *192* ou vá ao pronto-socorro mais próximo.\n\n" +
  "Já estou avisando a equipe da clínica. 💙";

/** Decide e responde. Devolve o texto a enviar, ou null se o bot deve calar. */
export async function agente(conv: string, texto: string): Promise<string | null> {
  const { data: ctx } = await sb.rpc("nx_agent_contexto", { p_conv: conv });
  if (!ctx || ctx.ativo === false) return null;

  // ---- piso deterministico: roda ANTES do modelo e vence sozinho ----
  const { data: bandeira } = await sb.rpc("nx_wa_has_redflag", {
    t: texto.toLowerCase(), p_meses: ctx.meses ?? null,
  });
  if (bandeira === true) {
    await sb.rpc("nx_agent_aplicar", {
      p_conv: conv, p_risco: "emergencia", p_encaminhar: true,
      p_dados: [{ chave: "red_flags", valor: texto.slice(0, 160), atencao: true }],
    });
    return MSG_EMERGENCIA;
  }

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

  let saida: { resposta: string; dados: any[]; risco: string; encaminhar_humano: boolean };
  try {
    saida = JSON.parse(j.choices?.[0]?.message?.content ?? "{}");
  } catch {
    console.error("agente: resposta fora do formato"); return null;
  }
  if (!saida?.resposta) { console.error("agente: sem resposta"); return null; }

  // o agente pode SUBIR o risco, nunca baixar abaixo do que ja estava
  const atual = ctx.risco ?? "nao_urgente";
  const risco = (PESO[saida.risco] ?? 1) >= (PESO[atual] ?? 1) ? saida.risco : atual;

  await sb.rpc("nx_agent_aplicar", {
    p_conv: conv, p_risco: risco,
    p_encaminhar: saida.encaminhar_humano || risco === "emergencia",
    p_dados: saida.dados ?? [],
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
