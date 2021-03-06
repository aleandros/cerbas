defmodule Request do
  @moduledoc false
  @derive [Poison.Encoder]
  defstruct [:func, :args, :source, :user, :delay]
end

defmodule Response do
  @moduledoc false
  @derive [Poison.Encoder]
  defstruct [:status, :data]
end

defmodule ForcedReturnError do
  @moduledoc false
  defexception [:message]
end

defmodule RequestDataError do
  @moduledoc false
  defexception [:message]
end

defmodule Cerbas do
  @moduledoc """
  Documentation for Cerbas.
  """

  require Logger

  def reg_tuple(name) do
    {:via, Registry, {Registry.Cerbas, name}}
  end

  def init() do
    {:ok, _} = Registry.start_link(:unique, Registry.Cerbas)
    if from_mix(), do: get_version() |> color_me(:lightblue) 
    Agent.start_link(fn -> false end, name: reg_tuple("halt"))
    command(["SET", "CERBAS-COUNTER", 0])
    command(["DELETE", "CERBAS-QUEUE"])
    {_,_,db} = get_redis_conf()
    "CERBAS ... will stop at loop number #{@stop_at_loop_number}" 
    |> color_info(:yellow)
    mainloop(1, db)
    {:ok, self()}
  end

  def color_reset , do: "\x1b[0m"
  def color_red, do: "\x1b[31m"
  def color_green, do: "\x1b[32m"
  def color_yellow, do: "\x1b[33m"
  def color_blue, do: "\x1b[34m"
  def color_magenta, do: "\x1b[35m"
  def color_light_blue, do: "\x1b[94m"
  def color_light_red, do: "\x1b[91m"

  def color_me(value, atom \\ nil) do
    color = 
    case atom do
      :red -> color_red
      :green -> color_green
      :yellow -> color_yellow
      :blue -> color_blue
      :magenta -> color_magenta
      :lightblue -> color_light_blue
      :lightred -> color_light_red
      _ -> ""
    end
    "#{color}#{value}#{color_reset}"
  end

  def color_info(color, msg) when is_atom(color) do
    msg |> color_me(color) |> Logger.info
    color
  end

  def color_info(msg, color) when is_atom(color) do
    msg |> color_me(color) |> Logger.info
    msg
  end

  def zformat(value, zeroes \\ 1) do
    value
    |> Integer.to_string
    |> String.rjust(zeroes, ?0)
  end

  defp lua_script_redis() , do: """
    local channel = KEYS[1];
    local msgpack_channel = "MSGPACK:" .. channel;
    local value = ARGV[1];
    redis.call('PUBLISH', channel, value);
    local mvalue = cmsgpack.pack(cjson.decode(value));
    return redis.call('PUBLISH', msgpack_channel, mvalue);
    """

  def command(cmd) do
    :poolboy.transaction(:redix_poolboy, &Redix.command(&1, cmd))
  end

  def pipeline(commands) do
    :poolboy.transaction(:redix_poolboy, &Redix.pipeline(&1, commands))
  end

  defp popper() do
    pop = command(["LPOP", "CERBAS-QUEUE"])
    case pop do
      {:ok, value} -> {:ok, value}
      {:error, :timeout} -> {:timeout, nil}
      _ -> {:error, nil}
    end
  end

  defp rkey_name(number) when is_number(number) do
    "CERBAS-REQUEST-#{zformat(number,10)}"
  end

  defp channels(number, db) when is_number(number) do
    channel = "CERBAS-RESPONSE-#{db}-#{zformat(number,10)}"
    m_channel = "MSGPACK:#{channel}"
    {channel, m_channel}
  end

  def from_mix do
    Mix.env
    true
    rescue
      e in UndefinedFunctionError -> false
  end

  def get_version do
    erlang = :erlang.system_info(:otp_release)
    "#{System.version}/#{erlang}"
  end

  def get_request_parts(request) do
    req = Poison.decode!(request, as: %Request{}) 
    if from_mix do
      "API Request #{inspect req}" |> color_info(:yellow)
    end
    case req do
      %Request{func: func, args: args, source: source, delay: delay} 
      when is_number(delay) -> 
        if delay > 0 do
          "Delaying request #{delay} milliseconds" |> color_info(:yellow)
          :timer.sleep(delay) 
          "After delay" |> color_info(:green)
        end
        {func, args, source}
      %Request{func: func, args: args, source: source} -> {func, args, source}
      _ ->
        "invalid request" |> color_info(:red)
        {"invalidrequest", "invalid", "invalid"}
    end
    rescue 
      e ->  "invalid request" |> color_info(:red)
            {"invalidrequest", "invalid", "invalid"}
  end

  @delay_in_every_loop Application.get_env(:cerbas, :delay_in_every_loop) 

  def mainloop(0, db) , do: "Stopped" |> color_info(:cyan)

  def mainloop(n, db) when is_number(n) do
    if Agent.get(reg_tuple("halt"), & &1) do
       mainloop(0, db)
    else
      :timer.sleep @delay_in_every_loop
      spawn_link __MODULE__, :process_request, [n, db]
      mainloop(n + 1, db)
    end
  end

  def get_redis_conf() do
    {redis_host, redis_port, redis_db} = 
      Application.get_env(:cerbas, :redis_conf)
  end

  @stop_at_loop_number Application.get_env(:cerbas, :stop_at_loop_number)

  def process_request(n, db) when n > (@stop_at_loop_number - 1) do
    if n == @stop_at_loop_number do 
      Agent.update(reg_tuple("halt"), &(not &1)) 
      "Last" |> color_info(:yellow)
    end
  end

  def process_request(n, db) do
    content = 
    case popper() do
      {:ok, value} ->
        case value do
          nil -> "skipping" 
          val -> 
            {v, _} = Integer.parse(val)
            v
        end
      {:error, _} ->
        "ERROR" 
      {:timeout, _} ->
        "TIMEOUT" 
      _ ->
        "ETC" 
    end 
    if is_number(content) do
      key = rkey_name(content)
      {channel, msgpack_channel} = channels(content, db)
      {:ok, request} = command(["GET", key])
      command(["DELETE", key])
      data =
      case request |> get_request_parts |> Cerbas.Dispatcher.dispatch do
        {:error, msg} -> %Response{status: "error", data: msg}
        val -> %Response{status: "ok", data: val}
        _ -> nil 
      end 
      unless is_nil(data) do
        contents = Poison.encode!(data)
        command(["EVAL", lua_script_redis, 1, channel, contents])
      end
    else
      "#{n} #{content}" |> Logger.info
    end
  end

end
