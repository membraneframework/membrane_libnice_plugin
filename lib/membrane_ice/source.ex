defmodule Membrane.ICE.Source do
  @moduledoc """
  Element that receives buffers (over UDP or TCP) and sends them on relevant pads.

  As Source works analogously to the Sink here we only describe features that are specific
  for Source.

  ## Architecture and pad semantics
  Receiving data on component with id `component_id`  will cause in conveying this data on pad
  with id `component_id`.

  ## Interacting with Source
  Interacting with Source is the same as with Sink. Please refer to `Membrane.ICE.Sink` for
  details.

  ### Messages Source is able to process
  Messages Source is able to process are the same as for Sink. Please refer to `Membrane.ICE.Sink`
  for details.

  ### Messages Source sends
  Source sends all messages that Sink sends. Please refer to `Membrane.ICE.Sink` for details.
  """

  use Membrane.Source

  alias Membrane.Buffer
  alias Membrane.ICE.Common
  alias Membrane.ICE.Handshake

  require Unifex.CNode
  require Membrane.Logger

  def_options n_components: [
                type: :integer,
                default: 1,
                description: "Number of components that will be created in the stream"
              ],
              stream_name: [
                type: :string,
                default: "",
                description: "Name of the stream"
              ],
              stun_servers: [
                type: [:string],
                default: [],
                description: "List of stun servers in form of ip:port"
              ],
              controlling_mode: [
                type: :bool,
                default: false,
                description: "Refer to RFC 8445 section 4 - Controlling and Controlled Agent"
              ],
              port_range: [
                type: :range,
                default: 0..0,
                description: "The port range to use"
              ],
              handshake_module: [
                type: :module,
                default: Handshake.Default,
                description: "Module implementing Handshake behaviour"
              ],
              handshake_opts: [
                type: :list,
                default: [],
                description: "Options for handshake module. They will be passed to start_link
                function of handshake_module"
              ]

  def_output_pad :output,
    availability: :on_request,
    caps: :any,
    mode: :push

  @impl true
  def handle_init(options) do
    %__MODULE__{
      n_components: n_components,
      stream_name: stream_name,
      stun_servers: stun_servers,
      controlling_mode: controlling_mode,
      port_range: port_range,
      handshake_module: handshake_module,
      handshake_opts: handshake_opts
    } = options

    {:ok, ice} =
      ExLibnice.start_link(
        parent: self(),
        stun_servers: stun_servers,
        controlling_mode: controlling_mode,
        port_range: port_range
      )

    state = %Common.State{
      ice: ice,
      controlling_mode: controlling_mode,
      n_components: n_components,
      stream_name: stream_name,
      handshake_module: handshake_module,
      handshake_opts: handshake_opts
    }

    {:ok, state}
  end

  @impl true
  def handle_stopped_to_prepared(ctx, state) do
    Common.handle_stopped_to_prepared(ctx, state)
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, component_id), _ctx, state) do
    if MapSet.member?(state.connections, component_id) do
      {:ok, state}
    else
      Membrane.Logger.error("""
      Connection for component: #{component_id} not established yet. Cannot add pad
      """)

      {{:ok, notify: :connection_not_established_yet}, state}
    end
  end

  @impl true
  def handle_other(
        {:ice_payload, _stream_id, component_id, payload},
        %{playback_state: :playing} = ctx,
        state
      ) do
    Membrane.Logger.debug("Received payload: #{Membrane.Payload.size(payload)} bytes")

    actions =
      case Map.get(ctx.pads, Pad.ref(:output, component_id)) do
        nil ->
          Membrane.Logger.warn("""
          Pad for component: #{component_id} not added yet. Probably your component is not in READY
          state yet. Ignoring message
          """)

          []

        pad ->
          [buffer: {pad.ref, %Buffer{payload: payload}}]
      end

    {{:ok, actions}, state}
  end

  @impl true
  def handle_other(msg, ctx, state) do
    Common.handle_ice_message(msg, ctx, state)
  end
end
