-- Finsave comercial v10: historial automático y restauración por fecha/hora.
-- Ejecutar después de supabase_commercial_v9.sql.

create table if not exists public.finsave_data_history(
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  data jsonb not null,
  source text not null default 'automatic' check(source in ('automatic','initial','before_restore','restored')),
  changed_by uuid references auth.users(id) on delete set null,
  captured_at timestamptz not null default now()
);

create index if not exists finsave_data_history_user_time_idx
  on public.finsave_data_history(user_id,captured_at desc);

alter table public.finsave_data_history enable row level security;
drop policy if exists "finsave_history_admin_read" on public.finsave_data_history;
create policy "finsave_history_admin_read" on public.finsave_data_history
  for select to authenticated using(public.is_finsave_admin());
grant select on public.finsave_data_history to authenticated;

create or replace function public.capture_finsave_data_history()
returns trigger language plpgsql security definer set search_path=public as $$
declare snapshot jsonb; capture_source text;
begin
  snapshot := case when tg_op='DELETE' then old.data::text::jsonb else new.data::text::jsonb end;
  capture_source := coalesce(nullif(current_setting('finsave.restore_mode',true),''),'automatic');
  insert into public.finsave_data_history(user_id,data,source,changed_by,captured_at)
  values(case when tg_op='DELETE' then old.user_id else new.user_id end,snapshot,capture_source,auth.uid(),now());
  return case when tg_op='DELETE' then old else new end;
exception when others then
  -- El guardado principal nunca debe fallar si una versión antigua no contiene JSON válido.
  return case when tg_op='DELETE' then old else new end;
end;$$;

drop trigger if exists finsave_data_history_capture on public.finsave_data;
create trigger finsave_data_history_capture
after insert or update of data on public.finsave_data
for each row execute function public.capture_finsave_data_history();

-- Crea el primer punto de recuperación para cuentas que ya existían antes de esta actualización.
insert into public.finsave_data_history(user_id,data,source,changed_by,captured_at)
select d.user_id,d.data::text::jsonb,'initial',null,coalesce(d.updated_at,now())
from public.finsave_data d
where not exists(select 1 from public.finsave_data_history h where h.user_id=d.user_id)
on conflict do nothing;

create or replace function public.get_finsave_data_history(
  target_user uuid,
  date_from timestamptz default null,
  date_to timestamptz default null,
  result_limit integer default 200
)
returns table(id bigint,captured_at timestamptz,source text,ingresos integer,gastos integer,creditos integer,metas integer,liquidaciones integer)
language plpgsql security definer set search_path=public as $$
begin
  if not public.is_finsave_admin() then raise exception 'Acceso denegado'; end if;
  return query
  select h.id,h.captured_at,h.source,
    jsonb_array_length(coalesce(h.data->'ingresos','[]'::jsonb)),
    jsonb_array_length(coalesce(h.data->'gastosFijos','[]'::jsonb))+jsonb_array_length(coalesce(h.data->'gastosVariables','[]'::jsonb)),
    jsonb_array_length(coalesce(h.data->'creditos','[]'::jsonb)),
    jsonb_array_length(coalesce(h.data->'metas','[]'::jsonb)),
    jsonb_array_length(coalesce(h.data->'liquidaciones','[]'::jsonb))
  from public.finsave_data_history h
  where h.user_id=target_user
    and (date_from is null or h.captured_at>=date_from)
    and (date_to is null or h.captured_at<date_to)
  order by h.captured_at desc
  limit greatest(1,least(coalesce(result_limit,200),500));
end;$$;
grant execute on function public.get_finsave_data_history(uuid,timestamptz,timestamptz,integer) to authenticated;

create or replace function public.restore_finsave_data_version(target_user uuid,version_id bigint)
returns timestamptz language plpgsql security definer set search_path=public as $$
declare selected public.finsave_data_history%rowtype; current_data jsonb; restored_at timestamptz:=now(); data_kind text;
begin
  if not public.is_finsave_admin() then raise exception 'Acceso denegado'; end if;
  select * into selected from public.finsave_data_history where id=version_id and user_id=target_user;
  if selected.id is null then raise exception 'Versión no encontrada'; end if;

  select d.data::text::jsonb into current_data from public.finsave_data d where d.user_id=target_user for update;
  if current_data is not null then
    insert into public.finsave_data_history(user_id,data,source,changed_by,captured_at)
    values(target_user,current_data,'before_restore',auth.uid(),restored_at);
  end if;

  select data_type into data_kind from information_schema.columns
  where table_schema='public' and table_name='finsave_data' and column_name='data';
  perform set_config('finsave.restore_mode','restored',true);
  if data_kind in ('json','jsonb') then
    execute 'update public.finsave_data set data=$1,updated_at=$2 where user_id=$3' using selected.data,restored_at,target_user;
  else
    execute 'update public.finsave_data set data=$1,updated_at=$2 where user_id=$3' using selected.data::text,restored_at,target_user;
  end if;
  if not found then raise exception 'No se encontró la información actual del cliente'; end if;
  return restored_at;
end;$$;
grant execute on function public.restore_finsave_data_version(uuid,bigint) to authenticated;

