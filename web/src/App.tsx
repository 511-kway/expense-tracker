import { useEffect, useState } from "react";
import { supabaseUrl } from "./supabase";

type Health = "checking" | "up" | "down";

export function App() {
  const [health, setHealth] = useState<Health>("checking");

  useEffect(() => {
    fetch(`${supabaseUrl}/auth/v1/health`)
      .then((r) => setHealth(r.ok ? "up" : "down"))
      .catch(() => setHealth("down"));
  }, []);

  return (
    <main>
      <h1>Трекер затрат</h1>
      <p>
        Сервер:{" "}
        {health === "checking" ? "проверяю…" : health === "up" ? "доступен" : "недоступен"}
      </p>
    </main>
  );
}
