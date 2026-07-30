defmodule Valea.Mail.CertProbeTest do
  use ExUnit.Case, async: true

  alias Valea.Mail.CertProbe

  # Real sockets against the fake IMAP server presenting the SELF-SIGNED
  # fixture pair — the ProtonMail Bridge shape this probe exists for. The
  # probe never verifies (it RETRIEVES what to pin; the human confirms the
  # fingerprint), so no trust root appears anywhere in these tests.

  @selfsigned Path.expand("../../fixtures/tls/selfsigned.pem", __DIR__)
  @selfsigned_key Path.expand("../../fixtures/tls/selfsigned.key", __DIR__)

  defp fixture_der do
    [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(File.read!(@selfsigned))
    der
  end

  defp fixture_sha256 do
    :sha256
    |> :crypto.hash(fixture_der())
    |> Base.encode16()
    |> String.codepoints()
    |> Enum.chunk_every(2)
    |> Enum.map_join(":", &Enum.join/1)
  end

  test "fetches the presented certificate over implicit TLS" do
    server =
      FakeImapServer.start([], tls: true, certfile: @selfsigned, keyfile: @selfsigned_key)

    assert {:ok, cert} = CertProbe.fetch("localhost", server.port, :tls)

    assert [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(cert.pem)
    assert der == fixture_der()
    assert cert.sha256 == fixture_sha256()
    assert cert.subject =~ "O=Valea Test Bridge"
    assert cert.subject =~ "CN=localhost"
    assert cert.not_after =~ ~r/^\d{4}-\d{2}-\d{2}$/

    assert :ok = FakeImapServer.await(server)
  end

  test "fetches over an IMAP STARTTLS preamble (the Bridge's 1143 shape)" do
    script = [{:send, "* OK ready"}, :starttls]

    server =
      FakeImapServer.start(script, tls: false, certfile: @selfsigned, keyfile: @selfsigned_key)

    assert {:ok, cert} = CertProbe.fetch("localhost", server.port, :starttls)
    assert [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(cert.pem)
    assert der == fixture_der()

    assert :ok = FakeImapServer.await(server)
  end

  test "a server refusing STARTTLS is an error, not a plaintext anything" do
    script = [
      {:send, "* OK ready"},
      {:expect, ~r/^A1 STARTTLS$/, then: ["A1 NO not here"]}
    ]

    server = FakeImapServer.start(script, tls: false)

    assert {:error, {:starttls_refused, :no, _text}} =
             CertProbe.fetch("localhost", server.port, :starttls)

    assert :ok = FakeImapServer.await(server)
  end

  test "an unreachable port is a clean error" do
    # Ephemeral port allocated then immediately closed — nothing listens.
    {:ok, listen} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listen)
    :ok = :gen_tcp.close(listen)

    assert {:error, _reason} = CertProbe.fetch("localhost", port, :tls)
    assert {:error, _reason} = CertProbe.fetch("localhost", port, :starttls)
  end
end
