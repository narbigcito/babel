defmodule BabelWeb.ErrorJSON do
  def render("404.json", _assigns) do
    %{error: %{message: "Not found", type: "not_found", code: 404}}
  end

  def render("500.json", _assigns) do
    %{error: %{message: "Internal server error", type: "server_error", code: 500}}
  end
end
