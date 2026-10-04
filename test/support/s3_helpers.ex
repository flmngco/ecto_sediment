defmodule EctoSediment.S3Helpers do
  @moduledoc false
  # Helpers for S3 tests. By default they use the local SeaweedFS gateway,
  # which accepts unsigned requests. Set S3_TEST_ENDPOINT, S3_TEST_BUCKET,
  # S3_TEST_ACCESS_KEY_ID and S3_TEST_SECRET_ACCESS_KEY (as in sediment) to
  # use another S3 server; the bucket must then exist. All tests share
  # one bucket with unique prefixes.

  def bucket, do: System.get_env("S3_TEST_BUCKET", "ecto-tests")
  def endpoint, do: System.get_env("S3_TEST_ENDPOINT", "http://127.0.0.1:8333")

  defp custom_server?, do: System.get_env("S3_TEST_ENDPOINT") != nil

  # list_objects/1 sends unsigned requests, which only SeaweedFS accepts
  def can_list?, do: not custom_server?()

  # The current snapshot key of a running S3-backed repo
  def snapshot(repo) do
    {:ok, %{snapshot: snapshot}} = Ecto.Adapters.Sediment.s3_info(repo)
    snapshot
  end

  defp host_port do
    %URI{host: host, port: port} = URI.parse(endpoint())
    {String.to_charlist(host), port}
  end

  def unique_prefix(name) do
    "ecto/#{name}/#{System.unique_integer([:positive])}-#{System.os_time()}"
  end

  def s3_opts(prefix, owner \\ "ecto-test", extra \\ []) do
    [
      bucket: bucket(),
      prefix: prefix,
      endpoint: endpoint(),
      access_key_id: System.get_env("S3_TEST_ACCESS_KEY_ID", "any"),
      secret_access_key: System.get_env("S3_TEST_SECRET_ACCESS_KEY", "any"),
      owner: owner,
      lease_ttl_ms: 5_000
    ] ++ extra
  end

  def ensure_bucket do
    if custom_server?() do
      :ok
    else
      "HTTP/1.1 " <> <<status::binary-size(3), _::binary>> =
        http("PUT /#{bucket()} HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\n")

      if status in ["200", "409"], do: :ok, else: {:error, status}
    end
  end

  def list_objects(prefix) do
    body =
      http(
        "GET /#{bucket()}?list-type=2&prefix=#{URI.encode_www_form(prefix)} HTTP/1.1\r\n" <>
          "Host: 127.0.0.1\r\n"
      )

    ~r{<Key>([^<]+)</Key>}
    |> Regex.scan(body, capture: :all_but_first)
    |> List.flatten()
  end

  # Unsigned, like list_objects/1: SeaweedFS only
  def delete_object(key) do
    "HTTP/1.1 " <> <<status::binary-size(3), _::binary>> =
      http("DELETE /#{bucket()}/#{key} HTTP/1.1\r\nHost: 127.0.0.1\r\n")

    if status in ["200", "204"], do: :ok, else: {:error, status}
  end

  # Unsigned GET/PUT of one object, for copying a prefix: SeaweedFS only
  def get_object(key) do
    response = http("GET /#{bucket()}/#{key} HTTP/1.1\r\nHost: 127.0.0.1\r\n")
    [head, body] = :binary.split(response, "\r\n\r\n")
    "HTTP/1.1 200" <> _ = head
    body
  end

  def put_object(key, body) do
    "HTTP/1.1 200" <> _ =
      http(
        "PUT /#{bucket()}/#{key} HTTP/1.1\r\nHost: 127.0.0.1\r\n" <>
          "Content-Length: #{byte_size(body)}\r\n",
        body
      )

    :ok
  end

  defp http(request, body \\ "") do
    {host, port} = host_port()
    {:ok, socket} = :gen_tcp.connect(host, port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, [request, "Connection: close\r\n\r\n", body])
    recv_all(socket, "")
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, :closed} -> :gen_tcp.close(socket) && acc
    end
  end
end
