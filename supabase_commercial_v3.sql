-- Finsave comercial v3: datos tributarios, estados DTE y solicitudes de cambio de plan.

alter table public.finsave_invoices add column if not exists dte_status text not null default 'pending' check(dte_status in('pending','issued','void'));
alter table public.finsave_invoices add column if not exists dte_type integer;
alter table public.finsave_invoices add column if not exists sii_folio bigint;
alter table public.finsave_invoices add column if not exists issued_at timestamptz;
alter table public.finsave_invoices add column if not exists dte_pdf_path text;
alter table public.finsave_invoices add column if not exists dte_xml_path text;
alter table public.finsave_invoices add column if not exists void_reason text not null default '';
alter table public.finsave_invoices add column if not exists credit_note_folio bigint;

create table if not exists public.finsave_billing_profiles(
 user_id uuid primary key references auth.users(id) on delete cascade,
 rut text not null default '', business_name text not null default '', giro text not null default '',
 address text not null default '', comuna text not null default '', city text not null default '',
 dte_email text not null default '', phone text not null default '',
 document_preference text not null default 'boleta' check(document_preference in('boleta','factura','exenta')),
 updated_at timestamptz not null default now()
);

create table if not exists public.finsave_plan_change_requests(
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
 current_plan_id uuid references public.finsave_plans(id) on delete set null,
 requested_plan_id uuid not null references public.finsave_plans(id) on delete restrict,
 payment_method text not null check(payment_method in('transfer','online')),
 amount_clp integer not null check(amount_clp>=0),
 invoice_id uuid references public.finsave_invoices(id) on delete set null,
 status text not null default 'pending_payment' check(status in('pending_payment','payment_review','pending_approval','approved','rejected','cancelled')),
 payment_request_id uuid references public.finsave_payment_requests(id) on delete set null,
 admin_note text not null default '', reviewed_by uuid references auth.users(id) on delete set null,
 reviewed_at timestamptz, created_at timestamptz not null default now()
);
alter table public.finsave_plan_change_requests add column if not exists invoice_id uuid references public.finsave_invoices(id) on delete set null;
create unique index if not exists finsave_one_open_plan_request on public.finsave_plan_change_requests(user_id)
where status in('pending_payment','payment_review','pending_approval');

alter table public.finsave_billing_profiles enable row level security;
alter table public.finsave_plan_change_requests enable row level security;
drop policy if exists "billing_profiles_read" on public.finsave_billing_profiles;
create policy "billing_profiles_read" on public.finsave_billing_profiles for select to authenticated using(user_id=auth.uid() or public.is_finsave_admin());
drop policy if exists "billing_profiles_write_own_or_admin" on public.finsave_billing_profiles;
create policy "billing_profiles_write_own_or_admin" on public.finsave_billing_profiles for all to authenticated using(user_id=auth.uid() or public.is_finsave_admin()) with check(user_id=auth.uid() or public.is_finsave_admin());
drop policy if exists "plan_requests_read" on public.finsave_plan_change_requests;
create policy "plan_requests_read" on public.finsave_plan_change_requests for select to authenticated using(user_id=auth.uid() or public.is_finsave_admin());
drop policy if exists "plan_requests_create_own" on public.finsave_plan_change_requests;
create policy "plan_requests_create_own" on public.finsave_plan_change_requests for insert to authenticated with check(user_id=auth.uid());
drop policy if exists "plan_requests_admin_update" on public.finsave_plan_change_requests;
create policy "plan_requests_admin_update" on public.finsave_plan_change_requests for update to authenticated using(public.is_finsave_admin()) with check(public.is_finsave_admin());
grant select,insert,update on public.finsave_billing_profiles,public.finsave_plan_change_requests to authenticated;

create or replace function public.submit_finsave_plan_request(requested_plan uuid, method text default 'transfer')
returns uuid language plpgsql security definer set search_path=public as $$
declare p public.finsave_plans%rowtype; current_plan uuid; inv_id uuid; req_id uuid;
begin
 if method <> 'transfer' then raise exception 'El pago automático aún no está habilitado'; end if;
 if exists(select 1 from public.finsave_plan_change_requests where user_id=auth.uid() and status in('pending_payment','payment_review','pending_approval')) then raise exception 'Ya existe una solicitud en curso'; end if;
 select * into p from public.finsave_plans where id=requested_plan and is_active and not is_admin_plan;
 if p.id is null then raise exception 'Plan no disponible'; end if;
 select plan_id into current_plan from public.finsave_subscriptions where user_id=auth.uid();
 insert into public.finsave_invoices(user_id,plan_id,period_start,period_end,due_date,amount_clp,status,notes)
 values(auth.uid(),p.id,current_date,current_date+(p.duration_days-1),current_date+5,p.price_clp,'pending','Solicitud de cambio de plan') returning id into inv_id;
 insert into public.finsave_plan_change_requests(user_id,current_plan_id,requested_plan_id,payment_method,amount_clp,invoice_id,status)
 values(auth.uid(),current_plan,p.id,method,p.price_clp,inv_id,'pending_payment') returning id into req_id;
 return req_id;
end;$$;
grant execute on function public.submit_finsave_plan_request(uuid,text) to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('dte-files','dte-files',false,10485760,array['application/pdf','application/xml','text/xml'])
on conflict(id) do update set public=false,file_size_limit=10485760,allowed_mime_types=excluded.allowed_mime_types;
drop policy if exists "dte_admin_upload" on storage.objects;
create policy "dte_admin_upload" on storage.objects for insert to authenticated with check(bucket_id='dte-files' and public.is_finsave_admin());
drop policy if exists "dte_read_own_or_admin" on storage.objects;
create policy "dte_read_own_or_admin" on storage.objects for select to authenticated using(bucket_id='dte-files' and (public.is_finsave_admin() or (storage.foldername(name))[1]=auth.uid()::text));

create or replace function public.review_finsave_plan_request(request_id uuid, approve boolean, note text default '')
returns void language plpgsql security definer set search_path=public as $$
declare r public.finsave_plan_change_requests%rowtype; p public.finsave_plans%rowtype;
begin
 if not public.is_finsave_admin() then raise exception 'Acceso denegado'; end if;
 select * into r from public.finsave_plan_change_requests where id=request_id for update;
 if r.id is null or r.status not in('payment_review','pending_approval') then raise exception 'Solicitud no disponible'; end if;
 if not approve then update public.finsave_plan_change_requests set status='rejected',admin_note=note,reviewed_by=auth.uid(),reviewed_at=now() where id=request_id; return; end if;
 select * into p from public.finsave_plans where id=r.requested_plan_id;
 insert into public.finsave_subscriptions(user_id,plan_id,status,starts_at,ends_at,auto_renew,notes)
 values(r.user_id,p.id,'active',current_date,case when p.is_lifetime then null else current_date+(p.duration_days-1) end,false,'Cambio de plan aprobado')
 on conflict(user_id) do update set plan_id=excluded.plan_id,status='active',starts_at=excluded.starts_at,ends_at=excluded.ends_at,notes=excluded.notes;
 update public.finsave_plan_change_requests set status='approved',admin_note=note,reviewed_by=auth.uid(),reviewed_at=now() where id=request_id;
end;$$;
grant execute on function public.review_finsave_plan_request(uuid,boolean,text) to authenticated;

create or replace function public.link_finsave_plan_payment(request_id uuid, payment_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
 update public.finsave_plan_change_requests
 set payment_request_id=payment_id,status='payment_review'
 where id=request_id and user_id=auth.uid() and status='pending_payment';
 if not found then raise exception 'Solicitud no disponible'; end if;
end;$$;
grant execute on function public.link_finsave_plan_payment(uuid,uuid) to authenticated;

-- Conserva el nombre capturado durante el registro en la ficha de Finsave.
create or replace function public.sync_finsave_signup_name()
returns trigger language plpgsql security definer set search_path=public as $$
begin
 update public.finsave_users set name=coalesce(nullif(new.raw_user_meta_data->>'name',''),'Usuario') where id=new.id;
 return new;
end;$$;
drop trigger if exists finsave_auth_sync_name on auth.users;
create trigger finsave_auth_sync_name after insert or update of raw_user_meta_data on auth.users for each row execute function public.sync_finsave_signup_name();
update public.finsave_users fu set name=au.raw_user_meta_data->>'name' from auth.users au
where fu.id=au.id and coalesce(nullif(au.raw_user_meta_data->>'name',''),'')<>'' and (fu.name is null or fu.name='' or fu.name='Usuario');
