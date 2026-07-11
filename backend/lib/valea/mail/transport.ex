defmodule Valea.Mail.Transport do
  @moduledoc """
  The IMAP operations `Valea.Mail.Engine` needs, independent of the
  underlying wire client. `Valea.Mail.ImapClient` is the real (`:ssl`
  socket) implementation; tests inject a fake per `FakeMailTransport`.

  Copied verbatim from the mail design spec (§Transport behaviour) — every
  later task types against this exact callback list and these exact
  signatures. Do not change a callback's shape here without updating every
  consumer.
  """

  @type conn :: term()
  @type config :: %{host: String.t(), port: pos_integer(), username: String.t()}

  @callback connect(config, credential :: String.t(), opts :: keyword()) ::
              {:ok, conn} | {:error, term()}
  @callback capabilities(conn) :: {:ok, [String.t()]}
  @callback list_folders(conn) :: {:ok, [String.t()]}
  @callback create_folder(conn, String.t()) :: :ok | {:error, term()}
  @callback select(conn, String.t()) ::
              {:ok, %{uidvalidity: integer(), uidnext: integer() | nil}} | {:error, term()}
  @callback uid_search(conn, String.t()) :: {:ok, [pos_integer()]} | {:error, term()}
  @callback uid_fetch_meta(conn, [pos_integer()]) ::
              {:ok, [%{uid: pos_integer(), size: non_neg_integer()}]} | {:error, term()}
  @callback uid_fetch_headers(conn, [pos_integer()]) ::
              {:ok, [%{uid: pos_integer(), header: binary()}]} | {:error, term()}
  @callback uid_fetch_full(conn, pos_integer()) :: {:ok, binary()} | {:error, term()}
  @callback uid_move(conn, pos_integer(), String.t()) ::
              :ok | {:error, term()} | {:unsupported, String.t()}
  @callback append(conn, folder :: String.t(), flags :: [String.t()], rfc822 :: binary()) ::
              :ok | {:error, term()}
  @callback logout(conn) :: :ok
end
