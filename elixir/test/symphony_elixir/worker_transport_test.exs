defmodule SymphonyElixir.WorkerTransportTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.WorkerTransport
  @binding %{"cycle" => "cycle", "branch" => "agent/task", "interval" => "interval", "generation" => "generation"}
  @worker %{interval: "interval", handle: %{context: %{"cycle_id" => "cycle"}}}
  @cycle %{"id" => "cycle", "work" => %{"branch" => "agent/task"}}

  test "only a bound actual stop acknowledgement releases the worker" do
    success = Map.merge(@binding, %{"phase" => "stopped"})

    for proof <- [success, Map.put(success, "generation", "old"), Map.put(success, "phase", "stopping")] do
      callback =
        WorkerTransport.callbacks(@binding, fn request ->
          assert request == %{"action" => "stop", "interval" => "interval", "generation" => "generation"}
          {:ok, proof}
        end)[:stop_verifier]

      assert callback.(@worker) == if(proof == success, do: :stopped, else: :stop_unconfirmed)
    end

    callback = WorkerTransport.callbacks(@binding, fn _ -> flunk("stale worker contacted transport") end)[:stop_verifier]
    assert callback.(%{}) == :stop_unconfirmed
    assert callback.(%{@worker | interval: "old"}) == :stop_unconfirmed
    callback = WorkerTransport.callbacks(@binding, fn _ -> {:error, :timeout} end)[:stop_verifier]
    assert callback.(@worker) == :stop_unconfirmed

    for failure <- [fn _ -> raise "transport down" end, fn _ -> exit(:timeout) end] do
      assert WorkerTransport.callbacks(@binding, failure)[:stop_verifier].(@worker) == :stop_unconfirmed
    end
  end

  test "export is bound to the cycle, branch, interval, generation and requested SHA" do
    success = Map.merge(@binding, %{"path" => "/private/export.bundle", "sha" => "sha"})

    for proof <- [success, Map.put(success, "interval", "old"), Map.put(success, "sha", "different")] do
      callback =
        WorkerTransport.callbacks(@binding, fn request ->
          assert request["action"] == "export" and request["sha"] == "sha"
          {:ok, proof}
        end)[:export_candidate]

      assert callback.(@cycle, "sha") == if(proof == success, do: {:ok, "/private/export.bundle"}, else: {:error, :worker_export_unconfirmed})
    end

    callback = WorkerTransport.callbacks(@binding, fn _ -> flunk("wrong cycle contacted transport") end)[:export_candidate]
    assert callback.(%{}, "sha") == {:error, :worker_export_unconfirmed}
    assert callback.(put_in(@cycle["work"]["branch"], "dev"), "sha") == {:error, :worker_export_unconfirmed}
  end

  @tag skip: :os.type() != {:unix, :linux}
  test "framed Python transport rejects errors, truncated output and timeouts" do
    root = Path.join(System.tmp_dir!(), "worker-transport-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    script = Path.join(root, "fixture.py")

    for {body, expected} <- [
          {"{'ok': {'phase': 'stopped'}}", {:ok, %{"phase" => "stopped"}}},
          {"{'error': 'unconfirmed'}", {:error, :worker_transport_unconfirmed}}
        ] do
      File.write!(
        script,
        "import sys,struct,json\nn=struct.unpack('!I',sys.stdin.buffer.read(4))[0]\nsys.stdin.buffer.read(n)\nx=json.dumps(#{body}).encode()\nsys.stdout.buffer.write(struct.pack('!I',len(x))+x)\n"
      )

      assert WorkerTransport.exchange(script, "fixture", %{}) == expected
    end

    File.write!(script, "raise SystemExit(1)\n")
    assert WorkerTransport.exchange(script, "fixture", %{}) == {:error, :worker_transport_unconfirmed}
    File.write!(script, "import time\ntime.sleep(2)\n")
    assert WorkerTransport.exchange(script, "fixture", %{}, 20) == {:error, :worker_transport_timeout}
  end
end
