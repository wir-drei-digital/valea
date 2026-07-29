defmodule Valea.Mail.AutoconfigTest do
  use ExUnit.Case, async: true

  alias Valea.Mail.Autoconfig

  @ispdb_xml """
  <?xml version="1.0"?>
  <clientConfig version="1.1">
    <emailProvider id="infomaniak.ch">
      <incomingServer type="imap">
        <hostname>imap.infomaniak.com</hostname>
        <port>993</port>
        <socketType>SSL</socketType>
        <username>%EMAILADDRESS%</username>
      </incomingServer>
      <incomingServer type="imap">
        <hostname>imap.infomaniak.com</hostname>
        <port>143</port>
        <socketType>STARTTLS</socketType>
      </incomingServer>
      <outgoingServer type="smtp">
        <hostname>mail.infomaniak.com</hostname>
        <port>587</port>
        <socketType>STARTTLS</socketType>
      </outgoingServer>
    </emailProvider>
  </clientConfig>
  """

  describe "domain_of/1" do
    test "extracts and lowercases the domain" do
      assert {:ok, "wirdrei.digital"} = Autoconfig.domain_of("Daniel@Wirdrei.Digital")
    end

    test "rejects addresses without a usable domain" do
      assert {:error, :invalid_email} = Autoconfig.domain_of("not-an-address")
      assert {:error, :invalid_email} = Autoconfig.domain_of("@nolocal.com")
      assert {:error, :invalid_email} = Autoconfig.domain_of("x@nodot")
      assert {:error, :invalid_email} = Autoconfig.domain_of("x@bad domain.com")
    end
  end

  describe "parse_config/1" do
    test "picks the SSL imap entry (never the STARTTLS one) and the smtp entry" do
      assert %{
               imap: %{host: "imap.infomaniak.com", port: 993, security: "tls"},
               smtp: %{host: "mail.infomaniak.com", port: 587, security: "starttls"}
             } = Autoconfig.parse_config(@ispdb_xml)
    end

    test "a STARTTLS-only incoming server yields no imap guess" do
      xml = """
      <clientConfig><emailProvider>
        <incomingServer type="imap">
          <hostname>imap.x.com</hostname><port>143</port><socketType>STARTTLS</socketType>
        </incomingServer>
      </emailProvider></clientConfig>
      """

      assert %{imap: nil, smtp: nil} = Autoconfig.parse_config(xml)
    end

    test "garbage input parses to no servers" do
      assert %{imap: nil} = Autoconfig.parse_config("not xml at all")
      assert %{imap: nil} = Autoconfig.parse_config("<clientConfig></clientConfig>")
    end
  end

  describe "discover/2 source chain" do
    test "ISPDB by address domain wins first" do
      http_get = fn
        "https://autoconfig.thunderbird.net/v1.1/example.com" -> {:ok, @ispdb_xml}
        _other -> :error
      end

      assert {:ok, %{imap: %{host: "imap.infomaniak.com"}, source: "ispdb:example.com"}} =
               Autoconfig.discover("me@example.com",
                 http_get: http_get,
                 dns_lookup: fn _, _ -> [] end
               )
    end

    test "falls through to MX-derived ISPDB (custom domain at a known provider)" do
      http_get = fn
        "https://autoconfig.thunderbird.net/v1.1/infomaniak.ch" -> {:ok, @ispdb_xml}
        _other -> :error
      end

      dns_lookup = fn
        "wirdrei.digital", :mx -> [{10, ~c"mta-gw.infomaniak.ch"}]
        _, _ -> []
      end

      assert {:ok, %{imap: %{host: "imap.infomaniak.com"}, source: "ispdb:infomaniak.ch"}} =
               Autoconfig.discover("daniel@wirdrei.digital",
                 http_get: http_get,
                 dns_lookup: dns_lookup
               )
    end

    test "MX-derived falls through to the provider's own autoconfig when ISPDB misses (the Infomaniak case)" do
      http_get = fn
        "https://autoconfig.infomaniak.ch/mail/config-v1.1.xml" -> {:ok, @ispdb_xml}
        _other -> :error
      end

      dns_lookup = fn
        "wirdrei.digital", :mx -> [{5, ~c"mta-gw.infomaniak.ch"}]
        _, _ -> []
      end

      assert {:ok, %{imap: %{host: "imap.infomaniak.com"}, source: "autoconfig:infomaniak.ch"}} =
               Autoconfig.discover("daniel@wirdrei.digital",
                 http_get: http_get,
                 dns_lookup: dns_lookup
               )
    end

    test "falls through to DNS SRV (RFC 6186)" do
      dns_lookup = fn
        "_imaps._tcp.example.org", :srv -> [{0, 1, 993, ~c"mail.example.org."}]
        "_submission._tcp.example.org", :srv -> [{0, 1, 587, ~c"mail.example.org."}]
        _, _ -> []
      end

      assert {:ok,
              %{
                imap: %{host: "mail.example.org", port: 993, security: "tls"},
                smtp: %{host: "mail.example.org", port: 587, security: "starttls"},
                source: "srv:example.org"
              }} =
               Autoconfig.discover("me@example.org",
                 http_get: fn _ -> :error end,
                 dns_lookup: dns_lookup
               )
    end

    test "last resort: imap.<domain> heuristic, only when it resolves" do
      dns_lookup = fn
        "imap.example.net", :a -> [{192, 0, 2, 1}]
        "smtp.example.net", :a -> [{192, 0, 2, 2}]
        _, _ -> []
      end

      assert {:ok,
              %{
                imap: %{host: "imap.example.net", port: 993, security: "tls"},
                smtp: %{host: "smtp.example.net", port: 587, security: "starttls"},
                source: "guess:example.net"
              }} =
               Autoconfig.discover("me@example.net",
                 http_get: fn _ -> :error end,
                 dns_lookup: dns_lookup
               )
    end

    test "everything dry -> all-nil result, never an error" do
      assert {:ok, %{imap: nil, smtp: nil, source: nil}} =
               Autoconfig.discover("me@nowhere.invalid",
                 http_get: fn _ -> :error end,
                 dns_lookup: fn _, _ -> [] end
               )
    end

    test "an invalid email is the one error" do
      assert {:error, :invalid_email} = Autoconfig.discover("nope", http_get: fn _ -> :error end)
    end
  end
end
