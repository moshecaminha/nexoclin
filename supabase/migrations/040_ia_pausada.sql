-- Pausa geral da IA por clinica. Com clinics.ia_pausada = true:
--  - toda conversa da clinica nasce (ou fica) com bot_active = false;
--  - a wa-webhook e a wa-sweep nao chamam o agente nem mandam aviso automatico.
-- Aplicada em 19/10 em carater de urgencia na clinica conectada pela Zernio.
alter table public.clinics add column if not exists ia_pausada boolean not null default false;

create or replace function public.nx_trg_conv_ia_pausada() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if exists (select 1 from public.clinics c where c.id = new.clinic_id and c.ia_pausada) then
    new.bot_active := false;
  end if;
  return new;
end $$;

drop trigger if exists trg_conv_ia_pausada on public.conversations;
create trigger trg_conv_ia_pausada before insert or update of bot_active on public.conversations
  for each row execute function public.nx_trg_conv_ia_pausada();
