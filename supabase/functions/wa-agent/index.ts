// supabase/functions/wa-agent/index.ts
// Agente de atendimento por WhatsApp (OpenAI), com o sistema na frente.
//
// Duas comunicacoes, escolhidas por nx_conv_modo:
//   - pediatria: fala com o RESPONSAVEL sobre a crianca;
//   - geral: fala com o proprio paciente.
//
// Ordem de decisao, da mais dura para a mais livre:
//   1. confirmacao de presenca          (vale mesmo com a IA pausada)
//   2. saude mental e bandeira vermelha (valem SEMPRE, inclusive com humano)
//   3. humano pausou ou assumiu -> para aqui (so um humano desliga a IA)
//   4. agendamento, preco, cupom, modalidade, remarcacao  (banco, sem modelo)
//   5. consentimento LGPD               (conversa nova, antes de dado de saude)
//   6. triagem com o modelo, no modo da conversa
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

const PEDIATRIA = `Você é o atendimento virtual por WhatsApp de uma clínica PEDIÁTRICA no Brasil.
Acolhe, faz triagem e coleta informações para preparar o caso para o médico.

# Quem está do outro lado
Na maioria das vezes é a MÃE, o PAI ou outro responsável falando da criança.
Pegue o NOME e a IDADE da criança antes de qualquer triagem clínica: a idade muda
o que é grave. Depois disso, fale sempre da criança na terceira pessoa
("a Ana está com febre?"), nunca "você está com febre?".
Se for o próprio adolescente escrevendo, fale diretamente com ele, com cuidado.

# Checagem de segurança
Logo depois de nome e idade, pergunte se a criança está AGORA com algum destes
sinais (responder SIM ou NÃO):
• dificuldade para respirar ou peito afundando
• lábios ou rosto arroxeados
• muito molinha ou difícil de acordar
• convulsão
• manchas roxas que não somem ao apertar

A qualquer momento, classifique como emergencia e encaminhe para humano se houver:
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

# Triagem (uma pergunta por vez)
Principal sintoma; desde quando; febre (quanto e como mediu); outros sintomas;
se está bebendo líquido e fazendo xixi; doenças crônicas; remédios em uso,
inclusive o que já deu para esse quadro; alergias.
Para criança pequena, não peça nota de dor de 0 a 10: pergunte o comportamento
(brincando normal / mais quieta / muito abatida).`;

const GERAL = `Você é o atendimento virtual por WhatsApp de uma clínica médica no Brasil (atendimento geral).
Acolhe, faz triagem e coleta informações para preparar o caso para o médico.

# Quem está do outro lado
Normalmente é o próprio paciente: fale com ele diretamente ("você") e use o nome
dele quando souber. Se a pessoa disser que o atendimento é para outra pessoa
(um filho, um pai idoso), pegue o NOME e a IDADE dessa pessoa e passe a falar
dela na terceira pessoa. Se for uma criança, fale com o responsável e use os
cuidados de criança: não peça nota de 0 a 10 (pergunte o comportamento), e
qualquer febre em bebê com menos de 3 meses é emergência.

# Checagem de segurança
Antes da triagem, pergunte se a pessoa está AGORA com algum destes sinais
(responder SIM ou NÃO):
• Dor forte no peito
• Falta de ar intensa
• Boca torta ou fraqueza de um lado (AVC)
• Sangramento intenso
• Desmaio
Se SIM, ou se qualquer desses sinais aparecer depois: classifique como
emergencia, oriente ligar agora para o SAMU 192 ou ir ao pronto-socorro mais
próximo, avise que já avisou a equipe da clínica, e pare a triagem.

# Motivo do contato
Depois da checagem, pergunte como pode ajudar, com estas opções (aceite texto livre):
1) Sintoma ou mal-estar
2) Retorno / acompanhamento
3) Resultado de exame
4) Renovar receita
5) Marcar ou remarcar consulta
6) Atestado / documento
7) Dúvida (horário, endereço, convênio)

# Triagem do sintoma (uma pergunta por vez)
Principal sintoma ou incômodo; desde quando começou (hoje, há 2 dias, 1 semana);
intensidade de 0 a 10 (0 = bem leve, 10 = muito forte); febre ou outros sintomas
junto; doença crônica, medicação contínua ou alergia a remédio.

# Outros motivos
- Exame: pergunte qual; a pessoa pode mandar foto ou PDF aqui mesmo. Você não
  interpreta exame: quem avalia é o médico.
- Receita: pergunte qual medicação e dose. A renovação é sempre avaliada pelo médico.
- Atestado ou documento: pergunte qual e para quê. Documentos são emitidos e
  assinados pelo médico.
- Dúvida: responda se o contexto permitir; senão, diga que vai passar para a equipe.`;

const COMUM = `# O que você NUNCA faz
- Não diagnostica, não prescreve, não indica medicamento nem dose.
- Não interpreta exame.
- Não minimiza sintoma grave ("deve ser só uma virose" é proibido).
- Não insiste depois de duas tentativas sem entender: encaminha para humano.

# Saúde mental
Se houver menção a se machucar, ideação suicida ou desânimo profundo (de quem
escreve ou do paciente): acolha, ofereça o CVV 188 (24h, gratuito), não colete
sintomas, classifique como muito_urgente e encaminhe para humano na hora.

Se a pessoa pedir para falar com um atendente, encaminhe sem resistir.

# Como escrever
- WhatsApp: frases curtas, tom acolhedor, UMA pergunta por vez.
- Use *negrito* para destacar e quebras de linha para separar. Nada de parágrafo longo.
- No máximo um emoji por mensagem.
- Ofereça opções numeradas quando fizer sentido, mas aceite texto livre.
- Não repita o que já perguntou. Não se apresente: a abertura e o consentimento
  já foram feitos pelo sistema.
- Confirme o que entendeu antes de encerrar ("dor de garganta há 2 dias, febre 38").

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
Quando tiver o suficiente: agradeça, diga que registrou tudo e organizou as
informações para o médico, lembre que se algo piorar deve procurar o
pronto-socorro ou ligar 192, e termine oferecendo o próximo passo com exatamente:
"Posso já verificar horários para a consulta?
1) Sim, quero agendar
2) Prefiro aguardar o retorno da equipe"
Marque encaminhar_humano = true e tipo_encaminhamento = "clinico".
Se a pessoa pedir para falar com alguém, use tipo_encaminhamento = "pedido_humano".
Nos demais casos, tipo_encaminhamento = "nenhum".

# Depois de encaminhar ou agendar
Você continua respondendo até alguém da equipe assumir a conversa.
- Não recomece a triagem e não repita que encaminhou.
- Responda dúvidas, acolha e anote em "dados" qualquer informação nova.
- Se surgir sintoma novo ou piora, suba o risco.
- Nunca diga que alguém da equipe já está conversando com a pessoa.`;

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

const MSG_SAUDE_MENTAL: Record<string, string> = {
  geral:
    "Sinto muito que você esteja passando por isso, e obrigado por compartilhar. " +
    "Você não está sozinho(a). 💙\n\n" +
    "Se estiver pensando em se machucar, ligue *agora* para o *CVV 188* (24h, gratuito) " +
    "ou fale com alguém de confiança.\n\n" +
    "Já estou chamando uma pessoa da nossa equipe para falar com você.",
  pediatria:
    "Obrigado por contar. Isso é importante, e vocês não estão sozinhos. 💙\n\n" +
    "Se houver risco de alguém se machucar agora, ligue para o *CVV 188* (24h, gratuito) " +
    "ou para o *SAMU 192*, e não deixe a pessoa sozinha.\n\n" +
    "Já estou chamando uma pessoa da nossa equipe para falar com vocês.",
};

// Ideacao suicida e automutilacao. Sem negacao de proposito: na duvida, acolhe.
// "Se machucar" e "se cortou" ficam de fora: em pediatria costumam ser acidente
// ("medo de ele se machucar na escola"); o que pega e o habito ("tem se cortado").
const RE_SAUDE_MENTAL =
  /(suic[ií]d|me matar|se matar|me machucar|tirar (a )?(minha|sua) (pr[óo]pria )?vida|acabar com (a )?(minha|sua) vida|quero morrer|n[ãa]o (aguento|quero) mais viver|me cortar|me cortando|se cortando|tem se cortado|automutila)/;

// ---- consentimento LGPD ----
const MARCA_CONSENTIMENTO = "podemos começar?";
const RE_SIM =
  /^\s*(1\b|1️⃣|sim\b|s\b|pode\b|claro\b|ok\b|okay\b|vamos\b|bora\b|aceito\b|concordo\b|autorizo\b)/;
const RE_PESSOA =
  /(^\s*(2\b|2️⃣)|atendente|falar com (uma )?pessoa|falar com algu[ée]m|humano)/;

function abertura(modo: string, clinica: string | null): string {
  const nome = clinica ? `*${clinica}*` : "clínica";
  const quem = modo === "pediatria" ? "o atendimento" : "o seu atendimento";
  const lgpd = modo === "pediatria"
    ? "_Os dados são usados só para o cuidado (LGPD)._"
    : "_Seus dados são usados só para o seu cuidado (LGPD)._";
  return `Olá! 👋 Você chegou ao atendimento virtual da ${nome}.\n` +
    `Vou fazer algumas perguntinhas rápidas para já preparar ${quem} com o médico. ` +
    `Podemos começar?\n\n1️⃣ Sim, pode seguir\n2️⃣ Prefiro falar com uma pessoa\n\n${lgpd}`;
}
const MSG_CONFIRMA =
  "Só para confirmar, podemos começar? Responda *1* para seguir ou *2* para falar com uma pessoa.";
const MSG_CHAMA_EQUIPE =
  "Sem problema! Vou chamar alguém da equipe para continuar com você por aqui. 🙂";
const MSG_AGUARDA =
  "Já avisei a equipe, e alguém vai continuar com você por aqui. " +
  "Se preferir seguir comigo, é só responder *1*.";

// Gatilhos da camada do sistema. Estreitos de proposito: "ha quanto tempo" e
// "horario do remedio" sao triagem, nao preco nem agenda.
const RE_DIRETA =
  /(pre[çc]o|valor da consulta|quanto (custa|[ée]|fica|sai)|honor[áa]rio|cupom|desconto|remarc|desmarc|cancelar|teleconsulta|telemedicin|por v[ií]deo|online|presencial)/;
const RE_AGENDAR =
  /(agendar|marcar (uma )?consulta|quero marcar|hor[áa]rios? (livres?|dispon[íi]ve(l|is))|tem vaga)/;

// Cara de resposta a cada passo do agendamento. Se a mae voltou a falar do
// sintoma no meio ("39 de febre"), a triagem responde e o passo fica onde esta.
const RESPONDE_PASSO: Record<string, RegExp> = {
  ag_quem: /.+/,
  ag_prof: /(dr\.?|dra\.?|tanto faz|qualquer|indiferente|mais (cedo|pr[óo]xim)|^\D{0,12}\d{1,2}\D{0,12}$|[a-zà-ú]{3,})/,
  ag_mod: /(tele|v[ií]deo|online|presencial|^\s*[12]\s*$)/,
  // Nos dois passos de escolha o banco sempre tem resposta (entende ate
  // "depois das 15h"), entao nada aqui pode escapar para o modelo.
  ag_turno: /.+/,
  ag_offer: /.+/,
  agenda_pref: /.+/,
  ag_dia: /(amanh|hoje|segunda|ter[çc]a|quarta|quinta|sexta|s[áa]bado|domingo|\b\d{1,2}\/\d{1,2}\b|\bdia \d{1,2}\b)/,
  ag_slot: /^\D{0,12}\d{1,2}\D{0,12}$/,
};

// Passos em que ainda nao ha medico escolhido - e justamente o que se esta
// resolvendo ali, entao nao da para exigir professional_id.
const PASSO_SEM_MEDICO = new Set(["ag_quem", "ag_prof", "ag_turno", "agenda_pref"]);

// Respostas numericas as opcoes que a propria IA ofereceu e que levam a agenda.
const RE_SO_1 = /^\s*(1\b|1️⃣|sim\b)/;
const RE_SO_5 = /^\s*(5|5️⃣)\s*[).]?\s*$/;

/**
 * Quem e a familia deste telefone. Sem isso a IA pergunta o nome de quem ja e
 * paciente da casa. Cada crianca tem o seu proprio prontuario: a IA precisa
 * saber de qual delas se esta falando antes de registrar qualquer sintoma.
 */
function familia(quem: any): string {
  if (!quem?.encontrado) return "Cadastro: telefone ainda não conhecido nesta clínica\n";
  const cr = (quem.criancas ?? []).map((c: any) => c.nome).filter(Boolean);
  return `Responsável já cadastrado: ${quem.responsavel_nome ?? "sem nome"}\n` +
    (cr.length
      ? `Crianças deste responsável: ${cr.join(", ")}. ` +
        `Cumprimente pelo nome, confirme de QUAL delas se trata antes de coletar ` +
        `sintoma, e nunca misture sintomas de irmãos.\n`
      : "Ainda sem criança cadastrada para este responsável.\n");
}


/**
 * O modelo INTERPRETA, o banco DECIDE.
 *
 * Aqui o modelo so converte a frase em estrutura: dia, hora, turno, se e
 * confirmacao, qual opcao. Ele nao ve a agenda, nao escolhe horario e nao
 * escreve nada para o paciente. Se ele errar ou a chamada falhar, o banco
 * valida, descarta o impossivel e cai na leitura por regra.
 */
const ESQUEMA_PEDIDO = {
  type: "json_schema",
  json_schema: {
    name: "pedido_agenda",
    strict: true,
    schema: {
      type: "object",
      additionalProperties: false,
      required: ["data", "hora", "hora_min", "hora_max", "turno", "confirmacao", "escolha"],
      properties: {
        data: { type: ["string", "null"], description: "AAAA-MM-DD do dia pedido" },
        hora: { type: ["string", "null"], description: "HH:MM exato pedido" },
        hora_min: { type: ["string", "null"], description: "HH:MM minimo (depois das X)" },
        hora_max: { type: ["string", "null"], description: "HH:MM maximo (antes das X)" },
        turno: { type: ["string", "null"], enum: ["manha", "tarde", null] },
        confirmacao: {
          type: "boolean",
          description: "true SO quando a mensagem e apenas um aceite, sem pedir nada novo",
        },
        escolha: {
          type: ["integer", "null"],
          description: "1 ou 2 quando a pessoa escolhe uma das opcoes ja oferecidas",
        },
      },
    },
  },
} as const;

async function interpretar(
  texto: string, offers: unknown[], hoje: string,
): Promise<{ ped: Record<string, string>; conf: boolean; escolha: number | null } | null> {
  const chave = Deno.env.get("OPENAI_API_KEY");
  if (!chave) return null;

  const mesa = (offers ?? []).map((o: any, i: number) =>
    `${i + 1}) ${o?.data} as ${o?.hora}`).join("; ") || "nada oferecido ainda";

  try {
    const r = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: { Authorization: `Bearer ${chave}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        model: Deno.env.get("WA_INTERP_MODEL") ?? "gpt-4o-mini",
        temperature: 0,
        max_tokens: 200,
        response_format: ESQUEMA_PEDIDO,
        messages: [
          {
            role: "system",
            content:
              `Você converte a mensagem de um paciente sobre AGENDAMENTO em estrutura. ` +
              `Não responda ao paciente, não invente horário, não escolha por ele.
` +
              `Hoje é ${hoje} (America/Sao_Paulo). Horários já oferecidos: ${mesa}.
` +
              `Regras:
` +
              `- confirmacao = true SÓ se a mensagem for apenas aceite ("sim", "pode ser", ` +
              `"isso mesmo"). Se ela pedir qualquer coisa nova (outro dia, outro horário, ` +
              `turno), confirmacao = false.
` +
              `- escolha = 1 ou 2 só quando a pessoa aponta uma das opções já oferecidas ` +
              `("a primeira", "a de sexta").
` +
              `- data só quando houver dia claro; converta "quinta", "amanhã", "28/10".
` +
              `- "de manhã"/"de tarde" vão em turno; "depois das 15h" em hora_min; ` +
              `"antes das 10" em hora_max; "às 15h" em hora.
` +
              `- o que não estiver na mensagem vai null.`,
          },
          { role: "user", content: texto },
        ],
      }),
    });
    const j = await r.json().catch(() => ({}));
    const bruto = j?.choices?.[0]?.message?.content;
    if (!bruto) return null;
    const p = JSON.parse(bruto);

    const ped: Record<string, string> = {};
    for (const k of ["data", "hora", "hora_min", "hora_max", "turno"]) {
      if (p?.[k]) ped[k] = String(p[k]);
    }
    const escolha = Number.isInteger(p?.escolha) ? p.escolha : null;
    return { ped, conf: p?.confirmacao === true, escolha };
  } catch (e) {
    console.error("interp:", e instanceof Error ? e.message : e);
    return null;
  }
}

/** Agenda, preco, cupom, modalidade e remarcacao: responde o banco, nao o modelo. */
async function doSistema(
  conv: string, texto: string, estado: string | null, ultimaIA: string,
): Promise<string | null> {
  const t = texto.toLowerCase();

  // Quem pede agenda explicitamente recomeca o agendamento, mesmo parado num
  // passo antigo. Sem isto a conversa morria no passo e o modelo respondia
  // "vou pedir para a equipe verificar os horarios".
  if (estado && RE_AGENDAR.test(t)) {
    const { data } = await sb.rpc("nx_book_start", { p_conv: conv });
    if (data) return data;
  }

  const passo = estado ? RESPONDE_PASSO[estado] : undefined;
  if (passo) {
    if (!passo.test(t)) return null;
    // fora dos passos de escolha, sem medico definido nao ha agenda de onde
    // tirar horario
    if (!PASSO_SEM_MEDICO.has(estado!)) {
      const { data: prof } = await sb.rpc("nx_conv_doctor", { p_conv: conv });
      if (!prof) return null;
    }
    // Interpretacao pelo modelo; o banco valida e decide.
    const { data: conversa } = await sb.from("conversations")
      .select("bot_ctx").eq("id", conv).maybeSingle();
    const offers = (conversa?.bot_ctx as any)?.offers ?? [];
    const hoje = new Date().toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" });
    const lido = await interpretar(texto, offers, hoje);

    const { data } = await sb.rpc("nx_book_step_ia", {
      p_conv: conv,
      p_texto: texto,
      p_ped: lido ? lido.ped : null,
      p_conf: lido ? lido.conf : null,
      p_escolha: lido ? lido.escolha : null,
      p_origem: lido ? "modelo" : "regra",
    });
    return data ?? null;
  }

  const u = ultimaIA.toLowerCase();
  const escolheuAgenda = (u.includes("verificar horários") && RE_SO_1.test(t)) ||
    (u.includes("5) marcar") && RE_SO_5.test(t));
  if (escolheuAgenda) {
    const { data } = await sb.rpc("nx_book_start", { p_conv: conv });
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

/**
 * Consentimento LGPD. Devolve o texto a enviar, null para calar, ou undefined
 * quando a pessoa acabou de aceitar e a triagem pode seguir.
 */
async function consentimento(
  conv: string, t: string, ctx: any, falasIA: string[],
): Promise<string | null | undefined> {
  const pedidos = falasIA.filter((b) => b.toLowerCase().includes(MARCA_CONSENTIMENTO)).length;
  if (pedidos === 0) return abertura(ctx.modo ?? "geral", ctx.clinica ?? null);

  if (RE_SIM.test(t)) {
    await sb.rpc("nx_agent_consentir", { p_conv: conv });
    return undefined;
  }

  const ultima = falasIA[falasIA.length - 1] ?? "";
  const recusou = "consentimento_recusado" in (ctx.coletado ?? {});
  const chamarEquipe = async (motivo: string) => {
    if (!recusou) {
      await sb.rpc("nx_agent_aplicar", {
        p_conv: conv, p_risco: "", p_encaminhar: true,
        p_dados: [{ chave: "consentimento_recusado", valor: motivo, atencao: true }],
      });
    }
    return ultima === MSG_CHAMA_EQUIPE ? null : MSG_CHAMA_EQUIPE;
  };

  if (RE_PESSOA.test(t)) return chamarEquipe("pediu para falar com uma pessoa");
  if (recusou) return ultima === MSG_AGUARDA ? null : MSG_AGUARDA;
  if (pedidos < 2) return MSG_CONFIRMA;
  return chamarEquipe("não respondeu ao consentimento");
}

// O que a IA precisa saber do andamento para nao recomecar a triagem.
const SITUACAO: Record<string, string> = {
  aguardando_medico: "já encaminhado para a equipe, aguardando o médico",
  agendada: "consulta já agendada",
};

// Chaves que nao sao triagem: nao contam para decidir se ha triagem em andamento.
const FORA_DA_TRIAGEM = new Set(["encaminhamento", "consentimento", "consentimento_recusado"]);

/** Decide e responde. Devolve o texto a enviar, ou null se o bot deve calar. */
export async function agente(conv: string, texto: string): Promise<string | null> {
  const t = texto.toLowerCase();

  // 1) Confirmacao de presenca. Vale com a IA pausada: quem so responde
  //    "confirmo" a um lembrete precisa de retorno.
  const pediuConfirmar = /confirm/.test(t) && !/(remarc|desmarc|cancel|n[ãa]o)/.test(t);
  if (pediuConfirmar) {
    const { data: cf } = await sb.rpc("nx_appt_confirmar_paciente", { p_conv: conv });
    if (cf?.ok && cf.ja_confirmada) {
      return `Sua consulta de ${cf.quando} já está confirmada. ✅ Até lá! ` +
        "Se precisar remarcar ou cancelar, é só me avisar por aqui.";
    }
    if (cf?.ok) {
      return `Perfeito! Sua consulta de ${cf.quando} está confirmada. ✅ Até lá! ` +
        "Se precisar remarcar ou cancelar, é só me avisar por aqui.";
    }
    // Respondeu a um lembrete e nao achamos a consulta: a equipe resolve. O que
    // nao pode e cair na pergunta de consentimento, como se fosse conversa nova.
    const { data: temAppt } = await sb.from("appointments")
      .select("id").eq("conversation_id", conv).limit(1).maybeSingle();
    if (temAppt) {
      return "Não consegui localizar essa consulta agora. Já avisei a equipe para " +
        "confirmar com você por aqui. 💙";
    }
  }

  const { data: conversa } = await sb.from("conversations")
    .select("bot_state, paciente_idade").eq("id", conv).single();
  if (!conversa) return null;

  // 2) Saude mental e bandeira vermelha. Rodam ANTES da checagem de IA ativa:
  //    mesmo com a IA pausada por alguem da equipe, o aviso sai.
  const alertaRepetido = async (msg: string) => {
    const { data: ultima } = await sb.from("messages").select("body")
      .eq("conversation_id", conv).eq("direction", "out")
      .order("created_at", { ascending: false }).limit(1).maybeSingle();
    // ja mandou o alerta e ninguem falou depois: nao repete a cada mensagem
    return ultima?.body === msg;
  };

  if (RE_SAUDE_MENTAL.test(t)) {
    const { data: modo } = await sb.rpc("nx_conv_modo", { p_conv: conv });
    const msg = MSG_SAUDE_MENTAL[modo === "pediatria" ? "pediatria" : "geral"];
    await sb.rpc("nx_agent_aplicar", {
      p_conv: conv, p_risco: "muito_urgente", p_encaminhar: true,
      p_dados: [{ chave: "red_flags", valor: "saúde mental: " + texto.slice(0, 140), atencao: true }],
    });
    return (await alertaRepetido(msg)) ? null : msg;
  }

  // 2.5) Conversa parada ha mais de 12h: pergunta se e para continuar o
  //      assunto anterior ou abrir outro. So depois volta a triagem.
  const estadoConv = conversa.bot_state ?? null;
  if (estadoConv === "retomar" || estadoConv === "retomar_resp") {
    const { data: ret } = await sb.rpc("nx_conv_retomar", { p_conv: conv, p_text: texto });
    if (ret?.texto) return ret.texto;
  }

  const { data: meses } = await sb.rpc("nx_idade_meses", { p: conversa.paciente_idade ?? null });
  const { data: bandeira } = await sb.rpc("nx_wa_has_redflag", { t, p_meses: meses ?? null });
  if (bandeira === true) {
    await sb.rpc("nx_agent_aplicar", {
      p_conv: conv, p_risco: "emergencia", p_encaminhar: true,
      p_dados: [{ chave: "red_flags", valor: texto.slice(0, 160), atencao: true }],
    });
    return (await alertaRepetido(MSG_EMERGENCIA)) ? null : MSG_EMERGENCIA;
  }

  // 3) So um humano cala a IA: pausou no cockpit ou assumiu o atendimento.
  //    Encaminhar e agendar nao calam.
  const { data: ctx } = await sb.rpc("nx_agent_contexto", { p_conv: conv });
  if (!ctx || ctx.ativo === false) return null;

  const falasIA: string[] = (ctx.historico ?? [])
    .filter((m: any) => m.direction === "out")
    .map((m: any) => String(m.body ?? ""));
  const ultimaIA = falasIA[falasIA.length - 1] ?? "";

  // 4) Sistema
  const sistema = await doSistema(conv, texto, conversa.bot_state ?? null, ultimaIA);
  if (sistema) return sistema;

  // 5) Consentimento LGPD antes de coletar dado de saude. Conversa com triagem
  //    ja em andamento antes desta regra nao recebe a pergunta no meio.
  // No meio do agendamento nao se interrompe para pedir consentimento: a
  // pergunta volta quando a triagem comecar.
  // Consentimento e coisa de conversa nova. Quem ja tem consulta marcada ou
  // caso na fila nao pode receber "podemos comecar?" no meio do caminho.
  const jaEmAndamento = ["agendada", "aguardando_medico", "em_atendimento"]
    .includes(String(ctx.status ?? ""));
  const agendando = (conversa.bot_state ?? "").startsWith("ag_") || pediuConfirmar || jaEmAndamento;
  const triagemEmAndamento = Object.keys(ctx.coletado ?? {}).some((k) => !FORA_DA_TRIAGEM.has(k));
  const jaPediu = falasIA.some((b) => b.toLowerCase().includes(MARCA_CONSENTIMENTO));
  if (!ctx.consentiu && !agendando && (jaPediu || !triagemEmAndamento)) {
    const c = await consentimento(conv, t, ctx, falasIA);
    if (c !== undefined) return c;
  }

  // 6) Triagem com o modelo, no modo da conversa
  const chave = Deno.env.get("OPENAI_API_KEY");
  if (!chave) { console.error("agente: OPENAI_API_KEY ausente"); return null; }

  const historico = (ctx.historico ?? [])
    .map((m: any) => ({
      role: m.direction === "in" ? "user" : "assistant",
      content: String(m.body ?? ""),
    }))
    .filter((m: any) => m.content.length > 0);

  const instrucoes = (ctx.modo === "pediatria" ? PEDIATRIA : GERAL) + "\n\n" + COMUM;

  const contexto =
    `Clínica: ${ctx.clinica ?? "—"}\n` +
    `Paciente já identificado: ${ctx.paciente_nome ?? "ainda não"}\n` +
    `Idade: ${ctx.paciente_idade ?? "ainda não"}\n` +
    familia(ctx.quem) +
    `Já coletado: ${JSON.stringify(ctx.coletado ?? {})}\n` +
    `Situação: ${SITUACAO[ctx.status ?? ""] ?? "em triagem"}`;

  const r = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${chave}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: MODELO,
      temperature: 0.3,
      max_tokens: 800,
      response_format: FORMATO,
      messages: [
        { role: "system", content: instrucoes },
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

  // Encaminhar nunca desliga a IA (so um humano desliga). Administrativo
  // (valor, confirmar horario) nem move a fila: so pede atencao da equipe.
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
