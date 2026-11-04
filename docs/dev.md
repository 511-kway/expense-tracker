# Локальная разработка

Нужно: Docker, [Supabase CLI](https://github.com/supabase/cli) (open source, Apache 2.0).

```bash
cp .env.example .env     # один раз: впишите ADMIN_EMAIL (свой email), Google-ключи по желанию
./scripts/dev-up.sh      # поднять Supabase (порты только на 127.0.0.1) и разрешить владельца
./scripts/db-reset.sh    # чистая база из миграций и сидов плюс владелец из ADMIN_EMAIL
supabase test db         # pgTAP тесты из supabase/tests/
supabase stop
```

Не запускайте `supabase start` напрямую на сервере с публичным IP: CLI публикует порты на `0.0.0.0`, и база с паролем `postgres` и Studio без пароля окажутся в интернете. `scripts/dev-up.sh` это предотвращает.

Фронт (React + Vite, Node нужен только для сборки):

```bash
./scripts/web-dev.sh   # http://127.0.0.1:5173: ставит зависимости, берёт ключ из `supabase status`, запускает Vite
cd web && npm test     # тесты фронта (vitest)
cd web && npm run typecheck
```

Studio, API, почта и фронт доступны с вашего компьютера через SSH-туннель:

```bash
ssh -L 54323:127.0.0.1:54323 -L 54321:127.0.0.1:54321 -L 54324:127.0.0.1:54324 -L 5173:127.0.0.1:5173 user@your-vps
# Studio: http://localhost:54323, фронт: http://localhost:5173, Mailpit: http://localhost:54324
```

## Доступ: владелец и лист ожидания (ADR-0007)

- Войти может кто угодно, но внутрь пускают только строки `app_users` с `allowed = true`. Остальные видят «Добавили вас в лист ожидания», попытка записывается (`attempts`, `last_attempt_at`), сессия завершается.
- Владелец берётся из `ADMIN_EMAIL` (корневой `.env` или окружение). SQL-сид не умеет читать env, поэтому строку делает `scripts/allow-owner.sh`: вызывает RPC `allow_owner(email)` service_role-ключом. Его зовут `dev-up.sh` и `db-reset.sh`; после голого `supabase db reset` запустите `./scripts/allow-owner.sh` сами. Деплой (тикет 21) зовёт тот же скрипт с `SUPABASE_URL` и `SUPABASE_SERVICE_ROLE_KEY` в окружении.
- Пустить другого человека: Studio → Table Editor → `app_users` → `allowed = true`. Снять отметку: доступ пропадает сразу, даже с живой сессией.
- `register_login()` зовётся при каждом открытии приложения с сессией, поэтому у владельца `attempts` растёт с каждым открытием, у человека из листа ожидания с каждой попыткой входа.

### Новая таблица с данными

Каждая таблица с данными пользователя имеет колонку `user_id uuid not null default auth.uid() references auth.users` и в той же миграции:

```sql
select public.apply_user_rls('public.accounts');
```

Это включает RLS и ставит одну политику `user_rows` на чтение и запись: `user_id = auth.uid() and is_allowed()`, и закрывает таблицу от `anon`. Что можно делать с клиента, решают GRANT'ы таблицы (например, `entries` с клиента только читается: `revoke insert, update, delete ... from authenticated`). Тест `supabase/tests/database/900_rls_guard.test.sql` падает, если таблица с `user_id` осталась без RLS или с политикой без `is_allowed()`.

RPC с данными первым шагом зовут `perform public.assert_allowed();` (ошибка `not_allowed`, док 05).

### Движок

Денежная логика в схеме `engine` (миграция `20261105120000_engine_and_first_run.sql`), наружу её не видно. Любая RPC, меняющая записи, в конце зовёт `engine.recompute(user_id)`: полный пересчёт журнала по хронологии (ADR-0002, ADR-0006). Новый тип записи: функция `engine.apply_<тип>(st, e)` и ветка в `engine.apply_entry`; движения только через `engine.post`, нарушения правил через `engine.fail('<код>', e, info)`, предупреждения в `engine.collect_warnings`. Ошибка приходит клиенту как `message` = код, `details` = JSON с `entry_id`. Корректировка (`engine.apply_adjustment`) умеет цели «остаток» (с авансом или без) и обе стороны долга; счета и стартовый остаток в миграции `20261106120000_accounts.sql`.

Записи создаются, правятся и удаляются только RPC `create_entry(p_payload)`, `update_entry(p_entry_id, p_payload)`, `delete_entry(p_entry_id)` (миграция `20261107120000_expense_and_income.sql`); payload по доку 05, суммы целыми тиынами. Путь записи: `engine.entry_from_payload` (JSON → строка, неверный тип значения = `field_invalid`) → `engine.check_entry` (общие поля, дата начала учёта, затем ветка по типу `engine.check_<тип>(n, e)`: переносит в чистую строку только поля своего типа и проверяет их) → `engine.insert_entry` / `engine.replace_entry` → `engine.recompute`. Новый тип записи: `engine.check_<тип>` и ветка в `engine.check_entry` плюс `engine.apply_<тип>` и ветка в `engine.apply_entry`. Пополнение от компании и изъятие аванса в миграции `20261108120000_company_topup.sql` (комиссию пополнения в форме считает RPC `topup_amounts`). Переводы в миграции `20261109120000_transfers.sql` (форме долг на дату отдаёт RPC `debt_on_date`). Ответ `{ok, entry_id, status, warnings}`: предупреждения о дубле (`possible_duplicate`) и пересчёта (`negative_balance`, его выдаёт `engine.collect_warnings(до, после, запись)`).

## Вход через Google на localhost

Без ключей стек стартует, но кнопка «Войти через Google» упрётся в ошибку Google. Чтобы завести ключи:

1. [Google Cloud Console](https://console.cloud.google.com/) → создайте проект (или выберите свой).
2. APIs & Services → OAuth consent screen: тип External, название приложения, свой email как поддержка. Пока приложение в статусе Testing, добавьте свой Google-аккаунт в Test users.
3. APIs & Services → Credentials → Create credentials → OAuth client ID → Web application.
   - Authorized JavaScript origins: `http://localhost:5173`
   - Authorized redirect URIs: `http://localhost:54321/auth/v1/callback` (так в `supabase/config.toml`, `[auth.external.google] redirect_uri`).
4. Client ID и Client secret впишите в корневой `.env` как `GOOGLE_CLIENT_ID` и `GOOGLE_CLIENT_SECRET`, затем `supabase stop && ./scripts/dev-up.sh` (dev-up передаёт `.env` в Supabase CLI).
5. Откройте фронт через SSH-туннель именно как `http://localhost:5173` (Google принимает http только для localhost).

Для прода в том же OAuth client добавьте боевые origin и redirect URI (`https://<домен>/auth/v1/callback`), это часть тикета 21.

## Вход по ссылке из письма (только локально)

Пока Google-ключей нет, войти можно по email: `scripts/web-dev.sh` ставит `VITE_DEV_EMAIL_LOGIN=true`, и на экране входа появляется форма «Отправить ссылку для входа». Письмо ловит локальный Mailpit (http://localhost:54324), ссылка из письма логинит. Лист ожидания действует так же: внутрь пускают только `ADMIN_EMAIL` и строки с `allowed = true`.

В проде этого входа нет и не должно быть:
- форма показывается только в `vite dev` (`import.meta.env.DEV`), из сборки `npm run build` она вырезается при любом значении флага; не задавайте `VITE_DEV_EMAIL_LOGIN` и в окружении сборки;
- на прод-GoTrue выключите email-провайдер (`GOTRUE_EXTERNAL_EMAIL_ENABLED=false` в self-hosted Supabase), оставьте только Google. Лимит писем `auth.rate_limit.email_sent = 30` в `config.toml` поднят только для локальной разработки.
