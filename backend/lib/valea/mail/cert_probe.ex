defmodule Valea.Mail.CertProbe do
  @moduledoc """
  Retrieves the certificate a mail server PRESENTS — the trust-on-first-use
  half of the `tls_cacert_file` pin (setup form's "Fetch certificate",
  `fetch_mail_server_cert` RPC). Exists because a local bridge's certificate
  often lives nowhere a client can read (ProtonMail Bridge v3 keeps its
  inside an encrypted vault); the one place it is always available is the
  TLS handshake itself.

  ## Why `verify: :verify_none` is correct here — and ONLY here

  This connection is never used for anything: no credential is formatted,
  no command follows the handshake, nothing read off the socket is
  interpreted beyond the STARTTLS preamble. Its sole output is the identity
  the server CLAIMED, handed to a human as a subject + SHA-256 fingerprint
  to confirm before it becomes the account's pinned trust root — after
  which every real connection verifies strictly against those exact bytes
  (`Valea.Mail.ImapClient`'s pinning `verify_fun`). Verifying a probe whose
  entire purpose is to discover what to verify against would be circular.
  No other module may borrow this posture; grep for `verify_none` — this
  must stay the only production match.

  The STARTTLS preamble is the IMAP one (`Valea.Mail.ImapClient`'s shape,
  minus everything after the upgrade). One probe covers both protocols in
  practice: the pin file is per-ACCOUNT, and a local bridge presents the
  same certificate on its IMAP and SMTP ports.
  """

  alias Valea.Mail.Imap.Wire

  @timeout 5_000

  # RDN attribute types worth printing, in no particular order — the
  # subject line preserves the certificate's own RDN order.
  @rdn_labels %{
    {2, 5, 4, 3} => "CN",
    {2, 5, 4, 6} => "C",
    {2, 5, 4, 7} => "L",
    {2, 5, 4, 8} => "ST",
    {2, 5, 4, 10} => "O",
    {2, 5, 4, 11} => "OU"
  }

  @type cert :: %{pem: String.t(), sha256: String.t(), subject: String.t(), not_after: String.t()}

  @doc """
  Connects to `host:port` with the given security mode (`:tls` implicit,
  `:starttls` the IMAP upgrade preamble), captures the peer certificate,
  and closes. Returns its PEM plus the display fields the confirmation UI
  shows (colon-separated uppercase SHA-256 of the DER, the subject RDNs,
  and the not-after date).
  """
  @spec fetch(String.t(), pos_integer(), :tls | :starttls) :: {:ok, cert()} | {:error, term()}
  def fetch(host, port, security) when is_binary(host) and is_integer(port) do
    case peer_der(host, port, security) do
      {:ok, der} -> {:ok, describe(der)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp peer_der(host, port, :tls) do
    case :ssl.connect(String.to_charlist(host), port, probe_tls_opts(), @timeout) do
      {:ok, socket} ->
        der = capture_peercert(socket)
        :ssl.close(socket)
        der

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp peer_der(host, port, :starttls) do
    plain_opts = [active: false, mode: :binary, packet: :raw]

    case :gen_tcp.connect(String.to_charlist(host), port, plain_opts, @timeout) do
      {:ok, plain} ->
        with {:ok, buffer} <- plain_greeting(plain),
             :ok <- starttls_exchange(plain, buffer),
             {:ok, socket} <- :ssl.connect(plain, probe_tls_opts(), @timeout) do
          der = capture_peercert(socket)
          :ssl.close(socket)
          der
        else
          {:error, reason} ->
            :gen_tcp.close(plain)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # See the moduledoc: the probe's output is the UNVERIFIED claim, by design.
  defp probe_tls_opts do
    [verify: :verify_none, active: false, mode: :binary, packet: :raw]
  end

  defp capture_peercert(socket) do
    case :ssl.peercert(socket) do
      {:ok, der} -> {:ok, der}
      {:error, reason} -> {:error, {:no_peercert, reason}}
    end
  end

  # The same two plaintext exchanges `Valea.Mail.ImapClient.establish/6`
  # performs before its upgrade, minus the injection guard — residual bytes
  # can't matter on a socket that is only ever read for a handshake and
  # then closed.
  defp plain_greeting(socket) do
    case read_plain_response(socket, "") do
      {:ok, {:untagged, _line}, rest} -> {:ok, rest}
      {:ok, other, _rest} -> {:error, {:unexpected_greeting, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp starttls_exchange(socket, buffer) do
    with :ok <- :gen_tcp.send(socket, "A1 STARTTLS\r\n") do
      case read_plain_response(socket, buffer) do
        {:ok, {:tagged, "A1", :ok, _text}, _rest} -> :ok
        {:ok, {:tagged, "A1", status, text}, _rest} -> {:error, {:starttls_refused, status, text}}
        {:ok, other, _rest} -> {:error, {:unexpected_response, other}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp read_plain_response(socket, buffer) do
    case Wire.pull(buffer) do
      {:ok, response, rest} ->
        {:ok, response, rest}

      :incomplete ->
        case :gen_tcp.recv(socket, 0, @timeout) do
          {:ok, data} -> read_plain_response(socket, buffer <> data)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # -- display fields -----------------------------------------------------------

  defp describe(der) do
    # `pem_encode` terminates each entry with a blank line; a single trailing
    # newline matches what an exported cert.pem conventionally looks like.
    pem =
      [{:Certificate, der, :not_encrypted}]
      |> :public_key.pem_encode()
      |> String.trim_trailing()
      |> Kernel.<>("\n")

    %{
      pem: pem,
      sha256: fingerprint(der),
      subject: subject_line(der),
      not_after: not_after(der)
    }
  end

  defp fingerprint(der) do
    :sha256
    |> :crypto.hash(der)
    |> Base.encode16()
    |> String.codepoints()
    |> Enum.chunk_every(2)
    |> Enum.map_join(":", &Enum.join/1)
  end

  # `:public_key.pkix_decode_cert(der, :otp)` yields `#OTPCertificate{}` /
  # `#OTPTBSCertificate{}` records; matched positionally (element 2 of the
  # certificate is its TBS; the TBS's issuer/validity/subject sit at fixed
  # record positions) rather than via `Record.extract`, which would pull the
  # whole `public_key` hrl in for two field reads.
  defp subject_line(der) do
    tbs = der |> :public_key.pkix_decode_cert(:otp) |> elem(1)
    {:rdnSequence, rdns} = elem(tbs, 6)

    rdns
    |> List.flatten()
    |> Enum.flat_map(fn {:AttributeTypeAndValue, oid, value} ->
      case {Map.get(@rdn_labels, oid), attribute_text(value)} do
        {nil, _text} -> []
        {_label, nil} -> []
        {label, text} -> ["#{label}=#{text}"]
      end
    end)
    |> Enum.join(", ")
  end

  defp attribute_text({:utf8String, text}) when is_binary(text), do: text
  defp attribute_text({:printableString, chars}), do: to_string(chars)
  defp attribute_text({:teletexString, chars}), do: to_string(chars)
  defp attribute_text({:ia5String, chars}), do: to_string(chars)
  defp attribute_text(_other), do: nil

  defp not_after(der) do
    tbs = der |> :public_key.pkix_decode_cert(:otp) |> elem(1)
    {:Validity, _not_before, not_after} = elem(tbs, 5)
    format_time(not_after)
  end

  # utcTime is YYMMDD... with RFC 5280's 1950-2049 window; generalTime is
  # YYYYMMDD... . Only the date part matters for "when does this pin expire".
  defp format_time({:utcTime, chars}) do
    <<yy::binary-size(2), mm::binary-size(2), dd::binary-size(2), _rest::binary>> =
      to_string(chars)

    century = if String.to_integer(yy) >= 50, do: "19", else: "20"
    "#{century}#{yy}-#{mm}-#{dd}"
  end

  defp format_time({:generalTime, chars}) do
    <<yyyy::binary-size(4), mm::binary-size(2), dd::binary-size(2), _rest::binary>> =
      to_string(chars)

    "#{yyyy}-#{mm}-#{dd}"
  end

  defp format_time(_other), do: ""
end
