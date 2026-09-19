// supabase/functions/wa-signup/index.ts
// Recebe o `code` do Embedded Signup e conecta a clinica sozinha:
// troca por token -> registra o numero no Cloud API -> assina a WABA ->
// aponta o webhook para ca -> grava. O gestor so clicou num botao.
//
// Coexistencia (numero que ja esta no app WhatsApp Business): NAO registra o
// numero (a Meta manda pular esse passo) e dispara as duas sincronizacoes
// (contatos e historico), que so podem ser feitas nas 24h apos conectar.
//
// Travas: o app MVF e compartilhado com outros sistemas. Esta funcao nunca
// escolhe numero ou WABA por posicao e nunca sobrescreve o webhook de um
// numero que ja entrega para outro lugar.
import { createClient } from "npm:@supabase/supabase-js@2";

const URL_SB = Deno.env.get("SUPABASE_URL")!;
const SRV    = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON   = Deno.env.get("SUPABASE_ANON_KEY")!;
const VERIFY = Deno.env.get("WA_VERIFY_TOKEN") ?? "";
const GRAPH  = `https://graph.facebook.com/${Deno.env.get("WA_GRAPH_VERSION") ?? "v21.0"}`;
const WEBHOOK = `${URL_SB}/functions/v1/wa-webhook`;

// Enquanto a NexoClin nao tiver Tech Provider proprio, o Embedded Signup roda
// no app do MVF. Trocar estas duas variaveis migra o fluxo, sem tocar no codigo.
const APP_ID     = Deno.env.get("MVF_APP_ID") ?? "";
const APP_SECRET = Deno.env.get("WA_APP_SECRET_MVF") ?? "";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "content-type": "application/json" } });

async function graph(path: string, token: string, init?: RequestInit) {
  const r = await fetch(`${GRAPH}/${path}`, {
    ...init,
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", ...(init?.headers ?? {}) },
  });
  return { ok: r.ok, body: await r.json().catch(() => ({})) };
}

/** Compara URLs de webhook ignorando query string e barra final. */
function mesmaUrl(a?: string | null, b?: string | null) {
  const n = (u?: string | null) => {
    if (!u) return "";
    try { const x = new URL(u); return (x.origin + x.pathname).replace(/\/+$/, ""); }
    catch { return u.replace(/\/+$/, ""); }
  };
  return !!a && !!b && n(a) === n(b);
}

const erroMeta = (r: { body: any }) => r.body?.error?.message ?? r.body;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST")    return json({ erro: "method not allowed" }, 405);

  const jwt = req.headers.get("Authorization") ?? "";
  if (!jwt.startsWith("Bearer ")) return json({ erro: "sem autenticação" }, 401);

  let b: any;
  try { b = await req.json(); } catch { return json({ erro: "json inválido" }, 400); }
  const { clinic_id, code, waba_id, phone_number_id, pin } = b ?? {};
  if (!clinic_id || !code) return json({ erro: "clinic_id e code são obrigatórios" }, 400);

  // 1) So gestor/admin conecta. Checado com o JWT de quem clicou.
  const comoUsuario = createClient(URL_SB, ANON, { global: { headers: { Authorization: jwt } } });
  const { data: pode, error: errPerm } = await comoUsuario.rpc("nx_can_admin", { p_clinic: clinic_id });
  if (errPerm || pode !== true) return json({ erro: "sem permissão", detalhe: errPerm?.message }, 403);

  const admin = createClient(URL_SB, SRV);
  const passos: Record<string, unknown> = {};

  // 2) Troca o code por token. Este e o unico ponto que usa o app secret.
  const troca = await fetch(
    `${GRAPH}/oauth/access_token?client_id=${APP_ID}&client_secret=${APP_SECRET}&code=${encodeURIComponent(code)}`,
  );
  const tk = await troca.json().catch(() => ({}));
  if (!troca.ok || !tk?.access_token) {
    return json({ erro: "falha ao trocar o código por token", meta: tk?.error ?? tk }, 502);
  }
  const token = tk.access_token as string;
  passos.token = "obtido";

  // 3) WABA e numero. Se o popup nao informou, so aceita quando existe UMA
  //    opcao. Escolher "o primeiro da lista" pode pegar numero de outro sistema.
  let waba = waba_id, phone = phone_number_id;
  if (!waba) {
    const w = await graph("me?fields=businesses{owned_whatsapp_business_accounts{id}}", token);
    const wabas: string[] = [];
    for (const bz of w.body?.businesses?.data ?? []) {
      for (const a of bz?.owned_whatsapp_business_accounts?.data ?? []) if (a?.id) wabas.push(a.id);
    }
    if (wabas.length !== 1) {
      return json({ erro: "não consegui identificar a conta do WhatsApp com segurança. Refaça a conexão escolhendo a conta.", wabas, passos }, 409);
    }
    waba = wabas[0];
  }
  if (!phone) {
    const p = await graph(`${waba}/phone_numbers?fields=id,display_phone_number`, token);
    const nums = (p.body?.data ?? []) as Array<{ id: string; display_phone_number?: string }>;
    if (nums.length !== 1) {
      return json({
        erro: "esta conta tem mais de um número (ou nenhum). Refaça a conexão escolhendo o número.",
        numeros: nums.map((n) => n.display_phone_number ?? n.id), passos,
      }, 409);
    }
    phone = nums[0].id;
  }
  passos.waba_id = waba; passos.phone_number_id = phone;

  // 4) Trava interna: o numero nao pode estar ligado a OUTRA clinica da NexoClin.
  const { data: dono } = await admin.from("clinic_whatsapp")
    .select("clinic_id").eq("phone_number_id", phone).neq("clinic_id", clinic_id).limit(1);
  if (dono?.length) {
    return json({ erro: "este número já está conectado em outra clínica da NexoClin.", passos }, 409);
  }

  // 5) Trava entre sistemas: le para onde o numero entrega hoje. Se ja aponta
  //    para outra URL, e de outro sistema: aborta sem sobrescrever.
  const antes = await graph(
    `${phone}?fields=display_phone_number,verified_name,webhook_configuration,is_on_biz_app,platform_type`, token);
  if (!antes.ok) return json({ erro: "não consegui ler o número na Meta", meta: erroMeta(antes), passos }, 502);
  const atual = antes.body?.webhook_configuration?.phone_number ?? null;
  if (atual && !mesmaUrl(atual, WEBHOOK)) {
    return json({
      erro: "este número já está conectado em outro sistema. Desconecte lá antes de conectar aqui.",
      webhook_atual: atual, passos,
    }, 409);
  }

  const coexistencia = b?.coexistencia === true || antes.body?.is_on_biz_app === true;
  passos.coexistencia = coexistencia;

  // 6) Registra o numero no Cloud API. Na coexistencia a Meta manda PULAR:
  //    o numero ja esta registrado pelo app.
  if (!coexistencia) {
    const reg = await graph(`${phone}/register`, token, {
      method: "POST",
      body: JSON.stringify({ messaging_product: "whatsapp", pin: pin ?? "159357" }),
    });
    passos.register = reg.ok ? "ok" : erroMeta(reg);
  } else {
    passos.register = "pulado (coexistência)";
  }

  // 7) Assina a WABA no app. So chama se o app ainda nao estiver assinado:
  //    POST sem corpo APAGA o override de WABA, se outro sistema tiver um.
  const subs = await graph(`${waba}/subscribed_apps`, token);
  const jaAssinado = (subs.body?.data ?? [])
    .some((s: any) => String(s?.whatsapp_business_api_data?.id ?? "") === String(APP_ID));
  if (jaAssinado) {
    passos.subscribed_apps = "já assinado";
  } else {
    const sub = await graph(`${waba}/subscribed_apps`, token, { method: "POST" });
    passos.subscribed_apps = sub.ok ? "ok" : erroMeta(sub);
  }

  // 8) Override do webhook NO NUMERO, e confere depois se pegou.
  const ov = await graph(phone, token, {
    method: "POST",
    body: JSON.stringify({ webhook_configuration: { override_callback_uri: WEBHOOK, verify_token: VERIFY } }),
  });
  const depois = await graph(`${phone}?fields=webhook_configuration`, token);
  const ovOk = ov.ok && mesmaUrl(depois.body?.webhook_configuration?.phone_number, WEBHOOK);
  passos.override_webhook = ovOk ? WEBHOOK : (ov.ok ? "não confirmado na releitura" : erroMeta(ov));

  // 9) Coexistencia: sincroniza contatos e historico. Cada chamada so pode ser
  //    feita UMA vez por conexao; se ja foi feita para este numero, nao repete.
  const { data: previo } = await admin.from("clinic_whatsapp")
    .select("phone_number_id, sync_contatos_id, sync_historico_id, sync_em")
    .eq("clinic_id", clinic_id).maybeSingle();
  const mesmoNumero = previo?.phone_number_id === phone;
  let syncContatos: string | null = mesmoNumero ? (previo?.sync_contatos_id ?? null) : null;
  let syncHistorico: string | null = mesmoNumero ? (previo?.sync_historico_id ?? null) : null;
  let syncEm: string | null = mesmoNumero ? (previo?.sync_em ?? null) : null;
  const falhas: string[] = [];

  if (coexistencia && ovOk) {
    if (!syncContatos) {
      const sc = await graph(`${phone}/smb_app_data`, token, {
        method: "POST", body: JSON.stringify({ messaging_product: "whatsapp", sync_type: "smb_app_state_sync" }),
      });
      if (sc.ok) syncContatos = sc.body?.request_id ?? "ok";
      else falhas.push("contatos: " + JSON.stringify(erroMeta(sc)));
    }
    if (!syncHistorico) {
      const sh = await graph(`${phone}/smb_app_data`, token, {
        method: "POST", body: JSON.stringify({ messaging_product: "whatsapp", sync_type: "history" }),
      });
      if (sh.ok) syncHistorico = sh.body?.request_id ?? "ok";
      else falhas.push("histórico: " + JSON.stringify(erroMeta(sh)));
    }
    if ((syncContatos || syncHistorico) && !syncEm) syncEm = new Date().toISOString();
    passos.sincronizacao = falhas.length ? falhas : "solicitada";
  }

  // 10) Estado final do numero e gravacao.
  const info = await graph(`${phone}?fields=display_phone_number,verified_name,is_on_biz_app,platform_type`, token);

  const motivo = !ovOk
    ? "o webhook do número não ficou apontado para a NexoClin"
    : (falhas.length ? "sincronização da coexistência: " + falhas.join("; ") : null);

  const { error: errUp } = await admin.from("clinic_whatsapp").upsert({
    clinic_id, provider: "meta_cloud",
    phone_number_id: phone, waba_id: waba, access_token: token,
    display_number: info.body?.display_phone_number ?? null,
    status: ovOk ? "conectado" : "pendente",
    coexistencia,
    is_on_biz_app: info.body?.is_on_biz_app ?? null,
    sync_contatos_id: syncContatos, sync_historico_id: syncHistorico, sync_em: syncEm,
    conexao_erro: motivo,
    verificado_em: new Date().toISOString(),
    connected_at: new Date().toISOString(), updated_at: new Date().toISOString(),
  }, { onConflict: "clinic_id" });
  if (errUp) return json({ erro: "falha ao gravar", detalhe: errUp.message, passos }, 500);

  return json({
    ok: ovOk,
    status: ovOk ? "conectado" : "pendente",
    erro: ovOk ? undefined : motivo,
    coexistencia,
    numero: info.body?.display_phone_number,
    nome_verificado: info.body?.verified_name,
    passos,
  });
});
