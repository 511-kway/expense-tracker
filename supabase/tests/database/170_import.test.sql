-- Импорт (док 04, раздел 8; док 05; ADR-0004; тикет 18). Строки приходят от Edge Function
-- import_parse: названия счетов и категорий, суммы модулем целыми тиынами строкой, знак
-- корректировки отдельно. import_preview проверяет каждую строку теми же проверками, что
-- create_entry, и ничего не создаёт; import_commit создаёт всё одной транзакцией или ничего.
-- Суммы в тиынах: 1 000 ₸ = 100 000.
begin;
create extension if not exists pgtap with schema extensions;
select plan(32);

create function pg_temp.login(p_n int) returns void language plpgsql as $$
declare v_uid uuid := ('00000000-0000-0000-0000-' || lpad(p_n::text, 12, '0'))::uuid;
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
end $$;

create function pg_temp.scenario(p_n int, p_owe_me bigint default 0, p_i_owe bigint default 0) returns void
language plpgsql as $$
declare v_uid uuid := ('00000000-0000-0000-0000-' || lpad(p_n::text, 12, '0'))::uuid;
begin
  perform set_config('role', 'postgres', true);
  insert into auth.users (id, email) values (v_uid, 'user' || p_n || '@example.com');
  insert into public.app_users (email, user_id, allowed) values ('user' || p_n || '@example.com', v_uid, true);
  perform pg_temp.login(p_n);
  perform public.setup_start('2026-11-01', p_owe_me, p_i_owe);
  perform public.create_category('Реклама');
  perform public.create_category('Еда');
end $$;

create function pg_temp.account(p_name text, p_total bigint default 0, p_company bigint default 0,
                                p_currency text default 'KZT') returns uuid
language sql as $$
  select (public.create_account(p_name => p_name, p_type => 'card', p_currency => p_currency,
            p_start_date => '2026-11-01', p_total_minor => p_total, p_company_minor => p_company) ->> 'account_id')::uuid
$$;

create function pg_temp.acc(p_name text) returns uuid language sql as $$
  select account_id from public.v_account_balances where name = p_name
$$;

create function pg_temp.cat(p_name text) returns uuid language sql as $$
  select id from public.categories where name = p_name and user_id = auth.uid()
$$;

create function pg_temp.entry(p jsonb) returns uuid language sql as $$
  select (public.create_entry(p) ->> 'entry_id')::uuid
$$;

-- Строка импорта, как её отдаёт import_parse: все колонки схемы, пустые = null.
create function pg_temp.row(p_line int, p jsonb) returns jsonb language sql as $$
  select jsonb_build_object(
    'line', p_line, 'occurred_on', '2026-11-02', 'type', 'expense', 'account', 'H1', 'amount_minor', '150000',
    'currency', 'KZT', 'category', 'Еда', 'source', 'own', 'purpose', 'personal', 'transfer_purpose', null,
    'to_account', null, 'fee_minor', null, 'fee_payer', null, 'comment', null, 'title', null,
    'external_id', 'ext-' || p_line, 'settlement_direction', null, 'adjustment_target', null,
    'adjustment_mode', null, 'adjustment_sign', null, 'adjustment_affects_advance', null,
    'parent_external_id', null, 'rate', null, 'rate_source', null, 'amount_kzt_minor', null,
    'in_analytics', null, 'errors', '[]'::jsonb) || p
$$;

-- Файл expenses текущего пользователя, прочитанный обратно (то, что import_parse отдаёт из его
-- выгрузки; совпадение файла и строк проверяют тесты Deno import_parse/parse_test.ts).
create function pg_temp.exported_rows() returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'line', n + 1, 'occurred_on', occurred_on, 'type', type, 'account', account_name,
    'amount_minor', amount_minor::text, 'currency', currency, 'category', category_name, 'source', source,
    'purpose', purpose, 'transfer_purpose', transfer_purpose, 'to_account', to_account_name,
    'fee_minor', nullif(fee_minor, 0)::text, 'fee_payer', fee_payer, 'comment', comment, 'title', title,
    'external_id', external_id, 'settlement_direction', settlement_direction,
    'adjustment_target', adjustment_target, 'adjustment_mode', adjustment_mode, 'adjustment_sign', adjustment_sign,
    'adjustment_affects_advance', case when adjustment_target = 'balance' then adjustment_affects_advance end,
    'parent_external_id', parent_external_id, 'rate', rtrim(rtrim(rate::text, '0'), '.'), 'rate_source', rate_source,
    'amount_kzt_minor', amount_kzt_minor::text, 'in_analytics', in_analytics, 'errors', '[]'::jsonb) order by n), '[]')
  from (select *, row_number() over (order by occurred_on, occurred_at nulls last, created_at, seq) as n
        from public.v_export_entries) x
$$;

-- Всё, что видно пользователю о записях, кроме id: для сравнения двух пользователей.
create function pg_temp.picture() returns table (r text) language sql as $$
  select concat_ws('|', occurred_on, type, account_name, amount_minor, currency, category_name, source, purpose,
                   transfer_purpose, to_account_name, fee_minor, fee_payer, comment, title, external_id,
                   settlement_direction, adjustment_target, adjustment_mode, adjustment_sign,
                   adjustment_affects_advance, parent_external_id, rate, rate_source, amount_kzt_minor, in_analytics)
  from public.v_export_entries
  union all
  select concat_ws('|', name, currency, balance_minor, advance_minor, own_minor) from public.v_account_balances
  union all
  select concat_ws('|', company_owes_me_minor, i_owe_company_minor, net_minor) from public.v_company_settlement
$$;

create function pg_temp.counts() returns text language sql as $$
  select (select count(*) from public.entries) || '/' || (select count(*) from public.ledger_entries)
$$;

-- 1. TC-IMPORT-ATOMIC (док 06, раздел 11): три верные строки и одна с несуществующим счётом.
select pg_temp.scenario(1);
select pg_temp.account('H1', 10000000);
select set_config('test.before', pg_temp.counts(), true);
select set_config('test.rows', jsonb_build_array(
  pg_temp.row(2, '{}'),
  pg_temp.row(3, '{"type": "income", "category": null, "source": null, "purpose": null, "amount_minor": "300000"}'),
  pg_temp.row(4, '{"account": "Нет такого"}'),
  pg_temp.row(5, '{"occurred_on": "2026-11-03", "category": "Реклама", "purpose": "work", "source": null}'))::text, true);

select set_config('test.preview', public.import_preview(current_setting('test.rows')::jsonb, 'expenses.csv', 'csv')::text, true);
select set_config('test.batch1', current_setting('test.preview')::jsonb ->> 'batch_id', true);
select is(pg_temp.counts(), current_setting('test.before'), 'preview creates no entries and no ledger rows');
select results_eq(
  $$ select (r ->> 'line')::int, r ->> 'status', r -> 'errors' -> 0 ->> 'code', r -> 'errors' -> 0 ->> 'field'
     from jsonb_array_elements(current_setting('test.preview')::jsonb -> 'rows') r $$,
  $$ values (2, 'create', null::text, null::text), (3, 'create', null, null), (4, 'error', 'account_not_found', 'account'),
            (5, 'create', null, null) $$,
  'preview: every row is checked, the unknown account is an error of exactly that row');
select is((select status from public.import_batches where id = (current_setting('test.preview')::jsonb ->> 'batch_id')::uuid),
  'preview', 'the batch is kept for the confirmation');

select set_config('test.commit', public.import_commit((current_setting('test.preview')::jsonb ->> 'batch_id')::uuid)::text, true);
select is(pg_temp.counts(), current_setting('test.before'), 'TC-IMPORT-ATOMIC: one bad row, 0 new entries and ledger rows');
select is((select count(*) from public.entries where status = 'draft'), 0::bigint, 'no drafts are made from the file');
select is((current_setting('test.commit')::jsonb ->> 'status'), 'failed', 'the confirmation answers «failed»');
select results_eq(
  $$ select status, rows_created from public.import_batches
     where id = (current_setting('test.preview')::jsonb ->> 'batch_id')::uuid $$,
  $$ values ('failed'::text, 0) $$,
  'the batch stays marked failed although its data is rolled back');
select results_eq(
  $$ select (r ->> 'line')::int, e ->> 'code'
     from jsonb_array_elements(current_setting('test.commit')::jsonb -> 'rows') r,
          jsonb_array_elements(r -> 'errors') e $$,
  $$ values (4, 'account_not_found') $$,
  'the report points exactly at the bad row with account_not_found');
select results_eq(
  $$ select (r ->> 'line')::int, e ->> 'code'
     from public.import_batches b, jsonb_array_elements(b.report) r, jsonb_array_elements(r -> 'errors') e
     where b.id = (current_setting('test.preview')::jsonb ->> 'batch_id')::uuid $$,
  $$ values (4, 'account_not_found') $$,
  'the per-row report is saved in the batch');

-- 2. Проверки строки те же, что у create_entry; ошибки разбора файла и пересчёта тоже по строкам.
select set_config('test.preview', public.import_preview(jsonb_build_array(
  pg_temp.row(2, '{"category": "Нет такой"}'),
  pg_temp.row(3, '{"amount_minor": "0"}'),
  pg_temp.row(4, '{"occurred_on": "2026-10-31"}'),
  pg_temp.row(5, '{"purpose": "work", "category": null, "source": null}'),
  pg_temp.row(6, '{"source": null}'),
  pg_temp.row(7, '{"amount_minor": null, "errors": [{"field": "amount", "code": "amount_too_precise"}]}'),
  pg_temp.row(8, '{"type": "transfer", "to_account": "H1", "transfer_purpose": "move_own", "category": null, "purpose": null, "source": null}'),
  pg_temp.row(9, '{"type": "company_advance_return", "category": null, "purpose": null, "source": null}'),
  pg_temp.row(10, '{"type": "refund", "parent_external_id": "нет-траты", "category": null, "purpose": null, "source": null}')
), 'x.csv', 'csv')::text, true);
select results_eq(
  $$ select (r ->> 'line')::int, e ->> 'code', e ->> 'field'
     from jsonb_array_elements(current_setting('test.preview')::jsonb -> 'rows') r,
          jsonb_array_elements(r -> 'errors') e order by 1 $$,
  $$ values (2, 'category_not_found', 'category'), (3, 'amount_not_positive', 'amount'),
            (4, 'entry_before_start', 'occurred_on'), (5, 'missing_required', 'category'),
            (6, 'source_required', 'source'), (7, 'amount_too_precise', 'amount'),
            (8, 'same_account_transfer', 'to_account'), (9, 'advance_return_too_big', null),
            (10, 'entry_not_found', 'parent_external_id') $$,
  'row errors use the codes of create_entry and of the recompute, in file columns; parse errors pass through');

-- 3. Удачное подтверждение: всё создано учтённым, возврат покупки ссылается на трату из того же файла.
select set_config('test.preview', public.import_preview(jsonb_build_array(
  pg_temp.row(2, '{"category": "Реклама", "purpose": "work", "source": null, "amount_minor": "2000000", "external_id": "bank-1"}'),
  pg_temp.row(3, '{"type": "company_topup", "category": null, "purpose": null, "source": null, "amount_minor": "5000000", "fee_minor": "100000", "fee_payer": "own", "external_id": "bank-2"}'),
  pg_temp.row(4, '{"type": "refund", "occurred_on": "2026-11-04", "parent_external_id": "bank-1", "category": null, "purpose": null, "source": null, "amount_minor": "500000", "external_id": "bank-3"}'),
  pg_temp.row(5, '{"type": "adjustment", "account": null, "category": null, "purpose": null, "source": null, "amount_minor": "10000", "adjustment_target": "i_owe_company", "adjustment_sign": 1, "external_id": null}')
), 'bank.csv', 'csv')::text, true);
select is(current_setting('test.preview')::jsonb ->> 'rows_error', '0', 'a clean file has no row errors');
select set_config('test.commit', public.import_commit((current_setting('test.preview')::jsonb ->> 'batch_id')::uuid)::text, true);
select results_eq(
  $$ select c ->> 'status', (c ->> 'created')::int, (c ->> 'skipped')::int from (select current_setting('test.commit')::jsonb c) x $$,
  $$ values ('committed'::text, 4, 0) $$,
  'the confirmation creates every row');
select results_eq(
  $$ select type::text, status::text, external_id, (import_batch_id = (current_setting('test.preview')::jsonb ->> 'batch_id')::uuid)
     from public.entries where import_batch_id is not null order by seq $$,
  $$ values ('expense', 'done', 'bank-1', true), ('company_topup', 'done', 'bank-2', true),
            ('refund', 'done', 'bank-3', true), ('adjustment', 'done', null, true) $$,
  'imported entries are done and remember their batch and external id');
select is((select parent_entry_id from public.entries where external_id = 'bank-3'),
  (select id from public.entries where external_id = 'bank-1'), 'the refund points to the expense from the same file');
-- H1: 100 000 − 20 000 (работа своими, аванса нет) + 50 000 − 1 000 (пополнение, комиссия своими)
-- + 5 000 (возврат покупки) = 134 000 ₸, аванс 50 000. Компания должна мне: 20 000 + 1 000 − 5 000;
-- я должен компании: корректировка +100 ₸.
select results_eq(
  $$ select balance_minor, advance_minor from public.v_account_balances where name = 'H1' $$,
  $$ values (13400000::bigint, 5000000::bigint) $$,
  'the recompute at the end of the batch gives the account its balance and advance');
select results_eq(
  $$ select company_owes_me_minor, i_owe_company_minor from public.v_company_settlement $$,
  $$ values (1600000::bigint, 10000::bigint) $$,
  'and both sides of the debt');
select is((select status from public.import_batches where id = (current_setting('test.preview')::jsonb ->> 'batch_id')::uuid),
  'committed', 'the batch is committed');
select throws_ok(
  format('select public.import_commit(%L)', current_setting('test.preview')::jsonb ->> 'batch_id'),
  'import_batch_committed', 'a committed batch cannot be confirmed again');

-- 4. TC-IDEMPOTENT-IMPORT: тот же файл ещё раз, строки с теми же external_id пропускаются.
select set_config('test.before', pg_temp.counts(), true);
select set_config('test.preview', public.import_preview(jsonb_build_array(
  pg_temp.row(2, '{"category": "Реклама", "purpose": "work", "source": null, "amount_minor": "2000000", "external_id": "bank-1"}'),
  pg_temp.row(3, '{"type": "company_topup", "category": null, "purpose": null, "source": null, "amount_minor": "5000000", "fee_minor": "100000", "fee_payer": "own", "external_id": "bank-2"}'),
  pg_temp.row(4, '{"type": "refund", "occurred_on": "2026-11-04", "parent_external_id": "bank-1", "category": null, "purpose": null, "source": null, "amount_minor": "500000", "external_id": "bank-3"}')
), 'bank.csv', 'csv')::text, true);
select results_eq(
  $$ select r ->> 'status' from jsonb_array_elements(current_setting('test.preview')::jsonb -> 'rows') r $$,
  $$ values ('skip'::text), ('skip'), ('skip') $$,
  'TC-IDEMPOTENT-IMPORT: the preview marks already imported rows as skipped');
select set_config('test.commit', public.import_commit((current_setting('test.preview')::jsonb ->> 'batch_id')::uuid)::text, true);
select results_eq(
  $$ select c ->> 'status', (c ->> 'created')::int, (c ->> 'skipped')::int from (select current_setting('test.commit')::jsonb c) x $$,
  $$ values ('committed'::text, 0, 3) $$,
  'the second import creates nothing and skips every row');
select is(pg_temp.counts(), current_setting('test.before'), 'no duplicates appear');

-- 5. TC-DEDUP-IMPORT: возможный дубль по отпечатку в окне ±3 дня, в том числе внутри файла.
select pg_temp.entry(jsonb_build_object('type', 'expense', 'occurred_on', '2026-11-10', 'amount_minor', 70000,
  'account_id', pg_temp.acc('H1'), 'purpose', 'personal', 'source', 'own', 'title', 'Такси', 'category_id', pg_temp.cat('Еда')));
select set_config('test.preview', public.import_preview(jsonb_build_array(
  pg_temp.row(2, '{"occurred_on": "2026-11-12", "amount_minor": "70000", "title": "такси"}'),
  pg_temp.row(3, '{"occurred_on": "2026-11-14", "amount_minor": "70000", "title": "Такси"}'),
  pg_temp.row(4, '{"occurred_on": "2026-11-20", "amount_minor": "90000", "title": "Кофе"}'),
  pg_temp.row(5, '{"occurred_on": "2026-11-20", "amount_minor": "90000", "title": "Кофе"}'),
  pg_temp.row(6, '{"occurred_on": "2026-11-20", "amount_minor": "90001", "title": "Кофе"}')
), 'dup.csv', 'csv')::text, true);
select results_eq(
  $$ select (r ->> 'line')::int, r ->> 'status', jsonb_array_length(r -> 'duplicates'), r -> 'duplicates' -> 0 ->> 'line'
     from jsonb_array_elements(current_setting('test.preview')::jsonb -> 'rows') r $$,
  $$ values (2, 'create', 1, null::text), (3, 'create', 1, '2'), (4, 'create', 0, null), (5, 'create', 1, '4'),
            (6, 'create', 0, null) $$,
  'TC-DEDUP-IMPORT: same fingerprint within ±3 days is a possible duplicate, not an error; also inside the file');
select set_config('test.before', pg_temp.counts(), true);
select set_config('test.commit', public.import_commit((current_setting('test.preview')::jsonb ->> 'batch_id')::uuid,
  array[3, 5])::text, true);
select results_eq(
  $$ select c ->> 'status', (c ->> 'created')::int, (c ->> 'skipped')::int from (select current_setting('test.commit')::jsonb c) x $$,
  $$ values ('committed'::text, 3, 2) $$,
  'the owner decides: rows left out at the confirmation are skipped, the rest is created');

-- 6. Ошибка пересчёта при подтверждении откатывает всё и указывает строку.
select set_config('test.before', pg_temp.counts(), true);
select set_config('test.preview', public.import_preview(jsonb_build_array(
  pg_temp.row(2, '{"type": "income", "category": null, "source": null, "purpose": null, "external_id": "r-1"}'),
  pg_temp.row(3, '{"type": "company_advance_return", "amount_minor": "99000000", "category": null, "purpose": null, "source": null, "external_id": "r-2"}')
), 'replay.csv', 'csv')::text, true);
select set_config('test.commit', public.import_commit((current_setting('test.preview')::jsonb ->> 'batch_id')::uuid)::text, true);
select results_eq(
  $$ select c ->> 'status', c -> 'rows' -> 1 -> 'errors' -> 0 ->> 'code', pg_temp.counts() = current_setting('test.before')
     from (select current_setting('test.commit')::jsonb c) x $$,
  $$ values ('failed'::text, 'advance_return_too_big'::text, true) $$,
  'a rule broken in the recompute fails the batch at its row and nothing is created');

-- 7. Round trip: выгрузка пользователя 1 загружается пользователю 2 с теми же счетами и даёт те же записи.
select pg_temp.scenario(3, 500000, 600000);
select pg_temp.account('H1', 10000000, 2000000);
select pg_temp.account('KS');
select pg_temp.account('Visa USD', p_currency => 'USD');
select set_config('test.work', pg_temp.entry(jsonb_build_object('type', 'expense', 'occurred_on', '2026-11-02',
  'amount_minor', 2000000, 'account_id', pg_temp.acc('H1'), 'purpose', 'work', 'category_id', pg_temp.cat('Реклама'),
  'title', 'Таргет', 'comment', 'ноябрь, «первая» неделя'))::text, true);
select pg_temp.entry(jsonb_build_object('type', 'expense', 'occurred_on', '2026-11-02', 'amount_minor', 150000,
  'account_id', pg_temp.acc('H1'), 'purpose', 'personal', 'source', 'company', 'category_id', pg_temp.cat('Еда')));
select pg_temp.entry(jsonb_build_object('type', 'income', 'occurred_on', '2026-11-02', 'amount_minor', 300000,
  'account_id', pg_temp.acc('KS')));
select pg_temp.entry(jsonb_build_object('type', 'company_topup', 'occurred_on', '2026-11-03', 'amount_minor', 5000000,
  'account_id', pg_temp.acc('H1'), 'fee_minor', 100000, 'fee_payer', 'own'));
select pg_temp.entry(jsonb_build_object('type', 'transfer', 'occurred_on', '2026-11-03', 'amount_minor', 500000,
  'account_id', pg_temp.acc('H1'), 'to_account_id', pg_temp.acc('KS'), 'transfer_purpose', 'move_own',
  'fee_minor', 1000, 'fee_payer', 'own'));
select pg_temp.entry(jsonb_build_object('type', 'transfer', 'occurred_on', '2026-11-03', 'amount_minor', 200000,
  'account_id', pg_temp.acc('KS'), 'to_account_id', pg_temp.acc('H1'), 'transfer_purpose', 'repay_debt'));
select pg_temp.entry(jsonb_build_object('type', 'company_advance_return', 'occurred_on', '2026-11-04',
  'amount_minor', 100000, 'account_id', pg_temp.acc('H1')));
select pg_temp.entry(jsonb_build_object('type', 'settlement', 'occurred_on', '2026-11-04', 'amount_minor', 50000,
  'account_id', pg_temp.acc('KS'), 'settlement_direction', 'i_paid_company'));
select pg_temp.entry(jsonb_build_object('type', 'settlement', 'occurred_on', '2026-11-04', 'amount_minor', 40000,
  'account_id', pg_temp.acc('KS'), 'settlement_direction', 'company_paid_me'));
select pg_temp.entry(jsonb_build_object('type', 'netting', 'occurred_on', '2026-11-05', 'amount_minor', 10000));
select pg_temp.entry(jsonb_build_object('type', 'adjustment', 'occurred_on', '2026-11-05', 'amount_minor', 5000,
  'adjustment_target', 'i_owe_company', 'adjustment_sign', -1));
select pg_temp.entry(jsonb_build_object('type', 'adjustment', 'occurred_on', '2026-11-05', 'amount_minor', 7000,
  'account_id', pg_temp.acc('KS'), 'adjustment_target', 'balance', 'adjustment_sign', -1, 'adjustment_mode', 'plug_analytics'));
select pg_temp.entry(jsonb_build_object('type', 'refund', 'occurred_on', '2026-11-06', 'amount_minor', 500000,
  'parent_entry_id', current_setting('test.work')));
select pg_temp.entry(jsonb_build_object('type', 'expense', 'occurred_on', '2026-11-06', 'amount_minor', 1050,
  'currency', 'USD', 'rate_source', 'manual', 'rate', '480.5', 'account_id', pg_temp.acc('Visa USD'),
  'purpose', 'personal', 'source', 'own', 'category_id', pg_temp.cat('Еда')));
select set_config('test.rows', pg_temp.exported_rows()::text, true);
select set_config('test.picture', (select string_agg(r, E'\n' order by r) from pg_temp.picture()), true);

select results_eq(
  $$ select c ->> 'status', (c ->> 'created')::int, (c ->> 'skipped')::int
     from (select public.import_commit((public.import_preview(current_setting('test.rows')::jsonb, 'expenses.csv', 'csv')
                                         ->> 'batch_id')::uuid) c) x $$,
  $$ values ('committed'::text, 0, jsonb_array_length(current_setting('test.rows')::jsonb)) $$,
  'round trip: the export of a user loaded back into the same user creates nothing (external_id = entry id)');

select pg_temp.scenario(4);
select pg_temp.account('H1');
select pg_temp.account('KS');
select pg_temp.account('Visa USD', p_currency => 'USD');
select results_eq(
  $$ select c ->> 'status', (c ->> 'created')::int
     from (select public.import_commit((public.import_preview(current_setting('test.rows')::jsonb, 'expenses.csv', 'csv')
                                         ->> 'batch_id')::uuid) c) x $$,
  $$ values ('committed'::text, jsonb_array_length(current_setting('test.rows')::jsonb)) $$,
  'round trip: the same file is loaded into another user with the same accounts and categories');
select is((select string_agg(r, E'\n' order by r) from pg_temp.picture()), current_setting('test.picture'),
  'round trip: the same entries with the same external ids, balances, advances and debt');
select results_eq(
  $$ select c ->> 'status', (c ->> 'created')::int, (c ->> 'skipped')::int
     from (select public.import_commit((public.import_preview(current_setting('test.rows')::jsonb, 'expenses.csv', 'csv')
                                         ->> 'batch_id')::uuid) c) x $$,
  $$ values ('committed'::text, 0, jsonb_array_length(current_setting('test.rows')::jsonb)) $$,
  'round trip: loading it once more creates nothing thanks to external_id');

-- 8. Доступ: партии видны только своему разрешённому пользователю.
select throws_ok(
  format('select public.import_commit(%L)', current_setting('test.batch1')),
  'import_batch_not_found', 'someone else''s batch cannot be confirmed');
select is((select count(*) from public.import_batches where user_id <> auth.uid()), 0::bigint,
  'someone else''s batches are not visible');
select throws_ok($$ select public.import_preview('{}'::jsonb, 'x.csv', 'csv') $$, 'field_invalid',
  'rows must be an array');
reset role;
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000cc', 'stranger@example.com');
insert into public.app_users (email, user_id, allowed) values ('stranger@example.com', '00000000-0000-0000-0000-0000000000cc', false);
select set_config('role', 'authenticated', true);
select set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-0000000000cc', 'role', 'authenticated')::text, true);
select throws_ok($$ select public.import_preview('[]'::jsonb, 'x.csv', 'csv') $$, 'not_allowed',
  'a user who is not allowed cannot import');

select * from finish();
rollback;
