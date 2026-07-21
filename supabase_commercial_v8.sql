-- Finsave comercial v8: centro SAC tipo Intercom, prioridades, pospuestos y macros.
-- Ejecutar después de supabase_commercial_v7.sql.

alter table public.finsave_support_conversations
  drop constraint if exists finsave_support_conversations_status_check;

alter table public.finsave_support_conversations
  add constraint finsave_support_conversations_status_check
  check(status in('open','snoozed','closed'));

alter table public.finsave_support_conversations
  add column if not exists priority text not null default 'normal',
  add column if not exists snoozed_until timestamptz,
  add column if not exists closed_at timestamptz;

alter table public.finsave_support_conversations
  drop constraint if exists finsave_support_conversations_priority_check;

alter table public.finsave_support_conversations
  add constraint finsave_support_conversations_priority_check
  check(priority in('low','normal','high','urgent'));

create index if not exists finsave_support_conversations_queue_idx
  on public.finsave_support_conversations(status,priority,last_message_at desc);

create table if not exists public.finsave_support_macros(
  id uuid primary key default gen_random_uuid(),
  shortcut text not null unique check(shortcut ~ '^[a-z0-9_-]{1,30}$'),
  title text not null check(char_length(trim(title)) between 1 and 80),
  body text not null check(char_length(trim(body)) between 1 and 1500),
  active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.finsave_support_macros enable row level security;
drop policy if exists "support_macros_admin_all" on public.finsave_support_macros;
create policy "support_macros_admin_all" on public.finsave_support_macros
  for all to authenticated using(public.is_finsave_admin()) with check(public.is_finsave_admin());
grant select,insert,update,delete on public.finsave_support_macros to authenticated;

create or replace function public.manage_finsave_support_conversation(
  target_conversation uuid,
  new_status text default null,
  new_priority text default null,
  snooze_until timestamptz default null
)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.is_finsave_admin() then raise exception 'Acceso denegado'; end if;
  if new_status is not null and new_status not in('open','snoozed','closed') then raise exception 'Estado inválido'; end if;
  if new_priority is not null and new_priority not in('low','normal','high','urgent') then raise exception 'Prioridad inválida'; end if;
  if new_status='snoozed' and (snooze_until is null or snooze_until<=now()) then raise exception 'La fecha para posponer debe ser futura'; end if;

  update public.finsave_support_conversations set
    status=coalesce(new_status,status),
    priority=coalesce(new_priority,priority),
    snoozed_until=case when new_status='snoozed' then snooze_until when new_status is not null then null else finsave_support_conversations.snoozed_until end,
    closed_at=case when new_status='closed' then now() when new_status is not null then null else closed_at end,
    updated_at=now()
  where id=target_conversation;
  if not found then raise exception 'Conversación no encontrada'; end if;
end;$$;

grant execute on function public.manage_finsave_support_conversation(uuid,text,text,timestamptz) to authenticated;

-- Mantiene compatibilidad con llamadas anteriores y permite los nuevos estados.
create or replace function public.set_finsave_support_status(target_conversation uuid,new_status text)
returns void language plpgsql security definer set search_path=public as $$
begin
  perform public.manage_finsave_support_conversation(target_conversation,new_status,null,null);
end;$$;

-- Si el cliente vuelve a escribir, la conversación regresa automáticamente a abiertos.
create or replace function public.send_finsave_support_message(message_body text,target_conversation uuid default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare
  uid uuid := auth.uid(); admin_sender boolean := public.is_finsave_admin();
  conv public.finsave_support_conversations%rowtype; clean_body text := trim(coalesce(message_body,''));
begin
  if uid is null then raise exception 'Debes iniciar sesión'; end if;
  if char_length(clean_body)<1 or char_length(clean_body)>1500 then raise exception 'Mensaje inválido'; end if;
  if admin_sender and target_conversation is not null then
    select * into conv from public.finsave_support_conversations where id=target_conversation for update;
    if conv.id is null then raise exception 'Conversación no encontrada'; end if;
  else
    select * into conv from public.finsave_support_conversations where user_id=uid for update;
    if conv.id is null then insert into public.finsave_support_conversations(user_id,status) values(uid,'open') returning * into conv; end if;
  end if;
  insert into public.finsave_support_messages(conversation_id,sender_id,sender_role,body)
  values(conv.id,uid,case when admin_sender then 'admin' else 'user' end,clean_body);
  update public.finsave_support_conversations set
    status=case when admin_sender then status else 'open' end,
    snoozed_until=case when admin_sender then snoozed_until else null end,
    closed_at=case when admin_sender then closed_at else null end,
    last_message_preview=left(clean_body,180),last_message_at=now(),updated_at=now(),
    unread_user=case when admin_sender then unread_user+1 else unread_user end,
    unread_admin=case when admin_sender then unread_admin else unread_admin+1 end
  where id=conv.id;
  return conv.id;
end;$$;

grant execute on function public.send_finsave_support_message(text,uuid) to authenticated;
