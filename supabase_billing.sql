-- Finsave: planes, suscripciones, facturas y pagos
-- Ejecutar una sola vez en el SQL Editor del proyecto Supabase.

create extension if not exists pgcrypto;

create or replace function public.is_finsave_admin()
returns boolean language sql stable security definer set search_path = public
as $$
  select lower(coalesce(auth.jwt() ->> 'email','')) = 'bryan.serrano.perez@icloud.com'
    or exists (
      select 1 from public.finsave_admins a
      where lower(a.email) = lower(coalesce(auth.jwt() ->> 'email',''))
    );
$$;

grant execute on function public.is_finsave_admin() to authenticated;

create table if not exists public.finsave_plans (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(trim(name)) between 2 and 60),
  description text not null default '',
  price_clp integer not null default 0 check (price_clp >= 0),
  duration_days integer not null check (duration_days between 1 and 3650),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.finsave_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  plan_id uuid references public.finsave_plans(id) on delete set null,
  status text not null default 'trial' check (status in ('trial','active','past_due','paused','cancelled','expired')),
  starts_at date not null default current_date,
  ends_at date not null,
  auto_renew boolean not null default false,
  notes text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at >= starts_at)
);

create table if not exists public.finsave_invoices (
  id uuid primary key default gen_random_uuid(),
  invoice_number bigint generated always as identity unique,
  user_id uuid not null references auth.users(id) on delete cascade,
  subscription_id uuid references public.finsave_subscriptions(id) on delete set null,
  plan_id uuid references public.finsave_plans(id) on delete set null,
  period_start date not null,
  period_end date not null,
  due_date date not null,
  amount_clp integer not null check (amount_clp >= 0),
  status text not null default 'pending' check (status in ('draft','pending','paid','overdue','void')),
  paid_at timestamptz,
  notes text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (period_end >= period_start)
);

create table if not exists public.finsave_payments (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.finsave_invoices(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  amount_clp integer not null check (amount_clp > 0),
  method text not null default 'transferencia',
  reference text not null default '',
  paid_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists finsave_subscriptions_user_idx on public.finsave_subscriptions(user_id);
create index if not exists finsave_invoices_user_status_idx on public.finsave_invoices(user_id,status);
create index if not exists finsave_invoices_due_idx on public.finsave_invoices(due_date);
create index if not exists finsave_payments_invoice_idx on public.finsave_payments(invoice_id);

create or replace function public.finsave_touch_updated_at()
returns trigger language plpgsql as $$ begin new.updated_at = now(); return new; end; $$;

drop trigger if exists finsave_plans_touch on public.finsave_plans;
create trigger finsave_plans_touch before update on public.finsave_plans for each row execute function public.finsave_touch_updated_at();
drop trigger if exists finsave_subscriptions_touch on public.finsave_subscriptions;
create trigger finsave_subscriptions_touch before update on public.finsave_subscriptions for each row execute function public.finsave_touch_updated_at();
drop trigger if exists finsave_invoices_touch on public.finsave_invoices;
create trigger finsave_invoices_touch before update on public.finsave_invoices for each row execute function public.finsave_touch_updated_at();

alter table public.finsave_plans enable row level security;
alter table public.finsave_subscriptions enable row level security;
alter table public.finsave_invoices enable row level security;
alter table public.finsave_payments enable row level security;

drop policy if exists "plans_read_authenticated" on public.finsave_plans;
create policy "plans_read_authenticated" on public.finsave_plans for select to authenticated using (is_active or public.is_finsave_admin());
drop policy if exists "plans_admin_write" on public.finsave_plans;
create policy "plans_admin_write" on public.finsave_plans for all to authenticated using (public.is_finsave_admin()) with check (public.is_finsave_admin());

drop policy if exists "subscriptions_read_own_or_admin" on public.finsave_subscriptions;
create policy "subscriptions_read_own_or_admin" on public.finsave_subscriptions for select to authenticated using (user_id = auth.uid() or public.is_finsave_admin());
drop policy if exists "subscriptions_admin_write" on public.finsave_subscriptions;
create policy "subscriptions_admin_write" on public.finsave_subscriptions for all to authenticated using (public.is_finsave_admin()) with check (public.is_finsave_admin());

drop policy if exists "invoices_read_own_or_admin" on public.finsave_invoices;
create policy "invoices_read_own_or_admin" on public.finsave_invoices for select to authenticated using (user_id = auth.uid() or public.is_finsave_admin());
drop policy if exists "invoices_admin_write" on public.finsave_invoices;
create policy "invoices_admin_write" on public.finsave_invoices for all to authenticated using (public.is_finsave_admin()) with check (public.is_finsave_admin());

drop policy if exists "payments_read_own_or_admin" on public.finsave_payments;
create policy "payments_read_own_or_admin" on public.finsave_payments for select to authenticated using (user_id = auth.uid() or public.is_finsave_admin());
drop policy if exists "payments_admin_write" on public.finsave_payments;
create policy "payments_admin_write" on public.finsave_payments for all to authenticated using (public.is_finsave_admin()) with check (public.is_finsave_admin());

grant select on public.finsave_plans, public.finsave_subscriptions, public.finsave_invoices, public.finsave_payments to authenticated;
grant insert, update, delete on public.finsave_plans, public.finsave_subscriptions, public.finsave_invoices, public.finsave_payments to authenticated;
grant usage, select on all sequences in schema public to authenticated;

insert into public.finsave_plans (name,description,price_clp,duration_days,is_active)
select 'Prueba','Acceso de evaluación a Finsave',0,14,true
where not exists (select 1 from public.finsave_plans where lower(name)='prueba');
insert into public.finsave_plans (name,description,price_clp,duration_days,is_active)
select 'Mensual','Acceso completo por 30 días',4990,30,true
where not exists (select 1 from public.finsave_plans where lower(name)='mensual');
insert into public.finsave_plans (name,description,price_clp,duration_days,is_active)
select 'Anual','Acceso completo por 365 días',49900,365,true
where not exists (select 1 from public.finsave_plans where lower(name)='anual');

-- Mantiene automáticamente la vista de morosidad al consultar el sistema.
create or replace function public.refresh_finsave_billing_statuses()
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_finsave_admin() then raise exception 'Acceso denegado'; end if;
  update public.finsave_invoices set status='overdue' where status='pending' and due_date < current_date;
  update public.finsave_subscriptions s set status='expired'
    where s.status in ('trial','active') and s.ends_at < current_date;
  update public.finsave_subscriptions s set status='past_due'
    where s.status not in ('cancelled','paused') and exists (
      select 1 from public.finsave_invoices i where i.user_id=s.user_id and i.status='overdue'
    );
end;
$$;
grant execute on function public.refresh_finsave_billing_statuses() to authenticated;

-- Toda cuenta nueva recibe un plan de prueba; las cuentas existentes se incorporan
-- sin tocar sus datos financieros ni bloquear su acceso actual.
create or replace function public.assign_finsave_trial_plan()
returns trigger language plpgsql security definer set search_path = public as $$
declare trial_plan public.finsave_plans%rowtype;
begin
  select * into trial_plan from public.finsave_plans where lower(name)='prueba' and is_active limit 1;
  if trial_plan.id is not null then
    insert into public.finsave_subscriptions(user_id,plan_id,status,starts_at,ends_at,notes)
    values(new.id,trial_plan.id,'trial',current_date,current_date + (trial_plan.duration_days - 1),'Plan inicial automático')
    on conflict(user_id) do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists finsave_users_assign_trial on public.finsave_users;
create trigger finsave_users_assign_trial after insert on public.finsave_users
for each row execute function public.assign_finsave_trial_plan();

insert into public.finsave_subscriptions(user_id,plan_id,status,starts_at,ends_at,notes)
select u.id,p.id,'trial',current_date,current_date + (p.duration_days - 1),'Plan inicial de incorporación'
from public.finsave_users u cross join lateral (
  select id,duration_days from public.finsave_plans where lower(name)='prueba' and is_active limit 1
) p
on conflict(user_id) do nothing;
