-- Finsave comercial v6: continuidad de acceso durante revisiones y control administrativo del DTE.

create or replace function public.get_finsave_access_state()
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
  uid uuid := auth.uid();
  account_active boolean := true;
  subscription_valid boolean := false;
  review_grace boolean := false;
  access_reason text := 'without_subscription';
begin
  if uid is null then return jsonb_build_object('allowed',false,'reason','not_authenticated','review_grace',false); end if;
  if public.is_finsave_admin() then return jsonb_build_object('allowed',true,'reason','administrator','review_grace',false); end if;

  select coalesce(is_active,true) into account_active from public.finsave_users where id=uid;
  if not account_active then return jsonb_build_object('allowed',false,'reason','account_disabled','review_grace',false); end if;

  select exists(
    select 1 from public.finsave_subscriptions s
    left join public.finsave_plans p on p.id=s.plan_id
    where s.user_id=uid and s.status in('trial','active')
      and (coalesce(p.is_lifetime,false) or s.ends_at is null or s.ends_at>=current_date)
  ) into subscription_valid;

  select exists(
    select 1 from public.finsave_plan_change_requests r
    where r.user_id=uid and r.status in('pending_payment','payment_review','pending_approval')
  ) or exists(
    select 1 from public.finsave_payment_requests pr
    where pr.user_id=uid and pr.status='pending'
  ) into review_grace;

  if review_grace then access_reason := 'commercial_review';
  elsif subscription_valid then access_reason := 'active_subscription';
  else access_reason := 'subscription_expired'; end if;

  return jsonb_build_object(
    'allowed', subscription_valid or review_grace,
    'reason', access_reason,
    'review_grace', review_grace,
    'subscription_valid', subscription_valid
  );
end;$$;
grant execute on function public.get_finsave_access_state() to authenticated;

-- Al rechazar un comprobante también se cierra la solicitud de plan vinculada.
create or replace function public.reject_finsave_payment_request(request_id uuid, note text default '')
returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.is_finsave_admin() then raise exception 'Acceso denegado'; end if;
  update public.finsave_payment_requests
    set status='rejected',admin_note=note,reviewed_by=auth.uid(),reviewed_at=now()
    where id=request_id and status='pending';
  if not found then raise exception 'Pago no disponible'; end if;
  update public.finsave_plan_change_requests
    set status='rejected',admin_note=note,reviewed_by=auth.uid(),reviewed_at=now()
    where payment_request_id=request_id and status in('payment_review','pending_approval');
end;$$;
grant execute on function public.reject_finsave_payment_request(uuid,text) to authenticated;

-- El cliente entrega sus antecedentes, pero la clasificación tributaria la controla Finsave.
alter table public.finsave_billing_profiles add column if not exists taxpayer_type text not null default 'unknown'
  check(taxpayer_type in('unknown','natural','business'));

create or replace function public.protect_finsave_document_type()
returns trigger language plpgsql security definer set search_path=public as $$
declare rut_body bigint;
begin
  if public.is_finsave_admin() then return new; end if;
  if tg_op='UPDATE' then
    new.document_preference := old.document_preference;
    new.taxpayer_type := old.taxpayer_type;
  else
    rut_body := nullif(regexp_replace(split_part(coalesce(new.rut,''),'-',1),'[^0-9]','','g'),'')::bigint;
    new.document_preference := case when coalesce(rut_body,0)>50000000 then 'factura' else 'boleta' end;
    new.taxpayer_type := case when coalesce(rut_body,0)>50000000 then 'business' else 'natural' end;
  end if;
  return new;
end;$$;
drop trigger if exists finsave_billing_document_type_guard on public.finsave_billing_profiles;
create trigger finsave_billing_document_type_guard before insert or update on public.finsave_billing_profiles
for each row execute function public.protect_finsave_document_type();
