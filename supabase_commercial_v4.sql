-- Finsave comercial v4: distingue planes comerciales del acceso administrativo.

alter table public.finsave_plans
add column if not exists is_admin_plan boolean not null default false;

update public.finsave_plans
set is_admin_plan = true,
    is_lifetime = true,
    is_active = true
where lower(trim(name)) = 'administrador';

create index if not exists finsave_plans_commercial_idx
on public.finsave_plans(is_active, is_admin_plan, price_clp);
