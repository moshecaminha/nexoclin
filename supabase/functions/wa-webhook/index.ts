// supabase/functions/wa-webhook/index.ts
// Webhook unico da NexoClin para a WhatsApp Cloud API (app Tech Provider).
// Roteia por phone_number_id: a Meta entrega TODAS as WABAs nesta mesma URL.
// Tambem recebe a uazapi (API nao oficial) em ?uaz=<segredo da conexao> e a
// Zernio (API oficial intermediada), reconhecida pelo header X-Zernio-Signature.
import { createClient } from "npm:@supabase/supabase-js@2";
import {
  CAMPOS_CONEXAO, enviarTextoCanal, lembrarConversaZernio, uazapi, type Conexao,
} from "../_shared/canal.ts";

const sb = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const enc = new TextEncoder();
const URL_SB = Deno.env.get("SUPABASE_URL")!;

/** HMAC-SHA256 do corpo cru, comparado em tempo constante. */
async function confere(raw: string, recebido: string, appSecret: string) {
  const key = await crypto.subtle.importKey(
    "raw", enc.encode(appSecret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, enc.encode(raw));
  const esperado = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
  if (esperado.length !== recebido.length) return false;
  let diff = 0;
  for (let i = 0; i < esperado.length; i++) diff |= esperado.charCodeAt(i) ^ recebido.charCodeAt(i);
  return diff === 0;
}

/**
 * App secret de cada clinica conectada por um app PROPRIO do medico (token
 * gerado na BM dele, sem passar pelo cadastro do MVF). Fica em
 * clinic_whatsapp.app_secret. Cache curto: a lista muda raramente.
 */
let cacheSegredos: { em: number; lista: string[] } = { em: 0, lista: [] };
async function segredosDasClinicas(): Promise<string[]> {
  if (Date.now() - cacheSegredos.em < 5 * 60_000) return cacheSegredos.lista;
  try {
    const { data } = await sb.from("clinic_whatsapp").select("app_secret").not("app_secret", "is", null);
    const lista = [...new Set((data ?? []).map((r: any) => r.app_secret).filter(Boolean))] as string[];
    cacheSegredos = { em: Date.now(), lista };
  } catch (e) {
    console.error("segredosDasClinicas", e instanceof Error ? e.message : e);
  }
  return cacheSegredos.lista;
}

/**
 * Aceita mais de um app secret. Enquanto a NexoClin nao tiver Tech Provider
 * proprio, uma clinica pode estar conectada pelo app do MVF — e ai a Meta
 * assina com o secret DAQUELE app, nao com o desta.
 */
async function assinaturaValida(raw: string, header: string | null) {
  if (!header?.startsWith("sha256=")) return false;
  const recebido = header.slice(7);
  const segredos = [
    Deno.env.get("WA_APP_SECRET"),
    Deno.env.get("WA_APP_SECRET_MVF"),
    ...(await segredosDasClinicas()),
  ].filter(Boolean) as string[];
  for (const s of segredos) {
    if (await confere(raw, recebido, s)) return true;
  }
  return false;
}

/** Texto exibivel de cada tipo de mensagem, para a fila nao ficar vazia. */
function corpoDe(msg: any): string | null {
  switch (msg.type) {
    case "text": return msg.text?.body ?? null;
    case "button": return msg.button?.text ?? null;
    case "interactive":
      return msg.interactive?.button_reply?.title ?? msg.interactive?.list_reply?.title ?? null;
    case "image": case "video": case "document": case "audio": case "sticker":
      return msg[msg.type]?.caption ?? null;
    case "location": return msg.location?.name ?? "[localizacao]";
    case "contacts": return "[contato]";
    default: return null;
  }
}


const GRAPH = `https://graph.facebook.com/${Deno.env.get("WA_GRAPH_VERSION") ?? "v21.0"}`;

/** Tipos que trazem arquivo: a Meta manda so um id, o binario e baixado depois. */
function midiaDe(msg: any): { id: string; mime?: string; filename?: string } | null {
  for (const t of ["image", "video", "audio", "document", "sticker"]) {
    if (msg?.[t]?.id) return { id: msg[t].id, mime: msg[t].mime_type, filename: msg[t].filename };
  }
  return null;
}

const EXT: Record<string, string> = {
  "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp",
  "video/mp4": "mp4", "video/3gpp": "3gp",
  "audio/ogg": "ogg", "audio/mpeg": "mp3", "audio/mp4": "m4a", "audio/amr": "amr",
  "application/pdf": "pdf",
};
function extDe(mime?: string, filename?: string): string {
  if (filename?.includes(".")) return filename.split(".").pop()!.toLowerCase().slice(0, 8);
  const base = (mime ?? "").split(";")[0].trim();
  return EXT[base] ?? (base.split("/")[1] ?? "bin").slice(0, 8);
}

/**
 * Baixa a midia da Meta e guarda no bucket 'documentos', no MESMO padrao de
 * caminho que o cockpit ja usa (clinic/conversa/arquivo) — assim o front
 * renderiza sem precisar de nenhuma alteracao.
 * Roda FORA da resposta do webhook: a Meta corta em poucos segundos.
 */
async function baixarMidia(
  mediaId: string, wamid: string, clinic: string, conv: string,
  token: string, telefone: string, mime?: string, filename?: string,
) {
  try {
    const meta = await fetch(`${GRAPH}/${mediaId}`, { headers: { Authorization: `Bearer ${token}` } });
    const info = await meta.json();
    if (!meta.ok || !info?.url) { console.error("midia: sem url", mediaId, info?.error); return; }

    const bin = await fetch(info.url, { headers: { Authorization: `Bearer ${token}` } });
    if (!bin.ok) { console.error("midia: download falhou", mediaId, bin.status); return; }
    const bytes = new Uint8Array(await bin.arrayBuffer());
    await guardarMidia(bytes, info.mime_type ?? mime, filename, wamid, clinic, conv, telefone);
  } catch (e) {
    console.error("midia:", e instanceof Error ? e.message : e);
  }
}

/** Midia recebida pela uazapi: POST /message/download devolve a URL do arquivo. */
async function baixarMidiaUazapi(
  c: Conexao, idDownload: string, wamid: string, clinic: string, conv: string,
  telefone: string, mime?: string, filename?: string,
) {
  try {
    const d = await uazapi(c, "/message/download", { id: idDownload });
    const url = d.body?.fileURL ?? d.body?.url;
    if (!d.ok || !url) { console.error("midia uazapi: sem url", idDownload, JSON.stringify(d.body)); return; }
    const bin = await fetch(url);
    if (!bin.ok) { console.error("midia uazapi: download falhou", bin.status); return; }
    const bytes = new Uint8Array(await bin.arrayBuffer());
    await guardarMidia(bytes, d.body?.mimetype ?? mime, d.body?.fileName ?? filename, wamid, clinic, conv, telefone);
  } catch (e) {
    console.error("midia uazapi:", e instanceof Error ? e.message : e);
  }
}

/**
 * Guarda o arquivo no bucket e entrega o conteudo a IA como texto: audio
 * transcrito, foto descrita, nome do arquivo. Midia nunca recebe resposta
 * pronta ("recebi a foto, ja anexei"): quem decide o que dizer, e se deve
 * dizer algo, e o agente, com o contexto da conversa.
 */
async function guardarMidia(
  bytes: Uint8Array, mime: string | undefined, filename: string | undefined,
  wamid: string, clinic: string, conv: string, telefone: string,
) {
  try {
    const ext = extDe(mime, filename);
    const path = `${clinic}/${conv}/${Date.now()}_${crypto.randomUUID().slice(0, 5)}.${ext}`;
    const { error } = await sb.storage.from("documentos")
      .upload(path, bytes, { contentType: mime ?? "application/octet-stream", upsert: false });
    if (error) console.error("midia: upload falhou", error.message);
    else await sb.rpc("nx_wa_media_set", { p_wamid: wamid, p_path: path });

    const { data: msg } = await sb.from("messages").select("body, type")
      .eq("wa_message_id", wamid).maybeSingle();
    const legenda = String(msg?.body ?? "").trim();
    const tipo = String(msg?.type ?? "");
    const base = (mime ?? "").split(";")[0].trim();
    if (tipo === "sticker") return;   // figurinha nao pede resposta

    let conteudo: string;
    if (base.startsWith("audio")) {
      const ouvido = await transcrever(bytes, mime ?? "audio/ogg");
      conteudo = ouvido ?? "[áudio que não foi possível ouvir]";
    } else if (base.startsWith("image")) {
      const visto = await descreverImagem(bytes, base);
      conteudo = `[Foto enviada: ${visto ?? "não foi possível ver o conteúdo"}]`;
    } else if (base.startsWith("video")) {
      conteudo = "[Vídeo enviado]";
    } else {
      conteudo = `[Arquivo enviado: ${filename ?? ext.toUpperCase()}]`;
    }
    await sb.rpc("nx_wa_set_transcript", { p_wamid: wamid, p_texto: conteudo });

    if (await iaPausada(clinic, telefone)) return;

    // Com consulta esperando pagamento, foto ou PDF quase sempre e o
    // comprovante: registra e chama a equipe. A IA nunca da pagamento por certo.
    if (base.startsWith("image") || base === "application/pdf") {
      const { data: comp } = await sb.rpc("nx_pagamento_comprovante", { p_conv: conv });
      if (comp) { await enviarTexto(clinic, conv, telefone, comp, "assistente"); return; }
    }

    const texto = legenda && legenda !== conteudo ? `${conteudo}\nLegenda: ${legenda}` : conteudo;
    await responderBot(conv, texto, telefone, clinic, wamid);
  } catch (e) {
    console.error("midia:", e instanceof Error ? e.message : e);
  }
}

/** Descricao objetiva da foto para a IA. null se nao der para ver. */
async function descreverImagem(bytes: Uint8Array, mime: string): Promise<string | null> {
  const chave = Deno.env.get("OPENAI_API_KEY");
  if (!chave || bytes.length > 15_000_000) return null;
  try {
    let bin = "";
    for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    const r = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: { Authorization: `Bearer ${chave}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        model: Deno.env.get("WA_VISAO_MODEL") ?? "gpt-4o-mini",
        temperature: 0,
        max_tokens: 160,
        messages: [{
          role: "user",
          content: [
            {
              type: "text",
              text: "Descreva em até 2 frases, em português, o que esta foto mostra, de forma " +
                "objetiva. Se for documento (exame, receita, comprovante, carteirinha), diga o tipo " +
                "e as informações principais legíveis. Não faça diagnóstico.",
            },
            { type: "image_url", image_url: { url: `data:${mime};base64,${btoa(bin)}`, detail: "low" } },
          ],
        }],
      }),
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) { console.error("visao:", JSON.stringify(j?.error ?? j)); return null; }
    return String(j?.choices?.[0]?.message?.content ?? "").trim() || null;
  } catch (e) {
    console.error("visao:", e instanceof Error ? e.message : e);
    return null;
  }
}


/**
 * Roda o roteiro de triagem (nx_wa_orchestrate) e, se ele tiver o que dizer,
 * MANDA de verdade pela Graph API. Sem esta parte o bot decide e ninguem ve:
 * era o que acontecia na producao, onde a resposta so era gravada no banco.
 * Roda fora da resposta do webhook — a Meta corta em poucos segundos.
 */
/** Segundos de espera antes de responder: quem escreve em rajada ("oi", "bom
 *  dia", "e o seguinte") recebia uma resposta para cada mensagem. */
const ESPERA_RAJADA_MS = 7000;

/**
 * Espera a pessoa terminar de escrever. Se chegou mensagem nova depois desta,
 * quem responde e a ultima - esta sai de cena. Devolve o texto acumulado.
 */
async function aguardarRajada(conv: string, texto: string, wamid?: string | null): Promise<string | null> {
  const marca = new Date().toISOString();
  await new Promise((r) => setTimeout(r, ESPERA_RAJADA_MS));

  if (!wamid) {
    const { data: novas } = await sb.from("messages").select("body")
      .eq("conversation_id", conv).eq("direction", "in")
      .gt("created_at", marca).order("created_at", { ascending: true });
    // chegou mensagem depois desta: quem responde e a ultima da rajada
    return novas?.length ? null : texto;
  }

  // A ultima da rajada e a de horario mais recente, nao a que chegou por
  // ultimo: a Zernio entrega fora de ordem e com ate ~30s de atraso.
  const { data: ultima } = await sb.from("messages").select("wa_message_id, created_at")
    .eq("conversation_id", conv).eq("direction", "in")
    .order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (ultima?.wa_message_id && ultima.wa_message_id !== wamid) return null;

  // Mensagem enviada ANTES da ultima resposta e entregue depois dela: nao
  // gera resposta nova. Fica no historico e entra na proxima resposta.
  const { data: saida } = await sb.from("messages").select("created_at")
    .eq("conversation_id", conv).eq("direction", "out")
    .order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (saida && ultima && ultima.created_at < saida.created_at) return null;

  // Responde a tudo que a pessoa mandou desde a ultima fala nossa (ate 8).
  let q = sb.from("messages").select("body, transcript, type")
    .eq("conversation_id", conv).eq("direction", "in");
  if (saida) q = q.gt("created_at", saida.created_at);
  const { data: rajada } = await q.order("created_at", { ascending: false }).limit(8);

  const partes = (rajada ?? []).reverse().map((m: any) => {
    const corpo = String(m.body ?? "").trim();
    const conteudo = String(m.transcript ?? "").trim();
    if (m.type !== "text" && conteudo) return corpo && corpo !== conteudo ? `${conteudo} Legenda: ${corpo}` : conteudo;
    return corpo || conteudo;
  }).filter((b: string) => b.length > 0);
  return partes.length > 1 ? partes.join("\n") : texto;
}

/** Pausa geral da IA na clinica (clinics.ia_pausada): nada automatico sai,
 *  exceto para os numeros liberados em clinic_whatsapp.numeros_permitidos. */
async function iaPausada(clinic: string, telefone: string): Promise<boolean> {
  const { data } = await sb.rpc("nx_ia_liberada", { p_clinic: clinic, p_telefone: telefone });
  return data === false;
}

async function responderBot(
  conv: string, texto: string, telefone: string, clinic: string, wamid?: string | null,
) {
  let travou = false;
  try {
    if (await iaPausada(clinic, telefone)) return;
    const juntado = await aguardarRajada(conv, texto, wamid);
    if (juntado === null) return;   // outra mensagem chegou; ela e que responde
    texto = juntado;

    // Uma resposta por vez na conversa: entrega repetida do webhook ou a
    // wa-sweep ao mesmo tempo mandavam o "So para confirmar" em dobro.
    const { data: trava } = await sb.rpc("nx_wa_bot_lock", { p_conv: conv, p_seg: 90 });
    if (trava !== true) return;
    travou = true;

    // O agente (wa-agent) decide o que responder. Ele ja aplica risco,
    // dados coletados e encaminhamento no banco antes de devolver o texto.
    const r = await fetch(`${URL_SB}/functions/v1/wa-agent`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}`,
        "x-nx-internal": Deno.env.get("WA_INTERNAL_SECRET") ?? "",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ conversation_id: conv, texto }),
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) { console.error("agente:", JSON.stringify(j)); return; }
    if (!j?.resposta) return;   // bot desligado, humano assumiu, ou nada a dizer

    await enviarTexto(clinic, conv, telefone, j.resposta, "assistente");
  } catch (e) {
    console.error("bot:", e instanceof Error ? e.message : e);
  } finally {
    if (travou) await sb.rpc("nx_wa_bot_unlock", { p_conv: conv });
  }
}

/** Palavras que zeram a conversa. So no ambiente de trabalho. */
const CMD_ZERAR = ["zerar", "#zerar", "reset", "#reset", "recomecar", "recomeçar"];

/**
 * Comando de teste: apaga a conversa e responde confirmando, sem deixar rastro
 * na fila. Serve para testar a triagem do zero sem sair do WhatsApp.
 */
async function zerarConversa(phoneId: string, telefone: string): Promise<boolean> {
  try {
    // zera so neste consultorio: o mesmo telefone pode falar com varios
    const { data: cw } = await sb.from("clinic_whatsapp")
      .select("clinic_id").eq("phone_number_id", phoneId).maybeSingle();
    const { data: r, error: eReset } = await sb.rpc("nx_dev_reset", {
      p_telefone: telefone,
      p_clinic: cw?.clinic_id ?? null,
    });
    if (eReset) console.error("zerar:", eReset.message);
    const { data: conn } = await sb.from("clinic_whatsapp")
      .select(CAMPOS_CONEXAO).eq("phone_number_id", phoneId).single();
    if (!conn?.access_token) return true;

    const n = r?.conversas_apagadas ?? 0;
    const texto = n
      ? `🧹 Conversa zerada (${r.mensagens} mensagens apagadas).${"\n"}Manda qualquer coisa que a triagem começa do zero.`
      : `🧹 Já estava limpo. Manda qualquer coisa que a triagem começa.`;

    await enviarTextoCanal(conn, telefone, texto);
  } catch (e) {
    console.error("zerar:", e instanceof Error ? e.message : e);
  }
  return true;
}


/** Manda um texto pelo numero da clinica e registra a mensagem enviada. */
async function enviarTexto(clinic: string, conv: string, telefone: string, texto: string, autor: string) {
  const { data: conn } = await sb.from("clinic_whatsapp")
    .select(CAMPOS_CONEXAO).eq("clinic_id", clinic).single();
  if (!conn?.access_token) { console.error("envio: clinica sem token"); return; }

  const env = await enviarTextoCanal(conn, telefone, texto);
  if (!env.ok) { console.error("envio: recusado", conn.provider, JSON.stringify(env.erro)); return; }

  await sb.rpc("nx_wa_record_out", {
    p_conv: conv, p_body: texto, p_wamid: env.id, p_type: "text", p_author: autor,
  });
}



/**
 * Transcreve o audio do paciente. Numa clinica pediatrica isto nao e luxo:
 * mae com crianca no colo manda audio, nao texto. Sem transcrever, a triagem
 * simplesmente para.
 * Usa Whisper da OpenAI; se nao houver chave configurada, devolve null e o
 * fluxo cai no aviso pedindo texto — degradado, mas honesto.
 */
async function transcrever(bytes: Uint8Array, mime: string): Promise<string | null> {
  const chave = Deno.env.get("OPENAI_API_KEY");
  if (!chave) return null;
  try {
    const fd = new FormData();
    fd.append("file", new Blob([bytes], { type: mime || "audio/ogg" }), "audio.ogg");
    fd.append("model", Deno.env.get("WA_STT_MODEL") ?? "whisper-1");
    fd.append("language", "pt");
    // Contexto ajuda o modelo com termos que aparecem muito nesse dominio.
    fd.append("prompt", "Atendimento de clínica pediátrica: febre, tosse, vômito, "
      + "diarreia, mamada, vacina, consulta, remédio, alergia, garganta, ouvido.");

    const r = await fetch("https://api.openai.com/v1/audio/transcriptions", {
      method: "POST",
      headers: { Authorization: `Bearer ${chave}` },
      body: fd,
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) { console.error("transcricao:", JSON.stringify(j?.error ?? j)); return null; }
    const texto = (j?.text ?? "").trim();
    return texto.length ? texto : null;
  } catch (e) {
    console.error("transcricao:", e instanceof Error ? e.message : e);
    return null;
  }
}

// ---------------------------------------------------------------------------
// uazapi (API nao oficial). Formato do webhook (evento "messages"):
// { EventType:"messages", message:{ chatid:"5521...@s.whatsapp.net", sender,
//   senderName, fromMe, wasSentByApi, isGroup, messageType, mediaType, text,
//   messageid, id:"<dono>:<messageid>", messageTimestamp }, chat, owner, token }
// Mesmas pegadinhas tratadas no MVF: o numero real vem no chatid (o sender
// costuma ser um @lid), e o que a propria API enviou volta como fromMe.

const UAZ_PULAR = new Set([
  "reactionmessage", "reaction", "protocolmessage", "senderkeydistributionmessage",
  "pollupdatemessage", "ephemeralmessage",
]);

function uazNumero(m: any): string {
  const jid = String(m?.chatid ?? m?.chat ?? m?.key?.remoteJid ?? m?.sender ?? "");
  if (/@lid/i.test(jid) && !/@s\.whatsapp\.net/i.test(jid)) {
    const alt = String(m?.sender_pn ?? m?.sender ?? "");
    return /@s\.whatsapp\.net/i.test(alt) ? alt.replace(/@.*/, "").replace(/\D/g, "") : "";
  }
  return jid.replace(/@.*/, "").replace(/\D/g, "");
}

function uazTipo(m: any): string {
  const t = String(m?.mediaType ?? m?.messageType ?? m?.type ?? "").toLowerCase();
  if (/audio|ptt/.test(t)) return "audio";
  if (/image|sticker/.test(t)) return "image";
  if (/video/.test(t)) return "video";
  if (/document/.test(t)) return "document";
  return "text";
}

/** DDD + 8 ultimos digitos: casa o numero com ou sem 55 e com ou sem o 9. */
function chaveFone(n: string): string {
  let d = String(n).replace(/\D/g, "");
  if (d.length > 11 && d.startsWith("55")) d = d.slice(2);
  return d.slice(0, 2) + d.slice(-8);
}

async function webhookUazapi(chave: string, req: Request): Promise<Response> {
  const { data: conn } = await sb.from("clinic_whatsapp")
    .select(`clinic_id, numeros_permitidos, ${CAMPOS_CONEXAO}`)
    .eq("provider", "uazapi").eq("verify_token", chave).maybeSingle();
  if (!conn) return new Response("forbidden", { status: 403 });

  let body: any;
  try { body = await req.json(); } catch { return new Response("ok", { status: 200 }); }

  // Registro cru so do que vai entrar no sistema: o numero pode receber
  // mensagem pessoal e de grupo, que nao deve ficar gravada na clinica.
  let registrado = false;
  const registrar = async () => {
    if (registrado) return;
    registrado = true;
    try {
      await sb.from("webhook_events").insert({
        event_type: "whatsapp", origem: "uazapi", clinic_id: conn.clinic_id, payload: body,
      });
    } catch (e) {
      console.error("webhook_events uazapi", e instanceof Error ? e.message : e);
    }
  };

  const evento = String(body?.EventType ?? body?.event ?? "").toLowerCase();
  if (evento !== "messages") return new Response("ok", { status: 200 });

  // Numero de teste: so os telefones da lista entram no sistema.
  const permitidos = ((conn.numeros_permitidos ?? []) as string[]).map(chaveFone);
  const phoneId = String(conn.phone_number_id);

  try {
    const lista = body?.messages ?? (body?.message ? [body.message] : []);
    for (const m of Array.isArray(lista) ? lista : []) {
      if (m?.isGroup === true || /@g\.us/i.test(String(m?.chatid ?? ""))) continue;
      const tipoBruto = String(m?.messageType ?? m?.type ?? "").toLowerCase();
      if (UAZ_PULAR.has(tipoBruto) || m?.reaction) continue;
      if (m?.wasSentByApi) continue;   // o que a propria NexoClin enviou

      const fone = uazNumero(m);
      if (!fone) continue;
      if (permitidos.length && !permitidos.includes(chaveFone(fone))) continue;
      await registrar();

      const tipo = uazTipo(m);
      const texto = String(m?.text ?? m?.content?.text ?? m?.caption ?? m?.content?.caption ?? "").trim() || null;
      const wamid = String(m?.messageid ?? m?.id ?? "") || null;
      const idDownload = String(m?.id ?? m?.messageid ?? "");
      const tsBruto = Number(m?.messageTimestamp ?? 0);
      const ts = tsBruto > 1e12 ? Math.floor(tsBruto / 1000) : tsBruto;
      const temMidia = tipo !== "text";

      // Equipe respondeu pelo celular: entra como saida da equipe e pausa a IA.
      if (m?.fromMe) {
        await sb.rpc("nx_wa_eco", {
          p_phone_number_id: phoneId, p_to: fone, p_type: tipo,
          p_body: texto ?? `[${tipo} enviada pelo celular]`, p_wamid: wamid, p_ts: ts, p_media_id: null,
        });
        continue;
      }

      if (CMD_ZERAR.includes((texto ?? "").toLowerCase())) {
        EdgeRuntime.waitUntil(zerarConversa(phoneId, fone));
        continue;
      }

      const { data: ctx } = await sb.rpc("nx_wa_ingest", {
        p_phone_number_id: phoneId, p_from: fone, p_nome: m?.senderName ?? null,
        p_type: tipo, p_body: texto, p_wamid: wamid, p_ts: ts, p_payload: m,
        p_media_id: temMidia ? idDownload : null,
      });
      if (!ctx?.conversation_id || !ctx?.clinic_id) continue;

      // Midia (com ou sem legenda) responde depois de baixada, ja com o conteudo.
      if (texto && !temMidia) {
        EdgeRuntime.waitUntil(responderBot(ctx.conversation_id, texto, fone, ctx.clinic_id, wamid));
      }
      if (temMidia && wamid) {
        EdgeRuntime.waitUntil(baixarMidiaUazapi(
          conn, idDownload, wamid, ctx.clinic_id, ctx.conversation_id, fone,
          m?.mimetype ?? m?.content?.mimetype, m?.fileName ?? m?.content?.fileName,
        ));
      }
    }
  } catch (e) {
    console.error("wa-webhook uazapi", e instanceof Error ? e.message : e);
  }
  return new Response("ok", { status: 200 });
}

// ---------------------------------------------------------------------------
// Zernio (API oficial da Meta, intermediada). Um webhook so para todas as
// clinicas: a conta vem em account.accountId e casa com
// clinic_whatsapp.phone_number_id = "zernio:<accountId>".
// Assinatura: X-Zernio-Signature = HMAC-SHA256 hex do corpo cru, com o
// secret cadastrado no POST /v1/webhooks/settings (ZERNIO_WEBHOOK_SECRET).

/** Tipo da mensagem no vocabulario da Meta, que e o do banco (msg_type). */
function zernioTipo(m: any): string {
  const t = String(m?.attachments?.[0]?.type ?? "").toLowerCase();
  if (!t) return "text";
  if (t === "file") return "document";
  if (["image", "video", "audio", "sticker"].includes(t)) return t;
  return "document";
}

const STATUS_ZERNIO: Record<string, string> = {
  "message.delivered": "delivered", "message.read": "read", "message.failed": "failed",
};

/** Midia recebida pela Zernio: a URL e da propria Zernio e pede a API key. */
async function baixarMidiaZernio(
  url: string, wamid: string, clinic: string, conv: string,
  telefone: string, mime?: string, filename?: string,
) {
  try {
    const bin = await fetch(url, { headers: { Authorization: `Bearer ${Deno.env.get("ZERNIO_API_KEY") ?? ""}` } });
    if (!bin.ok) { console.error("midia zernio: download falhou", bin.status); return; }
    const tipo = bin.headers.get("content-type") ?? mime;
    const bytes = new Uint8Array(await bin.arrayBuffer());
    await guardarMidia(bytes, tipo ?? undefined, filename, wamid, clinic, conv, telefone);
  } catch (e) {
    console.error("midia zernio:", e instanceof Error ? e.message : e);
  }
}

async function webhookZernio(req: Request): Promise<Response> {
  const raw = await req.text();
  const segredo = Deno.env.get("ZERNIO_WEBHOOK_SECRET") ?? "";
  const assinatura = (req.headers.get("x-zernio-signature") ?? "").toLowerCase();
  if (!segredo || !(await confere(raw, assinatura, segredo))) {
    return new Response("invalid signature", { status: 401 });
  }

  let body: any;
  try { body = JSON.parse(raw); } catch { return new Response("ok", { status: 200 }); }

  const evento = String(body?.event ?? "");
  const conta = String(body?.account?.accountId ?? body?.account?.id ?? "");
  const phoneId = `zernio:${conta}`;

  const { data: conn } = conta
    ? await sb.from("clinic_whatsapp").select("clinic_id").eq("phone_number_id", phoneId).maybeSingle()
    : { data: null };

  try {
    await sb.from("webhook_events").insert({
      event_type: evento || "zernio", origem: "zernio", clinic_id: conn?.clinic_id ?? null, payload: body,
    });
  } catch (e) {
    console.error("webhook_events zernio", e instanceof Error ? e.message : e);
  }
  if (!conn || body?.test === true) return new Response("ok", { status: 200 });

  try {
    const m = body?.message ?? {};
    const convZernio = String(body?.conversation?.id ?? m?.conversationId ?? "");

    if (evento === "account.disconnected") {
      await sb.from("clinic_whatsapp").update({
        status: "pendente", conexao_erro: "Zernio: " + (body?.account?.reason ?? "conta desconectada"),
        verificado_em: new Date().toISOString(),
      }).eq("clinic_id", conn.clinic_id);
      return new Response("ok", { status: 200 });
    }

    if (STATUS_ZERNIO[evento]) {
      const e = body?.error;
      await sb.rpc("nx_wa_status", {
        p_phone_number_id: phoneId,
        p_wamid: m?.platformMessageId ?? null,
        p_status: STATUS_ZERNIO[evento],
        p_ts: Math.floor(Date.parse(body?.statusAt ?? "") / 1000) || 0,
        p_erro: e ? { code: e.code, title: e.title, message: e.message } : null,
      });
      return new Response("ok", { status: 200 });
    }

    // Equipe respondeu pelo app do celular (coexistencia): entra como saida
    // da equipe e pausa a IA. O que a propria NexoClin mandou ja foi gravado.
    if (evento === "message.sent") {
      if (m?.source !== "whatsapp_business_app") return new Response("ok", { status: 200 });
      const para = String(body?.conversation?.participantId ?? "").replace(/\D/g, "");
      if (!para) return new Response("ok", { status: 200 });
      await lembrarConversaZernio(conta, para, convZernio);
      const tipo = zernioTipo(m);
      await sb.rpc("nx_wa_eco", {
        p_phone_number_id: phoneId, p_to: para, p_type: tipo,
        p_body: m?.text ?? `[${tipo} enviada pelo celular]`,
        p_wamid: m?.platformMessageId ?? null,
        p_ts: Math.floor(Date.parse(m?.sentAt ?? "") / 1000) || 0,
        p_media_id: null,
      });
      return new Response("ok", { status: 200 });
    }

    if (evento !== "message.received" || m?.platform !== "whatsapp") return new Response("ok", { status: 200 });
    // Outro agente (Meta Business Agent) esta com a conversa: so observa.
    if (body?.metadata?.standby === true) return new Response("ok", { status: 200 });

    const fone = String(m?.sender?.phoneNumber ?? m?.sender?.id ?? body?.conversation?.participantId ?? "")
      .replace(/\D/g, "");
    if (!fone) return new Response("ok", { status: 200 });
    await lembrarConversaZernio(conta, fone, convZernio);

    const texto = (m?.text ?? "").trim() || null;
    if (CMD_ZERAR.includes((texto ?? "").toLowerCase())) {
      EdgeRuntime.waitUntil(zerarConversa(phoneId, fone));
      return new Response("ok", { status: 200 });
    }

    const tipo = zernioTipo(m);
    const anexo = m?.attachments?.[0] ?? null;
    const wamid = m?.platformMessageId ?? null;
    const { data: ctx } = await sb.rpc("nx_wa_ingest", {
      p_phone_number_id: phoneId,
      p_from: fone,
      p_nome: m?.sender?.name ?? body?.conversation?.participantName ?? null,
      p_type: tipo,
      p_body: texto,
      p_wamid: wamid,                     // idempotencia: a Zernio reentrega
      p_ts: Math.floor(Date.parse(m?.sentAt ?? "") / 1000) || 0,
      p_payload: m,
      p_media_id: anexo?.url ?? null,
    });

    if (ctx?.conversation_id && ctx?.clinic_id) {
      // Midia (com ou sem legenda) responde depois de baixada, ja com o conteudo.
      if (texto && !anexo) {
        EdgeRuntime.waitUntil(responderBot(ctx.conversation_id, texto, fone, ctx.clinic_id, wamid));
      }
      // A Meta apaga a midia depois de um tempo: baixa ja.
      if (anexo?.url && wamid) {
        EdgeRuntime.waitUntil(baixarMidiaZernio(
          anexo.url, wamid, ctx.clinic_id, ctx.conversation_id, fone, anexo?.mimeType, anexo?.payload?.filename,
        ));
      }
    }
  } catch (e) {
    console.error("wa-webhook zernio", e instanceof Error ? e.message : e);
  }
  return new Response("ok", { status: 200 });
}

Deno.serve(async (req) => {
  const url = new URL(req.url);

  // uazapi: o segredo da conexao vem na URL (a uazapi nao assina o webhook).
  const uazChave = url.searchParams.get("uaz");
  if (uazChave && req.method === "POST") return await webhookUazapi(uazChave, req);

  // Zernio: assina com header proprio.
  if (req.method === "POST" && req.headers.has("x-zernio-signature")) return await webhookZernio(req);

  // 0) Saude: diz se os segredos estao configurados, sem revelar valor algum.
  if (url.pathname.endsWith("/health")) {
    return Response.json({
      ok: true,
      app_secret_configurado: !!Deno.env.get("WA_APP_SECRET"),
      app_secret_mvf_configurado: !!Deno.env.get("WA_APP_SECRET_MVF"),
      verify_token_configurado: !!Deno.env.get("WA_VERIFY_TOKEN"),
      zernio_api_key_configurada: !!Deno.env.get("ZERNIO_API_KEY"),
      zernio_webhook_secret_configurado: !!Deno.env.get("ZERNIO_WEBHOOK_SECRET"),
    });
  }

  // 1) Verificacao do webhook (GET). O verify token e do APP, nao da clinica:
  //    com app unico a Meta chama esta URL uma vez so.
  if (req.method === "GET") {
    const modo = url.searchParams.get("hub.mode");
    const token = url.searchParams.get("hub.verify_token");
    const desafio = url.searchParams.get("hub.challenge") ?? "";
    const esperado = Deno.env.get("WA_VERIFY_TOKEN") ?? "";
    if (modo === "subscribe" && esperado && token === esperado) {
      return new Response(desafio, { status: 200, headers: { "content-type": "text/plain" } });
    }
    return new Response("forbidden", { status: 403 });
  }

  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });

  const raw = await req.text();

  // 2) Assinatura. Sem isso qualquer um injeta mensagem na fila de uma clinica.
  const ok = await assinaturaValida(raw, req.headers.get("x-hub-signature-256"));
  if (!ok) return new Response("invalid signature", { status: 401 });

  let body: any;
  try { body = JSON.parse(raw); } catch { return new Response("ok", { status: 200 }); }

  // 3) Rede de seguranca: guarda o payload cru ANTES de processar. Enquanto
  //    nx_wa_ingest/nx_wa_status nao existirem, nada se perde.
  try {
    await sb.from("webhook_events").insert({
      event_type: "whatsapp", origem: "meta_cloud", payload: body,
    });
  } catch (e) {
    console.error("webhook_events", e instanceof Error ? e.message : e);
  }

  // 4) Processa tudo, mas SEMPRE responde 200: erro nosso faz a Meta reentregar
  //    em backoff e, depois de muitas falhas, desinscrever o app.
  try {
    for (const entry of body?.entry ?? []) {
      for (const change of entry?.changes ?? []) {
        // Coexistencia: mensagem que a equipe mandou pelo app do celular.
        // Grava na conversa como saida da equipe e pausa a IA. history e
        // smb_app_state_sync ficam so no webhook_events (gravado acima).
        if (change?.field === "smb_message_echoes") {
          const ve = change.value ?? {};
          const phoneEco = ve.metadata?.phone_number_id;
          if (!phoneEco) continue;
          for (const eco of ve.message_echoes ?? []) {
            // edicao e exclusao nao sao mensagem nova
            if (eco?.type === "edit" || eco?.type === "revoke") continue;
            await sb.rpc("nx_wa_eco", {
              p_phone_number_id: phoneEco,
              p_to: String(eco?.to ?? ""),
              p_type: eco?.type ?? "text",
              p_body: corpoDe(eco) ?? `[${eco?.type ?? "mensagem"} enviada pelo celular]`,
              p_wamid: eco?.id ?? null,
              p_ts: Number(eco?.timestamp ?? 0),
              p_media_id: midiaDe(eco)?.id ?? null,
            });
          }
          continue;
        }
        if (change?.field !== "messages") continue;
        const v = change.value ?? {};
        const phoneId = v.metadata?.phone_number_id;   // <- a chave do roteamento
        if (!phoneId) continue;

        const nome = v.contacts?.[0]?.profile?.name ?? null;

        for (const msg of v.messages ?? []) {
          // Comando de teste: nao entra na fila, nao passa pelo bot.
          const cmd = (corpoDe(msg) ?? "").trim().toLowerCase();
          if (CMD_ZERAR.includes(cmd)) {
            EdgeRuntime.waitUntil(zerarConversa(phoneId, msg.from));
            continue;
          }

          const mid = midiaDe(msg);
          const { data: ctx } = await sb.rpc("nx_wa_ingest", {
            p_phone_number_id: phoneId,
            p_from: msg.from,
            p_nome: nome,
            p_type: msg.type,
            p_body: corpoDe(msg),
            p_wamid: msg.id,                  // idempotencia: a Meta reentrega
            p_ts: Number(msg.timestamp ?? 0),
            p_payload: msg,
            p_media_id: mid?.id ?? null,
          });

          // Triagem automatica: o bot le a mensagem e responde, se for o caso.
          // Tambem fora da resposta do webhook, pelo mesmo motivo da midia.
          if (ctx?.conversation_id && ctx?.clinic_id) {
            const texto = corpoDe(msg);
            // Midia (com ou sem legenda) responde depois de baixada, ja com o conteudo.
            if (texto && !mid) {
              EdgeRuntime.waitUntil(
                responderBot(ctx.conversation_id, texto, msg.from, ctx.clinic_id, msg.id),
              );
            }
          }

          // Arquivo: baixa DEPOIS de responder 200. Se demorar aqui dentro, a
          // Meta considera falha e reentrega o evento inteiro.
          if (mid && ctx?.clinic_id && ctx?.conversation_id) {
            const { data: conn } = await sb.from("clinic_whatsapp")
              .select("access_token").eq("clinic_id", ctx.clinic_id).single();
            if (conn?.access_token) {
              EdgeRuntime.waitUntil(baixarMidia(
                mid.id, msg.id, ctx.clinic_id, ctx.conversation_id,
                conn.access_token, msg.from, mid.mime, mid.filename,
              ));
            }
          }
        }

        for (const st of v.statuses ?? []) {
          await sb.rpc("nx_wa_status", {
            p_phone_number_id: phoneId,
            p_wamid: st.id,
            p_status: st.status,              // sent | delivered | read | failed
            p_ts: Number(st.timestamp ?? 0),
            p_erro: st.errors?.[0] ?? null,   // 131047, 131026, 470...
          });
        }
      }
    }
  } catch (e) {
    console.error("wa-webhook", e instanceof Error ? e.message : e);
  }

  return new Response("ok", { status: 200 });
});
