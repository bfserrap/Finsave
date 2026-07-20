-- Finsave comercial v2: plan vitalicio, datos bancarios y comprobantes de pago.

alter table public.finsave_plans add column if not exists is_lifetime boolean not null default false;
alter table public.finsave_subscriptions alter column ends_at drop not null;

insert into public.finsave_plans(name,description,price_clp,duration_days,is_active,is_lifetime)
select 'Administrador','Acceso administrativo vitalicio',0,3650,true,true
where not exists(select 1 from public.finsave_plans where lower(name)='administrador');

update public.finsave_subscriptions s
set plan_id=p.id,status='active',starts_at=current_date,ends_at=null,auto_renew=false,notes='Acceso administrativo vitalicio'
from public.finsave_plans p, public.finsave_users u
where s.user_id=u.id and lower(u.email)='bryan.serrano.perez@icloud.com' and lower(p.name)='administrador';

create table if not exists public.finsave_commercial_settings(
  id smallint primary key default 1 check(id=1),
  bank_name text not null default '', account_type text not null default '',
  account_number text not null default '', account_holder text not null default '',
  account_rut text not null default '', account_email text not null default '',
  payment_instructions text not null default '', transfers_enabled boolean not null default false,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);
insert into public.finsave_commercial_settings(id) values(1) on conflict(id) do nothing;

create table if not exists public.finsave_payment_requests(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  invoice_id uuid references public.finsave_invoices(id) on delete set null,
  amount_clp integer not null check(amount_clp>0), transfer_date date not null,
  reference text not null default '', receipt_path text,
  status text not null default 'pending' check(status in ('pending','approved','rejected')),
  admin_note text not null default '', reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz, created_at timestamptz not null default now()
);
create index if not exists finsave_payment_requests_user_idx on public.finsave_payment_requests(user_id,status);

alter table public.finsave_commercial_settings enable row level security;
alter table public.finsave_payment_requests enable row level security;
drop policy if exists "settings_read_authenticated" on public.finsave_commercial_settings;
create policy "settings_read_authenticated" on public.finsave_commercial_settings for select to authenticated using(true);
drop policy if exists "settings_admin_write" on public.finsave_commercial_settings;
create policy "settings_admin_write" on public.finsave_commercial_settings for all to authenticated using(public.is_finsave_admin()) with check(public.is_finsave_admin());
drop policy if exists "payment_requests_read" on public.finsave_payment_requests;
create policy "payment_requests_read" on public.finsave_payment_requests for select to authenticated using(user_id=auth.uid() or public.is_finsave_admin());
drop policy if exists "payment_requests_user_insert" on public.finsave_payment_requests;
create policy "payment_requests_user_insert" on public.finsave_payment_requests for insert to authenticated with check(user_id=auth.uid());
drop policy if exists "payment_requests_admin_update" on public.finsave_payment_requests;
create policy "payment_requests_admin_update" on public.finsave_payment_requests for update to authenticated using(public.is_finsave_admin()) with check(public.is_finsave_admin());
grant select on public.finsave_commercial_settings,public.finsave_payment_requests to authenticated;
grant insert on public.finsave_payment_requests to authenticated;
grant insert,update on public.finsave_commercial_settings to authenticated;
grant update on public.finsave_payment_requests to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('payment-receipts','payment-receipts',false,5242880,array['image/jpeg','image/png','application/pdf'])
on conflict(id) do update set public=false,file_size_limit=5242880,allowed_mime_types=excluded.allowed_mime_types;
drop policy if exists "receipts_user_upload" on storage.objects;
create policy "receipts_user_upload" on storage.objects for insert to authenticated
with check(bucket_id='payment-receipts' and (storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists "receipts_read_own_or_admin" on storage.objects;
create policy "receipts_read_own_or_admin" on storage.objects for select to authenticated
using(bucket_id='payment-receipts' and ((storage.foldername(name))[1]=auth.uid()::text or public.is_finsave_admin()));

create or replace function public.approve_finsave_payment_request(request_id uuid, note text default '')
returns void language plpgsql security definer set search_path=public as $$
declare r public.finsave_payment_requests%rowtype;
begin
  if not public.is_finsave_admin() then raise exception 'Acceso denegado'; end if;
  select * into r from public.finsave_payment_requests where id=request_id for update;
  if r.id is null or r.status<>'pending' then raise exception 'Solicitud no disponible'; end if;
  insert into public.finsave_payments(invoice_id,user_id,amount_clp,method,reference,paid_at,created_by)
  values(r.invoice_id,r.user_id,r.amount_clp,'transferencia',r.reference,now(),auth.uid());
  update public.finsave_invoices set status='paid',paid_at=now() where id=r.invoice_id;
  update public.finsave_payment_requests set status='approved',admin_note=note,reviewed_by=auth.uid(),reviewed_at=now() where id=request_id;
  update public.finsave_subscriptions set status='active' where user_id=r.user_id and status='past_due'
    and not exists(select 1 from public.finsave_invoices where user_id=r.user_id and status in('pending','overdue') and id<>r.invoice_id);
end;$$;
grant execute on function public.approve_finsave_payment_request(uuid,text) to authenticated;
