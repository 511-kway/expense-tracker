import { useAuth } from "./auth";
import { Login } from "./screens/Login";
import { Waitlist } from "./screens/Waitlist";
import { Shell } from "./screens/Shell";

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
      return <Shell email={auth.email} name={auth.name} onSignOut={signOut} />;
  }
}
