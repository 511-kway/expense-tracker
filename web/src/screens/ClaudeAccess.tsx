import { useCallback, useEffect, useState } from "react";
import { supabase, supabaseUrl } from "../supabase";
import { errorText } from "../errors";
import { formatDate, formatDateTime } from "../dates";

type TokenRow = { token_hint: string; created_at: string; expires_at: string; last_used_at: string | null };

type State =
  | { kind: "loading" }
  | { kind: "error" }
  | { kind: "ready"; token: TokenRow | null };

/**
 * «Доступ для Claude Code» (док 04, раздел 11; тикет 20): выпустить, сменить и отозвать служебный
 * токен. Токен показывается один раз сразу после выпуска; в базе только его хэш, поэтому потом
 * виден лишь его начало. Смена выпускает новый, старый перестаёт работать сразу.
 */
export function ClaudeAccess() {
  const [state, setState] = useState<State>({ kind: "loading" });
  const [fresh, setFresh] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [confirm, setConfirm] = useState<"rotate" | "revoke" | null>(null);
  const [message, setMessage] = useState<{ error: boolean; text: string } | null>(null);
  const [copied, setCopied] = useState(false);

  const load = useCallback(async () => {
    const { data, error } = await supabase
      .from("claude_tokens")
      .select("token_hint, created_at, expires_at, last_used_at")
      .maybeSingle();
    setState(error ? { kind: "error" } : { kind: "ready", token: (data as TokenRow | null) ?? null });
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  async function issue(kind: "issue" | "rotate") {
    if (kind === "rotate" && confirm !== "rotate") return setConfirm("rotate");
    setBusy(true);
    setMessage(null);
    setCopied(false);
    const { data, error } = await supabase.rpc("claude_token_generate");
    setBusy(false);
    setConfirm(null);
    if (error) return setMessage({ error: true, text: errorText(error) });
    setFresh((data as { token: string }).token);
    await load();
  }

  async function revoke() {
    if (confirm !== "revoke") return setConfirm("revoke");
    setBusy(true);
    setMessage(null);
    const { error } = await supabase.rpc("claude_token_revoke");
    setBusy(false);
    setConfirm(null);
    if (error) return setMessage({ error: true, text: errorText(error) });
    setFresh(null);
    setMessage({ error: false, text: "Доступ отозван: Claude Code больше не может создавать записи" });
    await load();
  }

  async function copy() {
    if (!fresh) return;
    try {
      await navigator.clipboard.writeText(fresh);
      setCopied(true);
    } catch {
      setCopied(false);
    }
  }

  if (state.kind === "loading") return <div aria-busy="true" />;
  if (state.kind === "error") {
    return (
      <p className="error" role="alert">
        Не получилось загрузить доступ для Claude Code: сервер не ответил.
      </p>
    );
  }

  const token = state.token;
  const expired = token !== null && new Date(token.expires_at) <= new Date();
  const endpoint = `${supabaseUrl}/functions/v1/claude_ingest`;

  return (
    <section className="claude-access" aria-labelledby="claude-access-title">
      <h2 id="claude-access-title">Доступ для Claude Code</h2>
      <p className="muted">
        Claude Code разбирает заметки и создаёт записи по тем же правилам, что и форма: та же проверка, тот же
        пересчёт. Входит по служебному токену; в базе хранится только его хэш.
      </p>

      {fresh && (
        <div className="claude-access__fresh" role="status">
          <label htmlFor="claude-token">Новый токен</label>
          <div className="claude-access__token">
            <input id="claude-token" readOnly value={fresh} onFocus={(e) => e.currentTarget.select()} />
            <button className="button" type="button" onClick={copy}>
              {copied ? "Скопирован" : "Скопировать"}
            </button>
          </div>
          <p className="field__hint">
            Сохраните его сейчас, например в переменную CLAUDE_INGEST_TOKEN: больше его не покажем. Прежний токен
            уже не работает.
          </p>
        </div>
      )}

      {token ? (
        <dl className="claude-access__status">
          <div>
            <dt>Токен</dt>
            <dd className="amount">{token.token_hint}</dd>
          </div>
          <div>
            <dt>Последний вызов</dt>
            <dd>{token.last_used_at ? formatDateTime(token.last_used_at) : "Ещё не было"}</dd>
          </div>
          <div>
            <dt>{expired ? "Истёк" : "Действует до"}</dt>
            <dd className={expired ? "is-negative" : undefined}>{formatDate(token.expires_at.slice(0, 10))}</dd>
          </div>
        </dl>
      ) : (
        <p>Доступа пока нет. Выпустите токен и передайте его Claude Code.</p>
      )}

      <div className="claude-access__actions">
        {token ? (
          <>
            <button className="button" type="button" disabled={busy} onClick={() => issue("rotate")}>
              {confirm === "rotate" ? "Точно сменить токен" : "Сменить токен"}
            </button>
            <button className="button button--quiet button--danger" type="button" disabled={busy} onClick={revoke}>
              {confirm === "revoke" ? "Точно отозвать доступ" : "Отозвать доступ"}
            </button>
          </>
        ) : (
          <button className="button button--primary" type="button" disabled={busy} onClick={() => issue("issue")}>
            Выпустить токен
          </button>
        )}
      </div>
      {confirm && (
        <p className="field__hint">
          {confirm === "rotate"
            ? "Старый токен перестанет работать сразу: Claude Code понадобится новый."
            : "Claude Code сразу потеряет доступ. Записи, которые он уже создал, останутся."}
        </p>
      )}
      {message && (
        <p className={message.error ? "error" : "muted"} role={message.error ? "alert" : "status"}>
          {message.text}
        </p>
      )}

      <details className="claude-access__howto">
        <summary>Как Claude Code создаёт запись</summary>
        <p className="field__hint">
          POST на адрес ниже, токен в заголовке X-Claude-Token. Сначала action «context» (счета, категории, новые
          заметки), затем «create_entry» или «convert_note» с полями записи. Подробно в docs/claude-code-ingest.md.
        </p>
        <pre>{`curl -X POST ${endpoint} \\
  -H "X-Claude-Token: $CLAUDE_INGEST_TOKEN" \\
  -H "Content-Type: application/json" \\
  -d '{"action": "context"}'`}</pre>
      </details>
    </section>
  );
}
