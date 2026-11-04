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
./scripts/web-dev.sh   # http://127.0.0.1:5173: ставит зависимости, берёт ключ из `supabase status`, запускает Vite
cd web && npm test     # тесты фронта (vitest)
cd web && npm run typecheck
```

Studio, API и фронт доступны с вашего компьютера через SSH-туннель:

```bash
ssh -L 54323:127.0.0.1:54323 -L 54321:127.0.0.1:54321 -L 5173:127.0.0.1:5173 user@your-vps
# Studio: http://localhost:54323, фронт: http://localhost:5173
```
