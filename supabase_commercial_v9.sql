-- Finsave comercial v9: CSAT SAC por cierre y reapertura programada.
-- Ejecutar después de supabase_commercial_v8.sql.

create table if not exists public.finsave_support_csat(
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.finsave_support_conversations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  admin_id uuid references auth.users(id) on delete set null,
  rating smallint check(rating between 1 and 5),
  requested_at timestamptz not null default now(),
  responded_at timestamptz,
  cancelled_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists finsave_support_csat_month_idx on public.finsave_support_csat(requested_at desc,admin_id);
create unique index if not exists finsave_support_csat_one_pending_idx
  on public.finsave_support_csat(conversation_id) where rating is null and cancelled_at is null;

alter table public.finsave_support_csat enable row level security;
drop policy if exists "support_csat_read" on public.finsave_support_csat;
create policy "support_csat_read" on public.finsave_support_csat for select to authenticated
  using(user_id=auth.uid() or public.is_finsave_admin());
grant select on public.finsave_support_csat to authenticated;

create or replace function public.submit_finsave_support_csat(survey_id uuid,score integer)
returns void language plpgsql security definer set search_path=public as $$
begin
  if score not between 1 and 5 then raise exception 'Evaluación inválida'; end if;
  update public.finsave_support_csat set rating=score,responded_at=now()
  where id=survey_id and user_id=auth.uid() and rating is null and cancelled_at is null;
  if not found then raise exception 'Encuesta no disponible'; end if;
end;$$;
grant execute on function public.submit_finsave_support_csat(uuid,integer) to authenticated;

create or replace function public.manage_finsave_support_conversation(
  target_conversation uuid,
  new_status text default null,
  new_priority text default null,
  snooze_until timestamptz default null
)
returns void language plpgsql security definer set search_path=public as $$
declare conv public.finsave_support_conversations%rowtype;
begin
  if not public.is_finsave_admin() then raise exception 'Acceso denegado'; end if;
  if new_status is not null and new_status not in('open','snoozed','closed') then raise exception 'Estado inválido'; end if;
  if new_priority is not null and new_priority not in('low','normal','high','urgent') then raise exception 'Prioridad inválida'; end if;
  if new_status='snoozed' and (snooze_until is null or snooze_until<=now()) then raise exception 'La fecha para posponer debe ser futura'; end if;
  select * into conv from public.finsave_support_conversations where id=target_conversation for update;
  if conv.id is null then raise exception 'Conversación no encontrada'; end if;

  update public.finsave_support_conversations set
    status=coalesce(new_status,status), priority=coalesce(new_priority,priority),
    snoozed_until=case when new_status='snoozed' then snooze_until when new_status is not null then null else finsave_support_conversations.snoozed_until end,
    closed_at=case when new_status='closed' then now() when new_status is not null then null else closed_at end,
    updated_at=now()
  where id=target_conversation;

  if new_status='closed' and conv.status<>'closed' then
    insert into public.finsave_support_csat(conversation_id,user_id,admin_id)
    select conv.id,conv.user_id,auth.uid()
    where not exists(select 1 from public.finsave_support_csat s where s.conversation_id=conv.id and s.rating is null and s.cancelled_at is null);
  elsif new_status='open' then
    update public.finsave_support_csat set cancelled_at=now()
    where conversation_id=conv.id and rating is null and cancelled_at is null;
  end if;
end;$$;
grant execute on function public.manage_finsave_support_conversation(uuid,text,text,timestamptz) to authenticated;

-- Un nuevo mensaje del cliente reabre el caso y cancela una encuesta aún no respondida.
create or replace function public.send_finsave_support_message(message_body text,target_conversation uuid default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare uid uuid := auth.uid(); admin_sender boolean := public.is_finsave_admin(); conv public.finsave_support_conversations%rowtype; clean_body text := trim(coalesce(message_body,''));
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
  update public.finsave_support_conversations set status=case when admin_sender then status else 'open' end,
    snoozed_until=case when admin_sender then snoozed_until else null end,closed_at=case when admin_sender then closed_at else null end,
    last_message_preview=left(clean_body,180),last_message_at=now(),updated_at=now(),
    unread_user=case when admin_sender then unread_user+1 else unread_user end,
    unread_admin=case when admin_sender then unread_admin else unread_admin+1 end where id=conv.id;
  if not admin_sender then update public.finsave_support_csat set cancelled_at=now() where conversation_id=conv.id and rating is null and cancelled_at is null; end if;
  return conv.id;
end;$$;
grant execute on function public.send_finsave_support_message(text,uuid) to authenticated;
