import { useAuth } from "./auth";
import { Login } from "./screens/Login";
import { Waitlist } from "./screens/Waitlist";
import { Shell } from "./screens/Shell";
import { FirstRun } from "./screens/FirstRun";
import { useSettings } from "./settings";

export function App() {
  const [auth, signOut] = useAuth();

  switch (auth.kind) {
    case "loading":
      return <div className="gate" aria-busy="true" />;
    case "signed-out":
      return <Login error={auth.error} />;
    case "waitlisted":
      return <Waitlist onBack={signOut} />;
    case "error":
      return <Login error={auth.message} />;
    case "signed-in":
      return <Workspace email={auth.email} name={auth.name} onSignOut={signOut} />;
  }
}

/** Внутри приложения: мастер первого запуска, пока дата начала учёта не задана (ADR-0008). */
function Workspace(props: { email: string; name: string | null; onSignOut: () => void }) {
  const [settings, reload] = useSettings();
  switch (settings.kind) {
    case "loading":
      return <div className="gate" aria-busy="true" />;
    case "error":
      return (
        <main className="gate">
          <div className="gate__inner">
            <p className="error" role="alert">
              Не получилось загрузить настройки: сервер не ответил.
            </p>
            <button className="button" type="button" onClick={reload}>
              Попробовать снова
            </button>
          </div>
        </main>
      );
    case "first-run":
      return <FirstRun onDone={reload} />;
    case "ready":
      return <Shell {...props} accountingStartDate={settings.accountingStartDate} />;
  }
}
