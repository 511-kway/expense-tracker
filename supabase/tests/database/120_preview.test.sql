-- Предпросмотр эффекта (ADR-0010; spec.md, история 32): preview_entry применяет запись тем же
-- путём, что create_entry / update_entry, пересчитывает, сравнивает остаток и аванс по счетам и
-- обе стороны долга до и после, откатывает. Суммы в тиынах: 1 000 ₸ = 100 000.
begin;
create extension if not exists pgtap with schema extensions;
select plan(26);

create function pg_temp.scenario(p_n int, p_start date default '2026-11-01', p_owe_me bigint default 0,
                                  p_i_owe bigint default 0) returns void language plpgsql as $$
declare v_uid uuid := ('00000000-0000-0000-0000-' || lpad(p_n::text, 12, '0'))::uuid;
begin
  perform set_config('role', 'postgres', true);
  insert into auth.users (id, email) values (v_uid, 'user' || p_n || '@example.com');
  insert into public.app_users (email, user_id, allowed) values ('user' || p_n || '@example.com', v_uid, true);
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  perform public.setup_start(p_start, p_owe_me, p_i_owe);
  perform public.create_category('Реклама');
end $$;

create function pg_temp.account(p_name text, p_total bigint default 0, p_company bigint default 0,
                                p_start date default '2026-11-01') returns uuid language sql as $$
  select (public.create_account(p_name => p_name, p_type => 'card', p_start_date => p_start,
            p_total_minor => p_total, p_company_minor => p_company) ->> 'account_id')::uuid
$$;

create function pg_temp.acc(p_name text) returns uuid language sql as $$
  select account_id from public.v_account_balances where name = p_name
$$;

create function pg_temp.expense_payload(p_account text, p_purpose text, p_amount bigint, p_source text default null,
                                        p_date date default '2026-11-02') returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'type', 'expense', 'occurred_on', p_date, 'amount_minor', p_amount, 'currency', 'KZT',
    'account_id', pg_temp.acc(p_account), 'purpose', p_purpose, 'source', p_source,
    'category_id', (select id from public.categories where name = 'Реклама')))
$$;

create function pg_temp.topup_payload(p_account text, p_amount bigint, p_date date default '2026-11-02')
returns jsonb language sql as $$
  select jsonb_build_object('type', 'company_topup', 'occurred_on', p_date, 'amount_minor', p_amount,
    'account_id', pg_temp.acc(p_account))
$$;

create function pg_temp.login_as_stranger() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000cc', 'stranger@example.com');
  insert into public.app_users (email, user_id, allowed) values ('stranger@example.com', '00000000-0000-0000-0000-0000000000cc', false);
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-0000000000cc', 'role', 'authenticated')::text, true);
end $$;

create function pg_temp.error_of(sql text) returns jsonb language plpgsql as $$
declare v_msg text; v_detail text;
begin
  execute sql;
  return null;
exception when others then
  get stacked diagnostics v_msg = message_text, v_detail = pg_exception_detail;
  return jsonb_build_object('code', v_msg, 'detail', nullif(v_detail, '')::jsonb);
end $$;

create function pg_temp.transfer_payload(p_from text, p_to text, p_purpose text, p_amount bigint,
                                         p_date date default '2026-11-03') returns jsonb language sql as $$
  select jsonb_build_object('type', 'transfer', 'occurred_on', p_date, 'amount_minor', p_amount,
    'account_id', pg_temp.acc(p_from), 'to_account_id', pg_temp.acc(p_to), 'transfer_purpose', p_purpose)
$$;

create function pg_temp.withdraw_payload(p_account text, p_amount bigint, p_date date default '2026-11-05')
returns jsonb language sql as $$
  select jsonb_build_object('type', 'company_advance_return', 'occurred_on', p_date, 'amount_minor', p_amount,
    'account_id', pg_temp.acc(p_account))
$$;

-- Всё, что хранится у пользователя: записи и журнал (для «после предпросмотра ничего не изменилось»).
create function pg_temp.stored() returns jsonb language sql as $$
  select jsonb_build_object(
    'entries', (select coalesce(jsonb_agg(to_jsonb(e) order by e.id), '[]') from public.entries e),
    'ledger',  (select coalesce(jsonb_agg(to_jsonb(l) order by l.entry_id, l.target, l.account_id, l.delta_minor), '[]')
                from public.ledger_entries l))
$$;

-- Счётчики после настоящего сохранения из выборок экранов, в форме «after» предпросмотра и по его
-- же списку счетов: источник, независимый от preview_entry.
create function pg_temp.saved_counters(p jsonb) returns jsonb language sql as $$
  select jsonb_build_object(
    'accounts', coalesce((select jsonb_object_agg(b.account_id, jsonb_build_object(
                  'balance_minor', b.balance_minor, 'advance_minor', b.advance_minor, 'own_minor', b.own_minor))
                from public.v_account_balances b
                where b.account_id::text in (select x ->> 'account_id' from jsonb_array_elements(p -> 'accounts') x)),
                '{}'::jsonb),
    'company_owes_me_minor', s.company_owes_me_minor,
    'i_owe_company_minor', s.i_owe_company_minor)
  from public.v_company_settlement s
$$;

-- Предупреждения без id записи (у новой записи в предпросмотре id временный).
create function pg_temp.warnings_wo_id(p jsonb) returns jsonb language sql as $$
  select coalesce(jsonb_agg(w - 'entry_id' order by w ->> 'code', w ->> 'occurred_on'), '[]')
  from jsonb_array_elements(p -> 'warnings') w
$$;

create function pg_temp.income_payload(p_account text, p_amount bigint, p_date date default '2026-11-02')
returns jsonb language sql as $$
  select jsonb_build_object('type', 'income', 'occurred_on', p_date, 'amount_minor', p_amount,
    'account_id', pg_temp.acc(p_account))
$$;

-- Счётчики одного счёта из предпросмотра: before/after/deltas → (остаток, аванс).
create function pg_temp.acc_part(p jsonb, p_part text, p_account text) returns jsonb language sql as $$
  select p -> p_part -> 'accounts' -> pg_temp.acc(p_account)::text
$$;

-- TC-EXP-WORK-SPLIT: topup H1 60000; expense work H1 100000 → adv 0, owe_me 40000, bal −40000.
select pg_temp.scenario(1);
select pg_temp.account('H1');
select public.create_entry(pg_temp.topup_payload('H1', 6000000));
select set_config('test.stored', pg_temp.stored()::text, true);
select set_config('test.p', public.preview_entry(pg_temp.expense_payload('H1', 'work', 10000000))::text, true);
select is(
  jsonb_build_object(
    'before', pg_temp.acc_part(current_setting('test.p')::jsonb, 'before', 'H1'),
    'after',  pg_temp.acc_part(current_setting('test.p')::jsonb, 'after', 'H1'),
    'deltas', pg_temp.acc_part(current_setting('test.p')::jsonb, 'deltas', 'H1'),
    'owe_me', current_setting('test.p')::jsonb -> 'after' -> 'company_owes_me_minor',
    'owe_me_delta', current_setting('test.p')::jsonb -> 'deltas' -> 'company_owes_me_minor'),
  '{"before": {"balance_minor": 6000000, "advance_minor": 6000000, "own_minor": 0},
    "after":  {"balance_minor": -4000000, "advance_minor": 0, "own_minor": -4000000},
    "deltas": {"balance_minor": -10000000, "advance_minor": -6000000, "own_minor": -4000000},
    "owe_me": 4000000, "owe_me_delta": 4000000}'::jsonb,
  'TC-EXP-WORK-SPLIT preview: the work expense shows the split before it is saved');

select is(pg_temp.stored(), current_setting('test.stored')::jsonb,
  'after a preview the entries and the ledger are unchanged');
select is((select count(*) from public.entries where type = 'expense'), 0::bigint,
  'the previewed expense is not saved');

-- Настоящее сохранение даёт ровно то, что показал предпросмотр.
select set_config('test.s', public.create_entry(pg_temp.expense_payload('H1', 'work', 10000000))::text, true);
select is(pg_temp.saved_counters(current_setting('test.p')::jsonb), current_setting('test.p')::jsonb -> 'after',
  'TC-EXP-WORK-SPLIT: the save ends exactly where the preview said');
select is(pg_temp.warnings_wo_id(current_setting('test.p')::jsonb), pg_temp.warnings_wo_id(current_setting('test.s')::jsonb),
  'the preview warns about the negative balance exactly like the save');
select is(jsonb_array_length(current_setting('test.p')::jsonb -> 'warnings'), 1,
  'the preview has the negative balance warning');
select is(current_setting('test.p')::jsonb -> 'accounts',
  jsonb_build_array(jsonb_build_object('account_id', pg_temp.acc('H1'), 'name', 'H1', 'currency', 'KZT')),
  'the preview lists the account of the entry');
select is(current_setting('test.p')::jsonb -> 'entry_id', 'null'::jsonb, 'a new entry has no id in the preview');

-- TC-BACKDATE-NET задним числом: 10.11 topup 100000 уже есть; трата 01.11 work 100000 → owe_me 100000,
-- аванс 100000 остаётся.
select pg_temp.scenario(2);
select pg_temp.account('H1');
select public.create_entry(pg_temp.topup_payload('H1', 10000000, '2026-11-10'));
select set_config('test.p', public.preview_entry(pg_temp.expense_payload('H1', 'work', 10000000, p_date => '2026-11-01'))::text, true);
select is(
  jsonb_build_object('after', pg_temp.acc_part(current_setting('test.p')::jsonb, 'after', 'H1'),
                     'owe_me', current_setting('test.p')::jsonb -> 'after' -> 'company_owes_me_minor',
                     'i_owe', current_setting('test.p')::jsonb -> 'after' -> 'i_owe_company_minor'),
  '{"after": {"balance_minor": 0, "advance_minor": 10000000, "own_minor": -10000000}, "owe_me": 10000000, "i_owe": 0}'::jsonb,
  'TC-BACKDATE-NET preview: the backdated expense could not use the later advance');
select set_config('test.s', public.create_entry(pg_temp.expense_payload('H1', 'work', 10000000, p_date => '2026-11-01'))::text, true);
select is(pg_temp.saved_counters(current_setting('test.p')::jsonb), current_setting('test.p')::jsonb -> 'after',
  'TC-BACKDATE-NET: the backdated save ends exactly where the preview said');
select is(pg_temp.warnings_wo_id(current_setting('test.p')::jsonb), pg_temp.warnings_wo_id(current_setting('test.s')::jsonb),
  'TC-BACKDATE-NET: the backdated preview warns like the save (balance below zero until the top-up)');

-- TC-MOVE-COMPANY-PARTIAL: topup KP 40000; transfer move_company KP→H1 60000 → adv KP 0, adv H1 40000.
select pg_temp.scenario(3);
select pg_temp.account('KP');
select pg_temp.account('H1', 10000000);
select public.create_entry(pg_temp.topup_payload('KP', 4000000));
select public.create_entry(jsonb_build_object('type', 'income', 'occurred_on', '2026-11-02', 'amount_minor', 2000000,
  'account_id', pg_temp.acc('KP')));
select set_config('test.p', public.preview_entry(pg_temp.transfer_payload('KP', 'H1', 'move_company', 6000000))::text, true);
select is(
  jsonb_build_object('kp', pg_temp.acc_part(current_setting('test.p')::jsonb, 'deltas', 'KP'),
                     'h1', pg_temp.acc_part(current_setting('test.p')::jsonb, 'deltas', 'H1'),
                     'names', jsonb_path_query_array(current_setting('test.p')::jsonb, '$.accounts[*].name')),
  '{"kp": {"balance_minor": -6000000, "advance_minor": -4000000, "own_minor": -2000000},
    "h1": {"balance_minor": 6000000, "advance_minor": 4000000, "own_minor": 2000000},
    "names": ["KP", "H1"]}'::jsonb,
  'TC-MOVE-COMPANY-PARTIAL preview: both accounts, «откуда» first, only the advance there moves');
select public.create_entry(pg_temp.transfer_payload('KP', 'H1', 'move_company', 6000000));
select is(pg_temp.saved_counters(current_setting('test.p')::jsonb), current_setting('test.p')::jsonb -> 'after',
  'TC-MOVE-COMPANY-PARTIAL: the save ends exactly where the preview said');

-- Правка: пополнение 01.11 100000 уменьшаем до 70000; изъятие 05.11 60000 ещё влезает.
select pg_temp.scenario(4);
select pg_temp.account('H1');
select set_config('test.topup', (public.create_entry(pg_temp.topup_payload('H1', 10000000, '2026-11-01')) ->> 'entry_id'), true);
select set_config('test.withdraw', (public.create_entry(pg_temp.withdraw_payload('H1', 6000000)) ->> 'entry_id'), true);
select set_config('test.stored', pg_temp.stored()::text, true);
select set_config('test.p', public.preview_entry(pg_temp.topup_payload('H1', 7000000, '2026-11-01'),
  current_setting('test.topup')::uuid)::text, true);
select is(
  jsonb_build_object('before', pg_temp.acc_part(current_setting('test.p')::jsonb, 'before', 'H1'),
                     'after', pg_temp.acc_part(current_setting('test.p')::jsonb, 'after', 'H1'),
                     'entry_id', current_setting('test.p')::jsonb ->> 'entry_id'),
  jsonb_build_object('before', '{"balance_minor": 4000000, "advance_minor": 4000000, "own_minor": 0}'::jsonb,
                     'after', '{"balance_minor": 1000000, "advance_minor": 1000000, "own_minor": 0}'::jsonb,
                     'entry_id', current_setting('test.topup')),
  'an edit preview shows the counters before and after the edit');
select is(pg_temp.stored(), current_setting('test.stored')::jsonb,
  'after an edit preview the entry and the ledger are unchanged');
select set_config('test.s', public.update_entry(current_setting('test.topup')::uuid,
  pg_temp.topup_payload('H1', 7000000, '2026-11-01'))::text, true);
select is(pg_temp.saved_counters(current_setting('test.p')::jsonb), current_setting('test.p')::jsonb -> 'after',
  'the edit ends exactly where the preview said');
select is(current_setting('test.p')::jsonb -> 'warnings', current_setting('test.s')::jsonb -> 'warnings',
  'an edit preview has the same warnings as the edit');

-- Ошибки те же, что у сохранения: правка задним числом ломает более позднее изъятие (с его id).
select is(
  pg_temp.error_of(format($$ select public.preview_entry(pg_temp.topup_payload('H1', 5000000, '2026-11-01'), %L) $$,
                          current_setting('test.topup'))),
  pg_temp.error_of(format($$ select public.update_entry(%L, pg_temp.topup_payload('H1', 5000000, '2026-11-01')) $$,
                          current_setting('test.topup'))),
  'an edit preview that breaks a later withdrawal fails exactly like the edit');
select is(
  pg_temp.error_of(format($$ select public.preview_entry(pg_temp.topup_payload('H1', 5000000, '2026-11-01'), %L) $$,
                          current_setting('test.topup'))) ->> 'code',
  'advance_return_too_big', 'the edit preview names the error code');
select is(pg_temp.error_of($$ select public.preview_entry(pg_temp.withdraw_payload('H1', 2000000)) $$) #- '{detail,entry_id}',
  pg_temp.error_of($$ select public.create_entry(pg_temp.withdraw_payload('H1', 2000000)) $$) #- '{detail,entry_id}',
  'a preview of a withdrawal above the advance fails exactly like the save');
select is(pg_temp.error_of($$ select public.preview_entry(jsonb_build_object('type', 'income', 'occurred_on', '2026-11-02')) $$),
  pg_temp.error_of($$ select public.create_entry(jsonb_build_object('type', 'income', 'occurred_on', '2026-11-02')) $$),
  'a preview with missing fields fails exactly like the save');
select is(pg_temp.error_of($$ select public.preview_entry(pg_temp.income_payload('H1', 100000, '2026-10-01')) $$),
  pg_temp.error_of($$ select public.create_entry(pg_temp.income_payload('H1', 100000, '2026-10-01')) $$),
  'a preview before the account start fails exactly like the save');
select is(pg_temp.error_of(format('select public.preview_entry(%L::jsonb, %L)',
            pg_temp.topup_payload('H1', 100000), gen_random_uuid())) ->> 'code',
  'entry_not_found', 'an edit preview of a missing entry fails like the edit');

-- Взаимозачёт без счёта: только стороны долга. Стартовый долг 50000 / 30000, зачёт 20000.
select pg_temp.scenario(5, p_owe_me => 5000000, p_i_owe => 3000000);
select pg_temp.account('H1');
select set_config('test.p', public.preview_entry(jsonb_build_object('type', 'netting', 'occurred_on', '2026-11-02',
  'amount_minor', 2000000))::text, true);
select is(
  jsonb_build_object('accounts', current_setting('test.p')::jsonb -> 'accounts',
                     'deltas', current_setting('test.p')::jsonb -> 'deltas'),
  '{"accounts": [], "deltas": {"accounts": {}, "company_owes_me_minor": -2000000, "i_owe_company_minor": -2000000}}'::jsonb,
  'a netting preview moves only both debt sides, no account');

-- Возврат покупки: счёт берётся у траты и попадает в предпросмотр.
-- TC-REFUND-PARTIAL: topup H1 100000; expense personal H1 30000 company; refund 15000.
select pg_temp.scenario(6);
select pg_temp.account('H1');
select public.create_entry(pg_temp.topup_payload('H1', 10000000));
select set_config('test.exp', public.create_entry(pg_temp.expense_payload('H1', 'personal', 3000000, 'company')) ->> 'entry_id', true);
select set_config('test.p', public.preview_entry(jsonb_build_object('type', 'refund', 'occurred_on', '2026-11-05',
  'amount_minor', 1500000, 'parent_entry_id', current_setting('test.exp')))::text, true);
select is(
  jsonb_build_object('h1', pg_temp.acc_part(current_setting('test.p')::jsonb, 'after', 'H1'),
                     'i_owe', current_setting('test.p')::jsonb -> 'after' -> 'i_owe_company_minor'),
  '{"h1": {"balance_minor": 8500000, "advance_minor": 8500000, "own_minor": 0}, "i_owe": 1500000}'::jsonb,
  'TC-REFUND-PARTIAL preview: the refund lands on the account of its expense');

select pg_temp.login_as_stranger();
select is(pg_temp.error_of($$ select public.preview_entry('{}'::jsonb) $$) ->> 'code', 'not_allowed',
  'a user outside the allowlist cannot preview');

select * from finish();
rollback;
