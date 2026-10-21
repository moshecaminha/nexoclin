// supabase/functions/wa-agent/index.ts
// Agente de atendimento por WhatsApp (OpenAI), com o sistema na frente.
//
// Duas comunicacoes, escolhidas por nx_conv_modo:
//   - pediatria: fala com o RESPONSAVEL sobre a crianca;
//   - geral: fala com o proprio paciente.
//
// Ordem de decisao, da mais dura para a mais livre:
//   0. porteiro: num numero compartilhado com o celular do medico, o primeiro
//      contato e classificado (paciente / pessoal / duvida) antes de a IA falar
//   1. confirmacao de presenca          (vale mesmo com a IA pausada)
//   2. saude mental e bandeira vermelha (valem SEMPRE, inclusive com humano)
//   3. humano pausou ou assumiu -> para aqui (so um humano desliga a IA)
//   4. agendamento, preco, cupom, modalidade, remarcacao  (banco, sem modelo)
//   5. consentimento LGPD               (conversa nova, antes de dado de saude)
//   6. triagem com o modelo, no modo da conversa
// O modelo nunca informa horario, valor nem reserva: isso vem do banco. E so
// pode SUBIR a gravidade, nunca baixar.
import { createClient } from "npm:@supabase/supabase-js@2";
import { historicoZernio, type FalaHistorico } from "../_shared/canal.ts";

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
Depois da checagem de segurança, descubra a queixa principal e classifique-a em
uma das CATEGORIAS DA QUEIXA (campo "categoria"). Faça as primeiras perguntas
da categoria, na ordem, pulando o que a pessoa já respondeu. Depois delas, se
ainda faltar: doenças crônicas; remédios em uso, inclusive o que já deu para
esse quadro; alergias.
Para criança pequena, não peça nota de dor de 0 a 10: pergunte o comportamento
(brincando normal / mais quieta / muito abatida).`;

// Categorias da queixa (tabela nx_queixa_categorias). Editar la muda o agente
// sem publicar codigo; o cache evita uma consulta a cada mensagem.
type Categoria = {
  codigo: string; nome: string; exemplos: string; perguntas: string[];
  objetivo: string | null; regra: string | null;
};
let CATS: { em: number; lista: Categoria[] } = { em: 0, lista: [] };
async function categorias(): Promise<Categoria[]> {
  if (CATS.lista.length && Date.now() - CATS.em < 5 * 60_000) return CATS.lista;
  const { data, error } = await sb.from("nx_queixa_categorias")
    .select("codigo, nome, exemplos, perguntas, objetivo, regra")
    .eq("ativo", true).order("ordem");
  if (error || !data?.length) {
    console.error("agente: categorias indisponiveis", error?.message);
    return CATS.lista; // ultimo cache bom; vazio = segue sem categorias
  }
  CATS = { em: Date.now(), lista: data as Categoria[] };
  return CATS.lista;
}

function blocoCategorias(lista: Categoria[]): string {
  const partes = lista.map((c) => {
    const linhas = [`## ${c.nome} (${c.codigo})`];
    if (c.exemplos) linhas.push(`Exemplos: ${c.exemplos}`);
    if (c.perguntas?.length) {
      linhas.push("Primeiras perguntas:", ...c.perguntas.map((p, i) => `${i + 1}. ${p}`));
    }
    if (c.objetivo) linhas.push(`Objetivo: ${c.objetivo}`);
    if (c.regra) linhas.push(`Regra: ${c.regra}`);
    return linhas.join("\n");
  });
  return `# Categorias da queixa
As palavras de cada categoria são EXEMPLOS de linguagem, não lista fechada.
Reconheça sinônimos, erros de digitação, abreviações, linguagem coloquial,
diminutivos e descrições equivalentes. Exemplos: "tá molinho", "meio caidinho",
"não está com a mesma energia" = alteração do estado geral (febre/prostração);
"tá puxando o ar", "a costelinha fica entrando" = esforço respiratório, mesmo
sem a palavra "falta de ar".
Se a queixa mudar, mude a categoria. Se houver mais de uma, use a mais grave e
pergunte da outra depois. Adapte a pergunta ao nome da criança e ao que já foi
dito, sem mudar o sentido. Enquanto não houver queixa, use nao_classificado.

${partes.join("\n\n")}`;
}

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
exame_tipo, medicacao_solicitada, documento_tipo, preferencia, convenio, pedido

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
// Com categorias (pediatria), "categoria" entra como campo obrigatorio.
function formato(codigos: string[] | null) {
  if (!codigos?.length) return FORMATO;
  const s = FORMATO.json_schema.schema;
  return {
    ...FORMATO,
    json_schema: {
      ...FORMATO.json_schema,
      schema: {
        ...s,
        properties: {
          ...s.properties,
          categoria: { type: "string", enum: codigos, description: "Categoria da queixa atual." },
        },
        required: [...s.required, "categoria"],
      },
    },
  };
}

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
  /(agendar|marcar (uma )?consulta|quero marcar|hor[áa]rios? (livres?|dispon[íi]ve(l|is))|tem vaga|(pode|consegue|d[áa] (pra|para)) (me )?atender|encaix|consulta (pra|para|amanh|hoje|dia|segunda|ter[çc]a|quarta|quinta|sexta|s[áa]bado))/;

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

// ---- porteiro ----
// O numero do medico (coexistencia ou uazapi) recebe amigos, familia, escola,
// fornecedores. A IA so entra em conversa de PACIENTE; na duvida, fica calada.
const ESQUEMA_PORTEIRO = {
  type: "json_schema",
  json_schema: {
    name: "porteiro",
    strict: true,
    schema: {
      type: "object",
      additionalProperties: false,
      required: ["tipo", "motivo"],
      properties: {
        tipo: { type: "string", enum: ["paciente", "pessoal", "duvida"] },
        motivo: { type: "string", description: "Uma frase curta explicando a decisão." },
      },
    },
  },
} as const;

async function classificar(
  clinica: string, historico: FalaHistorico[], novas: string,
): Promise<{ tipo: string; motivo: string } | null> {
  const chave = Deno.env.get("OPENAI_API_KEY");
  if (!chave) return null;
  const linhas = historico.slice(-30)
    .map((f) => `${f.em.slice(0, 10)} ${f.quem === "dono" ? "MÉDICO" : "CONTATO"}: ${f.texto}`)
    .join("\n") || "(nenhuma conversa anterior)";
  try {
    const r = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: { Authorization: `Bearer ${chave}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        model: Deno.env.get("WA_PORTEIRO_MODEL") ?? "gpt-4o-mini",
        temperature: 0,
        max_tokens: 120,
        response_format: ESQUEMA_PORTEIRO,
        messages: [
          {
            role: "system",
            content:
`Este é o WhatsApp pessoal de um médico (${clinica}), usado também para atender pacientes.
Uma assistente virtual atende os PACIENTES. Você decide se ela deve entrar nesta conversa.

- paciente: alguém procurando a clínica como paciente ou responsável: marcar consulta,
  sintoma, retorno, exame, receita, valor, horário. Primeiro contato sem relação anterior
  com o médico, falando de atendimento, é paciente.
- pessoal: a conversa anterior mostra relação pessoal ou profissional com o médico
  (amigo, família, colega, escola, igreja, fornecedor, trabalho), ou a mensagem segue um
  assunto já em andamento com ele, ou o contato chama o médico pelo apelido/primeiro nome
  em tom pessoal. Amigo pedindo um conselho de saúde ao médico também é pessoal: quem
  responde é ele.
- Pedido de CONSULTA ou horário (para si ou para filho/familiar) é paciente, mesmo
  vindo de amigo ou conhecido: "pode atender o José amanhã às 13h?" é paciente.
- duvida: não dá para saber com segurança.

Lembrete ou confirmação de uma consulta marcada no histórico indicam paciente.
Mensagens da assistente virtual (boas-vindas, "podemos começar?", "da última vez
falamos sobre...") NÃO provam nada: ela já respondeu amigos por engano.
Foto, áudio ou arquivo sozinhos não fazem de ninguém paciente: decida pelo contexto.
Na dúvida entre paciente e pessoal, responda duvida.`,
          },
          {
            role: "user",
            content: `Conversa anterior (mais antiga primeiro):\n${linhas}\n\nMensagens novas do CONTATO:\n${novas}`,
          },
        ],
      }),
    });
    const j = await r.json().catch(() => ({}));
    const bruto = j?.choices?.[0]?.message?.content;
    return bruto ? JSON.parse(bruto) : null;
  } catch (e) {
    console.error("porteiro:", e instanceof Error ? e.message : e);
    return null;
  }
}

/**
 * true = a IA pode atender. Decide uma vez por conversa e grava em
 * contexto_tipo. Conversa pessoal ou em duvida fica com a IA desligada; se
 * a equipe religar no cockpit, a decisao e respeitada.
 */
async function porteiro(conv: string, texto: string): Promise<boolean> {
  const { data: c } = await sb.from("conversations")
    .select("clinic_id, telefone, bot_active, contexto_tipo").eq("id", conv).maybeSingle();
  if (!c) return false;

  const marcar = async (tipo: string, motivo: string) => {
    await sb.from("conversations").update({ contexto_tipo: tipo, contexto_motivo: motivo.slice(0, 300) })
      .eq("id", conv);
  };

  // Numero so da clinica: todo contato e paciente.
  const { data: w } = await sb.from("clinic_whatsapp")
    .select("provider, access_token, coexistencia").eq("clinic_id", c.clinic_id).maybeSingle();
  const compartilhado = w?.coexistencia === true || w?.provider === "uazapi";
  if (!compartilhado) {
    if (!c.contexto_tipo) await marcar("paciente", "número exclusivo da clínica");
    return true;
  }

  // No numero do medico, IA desligada e silencio total: nada de retomada,
  // confirmacao ou aviso automatico numa conversa que um humano conduz.
  if (c.bot_active === false) return false;
  if (c.contexto_tipo) return c.contexto_tipo === "paciente" || c.bot_active === true;

  // Historico: o do proprio WhatsApp (Zernio) e o que ja esta na NexoClin.
  let hist: FalaHistorico[] = [];
  if (w?.provider === "zernio" && w?.access_token) {
    hist = await historicoZernio(String(w.access_token), String(c.telefone ?? ""), 30).catch(() => []);
  }
  if (!hist.length) {
    const { data: loc } = await sb.from("messages").select("direction, body, transcript, created_at")
      .eq("conversation_id", conv).order("created_at", { ascending: false }).limit(30);
    hist = (loc ?? []).reverse().map((m: any) => ({
      quem: m.direction === "out" ? "dono" : "contato",
      texto: String(m.body || m.transcript || "").slice(0, 400),
      em: String(m.created_at ?? ""),
    } as FalaHistorico)).filter((f) => f.texto);
  }

  const { data: cl } = await sb.from("clinics").select("nome").eq("id", c.clinic_id).maybeSingle();
  const d = await classificar(cl?.nome ?? "clínica", hist, texto);
  const tipo = d?.tipo ?? "duvida";
  await marcar(tipo, d?.motivo ?? "classificação indisponível");
  if (tipo === "paciente") return true;

  // pessoal ou duvida: a IA sai desta conversa. Duvida chama a equipe.
  await sb.from("conversations")
    .update({ bot_active: false, ...(tipo === "duvida" ? { attention: true } : {}) }).eq("id", conv);
  return false;
}

// ---- nome e idade no agendamento ----
const ESQUEMA_QUEM = {
  type: "json_schema",
  json_schema: {
    name: "quem",
    strict: true,
    schema: {
      type: "object",
      additionalProperties: false,
      required: ["nome", "idade", "outras_informacoes"],
      properties: {
        nome: { type: ["string", "null"], description: "Só o nome do paciente" },
        idade: { type: ["string", "null"], description: "Ex.: '4 anos', '8 meses'" },
        outras_informacoes: {
          type: ["string", "null"],
          description: "Sintoma ou outra informação de saúde que veio junto",
        },
      },
    },
  },
} as const;

/** "Pedro. tem 4 anos. ele esta com febre" -> nome Pedro, idade 4 anos, febre. */
async function extrairQuem(texto: string) {
  const chave = Deno.env.get("OPENAI_API_KEY");
  if (!chave) return null;
  try {
    const r = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: { Authorization: `Bearer ${chave}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        model: Deno.env.get("WA_INTERP_MODEL") ?? "gpt-4o-mini",
        temperature: 0,
        max_tokens: 120,
        response_format: ESQUEMA_QUEM,
        messages: [
          {
            role: "system",
            content: "Extraia do texto do responsável o nome e a idade do paciente e qualquer " +
              "informação de saúde mencionada. O que não estiver no texto vai null. Não invente.",
          },
          { role: "user", content: texto },
        ],
      }),
    });
    const j = await r.json().catch(() => ({}));
    const bruto = j?.choices?.[0]?.message?.content;
    if (!bruto) return null;
    // o modelo as vezes devolve o texto "null" no lugar de null
    const limpo = (v: unknown) => {
      const t = String(v ?? "").trim();
      return t && !/^(null|undefined|n\/a|-)$/i.test(t) ? t : null;
    };
    const p = JSON.parse(bruto);
    return { nome: limpo(p?.nome), idade: limpo(p?.idade), outras_informacoes: limpo(p?.outras_informacoes) };
  } catch (e) {
    console.error("extrairQuem:", e instanceof Error ? e.message : e);
    return null;
  }
}

// Respostas sem dia/turno/horario que ainda assim seguem o agendamento.
const RE_INDIFERENTE =
  /(tanto faz|qualquer|indiferente|pode ser|o mais (cedo|r[áa]pido|pr[óo]ximo)|primeir|^\s*(sim|ok|isso|beleza|certo)\b)/;
// Passos em que o banco aceitava qualquer texto: agora so seguem com algo de agenda.
const PASSO_LIVRE = new Set(["ag_turno", "ag_offer", "agenda_pref"]);

// ---- cadastro do paciente depois de marcar ----
// Consulta marcada sem cadastro deixava a clinica sem nome completo, data de
// nascimento e responsavel (nota, prontuario, pagamento). Depois de confirmar
// o horario a IA pede o que falta e grava no prontuario.
const ESQUEMA_CADASTRO = {
  type: "json_schema",
  json_schema: {
    name: "cadastro",
    strict: true,
    schema: {
      type: "object",
      additionalProperties: false,
      required: ["paciente_nome_completo", "data_nascimento", "responsavel_nome", "responsavel_cpf"],
      properties: {
        paciente_nome_completo: { type: ["string", "null"] },
        data_nascimento: { type: ["string", "null"], description: "AAAA-MM-DD" },
        responsavel_nome: { type: ["string", "null"], description: "Nome completo do responsável" },
        responsavel_cpf: { type: ["string", "null"], description: "Só os 11 dígitos" },
      },
    },
  },
} as const;

const ROTULO_CAD: Record<string, string> = {
  paciente_nome_completo: "Nome completo do paciente",
  data_nascimento: "Data de nascimento",
  responsavel_nome: "Nome completo do responsável",
  responsavel_cpf: "CPF do responsável",
};

const nomeCompleto = (n?: string | null) => String(n ?? "").trim().split(/\s+/).filter(Boolean).length >= 2;

/** O que falta no cadastro desta conversa (paciente + responsavel pelo telefone). */
async function faltaCadastro(conv: string) {
  const { data: c } = await sb.from("conversations")
    .select("clinic_id, telefone, patient_id, paciente_nome").eq("id", conv).maybeSingle();
  if (!c) return { falta: [] as string[], c: null, pac: null, resp: null };
  const { data: pac } = c.patient_id
    ? await sb.from("patients").select("id, nome, nascimento, responsavel_id").eq("id", c.patient_id).maybeSingle()
    : { data: null };
  const tel = String(c.telefone ?? "").replace(/\D/g, "");
  const { data: resps } = await sb.from("responsaveis").select("id, nome, cpf, telefone").eq("clinic_id", c.clinic_id);
  const resp = (resps ?? []).find((r: any) => String(r.telefone ?? "").replace(/\D/g, "") === tel) ?? null;
  const falta: string[] = [];
  if (!nomeCompleto(pac?.nome ?? c.paciente_nome)) falta.push("paciente_nome_completo");
  if (!pac?.nascimento) falta.push("data_nascimento");
  if (!nomeCompleto(resp?.nome)) falta.push("responsavel_nome");
  if (String(resp?.cpf ?? "").replace(/\D/g, "").length !== 11) falta.push("responsavel_cpf");
  return { falta, c, pac, resp };
}

function pedidoCadastro(falta: string[], quem: string | null): string {
  return `📋 Para deixar o cadastro${quem ? ` de *${quem}*` : ""} completo, me envie por favor:\n` +
    falta.map((k) => `• ${ROTULO_CAD[k]}`).join("\n");
}

/** Le os dados do cadastro na mensagem, grava e diz o que ainda falta. */
async function passoCadastro(conv: string, texto: string): Promise<string | null> {
  const chave = Deno.env.get("OPENAI_API_KEY");
  if (!chave) return null;
  const hoje = new Date().toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" });
  let d: Record<string, string | null> = {};
  try {
    const r = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: { Authorization: `Bearer ${chave}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        model: Deno.env.get("WA_INTERP_MODEL") ?? "gpt-4o-mini",
        temperature: 0, max_tokens: 150, response_format: ESQUEMA_CADASTRO,
        messages: [
          { role: "system", content: `Extraia os dados de cadastro da mensagem. Hoje é ${hoje}. ` +
            "Data de nascimento em AAAA-MM-DD. O que não estiver na mensagem vai null. Não invente." },
          { role: "user", content: texto },
        ],
      }),
    });
    const j = await r.json().catch(() => ({}));
    d = JSON.parse(j?.choices?.[0]?.message?.content ?? "{}");
  } catch (e) {
    console.error("cadastro:", e instanceof Error ? e.message : e);
    return null;
  }
  const veio = Object.values(d).some((v) => v);
  const { c, pac, resp } = await faltaCadastro(conv);
  if (!c) return null;
  if (!veio) return null;   // falou de outra coisa: segue o fluxo normal

  const tel = String(c.telefone ?? "").replace(/\D/g, "");
  let respId = resp?.id ?? pac?.responsavel_id ?? null;
  const cpf = String(d.responsavel_cpf ?? "").replace(/\D/g, "");
  const dadosResp: Record<string, string> = {};
  if (d.responsavel_nome) dadosResp.nome = d.responsavel_nome;
  if (cpf.length === 11) dadosResp.cpf = cpf;
  if (Object.keys(dadosResp).length) {
    if (respId) await sb.from("responsaveis").update(dadosResp).eq("id", respId);
    else {
      const { data: novo } = await sb.from("responsaveis")
        .insert({ clinic_id: c.clinic_id, telefone: tel, ...dadosResp }).select("id").single();
      respId = novo?.id ?? null;
    }
  }
  if (pac?.id) {
    const dadosPac: Record<string, unknown> = {};
    if (d.paciente_nome_completo && nomeCompleto(d.paciente_nome_completo)) dadosPac.nome = d.paciente_nome_completo;
    if (d.data_nascimento && /^\d{4}-\d{2}-\d{2}$/.test(d.data_nascimento)) dadosPac.nascimento = d.data_nascimento;
    if (respId) dadosPac.responsavel_id = respId;
    if (Object.keys(dadosPac).length) await sb.from("patients").update(dadosPac).eq("id", pac.id);
    if (dadosPac.nome) await sb.from("conversations").update({ paciente_nome: dadosPac.nome }).eq("id", conv);
    if (dadosPac.nascimento) {
      await sb.from("pt_ficha").upsert({ patient_id: pac.id, clinic_id: c.clinic_id, data_nascimento: dadosPac.nascimento },
        { onConflict: "patient_id" });
    }
  }

  const depois = await faltaCadastro(conv);
  if (!depois.falta.length) {
    await sb.from("conversations").update({ bot_state: null }).eq("id", conv);
    return "Cadastro completo! ✅ Obrigado. Qualquer dúvida até a consulta, é só chamar por aqui. 💙";
  }
  const cpfInvalido = d.responsavel_cpf && cpf.length !== 11 ? "O CPF precisa ter 11 números. " : "";
  return `${cpfInvalido}Anotei! ${pedidoCadastro(depois.falta, null).replace("📋 ", "")}`;
}

/** Depois de "Prontinho! Consulta marcada": pede o cadastro que faltar. */
async function aposMarcar(conv: string, resposta: string): Promise<string> {
  if (!/marcad[ao] para/i.test(resposta)) return resposta;
  const { falta, c, pac } = await faltaCadastro(conv);
  if (!c || !falta.length) return resposta;
  await sb.from("conversations").update({ bot_state: "cad" }).eq("id", conv);
  const quem = String(pac?.nome ?? c.paciente_nome ?? "").split(" (")[0] || null;
  return `${resposta}\n\n${pedidoCadastro(falta, quem)}`;
}

/**
 * Passo "para quem e a consulta". O modelo separa nome, idade e o que mais
 * veio junto. Sem idade nao segue: a idade muda o que e grave e o medico
 * precisa dela. Se o pedido original ja trazia dia/hora ("amanha as 13h"),
 * aplica depois de identificar o paciente.
 */
async function passoQuem(conv: string, texto: string, pedido?: string): Promise<string | null> {
  // "1", "2)": escolha na lista de criancas ja cadastradas, o banco decide.
  if (/^\s*[0-9]\s*[).]?\s*$/.test(texto)) {
    const { data } = await sb.rpc("nx_book_step_ia", {
      p_conv: conv, p_texto: texto, p_ped: null, p_conf: null, p_escolha: null, p_origem: "regra",
    });
    return data ?? null;
  }

  const { data: cv } = await sb.from("conversations").select("bot_ctx").eq("id", conv).maybeSingle();
  const guardado = (cv?.bot_ctx ?? {}) as Record<string, any>;
  const q = await extrairQuem(texto);
  if (q?.outras_informacoes) {
    await sb.rpc("nx_agent_aplicar", {
      p_conv: conv, p_risco: "", p_encaminhar: false, p_manter_bot: true,
      p_dados: [{ chave: "sintoma_principal", valor: q.outras_informacoes.slice(0, 300), atencao: false }],
    });
  }
  const nome = q?.nome ?? guardado.quem_nome ?? null;
  const idade = q?.idade ?? null;
  const pedidoOriginal = pedido ?? guardado.quem_pedido ?? null;
  if (!nome) return null;

  if (!idade) {
    await sb.from("conversations").update({
      bot_ctx: { ...guardado, quem_nome: nome, ...(pedidoOriginal ? { quem_pedido: pedidoOriginal } : {}) },
    }).eq("id", conv);
    return `Qual a *idade* de ${nome}?`;
  }

  const { data: r } = await sb.rpc("nx_book_step_ia", {
    p_conv: conv, p_texto: `${nome} ${idade}`, p_ped: null, p_conf: null, p_escolha: null, p_origem: "modelo",
  });

  // O pedido ja dizia dia/hora: segue direto para esse horario.
  if (pedidoOriginal) {
    const { data: st } = await sb.from("conversations").select("bot_state").eq("id", conv).maybeSingle();
    if (st?.bot_state && st.bot_state !== "ag_quem" && st.bot_state !== "ag_prof" && st.bot_state !== "ag_mod") {
      const hoje = new Date().toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" });
      const lido = await interpretar(pedidoOriginal, [], hoje);
      if (lido && Object.keys(lido.ped).length) {
        const { data: r2 } = await sb.rpc("nx_book_step_ia", {
          p_conv: conv, p_texto: pedidoOriginal, p_ped: lido.ped, p_conf: false, p_escolha: null,
          p_origem: "modelo",
        });
        if (r2) return r2;
      }
    }
  }
  return r ?? null;
}

/**
 * Comeca o agendamento. Se a pessoa ja disse para quem e ("para minha filha
 * Maria, 2 anos"), responde o passo do "para quem" na mesma hora, em vez de
 * perguntar de novo o que ela acabou de dizer.
 */
async function iniciarAgenda(conv: string, texto: string): Promise<string | null> {
  const { data: inicio } = await sb.rpc("nx_book_start", { p_conv: conv });
  const { data: st } = await sb.from("conversations").select("bot_state").eq("id", conv).maybeSingle();
  if (st?.bot_state !== "ag_quem") return inicio ?? null;
  return (await passoQuem(conv, texto, texto)) ?? inicio ?? null;
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
    const data = await iniciarAgenda(conv, texto);
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

    // Quem e o paciente: o modelo separa nome, idade e o que mais veio junto
    // (a regra do banco lia "Pedro. tem 4 anos" como o nome "Pedro tem").
    if (estado === "ag_quem") {
      const r = await passoQuem(conv, texto);
      if (r) return r;
    }
    const textoPasso = texto;
    const lido = estado === "ag_quem" ? null : await interpretar(texto, offers, hoje);

    // Turno, oferta e preferencia aceitavam qualquer texto: "febre desde ontem"
    // virava escolha de horario. Sem nada de agenda na frase, quem responde e
    // a triagem, e o passo fica onde esta.
    const semAgenda = lido && !Object.keys(lido.ped).length && !lido.conf && lido.escolha === null;
    if (PASSO_LIVRE.has(estado!) && semAgenda && !RE_INDIFERENTE.test(t)) return null;

    const { data } = await sb.rpc("nx_book_step_ia", {
      p_conv: conv,
      p_texto: textoPasso,
      p_ped: lido ? lido.ped : null,
      p_conf: lido ? lido.conf : null,
      p_escolha: lido ? lido.escolha : null,
      p_origem: lido ? "modelo" : "regra",
    });
    return data ? await aposMarcar(conv, data) : null;
  }

  const u = ultimaIA.toLowerCase();
  const escolheuAgenda = (u.includes("verificar horários") && RE_SO_1.test(t)) ||
    (u.includes("5) marcar") && RE_SO_5.test(t));
  if (escolheuAgenda) {
    const data = await iniciarAgenda(conv, texto);
    return data ?? null;
  }

  if (!RE_DIRETA.test(t) && !RE_AGENDAR.test(t)) return null;
  const { data: ai } = await sb.rpc("nx_ai_answer", { p_conv: conv, p_texto: texto });
  if (ai?.matched && ai.intent !== "agenda") return ai.answer ?? null;
  if (ai?.intent === "agenda" || RE_AGENDAR.test(t)) {
    const data = await iniciarAgenda(conv, texto);
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

  // 0) Porteiro: conversa pessoal do medico nao e atendimento.
  if (!(await porteiro(conv, texto))) return null;

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
  const { data: ativa } = await sb.from("conversations")
    .select("bot_active, paciente_nome").eq("id", conv).maybeSingle();
  if (estadoConv === "retomar" || estadoConv === "retomar_resp") {
    // So pergunta "continuar o anterior?" quando houve atendimento de verdade
    // (paciente identificado ou triagem). Sem isso, ou se a pessoa ja chega
    // pedindo consulta, comeca do inicio.
    const { count: dados } = await sb.from("collected_data").select("chave", { count: "exact", head: true })
      .eq("conversation_id", conv).not("chave", "in", "(consentimento,consentimento_recusado,encaminhamento)");
    const pac = String(ativa?.paciente_nome ?? "").toLowerCase();
    const teveAtendimento = (!!pac && !pac.startsWith("paciente")) || !!dados;
    if (!teveAtendimento || (estadoConv === "retomar" && RE_AGENDAR.test(t))) {
      await sb.from("conversations").update({ bot_state: null }).eq("id", conv);
      conversa.bot_state = null;
    }
  }
  if ((conversa.bot_state === "retomar" || conversa.bot_state === "retomar_resp") && ativa?.bot_active !== false) {
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

  // 3.5) Cadastro pedido depois de marcar.
  if (conversa.bot_state === "cad") {
    const cad = await passoCadastro(conv, texto);
    if (cad) return cad;
  }

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

  // Quem disse o que: a fala do medico ou da equipe (pelo celular ou pelo
  // cockpit) nao e da IA, e a IA precisa saber disso para nao contradizer.
  const historico = (ctx.historico ?? [])
    .map((m: any) => {
      const corpo = String(m.body ?? "");
      if (m.direction === "in") return { role: "user", content: corpo };
      if (m.author === "assistente") return { role: "assistant", content: corpo };
      return { role: "user", content: `[Mensagem da equipe/médico para o paciente, não sua]: ${corpo}` };
    })
    .filter((m: any) => m.content.length > 0);

  // Categorias da queixa valem no modo pediatria (o documento e pediatrico).
  const cats = ctx.modo === "pediatria" ? await categorias() : [];
  const instrucoes = (ctx.modo === "pediatria" ? PEDIATRIA : GERAL) + "\n\n" +
    (cats.length ? blocoCategorias(cats) + "\n\n" : "") + COMUM;
  const { data: convCat } = cats.length
    ? await sb.from("conversations").select("queixa_categoria").eq("id", conv).maybeSingle()
    : { data: null };
  const catAtual: string | null = convCat?.queixa_categoria ?? null;

  const contexto =
    `Clínica: ${ctx.clinica ?? "—"}\n` +
    `Paciente já identificado: ${ctx.paciente_nome ?? "ainda não"}\n` +
    `Idade: ${ctx.paciente_idade ?? "ainda não"}\n` +
    familia(ctx.quem) +
    (cats.length ? `Categoria da queixa até aqui: ${catAtual ?? "nao_classificado"}\n` : "") +
    `Já coletado: ${JSON.stringify(ctx.coletado ?? {})}\n` +
    `Situação: ${SITUACAO[ctx.status ?? ""] ?? "em triagem"}` +
    ((conversa.bot_state ?? "").startsWith("ag_")
      ? `\nHá um agendamento em andamento. Acolha o que a pessoa disse (anote em "dados") ` +
        `e, no fim, repita a pergunta pendente do agendamento: "${ultimaIA}"`
      : "");

  const r = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${chave}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: MODELO,
      temperature: 0.3,
      max_tokens: 800,
      response_format: formato(cats.length ? cats.map((c) => c.codigo) : null),
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
    encaminhar_humano: boolean; tipo_encaminhamento?: string; categoria?: string;
  };
  try {
    saida = JSON.parse(j.choices?.[0]?.message?.content ?? "{}");
  } catch {
    console.error("agente: resposta fora do formato"); return null;
  }
  if (!saida?.resposta) { console.error("agente: sem resposta"); return null; }

  // o agente pode SUBIR o risco, nunca baixar abaixo do que ja estava
  const atual = ctx.risco ?? "nao_urgente";
  let risco = (PESO[saida.risco] ?? 1) >= (PESO[atual] ?? 1) ? saida.risco : atual;

  // Categoria da queixa. "nao_classificado" nunca apaga uma categoria ja dada.
  const cat = cats.find((c) => c.codigo === saida.categoria) ?? null;
  const novaCat = cat && cat.codigo !== catAtual && (cat.codigo !== "nao_classificado" || !catAtual)
    ? cat : null;
  const dados = [...(saida.dados ?? [])];
  if (novaCat) {
    await sb.from("conversations").update({ queixa_categoria: novaCat.codigo }).eq("id", conv);
    if (novaCat.codigo !== "nao_classificado") {
      dados.push({ chave: "categoria", valor: novaCat.nome, atencao: false });
    }
  }
  // Ingestao/intoxicacao: sem conduta improvisada, minimo urgente e vai para a equipe.
  const intoxicacao = saida.categoria === "intoxicacao";
  if (intoxicacao && (PESO[risco] ?? 1) < PESO.urgente) risco = "urgente";

  // Encaminhar nunca desliga a IA (so um humano desliga). Administrativo
  // (valor, confirmar horario) nem move a fila: so pede atencao da equipe.
  const administrativo = saida.tipo_encaminhamento === "administrativo" && risco !== "emergencia" &&
    !intoxicacao;
  await sb.rpc("nx_agent_aplicar", {
    p_conv: conv, p_risco: risco,
    p_encaminhar: saida.encaminhar_humano || administrativo || intoxicacao || risco === "emergencia",
    p_dados: dados,
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
