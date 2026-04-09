defmodule AlemWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.
  """
  use AlemWeb, :html

  embed_templates "page_html/*"
end
