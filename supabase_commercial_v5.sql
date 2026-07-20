-- Finsave comercial v5: conecta aprobación del pago con activación del cambio de plan.

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
  update public.finsave_plan_change_requests set status='pending_approval'
    where payment_request_id=request_id and status='payment_review';
  update public.finsave_subscriptions set status='active' where user_id=r.user_id and status='past_due'
    and not exists(select 1 from public.finsave_invoices where user_id=r.user_id and status in('pending','overdue') and id<>r.invoice_id);
end;$$;
grant execute on function public.approve_finsave_payment_request(uuid,text) to authenticated;

create or replace function public.review_finsave_plan_request(request_id uuid, approve boolean, note text default '')
returns void language plpgsql security definer set search_path=public as $$
declare r public.finsave_plan_change_requests%rowtype; p public.finsave_plans%rowtype;
begin
 if not public.is_finsave_admin() then raise exception 'Acceso denegado'; end if;
 select * into r from public.finsave_plan_change_requests where id=request_id for update;
 if r.id is null then raise exception 'Solicitud no disponible'; end if;
 if not approve and r.status in('pending_payment','payment_review','pending_approval') then
   update public.finsave_plan_change_requests set status='rejected',admin_note=note,reviewed_by=auth.uid(),reviewed_at=now() where id=request_id;
   return;
 end if;
 if r.status<>'pending_approval' then raise exception 'Primero debes aprobar el pago asociado'; end if;
 select * into p from public.finsave_plans where id=r.requested_plan_id;
 insert into public.finsave_subscriptions(user_id,plan_id,status,starts_at,ends_at,auto_renew,notes)
 values(r.user_id,p.id,'active',current_date,case when p.is_lifetime then null else current_date+(p.duration_days-1) end,false,'Cambio de plan aprobado')
 on conflict(user_id) do update set plan_id=excluded.plan_id,status='active',starts_at=excluded.starts_at,ends_at=excluded.ends_at,notes=excluded.notes;
 update public.finsave_plan_change_requests set status='approved',admin_note=note,reviewed_by=auth.uid(),reviewed_at=now() where id=request_id;
end;$$;
grant execute on function public.review_finsave_plan_request(uuid,boolean,text) to authenticated;

-- Regulariza solicitudes cuyo pago ya había sido aprobado antes de esta mejora.
update public.finsave_plan_change_requests r
set status='pending_approval'
from public.finsave_payment_requests p
where r.payment_request_id=p.id and r.status='payment_review' and p.status='approved';
