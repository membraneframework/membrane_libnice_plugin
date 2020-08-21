defmodule Membrane.ICE.Source do
  use Membrane.Source

  require Unifex.CNode
  require Membrane.Logger

  alias Membrane.Buffer
  alias Membrane.ICE.Common

  def_options stun_servers: [
                type: [:string],
                default: [],
                description: "List of stun servers in form of ip:port"
              ],
              turn_servers: [
                type: [:string],
                default: [],
                description: "List of turn servers in form of ip:port:proto:username:passwd"
              ],
              controlling_mode: [
                type: :integer,
                default: 0,
                description: "0 for FALSE, 1 for TRUE"
              ]

  def_output_pad :output,
    availability: :on_request,
    caps: :any,
    mode: :push

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            cnode: Unifex.CNode.t(),
            connections: MapSet.t(),
            pads: %{{stream_id :: integer, component_id :: integer} => Pad.ref_t()}
          }
    defstruct cnode: nil,
              connections: MapSet.new(),
              pads: %{}
  end

  @impl true
  def handle_init(%__MODULE__{} = options) do
    %__MODULE__{
      stun_servers: stun_servers,
      turn_servers: turn_servers,
      controlling_mode: controlling_mode
    } = options

    {:ok, cnode} = Unifex.CNode.start_link(:native)
    :ok = Unifex.CNode.call(cnode, :init, [stun_servers, turn_servers, controlling_mode])

    state = %State{
      cnode: cnode
    }

    {:ok, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, {stream_id, component_id}) = pad, _ctx, state) do
    case MapSet.member?(state.connections, {stream_id, component_id}) do
      true ->
        new_pads = Map.put(state.pads, {stream_id, component_id}, pad)
        {:ok, %State{state | pads: new_pads}}

      false ->
        {{:ok, notify: :connection_not_established_yet}, state}
    end
  end

  @impl true
  def handle_pad_removed(Pad.ref(:output, {_stream_id, _component_id}) = pad, _ctx, state) do
    new_pads =
      state.pads
      |> Enum.filter(fn {_key, inner_pad} -> inner_pad != pad end)
      |> Enum.into(%{})

    {:ok, %State{state | pads: new_pads}}
  end

  @impl true
  def handle_other(
        {:ice_payload, stream_id, component_id, payload},
        %{playback_state: :playing},
        state
      ) do
    Membrane.Logger.debug("recv payload: #{Membrane.Payload.size(payload)} bytes")

    actions =
      case Map.get(state.pads, {stream_id, component_id}) do
        nil ->
          Membrane.Logger.warn("pad for stream: #{stream_id} and component: #{component_id} not
          added yet. Probably your component is not in READY state. Ignoring message.")
          []

        pad ->
          [buffer: {pad, %Buffer{payload: payload}}]
      end

    {{:ok, actions}, state}
  end

  @impl true
  def handle_other({:component_state_ready, stream_id, component_id} = msg, _ctx, state) do
    new_connections = MapSet.put(state.connections, {stream_id, component_id})
    new_state = %State{state | connections: new_connections}
    {{:ok, notify: msg}, new_state}
  end

  @impl true
  def handle_other(msg, ctx, state) do
    Common.handle_ice_message(msg, ctx, state)
  end
end
