import { useState, type FormEvent } from "react";
import { devEmailLogin, supabase } from "../supabase";
import { OwnershipMark } from "./OwnershipMark";

export function Login({ error }: { error?: string }) {
  const [failure, setFailure] = useState(error);
  const [busy, setBusy] = useState(false);

  async function signInWithGoogle() {
    setBusy(true);
    const { error } = await supabase.auth.signInWithOAuth({
      provider: "google",
      options: { redirectTo: window.location.origin },
    });
    if (error) {
      setBusy(false);
      setFailure("Вход через Google сейчас недоступен. Попробуйте позже.");
    }
  }

  return (
    <main className="gate">
      <div className="gate__inner">
        <OwnershipMark className="gate__mark" />
        <div className="gate__text">
          <h1>Трекер затрат</h1>
          <p className="muted">Свои деньги, аванс и расчёт с компанией по каждой карте.</p>
        </div>
        <div className="gate__actions">
          <button className="button button--primary" type="button" onClick={signInWithGoogle} disabled={busy}>
            <GoogleIcon />
            Войти через Google
          </button>
          {failure && (
            <p className="error" role="alert">
              {failure}
            </p>
          )}
        </div>
        {devEmailLogin && <DevEmailLogin />}
      </div>
    </main>
  );
}

/** Только для локальной разработки: письмо со ссылкой ловит Mailpit (docs/dev.md). */
function DevEmailLogin() {
  const [email, setEmail] = useState("");
  const [sentTo, setSentTo] = useState<string | null>(null);
  const [failure, setFailure] = useState<string | null>(null);

  async function submit(e: FormEvent) {
    e.preventDefault();
    setFailure(null);
    const { error } = await supabase.auth.signInWithOtp({
      email,
      options: { emailRedirectTo: window.location.origin },
    });
    if (error) setFailure(`Письмо не отправлено: ${error.message}`);
    else setSentTo(email);
  }

  return (
    <form className="dev-login" onSubmit={submit}>
      <p className="muted">Локальная разработка: вход по ссылке из письма. Письма приходят в Mailpit на порту 54324.</p>
      <div className="field">
        <label htmlFor="dev-email">Email</label>
        <input
          id="dev-email"
          type="email"
          autoComplete="email"
          required
          value={email}
          onChange={(e) => setEmail(e.target.value)}
        />
      </div>
      <button className="button" type="submit">
        Отправить ссылку для входа
      </button>
      {sentTo && <p role="status">Ссылка отправлена на {sentTo}. Откройте письмо в Mailpit.</p>}
      {failure && (
        <p className="error" role="alert">
          {failure}
        </p>
      )}
    </form>
  );
}

function GoogleIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 48 48" aria-hidden="true">
      <path fill="#FFC107" d="M43.6 20.1H42V20H24v8h11.3C33.7 32.7 29.2 36 24 36c-6.6 0-12-5.4-12-12s5.4-12 12-12c3.1 0 5.8 1.2 7.9 3.1l5.7-5.7C34 6.1 29.3 4 24 4 12.9 4 4 12.9 4 24s8.9 20 20 20 20-8.9 20-20c0-1.3-.1-2.6-.4-3.9z" />
      <path fill="#FF3D00" d="m6.3 14.7 6.6 4.8C14.7 15.1 19 12 24 12c3.1 0 5.8 1.2 7.9 3.1l5.7-5.7C34 6.1 29.3 4 24 4 16.3 4 9.7 8.3 6.3 14.7z" />
      <path fill="#4CAF50" d="M24 44c5.2 0 9.9-2 13.4-5.2l-6.2-5.2C29.2 35.1 26.7 36 24 36c-5.2 0-9.6-3.3-11.3-8l-6.5 5C9.5 39.6 16.2 44 24 44z" />
      <path fill="#1976D2" d="M43.6 20.1H42V20H24v8h11.3c-.8 2.2-2.2 4.2-4.1 5.6l6.2 5.2C37 39.2 44 34 44 24c0-1.3-.1-2.6-.4-3.9z" />
    </svg>
  );
}
