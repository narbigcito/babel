defmodule BabelWeb.Layouts do
  use BabelWeb, :html

  embed_templates "layouts/*"

  def auth_enabled?, do: System.get_env("BABEL_UI_PASSWORD") not in [nil, ""]
end
