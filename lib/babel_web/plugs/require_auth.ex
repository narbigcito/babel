defmodule BabelWeb.Plugs.RequireAuth do
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    password = System.get_env("BABEL_UI_PASSWORD")

    if is_nil(password) or password == "" or get_session(conn, :authenticated) == true do
      conn
    else
      conn
      |> redirect(to: "/login")
      |> halt()
    end
  end
end
