import { StrictMode, useEffect, useState } from "react";
import { createRoot } from "react-dom/client";

function App() {
  const [health, setHealth] = useState<string>("…");
  useEffect(() => {
    fetch("/api/health")
      .then((r) => r.json() as Promise<{ status: string }>)
      .then((d) => setHealth(d.status))
      .catch(() => setHealth("unreachable"));
  }, []);
  return (
    <main style={{ fontFamily: "system-ui", padding: 32 }}>
      <h1>It works 🚀</h1>
      <p>
        Backend health: <strong>{health}</strong>
      </p>
      <p>Edit <code>ui/main.tsx</code> and the FastAPI backend under <code>src/</code>.</p>
    </main>
  );
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
