-- UAM Incoming Inspection — schema v1
-- Applied 2026-10-10 to project lgjuokwwsjpicqljimpq.
-- Writes require the site key (รหัสหน้างาน) sent by the app as header x-site-key.
-- Reads are open to the app's public key so live updates (realtime) work for every device.

create extension if not exists pgcrypto;

-- private settings (no policies: unreachable from the public API)
create table if not exists public.app_config (
  key   text primary key,
  value text not null
);
alter table public.app_config enable row level security;

create or replace function public.has_site_key()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select coalesce(
    (current_setting('request.headers', true)::json ->> 'x-site-key')
      = (select value from public.app_config where key = 'site_key'),
    false)
$$;
revoke all on function public.has_site_key() from public;
grant execute on function public.has_site_key() to anon, authenticated;

-- used by the app's sign-in screen to check the code
create or replace function public.check_site_key()
returns boolean
language sql stable security definer
set search_path = public
as $$ select public.has_site_key() $$;
grant execute on function public.check_site_key() to anon, authenticated;

-- lots (one delivery / packing list)
create table if not exists public.receipts (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  supplier    text default '',
  model       text default '',
  doc_no      text default '',
  doc_date    text default '',
  status      text not null default 'open' check (status in ('open','closed')),
  source      text default 'manual',
  created_at  timestamptz not null default now(),
  created_by  text default '',
  closed_at   timestamptz,
  closed_by   text
);

-- printed rows of the packing list
create table if not exists public.receipt_lines (
  id          uuid primary key default gen_random_uuid(),
  receipt_id  uuid not null references public.receipts(id) on delete cascade,
  line_no     int  not null default 0,
  part_no     text not null,
  description text default '',
  box         text default '',
  packing     int  default 0,
  qty         int  not null check (qty >= 0)
);
create index if not exists receipt_lines_receipt_idx on public.receipt_lines(receipt_id);

-- every tap at the dock (append-only; undo = voided)
create table if not exists public.count_events (
  id          uuid primary key,
  receipt_id  uuid not null references public.receipts(id) on delete cascade,
  part_no     text not null,
  box         text default '',
  qty         int  not null,
  kind        text not null default 'count' check (kind in ('count','damage')),
  source      text default 'tap',
  note        text default '',
  photo       text,                     -- small compressed jpeg (data URL) for damage evidence
  counted_by  text default '',
  created_at  timestamptz not null default now(),
  voided      boolean not null default false,
  voided_by   text,
  voided_at   timestamptz
);
create index if not exists count_events_receipt_idx on public.count_events(receipt_id);
create index if not exists count_events_created_idx on public.count_events(created_at desc);

-- reason recorded for a part whose count does not match the document
create table if not exists public.part_notes (
  receipt_id  uuid not null references public.receipts(id) on delete cascade,
  part_no     text not null,
  note        text not null default '',
  noted_by    text default '',
  noted_at    timestamptz not null default now(),
  primary key (receipt_id, part_no)
);

-- per-part rollup for reports / BI
create or replace view public.v_part_summary with (security_invoker = true) as
with exp as (
  select receipt_id, upper(part_no) part_no, max(description) description, sum(qty) expected
  from public.receipt_lines group by 1,2
), cnt as (
  select receipt_id, upper(part_no) part_no,
         sum(qty) filter (where kind='count')  counted,
         sum(qty) filter (where kind='damage') damaged
  from public.count_events where not voided group by 1,2
)
select coalesce(e.receipt_id,c.receipt_id) receipt_id,
       coalesce(e.part_no,c.part_no) part_no,
       e.description,
       coalesce(e.expected,0) expected,
       coalesce(c.counted,0) counted,
       coalesce(c.counted,0)-coalesce(e.expected,0) diff,
       coalesce(c.damaged,0) damaged
from exp e full join cnt c on c.receipt_id=e.receipt_id and c.part_no=e.part_no;

-- RLS
alter table public.receipts      enable row level security;
alter table public.receipt_lines enable row level security;
alter table public.count_events  enable row level security;
alter table public.part_notes    enable row level security;

create policy receipts_read on public.receipts for select to anon, authenticated using (true);
create policy receipts_insert on public.receipts for insert to anon, authenticated with check (public.has_site_key());
create policy receipts_update on public.receipts for update to anon, authenticated using (public.has_site_key()) with check (public.has_site_key());
create policy receipt_lines_read on public.receipt_lines for select to anon, authenticated using (true);
create policy receipt_lines_insert on public.receipt_lines for insert to anon, authenticated with check (public.has_site_key());
create policy receipt_lines_update on public.receipt_lines for update to anon, authenticated using (public.has_site_key()) with check (public.has_site_key());
-- lines may be corrected (deleted) while reviewing; nothing else is deletable from the app
create policy receipt_lines_delete on public.receipt_lines for delete to anon, authenticated using (public.has_site_key());
create policy count_events_read on public.count_events for select to anon, authenticated using (true);
create policy count_events_insert on public.count_events for insert to anon, authenticated with check (public.has_site_key());
create policy count_events_update on public.count_events for update to anon, authenticated using (public.has_site_key()) with check (public.has_site_key());
create policy part_notes_read on public.part_notes for select to anon, authenticated using (true);
create policy part_notes_insert on public.part_notes for insert to anon, authenticated with check (public.has_site_key());
create policy part_notes_update on public.part_notes for update to anon, authenticated using (public.has_site_key()) with check (public.has_site_key());

grant select, insert, update on public.receipts, public.receipt_lines, public.count_events, public.part_notes to anon, authenticated;
grant delete on public.receipt_lines to anon, authenticated;
grant select on public.v_part_summary to anon, authenticated;

-- live updates
alter publication supabase_realtime add table public.receipts, public.receipt_lines, public.count_events, public.part_notes;
