defmodule ValeaWeb.SpaController do
  use Phoenix.Controller, formats: [:html]

  def index(conn, _params) do
    index = Path.join(Application.app_dir(:valea, "priv/static"), "index.html")

    if File.exists?(index) do
      conn
      |> put_resp_content_type("text/html")
      |> put_csp()
      |> send_file(200, index)
    else
      send_resp(conn, 404, "frontend build not present")
    end
  end

  # Scripts and fonts are bundled into the build (file-first, no CDN), so
  # 'self' covers them; 'unsafe-inline' for styles is required by Svelte's
  # transitions/inline styles. connect-src allows the loopback socket + HTTP
  # RPC the SPA makes back to the sidecar.
  #
  # script-src carries 'unsafe-inline' ON PURPOSE. SvelteKit's adapter-static
  # build boots hydration from an INLINE <script> in index.html, and the strict
  # policy for it lives in a <meta http-equiv="content-security-policy"> the
  # build emits with a per-build sha256 hash (see frontend/svelte.config.js
  # kit.csp). This response header cannot know that per-build hash, so it must
  # not veto the meta's hashes: a browser enforces the INTERSECTION of header
  # and meta CSPs, and a hash-based script-src silently drops 'unsafe-inline',
  # so the effective policy stays hash-gated. Removing script-src here would NOT
  # help — default-src 'self' would then govern scripts and still block the
  # inline bootstrap; the permissive script-src is what lets the meta's hashes win.
  defp put_csp(conn) do
    put_resp_header(
      conn,
      "content-security-policy",
      "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; " <>
        "connect-src 'self' ws://localhost:* http://localhost:*; img-src 'self' data:; font-src 'self'"
    )
  end
end
