-- Postcards: "Mail one to us first". One card of a draft, made through Lob and addressed to the
-- company's own address, so the office holds the real thing (or, with a test key, sees Lob's
-- picture of it) before a campaign of hundreds goes out. Lob itself recommends it.
--
--   postcard_proofs   a row per card mailed to ourselves: the draft it was of, the kind of key it
--                     was made with, the address it went to, Lob's id for it, Lob's picture of it
--                     and when it's expected. Its front picture is its own public copy, with its own
--                     token, served like a campaign's (/api/public/postcards/<token>.jpg), and it
--                     outlives the draft: deleting the draft leaves the row and the picture, so Lob
--                     can still fetch it.
--
-- Written only by the server (apps/api/src/services/postcards.ts, mailProof), which checks what
-- Send checks and, for a live key, that an owner or admin asked. Read by the office with the
-- marketing area, as a campaign's recipients are. supabase/tests/postcard_fixes_test.sql covers it.

create table public.postcard_proofs (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  campaign_id uuid references public.postcard_campaigns (id) on delete set null,
  mode text not null check (mode in ('test', 'live')),
  size text not null check (size in ('4x6', '6x9', '6x11')),
  -- {line1, line2, city, region, postal_code, country}: the company's address when it was mailed.
  address jsonb not null check (jsonb_typeof(address) = 'object'),
  status text not null default 'sending' check (status in ('sending', 'made', 'failed')),
  error text check (length(error) <= 1000),
  idempotency_key uuid not null default gen_random_uuid() unique,
  lob_id text,
  proof_url text check (proof_url is null or (proof_url ~ '^https://' and length(proof_url) <= 2000)),
  expected_delivery date,
  image_token text not null unique check (image_token ~ '^[A-Za-z0-9_-]{32}$'),
  image_path text not null,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now()
);
create index postcard_proofs_campaign_idx on public.postcard_proofs (campaign_id, created_at desc);
create index postcard_proofs_company_idx on public.postcard_proofs (company_id, created_at desc);
comment on table public.postcard_proofs is 'One card of a postcard draft mailed to the company''s own address, to see it before the campaign goes out';

alter table public.postcard_proofs enable row level security;
create policy postcard_proofs_read on public.postcard_proofs for select to authenticated
  using (private.has_role(company_id, '{owner,admin,office}'));
select private.restrict_area('postcard_proofs', 'marketing', true);
revoke all on public.postcard_proofs from anon;
revoke insert, update, delete, truncate on public.postcard_proofs from authenticated;
select private.fold_member_checks('public.postcard_proofs');

notify pgrst, 'reload schema';
