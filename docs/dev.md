# Локальная разработка

Нужно: Docker, [Supabase CLI](https://github.com/supabase/cli) (open source, Apache 2.0).

```bash
./scripts/dev-up.sh      # поднять Supabase (порты только на 127.0.0.1)
supabase db reset        # чистая база из миграций
supabase test db         # pgTAP тесты из supabase/tests/
supabase stop
```

Не запускайте `supabase start` напрямую на сервере с публичным IP: CLI публикует порты на `0.0.0.0`, и база с паролем `postgres` и Studio без пароля окажутся в интернете. `scripts/dev-up.sh` это предотвращает.

Фронт (React + Vite, Node нужен только для сборки):

```bash
cd web
npm ci
# ключ из `supabase status -o env` (ANON_KEY)
printf 'VITE_SUPABASE_URL=http://127.0.0.1:54321\nVITE_SUPABASE_ANON_KEY=<ANON_KEY>\n' > .env.local
npm run dev        # http://127.0.0.1:5173, только локальный адрес
npm test           # тесты фронта (vitest)
npm run typecheck
```

Studio, API и фронт доступны с вашего компьютера через SSH-туннель:

```bash
ssh -L 54323:127.0.0.1:54323 -L 54321:127.0.0.1:54321 -L 5173:127.0.0.1:5173 user@your-vps
# Studio: http://localhost:54323, фронт: http://localhost:5173
```
