import { useEffect, useState } from "react";

function App() {
  const [status, setStatus] = useState<string>("loading...");

  useEffect(() => {
    fetch("/api/health")
      .then((res) => {
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        return res.json();
      })
      .then((data: { status: string }) => setStatus(data.status))
      .catch((err: Error) => setStatus(`error: ${err.message}`));
  }, []);

  return (
    <div style={{ padding: "2rem", fontFamily: "sans-serif" }}>
      <h1>Health Check</h1>
      <p>Status: <strong>{status}</strong></p>
    </div>
  );
}

export default App;