// Explicitly propagate closes in both directions. Passing a DO's upgrade
// response straight through can leave silent clients waiting for TCP teardown.
// The room still uses hibernating sockets; this ingress adapter has no storage.
export function proxySocket(response: Response): Response {
  const backend = response.webSocket!;
  const pair = new WebSocketPair(), client = pair[0], server = pair[1];
  backend.accept({ allowHalfOpen: false }); server.accept({ allowHalfOpen: false });
  function close(target: WebSocket, code: number, reason: string): void {
    if (target.readyState === 1) target.close(code === 1005 || code === 1006 ? 1000 : code, reason);
  }
  backend.addEventListener("message", event => { if (server.readyState === 1) server.send(event.data); });
  server.addEventListener("message", event => { if (backend.readyState === 1) backend.send(event.data); });
  backend.addEventListener("close", event => close(server, event.code, event.reason));
  server.addEventListener("close", event => close(backend, event.code, event.reason));
  backend.addEventListener("error", () => close(server, 1011, "unavailable"));
  server.addEventListener("error", () => close(backend, 1011, "unavailable"));
  return new Response(null, { status: 101, webSocket: client, headers: response.headers });
}
