defmodule DrowzeeWeb.HomeLiveTest do
  use DrowzeeWeb.ConnCase

  setup do
    K8s.Client.DynamicHTTPProvider.register(self(), fn _method, _url, _body, _headers, _opts ->
      {:ok, %{"items" => []}}
    end)
    :ok
  end

  describe "Index" do
    @tag capture_log: true
    test "home redirects to namespace", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert redirected_to(conn) =~ ~r"^/(default|all)"
    end
  end
end
