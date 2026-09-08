-- Antes de aplicar: gere um segredo aleatorio (openssl rand -hex 24), coloque
-- abaixo e tambem em WA_INTERNAL_SECRET nos secrets das Edge Functions.

-- Segredo interno no Vault: o cron le de la, em vez de ficar em texto puro
-- dentro de cron.job.
select vault.create_secret('TROQUE-POR-UM-SEGREDO-ALEATORIO', 'wa_internal_secret', 'segredo entre as Edge Functions do WhatsApp')
where not exists (select 1 from vault.secrets where name='wa_internal_secret');

-- Varredura de recuperacao a cada minuto.
select cron.unschedule('wa-sweep') where exists (select 1 from cron.job where jobname='wa-sweep');
select cron.schedule('wa-sweep', '* * * * *', $cron$
  select net.http_post(
    url := 'https://kzbazzwfdagfhyxuadqp.supabase.co/functions/v1/wa-sweep',
    headers := jsonb_build_object(
      'Content-Type','application/json',
      'x-nx-internal', (select decrypted_secret from vault.decrypted_secrets where name='wa_internal_secret')),
    body := '{}'::jsonb
  );
$cron$);
