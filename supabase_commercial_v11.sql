-- Finsave comercial v11: continuidad de planes, notificaciones, documentos y soporte trazable.

alter table public.finsave_plan_change_requests
  add column if not exists effective_mode text not null default 'renewal',
  add column if not exists effective_at timestamptz,
  add column if not exists activated_at timestamptz,
  add column if not exists previous_period_end date;

alter table public.finsave_plan_change_requests
  drop constraint if exists finsave_plan_change_requests_status_check;
alter table public.finsave_plan_change_requests
  add constraint finsave_plan_change_requests_status_check
  check(status in('pending_payment','payment_review','pending_approval','scheduled','approved','rejected','cancelled'));
drop index if exists public.finsave_one_open_plan_request;
create unique index finsave_one_open_plan_request on public.finsave_plan_change_requests(user_id)
where status in('pending_payment','payment_review','pending_approval','scheduled');

create table if not exists public.finsave_notifications(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  type text not null default 'info',
  title text not null,
  body text not null,
  action_key text not null default '',
  metadata jsonb not null default '{}'::jsonb,
  is_read boolean not null default false,
  read_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists finsave_notifications_user_idx
  on public.finsave_notifications(user_id,is_read,created_at desc);
alter table public.finsave_notifications enable row level security;
drop policy if exists "notifications_read_own" on public.finsave_notifications;
create policy "notifications_read_own" on public.finsave_notifications
  for select to authenticated using(user_id=auth.uid() or public.is_finsave_admin());
drop policy if exists "notifications_update_own" on public.finsave_notifications;
create policy "notifications_update_own" on public.finsave_notifications
  for update to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
drop policy if exists "notifications_admin_insert" on public.finsave_notifications;
create policy "notifications_admin_insert" on public.finsave_notifications
  for insert to authenticated with check(public.is_finsave_admin());
grant select,insert,update on public.finsave_notifications to authenticated;

create or replace function public.send_finsave_notification(
  target_user uuid, notification_title text, notification_body text,
  notification_type text default 'info', notification_action text default ''
) returns uuid language plpgsql security definer set search_path=public as $$
declare new_id uuid;
begin
  if not public.is_finsave_admin() then raise exception 'Acceso denegado'; end if;
  if nullif(trim(notification_title),'') is null or nullif(trim(notification_body),'') is null then
    raise exception 'Completa título y mensaje';
  end if;
  insert into public.finsave_notifications(user_id,type,title,body,action_key,created_by)
  values(target_user,coalesce(nullif(trim(notification_type),''),'info'),trim(notification_title),trim(notification_body),coalesce(notification_action,''),auth.uid())
  returning id into new_id;
  return new_id;
end;$$;
grant execute on function public.send_finsave_notification(uuid,text,text,text,text) to authenticated;

create or replace function public.apply_due_finsave_plan_changes()
returns integer language plpgsql security definer set search_path=public as $$
declare r record; p public.finsave_plans%rowtype; applied integer := 0; start_day date;
begin
  for r in
    select * from public.finsave_plan_change_requests
    where status='scheduled' and effective_at<=now()
    for update skip locked
  loop
    select * into p from public.finsave_plans where id=r.requested_plan_id;
    start_day := greatest(current_date,r.effective_at::date);
    insert into public.finsave_subscriptions(user_id,plan_id,status,starts_at,ends_at,auto_renew,notes)
    values(r.user_id,p.id,'active',start_day,case when p.is_lifetime then null else start_day+(p.duration_days-1) end,false,'Cambio programado aplicado automáticamente')
    on conflict(user_id) do update set plan_id=excluded.plan_id,status='active',starts_at=excluded.starts_at,
      ends_at=excluded.ends_at,auto_renew=excluded.auto_renew,notes=excluded.notes;
    update public.finsave_plan_change_requests set status='approved',activated_at=now() where id=r.id;
    insert into public.finsave_notifications(user_id,type,title,body,action_key,metadata)
    values(r.user_id,'plan','Tu nuevo plan ya está activo',
      'El cambio a '||p.name||' se aplicó en la fecha programada. Puedes revisar la nueva vigencia en tu perfil.',
      'billing',jsonb_build_object('request_id',r.id,'plan_id',p.id));
    applied := applied+1;
  end loop;
  return applied;
end;$$;
grant execute on function public.apply_due_finsave_plan_changes() to authenticated;

create or replace function public.review_finsave_plan_request_mode(
  request_id uuid, approve boolean, note text default '', activation_mode text default 'renewal'
) returns text language plpgsql security definer set search_path=public as $$
declare r public.finsave_plan_change_requests%rowtype; p public.finsave_plans%rowtype;
  s public.finsave_subscriptions%rowtype; effective_day date; result text;
begin
  if not public.is_finsave_admin() then raise exception 'Acceso denegado'; end if;
  select * into r from public.finsave_plan_change_requests where id=request_id for update;
  if r.id is null then raise exception 'Solicitud no disponible'; end if;
  if not approve and r.status in('pending_payment','payment_review','pending_approval','scheduled') then
    update public.finsave_plan_change_requests set status='rejected',admin_note=note,reviewed_by=auth.uid(),reviewed_at=now()
    where id=request_id;
    insert into public.finsave_notifications(user_id,type,title,body,action_key,created_by)
    values(r.user_id,'plan','Solicitud de plan rechazada',
      coalesce(nullif(trim(note),''),'No fue posible aprobar el cambio. Contáctanos por el chat si necesitas ayuda.'),
      'billing',auth.uid());
    return 'rejected';
  end if;
  if r.status<>'pending_approval' then raise exception 'Primero debes aprobar el pago asociado'; end if;
  select * into p from public.finsave_plans where id=r.requested_plan_id;
  select * into s from public.finsave_subscriptions where user_id=r.user_id;

  if activation_mode='immediate' then
    effective_day:=current_date;
  elsif s.id is not null and s.ends_at is not null and s.ends_at>=current_date then
    effective_day:=s.ends_at+1;
  else
    effective_day:=current_date;
  end if;

  if effective_day>current_date then
    update public.finsave_plan_change_requests set status='scheduled',effective_mode='renewal',
      effective_at=effective_day::timestamptz,previous_period_end=s.ends_at,admin_note=note,
      reviewed_by=auth.uid(),reviewed_at=now()
    where id=request_id;
    insert into public.finsave_notifications(user_id,type,title,body,action_key,created_by,metadata)
    values(r.user_id,'plan','Cambio de plan aprobado',
      'Tu plan actual seguirá activo hasta el '||to_char(s.ends_at,'DD/MM/YYYY')||
      '. El plan '||p.name||' comenzará el '||to_char(effective_day,'DD/MM/YYYY')||'. No perderás días pagados.',
      'billing',auth.uid(),jsonb_build_object('request_id',r.id,'effective_at',effective_day));
    result:='scheduled';
  else
    insert into public.finsave_subscriptions(user_id,plan_id,status,starts_at,ends_at,auto_renew,notes)
    values(r.user_id,p.id,'active',current_date,case when p.is_lifetime then null else current_date+(p.duration_days-1) end,false,'Cambio de plan aprobado')
    on conflict(user_id) do update set plan_id=excluded.plan_id,status='active',starts_at=excluded.starts_at,
      ends_at=excluded.ends_at,auto_renew=excluded.auto_renew,notes=excluded.notes;
    update public.finsave_plan_change_requests set status='approved',effective_mode='immediate',
      effective_at=now(),activated_at=now(),previous_period_end=s.ends_at,admin_note=note,
      reviewed_by=auth.uid(),reviewed_at=now()
    where id=request_id;
    insert into public.finsave_notifications(user_id,type,title,body,action_key,created_by,metadata)
    values(r.user_id,'plan','Cambio de plan aprobado',
      'Tu plan '||p.name||' ya está activo. Revisa la nueva vigencia en tu perfil.',
      'billing',auth.uid(),jsonb_build_object('request_id',r.id));
    result:='approved';
  end if;
  return result;
end;$$;
grant execute on function public.review_finsave_plan_request_mode(uuid,boolean,text,text) to authenticated;

create or replace function public.admin_schedule_finsave_plan_change(
  target_user uuid, requested_plan uuid, note text default ''
) returns uuid language plpgsql security definer set search_path=public as $$
declare s public.finsave_subscriptions%rowtype; p public.finsave_plans%rowtype;
  effective_day date; request_id uuid;
begin
  if not public.is_finsave_admin() then raise exception 'Acceso denegado'; end if;
  if exists(select 1 from public.finsave_plan_change_requests where user_id=target_user and status in('pending_payment','payment_review','pending_approval','scheduled')) then
    raise exception 'La persona ya tiene un cambio de plan en curso';
  end if;
  select * into s from public.finsave_subscriptions where user_id=target_user for update;
  select * into p from public.finsave_plans where id=requested_plan and is_active;
  if p.id is null then raise exception 'Plan no disponible'; end if;
  effective_day:=case when s.ends_at is not null and s.ends_at>=current_date then s.ends_at+1 else current_date end;
  if effective_day=current_date then
    insert into public.finsave_subscriptions(user_id,plan_id,status,starts_at,ends_at,auto_renew,notes)
    values(target_user,p.id,'active',current_date,case when p.is_lifetime then null else current_date+(p.duration_days-1) end,false,note)
    on conflict(user_id) do update set plan_id=excluded.plan_id,status='active',starts_at=excluded.starts_at,ends_at=excluded.ends_at,notes=excluded.notes;
    insert into public.finsave_plan_change_requests(user_id,current_plan_id,requested_plan_id,payment_method,amount_clp,status,effective_mode,effective_at,activated_at,previous_period_end,admin_note,reviewed_by,reviewed_at)
    values(target_user,s.plan_id,p.id,'transfer',0,'approved','immediate',now(),now(),s.ends_at,note,auth.uid(),now()) returning id into request_id;
  else
    insert into public.finsave_plan_change_requests(user_id,current_plan_id,requested_plan_id,payment_method,amount_clp,status,effective_mode,effective_at,previous_period_end,admin_note,reviewed_by,reviewed_at)
    values(target_user,s.plan_id,p.id,'transfer',0,'scheduled','renewal',effective_day::timestamptz,s.ends_at,note,auth.uid(),now()) returning id into request_id;
  end if;
  insert into public.finsave_notifications(user_id,type,title,body,action_key,created_by,metadata)
  values(target_user,'plan',case when effective_day>current_date then 'Cambio de plan programado' else 'Plan actualizado' end,
    case when effective_day>current_date then 'Tu plan actual continúa hasta el '||to_char(s.ends_at,'DD/MM/YYYY')||'. '||p.name||' comenzará el '||to_char(effective_day,'DD/MM/YYYY')||'.'
    else 'Tu plan '||p.name||' ya está activo.' end,'billing',auth.uid(),jsonb_build_object('request_id',request_id));
  return request_id;
end;$$;
grant execute on function public.admin_schedule_finsave_plan_change(uuid,uuid,text) to authenticated;

-- Las facturas de nuevas solicitudes reflejan el período real posterior al plan vigente.
create or replace function public.submit_finsave_plan_request(requested_plan uuid, method text default 'transfer')
returns uuid language plpgsql security definer set search_path=public as $$
declare p public.finsave_plans%rowtype; current_plan uuid; inv_id uuid; req_id uuid;
  current_end date; period_begin date;
begin
  perform public.apply_due_finsave_plan_changes();
  if method <> 'transfer' then raise exception 'El pago automático aún no está habilitado'; end if;
  if exists(select 1 from public.finsave_plan_change_requests where user_id=auth.uid() and status in('pending_payment','payment_review','pending_approval','scheduled')) then
    raise exception 'Ya existe una solicitud o cambio programado';
  end if;
  select * into p from public.finsave_plans where id=requested_plan and is_active and not is_admin_plan;
  if p.id is null then raise exception 'Plan no disponible'; end if;
  select plan_id,ends_at into current_plan,current_end from public.finsave_subscriptions where user_id=auth.uid();
  if current_plan=requested_plan then raise exception 'Ese ya es tu plan actual'; end if;
  period_begin:=case when current_end is not null and current_end>=current_date then current_end+1 else current_date end;
  insert into public.finsave_invoices(user_id,plan_id,period_start,period_end,due_date,amount_clp,status,notes)
  values(auth.uid(),p.id,period_begin,case when p.is_lifetime then period_begin else period_begin+(p.duration_days-1) end,
    current_date+5,p.price_clp,'pending','Solicitud de cambio de plan · activación al término del período vigente')
  returning id into inv_id;
  insert into public.finsave_plan_change_requests(user_id,current_plan_id,requested_plan_id,payment_method,amount_clp,invoice_id,status,effective_mode,effective_at,previous_period_end)
  values(auth.uid(),current_plan,p.id,method,p.price_clp,inv_id,'pending_payment','renewal',period_begin::timestamptz,current_end)
  returning id into req_id;
  return req_id;
end;$$;
grant execute on function public.submit_finsave_plan_request(uuid,text) to authenticated;

alter table public.finsave_support_conversations
  add column if not exists category text not null default 'general',
  add column if not exists assigned_admin_id uuid references auth.users(id) on delete set null,
  add column if not exists first_response_at timestamptz;

create table if not exists public.finsave_support_notes(
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.finsave_support_conversations(id) on delete cascade,
  admin_id uuid references auth.users(id) on delete set null,
  body text not null,
  created_at timestamptz not null default now()
);
alter table public.finsave_support_notes enable row level security;
drop policy if exists "support_notes_admin_all" on public.finsave_support_notes;
create policy "support_notes_admin_all" on public.finsave_support_notes
  for all to authenticated using(public.is_finsave_admin()) with check(public.is_finsave_admin());
grant select,insert,update,delete on public.finsave_support_notes to authenticated;

create or replace function public.add_finsave_support_note(target_conversation uuid, note_body text)
returns uuid language plpgsql security definer set search_path=public as $$
declare note_id uuid;
begin
  if not public.is_finsave_admin() then raise exception 'Acceso denegado'; end if;
  if nullif(trim(note_body),'') is null then raise exception 'Escribe una nota'; end if;
  insert into public.finsave_support_notes(conversation_id,admin_id,body)
  values(target_conversation,auth.uid(),trim(note_body)) returning id into note_id;
  return note_id;
end;$$;
grant execute on function public.add_finsave_support_note(uuid,text) to authenticated;

create or replace function public.classify_finsave_support_conversation(
  target_conversation uuid, new_category text
) returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.is_finsave_admin() then raise exception 'Acceso denegado'; end if;
  if new_category not in('general','access','billing','payment','plan','data','incident') then
    raise exception 'Categoría inválida';
  end if;
  update public.finsave_support_conversations
  set category=new_category,assigned_admin_id=coalesce(assigned_admin_id,auth.uid()),updated_at=now()
  where id=target_conversation;
end;$$;
grant execute on function public.classify_finsave_support_conversation(uuid,text) to authenticated;
