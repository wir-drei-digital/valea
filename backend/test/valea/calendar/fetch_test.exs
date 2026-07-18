defmodule Valea.Calendar.FetchTest do
  use ExUnit.Case, async: false

  alias Valea.Calendar.Fetch

  @cacertfile Path.expand("../../fixtures/tls/ca.pem", __DIR__)

  # Every fake-server scenario needs the two documented test-only seams:
  # the server binds loopback (which the SSRF gate would otherwise reject)
  # and most scenarios speak plain HTTP (which the scheme gate would
  # otherwise reject). `verify_peer` itself is never weakened — the TLS
  # scenarios inject the fixture CA via `tls_opts:` exactly like the
  # ImapClient tests do.
  defp get_local(server, path, opts \\ []) do
    {etag, opts} = Keyword.pop(opts, :etag)
    {last_modified, opts} = Keyword.pop(opts, :last_modified)
    scheme = Keyword.get(opts, :scheme, "http")

    Fetch.get(
      "#{scheme}://127.0.0.1:#{server.port}#{path}",
      etag,
      last_modified,
      Keyword.merge([allow_http: true, allow_loopback: true], opts)
    )
  end

  describe "validate_url/1" do
    test "accepts an https URL with a host" do
      assert :ok =
               Fetch.validate_url(
                 "https://calendar.google.com/calendar/ical/x/private-abc/basic.ics"
               )
    end

    test "rejects http as :not_https" do
      assert {:error, :not_https} = Fetch.validate_url("http://example.com/feed.ics")
    end

    test "rejects other schemes as :not_https" do
      assert {:error, :not_https} = Fetch.validate_url("webcal://example.com/feed.ics")
      assert {:error, :not_https} = Fetch.validate_url("file:///etc/passwd")
    end

    test "rejects unparseable and host-less values as :invalid_url" do
      assert {:error, :invalid_url} = Fetch.validate_url("nonsense")
      assert {:error, :invalid_url} = Fetch.validate_url("")
      assert {:error, :invalid_url} = Fetch.validate_url("https://")
      assert {:error, :invalid_url} = Fetch.validate_url("https:///path-only")
      assert {:error, :invalid_url} = Fetch.validate_url("https://exa mple.com/feed.ics")
    end
  end

  describe "blocked_address?/1 (the SSRF address classifier)" do
    test "blocks IPv4 loopback, link-local, RFC 1918, CGNAT, and reserved ranges" do
      blocked = [
        {127, 0, 0, 1},
        {127, 255, 255, 255},
        {10, 0, 0, 1},
        {10, 255, 255, 255},
        {172, 16, 0, 1},
        {172, 31, 255, 255},
        {192, 168, 0, 1},
        {169, 254, 1, 1},
        {100, 64, 0, 1},
        {100, 127, 255, 255},
        {0, 0, 0, 0},
        {0, 1, 2, 3},
        {192, 0, 0, 1},
        {192, 0, 2, 1},
        {198, 18, 0, 1},
        {198, 19, 255, 255},
        {198, 51, 100, 7},
        {203, 0, 113, 9},
        {224, 0, 0, 1},
        {239, 255, 255, 255},
        {240, 0, 0, 1},
        {255, 255, 255, 255}
      ]

      for addr <- blocked do
        assert Fetch.blocked_address?(addr), "expected #{inspect(addr)} to be blocked"
      end
    end

    test "allows public IPv4 addresses, including near-miss neighbors of blocked ranges" do
      allowed = [
        {8, 8, 8, 8},
        {142, 250, 74, 110},
        {172, 15, 255, 255},
        {172, 32, 0, 1},
        {100, 63, 255, 255},
        {100, 128, 0, 1},
        {192, 0, 3, 1},
        {198, 17, 0, 1},
        {198, 20, 0, 1},
        {223, 255, 255, 255}
      ]

      for addr <- allowed do
        refute Fetch.blocked_address?(addr), "expected #{inspect(addr)} to be allowed"
      end
    end

    test "blocks IPv6 loopback, unspecified, link-local, ULA, multicast, and documentation" do
      blocked = [
        {0, 0, 0, 0, 0, 0, 0, 1},
        {0, 0, 0, 0, 0, 0, 0, 0},
        {0xFE80, 0, 0, 0, 0, 0, 0, 1},
        {0xFEBF, 0xFFFF, 0, 0, 0, 0, 0, 1},
        {0xFC00, 0, 0, 0, 0, 0, 0, 1},
        {0xFD12, 0x3456, 0, 0, 0, 0, 0, 1},
        {0xFF02, 0, 0, 0, 0, 0, 0, 1},
        {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}
      ]

      for addr <- blocked do
        assert Fetch.blocked_address?(addr), "expected #{inspect(addr)} to be blocked"
      end
    end

    test "classifies embedded IPv4 inside v4-mapped, v4-compatible, and NAT64 forms" do
      # ::ffff:127.0.0.1 and ::ffff:10.0.0.1 — mapped private v4 is blocked
      assert Fetch.blocked_address?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001})
      assert Fetch.blocked_address?({0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001})
      # ::ffff:8.8.8.8 — mapped public v4 is allowed
      refute Fetch.blocked_address?({0, 0, 0, 0, 0, 0xFFFF, 0x0808, 0x0808})
      # deprecated v4-compatible ::a.b.c.d is blocked outright (fail closed)
      assert Fetch.blocked_address?({0, 0, 0, 0, 0, 0, 0x0808, 0x0808})
      # NAT64 64:ff9b::10.0.0.1 blocked, 64:ff9b::8.8.8.8 allowed
      assert Fetch.blocked_address?({0x64, 0xFF9B, 0, 0, 0, 0, 0x0A00, 0x0001})
      refute Fetch.blocked_address?({0x64, 0xFF9B, 0, 0, 0, 0, 0x0808, 0x0808})
    end

    test "allows public IPv6 addresses" do
      refute Fetch.blocked_address?({0x2607, 0xF8B0, 0, 0, 0, 0, 0, 1})
      refute Fetch.blocked_address?({0x2A00, 0x1450, 0x4001, 0x0800, 0, 0, 0, 0x200E})
    end
  end

  describe "get/4 — plain scenarios against FakeFeedServer" do
    test "200 with etag/last-modified returns body and validators" do
      body = "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n"

      server =
        FakeFeedServer.start([
          %{
            expect: ~r/^GET \/feed\.ics HTTP\/1\.1\r\n/,
            respond:
              FakeFeedServer.response(
                200,
                ["etag: \"v1\"", "last-modified: Sat, 18 Jul 2026 08:00:00 GMT"],
                body
              )
          }
        ])

      assert {:ok, %{body: ^body, etag: "\"v1\"", last_modified: "Sat, 18 Jul 2026 08:00:00 GMT"}} =
               get_local(server, "/feed.ics")

      FakeFeedServer.await(server)
    end

    test "a response without validators returns nil etag/last_modified" do
      server =
        FakeFeedServer.start([
          %{respond: FakeFeedServer.response(200, [], "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n")}
        ])

      assert {:ok, %{etag: nil, last_modified: nil}} = get_local(server, "/feed.ics")
      FakeFeedServer.await(server)
    end

    test "a conditional GET carries If-None-Match/If-Modified-Since and 304 is :unchanged" do
      server =
        FakeFeedServer.start([
          %{
            expect:
              ~r/if-none-match: "v1"\r\n.*if-modified-since: Sat, 18 Jul 2026 08:00:00 GMT/is,
            respond: FakeFeedServer.response(304, ["etag: \"v1\""])
          }
        ])

      assert :unchanged =
               get_local(server, "/feed.ics",
                 etag: "\"v1\"",
                 last_modified: "Sat, 18 Jul 2026 08:00:00 GMT"
               )

      FakeFeedServer.await(server)
    end

    test "an unconditional GET carries no conditional headers" do
      server =
        FakeFeedServer.start([
          %{
            expect: ~r/\A(?!.*if-none-match)(?!.*if-modified-since).*\z/is,
            respond: FakeFeedServer.response(200, [], "ok")
          }
        ])

      assert {:ok, %{body: "ok"}} = get_local(server, "/feed.ics")
      FakeFeedServer.await(server)
    end

    test "a redirect chain of 3 same-origin hops is followed" do
      redirect = fn to -> FakeFeedServer.response(302, ["location: #{to}"]) end

      server =
        FakeFeedServer.start([
          %{expect: ~r/^GET \/feed\.ics /, respond: redirect.("/hop1")},
          %{expect: ~r/^GET \/hop1 /, respond: redirect.("/hop2")},
          %{expect: ~r/^GET \/hop2 /, respond: redirect.("/hop3")},
          %{expect: ~r/^GET \/hop3 /, respond: FakeFeedServer.response(200, [], "made it")}
        ])

      assert {:ok, %{body: "made it"}} = get_local(server, "/feed.ics")
      FakeFeedServer.await(server)
    end

    test "a 4th redirect is :redirect_limit" do
      redirect = fn to -> FakeFeedServer.response(302, ["location: #{to}"]) end

      server =
        FakeFeedServer.start([
          %{respond: redirect.("/hop1")},
          %{respond: redirect.("/hop2")},
          %{respond: redirect.("/hop3")},
          %{respond: redirect.("/hop4")}
        ])

      assert {:error, :redirect_limit} = get_local(server, "/feed.ics")
      FakeFeedServer.await(server)
    end

    test "a cross-origin redirect is rejected without connecting onward" do
      # The Location host does not exist and must never be resolved or
      # contacted — the same-origin check fires first. One exchange only.
      server =
        FakeFeedServer.start([
          %{
            respond:
              FakeFeedServer.response(302, [
                "location: https://feeds.invalid.example/feed.ics"
              ])
          }
        ])

      assert {:error, :cross_origin_redirect} = get_local(server, "/feed.ics")
      FakeFeedServer.await(server)
    end

    test "a same-host redirect to a different port is also cross-origin" do
      server = FakeFeedServer.start([%{respond: :close}])

      redirecting =
        FakeFeedServer.start([
          %{
            respond:
              FakeFeedServer.response(302, [
                "location: http://127.0.0.1:#{server.port}/feed.ics"
              ])
          }
        ])

      assert {:error, :cross_origin_redirect} = get_local(redirecting, "/feed.ics")
      FakeFeedServer.await(redirecting)
    end

    test "a declared content-length over the 20 MB default cap is :too_large without a download" do
      # Headers only, no body bytes: the client must reject on the declared
      # length at the default 20 MB cap, not stream 30 MB first.
      head =
        "HTTP/1.1 200 OK\r\ncontent-length: 30000000\r\nconnection: close\r\n\r\n"

      server = FakeFeedServer.start([%{respond: {:tolerate_abort, head}}])

      assert {:error, :too_large} = get_local(server, "/feed.ics")
      FakeFeedServer.await(server)
    end

    test "a chunked body exceeding the cap is aborted mid-stream as :too_large" do
      chunk = String.duplicate("x", 16_384)

      server =
        FakeFeedServer.start([
          %{
            respond:
              {:tolerate_abort, FakeFeedServer.chunked_response([], List.duplicate(chunk, 16))}
          }
        ])

      assert {:error, :too_large} = get_local(server, "/feed.ics", max_body_bytes: 50_000)
      FakeFeedServer.await(server)
    end

    test "a stalled server is :timeout" do
      server = FakeFeedServer.start([%{respond: :stall}])

      assert {:error, :timeout} = get_local(server, "/feed.ics", timeout: 300)
      FakeFeedServer.await(server)
    end

    test "an HTML error page served as 200 passes through (guarding is the parser's job)" do
      html = "<html><body>Please sign in</body></html>"

      server =
        FakeFeedServer.start([
          %{respond: FakeFeedServer.response(200, ["content-type: text/html"], html)}
        ])

      assert {:ok, %{body: ^html}} = get_local(server, "/feed.ics")
      FakeFeedServer.await(server)
    end

    test "HTTP error statuses come back as {:http, status}" do
      server =
        FakeFeedServer.start([
          %{respond: FakeFeedServer.response(404, [], "gone")},
          %{respond: FakeFeedServer.response(500, [], "boom")}
        ])

      assert {:error, {:http, 404}} = get_local(server, "/feed.ics")
      assert {:error, {:http, 500}} = get_local(server, "/feed.ics")
      FakeFeedServer.await(server)
    end
  end

  describe "get/4 — admission gates (no server, no packets)" do
    test "an http URL without the test seam is :not_https" do
      assert {:error, :not_https} = Fetch.get("http://127.0.0.1:9/feed.ics", nil, nil)
    end

    test "a malformed URL is :not_https" do
      assert {:error, :not_https} = Fetch.get("nonsense", nil, nil)
    end

    test "a private-range IP literal target is :ssrf_blocked before any connect" do
      assert {:error, :ssrf_blocked} = Fetch.get("https://10.0.0.1/feed.ics", nil, nil)
      assert {:error, :ssrf_blocked} = Fetch.get("https://192.168.1.10/feed.ics", nil, nil)
      assert {:error, :ssrf_blocked} = Fetch.get("https://[fd00::1]/feed.ics", nil, nil)
      assert {:error, :ssrf_blocked} = Fetch.get("https://[fe80::1]/feed.ics", nil, nil)
    end

    test "loopback is :ssrf_blocked without the test seam" do
      assert {:error, :ssrf_blocked} = Fetch.get("https://127.0.0.1:9/feed.ics", nil, nil)
      assert {:error, :ssrf_blocked} = Fetch.get("https://[::1]:9/feed.ics", nil, nil)
    end
  end

  describe "get/4 — TLS" do
    test "succeeds over TLS against the fixture CA" do
      body = "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n"

      server =
        FakeFeedServer.start(
          [%{expect: ~r/^GET \/feed\.ics /, respond: FakeFeedServer.response(200, [], body)}],
          tls: true
        )

      assert {:ok, %{body: ^body}} =
               Fetch.get("https://localhost:#{server.port}/feed.ics", nil, nil,
                 allow_loopback: true,
                 tls_opts: [cacertfile: @cacertfile]
               )

      FakeFeedServer.await(server)
    end

    test "an untrusted certificate is :tls (verify_peer, no escape hatch)" do
      server = FakeFeedServer.start([%{respond: :handshake_failure}], tls: true)

      assert {:error, :tls} =
               Fetch.get("https://localhost:#{server.port}/feed.ics", nil, nil,
                 allow_loopback: true
               )

      FakeFeedServer.await(server)
    end
  end
end
