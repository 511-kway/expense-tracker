# 10. Живой предпросмотр считает сервер

Статус: принято (2026-11-03).

## Решение
RPC `preview_entry(payload)` → `{ deltas: { balance, card_advance, company_owes_me, i_owe_company } по счетам, before, after, warnings }`. Внутри: та же валидация и тот же `recompute`, сравнение счётчиков до и после, затем откат (savepoint/исключение). Клиент формулы не дублирует. Фронт зовёт с debounce ~300 мс.
