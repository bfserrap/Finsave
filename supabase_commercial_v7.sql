-- Finsave comercial v7: chat de soporte tipo Intercom y clasificación tributaria segura.

-- El número del RUT no define por sí solo si el receptor es persona o empresa.
-- El cliente entrega sus antecedentes; Finsave confirma la clasificación y el DTE.
create or replace function public.protect_finsave_document_type()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if public.is_finsave_admin() then return new; end if;
  if tg_op='UPDATE' then
    new.document_preference := old.document_preference;
    new.taxpayer_type := old.taxpayer_type;
  else
    new.document_preference := 'boleta';
    new.taxpayer_type := 'unknown';
  end if;
  return new;
end;$$;

create table if not exists public.finsave_support_conversations(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  status text not null default 'open' check(status in('open','closed')),
  subject text not null default 'Soporte general',
  last_message_preview text not null default '',
  last_message_at timestamptz not null default now(),
  unread_user integer not null default 0 check(unread_user>=0),
  unread_admin integer not null default 0 check(unread_admin>=0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.finsave_support_messages(
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.finsave_support_conversations(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  sender_role text not null check(sender_role in('user','admin')),
  body text not null check(char_length(trim(body)) between 1 and 1500),
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists finsave_support_conversations_last_idx on public.finsave_support_conversations(last_message_at desc);
create index if not exists finsave_support_messages_conversation_idx on public.finsave_support_messages(conversation_id,created_at);

alter table public.finsave_support_conversations enable row level security;
alter table public.finsave_support_messages enable row level security;

drop policy if exists "support_conversations_read" on public.finsave_support_conversations;
create policy "support_conversations_read" on public.finsave_support_conversations for select to authenticated
using(user_id=auth.uid() or public.is_finsave_admin());

drop policy if exists "support_messages_read" on public.finsave_support_messages;
create policy "support_messages_read" on public.finsave_support_messages for select to authenticated
using(exists(select 1 from public.finsave_support_conversations c where c.id=conversation_id and (c.user_id=auth.uid() or public.is_finsave_admin())));

grant select on public.finsave_support_conversations,public.finsave_support_messages to authenticated;

create or replace function public.send_finsave_support_message(message_body text,target_conversation uuid default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare
  uid uuid := auth.uid();
  admin_sender boolean := public.is_finsave_admin();
  conv public.finsave_support_conversations%rowtype;
  clean_body text := trim(coalesce(message_body,''));
begin
  if uid is null then raise exception 'Debes iniciar sesión'; end if;
  if char_length(clean_body)<1 or char_length(clean_body)>1500 then raise exception 'Mensaje inválido'; end if;

  if admin_sender and target_conversation is not null then
    select * into conv from public.finsave_support_conversations where id=target_conversation for update;
    if conv.id is null then raise exception 'Conversación no encontrada'; end if;
  else
    select * into conv from public.finsave_support_conversations where user_id=uid for update;
    if conv.id is null then
      insert into public.finsave_support_conversations(user_id,status) values(uid,'open') returning * into conv;
    end if;
  end if;

  insert into public.finsave_support_messages(conversation_id,sender_id,sender_role,body)
  values(conv.id,uid,case when admin_sender then 'admin' else 'user' end,clean_body);

  update public.finsave_support_conversations set
    status='open',last_message_preview=left(clean_body,180),last_message_at=now(),updated_at=now(),
    unread_user=case when admin_sender then unread_user+1 else unread_user end,
    unread_admin=case when admin_sender then unread_admin else unread_admin+1 end
  where id=conv.id;
  return conv.id;
end;$$;

create or replace function public.mark_finsave_support_read(target_conversation uuid)
returns void language plpgsql security definer set search_path=public as $$
declare admin_reader boolean := public.is_finsave_admin();
begin
  if not exists(select 1 from public.finsave_support_conversations c where c.id=target_conversation and (c.user_id=auth.uid() or admin_reader)) then raise exception 'Acceso denegado'; end if;
  update public.finsave_support_conversations set
    unread_admin=case when admin_reader then 0 else unread_admin end,
    unread_user=case when admin_reader then unread_user else 0 end,
    updated_at=now()
  where id=target_conversation;
  update public.finsave_support_messages set read_at=coalesce(read_at,now())
  where conversation_id=target_conversation and sender_role<>case when admin_reader then 'admin' else 'user' end;
end;$$;

create or replace function public.set_finsave_support_status(target_conversation uuid,new_status text)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.is_finsave_admin() then raise exception 'Acceso denegado'; end if;
  if new_status not in('open','closed') then raise exception 'Estado inválido'; end if;
  update public.finsave_support_conversations set status=new_status,updated_at=now() where id=target_conversation;
  if not found then raise exception 'Conversación no encontrada'; end if;
end;$$;

grant execute on function public.send_finsave_support_message(text,uuid) to authenticated;
grant execute on function public.mark_finsave_support_read(uuid) to authenticated;
grant execute on function public.set_finsave_support_status(uuid,text) to authenticated;

-- Realtime permite que la interfaz reciba respuestas sin recargar.
do $$ begin
  alter publication supabase_realtime add table public.finsave_support_conversations;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.finsave_support_messages;
exception when duplicate_object then null; end $$;

