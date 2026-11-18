-- Texting from a company's own Twilio account. Texts went out only through the server's account
-- (three environment variables), so a business had to reach its host's settings to turn texting
-- on. A company now connects its own on the Apps page: the Account SID and sending number in
-- integrations (provider 'twilio', external_account_id and settings), the Auth Token encrypted in
-- integration_secrets, as its own mailbox or Stripe key is kept. Nothing new is stored here for
-- that; the server reads those rows (apps/api/src/lib/twilio.ts).
--
-- One function asked "can texts go out?" of the whole server: the reminders to subs before their
-- insurance runs out. p_can_text still says whether the server has an account; a company with its
-- own counts too, the way a company's own mailbox already did for email.

-- As in 20261025002004_sub_paperwork_sign_ins.sql, and a sub with a phone is reminded by text when
-- their company has its own Twilio account, not only when the server has one.
create or replace function public.emit_sub_document_alerts(p_can_text boolean default false, p_can_email boolean default false)
returns table (company_id uuid, subcontractor_id uuid, document_id uuid, kind text, expires_on date, days_left integer, alert text, remind_sub boolean)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  r record;
  v_when text;
  v_title text;
  v_body text;
  v_ends text;
begin
  for r in
    select d.id, d.company_id, d.subcontractor_id, d.kind, d.expires_on, x.days_left, private.sub_alert_due(x.days_left) as due,
           s.name, w.waiting,
           (c.settings -> 'subs' -> 'remind_subs') is distinct from 'false'::jsonb and not w.waiting
             and ((s.email is not null and (coalesce(p_can_email, false)
                   or exists (select 1 from public.integrations i where i.company_id = d.company_id and i.provider = 'email' and i.status <> 'disconnected')))
               or (s.phone is not null and (coalesce(p_can_text, false)
                   or exists (select 1 from public.integrations i where i.company_id = d.company_id and i.provider = 'twilio' and i.status <> 'disconnected' and i.external_account_id is not null)))) as remind,
           (c.settings -> 'subs' -> 'remind_subs') is distinct from 'false'::jsonb and not w.waiting as remind_sign_in
    from public.sub_documents d
    join public.subcontractors s on s.id = d.subcontractor_id
    join public.companies c on c.id = d.company_id
    cross join lateral (select d.expires_on - private.company_today(d.company_id) as days_left) x
    -- Something newer they sent, waiting for the office to check it.
    cross join lateral (
      select exists (
        select 1 from public.sub_documents n
        where n.subcontractor_id = d.subcontractor_id and n.id <> d.id and n.superseded_at is null and n.verified_at is null
          and private.sub_document_group(n.kind) = private.sub_document_group(d.kind) and (n.expires_on is null or n.expires_on >= d.expires_on)
      ) as waiting
    ) w
    where d.kind in ('liability', 'workers_comp', 'wc_exemption') and d.superseded_at is null and d.expires_on is not null
      and s.active
      and d.expires_on <= current_date + 32 -- every time zone's today is within a day of the server's
      and extract(hour from now() at time zone c.timezone) >= 8 -- sent in the morning, not at midnight
      and private.sub_alert_rank(private.sub_alert_due(x.days_left)) > private.sub_alert_rank(d.alerted_state)
      -- Only the one that counts: checked first, then the one that runs longest, then the newest.
      and not exists (
        select 1 from public.sub_documents e
        where e.subcontractor_id = d.subcontractor_id and e.id <> d.id and e.superseded_at is null
          and private.sub_document_group(e.kind) = private.sub_document_group(d.kind)
          and ((e.verified_at is not null), coalesce(e.expires_on, 'infinity'::date), e.created_at, e.id)
            > ((d.verified_at is not null), coalesce(d.expires_on, 'infinity'::date), d.created_at, d.id)
      )
    for update of d skip locked
  loop
    v_when := case
      when r.days_left < 0 then 'has run out'
      when r.days_left = 0 then 'ends today'
      when r.days_left = 1 then 'ends tomorrow'
      else format('ends in %s days', r.days_left)
    end;
    v_ends := format('%s %s.', case when r.days_left < 0 then 'It ended' else 'It ends' end, to_char(r.expires_on, 'Mon FMDD, YYYY'));
    v_title := format('%s''s %s %s', r.name, private.sub_document_words(r.kind), v_when);
    v_body := v_ends
      || case
        when r.waiting then ' They''ve sent a new one. Have a look and verify it.'
        when r.remind then ' We''re sending them a link to send in a new one.'
        else ''
      end;
    insert into public.notifications (company_id, user_id, kind, title, body, link)
    select r.company_id, o.user_id, 'subs', v_title, v_body, '/subs/' || r.subcontractor_id
    from private.subs_office(r.company_id) as o(user_id);
    if r.remind_sign_in then
      insert into public.notifications (company_id, user_id, kind, title, body, link)
      select r.company_id, m.user_id, 'subs', format('Your %s %s', private.sub_document_words(r.kind), v_when),
        v_ends || ' Send us the new one under My paperwork.', '/field/paperwork'
      from public.memberships m
      where m.company_id = r.company_id and m.subcontractor_id = r.subcontractor_id and m.active;
    end if;
    update public.sub_documents set alerted_state = r.due where id = r.id;

    company_id := r.company_id;
    subcontractor_id := r.subcontractor_id;
    document_id := r.id;
    kind := r.kind;
    expires_on := r.expires_on;
    days_left := r.days_left;
    alert := r.due;
    remind_sub := r.remind;
    return next;
  end loop;
end $$;
