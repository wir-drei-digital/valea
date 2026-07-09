defmodule ValeaWeb.SpaController do
  use Phoenix.Controller, formats: [:html]

  def index(conn, _params) do
    index = Path.join(Application.app_dir(:valea, "priv/static"), "index.html")

    if File.exists?(index) do
      conn |> put_resp_content_type("text/html") |> send_file(200, index)
    else
      send_resp(conn, 404, "frontend build not present")
    end
  end
end
