defmodule BabelWeb.SessionController do
  use BabelWeb, :controller

  alias Babel.ConfigLoader

  def new(conn, _params) do
    if ConfigLoader.auth_mode() == :none do
      redirect(conn, to: "/")
    else
      conn
      |> put_layout(html: false)
      |> render(:new, mode: ConfigLoader.auth_mode(), error: nil)
    end
  end

  def create(conn, params) do
    username = Map.get(params, "username", "")
    password = Map.get(params, "password", "")

    if ConfigLoader.authenticate_user(username, password) do
      conn
      |> put_session(:authenticated, true)
      |> put_session(:username, username)
      |> redirect(to: "/")
    else
      conn
      |> put_layout(html: false)
      |> render(:new,
        mode: ConfigLoader.auth_mode(),
        error: "Credenciales incorrectas."
      )
    end
  end

  def delete(conn, _params) do
    conn
    |> clear_session()
    |> redirect(to: "/login")
  end
end
