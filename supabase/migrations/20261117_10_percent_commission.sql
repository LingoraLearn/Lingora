-- Lingora: secure 10% platform commission and atomic lesson booking.
-- Apply this migration in the Supabase SQL Editor before deploying marketplace.js.
begin;

alter table public.bookings
  add column if not exists commission_rate numeric(5,4) not null default 0.10,
  add column if not exists platform_fee_eur numeric(10,2),
  add column if not exists tutor_payout_eur numeric(10,2);

-- Backfill existing bookings using their stored lesson amount.
update public.bookings
set commission_rate = 0.10,
    platform_fee_eur = round(amount_eur * 0.10, 2),
    tutor_payout_eur = amount_eur - round(amount_eur * 0.10, 2)
where platform_fee_eur is null or tutor_payout_eur is null;

alter table public.bookings
  alter column platform_fee_eur set not null,
  alter column tutor_payout_eur set not null;

alter table public.bookings
  drop constraint if exists bookings_commission_rate_check,
  add constraint bookings_commission_rate_check
    check (commission_rate = 0.10),
  drop constraint if exists bookings_amount_split_check,
  add constraint bookings_amount_split_check
    check (platform_fee_eur >= 0 and tutor_payout_eur >= 0
      and round(platform_fee_eur + tutor_payout_eur, 2) = round(amount_eur, 2));

-- Prices and fee splits are calculated in the database, never trusted from the browser.
-- The row lock and conditional slot update prevent two students taking the same slot.
create or replace function public.create_lingora_booking(p_slot_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_student_id uuid := auth.uid();
  v_tutor_id uuid;
  v_amount numeric(10,2);
  v_booking_id uuid;
begin
  if v_student_id is null then
    raise exception 'You must be logged in to book a lesson.';
  end if;

  select s.tutor_id, t.price_eur
    into v_tutor_id, v_amount
  from public.availability_slots s
  join public.tutors t on t.id = s.tutor_id
  where s.id = p_slot_id
    and s.status = 'available'
    and s.starts_at > now()
    and t.approved = true
  for update of s;

  if not found then
    raise exception 'This lesson time is no longer available.';
  end if;

  if v_amount is null or v_amount <= 0 then
    raise exception 'The tutor lesson price is invalid.';
  end if;

  update public.availability_slots
     set status = 'booked'
   where id = p_slot_id and status = 'available';

  if not found then
    raise exception 'This lesson time has just been booked by someone else.';
  end if;

  insert into public.bookings
    (student_id, tutor_id, slot_id, status, amount_eur, payment_status,
     commission_rate, platform_fee_eur, tutor_payout_eur)
  values
    (v_student_id, v_tutor_id, p_slot_id, 'pending', v_amount, 'unpaid',
     0.10, round(v_amount * 0.10, 2),
     v_amount - round(v_amount * 0.10, 2))
  returning id into v_booking_id;

  return v_booking_id;
end;
$$;

revoke all on function public.create_lingora_booking(uuid) from public;
grant execute on function public.create_lingora_booking(uuid) to authenticated;

commit;
